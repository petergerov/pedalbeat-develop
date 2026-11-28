import Foundation
import Accelerate
import Synchronization

/// One ranked chord hypothesis (ML score before / after priors).
struct ChordScore: Sendable {
    var chord: LiveChord
    var score: Float
}

/// Softmax-linear chroma → 24 maj/min classes. Template prior + optional legacy linear bake.
final class ChordClassifier: @unchecked Sendable {
    private var weight: [[Float]]
    private var bias: [Float]

    init() {
        weight = Self.templateWeights()
        bias = [Float](repeating: 0, count: 24)
    }

    func load(weights w: [[Float]], bias b: [Float]) {
        guard w.count == 24, w.allSatisfy({ $0.count == 12 }), b.count == 24 else { return }
        weight = w
        bias = b
    }

    /// Mix template prior with optional song-trained weights (keeps all-style generality).
    func loadBlended(trainedW: [[Float]], trainedB: [Float], trainedMix: Float = 0.28) {
        guard trainedW.count == 24, trainedB.count == 24 else { return }
        let a = min(max(trainedMix, 0), 0.5)
        let tw = Self.templateWeights()
        var w = tw
        var b = [Float](repeating: 0, count: 24)
        for c in 0..<24 {
            for i in 0..<12 {
                w[c][i] = tw[c][i] * (1 - a) + trainedW[c][i] * a
            }
            b[c] = trainedB[c] * a
        }
        weight = w
        bias = b
    }

    func rank(_ chroma: [Float]) -> [ChordScore] {
        var scored = [ChordScore]()
        scored.reserveCapacity(24)
        for c in 0..<24 {
            let s = dot(weight[c], chroma) + bias[c]
            scored.append(ChordScore(chord: LiveChord(root: c % 12, minor: c >= 12, confidence: 0), score: s))
        }
        scored.sort { $0.score > $1.score }
        let minS = scored.last?.score ?? 0
        if minS < 0 {
            for i in scored.indices { scored[i].score -= minS }
        }
        return scored
    }

    func score(_ chroma: [Float], chord: LiveChord) -> Float {
        let c = chord.root + (chord.minor ? 12 : 0)
        return max(0, dot(weight[c], chroma) + bias[c] + 0.5)
    }

    private func dot(_ w: [Float], _ x: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<12 { s += w[i] * x[i] }
        return s
    }

    static func templateWeights() -> [[Float]] {
        var w = [[Float]](repeating: [Float](repeating: 0, count: 12), count: 24)
        for root in 0..<12 {
            w[root][root] = 1.4
            w[root][(root + 4) % 12] = 1.35
            w[root][(root + 7) % 12] = 1.0
            w[root][(root + 3) % 12] = -1.15
            w[root + 12][root] = 1.4
            w[root + 12][(root + 3) % 12] = 1.35
            w[root + 12][(root + 7) % 12] = 1.0
            w[root + 12][(root + 4) % 12] = -1.15
        }
        return w
    }
}

/// Realtime-safe audio → chord detector: Goertzel chroma, MLP+CNN+HMM ensemble,
/// onset hold, key/progression priors, bass-PC bias (guitar / keys / voice-like).
final class ChordDetector: @unchecked Sendable {
    static let windowSize = 2048
    static let hopSize = 1024
    private static let hangAlpha: Float = 0.18
    private static let confirmHops = 3
    private static let switchMargin: Float = 0.22
    private static let holdSilenceHops = 12
    private static let onsetWindowHops = 8
    private static let sustainSwitchExtra: Float = 0.35

