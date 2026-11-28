import Foundation

/// Minimal Standard MIDI File reader for drum grooves (and their bass lines).
public struct MIDIDrumFile: Sendable {
    public var name: String
    public var tempo: Double?
    public var numerator = 4
    public var denominator = 4
    public var events: [SeqEvent]   // already in engine ticks (PPQN)
    public var lengthTicks: Int
    public var unmappedNotes = 0
    /// Bass line: notes on a channel or track named or programmed as bass (every note outside
    /// channel 10 if the file name says "bass"), or next to channel 10 the lowest other part.
    public var bass: BassPattern?

    // Set from PedalBeat's meta event (exact grid of an exported song).
    var gridBarTicks: Int?
    var gridBeatTicks: Int?
    var gridLabel: String?

    public var barTicks: Int { gridBarTicks ?? numerator * PPQN * 4 / max(denominator, 1) }
    public var beatTicks: Int {
        if let g = gridBeatTicks { return g }
        // Compound meters (6/8, 9/8, 12/8) count in dotted quarters.
        if denominator == 8 && numerator % 3 == 0 && numerator > 3 { return PPQN * 3 / 2 }
        return PPQN * 4 / max(denominator, 1)
    }
    public var signature: String { gridLabel ?? "\(numerator)/\(denominator)" }
    public var pattern: PatternData { PatternData(events: events, length: lengthTicks) }

    public enum ParseError: LocalizedError {
        case notMIDI, smpteUnsupported, noNotes, truncated
        public var errorDescription: String? {
            switch self {
            case .notMIDI: "Not a Standard MIDI File."
            case .smpteUnsupported: "SMPTE-timed MIDI files are not supported."
            case .noNotes: "The file contains no drum or bass notes."
            case .truncated: "The MIDI file is damaged or truncated."
            }
        }
    }

