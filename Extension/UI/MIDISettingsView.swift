import CoreMIDI
import SwiftUI
#if os(iOS)
import CoreAudioKit
#endif

/// MIDI Settings: the user's mappings, and the MIDI that reaches the engine. Learn takes the
/// next press from there, so it works wherever the host routes MIDI to PedalBeat.
@MainActor
final class MIDISettingsModel: ObservableObject {
    let engine: DrumEngine
    @Published var mappings = MIDIMappings.load() {
        didSet { if mappings != oldValue { mappings.save() } }
    }
    /// The action waiting for a press.
    @Published var learning: MIDIAction? {
        didSet { engine.midiMonitor.isLearning = learning != nil }
    }
    @Published private(set) var lastMessage: String?
    private var timer: Timer?

    init(engine: DrumEngine) { self.engine = engine }

    func start() {
        guard timer == nil else { return }
        // PedalBeat in another app may have saved new mappings since this one loaded them.
        engine.setMIDIMappings(mappings)
        engine.midiMonitor.isListening = true
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.receive()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        learning = nil
        engine.midiMonitor.isListening = false
        timer?.invalidate()
        timer = nil
    }

    func resetToDefaults() {
        learning = nil
        mappings = .default
    }

    private func receive() {
        for message in engine.midiMonitor.drain() {
            lastMessage = message.summary
            if let action = learning,
               let trigger = MIDITrigger(status: message.status, data1: message.data1, data2: message.data2) {
                mappings.assign(trigger, to: action)
                learning = nil
            }
        }
    }
}

/// CoreMIDI's sources (USB, Bluetooth, network, other apps), listed in MIDI Settings.
@MainActor
final class MIDIDevices: ObservableObject {
    static let shared = MIDIDevices()
    @Published private(set) var names: [String] = []
    private var client = MIDIClientRef()

    /// The client lives as long as the process: disposing CoreMIDI's last client can stop its server.
    func start() {
        if client == 0 {
            MIDIClientCreateWithBlock("PedalBeat MIDI Settings" as CFString, &client) { notification in
                guard notification.pointee.messageID == .msgSetupChanged else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { MIDIDevices.shared.refresh() } }
            }
        }
        refresh()
    }

    private func refresh() {
        names = (0..<MIDIGetNumberOfSources()).compactMap { i in
            var name: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(MIDIGetSource(i), kMIDIPropertyDisplayName, &name) == noErr else { return nil }
            return name?.takeRetainedValue() as String?
        }
    }
}

/// MIDI Settings: assign a pedal, key or button to each action by pressing it.
struct MIDISettingsView: View {
    @StateObject private var midi: MIDISettingsModel
    @ObservedObject private var devices = MIDIDevices.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingProgramChangeInfo = false
    @State private var showingBluetooth = false

    init(engine: DrumEngine) {
        _midi = StateObject(wrappedValue: MIDISettingsModel(engine: engine))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MIDI Settings").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .top], 20)
            Form {
                Section {
                    ForEach(MIDIAction.allCases) { actionRow($0) }
                    Toggle(isOn: $midi.mappings.programChangeSelectsSong) {
                        HStack(spacing: 6) {
                            Text("Program Change Selects Song")
                            Button { showingProgramChangeInfo = true } label: { Image(systemName: "info.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("About Program Change Selects Song")
                                .popover(isPresented: $showingProgramChangeInfo) {
                                    ProgramChangeInfo().presentationCompactAdaptation(.popover)
                                }
                        }
                    }
                } header: {
                    Text("Actions")
                } footer: {
                    Text("Tap Learn, then press the pedal, key or button you want to use: a Note, Control Change or Program Change on any channel. That press only makes the assignment; it doesn't trigger anything. A note you assign no longer plays its drum. Swipe a row to clear it (right-click on a Mac).")
                }

                Section {
                    if devices.names.isEmpty {
                        Text("No MIDI devices connected").foregroundStyle(Theme.dim)
                    } else {
                        ForEach(Array(devices.names.enumerated()), id: \.offset) { Text($0.element) }
                    }
                    #if os(iOS)
                    if !ProcessInfo.processInfo.isiOSAppOnMac {
                        Button("Connect Bluetooth MIDI Device") { showingBluetooth = true }
                    }
                    #endif
                    LabeledContent("Last Received", value: midi.lastMessage ?? "Nothing yet")
                } header: {
                    Text("Devices")
                } footer: {
                    Text("PedalBeat responds to the MIDI that reaches the plugin. In Loopy Pro, AUM or a DAW, route your controller to PedalBeat; the PedalBeat app listens to every device.")
                }

                Section {
                    Button("Reset to Defaults") { midi.resetToDefaults() }
                        .disabled(midi.mappings == .default)
                } footer: {
                    Text("Notes 0–9, as listed in Help.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onAppear { midi.start(); devices.start() }
        .onDisappear { midi.stop() }
        #if os(iOS)
        .sheet(isPresented: $showingBluetooth) { BluetoothMIDISheet() }
        #endif
    }

    private func actionRow(_ action: MIDIAction) -> some View {
        HStack {
            Text(action.title)
            Spacer()
            if midi.learning == action {
                Text("Press a pedal or key…").foregroundStyle(Theme.accent)
            } else {
                Text(midi.mappings.triggers[action]?.title ?? "Not set").foregroundStyle(Theme.dim)
            }
            Button(midi.learning == action ? "Cancel" : "Learn") {
                midi.learning = midi.learning == action ? nil : action
            }
            .buttonStyle(.bordered)
        }
        .swipeActions { clearButton(action) }
        .contextMenu { clearButton(action) }
    }

    @ViewBuilder private func clearButton(_ action: MIDIAction) -> some View {
        if midi.mappings.triggers[action] != nil {
            Button("Clear", role: .destructive) { midi.mappings.triggers[action] = nil }
        }
    }
}

/// What Program Change Selects Song is for, behind the ⓘ next to the switch.
private struct ProgramChangeInfo: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Program Change Selects Song").font(.headline)
                Text("Jump straight to a song: Program Change 0 selects the first song in PedalBeat's list, 1 the second, and so on. While a song plays, the new one takes over at the next bar.")
                Text("Turn it off if your controller or Loopy Pro sends Program Changes for something else, such as plugin presets — otherwise songs change unexpectedly. A Program Change you assign to an action with Learn always does that action.")
                Text("Many devices count from 1: their \"Program 1\" arrives as Program Change 0. Last Received shows what really arrives.")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding()
        }
        .frame(idealWidth: 340, idealHeight: 380)
    }
}

#if os(iOS)
/// The system screen for pairing Bluetooth LE MIDI devices.
private struct BluetoothMIDISheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BluetoothMIDIView()
                .navigationTitle("Bluetooth MIDI")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .preferredColorScheme(.dark)
    }
}

private struct BluetoothMIDIView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CABTMIDICentralViewController { CABTMIDICentralViewController() }
    func updateUIViewController(_ controller: CABTMIDICentralViewController, context: Context) {}
}
#endif
