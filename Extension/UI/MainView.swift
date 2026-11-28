import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    static let bg = Color(red: 0.07, green: 0.075, blue: 0.085)
    static let panel = Color(red: 0.12, green: 0.125, blue: 0.14)
    static let panelHi = Color(red: 0.17, green: 0.175, blue: 0.19)
    static let lcd = Color(red: 0.05, green: 0.09, blue: 0.08)
    static let lcdText = Color(red: 0.45, green: 1.0, blue: 0.72)
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.18)
    static let dim = Color.white.opacity(0.55)
}

struct MainView: View {
    @ObservedObject var model: PedalViewModel
    @State private var pendingURLs: [URL] = []
    @State private var askImportMode = false
    @State private var showHelp = false

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 720
            Group {
                if compact {
                    VStack(spacing: 10) {
                        PedalPanel(model: model, showHelp: $showHelp, onImport: { model.showImporter = true })
                        SongBrowser(model: model, onImport: { model.showImporter = true })
                    }
                } else {
                    HStack(spacing: 12) {
                        SongBrowser(model: model, onImport: { model.showImporter = true })
                            .frame(width: min(320, geo.size.width * 0.34))
                        PedalPanel(model: model, showHelp: $showHelp, onImport: { model.showImporter = true })
                    }
                }
            }
            .padding(12)
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.midi, .pedalBeatKit, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                model.importAny(urls) { pendingURLs = $0; askImportMode = true }
            }
        }
        .confirmationDialog("Import \(pendingURLs.count) MIDI files", isPresented: $askImportMode) {
            Button("One song (intro / main / fill / outro by file name)") { model.importFiles(pendingURLs, asOneSong: true) }
            Button("Each file as its own song") { model.importFiles(pendingURLs, asOneSong: false) }
            Button("Cancel", role: .cancel) {}
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDropped(providers)
            return true
        }
        .sheet(isPresented: $showHelp) { HelpView(isPresented: $showHelp) }
        .sheet(isPresented: $model.showKitManager) { KitManagerView(model: model) }
        .sheet(isPresented: $model.showMIDISettings) { MIDISettingsView(engine: model.engine) }
        .sheet(item: $model.songEditor) { SongEditorView(editor: $0, model: model) }
        .sheet(item: $model.songMixer) { SongMixerView(mixer: $0, model: model) }
        .alert(model.importMessage ?? "", isPresented: Binding(get: { model.importMessage != nil },
                                                               set: { if !$0 { model.importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, ["mid", "midi", "smf", "pbkit"].contains(url.pathExtension.lowercased())
                    || PedalViewModel.isDirectory(url) {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            model.importAny(urls) { pendingURLs = $0; askImportMode = true }
        }
    }
}

// MARK: - Song browser

struct SongBrowser: View {
    @ObservedObject var model: PedalViewModel
    var onImport: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $model.browserMode) {
                Label("Beats", systemImage: "square.grid.2x2").tag(PedalViewModel.BrowserMode.beats)
                Label("Songs", systemImage: "music.note.list").tag(PedalViewModel.BrowserMode.songs)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Beats: browse grooves by style. Songs: find a popular song and load a matching beat at its tempo.")

            switch model.browserMode {
            case .beats: BeatsTab(model: model)
            case .songs: SongsTab(model: model)
            }

            Button(action: onImport) {
                HStack(spacing: 6) {
                    if model.importing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "square.and.arrow.down") }
                    Text(model.importing ? "Importing…" : "Import MIDI, Folder or Kit…")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PanelButtonStyle())
            .disabled(model.importing)
            .help("Pick MIDI files, a whole folder (e.g. a loop pack: Pack / Style / Song / sections), a .BBS SD card folder or a .pbkit kit. You can also drag them here.")
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim)
            }
        }
        .padding(8)
        .background(Theme.panelHi, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The groove library, grouped by genre.
struct BeatsTab: View {
    @ObservedObject var model: PedalViewModel

    var body: some View {
        SearchField(prompt: "Search beats", text: $model.search)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.genres, id: \.0) { genre, songs in
                        let open = !model.search.isEmpty || model.expandedGenre == genre
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                model.expandedGenre = model.expandedGenre == genre ? nil : genre
                            }
                        } label: {
                            HStack {
                                Image(systemName: open ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.bold)).frame(width: 14)
                                GroupTitle(genre: genre, imported: model.isUserGroup(songs))
                                Spacer()
                                Text("\(songs.count)").font(.caption).foregroundStyle(Theme.dim)
                            }
                            .padding(.vertical, 7).padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if model.isUserGroup(songs) {
                                Button("Remove “\(genre)”", role: .destructive) { model.removeGroup(genre) }
                            }
                        }
                        if open {
                            ForEach(songs) { song in
                                SongRow(song: song, selected: song.id == model.selectedSong,
                                        edited: model.isEditedFactorySong(song), percussion: model.percussion(for: song))
                                    .id(song.id)
                                    .onTapGesture { model.select(song) }
                                    .contextMenu {
                                        Button("Edit Song…") { model.editSong(song) }
                                        Button("Mix Song…") { model.mixSong(song) }
                                        if model.isEditedFactorySong(song) {
                                            Button("Revert to Factory Version", role: .destructive) { model.revertToFactory(song) }
                                        } else if song.isUser {
                                            Button("Remove from list", role: .destructive) { model.remove(song) }
                                        }
                                    }
                            }
                        }
                    }
                    if model.genres.isEmpty, !model.search.isEmpty {
                        VStack(spacing: 8) {
                            Text("No beats match “\(model.search)”.").foregroundStyle(Theme.dim)
                            Button("Search songs instead") {
                                model.songSearch = model.search
                                model.browserMode = .songs
                            }
                            .buttonStyle(.plain).foregroundStyle(Theme.accent)
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity).padding(.top, 24)
                    }
                }
            }
            .onAppear { proxy.scrollTo(model.selectedSong, anchor: .center) }
        }
    }
}

