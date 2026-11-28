import AudioToolbox
import AVFoundation
import CoreAudioKit
import os

/// What reaches Bass Follow, for the UI and the input log.
public struct InputStatus: Sendable {
    public enum Source: Int, Sendable { case none, sideChain, trackInput }
    public var source: Source
    /// Result of the last Side Chain (bus 1) pull; `nil` when the host passes no pull block.
    public var sideChainResult: OSStatus?
    /// Recent peak 0…1 of the Side Chain and of the track / main input (bus 0).
    public var sideChainLevel: Float
    public var trackLevel: Float
    /// The host answered pulls with pointers to its own memory instead of filling ours.
    public var hostBuffers: Bool
}

/// Pull buffer for one input bus, laid out exactly like the bus format.
/// AURenderPullInputBlock may fill the buffers we pass or replace `mData` with memory the
/// host owns (the out-of-process AUv3 bridge does), so samples are read back through the list.
private final class InputBusBuffer {
    private let pcm: AVAudioPCMBuffer
    private let original: UnsafePointer<AudioBufferList>
    private let list: UnsafeMutablePointer<AudioBufferList>
    private let interleaved: Bool
    private let channels: Int
    private let bytesPerFrame: UInt32
    let summary: String

    init?(bus: AUAudioUnitBus, maxFrames: AUAudioFrameCount) {
        let format = bus.format
        guard format.commonFormat == .pcmFormatFloat32,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames) else { return nil }
        self.pcm = pcm
        original = pcm.audioBufferList
        list = pcm.mutableAudioBufferList
        interleaved = format.isInterleaved
        channels = max(Int(format.channelCount), 1)
        bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        summary = "\(channels) ch \(interleaved ? "interleaved" : "deinterleaved")"
            + (bus.isEnabled ? "" : " (disabled)")
    }

    /// Pulls `bus` into planar `left`/`right` (mono goes to both, silence on error).
    func pull(bus: Int, frames: Int, timestamp: UnsafePointer<AudioTimeStamp>, block: AURenderPullInputBlock,
              left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
              hostBuffers: inout Bool) -> OSStatus {
        let ours = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: original))
        let abl = UnsafeMutableAudioBufferListPointer(list)
        // The previous pull may have left host pointers in the list.
        list.pointee.mNumberBuffers = original.pointee.mNumberBuffers
        for i in 0..<ours.count {
            abl[i] = AudioBuffer(mNumberChannels: ours[i].mNumberChannels,
                                 mDataByteSize: UInt32(frames) * bytesPerFrame, mData: ours[i].mData)
        }
        var flags = AudioUnitRenderActionFlags()
        let status = block(&flags, timestamp, AUAudioFrameCount(frames), bus, list)
        let count = min(abl.count, ours.count)
        guard status == noErr, count > 0, let first = abl[0].mData else {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            return status
        }
        if first != ours[0].mData { hostBuffers = true }
        if interleaved {
            let src = first.assumingMemoryBound(to: Float.self)
            let second = channels > 1 ? 1 : 0
            for i in 0..<frames {
                left[i] = src[i * channels]
                right[i] = src[i * channels + second]
            }
        } else {
            left.update(from: first.assumingMemoryBound(to: Float.self), count: frames)
            if count > 1, let r = abl[1].mData {
                right.update(from: r.assumingMemoryBound(to: Float.self), count: frames)
            } else {
                right.update(from: left, count: frames)
            }
        }
        return noErr
    }
}

/// AUv3 drum engine. Registered as:
/// - `aumu` instrument (`pdbt`) — Side Chain on input bus 1 (bus 0 as fallback) for Bass Follow
/// - `aumf` music effect (`pdbf`) — strip audio on bus 0 + Logic Side Chain on bus 1
/// MIDI pedal control + MIDI out (drums ch 10, bass ch 2) work in both forms.
public final class PedalBeatAudioUnit: AUAudioUnit, @unchecked Sendable {
    public let engine = DrumEngine()
    public let library: SongLibrary
    public let kits: KitManager

