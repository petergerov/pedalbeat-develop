import Foundation

// Offline checks for the core engine: library integrity, pedal state machine,
// audio sanity (no NaN / clipping), MIDI import. Writes demo WAVs to argv[1].

// Default under build/ so running from the repo root does not dump demo WAVs into git.
let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("build/rendertest-out")
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
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
check(SongIndex.songKey(artist: "AC/DC", title: "What's Up?") == SongIndex.songKey(artist: "AC DC", title: "What's Up"),
      "song key ignores punctuation (index “AC/DC” vs folder “AC DC”)")
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

let demoNames = ["Rock 1", "Funk 1", "Blues 1", "Jazz 1", "Latin 1", "Electronic 1", "Hip-Hop & R&B 3", "Odd Time 2",
                 "Bass & Drums 1", "Bass & Drums 3"]
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
    func bassSig(_ idx: Int32) -> String {
        guard let b = store.bassPattern(idx) else { return "-" }
        return "\(b.length):" + b.events.sorted { ($0.tick, $0.note) < ($1.tick, $1.note) }
            .map { "\($0.tick),\($0.note),\($0.velocity),\($0.durationTicks)" }.joined(separator: ";")
    }
    func songSig(_ i: Int) -> String {
        let r = store.songs[i]
        var parts: [String] = []
        for p in 0..<Int(r.partCount) {
            parts.append(patternSig(store.partMain[i * SongStore.maxParts + p]))
            parts.append((0..<store.fillCount(song: i, part: p)).map { patternSig(store.fill(song: i, part: p, $0)) }.joined(separator: "|"))
            parts.append(bassSig(store.bass(song: i, part: p)))
        }
        return "\(r.tempo) \(r.barTicks) \(r.beatTicks) \(r.introCrash) \(r.fillCrash) \(patternSig(r.intro)) "
            + "\(patternSig(r.transition)) \(patternSig(r.outro)) " + parts.joined(separator: " / ")
            + " bass \(r.bassEnabled) \(bassSig(r.introBass)) \(bassSig(r.transitionBass)) \(bassSig(r.outroBass))"
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
        // Loaded, and the audio thread has picked it up (the kit may be published just after
        // this block's render; then the next render takes it).
        if kitManager.activeSampleKitID == id && !kitManager.isLoading
            && engine.sampleKitInUse == engine.publishedSampleKit { return true }
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
        check(engine.sampleKitInUse != 0 && engine.sampleKitInUse == engine.publishedSampleKit,
              "\(m.name): audio thread not using kit")
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

// 6. MIDI Settings: Learn, the default notes 0-9, and what the engine does with a message.
do {
    func learned(_ s: UInt8, _ d1: UInt8, _ d2: UInt8) -> MIDITrigger? { MIDITrigger(status: s, data1: d1, data2: d2) }
    check(learned(0xB3, 80, 127) == MIDITrigger(kind: .controlChange, number: 80), "learn CC at 127")
    check(learned(0xB0, 80, 0) == MIDITrigger(kind: .controlChange, number: 80, firesOnAnyValue: true), "learn CC at 0 fires on any value")
    check(learned(0x95, 60, 100) == MIDITrigger(kind: .note, number: 60), "learn note")
    check(learned(0xC0, 4, 0) == MIDITrigger(kind: .programChange, number: 4), "learn program change")
    check(learned(0x90, 60, 0) == nil && learned(0x80, 60, 64) == nil && learned(0xE0, 0, 64) == nil, "note off and pitch bend aren't learned")
    check(MIDITrigger(kind: .note, number: 0).title == "Note 0 (C-2)" && MIDITrigger(kind: .note, number: 60).title == "Note 60 (C3)",
          "note names")
    check(MIDIMonitor.Message(status: 0xB0, data1: 80, data2: 127).summary == "CC 80 · value 127 · channel 1", "last received summary")

    let defaults = MIDIMappings.default
    check(MIDIAction.allCases.enumerated().allSatisfy { defaults.command(status: 0x9A, data1: UInt8($0), data2: 1) == $1.command },
          "default notes 0-9 on any channel")
    check(defaults.command(status: 0x80, data1: 0, data2: 0) == nil && defaults.command(status: 0x90, data1: 0, data2: 0) == nil,
          "note off is not a press")
    check(defaults.command(status: 0xB0, data1: 80, data2: 127) == nil, "CC 80 is not a default")
    check(defaults.selectedSong(status: 0xC2, data1: 7, data2: 0) == 7, "program change selects a song")

    var custom = MIDIMappings.default
    custom.assign(MIDITrigger(kind: .controlChange, number: 64, firesOnAnyValue: true), to: .pedalTap)
    check(custom.command(status: 0xB0, data1: 64, data2: 0) == .pedalTap && custom.command(status: 0xB0, data1: 64, data2: 127) == .pedalTap,
          "any-value CC")
    custom.assign(MIDITrigger(kind: .controlChange, number: 80), to: .nextSong)
    check(custom.command(status: 0xB0, data1: 80, data2: 127) == .nextSong && custom.command(status: 0xB0, data1: 80, data2: 0) == nil,
          "footswitch release ignored")
    custom.assign(MIDITrigger(kind: .note, number: 1), to: .fill)
    check(custom.triggers[.startStop] == nil && custom.command(status: 0x90, data1: 1, data2: 100) == .fill, "assigning moves the trigger")
    custom.assign(MIDITrigger(kind: .programChange, number: 3), to: .accent)
    check(custom.command(status: 0xC0, data1: 3, data2: 0) == .accent && custom.selectedSong(status: 0xC0, data1: 3, data2: 0) == nil,
          "an action wins over song select")
    custom.programChangeSelectsSong = false
    check(custom.selectedSong(status: 0xC0, data1: 2, data2: 0) == nil, "song select off")

    let suiteName = "pedalbeat-midi-test-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    check(MIDIMappings.load(from: suite) == .default, "defaults before saving")
    custom.save(to: suite)
    check(MIDIMappings.load(from: suite) == custom, "mappings round trip")
    suite.removePersistentDomain(forName: suiteName)

    // The audio thread's table answers like the mappings for every message.
    let table = MIDIControlTable()
    for mappings in [defaults, custom] {
        table.update(mappings)
        var mismatches = 0
        for s: UInt8 in [0x80, 0x90, 0x9F, 0xB0, 0xB7, 0xC0, 0xCF, 0xE0] {
            for d1 in UInt8(0)..<128 {
                for d2: UInt8 in [0, 1, 63, 64, 127]
                where table.command(status: s, data1: d1, data2: d2) != mappings.command(status: s, data1: d1, data2: d2) {
                    mismatches += 1
                }
            }
        }
        check(mismatches == 0 && table.programChangeSelectsSong == mappings.programChangeSelectsSong,
              "audio-thread table matches the mappings (\(mismatches) messages differ)")
    }

    // Engine: the notes one message plays (MIDI out), while stopped.
    func notesPlayed(_ s: UInt8, _ d1: UInt8, _ d2: UInt8) -> Set<UInt8> {
        engine.beginRender()
        engine.handleMIDI(s, d1, d2, offset: 0)
        var notes = Set<UInt8>()
        engine.forEachOutputEvent { _, note, _ in notes.insert(note) }
        engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
        return notes
    }
    let accentNotes: Set<UInt8> = [Drum.crash.gmNote, Drum.kick.gmNote]
    engine.send(.stop)
    engine.setParameter(.song, 0)
    engine.setMIDIMappings(.default)
    check(notesPlayed(0x99, Drum.kick.gmNote, 100) == [Drum.kick.gmNote], "GM drum note plays the kit")
    check(notesPlayed(0x99, Drum.brushSweep.gmNote, 100) == [Drum.brushSweep.gmNote], "note 88 plays the brush sweep")
    check(notesPlayed(0x90, 6, 100) == accentNotes, "note 6 is the accent")
    var snareAccent = MIDIMappings.default
    snareAccent.assign(MIDITrigger(kind: .note, number: Drum.snare.gmNote), to: .accent)
    engine.setMIDIMappings(snareAccent)
    check(notesPlayed(0x99, Drum.snare.gmNote, 100) == accentNotes, "an assigned drum note does its action instead of playing")
    check(notesPlayed(0x90, 6, 100).isEmpty, "a cleared default note does nothing")
    engine.setMIDIMappings(.default)

    // Learn: only while MIDI Settings listens; the press it takes is reported, not played.
    let monitor = engine.midiMonitor
    monitor.isLearning = true
    check(!monitor.isLearning, "Learn needs MIDI Settings open")
    monitor.isListening = true
    monitor.isLearning = true
    check(notesPlayed(0x90, 0, 100).isEmpty && engine.status.state == .stopped, "the press Learn takes doesn't play")
    check(!monitor.isLearning && notesPlayed(0x99, Drum.kick.gmNote, 90) == [Drum.kick.gmNote], "Learn takes one press")
    check(monitor.drain() == [.init(status: 0x90, data1: 0, data2: 100), .init(status: 0x99, data1: Drum.kick.gmNote, data2: 90)],
          "monitor reports what arrived")
    monitor.isLearning = true
    monitor.isListening = false
    check(!monitor.isLearning, "closing MIDI Settings ends Learn")
    _ = notesPlayed(0x99, Drum.kick.gmNote, 90)
    check(monitor.drain().isEmpty, "nothing kept while MIDI Settings is closed")

    // Song select: program change, the switch, and a song action learned from a footswitch CC.
    _ = notesPlayed(0xC0, 3, 0)
    check(engine.songParam.value == 3, "program change selects song 3")
    var footswitch = MIDIMappings.default
    footswitch.programChangeSelectsSong = false
    footswitch.assign(MIDITrigger(kind: .controlChange, number: 80), to: .nextSong)
    engine.setMIDIMappings(footswitch)
    _ = notesPlayed(0xC0, 5, 0)
    check(engine.songParam.value == 3, "song select off in the engine")
    _ = notesPlayed(0xB0, 80, 127)
    check(engine.songParam.value == 4, "learned CC 80 selects the next song")
    _ = notesPlayed(0xB0, 80, 0)
    check(engine.songParam.value == 4, "footswitch release ignored in the engine")

    engine.setMIDIMappings(.default)
    engine.setParameter(.song, 0)
    print("MIDI Settings: Learn, defaults, table and engine checked")
}

// 7. MIDI Clock Out: Start / Stop / Continue and 24 PPQN at the song tempo.
do {
    engine.send(.stop)
    engine.setParameter(.song, 0)
    engine.setParameter(.tempo, 120)
    engine.setParameter(.hostSync, 0)
    engine.setParameter(.midiClockOut, 1)
    engine.beginRender()
    engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
    var idle: [UInt8] = []
    engine.forEachClockEvent { _, b0, _, _, _ in idle.append(b0) }
    check(idle.isEmpty, "no clock while stopped")

    engine.send(.pedalTap) // start intro
    engine.beginRender()
    engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
    var startBytes: [UInt8] = []
    engine.forEachClockEvent { _, b0, _, _, len in
        if len == 3 { startBytes.append(0xF2) } else { startBytes.append(b0) }
    }
    check(startBytes.contains(0xF2) && startBytes.contains(0xFA), "Start + Song Position when playback begins")

    // One second at 120 BPM → 48 clock ticks (24 PPQN × 2 beats). A 512-frame
    // buffer at 48 kHz is shorter than one tick (1000 samples), so ticks appear
    // once we accumulate enough audio.
    var ticks = 0
    let oneSec = Int(sr)
    var left = oneSec
    while left > 0 {
        let n = min(frames, left)
        engine.beginRender()
        engine.render(frames: n, left: L, right: R, hostTempo: nil, hostPlaying: nil)
        engine.forEachClockEvent { _, b0, _, _, _ in if b0 == 0xF8 { ticks += 1 } }
        left -= n
    }
    check((46...50).contains(ticks), "≈48 clock ticks per second at 120 BPM (got \(ticks))")
    check(ticks > 0, "clock ticks while playing")

    engine.send(.pauseResume)
    engine.beginRender()
    engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
    var pauseBytes: [UInt8] = []
    engine.forEachClockEvent { _, b0, _, _, _ in pauseBytes.append(b0) }
    check(pauseBytes == [0xFC] || pauseBytes.first == 0xFC, "Stop on pause")

    engine.send(.pauseResume) // resume
    engine.beginRender()
    engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
    var cont: [UInt8] = []
    engine.forEachClockEvent { _, b0, _, _, _ in cont.append(b0) }
    check(cont.contains(0xFB), "Continue on resume")

    engine.send(.stop)
    engine.beginRender()
    engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
    var stopBytes: [UInt8] = []
    engine.forEachClockEvent { _, b0, _, _, _ in stopBytes.append(b0) }
    check(stopBytes.contains(0xFC), "Stop when playback ends")

    engine.setParameter(.midiClockOut, 0)
    engine.send(.pedalTap)
    engine.beginRender()
    engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
    var off: [UInt8] = []
    engine.forEachClockEvent { _, b0, _, _, _ in off.append(b0) }
    check(off.isEmpty, "no clock when MIDI Clock Out is off")
    engine.send(.stop)
    print("MIDI Clock Out: Start/Stop/Continue and 24 PPQN checked")
}

// 8. Bass track: plays with its part, keeps going under fills, follows transitions and the
//    ending, mutes, sends MIDI, imports from MIDI files.
do {
    engine.setParameter(.volume, 0.8)
    engine.setParameter(.bassVolume, 0.8)
    engine.setParameter(.bassMute, 0)
    engine.setParameter(.hostSync, 0)
    func line(_ notes: [UInt8], length: Int = 1920) -> BassPattern {
        BassPattern(events: notes.enumerated().map {
            BassEvent(tick: Int32($0.offset * 480), note: $0.element, velocity: 100, durationTicks: 400)
        }, length: length)
    }
    func drums(_ hits: [(Int, Drum)], length: Int = 1920) -> PatternData {
        PatternData(events: hits.map { SeqEvent(tick: Int32($0.0), drum: UInt8($0.1.rawValue), velocity: 100) }, length: length)
    }
    let groove = drums([(0, .kick), (480, .snare), (960, .kick), (1440, .snare)])
    let fillBar = drums((0..<8).map { ($0 * 240, Drum.snare) })
    func testSong(_ name: String, _ parts: [PartData], transition: PatternData? = nil, outro: PatternData? = nil) -> SongData {
        SongData(name: name, genre: "Bass Test", tempo: 120, timeSignature: "4/4", barTicks: 1920, beatTicks: 480,
                 intro: nil, parts: parts, transition: transition, outro: outro)
    }
    typealias BassNote = (t: Double, note: UInt8, vel: UInt8)
    struct Run { var rms: Float; var peak: Float; var bass: [BassNote]; var states: [(t: Double, state: PlayState, voices: Int, peak: Float)] }
    /// Starts store song `song` at 120 BPM (one bar = 2 s) and plays the script; bass MIDI out in seconds.
    func run(_ song: Int, seconds: Double, script: [(Double, PedalCommand)] = [],
             params: [(Double, ParamAddress, Float)] = []) -> Run {
        engine.send(.stop)
        engine.setParameter(.song, Float(song))
        engine.setParameter(.tempo, 120)
        engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
        engine.synth.reset(); engine.bass.reset()
        var pending = [(0.0, PedalCommand.start)] + script
        var pendingParams = params
        var r = Run(rms: 0, peak: 0, bass: [], states: [])
        var sum = 0.0
        let total = Int(seconds * sr / Double(frames))
        for b in 0..<total {
            let t = Double(b * frames) / sr
            while let first = pending.first, first.0 <= t { engine.send(first.1); pending.removeFirst() }
            while let first = pendingParams.first, first.0 <= t { engine.setParameter(first.1, first.2); pendingParams.removeFirst() }
            engine.beginRender()
            engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
            engine.forEachBassOutputEvent { off, note, vel in r.bass.append((t + Double(off) / sr, note, vel)) }
            var peak: Float = 0
            for i in 0..<frames { sum += Double(L[i] * L[i] + R[i] * R[i]); peak = max(peak, abs(L[i]), abs(R[i])) }
            r.peak = max(r.peak, peak)
            r.states.append((t, engine.status.state, engine.bass.activeVoices, peak))
        }
        r.rms = Float((sum / Double(max(total * frames * 2, 1))).squareRoot())
        return r
    }
    func notes(_ r: Run, from a: Double, to b: Double) -> [UInt8] {
        r.bass.filter { $0.vel > 0 && $0.t >= a - 0.005 && $0.t < b - 0.005 }.map(\.note)
    }
    func state(_ r: Run, at t: Double) -> PlayState { r.states.last { $0.t <= t }?.state ?? .stopped }
    /// Loudest output buffer starting in `a..<b` seconds.
    func level(_ r: Run, from a: Double, to b: Double) -> Float { r.states.filter { $0.t >= a && $0.t < b }.map(\.peak).max() ?? 0 }
    /// Every note-on is followed by its note-off, and nothing is left hanging.
    func balanced(_ r: Run) -> Bool {
        var held: [UInt8: Int] = [:]
        for e in r.bass {
            held[e.note, default: 0] += e.vel > 0 ? 1 : -1
            if held[e.note]! < 0 || held[e.note]! > 1 { return false }
        }
        return held.values.allSatisfy { $0 == 0 }
    }

    // Level and mute: a song with only a bass line.
    let bassOnly = try store.add(testSong("Bass Only", [PartData(main: PatternData(events: [], length: 1920), fill: nil, bass: line([28, 31, 33, 35]))]))
    let on = run(bassOnly, seconds: 2)
    check(on.rms > 0.02 && on.peak < 1 && notes(on, from: 0, to: 2) == [28, 31, 33, 35] && balanced(on),
          "bass is heard (rms \(on.rms), notes \(notes(on, from: 0, to: 2)))")
    engine.setParameter(.bassMute, 1)
    let muted = run(bassOnly, seconds: 2)
    check(muted.rms < on.rms * 0.01, "mute silences the bass (\(muted.rms) vs \(on.rms))")
    check(notes(muted, from: 0, to: 2) == [28, 31, 33, 35], "muted bass still sends MIDI")
    engine.setParameter(.bassMute, 0)
    engine.setParameter(.bassVolume, 0.4)
    let half = run(bassOnly, seconds: 2)
    check(abs(half.rms / on.rms - 0.5) < 0.08, "bass volume scales the level (\(half.rms / on.rms))")
    engine.setParameter(.bassVolume, 9)
    check(engine.parameter(.bassVolume) == 1.5, "bass volume clamps to 1.5")
    engine.setParameter(.bassVolume, 0.8)

    // Fills: drums play the fill, the bass carries on with bar 2 of its two-bar line.
    let twoBars = line([28, 31, 33, 35, 36, 38, 40, 42], length: 3840)
    let fillSong = try store.add(testSong("Fill Bass", [PartData(main: groove, fill: fillBar, bass: twoBars)]))
    let f = run(fillSong, seconds: 6.2, script: [(1.75, .fill), (5.95, .stop)])
    check(state(f, at: 3) == .fill && state(f, at: 4.5) == .main, "fill on bar 2")
    check(notes(f, from: 0, to: 2) == [28, 31, 33, 35], "bass bar 1: \(notes(f, from: 0, to: 2))")
    check(notes(f, from: 2, to: 4) == [36, 38, 40, 42], "bass keeps going under the fill: \(notes(f, from: 2, to: 4))")
    check(notes(f, from: 4, to: 6) == [28, 31, 33, 35], "bass bar 1 again after the fill: \(notes(f, from: 4, to: 6))")
    check(f.states.contains { $0.state == .fill && $0.voices > 0 } && balanced(f), "bass synth sounds during the fill")

    // A half-bar fill started inside the bar skips the rest of the bar; so does the bass.
    let halfFill = drums((0..<4).map { ($0 * 240, Drum.snare) }, length: 960)
    let shortSong = try store.add(testSong("Short Fill Bass", [PartData(main: groove, fill: halfFill, bass: twoBars)]))
    let sf = run(shortSong, seconds: 5.2, script: [(2.25, .fill)])
    check(notes(sf, from: 2, to: 3) == [36, 38] && notes(sf, from: 3, to: 5) == [28, 31, 33, 35],
          "bass follows a short fill: \(notes(sf, from: 2, to: 3)) then \(notes(sf, from: 3, to: 5))")

    // Transition with its own bass, ending without: the part's bass keeps going, then stops with the song.
    var sectionSong = testSong("Section Bass", [PartData(main: groove, fill: fillBar, bass: line([28, 28, 28, 28])),
                                                PartData(main: groove, fill: fillBar, bass: line([33, 33, 33, 33]))],
                               transition: fillBar, outro: drums([(0, .crash), (0, .kick)]))
    sectionSong.transitionBass = line([38, 38, 38, 38])
    let tr = run(try store.add(sectionSong), seconds: 9, script: [(1.75, .transition), (5.75, .outro)])
    check(Set(notes(tr, from: 0, to: 2)) == [28], "part 1 bass")
    check(Set(notes(tr, from: 2, to: 4)) == [38] && state(tr, at: 3) == .transition, "transition plays its own bass: \(notes(tr, from: 2, to: 4))")
    check(Set(notes(tr, from: 4, to: 6)) == [33], "part 2 bass: \(notes(tr, from: 4, to: 6))")
    check(Set(notes(tr, from: 6, to: 8)) == [33] && state(tr, at: 7) == .outro, "ending keeps the part's bass: \(notes(tr, from: 6, to: 8))")
    check(notes(tr, from: 8, to: 9).isEmpty && state(tr, at: 8.5) == .stopped && balanced(tr), "bass ends with the song")

    // Pause and stop end the notes (MIDI note-offs, synth released); resume picks the line up again.
    let pr = run(fillSong, seconds: 4, script: [(0.6, .pauseResume), (1.2, .pauseResume), (2.6, .stop)])
    check(notes(pr, from: 0.62, to: 1.2).isEmpty && state(pr, at: 0.9) == .paused, "no bass while paused")
    check(pr.states.first { $0.t >= 0.85 }?.voices == 0, "pause releases the bass synth")
    check(!notes(pr, from: 1.2, to: 2.6).isEmpty && notes(pr, from: 2.65, to: 4).isEmpty && balanced(pr), "resume and stop: \(pr.bass.count) events")

    // Bass turned off for a song, and songs without a bass pattern: no bass at all.
    var offSong = testSong("Bass Off", [PartData(main: groove, fill: fillBar, bass: twoBars)])
    offSong.bassEnabled = false
    let off = run(try store.add(offSong), seconds: 3)
    check(off.bass.isEmpty && off.states.allSatisfy { $0.voices == 0 }, "bass turned off for the song")
    let bare = try store.add(testSong("No Bass Pattern", [PartData(main: groove, fill: fillBar)]))
    let bareRun = run(bare, seconds: 3)
    check(bareRun.bass.isEmpty && bareRun.states.allSatisfy { $0.voices == 0 } && bareRun.peak > 0.05,
          "song without a bass pattern unchanged")

    // Bass switched off (Bass toggle, AU parameter "Bass"): drums only. No bass audio, synth voices
    // or MIDI in any section, and Bass Follow can't be turned on.
    engine.setParameter(.bassOn, 0)
    check(engine.parameter(.bassOn) == 0, "bass switch reads back off")
    let silent = run(bassOnly, seconds: 2)
    check(silent.rms < on.rms * 0.01 && silent.bass.isEmpty && silent.states.allSatisfy { $0.voices == 0 },
          "bass off silences the bass (\(silent.rms) vs \(on.rms), \(silent.bass.count) MIDI events)")
    let drumRef = run(bare, seconds: 6.2, script: [(1.75, .fill), (5.95, .stop)])
    let drumsOnly = run(fillSong, seconds: 6.2, script: [(1.75, .fill), (5.95, .stop)])
    check(drumsOnly.bass.isEmpty && drumsOnly.states.allSatisfy { $0.voices == 0 } && state(drumsOnly, at: 3) == .fill,
          "bass off: no bass under the groove or the fill (\(drumsOnly.bass.count) MIDI events)")
    check(drumsOnly.peak > 0.05 && abs(drumsOnly.rms / drumRef.rms - 1) < 0.05,
          "bass off: the drums play as in a song without bass (rms \(drumsOnly.rms) vs \(drumRef.rms))")
    engine.setParameter(.bassFollow, 1)
    check(engine.parameter(.bassFollow) == 0, "Bass Follow stays off while the bass is off")
    // Switched off mid-note: the note gets its MIDI note-off and the synth goes silent in the next
    // buffer. Switched back on, the part's line comes back in time.
    engine.setParameter(.bassOn, 1)
    let sw = run(bassOnly, seconds: 4, params: [(1.1, .bassOn, 0), (2.6, .bassOn, 1)])
    check(notes(sw, from: 0, to: 1.1) == [28, 31, 33] && notes(sw, from: 1.1, to: 2.6).isEmpty
          && sw.bass.contains { $0.note == 33 && $0.vel == 0 && $0.t >= 1.1 && $0.t < 1.12 },
          "switching off ends the held note: \(sw.bass.filter { $0.t >= 1 && $0.t < 2.6 })")
    check(level(sw, from: 1.1, to: 2.6) < 0.001 && sw.states.filter { $0.t >= 1.4 && $0.t < 2.6 }.allSatisfy { $0.voices == 0 },
          "switching off silences the bass at once (peak \(level(sw, from: 1.1, to: 2.6)))")
    check(notes(sw, from: 2.6, to: 4) == [33, 35] && level(sw, from: 3, to: 4) > 0.05 && balanced(sw),
          "switching back on brings the bass back: \(notes(sw, from: 2.6, to: 4))")
    var drumRMS: Float = 0
    if let rock = library.songs.first(where: { $0.name.hasPrefix("Rock 1 ") }) {
        let nb = run(rock.id, seconds: 6, script: [(1.75, .fill), (4.0, .outro)])
        check(rock.hasBass && !nb.bass.isEmpty && balanced(nb) && nb.peak > 0.05, "Rock 1 has generated bass")
        drumRMS = nb.rms
    }

    // Factory songs: every part has a bass line; "Bass & Drums" keep their hand-written ones.
    let bassFactory = library.songs.filter { !$0.isUser && $0.genre == FactoryLibrary.bassGenre }
    check(bassFactory.count == 3 && bassFactory.allSatisfy(\.hasBass), "Bass & Drums songs \(bassFactory.map(\.name))")
    let factory = library.songs.filter { !$0.isUser }
    check(factory.allSatisfy(\.hasBass), "every factory song has bass (\(factory.filter { !$0.hasBass }.map(\.name)))")
    for s in factory {
        let rec = store.songs[s.id]
        let lines = (0..<Int(rec.partCount)).compactMap { store.bassPattern(store.bass(song: s.id, part: $0)) }
        check(!lines.isEmpty && lines.allSatisfy { $0.length % Int(rec.barTicks) == 0 && !$0.events.isEmpty },
              "\(s.name): part bass lines")
    }
    // Hand-written lines still look like the DSL (E1 roots), not a one-note kick lock.
    if let hand = bassFactory.first {
        let notes = store.bassPattern(store.bass(song: hand.id, part: 0))?.events.map(\.note) ?? []
        check(Set(notes).count >= 3, "Bass & Drums keep hand-written lines: \(notes)")
    }

    // Generator: kick-locked rock line, walking jazz beats, no-op when bass already set.
    let genKick = PatternData(events: [
        SeqEvent(tick: 0, drum: UInt8(Drum.kick.rawValue), velocity: 120),
        SeqEvent(tick: 960, drum: UInt8(Drum.kick.rawValue), velocity: 100),
        SeqEvent(tick: 1440, drum: UInt8(Drum.kick.rawValue), velocity: 90),
    ], length: 1920)
    let genRock = BassGenerator.pattern(for: genKick, barTicks: 1920, beatTicks: 480, style: .rock, role: .verse)
    check(genRock.events.map(\.tick) == [0, 960, 1440] && genRock.events.first?.note == BassGenerator.defaultRoot,
          "generator locks to kicks: \(genRock.events)")
    let genWalk = BassGenerator.pattern(for: genKick, barTicks: 1920, beatTicks: 480, style: .walking, role: .verse)
    check(genWalk.events.count == 4 && genWalk.events.map(\.tick) == [0, 480, 960, 1440],
          "walking lays one note per beat: \(genWalk.events.map(\.tick))")
    var already = testSong("Already Bass", [PartData(main: groove, fill: nil, bass: line([40, 40, 40, 40]))])
    let before = already.parts[0].bass
    BassGenerator.apply(to: &already, seed: 1)
    check(already.parts[0].bass == before, "generator leaves existing bass alone")

    // MIDI files: drums on channel 10 plus a bass part, bass-only files, what is not bass.
    func smfEvents(_ msgs: [(Int, [UInt8])], name: String? = nil, ppq: Int = 96) -> Data {
        var trk: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]   // 120 BPM
        if let name { trk += [0x00, 0xFF, 0x03, UInt8(name.utf8.count)] + Array(name.utf8) }
        func vlq(_ v: Int) -> [UInt8] {
            var v = v; var out = [UInt8(v & 0x7F)]; v >>= 7
            while v > 0 { out.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            return out
        }
        var last = 0
        for (t, bytes) in msgs.enumerated().sorted(by: { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }).map(\.element) {
            trk += vlq(t - last) + bytes; last = t
        }
        trk += vlq(max(ppq * 4 - last, 0)) + [0xFF, 0x2F, 0x00]
        var d = Data("MThd".utf8); d.append(contentsOf: [0, 0, 0, 6, 0, 0, 0, 1, UInt8(ppq >> 8), UInt8(ppq & 0xFF)])
        d.append(Data("MTrk".utf8))
        d.append(contentsOf: [UInt8(trk.count >> 24 & 0xFF), UInt8(trk.count >> 16 & 0xFF), UInt8(trk.count >> 8 & 0xFF), UInt8(trk.count & 0xFF)])
        d.append(contentsOf: trk)
        return d
    }
    let drumMsgs: [(Int, [UInt8])] = [(0, 36), (96, 38), (192, 36), (288, 38)].flatMap { [($0.0, [0x99, $0.1, 100]), ($0.0 + 10, [0x89, $0.1, 0])] }
    func bassMsgs(_ notes: [UInt8], channel: UInt8 = 1, program: Bool = true, dur: Int = 90) -> [(Int, [UInt8])] {
        (program ? [(0, [0xC0 | channel, 33])] : [])
            + notes.enumerated().flatMap { [($0.offset * 96, [0x90 | channel, $0.element, 100]), ($0.offset * 96 + dur, [0x80 | channel, $0.element, 0])] }
    }
    let both = try MIDIDrumFile(data: smfEvents(drumMsgs + bassMsgs([28, 31, 33, 35])), name: "Groove.mid")
    check(both.events.count == 4 && both.bass?.events.map(\.note) == [28, 31, 33, 35]
          && both.bass?.events.map(\.durationTicks) == [450, 450, 450, 450] && both.bass?.events.map(\.tick) == [0, 480, 960, 1440]
          && both.bass?.length == both.lengthTicks, "drums + bass in one file: \(String(describing: both.bass))")
    let lowPart = try MIDIDrumFile(data: smfEvents(drumMsgs + bassMsgs([28, 31], channel: 2, program: false)), name: "Groove.mid")
    check(lowPart.events.count == 4 && lowPart.bass?.events.count == 2, "unlabeled low part next to the drums is the bass")
    let named = try MIDIDrumFile(data: smfEvents(drumMsgs + bassMsgs([48, 52], channel: 3, program: false), name: "Fretless Bass"), name: "Groove.mid")
    check(named.events.count == 4 && named.bass?.events.count == 2, "track named bass")
    let keys = try MIDIDrumFile(data: smfEvents(drumMsgs + bassMsgs([72, 76], channel: 0, program: false)), name: "Groove.mid")
    check(keys.events.count == 4 && keys.bass == nil, "a high melodic part is not bass")
    let kick = try MIDIDrumFile(data: smfEvents(drumMsgs), name: "Bass Drum Groove.mid")
    check(kick.bass == nil && MIDISongImporter.role(for: kick) == .main, "\"Bass Drum\" is drums")
    let verseBassData = smfEvents(bassMsgs([28, 31, 33, 35], channel: 0, program: false))
    let verseBass = try MIDIDrumFile(data: verseBassData, name: "Verse Bass.mid")
    check(verseBass.events.isEmpty && verseBass.bass?.events.count == 4 && MIDISongImporter.role(for: verseBass) == .bass,
          "bass-only file")

    // Writer: drums + bass on channel 2 read back exactly (swing included), and a bass-only file.
    if let funk = library.songs.first(where: { $0.name.hasPrefix("Funk 1 ") }) {
        let pr0 = store.patterns[Int(store.partMain[funk.id * SongStore.maxParts])]
        let p0 = PatternData(events: (0..<Int(pr0.count)).map { store.events[Int(pr0.start) + $0] }, length: Int(pr0.length))
        let bl = BassLine.pattern("E1 . E1 . G1 . A1 . E1 . e1 . D2 . B1 .")
        let back = try MIDIDrumFile(data: MIDIWriter.drumFile(p0, tempo: 116, signature: "4/4", bass: bl), name: "Groove A.mid")
        func key(_ e: SeqEvent) -> [Int] { [Int(e.tick), Int(e.drum), Int(e.velocity), Int(e.swingUnit)] }
        check(back.events.map(key).sorted { $0.lexicographicallyPrecedes($1) } == p0.events.map(key).sorted { $0.lexicographicallyPrecedes($1) }
              && p0.events.contains { $0.swingUnit != 0 } && back.bass == bl, "drums + bass written and read back")
        let alone = try MIDIDrumFile(data: MIDIWriter.drumFile(PatternData(events: [], length: 3840), tempo: 120, signature: "4/4", bass: twoBars),
                                     name: "Groove A Bass.mid")
        check(alone.events.isEmpty && alone.bass == twoBars && alone.lengthTicks == 3840, "bass-only file written and read back")
    }

    // Import as one song: a bass file goes with the groove it's named after, a file's own bass
    // plays with that groove, "Ending Bass" plays under the ending.
    let verse = smf([(0, 36), (96, 38), (192, 36), (288, 38)])
    let added = try library.importMIDI([.init(name: "Verse.mid", data: verse), .init(name: "Verse Bass.mid", data: verseBassData),
                                        .init(name: "Chorus.mid", data: smfEvents(drumMsgs + bassMsgs([33, 36, 38, 40]))),
                                        .init(name: "Ending Bass.mid", data: smfEvents(bassMsgs([28], channel: 0, dur: 380)))], asOneSong: true)
    if let s = added.first, let lay = library.importRecord(forKey: s.key)?.layout {
        let rec = store.songs[s.id]
        check(s.hasBass && lay.parts.map(\.main) == ["Verse.mid", "Chorus.mid"] && lay.parts.map(\.bass) == ["Verse Bass.mid", nil]
              && lay.outroBass == "Ending Bass.mid", "bass layout \(lay)")
        check(store.bassPattern(store.bass(song: s.id, part: 0))?.events.map(\.note) == [28, 31, 33, 35]
              && store.bassPattern(store.bass(song: s.id, part: 1))?.events.map(\.note) == [33, 36, 38, 40]
              && store.bassPattern(rec.outroBass)?.events.map(\.note) == [28] && rec.introBass < 0, "imported bass lines")
        let info = library.fileInfo(forKey: s.key)
        check(info.first { $0.name == "Verse Bass.mid" }?.role == "Bass" && info.first { $0.name == "Chorus.mid" }.map { $0.role == "Groove" && $0.hasBass } == true,
              "file info \(info.map { "\($0.name):\($0.role)" })")
        let ir = run(s.id, seconds: 8, script: [(3.75, .fill), (5.75, .outro)])
        check(Set(ir.bass.filter { $0.vel > 0 }.map(\.note)).isSuperset(of: [28, 31]) && balanced(ir) && ir.peak > 0.05, "imported song plays its bass")

        // Auditioning a file plays its bass line along (a bass-only file over silent drums); stopping ends it.
        func audition(_ file: String) -> (ons: [UInt8], ended: Bool, voices: Int, peak: Float)? {
            guard let gp = library.previewPattern(forKey: s.key, file: file),
                  let bp = library.previewBassPattern(forKey: s.key, file: file) else { return nil }
            engine.send(.stop)
            engine.preview(pattern: gp, loop: true, bass: bp)
            var pv: [(UInt8, UInt8)] = []
            var voices = 0
            var peak: Float = 0
            let total = Int(3.0 * sr / Double(frames))
            let stopAt = Int(2.0 * sr / Double(frames))
            for i in 0..<total {
                if i == stopAt { engine.stopPreview() }
                engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
                engine.forEachBassOutputEvent { _, n, v in pv.append((n, v)) }
                voices = max(voices, engine.bass.activeVoices)
                for k in 0..<frames { peak = max(peak, abs(L[k]), abs(R[k])) }
            }
            let ons = pv.filter { $0.1 > 0 }.map(\.0)
            return (ons, pv.filter { $0.1 == 0 }.count == ons.count && !engine.status.previewing, voices, peak)
        }
        check(library.previewBassPattern(forKey: s.key, file: "Chorus.mid") == library.previewBassPattern(forKey: s.key, file: "Chorus.mid")
              && library.previewBassPattern(forKey: s.key, file: "Verse.mid") == nil, "bass preview cached, none for a drums-only file")
        let chorus = audition("Chorus.mid"), verseLine = audition("Verse Bass.mid")
        check(chorus.map { $0.ons.starts(with: [33, 36, 38, 40]) && $0.ended } == true, "preview with bass: \(String(describing: chorus))")
        check(verseLine.map { $0.ons.starts(with: [28, 31, 33, 35]) && $0.ended } == true, "bass file preview: \(String(describing: verseLine))")
        // With the bass off, an audition plays its drums only: no bass MIDI and no synth voices.
        engine.setParameter(.bassOn, 0)
        let chorusOff = audition("Chorus.mid")
        engine.setParameter(.bassOn, 1)
        check(chorusOff.map { $0.ons.isEmpty && $0.voices == 0 && $0.peak > 0.05 && $0.ended } == true,
              "bass off: preview without bass: \(String(describing: chorusOff))")
    } else { check(false, "bass import") }

    // Folder import: "Groove 1 Bass.mid" joins the "Groove 1" song.
    let plan = MIDIFolderImport.plan([.init(path: ["Bass Pack", "Funk", "Groove 1.mid"], data: verse),
                                      .init(path: ["Bass Pack", "Funk", "Groove 1 Bass.mid"], data: verseBassData)])
    let planFiles = plan.groups.first?.files.compactMap { try? MIDIDrumFile(data: $0.data, name: $0.name) } ?? []
    check(plan.groups.count == 1 && plan.skipped.isEmpty
          && MIDISongImporter.layout(for: planFiles)?.parts.map(\.bass) == ["Groove 1 Bass.mid"], "folder import with a bass file")
    // Mix Song bass bus: multi-out carries the bass when the track is playing.
    engine.setParameter(.bassMute, 0)
    engine.setParameter(.bassVolume, 0.8)
    engine.setParameter(.song, Float(bassOnly))
    engine.send(.stop)
    engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
    engine.synth.reset(); engine.bass.reset()
    engine.send(.start)
    var busPeak: Float = 0
    let busL = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    let busR = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer { busL.deallocate(); busR.deallocate() }
    for b in 0..<Int(1.5 * sr / Double(frames)) {
        engine.beginRender()
        engine.renderBus(MixBus.bass.rawValue, frames: frames, left: busL, right: busR,
                         sampleTime: Float64(b * frames), hostTempo: nil, hostPlaying: nil)
        for i in 0..<frames { busPeak = max(busPeak, abs(busL[i]), abs(busR[i])) }
    }
    check(busPeak > 0.02, "bass MixBus has signal (peak \(busPeak))")
    check(engine.bassChannelLevel() > 0, "bass mixer meter lit")
    // Switched off mid-note, the bass multi-out goes silent too.
    engine.setParameter(.bassOn, 0)
    let busStart = Int(1.5 * sr / Double(frames))
    busPeak = 0
    for b in busStart..<busStart + Int(sr / Double(frames)) {
        engine.beginRender()
        engine.renderBus(MixBus.bass.rawValue, frames: frames, left: busL, right: busR,
                         sampleTime: Float64(b * frames), hostTempo: nil, hostPlaying: nil)
        for i in 0..<frames { busPeak = max(busPeak, abs(busL[i]), abs(busR[i])) }
    }
    check(busPeak < 1e-6, "bass off: bass MixBus silent (peak \(busPeak))")
    engine.setParameter(.bassOn, 1)
    engine.send(.stop)
    print(String(format: "Bass: %.1f dB rms (drum groove %.1f dB); mute, bass switch, fills, transitions, MIDI out, MixBus and import checked",
                 20 * log10(max(on.rms, 1e-9)), 20 * log10(max(drumRMS, 1e-9))))
} catch { check(false, "bass tests threw \(error)") }

// 9. Bass Follow (MIDI): chord detect + beat-quantized transpose of the written bass root.
do {
    // A major (A C# E) and Em templates.
    var pc = [Int](repeating: 0, count: 12)
    pc[9] = 1; pc[1] = 1; pc[4] = 1
    let aMaj = ChordFollower.detect(pcCount: pc)
    check(aMaj?.root == 9 && aMaj?.minor == false, "detect A major → \(String(describing: aMaj))")
    pc = [Int](repeating: 0, count: 12)
    pc[4] = 1; pc[7] = 1; pc[11] = 1
    let eMin = ChordFollower.detect(pcCount: pc)
    check(eMin?.root == 4 && eMin?.minor == true, "detect Em → \(String(describing: eMin))")
    check(ChordFollower.transpose(28, by: 5) == 33, "E1 + 5 semitones = A1")
    // Nearest transpose: E→D is −2 (not +10); floor keeps written E1 from going below E1.
    let near = ChordFollower()
    near.enabled = true
    near.songRoot = 4 // E
    near.setLiveChord(LiveChord(root: 2, minor: false, confidence: 0.9)) // D
    near.applyQuantized(force: true)
    check(near.transpose == -2, "nearest E→D = −2, got \(near.transpose)")
    // Written E1 + (−2) would be D1; bump an octave so the note stays playable (≥ E1).
    check(ChordFollower.transpose(28, by: -2) == 38, "E1 + (−2) → D2 (register floor)")
    check(ChordFollower.transpose(40, by: -2) == 38, "E2 + (−2) = D2")
    near.setLiveChord(LiveChord(root: 0, minor: false, confidence: 0.9)) // C
    for _ in 0..<8 { near.setLiveChord(LiveChord(root: 0, minor: false, confidence: 0.9)) }
    near.applyQuantized(beatInBar: 0, beatsPerBar: 4)
    check(near.transpose == -4 || near.transpose == 8, "E→C nearest −4, got \(near.transpose)")
    // Prefer −4; if grid blocked, force:
    near.applyQuantized(force: true)
    check(near.transpose == -4, "nearest E→C = −4, got \(near.transpose)")

    engine.setParameter(.bassFollow, 0)
    engine.setParameter(.bassMute, 0)
    engine.setParameter(.bassVolume, 0.8)
    engine.setParameter(.hostSync, 0)
    let eLine = BassPattern(events: [
        BassEvent(tick: 0, note: 28, velocity: 100, durationTicks: 400),
        BassEvent(tick: 480, note: 28, velocity: 100, durationTicks: 400),
        BassEvent(tick: 960, note: 28, velocity: 100, durationTicks: 400),
        BassEvent(tick: 1440, note: 28, velocity: 100, durationTicks: 400),
    ], length: 1920)
    let groove = PatternData(events: [
        SeqEvent(tick: 0, drum: UInt8(Drum.kick.rawValue), velocity: 100),
        SeqEvent(tick: 960, drum: UInt8(Drum.snare.rawValue), velocity: 100),
    ], length: 1920)
    var followSong = SongData(name: "Follow Test", genre: "Bass Test", tempo: 120, timeSignature: "4/4",
                              barTicks: 1920, beatTicks: 480, intro: nil,
                              parts: [PartData(main: groove, fill: nil, bass: eLine)],
                              transition: nil, outro: nil, bassRootPitchClass: 4)
    followSong.bassEnabled = true
    let fid = try store.add(followSong)
    check(store.songs[fid].bassRoot == 4, "song bassRoot E")

    // Off: bass stays on E1 (28).
    engine.setParameter(.bassFollow, 0)
    engine.setParameter(.song, Float(fid))
    engine.setParameter(.tempo, 120)
    engine.send(.stop)
    engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
    engine.synth.reset(); engine.bass.reset()
    engine.send(.start)
    var offNotes: [UInt8] = []
    for _ in 0..<Int(2.1 * sr / Double(frames)) {
        engine.beginRender()
        engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
        engine.forEachBassOutputEvent { _, n, v in if v > 0 { offNotes.append(n) } }
    }
    check(!offNotes.isEmpty && offNotes.allSatisfy { $0 == 28 }, "follow off keeps E1: \(offNotes.prefix(8))")

    // On: hold A major on ch 1 before start; first notes still E until… start applies pending.
    engine.send(.stop)
    engine.setParameter(.bassFollow, 1)
    check(engine.status.bassFollow, "status bassFollow on")
    // A3=57, C#4=61, E4=64 on channel 1
    engine.handleMIDI(0x90, 57, 100, offset: 0)
    engine.handleMIDI(0x90, 61, 100, offset: 0)
    engine.handleMIDI(0x90, 64, 100, offset: 0)
    engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
    engine.synth.reset(); engine.bass.reset()
    engine.send(.start)
    var onNotes: [UInt8] = []
    for _ in 0..<Int(2.1 * sr / Double(frames)) {
        engine.beginRender()
        engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
        engine.forEachBassOutputEvent { _, n, v in if v > 0 { onNotes.append(n) } }
    }
    check(!onNotes.isEmpty && onNotes.allSatisfy { $0 == 33 }, "follow A → A1 (33): \(onNotes.prefix(8))")
    check(engine.status.followChord == "A" || engine.status.followChord.hasPrefix("A"),
          "followChord display \(engine.status.followChord)")

    // Mid-play change: G major → next beat bass moves to G1 (31). Channel 10 must not steal follow.
    engine.handleMIDI(0x99, 38, 100, offset: 0) // snare on ch 10 — drums, not chord
    engine.handleMIDI(0x80, 57, 0, offset: 0)
    engine.handleMIDI(0x80, 61, 0, offset: 0)
    engine.handleMIDI(0x80, 64, 0, offset: 0)
    engine.handleMIDI(0x90, 55, 100, offset: 0) // G
    engine.handleMIDI(0x90, 59, 100, offset: 0) // B
    engine.handleMIDI(0x90, 62, 100, offset: 0) // D
    check(engine.bassFollow.follower.pendingChord?.root == 7, "pending G after MIDI \(String(describing: engine.bassFollow.follower.pendingChord))")
    var gNotes: [UInt8] = []
    for _ in 0..<Int(3.0 * sr / Double(frames)) {
        engine.beginRender()
        engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
        engine.forEachBassOutputEvent { _, n, v in if v > 0 { gNotes.append(n) } }
    }
    check(gNotes.contains(31), "after G chord, bass hits G1: \(gNotes) chord=\(engine.status.followChord)")
    check(engine.status.followChord == "G", "applied chord G, got \(engine.status.followChord)")

    // Commit grid: weak beats must not apply a pending change (anti mid-bar flicker).
    let gridFollower = ChordFollower()
    gridFollower.enabled = true
    gridFollower.commitGrid = .strongBeats
    gridFollower.setLiveChord(LiveChord(root: 0, minor: false, confidence: 0.9)) // C
    gridFollower.applyQuantized(beatInBar: 0, beatsPerBar: 4, force: true)
    check(gridFollower.appliedChord?.root == 0, "force commit C on start")
    gridFollower.setLiveChord(LiveChord(root: 7, minor: false, confidence: 0.9)) // G pending
    // Dual timescale: one observation is not enough to replace pending after first lock.
    // Drive slow confirm explicitly via repeated observations.
    for _ in 0..<8 {
        gridFollower.setLiveChord(LiveChord(root: 7, minor: false, confidence: 0.9))
    }
    check(gridFollower.pendingChord?.root == 7, "slow path promotes G to pending")
    gridFollower.applyQuantized(beatInBar: 1, beatsPerBar: 4) // weak beat
    check(gridFollower.appliedChord?.root == 0, "weak beat keeps C: \(String(describing: gridFollower.appliedChord))")
    gridFollower.applyQuantized(beatInBar: 2, beatsPerBar: 4) // strong beat (3)
    check(gridFollower.appliedChord?.root == 7, "strong beat commits G: \(String(describing: gridFollower.appliedChord))")
    check(gridFollower.allowsCommit(beatInBar: 0, beatsPerBar: 4)
          && !gridFollower.allowsCommit(beatInBar: 1, beatsPerBar: 4)
          && gridFollower.allowsCommit(beatInBar: 2, beatsPerBar: 4)
          && !gridFollower.allowsCommit(beatInBar: 3, beatsPerBar: 4),
          "strong-beat grid is 1+3 only")

    engine.setParameter(.chordCommitGrid, Float(ChordCommitGrid.bar.rawValue))
    check(engine.parameter(.chordCommitGrid) == Float(ChordCommitGrid.bar.rawValue),
          "chordCommitGrid param \(engine.parameter(.chordCommitGrid))")
    check(engine.bassFollow.commitGrid == .bar, "commitGrid wired to engine")
    engine.setParameter(.chordCommitGrid, Float(ChordCommitGrid.strongBeats.rawValue))

    engine.setParameter(.bassFollow, 0)
    engine.send(.stop)
    print("Bass Follow: detect, MIDI transpose E→A, beat update to G, commit grid, nearest, ch10 ignored")
} catch { check(false, "bass follow tests threw \(error)") }

// 10. Bass kits: four distinct tones, each audible, kit param switches the synth.
do {
    check(BassKit.allCases.map(\.name) == [
        "Acoustic Upright Bass", "Electric Ballad Bass", "Acoustic Bass", "Electric Jazz Bass"
    ], "bass kit names")
    engine.setParameter(.bassMute, 0)
    engine.setParameter(.bassVolume, 1)
    engine.setParameter(.hostSync, 0)
    engine.setParameter(.tempo, 120)
    let note = BassPattern(events: [BassEvent(tick: 0, note: 28, velocity: 110, durationTicks: 1600)], length: 1920)
    let kick = PatternData(events: [SeqEvent(tick: 0, drum: UInt8(Drum.kick.rawValue), velocity: 80)], length: 1920)
    let kid = try store.add(SongData(name: "Kit Tone", genre: "Bass Test", tempo: 120, timeSignature: "4/4",
                                     barTicks: 1920, beatTicks: 480, intro: nil,
                                     parts: [PartData(main: kick, fill: nil, bass: note)],
                                     transition: nil, outro: nil))
    engine.setParameter(.song, Float(kid))
    var peaks: [BassKit: Float] = [:]
    for k in BassKit.allCases {
        engine.setParameter(.bassKit, Float(k.rawValue))
        check(engine.bass.kit == k && engine.parameter(.bassKit) == Float(k.rawValue), "kit param \(k.name)")
        engine.send(.stop)
        engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
        engine.synth.reset(); engine.bass.reset()
        engine.send(.start)
        var peak: Float = 0
        for _ in 0..<Int(1.2 * sr / Double(frames)) {
            engine.beginRender()
            engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
            for i in 0..<frames { peak = max(peak, abs(L[i]), abs(R[i])) }
        }
        peaks[k] = peak
        check(peak > 0.03, "\(k.name) audible (peak \(peak))")
        engine.send(.stop)
    }
    // Kits should not all sound identical (peak or character differs enough that at least two diverge).
    let vals = BassKit.allCases.map { peaks[$0]! }
    check(vals.max()! - vals.min()! > 0.005 || Set(vals.map { Int($0 * 1000) }).count > 1,
          "kits produce distinct levels \(peaks)")
    engine.setParameter(.bassKit, Float(BassKit.electricJazz.rawValue))
    print("Bass kits: \(BassKit.allCases.map(\.name).joined(separator: ", "))")
} catch { check(false, "bass kit tests threw \(error)") }

// 11. Audio Chord Follow: synthetic A major triad → detector → bass transpose.
do {
    let sr = 48000.0
    engine.prepare(sampleRate: sr, maxFrames: frames)
    engine.bassFollow.detector.reset()
    engine.bassFollow.detector.useTemplateClassifierOnly()
    engine.bassFollow.detector.gate = 0.001
    engine.bassFollow.detector.minConfidence = 0.35
    engine.bassFollow.detector.songRoot = 9
    engine.bassFollow.detector.preferMinorKey = false
    engine.bassFollow.detector.songRoot = 9
    // A2 + C#3 + E3 (A major), plus octave doubles for a more guitar-like spectrum.
    let freqs: [Double] = [110.0, 138.59, 164.81, 220.0, 277.18, 329.63]
    let amps: [Double] = [0.32, 0.28, 0.20, 0.22, 0.18, 0.12]
    let buf = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer { buf.deallocate() }
    var phase = [Double](repeating: 0, count: freqs.count)
    func fillTriad() {
        for i in 0..<frames {
            var s = 0.0
            for (j, f) in freqs.enumerated() {
                s += amps[j] * sin(phase[j])
                phase[j] += 2 * Double.pi * f / sr
                if phase[j] > 2 * Double.pi { phase[j] -= 2 * Double.pi }
            }
            buf[i] = Float(s)
        }
    }
    var last: LiveChord?
    // Feed ~1.5 s so hang chroma + confirmation + onset logic can lock A major.
    for _ in 0..<Int(1.5 * sr / Double(frames)) {
        fillTriad()
        if let c = engine.bassFollow.detector.process(left: UnsafePointer(buf), right: nil, frames: frames) {
            last = c
        }
    }
    check(last?.root == 9 && last?.minor == false, "audio detect A major → \(String(describing: last))")
    check(engine.bassFollow.detector.inputLevel > 0.05, "guitar level from synthetic triad")

    // Engine path: Bass Follow on + feedGuitar → pending A → start → bass on A1.
    engine.setParameter(.bassFollow, 1)
    engine.setParameter(.bassMute, 0)
    engine.setParameter(.bassVolume, 0.8)
    engine.setParameter(.hostSync, 0)
    engine.setParameter(.tempo, 120)
    let eLine = BassPattern(events: (0..<4).map {
        BassEvent(tick: Int32($0 * 480), note: 28, velocity: 100, durationTicks: 400)
    }, length: 1920)
    let groove = PatternData(events: [SeqEvent(tick: 0, drum: UInt8(Drum.kick.rawValue), velocity: 80)], length: 1920)
    let aid = try store.add(SongData(name: "Audio Follow", genre: "Bass Test", tempo: 120, timeSignature: "4/4",
                                     barTicks: 1920, beatTicks: 480, intro: nil,
                                     parts: [PartData(main: groove, fill: nil, bass: eLine)],
                                     transition: nil, outro: nil, bassRootPitchClass: 4))
    engine.setParameter(.song, Float(aid))
    engine.bassFollow.detector.reset()
    engine.bassFollow.detector.useTemplateClassifierOnly()
    engine.bassFollow.detector.gate = 0.001
    engine.bassFollow.detector.minConfidence = 0.35
    // Song bass root E → detector key E major; A major is diatonic IV.
    engine.bassFollow.detector.preferMinorKey = false
    for _ in 0..<Int(1.5 * sr / Double(frames)) {
        fillTriad()
        engine.feedGuitarInput(left: UnsafePointer(buf), right: nil, frames: frames)
    }
    check(engine.bassFollow.follower.pendingChord?.root == 9, "feedGuitar pending A \(String(describing: engine.bassFollow.follower.pendingChord))")
    engine.send(.stop)
    engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
    engine.synth.reset(); engine.bass.reset()
    engine.send(.start)
    var notes: [UInt8] = []
    for _ in 0..<Int(2.0 * sr / Double(frames)) {
        fillTriad()
        engine.feedGuitarInput(left: UnsafePointer(buf), right: nil, frames: frames)
        engine.beginRender()
        engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
        engine.forEachBassOutputEvent { _, n, v in if v > 0 { notes.append(n) } }
    }
    check(notes.contains(33), "audio follow transposes E→A: \(notes.prefix(8))")
    check(engine.status.guitarLevel > 0 || engine.guitarInputLevel() > 0, "status guitar level")
    engine.setParameter(.bassFollow, 0)
    engine.send(.stop)
    print("Audio Chord Follow: A major chroma + bass transpose checked")
} catch { check(false, "audio follow tests threw \(error)") }

// 12. Percussion layers: a song's shaker / tambourine / clap play along with its drums, follow its
//     sections, have their own switches and level, and import from "shaker_songs/<Artist>/<Title>/"
//     folders without becoming beats of their own.
do {
    engine.prepare(sampleRate: sr, maxFrames: frames)
    engine.setParameter(.volume, 0.8)
    engine.setParameter(.hostSync, 0)
    engine.setParameter(.tempo, 120)
    engine.setParameter(.percOn, 1)
    engine.setParameter(.percVolume, 1)
    for i in PercussionInstrument.allCases { engine.setParameter(i.parameter, 1) }
    check(engine.parameter(.percOn) == 1 && PercussionInstrument.allCases.allSatisfy { engine.parameter($0.parameter) == 1 },
          "percussion switches read back on")
    func hits(_ drum: Drum, _ ticks: [Int], length: Int = 1920) -> PatternData {
        PatternData(events: ticks.map { SeqEvent(tick: Int32($0), drum: UInt8(drum.rawValue), velocity: 100) }, length: length)
    }
    func every(_ step: Int, _ length: Int = 1920) -> [Int] { Array(stride(from: 0, to: length, by: step)) }
    let groove = PatternData(events: hits(.kick, [0, 960]).events + hits(.snare, [480, 1440]).events, length: 1920)
    let fillBar = hits(.snare, every(240))
    func percSong(_ name: String, intro: PatternData? = nil, parts: Int = 2) -> SongData {
        SongData(name: name, genre: "drum songs › Test Artist", tempo: 120, timeSignature: "4/4", barTicks: 1920, beatTicks: 480,
                 intro: intro, parts: Array(repeating: PartData(main: groove, fill: fillBar), count: parts),
                 transition: fillBar, outro: hits(.crash, [0]))
    }
    struct Hits { var notes: [(t: Double, note: UInt8)] = []; var states: [(t: Double, state: PlayState)] = []; var sum = 0.0; var n = 0 }
    /// Plays store song `song` at 120 BPM (one bar = 2 s); drum MIDI out (channel 10) in seconds.
    func play(_ song: Int, seconds: Double, script: [(Double, PedalCommand)] = [],
              params: [(Double, ParamAddress, Float)] = []) -> Hits {
        engine.send(.stop)
        engine.setParameter(.song, Float(song))
        engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
        engine.synth.reset(); engine.bass.reset()
        var pending = [(0.0, PedalCommand.start)] + script
        var pendingParams = params
        var h = Hits()
        for b in 0..<Int(seconds * sr / Double(frames)) {
            let t = Double(b * frames) / sr
            while let first = pending.first, first.0 <= t { engine.send(first.1); pending.removeFirst() }
            while let first = pendingParams.first, first.0 <= t { engine.setParameter(first.1, first.2); pendingParams.removeFirst() }
            engine.beginRender()
            engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
            engine.forEachOutputEvent { off, note, _ in h.notes.append((t + Double(off) / sr, note)) }
            for i in 0..<frames { h.sum += Double(L[i] * L[i] + R[i] * R[i]) }
            h.n += frames * 2
            h.states.append((t, engine.status.state))
        }
        engine.send(.stop)
        return h
    }
    func count(_ h: Hits, _ drum: Drum, from a: Double, to b: Double) -> Int {
        h.notes.filter { $0.note == drum.gmNote && $0.t >= a - 0.005 && $0.t < b - 0.005 }.count
    }
    func perc(_ h: Hits, from a: Double, to b: Double) -> [Int] {
        PercussionInstrument.allCases.map { count(h, $0.drum, from: a, to: b) }
    }
    func state(_ h: Hits, at t: Double) -> PlayState { h.states.last { $0.t <= t }?.state ?? .stopped }
    func rms(_ h: Hits) -> Double { (h.sum / Double(max(h.n, 1))).squareRoot() }

    // Shaker: 8ths in part A with a 16th fill, quarters in part B. Tambourine: 2 and 4 in its only
    // part, plus an ending of its own. No clap.
    let sid = try store.add(percSong("Perc Song"))
    let shaker = try store.addPercussion(PercussionData(instrument: .shaker, parts: [
        PercussionPart(main: hits(.shaker, every(240)), fills: [hits(.shaker, every(120))]),
        PercussionPart(main: hits(.shaker, every(480)))]))
    let tamb = try store.addPercussion(PercussionData(instrument: .tambourine, parts: [PercussionPart(main: hits(.tambourine, [480, 1440]))],
                                                      outro: hits(.tambourine, [0])))
    check(perc(play(sid, seconds: 2), from: 0, to: 2) == [0, 0, 0, 0], "no percussion before it is linked")
    store.setPercussion(shaker, song: sid, instrument: .shaker)
    store.setPercussion(tamb, song: sid, instrument: .tambourine)
    let full = play(sid, seconds: 13, script: [(1.75, .fill), (5.75, .transition), (9.75, .outro)])
    check(perc(full, from: 0, to: 2) == [8, 2, 0, 0] && count(full, .kick, from: 0, to: 2) == 2, "part A percussion: \(perc(full, from: 0, to: 2))")
    check(state(full, at: 3) == .fill && perc(full, from: 2, to: 4) == [16, 2, 0, 0],
          "fill: the shaker plays its fill, the tambourine keeps its groove: \(perc(full, from: 2, to: 4))")
    check(perc(full, from: 4, to: 6) == [8, 2, 0, 0], "back to the groove after the fill: \(perc(full, from: 4, to: 6))")
    check(state(full, at: 7) == .transition && perc(full, from: 6, to: 8) == [8, 2, 0, 0],
          "transition without its own: the grooves keep going: \(perc(full, from: 6, to: 8))")
    check(perc(full, from: 8, to: 10) == [4, 2, 0, 0], "part B: the shaker's part B, the tambourine's only part: \(perc(full, from: 8, to: 10))")
    check(state(full, at: 11) == .outro && perc(full, from: 10, to: 12) == [0, 1, 0, 0],
          "ending: only the tambourine's own ending: \(perc(full, from: 10, to: 12))")
    check(perc(full, from: 12, to: 13) == [0, 0, 0, 0] && state(full, at: 12.5) == .stopped, "percussion stops with the song")

    // Shaker pocket and feel (ShakerStack): the shaker moves against the grid, the other layers stay.
    // Part A's shaker plays 8ths (every 0.25 s at 120 BPM), the tambourine 2 and 4.
    do {
        let humanize = engine.parameter(.humanize)
        engine.setParameter(.humanize, 0)
        /// Offsets (ms) of `drum`'s hits from the nearest 8th, between `a` and `b` seconds.
        func offsets(_ h: Hits, _ drum: Drum, from a: Double, to b: Double) -> [Double] {
            h.notes.filter { $0.note == drum.gmNote && $0.t >= a && $0.t < b }
                .map { ($0.t - ($0.t / 0.25).rounded() * 0.25) * 1000 }
        }
        func near(_ xs: [Double], _ ms: Double) -> Bool { !xs.isEmpty && xs.allSatisfy { abs($0 - ms) < 1.5 } }
        let grid = play(sid, seconds: 2.2)
        check(near(offsets(grid, .shaker, from: 0.1, to: 1.9), 0), "shaker on the grid by default: \(offsets(grid, .shaker, from: 0.1, to: 1.9))")
        let ahead = play(sid, seconds: 4.2, params: [(0, .shakerPocket, -20)])
        let early = offsets(ahead, .shaker, from: 0.1, to: 3.9)
        check(near(early, -20), "pocket -20 ms: the shaker plays 20 ms early: \(early)")
        check(near(offsets(ahead, .tambourine, from: 0.1, to: 3.9), 0), "the pocket moves only the shaker")
        check(ahead.notes.contains { $0.note == Drum.shaker.gmNote && $0.t < 0.002 },
              "ahead of the grid, the first shaker hit still plays at the start")
        check(count(ahead, .shaker, from: 1.9, to: 2.1) == 1, "ahead: a bar line's hit plays once, just before it")
        let behind = play(sid, seconds: 2.2, params: [(0, .shakerPocket, 15)])
        check(near(offsets(behind, .shaker, from: 0.1, to: 1.9), 15), "pocket +15 ms: the shaker plays 15 ms late")
        engine.setParameter(.shakerPocket, 0)
        // Push: off-beat 8ths 6 % of a 16th early (7.5 ms at 120 BPM), beats stay.
        let push = play(sid, seconds: 2.2, params: [(0, .shakerFeel, Float(ShakerFeel.push.rawValue))])
        let pushed = push.notes.filter { $0.note == Drum.shaker.gmNote && $0.t > 0.1 && $0.t < 1.9 }
        let onBeat = pushed.filter { abs($0.t * 2 - ($0.t * 2).rounded()) * 500 < 20 }.map { ($0.t - ($0.t * 2).rounded() / 2) * 1000 }
        let offBeat = pushed.filter { abs($0.t * 2 - ($0.t * 2).rounded()) * 500 >= 20 }
            .map { ($0.t - ($0.t / 0.25).rounded() * 0.25) * 1000 }
        check(near(onBeat, 0) && near(offBeat, -7.5), "push: beats on the grid \(onBeat), off-beats early \(offBeat)")
        engine.setParameter(.shakerFeel, Float(ShakerFeel.grid.rawValue))
        engine.setParameter(.humanize, humanize)
        print("Shaker pocket and feel checked")
    }

    // Intro: a layer's own intro plays under it; without one it is silent until the groove.
    let introSong = try store.add(percSong("Perc Intro", intro: hits(.hatClosed, every(480)), parts: 1))
    let introShaker = try store.addPercussion(PercussionData(instrument: .shaker, intro: hits(.shaker, [0, 960]),
                                                             parts: [PercussionPart(main: hits(.shaker, every(240)))]))
    store.setPercussion(introShaker, song: introSong, instrument: .shaker)
    store.setPercussion(tamb, song: introSong, instrument: .tambourine)
    let intro = play(introSong, seconds: 4)
    check(state(intro, at: 1) == .intro && perc(intro, from: 0, to: 2) == [2, 0, 0, 0] && perc(intro, from: 2, to: 4) == [8, 2, 0, 0],
          "intro: \(perc(intro, from: 0, to: 2)) then \(perc(intro, from: 2, to: 4))")

    // Switches: percussion off = drums only; one instrument off; off and on again mid-song.
    let ref = play(sid, seconds: 4.2, script: [(1.75, .fill)])
    engine.setParameter(.percOn, 0)
    check(engine.parameter(.percOn) == 0, "percussion switch reads back off")
    let off = play(sid, seconds: 4.2, script: [(1.75, .fill)])
    check(perc(off, from: 0, to: 4.2) == [0, 0, 0, 0] && count(off, .kick, from: 0, to: 4.2) == count(ref, .kick, from: 0, to: 4.2)
          && count(off, .snare, from: 0, to: 4.2) == count(ref, .snare, from: 0, to: 4.2) && state(off, at: 3) == .fill,
          "percussion off: drums only, no percussion MIDI (\(perc(off, from: 0, to: 4.2)))")
    engine.setParameter(.percOn, 1)
    engine.setParameter(.percShaker, 0)
    check(engine.parameter(.percShaker) == 0 && engine.parameter(.percTambourine) == 1, "instrument switches read back")
    let noShaker = play(sid, seconds: 2)
    check(perc(noShaker, from: 0, to: 2) == [0, 2, 0, 0], "shaker off, tambourine plays: \(perc(noShaker, from: 0, to: 2))")
    engine.setParameter(.percShaker, 1)
    let sw = play(sid, seconds: 4, params: [(1.1, .percOn, 0), (2.6, .percOn, 1)])
    check(perc(sw, from: 0, to: 1.1) == [5, 1, 0, 0] && perc(sw, from: 1.1, to: 2.6) == [0, 0, 0, 0] && perc(sw, from: 2.6, to: 4) == [5, 1, 0, 0],
          "off and on mid-song, back in time: \(perc(sw, from: 0, to: 1.1)) \(perc(sw, from: 1.1, to: 2.6)) \(perc(sw, from: 2.6, to: 4))")
    check(sw.notes.filter { $0.note == Drum.shaker.gmNote && $0.t >= 2.6 }.first.map { abs($0.t - 2.75) < 0.01 } == true,
          "switched on, the shaker lands on the grid")

    // Level: scales the layers' sound, not their MIDI, and not the drums.
    let quiet = try store.add(SongData(name: "Perc Only", genre: "drum songs › Test Artist", tempo: 120, timeSignature: "4/4",
                                       barTicks: 1920, beatTicks: 480, intro: nil,
                                       parts: [PartData(main: PatternData(events: [], length: 1920), fill: nil)], transition: nil, outro: nil))
    store.setPercussion(shaker, song: quiet, instrument: .shaker)
    let loud = play(quiet, seconds: 2)
    engine.setParameter(.percVolume, 0.5)
    let half = play(quiet, seconds: 2)
    engine.setParameter(.percVolume, 0)
    let silentLayers = play(sid, seconds: 2)
    engine.setParameter(.percOn, 0)
    let drumsAlone = play(sid, seconds: 2)
    engine.setParameter(.percOn, 1)
    engine.setParameter(.percVolume, 1)
    check(rms(loud) > 0.001 && abs(rms(half) / rms(loud) - 0.5) < 0.08 && perc(half, from: 0, to: 2) == [8, 0, 0, 0],
          "percussion level scales the layer (\(rms(half) / rms(loud))), MIDI unchanged")
    check(abs(rms(silentLayers) / rms(drumsAlone) - 1) < 0.05 && perc(silentLayers, from: 0, to: 2) == [8, 2, 0, 0],
          "level 0 silences the layers only (\(rms(silentLayers)) vs drums \(rms(drumsAlone)))")
    engine.setParameter(.percVolume, 9)
    check(engine.parameter(.percVolume) == 1.5, "percussion level clamps to 1.5")
    engine.setParameter(.percVolume, 1)

    // Auditioning a file in the song editor plays no percussion.
    engine.send(.stop)
    engine.preview(pattern: store.partMain[sid * SongStore.maxParts], loop: true)
    var auditioned: [UInt8] = []
    for _ in 0..<Int(2.0 * sr / Double(frames)) {
        engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
        engine.forEachOutputEvent { _, n, _ in auditioned.append(n) }
    }
    engine.stopPreview()
    check(auditioned.contains(Drum.kick.gmNote) && !auditioned.contains(Drum.shaker.gmNote), "audition without percussion")

    // Folder import. Layers never become songs; each plays with the "drum songs" song of the same
    // artist and title, whichever is imported first, also from a parent folder (group from song.json).
    check(PercussionInstrument(pack: "Shaker_Songs") == .shaker && PercussionInstrument(pack: "clap songs") == .clap
          && PercussionInstrument(pack: "drum songs") == nil, "percussion packs")
    check(SongIndex.linkKey(genre: "drum songs › AC/DC", name: "What's Up?") == SongIndex.linkKey(genre: "tambourine songs › AC DC", name: "What's up")
          && SongIndex.linkKey(genre: "Rock", name: "Straight Eights") == nil, "song link keys")
    let one = MIDISongImporter.SongLayout(parts: [.init(main: "Groove A.mid")])
    func folder(_ path: [String], _ genre: String, _ title: String, _ groove: Data, fill: Data? = nil) -> [MIDIFolderImport.Entry] {
        var layout = one
        var entries: [MIDIFolderImport.Entry] = [.init(path: path + ["Groove A.mid"], data: groove)]
        if let fill {
            layout.parts[0].fills = ["Groove A Fill 1.mid"]
            entries.append(.init(path: path + ["Groove A Fill 1.mid"], data: fill))
        }
        let json = try? JSONEncoder().encode(SongLibrary.SongFile(name: title, genre: genre, layout: layout))
        return entries + [.init(path: path + [SongLibrary.songFileName], data: json ?? Data())]
    }
    let shakerFile = smf((0..<8).map { ($0 * 48, UInt8(70)) } + [(0, 36)])   // a stray kick is left out
    let r1 = library.importFolder(folder(["shaker_songs", "Perc Artist", "Shake It"], "shaker songs › Perc Artist", "Shake It", shakerFile,
                                         fill: smf((0..<16).map { ($0 * 24, UInt8(82)) }))
                                  + folder(["shaker_songs", "Perc Artist", "Same Shake"], "shaker songs › Perc Artist", "Same Shake", shakerFile))
    check(r1.songs.isEmpty && r1.percussion[.shaker] == 2 && r1.skipped.isEmpty, "shaker folder imports layers, not songs: \(r1.percussion) \(r1.skipped)")
    check(!library.visibleSongs.contains { $0.genre.hasPrefix("shaker songs") } && library.percussionCounts[.shaker] == 2,
          "layers are not beats")
    let r2 = library.importFolder(folder(["drum_songs", "Perc Artist", "Shake It"], "drum songs › Perc Artist", "Shake It",
                                         smf([(0, 36), (96, 38), (192, 36), (288, 38)]))
                                  + folder(["drum_songs", "Perc Artist", "Same Shake"], "drum songs › Perc Artist", "Same Shake",
                                           smf([(0, 36), (192, 36)])))
    check(r2.songs.count == 2 && r2.songs.allSatisfy { library.percussion(for: $0) == [.shaker] && store.percussion(song: $0.id, instrument: 0) >= 0 },
          "drum songs imported after their shaker play it")
    let r3 = library.importFolder(folder(["tambourine_songs", "Perc Artist", "Shake It"], "tambourine songs › Perc Artist", "Shake It",
                                         smf([(96, 54), (288, 54)]))
                                  + folder(["midi-songs", "clap_songs", "Perc Artist", "Shake It"], "clap songs › Perc Artist", "Shake It",
                                           smf([(96, 39), (288, 39)])))
    check(r3.percussion[.tambourine] == 1 && r3.percussion[.clap] == 1, "tambourine and clap (parent folder) import: \(r3.percussion)")
    let parentPlan = MIDIFolderImport.plan(folder(["midi-songs", "drum_songs", "Perc Artist", "Shake It"], "drum songs › Perc Artist", "Shake It",
                                                  smf([(0, 36)])))
    check(parentPlan.groups.first?.genre == "drum songs › Perc Artist", "a song pack keeps its group: \(parentPlan.groups.map(\.genre))")
    if let shakeIt = r2.songs.first(where: { $0.name == "Shake It" }) {
        check(library.percussion(for: shakeIt) == [.shaker, .tambourine, .clap], "all three layers: \(library.percussion(for: shakeIt))")
        // The imported song starts with its count-in (no layer has an intro), then the groove with all three.
        let rec = store.songs[shakeIt.id]
        let t0 = Double(store.patterns[Int(rec.intro)].length) / 960
        let ip = play(shakeIt.id, seconds: t0 + 6.1, script: [(t0 + 1.75, .fill)])
        check(perc(ip, from: 0, to: t0) == [0, 0, 0, 0] && perc(ip, from: t0, to: t0 + 2) == [8, 2, 2, 0] && count(ip, .kick, from: t0, to: t0 + 2) == 2,
              "imported song plays its percussion: \(perc(ip, from: 0, to: t0)) \(perc(ip, from: t0, to: t0 + 2))")
        check(perc(ip, from: t0 + 2, to: t0 + 4) == [16, 2, 2, 0], "imported shaker fill: \(perc(ip, from: t0 + 2, to: t0 + 4))")

        // Saved with the user library and with a host project (the song plus its layers).
        let project = library.importsPropertyList(forKey: shakeIt.key) + library.percussionPropertyList(for: shakeIt)
        check(project.count == 4, "project keeps the song and its 3 layers (\(project.count))")
        let lib2 = SongLibrary(store: DrumEngine().store)
        lib2.restoreImports(project)
        let restored = lib2.visibleSongs.filter { $0.isUser }
        check(restored.count == 1 && restored.first.map { lib2.percussion(for: $0) } == [.shaker, .tambourine, .clap],
              "percussion restored with the project: \(restored.map(\.name))")

        // Removing an instrument's imports stops it; importing again brings it back.
        library.removePercussion(.shaker)
        check(library.percussion(for: shakeIt) == [.tambourine, .clap] && store.percussion(song: shakeIt.id, instrument: 0) == -1
              && library.percussionCounts[.shaker] == nil && !library.imports.contains { $0.genre.hasPrefix("shaker songs") },
              "shaker imports removed")
        check(perc(play(shakeIt.id, seconds: t0 + 2), from: t0, to: t0 + 2) == [0, 2, 2, 0], "removed shaker is silent")
        let back = library.importFolder(folder(["shaker_songs", "Perc Artist", "Shake It"], "shaker songs › Perc Artist", "Shake It", shakerFile,
                                               fill: smf((0..<16).map { ($0 * 24, UInt8(82)) })))
        check(back.percussion[.shaker] == 1 && library.percussion(for: shakeIt) == [.shaker, .tambourine, .clap], "re-import brings it back")
        library.removePercussion(.shaker); library.removePercussion(.tambourine); library.removePercussion(.clap)
        check(library.percussionCounts.isEmpty, "all percussion imports removed")
    } else { check(false, "percussion drum song import") }
    print("Percussion: sections, fills, switches, level, audition, folder import, linking, saving and removal checked")
} catch { check(false, "percussion tests threw \(error)") }

// 13. Song pack: the songs that ship inside the plug-in (own drums, bass with its root, percussion)
//     survive encode → decode, load as built-in songs that aren't saved with the imports, keep their
//     percussion, can be edited as a copy; "bassRoot" in song.json reaches the engine.
do {
    func hits(_ drum: Drum, _ ticks: [Int], length: Int = 1920, swing: Int16 = 0) -> PatternData {
        PatternData(events: ticks.map { SeqEvent(tick: Int32($0), drum: UInt8(drum.rawValue), velocity: 90, swingUnit: swing) }, length: length)
    }
    func line(_ notes: [UInt8], length: Int = 1920) -> BassPattern {
        BassPattern(events: notes.enumerated().map { BassEvent(tick: Int32($0.offset * 480), note: $0.element, velocity: 99, durationTicks: 300) },
                    length: length)
    }
    let groove = PatternData(events: hits(.kick, [0, 960]).events + hits(.snare, [480, 1440]).events, length: 1920)
    var s1 = SongData(name: "Pack Song", genre: "drum songs › Pack Artist", tempo: 99, timeSignature: "4/4", barTicks: 1920, beatTicks: 480,
                      intro: hits(.rim, [0, 480, 960, 1440]),
                      parts: [PartData(main: groove, fills: [hits(.snare, [0, 240, 480, 720])], bass: line([31, 31, 38, 36])),
                              PartData(main: hits(.ride, [0, 480, 960, 1440], length: 3840), fills: [], bass: nil)],
                      transition: hits(.tomLow, [0, 960]), outro: hits(.crash, [0]), introCrash: false, fillCrash: true, kitHint: 3,
                      key: ContentPack.keyPrefix + "pack artist pack song", bassRootPitchClass: 7)
    s1.introBass = line([31]); s1.outroBass = line([31], length: 960); s1.bassEnabled = true
    let s2 = SongData(name: "Swing Six", genre: "drum songs › Pack Artist", tempo: 70, timeSignature: "6/8", barTicks: 1440, beatTicks: 720,
                      intro: nil, parts: [PartData(main: hits(.hatClosed, [0, 240, 480, 720], length: 1440, swing: 60), fill: nil)],
                      transition: nil, outro: nil, key: ContentPack.keyPrefix + "pack artist swing six")
    let layer = ContentPack.Layer(genre: "shaker songs › Pack Artist", name: "Pack Song",
                                  data: PercussionData(instrument: .shaker, parts: [PercussionPart(main: hits(.shaker, Array(stride(from: 0, to: 1920, by: 240))),
                                                                                                   fills: [hits(.shaker, [0, 120, 240])])],
                                                       outro: hits(.shaker, [0])))
    let data = ContentPack.encode(.init(songs: [s1, s2], percussion: [layer]))
    let back = try ContentPack.decode(data)
    func same(_ a: PatternData?, _ b: PatternData?) -> Bool { a?.events == b?.events && a?.length == b?.length }
    func sameSong(_ a: SongData, _ b: SongData) -> Bool {
        a.name == b.name && a.genre == b.genre && a.key == b.key && a.tempo == b.tempo && a.timeSignature == b.timeSignature
            && a.barTicks == b.barTicks && a.beatTicks == b.beatTicks && a.introCrash == b.introCrash && a.fillCrash == b.fillCrash
            && a.kitHint == b.kitHint && a.isUser == b.isUser && a.bassEnabled == b.bassEnabled && a.bassRootPitchClass == b.bassRootPitchClass
            && same(a.intro, b.intro) && same(a.transition, b.transition) && same(a.outro, b.outro)
            && a.introBass == b.introBass && a.transitionBass == b.transitionBass && a.outroBass == b.outroBass
            && a.parts.count == b.parts.count && zip(a.parts, b.parts).allSatisfy {
                same($0.main, $1.main) && $0.fills.count == $1.fills.count && zip($0.fills, $1.fills).allSatisfy { same($0, $1) } && $0.bass == $1.bass
            }
    }
    check(back.songs.count == 2 && zip([s1, s2], back.songs).allSatisfy { sameSong($0, $1) }, "song pack round trip: songs")
    let bl = back.percussion.first
    check(back.percussion.count == 1 && bl?.genre == layer.genre && bl?.name == layer.name && bl?.data.instrument == .shaker
          && same(bl?.data.parts.first?.main, layer.data.parts[0].main) && same(bl?.data.parts.first?.fills.first, layer.data.parts[0].fills[0])
          && same(bl?.data.outro, layer.data.outro) && bl?.data.intro == nil, "song pack round trip: percussion")
    check((try? ContentPack.decode(data.prefix(data.count / 2))) == nil && (try? ContentPack.decode(Data("PBCP".utf8))) == nil
          && (try? ContentPack.decode(Data("nope, not a pack".utf8))) == nil, "damaged song packs are rejected")

    // Loaded like the plug-in does: built-in songs, not saved with the imports; percussion linked.
    let packURL = URL(fileURLWithPath: outDir).appendingPathComponent("test.pbcp")
    try data.write(to: packURL)
    let engine2 = DrumEngine()
    let lib = SongLibrary(store: engine2.store)
    check(lib.loadContentPack(at: packURL) == 2 && lib.loadContentPack(at: URL(fileURLWithPath: outDir).appendingPathComponent("none.pbcp")) == 0,
          "song pack loads (and a missing one is skipped)")
    let pack = lib.visibleSongs.filter { $0.key.hasPrefix(ContentPack.keyPrefix) }
    check(pack.count == 2 && pack.allSatisfy { !$0.isUser } && lib.imports.isEmpty && lib.importsPropertyList.isEmpty,
          "pack songs are built in and not saved with the imports")
    if let ps = pack.first(where: { $0.name == "Pack Song" }) {
        let builtInTrack = engine2.store.percussion(song: ps.id, instrument: PercussionInstrument.shaker.rawValue)
        check(ps.hasBass && engine2.store.songs[ps.id].bassRoot == 7 && lib.percussion(for: ps) == [.shaker] && builtInTrack >= 0
              && lib.percussionCounts.isEmpty && lib.percussionPropertyList(for: ps).isEmpty, "pack song: bass in G, its own shaker")
        lib.removePercussion(.shaker)
        check(engine2.store.percussion(song: ps.id, instrument: 0) == builtInTrack, "built-in percussion can't be removed")
        // A user import of that song's shaker plays instead; removing it brings the built-in one back.
        let shakerJSON = try JSONEncoder().encode(SongLibrary.SongFile(name: "Pack Song", genre: "shaker songs › Pack Artist",
                                                                       layout: .init(parts: [.init(main: "Groove A.mid")])))
        let r = lib.importFolder([.init(path: ["shaker_songs", "Pack Artist", "Pack Song", "Groove A.mid"], data: smf((0..<16).map { ($0 * 24, UInt8(70)) })),
                                  .init(path: ["shaker_songs", "Pack Artist", "Pack Song", SongLibrary.songFileName], data: shakerJSON)])
        let userTrack = engine2.store.percussion(song: ps.id, instrument: 0)
        check(r.percussion[.shaker] == 1 && userTrack >= 0 && userTrack != builtInTrack && lib.percussionCounts[.shaker] == 1,
              "an imported shaker replaces the built-in one")
        lib.removePercussion(.shaker)
        check(engine2.store.percussion(song: ps.id, instrument: 0) == builtInTrack && lib.percussion(for: ps) == [.shaker],
              "removing the import brings the built-in shaker back")
        // Editing a pack song saves a copy that keeps the bass root and replaces it.
        if let rec = lib.beginEditing(ps), let layout = rec.layout {
            check(layout.bassRoot == 7 && layout.parts.first?.bass != nil, "pack song opens in the editor with its bass root")
            let copy = try lib.updateSong(key: ps.key, name: "Pack Song", layout: layout)
            check(copy.isUser && engine2.store.songs[copy.id].bassRoot == 7 && lib.isEditedFactorySong(key: ps.key)
                  && !lib.visibleSongs.contains { $0.id == ps.id } && lib.percussion(for: copy) == [.shaker],
                  "edited pack song: a user copy with its bass root and percussion")
        } else { check(false, "pack song editable") }
    } else { check(false, "pack song loaded") }

    // "bassRoot" in song.json sets the song's bass root (Bass Follow transposes from it).
    var rooted = MIDISongImporter.SongLayout(parts: [.init(main: "Groove A.mid", bass: "Groove A Bass.mid")])
    rooted.bassRoot = 2
    let rootedJSON = try JSONEncoder().encode(SongLibrary.SongFile(name: "Rooted", genre: "Root Test", layout: rooted))
    let bassOnly = MIDIWriter.drumFile(PatternData(events: [], length: 1920), tempo: 120, signature: "4/4", bass: line([38, 38, 45, 38]))
    let rr = lib.importFolder([.init(path: ["Root Test", "Rooted", "Groove A.mid"], data: smf([(0, 36), (96, 38), (192, 36), (288, 38)])),
                               .init(path: ["Root Test", "Rooted", "Groove A Bass.mid"], data: bassOnly),
                               .init(path: ["Root Test", "Rooted", SongLibrary.songFileName], data: rootedJSON)])
    check(rr.songs.count == 1 && rr.songs.first.map { engine2.store.songs[$0.id].bassRoot == 2 && $0.hasBass } == true,
          "bassRoot from song.json reaches the engine")

    // Songs tab tempo: the index BPM, or the drums' own when they were written at double or half of it.
    check(SongIndex.playTempo(indexBPM: 198, drumsTempo: 99, ownDrums: true) == 99
          && SongIndex.playTempo(indexBPM: 121, drumsTempo: 61, ownDrums: true) == 61
          && SongIndex.playTempo(indexBPM: 169, drumsTempo: 155, ownDrums: true) == 169
          && SongIndex.playTempo(indexBPM: 198, drumsTempo: 99, ownDrums: false) == 198, "play tempo for the songs' own drums")
    print("Song pack: \(data.count) bytes for 2 songs + 1 layer; round trip, built-in loading, percussion, editing, bassRoot and tempo checked")
} catch { check(false, "song pack tests threw \(error)") }

// 14. Fill bass: a fill with a bass line of its own plays it, then the groove's bass returns in step
//     with the drums; a fill without one leaves the groove's bass running. Survives the pack format.
do {
    engine.setParameter(.volume, 0.8); engine.setParameter(.bassVolume, 0.8); engine.setParameter(.bassMute, 0)
    engine.setParameter(.hostSync, 0); engine.setParameter(.tempo, 120)
    func line(_ notes: [UInt8]) -> BassPattern {
        BassPattern(events: notes.enumerated().map { BassEvent(tick: Int32($0.offset * 480), note: $0.element, velocity: 100, durationTicks: 400) }, length: 1920)
    }
    let groove = PatternData(events: [SeqEvent(tick: 0, drum: UInt8(Drum.kick.rawValue), velocity: 100)], length: 1920)
    let fillBar = PatternData(events: (0..<8).map { SeqEvent(tick: Int32($0 * 240), drum: UInt8(Drum.snare.rawValue), velocity: 100) }, length: 1920)
    let fbPart = PartData(main: groove, fills: [fillBar, fillBar], bass: line([40, 40, 40, 40]), fillBass: [line([50, 51, 52, 53]), nil])
    let song = SongData(name: "Fill Bass", genre: "Bass Test", tempo: 120, timeSignature: "4/4", barTicks: 1920, beatTicks: 480,
                        intro: nil, parts: [fbPart], transition: fillBar, outro: nil)
    let sid = try store.add(song)
    func bassNotes(fills at: [Double], seconds: Double) -> [(Double, UInt8)] {
        engine.send(.stop); engine.setParameter(.song, Float(sid))
        engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
        engine.synth.reset(); engine.bass.reset()
        var pending = [(0.0, PedalCommand.start)] + at.map { ($0, PedalCommand.fill) }
        var out: [(Double, UInt8)] = []
        for b in 0..<Int(seconds * sr / Double(frames)) {
            let t = Double(b * frames) / sr
            while let f = pending.first, f.0 <= t { engine.send(f.1); pending.removeFirst() }
            engine.beginRender()
            engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
            engine.forEachBassOutputEvent { off, n, v in if v > 0 { out.append((t + Double(off) / sr, n)) } }
        }
        engine.send(.stop)
        return out
    }
    func within(_ o: [(Double, UInt8)], _ a: Double, _ b: Double) -> [UInt8] { o.filter { $0.0 >= a - 0.005 && $0.0 < b - 0.005 }.map(\.1) }
    // Fill 1 (own bass) starts in the bar at 2 s; fill 2 (none) in the bar at 6 s.
    let o = bassNotes(fills: [2.25, 6.25], seconds: 9)
    check(within(o, 0, 2) == [40, 40, 40, 40], "groove bass before the fill: \(within(o, 0, 2))")
    check(within(o, 2, 4).suffix(3) == [51, 52, 53] || within(o, 2, 4) == [50, 51, 52, 53], "fill 1 plays its own bass: \(within(o, 2, 4))")
    check(within(o, 4, 6) == [40, 40, 40, 40], "groove bass returns after the fill: \(within(o, 4, 6))")
    check(within(o, 6, 8) == [40, 40, 40, 40], "fill 2 has no bass of its own: the groove's keeps going: \(within(o, 6, 8))")
    // Pack round trip keeps the per-fill bass.
    let back = try ContentPack.decode(ContentPack.encode(.init(songs: [song], percussion: [])))
    check(back.songs.first?.parts.first?.fillBass.map { $0?.events.count } == [4, nil], "pack round trip keeps fill bass")
    print("Fill bass: own bass in a fill, groove bass resumes, pack round trip checked")
} catch { check(false, "fill bass tests threw \(error)") }

// 15. A bb beat with a song's bass and percussion: the beat keeps its parts and fills,
//     the song brings its bass (per part) and percussion; built once, hidden, meters must match.
do {
    let eng = DrumEngine()
    let lib = SongLibrary(store: eng.store)
    typealias Layout = MIDISongImporter.SongLayout
    func entries(_ path: [String], _ genre: String, _ title: String, _ layout: Layout, _ files: [String: Data]) -> [MIDIFolderImport.Entry] {
        let json = try? JSONEncoder().encode(SongLibrary.SongFile(name: title, genre: genre, layout: layout))
        return files.map { .init(path: path + [$0.key], data: $0.value) } + [.init(path: path + [SongLibrary.songFileName], data: json ?? Data())]
    }
    let groove = smf([(0, 36), (96, 38), (192, 36), (288, 38)])
    let offbeatKicks = smf([(72, 36), (96, 38), (264, 36), (288, 38)])     // kicks on the "a" of 1 and 3
    let fill = smf((0..<8).map { ($0 * 48, UInt8(38)) })
    let bassLine = BassPattern(events: [40, 40, 43, 45].enumerated().map {
        BassEvent(tick: Int32($0.offset * 480), note: $0.element, velocity: 100, durationTicks: 400) }, length: 1920)
    let bassFile = MIDIWriter.drumFile(PatternData(events: [], length: 1920), tempo: 120, signature: "4/4", bass: bassLine)
    let bb = Layout(parts: [.init(main: "Part 1.mid", fills: ["Part 1 Fill 1.mid"]),
                            .init(main: "Part 2.mid", fills: ["Part 2 Fill 1.mid", "Part 2 Fill 2.mid"])])
    let r = lib.importFolder(
        entries(["BBS", "Ballad", "Ballad 2"], "\(BBSImport.packName) › Ballad", "Ballad 2", bb,
                ["Part 1.mid": groove, "Part 1 Fill 1.mid": fill, "Part 2.mid": offbeatKicks, "Part 2 Fill 1.mid": fill, "Part 2 Fill 2.mid": fill])
        + entries(["drum_songs", "Eagles", "Hotel California"], "drum songs › Eagles", "Hotel California",
                  Layout(parts: [.init(main: "Groove A.mid", bass: "Groove A Bass.mid")]), ["Groove A.mid": groove, "Groove A Bass.mid": bassFile])
        + entries(["shaker_songs", "Eagles", "Hotel California"], "shaker songs › Eagles", "Hotel California",
                  Layout(parts: [.init(main: "Groove A.mid")]), ["Groove A.mid": smf((0..<8).map { ($0 * 48, UInt8(70)) })])
        + entries(["drum_songs", "Odd", "Five"], "drum songs › Odd", "Five",
                  Layout(parts: [.init(main: "Groove A.mid", bass: "Groove A Bass.mid")]),
                  ["Groove A.mid": MIDIWriter.drumFile(PatternData(events: [SeqEvent(tick: 0, drum: UInt8(Drum.kick.rawValue), velocity: 100)], length: 2400),
                                                       tempo: 120, signature: "5/4", barTicks: 2400, beatTicks: 480),
                   "Groove A Bass.mid": MIDIWriter.drumFile(PatternData(events: [], length: 2400), tempo: 120, signature: "5/4",
                                                            barTicks: 2400, beatTicks: 480, bass: BassPattern(events: bassLine.events, length: 2400))]))
    let beat = r.songs.first { $0.name == "Ballad 2" }, song = r.songs.first { $0.name == "Hotel California" }
    if let beat, let song {
        let visibleBefore = lib.visibleSongs.count
        if let l = lib.beat(beat, withBassAndPercussionOf: song) {
            let st = eng.store
            check(l.partCount == 2 && (0..<2).map { st.fillCount(song: l.id, part: $0) } == [1, 2],
                  "layered beat keeps the bb parts and fills: \(l.partCount) parts")
            check(st.bassPattern(st.bass(song: l.id, part: 0))?.events.map(\.note) == [40, 40, 43, 45] && l.hasBass,
                  "part 1: the song's bass fits the beat and plays")
            let gen = st.bassPattern(st.bass(song: l.id, part: 1))
            check(gen?.events.map(\.tick) == [360, 1320] && gen?.events.first?.note == BassGenerator.root(pitchClass: 4)
                  && lib.generatedBassParts(l) == 1,
                  "part 2: the song's bass misses the beat's kicks, a line on the kick plays: \(gen?.events.map { ($0.tick, $0.note) } ?? [])")
            let straight = BassPattern(events: [0, 240, 480, 720].map { BassEvent(tick: Int32($0), note: 40, velocity: 100, durationTicks: 200) }, length: 1920)
            let shuffle = PatternData(events: [0, 320, 480, 800, 960, 1280].map { SeqEvent(tick: Int32($0), drum: UInt8($0 % 960 == 0 ? Drum.kick.rawValue : Drum.hatClosed.rawValue), velocity: 100) }, length: 1920)
            check(!BassGenerator.fits(straight, drums: shuffle, barTicks: 1920, beatTicks: 480)
                  && BassGenerator.fits(bassLine, drums: shuffle, barTicks: 1920, beatTicks: 480),
                  "straight 8ths do not fit a shuffle; quarters on its kicks do")
            check(BassGenerator.style(forBeatGenre: "BBS › Reggae") == .reggae && BassGenerator.style(forBeatGenre: "BBS › Ballad-mini") == .rock,
                  "beat genre picks the generator style")
            check(st.percussion(song: l.id, instrument: PercussionInstrument.shaker.rawValue) >= 0, "the song's shaker plays on the beat")
            check(st.partMain[l.id * SongStore.maxParts] == st.partMain[beat.id * SongStore.maxParts]
                  || st.patterns[Int(st.partMain[l.id * SongStore.maxParts])].count == st.patterns[Int(st.partMain[beat.id * SongStore.maxParts])].count,
                  "same drums as the beat")
            check(lib.beat(beat, withBassAndPercussionOf: song)?.id == l.id && lib.visibleSongs.count == visibleBefore,
                  "built once, not in the song lists")
            check(l.name == "Hotel California" && st.bass(song: beat.id, part: 0) != st.bass(song: l.id, part: 0),
                  "named after the song; the beat itself is unchanged")
        } else { check(false, "layered beat built") }
        if let five = r.songs.first(where: { $0.name == "Five" }) {
            check(lib.beat(beat, withBassAndPercussionOf: five) == nil, "a song in another meter does not layer")
        } else { check(false, "5/4 song imported: \(r.skipped)") }
    } else { check(false, "bb beat and song imported: \(r.songs.map(\.name)) \(r.skipped)") }
    print("bb beat + song bass/percussion checked")
}

// 16. Beats (not songs) get a generated bass and generated percussion; Auto Percussion plays it.
//     Maracas are an instrument of their own (GM 70), the shaker is GM 82.
do {
    check(Drum.fromGM(70) == .maracas && Drum.fromGM(82) == .shaker && Drum.fromGM(69) == .shaker
          && Drum.shaker.gmNote == 82 && Drum.maracas.gmNote == 70 && MixBus.forDrum(.maracas) == .perc, "maracas and shaker notes")
    check(PercussionInstrument.maracas.drum == .maracas && PercussionInstrument(pack: "maracas songs") == .maracas, "maracas layers")
    // Old shaker files hold maracas notes too: they stay shaker.
    let shakerMix = try MIDIDrumFile(data: smf([(0, 70), (48, 82), (96, 70)]), name: "Groove A.mid")
    let mixed = PercussionData.make(files: [shakerMix], layout: .init(parts: [.init(main: "Groove A.mid")]), instrument: .shaker)
    check(mixed?.parts.first?.main.events.count == 3 && mixed?.parts.first?.main.events.allSatisfy { $0.drum == UInt8(Drum.shaker.rawValue) } == true,
          "a shaker file's maracas notes stay shaker")

    // Generator: shaker follows the hats (8ths here), tambourine and clap the snare; a shuffle keeps its triplets.
    let rockBar = PatternData(events: [0, 960].map { SeqEvent(tick: Int32($0), drum: UInt8(Drum.kick.rawValue), velocity: 110) }
        + [480, 1440].map { SeqEvent(tick: Int32($0), drum: UInt8(Drum.snare.rawValue), velocity: 110) }
        + stride(from: 0, to: 1920, by: 240).map { SeqEvent(tick: Int32($0), drum: UInt8(Drum.hatClosed.rawValue), velocity: 90) }, length: 1920)
    let shk = PercussionGenerator.pattern(.pulse(subdivision: 2), instrument: .shaker, drums: rockBar, barTicks: 1920, beatTicks: 480)
    check(shk.events.map(\.tick) == stride(from: 0, to: 1920, by: 240).map { Int32($0) } && shk.events.allSatisfy { $0.drum == UInt8(Drum.shaker.rawValue) },
          "shaker on the hats' eighths: \(shk.events.map(\.tick))")
    let bb = PercussionGenerator.pattern(.backbeat, instrument: .clap, drums: rockBar, barTicks: 1920, beatTicks: 480)
    check(bb.events.map(\.tick) == [480, 1440], "clap on the snare backbeats")
    let shuffle = PatternData(events: [0, 320, 480, 800, 960, 1280, 1440, 1760].map { SeqEvent(tick: Int32($0), drum: UInt8(Drum.ride.rawValue), velocity: 90) }, length: 1920)
    let shufShk = PercussionGenerator.pattern(.pulse(subdivision: 2), instrument: .shaker, drums: shuffle, barTicks: 1920, beatTicks: 480)
    check(shufShk.events.map(\.tick) == [0, 320, 480, 800, 960, 1280, 1440, 1760], "shuffle: the shaker swings with the ride: \(shufShk.events.map(\.tick))")
    let noHats = PercussionGenerator.pattern(.backbeat, instrument: .tambourine, drums: PatternData(events: [], length: 1920), barTicks: 1920, beatTicks: 480)
    check(noHats.events.map(\.tick) == [480, 1440], "no snare: tambourine on 2 and 4")
    let latin = SongData(name: "L", genre: "Latin", tempo: 100, timeSignature: "4/4", barTicks: 1920, beatTicks: 480, intro: nil,
                         parts: [PartData(main: rockBar, fill: nil)], transition: nil, outro: nil)
    check(PercussionGenerator.layers(for: latin).map(\.instrument) == [.maracas], "latin: maracas")

    // Library: beats get generated bass and percussion, songs do not.
    let eng = DrumEngine()
    let lib = SongLibrary(store: eng.store)
    let rock1 = lib.songs.first { $0.name.hasPrefix("Rock 1 ") }
    check(rock1.map { lib.autoPercussion(for: $0) == [.shaker, .tambourine] } == true, "factory beat: generated shaker and tambourine")
    func folder(_ path: [String], _ genre: String, _ title: String, _ files: [String: Data]) -> [MIDIFolderImport.Entry] {
        let layout = MIDISongImporter.SongLayout(parts: [.init(main: "Groove A.mid")])
        let json = try? JSONEncoder().encode(SongLibrary.SongFile(name: title, genre: genre, layout: layout))
        return files.map { .init(path: path + [$0.key], data: $0.value) } + [.init(path: path + [SongLibrary.songFileName], data: json ?? Data())]
    }
    let groove = smf([(0, 36), (96, 38), (192, 36), (288, 38)] + (0..<8).map { ($0 * 48, UInt8(42)) })
    let r = lib.importFolder(folder(["BBS", "Funk", "Funk 1"], "BBS › Funk", "Funk 1", ["Groove A.mid": groove])
                             + folder(["drum_songs", "Some Artist", "Some Song"], "drum songs › Some Artist", "Some Song", ["Groove A.mid": smf([(0, 36), (96, 38), (192, 36), (240, 36), (288, 38)])]))
    let bbsBeat = r.songs.first { $0.name == "Funk 1" }, songOnly = r.songs.first { $0.name == "Some Song" }
    check(bbsBeat?.hasBass == true && bbsBeat.map { eng.store.bass(song: $0.id, part: 0) >= 0 } == true, "a bb beat gets a generated bass")
    check(bbsBeat.map { lib.autoPercussion(for: $0) == [.shaker] } == true, "one-part funk beat: the verse's shaker (clap comes in the chorus): \(bbsBeat.map { lib.autoPercussion(for: $0) } ?? []) \(bbsBeat?.genre ?? "-")")
    check(songOnly?.hasBass == false && songOnly.map { lib.autoPercussion(for: $0).isEmpty } == true, "a song gets neither: \(songOnly?.hasBass ?? true) \(songOnly.map { lib.autoPercussion(for: $0) } ?? []) \(songOnly?.genre ?? "-") \(r.songs.map { $0.name + "|" + $0.genre })")

    // Playback: generated layers play only with Auto Percussion on.
    if let rock1 {
        func shakerNotes(_ seconds: Double) -> Int {
            engine.send(.stop); engine.setParameter(.song, Float(rock1.id)); engine.setParameter(.tempo, 120)
            engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
            engine.send(.start)
            var n = 0
            for _ in 0..<Int(seconds * sr / Double(frames)) {
                engine.beginRender(); engine.render(frames: frames, left: L, right: R, hostTempo: nil, hostPlaying: nil)
                engine.forEachOutputEvent { _, note, _ in if note == Drum.shaker.gmNote { n += 1 } }
            }
            engine.send(.stop)
            return n
        }
        let rockIdx = library.songs.first { $0.name == rock1.name }!.id   // same factory order in the shared engine
        check(rockIdx == rock1.id, "factory order")
        engine.setParameter(.percOn, 1)
        engine.setParameter(.percAuto, 0)
        let off = shakerNotes(6)
        engine.setParameter(.percAuto, 1)
        check(engine.parameter(.percAuto) == 1, "Auto Percussion reads back")
        let on = shakerNotes(6)
        engine.setParameter(.percAuto, 0)
        check(off == 0 && on >= 8, "Auto Percussion plays the generated shaker: off \(off), on \(on)")
    }
    // Built-in bb beats: visible like imported ones, with generated bass; an import of the same beat replaces them.
    let pe = DrumEngine()
    let plib = SongLibrary(store: pe.store)
    let builtInBeat = SongData(name: "Rock 9", genre: "BBS › Rock", tempo: 120, timeSignature: "4/4", barTicks: 1920, beatTicks: 480,
                               intro: nil, parts: [PartData(main: rockBar, fill: nil)], transition: nil, outro: nil,
                               key: ContentPack.beatKey(genre: "BBS › Rock", name: "Rock 9"))
    let packURL = FileManager.default.temporaryDirectory.appendingPathComponent("pedalbeat-beat-\(UUID().uuidString).pbcp")
    try ContentPack.encode(.init(songs: [builtInBeat], percussion: [])).write(to: packURL)
    defer { try? FileManager.default.removeItem(at: packURL) }
    check(plib.loadContentPack(at: packURL) == 1, "pack with a beat loads")
    let shownBeat = plib.visibleSongs.first { $0.name == "Rock 9" }
    check(shownBeat.map { !$0.isUser && !$0.key.hasPrefix(ContentPack.keyPrefix) && $0.hasBass && !plib.autoPercussion(for: $0).isEmpty } == true,
          "built-in beat: in the Beats tab, generated bass and percussion")
    let ri = plib.importFolder(folder(["BBS", "Rock", "Rock 9"], "BBS › Rock", "Rock 9", ["Groove A.mid": groove]))
    let rock9 = plib.visibleSongs.filter { $0.name == "Rock 9" }
    check(ri.songs.count == 1 && rock9.count == 1 && rock9.first?.isUser == true, "an import of the same beat replaces the built-in one: \(rock9.count)")
    print("Generated bass and percussion for beats, maracas, Auto Percussion checked")
} catch { check(false, "generated percussion tests threw \(error)") }

// 17. A song's bb version as a folder of its own ("bb songs › Artist" / "Title · Beat"): exported
//     from the layered beat, imported again it plays the same, keeps its bass (nothing generated on top)
//     and gets the song's percussion by artist + title.
do {
    typealias Layout = MIDISongImporter.SongLayout
    func entries(_ path: [String], _ genre: String, _ title: String, _ layout: Layout, _ files: [String: Data]) -> [MIDIFolderImport.Entry] {
        let json = try? JSONEncoder().encode(SongLibrary.SongFile(name: title, genre: genre, layout: layout))
        return files.map { .init(path: path + [$0.key], data: $0.value) } + [.init(path: path + [SongLibrary.songFileName], data: json ?? Data())]
    }
    let groove = smf([(0, 36), (96, 38), (192, 36), (288, 38)])
    let offbeatKicks = smf([(72, 36), (96, 38), (264, 36), (288, 38)])
    let fill = smf((0..<8).map { ($0 * 48, UInt8(38)) })
    let bassLine = BassPattern(events: [40, 40, 43, 45].enumerated().map {
        BassEvent(tick: Int32($0.offset * 480), note: $0.element, velocity: 100, durationTicks: 400) }, length: 1920)
    let bassFile = MIDIWriter.drumFile(PatternData(events: [], length: 1920), tempo: 120, signature: "4/4", bass: bassLine)
    let shaker = entries(["shaker_songs", "Eagles", "Hotel California"], "shaker songs › Eagles", "Hotel California",
                         Layout(parts: [.init(main: "Groove A.mid")]), ["Groove A.mid": smf((0..<8).map { ($0 * 48, UInt8(70)) })])
    let eng = DrumEngine()
    let lib = SongLibrary(store: eng.store)
    let r = lib.importFolder(
        entries(["BBS", "Ballad", "Ballad 2"], "\(BBSImport.packName) › Ballad", "Ballad 2",
                Layout(parts: [.init(main: "Part 1.mid", fills: ["Part 1 Fill 1.mid"]),
                               .init(main: "Part 2.mid", fills: ["Part 2 Fill 1.mid", "Part 2 Fill 2.mid"])]),
                ["Part 1.mid": groove, "Part 1 Fill 1.mid": fill, "Part 2.mid": offbeatKicks, "Part 2 Fill 1.mid": fill, "Part 2 Fill 2.mid": fill])
        + entries(["drum_songs", "Eagles", "Hotel California"], "drum songs › Eagles", "Hotel California",
                  Layout(parts: [.init(main: "Groove A.mid", bass: "Groove A Bass.mid")]), ["Groove A.mid": groove, "Groove A Bass.mid": bassFile])
        + shaker)
    let name = SongIndex.bbSongName(title: "Hotel California", beat: "Ballad 2")
    check(SongIndex.splitBBSongName(name) == ("Hotel California", "Ballad 2")
          && SongIndex.linkKey(genre: "bb songs › Eagles", name: name) == SongIndex.linkKey(genre: "drum songs › Eagles", name: "Hotel California")
          && SongIndex.bbSongKey(artist: "Eagles", title: "Hotel California", beat: "BALLAD 2") == SongIndex.bbSongKey(artist: "eagles", title: "hotel california", beat: "Ballad 2"),
          "a bb version links to its song by artist + title")
    if let beat = r.songs.first(where: { $0.name == "Ballad 2" }), let song = r.songs.first(where: { $0.name == "Hotel California" }),
       let l = lib.beat(beat, withBassAndPercussionOf: song) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pedalbeat-bbsong-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try lib.exportStoredSong(l, name: name, genre: "\(SongIndex.bbSongsPack) › Eagles", to: dir)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let bbEntries = try files.map { MIDIFolderImport.Entry(path: ["bb_songs", "Eagles", name, $0], data: try Data(contentsOf: dir.appendingPathComponent($0))) }
        // A fresh library, as on another machine: the bb version and the song's shaker only.
        let e2 = DrumEngine()
        let lib2 = SongLibrary(store: e2.store)
        let r2 = lib2.importFolder(bbEntries + shaker)
        if let v = r2.songs.first {
            let a = eng.store, b = e2.store
            func notes(_ st: SongStore, _ idx: Int32) -> [Int32] {
                guard idx >= 0 else { return [] }
                let p = st.patterns[Int(idx)]
                return (0..<Int(p.count)).map { st.events[Int(p.start) + $0].tick }
            }
            check(v.genre == "bb songs › Eagles" && v.name == name && v.partCount == 2
                  && (0..<2).map { b.fillCount(song: v.id, part: $0) } == [1, 2],
                  "bb version imports with the beat's parts and fills: \(v.genre) / \(v.name), \(v.partCount) parts")
            check((0..<2).allSatisfy { notes(a, a.partMain[l.id * SongStore.maxParts + $0]) == notes(b, b.partMain[v.id * SongStore.maxParts + $0]) },
                  "same drums as the layered beat")
            check((0..<2).allSatisfy { a.bassPattern(a.bass(song: l.id, part: $0))?.events == b.bassPattern(b.bass(song: v.id, part: $0))?.events },
                  "same bass per part (the song's where it fits, the generated one elsewhere), nothing generated on top")
            check(b.percussion(song: v.id, instrument: PercussionInstrument.shaker.rawValue) >= 0 && lib2.autoPercussion(for: v).isEmpty,
                  "the song's shaker plays with its bb version; no generated percussion")
        } else { check(false, "bb version imported: \(r2.skipped)") }
    } else { check(false, "layered beat for the bb version") }
    print("bb versions of songs checked")
} catch { check(false, "bb version tests threw \(error)") }

