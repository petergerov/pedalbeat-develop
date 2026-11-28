import Foundation
import AudioToolbox

/// Train PedalBeat chord ensemble (MLP + tiny CNN) on multi-timbre synthetic
/// chroma + optional labeled WAV (e.g. BeatBudyTest). Emits ChordMLWeights+Trained.swift.
@main
struct ChordTrain {
    static func main() {
        let args = CommandLine.arguments
        let wavPath = args.count >= 2 ? args[1] : nil
        let destPath = args.count >= 3 ? args[2] : "Core/BassFollow/ChordMLWeights+Trained.swift"

        var mlpSamples: [([Float], Int)] = []
        var cnnSamples: [([[Float]], Int)] = [] // 8 frames × 12 → label

        print("synthetic multi-timbre…")
        synthCorpus(intoMLP: &mlpSamples, intoCNN: &cnnSamples)
        print("synthetic chord changes…")
        synthChanges(intoMLP: &mlpSamples, intoCNN: &cnnSamples)
        print("synthetic no-chord / noise…")
        synthNoChord(intoMLP: &mlpSamples, intoCNN: &cnnSamples)

        if let wavPath {
            print("wav \(wavPath)…")
            ingestWAV(path: wavPath, intoMLP: &mlpSamples, intoCNN: &cnnSamples)
        }

        print("mlp samples: \(mlpSamples.count)  cnn sequences: \(cnnSamples.count)")
        guard mlpSamples.count > 100 else {
            fputs("too few samples\n", stderr)
            exit(1)
        }

        let labeledMLP = mlpSamples.filter { $0.1 >= 0 }
        let labeledCNN = cnnSamples.filter { $0.1 >= 0 }
        let (legacyW, legacyB) = trainLinear(samples: labeledMLP.map { (Array($0.0.prefix(12)), $0.1) })
        let mlp = trainMLP(samples: mlpSamples)
        let cnn = trainCNN(samples: cnnSamples)
        _ = labeledCNN // accuracy logged inside trainers for y >= 0 only

        emit(dest: destPath, legacyW: legacyW, legacyB: legacyB, mlp: mlp, cnn: cnn)
        print("wrote \(destPath)")
    }

    // MARK: - Synthetic multi-timbre

    enum Timbre: CaseIterable {
        case guitar, keys, voice, pad, bassHeavy
    }

    static func synthCorpus(intoMLP mlp: inout [([Float], Int)], intoCNN cnn: inout [([[Float]], Int)]) {
        var rng = SystemRandomNumberGenerator()
        for root in 0..<12 {
            for minor in [false, true] {
                let y = root + (minor ? 12 : 0)
                for _ in 0..<40 {
                    for timbre in Timbre.allCases {
                        let (ch, bass) = synthFrame(root: root, minor: minor, timbre: timbre, rng: &rng)
                        let prev = synthFrame(root: root, minor: minor, timbre: timbre, rng: &rng).0
                        var feat = [Float](repeating: 0, count: 36)
                        for i in 0..<12 {
                            feat[i] = ch[i]
                            feat[12 + i] = ch[i] - prev[i]
                            feat[24 + i] = bass[i]
                        }
                        mlp.append((feat, y))

                        // Rising onset sequence for CNN
                        var seq = [[Float]]()
                        for t in 0..<ChordCNN.frames {
                            let a = Float(t) / Float(ChordCNN.frames - 1)
                            var frame = [Float](repeating: 0, count: 12)
                            let (c, _) = synthFrame(root: root, minor: minor, timbre: timbre, rng: &rng)
                            for i in 0..<12 { frame[i] = c[i] * (0.25 + 0.75 * a) }
                            normalize12(&frame)
                            seq.append(frame)
                        }
                        cnn.append((seq, y))
                    }
                }
            }
        }
        // Confusion pairs: shared-tone neighbors, rotated across all 12 keys.
        let traps: [(Int, Bool, Int, Bool)] = [
            (4, false, 9, true), (5, false, 9, true), (0, false, 9, true),
            (7, false, 4, true), (2, false, 9, true), (9, true, 0, false),
            (5, false, 2, true), (7, false, 0, false)
        ]
        let rotated = traps.flatMap { tr in
            (0..<12).map { k in ((tr.0 + k) % 12, tr.1, (tr.2 + k) % 12, tr.3) }
        }
        for (r1, m1, r2, m2) in rotated {
            for _ in 0..<3 {
                for timbre in Timbre.allCases {
                    let (ch, bass) = synthFrame(root: r1, minor: m1, timbre: timbre, rng: &rng)
                    // Bleed a bit of the rival — model must still pick r1
                    let rival = synthFrame(root: r2, minor: m2, timbre: timbre, rng: &rng).0
                    var mix = ch
                    for i in 0..<12 { mix[i] = ch[i] * 0.82 + rival[i] * 0.18 }
                    normalize12(&mix)
                    var feat = [Float](repeating: 0, count: 36)
                    for i in 0..<12 {
                        feat[i] = mix[i]
                        feat[12 + i] = 0
                        feat[24 + i] = bass[i]
                    }
                    mlp.append((feat, r1 + (m1 ? 12 : 0)))
                }
            }
        }
    }

