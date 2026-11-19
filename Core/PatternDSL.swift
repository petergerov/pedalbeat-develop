import Foundation

// MARK: - StepGrid

/// Step grid a groove is written on.
public struct StepGrid: Sendable, Equatable {
    public let stepsPerBar: Int
    public let stepTicks: Int
    public let beatTicks: Int
    /// Count-in / pulse spacing.
    public let pulseTicks: Int
    /// Extra delay (ticks) at 100% swing for odd steps; 0 = not swingable.
    public let swingUnit: Int
    public let signature: String

    public var barTicks: Int { stepsPerBar * stepTicks }
    public var isTriplet: Bool { stepTicks == 160 }

    public static let g16   = StepGrid(stepsPerBar: 16, stepTicks: 120, beatTicks: 480, pulseTicks: 480, swingUnit: 60, signature: "4/4")
    public static let g32   = StepGrid(stepsPerBar: 32, stepTicks: 60, beatTicks: 480, pulseTicks: 480, swingUnit: 30, signature: "4/4")
    public static let g12_8 = StepGrid(stepsPerBar: 12, stepTicks: 160, beatTicks: 480, pulseTicks: 480, swingUnit: 0, signature: "12/8")
    public static let g3_4  = StepGrid(stepsPerBar: 12, stepTicks: 120, beatTicks: 480, pulseTicks: 480, swingUnit: 60, signature: "3/4")
    public static let g3_4t = StepGrid(stepsPerBar: 9, stepTicks: 160, beatTicks: 480, pulseTicks: 480, swingUnit: 0, signature: "3/4")
    public static let g6_8  = StepGrid(stepsPerBar: 12, stepTicks: 120, beatTicks: 720, pulseTicks: 240, swingUnit: 0, signature: "6/8")
    public static let g5_4  = StepGrid(stepsPerBar: 20, stepTicks: 120, beatTicks: 480, pulseTicks: 480, swingUnit: 60, signature: "5/4")
    public static let g7_8  = StepGrid(stepsPerBar: 14, stepTicks: 120, beatTicks: 240, pulseTicks: 240, swingUnit: 0, signature: "7/8")
}

// MARK: - Groove notation

/// A groove written as one text row per drum. Characters:
/// `X` accent, `x` normal, `o` soft, `g` ghost, `-`/`.` rest. Spaces and `|` are ignored.
public struct Groove: Sendable {
    public var name: String
    public var grid: StepGrid
    public var rows: [String: String]
    public var tempo: Double

    public init(_ name: String, _ grid: StepGrid = .g16, tempo: Double, _ rows: [String: String]) {
        self.name = name; self.grid = grid; self.tempo = tempo
        self.rows = rows.mapValues { Groove.clean($0) }
    }

    static func clean(_ s: String) -> String { s.filter { $0 != " " && $0 != "|" } }

    var steps: Int { rows.values.map(\.count).max() ?? grid.stepsPerBar }
    var bars: Int { max(1, Int((Double(steps) / Double(grid.stepsPerBar)).rounded(.up))) }

    static func velocity(_ c: Character) -> UInt8? {
        switch c {
        case "X": 120
        case "x": 98
        case "o": 72
        case "g": 44
        default: nil
        }
    }

    /// Converts rows to sequencer events. `bakedSwing` (0...1) is applied to odd steps.
    func events(bakedSwing: Double = 0) -> [SeqEvent] {
        var out: [SeqEvent] = []
        for (sym, row) in rows {
            guard let drum = Drum.fromSymbol(sym) else {
                assertionFailure("Unknown drum symbol \(sym) in \(name)"); continue
            }
            for (i, c) in row.enumerated() {
                guard let v = Groove.velocity(c) else { continue }
                let odd = i % 2 == 1 && grid.swingUnit > 0
                let base = i * grid.stepTicks + (odd ? Int(bakedSwing * Double(grid.swingUnit)) : 0)
                out.append(SeqEvent(tick: Int32(base), drum: UInt8(drum.rawValue), velocity: v,
                                    swingUnit: odd ? Int16(grid.swingUnit) : 0))
            }
        }
        return out
    }

