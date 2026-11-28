import Foundation

/// Builds an optional bass track from a drum pattern. Leaves drums alone: only fills
/// `BassPattern` slots on a song that does not already have bass.
enum BassGenerator {

    /// How the bass locks to the groove. Chosen from the song's genre.
    enum Style: Sendable {
        /// Root on kicks; chorus lifts to the fifth / octave.
        case rock
        /// Sparse, syncopated roots with octave pops.
        case funk
        /// Steady quarters (or shuffle beats): root → chord tone → approach.
        case walking
        /// Offbeat / space around the one-drop.
        case reggae
        /// Four-on-the-floor roots and octave octaves.
        case fourFloor
        /// Boom-bap: hits with the kick, leave space.
        case boomBap
        /// Tumbao-ish: root on 1 & and, fifth / octave fills.
        case latin
        /// Boom-chick / waltz: root on 1, fifth on the weak beats.
        case waltz
        /// Simple root pulse on the beat (folk, percussion, fallback).
        case pulse
    }

    enum PartRole: Int, Sendable {
        case verse = 0, chorus = 1, bridge = 2, outro = 3
    }

    /// MIDI root for generated factory lines (E1). Matches Bass Follow demos.
    static let defaultRoot: UInt8 = 28
    static let defaultRootPitchClass = 4

    static func style(forGenre genre: String) -> Style {
        switch genre {
        case "Funk": .funk
        case "Jazz", "Blues", "Gospel & Shuffle": .walking
        case "Reggae & Ska": .reggae
        case "Electronic", "Disco & Soul": .fourFloor
        case "Hip-Hop & R&B": .boomBap
        case "Latin": .latin
        case "Waltz & Triple", "Folk & Acoustic": .waltz
        case "Country": .pulse
        case "Pop", "Rock", "Hard Rock & Metal", "Punk", "Odd Time", "Percussion": .rock
        default: .rock
        }
    }

    /// Factory genre names as such, anything else (bb, imports) by `style(forBeatGenre:)`.
    static func style(forAnyGenre genre: String) -> Style {
        let factory = ["Funk", "Jazz", "Blues", "Gospel & Shuffle", "Reggae & Ska", "Electronic", "Disco & Soul", "Hip-Hop & R&B",
                       "Latin", "Waltz & Triple", "Folk & Acoustic", "Country", "Pop", "Rock", "Hard Rock & Metal", "Punk",
                       "Odd Time", "Percussion"]
        return factory.contains(genre) ? style(forGenre: genre) : style(forBeatGenre: genre)
    }

    /// Style for a beat from another library, by its genre name (e.g. a bb "BBS › Reggae" beat):
    /// the last part of the name, matched loosely; unknown genres play `.rock`.
    static func style(forBeatGenre genre: String) -> Style {
        let g = (genre.components(separatedBy: " › ").last ?? genre).lowercased()
        func has(_ words: String...) -> Bool { words.contains { g.contains($0) } }
        if has("reggae", "ska") { return .reggae }
        if has("funk") { return .funk }
        if has("jazz", "blues", "swing", "shuffle", "gospel") { return .walking }
        if has("hip hop", "hip-hop", "r&b", "rnb") { return .boomBap }
        if has("latin", "brazil", "bossa", "samba", "salsa") { return .latin }
        if has("techno", "house", "disco", "dance", "drum & bass", "electro") { return .fourFloor }
        if has("waltz", "folk") { return .waltz }
        if has("country", "percussion", "metronome") { return .pulse }
        return .rock
    }

    /// Lowest octave of a pitch class (C1 = 24 … B1 = 35), the register of the generated lines.
    static func root(pitchClass pc: Int) -> UInt8 { UInt8(24 + ((pc % 12) + 12) % 12) }

    // MARK: - Does a bass line fit a drum pattern?

    /// Share of the beat's kicks (per bar position) that the bass must play along with.
    static let minKickCover = 0.5
    /// Share of the bass notes that must sit on the beat's grid (straight 16ths or triplets).
    static let minOnGrid = 0.8

