import Foundation
import Synchronization

// MARK: - Song data (built on the main thread)

public struct SeqEvent: Sendable, Equatable {
    public var tick: Int32
    public var drum: UInt8
    public var velocity: UInt8
    /// Extra delay in ticks applied at 100% "swing" (0 for on-beat notes).
    public var swingUnit: Int16

    public init(tick: Int32, drum: UInt8, velocity: UInt8, swingUnit: Int16 = 0) {
        self.tick = tick; self.drum = drum; self.velocity = velocity; self.swingUnit = swingUnit
    }
}

public struct PatternData: Sendable {
    public var events: [SeqEvent]
    public var length: Int
    public init(events: [SeqEvent], length: Int) {
        self.events = events.sorted { $0.tick < $1.tick }
        self.length = length
    }
}

/// One note of the bass track, on the same tick grid as the drums.
public struct BassEvent: Sendable, Equatable {
    public var tick: Int32
    public var note: UInt8             // MIDI pitch
    public var velocity: UInt8
    public var durationTicks: Int32    // at least 1

    public init(tick: Int32, note: UInt8, velocity: UInt8, durationTicks: Int32) {
        self.tick = tick; self.note = note; self.velocity = velocity; self.durationTicks = max(durationTicks, 1)
    }
}

/// A bass line. It loops over its own `length`, which may differ from the drum pattern's.
public struct BassPattern: Sendable, Equatable {
    public var events: [BassEvent]
    public var length: Int
    public init(events: [BassEvent], length: Int) {
        self.events = events.sorted { $0.tick < $1.tick }
        self.length = length
    }
}

public struct PartData: Sendable {
    public var main: PatternData
    /// Up to `SongStore.maxFills` fills; the pedal plays them in order or at random.
    public var fills: [PatternData]
    /// The groove's bass line. It keeps playing under the part's fills.
    public var bass: BassPattern?
    /// Optional bass line per fill (same order as `fills`; shorter or `nil` = the groove's bass keeps playing).
    public var fillBass: [BassPattern?] = []
    public var fill: PatternData? { fills.first }
    public init(main: PatternData, fill: PatternData?, bass: BassPattern? = nil) {
        self.main = main; self.fills = fill.map { [$0] } ?? []; self.bass = bass
    }
    public init(main: PatternData, fills: [PatternData], bass: BassPattern? = nil, fillBass: [BassPattern?] = []) {
        self.main = main; self.fills = fills; self.bass = bass; self.fillBass = fillBass
    }
}

public struct SongData: Sendable {
    public var name: String
    public var genre: String
    public var tempo: Double
    public var timeSignature: String
    public var barTicks: Int
    public var beatTicks: Int
    public var intro: PatternData?
    public var parts: [PartData]
    public var transition: PatternData?
    public var outro: PatternData?
    public var introCrash = true
    public var fillCrash = true
    public var kitHint = 0
    public var isUser = false
    public var key: String
    /// Bass lines of the other sections. Without one, the intro has no bass and transitions and
    /// the outro keep the current part's bass going.
    public var introBass: BassPattern?
    public var transitionBass: BassPattern?
    public var outroBass: BassPattern?
    public var bassEnabled = true
    /// Pitch class the written bass line is in (0 = C … 11 = B). Bass Follow transposes from this root.
    public var bassRootPitchClass: Int = 4
    /// How much of the song (its original recording or MIDI) each chord takes, index root + (minor ? 12 : 0),
    /// any scale; empty = unknown. Bass Follow prefers these chords when it detects the player's.
    public var chordProfile: [Float] = []
    public var hasBass: Bool {
        bassEnabled && (introBass != nil || transitionBass != nil || outroBass != nil || parts.contains { $0.bass != nil })
    }

