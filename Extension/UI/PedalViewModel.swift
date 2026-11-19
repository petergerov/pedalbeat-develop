import SwiftUI
import AudioToolbox
import Combine

@MainActor
final class PedalViewModel: ObservableObject {
    let au: PedalBeatAudioUnit
    var engine: DrumEngine { au.engine }

    @Published var songs: [SongInfo] = []
    @Published var selectedSong: Int = 0
    @Published var search = ""
    enum BrowserMode: String, CaseIterable { case beats = "Beats", songs = "Songs" }
    @Published var browserMode: BrowserMode = .beats
    @Published var songSearch = ""
    /// Genre filter in the Songs tab (nil = all).
    @Published var songGenre: String?
    @Published var expandedGenre: String?
    @Published var tempo: Double = 120
    @Published var volume: Double = 0.8
    @Published var kit: Int = 0
    @Published var swing: Double = 0
    @Published var humanize: Double = 15
    @Published var hostSync = true
    @Published var followTransport = false
    @Published var randomFills = false
    @Published var importMessage: String?
    @Published var kitNames: [String] = Kits.names
    @Published var sampleKits: [KitManager.Installed] = []
    @Published var kitLoading = false
    @Published var showImporter = false
    @Published var showKitManager = false
    @Published var mixGains: [Double] = Array(repeating: 1, count: Drum.count)
    @Published var importing = false
    @Published var songEditor: SongEditor?
    /// Open Mix Song sheet (same pattern as Edit Song).
    @Published var songMixer: SongMixer?
    /// The song-index entry last loaded (cleared when another song is picked).
    @Published var loadedEntry: SongIndex.Entry?
    /// Imported .BBS beats by normalized name, for exact song-index matches.
    private var bbsBeats: [String: SongInfo] = [:]
    private var shownKitError: String?

    private var observerToken: AUParameterObserverToken?
    private var tapTimes: [Date] = []

    init(audioUnit: PedalBeatAudioUnit) {
        au = audioUnit
        reloadSongs()
        pullParameters()
        expandedGenre = currentSong?.genre
        au.library.onChange = { [weak self] in Task { @MainActor in self?.reloadSongs() } }
        reloadKits()
        au.kits.onChange = { [weak self] in Task { @MainActor in self?.reloadKits() } }
        observerToken = au.parameterTree?.token(byAddingParameterObserver: { [weak self] _, _ in
            Task { @MainActor in self?.pullParameters() }
        })
        loadMix(forKey: currentSong?.key)
    }

    deinit {
        if let t = observerToken { au.parameterTree?.removeParameterObserver(t) }
    }

    func reloadSongs() {
        songs = au.library.visibleSongs
        var bb: [String: SongInfo] = [:]
        for s in songs where s.isUser && s.genre.hasPrefix(BBSImport.packName + " › ") {
            bb[SongIndex.normalize(s.name)] = bb[SongIndex.normalize(s.name)] ?? s
        }
        bbsBeats = bb
    }

    func pullParameters() {
        tempo = Double(engine.parameter(.tempo))
        volume = Double(engine.parameter(.volume))
        kit = Int(engine.parameter(.kit))
        swing = Double(engine.parameter(.swing))
        humanize = Double(engine.parameter(.humanize))
        hostSync = engine.parameter(.hostSync) >= 0.5
        followTransport = engine.parameter(.followTransport) >= 0.5
        randomFills = engine.parameter(.fillOrder) >= 0.5
        selectedSong = Int(engine.parameter(.song))
    }

    func set(_ a: ParamAddress, _ v: Double) {
        au.parameter(a)?.setValue(AUValue(v), originator: observerToken)
    }

    var currentSong: SongInfo? { au.library.song(at: selectedSong) }

