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

/// A bass note-off still to send (MIDI out), `samples` after the start of the current chunk.
private struct PendingOff { var note: UInt8; var samples: Int }

/// Preview commands share the command queue: `previewBase + pattern * 2 + loop`, plus
/// `(bass pattern + 1) * bassUnit` when a bass line plays along.
enum PreviewCommand {
    static let stop = (1 << 20) - 1
    static let base = 1 << 20
    static let bassUnit = 1 << 24
}

/// Pedal-style song sequencer. Runs entirely on the audio thread.
final class Sequencer {
    let store: SongStore
    let synth: DrumSynth
    let bass: BassSynth
    let bassFollow: BassFollow

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

    // Bass track: the section's bass line loops on its own length, `bassPos` ticks into it.
    // During a fill it stays on the part's main bass line.
    private var bassPattern: Int32 = -1
    private var bassPos: Double = 0
    /// The fill playing has a bass line of its own (the groove's bass resumes where the drums do).
    private var bassInFill = false
    /// Master switch from the UI / AU parameter. Off = no bass for any song or audition.
    private var globalBassEnabled = true
    // Bass MIDI out for the current buffer (velocity 0 = note off) and the note-offs still to come.
    let bassOutEvents: UnsafeMutablePointer<OutEvent>
    let bassOutCapacity = 256
    private(set) var bassOutCount = 0
    private let bassOffs: UnsafeMutablePointer<PendingOff>
    private let bassOffCapacity = 64
    private var bassOffCount = 0
    /// Note-offs from pause/stop between buffers. `beginBuffer` copies them in after clearing
    /// so a pedal command before `beginRender` does not lose MIDI offs to the wipe.
    private let deferredBassOffs: UnsafeMutablePointer<OutEvent>
    private var deferredBassOffCount = 0
    private var inBuffer = false

    // Percussion layers (shaker, tambourine, clap): like the bass, each loops its section's pattern
    // on its own length, `percPos` ticks in. Fixed-size, so the audio thread never allocates.
    private var percPattern = [Int32](repeating: -1, count: PercussionInstrument.count)
    private var percPos = [Double](repeating: 0, count: PercussionInstrument.count)
    /// The layer is playing its own fill (back to its groove when the drum fill ends).
    private var percInFill = [Bool](repeating: false, count: PercussionInstrument.count)
    /// Master switch and per-instrument switches from the UI / AU parameters.
    private var globalPercEnabled = true
    private var percInstrumentOn = [Bool](repeating: true, count: PercussionInstrument.count)
    /// Auto Percussion: a song without layers of its own plays its generated ones.
    private var autoPercEnabled = false
    /// Level of the layers: scales their hits, not the drums'.
    var percGain: Float = 1
    /// Shaker stack timing (`ShakerStack`): the layer shaker earlier (< 0) or later in ms, and its feel.
    var shakerPocketMs: Double = 0
    var shakerFeel = ShakerFeel.grid
    /// Layer `k` is in the first pass of its pattern (no hit before its start to carry over).
    private var percFresh = [Bool](repeating: false, count: PercussionInstrument.count)
    /// Layer `k`'s pattern has 16ths (back strokes between the 8ths).
    private var percDense = [Bool](repeating: false, count: PercussionInstrument.count)

    init(store: SongStore, synth: DrumSynth, bass: BassSynth, bassFollow: BassFollow) {
        self.store = store
        self.synth = synth
        self.bass = bass
        self.bassFollow = bassFollow
        outEvents = .allocate(capacity: outCapacity)
        bassOutEvents = .allocate(capacity: bassOutCapacity)
        bassOffs = .allocate(capacity: bassOffCapacity)
        deferredBassOffs = .allocate(capacity: bassOffCapacity)
    }

    deinit {
        outEvents.deallocate(); bassOutEvents.deallocate(); bassOffs.deallocate(); deferredBassOffs.deallocate()
    }

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
    var isPlayingBass: Bool { bassPattern >= 0 }

    func beginBuffer() {
        outCount = 0
        bassOutCount = 0
        chunkOffset = 0
        for i in 0..<deferredBassOffCount {
            bassOutEvents[bassOutCount] = deferredBassOffs[i]
            bassOutCount += 1
        }
        deferredBassOffCount = 0
    }

    // MARK: Song helpers