    /// Analysis rate after decimation (44.1–48 kHz for 88.2/96/176.4/192 kHz hosts), so the
    /// 2048-sample window spans the same time and pitch resolution at every host rate.
    private var sampleRate: Float = 44100
    /// Host samples averaged into one analysis sample (1 at ≤ 48 kHz-ish rates).
    private var decimation = 1
    private var decimSum: Float = 0
    private var decimCount = 0
    private var fifo: UnsafeMutablePointer<Float>
    private var write = 0
    private var filled = false
    private var samplesSinceHop = 0
    private var window: UnsafeMutablePointer<Float>
    private var frame: UnsafeMutablePointer<Float>
    private var chroma = [Float](repeating: 0, count: 12)
    private var hangChroma = [Float](repeating: 0, count: 12)
    private var bassPC = [Float](repeating: 0, count: 12)
    /// Smoothed bass pitch-class (raw `bassPC` is too frame-noisy for root vetoes).
    private var hangBass = [Float](repeating: 0, count: 12)
    private static let hangBassAlpha: Float = 0.28
    /// Chroma L1 novelty gate for onsets (same-chord strums stay below this).
    private static let harmonicNoveltyThresh: Float = 0.42
    private var goertzelCoeff = [Float](repeating: 0, count: 48)
    private var goertzelFreq = [Float](repeating: 0, count: 48)
    private let levelPub = AtomicFloat(0)
    private var levelEnv: Float = 0
    private var prevFluxRMS: Float = 0
    private let chordCode = AtomicInt(-1)
    var gate: Float = 0.008
    var minConfidence: Float = 0.45

    /// Song / written-bass pitch class = key tonic for the diatonic prior.
    var songRoot: Int = 4
    /// When nil, mode is inferred from the first stable chords; otherwise forced.
    var preferMinorKey: Bool? = nil

    private var locked: LiveChord?
    private var candidate: LiveChord?
    private var candidateCount = 0
    private var silenceHops = 0
    private var hopsSinceOnset = 100
    private var keyTonic = -1
    private var keyMinor = true
    private var history = [Int]()
    private let ensemble = ChordEnsemble()
    private let solitito = SolititoChordEngine()
    private let timbreCode = AtomicInt(ChordTimbre.mixed.rawValue)
    private var appliedTimbre = ChordTimbre.mixed.rawValue
    /// Whether `applyTimbre` saw Solitito ready (it loads on first use, in the background).
    private var appliedSolititoReady = false
    private var solititoSeq = 0
    private var solititoFrame = SolititoFrame()
    /// P(chord) of the newest Solitito prediction, index root + (minor ? 12 : 0).
    private var solititoProb = [Float](repeating: 0, count: 24)
    private var blockSumSq: Float = 0
    private var blockCount = 0
    /// Agreeing model runs (≥ 96 ms apart) before a Solitito switch locks.
    private static let solititoConfirm = 2
    /// ≈ 0.9 s of analysis-hop units for Solitito onset window.
    private static let solititoOnsetHops = 40

    /// Bass Follow input profile (Mixed / Guitar / Keys / Voice / Solitito Guitar).
    var chordTimbre: ChordTimbre {
        get { ChordTimbre(rawValue: timbreCode.value) ?? .mixed }
        set { timbreCode.value = newValue.rawValue }
    }

    var inputLevel: Float { levelPub.value }
    /// Latest smoothed chroma (for offline training / probes).
    var debugHangChroma: [Float] { hangChroma }
    /// Latest smoothed bass pitch-class (for offline training).
    var debugHangBass: [Float] { hangBass }
    /// True while the Solitito ONNX front end is active (affects follower slow-confirm).
    var isSolititoActive: Bool {
        appliedTimbre == ChordTimbre.solititoGuitar.rawValue && appliedSolititoReady
    }

    var lastChordName: String {
        let c = chordCode.value
        guard c >= 0 else { return "—" }
        let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
        return names[c % 12] + (c >= 12 ? "m" : "")
    }

    var lastRootName: String {
        let c = chordCode.value
        guard c >= 0 else { return "—" }
        let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
        return names[c % 12]
    }

    init() {
        fifo = .allocate(capacity: Self.windowSize)
        frame = .allocate(capacity: Self.windowSize)
        window = .allocate(capacity: Self.windowSize)
        fifo.initialize(repeating: 0, count: Self.windowSize)
        vDSP_hann_window(window, vDSP_Length(Self.windowSize), Int32(vDSP_HANN_NORM))
        rebuildGoertzel(sampleRate: sampleRate)
        applyTimbre(.mixed, force: true)
    }