    public init(name: String, genre: String, tempo: Double, timeSignature: String, barTicks: Int, beatTicks: Int,
                intro: PatternData?, parts: [PartData], transition: PatternData?, outro: PatternData?,
                introCrash: Bool = true, fillCrash: Bool = true, kitHint: Int = 0, isUser: Bool = false, key: String? = nil,
                bassRootPitchClass: Int = 4) {
        self.name = name; self.genre = genre; self.tempo = tempo; self.timeSignature = timeSignature
        self.barTicks = barTicks; self.beatTicks = beatTicks; self.intro = intro; self.parts = parts
        self.transition = transition; self.outro = outro; self.introCrash = introCrash; self.fillCrash = fillCrash
        self.kitHint = kitHint; self.isUser = isUser; self.key = key ?? "\(genre)/\(name)"
        self.bassRootPitchClass = ((bassRootPitchClass % 12) + 12) % 12
    }
}

/// Lightweight song description for the UI.
public struct SongInfo: Identifiable, Hashable, Sendable {
    public let id: Int          // index in the SongStore
    public let name: String
    public let genre: String
    public let tempo: Double
    public let timeSignature: String
    public let partCount: Int
    public let hasIntro: Bool
    public let hasOutro: Bool
    public let kitHint: Int
    public let isUser: Bool
    public let key: String
    public let hasBass: Bool
}

// MARK: - Realtime-safe storage

struct PatternRecord { var start: Int32; var count: Int32; var length: Int32 }

struct SongRecord {
    var tempo: Float = 120
    var barTicks: Int32 = 1920
    var beatTicks: Int32 = 480
    var intro: Int32 = -1
    var transition: Int32 = -1
    var outro: Int32 = -1
    var partCount: Int32 = 0
    var introCrash = true
    var fillCrash = true
    // Bass pattern indices (into `bassPatterns`), -1 = none.
    var introBass: Int32 = -1
    var transitionBass: Int32 = -1
    var outroBass: Int32 = -1
    var bassEnabled = true
    /// Pitch class 0…11 of the written bass (see `SongData.bassRootPitchClass`).
    var bassRoot: Int8 = 4
}

/// A percussion layer: section patterns (indices into `patterns`), -1 = none.
struct PercRecord {
    var intro: Int32 = -1
    var transition: Int32 = -1
    var outro: Int32 = -1
    var partCount: Int32 = 0
}

/// Append-only song storage. The writer (main thread) fills preallocated
/// buffers and then publishes the new song count with release ordering; the
/// audio thread only ever reads songs below the published count.
public final class SongStore: @unchecked Sendable {
    public static let maxParts = 8
    public static let maxFills = 8
    let eventCapacity: Int
    let patternCapacity: Int
    let songCapacity: Int
    let events: UnsafeMutablePointer<SeqEvent>
    let patterns: UnsafeMutablePointer<PatternRecord>
    let songs: UnsafeMutablePointer<SongRecord>
    let partMain: UnsafeMutablePointer<Int32>
    let partFill: UnsafeMutablePointer<Int32>       // (song * maxParts + part) * maxFills + k
    let partFillCount: UnsafeMutablePointer<Int8>   // song * maxParts + part
    // Bass track: its own event pool and patterns (same record shape as drum patterns).
    let bassEventCapacity: Int
    let bassPatternCapacity: Int
    let bassEvents: UnsafeMutablePointer<BassEvent>
    let bassPatterns: UnsafeMutablePointer<PatternRecord>
    let partBass: UnsafeMutablePointer<Int32>       // song * maxParts + part
    /// `SongData.chordProfile` per song: song * 24 + chord, all zero = none.
    let songChords: UnsafeMutablePointer<Float>
    let partFillBass: UnsafeMutablePointer<Int32>   // (song * maxParts + part) * maxFills + k, -1 = none
    // Percussion layers (shaker, tambourine, clap): patterns in the drum pools, one record per layer.
    let percCapacity: Int
    let percTracks: UnsafeMutablePointer<PercRecord>
    let percPartMain: UnsafeMutablePointer<Int32>        // track * maxParts + part
    let percPartFill: UnsafeMutablePointer<Int32>        // (track * maxParts + part) * maxFills + k
    let percPartFillCount: UnsafeMutablePointer<Int8>    // track * maxParts + part
    /// The layer each song plays per instrument (song * PercussionInstrument.count + instrument), -1 = none.
    /// A layer may be imported after its song, so this is changed while the audio thread reads it.
    private let songPerc: UnsafeMutablePointer<Atomic<Int32>>
    /// Generated layers (`PercussionGenerator`), played only with Auto Percussion and when the song has none of its own.
    private let songAutoPerc: UnsafeMutablePointer<Atomic<Int32>>