    func pattern(bakedSwing: Double = 0) -> PatternData {
        PatternData(events: events(bakedSwing: bakedSwing), length: bars * grid.barTicks)
    }

    // MARK: Transforms (used to derive chorus / bridge parts)

    public enum Transform: Sendable {
        case ride, openHats, crashOnOne, rimToSnare, floorTom, tambourine, shaker, busyKick, halfTime, bell
        /// Brush sweeps one step harder (g->o, o->x, x->X): a chorus lift for brush grooves.
        case hardSweeps
    }

    func merged(_ a: String?, _ b: String) -> String {
        guard let a, !a.isEmpty else { return b }
        let n = max(a.count, b.count)
        let ca = Array(a.padding(toLength: n, withPad: "-", startingAt: 0))
        let cb = Array(b.padding(toLength: n, withPad: "-", startingAt: 0))
        return String((0..<n).map { i -> Character in
            let va = Groove.velocity(ca[i]) ?? 0, vb = Groove.velocity(cb[i]) ?? 0
            return va >= vb ? ca[i] : cb[i]
        })
    }

    func applying(_ transforms: [Transform], name: String? = nil) -> Groove {
        var g = self
        if let name { g.name = name }
        for t in transforms { g = g.applying(t) }
        return g
    }

    func applying(_ t: Transform) -> Groove {
        var g = self
        let n = steps
        let empty = String(repeating: "-", count: n)
        let pulseSteps = max(1, grid.pulseTicks / grid.stepTicks)
        let beatSteps = max(1, grid.beatTicks / grid.stepTicks)
        let eighth = grid.isTriplet ? 3 : 2
        switch t {
        case .ride:
            if let h = g.rows.removeValue(forKey: "H") { g.rows["Y"] = merged(g.rows["Y"], h) }
            if let o = g.rows.removeValue(forKey: "O") { g.rows["B"] = merged(g.rows["B"], o) }
            if g.rows["P"] == nil {
                // Hi-hat foot on the backbeats.
                var p = Array(empty)
                for i in stride(from: beatSteps, to: n, by: beatSteps * 2) { p[i] = "o" }
                g.rows["P"] = String(p)
            }
        case .bell:
            if let h = g.rows.removeValue(forKey: "H") { g.rows["B"] = merged(g.rows["B"], h) }
        case .openHats:
            if let h = g.rows.removeValue(forKey: "H") {
                var o = Array(empty)
                for (i, c) in h.enumerated() where i % eighth == 0 && c != "-" && c != "." {
                    o[i] = i % (eighth * 2) == 0 ? "x" : "o"
                }
                g.rows["O"] = merged(g.rows["O"], String(o))
            }
        case .crashOnOne:
            var x = Array(empty); x[0] = "X"
            g.rows["X"] = merged(g.rows["X"], String(x))
        case .rimToSnare:
            if let r = g.rows.removeValue(forKey: "R") {
                g.rows["S"] = merged(g.rows["S"], String(r.map { $0 == "x" || $0 == "o" ? "X" : $0 }))
            }
        case .floorTom:
            if let h = g.rows.removeValue(forKey: "H") {
                var t3 = Array(empty)
                for (i, c) in h.enumerated() where i % eighth == 0 && c != "-" && c != "." { t3[i] = "x" }
                g.rows["T3"] = merged(g.rows["T3"], String(t3))
            }
        case .tambourine:
            var m = Array(empty)
            for i in stride(from: beatSteps, to: n, by: beatSteps * 2) { m[i] = "x" }
            g.rows["M"] = merged(g.rows["M"], String(m))
        case .shaker:
            var z = Array(empty)
            let sub = grid.isTriplet ? 1 : 1
            for i in stride(from: 0, to: n, by: sub) { z[i] = i % pulseSteps == 0 ? "x" : "g" }
            g.rows["Z"] = merged(g.rows["Z"], String(z))
        case .busyKick:
            var k = Array(g.rows["K"] ?? empty)
            // Add a pickup kick a 16th/triplet before beat 3 of each bar.
            for bar in 0..<bars {
                let i = bar * grid.stepsPerBar + beatSteps * 2 - 1
                if i > 0 && i < k.count && k[i] == "-" { k[i] = "o" }
            }
            g.rows["K"] = String(k)
        case .halfTime:
            var s = Array(empty)
            for bar in 0..<bars {
                let i = bar * grid.stepsPerBar + grid.stepsPerBar / 2
                if i < n { s[i] = "X" }
            }
            g.rows["S"] = String(s)
            g.rows.removeValue(forKey: "C")
        case .hardSweeps:
            if let sw = g.rows["SW"] {
                g.rows["SW"] = String(sw.map { c -> Character in
                    switch c { case "g": "o"; case "o": "x"; case "x": "X"; default: c }
                })
            }
        }
        return g
    }

