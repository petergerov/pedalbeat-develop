import Foundation

// Offline checks for the core engine: library integrity, pedal state machine,
// audio sanity (no NaN / clipping), MIDI import. Writes demo WAVs to argv[1].

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
var failures = 0
func check(_ cond: Bool, _ msg: String) { if !cond { failures += 1; print("FAIL: \(msg)") } }

// 1. Groove rows must fit their grid.
for genre in FactoryLibrary.genres {
    for g in genre.grooves {
        for (sym, row) in g.rows {
            check(Drum.fromSymbol(sym) != nil, "\(g.name): unknown symbol \(sym)")
            check(row.count % g.grid.stepsPerBar == 0,
                  "\(genre.name)/\(g.name) row \(sym) has \(row.count) steps, grid \(g.grid.stepsPerBar)")
        }
    }
}

// 2. Library builds and every pattern is sane.
let engine = DrumEngine()
let t0 = Date()
let library = SongLibrary(store: engine.store)
print("Built \(library.songs.count) songs in \(library.genres.count) genres in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms")
check(library.songs.count > 150, "expected > 150 songs")
let store = engine.store
for i in 0..<store.count {
    let rec = store.songs[i]
    check(rec.partCount >= 1, "song \(i) has no parts")
    var pats = [rec.intro, rec.transition, rec.outro]
    for p in 0..<Int(rec.partCount) {
        pats.append(store.partMain[i * SongStore.maxParts + p])
        check(store.fillCount(song: i, part: p) >= 1, "song \(i) part \(p) has no fill")
        for k in 0..<store.fillCount(song: i, part: p) { pats.append(store.fill(song: i, part: p, k)) }
    }
    for p in pats where p >= 0 {
        let pr = store.patterns[Int(p)]
        for e in 0..<Int(pr.count) {
            let ev = store.events[Int(pr.start) + e]
            check(ev.tick >= 0 && Int(ev.tick) + Int(ev.swingUnit) < Int(pr.length),
                  "song \(library.songs[i].name): event tick \(ev.tick) outside pattern length \(pr.length)")
        }
    }
}

// 2b. Brush sweeps: hard (X) sweeps in Medium Swing / Up Tempo verses and every jazz chorus.
func sweepVelocities(_ songName: String, part: Int) -> [UInt8] {
    guard let s = library.songs.first(where: { $0.name.hasPrefix(songName) }) else { return [] }
    let p = store.partMain[s.id * SongStore.maxParts + part]
    guard p >= 0 else { return [] }
    let pr = store.patterns[Int(p)]
    return (0..<Int(pr.count)).map { store.events[Int(pr.start) + $0] }
        .filter { Int($0.drum) == Drum.brushSweep.rawValue }.map(\.velocity)
}
for (song, part, wantHard) in [("Jazz 1 ", 0, true), ("Jazz 2 ", 0, true), ("Jazz 3 ", 0, false), ("Jazz 5 ", 0, false),
                               ("Jazz 3 ", 1, true), ("Jazz 4 ", 1, false), ("Jazz 5 ", 1, false)] {
    let v = sweepVelocities(song, part: part)
    check(!v.isEmpty, "\(song)part \(part): no sweeps")
    let hard = v.contains { $0 >= 109 }
    check(hard == wantHard, "\(song)part \(part): hard sweeps \(hard), expected \(wantHard) (\(v))")
}
// Folk 6/8 grooves: soft sweeps on each dotted-quarter beat, one step harder in the chorus.
for groove in ["Six-Eight Ballad", "Campfire"] {
    guard let s = library.songs.first(where: { $0.genre == "Folk & Acoustic" && $0.name.hasSuffix(groove) }) else {
        check(false, "missing folk song \(groove)"); continue
    }
    let prefix = String(s.name.prefix(while: { $0 != "·" }))
    let verse = sweepVelocities(prefix, part: 0), chorus = sweepVelocities(prefix, part: 1)
    check(verse.count >= 2 && verse.allSatisfy { $0 == 72 }, "\(groove) verse sweeps \(verse)")
    check(chorus.count == verse.count && chorus.allSatisfy { $0 == 98 }, "\(groove) chorus sweeps \(chorus)")
}
// Pop ballad: soft sweep on every beat.
if let pb = library.songs.first(where: { $0.genre == "Pop" && $0.name.hasSuffix("Ballad Sidestick") }) {
    let v = sweepVelocities(String(pb.name.prefix(while: { $0 != "·" })), part: 0)
    check(v.count == 4 && v.allSatisfy { $0 == 72 }, "Pop ballad verse sweeps \(v)")
} else { check(false, "missing Pop ballad") }
let chorusLift = zip(sweepVelocities("Jazz 5 ", part: 0), sweepVelocities("Jazz 5 ", part: 1)).allSatisfy { $0 < $1 }
check(chorusLift, "Two Feel chorus sweeps should be harder than the verse")

// 2c. Factory songs carry three different fills per part.
var factoryFillsDistinct = 0
for i in 0..<min(store.count, 40) where store.fillCount(song: i, part: 0) == 3 {
    let ids = (0..<3).map { k -> [Int32] in
        let pr = store.patterns[Int(store.fill(song: i, part: 0, k))]
        return (0..<Int(pr.count)).map { store.events[Int(pr.start) + $0].tick * 128 + Int32(store.events[Int(pr.start) + $0].drum) }
    }
    if Set(ids.map { $0.description }).count == 3 { factoryFillsDistinct += 1 }
}
check(factoryFillsDistinct >= 30, "factory songs should have 3 distinct fills per part (\(factoryFillsDistinct)/40)")