/// Popular songs (song index). Tapping one loads it at the song's tempo. A song with a bb
/// version (its beat with the song's bass and percussion) and a MIDI version (its own drums) has a row
/// for each; without either, the closest factory groove plays.
struct SongsTab: View {
    @ObservedObject var model: PedalViewModel
    @State private var pickArtist = false

    var body: some View {
        let matches = model.songRows
        HStack(spacing: 6) {
            SearchField(prompt: "Song title or artist", text: $model.songSearch)
            Menu {
                Picker("Version", selection: $model.songSource) {
                    Text("bb and MIDI").tag(PedalViewModel.SongVersion?.none)
                    Text("bb only").tag(PedalViewModel.SongVersion?.some(.bb))
                    Text("MIDI only").tag(PedalViewModel.SongVersion?.some(.midi))
                }
                .pickerStyle(.inline)
                Divider()
                Button("All genres") { model.songGenre = nil }
                Divider()
                ForEach(SongIndex.genres, id: \.self) { g in
                    Button {
                        model.songGenre = g
                        if let a = model.songArtist, !SongIndex.artists(inGenre: g).contains(a) {
                            model.songArtist = nil
                        }
                    } label: {
                        if model.songGenre == g { Label(g, systemImage: "checkmark") } else { Text(g) }
                    }
                }
            } label: {
                Image(systemName: model.songGenre == nil && model.songSource == nil
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(model.songGenre == nil && model.songSource == nil ? Theme.dim : Theme.accent)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filter by version and genre")

            Button { pickArtist = true } label: {
                Image(systemName: model.songArtist == nil ? "person" : "person.fill")
                    .foregroundStyle(model.songArtist == nil ? Theme.dim : Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Filter by artist")
            .sheet(isPresented: $pickArtist) {
                ArtistFilterView(artists: model.songFilterArtists, selected: model.songArtist) { artist in
                    model.songArtist = artist
                    pickArtist = false
                }
            }
        }
        HStack {
            Text(summary(matches.count)).font(.caption).foregroundStyle(Theme.dim)
            Spacer()
            if let a = model.songArtist {
                Button { model.songArtist = nil } label: { Label(a, systemImage: "xmark").font(.caption).lineLimit(1) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            if let g = model.songGenre {
                Button { model.songGenre = nil } label: { Label(g, systemImage: "xmark").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            if let v = model.songSource {
                Button { model.songSource = nil } label: { Label(v.label, systemImage: "xmark").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 4)

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(matches) { row in
                        let r = model.resolve(row)
                        SongIndexRow(entry: row.entry, version: row.version,
                                     beatName: row.version == .bb ? row.entry.style
                                         : r?.song.name.components(separatedBy: " · ").last ?? row.entry.target.groove,
                                     percussion: r.map { model.percussion(for: $0.extras ?? $0.song) } ?? [],
                                     selected: model.loadedRow == row)
                            .id(row.id)
                            .onTapGesture { model.load(row) }
                    }
                    if matches.isEmpty {
                        Text("No songs match.").font(.callout).foregroundStyle(Theme.dim)
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    }
                }
            }
            .onAppear { if let r = model.loadedRow { proxy.scrollTo(r.id, anchor: .center) } }
        }
        if !model.hasBBSBeats {
            Text("Tip: install PedalBeat bb Songs (or import your .BBS SD card folder) to play the songs with their bb beats too. Without a version of its own, a similar PedalBeat groove plays (≈).")
                .font(.caption2).foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summary(_ n: Int) -> String {
        let filtered = !model.songSearch.isEmpty || model.songGenre != nil || model.songArtist != nil || model.songSource != nil
        return filtered ? "\(n) of \(model.songRows(filtered: false)) songs" : "\(n) songs"
    }
}

/// Pick an artist (interpret) for the Songs tab filter.
private struct ArtistFilterView: View {
    let artists: [String]
    let selected: String?
    var onPick: (String?) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var matches: [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return artists }
        return artists.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Artist").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            SearchField(prompt: "Filter artists", text: $query)
            Button {
                onPick(nil)
            } label: {
                HStack {
                    Text("All artists")
                    Spacer()
                    if selected == nil { Image(systemName: "checkmark") }
                }
                .padding(.vertical, 6).padding(.horizontal, 8)
                .background(selected == nil ? Theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(matches, id: \.self) { name in
                        Button {
                            onPick(name)
                        } label: {
                            HStack {
                                Text(name).lineLimit(1)
                                Spacer()
                                if selected == name { Image(systemName: "checkmark") }
                            }
                            .padding(.vertical, 6).padding(.horizontal, 8)
                            .background(selected == name ? Theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if matches.isEmpty {
                        Text("No artists match.").font(.callout).foregroundStyle(Theme.dim)
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 320, idealWidth: 360, minHeight: 420)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }
}

struct SongIndexRow: View {
    let entry: SongIndex.Entry
    let version: PedalViewModel.SongVersion
    /// bb: the beat; similar: the factory groove.
    let beatName: String
    /// Its percussion layers that play along.
    var percussion: [PercussionInstrument] = []
    let selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.title).lineLimit(1)
                    if !percussion.isEmpty {
                        Image(systemName: "hands.clap").font(.caption2).foregroundStyle(Theme.dim)
                            .help("With \(percussion.map { $0.name.lowercased() }.joined(separator: ", "))")
                    }
                }
                HStack(spacing: 4) {
                    if !entry.artist.isEmpty { Text(entry.artist).lineLimit(1) }
                    Text("·")
                    VersionBadge(version: version)
                    Text(version == .midi ? "original drums" : beatName)
                        .foregroundStyle(version == .similar ? Theme.dim : Theme.lcdText.opacity(0.8))
                        .lineLimit(1)
                }
                .font(.caption).foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(Int(entry.bpm))").font(.callout.monospacedDigit())
                Text("BPM").font(.system(size: 9)).foregroundStyle(Theme.dim)
            }
            .frame(width: 34, alignment: .trailing)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(selected ? Theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            if selected { RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3).padding(.vertical, 4) }
        }
        .contentShape(Rectangle())
        .help(help)
    }

    private var help: String {
        let song = "\(entry.title) — \(entry.artist)"
        switch version {
        case .bb: return "\(song): bb beat “\(beatName)” with the song's bass and percussion, at \(Int(entry.bpm)) BPM"
        case .midi: return "\(song): the song's own drums, bass and percussion from its MIDI file, at \(Int(entry.bpm)) BPM"
        case .similar: return "\(song): similar groove \(entry.target.label) at \(Int(entry.bpm)) BPM (no bb or MIDI version)"
        }
    }
}

/// Small tag for a Songs-tab row: BB (bb version), MIDI (own drums) or ≈ (similar groove).
private struct VersionBadge: View {
    let version: PedalViewModel.SongVersion
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .foregroundStyle(version == .similar ? Theme.dim : Theme.accent)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(version == .similar ? Theme.dim : Theme.accent, lineWidth: 0.5))
    }
    private var text: String {
        switch version {
        case .bb: "BB"
        case .midi: "MIDI"
        case .similar: "≈"
        }
    }
}

/// Group header: imported packs show "Pack › Style" as a small pack line above the style.
struct GroupTitle: View {
    let genre: String
    let imported: Bool
    var body: some View {
        let parts = genre.components(separatedBy: " › ")
        HStack(spacing: 6) {
            if imported { Image(systemName: "folder").font(.caption).foregroundStyle(Theme.accent) }
            if parts.count >= 2 {
                VStack(alignment: .leading, spacing: 0) {
                    Text(parts[0]).font(.caption2).foregroundStyle(Theme.dim).lineLimit(1)
                    Text(parts.dropFirst().joined(separator: " › ")).font(.headline).lineLimit(1)
                }
            } else {
                Text(genre).font(.headline).lineLimit(1)
            }
        }
    }
}

struct SongRow: View {
    let song: SongInfo
    let selected: Bool
    var edited = false
    /// Plays imported percussion layers (shaker, tambourine, clap) with its drums.
    var percussion: [PercussionInstrument] = []
    var body: some View {
        HStack(spacing: 8) {
            Text(song.name.components(separatedBy: " · ").last ?? song.name)
                .lineLimit(1)
            if edited {
                Image(systemName: "pencil").font(.caption2).foregroundStyle(Theme.accent)
                    .help("Edited version of a factory song")
            }
            if song.hasBass {
                Image(systemName: "guitars").font(.caption2).foregroundStyle(Theme.dim)
                    .help("Plays a bass line with the drums")
            }
            if !percussion.isEmpty {
                Image(systemName: "hands.clap").font(.caption2).foregroundStyle(Theme.dim)
                    .help("Plays \(percussion.map { $0.name.lowercased() }.joined(separator: ", ")) with the drums")
            }
            Spacer(minLength: 4)
            Text(song.timeSignature).font(.caption2.monospaced()).foregroundStyle(Theme.dim)
            Text("\(Int(song.tempo))").font(.caption.monospacedDigit()).foregroundStyle(Theme.dim)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.vertical, 6).padding(.leading, 26).padding(.trailing, 6)
        .background(selected ? Theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            if selected { RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3).padding(.vertical, 4) }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Pedal panel

struct PedalPanel: View {
    @ObservedObject var model: PedalViewModel
    @Binding var showHelp: Bool
    var onImport: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
                StatusDisplay(model: model, status: model.engine.status)
            }
            ControlsRow(model: model)
            HStack(alignment: .center, spacing: 16) {
                SideButtons(model: model)
                PedalButton(model: model)
                    .frame(maxWidth: 260)
                TempoBlock(model: model)
            }
            .frame(maxHeight: .infinity)
            MixRow(model: model, showHelp: $showHelp)
            BassSection(bass: model.bass)
            PercussionSection(model: model)
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StatusDisplay: View {
    @ObservedObject var model: PedalViewModel
    let status: EngineStatus

    var body: some View {
        let song = model.currentSong
        let playingSong = status.song >= 0 && status.state != .stopped ? model.au.library.song(at: status.song) : nil
        let shown = playingSong ?? song
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(shown?.name.components(separatedBy: " · ").last ?? "—")
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer()
                Text(status.state == .fill && status.fillCount > 1
                     ? "\(status.state.label) \(status.fillNumber)/\(status.fillCount)" : status.state.label)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(stateColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(stateColor)
            }
            HStack(spacing: 10) {
                if let e = model.loadedEntry, shown?.id == model.selectedSong {
                    Text("♪ \(e.title)").font(.system(size: 13, weight: .bold, design: .monospaced)).lineLimit(1)
                }
                Text(shown?.genre ?? "").font(.system(size: 13, design: .monospaced))
                Text(shown?.timeSignature ?? "").font(.system(size: 13, design: .monospaced))
                if let playingSong, playingSong.id != model.selectedSong, let next = song {
                    Text("NEXT ▸ \(next.name.components(separatedBy: " · ").last ?? "")")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                pendingBadge
            }
            .opacity(0.8)
            HStack(spacing: 6) {
                ForEach(0..<max(status.beatsPerBar, 1), id: \.self) { b in
                    let lit = status.state != .stopped && status.state != .paused && b == status.beat
                    Circle()
                        .fill(lit ? (b == 0 ? Theme.accent : Theme.lcdText) : Theme.lcdText.opacity(0.15))
                        .frame(width: 14, height: 14)
                }
                Spacer()
                if status.bassFollow {
                    Text("FOLLOW \(status.followChord)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                    let input = model.au.inputStatus
                    if status.guitarLevel > 0.02 {
                        Text(input.source == .trackInput ? "GTR · IN" : "GTR · SC")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                            .help(input.source == .trackInput
                                  ? "Bass Follow hears this track's own audio."
                                  : "Bass Follow hears the Side Chain.")
                        LevelMeter(level: status.guitarLevel).frame(width: 40, height: 8)
                    } else {
                        Text(status.state == .stopped ? "tap PEDAL · Side Chain → Guitar track" : noGuitarHint(input))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .help("Bass Follow needs guitar audio. Either put PedalBeat Drums FX on the Guitar track, or set the plugin Side Chain menu to that track (e.g. Audio 1), not to the PedalBeat track.")
                    }
                }
                if status.state != .stopped {
                    Text("BAR \(status.bar + 1)/\(max(status.barsInPattern, 1))")
                        .font(.system(size: 13, design: .monospaced))
                }
                LevelMeter(level: status.level).frame(width: 60, height: 8)
            }
            PartSelector(model: model, status: status)
        }
        .foregroundStyle(Theme.lcdText)
        .padding(14)
        .background(Theme.lcd, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.lcdText.opacity(0.18)))
    }

    private var stateColor: Color {
        switch status.state {
        case .stopped: Theme.dim
        case .paused: .yellow
        case .fill, .transition: Theme.accent
        case .outro: .pink
        default: Theme.lcdText
        }
    }

    private func noGuitarHint(_ input: InputStatus) -> String {
        switch input.sideChainResult {
        case nil: "no GTR · host sends no audio input"
        case noErr?: "no GTR · Side Chain silent"
        default: "no GTR · Side Chain → Guitar track (not this track)"
        }
    }

    @ViewBuilder private var pendingBadge: some View {
        if status.pendingOutro { Text("OUTRO QUEUED").font(.caption.monospaced().bold()).foregroundStyle(.pink) }
        else if status.pendingTransition { Text("TRANSITION QUEUED").font(.caption.monospaced().bold()).foregroundStyle(Theme.accent) }
        else if status.pendingFill { Text("FILL QUEUED").font(.caption.monospaced().bold()).foregroundStyle(Theme.accent) }
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.lcdText.opacity(0.12))
                Capsule().fill(level > 0.95 ? Color.red : Theme.lcdText)
                    .frame(width: g.size.width * CGFloat(min(level, 1)))
            }
        }
    }
}

struct PartSelector: View {
    @ObservedObject var model: PedalViewModel
    let status: EngineStatus
    var body: some View {
        let count = status.state == .stopped ? (model.currentSong?.partCount ?? 1) : max(status.partCount, 1)
        HStack(spacing: 6) {
            Text("PARTS").font(.system(size: 11, weight: .bold, design: .monospaced)).opacity(0.6)
            ForEach(0..<count, id: \.self) { i in
                let active = status.state != .stopped && status.part == i
                Button { model.gotoPart(i) } label: {
                    Text("\(i + 1)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .frame(width: 34, height: 24)
                        .background(active ? Theme.lcdText : Theme.lcdText.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(active ? Theme.lcd : Theme.lcdText)
                }
                .buttonStyle(.plain)
                .help("Transition to part \(i + 1)")
            }
            Spacer()
        }
    }
}

struct ControlsRow: View {
    @ObservedObject var model: PedalViewModel
    var body: some View {
        HStack(spacing: 8) {
            Button { model.step(-1) } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(PanelButtonStyle()).help("Previous song")
            Button { model.step(1) } label: { Image(systemName: "forward.end.fill") }
                .buttonStyle(PanelButtonStyle()).help("Next song")
            Spacer()
            if let s = model.currentSong {
                Button { model.editSong(s) } label: { Label("Edit Song", systemImage: "square.and.pencil") }
                    .buttonStyle(PanelButtonStyle())
                    .help("Choose which file plays as intro, groove, fills, transition and ending")
                Button { model.mixSong(s) } label: { Label("Mix Song", systemImage: "slider.vertical.3") }
                    .buttonStyle(PanelButtonStyle())
                    .help("Open the mixer for this song — per-voice levels, stored with the song")
            }
            KitMenu(model: model)
        }
    }
}

extension UTType {
    /// PedalBeat drum kit (.pbkit): a CAF file with an embedded kit manifest.
    static let pedalBeatKit = UTType(exportedAs: "com.pedalbeat.kit", conformingTo: .data)
}

struct KitMenu: View {
    @ObservedObject var model: PedalViewModel
    var body: some View {
        Menu {
            Section("Synthesized") {
                ForEach(0..<Kits.all.count, id: \.self) { i in kitButton(i, Kits.names[i]) }
            }
            let drumKits = model.sampleKits.filter { $0.manifest.category != "layer" }
            if !drumKits.isEmpty {
                Section("Sampled") {
                    ForEach(drumKits, id: \.id) { k in
                        if let idx = model.sampleKits.firstIndex(where: { $0.id == k.id }) {
                            kitButton(Kits.all.count + idx, k.name)
                        }
                    }
                }
            }
            Divider()
            if let s = model.currentSong {
                Button { model.mixSong(s) } label: { Label("Mix Song…", systemImage: "slider.vertical.3") }
            }
            Button { model.showImporter = true } label: { Label("Import Kit…", systemImage: "square.and.arrow.down") }
            Button { model.showKitManager = true } label: { Label("Manage Kits…", systemImage: "info.circle") }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "circle.grid.cross")
                Text(model.kitName).lineLimit(1)
                if model.kitLoading { ProgressView().controlSize(.small) }
            }
        }
        .menuStyle(.button)
        .buttonStyle(PanelButtonStyle())
        .frame(maxWidth: 200)
        .help("Drum kit. Sampled kits are imported from .pbkit files.")
    }

    private func kitButton(_ index: Int, _ name: String) -> some View {
        Button { model.selectKit(index) } label: {
            if index == model.kit { Label(name, systemImage: "checkmark") } else { Text(name) }
        }
    }
}

/// Mix Song session — mirrors `SongEditor` as the sheet identity for Mix Song.
@MainActor
final class SongMixer: Identifiable {
    let id = UUID()
    let key: String
    let name: String
    /// Drum voices the song plays (its patterns, accent crash and kick, percussion layers), in kit order.
    let voices: [Drum]
    /// The song has a bass line.
    let hasBass: Bool
    init(key: String, name: String, voices: [Drum], hasBass: Bool) {
        self.key = key; self.name = name; self.voices = voices; self.hasBass = hasBass
    }
}

/// Console mixer for one song (opened like Edit Song).
struct SongMixerView: View {
    let mixer: SongMixer
    @ObservedObject var model: PedalViewModel
    @Environment(\.dismiss) private var dismiss

    private let stripWidth: CGFloat = 78
    private let faderHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Mix Song").font(.title2.bold())
                Text(mixer.name)
                    .font(.title3)
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Spacer()
                Text(model.kitName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.panelHi, in: Capsule())
                if showsBass { BassKitMenu(bass: model.bass) }
                Button("Reset") { model.resetMixGains() }
                    .buttonStyle(PanelButtonStyle())
                    .help("All faders back to 0 dB for this song")
                Button("Done") {
                    model.songMixer = nil
                    dismiss()
                }
                .buttonStyle(PanelButtonStyle(highlight: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Theme.panel)

            Text(mixerNote)
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)

            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(Array(mixer.voices.enumerated()), id: \.element.rawValue) { i, drum in
                            let bus = MixBus.forDrum(drum)
                            if i > 0, MixBus.forDrum(mixer.voices[i - 1]) != bus {
                                Rectangle()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(width: 1, height: faderHeight + 110)
                                    .padding(.horizontal, 4)
                            }
                            MixerChannelStrip(
                                title: shortName(drum),
                                bus: bus.displayName,
                                gain: Binding(
                                    get: { model.mixGains[drum.rawValue] },
                                    set: { model.setMixGain(drum, $0) }
                                ),
                                level: Double(model.engine.channelLevel(drum)),
                                width: stripWidth,
                                faderHeight: faderHeight
                            )
                        }
                        if showsBass {
                        Rectangle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 1, height: faderHeight + 110)
                            .padding(.horizontal, 6)
                        MixerChannelStrip(
                            title: "BASS",
                            bus: MixBus.bass.displayName,
                            gain: Binding(
                                get: { model.bass.faderLevel },
                                set: { model.bass.setFaderLevel($0) }
                            ),
                            level: Double(model.engine.bassChannelLevel()),
                            width: stripWidth,
                            faderHeight: faderHeight,
                            gainRange: 0...1.5,
                            muted: model.bass.muted,
                            onMuteToggle: { model.bass.setMuted(!model.bass.muted) }
                        )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.09, green: 0.095, blue: 0.11), Color(red: 0.05, green: 0.055, blue: 0.065)],
                    startPoint: .top, endPoint: .bottom)
            )
        }
        .frame(minWidth: 980, idealWidth: 1100, minHeight: 520, idealHeight: 560)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    private var showsBass: Bool { mixer.hasBass && model.bass.isOn }

