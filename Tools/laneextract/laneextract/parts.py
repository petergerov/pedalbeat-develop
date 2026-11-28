"""E4: bass and percussion loops per part, written onto the factory song's parts.

For every factory part (Groove A, B, …) the bars of the mapped source section group are
collected. From them a loop is built with the length and grid of the factory drum part:

  bass        chord-relative (rel to the chord root), so Bass Follow can transpose it live;
              written with the root on E, the app's default `bassRootPitchClass`.
  percussion  tambourine, shaker, clap, cowbell, … as GM notes on channel 10, separate files.

Two candidates per loop: consensus (per grid position: onset probability ≥ 0.5, most common
interval, median duration/velocity) and medoid (the real bar most similar to all others). The
medoid wins when it is about as representative, because it is a bar a player actually played.
"""
from __future__ import annotations

import json
import os
import statistics
from collections import Counter
from dataclasses import dataclass, field

from . import midiout
from .factory import DrumPattern, FactorySong
from .harmony import Harmony
from .roles import Lane
from .structure import BarFeat, Structure
from .timemap import U, TimeMap

LOW, HIGH = 28, 55          # E1 … G3
ROOT_E = 28

PERC_NAMES = {54: "tambourine", 70: "maracas", 82: "shaker", 69: "cabasa", 39: "clap", 56: "cowbell",
              75: "claves", 80: "triangle", 81: "triangle", 60: "bongo", 61: "bongo", 62: "conga",
              63: "conga", 64: "conga", 65: "timbale", 66: "timbale", 67: "agogo", 68: "agogo",
              73: "guiro", 74: "guiro", 76: "woodblock", 77: "woodblock", 78: "cuica", 79: "cuica"}
# instruments that sound alike: one of them already in the factory groove → skip the family
FAMILY = {"maracas": "shaker", "shaker": "shaker", "cabasa": "shaker"}


@dataclass
class Loop:
    notes: list[tuple[int, int, int, int]]   # (pos units, dur units, value, vel); value = rel or GM note
    length: int                               # units
    method: str                               # consensus | medoid | single
    consistency: float                        # mean similarity of the loop to the source bars
    bars_used: int


@dataclass
class SongParts:
    bass: dict[str, Loop] = field(default_factory=dict)          # "A", "B", …, "intro", "ending"
    perc: dict[str, Loop] = field(default_factory=dict)
    sources: dict[str, str] = field(default_factory=dict)        # part → source label
    notes: list[str] = field(default_factory=list)
    # fills: part letter → {fill number: FillLoop}; transition: bass for the Transition pattern
    fill_bass: dict[str, dict[int, "FillLoop"]] = field(default_factory=dict)
    fill_perc: dict[str, dict[int, "FillLoop"]] = field(default_factory=dict)
    transition: "FillLoop | None" = None


@dataclass
class FillLoop:
    loop: Loop
    kind: str            # dropout | hold | pickup | run | octave | drive | variation
    count: int           # how many source fill bars had this kind
    intensity: float


# ---------------------------------------------------------------- grid

def regrid(pos: int, target: str) -> int:
    """Moves a position onto the factory part's grid (straight: 16ths, triplet: triplet 16ths)."""
    beat, r = divmod(pos, U)
    if target == "straight":
        r = {4: 3, 8: 6, 2: 3, 10: 9}.get(r, r)
    elif target == "triplet":
        r = {3: 4, 6: 8, 9: 10}.get(r, r)
    return beat * U + r


# ---------------------------------------------------------------- bar collection

def _part_bars(st: Structure, group: int, feats: list[BarFeat], units: int, length_bars: int) -> list[list[int]]:
    """Bar windows (1 or 2 bars) of one section group, without the closing bar of each section."""
    out = []
    for s in st.sections:
        if s.group != group:
            continue
        end = s.end - 1 if s.bars >= 4 else s.end          # last bar = fill / turnaround
        for b in range(s.start, end - length_bars + 1, length_bars):
            win = list(range(b, b + length_bars))
            if all(feats[x].units == units for x in win) and any(feats[x].bass for x in win):
                out.append(win)
    return out