    private var outputBuses: [AUAudioUnitBus] = []
    private var _outputBusses: AUAudioUnitBusArray!
    private var mainInputBus: AUAudioUnitBus!
    private var guitarInputBus: AUAudioUnitBus!
    private var _inputBusses: AUAudioUnitBusArray!
    private var _parameterTree: AUParameterTree!
    private var renderFrames = 4096
    /// Side Chain audio for analysis (audio-thread only after allocate).
    private var guitarL: UnsafeMutablePointer<Float>!
    private var guitarR: UnsafeMutablePointer<Float>!
    /// Track / main input (bus 0): Music Effect dry passthrough, and analysis without Side Chain.
    private var trackL: UnsafeMutablePointer<Float>!
    private var trackR: UnsafeMutablePointer<Float>!
    private var mainInput: InputBusBuffer?
    private var sideChainInput: InputBusBuffer?
    /// `true` when loaded as Music Effect (`aumf`).
    private let guitarOnMainInput: Bool
    /// Track audio ready to mix under the drums (aumf only).
    private var trackPulledThisCycle = false
    /// A quiet Side Chain keeps priority over the track input for this many frames.
    private var sideChainHold = 0
    private var sideChainHoldFrames = 96000
    private var sideChainPeak: Float = 0
    private var trackPeak: Float = 0
    /// Input diagnostics (audio thread writes, UI and log read).
    private let inSource = AtomicInt(InputStatus.Source.none.rawValue)
    private let inSideChainResult = AtomicInt(Int(kAudioUnitErr_NoConnection))
    private let inSideChainLevel = AtomicFloat(0)
    private let inTrackLevel = AtomicFloat(0)
    private let inHostBuffers = AtomicInt(0)
    private static let noPullBlock = Int(Int32.min)
    private static let log = Logger(subsystem: "com.pedalbeat.au", category: "input")
    private var inputLogTimer: DispatchSourceTimer?

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        library = SongLibrary(store: engine.store)
        kits = KitManager(engine: engine, installedDirectory: InstalledContent.kitsFolder)
        // Songs that ship with PedalBeat (iOS: MIDI Songs and bb Songs built in) or were installed with it
        // (macOS: the MIDI Songs and bb Songs installers); before the user library so edited copies replace them.
        let builtIn = ContentPack.builtInPacks(in: [Bundle(for: PedalBeatAudioUnit.self), Bundle.main])
        for pack in builtIn + ContentPack.installedPacks() {
            let t0 = Date()
            let n = library.loadContentPack(at: pack)
            Self.log.notice("Song pack \(pack.lastPathComponent, privacy: .public): \(n) songs in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        }
        library.useUserLibrary(at: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PedalBeat/Library/imports.plist"))
        guitarOnMainInput = componentDescription.componentType == kAudioUnitType_MusicEffect
        try super.init(componentDescription: componentDescription, options: options)
        // Audio FX strips rarely get MIDI Start — follow host Play/Stop by default.
        if guitarOnMainInput { engine.setParameter(.followTransport, 1) }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        // Music Effect: single stereo out (hosts treat multi-out FX oddly). Instrument: MixBus multi-out.
        let outBuses: [MixBus] = guitarOnMainInput ? [.master] : MixBus.allCases
        outputBuses = try outBuses.map { bus in
            let b = try AUAudioUnitBus(format: format)
            b.maximumChannelCount = 2
            b.name = bus.displayName
            return b
        }
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: outputBuses)

        // Logic connects the plug-in header's Side Chain to input element 1. Music Effect
        // bus 0 is the channel strip's own audio.
        mainInputBus = try AUAudioUnitBus(format: format)
        mainInputBus.maximumChannelCount = 2
        mainInputBus.name = "Input"
        mainInputBus.isEnabled = true
        guitarInputBus = try AUAudioUnitBus(format: format)
        guitarInputBus.maximumChannelCount = 2
        guitarInputBus.name = "Side Chain"
        guitarInputBus.isEnabled = true
        _inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input,
                                           busses: [mainInputBus, guitarInputBus])
        maximumFramesToRender = 4096
        _parameterTree = makeParameterTree()
        if let first = library.songs.first { engine.setParameter(.tempo, Float(first.tempo)) }
        engine.setMIDIMappings(.load())
        NotificationCenter.default.addObserver(self, selector: #selector(midiMappingsChanged),
                                               name: MIDIMappings.didChange, object: nil)
    }