    private var mixerNote: String {
        let base = "Levels for the voices this song plays. Double-tap a fader for 0 dB. Drum levels are stored with the song. In a DAW, use PedalBeat multi-outs for real AU plugins."
        if !mixer.hasBass { return base }
        return model.bass.isOn ? base + " Bass: level, mute, meter, multi-out."
                               : base + " Bass is off in the Bass section — turn it on there to mix the bass bus."
    }

    private func shortName(_ drum: Drum) -> String {
        switch drum {
        case .kick: "KICK"
        case .snare: "SNR"
        case .rim: "RIM"
        case .clap: "CLAP"
        case .hatClosed: "HH C"
        case .hatPedal: "HH P"
        case .hatOpen: "HH O"
        case .ride: "RIDE"
        case .rideBell: "BELL"
        case .crash: "CRSH"
        case .tomHigh: "TOM H"
        case .tomMid: "TOM M"
        case .tomLow: "TOM L"
        case .cowbell: "COW"
        case .shaker: "SHAK"
        case .tambourine: "TAMB"
        case .brushSweep: "SWEEP"
        case .maracas: "MARA"
        }
    }
}

/// One mixer channel: bus tag, level meter + fader, scribble strip.
struct MixerChannelStrip: View {
    let title: String
    let bus: String
    @Binding var gain: Double
    var level: Double = 0   // 0…1 peak meter
    var width: CGFloat = 72
    var faderHeight: CGFloat = 220
    var gainRange: ClosedRange<Double> = 0...2
    var muted: Bool = false
    var onMuteToggle: (() -> Void)? = nil

