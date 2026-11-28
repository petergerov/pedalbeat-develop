import SwiftUI
import CoreAudioKit
import AVFoundation

@main
struct PedalBeatApp: App {
    @StateObject private var host = HostModel()

    var body: some Scene {
        WindowGroup {
            ContentView(host: host)
                .onAppear { host.load() }
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 720)
        #endif
    }
}

struct ContentView: View {
    @ObservedObject var host: HostModel
    @State private var showPlugins = false

    var body: some View {
        VStack(spacing: 0) {
            if let vc = host.viewController {
                AUViewRepresentable(viewController: vc)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(host.message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Image(systemName: "pianokeys")
                Text(host.midiSources.isEmpty ? "No MIDI inputs" : "MIDI in: " + host.midiSources.joined(separator: ", "))
                    .lineLimit(1)
                Spacer()
                #if os(macOS)
                Button {
                    host.refreshEffectList()
                    showPlugins = true
                } label: {
                    Label("AU Inserts…", systemImage: "cable.connector")
                }
                .buttonStyle(.borderless)
                #endif
                Text("AUv3 in DAW · multi-outs for per-bus plugins")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(Color(red: 0.07, green: 0.075, blue: 0.085))
        .preferredColorScheme(.dark)
        #if os(macOS)
        .sheet(isPresented: $showPlugins) {
            PluginInsertsView(host: host)
        }
        #endif
        .alert("Plugin", isPresented: Binding(
            get: { host.pluginError != nil },
            set: { if !$0 { host.pluginError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(host.pluginError ?? "")
        }
    }
}

#if os(macOS)
struct PluginInsertsView: View {
    @ObservedObject var host: HostModel
    @Environment(\.dismiss) private var dismiss
    @State private var pickingSlot: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AU / AUv3 Inserts").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Standalone macOS only. Effects sit on PedalBeat’s master out (out-of-process). In Logic/Ableton use the multi-out buses and assign plugins there — nesting AUs inside the PedalBeat AUv3 appex is not supported by Apple.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(host.inserts) { slot in
                HStack {
                    Text("Insert \(slot.id + 1)")
                        .frame(width: 70, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slot.name).font(.headline)
                        if !slot.manufacturer.isEmpty {
                            Text(slot.manufacturer).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Choose…") { pickingSlot = slot.id }
                    Button("Clear", role: .destructive) { host.clearInsert(slot: slot.id) }
                        .disabled(slot.component == nil)
                }
                .padding(10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 520, height: 320)
        .sheet(item: Binding(
            get: { pickingSlot.map { SlotPick($0) } },
            set: { pickingSlot = $0?.id }
        )) { pick in
            EffectPickerView(effects: host.availableEffects) { comp in
                host.setInsert(slot: pick.id, component: comp)
                pickingSlot = nil
            } onCancel: {
                pickingSlot = nil
            }
        }
    }
}

private struct SlotPick: Identifiable {
    let id: Int
    init(_ id: Int) { self.id = id }
}

struct EffectPickerView: View {
    let effects: [AVAudioUnitComponent]
    var onPick: (AVAudioUnitComponent) -> Void
    var onCancel: () -> Void
    @State private var filter = ""

    private var filtered: [AVAudioUnitComponent] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return effects }
        return effects.filter {
            $0.name.lowercased().contains(q) || $0.manufacturerName.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Choose Effect").font(.headline)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
            }
            TextField("Filter…", text: $filter)
                .textFieldStyle(.roundedBorder)
            List(Array(filtered.enumerated()), id: \.offset) { _, c in
                Button {
                    onPick(c)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name)
                        Text(c.manufacturerName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 420, height: 480)
    }
}
#endif

#if os(macOS)
struct AUViewRepresentable: NSViewControllerRepresentable {
    let viewController: HostViewController
    func makeNSViewController(context: Context) -> HostViewController { viewController }
    func updateNSViewController(_ vc: HostViewController, context: Context) {}
}
#else
struct AUViewRepresentable: UIViewControllerRepresentable {
    let viewController: HostViewController
    func makeUIViewController(context: Context) -> HostViewController { viewController }
    func updateUIViewController(_ vc: HostViewController, context: Context) {}
}
#endif
