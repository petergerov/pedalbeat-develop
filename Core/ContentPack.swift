import Foundation

extension SongIndex {
    /// Tempo for a popular song: its index BPM, unless the song's own drums were written at double or
    /// half of it (the pattern would play twice or half as fast); then the drums' own tempo.
    public static func playTempo(indexBPM: Double, drumsTempo: Double, ownDrums: Bool) -> Double {
        guard ownDrums, indexBPM > 0, drumsTempo > 0 else { return indexBPM }
        let ratio = drumsTempo / indexBPM
        return abs(ratio - 2) < 0.16 || abs(ratio - 0.5) < 0.04 ? drumsTempo : indexBPM
    }
}

/// Content the macOS installers put in place, ready to play without an import: song packs
/// (`Songs/*.pbcp`) and sampled kits (`Kits/*.pbkit`). Read-only for the sandboxed app and plug-in
/// (entitlement `com.apple.security.temporary-exception.files.absolute-path.read-only`).
public enum InstalledContent {
    public static let root = URL(fileURLWithPath: "/Library/Application Support/PedalBeat", isDirectory: true)
    public static var songsFolder: URL { root.appendingPathComponent("Songs", isDirectory: true) }
    public static var kitsFolder: URL { root.appendingPathComponent("Kits", isDirectory: true) }
}

/// Songs that ship inside the plug-in (iOS: `Content/SongPack.pbcp` and `Content/bb Songs.pbcp`) or come
/// with an installer (macOS: "MIDI Songs.pbcp", "bb Songs.pbcp" in `InstalledContent.songsFolder`): each popular song's own drums with
/// its bass line, and its percussion layers. Built offline by `Tools/SongPack` with the app's own
/// import code, loaded at launch in milliseconds instead of parsing thousands of MIDI files.
///
/// Binary, little-endian: "PBCP", version, songs, percussion layers. Patterns are stored as raw
/// event records, so loading is a straight copy.
public enum ContentPack {
    public static let fileName = "SongPack"
    public static let fileExtension = "pbcp"
    public static let folder = "Content"
    /// Song keys of the pack: "pack/" + artist and title (`SongIndex.linkKey`), stable across builds.
    public static let keyPrefix = "pack/"
    /// Beats of the pack (bb's, "BBS › Genre"): "pack-beat/" + group and name. They show in the
    /// Beats tab like an import of them would, and an actual import of the same beat replaces them.
    public static let beatKeyPrefix = "pack-beat/"
    public static func beatKey(genre: String, name: String) -> String {
        beatKeyPrefix + SongIndex.normalize(genre) + "/" + SongIndex.normalize(name)
    }
    /// Key of a song's bb version in a pack ("bb songs › Artist" / "Title · Beat"): apart from its
    /// MIDI version, which has the same artist and title.
    public static func bbSongKey(genre: String, name: String) -> String? {
        let parts = genre.components(separatedBy: " › ")
        guard parts.count >= 2, SongIndex.normalize(parts[0]) == SongIndex.normalize(SongIndex.bbSongsPack) else { return nil }
        let (title, beat) = SongIndex.splitBBSongName(name)
        return keyPrefix + "bb/" + SongIndex.bbSongKey(artist: parts.dropFirst().joined(separator: " "), title: title, beat: beat)
    }

    /// Song packs built into the first of `bundles` that has any (iOS plug-in: `Content/*.pbcp`, the MIDI Songs
    /// and bb Songs packs), by file name.
    public static func builtInPacks(in bundles: [Bundle]) -> [URL] {
        for bundle in bundles {
            guard let res = bundle.resourceURL else { continue }
            let packs = installedPacks(in: res.appendingPathComponent(folder, isDirectory: true))
            if !packs.isEmpty { return packs }
        }
        return []
    }

