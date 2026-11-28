import Foundation
import Synchronization

/// Single-producer / single-consumer lock-free queue (UI -> audio thread).
final class CommandQueue: @unchecked Sendable {
    private let capacity = 128
    private let buffer: UnsafeMutablePointer<Int>
    private let head = Atomic<Int>(0)   // next write slot
    private let tail = Atomic<Int>(0)   // next read slot
    private let producerLock = NSLock() // serializes multiple UI producers (never taken on audio thread)

    init() {
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }
    deinit { buffer.deallocate() }

    func push(_ value: Int) {
        producerLock.lock(); defer { producerLock.unlock() }
        let h = head.load(ordering: .relaxed)
        let next = (h + 1) % capacity
        guard next != tail.load(ordering: .acquiring) else { return } // full: drop
        buffer[h] = value
        head.store(next, ordering: .releasing)
    }

    /// Audio thread only.
    func pop() -> Int? {
        let t = tail.load(ordering: .relaxed)
        guard t != head.load(ordering: .acquiring) else { return nil }
        let v = buffer[t]
        tail.store((t + 1) % capacity, ordering: .releasing)
        return v
    }
}

/// Float stored in an atomic so UI and audio threads can share it safely.
public final class AtomicFloat: @unchecked Sendable {
    private let storage: Atomic<UInt32>
    public init(_ v: Float) { storage = Atomic(v.bitPattern) }
    public var value: Float {
        get { Float(bitPattern: storage.load(ordering: .relaxed)) }
        set { storage.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

public final class AtomicInt: @unchecked Sendable {
    private let storage: Atomic<Int>
    public init(_ v: Int) { storage = Atomic(v) }
    public var value: Int {
        get { storage.load(ordering: .relaxed) }
        set { storage.store(newValue, ordering: .relaxed) }
    }
}

/// Parameter addresses shared by the engine and the AU parameter tree.
public enum ParamAddress: UInt64, CaseIterable, Sendable {
    case volume = 0, tempo, hostSync, kit, swing, humanize, song, followTransport, fillVolume, fillOrder,
         midiClockOut, bassVolume, bassMute, bassFollow, bassKit, chordTimbre,
         /// Master bass switch: off = no bass audio or MIDI, regardless of the song.
         bassOn,
         /// Master percussion switch (shaker, tambourine, clap layers): off = none of their audio or MIDI.
         percOn, percVolume,
         /// One switch per percussion instrument (`PercussionInstrument`).
         percShaker, percTambourine, percClap,
         /// Appended: Maracas switch, and Auto Percussion (generated layers for beats without their own, default off).
         percMaracas, percAuto,
         /// Bass Follow: when pending chords may become the sounding harmony (strong beats default).
         chordCommitGrid,
         /// Sample kit for percussion layers (`PercLayerKit`: Drum Kit / FreePats / World).
         percKit,
         /// Shaker stack (`ShakerStack`): pocket (ms), feel (`ShakerFeel`), stereo width, and per lane
         /// its sound (`ShakerSource`), level and pan. Lane parameters stay in this order.
         shakerPocket, shakerFeel, shakerWidth,
         shakerLane1Source, shakerLane1Level, shakerLane1Pan,
         shakerLane2Source, shakerLane2Level, shakerLane2Pan,
         shakerLane3Source, shakerLane3Level, shakerLane3Pan
}

/// A sample kit handed to the audio thread: the published kit and the one it has picked up.
final class KitSlot: @unchecked Sendable {
    let published = Atomic<Int>(0)
    let inUse = Atomic<Int>(0)
}

/// One MIDI message for the AU MIDI output (drum notes or realtime clock).
struct MIDIOutMessage {
    var offset: Int32
    var b0: UInt8
    var b1: UInt8
    var b2: UInt8
    var length: Int32
}

/// Snapshot of playback state for the UI (written by the audio thread).
public struct EngineStatus: Sendable {
    public var state: PlayState
    public var song: Int
    public var part: Int
    public var partCount: Int
    public var bar: Int
    public var barsInPattern: Int
    public var beat: Int
    public var beatsPerBar: Int
    public var pendingFill: Bool
    public var pendingTransition: Bool
    public var pendingOutro: Bool
    public var effectiveTempo: Double
    public var level: Float
    public var fillNumber: Int = 0     // which fill is playing (1-based), 0 = none
    public var fillCount: Int = 0      // fills available in the current part
    public var previewing = false      // a file is being auditioned
    public var previewProgress: Double = 0
    /// Bass Follow on/off and the live chord name (e.g. "Am"), or "—" when none.
    public var bassFollow = false
    public var followChord: String = "—"
    /// Guitar input level 0…1 (AU sidechain / Guitar bus).
    public var guitarLevel: Float = 0
}

/// Complete realtime drum engine. Create on any thread; call `render` from the
/// audio thread and everything else from the UI.
public final class DrumEngine: @unchecked Sendable {
    public let store = SongStore()
    let synth = DrumSynth()
    let bass = BassSynth()
    let sequencer: Sequencer
    private let commands = CommandQueue()
    /// Serializes sequencer commands from UI / MIDI with the audio render path.
    /// UI start/stop must not wait for a host render (Logic FX often idle while Stopped).
    private let sequencerLock = NSLock()
    private let midiControl = MIDIControlTable()
    /// What reaches `handleMIDI`, for MIDI Settings.
    public let midiMonitor = MIDIMonitor()

    // Parameters
    public let volume = AtomicFloat(0.8)
    public let tempo = AtomicFloat(120)
    public let hostSync = AtomicInt(1)
    public let kit = AtomicInt(0)
    public let swing = AtomicFloat(0)        // 0...100 (%)
    public let humanize = AtomicFloat(15)    // 0...100 (%)
    public let songParam = AtomicInt(0)
    public let followTransport = AtomicInt(0)
    public let fillOrder = AtomicInt(0)      // 0 in order, 1 random
    /// Send MIDI Clock / Start / Stop / Continue on the AU MIDI out (24 PPQN).
    public let midiClockOut = AtomicInt(0)
    /// Bass track level (0…1.5) and mute. Muting only silences the synth bass; MIDI out keeps sending.
    public let bassVolume = AtomicFloat(0.8)
    public let bassMute = AtomicInt(0)
    /// Master on/off for the bass track (default on). Off stops audio and MIDI for bass.
    public let bassOn = AtomicInt(1)
    /// Master on/off for the percussion layers (default on), their level (0…1.5) and which
    /// instruments play (bit per `PercussionInstrument`).
    public let percOn = AtomicInt(1)
    public let percVolume = AtomicFloat(1)
    public let percInstruments = AtomicInt((1 << PercussionInstrument.count) - 1)
    public let percAuto = AtomicInt(0)
    /// Percussion-layer sample kit (`PercLayerKit` raw value).
    public let percKit = AtomicInt(0)
    /// Shaker stack (`ShakerStack`).
    public let shakerPocket = AtomicFloat(0)
    public let shakerFeel = AtomicInt(0)
    public let shakerWidth = AtomicFloat(1)
    public let shakerLaneSource = ShakerStack.defaultSources.map { AtomicInt($0.rawValue) }
    public let shakerLaneLevel = ShakerStack.defaultLevels.map { AtomicFloat($0) }
    public let shakerLanePan = ShakerStack.defaultPans.map { AtomicFloat($0) }
    let shakerLaneKits = (0..<ShakerStack.laneCount).map { _ in KitSlot() }
    /// Bass Follow (beta): transposes the bass line to live chords (MIDI and/or guitar audio).
    let bassFollow = BassFollow()

    // Status (audio thread -> UI)
    private let sState = AtomicInt(0), sSong = AtomicInt(-1), sPart = AtomicInt(0), sPartCount = AtomicInt(0)
    private let sBar = AtomicInt(0), sBars = AtomicInt(0), sBeat = AtomicInt(0), sBeats = AtomicInt(4)
    private let sPending = AtomicInt(0)
    private let sTempo = AtomicFloat(120), sLevel = AtomicFloat(0)
    private let sFill = AtomicInt(0), sFillCount = AtomicInt(0)
    private let sPreview = AtomicInt(0), sPreviewProgress = AtomicFloat(0)

    private var sampleRate: Double = 44100
    public private(set) var maxFrames = 4096
    public private(set) var scratchL: UnsafeMutablePointer<Float>
    public private(set) var scratchR: UnsafeMutablePointer<Float>
    /// Per MixBus stereo scratch (bus 0 unused — master uses scratchL/R).
    private var busL: UnsafeMutablePointer<UnsafeMutablePointer<Float>>!
    private var busR: UnsafeMutablePointer<UnsafeMutablePointer<Float>>!
    private var lpL: Float = 0, lpR: Float = 0
    private var wasHostPlaying = false

    /// So the next host-playing edge can start the drums (e.g. after allocate while Logic is already rolling).
    public func resetHostTransportEdge() { wasHostPlaying = false }

    // MIDI Clock (audio thread). 24 pulses per quarter note while the pedal is running.
    private let clockCapacity = 256
    private let clockEvents: UnsafeMutablePointer<MIDIOutMessage>
    private var clockCount = 0
    private var clockPhase = 0.0          // samples until the next 0xF8
    private var clockWasRunning = false
    private var clockWasPaused = false
    private let sampleKitSlot = Atomic<Int>(0)   // published LoadedSampleKit (raw bits), 0 = none
    private let sampleKitAck = Atomic<Int>(0)    // kit the audio thread is currently using
    private let percSampleKitSlot = Atomic<Int>(0)
    private let percSampleKitAck = Atomic<Int>(0)
    private var levelMeter: Float = 0
    /// Ballistic per-drum meters (audio thread writes, UI reads).
    private let channelMeter: UnsafeMutablePointer<Float>
    /// Peak-hold countdown in seconds (classic digital peak meter feel).
    private let channelHold: UnsafeMutablePointer<Float>
    /// Bass channel meter (same ballistics as the drum strips).
    private let bassMeter = AtomicFloat(0)
    private var bassHold: Float = 0
    /// Last multi-bus render identity (host may pull each bus separately).
    private var lastBusRenderTime: Float64 = .nan
    private var lastBusRenderFrames = 0

    public init() {
        sequencer = Sequencer(store: store, synth: synth, bass: bass, bassFollow: bassFollow)
        scratchL = .allocate(capacity: maxFrames)
        scratchR = .allocate(capacity: maxFrames)
        scratchL.initialize(repeating: 0, count: maxFrames)
        scratchR.initialize(repeating: 0, count: maxFrames)
        channelMeter = .allocate(capacity: Drum.count)
        channelMeter.initialize(repeating: 0, count: Drum.count)
        channelHold = .allocate(capacity: Drum.count)
        channelHold.initialize(repeating: 0, count: Drum.count)
        clockEvents = .allocate(capacity: clockCapacity)
        allocateBuses(frames: maxFrames)
    }

    deinit {
        freeBuses()
        scratchL.deallocate(); scratchR.deallocate()
        channelMeter.deallocate()
        channelHold.deallocate()
        clockEvents.deallocate()
    }

    /// Peak level 0…1 for a mixer channel (after gain), with release ballistics.
    public func channelLevel(_ drum: Drum) -> Float { channelMeter[drum.rawValue] }
    /// Peak level 0…1 for the bass mixer strip.
    public func bassChannelLevel() -> Float { bassMeter.value }

    private func allocateBuses(frames: Int) {
        freeBuses()
        busL = .allocate(capacity: MixBus.count)
        busR = .allocate(capacity: MixBus.count)
        for i in 0..<MixBus.count {
            if i == MixBus.master.rawValue {
                busL[i] = scratchL
                busR[i] = scratchR
            } else {
                busL[i] = .allocate(capacity: frames)
                busR[i] = .allocate(capacity: frames)
                busL[i].initialize(repeating: 0, count: frames)
                busR[i].initialize(repeating: 0, count: frames)
            }
        }
    }

    private func freeBuses() {
        guard busL != nil else { return }
        for i in 0..<MixBus.count where i != MixBus.master.rawValue {
            busL[i].deallocate(); busR[i].deallocate()
        }
        busL.deallocate(); busR.deallocate()
        busL = nil; busR = nil
    }

    /// Call before rendering starts (not on the audio thread).
    public func prepare(sampleRate: Double, maxFrames: Int) {
        self.sampleRate = sampleRate
        synth.setSampleRate(sampleRate)
        bass.setSampleRate(sampleRate)
        bassFollow.setSampleRate(sampleRate)
        sequencer.sampleRate = sampleRate
        sequencer.stop()
        if maxFrames > self.maxFrames {
            freeBuses()
            scratchL.deallocate(); scratchR.deallocate()
            self.maxFrames = maxFrames
            scratchL = .allocate(capacity: maxFrames)
            scratchR = .allocate(capacity: maxFrames)
            scratchL.initialize(repeating: 0, count: maxFrames)
            scratchR.initialize(repeating: 0, count: maxFrames)
            allocateBuses(frames: maxFrames)
        }
        lastBusRenderTime = .nan
    }

    /// Guitar AU input (sidechain). Always updates the guitar level meter; when Bass Follow
    /// is on, a detected chord is applied to the bass on the next beat.
    public func feedGuitarInput(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int) {
        bassFollow.feedAudio(left: left, right: right, frames: frames)
    }

    /// Guitar input level 0…1 (for the UI meter).
    public func guitarInputLevel() -> Float { bassFollow.inputLevel }

    /// Live per-drum mixer gain (linear, 0…2). Applies immediately on the audio thread.
    public func setMixGain(drum: Drum, _ gain: Float) {
        synth.sampler.mixGain[drum.rawValue] = min(max(gain, 0), 2)
    }
    public func mixGain(drum: Drum) -> Float { synth.sampler.mixGain[drum.rawValue] }
    public func resetMixGains() {
        for i in 0..<Drum.count { synth.sampler.mixGain[i] = 1 }
    }

    // MARK: UI API

    public func send(_ command: PedalCommand) {
        commands.push(command.rawValue)
        flushCommandsNow()
    }
    public func gotoPart(_ index: Int) {
        commands.push(PedalCommand.gotoPartBase.rawValue + index)
        flushCommandsNow()
    }

    /// Which MIDI messages press which pedal actions (MIDI Settings). Any thread; applies to the next message.
    public func setMIDIMappings(_ mappings: MIDIMappings) { midiControl.update(mappings) }

    /// Auditions a stored pattern with the current kit and tempo (stops pedal playback),
    /// with a stored bass line along when `bass` >= 0 and the bass is on.
    public func preview(pattern: Int32, loop: Bool, bass: Int32 = -1) {
        guard pattern >= 0 else { return }
        sPreview.value = 1   // shown immediately; the audio thread confirms
        commands.push(PreviewCommand.base + Int(pattern) * 2 + (loop ? 1 : 0) + Int(max(bass, -1) + 1) * PreviewCommand.bassUnit)
        flushCommandsNow()
    }
    public func stopPreview() {
        sPreview.value = 0
        commands.push(PreviewCommand.stop)
        flushCommandsNow()
    }

    /// Apply queued UI commands immediately and refresh the STOPPED/PLAYING badge.
    private func flushCommandsNow() {
        sequencerLock.lock()
        defer { sequencerLock.unlock() }
        while let c = commands.pop() {
            sequencer.handle(c)
            if c == PedalCommand.nextSong.rawValue || c == PedalCommand.prevSong.rawValue {
                songParam.value = sequencer.requestedSong
            }
        }
        publishPlayStatus()
    }

    private func publishPlayStatus(bpm: Double? = nil) {
        let s = sequencer
        sState.value = s.state.rawValue
        sSong.value = s.hasSong ? s.song : -1
        sPart.value = s.part
        sPartCount.value = s.partCount
        sBar.value = s.barInPattern
        sBars.value = s.barsInPattern
        sBeat.value = s.beatInBar
        sBeats.value = s.beatTicks > 0 ? max(1, s.barTicks / s.beatTicks) : 4
        sPending.value = (s.pendingFill ? 1 : 0) | (s.pendingTransition ? 2 : 0) | (s.pendingOutro ? 4 : 0)
        if let bpm { sTempo.value = Float(bpm) }
        sFill.value = s.state == .fill ? s.currentFill : 0
        sFillCount.value = s.fillCountInPart
        sPreview.value = s.isPreviewing ? 1 : 0
        sPreviewProgress.value = Float(s.previewProgress)
    }

    public func setParameter(_ address: ParamAddress, _ value: Float) {
        switch address {
        case .volume: volume.value = min(max(value, 0), 1.5)
        case .tempo: tempo.value = min(max(value, 30), 300)
        case .hostSync: hostSync.value = value >= 0.5 ? 1 : 0
        case .kit: kit.value = min(max(Int(value.rounded()), 0), KitManager.maxKits - 1)
        case .swing: swing.value = min(max(value, 0), 100)
        case .humanize: humanize.value = min(max(value, 0), 100)
        case .song: songParam.value = max(Int(value.rounded()), 0)
        case .followTransport: followTransport.value = value >= 0.5 ? 1 : 0
        case .fillVolume: break
        case .fillOrder: fillOrder.value = value >= 0.5 ? 1 : 0
        case .midiClockOut: midiClockOut.value = value >= 0.5 ? 1 : 0
        case .bassVolume: bassVolume.value = min(max(value, 0), 1.5)
        case .bassMute: bassMute.value = value >= 0.5 ? 1 : 0
        case .bassOn:
            let on = value >= 0.5
            bassOn.value = on ? 1 : 0
            sequencerLock.withLock { sequencer.setGlobalBassEnabled(on) }
            if !on { bassFollow.setOn(false) }
        case .bassFollow:
            bassFollow.setOn(value >= 0.5 && bassOn.value != 0)
        case .bassKit:
            let idx = min(max(Int(value.rounded()), 0), BassKit.count - 1)
            bass.setKit(BassKit(rawValue: idx) ?? .electricJazz)
        case .chordTimbre:
            let idx = min(max(Int(value.rounded()), 0), ChordTimbre.count - 1)
            bassFollow.timbre = ChordTimbre(rawValue: idx) ?? .mixed
        case .chordCommitGrid:
            let idx = min(max(Int(value.rounded()), 0), ChordCommitGrid.allCases.count - 1)
            bassFollow.commitGrid = ChordCommitGrid(rawValue: idx) ?? .strongBeats
        case .percOn:
            let on = value >= 0.5
            percOn.value = on ? 1 : 0
            sequencerLock.withLock { sequencer.setGlobalPercussionEnabled(on) }
        case .percVolume: percVolume.value = min(max(value, 0), 1.5)
        case .percAuto:
            let on = value >= 0.5
            percAuto.value = on ? 1 : 0
            sequencerLock.withLock { sequencer.setAutoPercussionEnabled(on) }
        case .percShaker, .percTambourine, .percClap, .percMaracas:
            guard let inst = PercussionInstrument.allCases.first(where: { $0.parameter == address }) else { return }
            let on = value >= 0.5
            let bit = 1 << inst.rawValue
            percInstruments.value = on ? percInstruments.value | bit : percInstruments.value & ~bit
            sequencerLock.withLock { sequencer.setPercussion(instrument: inst.rawValue, on: on) }
        case .percKit:
            percKit.value = min(max(Int(value.rounded()), 0), PercLayerKit.allCases.count - 1)
        case .shakerPocket:
            shakerPocket.value = min(max(value, ShakerStack.pocketRange.lowerBound), ShakerStack.pocketRange.upperBound)
        case .shakerFeel:
            shakerFeel.value = min(max(Int(value.rounded()), 0), ShakerFeel.allCases.count - 1)
        case .shakerWidth:
            shakerWidth.value = min(max(value, ShakerStack.widthRange.lowerBound), ShakerStack.widthRange.upperBound)
        case .shakerLane1Source, .shakerLane1Level, .shakerLane1Pan, .shakerLane2Source, .shakerLane2Level,
             .shakerLane2Pan, .shakerLane3Source, .shakerLane3Level, .shakerLane3Pan:
            guard let (lane, kind) = ShakerStack.lane(of: address) else { return }
            switch kind {
            case .source: shakerLaneSource[lane].value = min(max(Int(value.rounded()), 0), ShakerSource.allCases.count - 1)
            case .level: shakerLaneLevel[lane].value = min(max(value, 0), 1.5)
            case .pan: shakerLanePan[lane].value = min(max(value, -1), 1)
            }
        }
    }

    public func parameter(_ address: ParamAddress) -> Float {
        switch address {
        case .volume: volume.value
        case .tempo: tempo.value
        case .hostSync: Float(hostSync.value)
        case .kit: Float(kit.value)
        case .swing: swing.value
        case .humanize: humanize.value
        case .song: Float(songParam.value)
        case .followTransport: Float(followTransport.value)
        case .fillVolume: 1
        case .fillOrder: Float(fillOrder.value)
        case .midiClockOut: Float(midiClockOut.value)
        case .bassVolume: bassVolume.value
        case .bassMute: Float(bassMute.value)
        case .bassOn: Float(bassOn.value)
        case .bassFollow: bassFollow.isOn ? 1 : 0
        case .bassKit: Float(bass.kit.rawValue)
        case .chordTimbre: Float(bassFollow.timbre.rawValue)
        case .chordCommitGrid: Float(bassFollow.commitGrid.rawValue)
        case .percOn: Float(percOn.value)
        case .percVolume: percVolume.value
        case .percAuto: Float(percAuto.value)
        case .percShaker, .percTambourine, .percClap, .percMaracas:
            Float(PercussionInstrument.allCases.first { $0.parameter == address }
                .map { (percInstruments.value >> $0.rawValue) & 1 } ?? 0)
        case .percKit: Float(percKit.value)
        case .shakerPocket: shakerPocket.value
        case .shakerFeel: Float(shakerFeel.value)
        case .shakerWidth: shakerWidth.value
        case .shakerLane1Source, .shakerLane1Level, .shakerLane1Pan, .shakerLane2Source, .shakerLane2Level,
             .shakerLane2Pan, .shakerLane3Source, .shakerLane3Level, .shakerLane3Pan:
            ShakerStack.lane(of: address).map { lane, kind in
                switch kind {
                case .source: Float(shakerLaneSource[lane].value)
                case .level: shakerLaneLevel[lane].value
                case .pan: shakerLanePan[lane].value
                }
            } ?? 0
        }
    }

    /// Hands a loaded sample kit to the audio thread (see KitManager).
    func publishSampleKit(bits: Int) { sampleKitSlot.store(bits, ordering: .releasing) }
    var publishedSampleKit: Int { sampleKitSlot.load(ordering: .acquiring) }
    var sampleKitInUse: Int { sampleKitAck.load(ordering: .acquiring) }

    func publishPercSampleKit(bits: Int) { percSampleKitSlot.store(bits, ordering: .releasing) }
    func publishShakerLaneKit(_ lane: Int, bits: Int) { shakerLaneKits[lane].published.store(bits, ordering: .releasing) }
    /// Kits of the shaker lanes that the audio thread uses or is about to pick up.
    var shakerLaneKitsInUse: [Int] {
        shakerLaneKits.flatMap { [$0.published.load(ordering: .acquiring), $0.inUse.load(ordering: .acquiring)] }
    }
    var publishedPercSampleKit: Int { percSampleKitSlot.load(ordering: .acquiring) }
    var percSampleKitInUse: Int { percSampleKitAck.load(ordering: .acquiring) }

    public var status: EngineStatus {
        let pending = sPending.value
        return EngineStatus(state: PlayState(rawValue: sState.value) ?? .stopped, song: sSong.value,
                            part: sPart.value, partCount: sPartCount.value, bar: sBar.value,
                            barsInPattern: sBars.value, beat: sBeat.value, beatsPerBar: sBeats.value,
                            pendingFill: pending & 1 != 0, pendingTransition: pending & 2 != 0,
                            pendingOutro: pending & 4 != 0, effectiveTempo: Double(sTempo.value),
                            level: sLevel.value, fillNumber: sFill.value, fillCount: sFillCount.value,
                            previewing: sPreview.value != 0, previewProgress: Double(sPreviewProgress.value),
                            bassFollow: bassFollow.isOn, followChord: bassFollow.chordName,
                            guitarLevel: bassFollow.inputLevel)
    }

    // MARK: Audio thread API

    /// Handles a MIDI 1.0 channel message. Messages assigned in MIDI Settings (notes 0-9 by
    /// default) are pedal commands, other GM percussion notes play the kit, and program
    /// change selects a song unless that's turned off. With Bass Follow on, non–channel-10
    /// notes update the live chord (applied to the bass on the next beat).
    public func handleMIDI(_ status: UInt8, _ d1: UInt8, _ d2: UInt8, offset: Int) {
        midiMonitor.record(status, d1, d2)
        if midiMonitor.takesForLearn(status, d2) { return }
        if let command = midiControl.command(status: status, data1: d1, data2: d2) {
            sequencerLock.lock()
            sequencer.handle(command.rawValue)
            if command == .nextSong || command == .prevSong { songParam.value = sequencer.requestedSong }
            publishPlayStatus()
            sequencerLock.unlock()
            return
        }
        let ch = status & 0x0F
        let cmd = status & 0xF0
        if bassFollow.takeMIDINote(command: cmd, channel: ch, note: d1, velocity: d2) { return }
        switch cmd {
        case 0x90 where d2 > 0:
            if let drum = Drum.fromGM(d1) {
                sequencerLock.lock()
                sequencer.playDrum(drum.rawValue, velocity: Float(d2) / 127, offset: offset)
                sequencerLock.unlock()
            }
        case 0xC0:
            if midiControl.programChangeSelectsSong, Int(d1) < store.count { songParam.value = Int(d1) }
        default:
            break
        }
    }

    /// Call at the start of each render cycle, before handleMIDI.
    public func beginRender() {
        sequencerLock.lock()
        sequencer.beginBuffer()
        clockCount = 0
        while let c = commands.pop() { sequencer.handle(c) }
        sequencerLock.unlock()
    }

    /// Renders `frames` stereo samples (replacing buffer contents). Master only.
    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                       hostTempo: Double?, hostPlaying: Bool?) {
        _ = renderAllBuses(frames: frames, sampleTime: .nan, hostTempo: hostTempo, hostPlaying: hostPlaying)
        if left != scratchL { left.update(from: scratchL, count: frames) }
        if right != scratchR { right.update(from: scratchR, count: frames) }
    }

    /// True when the next `renderAllBuses` will actually recompute (not a multi-out cache hit).
    public func isNewRenderCycle(sampleTime: Float64, frames: Int) -> Bool {
        !(sampleTime == lastBusRenderTime && frames == lastBusRenderFrames && !sampleTime.isNaN)
    }

    /// Ensures all MixBus buffers are filled for this host render cycle, then copies `bus` out.
    public func renderBus(_ bus: Int, frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                          sampleTime: Float64, hostTempo: Double?, hostPlaying: Bool?) {
        _ = renderAllBuses(frames: frames, sampleTime: sampleTime, hostTempo: hostTempo, hostPlaying: hostPlaying)
        let b = min(max(bus, 0), MixBus.count - 1)
        left.update(from: busL[b], count: frames)
        right.update(from: busR[b], count: frames)
    }

    /// Renders master + subgroups into internal bus buffers. Returns false if `frames` is too large.
    @discardableResult
    public func renderAllBuses(frames: Int, sampleTime: Float64, hostTempo: Double?, hostPlaying: Bool?) -> Bool {
        guard frames <= maxFrames else { return false }
        // Same cycle (multi-out hosts pull each bus): reuse buffers.
        if !isNewRenderCycle(sampleTime: sampleTime, frames: frames) {
            return true
        }
        lastBusRenderTime = sampleTime
        lastBusRenderFrames = frames

        sequencerLock.lock()
        defer { sequencerLock.unlock() }

        // Host transport follow.
        if let playing = hostPlaying, followTransport.value == 1 {
            if playing && !wasHostPlaying && sequencer.state == .stopped { sequencer.handle(PedalCommand.start.rawValue) }
            if !playing && wasHostPlaying && sequencer.state != .stopped { sequencer.handle(PedalCommand.stop.rawValue) }
            wasHostPlaying = playing
        }

        if songParam.value != sequencer.requestedSong {
            sequencer.requestedSong = min(songParam.value, max(store.count - 1, 0))
        }
        let kitBits = sampleKitSlot.load(ordering: .acquiring)
        if kitBits != synth.sampler.kitBits {
            synth.sampler.setKit(bits: kitBits)
            sampleKitAck.store(kitBits, ordering: .releasing)
        }
        let percBits = percSampleKitSlot.load(ordering: .acquiring)
        if percBits != synth.sampler.percKitBits {
            synth.sampler.setPercKit(bits: percBits)
            percSampleKitAck.store(percBits, ordering: .releasing)
        }
        for lane in 0..<ShakerStack.laneCount {
            let bits = shakerLaneKits[lane].published.load(ordering: .acquiring)
            if bits != synth.sampler.laneKitBits[lane] {
                synth.sampler.setLaneKit(lane, bits: bits)
                shakerLaneKits[lane].inUse.store(bits, ordering: .releasing)
            }
            synth.sampler.laneSource[lane] = shakerLaneSource[lane].value
            synth.sampler.laneGain[lane] = shakerLaneLevel[lane].value
            synth.sampler.lanePan[lane] = shakerLanePan[lane].value
        }
        synth.sampler.shakerWidth = shakerWidth.value
        sequencer.shakerPocketMs = Double(shakerPocket.value)
        sequencer.shakerFeel = ShakerFeel(rawValue: shakerFeel.value) ?? .grid
        let kitIndex = kit.value
        let sampled = kitIndex >= Kits.all.count
        synth.kit = sampled ? (synth.sampler.fallbackSynthKit ?? 0) : kitIndex
        sequencer.swing = Double(swing.value) / 100
        sequencer.fillOrder = fillOrder.value
        sequencer.humanize = Double(humanize.value) / 100
        sequencer.percGain = percVolume.value
        var bpm = Double(tempo.value)
        if hostSync.value == 1, let ht = hostTempo, ht > 0 { bpm = ht }

        scratchL.update(repeating: 0, count: frames)
        scratchR.update(repeating: 0, count: frames)
        for i in 1..<MixBus.count {
            busL[i].update(repeating: 0, count: frames)
            busR[i].update(repeating: 0, count: frames)
        }
        synth.sampler.clearChannelPeaks()

        synth.sampler.beatFrames = sampleRate * 60 / max(bpm, 1)
        let bassGain: Float = (bassOn.value == 0 || bassMute.value == 1) ? 0 : bassVolume.value
        let chunk = 64
        var done = 0
        while done < frames {
            let n = min(chunk, frames - done)
            sequencer.advance(frames: n, chunkOffset: done, tempo: bpm)
            // Offset subgroup pointers for this chunk.
            var chunkL = [UnsafeMutablePointer<Float>](repeating: scratchL, count: MixBus.count)
            var chunkR = [UnsafeMutablePointer<Float>](repeating: scratchR, count: MixBus.count)
            for b in 0..<MixBus.count {
                chunkL[b] = busL[b] + done
                chunkR[b] = busR[b] + done
            }
            chunkL.withUnsafeMutableBufferPointer { lBuf in
                chunkR.withUnsafeMutableBufferPointer { rBuf in
                    synth.render(busesL: lBuf.baseAddress, busesR: rBuf.baseAddress, busCount: MixBus.count,
                                 left: scratchL + done, right: scratchR + done, frames: n)
                }
            }
            let b = MixBus.bass.rawValue
            bass.render(left: scratchL + done, right: scratchR + done, frames: n, gain: bassGain,
                        busLeft: busL[b] + done, busRight: busR[b] + done)
            done += n
        }

        // Master: kit tone filter, volume, soft clip, meter.
        let cutoff: Float = sampled ? 20000 : Kits.all[min(max(kitIndex, 0), Kits.all.count - 1)].masterCutoff
        let lpCoef: Float = cutoff >= 19000 ? 1 : 1 - expf(-2 * Float.pi * cutoff / Float(sampleRate))
        let vol = volume.value
        var peak: Float = 0
        for i in 0..<frames {
            var l = scratchL[i], r = scratchR[i]
            if lpCoef < 1 {
                lpL += lpCoef * (l - lpL); lpR += lpCoef * (r - lpR)
                l = lpL; r = lpR
            }
            l = softClip(l * vol); r = softClip(r * vol)
            scratchL[i] = l; scratchR[i] = r
            peak = max(peak, abs(l), abs(r))
        }
        // Soft-clip subgroups with the same master volume so inserts sit at a usable level.
        for b in 1..<MixBus.count {
            let bl = busL[b], br = busR[b]
            for i in 0..<frames {
                bl[i] = softClip(bl[i] * vol)
                br[i] = softClip(br[i] * vol)
            }
        }
        levelMeter = max(peak, levelMeter * 0.85)
        // Channel meters: instant attack, ~350 ms peak hold, ~1.2 s for a 20 dB fall.
        let dt = Float(frames) / Float(max(sampleRate, 1))
        let holdSec: Float = 0.35
        let releaseTau: Float = 0.52   // exp(-1.2/0.52) ≈ 0.1 → ~20 dB in 1.2 s
        let releaseCoef = expf(-dt / releaseTau)
        for i in 0..<Drum.count {
            let p = min(synth.sampler.channelPeak[i], 1.5) / 1.5
            if p >= channelMeter[i] - 0.0001 {
                channelMeter[i] = p
                channelHold[i] = holdSec
            } else if channelHold[i] > 0 {
                channelHold[i] -= dt
            } else {
                channelMeter[i] *= releaseCoef
                if channelMeter[i] < 0.0005 { channelMeter[i] = 0 }
            }
        }
        let bp = min(bass.lastPeak / 1.5, 1)
        if bp >= bassMeter.value - 0.0001 {
            bassMeter.value = bp
            bassHold = holdSec
        } else if bassHold > 0 {
            bassHold -= dt
        } else {
            var m = bassMeter.value * releaseCoef
            if m < 0.0005 { m = 0 }
            bassMeter.value = m
        }

        publishPlayStatus(bpm: bpm)
        sLevel.value = levelMeter

        emitMIDIClock(frames: frames, bpm: bpm)
        return true
    }

    /// MIDI notes produced during the last render (for MIDI output).
    public func forEachOutputEvent(_ body: (Int, UInt8, UInt8) -> Void) {
        for i in 0..<sequencer.outCount {
            let e = sequencer.outEvents[i]
            body(Int(e.offset), e.note, e.velocity)
        }
    }

    /// Bass notes from the last render, in order (velocity 0 = note off), for MIDI channel 2.
    public func forEachBassOutputEvent(_ body: (Int, UInt8, UInt8) -> Void) {
        for i in 0..<sequencer.bassOutCount {
            let e = sequencer.bassOutEvents[i]
            body(Int(e.offset), e.note, e.velocity)
        }
    }

    /// MIDI Clock / Start / Stop / Continue from the last render (1- or 3-byte messages).
    public func forEachClockEvent(_ body: (Int, UInt8, UInt8, UInt8, Int) -> Void) {
        for i in 0..<clockCount {
            let e = clockEvents[i]
            body(Int(e.offset), e.b0, e.b1, e.b2, Int(e.length))
        }
    }

    // MARK: MIDI Clock

    /// Running = pedal song playing (not stopped/paused, not file preview).
    private var clockShouldRun: Bool {
        midiClockOut.value == 1
            && !sequencer.isPreviewing
            && sequencer.state != .stopped
            && sequencer.state != .paused
    }

    private func pushClock(_ offset: Int, _ b0: UInt8, _ b1: UInt8 = 0, _ b2: UInt8 = 0, length: Int = 1) {
        guard clockCount < clockCapacity else { return }
        clockEvents[clockCount] = MIDIOutMessage(offset: Int32(max(0, offset)), b0: b0, b1: b1, b2: b2, length: Int32(length))
        clockCount += 1
    }

    /// 24 PPQN realtime clock while the pedal runs; Start / Continue / Stop on transitions.
    private func emitMIDIClock(frames: Int, bpm: Double) {
        let want = clockShouldRun
        let paused = midiClockOut.value == 1 && !sequencer.isPreviewing && sequencer.state == .paused

        if want && !clockWasRunning {
            if clockWasPaused {
                pushClock(0, 0xFB) // Continue — keep phase so the grid stays put
            } else {
                pushClock(0, 0xF2, 0, 0, length: 3) // Song Position = 0
                pushClock(0, 0xFA) // Start
                clockPhase = 0
            }
            clockWasRunning = true
            clockWasPaused = false
        } else if !want && clockWasRunning {
            pushClock(0, 0xFC) // Stop
            clockWasRunning = false
            clockWasPaused = paused
            if !paused { clockPhase = 0 }
            return
        } else if !want {
            if !paused { clockWasPaused = false }
            return
        }

        let safeBPM = max(bpm, 1)
        let samplesPerTick = sampleRate * 60.0 / (safeBPM * 24.0)
        guard samplesPerTick > 0, frames > 0 else { return }

        var phase = clockPhase
        var t = 0.0
        while true {
            let remain = samplesPerTick - phase
            if t + remain >= Double(frames) {
                phase += Double(frames) - t
                break
            }
            t += remain
            let off = min(frames - 1, Int(t))
            pushClock(off, 0xF8)
            phase = 0
            if clockCount >= clockCapacity { break }
        }
        clockPhase = phase
        clockWasRunning = true
        clockWasPaused = false
    }
}
