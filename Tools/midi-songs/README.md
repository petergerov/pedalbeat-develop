# midi-songs scripts

Build the drum and percussion songs that `Tools/build-songpack.sh` turns into the built-in song pack.
The scripts live here; the data (`midi.json`, `midis/`, `drum_songs/`, …) stays in `pedalbeat-data/midi-songs`
(default `../pedalbeat-data/midi-songs`; override with `MIDI_SONGS=<folder>` or `PEDALBEAT_DATA=<folder>`, see `paths.py`).

| Script | Does | Needs |
|---|---|---|
| `download_midis.py` | MIDIs for every song in `midi.json` from freemidi.org → `midis/`, `midi_results.json` | stdlib |
| `lakh_match.py` | fallback: matches the rest against the Lakh MIDI Dataset (`lakh_data/`) → `lakh_results.json` | stdlib |
| `build_map.py` | merges both into `midi_map.json` | stdlib |
| `extract_drums.py` | cuts drums (or `--kind shaker\|tambourine\|clap`) into `drum_songs/` … `clap_songs/` | `pip install mido` |

Run from the repo root, e.g. `python3 Tools/midi-songs/extract_drums.py --kind shaker`. Details: `docs/song-pack.md`.
