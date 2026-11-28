"""E6: bass for the song pack.

Each song's own drums come from `midi-songs/drum_songs/<Artist>/<Title>/` (extract_drums.py). The bass of
a groove is cut from exactly the bars of the source MIDI where that drum groove plays: the source is split
into bars the way extract_drums.py splits it, the groove file's bars are found there by the same 16th-note
signature, and the bass loop is the medoid / consensus of the bass in those bars (`parts.build_loop`).

    python3 -m laneextract songpack <midi_songs_dir> <out_dir>

<midi_songs_dir> holds drum_songs/, shaker_songs/, tambourine_songs/, clap_songs/, midis/ and
midi_songs_available.json. Writes into <out_dir>:
  drum_songs/…        the drum files unchanged, plus "Groove A Bass.mid" …, "Groove A Fill 1 Bass.mid" …, "Intro Bass.mid", "Ending Bass.mid",
                      and song.json with the bass in its layout and "bassRoot" (pitch class of the song's key)
  shaker_songs/ tambourine_songs/ clap_songs/   copied unchanged
  songpack_report.md, songpack.json
"""
from __future__ import annotations

import json
import os
import re
import shutil
import statistics
from collections import Counter

from . import harmony, midiout, parts, quant, roles, smf, timemap
from .timemap import U

PPQ = 480
GRID = PPQ // 4                     # extract_drums.py compares bars on 16ths
PERC_FOLDERS = ("shaker_songs", "tambourine_songs", "clap_songs")
MIN_BASS_SHARE = 0.4                # a groove gets bass if the bass plays in this share of its bars
FILL_SAME = 0.7                     # a fill's bass with this share of the groove's notes is no fill of its own


def _clean(s: str) -> str:
    """Folder name of an artist or title, as extract_drums.py writes it."""
    return re.sub(r"\s+", " ", re.sub(r'[\\/:*?"<>|]+', " ", s)).strip(" .") or "Unknown"


# ---------------------------------------------------------------- bars as extract_drums.py sees them

def _hits(song: smf.Song) -> list[tuple[int, int, int]]:
    """Channel-10 note-ons at 480 PPQ: (tick, note, velocity)."""
    return sorted((round(n.start * PPQ / song.ppq), n.pitch, n.velocity) for n in song.notes if n.channel == 9)


