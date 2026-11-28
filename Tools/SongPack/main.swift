import Foundation

// Builds a song pack (Core/ContentPack.swift) from a folder: the MIDI Songs pack from
// pedalbeat-data/build/songpack, the bb Songs pack from what Tools/BBSongs writes.
//
//   drum_songs/<Artist>/<Title>/      the song's own drums, its bass lines and song.json
//   bb_songs/<Artist>/<Title · Beat>/ a song's bb version (beat + the song's bass)
//   shaker_songs/ tambourine_songs/ clap_songs/<Artist>/<Title>/   its percussion layers
//   <any folder>/<Genre>/<NN Beat>/   bb beats (song.json with group "BBS › Genre"), as built-in beats
//
// Every file goes through the app's own import code (MIDIFolderImport, MIDIDrumFile, makeSong,
// PercussionData), so the pack plays exactly like an import of that folder would.
//
// Optionally also the bb beats of a SONGS folder (BBSImport), as built-in beats "BBS › Genre":
// they show in the Beats tab and give the Songs tab its beats, so nothing has to be imported.
//
//   songpack <songpack_dir> <out.pbcp> [<bb SONGS folder>]

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4 else {
    print("usage: songpack <songpack_dir> <out.pbcp> [<bb SONGS folder>]")
    exit(2)
}
let root = URL(fileURLWithPath: args[1]).standardizedFileURL
let outURL = URL(fileURLWithPath: args[2])

// 1. Read the folder like the app's folder import (paths start at "drum_songs", "shaker_songs", …).
var entries: [MIDIFolderImport.Entry] = []
let base = root.pathComponents.count
guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
    print("can't read \(root.path)")
    exit(1)
}
for case let f as URL in en where ["mid", "midi"].contains(f.pathExtension.lowercased())
    || f.lastPathComponent.lowercased() == SongLibrary.songFileName {
    guard let d = try? Data(contentsOf: f) else { continue }
    entries.append(.init(path: Array(f.standardizedFileURL.pathComponents.dropFirst(base)), data: d))
}
let plan = MIDIFolderImport.plan(entries)

// 2. Build songs and layers.
var songs: [SongData] = []
var layers: [ContentPack.Layer] = []
var seen = Set<String>()
var problems: [String] = []
var bassFiles = 0, bassFilesRead = 0
for g in plan.groups {
    let files = g.files.compactMap { try? MIDIDrumFile(data: $0.data, name: $0.name) }
    if files.count != g.files.count { problems.append("\(g.genre)/\(g.name): \(g.files.count - files.count) unreadable files") }
    guard let layout = g.layout ?? MIDISongImporter.layout(for: files) else { problems.append("\(g.genre)/\(g.name): no layout"); continue }
    if let (inst, _) = PercussionInstrument.layer(genre: g.genre, name: g.name) {
        guard let data = PercussionData.make(files: files, layout: layout, instrument: inst) else {
            problems.append("\(g.genre)/\(g.name): no \(inst.name.lowercased()) notes"); continue
        }
        layers.append(.init(genre: g.genre, name: g.name, data: data))
        continue
    }
    if g.genre.hasPrefix(BBSImport.packName + " › ") {
        let key = ContentPack.beatKey(genre: g.genre, name: g.name)
        guard seen.insert(key).inserted else { problems.append("\(g.genre)/\(g.name): duplicate beat"); continue }
        guard var beat = MIDISongImporter.makeSong(name: g.name, files: files, layout: layout, key: key, genre: g.genre) else {
            problems.append("\(g.genre)/\(g.name): no beat"); continue
        }
        beat.isUser = false
        songs.append(beat)
        continue
    }
    guard let link = SongIndex.linkKey(genre: g.genre, name: g.name) else { problems.append("\(g.genre)/\(g.name): not a song pack folder"); continue }
    let key = ContentPack.bbSongKey(genre: g.genre, name: g.name) ?? ContentPack.keyPrefix + link
    guard seen.insert(key).inserted else { problems.append("\(g.genre)/\(g.name): duplicate of an earlier song"); continue }
    // Every bass file named in the layout must read back as a bass line.
    let named = layout.parts.compactMap(\.bass) + layout.parts.flatMap { ($0.fillBass ?? []).filter { !$0.isEmpty } }
        + [layout.introBass, layout.transitionBass, layout.outroBass].compactMap { $0 }
    for n in named {
        bassFiles += 1
        if files.first(where: { $0.name == n })?.bass != nil { bassFilesRead += 1 } else { problems.append("\(g.genre)/\(g.name): \(n) has no bass") }
    }
    guard var song = MIDISongImporter.makeSong(name: g.name, files: files, layout: layout, key: key, genre: g.genre) else {
        problems.append("\(g.genre)/\(g.name): no song"); continue
    }
    song.isUser = false
    songs.append(song)
}

