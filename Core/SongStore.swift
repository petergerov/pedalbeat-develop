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

public struct PartData: Sendable {
    public var main: PatternData
    /// Up to `SongStore.maxFills` fills; the pedal plays them in order or at random.
    public var fills: [PatternData]
    public var fill: PatternData? { fills.first }
    public init(main: PatternData, fill: PatternData?) { self.main = main; self.fills = fill.map { [$0] } ?? [] }
    public init(main: PatternData, fills: [PatternData]) { self.main = main; self.fills = fills }
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

    public init(name: String, genre: String, tempo: Double, timeSignature: String, barTicks: Int, beatTicks: Int,
                intro: PatternData?, parts: [PartData], transition: PatternData?, outro: PatternData?,
                introCrash: Bool = true, fillCrash: Bool = true, kitHint: Int = 0, isUser: Bool = false, key: String? = nil) {
        self.name = name; self.genre = genre; self.tempo = tempo; self.timeSignature = timeSignature
        self.barTicks = barTicks; self.beatTicks = beatTicks; self.intro = intro; self.parts = parts
        self.transition = transition; self.outro = outro; self.introCrash = introCrash; self.fillCrash = fillCrash
        self.kitHint = kitHint; self.isUser = isUser; self.key = key ?? "\(genre)/\(name)"
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

    private var eventCount = 0
    private var patternCount = 0
    private var songCount = 0
    private let published = Atomic<Int>(0)
    private let writeLock = NSLock()

    public init(eventCapacity: Int = 1_000_000, patternCapacity: Int = 32_768, songCapacity: Int = 4096) {
        self.eventCapacity = eventCapacity
        self.patternCapacity = patternCapacity
        self.songCapacity = songCapacity
        events = .allocate(capacity: eventCapacity)
        patterns = .allocate(capacity: patternCapacity)
        songs = .allocate(capacity: songCapacity)
        partMain = .allocate(capacity: songCapacity * SongStore.maxParts)
        partFill = .allocate(capacity: songCapacity * SongStore.maxParts * SongStore.maxFills)
        partFillCount = .allocate(capacity: songCapacity * SongStore.maxParts)
        partFillCount.initialize(repeating: 0, count: songCapacity * SongStore.maxParts)
        partMain.initialize(repeating: -1, count: songCapacity * SongStore.maxParts)
        partFill.initialize(repeating: -1, count: songCapacity * SongStore.maxParts * SongStore.maxFills)
    }

    deinit {
        events.deallocate(); patterns.deallocate(); songs.deallocate()
        partMain.deallocate(); partFill.deallocate(); partFillCount.deallocate()
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
        let start = eventCount
        for (i, e) in p.events.enumerated() { events[start + i] = e }
        eventCount += p.events.count
        patterns[patternCount] = PatternRecord(start: Int32(start), count: Int32(p.events.count), length: Int32(max(p.length, 1)))
        patternCount += 1
        publishedPatterns.store(patternCount, ordering: .releasing)
        return Int32(patternCount - 1)
    }

    /// Number of fills of a part, and the pattern index of fill `k`.
    public func fillCount(song: Int, part: Int) -> Int { Int(partFillCount[song * SongStore.maxParts + part]) }
    func fill(song: Int, part: Int, _ k: Int) -> Int32 { partFill[(song * SongStore.maxParts + part) * SongStore.maxFills + k] }

    /// Adds a song and returns its index. Thread-safe for multiple writers.
    @discardableResult
    public func add(_ song: SongData) throws -> Int {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !song.parts.isEmpty else { throw StoreError.empty }
        let parts = Array(song.parts.prefix(SongStore.maxParts))
        var needed = 0
        var patternsNeeded = 0
        func tally(_ p: PatternData?) { if let p { needed += p.events.count; patternsNeeded += 1 } }
        tally(song.intro); tally(song.transition); tally(song.outro)
        for p in parts { tally(p.main); for f in p.fills.prefix(SongStore.maxFills) { tally(f) } }
        guard eventCount + needed <= eventCapacity,
              patternCount + patternsNeeded <= patternCapacity,
              songCount < songCapacity else { throw StoreError.full }

        func addPattern(_ p: PatternData?) -> Int32 {
            guard let p else { return -1 }
            let start = eventCount
            for (i, e) in p.events.enumerated() { events[start + i] = e }
            eventCount += p.events.count
            patterns[patternCount] = PatternRecord(start: Int32(start), count: Int32(p.events.count),
                                                   length: Int32(max(p.length, 1)))
            patternCount += 1
            return Int32(patternCount - 1)
        }

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
        let base = songCount * SongStore.maxParts
        for (i, p) in parts.enumerated() {
            partMain[base + i] = addPattern(p.main)
            let fills = Array(p.fills.prefix(SongStore.maxFills))
            for (k, f) in fills.enumerated() { partFill[(base + i) * SongStore.maxFills + k] = addPattern(f) }
            partFillCount[base + i] = Int8(fills.count)
        }
        songs[songCount] = rec
        songCount += 1
        publishedPatterns.store(patternCount, ordering: .releasing)
        published.store(songCount, ordering: .releasing)
        return songCount - 1
    }
}
