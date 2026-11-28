"""Timing grid analysis: bars, quantisation grid (16th / triplet), swing."""
from __future__ import annotations

from dataclasses import dataclass

from .smf import Note, Song


@dataclass
class GridInfo:
    kind: str                 # 16th | triplet | mixed | loose | none
    fit16: float              # share of onsets within tolerance of a 16th grid point
    fit3: float               # share within tolerance of a triplet (1/3 beat) grid point
    swing: float | None       # position of the off-8th inside the beat (0.5 straight, 0.667 triplet swing)


def _frac(tick: int, ppq: int) -> float:
    return (tick / ppq) % 1.0


def analyse_grid(onsets: list[int], ppq: int, tol: float = 0.06) -> GridInfo:
    if len(onsets) < 8:
        return GridInfo("none", 0.0, 0.0, None)
    n = len(onsets)

    def near(f: float, step: float) -> bool:
        r = (f / step) - round(f / step)
        return abs(r) * step <= tol

    fr = [_frac(t, ppq) for t in onsets]
    f16 = sum(1 for f in fr if near(f, 0.25) or near(f, 1.0)) / n
    f3 = sum(1 for f in fr if near(f, 1 / 3) or near(f, 1.0)) / n
    # swing: onsets in the second half of the beat (0.4–0.8)
    off = [f for f in fr if 0.4 <= f <= 0.8]
    swing = sorted(off)[len(off) // 2] if len(off) >= 4 else None
    if f16 >= 0.9 and f3 < 0.9:
        kind = "16th"
    elif f3 >= 0.9 and f16 < 0.9:
        kind = "triplet"
    elif max(f16, f3) >= 0.9:
        kind = "16th"            # both fit (mostly on-beat material)
    elif max(f16, f3) >= 0.7:
        kind = "mixed"
    else:
        kind = "loose"
    return GridInfo(kind, round(f16, 3), round(f3, 3), None if swing is None else round(swing, 3))


@dataclass
class BarInfo:
    num: int
    den: int
    ticks_per_bar: int
    bars: int
    timesig_changes: int
    tempo_changes: int
    bpm: float | None


def bar_info(song: Song) -> BarInfo:
    num, den = (song.timesigs[0][1], song.timesigs[0][2]) if song.timesigs else (4, 4)
    tpb = song.ppq * 4 * num // den
    bars = max(1, round(song.end_tick / tpb)) if tpb else 0
    bpm = round(60_000_000 / song.tempos[0][1], 1) if song.tempos else None
    return BarInfo(num, den, tpb, bars,
                   max(0, len({(n, d) for _, n, d in song.timesigs}) - 1),
                   max(0, len({u for _, u in song.tempos}) - 1), bpm)
