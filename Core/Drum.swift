import Foundation

/// The drum voices of the built-in kit. `brushSweep` is a sustained brush stir
/// that lasts until the next sweep (or two beats) — see `Sampler`.
public enum Drum: Int, CaseIterable, Sendable {
    case kick = 0, snare, rim, clap, hatClosed, hatPedal, hatOpen, ride, rideBell, crash,
         tomHigh, tomMid, tomLow, cowbell, shaker, tambourine, brushSweep

    public static let count = 17

    /// General MIDI percussion note used for MIDI output.
    public var gmNote: UInt8 {
        switch self {
        case .kick: 36
        case .snare: 38
        case .rim: 37
        case .clap: 39
        case .hatClosed: 42
        case .hatPedal: 44
        case .hatOpen: 46
        case .ride: 51
        case .rideBell: 53
        case .crash: 49
        case .tomHigh: 48
        case .tomMid: 45
        case .tomLow: 41
        case .cowbell: 56
        case .shaker: 70
        case .tambourine: 54
        case .brushSweep: 88   // no GM equivalent; dedicated note, same for MIDI in and out
        }
    }

    public var displayName: String {
        switch self {
        case .kick: "Kick"
        case .snare: "Snare"
        case .rim: "Side Stick"
        case .clap: "Clap"
        case .hatClosed: "Hi-Hat Closed"
        case .hatPedal: "Hi-Hat Pedal"
        case .hatOpen: "Hi-Hat Open"
        case .ride: "Ride"
        case .rideBell: "Ride Bell"
        case .crash: "Crash"
        case .tomHigh: "High Tom"
        case .tomMid: "Mid Tom"
        case .tomLow: "Floor Tom"
        case .cowbell: "Cowbell"
        case .shaker: "Shaker"
        case .tambourine: "Tambourine"
        case .brushSweep: "Brush Sweep"
        }
    }

    /// Maps an incoming General MIDI percussion note to a kit voice.
    public static func fromGM(_ note: UInt8) -> Drum? {
        switch note {
        case 35, 36: .kick
        case 37, 75, 76, 77: .rim
        case 38, 40: .snare
        case 39: .clap
        case 42: .hatClosed
        case 44: .hatPedal
        case 46: .hatOpen
        case 51, 59: .ride
        case 53: .rideBell
        case 49, 52, 55, 57: .crash
        case 41, 43, 64, 66, 68: .tomLow
        case 45, 47, 62, 63, 65: .tomMid
        case 48, 50, 60, 61, 67: .tomHigh
        case 56: .cowbell
        case 54: .tambourine
        case 69, 70, 82: .shaker
        case 88: .brushSweep
        default: nil
        }
    }

    /// Row symbols used by the groove notation in the factory library.
    public static func fromSymbol(_ s: String) -> Drum? {
        switch s {
        case "K": .kick
        case "S": .snare
        case "R": .rim
        case "C": .clap
        case "H": .hatClosed
        case "P": .hatPedal
        case "O": .hatOpen
        case "Y": .ride
        case "B": .rideBell
        case "X": .crash
        case "T1": .tomHigh
        case "T2": .tomMid
        case "T3": .tomLow
        case "W": .cowbell
        case "Z": .shaker
        case "M": .tambourine
        case "SW": .brushSweep
        default: nil
        }
    }
}

/// Pulses per quarter note used throughout the sequencer.
public let PPQN = 480

/// Stereo output buses for multi-out hosting. Bus 0 is always the full mix;
/// buses 1… are subgroups so a DAW (or the standalone host) can insert real AU/AUv3
/// plugins per group. Nesting AUs *inside* the PedalBeat AUv3 appex is not supported.
public enum MixBus: Int, CaseIterable, Sendable {
    case master = 0, kick, snare, hats, toms, cymbals, perc

    public static let count = MixBus.allCases.count

    public var displayName: String {
        switch self {
        case .master: "Master"
        case .kick: "Kick"
        case .snare: "Snare"
        case .hats: "Hats"
        case .toms: "Toms"
        case .cymbals: "Cymbals"
        case .perc: "Perc"
        }
    }

    public static func forDrum(_ drum: Drum) -> MixBus {
        switch drum {
        case .kick: .kick
        case .snare, .rim, .clap: .snare
        case .hatClosed, .hatPedal, .hatOpen: .hats
        case .tomHigh, .tomMid, .tomLow: .toms
        case .ride, .rideBell, .crash: .cymbals
        case .cowbell, .shaker, .tambourine, .brushSweep: .perc
        }
    }

    public static func forDrumIndex(_ index: Int) -> MixBus {
        MixBus.forDrum(Drum(rawValue: index) ?? .kick)
    }
}
