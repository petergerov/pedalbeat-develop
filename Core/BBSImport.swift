import Foundation

/// Imports `.BBS` song files from a drum-pedal SD card or project folder, so the song
/// index can play the exact beat it names. Each beat becomes MIDI files plus a `song.json`,
/// which the regular folder import turns into songs in groups "BBS › <Genre>".
///
/// Folder layout:  SONGS/config.csv            "165DA150,2. Blues"
///                 SONGS/165DA150/config.csv   "9EE9EE10.BBS,1. Blues 1"
///                 SONGS/165DA150/9EE9EE10.BBS
///
/// `.BBS` layout (little endian), as far as needed here:
///   0x00 "BBSF"; 0x2C offset of the track section; 0x178 number of parts
///   0x190 + 0x60·k section blocks: k = 0 intro, 1 outro, 2… parts. Ints: [0] fill count,
///         [3] [4] time signature, [5] bar ticks, [6] main track, [7] transition track, [8…15] fills
///   tracks, back to back: 56-byte header ([2] length, byte 20 numerator, [6] PPQ = 480,
///         [7] bar ticks, [9] tempo, [13] event count), then 8-byte events:
///         tick (u32), 0 = note on / 1 = note off, GM note, velocity, 0
public enum BBSImport {
    public static let packName = "BBS"

    public enum ParseError: LocalizedError {
        case notBBS, truncated, badTrack(Int), noParts
        public var errorDescription: String? {
            switch self {
            case .notBBS: "Not a .BBS song file."
            case .truncated: "The .BBS song file is truncated."
            case .badTrack(let o): "Unreadable track at byte \(o)."
            case .noParts: "The .BBS song has no playable parts."
            }
        }
    }

    struct Note { var tick: Int; var note: UInt8; var velocity: UInt8 }
    struct Track { var length: Int; var barTicks: Int; var numerator: Int; var tempo: Int; var notes: [Note] }
    struct Block { var main: Int; var transition: Int; var fills: [Int] }
    struct BBSong { var tracks: [Track]; var intro: Block; var outro: Block; var parts: [Block] }

    // MARK: Parsing

    static func parse(_ data: Data) throws -> BBSong {
        let b = [UInt8](data)
        guard b.count >= 0x190, b[0] == 0x42, b[1] == 0x42, b[2] == 0x53, b[3] == 0x46 else { throw ParseError.notBBS }
        func i32(_ o: Int) throws -> Int {
            guard o >= 0, o + 4 <= b.count else { throw ParseError.truncated }
            return Int(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24))
        }
        let partCount = try i32(0x178)
        guard (1...64).contains(partCount) else { throw ParseError.noParts }
        func block(_ k: Int) throws -> Block {
            let o = 0x190 + 0x60 * k
            let fillCount = min(max(try i32(o), 0), 8)
            return Block(main: try i32(o + 24), transition: try i32(o + 28),
                         fills: try (0..<fillCount).map { try i32(o + 32 + 4 * $0) }.filter { $0 >= 0 })
        }
        let intro = try block(0), outro = try block(1)
        let parts = try (0..<partCount).map { try block(2 + $0) }