    var genres: [(String, [SongInfo])] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? songs : songs.filter { $0.name.lowercased().contains(q) || $0.genre.lowercased().contains(q) }
        var order: [String] = []
        var map: [String: [SongInfo]] = [:]
        for s in filtered {
            if map[s.genre] == nil { order.append(s.genre) }
            map[s.genre, default: []].append(s)
        }
        return order.map { ($0, map[$0]!) }
    }

    // MARK: Actions

    /// Songs tab: popular songs (song index) matching the search and genre filter.
    var songMatches: [SongIndex.Entry] {
        let q = songSearch.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? SongIndex.entries : SongIndex.search(q, limit: .max)
        guard let g = songGenre else { return list }
        return list.filter { $0.genre == g }
    }

    var hasBBSBeats: Bool { !bbsBeats.isEmpty }

    /// What a song-index entry plays: the imported .BBS beat of that name (exact),
    /// else the closest factory groove.
    func resolve(_ entry: SongIndex.Entry) -> (song: SongInfo, exact: Bool)? {
        if let s = bbsBeats[SongIndex.normalize(entry.style)] { return (s, true) }
        return au.library.song(for: entry.target).map { ($0, false) }
    }

    /// Loads the beat for a popular song, at that song's tempo.
    func load(_ entry: SongIndex.Entry) {
        guard let (song, _) = resolve(entry) else {
            importMessage = "No groove found for “\(entry.title)” (\(entry.target.label))."
            return
        }
        select(song)
        loadedEntry = entry
        tempo = min(max(entry.bpm, 30), 300)
        set(.tempo, tempo)
        if hostSync { hostSync = false; set(.hostSync, 0) }
    }

    func select(_ song: SongInfo) {
        loadedEntry = nil
        selectedSong = song.id
        set(.song, Double(song.id))
        tempo = song.tempo
        set(.tempo, song.tempo)
        loadMix(forKey: song.key)
        // Keep an open Mix Song sheet pointed at the newly selected song.
        if songMixer != nil {
            songMixer = SongMixer(key: song.key, name: song.name)
        }
    }

    func step(_ delta: Int) {
        let list = genres.flatMap(\.1)
        guard let i = list.firstIndex(where: { $0.id == selectedSong }) else {
            if let f = list.first { select(f) }
            return
        }
        let j = min(max(i + delta, 0), list.count - 1)
        select(list[j])
        expandedGenre = list[j].genre
    }

    func send(_ c: PedalCommand) { engine.send(c) }
    func gotoPart(_ i: Int) { engine.gotoPart(i) }

    func nudgeTempo(_ d: Double) {
        tempo = min(max((tempo + d).rounded(), 30), 300)
        set(.tempo, tempo)
    }

    func tapTempo() {
        let now = Date()
        tapTimes = tapTimes.filter { now.timeIntervalSince($0) < 2.5 }
        tapTimes.append(now)
        guard tapTimes.count >= 2 else { return }
        let intervals = zip(tapTimes.dropFirst(), tapTimes).map { $0.timeIntervalSince($1) }
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        guard avg > 0 else { return }
        tempo = min(max((60 / avg).rounded(), 30), 300)
        set(.tempo, tempo)
        if hostSync { hostSync = false; set(.hostSync, 0) }
    }

    func resetTempoToSong() {
        if let s = currentSong { tempo = s.tempo; set(.tempo, s.tempo) }
    }

    // MARK: Import

    func importFiles(_ urls: [URL], asOneSong: Bool) {
        var files: [SongLibrary.ImportedFile] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let d = try? Data(contentsOf: url) { files.append(.init(name: url.lastPathComponent, data: d)) }
        }
        guard !files.isEmpty else { importMessage = "Couldn't read the selected files."; return }
        do {
            let added = try au.library.importMIDI(files, asOneSong: asOneSong)
            reloadSongs()
            if let first = added.first {
                select(first)
                expandedGenre = first.genre
            }
            importMessage = added.count == 1 ? "Imported “\(added[0].name)”" : "Imported \(added.count) songs"
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: Kits

    var kitName: String { kitNames.indices.contains(kit) ? kitNames[kit] : "Kit" }
    var currentKit: KitManager.Installed? { au.kits.installed(at: kit) }

    func reloadKits() {
        sampleKits = au.kits.kits
        kitNames = au.kits.allKitNames
        kitLoading = au.kits.isLoading
        if let e = au.kits.loadError, e != shownKitError {
            shownKitError = e
            importMessage = "The kit couldn't be loaded. \(e)"
        }
    }

    func selectKit(_ index: Int) {
        kit = index
        set(.kit, Double(index))
        kitLoading = au.kits.isLoading
    }

    // MARK: Mix Song (per-song levels, same entry pattern as Edit Song)

    func mixSong(_ song: SongInfo) {
        select(song)
        songMixer = SongMixer(key: song.key, name: song.name)
    }

    func loadMix(forKey key: String?) {
        guard let key, !key.isEmpty else {
            mixGains = Array(repeating: 1, count: Drum.count)
            engine.resetMixGains()
            return
        }
        if let saved = UserDefaults.standard.array(forKey: mixDefaultsKey(key)) as? [Double],
           saved.count == Drum.count {
            mixGains = saved
            for d in Drum.allCases { engine.setMixGain(drum: d, Float(saved[d.rawValue])) }
        } else {
            mixGains = Array(repeating: 1, count: Drum.count)
            engine.resetMixGains()
        }
    }

    func setMixGain(_ drum: Drum, _ gain: Double) {
        let g = min(max(gain, 0), 2)
        mixGains[drum.rawValue] = g
        engine.setMixGain(drum: drum, Float(g))
        if let key = songMixer?.key ?? currentSong?.key {
            UserDefaults.standard.set(mixGains, forKey: mixDefaultsKey(key))
        }
    }

    func resetMixGains() {
        mixGains = Array(repeating: 1, count: Drum.count)
        engine.resetMixGains()
        if let key = songMixer?.key ?? currentSong?.key {
            UserDefaults.standard.removeObject(forKey: mixDefaultsKey(key))
        }
    }

    private func mixDefaultsKey(_ songKey: String) -> String {
        "pedalbeat.songMix.\(songKey)"
    }

    /// Best kit for a song: an installed sample kit that suits it, else its synth kit.
    func suggestedKit(for song: SongInfo) -> Int { au.kits.suggestedKit(forHint: song.kitHint) }

    /// Kit indices shift when kits are added or removed; keep the current one selected.
    private func keepKit(id: String?) {
        guard let id else { return }
        if let idx = au.kits.index(forID: id) { if idx != kit { kit = idx; set(.kit, Double(idx)) } }
        else { selectKit(0) }
    }

    func importKits(_ urls: [URL]) {
        let currentID = currentKit?.id
        var names: [String] = [], errors: [String] = []
        var lastID: String?
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let idx = try au.kits.importKit(from: url)
                if let k = au.kits.installed(at: idx) { names.append(k.name); lastID = k.id }
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        keepKit(id: currentID)
        if let id = lastID, let idx = au.kits.index(forID: id) { selectKit(idx) }
        reloadKits()
        if !errors.isEmpty {
            importMessage = (names.isEmpty ? "" : "Imported \(names.joined(separator: ", ")). ") + "Failed: " + errors.joined(separator: "; ")
        } else if !names.isEmpty {
            importMessage = names.count == 1 ? "Kit “\(names[0])” installed" : "Installed \(names.count) kits"
        }
    }

    func removeKit(_ k: KitManager.Installed) {
        let currentID = currentKit?.id
        au.kits.remove(id: k.id)
        keepKit(id: currentID == k.id ? nil : currentID)
        if currentID == k.id { selectKit(min(k.manifest.fallbackSynthKit, Kits.all.count - 1)) }
        reloadKits()
    }

    // MARK: Folder import

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Imports whole folders of MIDI files (e.g. a loop pack). Runs off the main thread;
    /// every pack/style folder becomes a group in the song browser.
    func importFolders(_ urls: [URL]) {
        guard !importing else { return }
        importing = true
        let library = au.library
        Task.detached(priority: .userInitiated) { [weak self] in
            var entries: [MIDIFolderImport.Entry] = []
            var limited = false
            let maxFiles = 5000
            var bbFailed: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // A .BBS SD card or project folder: convert its songs.
                if let songsDir = BBSImport.songsFolder(in: url) {
                    let r = BBSImport.entries(songsFolder: songsDir)
                    entries += r.entries
                    bbFailed += r.failed
                    continue
                }
                let root = url.standardizedFileURL
                let baseCount = root.deletingLastPathComponent().pathComponents.count
                guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let f as URL in en where ["mid", "midi", "smf"].contains(f.pathExtension.lowercased())
                    || f.lastPathComponent.lowercased() == SongLibrary.songFileName {
                    if entries.count >= maxFiles { limited = true; break }
                    guard let d = try? Data(contentsOf: f), d.count < 4_000_000 else { continue }
                    entries.append(.init(path: Array(f.standardizedFileURL.pathComponents.dropFirst(baseCount)), data: d))
                }
            }
            let result = library.importFolder(entries)
            let found = entries.count
            await self?.finishFolderImport(result, found: found, limited: limited, bbsFailed: bbFailed)
        }
    }

    private func finishFolderImport(_ r: SongLibrary.FolderImportResult, found: Int, limited: Bool, bbsFailed: [String] = []) {
        importing = false
        reloadSongs()
        if let first = r.songs.first {
            select(first)
            expandedGenre = first.genre
        }
        var msg: String
        if found == 0 { msg = "No MIDI files found in that folder." }
        else if r.songs.isEmpty { msg = "None of the \(found) MIDI files contained drum notes." }
        else {
            msg = "Imported \(r.songs.count) song\(r.songs.count == 1 ? "" : "s") in \(r.groups.count) group\(r.groups.count == 1 ? "" : "s")"
            msg += r.groups.count <= 4 ? ": " + r.groups.joined(separator: ", ") + "." : "."
        }
        if !r.skipped.isEmpty { msg += " Skipped \(r.skipped.count) file\(r.skipped.count == 1 ? "" : "s") without usable drum notes." }
        if limited { msg += " Only the first 5000 files were read." }
        if !bbsFailed.isEmpty {
            msg += " \(bbsFailed.count) .BBS song\(bbsFailed.count == 1 ? "" : "s") couldn't be read: "
                + bbsFailed.prefix(5).joined(separator: ", ") + (bbsFailed.count > 5 ? "…" : "") + "."
        }
        importMessage = msg
    }

    /// Removes every imported song in a browser group.
    func removeGroup(_ genre: String) {
        au.library.hide(genre: genre)
        reloadSongs()
        if expandedGenre == genre { expandedGenre = nil }
    }

    func isUserGroup(_ songs: [SongInfo]) -> Bool { !songs.isEmpty && songs.allSatisfy(\.isUser) }

    /// Routes picked or dropped items: folders -> folder import, .pbkit -> kits, MIDI -> songs.
    func importAny(_ urls: [URL], askMode: ([URL]) -> Void) {
        let folders = urls.filter { PedalViewModel.isDirectory($0) }
        if !folders.isEmpty { importFolders(folders) }
        let urls = urls.filter { !folders.contains($0) }
        let kitURLs = urls.filter { $0.pathExtension.lowercased() == "pbkit" }
        let midi = urls.filter { ["mid", "midi", "smf"].contains($0.pathExtension.lowercased()) }
        if !kitURLs.isEmpty { importKits(kitURLs) }
        if midi.count == 1 { importFiles(midi, asOneSong: true) }
        else if midi.count > 1 { askMode(midi) }
    }

    // MARK: Song editor

    func editSong(_ song: SongInfo) {
        let lib = au.library
        // Factory songs become MIDI files in a draft; it replaces the original only when saved.
        guard let rec = lib.beginEditing(song), let layout = rec.layout ?? lib.automaticLayout(forKey: song.key) else {
            importMessage = "This song can't be edited."
            return
        }
        let editor = SongEditor(key: song.key, name: song.name, layout: layout,
                                files: lib.fileInfo(forKey: song.key), automatic: lib.automaticLayout(forKey: song.key))
        editor.model = self
        songEditor = editor
    }

    /// Plays one file of the song being edited with the current kit and tempo.
    func previewFile(_ editor: SongEditor, _ name: String) {
        guard let pattern = au.library.previewPattern(forKey: editor.key, file: name) else {
            importMessage = "“\(name)” can't be played."
            return
        }
        editor.previewingFile = name
        engine.preview(pattern: pattern, loop: editor.info(name)?.role == "Groove")
    }

    /// Editor closed (saved, cancelled or swiped away): stop audition, drop an unsaved draft.
    func closeSongEditor(_ editor: SongEditor) {
        stopPreview(editor)
        au.library.cancelEditing(key: editor.key)
    }

    func isEditedFactorySong(_ song: SongInfo) -> Bool { song.isUser && au.library.isEditedFactorySong(key: song.key) }

    func revertToFactory(_ song: SongInfo) {
        let wasSelected = song.id == selectedSong
        guard let factory = au.library.revertToFactory(key: song.key) else { return }
        reloadSongs()
        if wasSelected { select(factory) }
    }

    func stopPreview(_ editor: SongEditor) {
        if editor.previewingFile != nil || engine.status.previewing { engine.stopPreview() }
        editor.previewingFile = nil
    }

    func saveSongEditor(_ editor: SongEditor) {
        do {
            stopPreview(editor)
            let info = try au.library.updateSong(key: editor.key, name: editor.name, layout: editor.layout)
            reloadSongs()
            select(info)
            expandedGenre = info.genre
            songEditor = nil
        } catch {
            importMessage = "Couldn't save the song: \(error.localizedDescription)"
        }
    }

    func remove(_ song: SongInfo) {
        au.library.hide(key: song.key)
        reloadSongs()
    }
}
