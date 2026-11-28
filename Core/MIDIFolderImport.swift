import Foundation

/// Turns a folder tree of MIDI drum files (as sold in typical loop packs:
/// Pack / Style / Song-or-Tempo / Section files) into browser groups and songs.
///
///   Pack/Rock/Straight 120/Verse 1.mid   -> group "Pack › Rock", song "Straight 120"
///   Pack/Rock/Rock Straight Verse 1.mid  -> group "Pack › Rock", song "Rock Straight" (by name + tempo)
///   Pack/Verse 1.mid                     -> group "Pack", song "Pack"
public enum MIDIFolderImport {
    /// A MIDI file with its path relative to the parent of the imported folder,
    /// e.g. ["My Pack", "Rock", "Straight 120", "Verse 1.mid"].
    public struct Entry: Sendable {
        public var path: [String]
        public var data: Data
        public init(path: [String], data: Data) { self.path = path; self.data = data }
    }

    /// One song to build: files are in natural name order.
    public struct Group: Sendable {
        public var genre: String
        public var name: String
        public var files: [SongLibrary.ImportedFile]
        /// Exact layout from a `song.json` exported by PedalBeat (nil = from file names).
        public var layout: MIDISongImporter.SongLayout? = nil
    }

    public struct Plan: Sendable {
        public var groups: [Group]
        public var skipped: [String]   // files that are not usable drum MIDI
    }

    // MARK: Name analysis

    /// Words that describe a section or variation rather than the groove itself.
    static let sectionWords: Set<String> = [
        "intro", "count", "countin", "in", "verse", "vs", "vrs", "pre", "prechorus", "chorus", "chr", "ch",
        "bridge", "brg", "br", "solo", "break", "breakdown", "fill", "fills", "trans", "transition", "outro",
        "ending", "end", "main", "part", "section", "bass", "bassline", "basslines",
        "crash", "hit", "hits", "build", "buildup", "drop", "var", "variation", "alt", "bpm", "midi", "mid",
        "a", "b", "c", "d", "e", "v", "x", "and", "with", "w", "the", "gm",
    ]