    deinit {
        fifo.deallocate(); frame.deallocate(); window.deallocate()
    }

    func setSampleRate(_ sr: Double) {
        let host = max(sr, 1)
        decimation = max(1, Int((host / 48_000).rounded()))
        sampleRate = Float(host / Double(decimation))
        rebuildGoertzel(sampleRate: sampleRate)
        solitito.setSampleRate(sr)
        reset()
    }

    func reset() {
        write = 0
        filled = false
        samplesSinceHop = 0
        decimSum = 0
        decimCount = 0
        levelEnv = 0
        prevFluxRMS = 0
        levelPub.value = 0
        chordCode.value = -1
        locked = nil
        candidate = nil
        candidateCount = 0
        silenceHops = 0
        hopsSinceOnset = 100
        keyTonic = -1
        history.removeAll(keepingCapacity: true)
        for i in 0..<12 { hangChroma[i] = 0; bassPC[i] = 0; hangBass[i] = 0 }
        for i in 0..<24 { solititoProb[i] = 0 }
        blockSumSq = 0
        blockCount = 0
        solititoSeq = solitito.predictionCount
        ensemble.reset()
        solitito.reset()
        fifo.update(repeating: 0, count: Self.windowSize)
    }

    /// Tests: drop trained ML and use triad templates only.
    func useTemplateClassifierOnly() {
        ensemble.useTemplatesOnly()
    }

    private func syncTimbre() {
        let code = timbreCode.value
        if code != appliedTimbre {
            applyTimbre(ChordTimbre(rawValue: code) ?? .mixed, force: true)
        } else if code == ChordTimbre.solititoGuitar.rawValue, solitito.isReady != appliedSolititoReady {
            // Model finished loading: switch the priors over without dropping its context.
            applyTimbre(.solititoGuitar, force: false)
        }
    }

    private func applyTimbre(_ t: ChordTimbre, force: Bool) {
        let wasSolitito = isSolititoActive
        appliedTimbre = t.rawValue
        appliedSolititoReady = solitito.isReady
        if t == .solititoGuitar {
            if appliedSolititoReady {
                ensemble.useTemplatesOnly() // priors still use templates when Solitito locked
            } else if let m = ChordMLWeights.model(for: .guitar) {
                ensemble.loadTrained(m) // while the model loads / missing assets
            }
        } else if let m = ChordMLWeights.model(for: t) {
            ensemble.loadTrained(m)
        } else {
            ensemble.useTemplatesOnly()
        }
        if force {
            ensemble.reset()
            solitito.reset()
        }
        if isSolititoActive != wasSolitito {
            // Features came from the other front end; keep `locked` so the bass holds.
            for i in 0..<12 { chroma[i] = 0; hangChroma[i] = 0; bassPC[i] = 0; hangBass[i] = 0 }
            for i in 0..<24 { solititoProb[i] = 0 }
            candidate = nil
            candidateCount = 0
            solititoSeq = solitito.predictionCount
        }
    }

