# Bass guitar — implementation plan

Branch: `feature/bass-guitar`

## Decisions (locked)

| Topic | Choice |
|--------|--------|
| Sound for v1 | **Synth bass** (always available, any key) |
| Later | **Sample bass kits** plug into the **same** note track |
| Model | Separate **bass track** (not bb-style fake drum notes) |
| Fills (default) | **Bass keeps going** — during a drum fill, the part’s main bass line continues |
| Transitions / outro | Bass follows that section’s own bass pattern if present; otherwise keep the current part’s main bass (configurable later) |

Singular Sound / bb does *not* ship first-class bass: community kits map bass samples into MIDI note ranges and merge bass into the drum MIDI. PedalBeat will do it properly with a dedicated track + engines.

---

## Architecture

```
Song section (intro / part main / fill / transition / outro)
  ├── drum PatternData          (existing)
  └── optional BassPattern      (new) — pitched notes on the same tick grid

Playback
  ├── DrumEngine / Sequencer    (drums as today)
  └── Bass voice
        ├── v1: BassSynth
        └── later: BassSampler (kit)  ← same BassEvent stream
```

**Fill rule (default):** while `PlayState.fill`, sequencer keeps advancing/playing the **current part’s main bass pattern** (loop), not a fill-specific bass line. Drum fills stay drum-only unless a song later adds optional fill bass.

---

## v1 — ship synth + track + editor

### 1. Data model (`Core/`)

- `BassEvent`: `tick`, `note` (MIDI 0–127), `velocity`, optional `durationTicks` (or note-off via length).
- `BassPattern`: sorted events + `length` (same tick units as drums: `barTicks` / `beatTicks`).
- Attach optional bass to:
  - song `intro`, `outro`, `transition`
  - each `PartData.main` (required for “bass keeps going” on fills)
  - fills: **not required in v1**; ignored for playback by default
- Song-level: `key` (e.g. pitch class / MIDI root), `bassEnabled`, `bassVolume` (or use mixer only).
- Persist in `song.json` / library import (extend `MIDISongImporter.SongLayout` + `SongFile`).
- `SongStore`: parallel bass event/pattern buffers (or shared event pool with a `kind` flag) — realtime-safe like drums.

### 2. Synth (`Core/Bass/BassSynth.swift`)

- Monophonic or lightly polyphonic (2–3 voices) electric-bass style: saw/square → lowpass → simple amp envelope.
- Note on/off from sequencer; glide optional later.
- Parameters: level, filter cutoff, (optional) drive — expose level on mixer first.

### 3. Sequencer / engine

- On each section: load drum pattern as today; also load **bass pattern for that section**.
- **Fill:** drums switch to fill pattern; **bass stays on part main bass** (default).
- Pause/stop clears bass voices; tempo/swing: bass uses the same tick clock (swing on bass optional, off in v1).
- Mixer: **Bass** fader + mute; optional multi-out bus later.
- MIDI out: drums channel 10; bass on a melodic channel (e.g. **2**), note = pitch.

### 4. UI

- Mix row / Mix Song: Bass level (+ mute).
- Song editor: per slot (intro, part groove, …) show **Bass** sub-slot:
  - empty / import MIDI (non-drum notes) / clear
  - preview with current kit + bass synth
- Toggle **Bass on** per song (default on if any bass patterns exist).
- Help: one short note — bass continues under fills.

### 5. Content & import

- A few factory or demo songs with bass on part mains (synth only).
- Import MIDI: notes outside GM drum range → bass track; drums unchanged.
- No sample kits in v1.

### 6. Tests

- Store round-trip with bass patterns.
- Fill: drums change, bass events keep part-main timeline.
- MIDI out: bass notes on ch 2, drums on 10.
- Engine render: audible bass + drums, mute bass → drums only.

### v1 out of scope

- Sample bass kits  
- Per-fill bass patterns  
- Auto-harmonize / AI bass  
- Ableton Link for bass  
- bb `.DRM` bass kit import  

---

## Later — sample bass kits

### Goal

Same `BassEvent` stream; user (or song) selects **BassSynth** or a **BassKit** (samples).

### Work

1. `BassKit` package (range, root note, velocity layers, RR) — mirror `.pbkit` ideas or a slim `.pbbass`.
2. `BassSampler` realtime voice (pitch from closest sample + rate, or chromatic set).
3. Kit picker next to drum kit: Synth | installed bass kits.
4. Song `bassKitHint` (id) like `kitHint`.
5. Mixer still one Bass bus.
6. Docs: how to build/import a bass kit; key/range expectations.

No change to song note data when switching engines.

---

## Suggested milestones

| Milestone | Deliverable |
|-----------|-------------|
| M1 | `BassEvent` / patterns in store + `song.json` |
| M2 | `BassSynth` + sequencer (incl. fill = bass keeps going) |
| M3 | Mixer Bass + MIDI out ch 2 |
| M4 | Song editor bass slots + MIDI import |
| M5 | 2–3 demo songs + tests + Help/docs |
| M6+ | Sample bass kits |

**Status:** M1–M5 are in v1. Bass lines are stored as their own MIDI files (“Groove A Bass.mid”, “Ending Bass.mid”) and named in the `song.json` layout. A fill shorter than a bar skips the rest of the bar in the bass too, as it does in the drums.

---

## Open for later (not blocking v1)

- Mute bass on transition/outro (song flag)
- Optional fill bass patterns
- Bass swing / humanize
- Expression / mute footswitch (MIDI Learn action)

---

## References

- PedalBeat song shape: `Core/SongStore.swift` (`PartData`, patterns)
- bb community bass = kit samples + merged MIDI (not a separate track)
- Related docs: `docs/loopy-pro.md` (hosting), MIDI Settings for future “Bass mute” action
