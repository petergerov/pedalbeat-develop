"""Loader for the PedalBeat factory songs (`songs/<Genre>/<Song>/`): the *target* drums.

The bass is written for these existing songs and parts, not for the drums found in the
reference MIDIs. Each part is reduced to drum features (kick/snare/hat masks on the
1/12-quarter grid) that the later stages match against.
"""
from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field

from . import smf
from .timemap import U

LANES = {
    "kick": {35, 36},
    "snare": {38, 40, 37, 39},        # snare, rim, clap act as backbeat
    "hat": {42, 44, 46},
    "ride": {51, 53, 59},
    "crash": {49, 57, 52, 55},
    "tom": {41, 43, 45, 47, 48, 50},
    "perc": {54, 56, 69, 70, 82, 75, 88},
}
NOTE_LANE = {n: lane for lane, ns in LANES.items() for n in ns}


@dataclass
class DrumPattern:
    file: str
    role: str                     # intro | main | fill | transition | outro
    part: int | None              # part index for main/fill
    fill_no: int | None
    bar_units: int                # units per bar
    length_units: int             # exact pattern length
    bars: float
    label: str                    # signature label shown in the app, e.g. "12/8"
    grid: str                     # straight | triplet | mixed
    swing: float                  # mean |live swing| of the pattern, 0 = none
    lanes: dict[str, list[list[int]]] = field(default_factory=dict)   # lane -> [[unit, vel], ...]
    counts: dict[str, int] = field(default_factory=dict)
    masks: dict[str, str] = field(default_factory=dict)               # first bar, step grid
    pitches: list[int] = field(default_factory=list)                  # GM notes used
    path: str = ""


@dataclass
class FactorySong:
    key: str                      # "Genre/Folder"
    name: str
    genre: str
    bpm: float | None
    label: str
    kit_hint: int
    patterns: list[DrumPattern] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    dir: str = ""
    layout: dict = field(default_factory=dict)

    @property
    def mains(self) -> list[DrumPattern]:
        return [p for p in self.patterns if p.role == "main"]


def _mask(units: list[int], bar_units: int, step: int) -> str:
    n = max(bar_units // step, 1)
    chars = ["."] * n
    for u in units:
        if 0 <= u < bar_units and u % step == 0:
            chars[u // step] = "x"
    per = U // step      # one group per quarter-note beat
    return " ".join("".join(chars[i:i + per]) for i in range(0, n, per))


def read_pattern(path: str, role: str, part: int | None = None,
                 fill_no: int | None = None) -> tuple[DrumPattern, float | None]:
    s = smf.parse(path)
    pb = s.pb or {}
    sig = s.timesigs[0][1:] if s.timesigs else (4, 4)
    bar_ticks = pb.get("bar_ticks") or s.ppq * 4 * sig[0] // sig[1]
    length = pb.get("length") or max((n.end for n in s.notes), default=bar_ticks)
    scale = U / s.ppq
    lanes: dict[str, list[list[int]]] = {}
    for n in s.notes:
        lane = NOTE_LANE.get(n.pitch, "perc")
        lanes.setdefault(lane, []).append([round(n.start * scale), n.velocity])
    for v in lanes.values():
        v.sort()
    bar_units = round(bar_ticks * scale)
    # grid: are off-beat hits on thirds (triplet) or quarters (straight) of the beat?
    off = [u % U for v in lanes.values() for u, _ in v if u % U]
    t = sum(1 for o in off if o % 4 == 0 and o % 3 != 0)
    st = sum(1 for o in off if o % 3 == 0)
    grid = "straight" if t == 0 else "triplet" if st == 0 or t > 3 * st else "mixed" if st > 0 else "triplet"
    sw = pb.get("swing") or []
    swing = round(sum(abs(x) for x in sw) / len(sw), 1) if sw else 0.0
    step = 4 if grid == "triplet" else 3
    p = DrumPattern(os.path.basename(path), role, part, fill_no, bar_units, round(length * scale),
                    round(length / bar_ticks, 3) if bar_ticks else 0.0,
                    pb.get("label") or f"{sig[0]}/{sig[1]}", grid, swing, lanes,
                    {k: len(v) for k, v in lanes.items()})
    p.pitches = sorted({n.pitch for n in s.notes})
    p.path = path
    p.masks = {k: _mask([u for u, _ in v], bar_units, step) for k, v in lanes.items()
               if k in ("kick", "snare", "hat", "ride")}
    tempos = [60_000_000 / us for _, us in s.tempos if us]
    return p, (tempos[0] if tempos else None)


def load_song(song_dir: str, genre: str) -> FactorySong:
    folder = os.path.basename(song_dir)
    cfg = json.load(open(os.path.join(song_dir, "song.json")))
    lay = cfg.get("layout", {})
    song = FactorySong(f"{genre}/{folder}", cfg.get("name", folder), cfg.get("genre", genre),
                       None, "4/4", lay.get("kitHint", 0))
    song.dir, song.layout = song_dir, lay

    def add(fn: str | None, role: str, part: int | None = None, fill_no: int | None = None):
        if not fn:
            return
        path = os.path.join(song_dir, fn)
        if not os.path.exists(path):
            song.warnings.append(f"missing {fn}")
            return
        p, bpm = read_pattern(path, role, part, fill_no)
        if song.bpm is None and bpm:
            song.bpm, song.label = round(bpm, 1), p.label
        song.patterns.append(p)

    add(lay.get("intro"), "intro")
    for i, part in enumerate(lay.get("parts", [])):
        add(part.get("main"), "main", i)
        for j, f in enumerate(part.get("fills", [])):
            add(f, "fill", i, j + 1)
    add(lay.get("transition"), "transition")
    add(lay.get("outro"), "outro")
    return song


def load_all(songs_dir: str) -> list[FactorySong]:
    out = []
    for genre in sorted(os.listdir(songs_dir)):
        gdir = os.path.join(songs_dir, genre)
        if not os.path.isdir(gdir):
            continue
        for folder in sorted(os.listdir(gdir)):
            sdir = os.path.join(gdir, folder)
            if os.path.exists(os.path.join(sdir, "song.json")):
                out.append(load_song(sdir, genre))
    return out


def to_json(songs: list[FactorySong]) -> list[dict]:
    return [asdict(s) for s in songs]