    private func rebuildGoertzel(sampleRate sr: Float) {
        for i in 0..<48 {
            let midi = 36 + i
            let f = 440 * powf(2, (Float(midi) - 69) / 12)
            goertzelFreq[i] = f
            goertzelCoeff[i] = 2 * cosf(2 * Float.pi * f / sr)
        }
    }

    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int) -> LiveChord? {
        guard frames > 0 else { return nil }
        syncTimbre()
        var peak: Float = 0
        var sumSq: Float = 0
        for i in 0..<frames {
            let m = 0.5 * (left[i] + (right?[i] ?? left[i]))
            peak = max(peak, abs(m))
            sumSq += m * m
        }
        let rms = sqrtf(sumSq / Float(frames))
        let instant = min(max(peak * 1.4, rms * 3), 1)
        if instant >= levelEnv { levelEnv = instant } else { levelEnv *= 0.92 }
        levelPub.value = levelEnv

        // Feeding Solitito also asks it to load; the Guitar model covers until it is ready.
        if chordTimbre == .solititoGuitar { solitito.process(left: left, right: right, frames: frames) }
        if isSolititoActive {
            trackSolititoOnsets(sumSq: sumSq, frames: frames)
            return processSolitito()
        }

        var published: LiveChord?
        for i in 0..<frames {
            // Boxcar average: anti-alias low-pass + decimation (chroma lives below ~2 kHz).
            decimSum += 0.5 * (left[i] + (right?[i] ?? left[i]))
            decimCount += 1
            guard decimCount >= decimation else { continue }
            let m = decimSum / Float(decimation)
            decimSum = 0
            decimCount = 0
            fifo[write] = m
            write += 1
            if write >= Self.windowSize { write = 0; filled = true }
            samplesSinceHop += 1
            if filled && samplesSinceHop >= Self.hopSize {
                samplesSinceHop = 0
                if let c = analyzeFrame() { published = c }
            }
        }
        return published
    }

    private func analyzeFrame() -> LiveChord? {
        let start = write
        for i in 0..<Self.windowSize {
            frame[i] = fifo[(start + i) % Self.windowSize] * window[i]
        }
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(Self.windowSize))

        let flux = max(0, rms - prevFluxRMS * 1.05)
        prevFluxRMS = max(rms, prevFluxRMS * 0.92)
        let energyOnset = flux > max(gate * 2.5, prevFluxRMS * 0.15 + 0.01)

        if rms < gate {
            silenceHops += 1
            if silenceHops >= Self.holdSilenceHops {
                candidate = nil
                candidateCount = 0
            }
            hopsSinceOnset = min(hopsSinceOnset + 1, 1000)
            return locked
        }
        silenceHops = 0

        for i in 0..<12 { chroma[i] = 0; bassPC[i] = 0 }
        for i in 0..<48 {
            let e = goertzelPower(coeff: goertzelCoeff[i], freq: goertzelFreq[i])
            let oct = i / 12
            let w: Float = oct == 0 ? 1.4 : oct == 1 ? 1.15 : oct == 2 ? 0.85 : 0.55
            chroma[i % 12] += e * w
            if oct <= 1 { bassPC[i % 12] += e }
        }
        normalize(&chroma)
        normalize(&bassPC)

        // Harmonic novelty vs smoothed chroma: same-chord re-strums have low novelty and
        // must not reopen the permissive onset switch window.
        var novelty: Float = 0
        for i in 0..<12 { novelty += abs(chroma[i] - hangChroma[i]) }
        let harmonicOnset = energyOnset && novelty >= Self.harmonicNoveltyThresh
        // First lock: allow energy onsets so we can grab an initial chord at all.
        if harmonicOnset || (locked == nil && energyOnset) {
            hopsSinceOnset = 0
        } else {
            hopsSinceOnset = min(hopsSinceOnset + 1, 1000)
        }
        let nearOnset = hopsSinceOnset <= Self.onsetWindowHops

        let blend = nearOnset ? min(1, Self.hangAlpha * 2.2) : Self.hangAlpha
        for i in 0..<12 {
            hangChroma[i] = hangChroma[i] * (1 - blend) + chroma[i] * blend
            hangBass[i] = hangBass[i] * (1 - Self.hangBassAlpha) + bassPC[i] * Self.hangBassAlpha
        }

        let ranked = ensemble.rank(chroma: hangChroma, bass: hangBass)
        guard let adjusted = applyPriors(ranked, nearOnset: nearOnset) else { return locked }
        return stabilize(adjusted, nearOnset: nearOnset)
    }

    /// Solitito path: energy onset and silence per 1024-sample analysis hop.
    private func trackSolititoOnsets(sumSq: Float, frames: Int) {
        blockSumSq += sumSq
        blockCount += frames
        let hop = Self.hopSize * decimation
        guard blockCount >= hop else { return }
        let hops = blockCount / hop
        let rms = sqrtf(blockSumSq / Float(blockCount))
        blockSumSq = 0
        blockCount = 0
        let flux = max(0, rms - prevFluxRMS * 1.05)
        prevFluxRMS = max(rms, prevFluxRMS * powf(0.92, Float(hops)))
        if rms < gate {
            silenceHops = min(silenceHops + hops, 1000)
            if silenceHops >= Self.holdSilenceHops { candidate = nil; candidateCount = 0 }
        } else {
            silenceHops = 0
        }
        if rms >= gate, flux > max(gate * 2.5, prevFluxRMS * 0.15 + 0.01) {
            hopsSinceOnset = 0
        } else {
            hopsSinceOnset = min(hopsSinceOnset + hops, 1000)
        }
    }

    /// One decision per model prediction; buffers without a new one return nil so the
    /// follower dual-timescale also counts predictions rather than host buffers.
    private func processSolitito() -> LiveChord? {
        guard let seq = solitito.latestFrame(after: solititoSeq, into: &solititoFrame) else { return nil }
        solititoSeq = seq
        let f = solititoFrame
        let nearOnset = hopsSinceOnset <= Self.solititoOnsetHops

        var pitchSum: Float = 0, hangSum: Float = 0
        for i in 0..<12 { pitchSum += f.pitch[i]; hangSum += hangChroma[i] }
        let a: Float = hangSum < 1e-6 ? 1 : (nearOnset ? 0.8 : 0.5)
        for i in 0..<12 {
            chroma[i] = pitchSum > 1e-6 ? f.pitch[i] / pitchSum : 0
            bassPC[i] = f.root[i]
            hangChroma[i] = hangChroma[i] * (1 - a) + chroma[i] * a
            hangBass[i] = hangBass[i] * (1 - a) + bassPC[i] * a
        }
        for r in 0..<12 {
            solititoProb[r] = f.root[r] * f.major
            solititoProb[r + 12] = f.root[r] * f.minor
        }
        guard silenceHops < Self.holdSilenceHops, f.noChord < 0.5 else { return locked }

        var ranked = [ChordScore]()
        ranked.reserveCapacity(24)
        for c in 0..<24 {
            let p = solititoProb[c]
            ranked.append(ChordScore(
                chord: LiveChord(root: c % 12, minor: c >= 12, confidence: p),
                score: 2 * p
            ))
        }
        ranked.sort { $0.score > $1.score }
        guard let adjusted = applyPriors(ranked, nearOnset: nearOnset) else { return locked }
        return stabilize(adjusted, nearOnset: nearOnset)
    }

    /// Model evidence for `c` on the same scale as candidates given to `applyPriors`.
    private func modelScore(_ c: LiveChord) -> Float {
        if isSolititoActive {
            return 2 * solititoProb[c.root + (c.minor ? 12 : 0)]
        }
        return ensemble.score(chroma: hangChroma, chord: c)
    }

    private func normalize(_ v: inout [Float]) {
        var sum: Float = 0
        vDSP_sve(v, 1, &sum, 12)
        if sum > 1e-12 {
            var inv = 1 / sum
            vDSP_vsmul(v, 1, &inv, &v, 1, 12)
        }
    }

    private func goertzelPower(coeff: Float, freq: Float) -> Float {
        var s0: Float = 0, s1: Float = 0, s2: Float = 0
        for i in 0..<Self.windowSize {
            s0 = frame[i] + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let w = 2 * Float.pi * freq / sampleRate
        let re = s1 - s2 * cosf(w)
        let im = s2 * sinf(w)
        return re * re + im * im
    }

    private func applyPriors(_ ranked: [ChordScore], nearOnset: Bool) -> ChordScore? {
        ensureKey()
        var best: ChordScore?
        var second: Float = 0
        for s0 in ranked.prefix(8) {
            var s = s0
            s.score *= diatonicBoost(s.chord)
            s.score *= progressionBoost(s.chord, nearOnset: nearOnset)
            s.score *= bassRootBoost(s.chord)
            s.score *= negativeEvidence(s.chord)
            if locked.map({ $0.root == s.chord.root && $0.minor == s.chord.minor }) == true {
                s.score *= nearOnset ? 1.05 : 1.12
            }
            if best == nil || s.score > best!.score {
                if let b = best { second = max(second, b.score) }
                best = s
            } else {
                second = max(second, s.score)
            }
        }
        guard var b = best else { return nil }
        // Gap confidence: near-ties → low conf → hold current chord (old formula was ≥ 0.5 always).
        let gapConf = b.score <= 0 ? 0 : max(0, 1 - second / max(b.score, 1e-3))
        let modelConf = b.chord.confidence
        b.chord.confidence = min(max(0.55 * gapConf + 0.45 * modelConf, 0), 1)
        guard b.chord.confidence >= minConfidence * 0.8, b.score >= 0.12 else { return nil }
        return b
    }

    private func ensureKey() {
        if keyTonic < 0 {
            keyTonic = ((songRoot % 12) + 12) % 12
            if let forced = preferMinorKey {
                keyMinor = forced
            } else {
                // Infer later from locked chords; start neutral-major around song root.
                keyMinor = false
            }
        }
        // Adapt mode from recent locks (works for major and minor songs alike).
        if history.count >= 3 {
            let tonic = keyTonic
            let minorsAtTonic = history.suffix(5).filter { $0 == tonic + 12 }.count
            let majorsAtTonic = history.suffix(5).filter { $0 == tonic }.count
            if preferMinorKey == nil {
                if minorsAtTonic > majorsAtTonic { keyMinor = true }
                if majorsAtTonic > minorsAtTonic { keyMinor = false }
            }
            // If we keep landing on the relative minor as "home", shift tonic there.
            if preferMinorKey == nil, let locked, locked.minor,
               history.suffix(4).filter({ $0 == locked.root + 12 }).count >= 3 {
                keyTonic = locked.root
                keyMinor = true
            }
        }
    }

    private func diatonicBoost(_ c: LiveChord) -> Float {
        guard keyTonic >= 0 else { return 1 }
        // Soft prior only: song root major + parallel minor + relative minor.
        // Hard key lock breaks other styles (E-bass songs that are really in Am, etc.).
        let tonics = [keyTonic, (keyTonic + 9) % 12] // relative minor root if key is major
        var best: Float = 0.8
        for t in tonics {
            for minorKey in [false, true] {
                let pcs = minorKey ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
                let deg = (c.root - t + 12) % 12
                guard pcs.contains(deg) else { continue }
                var s: Float = 1.05
                if minorKey {
                    if c.minor && deg == 0 { s = 1.22 }
                    else if !c.minor && deg == 7 { s = 1.18 } // V
                    else if c.minor && [2, 5].contains(deg) { s = 1.12 }
                    else if !c.minor && [3, 8, 10].contains(deg) { s = 1.12 }
                } else {
                    if !c.minor && deg == 0 { s = 1.22 }
                    else if !c.minor && [5, 7].contains(deg) { s = 1.15 }
                    else if c.minor && deg == 9 { s = 1.15 }
                }
                best = max(best, s)
            }
        }
        return best
    }

    private func progressionBoost(_ c: LiveChord, nearOnset: Bool) -> Float {
        guard let prev = history.last else { return 1 }
        let to = c.root + (c.minor ? 12 : 0)
        if prev == to { return nearOnset ? 1.12 : 1.22 }

        let fromRoot = prev % 12
        let fromMinor = prev >= 12
        let dRoot = min((c.root - fromRoot + 12) % 12, (fromRoot - c.root + 12) % 12)

        // Mid-sustain: never reward leaving; crush shared-tone stealers.
        if !nearOnset {
            if sharedToneTrap(fromRoot: fromRoot, fromMinor: fromMinor, to: c) { return 0.2 }
            if dRoot == 1 { return 0.45 }
            return 0.85
        }

        // Onset: style-agnostic functional moves relative to key + circle-of-fifths.
        if sharedToneTrap(fromRoot: fromRoot, fromMinor: fromMinor, to: c) {
            // Allow at onset but no bonus (E→Am, F→Am, C→Am, …)
            return 0.9
        }
        // Relative major/minor (same triad pitch classes shifted)
        if c.root == fromRoot, c.minor != fromMinor { return 0.7 }
        if !fromMinor && c.minor && c.root == (fromRoot + 9) % 12 { return 1.15 } // C→Am
        if fromMinor && !c.minor && c.root == (fromRoot + 3) % 12 { return 1.15 } // Am→C

        // Fifths / fourths (any style)
        if dRoot == 5 { return 1.35 }
        // Stepwise diatonic root motion
        if dRoot == 2 || dRoot == 3 { return 1.2 }
        if dRoot == 1 { return 0.55 }
        return 1
    }

    /// Mid-sustain confusion when the new chord reuses the ringing root/tones but its
    /// own root is still weaker (E→Am, F→Am, C→Am, …) — not a real root change.
    private func sharedToneTrap(fromRoot: Int, fromMinor: Bool, to: LiveChord) -> Bool {
        if to.root == fromRoot, to.minor == fromMinor { return false }
        let fromThird = (fromRoot + (fromMinor ? 3 : 4)) % 12
        let fromFifth = (fromRoot + 7) % 12
        let toThird = (to.root + (to.minor ? 3 : 4)) % 12
        let toFifth = (to.root + 7) % 12
        let fromTones = [fromRoot, fromThird, fromFifth]
        let toTones = [to.root, toThird, toFifth]
        let shared = fromTones.filter { toTones.contains($0) }.count
        let oldIsInner = fromRoot == toThird || fromRoot == toFifth
        guard shared >= 2 || oldIsInner else { return false }
        guard hangChroma[fromRoot] > 0.08 else { return false }
        // Real change: new root clearly louder. Steal: old root still dominates.
        return hangChroma[to.root] < hangChroma[fromRoot] * 0.95
    }

    private func bassRootBoost(_ c: LiveChord) -> Float {
        var bestPC = 0
        var best: Float = 0
        for i in 0..<12 where hangBass[i] > best { best = hangBass[i]; bestPC = i }
        guard best > 0.08 else { return 1 }
        if c.root == bestPC { return 1.32 }
        if (c.root + 7) % 12 == bestPC { return 1.05 }
        return 0.72
    }

    private func negativeEvidence(_ c: LiveChord) -> Float {
        let third = (c.root + (c.minor ? 3 : 4)) % 12
        let fifth = (c.root + 7) % 12
        let r = hangChroma[c.root], t = hangChroma[third], f = hangChroma[fifth]
        if r < 0.04 { return 0.35 }
        if t < 0.025 && f < 0.025 { return 0.4 }
        let rival = hangChroma[(c.root + (c.minor ? 4 : 3)) % 12]
        // Major/minor quality: rival third must not dominate (G vs Gm, E vs Em).
        if rival > t * 1.05 { return 0.4 }
        if rival > t * 0.85 { return 0.7 }
        if t < 0.035 && rival < 0.02 { return 0.85 } // weak third — don't force quality
        return 1
    }

    private func stabilize(_ incoming: ChordScore, nearOnset: Bool) -> LiveChord? {
        let same = locked.map { $0.root == incoming.chord.root && $0.minor == incoming.chord.minor } ?? false

        if locked == nil {
            if let c = candidate, c.root == incoming.chord.root, c.minor == incoming.chord.minor {
                candidateCount += 1
            } else {
                candidate = incoming.chord
                candidateCount = 1
            }
            if candidateCount >= 2, incoming.chord.confidence >= minConfidence {
                lock(incoming.chord)
            }
            return locked
        }

        if same {
            candidate = nil
            candidateCount = 0
            var refreshed = incoming.chord
            refreshed.confidence = max(incoming.chord.confidence, locked!.confidence * 0.9)
            locked = refreshed
            publish(refreshed)
            return refreshed
        }

        // Mid-sustain: if the locked root is still loud, don't jump to a chord that barely has it
        // (classic F ↔ Am chatter — both contain A and C). Skip on Solitito (pitch probs ≈ 1).
        if !isSolititoActive, !nearOnset, hangChroma[locked!.root] > 0.1,
           hangChroma[incoming.chord.root] < hangChroma[locked!.root] * 0.85 {
            candidate = nil
            candidateCount = 0
            return locked
        }

        let margin = Self.switchMargin + (nearOnset ? 0 : Self.sustainSwitchExtra)
        // Like-for-like with `applyPriors`: include progression stay boost (not a weaker ad-hoc factor).
        let lockedScore = modelScore(locked!)
            * diatonicBoost(locked!)
            * progressionBoost(locked!, nearOnset: nearOnset)
            * bassRootBoost(locked!)
            * negativeEvidence(locked!)
        guard incoming.score >= lockedScore * (1 + margin),
              incoming.chord.confidence >= minConfidence else {
            candidate = nil
            candidateCount = 0
            return locked
        }
        // Clear new bass root at a strum → allow faster leave (all styles).
        var needHops = nearOnset ? Self.confirmHops : Self.confirmHops + 2
        if isSolititoActive {
            needHops = nearOnset ? Self.solititoConfirm : Self.solititoConfirm + 1
        } else if nearOnset, hangBass[incoming.chord.root] > 0.14,
                  hangBass[incoming.chord.root] > hangBass[locked!.root] * 1.15 {
            needHops = max(2, Self.confirmHops - 1)
        }
        if let c = candidate, c.root == incoming.chord.root, c.minor == incoming.chord.minor {
            candidateCount += 1
        } else {
            candidate = incoming.chord
            candidateCount = 1
        }
        if candidateCount >= needHops { lock(incoming.chord) }
        return locked
    }

    private func lock(_ chord: LiveChord) {
        locked = chord
        candidate = nil
        candidateCount = 0
        history.append(chord.root + (chord.minor ? 12 : 0))
        if history.count > 8 { history.removeFirst() }
        publish(chord)
    }

    private func publish(_ chord: LiveChord) {
        chordCode.value = chord.root + (chord.minor ? 12 : 0)
    }
}

