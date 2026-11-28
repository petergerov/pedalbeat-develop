import Foundation
import Accelerate

// MARK: - MLP (36 → 64 → 24)

/// Chroma + Δchroma + bass-PC → 24 maj/min logits. Realtime-safe after init.
final class ChordMLP: @unchecked Sendable {
    static let inputSize = 36
    static let hidden = 64
    static let classes = 24

    /// W1[hidden][input], b1[hidden], W2[classes][hidden], b2[classes]
    private var w1: [Float]
    private var b1: [Float]
    private var w2: [Float]
    private var b2: [Float]
    private var hiddenAct: [Float]
    private var logits: [Float]

    init() {
        w1 = [Float](repeating: 0, count: Self.hidden * Self.inputSize)
        b1 = [Float](repeating: 0, count: Self.hidden)
        w2 = [Float](repeating: 0, count: Self.classes * Self.hidden)
        b2 = [Float](repeating: 0, count: Self.classes)
        hiddenAct = [Float](repeating: 0, count: Self.hidden)
        logits = [Float](repeating: 0, count: Self.classes)
        seedFromTemplates()
    }

    func load(w1: [Float], b1: [Float], w2: [Float], b2: [Float]) {
        guard w1.count == Self.hidden * Self.inputSize, b1.count == Self.hidden,
              w2.count == Self.classes * Self.hidden, b2.count == Self.classes else { return }
        self.w1 = w1; self.b1 = b1; self.w2 = w2; self.b2 = b2
    }

    func export() -> (w1: [Float], b1: [Float], w2: [Float], b2: [Float]) {
        (w1, b1, w2, b2)
    }

    /// Fills `out[24]` with logits (not softmax).
    func forward(input: [Float], out: inout [Float]) {
        precondition(input.count == Self.inputSize)
        // h = ReLU(W1 x + b1)
        for h in 0..<Self.hidden {
            var s = b1[h]
            let row = h * Self.inputSize
            for i in 0..<Self.inputSize { s += w1[row + i] * input[i] }
            hiddenAct[h] = max(0, s)
        }
        for c in 0..<Self.classes {
            var s = b2[c]
            let row = c * Self.hidden
            for h in 0..<Self.hidden { s += w2[row + h] * hiddenAct[h] }
            out[c] = s
            logits[c] = s
        }
    }

    private func seedFromTemplates() {
        // First layer: copy chroma / bass slices toward triad detectors; delta starts near 0.
        let tw = ChordClassifier.templateWeights()
        for c in 0..<24 {
            for pc in 0..<12 {
                let t = tw[c][pc]
                // chroma
                w1[(c % Self.hidden) * Self.inputSize + pc] += t * 0.15
                // bass
                w1[((c + 12) % Self.hidden) * Self.inputSize + 24 + pc] += t * 0.1
            }
            b2[c] = 0
            for h in 0..<Self.hidden {
                w2[c * Self.hidden + h] = (h % 24 == c) ? 0.4 : 0.01
            }
        }
    }
}

// MARK: - Tiny CNN over chroma timeline (T=8, C=12)

/// Causal-ish 1D conv over recent chroma frames → 24 logits.
final class ChordCNN: @unchecked Sendable {
    static let frames = 8
    static let bins = 12
    static let filters = 16
    static let kernel = 3
    static let classes = 24

    /// Ring of frames * bins (row-major frame-major).
    private var ring: [Float]
    private var ringWrite = 0
    private var ringCount = 0

    /// convW[filters][kernel*bins], convB[filters]
    private var convW: [Float]
    private var convB: [Float]
    /// denseW[classes][filters * outFrames], denseB[classes]
    private var denseW: [Float]
    private var denseB: [Float]
    private var convOut: [Float]
    private let outFrames: Int

    init() {
        outFrames = Self.frames - Self.kernel + 1
        ring = [Float](repeating: 0, count: Self.frames * Self.bins)
        convW = [Float](repeating: 0, count: Self.filters * Self.kernel * Self.bins)
        convB = [Float](repeating: 0, count: Self.filters)
        denseW = [Float](repeating: 0, count: Self.classes * Self.filters * outFrames)
        denseB = [Float](repeating: 0, count: Self.classes)
        convOut = [Float](repeating: 0, count: Self.filters * outFrames)
        seed()
    }

    func reset() {
        ringWrite = 0
        ringCount = 0
        for i in ring.indices { ring[i] = 0 }
    }

