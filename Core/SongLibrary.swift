import Foundation
import CryptoKit

/// Song metadata + user imports. Owns the factory library build and keeps the
/// index order identical to the engine's SongStore.
public final class SongLibrary: @unchecked Sendable {
    public struct ImportedFile: Sendable { public var name: String; public var data: Data }
    public struct ImportRecord: Sendable {
        public var name: String
        public var files: [ImportedFile]
        public var key: String
        public var genre: String = "My Songs"
        /// Which file plays where (automatic from names unless edited).
        public var layout: MIDISongImporter.SongLayout? = nil
    }

    /// A file of an imported song, as shown in the song editor.
    public struct FileInfo: Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var bars: Int
        public var signature: String
        public var role: String
    }

    public struct FolderImportResult: Sendable {
        public var songs: [SongInfo]
        public var groups: [String]
        public var skipped: [String]
    }

    public let store: SongStore
    private let lock = NSLock()
    private var _songs: [SongInfo] = []
    private var _imports: [ImportRecord] = []
    private var superseded = Set<Int>()   // store indices replaced by an edited version
    private var previewCache: [String: Int32] = [:]
    private var drafts: [String: ImportRecord] = [:]   // factory songs opened in the editor, not saved yet
    public var onChange: (() -> Void)?
    /// When set, user imports are saved here and restored at launch (shared by all projects).
    private var userLibraryURL: URL?
    private let saveQueue = DispatchQueue(label: "pedalbeat.library.save", qos: .utility)

    public init(store: SongStore) {
        self.store = store
        for song in FactoryLibrary.build() { add(song) }
    }

    public var songs: [SongInfo] { lock.lock(); defer { lock.unlock() }; return _songs }
    public var imports: [ImportRecord] { lock.lock(); defer { lock.unlock() }; return _imports }

    public var genres: [String] {
        var seen = Set<String>(); var out: [String] = []
        for s in songs where seen.insert(s.genre).inserted { out.append(s.genre) }
        return out
    }

    public func song(at index: Int) -> SongInfo? {
        let s = songs
        return index >= 0 && index < s.count ? s[index] : nil
    }

    /// The current (latest edited) version of a song.
    public func index(forKey key: String) -> Int? {
        lock.lock(); let gone = superseded; lock.unlock()
        return songs.last { $0.key == key && !gone.contains($0.id) }?.id
    }

    @discardableResult
    private func add(_ song: SongData) -> SongInfo? {
        guard let idx = try? store.add(song) else { return nil }
        let info = SongInfo(id: idx, name: song.name, genre: song.genre, tempo: song.tempo,
                            timeSignature: song.timeSignature, partCount: song.parts.count,
                            hasIntro: song.intro != nil, hasOutro: song.outro != nil, kitHint: song.kitHint,
                            isUser: song.isUser, key: song.key)
        lock.lock(); _songs.append(info); lock.unlock()
        return info
    }

    private static func hashKey(_ files: [ImportedFile]) -> String {
        var h = SHA256()
        for f in files.sorted(by: { $0.name < $1.name }) { h.update(data: Data(f.name.utf8)); h.update(data: f.data) }
        return "user/" + h.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Imports MIDI files. `asOneSong` groups them as parts of one song
    /// (intro/fill/outro detected from file names); otherwise each file is a song.
    @discardableResult
    public func importMIDI(_ files: [ImportedFile], asOneSong: Bool, songName: String? = nil,
                           genre: String = "My Songs") throws -> [SongInfo] {
        let groups: [[ImportedFile]] = asOneSong ? [files] : files.map { [$0] }
        var added: [SongInfo] = []
        var firstError: Error?
        for group in groups {
            let baseName = songName ?? (group.count == 1
                ? (group[0].name as NSString).deletingPathExtension
                : commonName(group.map(\.name)))
            do {
                if let info = try addImport(name: baseName, genre: genre, files: group) { added.append(info) }
            } catch { firstError = firstError ?? error }
        }
        if added.isEmpty, let firstError { throw firstError }
        save()
        onChange?()
        return added
    }

    /// Imports a folder tree (see `MIDIFolderImport`): one browser group per pack/style folder.
    public func importFolder(_ entries: [MIDIFolderImport.Entry]) -> FolderImportResult {
        let plan = MIDIFolderImport.plan(entries)
        var added: [SongInfo] = []
        var groups: [String] = []
        var skipped = plan.skipped
        for g in plan.groups {
            do {
                if let info = try addImport(name: g.name, genre: g.genre, files: g.files, layout: g.layout) {
                    added.append(info)
                    if !groups.contains(g.genre) { groups.append(g.genre) }
                }
            } catch { skipped.append("\(g.genre)/\(g.name)") }
        }
        save()
        onChange?()
        return FolderImportResult(songs: added, groups: groups, skipped: skipped)
    }

    /// Builds and registers one imported song; returns the existing song for duplicate imports.
    private func addImport(name: String, genre: String, files: [ImportedFile],
                           layout: MIDISongImporter.SongLayout? = nil, key explicitKey: String? = nil) throws -> SongInfo? {
        let key = explicitKey ?? SongLibrary.hashKey(files)
        // An edited factory song replaces the original (same key, same group).
        let factory = songs.first { $0.key == key && !$0.isUser }
        if let idx = index(forKey: key), let existing = song(at: idx), existing.isUser {
            // Re-importing something that was removed brings it back.
            lock.lock()
            if !_imports.contains(where: { $0.key == key }) {
                _imports.append(ImportRecord(name: existing.name, files: files, key: key, genre: existing.genre, layout: layout))
            }
            lock.unlock()
            return existing
        }
        let parsed = try files.map { try MIDIDrumFile(data: $0.data, name: $0.name) }
        guard let l = layout ?? MIDISongImporter.layout(for: parsed),
              let data = MIDISongImporter.makeSong(name: name, files: parsed, layout: l, key: key, genre: genre),
              let info = add(data) else { return nil }
        lock.lock()
        _imports.append(ImportRecord(name: name, files: files, key: key, genre: genre, layout: l))
        if let factory { superseded.insert(factory.id) }
        lock.unlock()
        return info
    }

    // MARK: Song editor

    public func importRecord(forKey key: String) -> ImportRecord? {
        if let r = imports.first(where: { $0.key == key }) { return r }
        lock.lock(); defer { lock.unlock() }
        return drafts[key]
    }

    /// True when the song is a factory song or an edited copy of one.
    public func hasFactoryOriginal(key: String) -> Bool { songs.contains { $0.key == key && !$0.isUser } }
    /// True when the factory song has been replaced by an edited copy.
    public func isEditedFactorySong(key: String) -> Bool {
        hasFactoryOriginal(key: key) && imports.contains { $0.key == key }
    }

    /// Prepares a song for the editor. Imported songs are edited directly; a factory song is
    /// turned into MIDI files (Intro, Groove A…, Groove A Fill 1…, Transition, Ending) kept as a
    /// draft until it is saved, so cancelling leaves the factory song untouched.
    public func beginEditing(_ song: SongInfo) -> ImportRecord? {
        if let r = importRecord(forKey: song.key) { return r }
        guard let draft = factoryRecord(song) else { return nil }
        lock.lock(); drafts[song.key] = draft; lock.unlock()
        return draft
    }

    /// A factory song as MIDI files plus its exact layout.
    private func factoryRecord(_ song: SongInfo) -> ImportRecord? {
        guard !song.isUser, song.id >= 0, song.id < store.count else { return nil }
        let rec = store.songs[song.id]
        func pattern(_ idx: Int32) -> PatternData? {
            guard idx >= 0 else { return nil }
            let pr = store.patterns[Int(idx)]
            let evs = (0..<Int(pr.count)).map { store.events[Int(pr.start) + $0] }
            return PatternData(events: evs, length: Int(pr.length))
        }
        var files: [ImportedFile] = []
        func file(_ name: String, _ p: PatternData?) -> String? {
            guard let p else { return nil }
            files.append(ImportedFile(name: name, data: MIDIWriter.drumFile(p, tempo: song.tempo, signature: song.timeSignature,
                                                                            barTicks: Int(rec.barTicks), beatTicks: Int(rec.beatTicks))))
            return name
        }
        let letters = Array("ABCDEFGH")
        let intro = file("Intro.mid", pattern(rec.intro))
        var parts: [MIDISongImporter.SongLayout.Part] = []
        for i in 0..<Int(rec.partCount) {
            let groove = "Groove \(letters[i])"
            guard let main = file("\(groove).mid", pattern(store.partMain[song.id * SongStore.maxParts + i])) else { continue }
            let fills = (0..<store.fillCount(song: song.id, part: i)).compactMap {
                file("\(groove) Fill \($0 + 1).mid", pattern(store.fill(song: song.id, part: i, $0)))
            }
            parts.append(.init(main: main, fills: fills))
        }
        let layout = MIDISongImporter.SongLayout(
            intro: intro, parts: parts, transition: file("Transition.mid", pattern(rec.transition)),
            outro: file("Ending.mid", pattern(rec.outro)),
            introCrash: rec.introCrash, fillCrash: rec.fillCrash, kitHint: song.kitHint)
        return ImportRecord(name: song.name, files: files, key: song.key, genre: song.genre, layout: layout)
    }

    // MARK: Export

    /// Contents of the `song.json` written next to an exported song's MIDI files.
    public struct SongFile: Codable, Sendable {
        public var format = 1
        public var name: String
        public var genre: String
        public var layout: MIDISongImporter.SongLayout
    }
    public static let songFileName = "song.json"

    /// Folder name for a song: "Rock 9 · Straight Eights / Driving" -> "09 Straight Eights + Driving".
    public static func folderName(for song: SongInfo) -> String {
        let parts = song.name.components(separatedBy: " · ")
        var title = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : song.name
        if parts.count > 1, let n = parts[0].split(separator: " ").last.flatMap({ Int($0) }) {
            title = String(format: "%02d %@", n, title)
        }
        return safeFileName(title.replacingOccurrences(of: " / ", with: " + "))
    }

    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let cleaned = s.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "Song" : cleaned
    }

    /// Writes a song (factory or imported) as MIDI files plus `song.json` into `folder`.
    /// Importing the folder again with folder import recreates the song exactly.
    public func exportSong(_ song: SongInfo, to folder: URL) throws {
        // Imported songs and edited factory songs export what's in the library; factory songs as built.
        guard let rec = imports.first(where: { $0.key == song.key }) ?? factoryRecord(song) else { throw EditError.notFound }
        guard let layout = rec.layout ?? automaticLayout(forKey: song.key) else { throw EditError.noParts }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for f in rec.files {
            try f.data.write(to: folder.appendingPathComponent(SongLibrary.safeFileName(f.name)), options: .atomic)
        }
        // File names in the layout must match what was written.
        func safe(_ n: String?) -> String? { n.map(SongLibrary.safeFileName) }
        var l = layout
        l.intro = safe(l.intro); l.transition = safe(l.transition); l.outro = safe(l.outro)
        l.parts = l.parts.map { .init(main: SongLibrary.safeFileName($0.main), fills: $0.fills.map(SongLibrary.safeFileName)) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try enc.encode(SongFile(name: song.name, genre: song.genre, layout: l))
        try json.write(to: folder.appendingPathComponent(SongLibrary.songFileName), options: .atomic)
    }

    /// Exports songs into `root/<Genre>/<NN Title>/`. Returns the number written.
    @discardableResult
    public func exportSongs(_ songs: [SongInfo], to root: URL) throws -> Int {
        var n = 0
        for s in songs {
            try exportSong(s, to: root.appendingPathComponent(SongLibrary.safeFileName(s.genre), isDirectory: true)
                                     .appendingPathComponent(SongLibrary.folderName(for: s), isDirectory: true))
            n += 1
        }
        return n
    }

    /// Drops an unsaved factory-song draft.
    public func cancelEditing(key: String) {
        lock.lock(); drafts.removeValue(forKey: key); lock.unlock()
    }

    /// Removes the edited copy of a factory song and shows the original again.
    @discardableResult
    public func revertToFactory(key: String) -> SongInfo? {
        guard let factory = songs.first(where: { $0.key == key && !$0.isUser }) else { return nil }
        lock.lock()
        _imports.removeAll { $0.key == key }
        drafts.removeValue(forKey: key)
        for s in _songs where s.key == key && s.isUser { superseded.insert(s.id) }
        superseded.remove(factory.id)
        lock.unlock()
        save()
        onChange?()
        return factory
    }

    /// Bars, time signature and guessed role of each file of an imported song.
    public func fileInfo(forKey key: String) -> [FileInfo] {
        guard let rec = importRecord(forKey: key) else { return [] }
        return rec.files.compactMap { f in
            guard let m = try? MIDIDrumFile(data: f.data, name: f.name) else { return nil }
            let role: String
            switch MIDISongImporter.role(for: f.name) {
            case .intro: role = "Intro"
            case .outro: role = "Ending"
            case .transition: role = "Transition"
            case .fill: role = "Fill"
            case .main: role = "Groove"
            }
            return FileInfo(name: f.name, bars: max(1, Int((Double(m.lengthTicks) / Double(max(m.barTicks, 1))).rounded(.up))),
                            signature: m.signature, role: role)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A stored pattern for auditioning one file of an imported song (cached per file).
    public func previewPattern(forKey key: String, file: String) -> Int32? {
        let cacheKey = key + "/" + file
        lock.lock(); let cached = previewCache[cacheKey]; lock.unlock()
        if let cached { return cached }
        guard let f = importRecord(forKey: key)?.files.first(where: { $0.name == file }),
              let m = try? MIDIDrumFile(data: f.data, name: f.name),
              let idx = try? store.addPattern(m.pattern) else { return nil }
        lock.lock(); previewCache[cacheKey] = idx; lock.unlock()
        return idx
    }

    /// The automatic layout of an imported song (for "Reset to automatic").
    public func automaticLayout(forKey key: String) -> MIDISongImporter.SongLayout? {
        guard let rec = importRecord(forKey: key) else { return nil }
        return MIDISongImporter.layout(for: rec.files.compactMap { try? MIDIDrumFile(data: $0.data, name: $0.name) })
    }

    public enum EditError: LocalizedError {
        case notFound, noParts
        public var errorDescription: String? {
            switch self {
            case .notFound: "This song can't be edited (it isn't an imported song)."
            case .noParts: "A song needs at least one part with a groove."
            }
        }
    }

    /// Rebuilds an imported song with a new layout and name. The edited version keeps the
    /// song's key (so projects find it) and replaces the old one in the browser.
    @discardableResult
    public func updateSong(key: String, name: String, layout: MIDISongImporter.SongLayout) throws -> SongInfo {
        guard let rec = importRecord(forKey: key), let old = index(forKey: key) else { throw EditError.notFound }
        lock.lock(); let draft = drafts[key]; lock.unlock()
        if let draft, !imports.contains(where: { $0.key == key }) {
            // First save of an edited factory song: register the copy (it replaces the original).
            guard !layout.parts.isEmpty else { throw EditError.noParts }
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let info = try addImport(name: clean.isEmpty ? draft.name : clean, genre: draft.genre,
                                           files: draft.files, layout: layout, key: key)
            else { throw EditError.noParts }
            lock.lock(); drafts.removeValue(forKey: key); lock.unlock()
            save()
            onChange?()
            return info
        }
        let parsed = rec.files.compactMap { try? MIDIDrumFile(data: $0.data, name: $0.name) }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = MIDISongImporter.makeSong(name: cleanName.isEmpty ? rec.name : cleanName, files: parsed,
                                                   layout: layout, key: key, genre: rec.genre)
        else { throw EditError.noParts }
        guard let info = add(data) else { throw SongStore.StoreError.full }
        lock.lock()
        superseded.insert(old)
        if let i = _imports.firstIndex(where: { $0.key == key }) {
            _imports[i].name = data.name
            _imports[i].layout = layout
        }
        lock.unlock()
        save()
        onChange?()
        return info
    }

    private func commonName(_ names: [String]) -> String {
        let stems = names.map { ($0 as NSString).deletingPathExtension }
        guard var prefix = stems.first else { return "Imported Song" }
        for s in stems.dropFirst() {
            while !s.hasPrefix(prefix) && !prefix.isEmpty { prefix.removeLast() }
        }
        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: " _-.0123456789"))
        return trimmed.isEmpty ? "Imported Song" : trimmed
    }

    /// Removes a user song from the browser (storage stays allocated until reload).
    public func hide(key: String) {
        if hasFactoryOriginal(key: key) { revertToFactory(key: key); return }
        lock.lock(); _imports.removeAll { $0.key == key }; lock.unlock()
        save()
        onChange?()
    }

    /// Removes every imported song of a browser group (e.g. a whole imported pack folder).
    public func hide(genre: String) {
        lock.lock(); _imports.removeAll { $0.genre == genre }; lock.unlock()
        save()
        onChange?()
    }

    // MARK: Persistence

    static func plist(_ records: [ImportRecord]) -> [[String: Any]] {
        records.map { rec in
            var d: [String: Any] = ["name": rec.name, "key": rec.key, "genre": rec.genre,
                                    "files": rec.files.map { ["name": $0.name, "data": $0.data] as [String: Any] }]
            if let l = rec.layout, let json = try? JSONEncoder().encode(l) { d["layout"] = json }
            return d
        }
    }

    /// All user imports (property-list form).
    public var importsPropertyList: [[String: Any]] { SongLibrary.plist(imports) }

    /// Only the import that holds `key` (saved in a host project so it opens anywhere).
    public func importsPropertyList(forKey key: String) -> [[String: Any]] {
        SongLibrary.plist(imports.filter { $0.key == key })
    }

    public func restoreImports(_ plist: [[String: Any]]) {
        var changed = false
        for rec in plist {
            guard let name = rec["name"] as? String, let files = rec["files"] as? [[String: Any]] else { continue }
            let f = files.compactMap { d -> ImportedFile? in
                guard let n = d["name"] as? String, let data = d["data"] as? Data else { return nil }
                return ImportedFile(name: n, data: data)
            }
            let genre = rec["genre"] as? String ?? "My Songs"
            let layout = (rec["layout"] as? Data).flatMap { try? JSONDecoder().decode(MIDISongImporter.SongLayout.self, from: $0) }
            let key = rec["key"] as? String
            if (try? addImport(name: name, genre: genre, files: f, layout: layout, key: key)) != nil { changed = true }
        }
        if changed { save(); onChange?() }
    }

    /// Loads the shared user library and keeps it saved there from now on.
    public func useUserLibrary(at url: URL) {
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] {
            restoreImports(plist)
        }
        lock.lock(); userLibraryURL = url; lock.unlock()
    }

    private func save() {
        lock.lock(); let url = userLibraryURL; lock.unlock()
        guard let url else { return }
        let plist = importsPropertyList
        saveQueue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Songs visible in the browser (hidden imports excluded).
    public var visibleSongs: [SongInfo] {
        let keys = Set(imports.map(\.key))
        lock.lock(); let gone = superseded; lock.unlock()
        return songs.filter { (!$0.isUser || keys.contains($0.key)) && !gone.contains($0.id) }
    }
}