def _bass_events(h: Harmony) -> dict[int, list[tuple[int, int, int, int]]]:
    """Per bar: (pos, dur, rel, vel) with anticipations / approaches re-aimed at the loop's root."""
    by: dict[int, list] = {}
    ns = h.notes
    for i, n in enumerate(ns):
        if n.deg == "?":
            continue
        rel = n.rel
        if n.role in ("anticipation", "approach"):
            octave = 12 * round(rel / 12)
            if n.role == "anticipation":
                rel = octave
            elif i + 1 < len(ns):
                step = ns[i + 1].pitch - n.pitch        # +1/+2: from below, −1/−2: from above
                target = 12 * round((rel + step) / 12)
                rel = target - step
        by.setdefault(n.bar, []).append((n.pos, n.dur, rel, n.vel))
    return by


# ---------------------------------------------------------------- loop building

def _jac(a: set, b: set) -> float:
    return len(a & b) / len(a | b) if a or b else 1.0


def build_loop(windows: list[list[int]], events: dict[int, list], units: int, grid: str,
               pitched: bool, avoid: set | None = None) -> Loop | None:
    """`avoid`: (pos, value) set of an earlier part; a different real variant is preferred."""
    if not windows:
        return None
    length = units * len(windows[0])
    bars: list[list[tuple[int, int, int, int]]] = []
    for win in windows:
        notes = []
        for k, b in enumerate(win):
            for pos, dur, val, vel in events.get(b, []):
                p = regrid(pos, grid) + k * units
                if 0 <= p < length:
                    notes.append((p, dur, val, vel))
        # one note per position (lowest for bass, loudest for percussion of the same instrument)
        best: dict[tuple, tuple] = {}
        for n in notes:
            key = (n[0],) if pitched else (n[0], n[2])
            if key not in best or (n[2] < best[key][2] if pitched else n[3] > best[key][3]):
                best[key] = n
        bars.append(sorted(best.values()))
    N = len(bars)
    sets = [{(p, v) for p, _, v, _ in b} for b in bars]

    # consensus
    on: Counter = Counter()
    for b in bars:
        for key in {(p,) if pitched else (p, v) for p, _, v, _ in b}:
            on[key] += 1
    keep = [k for k, c in on.items() if c / N >= 0.5]
    if not keep:
        keep = [k for k, c in on.most_common(2) if c / N >= 0.3]
    cons = []
    for k in sorted(keep):
        hits = [n for b in bars for n in b if n[0] == k[0] and (pitched or n[2] == k[1])]
        if pitched:
            vals = Counter(n[2] for n in hits)
            top = max(vals.values())
            # ties: chord tone (root/fifth/octave) first, then closest to the root
            val = min((v for v, c in vals.items() if c == top), key=lambda v: (v % 12 not in (0, 7), abs(v)))
        else:
            val = k[1]
        dur = int(statistics.median(n[1] for n in hits))
        vel = int(statistics.median(n[3] for n in hits))
        cons.append((k[0], dur, val, vel))
    if pitched:   # monophonic: a note ends before the next one starts
        cons = [(p, max(1, min(d, (cons[i + 1][0] if i + 1 < len(cons) else length) - p)), v, vel)
                for i, (p, d, v, vel) in enumerate(cons)]
    cset = {(p, v) for p, _, v, _ in cons}
    c_score = sum(_jac(cset, s) for s in sets) / N

    # medoid
    m_idx = max(range(N), key=lambda i: sum(_jac(sets[i], s) for s in sets))
    m_score = sum(_jac(sets[m_idx], s) for s in sets) / N
    if N == 1:
        return Loop(bars[0], length, "single", 1.0, 1)
    if avoid is not None and sets[m_idx] == avoid:
        alt = [i for i in range(N) if sets[i] != avoid and bars[i]]
        if alt:
            a_idx = max(alt, key=lambda i: sum(_jac(sets[i], s) for s in sets))
            a_score = sum(_jac(sets[a_idx], s) for s in sets) / N
            if a_score >= 0.25:
                return Loop(bars[a_idx], length, "variant", round(a_score, 3), N)
    if m_score >= c_score - 0.03 and bars[m_idx]:
        return Loop(bars[m_idx], length, "medoid", round(m_score, 3), N)
    return Loop(cons, length, "consensus", round(c_score, 3), N) if cons else None


# ---------------------------------------------------------------- pitch

def bass_pitches(loop: Loop, root_pc: int = 4) -> list[tuple[int, int, int, int]]:
    """Chord-relative loop notes → pitches on `root_pc` (pitch class; 4 = E, the app's default bass root)."""
    rels = [v for _, _, v, _ in loop.notes]
    root = ROOT_E + (root_pc - 4) % 12
    best_base, best_out = root, None
    for base in (root, root + 12):
        out = sum(1 for r in rels if not LOW <= base + r <= HIGH)
        if best_out is None or out < best_out:
            best_base, best_out = base, out
    res = []
    for p, d, r, v in loop.notes:
        pitch = best_base + r
        while pitch < LOW:
            pitch += 12
        while pitch > HIGH:
            pitch -= 12
        res.append((p, d, pitch, max(50, min(120, v))))
    return res


