#!/usr/bin/env python3
"""Merge midi_results.json (freemidi/midiworld/bitmidi) and lakh_results.json into midi_map.json."""
import json

from download_midis import RESULTS, SONGS_JSON
from paths import DATA

results = json.loads(RESULTS.read_text()) if RESULTS.exists() else {}
lakh_path = DATA / "lakh_results.json"
lakh = json.loads(lakh_path.read_text()) if lakh_path.exists() else {}

mapped, by_source = [], {}
for s in json.loads(SONGS_JSON.read_text())["songs"]:
    key = f'{s["artist"]} - {s["title"]}'
    r = results.get(key, {})
    if r.get("status") != "ok":
        r = lakh.get(key, {})
    ok = r.get("status") == "ok"
    src = r.get("source", "freemidi") if ok else None
    by_source[src] = by_source.get(src, 0) + 1
    mapped.append({**s, "midi_file": f'midis/{r["file"]}' if ok else None, "source": src})

(DATA / "midi_map.json").write_text(json.dumps({"count": len(mapped), "songs": mapped}, indent=2, ensure_ascii=False))
print(f"{sum(1 for m in mapped if m['midi_file'])} of {len(mapped)} songs have a MIDI file")
print(by_source)
