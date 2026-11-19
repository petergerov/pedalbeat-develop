import AudioToolbox
import AVFoundation
import CoreAudioKit

/// AUv3 instrument ('aumu'): renders the drum engine, accepts MIDI for pedal
/// control / pad playing, and sends the played drums out as MIDI.
public final class PedalBeatAudioUnit: AUAudioUnit, @unchecked Sendable {
    public let engine = DrumEngine()
    public let library: SongLibrary
    public let kits: KitManager

    private var outputBuses: [AUAudioUnitBus] = []
    private var _outputBusses: AUAudioUnitBusArray!
    private var _parameterTree: AUParameterTree!
    private var renderFrames = 4096

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        library = SongLibrary(store: engine.store)
        kits = KitManager(engine: engine)
        library.useUserLibrary(at: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PedalBeat/Library/imports.plist"))
        try super.init(componentDescription: componentDescription, options: options)

        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        outputBuses = try MixBus.allCases.map { bus in
            let b = try AUAudioUnitBus(format: format)
            b.maximumChannelCount = 2
            b.name = bus.displayName
            return b
        }
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: outputBuses)
        maximumFramesToRender = 4096
        _parameterTree = makeParameterTree()
        if let first = library.songs.first { engine.setParameter(.tempo, Float(first.tempo)) }
    }

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
            case .fillOrder: return v >= 0.5 ? "Random" : "In Order"
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
    public override var channelCapabilities: [NSNumber]? { [0, 2] }
    public override var midiOutputNames: [String] { ["Drums"] }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        renderFrames = Int(maximumFramesToRender)
        let rate = outputBuses.first?.format.sampleRate ?? 48000
        engine.prepare(sampleRate: rate, maxFrames: renderFrames)
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
                // The user library lives on disk; the project only carries the song it uses.
                if s.isUser { state[importsKey] = library.importsPropertyList(forKey: s.key) }
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
        return { _, timestamp, frameCount, busNumber, outputData, eventList, _ in
            let frames = Int(frameCount)
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            guard abl.count >= 1, frames <= engine.maxFrames else { return kAudioUnitErr_TooManyFramesToProcess }

            let start = timestamp.pointee.mSampleTime
            let fresh = engine.isNewRenderCycle(sampleTime: start, frames: frames)
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

            if abl[0].mData == nil { abl[0].mData = UnsafeMutableRawPointer(engine.scratchL) }
            if abl.count > 1 && abl[1].mData == nil { abl[1].mData = UnsafeMutableRawPointer(engine.scratchR) }
            let left = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let right = abl.count > 1 ? abl[1].mData!.assumingMemoryBound(to: Float.self) : engine.scratchR

            engine.renderBus(Int(busNumber), frames: frames, left: left, right: right,
                             sampleTime: start, hostTempo: hostTempo, hostPlaying: hostPlaying)
            if abl.count == 1 {
                for i in 0..<frames { left[i] = (left[i] + right[i]) * 0.5 }
            }

            if fresh, let out = au.midiOutputEventBlock {
                let lastFrame = frames - 1
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
            }
            return noErr
        }
    }
}
