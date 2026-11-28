import Foundation

/// Percussion layers generated for a beat that has none of its own (Auto Percussion).
///
/// *Where* the instruments play comes from the beat's own drums: shaker and maracas follow its
/// hi-hat / ride pulse (with its swing or triplet feel), tambourine and clap its snare backbeats.
/// *Which* instruments play in which part comes from the style: e.g. rock has a shaker in the verse
/// and an eighth-note tambourine in the chorus, latin has maracas. Intro, fills and the ending get
/// nothing of their own: the layer keeps its groove under fills and is silent in the intro/ending.
enum PercussionGenerator {

    /// What one instrument plays in a part.
    enum Figure: Sendable, Equatable {
        /// The beat's hi-hat / ride pulse, filled up to `subdivision` notes per beat when sparser.
        case pulse(subdivision: Int)
        /// The snare backbeats (beats 2 and 4 when the beat has none).
        case backbeat
        /// Every eighth of the pulse, accented on the backbeats.
        case eighths
        /// Every beat but the first of the bar (waltz "chick-chick").
        case afterbeats
    }

    /// Figures per instrument for verse, chorus and bridge (later parts repeat the bridge).
    typealias Arrangement = [PercussionInstrument: [Figure?]]

    static func arrangement(for style: BassGenerator.Style) -> Arrangement {
        switch style {
        case .rock:
            [.shaker: [.pulse(subdivision: 2), nil, .pulse(subdivision: 2)],
             .tambourine: [nil, .eighths, .backbeat]]
        case .pulse:
            [.shaker: [.pulse(subdivision: 2), .pulse(subdivision: 2), .pulse(subdivision: 2)],
             .tambourine: [nil, .backbeat, .backbeat]]
        case .funk:
            [.shaker: [.pulse(subdivision: 4), .pulse(subdivision: 4), nil],
             .clap: [nil, .backbeat, .backbeat]]
        case .walking:
            [.shaker: [.pulse(subdivision: 1), .pulse(subdivision: 1), .pulse(subdivision: 1)],
             .tambourine: [nil, .backbeat, .backbeat]]
        case .reggae:
            [.shaker: [.pulse(subdivision: 2), .pulse(subdivision: 2), .pulse(subdivision: 2)],
             .tambourine: [nil, .backbeat, nil]]
        case .fourFloor:
            [.shaker: [.pulse(subdivision: 4), .pulse(subdivision: 4), .pulse(subdivision: 4)],
             .clap: [nil, .backbeat, .backbeat]]
        case .boomBap:
            [.shaker: [.pulse(subdivision: 2), .pulse(subdivision: 2), nil],
             .clap: [nil, .backbeat, .backbeat]]
        case .latin:
            [.maracas: [.pulse(subdivision: 2), .pulse(subdivision: 4), .pulse(subdivision: 2)],
             .tambourine: [nil, nil, .backbeat]]
        case .waltz:
            [.shaker: [.pulse(subdivision: 1), .pulse(subdivision: 2), .pulse(subdivision: 1)],
             .tambourine: [nil, .afterbeats, nil]]
        }
    }