    func load(convW: [Float], convB: [Float], denseW: [Float], denseB: [Float]) {
        guard convW.count == self.convW.count, convB.count == self.convB.count,
              denseW.count == self.denseW.count, denseB.count == self.denseB.count else { return }
        self.convW = convW; self.convB = convB; self.denseW = denseW; self.denseB = denseB
    }

    func export() -> (convW: [Float], convB: [Float], denseW: [Float], denseB: [Float]) {
        (convW, convB, denseW, denseB)
    }

    func push(_ chroma: [Float]) {
        let base = ringWrite * Self.bins
        for i in 0..<Self.bins { ring[base + i] = chroma[i] }
        ringWrite = (ringWrite + 1) % Self.frames
        ringCount = min(ringCount + 1, Self.frames)
    }

    func forward(out: inout [Float]) {
        guard ringCount >= Self.kernel else {
            for i in 0..<Self.classes { out[i] = 0 }
            return
        }
        // Oldest frame index in chronological order.
        let start = (ringWrite - ringCount + Self.frames) % Self.frames
        for f in 0..<outFrames {
            for k in 0..<Self.filters {
                var s = convB[k]
                for t in 0..<Self.kernel {
                    let fr = (start + f + t) % Self.frames
                    let row = k * (Self.kernel * Self.bins) + t * Self.bins
                    let base = fr * Self.bins
                    for b in 0..<Self.bins { s += convW[row + b] * ring[base + b] }
                }
                convOut[f * Self.filters + k] = max(0, s)
            }
        }
        let flat = Self.filters * outFrames
        for c in 0..<Self.classes {
            var s = denseB[c]
            let row = c * flat
            for i in 0..<flat { s += denseW[row + i] * convOut[i] }
            out[c] = s
        }
    }

    private func seed() {
        // Filters look for local triad energy rising over 3 frames.
        let tw = ChordClassifier.templateWeights()
        for k in 0..<Self.filters {
            let chord = k % 24
            for t in 0..<Self.kernel {
                let w: Float = t == Self.kernel - 1 ? 0.4 : 0.15
                let base = k * Self.kernel * Self.bins + t * Self.bins
                for b in 0..<Self.bins {
                    convW[base + b] = tw[chord][b] * w
                }
            }
        }
        for c in 0..<Self.classes {
            denseW[c * Self.filters * outFrames + (c % Self.filters)] = 0.3
        }
    }
}

// MARK: - Online HMM (forward-Viterbi filter)

final class ChordHMM: @unchecked Sendable {
    static let classes = 24
    private var logTrans: [Float] // [from * 24 + to]
    private var delta: [Float]
    private var prevDelta: [Float]
    private var started = false

    init() {
        logTrans = [Float](repeating: -3, count: Self.classes * Self.classes)
        delta = [Float](repeating: -1e9, count: Self.classes)
        prevDelta = [Float](repeating: -1e9, count: Self.classes)
        buildTransitions()
    }

    func reset() {
        started = false
        for i in 0..<Self.classes { delta[i] = -1e9; prevDelta[i] = -1e9 }
    }

    /// `emissionLog` = log probabilities (or scaled logits). Returns best class index.
    @discardableResult
    func step(emissionLog: [Float]) -> Int {
        if !started {
            for c in 0..<Self.classes { delta[c] = emissionLog[c] }
            started = true
            return argmax(delta)
        }
        swap(&delta, &prevDelta)
        for j in 0..<Self.classes {
            var best = -Float.greatestFiniteMagnitude
            for i in 0..<Self.classes {
                best = max(best, prevDelta[i] + logTrans[i * Self.classes + j])
            }
            delta[j] = best + emissionLog[j]
        }
        return argmax(delta)
    }

    func scores(into out: inout [Float]) {
        // Convert delta to positive relative scores.
        let m = delta.max() ?? 0
        for i in 0..<Self.classes { out[i] = delta[i] - m }
    }

    private func buildTransitions() {
        // Style-neutral: stay, fifths, relative maj/min, diatonic steps; chromatic weak.
        for i in 0..<Self.classes {
            let ir = i % 12
            let im = i >= 12
            for j in 0..<Self.classes {
                let jr = j % 12
                let jm = j >= 12
                let d = min((jr - ir + 12) % 12, (ir - jr + 12) % 12)
                var p: Float
                // Strong self-transition: ~0.92 after row normalize at 23 ms hops
                // (expected dwell ~280 ms) so frame noise cannot flip every hop.
                if i == j {
                    p = 12.0
                } else if d == 5 {
                    p = 0.12
                } else if d == 2 || d == 3 || d == 4 {
                    p = 0.06
                } else if ir == jr && im != jm {
                    p = 0.04 // quality flip
                } else if (!im && jm && jr == (ir + 9) % 12) || (im && !jm && jr == (ir + 3) % 12) {
                    p = 0.08 // relative
                } else if d == 1 {
                    p = 0.01
                } else {
                    p = 0.015
                }
                logTrans[i * Self.classes + j] = logf(max(p, 1e-6))
            }
            // Renormalize row in log domain roughly
            var sum: Float = 0
            for j in 0..<Self.classes { sum += expf(logTrans[i * Self.classes + j]) }
            let lsum = logf(sum)
            for j in 0..<Self.classes { logTrans[i * Self.classes + j] -= lsum }
        }
    }