// 18. Installed content (macOS installers): song packs in a folder load at launch, a song or layer two packs
//     share loads once; installed kits are listed read-only, and the user's import of the same kit wins.
do {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("pedalbeat-installed-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    let songs = dir.appendingPathComponent("Songs"), kitsInstalled = dir.appendingPathComponent("Kits")
    try fm.createDirectory(at: songs, withIntermediateDirectories: true)
    try fm.createDirectory(at: kitsInstalled, withIntermediateDirectories: true)
    let bar = PatternData(events: [0, 960].map { SeqEvent(tick: Int32($0), drum: UInt8(Drum.kick.rawValue), velocity: 100) }, length: 1920)
    func song(_ name: String, _ genre: String, key: String) -> SongData {
        SongData(name: name, genre: genre, tempo: 100, timeSignature: "4/4", barTicks: 1920, beatTicks: 480,
                 intro: nil, parts: [PartData(main: bar, fill: nil)], transition: nil, outro: nil, key: key)
    }
    let shakerLayer = ContentPack.Layer(genre: "shaker songs › Eagles", name: "Hotel California",
        data: PercussionData(instrument: .shaker, parts: [PercussionPart(main: PatternData(
            events: [SeqEvent(tick: 0, drum: UInt8(Drum.shaker.rawValue), velocity: 90)], length: 1920))]))
    let midi = song("Hotel California", "drum songs › Eagles", key: ContentPack.keyPrefix + SongIndex.songKey(artist: "Eagles", title: "Hotel California"))
    let bbName = SongIndex.bbSongName(title: "Hotel California", beat: "Ballad 2")
    let bbKey = ContentPack.bbSongKey(genre: "bb songs › Eagles", name: bbName)
    let bb = song(bbName, "bb songs › Eagles", key: bbKey ?? "")
    check(bbKey != nil && bbKey != midi.key, "a bb version has a pack key of its own: \(bbKey ?? "nil")")
    try ContentPack.encode(.init(songs: [midi], percussion: [shakerLayer])).write(to: songs.appendingPathComponent("MIDI Songs.pbcp"))
    try ContentPack.encode(.init(songs: [bb], percussion: [shakerLayer])).write(to: songs.appendingPathComponent("bb Songs.pbcp"))
    try Data("not a pack".utf8).write(to: songs.appendingPathComponent("Read Me.txt"))
    let packs = ContentPack.installedPacks(in: songs)
    check(packs.map(\.lastPathComponent) == ["bb Songs.pbcp", "MIDI Songs.pbcp"], "installed packs by name: \(packs.map(\.lastPathComponent))")
    let eng = DrumEngine(), lib = SongLibrary(store: eng.store)
    let layersBefore = eng.store.percussionCountPublished      // the factory beats' generated percussion
    let loaded = packs.map { lib.loadContentPack(at: $0) }
    let again = lib.loadContentPack(at: packs[1])
    let added = eng.store.percussionCountPublished - layersBefore
    check(loaded == [1, 1] && again == 0 && added == 1,
          "both packs load, the shared shaker once, a pack loaded twice adds nothing: \(loaded) \(again), \(added) layers")
    let v = lib.songs.first { $0.name == bbName }, m = lib.songs.first { $0.genre == "drum songs › Eagles" }
    check(v.map { lib.percussion(for: $0) } == [.shaker] && m.map { lib.percussion(for: $0) } == [.shaker],
          "the shaker plays with the song's MIDI and bb version")
    check([v, m].allSatisfy { $0.map { !$0.isUser && $0.key.hasPrefix(ContentPack.keyPrefix) } == true }, "both are built-in pack songs")

    if let kit = kitFiles.first {
        let user = dir.appendingPathComponent("UserKits")
        try fm.copyItem(at: kit, to: kitsInstalled.appendingPathComponent(kit.lastPathComponent))
        let km = KitManager(engine: DrumEngine(), directory: user, installedDirectory: kitsInstalled)
        let id = km.kits.first?.id ?? ""
        check(km.kits.count == 1 && km.kits.first?.removable == false, "an installed kit is listed, read-only")
        km.remove(id: id)
        check(km.kits.count == 1 && fm.fileExists(atPath: kitsInstalled.appendingPathComponent(kit.lastPathComponent).path),
              "an installed kit can't be removed")
        _ = try km.importKit(from: kit)
        check(km.kits.count == 1 && km.kits.first?.removable == true, "the user's import of the same kit replaces it in the list")
        km.remove(id: id)
        check(km.kits.count == 1 && km.kits.first?.removable == false, "removing the import shows the installed kit again")
    } else { print("(no .pbkit files: installed-kit checks skipped)") }
    print("Installed content checked")
} catch { check(false, "installed content tests threw \(error)") }

// 15. Mixer voices: only what a song plays (its patterns), plus the accent crash and kick.
do {
    var allSeen = Set<Drum>()
    var fewer = 0
    for info in library.songs {
        let used = library.usedDrums(info)
        allSeen.formUnion(used)
        if used.count < Drum.count { fewer += 1 }
        guard info.id == library.songs.first?.id else { continue }
        let main = engine.store.patterns[Int(engine.store.partMain[info.id * SongStore.maxParts])]
        let inMain = Set((0..<Int(main.count)).compactMap { Drum(rawValue: Int(engine.store.events[Int(main.start) + $0].drum)) })
        check(inMain.isSubset(of: used) && used.contains(.crash) && used.contains(.kick),
              "mixer voices of \(info.name) hold its groove's drums and the accent \(used.map(\.displayName).sorted())")
    }
    check(fewer > 0, "some songs show fewer strips than the whole kit (\(fewer) of \(library.songs.count))")
    check(allSeen.contains(.snare) && allSeen.contains(.hatClosed), "the songs play snare and hi-hat somewhere")
    print("Mixer voices checked: \(fewer) of \(library.songs.count) songs show fewer than \(Drum.count) strips")
}

// Percussion-layer kits: a layer hit plays the layer kit's own sample, over a sampled drum kit
// (whose audio it must not read) and over a synth kit (no sampled drum kit at all).
do {
    let layerFiles = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "Extension/Resources/PercKits"),
                                                                    includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "pbkit" && $0.lastPathComponent.hasPrefix("pedalbeat.layer-") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let drumFile = kitFiles.first { $0.lastPathComponent.contains("cajon2") } ?? kitFiles.first
    if layerFiles.isEmpty { print("(no layer kits in Extension/Resources/PercKits: layer-kit checks skipped)") }
    let drumKit = try drumFile.map { try LoadedSampleKit(url: $0) }
    let n = 2048
    let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
    defer { l.deallocate(); r.deallocate() }
    for file in layerFiles {
        let layer = try LoadedSampleKit(url: file)
        let lk = layer.raw.pointee
        for drumBits in [drumKit?.bits ?? 0, 0] {
            for inst in PercussionInstrument.allCases {
                let d = inst.drum.rawValue
                let sd = lk.drums[d]
                guard sd.layerCount > 0 else { check(false, "\(layer.manifest.name) has \(inst.name)"); continue }
                let sampler = Sampler()
                sampler.setSampleRate(lk.sampleRate)   // step 1: the output is the region scaled by a constant
                sampler.setKit(bits: drumBits)
                sampler.setPercKit(bits: layer.bits)
                l.update(repeating: 0, count: n); r.update(repeating: 0, count: n)
                let played = sampler.triggerLayer(d, velocity: 1, delay: 0)
                sampler.render(left: l, right: r, frames: n)
                // Which of the instrument's regions matches the output (correlation ≈ 1)?
                var best = 0.0
                for li in 0..<Int(sd.layerCount) {
                    let lay = lk.layers[Int(sd.firstLayer) + li]
                    for ri in lay.first..<(lay.first + lay.count) {
                        let reg = lk.regions[ri], m = min(n, reg.length - 2)
                        var xy = 0.0, xx = 0.0, yy = 0.0
                        for i in 0..<m {
                            let x = Double(lk.audio[(reg.start + i) * 2]), y = Double(l[i])
                            xy += x * y; xx += x * x; yy += y * y
                        }
                        if xx > 0 && yy > 0 { best = max(best, xy / (xx * yy).squareRoot()) }
                    }
                }
                check(played && best > 0.999,
                      "\(layer.manifest.name) \(inst.name) plays its own sample over \(drumBits == 0 ? "a synth kit" : drumKit!.manifest.name) (correlation \(best))")
            }
        }
    }
    print("Percussion-layer kits checked: \(layerFiles.map(\.lastPathComponent))")
} catch { check(false, "layer-kit tests threw \(error)") }

