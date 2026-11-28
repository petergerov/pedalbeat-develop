"""Reports: source corpus (E0/E1) and factory-song drum features (E1)."""
from __future__ import annotations

import json
import os
import statistics
from collections import Counter

from . import factory, quant, roles, smf, timemap

PERC = {39: "clap", 54: "tambourine", 69: "cabasa", 70: "maracas", 82: "shaker", 56: "cowbell", 75: "claves"}


def _quality(bass_score, coverage, mono, q, tm, has_drums, nbars, notes) -> float:
    """0..1; built so that unusable sources land clearly below 0.6."""
    dens = notes / max(nbars, 1)
    feel_ok = {"straight": 1.0, "triplet": 1.0, "mixed": 0.6, "loose": 0.2, "none": 0.0}[q.feel]
    s = (0.20 * bass_score + 0.20 * min(coverage / 0.8, 1.0) + 0.15 * mono + 0.15 * feel_ok
         + 0.10 * (1.0 - min(q.offgrid / 0.2, 1.0)) + 0.10 * min(dens / 3.0, 1.0)
         + 0.05 * (1.0 if has_drums else 0.4) + 0.05 * (1.0 if nbars >= 16 else 0.3))
    if tm.tempo_changes or tm.timesig_changes:
        s -= 0.15
    if tm.warnings:
        s -= 0.05 * len(tm.warnings)
    return max(0.0, min(1.0, s))


def analyse(path: str, bars_out: str | None = None) -> dict:
    s = smf.parse(path)
    lanes = roles.split_lanes(s)
    bass = next((l for l in lanes if l.role == "bass"), None)
    drums = [l for l in lanes if l.role == "drums"]
    tm = timemap.build(s)
    first = tm.bars[0]
    out: dict = {
        "file": os.path.basename(path), "format": s.fmt, "ppq": s.ppq,
        "timesig": f"{first.num}/{first.den}", "bars": len(tm.bars),
        "bpm": tm.bpm, "bpm_folded": tm.bpm_folded,
        "timesig_changes": tm.timesig_changes, "tempo_changes": tm.tempo_changes,
        "warnings": tm.warnings, "markers": len(s.markers),
        "lanes": [{"id": l.key, "role": l.role, "name": l.name, "program": l.program,
                   "notes": len(l.notes), "bass_score": round(l.bass_score, 2)} for l in lanes],
        "drums": bool(drums),
    }
    perc: Counter = Counter()
    for l in drums:
        for n in l.notes:
            if n.pitch in PERC:
                perc[PERC[n.pitch]] += 1
    out["percussion"] = dict(perc)

    q = 0.0
    if bass:
        qb = quant.quantise(bass.notes, tm)
        covered = len({n.bar for n in qb.notes})
        coverage = covered / max(len(tm.bars), 1)
        mono = roles.monophony(bass.notes)
        out["bass"] = {
            "lane": bass.key, "notes": len(qb.notes),
            "pitch_min": min(n.pitch for n in bass.notes), "pitch_max": max(n.pitch for n in bass.notes),
            "pitch_median": statistics.median(n.pitch for n in bass.notes),
            "monophony": round(mono, 2), "bar_coverage": round(coverage, 2),
            "feel": qb.feel, "offgrid": qb.offgrid, "triplet_share": qb.triplet_share,
            "poly_dropped": qb.dropped_poly,
        }
        q = _quality(bass.bass_score, coverage, mono, qb, tm, bool(drums), len(tm.bars), len(qb.notes))
        if bars_out:
            rows: dict[int, list] = {}
            for n in qb.notes:
                rows.setdefault(n.bar, []).append([n.pos, n.dur, n.pitch, n.vel])
            doc = {"file": out["file"], "unit": "1/12 quarter", "timesig": out["timesig"],
                   "bpm": tm.bpm, "feel": qb.feel,
                   "bars": [{"bar": b.index, "units": tm.bar_units(b), "notes": rows.get(b.index, [])}
                            for b in tm.bars]}
            with open(os.path.join(bars_out, os.path.splitext(out["file"])[0] + ".json"), "w") as fh:
                json.dump(doc, fh, separators=(",", ":"))
    out["quality"] = round(q, 2)
    out["usable"] = bool(bass) and q >= 0.65
    return out


