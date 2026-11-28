#!/usr/bin/env python3
"""Cut the drum track (channel 10) or a percussion instrument (--kind shaker|tambourine|clap) of every downloaded song MIDI into PedalBeat's import layout.

    drum_songs/<Artist>/<Title>/Intro.mid, Groove A.mid, Groove A Fill 1.mid, ..., Ending.mid

No song.json is written: PedalBeat lays the song out from the file names (see songs/README.md).
Each file is Standard MIDI format 0, 480 PPQ, drums on channel 10, tempo and time signature included,
and ends exactly at the pattern length so it loops cleanly.

Needs `mido` (pip install mido).   Usage: python3 Tools/midi-songs/extract_drums.py [--limit N] [--kind …]
Reads and writes the data folder (see paths.py: MIDI_SONGS / PEDALBEAT_DATA).
"""
import argparse
import json
import re
import shutil
from collections import Counter
from pathlib import Path

import mido

from paths import DATA

PPQ = 480
GRID = PPQ // 4            # 16th note, used to compare bars
KICK, SNARE = {35, 36}, {38, 39, 40}
TOMS = {41, 43, 45, 47, 48, 50}
CRASH = {49, 55, 57}


# kind -> (GM notes on channel 10, minimum hits per bar for a usable pattern, output folder)
KINDS = {
    "drums": (None, 6, "drum_songs"),
    "shaker": ({69, 70, 82}, 3, "shaker_songs"),      # cabasa, maracas, shaker
    "tambourine": ({54}, 2, "tambourine_songs"),
    "clap": ({39}, 2, "clap_songs"),                  # hand clap
}
NOTES, MIN_HITS = None, 6


def clean(s):
    return re.sub(r"\s+", " ", re.sub(r'[\\/:*?"<>|]+', " ", s)).strip(" .") or "Unknown"


def read_drums(path):
    mid = mido.MidiFile(str(path), clip=True)  # clip=True tolerates out-of-range data bytes
    tpb = mid.ticks_per_beat
    tempo, ts = None, None
    hits = []
    for track in mid.tracks:
        t = 0
        for msg in track:
            t += msg.time
            if msg.type == "set_tempo" and tempo is None:
                tempo = msg.tempo
            elif msg.type == "time_signature" and ts is None:
                ts = (msg.numerator, msg.denominator)
            elif (msg.type == "note_on" and msg.velocity > 0 and getattr(msg, "channel", -1) == 9
                  and (NOTES is None or msg.note in NOTES)):
                hits.append((round(t * PPQ / tpb), msg.note, msg.velocity))
    return sorted(hits), tempo or 500000, ts or (4, 4)