    /// Whether `bass`, written for other drums, sits well on `drums`: it plays along with most of their
    /// kicks and its notes fall on their grid (a straight line on a shuffle beat does not fit).
    /// Positions are compared within the bar, so lines and patterns of different lengths compare.
    static func fits(_ bass: BassPattern, drums: PatternData, barTicks: Int, beatTicks: Int) -> Bool {
        let bar = max(barTicks, 1), beat = max(beatTicks, 1)
        let tol = max(beat / 16, 1)
        let onsets = Set(bass.events.map { Int($0.tick) % bar })
        guard !onsets.isEmpty else { return false }
        func near(_ t: Int, _ set: Set<Int>) -> Bool {
            set.contains { abs($0 - t) <= tol || bar - abs($0 - t) <= tol }
        }
        let kicks = Set(drums.events.filter { $0.drum == UInt8(Drum.kick.rawValue) }.map { Int($0.tick) % bar })
        let cover = kicks.isEmpty ? 1 : Double(kicks.filter { near($0, onsets) }.count) / Double(kicks.count)
        // The beat's grid: triplets when its notes sit on thirds of a beat and not on straight 16ths.
        let ticks = drums.events.map { Int($0.tick) % beat }
        func share(_ step: Int, _ ts: [Int]) -> Double {
            ts.isEmpty ? 1 : Double(ts.filter { let r = $0 % step; return r <= tol || step - r <= tol }.count) / Double(ts.count)
        }
        let triplet = share(beat / 3, ticks) > share(beat / 4, ticks)
        let onGrid = share(triplet ? beat / 3 : beat / 4, onsets.map { $0 % beat })
        return cover >= minKickCover && onGrid >= minOnGrid
    }

    /// Fills every part's bass (and a short outro line). No-op when the song already has bass
    /// (hand-written "Bass & Drums" songs) or bass is disabled.
    static func apply(to song: inout SongData, seed: Int = 0) {
        guard song.bassEnabled, !song.hasBass else { return }
        song.bassRootPitchClass = defaultRootPitchClass
        let style = style(forAnyGenre: song.genre)
        for i in song.parts.indices {
            let role = PartRole(rawValue: min(i, 2)) ?? .verse
            song.parts[i].bass = pattern(for: song.parts[i].main,
                                         barTicks: song.barTicks, beatTicks: song.beatTicks,
                                         style: style, role: role, root: defaultRoot,
                                         seed: seed &+ i &* 17)
        }
        if let outro = song.outro {
            song.outroBass = pattern(for: outro, barTicks: song.barTicks, beatTicks: song.beatTicks,
                                     style: style, role: .outro, root: defaultRoot,
                                     seed: seed &+ 91)
        }
    }

    /// One bass line locked to `drums`. Length matches the drum pattern.
    static func pattern(for drums: PatternData, barTicks: Int, beatTicks: Int,
                        style: Style, role: PartRole, root: UInt8 = defaultRoot,
                        seed: Int = 0) -> BassPattern {
        let length = max(drums.length, barTicks)
        let bar = max(barTicks, 1)
        let beat = max(beatTicks, 1)
        let hits = anchors(in: drums, length: length, beatTicks: beat, style: style, role: role)
        guard !hits.isEmpty else {
            return BassPattern(events: [
                BassEvent(tick: 0, note: root, velocity: 100, durationTicks: Int32(min(beat * 3 / 4, length)))
            ], length: length)
        }

        var events: [BassEvent] = []
        for (i, hit) in hits.enumerated() {
            let next = i + 1 < hits.count ? hits[i + 1].tick : length
            let barIndex = hit.tick / bar
            let tickInBar = hit.tick % bar
            let notesInBar = hits.filter { $0.tick / bar == barIndex }.count
            let indexInBar = hits.prefix(i + 1).filter { $0.tick / bar == barIndex }.count - 1
            let note = pitch(root: root, style: style, role: role, barIndex: barIndex,
                             tickInBar: tickInBar, barTicks: bar, beatTicks: beat,
                             indexInBar: indexInBar, notesInBar: notesInBar, seed: seed &+ i)
            let gap = max(beat / 8, 1)
            let maxDur = durationCap(style: style, beatTicks: beat, role: role)
            let dur = max(1, min(next - hit.tick - gap, maxDur))
            let vel = velocity(base: hit.velocity, role: role, indexInBar: indexInBar)
            events.append(BassEvent(tick: Int32(hit.tick), note: note, velocity: vel, durationTicks: Int32(dur)))
        }
        if role == .outro, let last = events.indices.last {
            // Hold the final root into the crash.
            var end = events[last]
            end.note = root
            end.durationTicks = Int32(max(Int(end.durationTicks), beat))
            events[last] = end
        }
        return BassPattern(events: events, length: length)
    }