def run(midi_dir: str, out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    bars_dir = os.path.join(out_dir, "bass_bars")
    os.makedirs(bars_dir, exist_ok=True)
    rows, errors = [], []
    for f in sorted(os.listdir(midi_dir)):
        if not f.lower().endswith((".mid", ".midi")):
            continue
        try:
            rows.append(analyse(os.path.join(midi_dir, f), bars_dir))
        except Exception as ex:  # noqa: BLE001 - report every broken file
            errors.append({"file": f, "error": f"{type(ex).__name__}: {ex}"})
    with open(os.path.join(out_dir, "corpus_report.json"), "w") as fh:
        json.dump({"songs": rows, "errors": errors}, fh, indent=1)

    with_bass = [r for r in rows if "bass" in r]
    usable = [r for r in rows if r["usable"]]
    qs = sorted(r["quality"] for r in with_bass)
    md = [
        "# Corpus report (E1)", "",
        f"- Dateien: **{len(rows)}** (Lesefehler: {len(errors)})",
        f"- mit Bass-Lane: **{len(with_bass)}**, mit Drums: {sum(r['drums'] for r in rows)}",
        f"- brauchbar (Quality ≥ 0.65): **{len(usable)}**; Quality Median {statistics.median(qs) if qs else 0}, "
        f"P10 {qs[len(qs) // 10] if qs else 0}, P90 {qs[len(qs) * 9 // 10] if qs else 0}",
        f"- Taktarten (erste): {dict(Counter(r['timesig'] for r in rows))}",
        f"- Format: {dict(Counter(r['format'] for r in rows))}",
        f"- Bass-Feel: {dict(Counter(r['bass']['feel'] for r in with_bass))}",
        f"- Taktartwechsel / Tempowechsel: "
        f"{sum(r['timesig_changes'] > 0 for r in rows)} / {sum(r['tempo_changes'] > 0 for r in rows)}",
        f"- Warnungen: {dict(Counter(w.split(' ')[0] + ' ' + w.split(' ')[1] for r in rows for w in r['warnings']))}",
        f"- Perkussion (Noten): {dict(sum((Counter(r['percussion']) for r in rows), Counter()))}",
        "", "| Datei | Q | Takte | BPM | TS | Bass-Noten | Feel | offgrid | Drums | Perc |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for r in sorted(rows, key=lambda r: -r["quality"]):
        b = r.get("bass")
        md.append(f"| {r['file'][:56]} | {r['quality']} | {r['bars']} | {r['bpm']} | {r['timesig']} | "
                  f"{b['notes'] if b else '–'} | {b['feel'] if b else '–'} | {b['offgrid'] if b else '–'} | "
                  f"{'✓' if r['drums'] else '–'} | {','.join(r['percussion']) or '–'} |")
    if errors:
        md += ["", "## Fehler"] + [f"- {e['file']}: {e['error']}" for e in errors]
    with open(os.path.join(out_dir, "corpus_report.md"), "w") as fh:
        fh.write("\n".join(md) + "\n")
    print(f"{len(rows)} files, {len(with_bass)} with bass, {len(usable)} usable, {len(errors)} errors -> {out_dir}")


def run_factory(songs_dir: str, out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    songs = factory.load_all(songs_dir)
    with open(os.path.join(out_dir, "factory_drums.json"), "w") as fh:
        json.dump(factory.to_json(songs), fh, separators=(",", ":"))
    n_pat = sum(len(s.patterns) for s in songs)
    md = ["# Factory-Songs: Drum-Merkmale (E1)", "",
          f"- Songs: **{len(songs)}**, Patterns: {n_pat}, Parts (main): {sum(len(s.mains) for s in songs)}",
          f"- Genres: {dict(Counter(s.genre for s in songs))}",
          f"- Signaturen: {dict(Counter(s.label for s in songs))}",
          f"- Grid (main): {dict(Counter(p.grid for s in songs for p in s.mains))}",
          f"- Längen (Takte, main): {dict(sorted(Counter(p.bars for s in songs for p in s.mains).items()))}",
          f"- Fill-Längen (Takte): {dict(sorted(Counter(p.bars for s in songs for p in s.patterns if p.role == 'fill').items()))}",
          f"- Warnungen: {[w for s in songs for w in s.warnings][:10]}", "",
          "| Song | BPM | Sig | Part | Takte | Grid | Kick | Snare | Hat |", "|---|---|---|---|---|---|---|---|---|"]
    for s in songs:
        for p in s.mains:
            md.append(f"| {s.key} | {s.bpm} | {p.label} | {chr(65 + (p.part or 0))} | {p.bars} | {p.grid} | "
                      f"`{p.masks.get('kick', '')}` | `{p.masks.get('snare', '')}` | "
                      f"`{p.masks.get('hat') or p.masks.get('ride', '')}` |")
    with open(os.path.join(out_dir, "factory_report.md"), "w") as fh:
        fh.write("\n".join(md) + "\n")
    print(f"{len(songs)} songs, {n_pat} patterns -> {out_dir}")
