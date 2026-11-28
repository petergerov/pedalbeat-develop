# laneextract

Extracts bass (later shaker/tambourine/clap) parts from reference MIDIs for PedalBeat.
Drums always come from the existing PedalBeat factory songs (`songs/`); the reference MIDIs only
supply bass material. Concept and status: `docs/bass-extraction-engine.md`, song pack: `docs/song-pack.md`.
Stdlib only, Python 3.10+. The code lives here (`Tools/laneextract`); the data stays in `pedalbeat-data`.
Run from this folder:

    python3 -m laneextract report  <midi_dir> <out>                       # E0/E1 corpus report
    python3 -m laneextract factory <songs_dir> <out>                      # E1 target drum features
    python3 -m laneextract analyse <midi_dir> <songs_dir> <app_repo> <out> # E2+E3 link, chords, key, interval bass, structure, chord sheets
    python3 -m laneextract songpack <midi_songs_dir> <out>                 # E6 bass for the song pack (Tools/build-songpack.sh runs this)

Grid unit everywhere: 1/12 quarter note (16th = 3, 8th = 6, triplet 8th = 4).

`analyse` also writes importable example songs (E4): `<out>/examples/<Genre>/<Artist – Title>/` with the
factory drums at the song's tempo, `Groove X Bass.mid` (root E, chord-relative for Bass Follow),
`Intro/Ending Bass.mid`, `Groove X Percussion.mid` (GM, channel 10) and `song.json`.
Current output: `pedalbeat-data/build/laneextract/` (analyse) and `pedalbeat-data/build/songpack/` (songpack).
