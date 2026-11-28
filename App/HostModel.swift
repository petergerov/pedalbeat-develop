import AVFoundation
import AudioToolbox
import CoreAudioKit
import CoreMIDI
import SwiftUI

/// The audio unit's UI as delivered by `requestViewController`. When the extension runs out of
/// process this is a remote view controller, not an `AUViewController`, so keep the base type.
#if os(macOS)
typealias HostViewController = NSViewController
#else
typealias HostViewController = UIViewController
#endif

/// One insert slot in the standalone host (macOS). Plugins are real AU / AUv3 effects
/// loaded out-of-process after PedalBeat’s master output.
struct InsertSlot: Identifiable {
    let id: Int
    var name: String = "Empty"
    var manufacturer: String = ""
    var component: AVAudioUnitComponent?
}

/// Standalone host: loads the PedalBeat AUv3 into an AVAudioEngine, shows its UI
/// and forwards hardware MIDI (e.g. footswitch controllers) to it.
@MainActor
final class HostModel: ObservableObject {
    @Published var viewController: HostViewController?
    @Published var message = "Loading PedalBeat…"
    @Published var midiSources: [String] = []
    @Published var inserts: [InsertSlot] = [InsertSlot(id: 0), InsertSlot(id: 1)]
    @Published var availableEffects: [AVAudioUnitComponent] = []
    @Published var pluginError: String?

    private let engine = AVAudioEngine()
    private var unit: AVAudioUnit?
    private var insertUnits: [Int: AVAudioUnit] = [:]
    private var midiClient = MIDIClientRef()
    private var midiPort = MIDIPortRef()
    private var attempts = 0

    static let description = AudioComponentDescription(
        componentType: kAudioUnitType_MusicDevice,
        componentSubType: fourCC("pdbt"),
        componentManufacturer: fourCC("PdBt"),
        componentFlags: 0, componentFlagsMask: 0)

    func load() {
        guard unit == nil else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        refreshEffectList()
        AVAudioUnit.instantiate(with: Self.description, options: []) { [weak self] avUnit, error in
            Task { @MainActor in self?.didInstantiate(avUnit, error) }
        }
    }

    private func didInstantiate(_ avUnit: AVAudioUnit?, _ error: Error?) {
        guard let avUnit else {
            attempts += 1
            if attempts < 5 {
                // The extension may still be registering on first launch.
                message = "Registering audio unit… (\(attempts))"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.load() }
            } else {
                message = "Couldn't load the PedalBeat audio unit: \(error?.localizedDescription ?? "not found")"
            }
            return
        }
        unit = avUnit
        engine.attach(avUnit)
        rebuildGraph()
        do {
            try engine.start()
        } catch {
            message = "Audio engine failed to start: \(error.localizedDescription)"
        }
        avUnit.auAudioUnit.requestViewController { [weak self] vc in
            Task { @MainActor in
                self?.viewController = vc
                if vc == nil { self?.message = "The audio unit has no user interface." }
            }
        }
        setupMIDI(avUnit.auAudioUnit)
    }

    // MARK: AU / AUv3 inserts (standalone host only)

    func refreshEffectList() {
        let mgr = AVAudioUnitComponentManager.shared()
        var list: [AVAudioUnitComponent] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            var desc = AudioComponentDescription()
            desc.componentType = type
            desc.componentSubType = 0
            desc.componentManufacturer = 0
            desc.componentFlags = 0
            desc.componentFlagsMask = 0
            list += mgr.components(matching: desc)
        }
        // Prefer out-of-process-capable units; keep Apple + third-party.
        availableEffects = list
            .filter { !$0.name.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func setInsert(slot: Int, component: AVAudioUnitComponent?) {
        guard inserts.indices.contains(slot) else { return }
        pluginError = nil
        // Tear down previous unit in this slot.
        if let old = insertUnits[slot] {
            engine.disconnectNodeOutput(old)
            engine.detach(old)
            insertUnits[slot] = nil
        }
        inserts[slot].component = component
        inserts[slot].name = component?.name ?? "Empty"
        inserts[slot].manufacturer = component?.manufacturerName ?? ""
        guard let component else {
            rebuildGraph()
            return
        }
        AVAudioUnit.instantiate(with: component.audioComponentDescription, options: .loadOutOfProcess) { [weak self] avUnit, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.pluginError = "\(component.name): \(error.localizedDescription)"
                    self.inserts[slot].component = nil
                    self.inserts[slot].name = "Empty"
                    self.inserts[slot].manufacturer = ""
                    self.rebuildGraph()
                    return
                }
                guard let avUnit else {
                    self.pluginError = "Couldn’t instantiate \(component.name)."
                    self.rebuildGraph()
                    return
                }
                self.engine.attach(avUnit)
                self.insertUnits[slot] = avUnit
                self.rebuildGraph()
            }
        }
    }

    func clearInsert(slot: Int) { setInsert(slot: slot, component: nil) }

    /// PedalBeat → insert0 → insert1 → mainMixer → output
    private func rebuildGraph() {
        guard let unit else { return }
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }

        engine.disconnectNodeOutput(unit)
        for (_, u) in insertUnits { engine.disconnectNodeOutput(u) }

        let format = engine.outputNode.inputFormat(forBus: 0)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)
            ?? AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)

        var chain: AVAudioNode = unit
        for slot in inserts.indices {
            if let fx = insertUnits[slot] {
                engine.connect(chain, to: fx, format: stereo)
                chain = fx
            }
        }
        engine.connect(chain, to: engine.mainMixerNode, format: stereo)

        if wasRunning {
            do { try engine.start() }
            catch { pluginError = error.localizedDescription }
        }
    }

    // MARK: Hardware MIDI → AU

    private func setupMIDI(_ au: AUAudioUnit) {
        guard let schedule = au.scheduleMIDIEventBlock else { return }
        var client = MIDIClientRef()
        let status = MIDIClientCreateWithBlock("PedalBeat Host" as CFString, &client) { [weak self] _ in
            Task { @MainActor in self?.connectAllSources() }
        }
        guard status == noErr else { return }
        midiClient = client
        var port = MIDIPortRef()
        MIDIInputPortCreateWithProtocol(client, "Input" as CFString, ._1_0, &port) { eventList, _ in
            for packet in eventList.unsafeSequence() {
                let words = MIDIEventPacket.WordCollection(packet)
                for word in words {
                    // MIDI 1.0 channel voice message in a UMP word (message type 0x2).
                    guard word >> 28 == 0x2 else { continue }
                    var bytes: (UInt8, UInt8, UInt8) = (UInt8(word >> 16 & 0xFF), UInt8(word >> 8 & 0xFF), UInt8(word & 0xFF))
                    withUnsafeBytes(of: &bytes) { raw in
                        schedule(AUEventSampleTimeImmediate, 0, 3, raw.bindMemory(to: UInt8.self).baseAddress!)
                    }
                }
            }
        }
        midiPort = port
        connectAllSources()
    }

    private func connectAllSources() {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(midiPort, src, nil)
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name) == noErr, let n = name?.takeRetainedValue() {
                names.append(n as String)
            }
        }
        midiSources = names
    }
}

func fourCC(_ s: String) -> FourCharCode {
    s.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
}
