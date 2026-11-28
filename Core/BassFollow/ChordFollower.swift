import Foundation
import Synchronization

/// A chord for bass follow: pitch-class root (0 = C … 11 = B) and major/minor.
public struct LiveChord: Equatable, Sendable {
    public var root: Int       // 0…11
    public var minor: Bool
    public var confidence: Float

    public init(root: Int, minor: Bool = false, confidence: Float = 1) {
        self.root = ((root % 12) + 12) % 12
        self.minor = minor
        self.confidence = confidence
    }

    public var name: String {
        let n = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
        return n[root] + (minor ? "m" : "")
    }
}

/// When the bass is allowed to adopt a new live chord (anti-flicker grid).
public enum ChordCommitGrid: Int, CaseIterable, Sendable {
    /// Every beat line (legacy / tight tracking).
    case everyBeat = 0
    /// Beats 1 and 3 in 4/4 (beat 1 only in 3/4). Default — kills mid-bar chatter.
    case strongBeats = 1
    /// Downbeat only.
    case bar = 2

    public var name: String {
        switch self {
        case .everyBeat: "Every Beat"
        case .strongBeats: "Strong Beats"
        case .bar: "Bar"
        }
    }
}

/// Shared harmony state for bass follow. MIDI and audio chord detect both set a pending
/// chord; the sequencer commits it on the harmonic grid so the bass does not jitter mid-bar.
final class ChordFollower: @unchecked Sendable {
    /// When false, transpose is 0 and MIDI chord notes are ignored for follow.
    var enabled = false
    /// Pitch class the written bass line is in (Bass & Drums demos = E = 4).
    var songRoot = 4
    /// Musical-time commit policy. Default: strong beats only.
    var commitGrid: ChordCommitGrid = .strongBeats
    /// Consecutive matching observations before audio may change `pending` (dual timescale).
    /// MIDI bypasses this and promotes immediately.
    var slowConfirmCount = 4

    private var noteCount = [UInt8](repeating: 0, count: 128)
    private var pcCount = [Int](repeating: 0, count: 12)
    private var pending: LiveChord?
    private var applied: LiveChord?
    /// Slow-path candidate waiting for confirmation before becoming pending.
    private var slowCandidate: LiveChord?
    private var slowCount = 0
    /// True once pending is trusted enough to commit on the next allowed beat.
    private var pendingReady = false
    /// UI / tests: last applied chord name code (root + (minor?12:0)), or -1.
    private let published = Atomic<Int>(-1)

    var appliedChord: LiveChord? { applied }
    var pendingChord: LiveChord? { pending }

    /// Semitones to add to written bass MIDI notes (0 when follow is off).
    /// Nearest direction (−5…+6) so E→D is −2, not +10.
    var transpose: Int {
        guard enabled, let c = applied else { return 0 }
        let up = (c.root - songRoot + 12) % 12
        return up > 6 ? up - 12 : up
    }

    var displayName: String {
        guard enabled, let c = applied ?? pending else { return "—" }
        return c.name
    }

    /// Snapshot for the UI (-1 = none).
    var publishedChordCode: Int { published.load(ordering: .relaxed) }

    func reset() {
        for i in 0..<128 { noteCount[i] = 0 }
        for i in 0..<12 { pcCount[i] = 0 }
        pending = nil
        applied = nil
        slowCandidate = nil
        slowCount = 0
        pendingReady = false
        published.store(-1, ordering: .relaxed)
    }

    /// Audio path: fast observations feed a slow accumulator; only the slow path updates
    /// `pending`, so brief detector flickers never reach the bass commit stage.
    func setLiveChord(_ chord: LiveChord) {
        // Refresh confidence while the pending chord is confirmed again.
        if let p = pending, p.root == chord.root, p.minor == chord.minor {
            pending = chord
            pendingReady = true
            slowCandidate = chord
            slowCount = max(slowCount, slowConfirmCount)
            return
        }

        let isFirst = pending == nil && applied == nil
        let threshold: Float = isFirst ? 0.35 : 0.55
        guard chord.confidence >= threshold else { return }

        if let s = slowCandidate, s.root == chord.root, s.minor == chord.minor {
            slowCount += 1
            slowCandidate = chord
        } else {
            slowCandidate = chord
            slowCount = 1
        }

        let need = isFirst ? 1 : max(1, slowConfirmCount)
        guard slowCount >= need else { return }

        pending = chord
        pendingReady = true
    }

