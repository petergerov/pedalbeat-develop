import Foundation
import Synchronization

/// The pedal actions a MIDI message can be assigned to in MIDI Settings.
public enum MIDIAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case pedalTap, startStop, fill, transition, outro, stop, accent, pauseResume, nextSong, prevSong

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pedalTap: "Pedal Tap"
        case .startStop: "Start / Stop"
        case .fill: "Fill"
        case .transition: "Transition / Next Part"
        case .outro: "Outro"
        case .stop: "Stop Now"
        case .accent: "Accent"
        case .pauseResume: "Pause / Resume"
        case .nextSong: "Next Song"
        case .prevSong: "Previous Song"
        }
    }

    public var command: PedalCommand {
        switch self {
        case .pedalTap: .pedalTap
        case .startStop: .startStop
        case .fill: .fill
        case .transition: .transition
        case .outro: .outro
        case .stop: .stop
        case .accent: .accent
        case .pauseResume: .pauseResume
        case .nextSong: .nextSong
        case .prevSong: .prevSong
        }
    }
}

/// A MIDI message that presses an action, on any channel.
public struct MIDITrigger: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case controlChange, note, programChange
    }

    public var kind: Kind
    public var number: UInt8
    /// For a Control Change: every message is a press, whatever its value. Some pedals send
    /// one message per press at value 0; a plain footswitch sends 127 going down and 0 coming
    /// back up, and only the first counts.
    public var firesOnAnyValue = false

    /// The trigger Learn takes from a received MIDI 1.0 message: a Control Change at any
    /// value — below 64 it can only be a pedal that sends one message per press — a Note On,
    /// or a Program Change.
    public init?(status: UInt8, data1: UInt8, data2: UInt8) {
        guard data1 < 0x80 else { return nil }
        switch status & 0xF0 {
        case 0xB0: self.init(kind: .controlChange, number: data1, firesOnAnyValue: data2 < 64)
        case 0x90 where data2 > 0: self.init(kind: .note, number: data1)
        case 0xC0: self.init(kind: .programChange, number: data1)
        default: return nil
        }
    }

    public init(kind: Kind, number: UInt8, firesOnAnyValue: Bool = false) {
        self.kind = kind
        self.number = number
        self.firesOnAnyValue = firesOnAnyValue
    }

    public func isPressed(status: UInt8, data1: UInt8, data2: UInt8) -> Bool {
        guard data1 == number else { return false }
        switch kind {
        case .controlChange: return status & 0xF0 == 0xB0 && (firesOnAnyValue || data2 >= 64)
        case .note: return status & 0xF0 == 0x90 && data2 > 0
        case .programChange: return status & 0xF0 == 0xC0
        }
    }

    /// Same message, whatever the value rule: one of them per action.
    public func sharesMessage(with other: MIDITrigger) -> Bool {
        kind == other.kind && number == other.number
    }

    public var title: String {
        switch kind {
        case .controlChange: "CC \(number)"
        case .note: "Note \(number) (\(Self.noteName(number)))"
        case .programChange: "Program Change \(number)"
        }
    }

    /// Middle C (60) is C3, as Logic and GarageBand label it.
    public static func noteName(_ number: UInt8) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[Int(number) % 12])\(Int(number) / 12 - 2)"
    }
}

/// Which MIDI message presses which action. Saved for every project and host.
public struct MIDIMappings: Codable, Equatable, Sendable {
    public var triggers: [MIDIAction: MIDITrigger]
    /// Program Change n selects song n (0-based), unless an action claims that program.
    public var programChangeSelectsSong: Bool

    public init(triggers: [MIDIAction: MIDITrigger], programChangeSelectsSong: Bool = true) {
        self.triggers = triggers
        self.programChangeSelectsSong = programChangeSelectsSong
    }