    public init(data: Data, name: String) throws {
        self.name = name
        let b = [UInt8](data)
        var p = 0
        func u32() throws -> Int {
            guard p + 4 <= b.count else { throw ParseError.truncated }
            defer { p += 4 }
            return Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
        }
        func u16() throws -> Int {
            guard p + 2 <= b.count else { throw ParseError.truncated }
            defer { p += 2 }
            return Int(b[p]) << 8 | Int(b[p + 1])
        }
        guard b.count >= 14, b[0] == 0x4D, b[1] == 0x54, b[2] == 0x68, b[3] == 0x64 else { throw ParseError.notMIDI }
        p = 4
        let headerLen = try u32()
        _ = try u16() // format
        let tracks = try u16()
        let division = try u16()
        guard division & 0x8000 == 0 else { throw ParseError.smpteUnsupported }
        let ppq = max(division, 1)
        p = 8 + headerLen

        struct Hit { var tick: Int; var note: UInt8; var vel: UInt8; var channel: UInt8; var track: Int }
        var hits: [Hit] = []
        var offs: [Hit] = []                // note-offs, for bass note lengths
        var bassTracks = Set<Int>()         // tracks named "Bass…"
        var bassChannels = Set<UInt8>()     // channels set to a GM bass program (33–40)
        var endTick = 0
        var sigSet = false
        var pbLength: Int?          // PedalBeat meta: exact pattern length (ticks at file PPQ)
        var pbSwing: [Int16] = []   // PedalBeat meta: live-swing amount per note-on
        var pbBar: Int?, pbBeat: Int?, pbLabel: String?

        for track in 0..<tracks {
            guard p + 8 <= b.count else { break }
            let isTrack = b[p] == 0x4D && b[p + 1] == 0x54 && b[p + 2] == 0x72 && b[p + 3] == 0x6B
            p += 4
            let len = try u32()
            let end = min(p + len, b.count)
            if !isTrack { p = end; continue }
            var tick = 0
            var running: UInt8 = 0
            func vlq() -> Int {
                var v = 0
                while p < end {
                    let c = b[p]; p += 1
                    v = (v << 7) | Int(c & 0x7F)
                    if c & 0x80 == 0 { break }
                }
                return v
            }
            while p < end {
                tick += vlq()
                guard p < end else { break }
                var status = b[p]
                if status & 0x80 != 0 { p += 1; if status < 0xF0 { running = status } } else { status = running }
                if status == 0xFF {
                    guard p < end else { break }
                    let type = b[p]; p += 1
                    let l = vlq()
                    let dataStart = p
                    p = min(p + l, end)
                    switch type {
                    case 0x51 where l >= 3 && tempo == nil:
                        let us = Int(b[dataStart]) << 16 | Int(b[dataStart + 1]) << 8 | Int(b[dataStart + 2])
                        // MIDI stores µs per quarter; round to 0.01 BPM so 112 BPM reads back as 112.
                        if us > 0 { tempo = ((60_000_000.0 / Double(us)) * 100).rounded() / 100 }
                    case 0x58 where l >= 2 && !sigSet:
                        numerator = max(1, Int(b[dataStart]))
                        denominator = 1 << min(Int(b[dataStart + 1]), 5)
                        sigSet = true
                    case 0x2F:
                        endTick = max(endTick, tick)
                    case 0x03, 0x04:
                        if MIDISongImporter.mentionsBass(String(decoding: b[dataStart..<p], as: UTF8.self)) { bassTracks.insert(track) }
                    case 0x7F where l >= 20 && Array(b[dataStart..<dataStart + 3]) == MIDIWriter.tag:
                        func be32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
                        // PB1: length, barTicks, beatTicks, label (len + bytes), note count, swing per note.
                        var o = dataStart + 3
                        pbLength = be32(o); o += 4
                        pbBar = be32(o); o += 4
                        pbBeat = be32(o); o += 4
                        let ll = Int(b[o]); o += 1
                        guard o + ll + 4 <= dataStart + l else { break }
                        pbLabel = String(decoding: b[o..<o + ll], as: UTF8.self); o += ll
                        let n = be32(o); o += 4
                        if o + n * 2 <= dataStart + l {
                            pbSwing = (0..<n).map { Int16(bitPattern: UInt16(b[o + $0 * 2]) << 8 | UInt16(b[o + 1 + $0 * 2])) }
                        }
                    default: break
                    }
                } else if status == 0xF0 || status == 0xF7 {
                    let l = vlq(); p = min(p + l, end)
                } else if status >= 0x80 {
                    let kind = status & 0xF0
                    let dataCount = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
                    guard p + dataCount <= end else { p = end; break }
                    let d1 = b[p], d2 = dataCount > 1 ? b[p + 1] : 0
                    p += dataCount
                    let ch = status & 0x0F
                    if kind == 0x90 && d2 > 0 {
                        hits.append(Hit(tick: tick, note: d1, vel: d2, channel: ch, track: track))
                    } else if kind == 0x80 || kind == 0x90 {
                        offs.append(Hit(tick: tick, note: d1, vel: 0, channel: ch, track: track))
                    } else if kind == 0xC0 && (32...39).contains(d1) && ch != 9 {
                        bassChannels.insert(ch)
                    }
                } else {
                    p += 1 // stray data byte without running status
                }
            }
            p = end
        }

        // Channel 10 is drums. Bass is what's named or programmed as bass, or every other note if
        // the file name says so; next to channel 10 an unlabeled low part (mean below C4) is the bass.
        let hasDrumChannel = hits.contains { $0.channel == 9 }
        let bassFile = MIDISongImporter.mentionsBass(name)
        var lowChannel: UInt8?
        if hasDrumChannel && !bassFile && bassTracks.isEmpty && bassChannels.isEmpty {
            var sum = [Int](repeating: 0, count: 16), n = [Int](repeating: 0, count: 16)
            for h in hits where h.channel != 9 { sum[Int(h.channel)] += Int(h.note); n[Int(h.channel)] += 1 }
            lowChannel = (0..<16).filter { n[$0] > 0 && sum[$0] < 60 * n[$0] }
                .min { sum[$0] * n[$1] < sum[$1] * n[$0] }.map { UInt8($0) }
        }
        func isBass(_ h: Hit) -> Bool {
            h.channel != 9 && (bassFile || bassTracks.contains(h.track) || bassChannels.contains(h.channel) || h.channel == lowChannel)
        }
        func ticks(_ t: Int) -> Int { Int((Double(t) * Double(PPQN) / Double(ppq)).rounded()) }

        // Otherwise prefer channel 10 if present, or accept every channel. The swing table counts drum notes.
        let drumHits = hits.filter { !isBass($0) }
        let bassHits = hits.filter(isBass).sorted { $0.tick < $1.tick }
        let useSwing = !pbSwing.isEmpty && pbSwing.count == drumHits.count
        var evs: [SeqEvent] = []
        var lastTick = bassHits.last.map { ticks($0.tick) } ?? 0
        for (i, h) in drumHits.enumerated() where !hasDrumChannel || h.channel == 9 {
            guard let d = Drum.fromGM(h.note) else { unmappedNotes += 1; continue }
            let t = ticks(h.tick)
            evs.append(SeqEvent(tick: Int32(t), drum: UInt8(d.rawValue), velocity: h.vel, swingUnit: useSwing ? pbSwing[i] : 0))
            lastTick = max(lastTick, t)
        }
        guard !evs.isEmpty || !bassHits.isEmpty else { throw ParseError.noNotes }
        events = evs.sorted { $0.tick < $1.tick }

        if let pb = pbBar, let bt = pbBeat, pb > 0, bt > 0 {
            gridBarTicks = Int((Double(pb) * Double(PPQN) / Double(ppq)).rounded())
            gridBeatTicks = Int((Double(bt) * Double(PPQN) / Double(ppq)).rounded())
            gridLabel = pbLabel.flatMap { $0.isEmpty ? nil : $0 }
        }
        let bar = gridBarTicks ?? numerator * PPQN * 4 / max(denominator, 1)
        let endT = Int((Double(endTick) * Double(PPQN) / Double(ppq)).rounded())
        let notesBars = lastTick / bar + 1
        // Use end-of-track if it lands on (or near) a bar line after the last note.
        let eotBars = Int((Double(endT) / Double(bar)).rounded())
        if let exact = pbLength, exact > 0 {
            lengthTicks = Int((Double(exact) * Double(PPQN) / Double(ppq)).rounded())
        } else {
            lengthTicks = max(notesBars, eotBars) * bar
        }

        // A bass note lasts until its note-off or until the same key is struck again
        // (without either, until the next bass note).
        guard !bassHits.isEmpty else { return }
        func key(_ h: Hit) -> Int { Int(h.channel) << 7 | Int(h.note) }
        var offTicks: [Int: [Int]] = [:]
        for o in offs { offTicks[key(o), default: []].append(o.tick) }
        for k in offTicks.keys { offTicks[k]!.sort() }
        var nextSame = [Int](repeating: .max, count: bassHits.count), seen: [Int: Int] = [:]
        for i in bassHits.indices.reversed() {
            nextSame[i] = seen[key(bassHits[i])] ?? .max
            seen[key(bassHits[i])] = bassHits[i].tick
        }
        var cursor: [Int: Int] = [:]
        var notes: [BassEvent] = []
        for (i, h) in bassHits.enumerated() {
            var off = Int.max
            if let list = offTicks[key(h)] {
                var c = cursor[key(h)] ?? 0
                while c < list.count && list[c] <= h.tick { c += 1 }
                cursor[key(h)] = c
                if c < list.count { off = list[c] }
            }
            let end = min(off, nextSame[i])
            let t = ticks(h.tick)
            let endT = end < .max ? ticks(end) : (bassHits[(i + 1)...].first { $0.tick > h.tick }.map { ticks($0.tick) } ?? lengthTicks)
            notes.append(BassEvent(tick: Int32(t), note: h.note, velocity: h.vel, durationTicks: Int32(min(endT - t, lengthTicks))))
        }
        bass = BassPattern(events: notes, length: lengthTicks)
    }
}