        var tracks: [Track] = []
        var o = try i32(0x2C)
        guard o > 0x190, o < b.count else { throw ParseError.truncated }
        while o + 56 <= b.count {
            let length = try i32(o + 8), ppq = try i32(o + 24), bar = try i32(o + 28)
            let tempo = try i32(o + 36), count = try i32(o + 52)
            guard ppq == PPQN, bar > 0, length >= 0, (0...20_000).contains(count), o + 56 + 8 * count <= b.count else {
                throw ParseError.badTrack(o)
            }
            var notes: [Note] = []
            for i in 0..<count {
                let e = o + 56 + 8 * i
                let tick = try i32(e)
                if b[e + 4] == 0, b[e + 6] > 0, tick >= 0 { notes.append(Note(tick: tick, note: b[e + 5], velocity: b[e + 6])) }
            }
            tracks.append(Track(length: length, barTicks: bar, numerator: Int(b[o + 20]), tempo: tempo, notes: notes))
            o += 56 + 8 * count
        }
        guard !tracks.isEmpty else { throw ParseError.noParts }
        return BBSong(tracks: tracks, intro: intro, outro: outro, parts: parts)
    }

    // MARK: Conversion

    /// GM drum mapping plus the metronome click (33) and bell (34) used by the metronome beats.
    static func drum(_ note: UInt8) -> Drum? {
        Drum.fromGM(note) ?? (note == 33 ? .rim : note == 34 ? .cowbell : nil)
    }

    /// Default synthesized kit for a .BBS genre (0 Studio, 2 Electro, 4 Brushes).
    static func kitHint(genre: String, name: String) -> Int {
        let g = (genre + " " + name).lowercased()
        if g.contains("brush") || g.contains("jazz") { return 4 }
        if g.contains("techno") || g.contains("drum & bass") || g.contains("beatbox") { return 2 }
        return 0
    }

    /// One .BBS song as MIDI files plus the layout that recreates it.
    static func convert(_ song: BBSong, name: String, genre: String) throws -> (files: [SongLibrary.ImportedFile], layout: MIDISongImporter.SongLayout) {
        func track(_ i: Int) -> Track? { i >= 0 && i < song.tracks.count && song.tracks[i].length > 0 ? song.tracks[i] : nil }
        let partTracks = song.parts.compactMap { p in track(p.main).map { (p, $0) } }.prefix(SongStore.maxParts)
        guard let first = partTracks.first?.1 else { throw ParseError.noParts }

        let bar = first.barTicks, num = max(first.numerator, 1)
        let den = bar > 0 && (num * PPQN * 4) % bar == 0 ? num * PPQN * 4 / bar : 4
        let beatTicks = den == 8 ? (num % 3 == 0 ? 720 : 240) : (den == 2 ? 960 : PPQN)
        let signature = "\(num)/\(den)"
        let storedTempo = song.tracks.map(\.tempo).max() ?? 0   // 0 when the file has none
        let tempo = Double(storedTempo >= 30 ? min(storedTempo, 300) : 120)

        func events(_ t: Track, from lo: Int = 0, below hi: Int, shift: Int = 0) -> [SeqEvent] {
            t.notes.compactMap { n in
                guard n.tick >= lo, n.tick < hi, let d = drum(n.note) else { return nil }
                return SeqEvent(tick: Int32(n.tick + shift), drum: UInt8(d.rawValue), velocity: n.velocity, swingUnit: 0)
            }
        }
        /// A note on the downbeat right after the section: the landing hit.
        func hasLanding(_ t: Track) -> Bool { t.notes.contains { $0.tick >= t.length && $0.tick < t.length + 120 } }
        func bars(_ ticks: Int) -> Int { max(1, Int((Double(ticks) / Double(bar)).rounded(.up))) * bar }

        var files: [SongLibrary.ImportedFile] = []
        func add(_ fileName: String, _ p: PatternData) -> String? {
            guard !p.events.isEmpty else { return nil }
            files.append(.init(name: fileName, data: MIDIWriter.drumFile(p, tempo: tempo, signature: signature,
                                                                          barTicks: bar, beatTicks: beatTicks)))
            return fileName
        }
        /// Fills end on the bar line; PedalBeat plays a fill from the current position in the
        /// bar, so a shorter fill gets the start of the groove in front of it.
        func barAligned(_ t: Track, groove: PatternData) -> PatternData {
            let total = bars(t.length), offset = total - t.length
            let lead = groove.events.filter { Int($0.tick) < offset }
            return PatternData(events: lead + events(t, below: t.length, shift: offset), length: total)
        }

        var layoutParts: [MIDISongImporter.SongLayout.Part] = []
        var transition: String?
        var fillLanding = false
        for (i, (block, main)) in partTracks.enumerated() {
            let groove = PatternData(events: events(main, below: bars(main.length)), length: bars(main.length))
            guard let mainName = add("Part \(i + 1).mid", groove) else { continue }
            var fills: [String] = []
            for (k, f) in block.fills.compactMap(track).prefix(SongStore.maxFills).enumerated() {
                if let n = add("Part \(i + 1) Fill \(k + 1).mid", barAligned(f, groove: groove)) { fills.append(n); fillLanding = fillLanding || hasLanding(f) }
            }
            // PedalBeat has one transition per song: the first part's.
            if transition == nil, let t = track(block.transition) {
                transition = add("Transition.mid", barAligned(t, groove: groove))
                fillLanding = fillLanding || hasLanding(t)
            }
            layoutParts.append(.init(main: mainName, fills: fills))
        }
        guard !layoutParts.isEmpty else { throw ParseError.noParts }

        var intro: String?, introLanding = false
        if let t = track(song.intro.main) {
            intro = add("Intro.mid", PatternData(events: events(t, below: t.length), length: t.length))
            introLanding = hasLanding(t)
        }
        var outro: String?
        if let t = track(song.outro.main) {
            // Keep the final hit on the downbeat after the ending.
            let ev = events(t, below: t.length + 120)
            let end = max(t.length, (ev.map { Int($0.tick) }.max() ?? 0) + 120)
            outro = add("Outro.mid", PatternData(events: ev, length: end))
        }
        let layout = MIDISongImporter.SongLayout(intro: intro, parts: layoutParts, transition: transition, outro: outro,
                                                 introCrash: intro != nil ? introLanding : nil, fillCrash: fillLanding,
                                                 kitHint: kitHint(genre: genre, name: name))
        return (files, layout)
    }

    // MARK: Folders

    /// The SONGS folder of a .BBS SD card / project folder, if `url` is (or contains) one.
    public static func songsFolder(in url: URL) -> URL? {
        let fm = FileManager.default
        for candidate in [url.appendingPathComponent("SONGS"), url] {
            let cfg = candidate.appendingPathComponent("config.csv")
            guard fm.fileExists(atPath: cfg.path),
                  let rows = try? readConfig(cfg), let firstID = rows.first?.0 else { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.appendingPathComponent(firstID).path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        return nil
    }

    /// `config.csv` rows: (file or folder id, display name without the "12. " number).
    static func readConfig(_ url: URL) throws -> [(String, String)] {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let cols = line.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count == 2, !cols[0].isEmpty else { return nil }
            return (cols[0], displayName(cols[1]))
        }
    }

    static func displayName(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^\d+\.\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        return t.isEmpty ? s : t
    }

    public struct FolderResult: Sendable {
        public var entries: [MIDIFolderImport.Entry]
        public var failed: [String]
    }

    /// Converts every song listed in a SONGS folder into folder-import entries
    /// (pack "BBS" / genre / song / MIDI files + song.json).
    public static func entries(songsFolder: URL) -> FolderResult {
        var out: [MIDIFolderImport.Entry] = [], failed: [String] = []
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let genres = (try? readConfig(songsFolder.appendingPathComponent("config.csv"))) ?? []
        for (genreID, genreName) in genres {
            let dir = songsFolder.appendingPathComponent(genreID)
            guard let songs = try? readConfig(dir.appendingPathComponent("config.csv")) else { continue }
            let genreFolder = SongLibrary.safeFileName(genreName)
            for (n, (file, name)) in songs.enumerated() {
                do {
                    let song = try parse(try Data(contentsOf: dir.appendingPathComponent(file)))
                    let (files, layout) = try convert(song, name: name, genre: genreName)
                    // Numbered folders keep the original order in the browser.
                    let folder = String(format: "%02d %@", n + 1, SongLibrary.safeFileName(name))
                    let base = [packName, genreFolder, folder]
                    for f in files { out.append(.init(path: base + [f.name], data: f.data)) }
                    let json = try enc.encode(SongLibrary.SongFile(name: name, genre: "\(packName) › \(genreName)", layout: layout))
                    out.append(.init(path: base + [SongLibrary.songFileName], data: json))
                } catch {
                    failed.append("\(genreName)/\(name)")
                }
            }
        }
        return FolderResult(entries: out, failed: failed)
    }
}

