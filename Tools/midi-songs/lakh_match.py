#!/usr/bin/env python3
"""Fallback source: Lakh MIDI Dataset (lmd_matched).

Needs (downloaded into <data>/lakh_data):
  lmd_matched.tar.gz   MIDI files, folder = Million Song Dataset track id
  match_scores.json    {track_id: {md5: score}}  (how well a MIDI matches the track)
  track_metadata.db    MSD metadata (track_id -> title, artist)

For every song in midi.json that has no MIDI yet (per midi_results.json) it fuzzy-matches
title+artist against the MSD tracks that have MIDI matches, picks the MIDI with the best
match score and extracts it into <data>/midis. Result goes to lakh_results.json.
Run build_map.py afterwards to merge everything into midi_map.json.
"""
import difflib
import json
import sqlite3
import tarfile
from collections import defaultdict

from paths import DATA
from download_midis import OUT_DIR, SONGS_JSON, RESULTS, pick_best, slug, title_key

LAKH = DATA / "lakh_data"
OUT = DATA / "lakh_results.json"


def main():
    songs = json.loads(SONGS_JSON.read_text())["songs"]
    results = json.loads(RESULTS.read_text()) if RESULTS.exists() else {}
    todo = [s for s in songs if results.get(f'{s["artist"]} - {s["title"]}', {}).get("status") != "ok"]
    print(f"{len(todo)} songs without MIDI -> searching Lakh")

    scores = json.loads((LAKH / "match_scores.json").read_text())
    db = sqlite3.connect(f"file:{LAKH / 'track_metadata.db'}?mode=ro", uri=True)
    by_key = defaultdict(list)  # title_key -> [(title, artist, track_id)]
    for tid, title, artist in db.execute("SELECT track_id, title, artist_name FROM songs"):
        if tid in scores and title:
            by_key[title_key(title)].append((title, artist or "", tid))
    keys = list(by_key)
    print(f"{len(keys)} distinct titles with MIDI matches")

    wanted = {}   # md5 -> info
    found = {}    # song key -> info
    for s in todo:
        k = title_key(s["title"])
        cand_keys = [k] if k in by_key else []
        if not cand_keys:
            cand_keys = difflib.get_close_matches(k, keys, n=5, cutoff=0.85)
        cards = [(t, a, tid) for ck in cand_keys for t, a, tid in by_key[ck]]
        m = pick_best(s["title"], s["artist"], cards)
        if not m:
            continue
        t, a, tid = m
        md5, sc = max(scores[tid].items(), key=lambda kv: kv[1])
        fname = f"{slug(s['artist'])}__{slug(s['title'])}__lmd{md5[:8]}.mid"
        info = {"title": s["title"], "artist": s["artist"], "status": "ok", "source": "lakh",
                "file": fname, "md5": md5, "track_id": tid, "match_score": sc,
                "matched_title": t, "matched_artist": a}
        found[f'{s["artist"]} - {s["title"]}'] = info
        wanted.setdefault(md5, []).append(info)
    print(f"{len(found)} songs matched, extracting {len(wanted)} MIDI files from the archive...")

    OUT_DIR.mkdir(exist_ok=True)
    extracted = set()
    with tarfile.open(LAKH / "lmd_matched.tar.gz", "r|gz") as tar:  # one sequential pass
        for member in tar:
            if not member.isfile() or not member.name.endswith(".mid"):
                continue
            md5 = member.name.rsplit("/", 1)[-1][:-4]
            if md5 not in wanted or md5 in extracted:
                continue
            data = tar.extractfile(member).read()
            if data.startswith(b"MThd"):
                for info in wanted[md5]:
                    (OUT_DIR / info["file"]).write_bytes(data)
                extracted.add(md5)
            if len(extracted) == len(wanted):
                break

    final = {k: v for k, v in found.items() if v["md5"] in extracted}
    OUT.write_text(json.dumps(final, indent=2, ensure_ascii=False))
    print(f"done: {len(final)} songs from Lakh -> {OUT.name}")


if __name__ == "__main__":
    main()