/// Assembles one or more MIDI files into a playable song.
public enum MIDISongImporter {
    public enum Role { case intro, main, fill, transition, outro, bass }

    static func tokens(_ filename: String) -> [String] {
        MIDIFolderImport.words((filename as NSString).deletingPathExtension).map { $0.lowercased() }
    }

    static let bassWords: Set<String> = ["bass", "bassline", "basslines"]

    /// "Verse Bass", "Bassline 2", a track named "Synth Bass" — but not "Bass Drum".
    static func mentionsBass(_ name: String) -> Bool {
        let t = MIDIFolderImport.words(name).map { $0.lowercased() }
        return t.indices.contains { bassWords.contains(t[$0]) && !(t[$0] == "bass" && $0 + 1 < t.count && t[$0 + 1].hasPrefix("drum")) }
    }

    /// A file with only a bass line is a bass part; anything else plays as its name says.
    public static func role(for file: MIDIDrumFile) -> Role {
        file.events.isEmpty && file.bass != nil ? .bass : role(for: file.name)
    }

    /// The section a file name describes ("Intro Bass" is an intro).
    public static func role(for filename: String) -> Role {
        let t = tokens(filename).filter { !bassWords.contains($0) }
        let has = { (w: String) in t.contains(w) }
        if has("fill") || has("fills") { return .fill }   // "Intro Fill", "Chorus Fill" are fills
        if has("intro") || has("count") || has("countin") { return .intro }
        if has("outro") || has("ending") || has("end") { return .outro }
        if has("trans") || has("transition") { return .transition }
        return .main
    }

