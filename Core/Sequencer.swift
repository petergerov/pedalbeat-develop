import Foundation

public enum PlayState: Int, Sendable {
    case stopped = 0, intro, main, fill, transition, outro, paused

    public var label: String {
        switch self {
        case .stopped: "STOPPED"
        case .intro: "INTRO"
        case .main: "PLAYING"
        case .fill: "FILL"
        case .transition: "TRANSITION"
        case .outro: "OUTRO"
        case .paused: "PAUSED"
        }
    }
}

/// Commands sent to the engine from the UI, MIDI or the host.
public enum PedalCommand: Int, Sendable {
    /// Main pedal press: start when stopped, fill while playing, resume when paused.
    case pedalTap = 1
    case start = 2
    case stop = 3
    case startStop = 4
    case fill = 5
    /// Transition fill, then move to the next part.
    case transition = 6
    case outro = 7
    case accent = 8
    case pauseResume = 9
    case nextSong = 10
    case prevSong = 11
    case cancelPending = 12
    /// 100 + n: transition into part n (0-based).
    case gotoPartBase = 100
}

struct OutEvent { var offset: Int32; var note: UInt8; var velocity: UInt8 }

/// Preview commands share the command queue: `previewBase + pattern * 2 + loop`.
enum PreviewCommand {
    static let stop = (1 << 20) - 1
    static let base = 1 << 20
}

/// Pedal-style song sequencer. Runs entirely on the audio thread.
final class Sequencer {
    let store: SongStore
    let synth: DrumSynth

    private(set) var state: PlayState = .stopped
    private var stateBeforePause: PlayState = .stopped
    private(set) var song = -1
    private var rec = SongRecord()
    private(set) var part = 0
    private var pattern: Int32 = -1
    private var pos: Double = 0
    private var mainResume: Double = 0

    private(set) var pendingFill = false
    private(set) var pendingTransition = false
    private(set) var pendingOutro = false
    private var pendingPart = -1

    var requestedSong = 0
    // Audition of a single pattern (song editor); only while the pedal player is stopped.
    private(set) var previewPattern: Int32 = -1
    private var previewLoop = false
    private var previewPos: Double = 0
    var isPreviewing: Bool { previewPattern >= 0 }
    var previewProgress: Double {
        guard previewPattern >= 0 else { return 0 }
        return previewPos / max(length(of: previewPattern), 1)
    }
    /// 0 = fills in order, 1 = random (never the same fill twice in a row).
    var fillOrder = 0
    private var nextFill = [Int](repeating: 0, count: SongStore.maxParts)   // preallocated
    private(set) var currentFill = 0       // 1-based number of the fill playing (0 = none)
    var swing: Double = 0
    var humanize: Double = 0
    var sampleRate: Double = 44100
    private var rng: UInt32 = 0xA5A5_1234

    // MIDI output capture for the current render buffer.
    let outEvents: UnsafeMutablePointer<OutEvent>
    let outCapacity = 1024
    private(set) var outCount = 0
    private var chunkOffset = 0

    init(store: SongStore, synth: DrumSynth) {
        self.store = store
        self.synth = synth
        outEvents = .allocate(capacity: outCapacity)
    }

    deinit { outEvents.deallocate() }

    // MARK: Status

    var partCount: Int { Int(rec.partCount) }
    var barTicks: Int { Int(rec.barTicks) }
    var beatTicks: Int { Int(rec.beatTicks) }
    var songTempo: Double { Double(rec.tempo) }
    var position: Double { pos }
    var barInPattern: Int { rec.barTicks > 0 ? Int(pos / Double(rec.barTicks)) : 0 }
    var beatInBar: Int {
        guard rec.barTicks > 0, rec.beatTicks > 0 else { return 0 }
        return Int(pos.truncatingRemainder(dividingBy: Double(rec.barTicks)) / Double(rec.beatTicks))
    }
    var barsInPattern: Int {
        guard pattern >= 0, rec.barTicks > 0 else { return 0 }
        return max(1, Int((Double(store.patterns[Int(pattern)].length) / Double(rec.barTicks)).rounded(.up)))
    }
    var hasSong: Bool { song >= 0 }

    func beginBuffer() { outCount = 0 }

    // MARK: Song helpers

    @discardableResult
    private func loadSong(_ index: Int) -> Bool {
        guard index >= 0 && index < store.count else { return false }
        song = index
        rec = store.songs[index]
        part = 0
        for i in 0..<SongStore.maxParts { nextFill[i] = 0 }
        return true
    }

