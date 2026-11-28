"""Where the midi-songs data lives (midi.json, midis/, drum_songs/, …).

The scripts live in pedalbeat-develop/Tools/midi-songs; the data stays in pedalbeat-data/midi-songs.
Default: ../pedalbeat-data/midi-songs next to this repo. Override with MIDI_SONGS=<folder>
(or PEDALBEAT_DATA=<pedalbeat-data folder>).
"""
import os
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
DATA = Path(os.environ.get("MIDI_SONGS")
            or Path(os.environ.get("PEDALBEAT_DATA", _REPO.parent / "pedalbeat-data")) / "midi-songs").resolve()