# ---------------------------------------------------------------- fills

def fill_bars(st: Structure, feats: list[BarFeat], group: int) -> list[tuple[int, bool, float]]:
    """Closing bars of the group's sections → (bar, next section is another part, drum-fill score)."""
    out = []
    secs = st.sections
    for i, s in enumerate(secs):
        if s.group != group or s.bars < 2:
            continue
        b = s.end - 1
        inner = [feats[k].drum_hits for k in range(s.start, b)]
        med = statistics.median(inner) if inner else 0
        f = feats[b]
        nxt = secs[i + 1] if i + 1 < len(secs) else None
        crash_next = nxt is not None and feats[nxt.start].crash
        score = min(1.0, f.tom_hits / 4) + 0.3 * crash_next + 0.3 * (f.drum_hits > 1.3 * med and med > 0)
        out.append((b, nxt is not None and nxt.group != group, round(score, 2)))
    return out


def classify(notes: list[tuple[int, int, int, int]], loop_set: set, units: int) -> str:
    """What the bass does in a fill bar compared with the part's loop."""
    if not notes:
        return "dropout"
    if _jac({(p, v) for p, _, v, _ in notes}, loop_set) >= 0.7:
        return "same"
    end = max(p + d for p, d, _, _ in notes)
    if max(p for p, _, _, _ in notes) < units // 2 and end <= units * 0.6:
        return "dropout"                                  # stop-time: the bass leaves the bar open
    if len(notes) <= 2 and max(d for _, d, _, _ in notes) >= units // 2:
        return "hold"
    rels = [v for _, _, v, _ in notes]
    steps = [b - a for a, b in zip(rels, rels[1:])]
    if steps:
        stepwise = sum(1 for x in steps if 0 < abs(x) <= 2) / len(steps)
        octave = sum(1 for x in steps if abs(x) == 12) / len(steps)
        if len(notes) >= 6 and octave >= 0.5:
            return "octave"
        if len(notes) >= 5 and stepwise >= 0.6:
            return "run"
    if len(notes) >= 6 and len({v % 12 for v in rels}) == 1:
        return "drive"                                    # steady repeated root: pushes into the next part
    last_beat = [v for p, _, v, _ in notes if p >= units - U]
    if len(last_beat) >= 2 and len(set(last_beat)) >= 2:
        return "pickup"                                   # movement in the last beat into the next one
    return "variation"


def _intensity(loop: Loop, kind: str) -> float:
    return len(loop.notes) + (3 if kind in ("run", "octave", "drive") else 0) - (2 if kind in ("dropout", "hold") else 0)