    private var eventCount = 0
    private var patternCount = 0
    private var songCount = 0
    private var bassEventCount = 0
    private var bassPatternCount = 0
    private var percCount = 0
    private let published = Atomic<Int>(0)
    private let writeLock = NSLock()

    /// Defaults: room for the built-in song pack plus both song installers imported (bb Songs and
    /// MIDI Songs, ≈ 3100 songs, 36 000 patterns, 700 000 events, 14 300 bass lines) with half again to spare.
    public init(eventCapacity: Int = 1_500_000, patternCapacity: Int = 65_536, songCapacity: Int = 6144,
                bassEventCapacity: Int = 524_288, bassPatternCapacity: Int = 32_768, percCapacity: Int = 4096) {
        self.eventCapacity = eventCapacity
        self.patternCapacity = patternCapacity
        self.songCapacity = songCapacity
        self.bassEventCapacity = bassEventCapacity
        self.bassPatternCapacity = bassPatternCapacity
        self.percCapacity = percCapacity
        percTracks = .allocate(capacity: percCapacity)
        percPartMain = .allocate(capacity: percCapacity * SongStore.maxParts)
        percPartMain.initialize(repeating: -1, count: percCapacity * SongStore.maxParts)
        percPartFill = .allocate(capacity: percCapacity * SongStore.maxParts * SongStore.maxFills)
        percPartFill.initialize(repeating: -1, count: percCapacity * SongStore.maxParts * SongStore.maxFills)
        percPartFillCount = .allocate(capacity: percCapacity * SongStore.maxParts)
        percPartFillCount.initialize(repeating: 0, count: percCapacity * SongStore.maxParts)
        songPerc = .allocate(capacity: songCapacity * PercussionInstrument.count)
        for i in 0..<songCapacity * PercussionInstrument.count { (songPerc + i).initialize(to: Atomic<Int32>(-1)) }
        songAutoPerc = .allocate(capacity: songCapacity * PercussionInstrument.count)
        for i in 0..<songCapacity * PercussionInstrument.count { (songAutoPerc + i).initialize(to: Atomic<Int32>(-1)) }
        events = .allocate(capacity: eventCapacity)
        patterns = .allocate(capacity: patternCapacity)
        songs = .allocate(capacity: songCapacity)
        partMain = .allocate(capacity: songCapacity * SongStore.maxParts)
        partFill = .allocate(capacity: songCapacity * SongStore.maxParts * SongStore.maxFills)
        partFillCount = .allocate(capacity: songCapacity * SongStore.maxParts)
        partFillCount.initialize(repeating: 0, count: songCapacity * SongStore.maxParts)
        partMain.initialize(repeating: -1, count: songCapacity * SongStore.maxParts)
        partFill.initialize(repeating: -1, count: songCapacity * SongStore.maxParts * SongStore.maxFills)
        bassEvents = .allocate(capacity: bassEventCapacity)
        bassPatterns = .allocate(capacity: bassPatternCapacity)
        partBass = .allocate(capacity: songCapacity * SongStore.maxParts)
        partBass.initialize(repeating: -1, count: songCapacity * SongStore.maxParts)
        partFillBass = .allocate(capacity: songCapacity * SongStore.maxParts * SongStore.maxFills)
        partFillBass.initialize(repeating: -1, count: songCapacity * SongStore.maxParts * SongStore.maxFills)
        songChords = .allocate(capacity: songCapacity * 24)
        songChords.initialize(repeating: 0, count: songCapacity * 24)
    }