    /// CNN/MLP windows that span a real chord change (matches hangChroma blend rates).
    static func synthChanges(intoMLP mlp: inout [([Float], Int)], intoCNN cnn: inout [([[Float]], Int)]) {
        var rng = SystemRandomNumberGenerator()
        let moves = [5, 7, 2, 10, 3, 9, 4, 8, 1, 11]
        for root in 0..<12 {
            for minor in [false, true] {
                for timbre in Timbre.allCases {
                    for (n, move) in moves.enumerated() {
                        let r2 = (root + move) % 12
                        let m2 = n % 2 == 0 ? minor : !minor
                        let cut = Int.random(in: 1..<ChordCNN.frames, using: &rng)
                        var (hang, bass) = synthFrame(root: root, minor: minor, timbre: timbre, rng: &rng)
                        var prev = hang
                        var seq = [[Float]]()
                        for t in 0..<ChordCNN.frames {
                            let neu = t >= cut
                            let (raw, b) = synthFrame(
                                root: neu ? r2 : root, minor: neu ? m2 : minor, timbre: timbre, rng: &rng)
                            let blend: Float = neu ? 0.396 : 0.18
                            prev = hang
                            for i in 0..<12 {
                                hang[i] = hang[i] * (1 - blend) + raw[i] * blend
                                bass[i] = bass[i] * 0.72 + b[i] * 0.28
                            }
                            seq.append(hang)
                        }
                        let y = ChordCNN.frames - cut >= 2
                            ? r2 + (m2 ? 12 : 0) : root + (minor ? 12 : 0)
                        var feat = [Float](repeating: 0, count: 36)
                        for i in 0..<12 {
                            feat[i] = hang[i]
                            feat[12 + i] = hang[i] - prev[i]
                            feat[24 + i] = bass[i]
                        }
                        mlp.append((feat, y))
                        cnn.append((seq, y))
                    }
                }
            }
        }
    }