    func noteOn(_ note: UInt8) {
        guard note < 128 else { return }
        if noteCount[Int(note)] == 0 { pcCount[Int(note) % 12] += 1 }
        noteCount[Int(note)] &+= 1
        recompute()
    }

    func noteOff(_ note: UInt8) {
        guard note < 128, noteCount[Int(note)] > 0 else { return }
        noteCount[Int(note)] &-= 1
        if noteCount[Int(note)] == 0 { pcCount[Int(note) % 12] -= 1 }
        recompute()
    }

    /// Call on each beat boundary while playing.
    /// - Parameters:
    ///   - beatInBar: 0-based beat index within the bar.
    ///   - beatsPerBar: usually 3 or 4 from `barTicks / beatTicks`.
    ///   - force: apply immediately (playback start / first lock), ignoring the grid.
    func applyQuantized(beatInBar: Int = 0, beatsPerBar: Int = 4, force: Bool = false) {
        guard enabled, let p = pending else { return }
        if applied == p {
            publish(p)
            return
        }
        if applied == nil || force {
            commit(p)
            return
        }
        guard pendingReady else { return }
        guard allowsCommit(beatInBar: beatInBar, beatsPerBar: max(1, beatsPerBar)) else { return }
        commit(p)
    }

    /// Whether this beat is an allowed harmonic change point for the current grid.
    func allowsCommit(beatInBar: Int, beatsPerBar: Int) -> Bool {
        let b = ((beatInBar % beatsPerBar) + beatsPerBar) % beatsPerBar
        switch commitGrid {
        case .everyBeat:
            return true
        case .strongBeats:
            if beatsPerBar <= 3 { return b == 0 }
            return b == 0 || b == beatsPerBar / 2
        case .bar:
            return b == 0
        }
    }

    private func commit(_ chord: LiveChord) {
        applied = chord
        pendingReady = true
        publish(chord)
    }

    private func publish(_ chord: LiveChord) {
        published.store(chord.root + (chord.minor ? 12 : 0), ordering: .relaxed)
    }

    private func recompute() {
        // MIDI is authoritative: promote immediately (no slow confirm).
        if let chord = Self.detect(pcCount: pcCount) {
            pending = chord
            pendingReady = true
            slowCandidate = chord
            slowCount = max(slowConfirmCount, 8)
        }
    }

    /// Major / minor template match, or the single sounding pitch class as root.
    static func detect(pcCount: [Int]) -> LiveChord? {
        let active = pcCount.indices.filter { pcCount[$0] > 0 }
        guard !active.isEmpty else { return nil }
        if active.count == 1 {
            return LiveChord(root: active[0], minor: false, confidence: 0.55)
        }
        var best: LiveChord?
        var bestScore = 0
        for root in 0..<12 {
            let maj = score(pcCount, root: root, intervals: [0, 4, 7])
            let min = score(pcCount, root: root, intervals: [0, 3, 7])
            if maj > bestScore { bestScore = maj; best = LiveChord(root: root, minor: false, confidence: Float(maj) / 3) }
            if min > bestScore { bestScore = min; best = LiveChord(root: root, minor: true, confidence: Float(min) / 3) }
        }
        guard let best, bestScore >= 2 else {
            // Fall back to lowest sounding pitch class (guitar often voices root low).
            let low = active.min()!
            return LiveChord(root: low, minor: false, confidence: 0.4)
        }
        return best
    }

    private static func score(_ pc: [Int], root: Int, intervals: [Int]) -> Int {
        intervals.reduce(0) { $0 + (pc[(root + $1) % 12] > 0 ? 1 : 0) }
    }

    static func transpose(_ note: UInt8, by semitones: Int) -> UInt8 {
        var n = Int(note) + semitones
        // Keep written bass lines in a playable register when nearest goes below E1.
        if semitones < 0, Int(note) >= 28, n < 28 { n += 12 }
        return UInt8(max(0, min(127, n)))
    }
}