    private func mainPattern(_ p: Int) -> Int32 {
        store.partMain[song * SongStore.maxParts + min(max(p, 0), max(partCount - 1, 0))]
    }

    /// The fill this part will play next (does not advance).
    private func fillPattern(_ p: Int) -> Int32 {
        let pp = min(max(p, 0), max(partCount - 1, 0))
        let n = store.fillCount(song: song, part: pp)
        guard n > 0 else { return -1 }
        return store.fill(song: song, part: pp, min(nextFill[pp], n - 1))
    }

    var fillCountInPart: Int { hasSong ? store.fillCount(song: song, part: min(max(part, 0), max(partCount - 1, 0))) : 0 }

    /// Call when the part's next fill actually starts: picks the one after it.
    private func consumeFill(_ p: Int) {
        let pp = min(max(p, 0), max(partCount - 1, 0))
        let n = store.fillCount(song: song, part: pp)
        guard n > 0 else { return }
        let played = min(nextFill[pp], n - 1)
        currentFill = played + 1
        if n == 1 { nextFill[pp] = 0; return }
        if fillOrder == 1 {
            rng = rng &* 1664525 &+ 1013904223
            var k = Int((rng >> 8) % UInt32(n))
            if k == played { k = (k + 1) % n }
            nextFill[pp] = k
        } else {
            nextFill[pp] = (played + 1) % n
        }
    }

    private func length(of pat: Int32) -> Double {
        pat >= 0 ? Double(store.patterns[Int(pat)].length) : 0
    }

    private func clearPending() {
        pendingFill = false; pendingTransition = false; pendingOutro = false; pendingPart = -1
    }

    // MARK: Commands

    func handle(_ raw: Int) {
        if raw == PreviewCommand.stop { previewPattern = -1; return }
        if raw >= PreviewCommand.base {
            let v = raw - PreviewCommand.base
            let pat = Int32(v / 2)
            guard Int(pat) < store.patternCountPublished else { return }
            stop()
            previewPattern = pat
            previewLoop = v % 2 == 1
            previewPos = 0
            return
        }
        previewPattern = -1   // any pedal action ends an audition
        if raw >= PedalCommand.gotoPartBase.rawValue {
            gotoPart(raw - PedalCommand.gotoPartBase.rawValue)
            return
        }
        guard let cmd = PedalCommand(rawValue: raw) else { return }
        switch cmd {
        case .pedalTap:
            switch state {
            case .stopped: start()
            case .paused: resume()
            case .main: requestFill(transition: false)
            case .intro, .fill, .transition, .outro: break
            }
        case .start: if state == .stopped { start() } else if state == .paused { resume() }
        case .stop: stop()
        case .startStop: if state == .stopped { start() } else { stop() }
        case .fill: if state == .main { requestFill(transition: false) }
        case .transition: requestTransition(to: -1)
        case .outro: requestOutro()
        case .accent: accentHit(offset: 0)
        case .pauseResume:
            if state == .paused { resume() } else if state != .stopped { stateBeforePause = state; state = .paused }
        case .nextSong: requestedSong = min(requestedSong + 1, max(store.count - 1, 0))
        case .prevSong: requestedSong = max(requestedSong - 1, 0)
        case .cancelPending: clearPending()
        case .gotoPartBase: break
        }
    }

    func start() {
        guard loadSong(requestedSong) else { return }
        clearPending()
        part = 0
        if rec.intro >= 0 {
            state = .intro
            pattern = rec.intro
        } else {
            state = .main
            pattern = mainPattern(0)
        }
        pos = 0
    }

    func stop() {
        state = .stopped
        clearPending()
        pos = 0
    }

    private func resume() {
        state = stateBeforePause == .paused || stateBeforePause == .stopped ? .main : stateBeforePause
    }

    func gotoPart(_ p: Int) {
        guard hasSong, p >= 0, p < partCount else { return }
        if state == .stopped {
            start()
            return
        }
        requestTransition(to: p)
    }