def _fill_loops(bars: list[int], events: dict[int, list], units: int, grid: str, pitched: bool,
                loop_set: set, min_score: list[float]) -> list[FillLoop]:
    """Groups fill bars by kind and returns one medoid loop per kind (most frequent kinds first)."""
    by_kind: dict[str, list[int]] = {}
    for b, sc in zip(bars, min_score):
        notes = sorted((regrid(p, grid), d, v, vel) for p, d, v, vel in events.get(b, []))
        kind = classify(notes, loop_set, units) if pitched else (
            "same" if _jac({(p, v) for p, _, v, _ in notes}, loop_set) >= 0.7 else
            "dropout" if not notes or max(p for p, *_ in notes) < units // 2 else "variation")
        if kind == "same" or (kind == "variation" and sc < 0.3):
            continue                       # bass just keeps playing, or a deviation without a drum fill
        by_kind.setdefault(kind, []).append(b)
    out = []
    for kind, bs in sorted(by_kind.items(), key=lambda kv: -len(kv[1])):
        loop = build_loop([[b] for b in bs], events, units, grid, pitched=pitched)
        if loop is None:
            continue
        if kind == "dropout" and not loop.notes:
            loop = Loop([], units, "dropout", 1.0, len(bs))
        out.append(FillLoop(loop, kind, len(bs), _intensity(loop, kind)))
    return out


def _assign(cands: list[FillLoop], fills: list[DrumPattern]) -> dict[int, FillLoop]:
    """Pairs bass-fill variants with the part's drum fills by intensity rank."""
    if not cands or not fills:
        return {}
    cands = cands[:len(fills)]
    by_int = sorted(cands, key=lambda c: c.intensity)
    drum = sorted(fills, key=lambda p: sum(p.counts.values()))
    if len(by_int) < len(drum):        # fewer variants: give them to the busiest fills
        drum = drum[-len(by_int):]
    return {p.fill_no: c for p, c in zip(drum, by_int)}


# ---------------------------------------------------------------- per song

def build(tm: TimeMap, lanes: list[Lane], h: Harmony, st: Structure, feats: list[BarFeat],
          mapping: dict, fsong: FactorySong) -> SongParts:
    out = SongParts()
    events = _bass_events(h)
    perc_ev: dict[int, list] = {}
    for lane in lanes:
        if lane.role != "drums":
            continue
        for n in lane.notes:
            if n.pitch in PERC_NAMES:
                bar = tm.bar_at(n.start)
                pos = round((n.start - bar.start) * U / tm.ppq)
                perc_ev.setdefault(bar.index, []).append((pos, 1, n.pitch, n.velocity))

    mains = sorted(fsong.mains, key=lambda p: p.part or 0)
    letters = [chr(65 + (p.part or 0)) for p in mains]
    found = {k: v for k, v in mapping.items() if len(k) == 1 and v}
    last_src = None
    for letter, dp in zip(letters, mains):
        src = found.get(letter) or last_src
        if src is None:
            continue
        last_src = src
        bars_n = max(1, round(dp.bars))
        wins = _part_bars(st, src["group"], feats, dp.bar_units, bars_n)
        if not wins:
            out.notes.append(f"{letter}: keine passenden Takte (Taktart?)")
            continue
        out.sources[letter] = src["label"] + ("" if found.get(letter) else " (übernommen)")
        prev = [{(p, v) for p, _, v, _ in l.notes} for l in out.bass.values()]
        loop = build_loop(wins, events, dp.bar_units, dp.grid, pitched=True)
        if loop and prev and {(p, v) for p, _, v, _ in loop.notes} in prev:
            loop = build_loop(wins, events, dp.bar_units, dp.grid, pitched=True,
                              avoid={(p, v) for p, _, v, _ in loop.notes}) or loop
        if loop and loop.notes:
            out.bass[letter] = loop
        p = _perc_loop(wins, perc_ev, dp)
        if p:
            out.perc[letter] = p
        # fills of this part: closing bars of its sections
        fills = sorted((f for f in fsong.patterns if f.role == "fill" and f.part == dp.part), key=lambda f: f.fill_no)
        fb = [x for x in fill_bars(st, feats, src["group"]) if feats[x[0]].units == dp.bar_units]
        if fills and fb and letter in out.bass:
            lset = {(q, v) for q, _, v, _ in out.bass[letter].notes}
            cands = _fill_loops([b for b, _, _ in fb], events, dp.bar_units, fills[0].grid, True,
                                lset, [sc for _, _, sc in fb])
            got = _assign(cands, fills)
            if got:
                out.fill_bass[letter] = got
            if letter in out.perc:
                pset = {(q, v) for q, _, v, _ in out.perc[letter].notes}
                keep = {v for _, _, v, _ in out.perc[letter].notes}
                pev = {b: [e for e in perc_ev.get(b, []) if e[2] in keep] for b, _, _ in fb}
                pc = _fill_loops([b for b, _, _ in fb], pev, dp.bar_units, fills[0].grid, False,
                                 pset, [sc for _, _, sc in fb])
                gotp = _assign(pc, fills)
                if gotp:
                    out.fill_perc[letter] = gotp
        transitions_src = [(b, sc) for b, changes, sc in fb if changes]
        if transitions_src:
            out.__dict__.setdefault("_trans", []).extend(
                (b, sc, {(q, v) for q, _, v, _ in out.bass[letter].notes} if letter in out.bass else set())
                for b, sc in transitions_src)

    # transition: real part-change fills of the source (closing bar before another part)
    trans = next((p for p in fsong.patterns if p.role == "transition"), None)
    tsrc = out.__dict__.pop("_trans", [])
    if trans and tsrc:
        bars = [b for b, _, _ in tsrc if feats[b].units == trans.bar_units]
        if bars:
            lset = tsrc[0][2]
            cands = _fill_loops(bars, events, trans.bar_units, trans.grid, True, lset, [sc for _, sc, _ in tsrc])
            # prefer motion into the next part over stops
            pref = sorted(cands, key=lambda c: (c.kind not in ("pickup", "run", "octave", "drive"), -c.count))
            if pref and pref[0].loop.notes:
                out.transition = pref[0]

    # intro: only when the source intro has bass in most of its bars
    intro = next((p for p in fsong.patterns if p.role == "intro"), None)
    if intro and mapping.get("intro"):
        a, b = mapping["intro"]["start"], mapping["intro"]["end"]
        with_bass = [x for x in range(a, b) if feats[x].bass and feats[x].units == intro.bar_units]
        if len(with_bass) >= max(1, (b - a) // 2):
            n_bars = max(1, round(intro.bars))
            wins = [with_bass[i:i + n_bars] for i in range(0, len(with_bass) - n_bars + 1, n_bars)]
            loop = build_loop(wins, events, intro.bar_units, intro.grid, pitched=True)
            if loop and loop.notes:
                out.bass["intro"] = loop
    # ending: the last bar that has bass, held for the ending pattern's length
    outro = next((p for p in fsong.patterns if p.role == "outro"), None)
    if outro:
        last = next((f.index for f in reversed(feats) if f.bass and f.units == outro.bar_units), None)
        if last is not None:
            ev = [e for e in events.get(last, []) if e[0] < outro.length_units]
            if ev:
                first = ev[0]
                # the final hit: first note of the last bar, ringing to the end of the pattern
                out.bass["ending"] = Loop([(0, max(first[1], min(outro.length_units, 2 * U)), first[2], first[3])],
                                          outro.length_units, "final", 1.0, 1)
    return out


def _perc_loop(wins: list[list[int]], perc_ev: dict[int, list], dp: DrumPattern) -> Loop | None:
    have = {FAMILY.get(PERC_NAMES.get(p, ""), PERC_NAMES.get(p, "")) for p in dp.pitches if p in PERC_NAMES}
    if dp.counts.get("snare") and 39 in dp.pitches:
        have.add("clap")
    loop = build_loop(wins, perc_ev, dp.bar_units, dp.grid, pitched=False)
    if not loop:
        return None
    # only instruments that play in at least half the bars, and that the groove does not have yet
    active: Counter = Counter()
    for win in wins:
        seen = {e[2] for b in win for e in perc_ev.get(b, [])}
        for x in seen:
            active[x] += 1
    keep = {x for x, c in active.items() if c / len(wins) >= 0.5
            and FAMILY.get(PERC_NAMES[x], PERC_NAMES[x]) not in have}
    notes = [n for n in loop.notes if n[2] in keep]
    if not notes:
        return None
    return Loop(notes, loop.length, loop.method, loop.consistency, loop.bars_used)


# ---------------------------------------------------------------- export

def export(sp: SongParts, fsong: FactorySong, entry, doc: dict, out_root: str) -> str | None:
    if not sp.bass:
        return None
    tempo = entry.bpm if entry else (fsong.bpm or 120)
    name = f"{entry.artist} – {entry.title}" if entry else doc["file"]
    folder = os.path.join(out_root, fsong.genre, _safe(name))
    os.makedirs(folder, exist_ok=True)
    lay = json.loads(json.dumps(fsong.layout))
    # drums: the factory files at the song's tempo
    for p in fsong.patterns:
        midiout.copy_with_tempo(p.path, os.path.join(folder, p.file), tempo)
    pat_by_letter = {chr(65 + (p.part or 0)): p for p in fsong.mains}

    def write_bass(fn: str, loop: Loop, ref: DrumPattern) -> str:
        notes = [(p * midiout.TICKS_PER_UNIT, d * midiout.TICKS_PER_UNIT, pitch, v) for p, d, pitch, v in bass_pitches(loop)]
        midiout.write(os.path.join(folder, fn), notes, loop.length * midiout.TICKS_PER_UNIT, tempo, ref.label,
                      ref.bar_units * midiout.TICKS_PER_UNIT, 480, channel=1, program=33)
        return fn

    def write_perc(fn: str, loop: Loop, ref: DrumPattern) -> str:
        notes = [(p * midiout.TICKS_PER_UNIT, 30, gm, v) for p, _, gm, v in loop.notes]
        midiout.write(os.path.join(folder, fn), notes, loop.length * midiout.TICKS_PER_UNIT, tempo, ref.label,
                      ref.bar_units * midiout.TICKS_PER_UNIT, 480, channel=9)
        return fn

    perc_files = {}
    for i, part in enumerate(lay.get("parts", [])):
        letter = chr(65 + i)
        ref = pat_by_letter.get(letter)
        if ref is None:
            continue
        if letter in sp.bass:
            part["bass"] = write_bass(f"Groove {letter} Bass.mid", sp.bass[letter], ref)
        if letter in sp.perc:
            perc_files[letter] = write_perc(f"Groove {letter} Percussion.mid", sp.perc[letter], ref)
    fills_meta: dict[str, list] = {}
    fill_pats = {(chr(65 + (p.part or 0)), p.fill_no): p for p in fsong.patterns if p.role == "fill"}
    for letter, got in sp.fill_bass.items():
        for no, fl in sorted(got.items()):
            ref = fill_pats.get((letter, no))
            if ref is None:
                continue
            entry_ = {"fill": no, "kind": fl.kind, "count": fl.count}
            if not fl.loop.notes:
                entry_["silent"] = True          # the bass stops for this fill (no file: empty MIDI is not importable)
            else:
                entry_["bass"] = write_bass(f"Groove {letter} Fill {no} Bass.mid",
                                            Loop(fl.loop.notes, ref.length_units, fl.loop.method,
                                                 fl.loop.consistency, fl.loop.bars_used), ref)
            pf = sp.fill_perc.get(letter, {}).get(no)
            if pf is not None and not pf.loop.notes:
                entry_["percussion_silent"] = True
            elif pf is not None:
                entry_["percussion"] = write_perc(f"Groove {letter} Fill {no} Percussion.mid",
                                                  Loop(pf.loop.notes, ref.length_units, pf.loop.method,
                                                       pf.loop.consistency, pf.loop.bars_used), ref)
                entry_["percussion_kind"] = pf.kind
            fills_meta.setdefault(letter, []).append(entry_)
    # Layout: one bass file per fill, in the order of the part's "fills" ("" = groove bass keeps playing).
    import re
    for i, part in enumerate(lay.get("parts", [])):
        letter = chr(65 + i)
        by_no = {e["fill"]: e["bass"] for e in fills_meta.get(letter, []) if "bass" in e}
        names = []
        for fn in part.get("fills", []):
            m = re.search(r"Fill (\d+)", fn)
            names.append(by_no.get(int(m.group(1)), "") if m else "")
        if any(names):
            part["fillBass"] = names
    trans_pat = next((p for p in fsong.patterns if p.role == "transition"), None)
    if sp.transition and trans_pat:
        t = sp.transition
        lay["transitionBass"] = write_bass("Transition Bass.mid",
                                           Loop(t.loop.notes, trans_pat.length_units, t.loop.method,
                                                t.loop.consistency, t.loop.bars_used), trans_pat)
    intro = next((p for p in fsong.patterns if p.role == "intro"), None)
    outro = next((p for p in fsong.patterns if p.role == "outro"), None)
    if "intro" in sp.bass and intro:
        lay["introBass"] = write_bass("Intro Bass.mid", sp.bass["intro"], intro)
    if "ending" in sp.bass and outro:
        lay["outroBass"] = write_bass("Ending Bass.mid", sp.bass["ending"], outro)

    meta = {
        "source": doc["file"], "factory": fsong.key, "key": (doc.get("key") or {}).get("name"),
        "bassRoot": "E (Bass Follow transponiert live)",
        "parts": {k: {"source": sp.sources.get(k), "method": v.method, "consistency": v.consistency,
                      "bars": v.bars_used} for k, v in sp.bass.items()},
        "percussion": {k: {"file": perc_files[k], "instruments": sorted({PERC_NAMES[n[2]] for n in sp.perc[k].notes}),
                           "consistency": sp.perc[k].consistency} for k in perc_files},
        "fills": fills_meta,
        "fillNote": "Fill-Bass/-Percussion: eigene Dateien für eine spätere App-Funktion. Die App spielt sie "
                    "(layout.parts[].fillBass); Fills ohne Datei lassen den Part-Bass weiterlaufen. Transition Bass wird von der App schon gespielt.",
        "transition": ({"kind": sp.transition.kind, "count": sp.transition.count} if sp.transition else None),
        "notes": sp.notes,
    }
    song_json = {"format": 1, "name": name, "genre": fsong.genre, "layout": lay, "laneextract": meta}
    with open(os.path.join(folder, "song.json"), "w") as fh:
        json.dump(song_json, fh, indent=2, ensure_ascii=False)
    return folder


def _safe(s: str) -> str:
    bad = set('/\\:?*"<>|')
    return "".join("-" if c in bad else c for c in s).strip(" .") or "Song"