    /// Song packs put in place by an installer (macOS: `/Library/Application Support/PedalBeat/Songs`),
    /// loaded at launch after the built-in ones, by file name.
    public static func installedPacks(in folder: URL = InstalledContent.songsFolder) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == fileExtension }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// A percussion layer and the song it belongs to (its group "shaker songs › Artist" and title).
    public struct Layer: Sendable {
        public var genre: String
        public var name: String
        public var data: PercussionData
        public init(genre: String, name: String, data: PercussionData) { self.genre = genre; self.name = name; self.data = data }
    }

    public struct Contents: Sendable {
        public var songs: [SongData]
        public var percussion: [Layer]
        public init(songs: [SongData], percussion: [Layer]) { self.songs = songs; self.percussion = percussion }
    }

    public enum PackError: Error { case notAPack, unsupportedVersion(Int), truncated, badValue }

    static let magic: [UInt8] = Array("PBCP".utf8)
    /// 2: one bass line per fill. 3: each song's chord profile (`SongData.chordProfile`).
    static let version: UInt32 = 3

    // MARK: Encoding

    public static func encode(_ c: Contents) -> Data {
        var w = Writer()
        w.bytes(magic)
        w.u32(version)
        w.u32(UInt32(c.songs.count))
        for s in c.songs {
            w.string(s.name); w.string(s.genre); w.string(s.key); w.string(s.timeSignature)
            w.f64(s.tempo)
            w.i32(Int32(s.barTicks)); w.i32(Int32(s.beatTicks)); w.i32(Int32(s.kitHint))
            w.u8((s.introCrash ? 1 : 0) | (s.fillCrash ? 2 : 0) | (s.bassEnabled ? 4 : 0) | (s.isUser ? 8 : 0))
            w.u8(UInt8(((s.bassRootPitchClass % 12) + 12) % 12))
            w.pattern(s.intro); w.pattern(s.transition); w.pattern(s.outro)
            w.bass(s.introBass); w.bass(s.transitionBass); w.bass(s.outroBass)
            w.u32(UInt32(s.parts.count))
            for p in s.parts {
                w.pattern(p.main)
                w.u32(UInt32(p.fills.count))
                for f in p.fills { w.pattern(f) }
                w.bass(p.bass)
                for k in 0..<p.fills.count { w.bass(k < p.fillBass.count ? p.fillBass[k] : nil) }
            }
            // Chord profile: the chords it plays, each with its share in 1/255 of the most played one.
            let peak = s.chordProfile.max() ?? 0
            let chords = peak > 0 ? s.chordProfile.prefix(24).enumerated().compactMap { i, v -> (Int, UInt8)? in
                let q = Int((v / peak * 255).rounded())
                return q > 0 ? (i, UInt8(min(q, 255))) : nil
            } : []
            w.u8(UInt8(chords.count))
            for (i, q) in chords { w.u8(UInt8(i)); w.u8(q) }
        }
        w.u32(UInt32(c.percussion.count))
        for l in c.percussion {
            w.string(l.genre); w.string(l.name)
            w.u8(UInt8(l.data.instrument.rawValue))
            w.pattern(l.data.intro); w.pattern(l.data.transition); w.pattern(l.data.outro)
            w.u32(UInt32(l.data.parts.count))
            for p in l.data.parts {
                w.pattern(p.main)
                w.u32(UInt32(p.fills.count))
                for f in p.fills { w.pattern(f) }
            }
        }
        return w.data
    }

    // MARK: Decoding

    public static func decode(_ data: Data) throws -> Contents {
        try data.withUnsafeBytes { raw in
            var r = Reader(raw)
            guard try r.bytes(4) == magic else { throw PackError.notAPack }
            let v = try r.u32()
            guard (1...version).contains(v) else { throw PackError.unsupportedVersion(Int(v)) }
            var songs: [SongData] = []
            let songCount = try r.count()
            songs.reserveCapacity(songCount)
            for _ in 0..<songCount {
                let name = try r.string(), genre = try r.string(), key = try r.string(), sig = try r.string()
                let tempo = try r.f64()
                let barTicks = Int(try r.i32()), beatTicks = Int(try r.i32()), kitHint = Int(try r.i32())
                let flags = try r.u8()
                let root = Int(try r.u8())
                let intro = try r.pattern(), transition = try r.pattern(), outro = try r.pattern()
                let introBass = try r.bass(), transitionBass = try r.bass(), outroBass = try r.bass()
                var parts: [PartData] = []
                for _ in 0..<(try r.count()) {
                    guard let main = try r.pattern() else { throw PackError.badValue }
                    var fills: [PatternData] = []
                    for _ in 0..<(try r.count()) { if let f = try r.pattern() { fills.append(f) } }
                    let bass = try r.bass()
                    // Version 2 adds one bass line per fill, after the groove's.
                    let fillBass: [BassPattern?] = v >= 2 ? try fills.map { _ in try r.bass() } : []
                    parts.append(PartData(main: main, fills: fills, bass: bass, fillBass: fillBass))
                }
                guard !parts.isEmpty, barTicks > 0, beatTicks > 0 else { throw PackError.badValue }
                var s = SongData(name: name, genre: genre, tempo: tempo, timeSignature: sig, barTicks: barTicks,
                                 beatTicks: beatTicks, intro: intro, parts: parts, transition: transition, outro: outro,
                                 introCrash: flags & 1 != 0, fillCrash: flags & 2 != 0, kitHint: kitHint,
                                 isUser: flags & 8 != 0, key: key, bassRootPitchClass: root)
                s.bassEnabled = flags & 4 != 0
                s.introBass = introBass; s.transitionBass = transitionBass; s.outroBass = outroBass
                if v >= 3 {
                    let n = Int(try r.u8())
                    if n > 0 {
                        var profile = [Float](repeating: 0, count: 24)
                        for _ in 0..<n {
                            let i = Int(try r.u8()), q = try r.u8()
                            guard i < 24 else { throw PackError.badValue }
                            profile[i] = Float(q) / 255
                        }
                        s.chordProfile = profile
                    }
                }
                songs.append(s)
            }
            var layers: [Layer] = []
            for _ in 0..<(try r.count()) {
                let genre = try r.string(), name = try r.string()
                guard let inst = PercussionInstrument(rawValue: Int(try r.u8())) else { throw PackError.badValue }
                let intro = try r.pattern(), transition = try r.pattern(), outro = try r.pattern()
                var parts: [PercussionPart] = []
                for _ in 0..<(try r.count()) {
                    guard let main = try r.pattern() else { throw PackError.badValue }
                    var fills: [PatternData] = []
                    for _ in 0..<(try r.count()) { if let f = try r.pattern() { fills.append(f) } }
                    parts.append(PercussionPart(main: main, fills: fills))
                }
                layers.append(Layer(genre: genre, name: name,
                                    data: PercussionData(instrument: inst, intro: intro, parts: parts, transition: transition, outro: outro)))
            }
            return Contents(songs: songs, percussion: layers)
        }
    }

    // MARK: Byte I/O

    private struct Writer {
        var data = Data()
        mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        mutating func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        mutating func string(_ s: String) { let b = Array(s.utf8); u32(UInt32(b.count)); bytes(b) }
        /// Optional pattern: length (0 = none), event count, events (tick, drum, velocity, swing unit).
        mutating func pattern(_ p: PatternData?) {
            guard let p else { i32(0); return }
            i32(Int32(max(p.length, 1)))
            u32(UInt32(p.events.count))
            for e in p.events { i32(e.tick); u8(e.drum); u8(e.velocity); u16(UInt16(bitPattern: e.swingUnit)) }
        }
        /// Optional bass line: length (0 = none), note count, notes (tick, note, velocity, duration).
        mutating func bass(_ b: BassPattern?) {
            guard let b else { i32(0); return }
            i32(Int32(max(b.length, 1)))
            u32(UInt32(b.events.count))
            for e in b.events { i32(e.tick); u8(e.note); u8(e.velocity); i32(e.durationTicks) }
        }
    }

    private struct Reader {
        let raw: UnsafeRawBufferPointer
        var pos = 0
        init(_ raw: UnsafeRawBufferPointer) { self.raw = raw }

        mutating func take(_ n: Int) throws -> Int {
            guard n >= 0, pos + n <= raw.count else { throw PackError.truncated }
            defer { pos += n }
            return pos
        }
        mutating func bytes(_ n: Int) throws -> [UInt8] { let p = try take(n); return Array(raw[p..<p + n]) }
        mutating func u8() throws -> UInt8 { raw[try take(1)] }
        mutating func u16() throws -> UInt16 { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: try take(2), as: UInt16.self)) }
        mutating func u32() throws -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: try take(4), as: UInt32.self)) }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        mutating func f64() throws -> Double {
            Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: try take(8), as: UInt64.self)))
        }
        /// A count, sanity-checked against what is left so a damaged file can't ask for huge arrays.
        mutating func count() throws -> Int {
            let n = Int(try u32())
            guard n <= raw.count - pos else { throw PackError.truncated }
            return n
        }
        mutating func string() throws -> String {
            let n = try count()
            let p = try take(n)
            return String(decoding: UnsafeRawBufferPointer(rebasing: raw[p..<p + n]), as: UTF8.self)
        }
        mutating func pattern() throws -> PatternData? {
            let length = Int(try i32())
            guard length > 0 else { return nil }
            let n = try count()
            var events: [SeqEvent] = []
            events.reserveCapacity(n)
            for _ in 0..<n {
                events.append(SeqEvent(tick: try i32(), drum: try u8(), velocity: try u8(), swingUnit: Int16(bitPattern: try u16())))
            }
            guard events.allSatisfy({ Int($0.drum) < Drum.count }) else { throw PackError.badValue }
            return PatternData(events: events, length: length)
        }
        mutating func bass() throws -> BassPattern? {
            let length = Int(try i32())
            guard length > 0 else { return nil }
            let n = try count()
            var events: [BassEvent] = []
            events.reserveCapacity(n)
            for _ in 0..<n {
                events.append(BassEvent(tick: try i32(), note: try u8(), velocity: try u8(), durationTicks: try i32()))
            }
            return BassPattern(events: events, length: length)
        }
    }
}
