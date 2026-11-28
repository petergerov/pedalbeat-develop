import Foundation

// Writes the songs' bb versions as song folders, for the bb Songs installer:
//
//   bb_songs/<Artist>/<Title · Beat>/     the bb beat the song index matches the song to, exactly
//                                         as it is (intro, parts, fills, transition, ending), with the
//                                         song's bass on top where it fits, else a line generated from the
//                                         beat's kick (SongLibrary.beat(_:withBassAndPercussionOf:))
//   shaker_songs/ tambourine_songs/ clap_songs/<Artist>/<Title>/   the song's percussion layers, copied
//
// The input is what the app has: the song folder the song pack is built from (drum_songs with bass,
// the percussion folders) and the bb beats (decoded: <Genre>/<NN Beat>/song.json, or a SONGS
// folder of .BBS files). Every file goes through the app's own import and export code, and the result
// is imported again to check it.
//
//   bbsongs <bb beats folder> <songpack_dir> <out_dir>

let args = CommandLine.arguments
guard args.count == 4 else {
    print("usage: bbsongs <bb beats folder> <songpack_dir> <out_dir>")
    exit(2)
}
let beatsURL = URL(fileURLWithPath: args[1]).standardizedFileURL
let packURL = URL(fileURLWithPath: args[2]).standardizedFileURL
let outURL = URL(fileURLWithPath: args[3]).standardizedFileURL
let fm = FileManager.default

/// MIDI files and song.json files under `root`, with paths starting below `base` (like the folder import).
func entries(_ root: URL, base: URL) -> [MIDIFolderImport.Entry] {
    let skip = base.pathComponents.count
    var out: [MIDIFolderImport.Entry] = []
    guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
    for case let f as URL in en where ["mid", "midi"].contains(f.pathExtension.lowercased())
        || f.lastPathComponent.lowercased() == SongLibrary.songFileName {
        guard let d = try? Data(contentsOf: f) else { continue }
        out.append(.init(path: Array(f.standardizedFileURL.pathComponents.dropFirst(skip)), data: d))
    }
    return out
}

// 1. The songs with their bass and percussion, then the bb beats, into one library.
let library = SongLibrary(store: DrumEngine().store)
let songResult = library.importFolder(entries(packURL, base: packURL))
let beatEntries: [MIDIFolderImport.Entry]
if let songs = BBSImport.songsFolder(in: beatsURL) {
    beatEntries = BBSImport.entries(songsFolder: songs).entries
} else {
    beatEntries = entries(beatsURL, base: beatsURL.deletingLastPathComponent())
}
_ = library.importFolder(beatEntries)

var beats: [String: SongInfo] = [:], own: [String: SongInfo] = [:]
for s in library.songs {
    let parts = s.genre.components(separatedBy: " › ")
    if parts.first == BBSImport.packName, parts.count >= 2 { beats[SongIndex.normalize(s.name)] = beats[SongIndex.normalize(s.name)] ?? s }
    if parts.count >= 2, SongIndex.normalize(parts[0]) == SongIndex.normalize(SongIndex.songDrumsPack) {
        own[SongIndex.songKey(artist: parts.dropFirst().joined(separator: " "), title: s.name)] = s
    }
}
print("read \(own.count) songs, \(songResult.percussion.values.reduce(0, +)) percussion layers, \(beats.count) bb beats")

// Percussion folders by song (link key), to copy next to the songs that use them.
var percFolders: [String: [String]] = [:]   // link → relative folder paths
for inst in PercussionInstrument.allCases {
    let dir = packURL.appendingPathComponent(inst.pack.replacingOccurrences(of: " ", with: "_"))
    guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
    for case let f as URL in en where f.lastPathComponent == SongLibrary.songFileName {
        guard let sf = try? JSONDecoder().decode(SongLibrary.SongFile.self, from: Data(contentsOf: f)),
              let link = SongIndex.linkKey(genre: sf.genre, name: sf.name) else { continue }
        let rel = f.deletingLastPathComponent().standardizedFileURL.pathComponents.dropFirst(packURL.pathComponents.count)
        percFolders[link, default: []].append(rel.joined(separator: "/"))
    }
}

// 2. Every song-index entry whose beat is a bb beat and whose song has its own bass or percussion.
try? fm.removeItem(at: outURL)
try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
var written = Set<String>(), links = Set<String>()
var noLayer = 0, meter = 0, parts = 0, generated = 0
for e in SongIndex.entries {
    guard let beat = beats[SongIndex.normalize(e.style)],
          let song = own[SongIndex.songKey(artist: e.artist, title: e.title)] else { continue }
    let artist = song.genre.components(separatedBy: " › ").dropFirst().joined(separator: " › ")
    let key = SongIndex.bbSongKey(artist: artist, title: song.name, beat: beat.name)
    guard written.insert(key).inserted else { continue }
    guard let layered = library.beat(beat, withBassAndPercussionOf: song) else {
        if library.percussion(for: song).isEmpty && !song.hasBass { noLayer += 1 } else { meter += 1 }
        written.remove(key)
        continue
    }
    let name = SongIndex.bbSongName(title: song.name, beat: beat.name)
    let folder = outURL.appendingPathComponent("bb_songs", isDirectory: true)
        .appendingPathComponent(SongLibrary.safeFileName(artist), isDirectory: true)
        .appendingPathComponent(SongLibrary.safeFileName(name), isDirectory: true)
    try library.exportStoredSong(layered, name: name, genre: "\(SongIndex.bbSongsPack) › \(artist)", to: folder)
    parts += layered.partCount
    generated += library.generatedBassParts(layered)
    if let link = SongIndex.linkKey(genre: song.genre, name: song.name) { links.insert(link) }
}

// 3. The percussion of those songs.
var percCopied = 0
for link in links.sorted() {
    for rel in percFolders[link] ?? [] {
        let dst = outURL.appendingPathComponent(rel, isDirectory: true)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: packURL.appendingPathComponent(rel, isDirectory: true), to: dst)
        percCopied += 1
    }
}

// 4. Import the result into a fresh library, like a user would (the folder picked as a whole).
let check = SongLibrary(store: DrumEngine().store)
let r = check.importFolder(entries(outURL, base: outURL.deletingLastPathComponent()))
let bbSongs = r.songs.filter { $0.genre.hasPrefix(SongIndex.bbSongsPack + " › ") }
let withPerc = bbSongs.filter { !check.percussion(for: $0).isEmpty }.count
print("""
bb versions \(outURL.path)
  \(written.count) songs (\(links.count) different songs), \(parts) parts: \(parts - generated) with the song's bass, \(generated) generated
  skipped: \(noLayer) songs without bass or percussion, \(meter) with another meter than their beat
  \(percCopied) percussion layers copied
  import check: \(bbSongs.count) songs in \(Set(bbSongs.map(\.genre)).count) groups, \(bbSongs.filter(\.hasBass).count) with bass, \(withPerc) with percussion, \(r.skipped.count) skipped
""")
if bbSongs.count != written.count || !r.skipped.isEmpty {
    print("import check failed: \(r.skipped.prefix(10))")
    exit(1)
}
