"""Pickup / bar-phase detection: where is the real "one"?

Many transcriptions start with a pickup or are off by a beat or half a bar. Loops must start
on the one, so the grid is shifted before anything is cut. Only for constant 4/4-like bars
with an even number of beats; other meters keep offset 0.

1. Beat parity from the backbeat: snare/clap on beats 2 & 4 (0-based 1 & 3).
2. Half-bar from harmony: chords change on the one far more often than in mid bar.
"""
from __future__ import annotations

from . import harmony, quant, timemap
from .roles import Lane
from .smf import Song

SNARES = {38, 40, 39}


def _snare_beats(drums: list[Lane], ppq: int, beats: int) -> list[int]:
    """Snare/clap hits on each beat of the bar (0-based), on-beat hits only."""
    c = [0] * beats
    for l in drums:
        for n in l.notes:
            if n.pitch not in SNARES or n.velocity < 50:
                continue
            q, r = divmod(n.start, ppq)
            if min(r, ppq - r) > ppq // 12:
                continue
            c[(q + (1 if r > ppq // 2 else 0)) % beats] += 1
    return c


def _change_phase(tm: timemap.TimeMap, lanes: list[Lane], qb: quant.QBass) -> tuple[int, int]:
    """→ (root changes at bar start, root changes at mid bar)."""
    chords = harmony.estimate_chords(tm, [l for l in lanes if l.role in ("harmony", "bass_double")], qb)
    at_start = at_mid = 0
    for a, b in zip(chords, chords[1:]):
        if a.root is None or b.root is None or a.root == b.root or b.carried:
            continue
        if b.start == 0:
            at_start += 1
        else:
            at_mid += 1
    return at_start, at_mid


def estimate(song: Song, lanes: list[Lane], bass: Lane) -> tuple[int, dict]:
    """→ (offset ticks, evidence)."""
    tm0 = timemap.build(song)
    first = tm0.bars[0]
    info: dict = {"beat_shift": 0, "half_shift": False}
    if tm0.timesig_changes or first.den != 4 or first.num not in (2, 4):
        info["skipped"] = "meter"
        return 0, info
    ppq = song.ppq
    drums = [l for l in lanes if l.role == "drums"]
    c = _snare_beats(drums, ppq, first.num)
    info["snare_beats"] = c
    keep, shift = sum(c[1::2]), sum(c[0::2])
    # shifted grid: the backbeat sits on beats 0 AND 2. A half-time groove (snare on 2 only)
    # or a double-tempo transcription looks similar but leaves beat 0 empty → no shift.
    both = first.num == 2 or min(c[0], c[2]) >= 0.5 * max(c[0], c[2], 1)
    candidate = shift >= 16 and shift > 2 * keep and both

    def on_one(off: int) -> tuple[float, list[int]]:
        tm = timemap.build(song, offset=off)
        a, m = _change_phase(tm, lanes, quant.quantise(bass.notes, tm))
        return a / max(a + m, 1), [a, m]

    r0, ch0 = on_one(0)
    info["changes"] = ch0
    beat_shift = 0
    if candidate:
        # the harmony must agree: chords change on the one more often on the shifted grid
        r1, ch1 = on_one(ppq)
        info["changes_shifted"] = ch1
        if r1 > r0 + 0.10:          # conservative: the transcriber is usually right
            beat_shift, r0, ch0 = 1, r1, ch1
    offset = beat_shift * ppq
    if first.num == 4 and ch0[1] >= 8 and ch0[1] > 1.6 * ch0[0]:
        offset += 2 * ppq
        info["half_shift"] = True
    info["beat_shift"] = beat_shift
    # the offset is applied as a pickup: keep it inside one bar
    bar = ppq * 4 * first.num // first.den
    return offset % bar, info