    /// The first bar of the groove as row strings.
    func firstBarRows() -> [String: String] {
        rows.mapValues { String($0.prefix(grid.stepsPerBar)) }
    }

    /// Only the time-keeping layer (hats / ride / shakers) of the first bar.
    func timekeeperRows() -> [String: String] {
        firstBarRows().filter { ["H", "Y", "P", "Z", "M", "W", "B"].contains($0.key) }
    }
}

// MARK: - Fill tails

/// A short fill phrase played over the end of a bar.
struct Tail {
    let stepTicks: Int
    let rows: [String: String]
    var steps: Int { rows.values.map { Groove.clean($0).count }.max() ?? 0 }
    var lengthTicks: Int { steps * stepTicks }

    init(_ stepTicks: Int, _ rows: [String: String]) {
        self.stepTicks = stepTicks
        self.rows = rows.mapValues { Groove.clean($0) }
    }

    func events(offset: Int) -> [SeqEvent] {
        var out: [SeqEvent] = []
        for (sym, row) in rows {
            guard let d = Drum.fromSymbol(sym) else { continue }
            for (i, c) in row.enumerated() {
                guard let v = Groove.velocity(c) else { continue }
                out.append(SeqEvent(tick: Int32(offset + i * stepTicks), drum: UInt8(d.rawValue), velocity: v))
            }
        }
        return out
    }
}

enum Tails {
    static let s16 = 120, s32 = 60, trip = 160

