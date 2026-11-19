import Foundation

// Converts a .BBS SD card / project folder into PedalBeat song folders:
//   <out>/<Genre>/<NN Song>/Intro.mid, Part 1.mid, Part 1 Fill 1.mid, …, song.json
// Importing <out> (or the source folder itself) with folder import gives the same songs.
//
//   swiftc -O Core/*.swift Tools/BBSongExport/main.swift -o build/bbsongexport
//   ./build/bbsongexport <content folder> bbsongs

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: bbsongexport <.BBS content folder> <output folder>")
    exit(2)
}
let source = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
guard let songsDir = BBSImport.songsFolder(in: source) else {
    print("No SONGS/config.csv found in \(source.path)")
    exit(1)
}
let r = BBSImport.entries(songsFolder: songsDir)
let fm = FileManager.default
var songs = 0
for e in r.entries {
    // Entry paths are ["BBS", genre, song, file]; the pack folder is dropped here.
    let rel = e.path.dropFirst()
    let url = rel.reduce(out) { $0.appendingPathComponent($1) }
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try e.data.write(to: url, options: .atomic)
    if e.path.last == SongLibrary.songFileName { songs += 1 }
}
print("Wrote \(songs) songs (\(r.entries.count) files) to \(out.path)")
if !r.failed.isEmpty { print("Failed: \(r.failed.joined(separator: ", "))"); exit(1) }