    /// Name of a groove without numbers and the words "fill" and "bass": "Groove A Fill 2" -> "groove a".
    static func grooveKey(_ filename: String) -> String {
        tokens(filename).filter { $0 != "fill" && $0 != "fills" && !bassWords.contains($0) && !$0.allSatisfy(\.isNumber) }
            .joined(separator: " ")
    }

    /// Distributes fills over parts, up to `SongStore.maxFills` each, the way a pedal song is laid out:
    /// 1. a fill named like a groove ("Groove A Fill 2") goes to that groove,
    /// 2. a fill naming a section ("Verse Fill") goes to every part of that section,
    /// 3. any other fills go to every part that still has none.
    static func assignFills(_ fills: [MIDIDrumFile], to parts: [MIDIDrumFile]) -> [[MIDIDrumFile]] {
        var out = [[MIDIDrumFile]](repeating: [], count: parts.count)
        guard !parts.isEmpty else { return out }
        let partKeys = parts.map { grooveKey($0.name) }
        var spare: [MIDIDrumFile] = []
        for f in fills {
            let key = grooveKey(f.name)
            let byName = parts.indices.filter { !key.isEmpty && partKeys[$0] == key }
            let rank = sectionRank(f.name)
            let bySection = rank > 0 ? parts.indices.filter { sectionRank(parts[$0].name) == rank } : []
            let targets = !byName.isEmpty ? byName : bySection
            if targets.isEmpty { spare.append(f); continue }
            for i in targets where out[i].count < SongStore.maxFills { out[i].append(f) }
        }
        if !spare.isEmpty {
            let empty = parts.indices.filter { out[$0].isEmpty }
            // As many generic fills as parts: one each, in order (classic numbered packs).
            if spare.count == empty.count && empty.count > 1 {
                for (i, f) in zip(empty, spare) { out[i].append(f) }
            } else {
                for i in empty { out[i] = Array(spare.prefix(SongStore.maxFills)) }
            }
        }
        return out
    }

    /// Song-form position of a part (verse before chorus, ...); 0 = unnamed groove.
    static func sectionRank(_ filename: String) -> Int {
        let t = tokens(filename)
        if t.contains("verse") || t.contains("vs") || t.contains("vrs") { return 1 }
        if t.contains("pre") || t.contains("prechorus") { return 2 }
        if t.contains("chorus") || t.contains("chr") || t.contains("ch") { return 3 }
        if t.contains("bridge") || t.contains("brg") { return 4 }
        if t.contains("solo") || t.contains("break") || t.contains("breakdown") { return 5 }
        return 0
    }