    /// The chord profile of song `song` (24 values, all zero = none). Audio thread safe.
    func chordProfile(song: Int) -> UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: songChords + song * 24, count: 24)
    }

    deinit {
        events.deallocate(); patterns.deallocate(); songs.deallocate()
        partMain.deallocate(); partFill.deallocate(); partFillCount.deallocate()
        bassEvents.deallocate(); bassPatterns.deallocate(); partBass.deallocate(); partFillBass.deallocate()
        songChords.deallocate()
        percTracks.deallocate(); percPartMain.deallocate(); percPartFill.deallocate(); percPartFillCount.deallocate()
        songPerc.deinitialize(count: songCapacity * PercussionInstrument.count)
        songPerc.deallocate()
        songAutoPerc.deinitialize(count: songCapacity * PercussionInstrument.count)
        songAutoPerc.deallocate()
    }

    public var count: Int { published.load(ordering: .acquiring) }

    public enum StoreError: Error { case full, empty }

    private let publishedPatterns = Atomic<Int>(0)
    /// Patterns visible to the audio thread.
    var patternCountPublished: Int { publishedPatterns.load(ordering: .acquiring) }

    /// Adds a standalone pattern (e.g. for auditioning a file) and returns its index.
    public func addPattern(_ p: PatternData) throws -> Int32 {
        writeLock.lock(); defer { writeLock.unlock() }
        guard eventCount + p.events.count <= eventCapacity, patternCount < patternCapacity else { throw StoreError.full }
        let idx = storePattern(p)
        publishedPatterns.store(patternCount, ordering: .releasing)
        return idx
    }

    /// Appends a drum pattern (caller holds `writeLock` and has checked capacity).
    private func storePattern(_ p: PatternData) -> Int32 {
        let start = eventCount
        for (i, e) in p.events.enumerated() { events[start + i] = e }
        eventCount += p.events.count
        patterns[patternCount] = PatternRecord(start: Int32(start), count: Int32(p.events.count), length: Int32(max(p.length, 1)))
        patternCount += 1
        return Int32(patternCount - 1)
    }

    private let publishedBassPatterns = Atomic<Int>(0)
    var bassPatternCountPublished: Int { publishedBassPatterns.load(ordering: .acquiring) }

    /// Adds a standalone bass line (e.g. for auditioning a file) and returns its index.
    public func addBassPattern(_ b: BassPattern) throws -> Int32 {
        writeLock.lock(); defer { writeLock.unlock() }
        guard bassEventCount + b.events.count <= bassEventCapacity, bassPatternCount < bassPatternCapacity else { throw StoreError.full }
        let idx = storeBass(b)
        publishedBassPatterns.store(bassPatternCount, ordering: .releasing)
        return idx
    }

    private func storeBass(_ b: BassPattern) -> Int32 {
        let start = bassEventCount
        for (i, e) in b.events.enumerated() { bassEvents[start + i] = e }
        bassEventCount += b.events.count
        bassPatterns[bassPatternCount] = PatternRecord(start: Int32(start), count: Int32(b.events.count), length: Int32(max(b.length, 1)))
        bassPatternCount += 1
        return Int32(bassPatternCount - 1)
    }

    /// Number of fills of a part, and the pattern index of fill `k`.
    public func fillCount(song: Int, part: Int) -> Int { Int(partFillCount[song * SongStore.maxParts + part]) }
    func fill(song: Int, part: Int, _ k: Int) -> Int32 { partFill[(song * SongStore.maxParts + part) * SongStore.maxFills + k] }
    /// Bass pattern of a part's groove (-1 = none).
    func bass(song: Int, part: Int) -> Int32 { partBass[song * SongStore.maxParts + part] }
    /// Bass pattern of fill `k` of a part (-1 = none: the groove's bass keeps playing).
    func fillBass(song: Int, part: Int, _ k: Int) -> Int32 {
        guard k >= 0 && k < SongStore.maxFills else { return -1 }
        return partFillBass[(song * SongStore.maxParts + part) * SongStore.maxFills + k]
    }

    /// A stored bass line read back (not for the audio thread).
    func bassPattern(_ idx: Int32) -> BassPattern? {
        guard idx >= 0 else { return nil }
        let pr = bassPatterns[Int(idx)]
        return BassPattern(events: (0..<Int(pr.count)).map { bassEvents[Int(pr.start) + $0] }, length: Int(pr.length))
    }

    // MARK: Percussion layers

    private let publishedPerc = Atomic<Int>(0)
    /// Percussion layers visible to the audio thread.
    var percussionCountPublished: Int { publishedPerc.load(ordering: .acquiring) }

    /// Adds a percussion layer and returns its index. It plays once linked to a song (`setPercussion`).
    public func addPercussion(_ d: PercussionData) throws -> Int32 {
        writeLock.lock(); defer { writeLock.unlock() }
        let parts = Array(d.parts.prefix(SongStore.maxParts))
        guard !parts.isEmpty else { throw StoreError.empty }
        var needed = 0, patternsNeeded = 0
        func tally(_ p: PatternData?) { if let p { needed += p.events.count; patternsNeeded += 1 } }
        tally(d.intro); tally(d.transition); tally(d.outro)
        for p in parts { tally(p.main); for f in p.fills.prefix(SongStore.maxFills) { tally(f) } }
        guard eventCount + needed <= eventCapacity, patternCount + patternsNeeded <= patternCapacity,
              percCount < percCapacity else { throw StoreError.full }
        func addPattern(_ p: PatternData?) -> Int32 { p.map(storePattern) ?? -1 }
        var rec = PercRecord()
        rec.intro = addPattern(d.intro)
        rec.transition = addPattern(d.transition)
        rec.outro = addPattern(d.outro)
        rec.partCount = Int32(parts.count)
        let base = percCount * SongStore.maxParts
        for (i, p) in parts.enumerated() {
            percPartMain[base + i] = addPattern(p.main)
            let fills = Array(p.fills.prefix(SongStore.maxFills))
            for (k, f) in fills.enumerated() { percPartFill[(base + i) * SongStore.maxFills + k] = addPattern(f) }
            percPartFillCount[base + i] = Int8(fills.count)
        }
        percTracks[percCount] = rec
        percCount += 1
        publishedPatterns.store(patternCount, ordering: .releasing)
        publishedPerc.store(percCount, ordering: .releasing)
        return Int32(percCount - 1)
    }

    /// Plays percussion layer `track` with `song` as its `instrument` (-1 = none). Any thread, any time.
    public func setPercussion(_ track: Int32, song: Int, instrument: PercussionInstrument) {
        guard song >= 0, song < songCapacity, track < Int32(percussionCountPublished) else { return }
        songPerc[song * PercussionInstrument.count + instrument.rawValue].store(max(track, -1), ordering: .releasing)
    }

    /// The layer `song` plays as instrument `k` (-1 = none).
    func percussion(song: Int, instrument k: Int) -> Int32 {
        guard song >= 0, song < songCapacity, k >= 0, k < PercussionInstrument.count else { return -1 }
        return songPerc[song * PercussionInstrument.count + k].load(ordering: .acquiring)
    }

    /// Links a generated layer to `song` (-1 removes it). It plays only with Auto Percussion on.
    public func setAutoPercussion(_ track: Int32, song: Int, instrument: PercussionInstrument) {
        guard song >= 0, song < songCapacity, track < Int32(percussionCountPublished) else { return }
        songAutoPerc[song * PercussionInstrument.count + instrument.rawValue].store(max(track, -1), ordering: .releasing)
    }

    /// The generated layer of `song` for instrument `k` (-1 = none).
    func autoPercussion(song: Int, instrument k: Int) -> Int32 {
        guard song >= 0, song < songCapacity, k >= 0, k < PercussionInstrument.count else { return -1 }
        return songAutoPerc[song * PercussionInstrument.count + k].load(ordering: .acquiring)
    }

    func percIntro(_ t: Int32) -> Int32 { percTracks[Int(t)].intro }
    func percTransition(_ t: Int32) -> Int32 { percTracks[Int(t)].transition }
    func percOutro(_ t: Int32) -> Int32 { percTracks[Int(t)].outro }
    func percPartCount(_ t: Int32) -> Int { Int(percTracks[Int(t)].partCount) }

    /// Groove of a layer for song part `part` (its last part when it has fewer).
    func percMain(_ t: Int32, part: Int) -> Int32 {
        let n = percPartCount(t)
        guard n > 0 else { return -1 }
        return percPartMain[Int(t) * SongStore.maxParts + min(max(part, 0), n - 1)]
    }

    /// Fill of a layer for the song's fill number `k` (0-based, wraps around its fills), -1 = it has none.
    func percFill(_ t: Int32, part: Int, _ k: Int) -> Int32 {
        let n = percPartCount(t)
        guard n > 0 else { return -1 }
        let slot = Int(t) * SongStore.maxParts + min(max(part, 0), n - 1)
        let count = Int(percPartFillCount[slot])
        guard count > 0 else { return -1 }
        return percPartFill[slot * SongStore.maxFills + max(k, 0) % count]
    }

    /// Adds a song and returns its index. Thread-safe for multiple writers.
    @discardableResult
    public func add(_ song: SongData) throws -> Int {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !song.parts.isEmpty else { throw StoreError.empty }
        let parts = Array(song.parts.prefix(SongStore.maxParts))
        var needed = 0
        var patternsNeeded = 0
        var bassNeeded = 0
        var bassPatternsNeeded = 0
        func tally(_ p: PatternData?) { if let p { needed += p.events.count; patternsNeeded += 1 } }
        func tallyBass(_ b: BassPattern?) { if let b { bassNeeded += b.events.count; bassPatternsNeeded += 1 } }
        tally(song.intro); tally(song.transition); tally(song.outro)
        tallyBass(song.introBass); tallyBass(song.transitionBass); tallyBass(song.outroBass)
        for p in parts { tally(p.main); for f in p.fills.prefix(SongStore.maxFills) { tally(f) }; tallyBass(p.bass); for b in p.fillBass.prefix(min(p.fills.count, SongStore.maxFills)) { tallyBass(b) } }
        guard eventCount + needed <= eventCapacity,
              patternCount + patternsNeeded <= patternCapacity,
              bassEventCount + bassNeeded <= bassEventCapacity,
              bassPatternCount + bassPatternsNeeded <= bassPatternCapacity,
              songCount < songCapacity else { throw StoreError.full }

        func addPattern(_ p: PatternData?) -> Int32 { p.map(storePattern) ?? -1 }

        var rec = SongRecord()
        rec.tempo = Float(song.tempo)
        rec.barTicks = Int32(max(song.barTicks, 1))
        rec.beatTicks = Int32(max(song.beatTicks, 1))
        rec.intro = addPattern(song.intro)
        rec.transition = addPattern(song.transition)
        rec.outro = addPattern(song.outro)
        rec.partCount = Int32(parts.count)
        rec.introCrash = song.introCrash
        rec.fillCrash = song.fillCrash
        func addBass(_ b: BassPattern?) -> Int32 { b.map(storeBass) ?? -1 }
        rec.introBass = addBass(song.introBass)
        rec.transitionBass = addBass(song.transitionBass)
        rec.outroBass = addBass(song.outroBass)
        rec.bassEnabled = song.bassEnabled
        rec.bassRoot = Int8(((song.bassRootPitchClass % 12) + 12) % 12)
        let base = songCount * SongStore.maxParts
        for (i, p) in parts.enumerated() {
            partMain[base + i] = addPattern(p.main)
            let fills = Array(p.fills.prefix(SongStore.maxFills))
            for (k, f) in fills.enumerated() { partFill[(base + i) * SongStore.maxFills + k] = addPattern(f) }
            partFillCount[base + i] = Int8(fills.count)
            partBass[base + i] = addBass(p.bass)
            for (k, b) in p.fillBass.prefix(fills.count).enumerated() {
                partFillBass[(base + i) * SongStore.maxFills + k] = addBass(b)
            }
        }
        for i in 0..<24 { songChords[songCount * 24 + i] = i < song.chordProfile.count ? max(song.chordProfile[i], 0) : 0 }
        songs[songCount] = rec
        songCount += 1
        publishedPatterns.store(patternCount, ordering: .releasing)
        publishedBassPatterns.store(bassPatternCount, ordering: .releasing)
        published.store(songCount, ordering: .releasing)
        return songCount - 1
    }
}