def _bars(hits: list[tuple[int, int, int]], bar_len: int) -> list[list[tuple[int, int, int]]]:
    by: dict[int, list] = {}
    for t, n, v in hits:
        by.setdefault(t // bar_len, []).append((t % bar_len, n, v))
    return [by.get(i, []) for i in range(max(by) + 1)] if by else []


def _sig(bar: list[tuple[int, int, int]]) -> frozenset:
    return frozenset((n, round(o / GRID)) for o, n, _ in bar)


def _musical(bar: list[tuple[int, int, int]]) -> bool:
    s = {n for _, n, _ in bar}
    return len(bar) >= 6 and bool(s & {35, 36}) and bool(s & {38, 39, 40})


class DrumFile:
    """A file of a drum song: its bars (signatures), tempo and meter."""

    def __init__(self, path: str):
        s = smf.parse(path)
        self.name = os.path.basename(path)
        num, den = (s.timesigs[0][1], s.timesigs[0][2]) if s.timesigs else (4, 4)
        self.num, self.den = num, den
        self.bar_len = num * PPQ * 4 // den
        self.tempo = 60_000_000 / s.tempos[0][1] if s.tempos else 120.0
        hits = _hits(s)
        self.n_bars = max(1, round(s.end_tick * PPQ / s.ppq / self.bar_len)) if s.end_tick else 1
        bars = _bars(hits, self.bar_len)
        bars += [[] for _ in range(self.n_bars - len(bars))]
        self.sigs = [_sig(b) for b in bars[:self.n_bars]]

    @property
    def label(self) -> str:
        return f"{self.num}/{self.den}"

    @property
    def beat_ticks(self) -> int:
        if self.den == 8 and self.num % 3 == 0 and self.num > 3:
            return PPQ * 3 // 2
        return PPQ * 4 // self.den


def _occurrences(src: list[frozenset], pattern: list[frozenset]) -> list[int]:
    k = len(pattern)
    return [i for i in range(len(src) - k + 1) if all(src[i + j] == pattern[j] for j in range(k))]


# ---------------------------------------------------------------- one song

class SongResult:
    def __init__(self, folder: str):
        self.folder = folder
        self.reason = ""                 # why there is no bass
        self.grooves: dict[str, dict] = {}
        self.intro = self.ending = ""
        self.fills: dict[str, list[str]] = {}   # per groove letter: what each fill got ("file", "same", "silent", "none")
        self.key = None


def _analysis(path: str):
    s = smf.parse(path)
    lanes = roles.split_lanes(s)
    bass = next((l for l in lanes if l.role == "bass"), None)
    if not bass:
        return s, None, None, None
    tm = timemap.build(s, offset=0)          # extract_drums.py's grid starts at tick 0
    qb = quant.quantise(bass.notes, tm)
    h = harmony.analyse(tm, lanes, qb)
    return s, tm, qb, h


def build_song(src_path: str, song_dir: str, out_dir: str) -> SongResult:
    res = SongResult(song_dir)
    with open(os.path.join(song_dir, "song.json")) as fh:
        sj = json.load(fh)
    lay = sj["layout"]
    os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(song_dir):
        if f.lower().endswith(".mid"):
            shutil.copy2(os.path.join(song_dir, f), os.path.join(out_dir, f))

    def finish() -> SongResult:
        with open(os.path.join(out_dir, "song.json"), "w") as fh:
            json.dump(sj, fh, indent=2, ensure_ascii=False)
        return res

    if not src_path or not os.path.exists(src_path):
        res.reason = "no source MIDI"
        return finish()
    s, tm, qb, h = _analysis(src_path)
    if h is None:
        res.reason = "no bass in the source"
        return finish()
    mains = [DrumFile(os.path.join(song_dir, p["main"])) for p in lay["parts"]]
    bar_len = mains[0].bar_len
    src_bars = _bars(_hits(s), bar_len)
    src_sigs = [_sig(b) for b in src_bars]
    units = bar_len // midiout.TICKS_PER_UNIT
    grid = qb.feel if qb.feel in ("straight", "triplet") else "none"
    events = parts._bass_events(h)
    tonic = h.key.tonic if h.key else 4
    res.key = h.key.name if h.key else None

    def tm_bar(i: int) -> int | None:
        """laneextract bar of extract_drums.py bar `i`, if both grids agree there."""
        tick = i * bar_len * s.ppq / PPQ
        if tick >= tm.bars[-1].end:
            return None
        b = tm.bar_at(round(tick))
        if abs(b.start - tick) > max(1.0, s.ppq / 96) or tm.bar_units(b) != units:
            return None
        return b.index

    def windows(starts: list[int], n: int) -> list[list[int]]:
        out = []
        for i in starts:
            w = [tm_bar(i + k) for k in range(n)]
            if all(x is not None for x in w):
                out.append(w)
        return out

    def write(fn: str, loop: parts.Loop, ref: DrumFile) -> str:
        notes = [(p * midiout.TICKS_PER_UNIT, d * midiout.TICKS_PER_UNIT, pitch, v)
                 for p, d, pitch, v in parts.bass_pitches(loop, tonic)]
        midiout.write(os.path.join(out_dir, fn), notes, loop.length * midiout.TICKS_PER_UNIT, ref.tempo,
                      ref.label, ref.bar_len, ref.beat_ticks, channel=1, program=33)
        return fn

    groove_sigs = {x for m in mains for x in m.sigs}
    groove_loops: dict[str, parts.Loop] = {}
    aligned_any = False
    for k, (p, m) in enumerate(zip(lay["parts"], mains)):
        letter = chr(65 + k)
        occ = _occurrences(src_sigs, m.sigs)
        wins = windows(occ, len(m.sigs))
        aligned_any = aligned_any or bool(wins)
        with_bass = [w for w in wins if any(events.get(b) for b in w)]
        info = {"occurrences": len(occ), "aligned": len(wins), "with_bass": len(with_bass)}
        res.grooves[letter] = info
        if not wins or len(with_bass) < MIN_BASS_SHARE * len(wins):
            continue
        loop = parts.build_loop(with_bass, events, units, grid, pitched=True)
        if not loop or not loop.notes:
            continue
        info.update(method=loop.method, consistency=loop.consistency, notes=len(loop.notes))
        p["bass"] = write(f"Groove {letter} Bass.mid", loop, m)
        groove_loops[letter] = loop

    # Fills: the bass in the bars where each fill file plays. Close to the groove's bass (or no bars
    # found) = no file, the groove's bass keeps playing under the fill. A bass that stops there is
    # noted as "silent" but has no file either (the app rejects empty MIDI files).
    for k, p in enumerate(lay["parts"]):
        letter = chr(65 + k)
        gl = groove_loops.get(letter)
        if gl is None or not p.get("fills"):
            continue
        gset = {(pos % units, v) for pos, _, v, _ in gl.notes}
        names: list[str] = []
        kinds: list[str] = []
        for fn in p["fills"]:
            f = DrumFile(os.path.join(song_dir, fn))
            wins = [] if any(x in groove_sigs for x in f.sigs) else windows(_occurrences(src_sigs, f.sigs), len(f.sigs))
            with_bass = [w for w in wins if any(events.get(b) for b in w)]
            loop = parts.build_loop(with_bass, events, units, grid, pitched=True) if with_bass else None
            if not wins:
                kind = "none"
            elif len(with_bass) < MIN_BASS_SHARE * len(wins) or not loop or not loop.notes:
                kind = "silent"
            else:
                fset = {(pos % units, v) for pos, _, v, _ in loop.notes}
                kind = "same" if len(fset & gset) >= FILL_SAME * max(len(fset), 1) else "file"
            kinds.append(kind)
            names.append(write(os.path.splitext(fn)[0] + " Bass.mid", loop, f) if kind == "file" else "")
        res.fills[letter] = kinds
        if any(names):
            p["fillBass"] = names

    if not aligned_any:
        res.reason = "bars of the source and the drum files do not line up (first time signature is not the song's)"
        return finish()

    # intro / ending: the bars extract_drums.py took (before the first / after the last groove bar)
    gbars = [i for i in range(len(src_bars)) if src_sigs[i] in groove_sigs and _musical(src_bars[i])]
    if gbars and lay.get("intro"):
        intro = DrumFile(os.path.join(song_dir, lay["intro"]))
        first = gbars[0]
        cand = [j for j in range(max(0, first - 4), first) if len(src_bars[j]) >= 2]
        w = [tm_bar(j) for j in cand]
        if cand and [src_sigs[j] for j in cand] == intro.sigs and all(x is not None for x in w):
            if sum(1 for b in w if events.get(b)) >= max(1, len(w) / 2):
                loop = parts.build_loop([w], events, units, grid, pitched=True)
                if loop and loop.notes:
                    lay["introBass"] = write("Intro Bass.mid", loop, intro)
                    res.intro = "bars"
    if gbars and lay.get("outro"):
        ending = DrumFile(os.path.join(song_dir, lay["outro"]))
        last = gbars[-1]
        cand = [j for j in range(last + 1, last + 3) if j < len(src_bars) and len(src_bars[j]) >= 1]
        w = [tm_bar(j) for j in cand]
        if cand and [src_sigs[j] for j in cand] == ending.sigs and all(x is not None for x in w):
            length = units * len(w)
            if any(events.get(b) for b in w):
                loop = parts.build_loop([w], events, units, grid, pitched=True)
                if loop and loop.notes:
                    lay["outroBass"] = write("Ending Bass.mid", loop, ending)
                    res.ending = "bars"
            else:
                # the bass stops with the last groove: its first note there, held up to two beats
                lb = next((b for b in range(w[0] - 1, -1, -1) if events.get(b)), None)
                if lb is not None:
                    e = min(events[lb])
                    loop = parts.Loop([(0, min(length, max(e[1], 2 * U)), e[2], e[3])], length, "final", 1.0, 1)
                    lay["outroBass"] = write("Ending Bass.mid", loop, ending)
                    res.ending = "final"
    if any("bass" in p for p in lay["parts"]):
        lay["bassRoot"] = tonic
    else:
        res.reason = res.reason or "bass silent in the drum grooves' bars"
    return finish()


# ---------------------------------------------------------------- corpus

def run(src_root: str, out_root: str) -> None:
    with open(os.path.join(src_root, "midi_songs_available.json")) as fh:
        avail = json.load(fh)["songs"]
    midi_of: dict[str, str] = {}
    for a in avail:      # later entries overwrite earlier ones, as in extract_drums.py
        # case-insensitive, like the macOS folders it wrote ("Billy idol" went into "Billy Idol")
        midi_of[os.path.join(_clean(a["artist"]), _clean(a["title"])).casefold()] = os.path.join(src_root, a["midi_file"])
    drums = os.path.join(src_root, "drum_songs")
    out_drums = os.path.join(out_root, "drum_songs")
    for _ in range(3):  # Finder may drop a .DS_Store in while we delete (as in extract_drums.py)
        if os.path.exists(out_root):
            shutil.rmtree(out_root, ignore_errors=True)
    if os.path.exists(out_root):
        shutil.rmtree(out_root)      # still there: fail with the real error
    os.makedirs(out_drums)
    results: list[SongResult] = []
    errors: list[str] = []
    for artist in sorted(os.listdir(drums)):
        adir = os.path.join(drums, artist)
        if not os.path.isdir(adir):
            continue
        for title in sorted(os.listdir(adir)):
            sdir = os.path.join(adir, title)
            if not os.path.exists(os.path.join(sdir, "song.json")):
                continue
            rel = os.path.join(artist, title)
            try:
                results.append(build_song(midi_of.get(rel.casefold(), ""), sdir, os.path.join(out_drums, rel)))
            except Exception as ex:  # noqa: BLE001
                errors.append(f"{rel}: {type(ex).__name__}: {ex}")
                shutil.copytree(sdir, os.path.join(out_drums, rel), dirs_exist_ok=True)
    for k in PERC_FOLDERS:
        src = os.path.join(src_root, k)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(out_root, k), ignore=shutil.ignore_patterns(".DS_Store"))
    _report(results, errors, out_root)