// Shaker stack (ShakerStack): strokes, feel, lanes with their own sound, level and pan.
do {
    check(!ShakerStack.isBackStroke(tick: 0, dense: true) && ShakerStack.isBackStroke(tick: 120, dense: true)
          && !ShakerStack.isBackStroke(tick: 240, dense: true) && ShakerStack.isBackStroke(tick: 360, dense: true),
          "16ths: forward on the 8ths, back in between")
    check(!ShakerStack.isBackStroke(tick: 0, dense: false) && ShakerStack.isBackStroke(tick: 240, dense: false)
          && !ShakerStack.isBackStroke(tick: 480, dense: false), "8ths: forward on the beats, back on the ands")
    check(ShakerStack.isDense(ticks: [0, 240, 360]) && !ShakerStack.isDense(ticks: [0, 240, 480]), "16th detection")
    check(ShakerStack.feelTicks(tick: 480, feel: .push) == 0 && ShakerStack.feelTicks(tick: 120, feel: .push) == -12
          && ShakerStack.feelTicks(tick: 240, feel: .laidBack) > 7 && ShakerStack.feelTicks(tick: 120, feel: .grid) == 0,
          "feel moves off-beats only")
    check((0..<ShakerStack.laneCount).allSatisfy { lane in
        [ShakerStack.LaneParameter.source, .level, .pan].allSatisfy { kind in
            ShakerStack.lane(of: ShakerStack.address(lane: lane, kind)).map { $0.lane == lane && $0.kind == kind } == true
        }
    } && ShakerStack.lane(of: .shakerPocket) == nil, "lane parameters map both ways")

    let dir = URL(fileURLWithPath: "Extension/Resources/PercKits")
    let egg = try LoadedSampleKit(url: dir.appendingPathComponent("pedalbeat.layer-world.pbkit"))
    let strokes = try LoadedSampleKit(url: dir.appendingPathComponent("pedalbeat.shaker-virtuosity.pbkit"))
    check(strokes.manifest.isPercussionOnly && strokes.raw.pointee.upShaker.layerCount > 0, "Virtuosity has back strokes")
    let n = 8192
    let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
    defer { l.deallocate(); r.deallocate() }
    func energy(_ x: UnsafeMutablePointer<Float>) -> Double { (0..<n).reduce(0) { $0 + Double(x[$1] * x[$1]) } }
    func stack(_ sources: [ShakerSource], pans: [Float] = [0, 0, 0], levels: [Float] = [1, 1, 1], width: Float = 1,
               back: Bool = false, kits: [LoadedSampleKit?] = [nil, nil, nil]) -> Bool {
        let s = Sampler()
        s.setSampleRate(44100)
        s.laneSource = sources.map(\.rawValue); s.lanePan = pans; s.laneGain = levels; s.shakerWidth = width
        for (i, k) in kits.enumerated() { s.setLaneKit(i, bits: k?.bits ?? 0) }
        l.update(repeating: 0, count: n); r.update(repeating: 0, count: n)
        let played = s.triggerShaker(velocity: 1, delay: 0, back: back)
        s.render(left: l, right: r, frames: n)
        return played
    }
    // Two lanes panned apart (mono each): the egg only left, Virtuosity only right.
    let both = stack([.worldEgg, .virtuosity, .off], pans: [-1, 1, 0], width: 0, kits: [egg, strokes, nil])
    let (bl, br) = (energy(l), energy(r))
    _ = stack([.worldEgg, .off, .off], pans: [-1, 1, 0], width: 0, kits: [egg, strokes, nil])
    check(both && bl > 0 && br > 0 && energy(r) == 0 && abs(energy(l) - bl) < bl * 1e-6,
          "two lanes play at once, each on its side; lane 2 off silences the right")
    _ = stack([.worldEgg, .off, .off], levels: [0.5, 1, 1], kits: [egg, nil, nil])
    let half = energy(l)
    _ = stack([.worldEgg, .off, .off], kits: [egg, nil, nil])
    check(abs(half / energy(l) - 0.25) < 0.01, "lane level scales the lane: \(half / energy(l))")
    // Strokes: a back stroke plays one of the back-stroke takes, a forward stroke one of the forward ones.
    func matches(_ d: SDrum, _ k: SampleKitRaw) -> Double {
        var best = 0.0
        for li in 0..<d.layerCount {
            let lay = k.layers[d.firstLayer + li]
            for ri in lay.first..<(lay.first + lay.count) {
                let reg = k.regions[ri], m = min(n, reg.length - 2)
                var xy = 0.0, xx = 0.0, yy = 0.0
                for i in 0..<m { let x = Double(k.audio[(reg.start + i) * 2]), y = Double(l[i]); xy += x * y; xx += x * x; yy += y * y }
                if xx > 0 && yy > 0 { best = max(best, xy / (xx * yy).squareRoot()) }
            }
        }
        return best
    }
    let raw = strokes.raw.pointee
    _ = stack([.virtuosity, .off, .off], back: true, kits: [strokes, nil, nil])
    let backTake = (matches(raw.upShaker, raw), matches(raw.drums[Drum.shaker.rawValue], raw))
    _ = stack([.virtuosity, .off, .off], back: false, kits: [strokes, nil, nil])
    let fwdTake = (matches(raw.upShaker, raw), matches(raw.drums[Drum.shaker.rawValue], raw))
    check(backTake.0 > 0.999 && backTake.1 < 0.9 && fwdTake.1 > 0.999 && fwdTake.0 < 0.9,
          "back strokes play back-stroke takes, forward strokes forward ones: \(backTake) \(fwdTake)")
    _ = stack([.worldEgg, .off, .off], back: true, kits: [egg, nil, nil])
    check(energy(l) > 0, "a kit without back strokes plays its shaker for them")
    check(stack([.off, .off, .off]) && energy(l) == 0, "every lane off: silence, no synth shaker")
    check(!stack([.worldEgg, .off, .off]), "a lane whose kit is still loading lets the synth stand in")
    print("Shaker stack checked")
} catch { check(false, "shaker stack tests threw \(error)") }

print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