// 2d. Song index: every entry parses and every beat style maps to a factory groove.
check(SongIndex.entries.count == SongIndex.entryCount, "song index parsed \(SongIndex.entries.count) of \(SongIndex.entryCount) entries")
for style in Set(SongIndex.entries.map(\.style)) where SongIndex.styleMap[style] == nil {
    check(false, "song index: beat style “\(style)” has no groove mapping")
}
for target in Set(SongIndex.styleMap.values).union(SongIndex.genreFallback.values) {
    check(library.song(for: target) != nil, "song index: no factory song for \(target.label)")
}
for (query, title) in [("hotel california", "Hotel California"), ("ipanema", "Girl from Ipanema"),
                       ("eagles hotel", "Hotel California")] {
    check(SongIndex.search(query).first?.title == title, "song index search “\(query)” should rank \(title) first")
}
check(SongIndex.search("ANTONIO jobim").contains { $0.title == "Girl from Ipanema" }, "song index search ignores case and accents")
if let e = SongIndex.search("take on me").first, let s = library.song(for: e.target) {
    print("Song index: \(SongIndex.entries.count) songs; “\(e.title)” → \(s.name) at \(Int(e.bpm)) BPM")
}

// 2e. .BBS content, when BBS_CONTENT points at an SD card / project folder.
if let bbPath = ProcessInfo.processInfo.environment["BBS_CONTENT"],
   let songsDir = BBSImport.songsFolder(in: URL(fileURLWithPath: bbPath)) {
    let t1 = Date()
    let r = BBSImport.entries(songsFolder: songsDir)
    check(r.failed.isEmpty, "BBS songs failed: \(r.failed)")
    let bbEngine = DrumEngine()
    let bbLib = SongLibrary(store: bbEngine.store)
    let res = bbLib.importFolder(r.entries)
    let jsonCount = r.entries.filter { $0.path.last == SongLibrary.songFileName }.count
    check(res.songs.count == jsonCount, "BBS: imported \(res.songs.count) of \(jsonCount) songs, skipped \(res.skipped.prefix(5))")
    let bbStore = bbEngine.store
    for s in res.songs {
        let rec = bbStore.songs[s.id]
        var pats = [rec.intro, rec.transition, rec.outro]
        for p in 0..<Int(rec.partCount) {
            pats.append(bbStore.partMain[s.id * SongStore.maxParts + p])
            for k in 0..<bbStore.fillCount(song: s.id, part: p) { pats.append(bbStore.fill(song: s.id, part: p, k)) }
        }
        for p in pats where p >= 0 {
            let pr = bbStore.patterns[Int(p)]
            check(pr.length > 0, "BBS \(s.name): empty pattern")
            for e in 0..<Int(pr.count) where Int(bbStore.events[Int(pr.start) + e].tick) >= Int(pr.length) {
                check(false, "BBS \(s.name): event outside pattern")
            }
        }
    }
    func bb(_ name: String) -> SongInfo? { res.songs.first { $0.name == name } }
    check(bb("Blues 1")?.genre == "BBS › Blues" && bb("Blues 1")?.timeSignature == "4/4", "BBS Blues 1 in 4/4")
    check(bb("Blues 1")?.tempo == 110, "BBS Blues 1 tempo \(bb("Blues 1")?.tempo ?? 0)")
    check(bb("Blues 3- 6/8")?.timeSignature == "6/8", "BBS Blues 3 in 6/8")
    check(bb("Jazz 9- 3/4 swing")?.timeSignature == "3/4", "BBS Jazz 9 in 3/4")
    let names = Set(res.songs.map { SongIndex.normalize($0.name) })
    let exact = SongIndex.entries.filter { names.contains(SongIndex.normalize($0.style)) }.count
    check(exact > SongIndex.entries.count * 9 / 10, "most song-index entries should match a .BBS beat (\(exact))")
    // Importing again adds nothing new.
    let again = bbLib.importFolder(r.entries)
    check(bbLib.visibleSongs.filter(\.isUser).count == res.songs.count, "BBS re-import duplicated songs (\(again.songs.count))")
    // The same songs from an exported copy (bbsongs/<Genre>/<Song>/) keep their groups and add nothing.
    let moved = r.entries.map { MIDIFolderImport.Entry(path: ["bbsongs"] + $0.path.dropFirst(), data: $0.data) }
    let fromCopy = bbLib.importFolder(moved)
    check(fromCopy.groups.allSatisfy { $0.hasPrefix("BBS › ") }, "bbsongs copy groups: \(fromCopy.groups.prefix(3))")
    check(bbLib.visibleSongs.filter(\.isUser).count == res.songs.count, "bbsongs copy duplicated songs")
    print("BBS: \(res.songs.count) beats in \(res.groups.count) groups in \(String(format: "%.0f", Date().timeIntervalSince(t1) * 1000)) ms; \(exact)/\(SongIndex.entries.count) indexed songs play the original beat")
}

// 3. Pedal state machine + audio.
let sr = 48000.0
let frames = 512
engine.prepare(sampleRate: sr, maxFrames: frames)
let L = UnsafeMutablePointer<Float>.allocate(capacity: frames)
let R = UnsafeMutablePointer<Float>.allocate(capacity: frames)

func writeWAV(_ samples: [Float], channels: Int, to path: String) {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    let bytes = samples.count * 2
    d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + bytes)); d.append("WAVEfmt ".data(using: .ascii)!)
    u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sr)); u32(UInt32(sr) * UInt32(channels) * 2)
    u16(UInt16(channels * 2)); u16(16); d.append("data".data(using: .ascii)!); u32(UInt32(bytes))
    for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
    try? d.write(to: URL(fileURLWithPath: path))
}

/// Plays a song through a scripted pedal performance. Returns states seen.
func perform(song: Int, seconds: Double, script: [(Double, PedalCommand)], wav: String?) -> (Set<PlayState>, Float, Bool) {
    engine.send(.stop)
    engine.setParameter(.song, Float(song))
    engine.setParameter(.tempo, Float(library.songs[song].tempo))
    engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
    var seen = Set<PlayState>()
    var peak: Float = 0
    var nan = false
    var pcm: [Float] = []
    var pending = script
    let total = Int(seconds * sr / Double(frames))
    for b in 0..<total {
        let t = Double(b * frames) / sr
        while let first = pending.first, first.0 <= t { engine.send(first.1); pending.removeFirst() }
        engine.beginRender()
        engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
        seen.insert(engine.status.state)
        for i in 0..<frames {
            if L[i].isNaN || R[i].isNaN { nan = true }
            peak = max(peak, abs(L[i]), abs(R[i]))
            if wav != nil { pcm.append(L[i]); pcm.append(R[i]) }
        }
    }
    if let wav { writeWAV(pcm, channels: 2, to: wav) }
    return (seen, peak, nan)
}