    // One-beat tails (16ths)
    static let beat1: [Tail] = [
        Tail(s16, ["S": "oxxX"]),
        Tail(s16, ["S": "xx--", "T3": "--xx"]),
        Tail(s16, ["T1": "xx--", "T2": "--xX"]),
        Tail(s16, ["S": "X--x", "K": "X-x-"]),
        Tail(s32, ["S": "oxoxxxxX"]),
    ]
    // Two-beat tails
    static let beat2: [Tail] = [
        Tail(s16, ["S": "oxxx xxxX"]),
        Tail(s16, ["S": "xx-- ----", "T1": "--xx ----", "T2": "---- xx--", "T3": "---- --xX"]),
        Tail(s16, ["S": "X--x --x-", "K": "X--x --x-", "T3": "---- ---x"]),
        Tail(s16, ["S": "x-xx x---", "T1": "---- -x--", "T3": "---- --xX"]),
        Tail(s16, ["T1": "xxx- ----", "T2": "---x xx--", "T3": "---- --xX"]),
        Tail(s16, ["S": "xoxo xoxo", "K": "---- ---x", "T3": "---- x-x-"]),
    ]
    // Full-bar tails (transitions / big endings)
    static let beat4: [Tail] = [
        Tail(s16, ["S": "oxxx xxxx ---- ----", "T1": "---- ---- xxxx ----", "T3": "---- ---- ---- xxxX",
                   "K": "X--- ---- X--- ----"]),
        Tail(s16, ["S": "o-o- x-x- xxxx XXXX", "K": "X--- X--- X--- X---"]),
        Tail(s16, ["T1": "xx-x x--- ---- ----", "T2": "---- -xx- x--- ----", "T3": "---- ---- -xx- xxXX",
                   "S": "---- ---- ---- x---", "K": "X--- ---- X--- ----"]),
        Tail(s16, ["S": "X--x --x- --x- -xxX", "K": "X--x --x- --x- ----", "X": "X--x --x- ---- ----"]),
        Tail(s16, ["H": "x-x- x-x- ---- ----", "S": "---- X--- xxxx ----", "T1": "---- ---- ---- xx--",
                   "T3": "---- ---- ---- --xX", "K": "X--- ---- X--- ----"]),
    ]
    // 3/4 & 6/8 full-bar tails (12 x 16th)
    static let bar12: [Tail] = [
        Tail(s16, ["S": "oxxx xxxx xxxX"]),
        Tail(s16, ["S": "xxxx ---- ----", "T1": "---- xxxx ----", "T3": "---- ---- xxxX", "K": "X--- ---- ----"]),
        Tail(s16, ["T1": "xx-- ---- ----", "T2": "--xx xx-- ----", "T3": "---- --xx xxxX", "K": "X--- ---- x---"]),
    ]
    // Half-bar 6/8 tails (6 x 16th)
    static let half6: [Tail] = [
        Tail(s16, ["S": "oxxxxX"]),
        Tail(s16, ["T1": "xx----", "T2": "--xx--", "T3": "----xX"]),
    ]
    // Triplet tails
    static let trip1: [Tail] = [
        Tail(trip, ["S": "xxX"]),
        Tail(trip, ["T1": "x--", "T2": "-x-", "T3": "--X"]),
        Tail(trip, ["S": "x-x", "K": "--x"]),
    ]
    static let trip2: [Tail] = [
        Tail(trip, ["S": "xxx xxX"]),
        Tail(trip, ["S": "xx- ---", "T1": "--x x--", "T2": "--- -x-", "T3": "--- --X"]),
        Tail(trip, ["S": "x-x x-x", "K": "--x --x", "T3": "--- ---"]),
        Tail(trip, ["S": "x-- x--", "T1": "-x- -x-", "T3": "--x --X"]),
    ]
    static let trip4: [Tail] = [
        Tail(trip, ["S": "xxx xxx --- ---", "T1": "--- --- xxx ---", "T3": "--- --- --- xxX", "K": "x-- --- x-- ---"]),
        Tail(trip, ["S": "o-o x-x xxx XXX", "K": "x-- x-- x-- x--"]),
        Tail(trip, ["S": "x-x x-x --- ---", "T2": "--- --- x-x ---", "T3": "--- --- --- xxX", "K": "x-- --- x-- ---"]),
    ]
    static let trip3bar: [Tail] = [
        Tail(trip, ["S": "x-x xxx xxX"]),
        Tail(trip, ["S": "xxx --- ---", "T1": "--- xxx ---", "T3": "--- --- xxX"]),
    ]

    /// Short tails that fit a part fill for the given grid.
    static func shortTails(for grid: StepGrid) -> [Tail] {
        if grid.isTriplet { return grid.stepsPerBar == 9 ? trip1 + trip2 : trip1 + trip2 }
        if grid == .g6_8 { return half6 }
        if grid == .g7_8 { return beat1 }
        return beat1 + beat2
    }

    /// Long tails for transitions and endings.
    static func longTails(for grid: StepGrid) -> [Tail] {
        if grid.isTriplet { return grid.stepsPerBar == 9 ? trip3bar : trip4 + trip2 }
        switch grid.stepsPerBar * grid.stepTicks {
        case 1440: return bar12
        case 1920: return beat4
        case 1680: return beat2
        default: return beat4 + beat2
        }
    }
}

// MARK: - Song construction

struct SongRecipe {
    var genre: String
    var name: String
    var parts: [Groove]
    var tempo: Double
    var bakedSwing: Double = 0
    var kitHint = 0
    var seed: Int
}

enum SongBuilder {
    static func fill(_ groove: Groove, tail: Tail, bakedSwing: Double) -> PatternData {
        let bar = groove.grid.barTicks
        let cut = max(0, bar - tail.lengthTicks)
        let base = Groove(groove.name, groove.grid, tempo: groove.tempo, groove.firstBarRows())
            .events(bakedSwing: bakedSwing)
            .filter { Int($0.tick) < cut || ($0.drum == UInt8(Drum.kick.rawValue) && Int($0.tick) == 0) }
        return PatternData(events: base + tail.events(offset: cut), length: bar)
    }