    private var gainDbText: String {
        if muted || gain <= 0.0001 { return "−∞" }
        return String(format: "%+.1f", 20 * log10(gain))
    }

    private var levelDbText: String {
        if level <= 0.0005 { return "—" }
        return String(format: "%.0f", 20 * log10(max(level, 0.0001)))
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(bus)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Theme.accent.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(gainDbText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(gain > 1.01 && !muted ? Theme.accent : Color.white.opacity(0.85))
                .frame(height: 16)

            HStack(alignment: .bottom, spacing: 6) {
                ChannelLevelMeter(level: level, height: faderHeight)
                    .frame(width: 12, height: faderHeight)
                VerticalFader(value: $gain, range: gainRange, height: faderHeight)
                    .frame(width: 36, height: faderHeight)
                    .opacity(muted ? 0.45 : 1)
            }

            Text(levelDbText)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(level > 0.85 ? Color.red.opacity(0.9) : Theme.dim)
                .frame(height: 12)

            Text(muted ? "MUTE" : (abs(gain - 1) < 0.02 ? "0 dB" : "\(Int((gain * 100).rounded()))%"))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(muted ? Theme.accent : Theme.dim)

            if let onMuteToggle {
                Button(action: onMuteToggle) {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(muted ? Theme.accent : Theme.dim)
                .help(muted ? "Unmute" : "Mute")
            }

            Text(title)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.14, green: 0.145, blue: 0.16))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.06), lineWidth: 1))
        )
        .padding(.horizontal, 3)
    }
}

