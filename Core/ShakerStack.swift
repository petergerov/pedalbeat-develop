import Foundation

/// Shaker stack: the percussion-layer shaker played by up to `laneCount` shaker sounds at once (lanes,
/// each with its own level and pan), with real stroke motion (forward strokes on the beats, back strokes
/// in between, for kits that have both) and a pocket: the whole shaker earlier or later in milliseconds,
/// plus a feel that pushes or lays back its off-beats.

/// Sound of one shaker lane.
public enum ShakerSource: Int, CaseIterable, Sendable, Identifiable {
    /// Lane off.
    case off = 0
    /// The shaker of the Percussion Kit menu (layer kit, else the drum kit): the classic single shaker.
    case percKit
    /// Egg shaker, two velocity layers (GoranGrooves World Percussion; Layer World kit).
    case worldEgg
    /// Egg shaker (FreePats World Percussion, CC0; Layer FreePats kit).
    case freepatsEgg
    /// Shaker with separate forward and back strokes (Virtuosity Drums, CC0).
    case virtuosity
    /// One-shot shaker of World Percussion Plus (the Layer World shaker before the WP egg).
    case wpPlus

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .off: "Off"
        case .percKit: "Perc Kit"
        case .worldEgg: "World Egg"
        case .freepatsEgg: "FreePats Egg"
        case .virtuosity: "Virtuosity (Strokes)"
        case .wpPlus: "World Plus"
        }
    }

    /// Bundled `.pbkit` whose shaker the lane plays; `nil` for Off and Perc Kit.
    public var sampleKitID: String? {
        switch self {
        case .off, .percKit: nil
        case .worldEgg: PercLayerKit.world.sampleKitID
        case .freepatsEgg: PercLayerKit.freepats.sampleKitID
        case .virtuosity: "pedalbeat.shaker-virtuosity"
        case .wpPlus: "pedalbeat.shaker-wpplus"
        }
    }
}

/// How the shaker's off-beats sit against the grid.
public enum ShakerFeel: Int, CaseIterable, Sendable, Identifiable {
    case grid = 0, push, laidBack

    public var id: Int { rawValue }
    public var name: String {
        switch self {
        case .grid: "Grid"
        case .push: "Push"
        case .laidBack: "Laid Back"
        }
    }
}

public enum ShakerStack {
    public static let laneCount = 3
    /// Pocket range in milliseconds (negative = ahead of the beat).
    public static let pocketRange: ClosedRange<Float> = -30...30
    /// Stereo width of the shaker voices (0 = mono, 1 = as recorded).
    public static let widthRange: ClosedRange<Float> = 0...1.5
    /// Defaults: lane 1 plays the Perc Kit shaker (as before), the other lanes are off.
    public static let defaultSources: [ShakerSource] = [.percKit, .off, .off]
    public static let defaultLevels: [Float] = [1, 0.8, 0.8]
    public static let defaultPans: [Float] = [0, -0.35, 0.35]

    public enum LaneParameter: Sendable { case source, level, pan }

    /// The AU parameter of one lane setting.
    public static func address(lane: Int, _ kind: LaneParameter) -> ParamAddress {
        let base = ParamAddress.shakerLane1Source.rawValue + UInt64(lane * 3)
        switch kind {
        case .source: return ParamAddress(rawValue: base)!
        case .level: return ParamAddress(rawValue: base + 1)!
        case .pan: return ParamAddress(rawValue: base + 2)!
        }
    }

    /// Lane and setting of a lane parameter, nil for any other parameter.
    public static func lane(of address: ParamAddress) -> (lane: Int, kind: LaneParameter)? {
        let first = ParamAddress.shakerLane1Source.rawValue
        guard address.rawValue >= first, address.rawValue < first + UInt64(laneCount * 3) else { return nil }
        let i = Int(address.rawValue - first)
        return (i / 3, [LaneParameter.source, .level, .pan][i % 3])
    }

    /// Whether a shaker hit at `tick` (unswung, in its pattern) is a back stroke. A player moves the
    /// shaker forward on the beat and back between: in a pattern with 16ths forward on every 8th,
    /// otherwise forward on every beat.
    public static func isBackStroke(tick: Int, dense: Bool) -> Bool {
        let step = dense ? PPQN / 2 : PPQN
        return tick % step != 0
    }

    /// Whether a pattern's shaker plays 16ths (hits off the 8th grid): then 8ths are forward strokes.
    public static func isDense(ticks: some Sequence<Int>) -> Bool {
        ticks.contains { $0 % (PPQN / 2) != 0 }
    }

    /// Feel offset in ticks for a hit at `tick`: beats stay, off-beat 8ths move 6 % and 16ths 10 % of a
    /// 16th (Push earlier, Laid Back later), so the feel scales with the tempo.
    public static func feelTicks(tick: Int, feel: ShakerFeel) -> Double {
        guard feel != .grid else { return 0 }
        let inBeat = tick % PPQN
        guard inBeat != 0 else { return 0 }
        let amount = Double(PPQN / 4) * (inBeat % (PPQN / 2) != 0 ? 0.10 : 0.06)
        return feel == .push ? -amount : amount
    }
}
