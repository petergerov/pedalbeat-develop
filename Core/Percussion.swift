import Foundation

/// Percussion layers that play along with a song's drums: a separate track with its own switch
/// and level, like the bass. Each instrument comes from its own imported folder, laid out like the
/// folder with the song's own drums:
///
///     shaker_songs/<Artist>/<Title>/Groove A.mid, Groove A Fill 1.mid, Intro.mid, Ending.mid, song.json
///     drum_songs/<Artist>/<Title>/…                (the song it plays with: same artist and title)
///
/// Layers are not beats: they never show up in the browser and only play with their song.
public enum PercussionInstrument: Int, CaseIterable, Sendable, Identifiable {
    case shaker = 0, tambourine, clap, maracas

    public static let count = 4
    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .shaker: "Shaker"
        case .tambourine: "Tambourine"
        case .clap: "Clap"
        case .maracas: "Maracas"
        }
    }

    /// The kit voice it plays. Other notes in its files are left out, so a layer never doubles the drums.
    public var drum: Drum {
        switch self {
        case .shaker: .shaker
        case .tambourine: .tambourine
        case .clap: .clap
        case .maracas: .maracas
        }
    }

    /// Group of its import: the folder `shaker_songs` becomes "shaker songs › Artist".
    public var pack: String { name.lowercased() + " songs" }
    /// Folder name on disk, for hints in the UI.
    public var folder: String { name.lowercased() + "_songs" }

    /// AU parameter that switches this instrument on and off.
    public var parameter: ParamAddress {
        switch self {
        case .shaker: .percShaker
        case .tambourine: .percTambourine
        case .clap: .percClap
        case .maracas: .percMaracas
        }
    }

    /// The instrument of a percussion pack ("shaker songs", "Shaker_Songs", …).
    public init?(pack: String) {
        let p = SongIndex.normalize(pack)
        guard let i = PercussionInstrument.allCases.first(where: { SongIndex.normalize($0.pack) == p }) else { return nil }
        self = i
    }

    /// Instrument and song key of an imported layer ("shaker songs › Adele" / "Rolling in the Deep"),
    /// nil for anything else (it then imports as an ordinary song).
    public static func layer(genre: String, name: String) -> (instrument: PercussionInstrument, link: String)? {
        guard let pack = genre.components(separatedBy: " › ").first, let i = PercussionInstrument(pack: pack),
              let link = SongIndex.linkKey(genre: genre, name: name) else { return nil }
        return (i, link)
    }
}

extension SongIndex {
    /// Folders whose songs each belong to one popular song (`<pack>/<Artist>/<Title>/`): the song's own
    /// drums ("drum songs"), its bb versions ("bb songs") and its percussion layers ("shaker songs", …).
    public static func isSongPack(_ pack: String) -> Bool {
        isDrumSongPack(pack) || PercussionInstrument(pack: pack) != nil
    }

    /// A pack of whole songs (drums and bass): "drum songs" or "bb songs", not a percussion layer.
    public static func isDrumSongPack(_ pack: String) -> Bool {
        let p = normalize(pack)
        return p == normalize(songDrumsPack) || p == normalize(bbSongsPack)
    }

    /// Artist + title key of a song from such a folder (group "drum songs › Adele", song
    /// "Rolling in the Deep"); nil for other songs. Percussion layers play with the song of the same key,
    /// both with its own drums and with its bb versions ("bb songs", named "Title · Beat").
    public static func linkKey(genre: String, name: String) -> String? {
        let parts = genre.components(separatedBy: " › ")
        guard parts.count >= 2, isSongPack(parts[0]) else { return nil }
        let title = normalize(parts[0]) == normalize(bbSongsPack) ? splitBBSongName(name).title : name
        return songKey(artist: parts.dropFirst().joined(separator: " "), title: title)
    }
}

/// One part of a percussion layer: its groove and fills.
public struct PercussionPart: Sendable {
    public var main: PatternData
    public var fills: [PatternData]
    public init(main: PatternData, fills: [PatternData] = []) { self.main = main; self.fills = fills }
}

/// A percussion layer for one song. It holds only what its files hold: unlike a song, nothing is
/// generated (no count-in, fills or ending). Patterns loop on their own length, like bass lines.
///
/// With the song's sections: part n plays the layer's part n (its last part if it has fewer);
/// fills and transitions play the layer's own fill or transition, otherwise its groove keeps going;
/// the intro and the ending play the layer's own, otherwise it's silent there.
public struct PercussionData: Sendable {
    public var instrument: PercussionInstrument
    public var intro: PatternData?
    public var parts: [PercussionPart]
    public var transition: PatternData?
    public var outro: PatternData?

    public init(instrument: PercussionInstrument, intro: PatternData? = nil, parts: [PercussionPart],
                transition: PatternData? = nil, outro: PatternData? = nil) {
        self.instrument = instrument; self.intro = intro; self.parts = parts
        self.transition = transition; self.outro = outro
    }

    /// Builds a layer from imported files and their layout, keeping only the instrument's notes.
    /// Nil when no groove has any.
    public static func make(files: [MIDIDrumFile], layout: MIDISongImporter.SongLayout,
                            instrument: PercussionInstrument) -> PercussionData? {
        var byName: [String: MIDIDrumFile] = [:]
        for f in files where byName[f.name] == nil { byName[f.name] = f }
        let voice = UInt8(instrument.drum.rawValue)
        // Shaker files have always held cabasa, maracas and shaker notes (GM 69, 70, 82): they stay shaker.
        let voices: Set<UInt8> = instrument == .shaker ? [voice, UInt8(Drum.maracas.rawValue)] : [voice]
        func pattern(_ name: String?) -> PatternData? {
            guard let f = name.flatMap({ byName[$0] }) else { return nil }
            let events = f.events.filter { voices.contains($0.drum) }.map { var e = $0; e.drum = voice; return e }
            return events.isEmpty ? nil : PatternData(events: events, length: f.lengthTicks)
        }
        let parts = layout.parts.prefix(SongStore.maxParts).compactMap { p -> PercussionPart? in
            guard let main = pattern(p.main) else { return nil }
            return PercussionPart(main: main, fills: p.fills.prefix(SongStore.maxFills).compactMap(pattern))
        }
        guard !parts.isEmpty else { return nil }
        return PercussionData(instrument: instrument, intro: pattern(layout.intro), parts: parts,
                              transition: pattern(layout.transition), outro: pattern(layout.outro))
    }
}