    /// Builds a song. Parts are ordered verse, pre-chorus, chorus, bridge, ... (then by name);
    /// a fill is matched to a part of the section its name mentions, otherwise in order.
    /// Which file plays where. File names refer to the song's imported files; `nil`
    /// slots and parts without fills are generated automatically.
    public struct SongLayout: Codable, Sendable, Equatable {
        public struct Part: Codable, Sendable, Equatable {
            public var main: String
            public var fills: [String]
            /// Bass line of the groove (nil = the main file's own, if it has one). It keeps playing under the fills.
            public var bass: String?
            /// Bass line per fill, same order as `fills` ("" or missing = the groove's bass keeps playing).
            public var fillBass: [String]?
            public init(main: String, fills: [String] = [], bass: String? = nil, fillBass: [String]? = nil) {
                self.main = main; self.fills = fills; self.bass = bass; self.fillBass = fillBass
            }
        }
        public var intro: String?
        public var parts: [Part]
        public var transition: String?
        public var outro: String?
        /// Crash cymbal when the groove starts after the intro / after each fill (nil = automatic).
        public var introCrash: Bool?
        public var fillCrash: Bool?
        /// Suggested synthesized kit (nil = Studio).
        public var kitHint: Int?
        /// Bass lines of the other sections (nil = the section file's own, if any).
        public var introBass: String?
        public var transitionBass: String?
        public var outroBass: String?
        /// Play the song's bass lines (nil = yes).
        public var bassEnabled: Bool?
        /// Pitch class the bass lines are written in, 0 = C … 11 = B (nil = E). Bass Follow transposes from it.
        public var bassRoot: Int?
        public init(intro: String? = nil, parts: [Part], transition: String? = nil, outro: String? = nil,
                    introCrash: Bool? = nil, fillCrash: Bool? = nil, kitHint: Int? = nil,
                    introBass: String? = nil, transitionBass: String? = nil, outroBass: String? = nil, bassEnabled: Bool? = nil,
                    bassRoot: Int? = nil) {
            self.intro = intro; self.parts = parts; self.transition = transition; self.outro = outro
            self.introCrash = introCrash; self.fillCrash = fillCrash; self.kitHint = kitHint
            self.introBass = introBass; self.transitionBass = transitionBass; self.outroBass = outroBass
            self.bassEnabled = bassEnabled; self.bassRoot = bassRoot
        }
        /// Effective crash settings (what "automatic" means for this layout).
        public var effectiveIntroCrash: Bool { introCrash ?? (intro != nil) }
        public var effectiveFillCrash: Bool { fillCrash ?? !parts.contains { !$0.fills.isEmpty } }
    }