    /// Notes 0–9, the layout Help and docs/Loopy-Pro-MIDI.md describe.
    public static let `default` = MIDIMappings(triggers: [
        .pedalTap: MIDITrigger(kind: .note, number: 0),
        .startStop: MIDITrigger(kind: .note, number: 1),
        .fill: MIDITrigger(kind: .note, number: 2),
        .transition: MIDITrigger(kind: .note, number: 3),
        .outro: MIDITrigger(kind: .note, number: 4),
        .stop: MIDITrigger(kind: .note, number: 5),
        .accent: MIDITrigger(kind: .note, number: 6),
        .pauseResume: MIDITrigger(kind: .note, number: 7),
        .nextSong: MIDITrigger(kind: .note, number: 8),
        .prevSong: MIDITrigger(kind: .note, number: 9),
    ])

    public func command(status: UInt8, data1: UInt8, data2: UInt8) -> PedalCommand? {
        action(status: status, data1: data1, data2: data2)?.command
    }

    /// The song (0-based) a Program Change selects, if that's on and no action claims the program.
    public func selectedSong(status: UInt8, data1: UInt8, data2: UInt8) -> Int? {
        guard status & 0xF0 == 0xC0, programChangeSelectsSong,
              action(status: status, data1: data1, data2: data2) == nil else { return nil }
        return Int(data1)
    }

    private func action(status: UInt8, data1: UInt8, data2: UInt8) -> MIDIAction? {
        MIDIAction.allCases.first { triggers[$0]?.isPressed(status: status, data1: data1, data2: data2) == true }
    }

    /// One trigger per action and one action per trigger: assigning takes the trigger away
    /// from whichever action had it.
    public mutating func assign(_ trigger: MIDITrigger, to action: MIDIAction) {
        for other in MIDIAction.allCases where triggers[other]?.sharesMessage(with: trigger) == true {
            triggers[other] = nil
        }
        triggers[action] = trigger
    }

    // MARK: Storage

    private static let defaultsKey = "midiMappings"
    /// Posted in this process after `save`, so every PedalBeat instance follows MIDI Settings.
    public static let didChange = Notification.Name("PedalBeatMIDIMappingsDidChange")