    /// MIDI Settings are shared by every project and host, so each instance follows a change.
    @objc private func midiMappingsChanged() { engine.setMIDIMappings(.load()) }

    // MARK: Parameters

    private func makeParameterTree() -> AUParameterTree {
        let rw: AudioUnitParameterOptions = [.flag_IsReadable, .flag_IsWritable]
        func p(_ id: String, _ name: String, _ a: ParamAddress, _ min: Float, _ max: Float,
               _ unit: AudioUnitParameterUnit, strings: [String]? = nil) -> AUParameter {
            AUParameterTree.createParameter(withIdentifier: id, name: name, address: a.rawValue,
                                            min: min, max: max, unit: unit, unitName: nil,
                                            flags: rw, valueStrings: strings, dependentParameters: nil)
        }
        let params: [AUParameter] = [
            p("volume", "Volume", .volume, 0, 1.5, .linearGain),
            p("tempo", "Tempo", .tempo, 30, 300, .BPM),
            p("hostSync", "Sync Tempo to Host", .hostSync, 0, 1, .boolean),
            p("kit", "Drum Kit", .kit, 0, Float(KitManager.maxKits - 1), .indexed),
            p("swing", "Swing", .swing, 0, 100, .percent),
            p("humanize", "Humanize", .humanize, 0, 100, .percent),
            p("song", "Song", .song, 0, 4095, .indexed),
            p("followTransport", "Start/Stop with Host", .followTransport, 0, 1, .boolean),
            p("fillOrder", "Fill Order", .fillOrder, 0, 1, .indexed, strings: ["In Order", "Random"]),
            p("midiClockOut", "MIDI Clock Out", .midiClockOut, 0, 1, .boolean),
            p("bassOn", "Bass", .bassOn, 0, 1, .boolean),
            p("bassVolume", "Bass Volume", .bassVolume, 0, 1.5, .linearGain),
            p("bassMute", "Mute Bass", .bassMute, 0, 1, .boolean),
            p("bassFollow", "Bass Follow (Beta)", .bassFollow, 0, 1, .boolean),
            p("bassKit", "Bass Kit", .bassKit, 0, Float(BassKit.count - 1), .indexed,
              strings: BassKit.allCases.map(\.name)),
            p("chordTimbre", "Follow Source", .chordTimbre, 0, Float(ChordTimbre.count - 1), .indexed,
              strings: ChordTimbre.allCases.map(\.name)),
            p("chordCommitGrid", "Follow Timing", .chordCommitGrid,
              0, Float(ChordCommitGrid.allCases.count - 1), .indexed,
              strings: ChordCommitGrid.allCases.map(\.name)),
            p("percOn", "Percussion", .percOn, 0, 1, .boolean),
            p("percVolume", "Percussion Volume", .percVolume, 0, 1.5, .linearGain),
            p("percShaker", "Shaker", .percShaker, 0, 1, .boolean),
            p("percTambourine", "Tambourine", .percTambourine, 0, 1, .boolean),
            p("percClap", "Clap", .percClap, 0, 1, .boolean),
            p("percMaracas", "Maracas", .percMaracas, 0, 1, .boolean),
            p("percAuto", "Auto Percussion", .percAuto, 0, 1, .boolean),
        ]
        for prm in params {
            if let a = ParamAddress(rawValue: prm.address) { prm.value = engine.parameter(a) }
        }
        let tree = AUParameterTree.createTree(withChildren: params)
        let engine = self.engine
        let library = self.library
        let kits = self.kits
        tree.implementorValueObserver = { param, value in
            guard let a = ParamAddress(rawValue: param.address) else { return }
            engine.setParameter(a, value)
            if a == .kit { kits.select(index: Int(engine.parameter(.kit))) }
        }
        tree.implementorValueProvider = { param in
            ParamAddress(rawValue: param.address).map { engine.parameter($0) } ?? 0
        }
        tree.implementorStringFromValueCallback = { param, valuePtr in
            let v = valuePtr?.pointee ?? param.value
            switch ParamAddress(rawValue: param.address) {
            case .song: return library.song(at: Int(v.rounded()))?.name ?? "\(Int(v))"
            case .kit: return kits.name(at: Int(v.rounded()))
            case .tempo: return String(format: "%.1f", v)
            case .volume, .bassVolume, .percVolume: return String(format: "%.2f", v)
            case .fillOrder: return v >= 0.5 ? "Random" : "In Order"
            case .bassOn, .percOn, .percShaker, .percTambourine, .percClap, .percMaracas, .percAuto: return v >= 0.5 ? "On" : "Off"
            case .bassKit: return BassKit(rawValue: Int(v.rounded()))?.name ?? "Bass"
            case .chordTimbre: return ChordTimbre(rawValue: Int(v.rounded()))?.name ?? "Mixed"
            case .chordCommitGrid: return ChordCommitGrid(rawValue: Int(v.rounded()))?.name ?? "Strong Beats"
            default: return String(format: "%.0f", v)
            }
        }
        return tree
    }