    // MARK: - Rhythm

    private struct Hit { var tick: Int; var velocity: UInt8 }

    private static func anchors(in drums: PatternData, length: Int, beatTicks: Int,
                                style: Style, role: PartRole) -> [Hit] {
        let kicks = drums.events
            .filter { $0.drum == UInt8(Drum.kick.rawValue) && Int($0.tick) < length }
            .map { Hit(tick: Int($0.tick), velocity: $0.velocity) }
        let source: [Hit]
        if kicks.isEmpty {
            source = stride(from: 0, to: length, by: beatTicks).map { Hit(tick: $0, velocity: 100) }
        } else {
            source = kicks
        }

        let thinned: [Hit]
        switch style {
        case .rock, .pulse:
            thinned = thin(source, preferAccents: true, minGap: beatTicks / 2, alwaysKeepBeat: beatTicks)
        case .funk:
            thinned = thin(source, preferAccents: false, minGap: beatTicks / 4, alwaysKeepBeat: beatTicks)
        case .walking:
            // One note per beat, walking style — ignore denser kicks.
            thinned = stride(from: 0, to: length, by: beatTicks).map { t in
                Hit(tick: t, velocity: source.first { abs($0.tick - t) < beatTicks / 3 }?.velocity ?? 96)
            }
        case .reggae:
            // Prefer the three (half bar) and leave space on one when one-drop-like.
            let half = beatTicks * 2
            var hits = source.filter { $0.tick % half == 0 || $0.velocity >= 110 }
            if hits.isEmpty { hits = thin(source, preferAccents: true, minGap: beatTicks, alwaysKeepBeat: half) }
            thinned = thin(hits, preferAccents: true, minGap: beatTicks, alwaysKeepBeat: half)
        case .fourFloor:
            thinned = stride(from: 0, to: length, by: beatTicks).map { Hit(tick: $0, velocity: 110) }
        case .boomBap:
            thinned = thin(source.filter { $0.velocity >= 90 || $0.tick % beatTicks == 0 },
                           preferAccents: true, minGap: beatTicks / 2, alwaysKeepBeat: beatTicks)
        case .latin:
            thinned = thin(source, preferAccents: false, minGap: beatTicks / 4, alwaysKeepBeat: beatTicks / 2)
        case .waltz:
            thinned = thin(source, preferAccents: true, minGap: beatTicks / 2, alwaysKeepBeat: beatTicks)
        }

        // Outro: fewer notes so the ending can breathe.
        if role == .outro {
            return thin(thinned, preferAccents: true, minGap: beatTicks, alwaysKeepBeat: beatTicks * 2)
        }
        // Chorus can take a little more motion from leftover kicks.
        if role == .chorus, style == .funk || style == .rock {
            let denser = thin(source, preferAccents: false, minGap: beatTicks / 4, alwaysKeepBeat: beatTicks / 2)
            if denser.count > thinned.count { return denser }
        }
        return thinned
    }

    /// Keeps hits at least `minGap` apart; accents win ties; tick 0 always stays when present.
    private static func thin(_ hits: [Hit], preferAccents: Bool, minGap: Int, alwaysKeepBeat: Int) -> [Hit] {
        guard !hits.isEmpty else { return [] }
        let gap = max(minGap, 1)
        var chosen: [Hit] = []
        let sorted = hits.sorted { a, b in
            if a.tick != b.tick { return a.tick < b.tick }
            return a.velocity > b.velocity
        }
        for h in sorted {
            let onGrid = alwaysKeepBeat > 0 && h.tick % alwaysKeepBeat == 0
            if let last = chosen.last {
                if h.tick - last.tick < gap {
                    if preferAccents && h.velocity > last.velocity && (onGrid || h.tick == last.tick) {
                        chosen[chosen.count - 1] = h
                    }
                    continue
                }
            }
            if chosen.isEmpty || onGrid || h.velocity >= 90 || h.tick == 0 {
                chosen.append(h)
            } else if let last = chosen.last, h.tick - last.tick >= gap * 2 {
                chosen.append(h)
            }
        }
        if chosen.isEmpty, let first = sorted.first { return [first] }
        // Ensure a downbeat when the pattern has one.
        if sorted.contains(where: { $0.tick == 0 }), chosen.first?.tick != 0 {
            chosen.insert(Hit(tick: 0, velocity: sorted.first { $0.tick == 0 }!.velocity), at: 0)
            chosen = thin(chosen, preferAccents: true, minGap: gap, alwaysKeepBeat: alwaysKeepBeat)
        }
        return chosen
    }

