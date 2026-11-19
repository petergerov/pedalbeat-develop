import Foundation

/// A searchable index of popular songs with their
/// tempo and the kind of beat that fits. Each song points at an original PedalBeat
/// factory groove with the same feel; loading it selects that groove at the song's tempo.
public enum SongIndex {
    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: Int
        public let title: String
        public let artist: String
        public let bpm: Double
        /// Genre of the song (Rock, Country, …).
        public let genre: String
        /// The beat style the song was matched to, e.g. "Pop 10- 8ths".
        public let style: String
        /// The PedalBeat groove that plays it.
        public let target: Target
        fileprivate let searchText: String
        fileprivate let titleText: String
    }

    /// A factory groove: the genre group and the groove name ("Rock" / "Straight Eights").
    public struct Target: Hashable, Sendable {
        public let genre: String
        public let groove: String
        public var label: String { "\(genre) · \(groove)" }
    }

    public static let entries: [Entry] = parse(rawData)

    /// Genres, most songs first.
    public static let genres: [String] = {
        var count: [String: Int] = [:]
        for e in entries { count[e.genre, default: 0] += 1 }
        return count.keys.sorted { count[$0]! != count[$1]! ? count[$0]! > count[$1]! : $0 < $1 }
    }()

    // MARK: Search

    /// Songs matching every word of the query in title or artist, best matches first.
    public static func search(_ query: String, limit: Int = 200) -> [Entry] {
        let words = normalize(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let q = words.joined(separator: " ")
        var scored: [(Int, Entry)] = []
        for e in entries where words.allSatisfy({ e.searchText.contains($0) }) {
            let score: Int
            if e.titleText == q { score = 0 }
            else if e.titleText.hasPrefix(q) { score = 1 }
            else if e.titleText.contains(q) { score = 2 }
            else if e.searchText.hasPrefix(q) || e.searchText.contains(" " + q) { score = 3 }
            else { score = 4 }
            scored.append((score, e))
        }
        scored.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.id < $1.1.id }
        return scored.prefix(limit).map(\.1)
    }

    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let mapped = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    // MARK: Beat style -> PedalBeat groove

    /// Every beat style used by the index, mapped to the closest
    /// original groove (same meter, subdivision and swing).
    static let styleMap: [String: Target] = {
        let m: [(String, String, String)] = [
            // Rock
            ("Rock 1", "Rock", "Straight Eights"),
            ("Rock 2", "Rock", "Driving"),
            ("Rock 3", "Rock", "Slow Burn"),
            ("Rock 4", "Rock", "Sixteenth Hats"),
            ("Rock 5- Jungle Toms", "Rock", "Tom Pulse"),
            ("Rock 6- Jungle Toms", "Rock", "Tom Pulse"),
            ("Rock 14- Jungle Toms", "Rock", "Tom Pulse"),
            ("Rock 7", "Rock", "Heartland"),
            ("Rock 8", "Rock", "Two-Bar Push"),
            ("Rock 9", "Rock", "Floor Stomp"),
            ("Rock 10", "Rock", "Driving"),
            ("Rock 11", "Rock", "Sixteenth Hats"),
            ("Rock 12", "Hard Rock & Metal", "Arena"),
            ("Pop-Rock Str8", "Rock", "Straight Eights"),
            ("In my place", "Rock", "Slow Burn"),
            ("Marching 9", "Rock", "Straight Eights"),
            ("Tango", "Rock", "Floor Stomp"),
            // Pop
            ("Pop 1- 16ths", "Pop", "Radio"),
            ("Pop 2- 16ths", "Pop", "Bounce"),
            ("Pop 4- 16ths", "Pop", "Synth Pop"),
            ("Pop 5- 16ths", "Pop", "Radio"),
            ("Pop 11- 16ths", "Pop", "Synth Pop"),
            ("Pop 6- 8ths", "Pop", "Anthem"),
            ("Pop 7- anticipated 1", "Pop", "Radio"),
            ("Pop 8- 8ths", "Pop", "Acoustic Pop"),
            ("Pop 9- 8ths", "Disco & Soul", "Motown"),
            ("Pop 10- 8ths", "Pop", "Anthem"),
            ("Pop 12- 8ths", "Rock", "Straight Eights"),
            // Ballads
            ("Ballad 1", "Rock", "Slow Burn"),
            ("Ballad 2", "Pop", "Ballad Sidestick"),
            ("Ballad 3", "Rock", "Slow Burn"),
            ("Ballad 6", "Pop", "Acoustic Pop"),
            ("Ballad 8", "Pop", "Acoustic Pop"),
            ("Ballad 13", "Pop", "Ballad Sidestick"),
            ("Wonderful World", "Blues", "Slow Twelve-Eight"),
            // Blues: shuffles, 6/8 and 12/8
            ("Blues 1", "Blues", "Shuffle"),
            ("Blues 2", "Blues", "Texas Shuffle"),
            ("Blues 3- 6/8", "Waltz & Triple", "Slow Six-Eight"),
            ("Blues 4- 6/8", "Waltz & Triple", "Six-Eight Rock"),
            ("Blues 5- 6/8", "Folk & Acoustic", "Six-Eight Ballad"),
            ("Blues 6- 6/8", "Waltz & Triple", "Six-Eight Rock"),
            ("Blues 7- 6/8", "Waltz & Triple", "Slow Six-Eight"),
            ("Blues 8- 12/8", "Blues", "Slow Twelve-Eight"),
            ("Blues 10- 12/8", "Blues", "Chicago"),
            ("Odd Time 3- 6/8", "Waltz & Triple", "Six-Eight Rock"),
            // Oldies
            ("Oldie 1- 4 on snare", "Disco & Soul", "Northern Stomp"),
            ("Oldie 2- 4 on snare", "Disco & Soul", "Northern Stomp"),
            ("Oldie 3- 4 on snare", "Disco & Soul", "Northern Stomp"),
            ("Oldie Song 4- Bum cha ka", "Country", "Boom Chick"),
            ("Oldie 5- Bum cha ka more", "Country", "Boom Chick"),
            ("Oldie 6", "Punk", "Garage"),
            ("Polka", "Country", "Boom Chick"),
            // Country
            ("Country 1- Shuffle", "Country", "Country Shuffle"),
            ("Country 2- Train Shuffle", "Country", "Train"),
            ("Country 3- 2nd line beat", "Funk", "Strut"),
            ("Country 4- Shuffle", "Country", "Country Shuffle"),
            ("Country 5- Brushes Train", "Country", "Train"),
            ("Country 6- Str 8", "Country", "Two-Step"),
            ("Country 7- Brushes Shuffle", "Country", "Country Shuffle"),
            ("Country 8- Str 8", "Country", "Modern Country"),
            // Brushes
            ("Brushes 1- Str 8", "Folk & Acoustic", "Shaker Groove"),
            ("Brushes 2- Str 16ths", "Pop", "Acoustic Pop"),
            ("Brushes 3- Half time shuffle", "Gospel & Shuffle", "Half-Time Shuffle"),
            ("Brushes 5- 3/4 Half time Shuffle Pop", "Jazz", "Jazz Waltz"),
            ("Brushes 8- Str 8", "Folk & Acoustic", "Shaker Groove"),
            ("Brushes 9- Bossa Nova brushes", "Latin", "Bossa"),
            ("Brushes 10- Spanish Rumba", "Latin", "Cha Cha"),
            // Funk
            ("Funk 1- str 16ths", "Funk", "Pocket"),
            ("Funk 2- str 16ths", "Funk", "Linear"),
            ("Funk 3- str 16ths", "Funk", "Strut"),
            ("Funk 4- str 16ths", "Funk", "Ghost Notes"),
            ("Funk 5- str 16ths", "Funk", "Fusion Two-Bar"),
            ("Funk 6- swung", "Funk", "Greasy"),
            ("Funk 7- swung", "Hip-Hop & R&B", "Boom Bap"),
            ("Funk 8- swung", "Hip-Hop & R&B", "Neo Soul"),
            ("Funk 9- swung", "Funk", "Greasy"),
            ("Shuffle Funk", "Gospel & Shuffle", "Half-Time Shuffle"),
            // Hip-hop / R&B
            ("Hip Hop 1", "Hip-Hop & R&B", "Boom Bap"),
            ("Hip Hop 2", "Hip-Hop & R&B", "West Coast"),
            ("Hip Hop 4", "Hip-Hop & R&B", "Slow Jam"),
            ("Hip Hop 5", "Hip-Hop & R&B", "Trap"),
            ("Hip Hop 6- swung", "Hip-Hop & R&B", "Lazy"),
            ("Hip Hop 8- swung", "Hip-Hop & R&B", "Lazy"),
            ("Hip Hop 9- swung", "Hip-Hop & R&B", "Neo Soul"),
            ("Hip Hop 10- swung", "Hip-Hop & R&B", "Lazy"),
            ("R&B 6", "Hip-Hop & R&B", "Slow Jam"),
            ("R&B 10", "Hip-Hop & R&B", "Slow Jam"),
            // Punk
            ("Punk 1", "Punk", "Straight Punk"),
            ("Punk 3", "Punk", "Garage"),
            ("Punk 4", "Punk", "Garage"),
            ("Punk 5", "Punk", "Pop Punk"),
            // Reggae & ska
            ("Reggae 1- backbeat", "Reggae & Ska", "Rockers"),
            ("Reggae 2- one drop str", "Reggae & Ska", "One Drop"),
            ("Reggae 4- one drop str", "Reggae & Ska", "One Drop"),
            ("Reggae 5- one drop str", "Reggae & Ska", "One Drop"),
            ("Reggae 6- stomp", "Reggae & Ska", "Steppers"),
            ("Reggae 7- swung one drop", "Reggae & Ska", "One Drop"),
            ("Reggae 8- swung one drop", "Reggae & Ska", "One Drop"),
            ("Reggae 9- swung stomp", "Reggae & Ska", "Steppers"),
            ("Reggae 10- swung", "Reggae & Ska", "Dub"),
            ("Ska", "Reggae & Ska", "Ska Upbeat"),
            // Electronic
            ("Techno 1", "Electronic", "House"),
            ("Techno 3", "Electronic", "Techno"),
            ("Techno 4", "Electronic", "Electro"),
            // Jazz
            ("Jazz 1- med swing", "Jazz", "Medium Swing"),
            ("Jazz 2- med swing", "Jazz", "Medium Swing"),
            ("Jazz 3- modal", "Jazz", "Two Feel"),
            // Latin
            ("Bossa Nova", "Latin", "Bossa"),
            ("Bossa Nova 2", "Latin", "Bossa"),
            ("Bolero", "Latin", "Cha Cha"),
            ("Cuban Son (2-3)", "Latin", "Mambo Bell"),
            ("Mambo (2-3)", "Latin", "Mambo Bell"),
            ("Rumba Guaguanco (3-2)", "Latin", "Mambo Bell"),
            ("Marengue (3-2)", "Latin", "Dembow"),
        ]
        var out: [String: Target] = [:]
        for (style, genre, groove) in m { out[style] = Target(genre: genre, groove: groove) }
        return out
    }()

    /// Used when a beat style is not in `styleMap` (e.g. after regenerating the data).
    static let genreFallback: [String: Target] = [
        "Rock": Target(genre: "Rock", groove: "Straight Eights"),
        "Pop": Target(genre: "Pop", groove: "Radio"),
        "Ballad": Target(genre: "Pop", groove: "Ballad Sidestick"),
        "Country": Target(genre: "Country", groove: "Two-Step"),
        "Blues": Target(genre: "Blues", groove: "Shuffle"),
        "Worship": Target(genre: "Pop", groove: "Anthem"),
        "Hip Hop": Target(genre: "Hip-Hop & R&B", groove: "Boom Bap"),
        "Funk": Target(genre: "Funk", groove: "Pocket"),
        "Reggae": Target(genre: "Reggae & Ska", groove: "One Drop"),
        "Latin": Target(genre: "Latin", groove: "Latin Rock"),
        "Jazz": Target(genre: "Jazz", groove: "Medium Swing"),
        "Punk": Target(genre: "Punk", groove: "Straight Punk"),
        "Ska": Target(genre: "Reggae & Ska", groove: "Ska Upbeat"),
        "House": Target(genre: "Electronic", groove: "House"),
    ]
    static let defaultTarget = Target(genre: "Rock", groove: "Straight Eights")

    public static func target(style: String, genre: String) -> Target {
        styleMap[style] ?? genreFallback[genre] ?? defaultTarget
    }

    // MARK: Parsing

    static func parse(_ raw: String) -> [Entry] {
        var out: [Entry] = []
        out.reserveCapacity(entryCount)
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let bpm = Double(f[2]) else { continue }
            let title = f[0], artist = f[1]
            out.append(Entry(id: out.count, title: title, artist: artist, bpm: bpm, genre: f[3], style: f[4],
                             target: target(style: f[4], genre: f[3]),
                             searchText: normalize(title + " " + artist), titleText: normalize(title)))
        }
        return out
    }
}

extension SongLibrary {
    /// The factory song (or the user's edited version of it) that plays a song-index target.
    public func song(for target: SongIndex.Target) -> SongInfo? {
        let suffix = " · " + target.groove
        guard let factory = songs.first(where: { !$0.isUser && $0.genre == target.genre && $0.name.hasSuffix(suffix) }),
              let idx = index(forKey: factory.key) else { return nil }
        return song(at: idx)
    }
}