    public override var parameterTree: AUParameterTree? {
        get { _parameterTree }
        set { /* fixed tree */ }
    }

    public func parameter(_ a: ParamAddress) -> AUParameter? { _parameterTree.parameter(withAddress: a.rawValue) }

    // MARK: Busses / capabilities

    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }
    public override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    /// Main in/out only; the Side Chain is the separate input bus 1.
    /// Music Effect (`aumf`): mono or stereo in → stereo out. Instrument (`aumu`): no main in
    /// (or the default stereo input bus) → stereo out.
    public override var channelCapabilities: [NSNumber]? {
        guitarOnMainInput ? [1, 2, 2, 2] : [0, 2, 2, 2]
    }
    public override var midiOutputNames: [String] { ["Drums"] }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        if guitarOnMainInput { engine.resetHostTransportEdge() }
        renderFrames = Int(maximumFramesToRender)
        let rate = outputBuses.first?.format.sampleRate ?? mainInputBus.format.sampleRate
        engine.prepare(sampleRate: rate, maxFrames: renderFrames)
        freeGuitarBuffers()
        guitarL = .allocate(capacity: renderFrames)
        guitarR = .allocate(capacity: renderFrames)
        trackL = .allocate(capacity: renderFrames)
        trackR = .allocate(capacity: renderFrames)
        guitarL.initialize(repeating: 0, count: renderFrames)
        guitarR.initialize(repeating: 0, count: renderFrames)
        trackL.initialize(repeating: 0, count: renderFrames)
        trackR.initialize(repeating: 0, count: renderFrames)
        // Bus formats can't change while render resources are allocated.
        mainInput = InputBusBuffer(bus: mainInputBus, maxFrames: maximumFramesToRender)
        sideChainInput = InputBusBuffer(bus: guitarInputBus, maxFrames: maximumFramesToRender)
        sideChainHoldFrames = Int(rate * 2)
        sideChainHold = 0
        sideChainPeak = 0
        trackPeak = 0
        inHostBuffers.value = 0
        Self.log.notice("""
            \(self.guitarOnMainInput ? "Drums FX" : "Drums", privacy: .public) render resources: \
            \(Int(rate)) Hz, \(self.renderFrames) frames; input bus 0 \
            \(self.mainInput?.summary ?? "unusable format", privacy: .public); Side Chain bus 1 \
            \(self.sideChainInput?.summary ?? "unusable format", privacy: .public)
            """)
        startInputLog()
    }

    public override func deallocateRenderResources() {
        inputLogTimer?.cancel()
        inputLogTimer = nil
        freeGuitarBuffers()
        super.deallocateRenderResources()
    }

    private func freeGuitarBuffers() {
        mainInput = nil
        sideChainInput = nil
        if guitarL != nil { guitarL.deallocate(); guitarL = nil }
        if guitarR != nil { guitarR.deallocate(); guitarR = nil }
        if trackL != nil { trackL.deallocate(); trackL = nil }
        if trackR != nil { trackR.deallocate(); trackR = nil }
    }

    /// Pulls the Side Chain (bus 1) and the track / main input (bus 0) and feeds Bass Follow.
    /// The Side Chain wins whenever it carries audio. Pull errors only mean "no input":
    /// the drums always render.
    private func captureInputs(frames: Int, timestamp: UnsafePointer<AudioTimeStamp>,
                               pullInput: AURenderPullInputBlock?) {
        trackPulledThisCycle = false
        guard let gL = guitarL, let gR = guitarR, let tL = trackL, let tR = trackR else { return }
        guard let pull = pullInput else {
            inSideChainResult.value = Self.noPullBlock
            inSource.value = InputStatus.Source.none.rawValue
            return
        }
        var hostBuffers = false
        var sideStatus = kAudioUnitErr_NoConnection
        if let side = sideChainInput {
            sideStatus = side.pull(bus: 1, frames: frames, timestamp: timestamp, block: pull,
                                   left: gL, right: gR, hostBuffers: &hostBuffers)
        } else {
            gL.update(repeating: 0, count: frames)
            gR.update(repeating: 0, count: frames)
        }
        var mainStatus = kAudioUnitErr_NoConnection
        if let main = mainInput {
            mainStatus = main.pull(bus: 0, frames: frames, timestamp: timestamp, block: pull,
                                   left: tL, right: tR, hostBuffers: &hostBuffers)
        }
        trackPulledThisCycle = guitarOnMainInput && mainStatus == noErr

        let silence: Float = 0.0001
        let sidePeakNow = sideStatus == noErr ? Self.bufferPeak(gL, gR, frames) : 0
        let trackPeakNow = mainStatus == noErr ? Self.bufferPeak(tL, tR, frames) : 0
        sideChainHold = sidePeakNow > silence ? sideChainHoldFrames : max(0, sideChainHold - frames)
        let source: InputStatus.Source
        if sideStatus == noErr && (sidePeakNow > silence || sideChainHold > 0) {
            source = .sideChain
        } else if mainStatus == noErr && trackPeakNow > silence {
            source = .trackInput
        } else {
            source = .none
        }
        if source == .trackInput {
            engine.feedGuitarInput(left: UnsafePointer(tL), right: UnsafePointer(tR), frames: frames)
        } else {
            // Side Chain, or silence so the GTR meter falls back to zero.
            engine.feedGuitarInput(left: UnsafePointer(gL), right: UnsafePointer(gR), frames: frames)
        }

        sideChainPeak = max(sidePeakNow, sideChainPeak * 0.8)
        trackPeak = max(trackPeakNow, trackPeak * 0.8)
        inSource.value = source.rawValue
        inSideChainResult.value = Int(sideStatus)
        inSideChainLevel.value = sideChainPeak
        inTrackLevel.value = trackPeak
        if hostBuffers { inHostBuffers.value = 1 }
    }

    private static func bufferPeak(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ frames: Int) -> Float {
        var peak: Float = 0
        for i in 0..<frames {
            peak = max(peak, abs(left[i]), abs(right[i]))
        }
        return peak
    }

    // MARK: Input diagnostics

    public var inputStatus: InputStatus {
        let result = inSideChainResult.value
        return InputStatus(source: InputStatus.Source(rawValue: inSource.value) ?? .none,
                           sideChainResult: result == Self.noPullBlock ? nil : OSStatus(truncatingIfNeeded: result),
                           sideChainLevel: inSideChainLevel.value, trackLevel: inTrackLevel.value,
                           hostBuffers: inHostBuffers.value != 0)
    }

    /// Logs Side Chain / input changes once a second (Console, subsystem com.pedalbeat.au).
    private func startInputLog() {
        inputLogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        var lastKey = ""
        timer.setEventHandler { [weak self] in
            guard let line = self?.inputLogLine(), line.key != lastKey else { return }
            lastKey = line.key
            PedalBeatAudioUnit.log.notice("\(line.message, privacy: .public)")
        }
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.resume()
        inputLogTimer = timer
    }

    /// `key` changes only on meaningful state changes, not on every level wiggle.
    private func inputLogLine() -> (key: String, message: String) {
        let s = inputStatus
        func db(_ level: Float) -> String { level > 0.0001 ? String(format: "%.0f dBFS", 20 * log10f(level)) : "silent" }
        let side: String
        switch s.sideChainResult {
        case nil: side = "no pull block from host"
        case noErr?: side = "connected, \(db(s.sideChainLevel))"
        case let err?: side = "not connected (\(err))"
        }
        let message = "Side Chain bus 1: \(side); input bus 0: \(db(s.trackLevel)); Bass Follow hears: "
            + ["nothing", "Side Chain", "input bus 0"][s.source.rawValue]
            + (s.hostBuffers ? "; host supplies input buffers" : "")
        let key = "\(s.sideChainResult.map { Int($0) } ?? Self.noPullBlock) \(s.sideChainLevel > 0.0001) "
            + "\(s.trackLevel > 0.0001) \(s.source.rawValue) \(s.hostBuffers)"
        return (key, message)
    }

    // MARK: State

    private let songKey = "pedalbeat.songKey"
    private let importsKey = "pedalbeat.imports"
    private let kitKey = "pedalbeat.kitID"

    public override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            if let s = library.song(at: engine.songParam.value) {
                state[songKey] = s.key
                // The user library lives on disk; the project only carries the song it uses
                // (and the percussion layers that play with it).
                if s.isUser {
                    state[importsKey] = library.importsPropertyList(forKey: s.key) + library.percussionPropertyList(for: s)
                }
            }
            if let k = kits.installed(at: Int(engine.parameter(.kit))) { state[kitKey] = k.id }
            return state
        }
        set {
            super.fullState = newValue
            guard let s = newValue else { return }
            if let imports = s[importsKey] as? [[String: Any]] { library.restoreImports(imports) }
            if let key = s[songKey] as? String, let idx = library.index(forKey: key) {
                parameter(.song)?.value = Float(idx)
            }
            // Sample kits are referenced by id: indices change as kits are added or removed.
            if let id = s[kitKey] as? String {
                parameter(.kit)?.value = Float(kits.index(forID: id) ?? 0)
            } else if Int(engine.parameter(.kit)) >= Kits.all.count {
                parameter(.kit)?.value = 0
            }
        }
    }

    // MARK: Render

    public override var internalRenderBlock: AUInternalRenderBlock {
        let engine = self.engine
        unowned(unsafe) let au = self
        return { _, timestamp, frameCount, busNumber, outputData, eventList, pullInput in
            let frames = Int(frameCount)
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            guard abl.count >= 1, frames <= engine.maxFrames else { return kAudioUnitErr_TooManyFramesToProcess }

            let start = timestamp.pointee.mSampleTime
            let fresh = engine.isNewRenderCycle(sampleTime: start, frames: frames)
            // Logic Music Effect often uses one interleaved stereo buffer (abl.count == 1).
            let interleaved = abl.count == 1 && abl[0].mNumberChannels >= 2
            if !interleaved {
                if abl[0].mData == nil { abl[0].mData = UnsafeMutableRawPointer(engine.scratchL) }
                if abl.count > 1 && abl[1].mData == nil { abl[1].mData = UnsafeMutableRawPointer(engine.scratchR) }
            }
            guard let hostRaw = abl[0].mData else { return noErr }
            let hostL = hostRaw.assumingMemoryBound(to: Float.self)
            let hostR: UnsafeMutablePointer<Float>? = abl.count > 1
                ? abl[1].mData.map { $0.assumingMemoryBound(to: Float.self) } : nil

            if busNumber == 0 {
                au.captureInputs(frames: frames, timestamp: timestamp, pullInput: pullInput)
            }

            if fresh {
                engine.beginRender()
                var ev = eventList
                while let e = ev {
                    switch e.pointee.head.eventType {
                    case .MIDI, .midiSysEx:
                        let m = e.pointee.MIDI
                        if m.length >= 1 {
                            let off = max(0, min(frames - 1, Int(Double(m.eventSampleTime) - start)))
                            engine.handleMIDI(m.data.0, m.length > 1 ? m.data.1 : 0, m.length > 2 ? m.data.2 : 0, offset: off)
                        }
                    case .parameter, .parameterRamp:
                        let p = e.pointee.parameter
                        if let a = ParamAddress(rawValue: p.parameterAddress) { engine.setParameter(a, p.value) }
                    default: break
                    }
                    ev = UnsafePointer(e.pointee.head.next)
                }
            }

            var hostTempo: Double?
            if let ctx = au.musicalContextBlock {
                var bpm = 0.0
                if ctx(&bpm, nil, nil, nil, nil, nil), bpm > 0 { hostTempo = bpm }
            }
            var hostPlaying: Bool?
            if let tb = au.transportStateBlock {
                var flags = AUHostTransportStateFlags()
                if tb(&flags, nil, nil, nil) { hostPlaying = flags.contains(.moving) }
            }

            let mixTrack = busNumber == 0 && au.guitarOnMainInput && au.trackPulledThisCycle
            if interleaved {
                // Render planar into scratch, mix track audio, then pack LRLR into the host buffer.
                engine.renderBus(Int(busNumber), frames: frames, left: engine.scratchL, right: engine.scratchR,
                                 sampleTime: start, hostTempo: hostTempo, hostPlaying: hostPlaying)
                if mixTrack, let tL = au.trackL, let tR = au.trackR {
                    for i in 0..<frames {
                        engine.scratchL[i] += tL[i]
                        engine.scratchR[i] += tR[i]
                    }
                }
                for i in 0..<frames {
                    hostL[i * 2] = engine.scratchL[i]
                    hostL[i * 2 + 1] = engine.scratchR[i]
                }
            } else if let hr = hostR {
                engine.renderBus(Int(busNumber), frames: frames, left: hostL, right: hr,
                                 sampleTime: start, hostTempo: hostTempo, hostPlaying: hostPlaying)
                if mixTrack, let tL = au.trackL, let tR = au.trackR {
                    for i in 0..<frames {
                        hostL[i] += tL[i]
                        hr[i] += tR[i]
                    }
                }
            } else {
                engine.renderBus(Int(busNumber), frames: frames, left: engine.scratchL, right: engine.scratchR,
                                 sampleTime: start, hostTempo: hostTempo, hostPlaying: hostPlaying)
                if mixTrack, let tL = au.trackL, let tR = au.trackR {
                    for i in 0..<frames {
                        engine.scratchL[i] += tL[i]
                        engine.scratchR[i] += tR[i]
                    }
                }
                for i in 0..<frames { hostL[i] = 0.5 * (engine.scratchL[i] + engine.scratchR[i]) }
            }

            if fresh, let out = au.midiOutputEventBlock {
                let lastFrame = frames - 1
                engine.forEachClockEvent { offset, b0, b1, b2, length in
                    var bytes: (UInt8, UInt8, UInt8) = (b0, b1, b2)
                    withUnsafeBytes(of: &bytes) { raw in
                        _ = out(AUEventSampleTime(start) + AUEventSampleTime(min(offset, lastFrame)), 0, length,
                                raw.bindMemory(to: UInt8.self).baseAddress!)
                    }
                }
                engine.forEachOutputEvent { offset, note, vel in
                    var on: (UInt8, UInt8, UInt8) = (0x99, note, vel)
                    withUnsafeBytes(of: &on) { raw in
                        _ = out(AUEventSampleTime(start) + AUEventSampleTime(min(offset, lastFrame)), 0, 3,
                                raw.bindMemory(to: UInt8.self).baseAddress!)
                    }
                    var off: (UInt8, UInt8, UInt8) = (0x89, note, 0)
                    withUnsafeBytes(of: &off) { raw in
                        _ = out(AUEventSampleTime(start) + AUEventSampleTime(lastFrame), 0, 3,
                                raw.bindMemory(to: UInt8.self).baseAddress!)
                    }
                }
                engine.forEachBassOutputEvent { offset, note, vel in
                    var msg: (UInt8, UInt8, UInt8) = vel > 0 ? (0x91, note, vel) : (0x81, note, 0)
                    withUnsafeBytes(of: &msg) { raw in
                        _ = out(AUEventSampleTime(start) + AUEventSampleTime(min(offset, lastFrame)), 0, 3,
                                raw.bindMemory(to: UInt8.self).baseAddress!)
                    }
                }
            }
            return noErr
        }
    }
}