    @discardableResult
    private func loadSong(_ index: Int) -> Bool {
        guard index >= 0 && index < store.count else { return false }
        song = index
        rec = store.songs[index]
        part = 0
        for i in 0..<SongStore.maxParts { nextFill[i] = 0 }
        bassFollow.setSongRoot(Int(rec.bassRoot))
        bassFollow.setSongChords(store.chordProfile(song: index))
        return true
    }

    private func mainPattern(_ p: Int) -> Int32 {
        store.partMain[song * SongStore.maxParts + min(max(p, 0), max(partCount - 1, 0))]
    }

    private func partBass(_ p: Int) -> Int32 {
        store.bass(song: song, part: min(max(p, 0), max(partCount - 1, 0)))
    }

    /// Starts a bass line `position` ticks in (wrapped to its length); -1 = no bass.
    private func setBass(_ pat: Int32, at position: Double) {
        bassPattern = (globalBassEnabled && rec.bassEnabled && pat >= 0) ? pat : -1
        let len = bassPattern >= 0 ? Double(store.bassPatterns[Int(bassPattern)].length) : 0
        bassPos = len > 0 ? position.truncatingRemainder(dividingBy: len) : 0
    }

    /// The fill that just started (`currentFill`) plays its own bass line if it has one; otherwise
    /// the groove's keeps going under it.
    private func startFillBass(at position: Double) {
        let idx = store.fillBass(song: song, part: min(max(part, 0), max(partCount - 1, 0)), currentFill - 1)
        guard globalBassEnabled, rec.bassEnabled, idx >= 0, Int(idx) < store.bassPatternCountPublished else { bassInFill = false; return }
        bassInFill = true
        setBass(idx, at: position)
    }

    /// A transition or the ending plays its own bass line if it has one; otherwise the part's keeps going.
    private func sectionBass(_ pat: Int32) { if pat >= 0 { setBass(pat, at: pos) } }

    /// UI / AU master bass switch. Turning off stops the current line; turning on restores it for the section.
    func setGlobalBassEnabled(_ on: Bool) {
        globalBassEnabled = on
        if !on {
            bassPattern = -1
            releaseBass()
            return
        }
        guard song >= 0, state != .stopped else { return }
        switch state {
        case .intro: setBass(rec.introBass, at: pos)
        case .main, .paused: setBass(partBass(part), at: pos)
        case .fill:
            let idx = bassInFill ? store.fillBass(song: song, part: min(max(part, 0), max(partCount - 1, 0)), currentFill - 1) : -1
            setBass(idx >= 0 ? idx : partBass(part), at: pos)
        case .transition: setBass(rec.transitionBass >= 0 ? rec.transitionBass : partBass(part), at: pos)
        case .outro: setBass(rec.outroBass >= 0 ? rec.outroBass : partBass(part), at: pos)
        case .stopped: break
        }
    }

    // MARK: Percussion layers

    /// The current song's layer for instrument `k`, if percussion and the instrument are switched on.
    private func percTrack(_ k: Int) -> Int32 {
        guard globalPercEnabled, percInstrumentOn[k], song >= 0 else { return -1 }
        let published = Int32(store.percussionCountPublished)
        let own = store.percussion(song: song, instrument: k)
        if own >= 0 { return own < published ? own : -1 }
        guard autoPercEnabled, !songHasOwnPercussion() else { return -1 }
        let t = store.autoPercussion(song: song, instrument: k)
        return t < published ? t : -1
    }

    /// Any own layer at all: a song with a shaker of its own does not get a generated clap.
    private func songHasOwnPercussion() -> Bool {
        for k in 0..<PercussionInstrument.count where store.percussion(song: song, instrument: k) >= 0 { return true }
        return false
    }

    private func startPerc(_ k: Int, _ pat: Int32, at position: Double, fill: Bool = false) {
        percPattern[k] = pat
        percInFill[k] = pat >= 0 && fill
        percFresh[k] = true
        percDense[k] = false
        if pat >= 0 {
            let p = store.patterns[Int(pat)]
            for i in Int(p.start)..<Int(p.start + p.count) where Int(store.events[i].tick) % (PPQN / 2) != 0 {
                percDense[k] = true
                break
            }
        }
        let len = length(of: pat)
        percPos[k] = len > 0 ? position.truncatingRemainder(dividingBy: len) : 0
    }

