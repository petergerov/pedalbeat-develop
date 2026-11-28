"""Links reference MIDIs to the app's SongIndex and from there to the factory song (target drums).

Chain:  "Artist__Title__id.mid"  →  SongIndex entry (title, artist, bpm, genre, beat style)
        →  Target(genre, groove) via the app's styleMap / genreFallback
        →  factory song whose genre matches and whose name ends in " · <groove>"
Reads the tables straight from the app sources (Core/SongIndexData.swift, Core/SongIndex.swift),
so it stays in sync with what the app plays when a song is picked.
"""
from __future__ import annotations

import difflib
import os
import re
import unicodedata
from dataclasses import dataclass


@dataclass
class Entry:
    title: str
    artist: str
    bpm: float
    genre: str
    style: str
    target_genre: str
    target_groove: str


@dataclass
class Link:
    file: str
    entry: Entry | None
    score: float              # 0..1 match confidence
    factory_key: str | None   # "Genre/Folder" of the factory song, None if not found


def normalize(s: str) -> str:
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return " ".join(s.split())


def _strip_the(s: str) -> str:
    return s[4:] if s.startswith("the ") else s


def load_index(app_dir: str) -> list[Entry]:
    core = os.path.join(app_dir, "Core")
    src = open(os.path.join(core, "SongIndex.swift")).read()
    style_map = {m[0]: (m[1], m[2]) for m in re.findall(r'\("([^"]+)",\s*"([^"]+)",\s*"([^"]+)"\)', src)}
    fallback = {m[0]: (m[1], m[2]) for m in
                re.findall(r'"([^"]+)":\s*Target\(genre:\s*"([^"]+)",\s*groove:\s*"([^"]+)"\)', src)}
    m = re.search(r'defaultTarget\s*=\s*Target\(genre:\s*"([^"]+)",\s*groove:\s*"([^"]+)"\)', src)
    default = (m.group(1), m.group(2)) if m else ("Rock", "Straight Eights")

    data = open(os.path.join(core, "SongIndexData.swift")).read()
    raw = data.split('#"""', 1)[1].split('"""#', 1)[0]
    out = []
    for line in raw.splitlines():
        f = line.split("\t")
        if len(f) < 5:
            continue
        try:
            bpm = float(f[2])
        except ValueError:
            continue
        tg = style_map.get(f[4]) or fallback.get(f[3]) or default
        out.append(Entry(f[0], f[1], bpm, f[3], f[4], tg[0], tg[1]))
    return out


def _split_filename(fn: str) -> tuple[str, str]:
    stem = os.path.splitext(fn)[0]
    parts = stem.split("__")
    if len(parts) >= 3:
        return parts[0].replace("_", " "), parts[1].replace("_", " ")
    if len(parts) == 2:
        return parts[0].replace("_", " "), parts[1].replace("_", " ")
    return "", stem.replace("_", " ")


class Matcher:
    def __init__(self, entries: list[Entry]):
        self.entries = entries
        self.by_title: dict[str, list[Entry]] = {}
        for e in entries:
            self.by_title.setdefault(_strip_the(normalize(e.title)), []).append(e)
        self.titles = list(self.by_title)

    def match(self, filename: str) -> tuple[Entry | None, float]:
        artist, title = _split_filename(filename)
        t, a = _strip_the(normalize(title)), _strip_the(normalize(artist))

        def artist_sim(e: Entry) -> float:
            return difflib.SequenceMatcher(None, a, _strip_the(normalize(e.artist))).ratio()

        cands = self.by_title.get(t)
        if cands:
            best = max(cands, key=artist_sim)
            sim = artist_sim(best)
            return best, round(0.6 + 0.4 * sim, 2)
        close = difflib.get_close_matches(t, self.titles, n=5, cutoff=0.8)
        best, score = None, 0.0
        for ct in close:
            ts = difflib.SequenceMatcher(None, t, ct).ratio()
            for e in self.by_title[ct]:
                s = 0.6 * ts + 0.4 * artist_sim(e)
                if s > score:
                    best, score = e, s
        if best is not None and score >= 0.75:
            return best, round(score, 2)
        return None, round(score, 2)


def factory_for(entry: Entry, factory_songs) -> str | None:
    suffix = " · " + entry.target_groove
    for s in factory_songs:
        if s.genre == entry.target_genre and s.name.endswith(suffix):
            return s.key
    return None


def link_all(files: list[str], app_dir: str, factory_songs) -> list[Link]:
    m = Matcher(load_index(app_dir))
    out = []
    for f in files:
        e, score = m.match(f)
        out.append(Link(f, e, score, factory_for(e, factory_songs) if e else None))
    return out
