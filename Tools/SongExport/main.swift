import Foundation

// Exports the factory songs as MIDI files:
//   songs/<Genre>/<NN Title>/{Intro, Groove A…, Groove A Fill 1…, Transition, Ending}.mid + song.json
// Import the folder in PedalBeat (Import MIDI, Folder or Kit…) to get the same songs back.
//
//   swiftc -O Core/*.swift Core/*/*.swift Tools/SongExport/main.swift -o build/songexport && ./build/songexport songs

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "songs", isDirectory: true)
let library = SongLibrary(store: SongStore())
let songs = library.visibleSongs.filter { !$0.isUser }
do {
    let n = try library.exportSongs(songs, to: out)
    let files = (FileManager.default.enumerator(at: out, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "mid" }
    print("Exported \(n) songs (\(files.count) MIDI files) in \(Set(songs.map(\.genre)).count) genres to \(out.path)")
} catch {
    FileHandle.standardError.write("Export failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
