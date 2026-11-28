#!/usr/bin/env python3
"""Pack Groove Monkee World Beats (GM layered) into PedalBeat song folders.

Handy Grooves–style layout per rhythm:
  Groove A = simplest / base loop
  Groove B = densest layered variant (last letter suffix)
  up to 3 fills when present

Output is importable via PedalBeat → Import MIDI, Folder or Kit…
Requires a local copy of Groove Monkee World Beats under gm-loops/
(commercial; not redistributed). Pair with kits/pedalbeat.world-percussion.pbkit.
"""

from __future__ import annotations

import json
import re
import shutil
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "gm-loops/Groove Monkee World Beats/Groove Monkee World Beats GM/Multi-Track/Layered Beats"
OUT = ROOT / "world-grooves/World Percussion"

# "… Fill" or "… Fill 2" optionally followed by "(6-8)" etc.
FILL_RE = re.compile(r"\s+[Ff]ill(?:\s+\d+)?(?:\s*\([^)]+\))?$")
# Variant only when glued to a number ("04a") or as its own token (" 02a (6-8)" / " a").
VARIANT_TOKEN_RE = re.compile(r"(?:(\d+)([a-e])|\s+([a-e]))(?=\s*\(|$)", re.I)


def strip_fill(stem: str) -> str:
    return FILL_RE.sub("", stem).strip()


def base_key(stem: str) -> str:
    s = strip_fill(stem)
    # Remove number-glued variants: 04a → 04, 02a (6-8) → 02 (6-8), 12e → 12
    s = re.sub(r"(\d+)[a-e]\b", r"\1", s, flags=re.I)
    # Remove lone trailing variant token before optional meter: " Name a (6-8)" / " Name a"
    s = re.sub(r"\s+[a-e](?=\s*\(|$)", "", s, flags=re.I)
    return re.sub(r"\s+", " ", s).strip()


def variant_rank(stem: str) -> int:
    if FILL_RE.search(stem):
        return -1
    s = strip_fill(stem)
    m = VARIANT_TOKEN_RE.search(s)
    if not m:
        return 0
    letter = (m.group(2) or m.group(3) or "").lower()
    return ord(letter) - ord("a") + 1 if letter else 0


def song_title(base: str) -> str:
    m = re.match(r"^(\d+)\s+(.+)$", base)
    if m:
        return f"{m.group(2)} · {m.group(1)}"
    return base


def meter_tag(folder: str, base: str) -> str:
    blob = f"{folder} {base}".lower()
    if "6-8" in blob or "12-8" in blob:
        return " 6/8"
    if "3-4" in blob:
        return " 3/4"
    return ""


def pack(src: Path = SRC, out: Path = OUT) -> int:
    if not src.is_dir():
        print(f"missing source: {src}", file=sys.stderr)
        return 1

    groups: dict[tuple[str, str], dict] = defaultdict(lambda: {"mains": [], "fills": []})
    for p in sorted(src.rglob("*.mid")):
        stem = p.stem
        folder = p.parent.name
        key = (folder, base_key(stem))
        if FILL_RE.search(stem):
            groups[key]["fills"].append(p)
        else:
            groups[key]["mains"].append(p)

    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    n = 0
    for (folder, base), g in sorted(groups.items(), key=lambda x: x[0][1]):
        mains = sorted(g["mains"], key=lambda p: (variant_rank(p.stem), p.name.lower()))
        fills = sorted(g["fills"], key=lambda p: p.name.lower())
        if not mains:
            # Orphan fill-only (shouldn't happen after FILL_RE fix) — skip
            continue

        groove_a = mains[0]
        groove_b = mains[-1] if len(mains) > 1 else mains[0]
        parts_src = [groove_a] if groove_a.resolve() == groove_b.resolve() else [groove_a, groove_b]

        title = song_title(base)
        meter = meter_tag(folder, base)
        song_dir = out / f"{n + 1:02d} {title}{meter}".replace("/", "-")
        song_dir.mkdir(parents=True)

        layout_parts = []
        letters = "ABCDEFGH"
        for i, src_mid in enumerate(parts_src):
            letter = letters[i]
            main_name = f"Groove {letter}.mid"
            shutil.copy2(src_mid, song_dir / main_name)
            fill_names = []
            if fills:
                for fi in range(min(3, len(fills))):
                    fname = f"Groove {letter} Fill {fi + 1}.mid"
                    shutil.copy2(fills[fi], song_dir / fname)
                    fill_names.append(fname)
                # Pad to 3 slots by cycling if fewer than 3 unique fills
                while len(fill_names) < 3 and fills:
                    fi = len(fill_names)
                    fname = f"Groove {letter} Fill {fi + 1}.mid"
                    shutil.copy2(fills[fi % len(fills)], song_dir / fname)
                    fill_names.append(fname)
            layout_parts.append({"main": main_name, "fills": fill_names})

        for name in ("Intro.mid", "Transition.mid", "Ending.mid"):
            shutil.copy2(groove_a, song_dir / name)

        song = {
            "format": 1,
            "genre": "World Percussion",
            "name": f"World Percussion · {title}{meter}",
            "layout": {
                "intro": "Intro.mid",
                "outro": "Ending.mid",
                "transition": "Transition.mid",
                "introCrash": False,
                "fillCrash": False,
                "kitHint": 0,
                "parts": layout_parts,
            },
        }
        (song_dir / "song.json").write_text(json.dumps(song, indent=2) + "\n")
        n += 1
        print(f"  {song_dir.name}: {len(parts_src)} parts, {len(fills)} fills")

    (out.parent / "README.md").write_text(
        "# World Percussion grooves\n\n"
        "PedalBeat song folders packed from **Groove Monkee World Beats** (GM Layered Beats),\n"
        "Handy Grooves–style: Groove A (simple) / Groove B (layered) + fills.\n\n"
        "**Import:** PedalBeat → *Import MIDI, Folder or Kit…* → select `world-grooves/`.\n"
        "Use with `kits/pedalbeat.world-percussion.pbkit`.\n\n"
        "Source is commercial Groove Monkee content under `gm-loops/`; regenerate with:\n"
        "```sh\n"
        "python3 Tools/WorldGroovesPack/pack_world_grooves.py\n"
        "```\n"
    )
    print(f"\npacked {n} songs → {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(pack())