    /// No-chord / noise / single-note frames → label −1 (train toward uniform output).
    static func synthNoChord(intoMLP mlp: inout [([Float], Int)], intoCNN cnn: inout [([[Float]], Int)]) {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            var ch = [Float](repeating: 0, count: 12)
            var bass = [Float](repeating: 0, count: 12)
            let kind = Int.random(in: 0...2, using: &rng)
            switch kind {
            case 0: // broadband noise
                for i in 0..<12 {
                    ch[i] = Float.random(in: 0.02...0.2, using: &rng)
                    bass[i] = Float.random(in: 0...0.1, using: &rng)
                }
            case 1: // single note + weak harmonics
                let pc = Int.random(in: 0..<12, using: &rng)
                ch[pc] = 1
                ch[(pc + 7) % 12] = 0.15
                bass[pc] = 1
            default: // semitone cluster (muted chuck)
                let pc = Int.random(in: 0..<12, using: &rng)
                for d in -1...1 { ch[(pc + d + 12) % 12] = Float.random(in: 0.3...0.8, using: &rng) }
            }
            normalize12(&ch)
            normalize12(&bass)
            var feat = [Float](repeating: 0, count: 36)
            for i in 0..<12 {
                feat[i] = ch[i]
                feat[12 + i] = Float.random(in: -0.05...0.05, using: &rng)
                feat[24 + i] = bass[i]
            }
            mlp.append((feat, -1))
            let seq = (0..<ChordCNN.frames).map { _ -> [Float] in
                var f = ch
                for i in 0..<12 { f[i] = max(0, f[i] + Float.random(in: -0.03...0.03, using: &rng)) }
                normalize12(&f)
                return f
            }
            cnn.append((seq, -1))
        }
    }

    static func synthFrame(root: Int, minor: Bool, timbre: Timbre, rng: inout SystemRandomNumberGenerator) -> ([Float], [Float]) {
        var ch = [Float](repeating: 0, count: 12)
        var bass = [Float](repeating: 0, count: 12)
        let third = (root + (minor ? 3 : 4)) % 12
        let fifth = (root + 7) % 12
        let rival = (root + (minor ? 4 : 3)) % 12

        func noise(_ s: Float) -> Float { Float.random(in: -s...s, using: &rng) }

        switch timbre {
        case .guitar:
            ch[root] = 1.0 + noise(0.05)
            ch[third] = 0.75 + noise(0.08)
            ch[fifth] = 0.9 + noise(0.06)
            ch[(root + 2) % 12] += 0.12 // pick harmonics
            ch[rival] += 0.05
            bass[root] = 1.1; bass[fifth] = 0.35
        case .keys:
            ch[root] = 0.95; ch[third] = 0.9; ch[fifth] = 0.85
            ch[rival] += 0.02
            bass[root] = 0.7; bass[fifth] = 0.25
        case .voice:
            // Formant smear + weaker fifth
            ch[root] = 0.85; ch[third] = 0.7; ch[fifth] = 0.55
            for d in [-1, 1, 2] { ch[(root + d + 12) % 12] += 0.12 }
            ch[rival] += 0.08
            bass[root] = 0.55; bass[third] = 0.2
        case .pad:
            ch[root] = 0.7; ch[third] = 0.65; ch[fifth] = 0.65
            for i in 0..<12 { ch[i] += 0.04 + noise(0.03) }
            bass[root] = 0.4
        case .bassHeavy:
            ch[root] = 1.2; ch[third] = 0.45; ch[fifth] = 0.7
            bass[root] = 1.4; bass[fifth] = 0.5
        }
        for i in 0..<12 {
            ch[i] = max(0, ch[i] + noise(0.03))
            bass[i] = max(0, bass[i] + noise(0.02))
        }
        normalize12(&ch)
        normalize12(&bass)
        return (ch, bass)
    }

    static func normalize12(_ v: inout [Float]) {
        var s: Float = 0
        for x in v { s += x }
        guard s > 1e-8 else { return }
        for i in 0..<12 { v[i] /= s }
    }

    // MARK: - WAV (BeatBudyTest labels)

    static func ingestWAV(path: String, intoMLP mlp: inout [([Float], Int)], intoCNN cnn: inout [([[Float]], Int)]) {
        struct Seg { var start: Double; var end: Double; var root: Int; var minor: Bool }
        let segs: [Seg] = [
            .init(start: 0.2, end: 7.2, root: 9, minor: true),
            .init(start: 7.9, end: 12.1, root: 7, minor: false),
            .init(start: 12.2, end: 16.9, root: 5, minor: false),
            .init(start: 17.0, end: 19.5, root: 4, minor: false),
            .init(start: 19.7, end: 24.0, root: 9, minor: true),
            .init(start: 24.9, end: 26.4, root: 9, minor: true),
            .init(start: 29.4, end: 31.2, root: 7, minor: false),
            .init(start: 31.5, end: 36.0, root: 5, minor: false),
            .init(start: 36.3, end: 41.4, root: 4, minor: false),
        ]
        func label(at t: Double) -> (Int, Bool)? {
            for s in segs where t >= s.start && t < s.end { return (s.root, s.minor) }
            return nil
        }

        var file: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(URL(fileURLWithPath: path) as CFURL, &file)
        guard status == noErr, let file else { fputs("open wav failed\n", stderr); return }
        defer { ExtAudioFileDispose(file) }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var size = UInt32(MemoryLayout.size(ofValue: asbd))
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, size, &asbd)
        guard status == noErr else { return }

        let det = ChordDetector()
        det.setSampleRate(44100)
        det.gate = 0.003
        det.songRoot = 4
        det.preferMinorKey = true
        det.useTemplateClassifierOnly() // features only

        let frames = 1024
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { buf.deallocate() }
        var abl = AudioBufferList(mNumberBuffers: 1,
                                  mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: buf))

        var prevCh = [Float](repeating: 0, count: 12)
        var ring = [[Float]](repeating: [Float](repeating: 0, count: 12), count: ChordCNN.frames)
        var ringN = 0
        var t = 0.0
        while true {
            var n = UInt32(frames)
            status = ExtAudioFileRead(file, &n, &abl)
            if status != noErr || n == 0 { break }
            _ = det.process(left: UnsafePointer(buf), right: nil, frames: Int(n))
            if let (root, minor) = label(at: t) {
                let ch = det.debugHangChroma
                let bass = det.debugHangBass
                var sum: Float = 0
                for x in ch { sum += x }
                if sum > 0.05 {
                    // Balance: one minor vs three majors in this clip.
                    let copies = minor ? 2 : 1
                    var ready = false
                    if ringN < ChordCNN.frames {
                        ring[ringN] = ch
                        ringN += 1
                        ready = ringN == ChordCNN.frames
                    } else {
                        for i in 0..<(ChordCNN.frames - 1) { ring[i] = ring[i + 1] }
                        ring[ChordCNN.frames - 1] = ch
                        ready = true
                    }
                    // Pitch-rotate across all 12 keys so Am/G/F/E bias cannot dominate.
                    for k in 0..<12 {
                        var feat = [Float](repeating: 0, count: 36)
                        for i in 0..<12 {
                            let j = (i + k) % 12
                            feat[j] = ch[i]
                            feat[12 + j] = ch[i] - prevCh[i]
                            feat[24 + j] = bass[i]
                        }
                        let y = (root + k) % 12 + (minor ? 12 : 0)
                        for _ in 0..<copies { mlp.append((feat, y)) }
                        if ready {
                            let rot = ring.map { f in (0..<12).map { f[($0 - k + 12) % 12] } }
                            for _ in 0..<copies { cnn.append((rot, y)) }
                        }
                    }
                    prevCh = ch
                }
            }
            // Keep the CNN window rolling through gaps so change windows stay contiguous.
            t += Double(n) / 44100
        }
    }

    // MARK: - Trainers

    static func trainLinear(samples: [([Float], Int)]) -> ([[Float]], [Float]) {
        var weight = ChordClassifier.templateWeights()
        var bias = [Float](repeating: 0, count: 24)
        let lr: Float = 0.05
        for _ in 0..<25 {
            for (x, y) in samples.shuffled() {
                var logits = [Float](repeating: 0, count: 24)
                var maxL: Float = -1e9
                for c in 0..<24 {
                    var s = bias[c]
                    for i in 0..<min(12, x.count) { s += weight[c][i] * x[i] }
                    logits[c] = s
                    maxL = max(maxL, s)
                }
                var sumE: Float = 0
                var exps = [Float](repeating: 0, count: 24)
                for c in 0..<24 { exps[c] = expf(logits[c] - maxL); sumE += exps[c] }
                for c in 0..<24 {
                    let g = exps[c] / sumE - (c == y ? 1 : 0)
                    bias[c] -= lr * g
                    for i in 0..<min(12, x.count) { weight[c][i] -= lr * g * x[i] }
                }
            }
        }
        return (weight, bias)
    }

    static func trainMLP(samples: [([Float], Int)]) -> ChordMLWeights.MLPWeights {
        let H = ChordMLP.hidden
        let I = ChordMLP.inputSize
        let C = 24
        // Xavier-ish init from templates
        var w1 = [Float](repeating: 0, count: H * I)
        var b1 = [Float](repeating: 0, count: H)
        var w2 = [Float](repeating: 0, count: C * H)
        var b2 = [Float](repeating: 0, count: C)
        let tw = ChordClassifier.templateWeights()
        for h in 0..<H {
            let chord = h % 24
            for pc in 0..<12 {
                w1[h * I + pc] = tw[chord][pc] * 0.2
                w1[h * I + 24 + pc] = tw[chord][pc] * 0.1
            }
        }
        for c in 0..<C {
            for h in 0..<H {
                w2[c * H + h] = (h % 24 == c) ? 0.3 : Float.random(in: -0.02...0.02)
            }
        }

        let lr: Float = 0.04
        var hAct = [Float](repeating: 0, count: H)
        var logits = [Float](repeating: 0, count: C)
        for epoch in 0..<35 {
            var correct = 0
            for (x, y) in samples.shuffled() {
                // forward
                for h in 0..<H {
                    var s = b1[h]
                    let row = h * I
                    for i in 0..<I { s += w1[row + i] * x[i] }
                    hAct[h] = max(0, s)
                }
                var maxL: Float = -1e9
                for c in 0..<C {
                    var s = b2[c]
                    let row = c * H
                    for h in 0..<H { s += w2[row + h] * hAct[h] }
                    logits[c] = s
                    maxL = max(maxL, s)
                }
                var exps = [Float](repeating: 0, count: C)
                var sumE: Float = 0
                for c in 0..<C { exps[c] = expf(logits[c] - maxL); sumE += exps[c] }
                var pred = 0
                for c in 0..<C { if exps[c] > exps[pred] { pred = c } }
                if y >= 0, pred == y { correct += 1 }

                var dLogits = [Float](repeating: 0, count: C)
                // y < 0 = no-chord → push toward uniform (low confidence), not a 25th class.
                for c in 0..<C {
                    dLogits[c] = exps[c] / sumE - (y < 0 ? 1 / Float(C) : (c == y ? 1 : 0))
                }
                var dH = [Float](repeating: 0, count: H)
                for c in 0..<C {
                    let row = c * H
                    for h in 0..<H { dH[h] += dLogits[c] * w2[row + h] }
                }
                for c in 0..<C {
                    let row = c * H
                    for h in 0..<H { w2[row + h] -= lr * dLogits[c] * hAct[h] }
                    b2[c] -= lr * dLogits[c]
                }
                for h in 0..<H {
                    if hAct[h] <= 0 { continue }
                    b1[h] -= lr * dH[h]
                    let row = h * I
                    for i in 0..<I { w1[row + i] -= lr * dH[h] * x[i] }
                }
            }
            if epoch % 10 == 0 || epoch == 34 {
                let n = max(1, samples.filter { $0.1 >= 0 }.count)
                print(String(format: "  mlp epoch %d acc %.1f%%", epoch, 100 * Float(correct) / Float(n)))
            }
        }
        return .init(w1: w1, b1: b1, w2: w2, b2: b2)
    }

    static func trainCNN(samples: [([[Float]], Int)]) -> ChordMLWeights.CNNWeights {
        let F = ChordCNN.filters
        let K = ChordCNN.kernel
        let B = ChordCNN.bins
        let T = ChordCNN.frames
        let outF = T - K + 1
        let flat = F * outF
        let C = 24

        var convW = [Float](repeating: 0, count: F * K * B)
        var convB = [Float](repeating: 0, count: F)
        var denseW = [Float](repeating: 0, count: C * flat)
        var denseB = [Float](repeating: 0, count: C)
        let tw = ChordClassifier.templateWeights()
        for f in 0..<F {
            let chord = f % 24
            for t in 0..<K {
                let w: Float = t == K - 1 ? 0.35 : 0.12
                let base = f * K * B + t * B
                for b in 0..<B {
                    convW[base + b] = tw[chord][b] * w
                }
            }
        }
        for c in 0..<C {
            denseW[c * flat + (c % F)] = 0.25
        }

        let lr: Float = 0.03
        var convOut = [Float](repeating: 0, count: flat)
        var logits = [Float](repeating: 0, count: C)

        for epoch in 0..<20 {
            var correct = 0
            for (seq, y) in samples.shuffled() {
                guard seq.count == T else { continue }
                // forward conv
                for of in 0..<outF {
                    for f in 0..<F {
                        var s = convB[f]
                        for t in 0..<K {
                            let row = f * K * B + t * B
                            let frame = seq[of + t]
                            for b in 0..<B { s += convW[row + b] * frame[b] }
                        }
                        convOut[of * F + f] = max(0, s)
                    }
                }
                var maxL: Float = -1e9
                for c in 0..<C {
                    var s = denseB[c]
                    let row = c * flat
                    for i in 0..<flat { s += denseW[row + i] * convOut[i] }
                    logits[c] = s
                    maxL = max(maxL, s)
                }
                var exps = [Float](repeating: 0, count: C)
                var sumE: Float = 0
                for c in 0..<C { exps[c] = expf(logits[c] - maxL); sumE += exps[c] }
                var pred = 0
                for c in 0..<C { if exps[c] > exps[pred] { pred = c } }
                if y >= 0, pred == y { correct += 1 }

                var dLogits = [Float](repeating: 0, count: C)
                for c in 0..<C {
                    dLogits[c] = exps[c] / sumE - (y < 0 ? 1 / Float(C) : (c == y ? 1 : 0))
                }
                var dConv = [Float](repeating: 0, count: flat)
                for c in 0..<C {
                    let row = c * flat
                    for i in 0..<flat { dConv[i] += dLogits[c] * denseW[row + i] }
                }
                for c in 0..<C {
                    let row = c * flat
                    for i in 0..<flat { denseW[row + i] -= lr * dLogits[c] * convOut[i] }
                    denseB[c] -= lr * dLogits[c]
                }
                for of in 0..<outF {
                    for f in 0..<F {
                        let idx = of * F + f
                        if convOut[idx] <= 0 { continue }
                        let g = dConv[idx]
                        convB[f] -= lr * g
                        for t in 0..<K {
                            let row = f * K * B + t * B
                            let frame = seq[of + t]
                            for b in 0..<B { convW[row + b] -= lr * g * frame[b] }
                        }
                    }
                }
            }
            if epoch % 5 == 0 || epoch == 19 {
                let n = max(1, samples.filter { $0.1 >= 0 }.count)
                print(String(format: "  cnn epoch %d acc %.1f%%", epoch, 100 * Float(correct) / Float(n)))
            }
        }
        return .init(convW: convW, convB: convB, denseW: denseW, denseB: denseB)
    }

    // MARK: - Emit

    static func emit(dest: String, legacyW: [[Float]], legacyB: [Float],
                     mlp: ChordMLWeights.MLPWeights, cnn: ChordMLWeights.CNNWeights) {
        func matrix(_ m: [[Float]]) -> String {
            m.map { row in
                let body = row.map { String(format: "%.6f", $0) }.joined(separator: ", ")
                return "                [\(body)]"
            }.joined(separator: ",\n")
        }
        func flat(_ v: [Float]) -> String {
            v.map { String(format: "%.6f", $0) }.joined(separator: ", ")
        }
        let out = """
        // Auto-generated by Tools/ChordProbe/train.swift — do not edit by hand.
        // Multi-timbre MLP + CNN (HMM transitions are code-defined in ChordML.swift).
        // Solitito Guitar uses ThirdParty/Solitito ONNX (MIT), not these weights.
        // Trained with 12-key rotation, chord-change windows, and no-chord (uniform) samples.
        enum ChordMLWeightsTrained {
            static func model(for timbre: ChordTimbre) -> ChordMLWeights.Model? {
                switch timbre {
                case .solititoGuitar: return nil
                case .mixed, .guitar, .keys, .voice: return model
                }
            }

            static var model: ChordMLWeights.Model? {
                ChordMLWeights.Model(
                    weights: [
        \(matrix(legacyW))
                    ],
                    bias: [\(flat(legacyB))],
                    mlp: ChordMLWeights.MLPWeights(
                        w1: [\(flat(mlp.w1))],
                        b1: [\(flat(mlp.b1))],
                        w2: [\(flat(mlp.w2))],
                        b2: [\(flat(mlp.b2))]
                    ),
                    cnn: ChordMLWeights.CNNWeights(
                        convW: [\(flat(cnn.convW))],
                        convB: [\(flat(cnn.convB))],
                        denseW: [\(flat(cnn.denseW))],
                        denseB: [\(flat(cnn.denseB))]
                    )
                )
            }
        }
        """
        try! out.write(to: URL(fileURLWithPath: dest), atomically: true, encoding: .utf8)
    }
}