def split_bars(hits, bar_len):
    bars = {}
    for t, n, v in hits:
        bars.setdefault(t // bar_len, []).append((t % bar_len, n, v))
    last = max(bars)
    return [bars.get(i, []) for i in range(last + 1)]


def sig(bar):
    return frozenset((n, round(o / GRID)) for o, n, _ in bar)


def musical(bar):
    if NOTES is not None:   # percussion: any bar with enough hits
        return len(bar) >= MIN_HITS
    s = {n for o, n, _ in bar}
    return len(bar) >= 6 and bool(s & KICK) and bool(s & SNARE)


def jaccard(a, b):
    return len(a & b) / len(a | b) if a | b else 1.0


def write_pattern(path, bars, bar_len, tempo, ts):
    """bars: list of bar hit-lists (offset, note, vel). Writes one format-0 file of len(bars) bars."""
    mid = mido.MidiFile(type=0, ticks_per_beat=PPQ)
    tr = mido.MidiTrack()
    tr.append(mido.MetaMessage("track_name", name=path.stem, time=0))
    tr.append(mido.MetaMessage("set_tempo", tempo=tempo, time=0))
    tr.append(mido.MetaMessage("time_signature", numerator=ts[0], denominator=ts[1], time=0))
    events = []
    for b, bar in enumerate(bars):
        for o, n, v in bar:
            start = b * bar_len + o
            events.append((start, 1, n, v))
            events.append((start + 60, 0, n, 0))
    events.sort()
    cur = 0
    for t, on, n, v in events:
        t = min(t, len(bars) * bar_len - 1) if not on else t
        tr.append(mido.Message("note_on" if on else "note_off", channel=9, note=n, velocity=v if on else 0, time=max(0, t - cur)))
        cur = max(cur, t)
    tr.append(mido.MetaMessage("end_of_track", time=max(0, len(bars) * bar_len - cur)))
    mid.tracks.append(tr)
    mid.save(str(path))


def analyse(path):
    """Return (tempo, ts, bar_len, parts, fills, intro, ending) or None if there are no usable drums."""
    hits, tempo, ts = read_drums(path)
    if len(hits) < (24 if NOTES is None else 16):
        return None
    bar_len = ts[0] * PPQ * 4 // ts[1]
    bars = split_bars(hits, bar_len)
    if len(bars) < 4:
        return None
    sigs = [sig(b) for b in bars]

    def window(i):  # a groove is one bar, or two if the bars differ
        if i + 1 < len(bars) and sigs[i + 1] != sigs[i] and musical(bars[i + 1]):
            return (sigs[i], sigs[i + 1])
        return (sigs[i],)

    counts = Counter(window(i) for i in range(len(bars)) if musical(bars[i]))
    if not counts:
        return None
    ranked = [w for w, c in counts.most_common() if c >= 2] or [counts.most_common(1)[0][0]]
    a = ranked[0]
    parts = [a]
    for w in ranked[1:]:
        if jaccard(set().union(*w), set().union(*a)) < 0.8:
            parts.append(w)
            break

    def first_bars(w):
        for i in range(len(bars)):
            if window(i) == w:
                return [bars[i + k] for k in range(len(w))]

    grooves = [first_bars(w) for w in parts]
    groove_sigs = {s for w in parts for s in w}
    groove_idx = [i for i in range(len(bars)) if sigs[i] in groove_sigs and musical(bars[i])]
    if not groove_idx:
        return None
    first, last = groove_idx[0], groove_idx[-1]

    # fills: busy bars that are not grooves and lead into a groove bar
    cand = Counter()
    for i in range(first + 1, last):
        if sigs[i] not in groove_sigs and len(bars[i]) >= max(2, MIN_HITS) and sigs[i + 1] in groove_sigs:
            cand[sigs[i]] += 1
    fill_sigs = [s for s, _ in sorted(cand.items(), key=lambda kv: (-kv[1], -len(kv[0])))][:3]
    fills = []
    for s in fill_sigs:
        i = next(i for i in range(first, last) if sigs[i] == s)
        fills.append(bars[i])

    intro = [b for b in bars[max(0, first - 4):first] if len(b) >= 2]
    ending = [b for b in bars[last + 1:last + 3] if len(b) >= 1]
    return tempo, ts, bar_len, grooves, fills, intro, ending


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--kind", choices=sorted(KINDS), default="drums")
    ap.add_argument("--out", default="")
    args = ap.parse_args()
    global NOTES, MIN_HITS
    NOTES, MIN_HITS, folder = KINDS[args.kind]
    out = Path(args.out) if args.out else DATA / folder
    for _ in range(3):  # Finder may drop a .DS_Store in while we delete
        if out.exists():
            shutil.rmtree(out, ignore_errors=True)
    songs = json.loads((DATA / "midi_songs_available.json").read_text())["songs"]
    if args.limit:
        songs = songs[: args.limit]
    ok, skipped, index = 0, [], []
    for s in songs:
        src = DATA / s["midi_file"]
        try:
            r = analyse(src)
        except Exception as e:
            r = None
            print(f"  ! {s['artist']} - {s['title']}: {e}")
        if r is None:
            skipped.append(f"{s['artist']} - {s['title']}")
            continue
        tempo, ts, bar_len, grooves, fills, intro, ending = r
        d = out / clean(s["artist"]) / clean(s["title"])
        d.mkdir(parents=True, exist_ok=True)
        if intro:
            write_pattern(d / "Intro.mid", intro, bar_len, tempo, ts)
        for k, g in enumerate(grooves):
            letter = "AB"[k]
            write_pattern(d / f"Groove {letter}.mid", g, bar_len, tempo, ts)
            for n, f in enumerate(fills, 1):
                write_pattern(d / f"Groove {letter} Fill {n}.mid", [f], bar_len, tempo, ts)
        if ending:
            write_pattern(d / "Ending.mid", ending, bar_len, tempo, ts)
        # Exact layout (like the factory songs): without it PedalBeat would split Intro/Ending
        # (no groove word in the name) into a separate song.
        layout = {"parts": [
            {"main": f"Groove {'AB'[k]}.mid", "fills": [f"Groove {'AB'[k]} Fill {n}.mid" for n in range(1, len(fills) + 1)]}
            for k in range(len(grooves))]}
        if intro:
            layout["intro"] = "Intro.mid"
        if ending:
            layout["outro"] = "Ending.mid"
        (d / "song.json").write_text(json.dumps(
            {"format": 1, "name": s["title"], "genre": f'{out.name.replace("_", " ")} › {s["artist"]}', "layout": layout},
            indent=2, ensure_ascii=False))
        ok += 1
        index.append({"artist": s["artist"], "title": s["title"], "folder": str(d.relative_to(out)),
                      "bpm": round(60_000_000 / tempo), "time_signature": f"{ts[0]}/{ts[1]}",
                      "parts": len(grooves), "fills": len(fills), "intro": bool(intro), "ending": bool(ending),
                      "source": s["source"]})
    out.mkdir(exist_ok=True)
    (out / "index.json").write_text(json.dumps(index, indent=2, ensure_ascii=False))
    (out / "skipped.txt").write_text("\n".join(skipped))
    print(f"{ok} songs with {args.kind} extracted, {len(skipped)} skipped (no/too little {args.kind}) -> {out}")


if __name__ == "__main__":
    main()
