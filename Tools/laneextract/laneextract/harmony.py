"""E2: chord root / quality per bar (or half bar), song key, and the bass line as intervals.

Evidence per slice (half bar in 4/4-like bars, whole bar otherwise):
  - harmony chroma: duration overlap of every non-bass, non-drum note (chordal lanes weigh more)
  - bass evidence:   duration × metric weight (slice start ≫ on-beat > off-beat), lowest note bonus
Chord score = prior(quality) × (0.55 · cos(chroma, template) + 0.45 · bass[root]).
"""
from __future__ import annotations

import bisect
import math
from dataclasses import dataclass, field

from .quant import QBass
from .roles import Lane, monophony
from .timemap import U, TimeMap

PC = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
DEG = ["R", "b2", "2", "b3", "3", "4", "b5", "5", "b6", "6", "b7", "7"]

QUALITIES: dict[str, dict[int, float]] = {
    "maj": {0: 1.0, 4: 1.0, 7: 0.8},
    "min": {0: 1.0, 3: 1.0, 7: 0.8},
    "7": {0: 1.0, 4: 1.0, 7: 0.8, 10: 0.7},
    "maj7": {0: 1.0, 4: 1.0, 7: 0.8, 11: 0.7},
    "m7": {0: 1.0, 3: 1.0, 7: 0.8, 10: 0.7},
    "sus4": {0: 1.0, 5: 1.0, 7: 0.8},
    "dim": {0: 1.0, 3: 1.0, 6: 1.0},
    "5": {0: 1.0, 7: 1.0},
}
PRIOR = {"maj": 1.0, "min": 1.0, "7": 0.93, "m7": 0.93, "maj7": 0.9, "sus4": 0.85, "dim": 0.8, "5": 0.86}
SUFFIX = {"maj": "", "min": "m", "7": "7", "maj7": "maj7", "m7": "m7", "sus4": "sus4", "dim": "dim", "5": "5"}

# Krumhansl–Kessler key profiles
KK_MAJ = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
KK_MIN = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]


def _templates() -> list[tuple[int, str, list[float]]]:
    out = []
    for q, iv in QUALITIES.items():
        for r in range(12):
            v = [0.0] * 12
            for i, w in iv.items():
                v[(r + i) % 12] = w
            n = math.sqrt(sum(x * x for x in v))
            out.append((r, q, [x / n for x in v]))
    return out


TEMPLATES = _templates()


@dataclass
class Chord:
    bar: int
    start: int        # units from bar start
    end: int
    root: int | None  # pitch class, None = no chord
    quality: str
    conf: float       # margin to the best chord with another root, 0..1
    carried: bool = False

    @property
    def name(self) -> str:
        return "N" if self.root is None else PC[self.root] + SUFFIX[self.quality]


@dataclass
class Key:
    tonic: int
    mode: str         # major | minor
    conf: float

    @property
    def name(self) -> str:
        return PC[self.tonic] + ("" if self.mode == "major" else "m")


@dataclass
class RelNote:
    bar: int
    pos: int
    dur: int
    pitch: int
    vel: int
    rel: int          # semitones above the chord-root anchor (may be negative)
    deg: str          # degree name relative to the chord root
    role: str         # chord | passing | approach | anticipation | none


@dataclass
class Harmony:
    key: Key | None
    chords: list[Chord] = field(default_factory=list)
    notes: list[RelNote] = field(default_factory=list)
    stats: dict = field(default_factory=dict)


# ---------------------------------------------------------------- slices

@dataclass
class _Slice:
    bar: int
    a: int            # absolute units
    b: int
    chroma: list[float]     # harmony + a little bass
    bass: list[float]
    harm: list[float]       # harmony lanes only (decides whether a bar really splits)


def _slices(tm: TimeMap) -> list[_Slice]:
    out = []
    for bar in tm.bars:
        a = bar.start * U // tm.ppq
        bu = tm.bar_units(bar)
        if bu >= 48 and bu % 24 == 0:
            half = bu // 2
            out.append(_Slice(bar.index, a, a + half, [0.0] * 12, [0.0] * 12, [0.0] * 12))
            out.append(_Slice(bar.index, a + half, a + bu, [0.0] * 12, [0.0] * 12, [0.0] * 12))
        else:
            out.append(_Slice(bar.index, a, a + bu, [0.0] * 12, [0.0] * 12, [0.0] * 12))
    return out