    private func requestFill(transition: Bool) {
        let fillPat = transition ? (rec.transition >= 0 ? rec.transition : fillPattern(part)) : fillPattern(part)
        let barT = Double(rec.barTicks)
        guard fillPat >= 0 else {
            // No fill available: a transition still changes part at the next bar line.
            if transition { pendingTransition = true }
            return
        }
        let inBar = pos.truncatingRemainder(dividingBy: barT)
        let barStart = pos - inBar
        let remaining = barT - inBar
        let fillLen = length(of: fillPat)
        // Like a hardware pedal: if more than a beat is left in the bar the fill
        // starts right away (at the same position inside the bar); otherwise it is
        // queued for the next downbeat.
        if remaining >= Double(rec.beatTicks) - 0.5 && inBar < fillLen {
            let mainLen = length(of: mainPattern(part))
            mainResume = (barStart + max(fillLen, barT)).truncatingRemainder(dividingBy: max(mainLen, 1))
            state = transition ? .transition : .fill
            if !transition || rec.transition < 0 { consumeFill(part) }
            pattern = fillPat
            pos = inBar
            if transition { pendingTransition = false } else { pendingFill = false }
        } else {
            if transition { pendingTransition = true } else { pendingFill = true }
        }
    }

    private func requestTransition(to target: Int) {
        guard hasSong else { return }
        pendingPart = target
        switch state {
        case .main:
            if partCount <= 1 && target < 0 {
                requestFill(transition: false)
            } else {
                requestFill(transition: true)
            }
        case .fill, .intro:
            pendingTransition = true
        default:
            break
        }
    }

    private func requestOutro() {
        switch state {
        case .main, .fill, .transition, .intro: pendingOutro = true
        case .paused: stop()
        default: break
        }
    }

    private func accentHit(offset: Int) {
        trigger(Drum.crash.rawValue, velocity: 1.0, offset: offset, humanized: false)
        trigger(Drum.kick.rawValue, velocity: 1.0, offset: offset, humanized: false)
    }

    // MARK: Event output

    private func trigger(_ drum: Int, velocity: Float, offset: Int, humanized: Bool = true) {
        var vel = velocity
        var off = offset
        if humanized && humanize > 0 {
            rng = rng &* 1664525 &+ 1013904223
            let r1 = Float(rng >> 8) / Float(1 << 24)
            rng = rng &* 1664525 &+ 1013904223
            let r2 = Float(rng >> 8) / Float(1 << 24)
            vel *= 1 + (r1 * 2 - 1) * 0.18 * Float(humanize)
            off += Int(Double(r2) * humanize * 0.010 * sampleRate)
        }
        vel = min(max(vel, 0.02), 1)
        synth.trigger(drum, velocity: vel, delay: off)
        if outCount < outCapacity, let d = Drum(rawValue: drum) {
            outEvents[outCount] = OutEvent(offset: Int32(chunkOffset + off), note: d.gmNote,
                                           velocity: UInt8(min(127, max(1, Int(vel * 127)))))
            outCount += 1
        }
    }

    /// Plays a hit from outside the sequence (MIDI input / pads).
    func playDrum(_ drum: Int, velocity: Float, offset: Int) {
        chunkOffset = 0
        trigger(drum, velocity: velocity, offset: offset, humanized: false)
    }

    private func advancePreview(frames: Int, tempo: Double) {
        let tps = max(tempo, 1) / 60.0 * Double(PPQN) / sampleRate
        let len = max(length(of: previewPattern), 1)
        var samplePos = 0.0
        var guardCount = 0
        while samplePos < Double(frames) && previewPattern >= 0 && guardCount < 16 {
            guardCount += 1
            let ticksAvail = (Double(frames) - samplePos) * tps
            let toEnd = len - previewPos
            if ticksAvail < toEnd {
                emit(from: previewPos, to: previewPos + ticksAvail, sampleBase: samplePos, tps: tps, pattern: previewPattern)
                previewPos += ticksAvail
                samplePos = Double(frames)
            } else {
                emit(from: previewPos, to: len, sampleBase: samplePos, tps: tps, pattern: previewPattern)
                samplePos += toEnd / tps
                previewPos = 0
                if !previewLoop { previewPattern = -1 }
            }
        }
    }

    private func emit(from: Double, to: Double, sampleBase: Double, tps: Double, pattern explicit: Int32? = nil) {
        let pattern = explicit ?? self.pattern
        guard pattern >= 0 else { return }
        let p = store.patterns[Int(pattern)]
        let start = Int(p.start)
        let end = start + Int(p.count)
        var i = start
        while i < end {
            let e = store.events[i]
            let eff = Double(e.tick) + swing * Double(e.swingUnit)
            if eff >= from && eff < to {
                let off = sampleBase + (eff - from) / tps
                trigger(Int(e.drum), velocity: Float(e.velocity) / 127, offset: Int(off))
            }
            i += 1
        }
    }

