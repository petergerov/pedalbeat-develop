# Chord Follow (guitar → bass) — plan

Branch: `feature/bass-guitar` (extends bass v1)

## Goal

You play guitar into PedalBeat. PedalBeat detects the chord and the **bass line follows** (root / groove pattern transposed to the live harmony), while drums keep the pedal song structure.

## Architecture

```
MIDI chords (any ch ≠ 10) ──┐
                            ├──► ChordFollower ──► beat-quantized transpose ──► BassSynth
Guitar AU input ──► ChordDetector (chroma)
                                      │
                         song bassRoot (demos = E)
Drums ← Sequencer (unchanged pedal behaviour)
```

## Locked decisions

| Topic | Choice |
|--------|--------|
| Order | MIDI first, then **audio** (both share `ChordFollower`). |
| Input (audio) | Stereo AU input bus **Guitar**. Host routes guitar there. |
| Detection (audio) | FFT → chroma → maj/min templates (vDSP). |
| Bass behaviour | Keep rhythmic pattern; **transpose** pitches to live root. |
| Quantize | Chord changes apply on the **next beat**. |
| AU type | `aumu` with `channelCapabilities` `[0, 2, 2, 2]`. |

## Phases

### ✅ P0 — MIDI Chord Follow

- `ChordFollower` + `ParamAddress.bassFollow`
- Song `bassRootPitchClass` (factory Bass & Drums = E = 4)
- Non–channel-10 Note On/Off → pending chord; apply on beat
- UI toggle + `FOLLOW Am` status; tests

### ✅ P1 / P2 — Guitar input + ChordDetector

- Input bus **Guitar**; capabilities `[0, 2, 2, 2]`
- Pull input in `internalRenderBlock`; `DrumEngine.feedGuitarInput`
- `ChordDetector`: 2048 FFT, hop 1024, chroma maj/min → `setLiveChord`
- Level gate + confidence; UI **GTR** meter when follow is on
- Help + Loopy docs; synthetic A-major audio test

### P3 — Polish (later)

- Sensitivity / gate knob
- Optional next-bar quantize
- Seventh / slash chords

## Loopy setup

See [loopy-pro.md](loopy-pro.md) §9 Bass Follow.

## Risks

- Distorted / heavy FX guitar confuses chroma → suggest DI or cleaner send.
- Some hosts ignore instrument inputs → MIDI follow remains the backup.
- auval / Logic need dual channel capability advertised correctly (`[0, 2, 2, 2]`).

## Out of scope (later)

- Seventh / slash chords, capo, drop-D specialized maps
- Sample bass kits
- Full transcription of guitar into notation
