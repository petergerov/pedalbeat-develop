import Foundation
import Accelerate
import AVFAudio
import Synchronization

/// One Solitito prediction as probabilities (pitch presence, root, major/minor, no-chord).
struct SolititoFrame {
    var pitch = [Float](repeating: 0, count: 12)   // sigmoid(pitch_logits), L1-ready
    var root = [Float](repeating: 0, count: 12)    // softmax over 12 pitch classes
    var major: Float = 0
    var minor: Float = 0
    var noChord: Float = 1
}

/// Solitito guitar chord backend (MIT model from greblus/solitito-ai), macOS and iOS.
/// 16 kHz sparse CQT features → ONNX → maj/min LiveChord for Bass Follow.
///
/// The audio thread only copies samples into a preallocated lock-free ring (`process`).
/// A worker thread loads the model on first use, resamples host rate → 16 kHz with an
/// anti-aliasing converter (any host rate), computes the features and runs the model;
/// the result comes back through atomics (`latestChord`).
final class SolititoChordEngine: @unchecked Sendable {
    static let targetSR: Double = 16_000
    static let fftSize = 8192
    static let hop = 256
    static let cqtBins = 144
    static let featureSize = 168
    static let ctxFrames = 48
    static let inputGain: Float = 2

    private let shared = SolititoShared()
    /// Inline mode (offline tools/tests): `process` runs the worker step on the caller's thread.
    private let inlineWorker: SolititoWorker?

    /// Model loaded and running. False until the first `process` call has loaded it
    /// (a few hundred ms on the worker), and for good when the model files are missing.
    var isReady: Bool { shared.state.load(ordering: .acquiring) == SolititoShared.ready }

    /// Finished model runs; changes once per prediction (every ≥ 96 ms).
    var predictionCount: Int { shared.predSeq.load(ordering: .acquiring) }

    var latestChord: LiveChord? {
        let r = shared.pubRoot.load(ordering: .relaxed)
        guard r >= 0, r < 12 else { return nil }
        return LiveChord(root: r, minor: shared.pubMinor.load(ordering: .relaxed) != 0,
                         confidence: Float(bitPattern: shared.pubConf.load(ordering: .relaxed)))
    }

    /// Audio thread: copies the newest prediction when it is newer than `seq`.
    func latestFrame(after seq: Int, into out: inout SolititoFrame) -> Int? {
        let s = shared.predSeq.load(ordering: .acquiring)
        guard s != seq, s > 0 else { return nil }
        let p = shared.pred + (s & 1) * SolititoShared.predSize
        for i in 0..<12 { out.pitch[i] = p[i]; out.root[i] = p[12 + i] }
        out.major = p[24]; out.minor = p[25]; out.noChord = p[26]
        // Two more predictions during the copy reuse this slot — skip, next call is clean.
        guard shared.predSeq.load(ordering: .acquiring) - s < 2 else { return nil }
        return s
    }

    init(threaded: Bool = true) {
        if threaded {
            inlineWorker = nil
            let worker = SolititoWorker(shared: shared)
            let thread = Thread { worker.run() }
            thread.name = "PedalBeat Solitito"
            thread.qualityOfService = .userInitiated
            thread.start()
        } else {
            inlineWorker = SolititoWorker(shared: shared)
        }
    }

    deinit {
        shared.running.store(false, ordering: .releasing)
    }

    /// Any thread, not concurrently with `process`.
    func setSampleRate(_ sr: Double) {
        shared.hostRate.store(Int(max(sr, 1).rounded()), ordering: .releasing)
        reset()
    }

    /// Realtime-safe: the worker drops its buffered audio and context on the next step.
    func reset() {
        shared.generation.wrappingAdd(1, ordering: .releasing)
        shared.pubRoot.store(-1, ordering: .relaxed)
        shared.pubConf.store(0, ordering: .relaxed)
        // Keep predSeq so a stale in-flight predict is ignored via generation; do not rewind.
    }