/// Vertical LED-style peak meter for a mixer channel (0…1).
struct ChannelLevelMeter: View {
    var level: Double
    var height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let t = min(max(level, 0), 1)
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.2, green: 0.85, blue: 0.35),
                                Color(red: 0.95, green: 0.85, blue: 0.2),
                                Color(red: 1.0, green: 0.25, blue: 0.2),
                            ],
                            startPoint: .bottom, endPoint: .top)
                    )
                    .frame(height: max(2, CGFloat(t) * h))
                    .padding(1.5)
            }
        }
        .frame(height: height)
    }
}

/// Vertical console fader (0…2 linear gain, unity at mid-ish visually mapped).
struct VerticalFader: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...2
    var height: CGFloat = 220

    private var span: Double { range.upperBound - range.lowerBound }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let t = CGFloat((value - range.lowerBound) / span) // 0…1
            let y = (1 - t) * (h - 18) // thumb top

            ZStack(alignment: .top) {
                // Slot
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 10)
                    .frame(maxHeight: .infinity)
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )

                // Fill from bottom up to unity-ish color
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent.opacity(0.3), Theme.accent],
                                startPoint: .bottom, endPoint: .top)
                        )
                        .frame(width: 6, height: max(4, t * (h - 18) + 9))
                }

                // Tick marks (unity ≈ 0.5 of 0…2 → mid)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { mark in
                    let my = (1 - mark) * (h - 18) + 9
                    Rectangle()
                        .fill(Color.white.opacity(mark == 0.5 ? 0.45 : 0.15))
                        .frame(width: mark == 0.5 ? 22 : 14, height: 1)
                        .position(x: w / 2, y: my)
                }

                // Cap / thumb
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.75), Color(white: 0.35)],
                            startPoint: .top, endPoint: .bottom)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.5), lineWidth: 0.5))
                    .frame(width: 28, height: 18)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(y: y)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let y = min(max(g.location.y - 9, 0), h - 18)
                        let nt = 1 - Double(y / (h - 18))
                        value = min(max(range.lowerBound + nt * span, range.lowerBound), range.upperBound)
                    }
            )
            .onTapGesture(count: 2) {
                value = 1 // unity
            }
        }
        .frame(height: height)
        .help("Drag to set level · double-tap for 0 dB")
    }
}