let demoNames = ["Rock 1", "Funk 1", "Blues 1", "Jazz 1", "Latin 1", "Electronic 1", "Hip-Hop & R&B 3", "Odd Time 2"]
for name in demoNames {
    guard let s = library.songs.first(where: { $0.name.hasPrefix(name + " ") }) else { check(false, "missing \(name)"); continue }
    let beat = 60 / s.tempo
    let script: [(Double, PedalCommand)] = [
        (0.1, .pedalTap),                  // start -> intro
        (0.1 + beat * 12, .pedalTap),      // fill
        (0.1 + beat * 22, .transition),    // next part
        (0.1 + beat * 34, .pedalTap),      // fill in part 2
        (0.1 + beat * 44, .accent),
        (0.1 + beat * 46, .outro),
    ]
    let file = "\(outDir)/\(name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "&", with: "and")).wav"
    let (seen, peak, nan) = perform(song: s.id, seconds: 0.1 + beat * 60, script: script, wav: file)
    print(String(format: "%-34@ peak %.2f states %@", s.name as NSString, peak,
                 seen.map(\.label).sorted().joined(separator: ",")))
    check(!nan, "\(s.name): NaN in output")
    check(peak > 0.05, "\(s.name): silent")
    check(peak <= 1.0, "\(s.name): clipping")
    for st in [PlayState.intro, .main, .fill, .transition, .outro, .stopped] {
        check(seen.contains(st), "\(s.name): never reached \(st.label)")
    }
}

// Every song must start, play and end cleanly (fast, no audio kept).
var silent = 0
for s in library.songs {
    let beat = 60 / s.tempo
    let (seen, peak, nan) = perform(song: s.id, seconds: beat * 28, script: [(0, .start), (beat * 10, .fill), (beat * 16, .outro)], wav: nil)
    check(!nan, "\(s.name): NaN")
    if peak < 0.02 { silent += 1; print("silent: \(s.name)") }
    check(seen.contains(.stopped) && seen.contains(.main), "\(s.name): states \(seen.map(\.label))")
}
check(silent == 0, "\(silent) silent songs")

