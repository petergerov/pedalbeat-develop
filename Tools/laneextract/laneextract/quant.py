"""Quantise a monophonic bass line onto the 16th + triplet grid (units of 1/12 quarter)."""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field

from .smf import Note
from .timemap import U, TimeMap

TOL = 0.75   # units (≈ 1/16 of a beat); beyond this a note counts as off-grid


@dataclass
class QNote:
    bar: int
    pos: int          # units from bar start
    dur: int          # units
    pitch: int
    vel: int
    tag: str          # 'b' beat, 's' straight (16th/8th), 't' triplet, 'x' off-grid


@dataclass
class QBass:
    notes: list[QNote] = field(default_factory=list)
    feel: str = "none"            # straight | triplet | mixed | loose | none
    offgrid: float = 0.0          # share of notes off both grids
    triplet_share: float = 0.0    # triplet positions among non-beat notes
    dropped_poly: int = 0         # notes removed by the monophonic reduction


def _snap(units: float) -> tuple[int, str, float]:
    """Nearest 16th/triplet grid point → (snapped, tag, residual)."""
    best = None
    for step, tag in ((3, "s"), (4, "t")):
        k = round(units / step)
        cand = k * step
        r = abs(units - cand)
        if best is None or r < best[2] - 1e-9:
            best = (cand, tag, r)
    snapped, tag, r = best
    if snapped % U == 0:
        tag = "b"
    if r > TOL:
        snapped, tag = round(units), "x"
    return snapped, tag, r


def quantise(notes: list[Note], tm: TimeMap) -> QBass:
    out = QBass()
    if not notes:
        return out
    ppq = tm.ppq
    # snap onsets on an absolute quarter-note grid (bars start on beat multiples)
    snapped: list[tuple[int, int, str, Note]] = []
    for n in sorted(notes, key=lambda n: (n.start, n.pitch)):
        u, tag, _ = _snap(n.start / ppq * U)
        snapped.append((u, 0, tag, n))
    # monophonic reduction: lowest pitch per onset
    by_onset: dict[int, tuple[str, Note]] = {}
    for u, _, tag, n in snapped:
        if u in by_onset:
            out.dropped_poly += 1
            if n.pitch < by_onset[u][1].pitch:
                by_onset[u] = (tag, n)
        else:
            by_onset[u] = (tag, n)
    onsets = sorted(by_onset)
    for i, u in enumerate(onsets):
        tag, n = by_onset[u]
        start_tick = round(u * ppq / U)
        bar = tm.bar_at(start_tick)
        bar_u0 = bar.start * U // ppq
        raw_dur = max(1, round((n.end - n.start) / ppq * U))
        nxt = onsets[i + 1] - u if i + 1 < len(onsets) else raw_dur
        dur = max(1, min(raw_dur, nxt))
        out.notes.append(QNote(bar.index, u - bar_u0, dur, n.pitch, n.velocity, tag))

    tags = Counter(q.tag for q in out.notes)
    total = len(out.notes)
    out.offgrid = round(tags["x"] / total, 3)
    off_beat = tags["s"] + tags["t"]
    out.triplet_share = round(tags["t"] / off_beat, 3) if off_beat else 0.0
    if out.offgrid > 0.2:
        out.feel = "loose"
    elif off_beat < 4:
        out.feel = "straight"
    elif out.triplet_share >= 0.7:
        out.feel = "triplet"
    elif out.triplet_share <= 0.15:
        out.feel = "straight"
    else:
        out.feel = "mixed"
    return out