    /// Points layer `k` at its pattern for the section now playing, `position` ticks into it.
    /// A fill or transition without one of its own keeps the layer's groove going; an intro or
    /// ending without one is silent.
    private func setPercLayer(_ k: Int, at position: Double) {
        let t = percTrack(k)
        guard t >= 0 else { percPattern[k] = -1; percInFill[k] = false; return }
        switch state {
        case .intro: startPerc(k, store.percIntro(t), at: position)
        case .main, .paused: startPerc(k, store.percMain(t, part: part), at: position)
        case .fill:
            let f = store.percFill(t, part: part, currentFill - 1)
            if f >= 0 { startPerc(k, f, at: position, fill: true) }
            else if percPattern[k] < 0 || percInFill[k] { startPerc(k, store.percMain(t, part: part), at: position) }
        case .transition:
            let tr = store.percTransition(t)
            if tr >= 0 { startPerc(k, tr, at: position) }
            else if percPattern[k] < 0 || percInFill[k] { startPerc(k, store.percMain(t, part: part), at: position) }
        case .outro: startPerc(k, store.percOutro(t), at: position)
        case .stopped: percPattern[k] = -1; percInFill[k] = false
        }
    }

    /// Every layer follows a section change.
    private func setPercussion(at position: Double) {
        for k in 0..<PercussionInstrument.count { setPercLayer(k, at: position) }
    }

    private func stopPercussion() {
        for k in 0..<PercussionInstrument.count { percPattern[k] = -1; percInFill[k] = false }
    }

    /// After a drum fill: a layer that played its own fill goes back to its groove where the drums
    /// resume; one that kept its groove going skips what the drums skip (a fill shorter than a bar).
    private func resumePercussionAfterFill(skip: Double) {
        for k in 0..<PercussionInstrument.count where percPattern[k] >= 0 {
            if percInFill[k] {
                setPercLayer(k, at: pos)
            } else if skip > 0 {
                let len = length(of: percPattern[k])
                if len > 0 { percPos[k] = (percPos[k] + skip).truncatingRemainder(dividingBy: len) }
            }
        }
    }

    /// Switches turned on mid-song start their layer in time; switched off, it stops at once.
    private func refreshPercussion() {
        for k in 0..<PercussionInstrument.count {
            if percTrack(k) < 0 { percPattern[k] = -1; percInFill[k] = false }
            else if percPattern[k] < 0 && state != .stopped && song >= 0 { setPercLayer(k, at: pos) }
        }
    }

    /// UI / AU master percussion switch. Off = no percussion audio or MIDI for any song.
    func setGlobalPercussionEnabled(_ on: Bool) {
        globalPercEnabled = on
        refreshPercussion()
    }

    /// UI / AU Auto Percussion switch: generated layers for songs without their own.
    func setAutoPercussionEnabled(_ on: Bool) {
        autoPercEnabled = on
        refreshPercussion()
    }