    private func argmax(_ v: [Float]) -> Int {
        var bi = 0
        var bv = v[0]
        for i in 1..<v.count where v[i] > bv { bv = v[i]; bi = i }
        return bi
    }
}

// MARK: - Ensemble

final class ChordEnsemble: @unchecked Sendable {
    let mlp = ChordMLP()
    let cnn = ChordCNN()
    let hmm = ChordHMM()
    let templates = ChordClassifier()

    private var prevChroma = [Float](repeating: 0, count: 12)
    private var mlpOut = [Float](repeating: 0, count: 24)
    private var cnnOut = [Float](repeating: 0, count: 24)
    private var blend = [Float](repeating: 0, count: 24)
    private var emis = [Float](repeating: 0, count: 24)
    private var hmmScores = [Float](repeating: 0, count: 24)

    /// MLP / CNN / template blend weights.
    var wMLP: Float = 0.45
    var wCNN: Float = 0.35
    var wTpl: Float = 0.20

    func reset() {
        cnn.reset()
        hmm.reset()
        for i in 0..<12 { prevChroma[i] = 0 }
    }

    func loadTrained(_ m: ChordMLWeights.Model) {
        if let mlp = m.mlp {
            self.mlp.load(w1: mlp.w1, b1: mlp.b1, w2: mlp.w2, b2: mlp.b2)
            wMLP = 0.50; wCNN = 0.35; wTpl = 0.15
        }
        if let cnn = m.cnn {
            self.cnn.load(convW: cnn.convW, convB: cnn.convB, denseW: cnn.denseW, denseB: cnn.denseB)
        }
    }

    /// Template-only (tests / no trained weights).
    func useTemplatesOnly() {
        wMLP = 0; wCNN = 0; wTpl = 1
        cnn.reset()
        hmm.reset()
    }

    /// Returns ranked scores after HMM smoothing.
    func rank(chroma: [Float], bass: [Float]) -> [ChordScore] {
        var feat = [Float](repeating: 0, count: ChordMLP.inputSize)
        for i in 0..<12 {
            feat[i] = chroma[i]
            feat[12 + i] = chroma[i] - prevChroma[i]
            feat[24 + i] = bass[i]
            prevChroma[i] = chroma[i]
        }
        mlp.forward(input: feat, out: &mlpOut)
        cnn.push(chroma)
        cnn.forward(out: &cnnOut)
        let tpl = templates.rank(chroma)

        for c in 0..<24 {
            let t = tpl.first(where: { $0.chord.root + ($0.chord.minor ? 12 : 0) == c })?.score ?? 0
            blend[c] = wMLP * mlpOut[c] + wCNN * cnnOut[c] + wTpl * t
        }
        // Softmax → log for HMM
        let maxB = blend.max() ?? 0
        var sum: Float = 0
        for c in 0..<24 {
            emis[c] = expf(blend[c] - maxB)
            sum += emis[c]
        }
        for c in 0..<24 { emis[c] = logf(max(emis[c] / sum, 1e-8)) }

        _ = hmm.step(emissionLog: emis)
        hmm.scores(into: &hmmScores)

        var ranked = [ChordScore]()
        ranked.reserveCapacity(24)
        for c in 0..<24 {
            ranked.append(ChordScore(
                chord: LiveChord(root: c % 12, minor: c >= 12, confidence: 0),
                score: hmmScores[c] + 5 // shift positive
            ))
        }
        ranked.sort { $0.score > $1.score }
        // Confidence from top-2 gap
        if ranked.count >= 2 {
            let gap = ranked[0].score - ranked[1].score
            ranked[0].chord.confidence = min(1, max(0.2, gap / 3))
        }
        return ranked
    }

    func score(chroma: [Float], chord: LiveChord) -> Float {
        let c = chord.root + (chord.minor ? 12 : 0)
        return max(0.1, hmmScores[c] + 5)
    }
}