    /// Automatic layout from file names (see `role`, `sectionRank`, `assignFills`).
    public static func layout(for files: [MIDIDrumFile]) -> SongLayout? {
        let sorted = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var intro: MIDIDrumFile?, outro: MIDIDrumFile?, transition: MIDIDrumFile?
        var mains: [MIDIDrumFile] = [], fills: [MIDIDrumFile] = [], basses: [MIDIDrumFile] = []
        for f in sorted {
            switch role(for: f) {
            case .intro: intro = intro ?? f
            case .outro: outro = outro ?? f
            case .transition: transition = transition ?? f
            case .fill: fills.append(f)
            case .main: mains.append(f)
            case .bass: basses.append(f)
            }
        }
        mains = mains.enumerated().sorted { a, b in
            let ra = sectionRank(a.element.name), rb = sectionRank(b.element.name)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        if mains.isEmpty, let f = fills.first { mains = [f]; fills.removeFirst() }
        guard !mains.isEmpty else { return nil }
        let used = Array(mains.prefix(SongStore.maxParts))
        let fillsFor = assignFills(fills, to: used)
        // Bass files: "Intro Bass" plays under the intro (likewise transition and ending), the
        // others go to grooves the way fills do ("Verse Bass" with Verse). Fills have no bass of their own.
        var introBass: String?, transitionBass: String?, outroBass: String?, grooveBasses: [MIDIDrumFile] = []
        for b in basses {
            switch role(for: b.name) {
            case .intro: introBass = introBass ?? b.name
            case .transition: transitionBass = transitionBass ?? b.name
            case .outro: outroBass = outroBass ?? b.name
            case .main: grooveBasses.append(b)
            case .fill, .bass: break
            }
        }
        let bassFor = assignFills(grooveBasses, to: used).map { $0.first?.name }
        return SongLayout(intro: intro?.name,
                          parts: used.enumerated().map {
                              .init(main: $0.element.name, fills: fillsFor[$0.offset].map(\.name), bass: bassFor[$0.offset])
                          },
                          transition: transition?.name, outro: outro?.name,
                          introBass: introBass, transitionBass: transitionBass, outroBass: outroBass)
    }

    public static func makeSong(name: String, files: [MIDIDrumFile], key: String, genre: String = "My Songs") -> SongData? {
        guard let l = layout(for: files) else { return nil }
        return makeSong(name: name, files: files, layout: l, key: key, genre: genre)
    }

    /// Builds a song from an explicit layout. Unknown file names are ignored.
    public static func makeSong(name: String, files: [MIDIDrumFile], layout: SongLayout, key: String,
                                genre: String = "My Songs") -> SongData? {
        var byName: [String: MIDIDrumFile] = [:]
        for f in files where byName[f.name] == nil { byName[f.name] = f }
        let mains = layout.parts.prefix(SongStore.maxParts).compactMap { p in byName[p.main].map { (p, $0) } }
        guard let first = mains.first?.1 else { return nil }
        let intro = layout.intro.flatMap { byName[$0] }
        let transition = layout.transition.flatMap { byName[$0] }
        let outro = layout.outro.flatMap { byName[$0] }
        let anyFills = mains.contains { !$0.0.fills.compactMap { byName[$0] }.isEmpty }

        let grid = StepGrid(stepsPerBar: max(first.barTicks / 120, 1), stepTicks: 120, beatTicks: first.beatTicks,
                        pulseTicks: first.beatTicks, swingUnit: 0, signature: first.signature)
        let shorts = Tails.shortTails(for: first.barTicks == 1920 ? .g16 : (first.barTicks == 1440 ? .g3_4 : .g16))
            .filter { $0.lengthTicks <= first.barTicks }
        let longs = Tails.longTails(for: first.barTicks == 1920 ? .g16 : .g3_4).filter { $0.lengthTicks <= first.barTicks }

        func firstBar(_ f: MIDIDrumFile) -> PatternData {
            PatternData(events: f.events.filter { Int($0.tick) < f.barTicks }, length: f.barTicks)
        }
        func generatedFill(_ f: MIDIDrumFile, _ tail: Tail?) -> PatternData {
            guard let tail else { return firstBar(f) }
            let cut = max(0, f.barTicks - tail.lengthTicks)
            let base = f.events.filter { Int($0.tick) < cut }
            return PatternData(events: base + tail.events(offset: cut), length: f.barTicks)
        }

        func bassLine(_ file: String?) -> BassPattern? { file.flatMap { byName[$0]?.bass } }
        var parts: [PartData] = []
        for (i, (p, m)) in mains.enumerated() {
            var pf: [PatternData] = [], pfBass: [BassPattern?] = []
            for (k, name) in p.fills.prefix(SongStore.maxFills).enumerated() {
                guard let pat = byName[name]?.pattern else { continue }
                pf.append(pat)
                let fb = (p.fillBass.flatMap { k < $0.count ? $0[k] : nil }).flatMap { $0.isEmpty ? nil : bassLine($0) }
                pfBass.append(fb)
            }
            if pf.isEmpty { pf = [generatedFill(m, shorts.isEmpty ? nil : shorts[i % shorts.count])]; pfBass = [] }
            parts.append(PartData(main: m.pattern, fills: pf, bass: bassLine(p.bass) ?? m.bass, fillBass: pfBass))
        }
        let trans = transition?.pattern ?? generatedFill(first, longs.first)
        let outroPattern: PatternData = outro?.pattern ?? {
            var ev = generatedFill(mains.last?.1 ?? first, shorts.first).events
            ev.append(SeqEvent(tick: Int32(first.barTicks), drum: UInt8(Drum.crash.rawValue), velocity: 124))
            ev.append(SeqEvent(tick: Int32(first.barTicks), drum: UInt8(Drum.kick.rawValue), velocity: 120))
            return PatternData(events: ev, length: first.barTicks + 120)
        }()
        let introPattern = intro?.pattern ?? SongBuilder.countIn(grid, jazz: false)

        var song = SongData(name: name, genre: genre, tempo: first.tempo ?? 120, timeSignature: first.signature,
                            barTicks: first.barTicks, beatTicks: first.beatTicks, intro: introPattern, parts: parts,
                            transition: trans, outro: outroPattern, introCrash: layout.introCrash ?? (intro != nil), fillCrash: layout.fillCrash ?? !anyFills,
                            kitHint: layout.kitHint ?? 0, isUser: true, key: key)
        song.introBass = bassLine(layout.introBass) ?? intro?.bass
        song.transitionBass = bassLine(layout.transitionBass) ?? transition?.bass
        song.outroBass = bassLine(layout.outroBass) ?? outro?.bass
        song.bassEnabled = layout.bassEnabled ?? true
        if let r = layout.bassRoot { song.bassRootPitchClass = ((r % 12) + 12) % 12 }
        return song
    }
}