    /// UI / AU switch of one instrument (`PercussionInstrument` raw value).
    func setPercussion(instrument k: Int, on: Bool) {
        guard k >= 0, k < PercussionInstrument.count else { return }
        percInstrumentOn[k] = on
        refreshPercussion()
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
        if raw == PreviewCommand.stop { endPreview(); return }
        if raw >= PreviewCommand.base {
            let v = raw - PreviewCommand.base
            let rest = v % PreviewCommand.bassUnit
            let pat = Int32(rest / 2)
            let bassPat = Int32(v / PreviewCommand.bassUnit) - 1
            guard Int(pat) < store.patternCountPublished else { return }
            stop()
            previewPattern = pat
            previewLoop = rest % 2 == 1
            previewPos = 0
            if globalBassEnabled && bassPat >= 0 && Int(bassPat) < store.bassPatternCountPublished { bassPattern = bassPat; bassPos = 0 }
            return
        }
        endPreview()   // any pedal action ends an audition
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
            if state == .paused { resume() } else if state != .stopped { stateBeforePause = state; state = .paused; releaseBass() }
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
            setBass(rec.introBass, at: 0)
        } else {
            state = .main
            pattern = mainPattern(0)
            setBass(partBass(0), at: 0)
        }
        pos = 0
        setPercussion(at: 0)
        // Apply any chord already held so the first bass notes land in key.
        bassFollow.applyOnBeat(force: true)
    }

    func stop() {
        finish()
        releaseBass()
    }

    /// The song ran out (end of the outro): stop, letting the last bass notes ring for their length.
    private func finish() {
        state = .stopped
        clearPending()
        pos = 0
        bassPattern = -1
        bassInFill = false
        stopPercussion()
    }

    private func endPreview() {
        guard previewPattern >= 0 else { return }
        previewPattern = -1
        bassPattern = -1
        releaseBass()
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
            if transition { pendingTransition = false; sectionBass(rec.transitionBass) } else { pendingFill = false; startFillBass(at: inBar) }
            setPercussion(at: inBar)
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

    /// `gain` scales the sound only (percussion level); MIDI out keeps the written velocity.
    private func trigger(_ drum: Int, velocity: Float, offset: Int, humanized: Bool = true,
                         gain: Float = 1, layer: Bool = false, back: Bool = false) {
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
        synth.trigger(drum, velocity: vel, delay: off, gain: gain, layer: layer, back: back)
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
                emitBass(ticks: ticksAvail, sampleBase: samplePos, tps: tps)
                previewPos += ticksAvail
                samplePos = Double(frames)
            } else {
                emit(from: previewPos, to: len, sampleBase: samplePos, tps: tps, pattern: previewPattern)
                emitBass(ticks: toEnd, sampleBase: samplePos, tps: tps, snap: true)
                samplePos += toEnd / tps
                previewPos = 0
                if !previewLoop { previewPattern = -1; bassPattern = -1 }
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

    /// Plays the next `ticks` of the bass line, looping it on its own length. With `snap` (a bar
    /// line or pattern end) it lands on a whole tick like the drums' `pos = segEnd`, and notes play
    /// a nanotick late, so a note on the line plays after the section change, never before it
    /// (`bassPos` and `pos` add up separately and can differ by rounding).
    private func emitBass(ticks: Double, sampleBase: Double, tps: Double, snap: Bool = false) {
        guard bassPattern >= 0 else { return }
        let p = store.bassPatterns[Int(bassPattern)]
        let len = Double(p.length)
        guard len > 0 else { return }
        let start = Int(p.start), end = start + Int(p.count)
        var target = snap ? (bassPos + ticks).rounded() : bassPos + ticks   // end of this stretch, not wrapped
        var base = sampleBase
        while target - bassPos > 1e-9 {
            let from = bassPos, to = min(target, len)
            var i = start
            while i < end {
                let e = store.bassEvents[i]
                let t = Double(e.tick) + 1e-6
                if t >= from && t < to { playBass(e, offset: Int(base + (t - from) / tps), tps: tps) }
                i += 1
            }
            base += (to - from) / tps
            if to >= len - 1e-6 { target -= len; bassPos = 0 } else if to > from { bassPos = to } else { break }
        }
        if snap { bassPos = bassPos.rounded(); if bassPos >= len { bassPos = 0 } }
    }

    /// Plays the next `ticks` of every percussion layer, each looping on its own length (see `emitBass`).
    /// The shaker plays at its pocket and feel, which can move a hit across the loop point: one moved
    /// before its pattern's start plays at the end of the pass before (and on the first pass at its
    /// start), one moved past the end plays at the start of the next pass.
    private func emitPercussion(ticks: Double, sampleBase: Double, tps: Double, snap: Bool = false) {
        let shakerK = PercussionInstrument.shaker.rawValue
        for k in 0..<PercussionInstrument.count where percPattern[k] >= 0 {
            let p = store.patterns[Int(percPattern[k])]
            let len = Double(p.length)
            guard len > 0 else { continue }
            let start = Int(p.start), end = start + Int(p.count)
            let shaker = k == shakerK
            let pocket = shaker ? shakerPocketMs / 1000 * sampleRate * tps : 0
            var at = percPos[k]
            var target = snap ? (at + ticks).rounded() : at + ticks   // end of this stretch, not wrapped
            var base = sampleBase
            while target - at > 1e-9 {
                let from = at, to = min(target, len)
                var i = start
                while i < end {
                    let e = store.events[i]
                    let t = Double(e.tick) + swing * Double(e.swingUnit) + 1e-6
                    if !shaker {
                        if t >= from && t < to {
                            trigger(Int(e.drum), velocity: Float(e.velocity) / 127,
                                    offset: Int(base + (t - from) / tps), gain: percGain, layer: true)
                        }
                    } else {
                        let tick = Int(e.tick)
                        let back = ShakerStack.isBackStroke(tick: tick, dense: percDense[k])
                        let moved = t + pocket + ShakerStack.feelTicks(tick: tick, feel: shakerFeel)
                        func play(_ at: Double) {
                            trigger(Int(e.drum), velocity: Float(e.velocity) / 127,
                                    offset: Int(base + (at - from) / tps), gain: percGain, layer: true, back: back)
                        }
                        if moved < 0 {
                            if moved + len >= from && moved + len < to { play(moved + len) }
                            if percFresh[k] && from < 1e-9 { play(from) }
                        } else if moved >= len {
                            if !percFresh[k] && moved - len >= from && moved - len < to { play(moved - len) }
                        } else if moved >= from && moved < to {
                            play(moved)
                        }
                    }
                    i += 1
                }
                base += (to - from) / tps
                if to >= len - 1e-6 { target -= len; at = 0; percFresh[k] = false } else if to > from { at = to } else { break }
            }
            if snap { at = at.rounded(); if at >= len { at = 0 } }
            percPos[k] = at
        }
    }

    private func playBass(_ e: BassEvent, offset: Int, tps: Double) {
        let note = bassFollow.transposed(e.note)
        let length = max(1, Int(Double(e.durationTicks) / tps))
        bass.noteOn(note, velocity: Float(e.velocity) / 127, delay: offset, length: length)
        // Earlier note-offs go out first, and a note still held on this pitch ends here.
        sendBassOffs(through: offset, pitch: note)
        guard bassOffCount < bassOffCapacity else { return }
        pushBassOut(offset: chunkOffset + offset, note: note, velocity: max(e.velocity, 1))
        bassOffs[bassOffCount] = PendingOff(note: note, samples: offset + length)
        bassOffCount += 1
    }

    private func pushBassOut(offset: Int, note: UInt8, velocity: UInt8) {
        guard bassOutCount < bassOutCapacity else { return }
        bassOutEvents[bassOutCount] = OutEvent(offset: Int32(offset), note: note, velocity: velocity)
        bassOutCount += 1
    }

    /// Sends the bass note-offs due by `offset` samples into this chunk, and any held on `pitch`.
    private func sendBassOffs(through offset: Int, pitch: UInt8? = nil) {
        var k = 0
        while k < bassOffCount {
            let o = bassOffs[k]
            if o.samples <= offset || o.note == pitch {
                pushBassOut(offset: chunkOffset + min(o.samples, offset), note: o.note, velocity: 0)
                bassOffCount -= 1
                bassOffs[k] = bassOffs[bassOffCount]
            } else {
                k += 1
            }
        }
    }

    private func endBassChunk(frames: Int) {
        guard bassOffCount > 0 else { return }
        sendBassOffs(through: frames - 1)
        for k in 0..<bassOffCount { bassOffs[k].samples -= frames }
    }

    /// Ends every bass note now (stop, pause). MIDI offs go into the open buffer, or into
    /// `deferredBassOffs` when the command arrived between buffers (before `beginRender`).
    private func releaseBass() {
        bass.allNotesOff()
        for k in 0..<bassOffCount {
            let note = bassOffs[k].note
            if inBuffer {
                pushBassOut(offset: chunkOffset, note: note, velocity: 0)
            } else if deferredBassOffCount < bassOffCapacity {
                deferredBassOffs[deferredBassOffCount] = OutEvent(offset: 0, note: note, velocity: 0)
                deferredBassOffCount += 1
            }
        }
        bassOffCount = 0
    }

    // MARK: Transport

    /// Advances the song by `frames` samples, triggering synth voices.
    func advance(frames: Int, chunkOffset: Int, tempo: Double) {
        self.chunkOffset = chunkOffset
        inBuffer = true
        defer { endBassChunk(frames: frames); inBuffer = false }
        if state == .stopped && previewPattern >= 0 {
            advancePreview(frames: frames, tempo: tempo)
            return
        }
        guard state != .stopped && state != .paused && pattern >= 0 else { return }
        let tps = max(tempo, 1) / 60.0 * Double(PPQN) / sampleRate
        let endSample = Double(frames)
        var samplePos = 0.0
        var iterations = 0
        let beatT = Double(max(rec.beatTicks, 1))
        while samplePos < endSample && state != .stopped && iterations < 64 {
            iterations += 1
            // Apply pending chord on allowed beats *before* notes on that beat sound.
            if bassFollow.followsBeats {
                let rem = pos.truncatingRemainder(dividingBy: beatT)
                if rem < 1e-6 || beatT - rem < 1e-6 {
                    let barT = Double(max(rec.barTicks, 1))
                    let beatsPerBar = max(1, Int((barT / beatT).rounded()))
                    let tickInBar = pos.truncatingRemainder(dividingBy: barT)
                    var beatInBar = Int(floor(tickInBar / beatT + 1e-6))
                    if beatInBar >= beatsPerBar { beatInBar = 0 }
                    bassFollow.applyOnBeat(beatInBar: beatInBar, beatsPerBar: beatsPerBar)
                }
            }
            let len = length(of: pattern)
            var barEnd = len
            if state == .main {
                let barT = Double(rec.barTicks)
                barEnd = min(len, (floor(pos / barT + 1e-9) + 1) * barT)
            }
            // Bass Follow: split at beat lines so pending chords apply without changing bar logic.
            var segEnd = barEnd
            var beatOnly = false
            if bassFollow.followsBeats {
                let nextBeat = (floor(pos / beatT + 1e-9) + 1) * beatT
                if nextBeat + 1e-9 < barEnd {
                    segEnd = nextBeat
                    beatOnly = true
                }
            }
            let ticksAvail = (endSample - samplePos) * tps
            let toBoundary = max(segEnd - pos, 0)
            if ticksAvail < toBoundary {
                emit(from: pos, to: pos + ticksAvail, sampleBase: samplePos, tps: tps)
                emitBass(ticks: ticksAvail, sampleBase: samplePos, tps: tps)
                emitPercussion(ticks: ticksAvail, sampleBase: samplePos, tps: tps)
                pos += ticksAvail
                samplePos = endSample
            } else {
                emit(from: pos, to: segEnd, sampleBase: samplePos, tps: tps)
                emitBass(ticks: toBoundary, sampleBase: samplePos, tps: tps, snap: true)
                emitPercussion(ticks: toBoundary, sampleBase: samplePos, tps: tps, snap: true)
                samplePos += toBoundary / tps
                pos = segEnd
                if !beatOnly { boundary(offset: min(Int(samplePos), frames - 1)) }
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
                setBass(partBass(0), at: 0)
                setPercussion(at: 0)
                accentHit(offset: offset)
                return
            }
            applyPendingAtBar(offset: offset)
        case .fill:
            // The bass kept going under the fill. A fill shorter than a bar skips the rest of
            // the bar in the groove, so the bass skips it too.
            let skip = max(Double(rec.barTicks) - length(of: pattern), 0)
            let ownBass = bassInFill
            bassInFill = false
            enterMain(part: part, at: mainResume, crash: rec.fillCrash, offset: offset)
            if ownBass { setBass(partBass(part), at: pos) }      // back to the groove's bass, in step with the drums
            else if skip > 0 { setBass(bassPattern, at: bassPos + skip) }
            resumePercussionAfterFill(skip: skip)
            applyPendingAtBar(offset: offset)
        case .transition:
            let next = pendingPart >= 0 ? pendingPart : (part + 1) % max(partCount, 1)
            pendingPart = -1
            pendingTransition = false
            enterMain(part: next, at: 0, crash: rec.fillCrash, offset: offset)
            applyPendingAtBar(offset: offset)
        case .outro:
            finish()
        case .stopped, .paused:
            break
        }
    }

    private func enterMain(part p: Int, at position: Double, crash: Bool, offset: Int) {
        let afterFill = state == .fill
        part = min(max(p, 0), max(partCount - 1, 0))
        state = .main
        pattern = mainPattern(part)
        let len = length(of: pattern)
        pos = len > 0 ? position.truncatingRemainder(dividingBy: len) : 0
        if !afterFill { setBass(partBass(part), at: pos); setPercussion(at: pos) }
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
                sectionBass(rec.outroBass)
                setPercussion(at: 0)
            } else {
                accentHit(offset: offset)
                finish()
            }
        } else if pendingTransition {
            pendingTransition = false
            let pat = rec.transition >= 0 ? rec.transition : fillPattern(part)
            if pat >= 0 {
                if rec.transition < 0 { consumeFill(part) }
                state = .transition
                pattern = pat
                pos = 0
                sectionBass(rec.transitionBass)
                setPercussion(at: 0)
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
                startFillBass(at: 0)
                setPercussion(at: 0)
            }
        }
    }
}