    /// Audio thread: feed host-rate audio. The first call asks the worker to load the model.
    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int) {
        guard frames > 0 else { return }
        let state = shared.state.load(ordering: .acquiring)
        if state == SolititoShared.idle {
            shared.state.store(SolititoShared.wanted, ordering: .releasing)
        }
        if state == SolititoShared.ready {
            shared.push(left: left, right: right, frames: frames)
        }
        if let w = inlineWorker {
            while w.step() {}
        }
    }
}

/// State shared by the audio thread (producer) and the worker (consumer).
private final class SolititoShared: @unchecked Sendable {
    static let idle = 0, wanted = 1, loading = 2, ready = 3, unavailable = 4
    /// ≈ 1.4 s at 192 kHz; power of two for masking.
    static let capacity = 1 << 18
    /// pitch[12] + root[12] + major + minor + noChord, double-buffered.
    static let predSize = 27

    let ring: UnsafeMutablePointer<Float>
    /// Newest prediction; slot `predSeq & 1` is complete once `predSeq` is stored.
    let pred: UnsafeMutablePointer<Float>
    let predSeq = Atomic<Int>(0)
    /// Monotonic sample counters; `write` is owned by the audio thread, `read` by the worker.
    let write = Atomic<Int>(0)
    let read = Atomic<Int>(0)
    let hostRate = Atomic<Int>(44_100)
    let generation = Atomic<Int>(0)
    let state = Atomic<Int>(SolititoShared.idle)
    let running = Atomic<Bool>(true)
    let pubRoot = Atomic<Int>(-1)
    let pubMinor = Atomic<Int>(0)
    let pubConf = Atomic<UInt32>(0)

    init() {
        ring = .allocate(capacity: Self.capacity)
        ring.initialize(repeating: 0, count: Self.capacity)
        pred = .allocate(capacity: 2 * Self.predSize)
        pred.initialize(repeating: 0, count: 2 * Self.predSize)
    }

    deinit {
        ring.deallocate()
        pred.deallocate()
    }

    /// Audio thread. Drops what does not fit (worker stalled); never blocks or allocates.
    func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int) {
        let w = write.load(ordering: .relaxed)
        let r = read.load(ordering: .acquiring)
        let n = min(frames, Self.capacity - (w - r))
        guard n > 0 else { return }
        let mask = Self.capacity - 1
        if let right {
            for i in 0..<n { ring[(w + i) & mask] = 0.5 * (left[i] + right[i]) }
        } else {
            for i in 0..<n { ring[(w + i) & mask] = left[i] }
        }
        write.store(w + n, ordering: .releasing)
    }
}

/// Everything that is not realtime-safe: model, resampler, features, inference.
private final class SolititoWorker: @unchecked Sendable {
    typealias E = SolititoChordEngine
    private static let chunk = 4096

    private let shared: SolititoShared
    private var session: OpaquePointer? // SolititoORTSession*

    // Host rate → 16 kHz
    private var converter: AVAudioConverter?
    private var converterRate = 0
    private var inBuf: AVAudioPCMBuffer?
    private var outBuf: AVAudioPCMBuffer?
    private var lastGeneration = -1

    // Last fftSize samples at 16 kHz (ring) and hop counter
    private var buf16 = [Float](repeating: 0, count: SolititoChordEngine.fftSize)
    private var buf16Write = 0
    private var buf16Filled = 0
    private var samplesSinceHop = 0

    // Analysis window at 16 kHz
    private var winBuf = [Float](repeating: 0, count: SolititoChordEngine.fftSize)
    private var hann = [Float](repeating: 0, count: SolititoChordEngine.fftSize)
    private var fftReal = [Float](repeating: 0, count: SolititoChordEngine.fftSize)
    private var fftImag = [Float](repeating: 0, count: SolititoChordEngine.fftSize)
    private var fftSetup: FFTSetup?
    private let log2n: vDSP_Length = 13 // 8192

    // Sparse CQT
    private var cqtOffsets = [UInt32]()
    private var cqtFftIdx = [UInt32]()
    private var cqtRe = [Float]()
    private var cqtIm = [Float]()
    private var chromaW = [Float]()

