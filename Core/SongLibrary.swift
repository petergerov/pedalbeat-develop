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
        public var hasBass = false
    }

    public struct FolderImportResult: Sendable {
        public var songs: [SongInfo]
        public var groups: [String]
        public var skipped: [String]
        /// Percussion layers imported (or already there) per instrument, from "shaker_songs" & co.
        public var percussion: [PercussionInstrument: Int] = [:]
    }

    /// A percussion layer: its store index and the import it came from (built-in layers come with the
    /// song pack: they are not saved with the imports and can't be removed).
    private struct PercLayer { var track: Int32; var importKey: String; var builtIn = false }

    public let store: SongStore
    private let lock = NSLock()
    private var _songs: [SongInfo] = []
    private var _imports: [ImportRecord] = []
    private var superseded = Set<Int>()   // store indices replaced by an edited version
    private var previewCache: [String: Int32] = [:]
    private var drafts: [String: ImportRecord] = [:]   // factory songs opened in the editor, not saved yet
    /// Percussion layers by song (artist + title, `SongIndex.linkKey`) and instrument.
    private var _percussion: [String: [PercussionInstrument: PercLayer]] = [:]
    /// Every layer ever built this session by import key (a re-import after removal reuses it).
    private var percByImport: [String: (instrument: PercussionInstrument, link: String, track: Int32)] = [:]
    /// Store indices of songs by artist + title, for linking their percussion.
    private var songsByLink: [String: [Int]] = [:]
    /// The song pack's layers, which come back when an import that replaced one is removed.
    private var builtInPercussion: [String: [PercussionInstrument: PercLayer]] = [:]
    /// Beats with another song's bass and percussion on top (`beat(_:withBassAndPercussionOf:)`), by pair.
    private var layered: [String: SongInfo] = [:]
    /// Parts of a layered beat whose bass was generated from the beat's kick (the song's did not fit).
    private var layeredGenerated: [Int: Int] = [:]
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

    /// A song of the Songs tab (its own drums, or a beat layered with a song's bass and percussion),
    /// as opposed to a beat (factory groove, bb beat, the user's own import).
    static func isSong(_ song: SongData) -> Bool {
        song.key.hasPrefix(layeredKeyPrefix) || SongIndex.isDrumSongPack(song.genre.components(separatedBy: " › ").first ?? "")
    }
    static let layeredKeyPrefix = "layered/"

    /// Adds a song to the store. A beat without bass gets a generated line (on by default, the Bass
    /// switch turns it off), and every beat gets generated percussion that plays with Auto Percussion.
    @discardableResult
    private func add(_ original: SongData) -> SongInfo? {
        var song = original
        let beat = !SongLibrary.isSong(song)
        if beat { BassGenerator.apply(to: &song, seed: song.name.utf8.reduce(0) { $0 &+ Int($1) }) }
        guard let idx = try? store.add(song) else { return nil }
        if beat {
            for layer in PercussionGenerator.layers(for: song) {
                guard let t = try? store.addPercussion(layer) else { break }    // store full: no more generated layers
                store.setAutoPercussion(t, song: idx, instrument: layer.instrument)
            }
        }
        let info = SongInfo(id: idx, name: song.name, genre: song.genre, tempo: song.tempo,
                            timeSignature: song.timeSignature, partCount: song.parts.count,
                            hasIntro: song.intro != nil, hasOutro: song.outro != nil, kitHint: song.kitHint,
                            isUser: song.isUser, key: song.key, hasBass: song.hasBass)
        let link = SongIndex.linkKey(genre: song.genre, name: song.name)
        lock.lock()
        _songs.append(info)
        var layers: [PercussionInstrument: PercLayer] = [:]
        if let link { songsByLink[link, default: []].append(idx); layers = _percussion[link] ?? [:] }
        lock.unlock()
        // Percussion imported before its song plays with it now.
        for (inst, layer) in layers { store.setPercussion(layer.track, song: idx, instrument: inst) }
        return info
    }

    /// `salt` tells apart imports with identical files (two songs' shakers can be note for note the same).
    private static func hashKey(_ files: [ImportedFile], salt: String = "") -> String {
        var h = SHA256()
        h.update(data: Data(salt.utf8))
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
        var percussion: [PercussionInstrument: Int] = [:]
        for g in plan.groups {
            do {
                if PercussionInstrument.layer(genre: g.genre, name: g.name) != nil {
                    if let inst = try addPercussionImport(name: g.name, genre: g.genre, files: g.files, layout: g.layout) {
                        percussion[inst, default: 0] += 1
                    } else { skipped.append("\(g.genre)/\(g.name)") }
                } else if let info = try addImport(name: g.name, genre: g.genre, files: g.files, layout: g.layout) {
                    added.append(info)
                    if !groups.contains(g.genre) { groups.append(g.genre) }
                }
            } catch { skipped.append("\(g.genre)/\(g.name)") }
        }
        save()
        onChange?()
        return FolderImportResult(songs: added, groups: groups, skipped: skipped, percussion: percussion)
    }

    // MARK: Percussion layers

    /// Builds and registers a percussion layer (`shaker songs › Artist` / title) and plays it with the
    /// song of the same artist and title. Returns its instrument; nil if its files have none of its notes.
    private func addPercussionImport(name: String, genre: String, files: [ImportedFile],
                                     layout: MIDISongImporter.SongLayout? = nil, key explicitKey: String? = nil) throws -> PercussionInstrument? {
        guard let (inst, link) = PercussionInstrument.layer(genre: genre, name: name) else { return nil }
        let key = explicitKey ?? SongLibrary.hashKey(files, salt: genre + "/" + name)
        lock.lock()
        let known = percByImport[key]
        let listed = _imports.contains { $0.key == key }
        lock.unlock()
        if listed { return inst }
        var track: Int32
        var savedLayout = layout
        if let known {
            track = known.track   // removed earlier and imported again
        } else {
            let parsed = try files.map { try MIDIDrumFile(data: $0.data, name: $0.name) }
            guard let l = layout ?? MIDISongImporter.layout(for: parsed),
                  let data = PercussionData.make(files: parsed, layout: l, instrument: inst) else { return nil }
            track = try store.addPercussion(data)
            savedLayout = l
        }
        lock.lock()
        // A newer import of the same song's instrument replaces the old one.
        if let old = _percussion[link]?[inst], old.importKey != key { _imports.removeAll { $0.key == old.importKey } }
        _imports.append(ImportRecord(name: name, files: files, key: key, genre: genre, layout: savedLayout))
        _percussion[link, default: [:]][inst] = PercLayer(track: track, importKey: key)
        percByImport[key] = (inst, link, track)
        let songs = songsByLink[link] ?? []
        lock.unlock()
        for s in songs { store.setPercussion(track, song: s, instrument: inst) }
        return inst
    }

    /// Stops the layers whose import was removed; the song pack's own layer takes over again if there is one.
    private func unlinkRemovedPercussion() {
        lock.lock()
        let keys = Set(_imports.map(\.key))
        var gone: [(link: String, inst: PercussionInstrument)] = []
        for (link, layers) in _percussion {
            for (inst, l) in layers where !l.builtIn && !keys.contains(l.importKey) { gone.append((link, inst)) }
        }
        var relink: [(song: Int, inst: PercussionInstrument, track: Int32)] = []
        for g in gone {
            let fallback = builtInPercussion[g.link]?[g.inst]
            _percussion[g.link]?[g.inst] = fallback
            if _percussion[g.link]?.isEmpty == true { _percussion[g.link] = nil }
            for s in songsByLink[g.link] ?? [] { relink.append((s, g.inst, fallback?.track ?? -1)) }
        }
        lock.unlock()
        for r in relink { store.setPercussion(r.track, song: r.song, instrument: r.inst) }
    }

    /// Instruments with a layer for this song (by artist + title; songs from "drum songs" folders).
    public func percussion(for song: SongInfo) -> [PercussionInstrument] {
        guard let link = SongIndex.linkKey(genre: song.genre, name: song.name) else { return [] }
        lock.lock(); defer { lock.unlock() }
        return (_percussion[link] ?? [:]).keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// Instruments of the generated layers of a beat (Auto Percussion); empty for songs.
    public func autoPercussion(for song: SongInfo) -> [PercussionInstrument] {
        PercussionInstrument.allCases.filter { store.autoPercussion(song: song.id, instrument: $0.rawValue) >= 0 }
    }

    /// Number of imported layers per instrument (the song pack's own are not counted: they can't be removed).
    public var percussionCounts: [PercussionInstrument: Int] {
        lock.lock(); defer { lock.unlock() }
        var n: [PercussionInstrument: Int] = [:]
        for layers in _percussion.values { for (inst, l) in layers where !l.builtIn { n[inst, default: 0] += 1 } }
        return n
    }

    /// Removes every imported layer of an instrument.
    public func removePercussion(_ inst: PercussionInstrument) {
        lock.lock()
        let keys = Set(_percussion.values.compactMap { $0[inst] }.filter { !$0.builtIn }.map(\.importKey))
        _imports.removeAll { keys.contains($0.key) }
        lock.unlock()
        unlinkRemovedPercussion()
        save()
        onChange?()
    }

    // MARK: Song pack

    /// Loads the songs and percussion that ship inside the plug-in (see `ContentPack`). They are built
    /// in like factory songs: not saved with the imports, editable as a copy. Returns the songs added.
    @discardableResult
    public func loadContentPack(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let pack = try? ContentPack.decode(data) else { return 0 }
        // Two packs may carry the same song or layer (e.g. a song's percussion in both song packs): the first wins.
        for layer in pack.percussion {
            guard let (inst, link) = PercussionInstrument.layer(genre: layer.genre, name: layer.name) else { continue }
            lock.lock(); let known = builtInPercussion[link]?[inst] != nil; lock.unlock()
            guard !known, let track = try? store.addPercussion(layer.data) else { continue }
            let l = PercLayer(track: track, importKey: ContentPack.keyPrefix + link, builtIn: true)
            lock.lock()
            builtInPercussion[link, default: [:]][inst] = l
            if _percussion[link]?[inst] == nil { _percussion[link, default: [:]][inst] = l }
            let songs = songsByLink[link] ?? []
            lock.unlock()
            for s in songs { store.setPercussion(track, song: s, instrument: inst) }
        }
        var added = 0
        let loaded = Set(songs.filter { !$0.isUser }.map(\.key))
        for s in pack.songs where !loaded.contains(s.key) && add(s) != nil { added += 1 }
        return added
    }

    /// The percussion imports that play with a song (a host project keeps them with the song).
    public func percussionPropertyList(for song: SongInfo) -> [[String: Any]] {
        guard let link = SongIndex.linkKey(genre: song.genre, name: song.name) else { return [] }
        lock.lock(); let keys = Set((_percussion[link] ?? [:]).values.map(\.importKey)); lock.unlock()
        return SongLibrary.plist(imports.filter { keys.contains($0.key) })
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
        song.isUser ? nil : storeRecord(song)
    }

    /// Any stored song (also a layered beat, which is no import) as MIDI files plus its exact layout.
    private func storeRecord(_ song: SongInfo) -> ImportRecord? {
        guard song.id >= 0, song.id < store.count else { return nil }
        let rec = store.songs[song.id]
        func pattern(_ idx: Int32) -> PatternData? {
            guard idx >= 0 else { return nil }
            let pr = store.patterns[Int(idx)]
            let evs = (0..<Int(pr.count)).map { store.events[Int(pr.start) + $0] }
            return PatternData(events: evs, length: Int(pr.length))
        }
        var files: [ImportedFile] = []
        func file(_ name: String, _ p: PatternData?, bass: BassPattern? = nil) -> String? {
            guard let p else { return nil }
            files.append(ImportedFile(name: name, data: MIDIWriter.drumFile(p, tempo: song.tempo, signature: song.timeSignature,
                                                                            barTicks: Int(rec.barTicks), beatTicks: Int(rec.beatTicks),
                                                                            bass: bass)))
            return name
        }
        // Bass lines go in files of their own ("Groove A Bass.mid"), so they keep their own length.
        func bassFile(_ name: String, _ idx: Int32) -> String? {
            guard let b = store.bassPattern(idx) else { return nil }
            return file(name, PatternData(events: [], length: b.length), bass: b)
        }
        let letters = Array("ABCDEFGH")
        let intro = file("Intro.mid", pattern(rec.intro))
        var parts: [MIDISongImporter.SongLayout.Part] = []
        for i in 0..<Int(rec.partCount) {
            let groove = "Groove \(letters[i])"
            guard let main = file("\(groove).mid", pattern(store.partMain[song.id * SongStore.maxParts + i])) else { continue }
            var fills: [String] = [], fillBass: [String] = []
            for k in 0..<store.fillCount(song: song.id, part: i) {
                guard let f = file("\(groove) Fill \(k + 1).mid", pattern(store.fill(song: song.id, part: i, k))) else { continue }
                fills.append(f)
                fillBass.append(bassFile("\(groove) Fill \(k + 1) Bass.mid", store.fillBass(song: song.id, part: i, k)) ?? "")
            }
            parts.append(.init(main: main, fills: fills, bass: bassFile("\(groove) Bass.mid", store.bass(song: song.id, part: i)),
                               fillBass: fillBass.contains { !$0.isEmpty } ? fillBass : nil))
        }
        var layout = MIDISongImporter.SongLayout(
            intro: intro, parts: parts, transition: file("Transition.mid", pattern(rec.transition)),
            outro: file("Ending.mid", pattern(rec.outro)),
            introCrash: rec.introCrash, fillCrash: rec.fillCrash, kitHint: song.kitHint,
            introBass: bassFile("Intro Bass.mid", rec.introBass), transitionBass: bassFile("Transition Bass.mid", rec.transitionBass),
            outroBass: bassFile("Ending Bass.mid", rec.outroBass), bassEnabled: rec.bassEnabled ? nil : false,
            bassRoot: rec.bassRoot == 4 ? nil : Int(rec.bassRoot))
        let chords = LiveChord.names(Array(store.chordProfile(song: song.id)))
        if !chords.isEmpty { layout.chords = chords }
        return ImportRecord(name: song.name, files: files, key: song.key, genre: song.genre, layout: layout)
    }

    // MARK: Beat + a song's bass and percussion

    /// The beat `drums` exactly as it is (intro, parts, fills, transition, ending), with the bass lines and
    /// percussion layers of `song` on top: part `i` gets the song's groove `i` (its last one when the beat
    /// has more parts) where that line fits the part's drums (`BassGenerator.fits`); elsewhere it plays a
    /// line generated from the part's kick, on the song's root. Used for a bb beat in the Songs tab,
    /// so the beat keeps its parts and the song still brings its bass and percussion. Built once per pair
    /// and hidden from the song lists.
    /// `nil` when the meters differ or `song` has neither bass nor percussion: then play `drums` alone.
    public func beat(_ drums: SongInfo, withBassAndPercussionOf song: SongInfo) -> SongInfo? {
        let key = SongLibrary.layeredKeyPrefix + drums.key + "+" + song.key
        lock.lock()
        if let s = layered[key] { lock.unlock(); return s }
        lock.unlock()
        guard drums.id >= 0, drums.id < store.count, song.id >= 0, song.id < store.count else { return nil }
        let d = store.songs[drums.id], e = store.songs[song.id]
        guard d.barTicks == e.barTicks, d.beatTicks == e.beatTicks else { return nil }
        let link = SongIndex.linkKey(genre: song.genre, name: song.name)
        lock.lock(); let layers = link.flatMap { _percussion[$0] } ?? [:]; lock.unlock()
        guard song.hasBass || !layers.isEmpty, var data = storedSong(drums) else { return nil }

        // The song's bass where it fits the beat; elsewhere a line generated from the beat's kick,
        // on the song's root so both kinds of part sound in the same key.
        let bar = Int(d.barTicks), beatT = Int(d.beatTicks)
        func fitting(_ b: BassPattern?, _ drums: PatternData?) -> BassPattern? {
            guard let b, let drums else { return nil }
            return BassGenerator.fits(b, drums: drums, barTicks: bar, beatTicks: beatT) ? b : nil
        }
        let style = BassGenerator.style(forBeatGenre: drums.genre)
        let root = BassGenerator.root(pitchClass: Int(e.bassRoot))
        let songParts = max(Int(e.partCount), 1)
        var generated = 0
        if song.hasBass {
            for i in data.parts.indices {
                let own = store.bassPattern(store.bass(song: song.id, part: min(i, songParts - 1)))
                if let b = fitting(own, data.parts[i].main) {
                    data.parts[i].bass = b
                } else {
                    data.parts[i].bass = BassGenerator.pattern(for: data.parts[i].main, barTicks: bar, beatTicks: beatT, style: style,
                                                               role: BassGenerator.PartRole(rawValue: min(i, 2)) ?? .verse,
                                                               root: root, seed: i &* 17)
                    generated += 1
                }
                data.parts[i].fillBass = []      // the song's fill bass belongs to its own fills
            }
            data.introBass = fitting(store.bassPattern(e.introBass), data.intro)
            data.transitionBass = fitting(store.bassPattern(e.transitionBass), data.transition)
            data.outroBass = fitting(store.bassPattern(e.outroBass), data.outro)
                ?? data.outro.map { BassGenerator.pattern(for: $0, barTicks: bar, beatTicks: beatT, style: style, role: .outro, root: root, seed: 91) }
        } else {
            // The song has no bass: the beat keeps its own (generated) line.
            for i in data.parts.indices { data.parts[i].fillBass = [] }
        }
        if song.hasBass {
            data.bassEnabled = e.bassEnabled
            data.bassRootPitchClass = Int(e.bassRoot)
        }
        // The player plays the song, not the beat: Bass Follow listens for the song's chords.
        let chords = Array(store.chordProfile(song: song.id))
        data.chordProfile = chords.contains { $0 > 0 } ? chords : []
        data.name = song.name
        data.isUser = true                   // not an import: hidden from the lists
        data.key = key
        guard let info = add(data) else { return nil }
        for (inst, layer) in layers { store.setPercussion(layer.track, song: info.id, instrument: inst) }
        lock.lock()
        layered[key] = info
        layeredGenerated[info.id] = generated
        if let link { songsByLink[link, default: []].append(info.id) }   // later percussion imports follow
        lock.unlock()
        return info
    }

    /// Number of parts of a layered beat that play a generated bass line (0 = all play the song's).
    public func generatedBassParts(_ song: SongInfo) -> Int {
        lock.lock(); defer { lock.unlock() }
        return layeredGenerated[song.id] ?? 0
    }

    /// Drum voices the song's own sections play, plus crash and kick: the sequencer adds them as an
    /// accent (after the intro and fills, on a song change, at an end without outro), so any song can
    /// play them. Percussion layers are not included (see `percussion(for:)`). Main thread only.
    public func usedDrums(_ song: SongInfo) -> Set<Drum> {
        guard song.id >= 0, song.id < store.count else { return [] }
        let rec = store.songs[song.id]
        var seen = [Bool](repeating: false, count: Drum.count)
        seen[Drum.crash.rawValue] = true
        seen[Drum.kick.rawValue] = true
        func scan(_ idx: Int32) {
            guard idx >= 0 else { return }
            let pr = store.patterns[Int(idx)]
            for i in 0..<Int(pr.count) {
                let d = Int(store.events[Int(pr.start) + i].drum)
                if d < Drum.count { seen[d] = true }
            }
        }
        scan(rec.intro); scan(rec.transition); scan(rec.outro)
        for p in 0..<Int(rec.partCount) {
            scan(store.partMain[song.id * SongStore.maxParts + p])
            for k in 0..<store.fillCount(song: song.id, part: p) { scan(store.fill(song: song.id, part: p, k)) }
        }
        return Set(Drum.allCases.filter { seen[$0.rawValue] })
    }

    /// A stored song read back as data (drums, crash settings and bass; not for the audio thread).
    private func storedSong(_ info: SongInfo) -> SongData? {
        let rec = store.songs[info.id]
        func pattern(_ idx: Int32) -> PatternData? {
            guard idx >= 0 else { return nil }
            let pr = store.patterns[Int(idx)]
            return PatternData(events: (0..<Int(pr.count)).map { store.events[Int(pr.start) + $0] }, length: Int(pr.length))
        }
        var parts: [PartData] = []
        for i in 0..<Int(rec.partCount) {
            guard let main = pattern(store.partMain[info.id * SongStore.maxParts + i]) else { continue }
            let n = store.fillCount(song: info.id, part: i)
            parts.append(PartData(main: main, fills: (0..<n).compactMap { pattern(store.fill(song: info.id, part: i, $0)) },
                                  bass: store.bassPattern(store.bass(song: info.id, part: i)),
                                  fillBass: (0..<n).map { store.bassPattern(store.fillBass(song: info.id, part: i, $0)) }))
        }
        guard !parts.isEmpty else { return nil }
        var s = SongData(name: info.name, genre: info.genre, tempo: Double(rec.tempo), timeSignature: info.timeSignature,
                         barTicks: Int(rec.barTicks), beatTicks: Int(rec.beatTicks), intro: pattern(rec.intro), parts: parts,
                         transition: pattern(rec.transition), outro: pattern(rec.outro),
                         introCrash: rec.introCrash, fillCrash: rec.fillCrash, kitHint: info.kitHint, isUser: info.isUser,
                         key: info.key, bassRootPitchClass: Int(rec.bassRoot))
        s.introBass = store.bassPattern(rec.introBass)
        s.transitionBass = store.bassPattern(rec.transitionBass)
        s.outroBass = store.bassPattern(rec.outroBass)
        s.bassEnabled = rec.bassEnabled
        let profile = Array(store.chordProfile(song: info.id))
        if profile.contains(where: { $0 > 0 }) { s.chordProfile = profile }
        return s
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
        try write(rec, name: song.name, genre: song.genre, to: folder)
    }

    /// Writes a song as it plays (from the store, so also a layered beat) under another name and group,
    /// e.g. a bb beat with a song's bass as "bb songs › Eagles" / "Hotel California · Ballad 2".
    public func exportStoredSong(_ song: SongInfo, name: String, genre: String, to folder: URL) throws {
        guard let rec = storeRecord(song) else { throw EditError.notFound }
        try write(rec, name: name, genre: genre, to: folder)
    }

    private func write(_ rec: ImportRecord, name: String, genre: String, to folder: URL) throws {
        guard let layout = rec.layout ?? automaticLayout(forKey: rec.key) else { throw EditError.noParts }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for f in rec.files {
            try f.data.write(to: folder.appendingPathComponent(SongLibrary.safeFileName(f.name)), options: .atomic)
        }
        // File names in the layout must match what was written.
        func safe(_ n: String?) -> String? { n.map(SongLibrary.safeFileName) }
        var l = layout
        l.intro = safe(l.intro); l.transition = safe(l.transition); l.outro = safe(l.outro)
        l.introBass = safe(l.introBass); l.transitionBass = safe(l.transitionBass); l.outroBass = safe(l.outroBass)
        l.parts = l.parts.map {
            .init(main: SongLibrary.safeFileName($0.main), fills: $0.fills.map(SongLibrary.safeFileName), bass: safe($0.bass),
                  fillBass: $0.fillBass?.map { $0.isEmpty ? "" : SongLibrary.safeFileName($0) })
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try enc.encode(SongFile(name: name, genre: genre, layout: l))
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
            switch MIDISongImporter.role(for: m) {
            case .intro: role = "Intro"
            case .outro: role = "Ending"
            case .transition: role = "Transition"
            case .fill: role = "Fill"
            case .main: role = "Groove"
            case .bass: role = "Bass"
            }
            return FileInfo(name: f.name, bars: max(1, Int((Double(m.lengthTicks) / Double(max(m.barTicks, 1))).rounded(.up))),
                            signature: m.signature, role: role, hasBass: m.bass != nil)
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

    /// The bass line of one file of an imported song, for auditioning it with the drums (cached per file).
    public func previewBassPattern(forKey key: String, file: String) -> Int32? {
        let cacheKey = "bass:" + key + "/" + file
        lock.lock(); let cached = previewCache[cacheKey]; lock.unlock()
        if let cached { return cached }
        guard let f = importRecord(forKey: key)?.files.first(where: { $0.name == file }),
              let b = (try? MIDIDrumFile(data: f.data, name: f.name))?.bass,
              let idx = try? store.addBassPattern(b) else { return nil }
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
        unlinkRemovedPercussion()
        save()
        onChange?()
    }

    /// Removes every imported song of a browser group (e.g. a whole imported pack folder).
    public func hide(genre: String) {
        lock.lock(); _imports.removeAll { $0.genre == genre }; lock.unlock()
        unlinkRemovedPercussion()
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
            if PercussionInstrument.layer(genre: genre, name: name) != nil {
                if (try? addPercussionImport(name: name, genre: genre, files: f, layout: layout, key: key)) != nil { changed = true }
            } else if (try? addImport(name: name, genre: genre, files: f, layout: layout, key: key)) != nil { changed = true }
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
        let shown = songs.filter { (!$0.isUser || keys.contains($0.key)) && !gone.contains($0.id) }
        // A built-in beat steps aside for the user's own import of it (same group and name).
        let imported = Set(shown.filter(\.isUser).map { ContentPack.beatKey(genre: $0.genre, name: $0.name) })
        return shown.filter { $0.isUser || !$0.key.hasPrefix(ContentPack.beatKeyPrefix) || !imported.contains($0.key) }
    }
}
