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
    /// Artist (interpret) filter in the Songs tab (nil = all).
    @Published var songArtist: String?
    @Published var expandedGenre: String?
    @Published var tempo: Double = 120
    @Published var volume: Double = 0.8
    @Published var kit: Int = 0
    @Published var swing: Double = 0
    @Published var humanize: Double = 15
    @Published var hostSync = true
    @Published var followTransport = false
    @Published var randomFills = false
    @Published var midiClockOut = false
    /// Bass track and Bass Follow (beta) settings, observed by `BassSection` and the mixer.
    let bass = BassControls()
    /// Percussion layers (shaker, tambourine, clap): master switch, level, one switch per instrument.
    @Published var percOn = true
    @Published var percVolume: Double = 1
    @Published var percInstruments = [Bool](repeating: true, count: PercussionInstrument.count)
    /// Auto Percussion: beats without percussion of their own play generated layers (default off).
    @Published var percAuto = false
    /// Imported layers per instrument.
    @Published var percussionCounts: [PercussionInstrument: Int] = [:]
    @Published var importMessage: String?
    @Published var kitNames: [String] = Kits.names
    @Published var sampleKits: [KitManager.Installed] = []
    @Published var kitLoading = false
    @Published var showImporter = false
    @Published var showKitManager = false
    @Published var showMIDISettings = false
    @Published var mixGains: [Double] = Array(repeating: 1, count: Drum.count)
    @Published var importing = false
    @Published var songEditor: SongEditor?
    /// Open Mix Song sheet (same pattern as Edit Song).
    @Published var songMixer: SongMixer?
    /// The song-index row last loaded (cleared when another song is picked).
    @Published var loadedRow: SongRow?
    var loadedEntry: SongIndex.Entry? { loadedRow?.entry }
    /// Songs tab: only the bb or only the MIDI versions (nil = both).
    @Published var songSource: SongVersion?
    /// Imported .BBS beats by normalized name, for exact song-index matches.
    private var bbsBeats: [String: SongInfo] = [:]
    /// Imported "drum songs": each popular song's own drum pattern, keyed by `SongIndex.songKey`.
    private var songDrums: [String: SongInfo] = [:]
    /// Imported "bb songs": a song's bb version (beat + the song's bass), by `SongIndex.bbSongKey`.
    private var bbSongs: [String: SongInfo] = [:]
    private var shownKitError: String?

    private var observerToken: AUParameterObserverToken?
    private var tapTimes: [Date] = []

    init(audioUnit: PedalBeatAudioUnit) {
        au = audioUnit
        bass.send = { [unowned self] address, value in self.set(address, value) }
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
        // Imported .BBS beats, or the built-in ones (an import of the same name wins).
        for s in songs where s.genre.hasPrefix(BBSImport.packName + " › ") {
            let k = SongIndex.normalize(s.name)
            if let old = bb[k], old.isUser || !s.isUser { continue }
            bb[k] = s
        }
        bbsBeats = bb
        var drums: [String: SongInfo] = [:]
        for s in songs {
            let parts = s.genre.components(separatedBy: " › ")
            guard parts.count >= 2, SongIndex.normalize(parts[0]) == SongIndex.normalize(SongIndex.songDrumsPack) else { continue }
            let key = SongIndex.songKey(artist: parts.dropFirst().joined(separator: " "), title: s.name)
            // The built-in song pack, unless the user imported (or edited) that song.
            if let old = drums[key], old.isUser || !s.isUser { continue }
            drums[key] = s
        }
        songDrums = drums
        var bbVersions: [String: SongInfo] = [:]
        for s in songs {
            let parts = s.genre.components(separatedBy: " › ")
            guard parts.count >= 2, SongIndex.normalize(parts[0]) == SongIndex.normalize(SongIndex.bbSongsPack) else { continue }
            let (title, beat) = SongIndex.splitBBSongName(s.name)
            let key = SongIndex.bbSongKey(artist: parts.dropFirst().joined(separator: " "), title: title, beat: beat)
            if let old = bbVersions[key], old.isUser || !s.isUser { continue }
            bbVersions[key] = s
        }
        bbSongs = bbVersions
        percussionCounts = au.library.percussionCounts
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
        midiClockOut = engine.parameter(.midiClockOut) >= 0.5
        bass.pull(from: engine)
        percOn = engine.parameter(.percOn) >= 0.5
        percVolume = Double(engine.parameter(.percVolume))
        percInstruments = PercussionInstrument.allCases.map { engine.parameter($0.parameter) >= 0.5 }
        percAuto = engine.parameter(.percAuto) >= 0.5
        selectedSong = Int(engine.parameter(.song))
    }

    // MARK: Percussion

    func setPercussionOn(_ on: Bool) {
        percOn = on
        set(.percOn, on ? 1 : 0)
    }

    func setPercussionVolume(_ v: Double) {
        percVolume = min(max(v, 0), 1.5)
        set(.percVolume, percVolume)
    }

    func setAutoPercussion(_ on: Bool) {
        percAuto = on
        set(.percAuto, on ? 1 : 0)
    }

    func setPercussion(_ inst: PercussionInstrument, on: Bool) {
        percInstruments[inst.rawValue] = on
        set(inst.parameter, on ? 1 : 0)
    }

    /// Instruments that play with the selected song: its own layers, else (Auto Percussion) the generated ones.
    var currentPercussion: [PercussionInstrument] {
        guard let s = currentSong else { return [] }
        let own = au.library.percussion(for: s)
        return own.isEmpty && percAuto ? au.library.autoPercussion(for: s) : own
    }
    /// The selected song plays generated percussion.
    var currentPercussionIsAuto: Bool {
        guard let s = currentSong, percAuto else { return false }
        return au.library.percussion(for: s).isEmpty && !au.library.autoPercussion(for: s).isEmpty
    }
    func percussion(for song: SongInfo) -> [PercussionInstrument] { au.library.percussion(for: song) }
    var hasPercussionImports: Bool { percussionCounts.values.contains { $0 > 0 } }

    func removePercussion(_ inst: PercussionInstrument) {
        au.library.removePercussion(inst)
        reloadSongs()
    }

    func set(_ a: ParamAddress, _ v: Double) {
        au.parameter(a)?.setValue(AUValue(v), originator: observerToken)
    }

    var currentSong: SongInfo? { au.library.song(at: selectedSong) }

    /// A song of the Songs tab, not a beat: from the built-in song pack, or an imported "drum songs" /
    /// "bb songs" folder (a song's MIDI or bb version).
    static func isPackSong(_ s: SongInfo) -> Bool {
        (!s.isUser && s.key.hasPrefix(ContentPack.keyPrefix) && !s.key.hasPrefix(ContentPack.beatKeyPrefix))
            || SongIndex.isDrumSongPack(s.genre.components(separatedBy: " › ").first ?? "")
    }

    var genres: [(String, [SongInfo])] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let beats = songs.filter { !PedalViewModel.isPackSong($0) }
        let filtered = q.isEmpty ? beats : beats.filter { $0.name.lowercased().contains(q) || $0.genre.lowercased().contains(q) }
        var order: [String] = []
        var map: [String: [SongInfo]] = [:]
        for s in filtered {
            if map[s.genre] == nil { order.append(s.genre) }
            map[s.genre, default: []].append(s)
        }
        return order.map { ($0, map[$0]!) }
    }

    // MARK: Actions

    /// Songs tab: popular songs matching search, genre and artist filters.
    var songMatches: [SongIndex.Entry] {
        let q = songSearch.trimmingCharacters(in: .whitespaces)
        var list = q.isEmpty ? SongIndex.entries : SongIndex.search(q, limit: .max)
        if let g = songGenre { list = list.filter { $0.genre == g } }
        if let a = songArtist { list = list.filter { $0.artist == a } }
        return list
    }

    /// Which version of a song a Songs-tab row plays.
    enum SongVersion: Int, CaseIterable, Hashable {
        /// Its bb beat with the song's bass and percussion on top.
        case bb
        /// Its own drums from the MIDI song, with its bass and percussion.
        case midi
        /// Neither is there: the closest factory groove (≈).
        case similar

        var label: String {
            switch self {
            case .bb: "bb"
            case .midi: "MIDI"
            case .similar: "Similar groove"
            }
        }
    }

    /// One row of the Songs tab: a song in one version. A song with both a bb and a MIDI version
    /// has two rows.
    struct SongRow: Identifiable, Hashable {
        let entry: SongIndex.Entry
        let version: SongVersion
        var id: Int { entry.id * 4 + version.rawValue }
    }

    /// The Songs tab's rows: every matching song once per version it has, filtered by `songSource`.
    var songRows: [SongRow] {
        songMatches.flatMap { e in versions(of: e).map { SongRow(entry: e, version: $0) } }
            .filter { songSource == nil || $0.version == songSource }
    }

    /// Number of rows without search and filters.
    func songRows(filtered: Bool) -> Int {
        filtered ? songRows.count : SongIndex.entries.reduce(0) { $0 + versions(of: $1).count }
    }

    /// Versions of a song: bb (its imported version, or its beat), MIDI (its own drums); the
    /// closest factory groove only when it has neither.
    func versions(of entry: SongIndex.Entry) -> [SongVersion] {
        var out: [SongVersion] = []
        if bbVersion(of: entry) != nil || bbsBeats[SongIndex.normalize(entry.style)] != nil { out.append(.bb) }
        if songDrums[SongIndex.songKey(artist: entry.artist, title: entry.title)] != nil { out.append(.midi) }
        return out.isEmpty ? [.similar] : out
    }

    private func bbVersion(of entry: SongIndex.Entry) -> SongInfo? {
        bbSongs[SongIndex.bbSongKey(artist: entry.artist, title: entry.title, beat: entry.style)]
    }

    /// Artists offered in the Songs filter (scoped to the selected genre when set).
    var songFilterArtists: [String] { SongIndex.artists(inGenre: songGenre) }

    var hasBBSBeats: Bool { !bbsBeats.isEmpty || !bbSongs.isEmpty }

    /// What a Songs-tab row plays.
    /// - bb: the imported bb version (a "bb songs" folder), else the .BBS beat of the song's
    ///   style with the song's own bass and percussion on top (`extras`; `load` builds that).
    /// - MIDI: the song's own drum pattern (`original`).
    /// - Similar: the closest factory groove (not `exact`).
    /// Cheap: for list rows.
    func resolve(_ row: SongRow) -> (song: SongInfo, exact: Bool, original: Bool, extras: SongInfo?)? {
        let entry = row.entry
        let own = songDrums[SongIndex.songKey(artist: entry.artist, title: entry.title)]
        switch row.version {
        case .bb:
            if let v = bbVersion(of: entry) { return (v, true, false, nil) }
            return bbsBeats[SongIndex.normalize(entry.style)].map { ($0, true, false, own) }
        case .midi:
            return own.map { ($0, true, true, $0) }
        case .similar:
            return au.library.song(for: entry.target).map { ($0, false, false, nil) }
        }
    }

    /// Loads a song in the row's version, at the song's tempo.
    func load(_ row: SongRow) {
        guard let (beat, _, original, extras) = resolve(row) else {
            importMessage = "No groove found for “\(row.entry.title)” (\(row.entry.target.label))."
            return
        }
        // A .BBS beat keeps its parts; the song's own bass and percussion come on top.
        let song = original ? beat : extras.flatMap { au.library.beat(beat, withBassAndPercussionOf: $0) } ?? beat
        select(song)
        loadedRow = row
        tempo = min(max(SongIndex.playTempo(indexBPM: row.entry.bpm, drumsTempo: song.tempo, ownDrums: original), 30), 300)
        set(.tempo, tempo)
        if hostSync { hostSync = false; set(.hostSync, 0) }
    }

    func select(_ song: SongInfo) {
        loadedRow = nil
        selectedSong = song.id
        set(.song, Double(song.id))
        tempo = song.tempo
        set(.tempo, song.tempo)
        loadMix(forKey: song.key)
        // Keep an open Mix Song sheet pointed at the newly selected song.
        if songMixer != nil {
            songMixer = makeMixer(for: song)
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
        songMixer = makeMixer(for: song)
    }

    /// Mixer for `song` with a strip for each voice it plays: its patterns, the accent crash and
    /// kick, and the percussion layers that play with it (own ones, else the generated ones with Auto).
    private func makeMixer(for song: SongInfo) -> SongMixer {
        var voices = au.library.usedDrums(song)
        let own = au.library.percussion(for: song)
        let layers = own.isEmpty && percAuto ? au.library.autoPercussion(for: song) : own
        for inst in layers { voices.insert(inst.drum) }
        return SongMixer(key: song.key, name: song.name,
                         voices: Drum.allCases.filter { voices.contains($0) }, hasBass: song.hasBass)
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

    /// `.pbkit` files anywhere in a folder (read while the caller holds the folder's access).
    nonisolated static func kitFiles(in folder: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return en.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "pbkit" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Whether a folder holds songs to import: MIDI files, song.json or a .BBS SONGS folder.
    nonisolated static func hasSongFiles(in folder: URL) -> Bool {
        if BBSImport.songsFolder(in: folder) != nil { return true }
        guard let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        return en.contains { f in
            guard let f = f as? URL else { return false }
            return ["mid", "midi", "smf"].contains(f.pathExtension.lowercased()) || f.lastPathComponent.lowercased() == SongLibrary.songFileName
        }
    }

    /// `selectLast`: switch to the last imported kit (picking kits); a whole folder of kits keeps the current one.
    func importKits(_ urls: [URL], selectLast: Bool = true) {
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
        if selectLast, let id = lastID, let idx = au.kits.index(forID: id) { selectKit(idx) }
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

    /// Most MIDI files (and song.json files) one folder import reads. Room for the bb Songs
    /// folder (≈ 18 000 files: beats, the songs' bb versions and their percussion) or the MIDI
    /// Songs one (≈ 15 000) with room to spare; each file is at most 4 MB.
    nonisolated static let maxFolderFiles = 40_000

    /// Imports whole folders of MIDI files (e.g. a loop pack). Runs off the main thread;
    /// every pack/style folder becomes a group in the song browser.
    func importFolders(_ urls: [URL]) {
        guard !importing else { return }
        importing = true
        let library = au.library
        Task.detached(priority: .userInitiated) { [weak self] in
            var entries: [MIDIFolderImport.Entry] = []
            var limited = false
            let maxFiles = PedalViewModel.maxFolderFiles
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
        let layers = PercussionInstrument.allCases.compactMap { i in
            r.percussion[i].map { "\($0) \(i.name.lowercased()) part\($0 == 1 ? "" : "s")" }
        }
        if found == 0 { msg = "No MIDI files found in that folder." }
        else if r.songs.isEmpty && layers.isEmpty { msg = "None of the \(found) MIDI files contained drum notes." }
        else if r.songs.isEmpty { msg = "" }
        else {
            msg = "Imported \(r.songs.count) song\(r.songs.count == 1 ? "" : "s") in \(r.groups.count) group\(r.groups.count == 1 ? "" : "s")"
            msg += r.groups.count <= 4 ? ": " + r.groups.joined(separator: ", ") + "." : "."
        }
        if !layers.isEmpty {
            msg += (msg.isEmpty ? "" : " ") + "Imported percussion: " + layers.joined(separator: ", ")
                + ". They play with the song of the same artist and title from “drum songs”; switch them in the Percussion section."
        }
        if !r.skipped.isEmpty { msg += " Skipped \(r.skipped.count) file\(r.skipped.count == 1 ? "" : "s") without usable drum notes." }
        if limited { msg += " Only the first \(PedalViewModel.maxFolderFiles) files were read." }
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
        // Kits inside a picked folder (e.g. "PedalBeat Kits" next to the installer) install like picked
        // .pbkit files; the folder's songs (if any) import as usual.
        var songFolders: [URL] = []
        for f in folders {
            let scoped = f.startAccessingSecurityScopedResource()
            defer { if scoped { f.stopAccessingSecurityScopedResource() } }
            let kits = PedalViewModel.kitFiles(in: f)
            if !kits.isEmpty { importKits(kits, selectLast: false) }
            if kits.isEmpty || PedalViewModel.hasSongFiles(in: f) { songFolders.append(f) }
        }
        if !songFolders.isEmpty { importFolders(songFolders) }
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

    /// Plays one file of the song being edited (with its bass line) with the current kit and tempo.
    func previewFile(_ editor: SongEditor, _ name: String) {
        guard let pattern = au.library.previewPattern(forKey: editor.key, file: name) else {
            importMessage = "“\(name)” can't be played."
            return
        }
        editor.previewingFile = name
        let role = editor.info(name)?.role
        engine.preview(pattern: pattern, loop: role == "Groove" || role == "Bass",
                       bass: au.library.previewBassPattern(forKey: editor.key, file: name) ?? -1)
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
