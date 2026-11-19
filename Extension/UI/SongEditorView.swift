import SwiftUI
import UniformTypeIdentifiers

/// Editable copy of an imported song's layout (which file plays where).
@MainActor
final class SongEditor: ObservableObject, Identifiable {
    enum Slot { case intro, transition, outro }

    let id = UUID()
    let key: String
    let files: [SongLibrary.FileInfo]
    let automatic: MIDISongImporter.SongLayout?
    @Published var name: String
    @Published var layout: MIDISongImporter.SongLayout
    @Published var previewingFile: String?
    weak var model: PedalViewModel?

    init(key: String, name: String, layout: MIDISongImporter.SongLayout, files: [SongLibrary.FileInfo],
         automatic: MIDISongImporter.SongLayout?) {
        self.key = key; self.name = name; self.layout = layout; self.files = files; self.automatic = automatic
    }

    var usedNames: Set<String> {
        var s = Set(layout.parts.flatMap { [$0.main] + $0.fills })
        for n in [layout.intro, layout.transition, layout.outro] { if let n { s.insert(n) } }
        return s
    }
    func info(_ name: String) -> SongLibrary.FileInfo? { files.first { $0.name == name } }
    var canSave: Bool { !layout.parts.isEmpty }

    func set(_ slot: Slot, _ name: String?) {
        switch slot {
        case .intro: layout.intro = name
        case .transition: layout.transition = name
        case .outro: layout.outro = name
        }
    }
    func value(_ slot: Slot) -> String? {
        switch slot {
        case .intro: layout.intro
        case .transition: layout.transition
        case .outro: layout.outro
        }
    }

    func addPart(_ main: String) {
        guard layout.parts.count < SongStore.maxParts else { return }
        layout.parts.append(.init(main: main))
    }
    func removePart(_ i: Int) { if layout.parts.indices.contains(i) { layout.parts.remove(at: i) } }
    func movePart(_ i: Int, by d: Int) {
        let j = i + d
        guard layout.parts.indices.contains(i), layout.parts.indices.contains(j) else { return }
        layout.parts.swapAt(i, j)
    }
    func setMain(_ i: Int, _ name: String) { if layout.parts.indices.contains(i) { layout.parts[i].main = name } }
    func addFill(_ i: Int, _ name: String) {
        guard layout.parts.indices.contains(i), layout.parts[i].fills.count < SongStore.maxFills,
              !layout.parts[i].fills.contains(name) else { return }
        layout.parts[i].fills.append(name)
    }
    func removeFill(_ i: Int, _ k: Int) {
        if layout.parts.indices.contains(i), layout.parts[i].fills.indices.contains(k) { layout.parts[i].fills.remove(at: k) }
    }
    func moveFill(_ i: Int, _ k: Int, by d: Int) {
        guard layout.parts.indices.contains(i) else { return }
        let j = k + d
        guard layout.parts[i].fills.indices.contains(k), layout.parts[i].fills.indices.contains(j) else { return }
        layout.parts[i].fills.swapAt(k, j)
    }
    /// Takes a file out of every slot (a part whose groove it was is removed).
    func removeEverywhere(_ name: String) {
        if layout.intro == name { layout.intro = nil }
        if layout.transition == name { layout.transition = nil }
        if layout.outro == name { layout.outro = nil }
        layout.parts.removeAll { $0.main == name }
        for i in layout.parts.indices { layout.parts[i].fills.removeAll { $0 == name } }
    }
    func resetToAutomatic() { if let a = automatic { layout = a } }
}

struct SongEditorView: View {
    @ObservedObject var editor: SongEditor
    @ObservedObject var model: PedalViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Edit Song").font(.title2.bold())
                TextField("Song name", text: $editor.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Spacer()
                Button("Reset to Automatic") { editor.resetToAutomatic() }
                    .disabled(editor.automatic == nil || editor.automatic == editor.layout)
                    .help("Lay the song out again from the file names")
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { model.saveSongEditor(editor) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!editor.canSave)
            }
            if model.au.library.hasFactoryOriginal(key: editor.key) {
                Text("Factory song: saving replaces it in the list with your version. Right-click the song and choose Revert to Factory Version to get the original back.")
                    .font(.caption).foregroundStyle(Theme.accent)
            }
            Text("Press ▶ to listen to a file with the current kit and tempo (grooves loop, fills play once). Drag files from the list onto a slot, or use the menus. A file can be used in several places. Drag a file back onto the list to take it out of the song. Empty slots and parts without fills are generated automatically.")
                .font(.caption).foregroundStyle(Theme.dim)