/// Input-source profile for Bass Follow chord ML (specialized weights per timbre).
public enum ChordTimbre: Int, CaseIterable, Sendable {
    case mixed = 0
    case guitar = 1
    case keys = 2
    case voice = 3
    /// Packaged Solitito ONNX guitar model (MIT), macOS and iOS. Uses `.guitar` while it loads.
    case solititoGuitar = 4

    public var name: String {
        switch self {
        case .mixed: "Mixed"
        case .guitar: "Guitar"
        case .keys: "Keys"
        case .voice: "Voice"
        case .solititoGuitar: "Guitar (Solitito)"
        }
    }

    public static var count: Int { allCases.count }
}

/// Optional baked weights from `Tools/ChordProbe/train.swift` → `ChordMLWeights+Trained.swift`.
enum ChordMLWeights {
    struct MLPWeights { var w1: [Float]; var b1: [Float]; var w2: [Float]; var b2: [Float] }
    struct CNNWeights { var convW: [Float]; var convB: [Float]; var denseW: [Float]; var denseB: [Float] }
    struct Model {
        /// Legacy linear 24×12 (kept for older probes; ensemble prefers mlp/cnn).
        var weights: [[Float]]
        var bias: [Float]
        var mlp: MLPWeights? = nil
        var cnn: CNNWeights? = nil
    }
    static var trained: Model? { model(for: .mixed) }
    static func model(for timbre: ChordTimbre) -> Model? {
        if timbre == .solititoGuitar { return nil }
        return ChordMLWeightsTrained.model(for: timbre) ?? ChordMLWeightsTrained.model(for: .mixed)
    }
}
