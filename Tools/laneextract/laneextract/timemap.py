"""Bar grid and tempo map for source MIDIs.

All later stages work in **units of 1/12 quarter note** (`U = 12`): a 16th is 3 units,
an 8th 6, a triplet-8th 4, a triplet-16th 2. That is the "fine" grid (16th + triplet).
"""
from __future__ import annotations

import bisect
from dataclasses import dataclass

from .smf import Song

U = 12  # units per quarter note


@dataclass
class Bar:
    index: int
    start: int       # tick
    end: int         # tick
    num: int
    den: int

    @property
    def units(self) -> int:
        return (self.end - self.start)  # ticks; convert with ppq by caller


@dataclass
class TimeMap:
    ppq: int
    bars: list[Bar]
    starts: list[int]
    bpm: float | None            # duration-weighted median tempo
    bpm_folded: float | None     # folded into 70–160 (half/double-time ambiguity)
    tempo_changes: int           # distinct tempo values that matter (>3 % apart)
    timesig_changes: int
    warnings: list[str]
    offset: int = 0              # ticks: the grid starts here; bar 0 is a pickup bar when > 0

    def bar_at(self, tick: int) -> Bar:
        i = bisect.bisect_right(self.starts, tick) - 1
        return self.bars[max(0, min(i, len(self.bars) - 1))]

    def bar_units(self, bar: Bar) -> int:
        return (bar.end - bar.start) * U // self.ppq


def _valid_sig(num: int, den: int) -> bool:
    return 1 <= num <= 32 and den in (1, 2, 4, 8, 16, 32)


def build(song: Song, end_tick: int | None = None, offset: int = 0) -> TimeMap:
    """`offset` (ticks) shifts the bar grid: notes before it form a pickup bar 0."""
    warnings: list[str] = []
    sigs = [(t, n, d) for t, n, d in song.timesigs if _valid_sig(n, d)]
    if len(sigs) != len(song.timesigs):
        warnings.append("implausible time signature ignored")
    if not sigs or sigs[0][0] > 0:
        sigs.insert(0, (0, 4, 4))
    end = end_tick if end_tick is not None else song.end_tick
    if song.notes:
        end = min(end, max(n.end for n in song.notes))

    bars: list[Bar] = []
    t, si = 0, 0
    num, den = sigs[0][1], sigs[0][2]
    changes = 0
    if offset > 0:
        beat = song.ppq * 4 // den
        bars.append(Bar(0, 0, offset, max(1, offset // max(beat, 1)), den))
        t = offset
    while t < max(end, 1) and len(bars) < 4000:
        # a signature event inside a bar takes effect at the next bar
        while si + 1 < len(sigs) and sigs[si + 1][0] <= t:
            si += 1
            if (sigs[si][1], sigs[si][2]) != (num, den):
                changes += 1
            num, den = sigs[si][1], sigs[si][2]
        length = song.ppq * 4 * num // den
        bars.append(Bar(len(bars), t, t + length, num, den))
        t += length
    if not bars:
        bars.append(Bar(0, 0, song.ppq * 4, 4, 4))

    # tempo: duration-weighted median over the song, ignoring absurd values
    tempos = [(t0, us) for t0, us in song.tempos if 150_000 <= us <= 1_500_000] or [(0, 500_000)]
    if tempos[0][0] > 0:
        tempos.insert(0, (0, tempos[0][1]))
    spans = []
    for i, (t0, us) in enumerate(tempos):
        t1 = tempos[i + 1][0] if i + 1 < len(tempos) else max(end, t0 + 1)
        if t1 > t0:
            spans.append((60_000_000 / us, t1 - t0))
    spans.sort()
    half = sum(w for _, w in spans) / 2
    acc, bpm = 0.0, spans[0][0] if spans else 120.0
    for b, w in spans:
        acc += w
        if acc >= half:
            bpm = b
            break
    folded = bpm
    while folded > 160:
        folded /= 2
    while folded < 70:
        folded *= 2
    distinct: list[float] = []
    for b, _ in spans:
        if all(abs(b - d) / d > 0.03 for d in distinct):
            distinct.append(b)
    if len(distinct) > 1:
        warnings.append(f"{len(distinct)} tempi")
    if bpm > 220 or bpm < 40:
        warnings.append(f"unusual tempo {bpm:.0f}")
    return TimeMap(song.ppq, bars, [b.start for b in bars], round(bpm, 1), round(folded, 1),
                   max(0, len(distinct) - 1), changes, warnings, offset)