            HStack(alignment: .top, spacing: 12) {
                FileList(editor: editor)
                    .frame(width: 250)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        SlotRow(editor: editor, title: "Intro", slot: .intro, placeholder: "Automatic count-in")
                        ForEach(Array(editor.layout.parts.enumerated()), id: \.offset) { i, _ in
                            PartCard(editor: editor, index: i)
                        }
                        NewPartZone(editor: editor)
                        SlotRow(editor: editor, title: "Transition", slot: .transition, placeholder: "Automatic (from part 1)")
                        SlotRow(editor: editor, title: "Ending", slot: .outro, placeholder: "Automatic ending")
                        HStack(spacing: 18) {
                            Toggle("Crash after intro", isOn: Binding(
                                get: { editor.layout.effectiveIntroCrash }, set: { editor.layout.introCrash = $0 }))
                            Toggle("Crash after fills", isOn: Binding(
                                get: { editor.layout.effectiveFillCrash }, set: { editor.layout.fillCrash = $0 }))
                        }
                        .font(.caption)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .padding(.horizontal, 8)
                    }
                    .padding(.trailing, 4)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 540)
        .onDisappear { model.closeSongEditor(editor) }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Pieces

private struct FileList: View {
    @ObservedObject var editor: SongEditor
    @State private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Files").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(editor.files) { f in
                        let used = editor.usedNames.contains(f.name)
                        HStack(spacing: 6) {
                            Image(systemName: used ? "checkmark.circle.fill" : "circle")
                                .font(.caption).foregroundStyle(used ? Theme.accent : Theme.dim)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(.callout).lineLimit(1)
                                Text("\(f.role) · \(f.bars) bar\(f.bars == 1 ? "" : "s") · \(f.signature)")
                                    .font(.caption2).foregroundStyle(Theme.dim)
                            }
                            Spacer(minLength: 0)
                            PreviewButton(editor: editor, name: f.name)
                        }
                        .padding(6)
                        .background(Theme.panelHi.opacity(used ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 6))
                        .draggable(f.name)
                    }
                }
            }
        }
        .padding(8)
        .background(targeted ? Theme.accent.opacity(0.15) : Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: String.self) { items, _ in
            items.forEach { editor.removeEverywhere($0) }
            return !items.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

/// ▶ / ■ audition button with a progress ring. Grooves loop; fills, intros, endings play once.
private struct PreviewButton: View {
    @ObservedObject var editor: SongEditor
    let name: String
    var size: CGFloat = 22
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let status = editor.model?.engine.status
            let active = editor.previewingFile == name && status?.previewing == true
            Button {
                if active { editor.model?.stopPreview(editor) } else { editor.model?.previewFile(editor, name) }
            } label: {
                ZStack {
                    Circle().stroke(Theme.dim.opacity(0.4), lineWidth: 1.5)
                    if active {
                        Circle().trim(from: 0, to: max(0.02, status?.previewProgress ?? 0))
                            .stroke(Theme.accent, lineWidth: 2)
                            .rotationEffect(.degrees(-90))
                    }
                    Image(systemName: active ? "stop.fill" : "play.fill")
                        .font(.system(size: size * 0.4))
                        .offset(x: active ? 0 : size * 0.04)
                }
                .frame(width: size, height: size)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(active ? Theme.accent : .white)
            .help(active ? "Stop" : "Listen (current kit and tempo)")
        }
    }
}

/// A file shown inside a slot: draggable, with a menu to replace and a button to remove.
private struct FileChip: View {
    @ObservedObject var editor: SongEditor
    let name: String
    var onRemove: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            PreviewButton(editor: editor, name: name, size: 16)
            Text(name).lineLimit(1)
            if let i = editor.info(name) { Text("\(i.bars)b").foregroundStyle(Theme.dim) }
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(Theme.dim)
                .help("Remove")
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.panelHi, in: Capsule())
        .draggable(name)
    }
}

private struct FileMenu: View {
    @ObservedObject var editor: SongEditor
    let title: String
    let systemImage: String
    var onPick: (String) -> Void
    var body: some View {
        Menu {
            ForEach(editor.files) { f in
                Button("\(f.name)  (\(f.role), \(f.bars) bar\(f.bars == 1 ? "" : "s"))") { onPick(f.name) }
            }
        } label: { Label(title, systemImage: systemImage).font(.caption) }
        .menuStyle(.button)
        .fixedSize()
    }
}