    /// The generated layers for `song`, one per instrument its style uses (none for an empty song).
    static func layers(for song: SongData) -> [PercussionData] {
        guard !song.parts.isEmpty else { return [] }
        let style = BassGenerator.style(forAnyGenre: song.genre)
        let bar = max(song.barTicks, 1), beat = max(song.beatTicks, 1)
        var out: [PercussionData] = []
        for (inst, figures) in arrangement(for: style).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let parts = song.parts.prefix(SongStore.maxParts).enumerated().map { i, p in
                let figure = figures.isEmpty ? nil : figures[min(i, figures.count - 1)]
                return PercussionPart(main: pattern(figure, instrument: inst, drums: p.main, barTicks: bar, beatTicks: beat))
            }
            guard parts.contains(where: { !$0.main.events.isEmpty }) else { continue }
            out.append(PercussionData(instrument: inst, parts: parts))
        }
        return out
    }

    /// One figure laid over `drums` (same length). `nil` = the instrument rests in this part.
    static func pattern(_ figure: Figure?, instrument: PercussionInstrument, drums: PatternData,
                        barTicks: Int, beatTicks: Int) -> PatternData {
        let length = max(drums.length, barTicks)
        guard let figure else { return PatternData(events: [], length: length) }
        let beat = max(beatTicks, 1)
        let voice = UInt8(instrument.drum.rawValue)
        let triplet = isTriplet(drums, beatTicks: beat)
        let backbeats = backbeatTicks(drums, length: length, barTicks: barTicks, beatTicks: beat)
        func ev(_ t: Int, _ v: UInt8) -> SeqEvent { SeqEvent(tick: Int32(t), drum: voice, velocity: v) }
        func accent(_ t: Int) -> UInt8 {
            if backbeats.contains(t) { return 100 }
            return t % beat == 0 ? 88 : 64
        }
        var events: [SeqEvent] = []
        switch figure {
        case .pulse(let sub):
            events = pulseTicks(drums, length: length, beatTicks: beat, triplet: triplet, subdivision: sub)
                .map { ev($0, accent($0)) }
        case .backbeat:
            events = backbeats.sorted().map { ev($0, 110) }
        case .eighths:
            let eighth = pulseTicks(drums, length: length, beatTicks: beat, triplet: triplet, subdivision: 2)
                .filter { isEighth($0, beatTicks: beat, triplet: triplet) }
            events = eighth.map { ev($0, backbeats.contains($0) ? 112 : ($0 % beat == 0 ? 84 : 70)) }
        case .afterbeats:
            events = stride(from: 0, to: length, by: beat).filter { $0 % max(barTicks, 1) != 0 }.map { ev($0, 96) }
        }
        return PatternData(events: events, length: length)
    }

    // MARK: - Reading the beat

    private static let pulseVoices = Set([Drum.hatClosed, .hatPedal, .hatOpen, .ride, .rideBell].map { UInt8($0.rawValue) })
    private static let snareVoices: Set<UInt8> = [UInt8(Drum.snare.rawValue), UInt8(Drum.clap.rawValue), UInt8(Drum.rim.rawValue)]

    /// Triplet feel: the beat's notes sit on thirds of a beat more than on straight sixteenths.
    static func isTriplet(_ drums: PatternData, beatTicks beat: Int) -> Bool {
        let tol = max(beat / 16, 1)
        func share(_ step: Int) -> Int {
            drums.events.filter { let r = Int($0.tick) % step; return r <= tol || step - r <= tol }.count
        }
        return share(beat / 3) > share(beat / 4)
    }

    /// The hi-hat / ride pulse, filled up to `subdivision` notes per beat where it is sparser
    /// (a beat without hats gets a plain pulse). Keeps the beat's own (swung) positions.
    static func pulseTicks(_ drums: PatternData, length: Int, beatTicks beat: Int, triplet: Bool, subdivision: Int) -> [Int] {
        let own = Set(drums.events.filter { pulseVoices.contains($0.drum) && Int($0.tick) < length }.map { Int($0.tick) })
        let sub = max(subdivision, 1)
        // Triplet beats: 1 → beat, 2 → shuffle (1 and the last third), 4 → all three thirds.
        let grid: [Int] = triplet
            ? (sub >= 3 ? [0, beat / 3, 2 * beat / 3] : sub == 2 ? [0, 2 * beat / 3] : [0])
            : (0..<sub).map { $0 * beat / sub }
        var out = Set<Int>()
        for b in stride(from: 0, to: length, by: beat) {
            let inBeat = own.filter { $0 >= b && $0 < b + beat }
            if inBeat.count >= grid.count {
                // The hats already play this densely: follow them, thinned to the subdivision.
                let keep = inBeat.sorted().enumerated().filter { $0.offset % max(inBeat.count / grid.count, 1) == 0 }.map(\.element)
                out.formUnion(keep.prefix(grid.count))
            } else {
                // Sparser: the hats' own notes plus the grid where they leave gaps.
                out.formUnion(inBeat)
                for g in grid where !inBeat.contains(where: { abs($0 - (b + g)) < beat / 8 }) { out.insert(b + g) }
            }
        }
        return out.filter { $0 < length }.sorted()
    }

    /// Snare (or clap / rim) hits on a beat, loud enough to be the backbeat; else beats 2 and 4
    /// (in 3/4 and 6/8-felt bars: the middle beat).
    static func backbeatTicks(_ drums: PatternData, length: Int, barTicks bar: Int, beatTicks beat: Int) -> Set<Int> {
        let tol = max(beat / 16, 1)
        let hits = drums.events.filter {
            snareVoices.contains($0.drum) && $0.velocity >= 70 && Int($0.tick) < length
                && (Int($0.tick) % beat <= tol || beat - Int($0.tick) % beat <= tol)
        }.map { (Int($0.tick) + tol) / beat * beat }
        if !hits.isEmpty { return Set(hits.filter { $0 < length }) }
        let beats = max(bar / beat, 1)
        var out = Set<Int>()
        for b in stride(from: 0, to: length, by: beat) {
            let i = (b % max(bar, 1)) / beat
            if beats % 2 == 0 ? i % 2 == 1 : (beats == 3 ? i == 1 : i == beats / 2) { out.insert(b) }
        }
        return out
    }

    private static func isEighth(_ t: Int, beatTicks beat: Int, triplet: Bool) -> Bool {
        let r = t % beat
        let tol = max(beat / 8, 1)
        let off = triplet ? 2 * beat / 3 : beat / 2
        // Swung eighths sit between the straight and the triplet position.
        return r <= tol || abs(r - off) <= tol || (!triplet && abs(r - 2 * beat / 3) <= tol)
    }
}