// 4. MIDI import round trip.
func smf(_ notes: [(Int, UInt8)], ppq: Int = 96, bars: Int = 1, bpm: Int = 120) -> Data {
    let us = 60_000_000 / bpm
    var trk = Data([0x00, 0xFF, 0x51, 0x03, UInt8(us >> 16 & 0xFF), UInt8(us >> 8 & 0xFF), UInt8(us & 0xFF)])
    var last = 0
    func vlq(_ v: Int) -> [UInt8] {
        var v = v; var out = [UInt8(v & 0x7F)]; v >>= 7
        while v > 0 { out.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
        return out
    }
    for (t, n) in notes.sorted(by: { $0.0 < $1.0 }) {
        trk.append(contentsOf: vlq(t - last) + [0x99, n, 100]); last = t
        trk.append(contentsOf: [0x00, 0x89, n, 0])
    }
    trk.append(contentsOf: vlq(ppq * 4 * bars - last) + [0xFF, 0x2F, 0x00])
    var d = Data("MThd".utf8); d.append(contentsOf: [0, 0, 0, 6, 0, 0, 0, 1, UInt8(ppq >> 8), UInt8(ppq & 0xFF)])
    d.append(Data("MTrk".utf8))
    let n = trk.count
    d.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
    d.append(trk)
    return d
}
let mainMid = smf([(0, 36), (96, 38), (192, 36), (288, 38)] + (0..<8).map { ($0 * 48, UInt8(42)) }, bars: 2)
let fillMid = smf([(0, 36), (96, 38), (192, 48), (240, 45), (288, 41), (336, 41)])
do {
    let added = try library.importMIDI([.init(name: "Groove 1 Main.mid", data: mainMid),
                                        .init(name: "Groove 1 Fill.mid", data: fillMid)], asOneSong: true)
    check(added.count == 1, "import should create one song")
    if let s = added.first {
        check(s.partCount == 1 && s.isUser, "imported song shape")
        check(abs(s.tempo - 120) < 0.5, "imported tempo \(s.tempo)")
        let beat = 60 / s.tempo
        let (seen, peak, _) = perform(song: s.id, seconds: beat * 20,
                                      script: [(0, .start), (beat * 6, .fill), (beat * 12, .outro)], wav: nil)
        check(peak > 0.05 && seen.contains(.fill), "imported song plays")
        let again = try library.importMIDI([.init(name: "Groove 1 Main.mid", data: mainMid),
                                            .init(name: "Groove 1 Fill.mid", data: fillMid)], asOneSong: true)
        check(again.first?.id == s.id, "re-import is deduplicated")
        print("Imported: \(s.name), \(s.timeSignature), \(s.tempo) bpm")
    }
} catch { check(false, "MIDI import threw \(error)") }
check((try? MIDIDrumFile(data: Data("hello".utf8), name: "x")) == nil, "garbage rejected")

// 4b. Folder import: pack / style / song folders, flat folders, big folders, persistence.
do {
    func groove(_ bpm: Int = 120) -> Data { smf([(0, 36), (96, 38), (192, 36), (288, 38)] + (0..<8).map { ($0 * 48, UInt8(42)) }, bpm: bpm) }
    func fill(_ note: UInt8, _ bpm: Int = 120) -> Data { smf([(0, 36), (192, note), (240, note), (288, note), (336, note)], bpm: bpm) }
    var entries: [MIDIFolderImport.Entry] = []
    func add(_ path: String, _ d: Data) { entries.append(.init(path: path.components(separatedBy: "/"), data: d)) }
    // A) song folder with sections
    add("Test Pack/Rock/Straight 120/01 Intro.mid", smf([(0, 42), (96, 42), (192, 42), (288, 42)]))
    add("Test Pack/Rock/Straight 120/02 Verse 1.mid", groove())
    add("Test Pack/Rock/Straight 120/03 Verse Fill 1.mid", fill(48))
    add("Test Pack/Rock/Straight 120/04 Chorus 1.mid", groove())
    add("Test Pack/Rock/Straight 120/05 Chorus Fill 1.mid", fill(41))
    add("Test Pack/Rock/Straight 120/06 Bridge.mid", groove())
    add("Test Pack/Rock/Straight 120/07 Ending.mid", smf([(0, 49), (0, 36)]))
    add("Test Pack/Rock/Straight 120/08 Verse 2.mid", smf([(0, 36), (192, 38)] + (0..<4).map { ($0 * 96, UInt8(51)) }))
    // B) flat style folder with two grooves (one at another tempo)
    add("Test Pack/Funk/Funk_Pocket_Verse.mid", groove(98))
    add("Test Pack/Funk/Funk_Pocket_Fill.mid", fill(45, 98))
    add("Test Pack/Funk/Funk_Pocket_Chorus.mid", groove(98))
    add("Test Pack/Funk/SlowGroove_90bpm_Verse.mid", groove(90))
    // C) 12 grooves in one folder -> split into two songs
    for i in 1...12 { add("Test Pack/Big/Verse \(i).mid", groove()) }
    // D) junk and E) loose files in the pack root
    add("Test Pack/Rock/Straight 120/notes.mid", Data("not midi".utf8))
    add("Test Pack/Loose Groove.mid", groove())

    let tmpLib = FileManager.default.temporaryDirectory.appendingPathComponent("pedalbeat-lib-\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: tmpLib) }
    library.useUserLibrary(at: tmpLib)
    let r = library.importFolder(entries)
    print("Folder import: \(r.songs.count) songs in groups \(r.groups), skipped \(r.skipped)")
    for s in r.songs { print("    \(s.genre) / \(s.name): \(s.partCount) parts, \(Int(s.tempo)) bpm, intro \(s.hasIntro)") }
    check(r.groups == ["Test Pack", "Test Pack › Big", "Test Pack › Funk", "Test Pack › Rock"], "groups \(r.groups)")
    check(r.skipped.count == 1 && r.skipped[0].hasSuffix("notes.mid"), "skipped \(r.skipped)")
    let straight = r.songs.first { $0.genre == "Test Pack › Rock" && $0.name == "Straight 120" }
    check(straight?.partCount == 4, "Straight 120 should have 4 parts (verse 1, verse 2, chorus, bridge)")
    if let st = straight {
        // Part order: verse 1, verse 2, chorus, bridge. Chorus fill (note 41 = floor tom) belongs to part 3.
        func drums(_ pattern: Int32) -> Set<Int> {
            let pr = store.patterns[Int(pattern)]
            return Set((0..<Int(pr.count)).map { Int(store.events[Int(pr.start) + $0].drum) })
        }
        let base = st.id * SongStore.maxParts
        check(drums(store.partMain[base + 1]).contains(Drum.ride.rawValue), "verse 2 should be part 2")
        _ = base
        check(drums(store.fill(song: st.id, part: 0, 0)).contains(Drum.tomHigh.rawValue), "verse fill on verse 1")
        check(drums(store.fill(song: st.id, part: 1, 0)).contains(Drum.tomHigh.rawValue), "verse fill also on verse 2")
        check(drums(store.fill(song: st.id, part: 2, 0)).contains(Drum.tomLow.rawValue), "chorus fill on chorus")
        check(store.fillCount(song: st.id, part: 2) == 1, "chorus has only the chorus fill")
        check(st.hasIntro && st.hasOutro, "intro/ending used")
        let beat = 60 / st.tempo
        let (seen, peak, _) = perform(song: st.id, seconds: beat * 30,
            script: [(0, .pedalTap), (beat * 8, .pedalTap), (beat * 14, .transition), (beat * 22, .outro)], wav: nil)
        check(peak > 0.05 && seen.contains(.intro) && seen.contains(.outro), "folder song plays")
    }
    let funk = r.songs.filter { $0.genre == "Test Pack › Funk" }.map(\.name).sorted()
    check(funk == ["Funk Pocket", "Slow Groove"], "funk songs \(funk)")
    check(r.songs.first { $0.name == "Funk Pocket" }?.partCount == 2, "Funk Pocket parts")
    check(abs((r.songs.first { $0.name == "Slow Groove" }?.tempo ?? 0) - 90) < 0.5, "Slow Groove tempo")
    let big = r.songs.filter { $0.genre == "Test Pack › Big" }.map { "\($0.name):\($0.partCount)" }
    check(big == ["Big 1:8", "Big 2:4"], "big folder split \(big)")
    check(r.songs.contains { $0.genre == "Test Pack" && $0.name == "Loose Groove" }, "loose root file")

    // Several fills per groove: "Groove A Fill 1/2/3" -> Groove A, "Groove B Fill" -> Groove B.
    var multi: [MIDIFolderImport.Entry] = []
    func addM(_ name: String, _ d: Data) { multi.append(.init(path: ["Fill Pack", "Style", name], data: d)) }
    addM("Groove A.mid", groove()); addM("Groove B.mid", groove())
    addM("Groove A Fill 1.mid", fill(48)); addM("Groove A Fill 2.mid", fill(45)); addM("Groove A Fill 3.mid", fill(41))
    addM("Groove B Fill.mid", fill(39))
    let mr = library.importFolder(multi)
    if let ms = mr.songs.first {
        check(mr.songs.count == 1 && ms.partCount == 2, "multi-fill song shape \(mr.songs.map { "\($0.name):\($0.partCount)" })")
        check(store.fillCount(song: ms.id, part: 0) == 3 && store.fillCount(song: ms.id, part: 1) == 1,
              "fills per part: \(store.fillCount(song: ms.id, part: 0)), \(store.fillCount(song: ms.id, part: 1))")
        // Pedal: three fills in a row on part 1 play fill 1, 2, 3 in order, then wrap to 1.
        func fillSequence(random: Bool, count: Int) -> [Int] {
            engine.setParameter(.fillOrder, random ? 1 : 0)
            engine.send(.stop); engine.setParameter(.song, Float(ms.id)); engine.setParameter(.tempo, 120)
            engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
            engine.send(.start)
            var played: [Int] = []
            var last = 0
            let bar = Int(sr * 2)  // one 4/4 bar at 120 bpm
            var t = 0
            var nextFillAt = bar + bar / 8
            while played.count < count && t < bar * (count * 3 + 4) {
                if t >= nextFillAt { engine.send(.fill); nextFillAt += bar * 2 }
                engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
                let st = engine.status
                if st.state == .fill && st.fillNumber != 0 && st.fillNumber != last { played.append(st.fillNumber) }
                last = st.state == .fill ? st.fillNumber : 0
                t += frames
            }
            engine.send(.stop)
            engine.setParameter(.fillOrder, 0)
            return played
        }
        let ordered = fillSequence(random: false, count: 4)
        check(ordered == [1, 2, 3, 1], "fills in order: \(ordered)")
        let random = fillSequence(random: true, count: 8)
        check(random.count == 8 && zip(random, random.dropFirst()).allSatisfy { $0 != $1 }, "random fills never repeat: \(random)")
        print("Fill order: in order \(ordered), random \(random)")
    } else { check(false, "multi-fill import failed") }

    // Song editor: reorder parts, move a fill, automatic intro, rename.
    var editedID = -1
    if let st = straight, let rec = library.importRecord(forKey: st.key), var lay = rec.layout {
        let names = lay.parts.map(\.main)
        check(names == ["02 Verse 1.mid", "08 Verse 2.mid", "04 Chorus 1.mid", "06 Bridge.mid"], "automatic part order \(names)")
        let info = library.fileInfo(forKey: st.key)
        check(info.count == 8 && info.first { $0.name == "07 Ending.mid" }?.role == "Ending", "file info \(info.map { "\($0.name):\($0.role)" })")
        lay.parts.reverse()                                   // bridge, chorus, verse 2, verse 1
        lay.parts[0].fills = ["05 Chorus Fill 1.mid", "03 Verse Fill 1.mid"]
        lay.intro = nil                                       // generated count-in
        do {
            let edited = try library.updateSong(key: st.key, name: "Straight Edit", layout: lay)
            editedID = edited.id
            check(edited.id != st.id && edited.name == "Straight Edit" && edited.partCount == 4, "edited song")
            check(library.index(forKey: st.key) == edited.id, "key resolves to edited version")
            check(!library.visibleSongs.contains { $0.id == st.id }, "old version hidden")
            check(library.visibleSongs.contains { $0.id == edited.id }, "edited version listed")
            func drums(_ pattern: Int32) -> Set<Int> {
                let pr = store.patterns[Int(pattern)]
                return Set((0..<Int(pr.count)).map { Int(store.events[Int(pr.start) + $0].drum) })
            }
            check(store.fillCount(song: edited.id, part: 0) == 2, "bridge now has 2 fills")
            check(drums(store.fill(song: edited.id, part: 0, 0)).contains(Drum.tomLow.rawValue)
                  && drums(store.fill(song: edited.id, part: 0, 1)).contains(Drum.tomHigh.rawValue), "moved fills in order")
            check(drums(store.partMain[edited.id * SongStore.maxParts + 2]).contains(Drum.ride.rawValue), "verse 2 is now part 3")
            let beat = 60 / edited.tempo
            let (seen, peak, _) = perform(song: edited.id, seconds: beat * 24,
                script: [(0, .pedalTap), (beat * 8, .pedalTap), (beat * 16, .outro)], wav: nil)
            check(peak > 0.05 && seen.contains(.fill) && seen.contains(.outro), "edited song plays")
            // Auditioning files: a groove loops, a fill plays once, stop and the pedal end it.
            func renderSeconds(_ secs: Double) -> Float {
                var pk: Float = 0
                for _ in 0..<Int(secs * sr / Double(frames)) {
                    engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
                    for i in 0..<frames { pk = max(pk, abs(L[i]), abs(R[i])) }
                }
                return pk
            }
            engine.send(.stop); engine.setParameter(.tempo, 120); engine.synth.reset(); _ = renderSeconds(0.2)
            let groovePat = library.previewPattern(forKey: st.key, file: "02 Verse 1.mid")
            check(groovePat != nil && groovePat == library.previewPattern(forKey: st.key, file: "02 Verse 1.mid"), "preview pattern cached")
            if let gp = groovePat, let fp = library.previewPattern(forKey: st.key, file: "05 Chorus Fill 1.mid") {
                engine.preview(pattern: gp, loop: true)
                let loopPeak = renderSeconds(5)       // 2.5 bars of a 1-bar groove
                check(loopPeak > 0.05 && engine.status.previewing && engine.status.state == .stopped, "groove preview loops")
                engine.stopPreview(); _ = renderSeconds(0.1)
                check(!engine.status.previewing, "preview stops")
                engine.synth.reset()
                engine.preview(pattern: fp, loop: false)
                let fillPeak = renderSeconds(1.0)
                check(fillPeak > 0.05 && engine.status.previewing, "fill preview plays")
                _ = renderSeconds(1.5)                // past the 2 s bar
                check(!engine.status.previewing, "fill preview plays once")
                engine.preview(pattern: gp, loop: true); _ = renderSeconds(0.5)
                engine.setParameter(.song, Float(edited.id)); engine.send(.start); _ = renderSeconds(0.2)
                check(!engine.status.previewing && engine.status.state != .stopped, "pedal start ends preview")
                engine.send(.stop); _ = renderSeconds(0.1)
            } else { check(false, "preview patterns") }
            check(library.previewPattern(forKey: st.key, file: "missing.mid") == nil, "unknown file not previewable")

            // Empty layout is rejected.
            check((try? library.updateSong(key: st.key, name: "x", layout: .init(parts: []))) == nil, "empty layout rejected")
        } catch { check(false, "updateSong threw \(error)") }
    } else { check(false, "no layout for Straight 120") }

    // Persistence: a fresh library restores the groups from disk.
    Thread.sleep(forTimeInterval: 0.5)
    let lib2 = SongLibrary(store: SongStore())
    lib2.useUserLibrary(at: tmpLib)
    let restored = lib2.visibleSongs.filter(\.isUser)
    check(restored.count == r.songs.count + 2, "restored \(restored.count) of \(r.songs.count + 2)")  // + earlier MIDI import + multi-fill
    check(Set(restored.map(\.genre)).isSuperset(of: r.groups), "restored groups")
    if let e = library.song(at: editedID), let ri = lib2.index(forKey: e.key), let rs = lib2.song(at: ri) {
        check(rs.name == "Straight Edit" && lib2.importRecord(forKey: e.key)?.layout == library.importRecord(forKey: e.key)?.layout,
              "edited layout restored")
    } else { check(false, "edited song not restored") }
    // Removing a whole group.
    library.hide(genre: "Test Pack › Big")
    check(!library.visibleSongs.contains { $0.genre == "Test Pack › Big" }, "group removed")
    check(library.visibleSongs.contains { $0.genre == "Test Pack › Funk" }, "other groups kept")
    // Re-import is deduplicated and brings removed songs back.
    let again = library.importFolder(entries)
    check(Set(again.songs.map(\.key)) == Set(r.songs.map(\.key)), "re-import deduplicated")
    check(again.songs.contains { $0.name == "Straight Edit" }, "re-import keeps the edited version")
    check(library.visibleSongs.contains { $0.genre == "Test Pack › Big" }, "re-import restores removed group")

    // Factory songs in the editor: lossless round trip through MIDI files for every song.
    func patternSig(_ idx: Int32) -> String {
        guard idx >= 0 else { return "-" }
        let pr = store.patterns[Int(idx)]
        let evs = (0..<Int(pr.count)).map { store.events[Int(pr.start) + $0] }
            .sorted { ($0.tick, $0.drum, $0.velocity, $0.swingUnit) < ($1.tick, $1.drum, $1.velocity, $1.swingUnit) }
        return "\(pr.length):" + evs.map { "\($0.tick),\($0.drum),\($0.velocity),\($0.swingUnit)" }.joined(separator: ";")
    }
    func songSig(_ i: Int) -> String {
        let r = store.songs[i]
        var parts: [String] = []
        for p in 0..<Int(r.partCount) {
            parts.append(patternSig(store.partMain[i * SongStore.maxParts + p]))
            parts.append((0..<store.fillCount(song: i, part: p)).map { patternSig(store.fill(song: i, part: p, $0)) }.joined(separator: "|"))
        }
        return "\(r.tempo) \(r.barTicks) \(r.beatTicks) \(r.introCrash) \(r.fillCrash) \(patternSig(r.intro)) "
            + "\(patternSig(r.transition)) \(patternSig(r.outro)) " + parts.joined(separator: " / ")
    }
    let factorySongs = library.visibleSongs.filter { !$0.isUser }
    var roundTripFailures: [String] = []
    for fs in factorySongs {
        guard let draft = library.beginEditing(fs), let lay = draft.layout,
              let copy = try? library.updateSong(key: fs.key, name: fs.name, layout: lay) else {
            roundTripFailures.append("\(fs.name): no copy"); continue
        }
        if songSig(copy.id) != songSig(fs.id) || copy.kitHint != fs.kitHint || copy.genre != fs.genre
            || copy.timeSignature != fs.timeSignature { roundTripFailures.append(fs.name) }
        library.revertToFactory(key: fs.key)
    }
    print("Factory round trip: \(factorySongs.count - roundTripFailures.count)/\(factorySongs.count) identical")
    check(roundTripFailures.isEmpty, "factory round trip differs: \(roundTripFailures.prefix(5))")
    check(library.visibleSongs.filter { !$0.isUser }.count == factorySongs.count, "all factory songs back after revert")

    // Edit a factory song: the copy takes its place; revert restores the original.
    if let rock = factorySongs.first(where: { $0.name.hasPrefix("Rock 1 ") }), let d = library.beginEditing(rock), var lay = d.layout {
        check(d.files.map(\.name).contains("Groove A Fill 3.mid") && lay.parts.count >= 2, "factory draft files \(d.files.map(\.name))")
        check(library.index(forKey: rock.key) == rock.id && !library.isEditedFactorySong(key: rock.key), "draft does not replace yet")
        lay.parts.removeLast()
        lay.fillCrash = false
        let copy = try library.updateSong(key: rock.key, name: "Rock 1 · My Version", layout: lay)
        let vis = library.visibleSongs.filter { $0.key == rock.key }
        check(vis.count == 1 && vis[0].id == copy.id && vis[0].genre == rock.genre && vis[0].isUser, "copy replaces factory song")
        check(copy.partCount == rock.partCount - 1 && !store.songs[copy.id].fillCrash, "edits applied")
        check(library.isEditedFactorySong(key: rock.key), "marked as edited")
        // Second edit of the copy.
        var lay2 = library.importRecord(forKey: rock.key)!.layout!
        lay2.parts.swapAt(0, lay2.parts.count - 1)
        let copy2 = try library.updateSong(key: rock.key, name: "Rock 1 · My Version", layout: lay2)
        check(library.visibleSongs.filter { $0.key == rock.key }.map(\.id) == [copy2.id], "second edit replaces first")
        // Persistence: a fresh library applies the edit over its factory song.
        Thread.sleep(forTimeInterval: 0.5)
        let lib3 = SongLibrary(store: SongStore())
        lib3.useUserLibrary(at: tmpLib)
        let v3 = lib3.visibleSongs.filter { $0.key == rock.key }
        check(v3.count == 1 && v3[0].isUser && v3[0].name == "Rock 1 · My Version", "edited factory song restored \(v3.map(\.name))")
        check(lib3.visibleSongs.filter { !$0.isUser }.count == factorySongs.count - 1, "restored library hides the original")
        // Revert.
        let back = library.revertToFactory(key: rock.key)
        check(back?.id == rock.id && library.visibleSongs.filter { $0.key == rock.key }.map(\.id) == [rock.id], "revert to factory")
        check(library.importRecord(forKey: rock.key) == nil, "revert removes the copy")
    } else { check(false, "factory edit setup") }
    // Export every factory song to folders and import them again: identical songs.
    let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("pedalbeat-export-\(UUID().uuidString)/songs")
    defer { try? FileManager.default.removeItem(at: exportDir.deletingLastPathComponent()) }
    do {
        let n = try library.exportSongs(factorySongs, to: exportDir)
        let base = exportDir.deletingLastPathComponent().standardizedFileURL.pathComponents.count
        var exported: [MIDIFolderImport.Entry] = []
        for case let f as URL in FileManager.default.enumerator(at: exportDir, includingPropertiesForKeys: nil)!
            where f.pathExtension == "mid" || f.lastPathComponent == SongLibrary.songFileName {
            exported.append(.init(path: Array(f.standardizedFileURL.pathComponents.dropFirst(base)), data: try Data(contentsOf: f)))
        }
        let folders = Set(exported.map { $0.path.dropLast().joined(separator: "/") })
        check(n == factorySongs.count && folders.count == factorySongs.count, "exported \(n) songs in \(folders.count) folders")
        check(FileManager.default.fileExists(atPath: exportDir.appendingPathComponent("Rock/09 Straight Eights + Driving/Groove A Fill 1.mid").path),
              "combination song folder name")
        let back = library.importFolder(exported)
        var mismatches: [String] = []
        for fs in factorySongs {
            guard let imp = back.songs.first(where: { $0.name == fs.name && $0.genre == "songs › \(fs.genre)" }) else {
                mismatches.append("missing \(fs.name)"); continue
            }
            if songSig(imp.id) != songSig(fs.id) || imp.kitHint != fs.kitHint || imp.timeSignature != fs.timeSignature {
                mismatches.append(fs.name)
            }
        }
        print("Export + folder import: \(factorySongs.count - mismatches.count)/\(factorySongs.count) identical, \(exported.count) files")
        check(mismatches.isEmpty, "export round trip: \(mismatches.prefix(5))")
        library.hide(genre: "songs")
        for g in Set(back.songs.map(\.genre)) { library.hide(genre: g) }
    } catch { check(false, "export failed: \(error)") }

    // Cancelling an edit leaves nothing behind.
    if let funk = factorySongs.first(where: { $0.name.hasPrefix("Funk 1 ") }) {
        _ = library.beginEditing(funk)
        library.cancelEditing(key: funk.key)
        check(library.importRecord(forKey: funk.key) == nil && library.index(forKey: funk.key) == funk.id, "cancel discards draft")
    }
}

/// Plays a brush sweep on every beat for `beats` beats at 100 bpm, then lets it ring out.
/// Returns per-20ms RMS (dB) during the sweeps, the RMS after the release, and the snare tap peak.
func sweepRun(beats: Int, velocity: UInt8 = 98, wav: String?) -> (during: [Float], after: Float, tapPeak: Float) {
    engine.send(.stop)
    engine.synth.reset()   // start from silence
    engine.setParameter(.tempo, 100)
    let beatFrames = Int(sr * 60 / 100)
    let total = beatFrames * (beats + 4)
    var mono: [Float] = [], pcm: [Float] = []
    var pos = 0
    while pos < total {
        engine.beginRender()
        for b in 0..<beats where b * beatFrames >= pos && b * beatFrames < pos + frames {
            engine.handleMIDI(0x99, Drum.brushSweep.gmNote, velocity, offset: b * beatFrames - pos)
        }
        engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
        for i in 0..<frames { mono.append((L[i] + R[i]) * 0.5); if wav != nil { pcm.append(L[i]); pcm.append(R[i]) } }
        pos += frames
    }
    if let wav { writeWAV(pcm, channels: 2, to: wav) }
    func rms(_ a: Int, _ b: Int) -> Float {
        var acc: Float = 0
        for i in a..<min(b, mono.count) { acc += mono[i] * mono[i] }
        return 10 * log10(acc / Float(max(b - a, 1)) + 1e-20)
    }
    let win = Int(0.02 * sr)
    var during: [Float] = []
    var w = Int(0.1 * sr)  // skip the first stroke's fade-in
    while w + win < beats * beatFrames { during.append(rms(w, w + win)); w += win }
    let releaseEnd = (beats - 1) * beatFrames + 2 * beatFrames + Int(0.3 * sr)
    let after = rms(releaseEnd, total)
    // Snare tap for level reference.
    engine.send(.stop); engine.synth.reset(); engine.beginRender()
    engine.handleMIDI(0x99, Drum.snare.gmNote, 98, offset: 0)
    var tap: Float = 0
    for _ in 0..<20 {
        engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
        for i in 0..<frames { tap = max(tap, abs(L[i]), abs(R[i])) }
        engine.beginRender()
    }
    return (during, after, tap)
}

func checkSweeps(_ name: String, wav: String?) {
    let r = sweepRun(beats: 8, wav: wav)
    let sorted = r.during.sorted()
    let median = sorted[sorted.count / 2], minimum = sorted.first ?? -200
    print(String(format: "    sweeps: median %.1f dB, quietest 20 ms %.1f dB, after release %.0f dB, snare tap peak %.1f dB",
                 median, minimum, r.after, 20 * log10(r.tapPeak)))
    check(median > -60, "\(name): sweeps inaudible")
    check(minimum > median - 15, "\(name): gap in continuous sweep (\(minimum) vs \(median))")
    check(r.after < -90, "\(name): sweep did not release (\(r.after) dB)")
}

/// Light / medium / hard sweeps (groove letters o, x, X) must get louder in that order.
func checkSweepDynamics(_ name: String) {
    let levels: [Float] = [72, 98, 120].map { v in
        let d = sweepRun(beats: 4, velocity: UInt8(v), wav: nil).during.sorted()
        return d[d.count / 2]
    }
    print(String(format: "    sweep dynamics: o %.1f dB, x %.1f dB, X %.1f dB", levels[0], levels[1], levels[2]))
    check(levels[0] < levels[1] && levels[1] < levels[2], "\(name): sweep levels not increasing \(levels)")
}

/// Renders the Pop ballad through intro, fill, transition and outro with the current kit.
func popBalladDemo(_ file: String) {
    guard let s = library.songs.first(where: { $0.genre == "Pop" && $0.name.hasSuffix("Ballad Sidestick") }) else { return }
    engine.synth.reset()
    let beat = 60 / s.tempo
    let (seen, peak, nan) = perform(song: s.id, seconds: 0.1 + beat * 40,
        script: [(0.1, .pedalTap), (0.1 + beat * 12, .pedalTap), (0.1 + beat * 20, .transition), (0.1 + beat * 32, .outro)],
        wav: file)
    check(!nan && peak > 0.05 && seen.contains(.outro), "Pop ballad demo \(file)")
}

// 5. Sample kits (.pbkit): import, load off-thread, play, switch, free.
let kitsDir = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "kits")
let kitFiles = ((try? FileManager.default.contentsOfDirectory(at: kitsDir, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "pbkit" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
if kitFiles.isEmpty { print("(no .pbkit files in \(kitsDir.path); skipping kit tests)") }
let tmpKits = FileManager.default.temporaryDirectory.appendingPathComponent("pedalbeat-kittest-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: tmpKits) }
let kitManager = KitManager(engine: engine, directory: tmpKits)
func waitForKit(_ id: String?) -> Bool {
    for _ in 0..<500 {
        engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
        if kitManager.activeSampleKitID == id && !kitManager.isLoading { return true }
        usleep(10_000)
    }
    return false
}
let demoForCategory = ["jazz": "Jazz 1", "brushes": "Jazz 3", "acoustic": "Rock 1"]
for f in kitFiles {
    do {
        let m = try KitFile.readManifest(url: f)
        // Manifest integrity.
        for (key, map) in m.drums {
            check(Drum.named(key) != nil, "\(m.name): unknown drum \(key)")
            for l in map.layers { for r in l.regions {
                check(r.start >= 0 && r.length > 0 && r.start + r.length <= m.frames, "\(m.name): region out of range")
                check(r.gain > 0 && r.gain.isFinite, "\(m.name): bad gain")
            } }
        }
        let t = Date()
        let idx = try kitManager.importKit(from: f)
        engine.setParameter(.kit, Float(idx))
        kitManager.select(index: idx)
        check(waitForKit(m.id), "\(m.name): kit did not load")
        let loadMs = Date().timeIntervalSince(t) * 1000
        check(engine.sampleKitInUse != 0, "\(m.name): audio thread not using kit")
        let songName = demoForCategory[m.category] ?? "Rock 1"
        guard let s = library.songs.first(where: { $0.name.hasPrefix(songName + " ") }) else { continue }
        let beat = 60 / s.tempo
        let file = "\(outDir)/kit_\(m.id.replacingOccurrences(of: "pedalbeat.", with: "")).wav"
        var (seen, peak, nan) = perform(song: s.id, seconds: 0.1 + beat * 40,
            script: [(0.1, .pedalTap), (0.1 + beat * 10, .pedalTap), (0.1 + beat * 20, .transition),
                     (0.1 + beat * 30, .outro)], wav: file)
        check(!nan, "\(m.name): NaN")
        check(peak > 0.1, "\(m.name): too quiet (\(peak))")
        check(seen.contains(.fill) && seen.contains(.outro), "\(m.name): states")
        // Every drum, every velocity: no NaN, audible.
        var drumPeaks: [String] = []
        for d in Drum.allCases {
            var dp: Float = 0
            for v in stride(from: 10, through: 127, by: 39) {
                engine.send(.stop)
                engine.beginRender()
                engine.handleMIDI(0x99, d.gmNote, UInt8(v), offset: 0)
                for _ in 0..<40 {
                    engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
                    for i in 0..<frames { if L[i].isNaN { nan = true }; dp = max(dp, abs(L[i]), abs(R[i])) }
                    engine.beginRender()
                }
            }
            drumPeaks.append(String(format: "%@ %.2f", d.key, dp))
            if d != .brushSweep || m.drums[d.key] != nil { check(dp > 0.005, "\(m.name): \(d.key) silent") }
        }
        check(!nan, "\(m.name): NaN in drum test")
        if m.drums[Drum.brushSweep.key] != nil {
            checkSweeps(m.name, wav: "\(outDir)/kit_\(m.id.replacingOccurrences(of: "pedalbeat.", with: ""))_sweeps.wav")
            checkSweepDynamics(m.name)
            popBalladDemo("\(outDir)/pop_ballad_brush_kit.wav")
            check(m.drums[Drum.brushSweep.key]?.layers.count == 3, "\(m.name): expected 3 sweep layers")
        }
        print(String(format: "Kit %-16@ %2d drums  load %4.0f ms  %.1f MB  song peak %.2f", m.name as NSString, m.drums.count,
                     loadMs, Double(m.frames * 4) / 1e6, peak))
        print("    " + drumPeaks.joined(separator: "  "))
    } catch { check(false, "\(f.lastPathComponent): \(error)") }
}
// Synthesized Brushes kit sweeps; other synth kits leave sweeps silent.
engine.setParameter(.kit, 4); kitManager.select(index: 4); _ = waitForKit(nil)
print("Synth Brushes kit:")
checkSweeps("Synth Brushes", wav: "\(outDir)/synth_brushes_sweeps.wav")
popBalladDemo("\(outDir)/pop_ballad_brushes.wav")
engine.setParameter(.kit, 0); kitManager.select(index: 0); _ = waitForKit(nil)
let studioSweep = sweepRun(beats: 2, wav: nil).during.max() ?? 0
print(String(format: "    studio kit sweep level %.0f dB", studioSweep))
check(studioSweep < -100, "Studio synth kit should not play sweeps")

if !kitFiles.isEmpty {
    // Switch back to a synth kit: the sample kit must be released once the audio thread lets go.
    engine.setParameter(.kit, 0)
    kitManager.select(index: 0)
    check(waitForKit(nil), "switch back to synth kit")
    check(engine.sampleKitInUse == 0, "audio thread released sample kit")
    check((try? KitFile.readManifest(url: URL(fileURLWithPath: "\(outDir)/Rock_1.wav"))) == nil, "non-kit file rejected")
}

print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