    // MARK: Transport

    /// Advances the song by `frames` samples, triggering synth voices.
    func advance(frames: Int, chunkOffset: Int, tempo: Double) {
        self.chunkOffset = chunkOffset
        if state == .stopped && previewPattern >= 0 {
            advancePreview(frames: frames, tempo: tempo)
            return
        }
        guard state != .stopped && state != .paused && pattern >= 0 else { return }
        let tps = max(tempo, 1) / 60.0 * Double(PPQN) / sampleRate
        let endSample = Double(frames)
        var samplePos = 0.0
        var iterations = 0
        while samplePos < endSample && state != .stopped && iterations < 64 {
            iterations += 1
            let len = length(of: pattern)
            var segEnd = len
            if state == .main {
                let barT = Double(rec.barTicks)
                segEnd = min(len, (floor(pos / barT + 1e-9) + 1) * barT)
            }
            let ticksAvail = (endSample - samplePos) * tps
            let toBoundary = max(segEnd - pos, 0)
            if ticksAvail < toBoundary {
                emit(from: pos, to: pos + ticksAvail, sampleBase: samplePos, tps: tps)
                pos += ticksAvail
                samplePos = endSample
            } else {
                emit(from: pos, to: segEnd, sampleBase: samplePos, tps: tps)
                samplePos += toBoundary / tps
                pos = segEnd
                boundary(offset: min(Int(samplePos), frames - 1))
            }
        }
    }

    /// Called whenever playback reaches a bar line (main) or the end of a pattern.
    private func boundary(offset: Int) {
        let atPatternEnd = pos >= length(of: pattern) - 1e-6
        switch state {
        case .intro:
            enterMain(part: 0, at: 0, crash: rec.introCrash, offset: offset)
            applyPendingAtBar(offset: offset)
        case .main:
            if atPatternEnd { pos = 0 }
            if requestedSong != song && requestedSong >= 0 && requestedSong < store.count {
                loadSong(requestedSong)
                clearPending()
                pattern = mainPattern(0)
                pos = 0
                accentHit(offset: offset)
                return
            }
            applyPendingAtBar(offset: offset)
        case .fill:
            enterMain(part: part, at: mainResume, crash: rec.fillCrash, offset: offset)
            applyPendingAtBar(offset: offset)
        case .transition:
            let next = pendingPart >= 0 ? pendingPart : (part + 1) % max(partCount, 1)
            pendingPart = -1
            pendingTransition = false
            enterMain(part: next, at: 0, crash: rec.fillCrash, offset: offset)
            applyPendingAtBar(offset: offset)
        case .outro:
            stop()
        case .stopped, .paused:
            break
        }
    }

    private func enterMain(part p: Int, at position: Double, crash: Bool, offset: Int) {
        part = min(max(p, 0), max(partCount - 1, 0))
        state = .main
        pattern = mainPattern(part)
        let len = length(of: pattern)
        pos = len > 0 ? position.truncatingRemainder(dividingBy: len) : 0
        if crash { trigger(Drum.crash.rawValue, velocity: 0.9, offset: offset, humanized: false) }
    }

    private func applyPendingAtBar(offset: Int) {
        guard state == .main else { return }
        if pendingOutro {
            clearPending()
            if rec.outro >= 0 {
                state = .outro
                pattern = rec.outro
                pos = 0
            } else {
                accentHit(offset: offset)
                stop()
            }
        } else if pendingTransition {
            pendingTransition = false
            let pat = rec.transition >= 0 ? rec.transition : fillPattern(part)
            if pat >= 0 {
                if rec.transition < 0 { consumeFill(part) }
                state = .transition
                pattern = pat
                pos = 0
            } else {
                let next = pendingPart >= 0 ? pendingPart : (part + 1) % max(partCount, 1)
                pendingPart = -1
                enterMain(part: next, at: 0, crash: true, offset: offset)
            }
        } else if pendingFill {
            pendingFill = false
            let pat = fillPattern(part)
            if pat >= 0 {
                consumeFill(part)
                let mainLen = length(of: mainPattern(part))
                mainResume = (pos + max(length(of: pat), Double(rec.barTicks)))
                    .truncatingRemainder(dividingBy: max(mainLen, 1))
                state = .fill
                pattern = pat
                pos = 0
            }
        }
    }
}