    public static func load(from defaults: UserDefaults = .standard) -> MIDIMappings {
        guard let data = defaults.data(forKey: defaultsKey),
              let mappings = try? JSONDecoder().decode(MIDIMappings.self, from: data) else { return .default }
        return mappings
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

// MARK: - Audio thread

/// `MIDIMappings` as the audio thread reads them: the command each Note, Control Change and
/// Program Change number sends. Every entry is its own atomic, so MIDI Settings can rewrite
/// the table while MIDI arrives. One action per message, as `MIDIMappings.assign` keeps it.
final class MIDIControlTable: @unchecked Sendable {
    private static let size = 3 * 128
    /// 0 = none, else a `PedalCommand` raw value; bit 7 marks a CC that fires on any value.
    private let entries: UnsafeMutablePointer<Atomic<UInt8>>
    private let selectsSong = Atomic<Bool>(true)
    private let writeLock = NSLock()   // serializes writers (never taken on the audio thread)

    init(_ mappings: MIDIMappings = .default) {
        entries = .allocate(capacity: Self.size)
        for i in 0..<Self.size { (entries + i).initialize(to: Atomic(0)) }
        update(mappings)
    }

    deinit {
        entries.deinitialize(count: Self.size)
        entries.deallocate()
    }

    func update(_ mappings: MIDIMappings) {
        var table = [UInt8](repeating: 0, count: Self.size)
        // Reversed: the first action with a message keeps it, as in `MIDIMappings.command`.
        for action in MIDIAction.allCases.reversed() {
            guard let t = mappings.triggers[action], t.number < 0x80 else { continue }
            table[Self.index(t.kind, t.number)] = UInt8(action.command.rawValue) | (t.firesOnAnyValue ? 0x80 : 0)
        }
        writeLock.withLock {
            for i in 0..<Self.size { entries[i].store(table[i], ordering: .relaxed) }
            selectsSong.store(mappings.programChangeSelectsSong, ordering: .relaxed)
        }
    }

    var programChangeSelectsSong: Bool { selectsSong.load(ordering: .relaxed) }

    func command(status: UInt8, data1: UInt8, data2: UInt8) -> PedalCommand? {
        guard data1 < 0x80 else { return nil }
        let kind: MIDITrigger.Kind
        switch status & 0xF0 {
        case 0x90 where data2 > 0: kind = .note
        case 0xB0: kind = .controlChange
        case 0xC0: kind = .programChange
        default: return nil
        }
        let entry = entries[Self.index(kind, data1)].load(ordering: .relaxed)
        if kind == .controlChange, entry & 0x80 == 0, data2 < 64 { return nil }
        return PedalCommand(rawValue: Int(entry & 0x7F))
    }

    private static func index(_ kind: MIDITrigger.Kind, _ number: UInt8) -> Int {
        let base = switch kind {
        case .note: 0
        case .controlChange: 128
        case .programChange: 256
        }
        return base + Int(number & 0x7F)
    }
}

/// The MIDI the engine receives, for MIDI Settings (Learn, Last Received). A lock-free
/// single-producer (audio thread) / single-consumer (UI) queue that only fills while the UI listens.
public final class MIDIMonitor: @unchecked Sendable {
    /// A MIDI 1.0 channel voice message.
    public struct Message: Equatable, Sendable {
        public var status: UInt8
        public var data1: UInt8
        public var data2: UInt8

        /// "CC 80 · value 127 · channel 1", for Last Received.
        public var summary: String {
            let channel = Int(status & 0x0F) + 1
            switch status & 0xF0 {
            case 0xB0: return "CC \(data1) · value \(data2) · channel \(channel)"
            case 0x90: return "Note On \(data1) · velocity \(data2) · channel \(channel)"
            case 0x80: return "Note Off \(data1) · channel \(channel)"
            default: return "Program Change \(data1) · channel \(channel)"
            }
        }
    }

    private let capacity = 64
    private let buffer: UnsafeMutablePointer<UInt32>
    private let head = Atomic<Int>(0)   // next write slot (audio thread)
    private let tail = Atomic<Int>(0)   // next read slot (UI)
    private let listening = Atomic<Bool>(false)
    private let learning = Atomic<Bool>(false)

    init() {
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }
    deinit { buffer.deallocate() }

    /// MIDI Settings is open: what arrives is kept for `drain`. Turning it off also ends Learn.
    public var isListening: Bool {
        get { listening.load(ordering: .relaxed) }
        set {
            // Starting over: drop what an earlier session left unread.
            if newValue { tail.store(head.load(ordering: .acquiring), ordering: .releasing) }
            else { learning.store(false, ordering: .relaxed) }
            listening.store(newValue, ordering: .relaxed)
        }
    }

    /// Learn is waiting: the next press (Note On, Control Change or Program Change) is only
    /// reported, not played. The audio thread clears it after that press.
    public var isLearning: Bool {
        get { learning.load(ordering: .relaxed) }
        set { learning.store(newValue && isListening, ordering: .relaxed) }
    }

    /// Audio thread: keeps Note, Control Change and Program Change messages while listening.
    func record(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        guard listening.load(ordering: .relaxed) else { return }
        switch status & 0xF0 {
        case 0x80, 0x90, 0xB0, 0xC0: break
        default: return
        }
        let h = head.load(ordering: .relaxed)
        let next = (h + 1) % capacity
        guard next != tail.load(ordering: .acquiring) else { return }   // full: drop
        buffer[h] = UInt32(status) << 16 | UInt32(data1) << 8 | UInt32(data2)
        head.store(next, ordering: .releasing)
    }

    /// Audio thread: true for the press Learn takes, which must not also play.
    func takesForLearn(_ status: UInt8, _ data2: UInt8) -> Bool {
        guard learning.load(ordering: .relaxed) else { return false }
        switch status & 0xF0 {
        case 0xB0, 0xC0: break
        case 0x90 where data2 > 0: break
        default: return false
        }
        learning.store(false, ordering: .relaxed)
        return true
    }

    /// UI: what arrived since the last call, oldest first.
    public func drain() -> [Message] {
        var messages: [Message] = []
        var t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        while t != h {
            let word = buffer[t]
            messages.append(Message(status: UInt8(word >> 16 & 0xFF), data1: UInt8(word >> 8 & 0xFF), data2: UInt8(word & 0xFF)))
            t = (t + 1) % capacity
        }
        tail.store(t, ordering: .releasing)
        return messages
    }
}
