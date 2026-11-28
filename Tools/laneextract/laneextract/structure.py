"""E3: song structure of a source MIDI → sections (intro / verse / chorus / bridge / outro …).

1. Bar features: bass (absolute + chord-relative), rhythm, chord roots, energy, fills, crashes.
2. Bar self-similarity (content similarity is computed once per distinct bar type).
3. Boundaries: Foote novelty on the similarity matrix + crash / fill / phrase-grid evidence.
4. Sections are grouped by aligned similarity; groups are labelled from repetition, energy and
   position.
5. The labels are mapped onto the parts of the target factory song (Groove A, B, …).
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .harmony import Harmony
from .roles import Lane
from .timemap import TimeMap

TOMS = {41, 43, 45, 47, 48, 50}
CRASH = {49, 57, 52, 55}


@dataclass
class BarFeat:
    index: int
    units: int
    bass: frozenset            # (pos, pitch)
    bass_rel: frozenset        # (pos, rel)
    rhythm: frozenset          # pos
    roots: tuple               # ((start, root relative to key), ...)
    notes_all: int = 0
    drum_hits: int = 0
    tom_hits: int = 0
    crash: bool = False
    vel: float = 0.0
    active: int = 0
    energy: float = 0.0


@dataclass
class Section:
    start: int                 # first bar
    end: int                   # exclusive
    group: int
    label: str = "?"
    energy: float = 0.0

    @property
    def bars(self) -> int:
        return self.end - self.start


@dataclass
class Structure:
    sections: list[Section] = field(default_factory=list)
    groups: dict[int, dict] = field(default_factory=dict)
    music_start: int = 0
    conf: float = 0.0

    def timeline(self) -> str:
        short = {"intro": "I", "verse": "V", "chorus": "C", "bridge": "B", "outro": "O", "part": "P",
                 "solo": "S", "?": "?"}
        return " ".join(f"{short.get(s.label, '?')}{s.group}({s.bars})" for s in self.sections)


# ---------------------------------------------------------------- features

def bar_features(tm: TimeMap, lanes: list[Lane], h: Harmony) -> list[BarFeat]:
    n = len(tm.bars)
    tonic = h.key.tonic if h.key else 0
    bass_by: dict[int, list] = {}
    for x in h.notes:
        bass_by.setdefault(x.bar, []).append(x)
    roots_by: dict[int, list] = {}
    for c in h.chords:
        roots_by.setdefault(c.bar, []).append((c.start, None if c.root is None else (c.root - tonic) % 12))
    feats = []
    for b in tm.bars:
        ns = bass_by.get(b.index, [])
        feats.append(BarFeat(b.index, tm.bar_units(b),
                             frozenset((x.pos, x.pitch) for x in ns),
                             frozenset((x.pos, x.rel) for x in ns),
                             frozenset(x.pos for x in ns),
                             tuple(roots_by.get(b.index, ()))))
    vel_sum = [0.0] * n
    lanes_in = [set() for _ in range(n)]
    for li, lane in enumerate(lanes):
        for x in lane.notes:
            bi = tm.bar_at(x.start).index
            f = feats[bi]
            f.notes_all += 1
            vel_sum[bi] += x.velocity
            lanes_in[bi].add(li)
            if lane.role == "drums":
                f.drum_hits += 1
                if x.pitch in TOMS:
                    f.tom_hits += 1
                if x.pitch in CRASH and x.start - tm.bars[bi].start < tm.ppq // 8:
                    f.crash = True
    for i, f in enumerate(feats):
        f.vel = vel_sum[i] / f.notes_all if f.notes_all else 0.0
        f.active = len(lanes_in[i])

    def p95(xs: list[float]) -> float:
        s = sorted(xs)
        return s[int(len(s) * 0.95)] if s and s[int(len(s) * 0.95)] > 0 else 1.0

    pn, pd, pv, pa = (p95([f.notes_all for f in feats]), p95([f.drum_hits for f in feats]),
                      p95([f.vel for f in feats]), p95([f.active for f in feats]))
    for f in feats:
        f.energy = min(1.0, 0.4 * f.notes_all / pn + 0.3 * f.drum_hits / pd + 0.2 * f.vel / pv + 0.1 * f.active / pa)
    return feats


# ---------------------------------------------------------------- similarity

def _jac(a: frozenset, b: frozenset) -> float:
    if not a and not b:
        return 1.0
    return len(a & b) / len(a | b)


def _chord_sim(a: tuple, b: tuple) -> float:
    if a == b:
        return 1.0
    ra = [r for _, r in a]
    rb = [r for _, r in b]
    if ra and rb and ra[0] == rb[0]:
        return 0.6
    return 0.0


def similarity(feats: list[BarFeat]) -> list[list[float]]:
    types: dict[tuple, int] = {}
    tid = []
    reps: list[BarFeat] = []
    for f in feats:
        k = (f.units, f.bass, f.roots)
        if k not in types:
            types[k] = len(reps)
            reps.append(f)
        tid.append(types[k])
    nt = len(reps)
    content = [[0.0] * nt for _ in range(nt)]
    for i in range(nt):
        for j in range(i, nt):
            a, b = reps[i], reps[j]
            if a.units != b.units:
                v = 0.0
            else:
                v = (0.35 * _jac(a.bass, b.bass) + 0.20 * _jac(a.bass_rel, b.bass_rel)
                     + 0.15 * _jac(a.rhythm, b.rhythm) + 0.30 * _chord_sim(a.roots, b.roots))
            content[i][j] = content[j][i] = v
    n = len(feats)
    S = [[0.0] * n for _ in range(n)]
    for i in range(n):
        ci = content[tid[i]]
        ei = feats[i].energy
        row = S[i]
        for j in range(n):
            row[j] = 0.85 * ci[tid[j]] + 0.15 * (1.0 - abs(ei - feats[j].energy))
    return S


# ---------------------------------------------------------------- boundaries

def _novelty(S: list[list[float]], w: int = 4) -> list[float]:
    n = len(S)
    nov = [0.0] * n
    for t in range(1, n):
        a0, b1 = max(0, t - w), min(n, t + w)
        past, fut = range(a0, t), range(t, b1)
        if not past or not fut:
            continue

        def mean(rs, cs):
            tot = sum(S[i][j] for i in rs for j in cs)
            return tot / (len(rs) * len(cs))
        nov[t] = max(0.0, 0.5 * (mean(past, past) + mean(fut, fut)) - mean(past, fut))
    return nov


def stripes(S: list[list[float]], thr: float = 0.8, min_run: int = 4) -> list[tuple[int, int, int]]:
    """Repetitions as diagonal runs: (length, lag, start) with S[i][i+lag] ≥ thr for ≥ min_run bars."""
    n = len(S)
    out = []
    for lag in range(4, n // 2 + 1):
        run = 0
        for i in range(n - lag):
            if S[i][i + lag] >= thr:
                run += 1
                continue
            if run >= min_run:
                out.append((run, lag, i - run))
            run = 0
        if run >= min_run:
            out.append((run, lag, n - lag - run))
    return out


def boundaries(feats: list[BarFeat], S: list[list[float]], music_start: int) -> list[int]:
    n = len(feats)
    nov = _novelty(S)
    mx = max(nov) or 1.0
    score = [0.0] * n
    rep = [0.0] * (n + 1)
    for run, lag, i0 in stripes(S):
        w = min(run / 8, 1.0)
        for t, v in ((i0, 0.45), (i0 + lag, 0.45), (i0 + run, 0.3), (i0 + lag + run, 0.3)):
            if 0 < t < n:
                rep[t] = min(0.6, rep[t] + v * w)
    for t in range(n):
        s = nov[t] / mx
        if feats[t].crash:
            s += 0.25
        if t > 0 and feats[t - 1].tom_hits >= 3 and feats[t - 1].tom_hits > 2 * (feats[t].tom_hits + 1):
            s += 0.25                                    # fill in the bar before
        if t >= music_start and (t - music_start) % 4 == 0:
            s += 0.15                                    # phrase grid
        if t >= music_start and (t - music_start) % 8 == 0:
            s += 0.05
        de = feats[t].energy - (feats[t - 1].energy if t else 0)
        s += 0.2 * min(abs(de) / 0.3, 1.0)
        score[t] = s + rep[t]
    # greedy peak picking, at least 4 bars apart (2 near the edges)
    order = sorted(range(1, n), key=lambda t: -score[t])
    thr = sorted(score)[int(n * 0.6)] if n > 5 else 1.0
    chosen = [0, n]
    if 0 < music_start < n:
        chosen.append(music_start)
    for t in order:
        if score[t] < max(thr, 0.45):
            break
        gap = min(abs(t - c) for c in chosen)
        edge = t <= music_start + 4 or t >= n - 4
        if gap >= 4 or (edge and gap >= 2):
            chosen.append(t)
    return sorted(set(chosen))


# ---------------------------------------------------------------- grouping & labels

def _section_sim(S: list[list[float]], a: Section, b: Section) -> float:
    k = min(a.bars, b.bars)
    if k == 0:
        return 0.0
    m = sum(S[a.start + i][b.start + i] for i in range(k)) / k
    return m * (k / max(a.bars, b.bars)) ** 0.3


def analyse(tm: TimeMap, lanes: list[Lane], h: Harmony) -> tuple[Structure, list[BarFeat]]:
    feats = bar_features(tm, lanes, h)
    n = len(feats)
    st = Structure()
    if n < 4:
        st.sections = [Section(0, n, 0, "verse")]
        return st, feats
    music = next((f.index for f in feats if f.bass or f.notes_all >= 4), 0)
    st.music_start = music
    S = similarity(feats)
    bnd = boundaries(feats, S, music)
    secs = [Section(a, b, -1) for a, b in zip(bnd, bnd[1:]) if b > a]
    _group(secs, S, 0.72)
    secs = _pair_merge(secs)
    secs = _merge_runs(secs)
    _join_variants(secs, S)
    secs = _edges(secs, n)
    secs = _merge_runs(secs)
    secs = _absorb_short(secs)
    secs = _merge_runs(secs)
    for s in secs:
        s.energy = round(sum(feats[k].energy for k in range(s.start, s.end)) / max(s.bars, 1), 3)
    groups = _group_stats(secs)

    # labels
    has_bass = lambda s: any(feats[k].bass for k in range(s.start, s.end))  # noqa: E731
    for s in secs:
        if s.label in ("intro", "outro") and not has_bass(s) and s.bars > 16:
            s.label = "?"
    repeated = [g for g, v in groups.items() if v["count"] >= 2 and v["bars"] / v["count"] >= 4
                and any(s.group == g and s.label == "?" for s in secs)]
    chorus = verse = None
    if repeated:
        # the two groups covering most of the song are verse and chorus; chorus = more energy
        main = sorted(repeated, key=lambda g: -groups[g]["bars"])[:2]
        if len(main) == 2 and groups[main[1]]["bars"] >= max(8, 0.12 * (n - music)):
            a, b = main
            de = groups[a]["energy"] - groups[b]["energy"]
            if abs(de) < 0.03:
                verse, chorus = (a, b) if groups[a]["first"] < groups[b]["first"] else (b, a)
            else:
                chorus, verse = (a, b) if de > 0 else (b, a)
        else:
            verse = main[0]
    for s in secs:
        if s.label != "?":
            continue
        if s.group == verse:
            s.label = "verse"
        elif s.group == chorus:
            s.label = "chorus"
        elif groups[s.group]["count"] >= 2:
            s.label = "part"
    uniques = [s for s in secs if s.label == "?"]
    if uniques:
        mid = [s for s in uniques if s.start >= n * 0.3] or uniques
        bridge = max(mid, key=lambda s: s.bars)
        bridge.label = "bridge"
        for s in uniques:
            if s.label == "?":
                s.label = "part"
    if verse is None and chorus is None:
        main = max(secs, key=lambda s: s.bars)
        if main.label in ("bridge", "part"):
            main.label = "verse"
    for s in secs:
        groups[s.group]["label"] = s.label if groups[s.group].get("label") in (None, s.label) else "mixed"
    st.sections, st.groups = secs, groups
    rep_bars = sum(s.bars for s in secs if groups[s.group]["count"] >= 2)
    st.conf = round(rep_bars / max(n - music, 1), 3)
    return st, feats


def _group(secs: list[Section], S: list[list[float]], thr: float) -> None:
    gid = 0
    for i, s in enumerate(secs):
        if s.group >= 0:
            continue
        s.group = gid
        for t in secs[i + 1:]:
            if t.group < 0 and _section_sim(S, s, t) >= thr:
                t.group = gid
        gid += 1


def _next_gid(secs: list[Section]) -> int:
    return max((s.group for s in secs), default=-1) + 1


def _pair_merge(secs: list[Section], max_bars: int = 16) -> list[Section]:
    """BPE on the group sequence: a pair of different phrases that repeats becomes one section."""
    for _ in range(8):
        counts: dict[tuple[int, int], int] = {}
        for a, b in zip(secs, secs[1:]):
            if a.group != b.group and a.bars + b.bars <= max_bars:
                counts[(a.group, b.group)] = counts.get((a.group, b.group), 0) + 1
        if not counts:
            break
        (ga, gb), c = max(counts.items(), key=lambda kv: (kv[1], kv[0][0] != kv[0][1]))
        if c < 2:
            break
        gid = _next_gid(secs)
        out, i = [], 0
        while i < len(secs):
            if i + 1 < len(secs) and secs[i].group == ga and secs[i + 1].group == gb \
                    and secs[i].bars + secs[i + 1].bars <= max_bars:
                out.append(Section(secs[i].start, secs[i + 1].end, gid))
                i += 2
            else:
                out.append(secs[i])
                i += 1
        secs = out
    return secs


def _merge_runs(secs: list[Section]) -> list[Section]:
    out: list[Section] = []
    for s in secs:
        if out and out[-1].group == s.group and out[-1].label == s.label:
            out[-1] = Section(out[-1].start, s.end, s.group, s.label)
        else:
            out.append(Section(s.start, s.end, s.group, s.label))
    return out


def _join_variants(secs: list[Section], S: list[list[float]], thr: float = 0.6) -> None:
    count: dict[int, int] = {}
    for s in secs:
        count[s.group] = count.get(s.group, 0) + 1
    reps = {}
    for s in secs:
        if count[s.group] >= 2 and s.group not in reps:
            reps[s.group] = s
    for s in secs:
        if count[s.group] != 1:
            continue
        best, bv = None, thr
        for g, r in reps.items():
            if min(r.bars, s.bars) / max(r.bars, s.bars) < 0.75:
                continue
            v = _section_sim(S, r, s)
            if v >= bv:
                best, bv = g, v
        if best is not None:
            count[s.group] -= 1
            s.group = best
            count[best] += 1


def _edges(secs: list[Section], n: int, limit: int = 16) -> list[Section]:
    """Everything before the first repeat is the intro, after the last repeat the outro."""
    count: dict[int, int] = {}
    for s in secs:
        count[s.group] = count.get(s.group, 0) + 1
    rep_idx = [i for i, s in enumerate(secs) if count[s.group] >= 2]
    if not rep_idx:
        return secs
    first, last = rep_idx[0], rep_idx[-1]
    out = list(secs)
    gid = _next_gid(secs)
    if first > 0 and secs[first].start <= limit:
        out = [Section(0, secs[first].start, gid, "intro")] + secs[first:]
        last = last - first + 1
    if last < len(out) - 1 and n - out[last].end <= limit:
        out = out[:last + 1] + [Section(out[last].end, n, gid + 1, "outro")]
    return out


def _absorb_short(secs: list[Section], min_len: int = 4) -> list[Section]:
    """Turnarounds / breaks under `min_len` bars join the section before them."""
    out: list[Section] = []
    for s in secs:
        if s.bars < min_len and s.label not in ("intro", "outro") and out and out[-1].label != "intro":
            out[-1] = Section(out[-1].start, s.end, out[-1].group, out[-1].label)
        else:
            out.append(Section(s.start, s.end, s.group, s.label))
    return out


def _group_stats(secs: list[Section]) -> dict[int, dict]:
    groups: dict[int, dict] = {}
    for s in secs:
        g = groups.setdefault(s.group, {"count": 0, "bars": 0, "energy": 0.0, "first": s.start})
        g["count"] += 1
        g["bars"] += s.bars
        g["energy"] += s.energy * s.bars
    for g in groups.values():
        g["energy"] = round(g["energy"] / max(g["bars"], 1), 3)
    return groups


# ---------------------------------------------------------------- mapping

PRIORITY = ["verse", "chorus", "bridge", "part", "solo"]


def map_to_factory(st: Structure, parts: int) -> dict:
    """Factory part letters → source label (and the groups used)."""
    present = []
    for lab in PRIORITY:
        gs = []
        for s in st.sections:
            if s.label == lab and s.group not in gs:
                gs.append(s.group)
        for g in gs:
            present.append((lab, g))
    out: dict = {}
    for i in range(min(parts, len(present))):
        lab, g = present[i]
        out[chr(65 + i)] = {"label": lab, "group": g}
    if parts and not out and st.sections:
        out["A"] = {"label": st.sections[0].label, "group": st.sections[0].group}
    intro = next((s for s in st.sections if s.label == "intro"), None)
    outro = next((s for s in st.sections if s.label == "outro"), None)
    out["intro"] = {"start": intro.start, "end": intro.end} if intro else None
    out["ending"] = ({"start": outro.start, "end": outro.end} if outro else
                     {"start": max(st.sections[-1].end - 2, 0), "end": st.sections[-1].end} if st.sections else None)
    return out


# ---------------------------------------------------------------- chord sheet

def chord_sheet(h: Harmony, st: Structure) -> dict:
    """Key, chord vocabulary, transitions and per-section progressions (for live chord priors)."""
    real = [c for c in h.chords if c.root is not None and not c.carried]
    vocab: dict[str, float] = {}
    for c in real:
        vocab[c.name] = vocab.get(c.name, 0) + (c.end - c.start)
    tot = sum(vocab.values()) or 1
    seq = [c.name for i, c in enumerate(real) if i == 0 or c.name != real[i - 1].name]
    trans: dict[str, int] = {}
    for a, b in zip(seq, seq[1:]):
        trans[f"{a}>{b}"] = trans.get(f"{a}>{b}", 0) + 1
    by_bar: dict[int, list[str]] = {}
    for c in h.chords:
        by_bar.setdefault(c.bar, []).append(c.name)
    progs: dict[str, list[str]] = {}
    for s in st.sections:
        key = s.label if s.label not in progs else None
        if key is None:
            continue
        progs[key] = [" ".join(by_bar.get(b, [])) for b in range(s.start, s.end)]
    return {
        "key": h.key.name if h.key else None,
        "vocabulary": {k: round(v / tot, 3) for k, v in sorted(vocab.items(), key=lambda kv: -kv[1])},
        "transitions": dict(sorted(trans.items(), key=lambda kv: -kv[1])[:40]),
        "progressions": progs,
    }