    /// Splits a file or folder name into words: separators, camelCase and letter/digit boundaries.
    static func words(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        var prev: Character?
        for ch in s {
            let boundary: Bool = {
                guard let p = prev else { return false }
                if !(ch.isLetter || ch.isNumber) { return true }
                if p.isLetter && ch.isNumber || p.isNumber && ch.isLetter { return true }
                if p.isLowercase && ch.isUppercase { return true }
                return false
            }()
            if boundary, !cur.isEmpty { out.append(cur); cur = "" }
            if ch.isLetter || ch.isNumber { cur.append(ch) }
            prev = ch
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func stem(_ filename: String) -> (key: String, pretty: String) {
        let base = (filename as NSString).deletingPathExtension
        let kept = words(base).filter { w in
            !w.allSatisfy(\.isNumber) && !sectionWords.contains(w.lowercased())
        }
        return (kept.map { $0.lowercased() }.joined(separator: " "), kept.joined(separator: " "))
    }

    /// Tempo written in a name: "120bpm", "bpm 96", or a lone 3-digit number like "_120_".
    static func tempoInName(_ name: String) -> Int? {
        let w = words((name as NSString).deletingPathExtension).map { $0.lowercased() }
        for (i, t) in w.enumerated() where t == "bpm" {
            if i > 0, let v = Int(w[i - 1]), (40...300).contains(v) { return v }
            if i + 1 < w.count, let v = Int(w[i + 1]), (40...300).contains(v) { return v }
        }
        return w.first { $0.count == 3 && Int($0).map { (60...240).contains($0) } == true }.flatMap { Int($0) }
    }

    static func pretty(_ folder: String) -> String {
        let s = folder.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? folder : s
    }

    // MARK: Planning

    public static func plan(_ entries: [Entry]) -> Plan {
        var skipped: [String] = []
        struct Parsed { var entry: Entry; var file: MIDIDrumFile }
        var byDir: [[String]: [Parsed]] = [:]
        var dirOrder: [[String]] = []
        var songFiles: [[String]: SongLibrary.SongFile] = [:]
        for e in entries where !e.path.isEmpty {
            let name = e.path.last!
            if name.lowercased() == SongLibrary.songFileName {
                if let sf = try? JSONDecoder().decode(SongLibrary.SongFile.self, from: e.data) { songFiles[Array(e.path.dropLast())] = sf }
                continue
            }
            guard let f = try? MIDIDrumFile(data: e.data, name: name) else { skipped.append(e.path.joined(separator: "/")); continue }
            let dir = Array(e.path.dropLast())
            if byDir[dir] == nil { dirOrder.append(dir) }
            byDir[dir, default: []].append(Parsed(entry: e, file: f))
        }
        dirOrder.sort { $0.joined(separator: "/").localizedStandardCompare($1.joined(separator: "/")) == .orderedAscending }

        var groups: [Group] = []
        for dir in dirOrder {
            let files = byDir[dir]!
            let pack = dir.first.map(pretty) ?? "Imported"
            let genre = dir.count >= 2 ? "\(pack) › \(pretty(dir[1]))" : pack
            let folderSong = dir.count >= 3 ? dir[2...].map(pretty).joined(separator: " ") : ""

            // A song exported by PedalBeat: one song with its exact layout.
            if let sf = songFiles[dir] {
                let sorted = files.sorted { $0.entry.path.last!.localizedStandardCompare($1.entry.path.last!) == .orderedAscending }
                // Converted .BBS songs keep their "BBS › Genre" group wherever the folder lives,
                // so the song index finds them and re-imports from another copy add nothing new.
                // So do a song's own drums and percussion ("drum songs › Artist", "shaker songs › Artist"),
                // which are matched to the song by that group, also when their parent folder is imported.
                let keepGroup = sf.genre.hasPrefix(BBSImport.packName + " › ")
                    || SongIndex.linkKey(genre: sf.genre, name: sf.name) != nil
                groups.append(Group(genre: keepGroup ? sf.genre : genre, name: sf.name,
                                    files: sorted.map { .init(name: $0.entry.path.last!, data: $0.entry.data) },
                                    layout: sf.layout))
                continue
            }

            // Cluster by groove name (sections/numbers removed) and tempo.
            var clusters: [String: [Parsed]] = [:]
            var clusterOrder: [String] = []
            var prettyName: [String: String] = [:]
            for p in files {
                let st = stem(p.entry.path.last!)
                let tempo = p.file.tempo.map { Int($0.rounded()) } ?? tempoInName(p.entry.path.last!) ?? 0
                let key = "\(st.key)|\(tempo)|\(p.file.signature)"
                if clusters[key] == nil { clusterOrder.append(key); prettyName[key] = st.pretty }
                clusters[key, default: []].append(p)
            }
            // Same name at several tempos: show the tempo.
            let stems = clusterOrder.map { $0.components(separatedBy: "|")[0] }
            for key in clusterOrder {
                let parts = key.components(separatedBy: "|")
                let stemName = prettyName[key] ?? ""
                var name: String
                if clusterOrder.count == 1 {
                    name = !folderSong.isEmpty ? folderSong : (!stemName.isEmpty ? stemName : pretty(dir.last ?? pack))
                } else {
                    name = stemName.isEmpty ? "Groove" : stemName
                    if !folderSong.isEmpty { name = "\(folderSong) – \(name)" }
                    if stems.filter({ $0 == parts[0] }).count > 1, let t = Int(parts[1]), t > 0 { name += " \(t) BPM" }
                }

                let members = clusters[key]!.sorted {
                    $0.entry.path.last!.localizedStandardCompare($1.entry.path.last!) == .orderedAscending
                }
                // More than 8 grooves: split into several songs of up to 8 parts.
                let mains = members.filter { MIDISongImporter.role(for: $0.file) == .main }
                let fills = members.filter { MIDISongImporter.role(for: $0.file) == .fill }
                let shared = members.filter {
                    let r = MIDISongImporter.role(for: $0.file)
                    return r != .main && r != .fill
                }
                let chunks = max(1, Int((Double(mains.count) / Double(SongStore.maxParts)).rounded(.up)))
                for c in 0..<chunks {
                    var chunkFiles: [Parsed]
                    if chunks == 1 { chunkFiles = members } else {
                        let lo = c * SongStore.maxParts, hi = min(mains.count, lo + SongStore.maxParts)
                        let fillShare = fills.count >= mains.count
                            ? Array(fills[min(lo, fills.count)..<min(hi, fills.count)])
                            : fills
                        chunkFiles = Array(mains[lo..<hi]) + fillShare + shared
                    }
                    groups.append(Group(genre: genre, name: chunks == 1 ? name : "\(name) \(c + 1)",
                                        files: chunkFiles.map { .init(name: $0.entry.path.last!, data: $0.entry.data) }))
                }
            }
        }
        return Plan(groups: groups, skipped: skipped)
    }
}