def _report(results: list[SongResult], errors: list[str], out_root: str) -> None:
    with_bass = [r for r in results if any("method" in g for g in r.grooves.values())]
    grooves = [g for r in results for g in r.grooves.values()]
    got = [g for g in grooves if "method" in g]
    cons = sorted(g["consistency"] for g in got)

    def q(p: float) -> float:
        return cons[min(len(cons) - 1, int(p * len(cons)))] if cons else 0

    reasons = Counter(r.reason for r in results if r not in with_bass)
    lines = ["# Song pack: bass for the song's own drums (E6)", "",
             f"- Drum songs: {len(results)}, errors: {len(errors)}",
             f"- With bass: **{len(with_bass)}** ({100 * len(with_bass) / max(len(results), 1):.0f} %)",
             f"- Grooves with bass: {len(got)} of {len(grooves)}; methods {dict(Counter(g['method'] for g in got))}",
             f"- Consistency P10 {q(0.1):.2f}, median {q(0.5):.2f}, P90 {q(0.9):.2f}",
             f"- Intro bass: {sum(1 for r in results if r.intro)}; ending bass: "
             f"{dict(Counter(r.ending for r in results if r.ending))}",
             f"- Fill bass: {sum(1 for r in results if any('file' in v for v in r.fills.values()))} songs, fills "
             f"{dict(Counter(k for r in results for v in r.fills.values() for k in v))}",
             "", "## Without bass", ""]
    lines += [f"- {k or 'grooves without bass'}: {v}" for k, v in reasons.most_common()]
    if errors:
        lines += ["", "## Errors", ""] + [f"- {e}" for e in errors[:50]]
    low = sorted((g["consistency"], r.folder) for r in with_bass for g in r.grooves.values() if "method" in g)[:20]
    lines += ["", "## Least consistent grooves (listen first)", ""]
    lines += [f"- {c:.2f}  {os.path.relpath(f, os.path.dirname(os.path.dirname(f)))}" for c, f in low]
    with open(os.path.join(out_root, "songpack_report.md"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(out_root, "songpack.json"), "w") as fh:
        json.dump([{"folder": os.path.relpath(r.folder, os.path.dirname(os.path.dirname(r.folder))), "key": r.key,
                    "reason": r.reason, "grooves": r.grooves, "intro": r.intro, "ending": r.ending, "fills": r.fills}
                   for r in results], fh, indent=1, ensure_ascii=False)
    print("\n".join(lines[:9]))