def _fill(slices: list[_Slice], harmony: list[Lane], qb: QBass, tm: TimeMap) -> None:
    starts = [s.a for s in slices]
    ppq = tm.ppq
    for lane in harmony:
        w = 1.0 if monophony(lane.notes) < 0.6 else 0.5      # chords count more than melody
        for n in lane.notes:
            s, e = n.start * U / ppq, n.end * U / ppq
            i = max(0, bisect.bisect_right(starts, s) - 1)
            while i < len(slices) and slices[i].a < e:
                ov = min(e, slices[i].b) - max(s, slices[i].a)
                if ov > 0:
                    slices[i].chroma[n.pitch % 12] += w * ov
                    slices[i].harm[n.pitch % 12] += w * ov
                i += 1
    bar_u0 = {b.index: b.start * U // ppq for b in tm.bars}
    for n in qb.notes:
        a = bar_u0[n.bar] + n.pos
        i = max(0, bisect.bisect_right(starts, a) - 1)
        sl = slices[i]
        metric = 3.0 if a == sl.a else 1.5 if (a - sl.a) % U == 0 else 1.0
        ov = min(a + n.dur, sl.b) - a
        sl.bass[n.pitch % 12] += metric * max(ov, 1)
        sl.chroma[n.pitch % 12] += 0.5 * max(ov, 1)          # bass notes are chord tones too
    # lowest-note bonus per slice
    by_slice: dict[int, list] = {}
    for n in qb.notes:
        a = bar_u0[n.bar] + n.pos
        by_slice.setdefault(max(0, bisect.bisect_right(starts, a) - 1), []).append(n)
    for i, ns in by_slice.items():
        low = min(ns, key=lambda n: n.pitch)
        slices[i].bass[low.pitch % 12] += 0.5 * low.dur


def _best(chroma: list[float], bass: list[float]) -> tuple[int | None, str, float, float]:
    """→ (root, quality, score, conf)."""
    cn = math.sqrt(sum(x * x for x in chroma))
    bm = max(bass) if bass else 0.0
    if cn == 0 and bm == 0:
        return None, "maj", 0.0, 0.0
    c = [x / cn for x in chroma] if cn else [0.0] * 12
    b = [x / bm for x in bass] if bm else [0.0] * 12
    scored = []
    for r, q, t in TEMPLATES:
        cos = sum(x * y for x, y in zip(c, t))
        scored.append((PRIOR[q] * (0.55 * cos + 0.45 * b[r]), r, q))
    scored.sort(reverse=True)
    s0, r0, q0 = scored[0]
    s1 = next((s for s, r, _ in scored if r != r0), 0.0)
    return r0, q0, s0, (s0 - s1) / s0 if s0 else 0.0


def _cos_template(v: list[float], root: int, quality: str) -> float:
    n = math.sqrt(sum(x * x for x in v))
    if n == 0:
        return 0.0
    t = [0.0] * 12
    for i, w in QUALITIES[quality].items():
        t[(root + i) % 12] = w
    tn = math.sqrt(sum(x * x for x in t))
    return sum(x * y for x, y in zip(v, t)) / (n * tn)


def _whole_fits(s1: "_Slice", s2: "_Slice", root: int | None, quality: str) -> bool:
    """True when one chord explains both halves: only the bass moves (root–fifth, walking).

    With accompaniment: both halves' harmony fits the bar chord. Without: every bass note of
    the bar is a tone of the bar chord.
    """
    if root is None:
        return False
    if sum(s1.harm) > 0 and sum(s2.harm) > 0:
        return _cos_template(s1.harm, root, quality) >= 0.75 and _cos_template(s2.harm, root, quality) >= 0.75
    tones = {(root + i) % 12 for i in QUALITIES[quality]} | {(root + 7) % 12}
    return all(s.bass[pc] == 0 for s in (s1, s2) for pc in range(12) if pc not in tones)


def _add(a: list[float], b: list[float]) -> list[float]:
    return [x + y for x, y in zip(a, b)]


def estimate_chords(tm: TimeMap, harmony: list[Lane], qb: QBass) -> list[Chord]:
    slices = _slices(tm)
    _fill(slices, harmony, qb, tm)
    chords: list[Chord] = []
    i = 0
    while i < len(slices):
        sl = slices[i]
        bar_u0 = sl.a
        pair = i + 1 < len(slices) and slices[i + 1].bar == sl.bar
        if pair:
            s2 = slices[i + 1]
            rw, qw, _, cw = _best(_add(sl.chroma, s2.chroma), _add(sl.bass, s2.bass))
            r1, q1, _, c1 = _best(sl.chroma, sl.bass)
            r2, q2, _, c2 = _best(s2.chroma, s2.bass)
            split = (r1 is not None and r2 is not None and r1 != r2 and sum(sl.bass) > 0
                     and sum(s2.bass) > 0 and c1 > 0.08 and c2 > 0.08
                     and not _whole_fits(sl, s2, rw, qw))
            if split:
                chords.append(Chord(sl.bar, 0, sl.b - bar_u0, r1, q1, round(c1, 3)))
                chords.append(Chord(sl.bar, sl.b - bar_u0, s2.b - bar_u0, r2, q2, round(c2, 3)))
            else:
                chords.append(Chord(sl.bar, 0, s2.b - bar_u0, rw, qw, round(cw, 3)))
            i += 2
        else:
            r, q, _, c = _best(sl.chroma, sl.bass)
            chords.append(Chord(sl.bar, 0, sl.b - bar_u0, r, q, round(c, 3)))
            i += 1
    # silent slices keep the previous chord
    prev = None
    for ch in chords:
        if ch.root is None and prev is not None:
            ch.root, ch.quality, ch.carried = prev.root, prev.quality, True
        if ch.root is not None:
            prev = ch
    return chords


def estimate_key(harmony: list[Lane], qb: QBass, chords: list[Chord], ppq: int) -> Key | None:
    chroma = [0.0] * 12
    for lane in harmony:
        for n in lane.notes:
            chroma[n.pitch % 12] += (n.end - n.start) / ppq
    for n in qb.notes:
        chroma[n.pitch % 12] += 1.5 * n.dur / U
    if not any(chroma):
        return None
    real = [c for c in chords if c.root is not None and not c.carried]
    # duration of each root, split by whether its quality fits a major or a minor tonic
    as_major = [0.0] * 12
    as_minor = [0.0] * 12
    for c in real:
        d = c.end - c.start
        if c.quality in ("maj", "7", "maj7"):
            as_major[c.root] += d
        elif c.quality in ("min", "m7"):
            as_minor[c.root] += d
        else:                                   # 5, sus4, dim: fits either
            as_major[c.root] += 0.6 * d
            as_minor[c.root] += 0.6 * d
    tmax = max(max(as_major), max(as_minor)) or 1.0
    # cadences into a root: V→I, IV→I, bVII→I (root movement only)
    cad = [0.0] * 12
    seq = [c.root for i, c in enumerate(real) if i == 0 or c.root != real[i - 1].root]
    for a, b in zip(seq, seq[1:]):
        if (a - b) % 12 in (7, 5, 10):
            cad[b] += 1
    cmax = max(cad) or 1.0
    first_root = seq[0] if seq else None
    last_root = seq[-1] if seq else None

    def corr(x: list[float], y: list[float]) -> float:
        mx, my = sum(x) / 12, sum(y) / 12
        num = sum((a - mx) * (b - my) for a, b in zip(x, y))
        den = math.sqrt(sum((a - mx) ** 2 for a in x) * sum((b - my) ** 2 for b in y))
        return num / den if den else 0.0

    scores = []
    for t in range(12):
        for mode, prof in (("major", KK_MAJ), ("minor", KK_MIN)):
            rot = [prof[(pc - t) % 12] for pc in range(12)]
            tonic = (as_major if mode == "major" else as_minor)[t] / tmax
            s = (corr(chroma, rot) + 0.35 * tonic + 0.12 * cad[t] / cmax
                 + 0.05 * (first_root == t) + 0.05 * (last_root == t))
            scores.append((s, t, mode))
    scores.sort(reverse=True)
    (s0, t0, m0), (s1, _, _) = scores[0], scores[1]
    return Key(t0, m0, round(s0 - s1, 3))


# ---------------------------------------------------------------- intervals

def relative_notes(qb: QBass, chords: list[Chord], tm: TimeMap) -> list[RelNote]:
    if not qb.notes:
        return []
    pitches = sorted(n.pitch for n in qb.notes)
    ref = pitches[len(pitches) // 2]
    by_bar: dict[int, list[Chord]] = {}
    for c in chords:
        by_bar.setdefault(c.bar, []).append(c)

    def chord_at(bar: int, pos: int) -> Chord | None:
        for c in by_bar.get(bar, []):
            if c.start <= pos < c.end:
                return c
        return None

    def next_chord(bar: int, pos: int) -> Chord | None:
        for c in by_bar.get(bar, []):
            if c.start > pos:
                return c
        nxt = by_bar.get(bar + 1)
        return nxt[0] if nxt else None

    def anchor(root: int) -> int:
        # the root pitch in the window [ref-9, ref+2]: root mostly at/below the line's centre
        lo = ref - 9
        return lo + ((root - lo) % 12)

    bar_units = {b.index: tm.bar_units(b) for b in tm.bars}
    out: list[RelNote] = []
    notes = qb.notes
    for i, n in enumerate(notes):
        c = chord_at(n.bar, n.pos)
        if c is None or c.root is None:
            out.append(RelNote(n.bar, n.pos, n.dur, n.pitch, n.vel, 0, "?", "none"))
            continue
        rel = n.pitch - anchor(c.root)
        iv = rel % 12
        role = "chord" if iv in QUALITIES[c.quality] else "passing"
        nc = next_chord(n.bar, n.pos)
        if nc is not None and nc.root is not None and nc.root != c.root:
            change_abs = (nc.bar - n.bar) * bar_units.get(n.bar, 48) + nc.start
            dist = change_abs - n.pos
            if 0 < dist <= 6 and n.pitch % 12 == nc.root:
                role = "anticipation"           # pushes the next chord's root ahead of the change
            elif role == "passing" and 0 < dist <= U and i + 1 < len(notes):
                nxt = notes[i + 1]
                if abs(nxt.pitch - n.pitch) <= 2 and nxt.pitch % 12 == nc.root:
                    role = "approach"           # chromatic / scale step into the next root
        out.append(RelNote(n.bar, n.pos, n.dur, n.pitch, n.vel, rel, DEG[iv], role))
    return out


def analyse(tm: TimeMap, lanes: list[Lane], qb: QBass) -> Harmony:
    harmony = [l for l in lanes if l.role in ("harmony", "bass_double")]
    chords = estimate_chords(tm, harmony, qb)
    key = estimate_key(harmony, qb, chords, tm.ppq)
    notes = relative_notes(qb, chords, tm)
    h = Harmony(key, chords, notes)

    real = [c for c in chords if c.root is not None and not c.carried]
    strong = [n for n in notes if n.pos % U == 0 and n.deg != "?"]
    downs = [n for n in notes if n.deg != "?" and any(
        c.bar == n.bar and c.start == n.pos for c in chords)]
    roles: dict[str, int] = {}
    degs: dict[str, int] = {}
    for n in notes:
        roles[n.role] = roles.get(n.role, 0) + 1
        degs[n.deg] = degs.get(n.deg, 0) + 1
    changes = sum(1 for a, b in zip(chords, chords[1:]) if a.root != b.root)
    on_one = sum(1 for a, b in zip(chords, chords[1:]) if a.root != b.root and b.start == 0)
    h.stats = {
        "changes_on_one": round(on_one / max(changes, 1), 3),
        "chord_conf_median": sorted(c.conf for c in real)[len(real) // 2] if real else 0.0,
        "carried_share": round(1 - len(real) / max(len(chords), 1), 3),
        "changes_per_bar": round(changes / max(len(tm.bars), 1), 2),
        "vocabulary": len({c.name for c in real}),
        "strong_chord_tone_share": round(sum(n.role in ("chord", "anticipation") for n in strong)
                                         / max(len(strong), 1), 3),
        "root_on_chord_start": round(sum(n.deg == "R" for n in downs) / max(len(downs), 1), 3),
        "roles": roles,
        "degrees": dict(sorted(degs.items(), key=lambda kv: -kv[1])),
    }
    return h