    private var history = [[Float]](
        repeating: [Float](repeating: 0, count: SolititoChordEngine.featureSize),
        count: SolititoChordEngine.ctxFrames)
    private var histWrite = 0
    private var histCount = 0
    private var hopsSincePredict = 0
    /// Hops between model runs: at least 6 (96 ms), more when the model is slow on this device,
    /// so it uses at most `maxDuty` of one core (one run is ~35 ms on an M2 Pro).
    private var predictEveryHops = 6
    private static let minPredictHops = 6
    private static let maxDuty = 0.4

    init(shared: SolititoShared) {
        self.shared = shared
        vDSP_hann_window(&hann, vDSP_Length(E.fftSize), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        if let s = session { solitito_ort_destroy(s) }
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup) }
    }

    /// Thread body; returns once the engine is gone.
    func run() {
        while shared.running.load(ordering: .acquiring) {
            let worked = autoreleasepool { step() }
            if !worked {
                let idle = shared.state.load(ordering: .relaxed) != SolititoShared.ready
                usleep(idle ? 50_000 : 4_000)
            }
        }
    }

    /// One unit of work. Returns false when there was nothing to do.
    func step() -> Bool {
        switch shared.state.load(ordering: .acquiring) {
        case SolititoShared.wanted:
            shared.state.store(SolititoShared.loading, ordering: .relaxed)
            let ok = loadResources()
            // Start reading at the current write position once the audio thread feeds the ring.
            lastGeneration = -1
            shared.state.store(ok ? SolititoShared.ready : SolititoShared.unavailable, ordering: .releasing)
            return ok
        case SolititoShared.ready:
            return drain()
        default:
            return false
        }
    }

    // MARK: - Resample + hops

    private func drain() -> Bool {
        let gen = shared.generation.load(ordering: .acquiring)
        let rate = shared.hostRate.load(ordering: .acquiring)
        if gen != lastGeneration || rate != converterRate {
            lastGeneration = gen
            clearAnalysis()
            if rate != converterRate { makeConverter(rate: rate) }
            converter?.reset()
            shared.read.store(shared.write.load(ordering: .acquiring), ordering: .releasing)
            return true
        }
        guard let converter, let inBuf, let outBuf,
              let src = inBuf.floatChannelData?[0], let dst = outBuf.floatChannelData?[0] else { return false }

        var r = shared.read.load(ordering: .relaxed)
        let w = shared.write.load(ordering: .acquiring)
        // Fell behind by more than 0.5 s: skip to the last 0.25 s so the chord stays current.
        if w - r > rate / 2 { r = w - rate / 4 }
        let n = min(w - r, Self.chunk)
        guard n > 0 else { return false }
        let mask = SolititoShared.capacity - 1
        for i in 0..<n { src[i] = shared.ring[(r + i) & mask] }
        shared.read.store(r + n, ordering: .releasing)
        inBuf.frameLength = AVAudioFrameCount(n)

        var fed = false
        var error: NSError?
        outBuf.frameLength = 0
        _ = converter.convert(to: outBuf, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        for i in 0..<Int(outBuf.frameLength) { push16(dst[i]) }
        return true
    }

    private func makeConverter(rate: Int) {
        converterRate = rate
        guard let from = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate),
                                       channels: 1, interleaved: false),
              let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: E.targetSR,
                                     channels: 1, interleaved: false),
              let c = AVAudioConverter(from: from, to: to) else {
            converter = nil
            return
        }
        c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        converter = c
        inBuf = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(Self.chunk))
        let outCap = Int((Double(Self.chunk) * E.targetSR / Double(rate)).rounded(.up)) + 256
        outBuf = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: AVAudioFrameCount(outCap))
    }

    private func clearAnalysis() {
        for i in buf16.indices { buf16[i] = 0 }
        buf16Write = 0
        buf16Filled = 0
        samplesSinceHop = 0
        histWrite = 0
        histCount = 0
        hopsSincePredict = 0
    }

    private func push16(_ s: Float) {
        buf16[buf16Write] = s
        buf16Write = (buf16Write + 1) % E.fftSize
        buf16Filled = min(buf16Filled + 1, E.fftSize)
        samplesSinceHop += 1
        // First window when the buffer is full, then one per hop.
        if buf16Filled == E.fftSize, samplesSinceHop >= E.hop {
            samplesSinceHop = 0
            analyzeLatestWindow()
        }
    }

    private func analyzeLatestWindow() {
        for i in 0..<E.fftSize {
            winBuf[i] = buf16[(buf16Write + i) % E.fftSize] * E.inputGain
        }
        var feat = [Float](repeating: 0, count: E.featureSize)
        computeFeatures(window: winBuf, into: &feat)
        history[histWrite] = feat
        histWrite = (histWrite + 1) % E.ctxFrames
        histCount = min(histCount + 1, E.ctxFrames)
        hopsSincePredict += 1
        if histCount >= E.ctxFrames, hopsSincePredict >= predictEveryHops {
            hopsSincePredict = 0
            let t0 = DispatchTime.now().uptimeNanoseconds
            predict()
            let took = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
            let hopSeconds = Double(E.hop) / E.targetSR
            let needed = Int((took / Self.maxDuty / hopSeconds).rounded(.up))
            // Follow the measured cost, smoothed so one slow run does not stall the chord.
            predictEveryHops = max(Self.minPredictHops, (predictEveryHops * 3 + needed) / 4)
        }
    }

    // MARK: - Load

    private func loadResources() -> Bool {
        guard let dspURL = Self.resourceURL("dsp_weights.json"),
              let modelURL = Self.resourceURL("best_model_v2_take6_chords.onnx") else {
            return false
        }
        guard loadDSP(dspURL) else { return false }
        session = solitito_ort_create(modelURL.path)
        return session != nil
    }

    private static func resourceURL(_ name: String) -> URL? {
        let bundles = [Bundle(for: SolititoWorker.self), Bundle.main]
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for b in bundles {
            if let u = b.url(forResource: base, withExtension: ext.isEmpty ? nil : ext) { return u }
            if let u = b.url(forResource: base, withExtension: ext.isEmpty ? nil : ext, subdirectory: "Solitito") { return u }
        }
        // Dev fallback: repo ThirdParty path
        let candidates = [
            URL(fileURLWithPath: "ThirdParty/Solitito/\(name)"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("ThirdParty/Solitito/\(name)"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func loadDSP(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["format"] as? String) == "sparse-csr-v1" else { return false }
        guard let offsets = obj["cqt_offsets"] as? [NSNumber],
              let idx = obj["cqt_fft_idx"] as? [NSNumber],
              let re = obj["cqt_re"] as? [NSNumber],
              let im = obj["cqt_im"] as? [NSNumber],
              let chroma = obj["chroma_weights"] as? [NSNumber] else { return false }
        cqtOffsets = offsets.map { $0.uint32Value }
        cqtFftIdx = idx.map { $0.uint32Value }
        cqtRe = re.map { $0.floatValue }
        cqtIm = im.map { $0.floatValue }
        chromaW = chroma.map { $0.floatValue }
        return cqtOffsets.count == E.cqtBins + 1 && chromaW.count == E.cqtBins * 12
    }

    // MARK: - Features + model

    private func computeFeatures(window: [Float], into out: inout [Float]) {
        guard let setup = fftSetup else { return }
        // Windowed real FFT via vDSP
        for i in 0..<E.fftSize {
            fftReal[i] = window[i] * hann[i]
            fftImag[i] = 0
        }
        fftReal.withUnsafeMutableBufferPointer { rp in
            fftImag.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
        // Sparse CQT magnitude
        var cqtMag = [Float](repeating: 0, count: E.cqtBins)
        for b in 0..<E.cqtBins {
            let from = Int(cqtOffsets[b]), to = Int(cqtOffsets[b + 1])
            var sumRe: Float = 0, sumIm: Float = 0
            for j in from..<to {
                let k = Int(cqtFftIdx[j])
                let re = fftReal[k], im = fftImag[k]
                let wr = cqtRe[j], wi = cqtIm[j]
                sumRe += re * wr - im * wi
                sumIm += re * wi + im * wr
            }
            cqtMag[b] = sqrtf(sumRe * sumRe + sumIm * sumIm)
        }
        let norm = logNormalise(cqtMag)
        var chroma = [Float](repeating: 0, count: 12)
        for i in 0..<12 {
            var s: Float = 0
            for k in 0..<E.cqtBins { s += norm[k] * chromaW[k * 12 + i] }
            chroma[i] = s
        }
        let cmax = chroma.max() ?? 0
        if cmax > 1e-9 { for i in 0..<12 { chroma[i] /= cmax } }
        var bass = [Float](repeating: 0, count: 12)
        for i in 0..<12 {
            let idx = i * 2
            if idx + 1 < E.cqtBins { bass[i] = (norm[idx] + norm[idx + 1]) * 0.5 }
        }
        for i in 0..<E.cqtBins { out[i] = norm[i] }
        for i in 0..<12 { out[E.cqtBins + i] = chroma[i] }
        for i in 0..<12 { out[E.cqtBins + 12 + i] = bass[i] }
    }

    private func logNormalise(_ mag: [Float]) -> [Float] {
        let frameMax = mag.max() ?? 0
        let ref = max(frameMax, 0.005)
        return mag.map { x in
            let db = 20 * log10f(max(x, 1e-9) / ref)
            return min(max((db + 80) / 80, 0), 1)
        }
    }

    private func predict() {
        guard let session else { return }
        var flat = [Float](repeating: 0, count: E.ctxFrames * E.featureSize)
        let start = (histWrite - E.ctxFrames + E.ctxFrames * 2) % E.ctxFrames
        for t in 0..<E.ctxFrames {
            let fr = history[(start + t) % E.ctxFrames]
            let base = t * E.featureSize
            for i in 0..<E.featureSize { flat[base + i] = fr[i] }
        }
        var root = [Float](repeating: 0, count: 13)
        var qual = [Float](repeating: 0, count: 11)
        var pitch = [Float](repeating: 0, count: 12)
        guard solitito_ort_predict(session, flat, &root, &qual, &pitch) == 0 else { return }
        // A reset while the model ran: this result belongs to the old audio.
        guard shared.generation.load(ordering: .acquiring) == lastGeneration else { return }

        let rootP = softmax(root)
        let qualP = softmax(qual)
        let next = shared.predSeq.load(ordering: .relaxed) + 1
        let out = shared.pred + (next & 1) * SolititoShared.predSize
        var pcSum: Float = 0
        for i in 0..<12 { pcSum += rootP[i] }
        for i in 0..<12 {
            out[i] = 1 / (1 + expf(-pitch[i]))
            out[12 + i] = rootP[i] / max(pcSum, 1e-6)
        }
        let minorP = qualP[1] + qualP[4] + qualP[5] // min, min7, m7b5
        out[24] = max(0, 1 - qualP[10] - minorP)
        out[25] = minorP
        out[26] = max(rootP[12], qualP[10]) // Noise root or N quality
        shared.predSeq.store(next, ordering: .releasing)

        let (ri, rc) = argmaxSoftmax(root)
        let (qi, qc) = argmaxSoftmax(qual)
        // quality: 0 maj, 1 min, … 10 N ; root 12 = Noise — clear sticky chord on silence/N.
        if ri >= 12 || qi == 10 {
            shared.pubRoot.store(-1, ordering: .relaxed)
            shared.pubConf.store(0, ordering: .relaxed)
            return
        }
        let minor = (qi == 1 || qi == 4 || qi == 5)
        shared.pubMinor.store(minor ? 1 : 0, ordering: .relaxed)
        shared.pubConf.store((rc * qc).bitPattern, ordering: .relaxed)
        shared.pubRoot.store(ri, ordering: .relaxed)
    }

    private func softmax(_ logits: [Float]) -> [Float] {
        let mx = logits.max() ?? 0
        let e = logits.map { expf($0 - mx) }
        let s = max(e.reduce(0, +), 1e-9)
        return e.map { $0 / s }
    }

    private func argmaxSoftmax(_ logits: [Float]) -> (Int, Float) {
        var mx = logits[0]
        var mi = 0
        for i in 1..<logits.count where logits[i] > mx { mx = logits[i]; mi = i }
        var sum: Float = 0
        for v in logits { sum += expf(v - mx) }
        let p = expf(logits[mi] - mx) / max(sum, 1e-9)
        return (mi, p)
    }
}
