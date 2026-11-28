import Foundation

/// Bass Follow (beta): transposes the written bass line to the chords played live, from MIDI
/// chord notes (any channel but 10) or guitar audio on the AU input.
///
/// The one type the rest of PedalBeat talks to: `ChordFollower`, `ChordDetector`, the chord
/// models and Solitito stay behind it. The engine feeds it audio, MIDI and its settings; the
/// sequencer asks it for the transposition and applies pending chords on the beat.
final class BassFollow: @unchecked Sendable {
    /// Internal parts. Only the engine tests and tools (RenderTest, ChordProbe) reach in here;
    /// everything else goes through the methods below.
    let follower = ChordFollower()
    let detector = ChordDetector()
    private let on = AtomicInt(0)

    // MARK: Settings (any thread)

    var isOn: Bool { on.value != 0 }

    /// Off forgets the held and pending chords, so the bass plays as written again.
    func setOn(_ isOn: Bool) {
        on.value = isOn ? 1 : 0
        follower.enabled = isOn
        if !isOn { follower.reset() }
    }

    /// Chord model for guitar audio.
    var timbre: ChordTimbre {
        get { detector.chordTimbre }
        set { detector.chordTimbre = newValue }
    }

    /// When pending chords may become the sounding bass harmony (default: strong beats).
    var commitGrid: ChordCommitGrid {
        get { follower.commitGrid }
        set { follower.commitGrid = newValue }
    }

    func setSampleRate(_ rate: Double) { detector.setSampleRate(rate) }

    // MARK: Input (audio thread)

    /// Guitar audio. Always updates the input meter; when on, a detected chord becomes pending.
    func feedAudio(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int) {
        detector.songRoot = follower.songRoot
        // Solitito reports ~once per 0.1 s; chroma path ~once per 23 ms hop.
        follower.slowConfirmCount = detector.isSolititoActive ? 2 : 4
        let chord = detector.process(left: left, right: right, frames: frames)
        if isOn, let chord { follower.setLiveChord(chord) }
    }

    /// A MIDI note message (status without channel, note, velocity). Returns true when it was
    /// taken as a chord note, i.e. Bass Follow is on and it is not on the drum channel.
    func takeMIDINote(command: UInt8, channel: UInt8, note: UInt8, velocity: UInt8) -> Bool {
        guard isOn, channel != 9 else { return false }
        if command == 0x90 && velocity > 0 { follower.noteOn(note); return true }
        if command == 0x80 || (command == 0x90 && velocity == 0) { follower.noteOff(note); return true }
        return false
    }

    // MARK: Status (UI)

    /// Guitar input level 0…1.
    var inputLevel: Float { detector.inputLevel }
    /// The chord the bass follows (e.g. "Am"), or "—".
    var chordName: String { follower.displayName }

    // MARK: Sequencer (audio thread)

    /// Pitch class the song's bass line is written in.
    func setSongRoot(_ root: Int) { follower.songRoot = root }

    /// True while chords should be applied on beat lines.
    var followsBeats: Bool { follower.enabled }

    /// Applies the pending chord on an allowed beat, or immediately when `force` (playback start).
    func applyOnBeat(beatInBar: Int = 0, beatsPerBar: Int = 4, force: Bool = false) {
        follower.applyQuantized(beatInBar: beatInBar, beatsPerBar: beatsPerBar, force: force)
    }

    /// A written bass note moved to the current chord.
    func transposed(_ note: UInt8) -> UInt8 { ChordFollower.transpose(note, by: follower.transpose) }
}