private struct DropBox<Content: View>: View {
    var onDrop: (String) -> Void
    @ViewBuilder var content: Content
    @State private var targeted = false
    var body: some View {
        content
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(targeted ? Theme.accent.opacity(0.18) : Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(targeted ? Theme.accent : .clear, lineWidth: 1.5))
            .dropDestination(for: String.self) { items, _ in
                items.forEach(onDrop)
                return !items.isEmpty
            } isTargeted: { targeted = $0 }
    }
}

private struct SlotRow: View {
    @ObservedObject var editor: SongEditor
    let title: String
    let slot: SongEditor.Slot
    let placeholder: String
    var body: some View {
        DropBox(onDrop: { editor.set(slot, $0) }) {
            HStack(spacing: 8) {
                Text(title).font(.headline).frame(width: 90, alignment: .leading)
                if let v = editor.value(slot) {
                    FileChip(editor: editor, name: v) { editor.set(slot, nil) }
                } else {
                    Text(placeholder).font(.caption).foregroundStyle(Theme.dim)
                }
                Spacer()
                FileMenu(editor: editor, title: "Choose", systemImage: "doc.badge.plus") { editor.set(slot, $0) }
            }
        }
    }
}

private struct PartCard: View {
    @ObservedObject var editor: SongEditor
    let index: Int
    var body: some View {
        let part = editor.layout.parts[index]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Part \(index + 1)").font(.headline)
                Spacer()
                Button { editor.movePart(index, by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0).help("Move up")
                Button { editor.movePart(index, by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == editor.layout.parts.count - 1).help("Move down")
                Button(role: .destructive) { editor.removePart(index) } label: { Image(systemName: "trash") }
                    .help("Remove part")
            }
            .buttonStyle(.borderless)

            DropBox(onDrop: { editor.setMain(index, $0) }) {
                HStack(spacing: 8) {
                    Text("Groove").font(.subheadline).frame(width: 60, alignment: .leading)
                    FileChip(editor: editor, name: part.main) { editor.removePart(index) }
                    Spacer()
                    FileMenu(editor: editor, title: "Replace", systemImage: "arrow.triangle.2.circlepath") { editor.setMain(index, $0) }
                }
            }
            DropBox(onDrop: { editor.addFill(index, $0) }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Fills").font(.subheadline).frame(width: 60, alignment: .leading)
                        Text("\(part.fills.count)/\(SongStore.maxFills)").font(.caption).foregroundStyle(Theme.dim)
                        if part.fills.isEmpty { Text("Automatic fill").font(.caption).foregroundStyle(Theme.dim) }
                        Spacer()
                        FileMenu(editor: editor, title: "Add Fill", systemImage: "plus") { editor.addFill(index, $0) }
                            .disabled(part.fills.count >= SongStore.maxFills)
                    }
                    if !part.fills.isEmpty {
                        FlowRow(spacing: 6) {
                            ForEach(Array(part.fills.enumerated()), id: \.offset) { k, f in
                                HStack(spacing: 2) {
                                    Text("\(k + 1)").font(.caption2.bold()).foregroundStyle(Theme.accent)
                                    FileChip(editor: editor, name: f) { editor.removeFill(index, k) }
                                        .contextMenu {
                                            Button("Play earlier") { editor.moveFill(index, k, by: -1) }.disabled(k == 0)
                                            Button("Play later") { editor.moveFill(index, k, by: 1) }.disabled(k == part.fills.count - 1)
                                        }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Theme.panelHi.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct NewPartZone: View {
    @ObservedObject var editor: SongEditor
    var body: some View {
        let full = editor.layout.parts.count >= SongStore.maxParts
        DropBox(onDrop: { editor.addPart($0) }) {
            HStack {
                Image(systemName: "plus.rectangle.on.rectangle").foregroundStyle(Theme.dim)
                Text(full ? "A song has at most \(SongStore.maxParts) parts" : "Drop a groove here to add a part")
                    .font(.caption).foregroundStyle(Theme.dim)
                Spacer()
                FileMenu(editor: editor, title: "Add Part", systemImage: "plus") { editor.addPart($0) }
                    .disabled(full)
            }
        }
    }
}

/// Simple wrapping row for fill chips.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); widest = max(widest, x)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