    private static func durationCap(style: Style, beatTicks: Int, role: PartRole) -> Int {
        switch style {
        case .funk, .latin: beatTicks
        case .walking: beatTicks * 9 / 10
        case .reggae: beatTicks * 2
        case .fourFloor: beatTicks * 3 / 4
        case .boomBap: beatTicks
        case .waltz, .pulse, .rock:
            role == .outro ? beatTicks * 2 : beatTicks + beatTicks / 2
        }
    }

    // MARK: - Pitch

    private static func pitch(root: UInt8, style: Style, role: PartRole, barIndex: Int,
                              tickInBar: Int, barTicks: Int, beatTicks: Int,
                              indexInBar: Int, notesInBar: Int, seed: Int) -> UInt8 {
        let r = Int(root)
        let fifth = r + 7
        let octave = r + 12
        let flat7 = r + 10
        let third = r + 4
        let sixth = r + 9
        let pick = (seed &+ barIndex &* 3 &+ indexInBar) & 3

        // Harmonic centre shifts slightly by part; still the same pitch-class root for Bass Follow.
        let centre: Int = switch role {
        case .verse: r
        case .chorus: pick == 0 ? octave : r
        case .bridge: fifth
        case .outro: r
        }

        switch style {
        case .rock, .pulse:
            if indexInBar == 0 { return UInt8(centre) }
            if indexInBar == notesInBar - 1 && barIndex % 2 == 1 { return UInt8(clamp(fifth)) }
            return UInt8(centre)

        case .funk:
            let steps = [centre, centre, octave, fifth, flat7, centre]
            return UInt8(clamp(steps[(indexInBar + barIndex) % steps.count]))

        case .walking:
            // Beat of the bar → scale degree.
            let beat = tickInBar / max(beatTicks, 1)
            let degrees = [centre, third, fifth, flat7, sixth, fifth, third, centre]
            var n = degrees[beat % degrees.count]
            // Chromatic approach into the next bar's root on the last beat.
            if beat % max(barTicks / beatTicks, 1) == max(barTicks / beatTicks, 1) - 1 {
                n = (barIndex % 2 == 0) ? centre - 1 : centre + 1
            }
            return UInt8(clamp(n))

        case .reggae:
            if tickInBar < beatTicks { return UInt8(clamp(r)) }          // sparse one
            if tickInBar >= beatTicks * 2 { return UInt8(clamp(fifth)) } // three
            return UInt8(clamp(centre))

        case .fourFloor:
            if indexInBar % 2 == 1 { return UInt8(clamp(octave)) }
            return UInt8(clamp(barIndex % 2 == 1 && indexInBar == 0 ? fifth : centre))

        case .boomBap:
            if indexInBar == 0 { return UInt8(clamp(centre)) }
            return UInt8(clamp(pick == 2 ? flat7 : centre))

        case .latin:
            let steps = [centre, centre, fifth, octave, centre, flat7]
            return UInt8(clamp(steps[(indexInBar + (tickInBar > beatTicks ? 1 : 0)) % steps.count]))

        case .waltz:
            let beat = tickInBar / max(beatTicks, 1)
            return UInt8(clamp(beat % 3 == 0 ? centre : fifth))
        }
    }

    private static func velocity(base: UInt8, role: PartRole, indexInBar: Int) -> UInt8 {
        var v = Int(max(base, 70))
        if indexInBar == 0 { v += 8 }
        switch role {
        case .verse: break
        case .chorus: v += 10
        case .bridge: v += 4
        case .outro: v += 6
        }
        return UInt8(min(v, 120))
    }

    private static func clamp(_ n: Int) -> Int {
        // Keep electric-bass range roughly E1…G3.
        min(max(n, 28), 55)
    }
}