    static func countIn(_ grid: StepGrid, jazz: Bool) -> PatternData {
        var ev: [SeqEvent] = []
        let drum = jazz ? Drum.hatPedal : Drum.rim
        var i = 0
        while i * grid.pulseTicks < grid.barTicks {
            let accent = i == 0
            ev.append(SeqEvent(tick: Int32(i * grid.pulseTicks), drum: UInt8(drum.rawValue), velocity: accent ? 120 : 92))
            i += 1
        }
        return PatternData(events: ev, length: grid.barTicks)
    }

    static func timekeeperIntro(_ groove: Groove, tail: Tail, bakedSwing: Double) -> PatternData {
        var rows = groove.timekeeperRows()
        if rows.isEmpty { rows = ["P": String(repeating: "x---", count: groove.grid.stepsPerBar / 4)] }
        let tk = Groove(groove.name, groove.grid, tempo: groove.tempo, rows)
        let bar = groove.grid.barTicks
        let first = tk.events(bakedSwing: bakedSwing)
        let second = fill(tk, tail: tail, bakedSwing: bakedSwing).events.map {
            var e = $0; e.tick += Int32(bar); return e
        }
        return PatternData(events: first + second, length: bar * 2)
    }

    static func outro(_ groove: Groove, tail: Tail, bakedSwing: Double) -> PatternData {
        let bar = groove.grid.barTicks
        var ev = fill(groove, tail: tail, bakedSwing: bakedSwing).events
        ev.append(SeqEvent(tick: Int32(bar), drum: UInt8(Drum.crash.rawValue), velocity: 124))
        ev.append(SeqEvent(tick: Int32(bar), drum: UInt8(Drum.kick.rawValue), velocity: 120))
        return PatternData(events: ev, length: bar + groove.grid.stepTicks)
    }

    static func build(_ r: SongRecipe) -> SongData {
        let first = r.parts[0]
        let grid = first.grid
        let shorts = Tails.shortTails(for: grid)
        let longs = Tails.longTails(for: grid)
        let jazz = r.genre == "Jazz"
        var parts: [PartData] = []
        for (i, g) in r.parts.enumerated() {
            // Three different fills per part (short tails first, then a longer one if needed).
            let pool = (0..<shorts.count).map { shorts[(r.seed + i * 3 + $0) % shorts.count] }
                + (0..<longs.count).map { longs[(r.seed + i + $0) % longs.count] }
            let fills = pool.prefix(3).map { fill(g, tail: $0, bakedSwing: r.bakedSwing) }
            parts.append(PartData(main: g.pattern(bakedSwing: r.bakedSwing), fills: Array(fills)))
        }
        let transition = fill(first, tail: longs[(r.seed + 1) % longs.count], bakedSwing: r.bakedSwing)

        let intro: PatternData
        var introCrash = true
        switch r.seed % 3 {
        case 0:
            intro = countIn(grid, jazz: jazz); introCrash = false
        case 1:
            intro = timekeeperIntro(first, tail: shorts[r.seed % shorts.count], bakedSwing: r.bakedSwing)
        default:
            intro = fill(first, tail: longs[r.seed % longs.count], bakedSwing: r.bakedSwing)
        }
        let outroTail = r.seed % 2 == 0 ? longs[(r.seed + 2) % longs.count] : shorts[(r.seed + 1) % shorts.count]
        let out = outro(r.parts.last!, tail: outroTail, bakedSwing: r.bakedSwing)

        return SongData(name: r.name, genre: r.genre, tempo: r.tempo, timeSignature: grid.signature,
                        barTicks: grid.barTicks, beatTicks: grid.beatTicks, intro: intro, parts: parts,
                        transition: transition, outro: out, introCrash: introCrash, fillCrash: true,
                        kitHint: r.kitHint)
    }
}
