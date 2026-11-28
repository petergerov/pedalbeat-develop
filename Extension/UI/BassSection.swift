import SwiftUI

// MARK: - State

/// The bass track's settings as the UI shows them: master switch, level, mute, tone, and Bass
/// Follow (beta). Mirrors the AU parameters; `send` writes a change back to the parameter tree.
@MainActor
@Observable
final class BassControls {
    private(set) var isOn = true
    private(set) var volume: Double = 0.8
    private(set) var muted = false
    private(set) var kit: BassKit = .electricJazz
    private(set) var follow = false
    private(set) var timbre: ChordTimbre = .mixed
    private(set) var commitGrid: ChordCommitGrid = .strongBeats

    /// Writes a parameter (set by the view model once it can observe the tree).
    @ObservationIgnored var send: (ParamAddress, Double) -> Void = { _, _ in }

    func pull(from engine: DrumEngine) {
        isOn = engine.parameter(.bassOn) >= 0.5
        volume = Double(engine.parameter(.bassVolume))
        muted = engine.parameter(.bassMute) >= 0.5
        kit = BassKit(rawValue: Int(engine.parameter(.bassKit).rounded())) ?? .electricJazz
        follow = engine.parameter(.bassFollow) >= 0.5
        timbre = ChordTimbre(rawValue: Int(engine.parameter(.chordTimbre).rounded())) ?? .mixed
        commitGrid = ChordCommitGrid(rawValue: Int(engine.parameter(.chordCommitGrid).rounded())) ?? .strongBeats
    }

    /// Off = drums only. Bass Follow goes off with it (the engine does the same).
    func setOn(_ on: Bool) {
        isOn = on
        send(.bassOn, on ? 1 : 0)
        if !on { follow = false }
    }

    func setVolume(_ v: Double) {
        volume = min(max(v, 0), 1.5)
        send(.bassVolume, volume)
    }

    func setMuted(_ m: Bool) {
        muted = m
        send(.bassMute, m ? 1 : 0)
    }

    /// Mixer fader: shows 0 while muted, and raising it unmutes.
    var faderLevel: Double { muted ? 0 : volume }
    func setFaderLevel(_ v: Double) {
        if muted && v > 0.001 { setMuted(false) }
        setVolume(v)
    }

    func selectKit(_ k: BassKit) {
        kit = k
        send(.bassKit, Double(k.rawValue))
    }

    func setFollow(_ on: Bool) {
        follow = on && isOn
        send(.bassFollow, follow ? 1 : 0)
    }

    func selectTimbre(_ t: ChordTimbre) {
        timbre = t
        send(.chordTimbre, Double(t.rawValue))
    }

    func selectCommitGrid(_ g: ChordCommitGrid) {
        commitGrid = g
        send(.chordCommitGrid, Double(g.rawValue))
    }

    /// One line for the folded section.
    var summary: String {
        var parts = [kit.name, muted ? "Muted" : "\(Int(volume * 100))%"]
        if follow { parts.append("Follow") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Section

/// Master bass switch and, unfolded, the controls that apply when the bass is on.
struct BassSection: View {
    let bass: BassControls
    @AppStorage("bassSectionExpanded") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BassHeader(bass: bass, expanded: $expanded)
            if bass.isOn && expanded {
                BassLevelRow(bass: bass)
                BassFollowRow(bass: bass)
            }
        }
        .font(.caption)
        .toggleStyle(.switch)
        .controlSize(.mini)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panelHi.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct BassHeader: View {
    let bass: BassControls
    @Binding var expanded: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { bass.isOn }, set: { bass.setOn($0) })) {
                Text("Bass").font(.caption.weight(.bold)).foregroundStyle(Theme.dim)
            }
            .fixedSize()
            .help("Play the bass line with the drums. Off = drums only (no bass audio or MIDI).")
            if bass.isOn && !expanded {
                Text(bass.summary)
                    .font(.caption2)
                    .foregroundStyle(Theme.lcdText.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if bass.isOn {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.dim)
                .help(expanded ? "Fold the bass controls" : "Show the bass controls")
            }
        }
    }
}

private struct BassLevelRow: View {
    let bass: BassControls

    var body: some View {
        HStack(spacing: 14) {
            HStack(alignment: .bottom, spacing: 6) {
                LabeledSlider(title: "Level", value: Binding(get: { bass.volume }, set: { bass.setVolume($0) }),
                              range: 0...1.5, format: { bass.muted ? "Muted" : "\(Int($0 * 100))%" })
                    .opacity(bass.muted ? 0.5 : 1)
                Button { bass.setMuted(!bass.muted) } label: {
                    Image(systemName: bass.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(bass.muted ? Theme.accent : Theme.dim)
                .help(bass.muted ? "Unmute the bass" : "Mute the bass (its notes still go out on MIDI channel 2)")
            }
            .frame(maxWidth: 260)
            .help("Level of the bass line in songs that have one")
            BassKitMenu(bass: bass)
            Spacer(minLength: 0)
        }
    }
}

/// Bass Follow: an experimental extra, so it sits in its own row with a Beta mark.
private struct BassFollowRow: View {
    let bass: BassControls

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { bass.follow }, set: { bass.setFollow($0) })) {
                HStack(spacing: 6) {
                    Text("Bass Follow")
                    BetaBadge()
                }
            }
            .fixedSize()
            .help("Beta. Transposes the bass to the chords you play. Guitar audio: PedalBeat Drums FX on the guitar channel, or Side Chain to your guitar track. MIDI chords (any channel except 10) also work.")
            ChordTimbreMenu(bass: bass)
                .opacity(bass.follow ? 1 : 0.45)
                .disabled(!bass.follow)
            ChordCommitGridMenu(bass: bass)
                .opacity(bass.follow ? 1 : 0.45)
                .disabled(!bass.follow)
            Spacer(minLength: 0)
        }
    }
}

struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(Theme.accent)
            .overlay(Capsule().stroke(Theme.accent.opacity(0.7), lineWidth: 1))
            .help("Experimental: chord detection can be wrong or late, especially with distorted guitar.")
    }
}

// MARK: - Menus

struct BassKitMenu: View {
    let bass: BassControls

    var body: some View {
        Menu {
            ForEach(BassKit.allCases, id: \.rawValue) { k in
                Button { bass.selectKit(k) } label: {
                    if k == bass.kit { Label(k.name, systemImage: "checkmark") } else { Text(k.name) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                Text(bass.kit.name).lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(PanelButtonStyle())
        .frame(maxWidth: 220)
        .help("Bass tone for songs with a bass line")
    }
}

private struct ChordTimbreMenu: View {
    let bass: BassControls

    var body: some View {
        Menu {
            ForEach(ChordTimbre.allCases, id: \.rawValue) { t in
                Button { bass.selectTimbre(t) } label: {
                    if t == bass.timbre { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                Text(bass.timbre.name).lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Chord model for audio Bass Follow: Mixed, Guitar, Keys, Voice, or Solitito Guitar (MIT ONNX)")
    }
}

private struct ChordCommitGridMenu: View {
    let bass: BassControls

    var body: some View {
        Menu {
            ForEach(ChordCommitGrid.allCases, id: \.rawValue) { g in
                Button { bass.selectCommitGrid(g) } label: {
                    if g == bass.commitGrid { Label(g.name, systemImage: "checkmark") } else { Text(g.name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "metronome")
                Text(bass.commitGrid.name).lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("When Bass Follow may change the bass chord: every beat, strong beats (1+3; a chord the song plays a lot also on 2 and 4), or only on the bar")
    }
}