// 2b. bb beats (optional): converted like the app's .BBS import, stored as built-in beats.
if args.count == 4 {
    let bbs = BBSImport.entries(songsFolder: URL(fileURLWithPath: args[3]))
    problems += bbs.failed.map { "bb: \($0)" }
    for g in MIDIFolderImport.plan(bbs.entries).groups {
        let files = g.files.compactMap { try? MIDIDrumFile(data: $0.data, name: $0.name) }
        guard let layout = g.layout ?? MIDISongImporter.layout(for: files) else { problems.append("\(g.genre)/\(g.name): no layout"); continue }
        let key = ContentPack.beatKey(genre: g.genre, name: g.name)
        guard seen.insert(key).inserted else { problems.append("\(g.genre)/\(g.name): duplicate beat"); continue }
        guard var beat = MIDISongImporter.makeSong(name: g.name, files: files, layout: layout, key: key, genre: g.genre) else {
            problems.append("\(g.genre)/\(g.name): no beat"); continue
        }
        beat.isUser = false
        songs.append(beat)
    }
}

// 3. Write, then read back and load into a fresh library like the plug-in does.
let data = ContentPack.encode(.init(songs: songs, percussion: layers))
try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try data.write(to: outURL, options: .atomic)

let t0 = Date()
let back = try ContentPack.decode(try Data(contentsOf: outURL))
let decodeMS = Date().timeIntervalSince(t0) * 1000
let engine = DrumEngine()
let library = SongLibrary(store: engine.store)
let t1 = Date()
let loaded = library.loadContentPack(at: outURL)
let loadMS = Date().timeIntervalSince(t1) * 1000
let store = engine.store
let events = (0..<store.patternCountPublished).reduce(0) { $0 + Int(store.patterns[$1].count) }
let packSongs = back.songs.filter { !$0.key.hasPrefix(ContentPack.beatKeyPrefix) }
let withBass = packSongs.filter { $0.parts.contains { $0.bass != nil } }.count
let withFillBass = back.songs.filter { $0.parts.contains { $0.fillBass.contains { $0 != nil } } }.count
let fillBassLines = back.songs.reduce(0) { $0 + $1.parts.reduce(0) { $0 + $1.fillBass.compactMap { $0 }.count } }
let withPerc = library.songs.filter { !library.percussion(for: $0).isEmpty }.count
var perInst: [String: Int] = [:]
for l in back.percussion { perInst[l.data.instrument.name, default: 0] += 1 }

print("""
Song pack \(outURL.path)
  \(String(format: "%.1f", Double(data.count) / 1_000_000)) MB, \(packSongs.count) songs (\(withBass) with bass), \(back.songs.count - packSongs.count) bb beats, \
\(back.percussion.count) percussion layers \(perInst.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
  bass files read back: \(bassFilesRead) of \(bassFiles); fill bass: \(fillBassLines) fills in \(withFillBass) songs
  loaded \(loaded) songs, \(withPerc) of them with percussion; decode \(Int(decodeMS)) ms, load into the library \(Int(loadMS)) ms
  store after factory + pack: \(events) of \(store.eventCapacity) drum events, \(store.patternCountPublished) of \(store.patternCapacity) patterns, \
\(store.count) songs, \(store.percussionCountPublished) percussion layers
""")
if !problems.isEmpty {
    print("  \(problems.count) notes:")
    for p in problems.prefix(30) { print("    - \(p)") }
}
exit(back.songs.count == songs.count && back.percussion.count == layers.count && loaded == songs.count ? 0 : 1)