struct KitManagerView: View {
    @ObservedObject var model: PedalViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Drum Kits").font(.title2.bold())
                Spacer()
                if let s = model.currentSong {
                    Button { model.mixSong(s); dismiss() } label: { Label("Mix Song…", systemImage: "slider.vertical.3") }
                }
                Button { model.showImporter = true; dismiss() } label: { Label("Import Kit…", systemImage: "square.and.arrow.down") }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Sampled kits are .pbkit files. Import them here, from the kit menu, or by dragging them onto the plugin. They are stored with the plugin and saved projects refer to them by name.")
                .font(.callout).foregroundStyle(Theme.dim)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.sampleKits.isEmpty {
                        Text("No sampled kits installed yet. The five synthesized kits are always available.")
                            .foregroundStyle(Theme.dim).padding(.vertical, 20)
                    }
                    ForEach(model.sampleKits) { k in
                        let m = k.manifest
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(m.name).font(.headline)
                                Text(m.category.capitalized).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Theme.panelHi, in: Capsule())
                                if model.currentKit?.id == m.id { Text("In use").font(.caption).foregroundStyle(Theme.accent) }
                                Spacer()
                                if k.removable {
                                    Button(role: .destructive) { model.removeKit(k) } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless)
                                        .help("Remove this kit")
                                } else {
                                    Text("Installed").font(.caption).foregroundStyle(Theme.dim)
                                        .help("Put in place by a PedalBeat installer")
                                }
                            }
                            Text(m.author).font(.subheadline)
                            HStack(spacing: 6) {
                                Text("License: \(m.license)")
                                if let url = URL(string: m.source), !m.source.isEmpty {
                                    Link("Source", destination: url)
                                }
                                Text(String(format: "· %d drums · %.0f MB", m.drums.count, Double(m.frames * 4) / 1e6))
                            }
                            .font(.caption).foregroundStyle(Theme.dim)
                            if !m.notes.isEmpty { Text(m.notes).font(.caption).foregroundStyle(Theme.dim) }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 380)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }
}

struct SideButtons: View {
    @ObservedObject var model: PedalViewModel
    var body: some View {
        VStack(spacing: 8) {
            Button { model.send(.startStop) } label: { Label("Start / Stop", systemImage: "playpause.fill").frame(maxWidth: .infinity) }
            Button { model.send(.pauseResume) } label: { Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity) }
            Button { model.send(.transition) } label: { Label("Next Part", systemImage: "arrow.right.to.line").frame(maxWidth: .infinity) }
            Button { model.send(.outro) } label: { Label("Outro", systemImage: "flag.checkered").frame(maxWidth: .infinity) }
            Button { model.send(.accent) } label: { Label("Accent", systemImage: "burst.fill").frame(maxWidth: .infinity) }
        }
        .buttonStyle(PanelButtonStyle())
        .frame(width: 150)
    }
}

/// The big footswitch: tap = start / fill / resume, hold = transition, double tap = outro.
struct PedalButton: View {
    @ObservedObject var model: PedalViewModel
    @State private var pressed = false
    @State private var pressStart: Date?
    @State private var holdFired = false
    @State private var lastTap: Date?

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(white: pressed ? 0.42 : 0.55), Color(white: 0.2)],
                                     center: .init(x: 0.4, y: 0.35), startRadius: 4, endRadius: 140))
                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 4))
                .overlay(Circle().inset(by: 10).stroke(Color.white.opacity(0.12), lineWidth: 2))
                .shadow(color: .black.opacity(0.6), radius: pressed ? 2 : 10, y: pressed ? 1 : 6)
            VStack(spacing: 4) {
                Image(systemName: "shoe.fill").font(.system(size: 28))
                Text("PEDAL").font(.system(size: 15, weight: .heavy, design: .rounded))
                Text("tap · hold · double").font(.system(size: 10, design: .rounded)).opacity(0.7)
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .aspectRatio(1, contentMode: .fit)
        .scaleEffect(pressed ? 0.97 : 1)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    holdFired = false
                    let now = Date()
                    pressStart = now
                    // Double tap → outro (the first tap already played a fill).
                    if let last = lastTap, now.timeIntervalSince(last) < 0.35 {
                        model.send(.outro)
                        lastTap = nil
                        holdFired = true
                        return
                    }
                    // Act on press, not release, so fills land in time.
                    model.send(.pedalTap)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if pressed, let s = pressStart, s == now, !holdFired {
                            holdFired = true
                            model.send(.cancelPending)
                            model.send(.transition)
                        }
                    }
                }
                .onEnded { _ in
                    pressed = false
                    if !holdFired { lastTap = Date() }
                    pressStart = nil
                }
        )
        .accessibilityLabel("Pedal")
        .accessibilityAddTraits(.isButton)
    }
}

struct TempoBlock: View {
    @ObservedObject var model: PedalViewModel
    var body: some View {
        VStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let eff = model.engine.status.effectiveTempo
                VStack(spacing: 0) {
                    Text("\(Int(eff.rounded()))")
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                    Text(model.hostSync ? "BPM · HOST" : "BPM").font(.caption.monospaced()).foregroundStyle(Theme.dim)
                }
            }
            HStack(spacing: 6) {
                Button { model.nudgeTempo(-1) } label: { Image(systemName: "minus").frame(maxWidth: .infinity) }
                Button { model.nudgeTempo(1) } label: { Image(systemName: "plus").frame(maxWidth: .infinity) }
            }
            .buttonStyle(PanelButtonStyle())
            Button { model.tapTempo() } label: { Text("TAP").bold().frame(maxWidth: .infinity) }
                .buttonStyle(PanelButtonStyle(highlight: true))
            Button { model.resetTempoToSong() } label: { Text("Song tempo").font(.caption).frame(maxWidth: .infinity) }
                .buttonStyle(PanelButtonStyle())
        }
        .frame(width: 140)
    }
}

struct MixRow: View {
    @ObservedObject var model: PedalViewModel
    @Binding var showHelp: Bool
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                LabeledSlider(title: "Volume", value: Binding(get: { model.volume }, set: { model.volume = $0; model.set(.volume, $0) }),
                              range: 0...1.5, format: { "\(Int($0 * 100))%" })
                LabeledSlider(title: "Swing", value: Binding(get: { model.swing }, set: { model.swing = $0; model.set(.swing, $0) }),
                              range: 0...100, format: { "\(Int($0))%" })
                LabeledSlider(title: "Humanize", value: Binding(get: { model.humanize }, set: { model.humanize = $0; model.set(.humanize, $0) }),
                              range: 0...100, format: { "\(Int($0))%" })
            }
            HStack(spacing: 16) {
                Toggle("Sync tempo to host", isOn: Binding(get: { model.hostSync }, set: { model.hostSync = $0; model.set(.hostSync, $0 ? 1 : 0) }))
                    .help("PedalBeat follows Loopy / the DAW project tempo")
                Toggle("MIDI Clock Out", isOn: Binding(get: { model.midiClockOut }, set: { model.midiClockOut = $0; model.set(.midiClockOut, $0 ? 1 : 0) }))
                    .help("Send MIDI Clock so Loopy (or another app) can follow PedalBeat’s tempo. Turn Sync tempo to host off.")
                Toggle("Start/stop with host", isOn: Binding(get: { model.followTransport }, set: { model.followTransport = $0; model.set(.followTransport, $0 ? 1 : 0) }))
                Toggle("Random fills", isOn: Binding(get: { model.randomFills }, set: { model.randomFills = $0; model.set(.fillOrder, $0 ? 1 : 0) }))
                    .help("Parts with several fills play them in order, or at random (never the same twice in a row)")
                Spacer()
                Button { model.showMIDISettings = true } label: { Label("MIDI Settings", systemImage: "pianokeys") }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim)
                    .help("Choose which pedal, key or button does what")
                Button { showHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim)
                    .help("Pedal and MIDI help")
            }
            .font(.caption)
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }
}

/// Master percussion switch (the song's shaker, tambourine and clap layers) and the controls that
/// only apply when it is on. A separate track like the bass, imported from its own folders.
struct PercussionSection: View {
    @ObservedObject var model: PedalViewModel
    var body: some View {
        let here = model.currentPercussion
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle(isOn: Binding(get: { model.percOn }, set: { model.setPercussionOn($0) })) {
                    Text("Percussion").font(.caption.weight(.bold)).foregroundStyle(Theme.dim)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
                .help("Play the song's own shaker, tambourine, maracas and clap with the drums. Off = drums only (no percussion audio or MIDI).")
                if model.percOn {
                    Toggle(isOn: Binding(get: { model.percAuto }, set: { model.setAutoPercussion($0) })) {
                        Text("Auto").font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .fixedSize()
                    .help("Beats without percussion of their own play generated shaker, tambourine, maracas or clap, following their hi-hats and backbeats.")
                    PercKitMenu(model: model)
                }
                Spacer(minLength: 4)
                PercussionSummary(here: here, auto: model.currentPercussionIsAuto, anyImported: model.hasPercussionImports)
                if model.hasPercussionImports { PercussionImportsMenu(model: model) }
            }
            if model.percOn {
                HStack(spacing: 14) {
                    LabeledSlider(title: "Level", value: Binding(get: { model.percVolume }, set: { model.setPercussionVolume($0) }),
                                  range: 0...1.5, format: { "\(Int($0 * 100))%" })
                        .frame(maxWidth: 200)
                        .help("Level of the percussion layers (not the drums' own shaker, tambourine or clap)")
                    ForEach(PercussionInstrument.allCases) { inst in
                        PercussionToggle(model: model, instrument: inst, inSong: here.contains(inst))
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panelHi.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Sample kit for percussion-layer hits (independent of the drum kit).
private struct PercKitMenu: View {
    @ObservedObject var model: PedalViewModel
    var body: some View {
        Menu {
            ForEach(model.availablePercKits) { choice in
                Button {
                    model.setPercKit(choice)
                } label: {
                    if choice == model.percKit {
                        Label(choice.name, systemImage: "checkmark")
                    } else {
                        Text(choice.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                Text(model.percKit.name).lineLimit(1)
            }
            .font(.caption)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Sample kit for shaker, tambourine, clap and maracas layers. Drum Kit = same as the drums; FreePats and World are dedicated layer kits with real hand-perc samples.")
    }
}

/// What the selected song has, or how to get percussion at all.
private struct PercussionSummary: View {
    let here: [PercussionInstrument]
    let auto: Bool
    let anyImported: Bool
    var body: some View {
        Text(here.isEmpty ? (anyImported ? "None for this song" : "Import shaker_songs, tambourine_songs or clap_songs, or switch on Auto")
                          : (auto ? "Auto: " : "") + here.map(\.name).joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(here.isEmpty ? Theme.dim : Theme.lcdText.opacity(0.8))
            .lineLimit(1)
            .help(here.isEmpty
                  ? "Percussion parts play with the song of the same artist and title from an imported “drum_songs” folder."
                  : "This song plays these percussion parts with its drums")
    }
}

private struct PercussionToggle: View {
    @ObservedObject var model: PedalViewModel
    let instrument: PercussionInstrument
    let inSong: Bool
    var body: some View {
        Toggle(instrument.name, isOn: Binding(get: { model.percInstruments[instrument.rawValue] },
                                              set: { model.setPercussion(instrument, on: $0) }))
            .opacity(inSong ? 1 : 0.5)
            .help(inSong ? "Play the \(instrument.name.lowercased()) part"
                         : "No \(instrument.name.lowercased()) part here (import the “\(instrument.folder)” folder, or Auto)")
    }
}

/// Imported layers per instrument, with a way to remove them (they are not in the song browser).
private struct PercussionImportsMenu: View {
    @ObservedObject var model: PedalViewModel
    var body: some View {
        Menu {
            ForEach(PercussionInstrument.allCases) { inst in
                let n = model.percussionCounts[inst] ?? 0
                if n > 0 {
                    Button("Remove \(n) imported \(inst.name.lowercased()) part\(n == 1 ? "" : "s")", role: .destructive) {
                        model.removePercussion(inst)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(Theme.dim)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(PercussionInstrument.allCases.compactMap { i in
            model.percussionCounts[i].map { "\($0) \(i.name.lowercased())" }
        }.joined(separator: ", ") + " parts imported")
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(Theme.dim)
                Spacer()
                Text(format(value)).font(.caption.monospacedDigit())
            }
            Slider(value: $value, in: range).tint(Theme.accent)
        }
    }
}

struct PanelButtonStyle: ButtonStyle {
    var highlight = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background((highlight ? Theme.accent.opacity(configuration.isPressed ? 0.6 : 0.85)
                         : Theme.panelHi.opacity(configuration.isPressed ? 0.6 : 1)),
                        in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(highlight ? Color.black : Color.white)
            .contentShape(Rectangle())
    }
}

struct HelpView: View {
    @Binding var isPresented: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pedal").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Tap").bold(); Text("Start (plays the intro) · fill while playing · resume when paused") }
                GridRow { Text("Hold").bold(); Text("Transition fill, then the next part") }
                GridRow { Text("Double tap").bold(); Text("Outro and stop") }
            }
            Text("Late presses (less than a beat left in the bar) are queued for the next bar, so fills always land on the downbeat.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Bass").font(.title3.bold())
            Text("The Bass switch turns the bass on or off. Off = drums only. On unlocks level, mute, kit and Bass Follow; the arrow folds them away. In songs with a bass line the bass keeps playing under fills; transitions and the ending use their own line when they have one. Mute silences the synth but still sends MIDI on channel 2.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Percussion").font(.title3.bold())
            Text("A separate track like the bass: a song's own shaker, tambourine and clap. Import the folders shaker_songs, tambourine_songs and clap_songs (Artist / Title / Groove A.mid …); each part plays with the song of the same artist and title from drum_songs. The Percussion switch turns them all on or off, and each instrument has its own switch. The kit menu next to Auto picks the samples for those layers (Drum Kit, FreePats or World). Fills and transitions play the part's own fill if it has one, otherwise its groove keeps going.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) { Text("Bass Follow").font(.title3.bold()); BetaBadge() }
            Text("Experimental. Only when Bass is on. Chord detection can be wrong or late, especially with distorted guitar. For guitar audio: PedalBeat Drums FX on the Guitar track, or Side Chain to that track (not to PedalBeat itself). GTR appears when audio arrives. MIDI chords (any channel except 10) also work.")
                .font(.callout).foregroundStyle(.secondary)
            Text("MIDI Control (any channel)").font(.title3.bold())
            Text("These are the defaults. To use your own pedal, key or button, open MIDI Settings and tap Learn.")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(MIDIAction.allCases) { action in
                    GridRow { Text(MIDIMappings.default.triggers[action]?.title ?? "–"); Text(action.title) }
                }
                GridRow { Text("Program change"); Text("Select song by number (can be turned off)") }
                GridRow { Text("GM drum notes"); Text("Play the kit live (35–82)") }
                GridRow { Text("Note 88"); Text("Brush sweep (sustained until the next sweep)") }
            }
            .font(.callout.monospaced())
            Text("MIDI Out sends every drum hit on channel 10 (GM notes; brush sweeps on note 88) to drive another drum module, and the bass line on channel 2 for a bass synth. With MIDI Clock Out on, Start/Stop/Continue and 24 PPQN clock leave the same port so Loopy Pro can follow PedalBeat’s tempo (turn Sync tempo to host off).")
                .font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(minWidth: 460)
    }
}
