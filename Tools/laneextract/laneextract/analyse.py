"""E2 runner: link → bar grid → quantised bass → chords/key → interval bass, per source MIDI.

Writes  <out>/songs/<stem>.json  (everything later stages need) and  <out>/harmony_report.md.
"""
from __future__ import annotations

import json
import os
import statistics
from collections import Counter
from dataclasses import asdict

from . import factory, gold, harmony, parts, phase, quant, roles, smf, songindex, structure, timemap


def analyse_file(path: str, link: songindex.Link | None, part_counts: dict[str, int] | None = None,
                 fsongs: dict | None = None, export_dir: str | None = None) -> dict:
    s = smf.parse(path)
    lanes = roles.split_lanes(s)
    bass = next((l for l in lanes if l.role == "bass"), None)
    offset, phase_info = phase.estimate(s, lanes, bass) if bass else (0, {})
    tm = timemap.build(s, offset=offset)
    doc: dict = {"file": os.path.basename(path), "unit": "1/12 quarter",
                 "timesig": f"{tm.bars[-1].num}/{tm.bars[-1].den}", "bpm": tm.bpm, "bpm_folded": tm.bpm_folded,
                 "pickup_units": offset * timemap.U // s.ppq, "phase": phase_info,
                 "warnings": tm.warnings}
    if link and link.entry:
        e = link.entry
        doc["index"] = {"title": e.title, "artist": e.artist, "bpm": e.bpm, "genre": e.genre, "style": e.style,
                        "target": f"{e.target_genre} · {e.target_groove}", "factory": link.factory_key,
                        "match": link.score}
    if not bass:
        doc["bass"] = None
        return doc
    qb = quant.quantise(bass.notes, tm)
    h = harmony.analyse(tm, lanes, qb)
    doc["feel"] = qb.feel
    doc["key"] = {"name": h.key.name, "tonic": h.key.tonic, "mode": h.key.mode, "conf": h.key.conf} if h.key else None
    doc["stats"] = h.stats
    chords_by_bar: dict[int, list] = {}
    for c in h.chords:
        chords_by_bar.setdefault(c.bar, []).append(
            {"start": c.start, "end": c.end, "name": c.name, "root": c.root, "quality": c.quality,
             "conf": c.conf, "carried": c.carried})
    notes_by_bar: dict[int, list] = {}
    for n in h.notes:
        notes_by_bar.setdefault(n.bar, []).append([n.pos, n.dur, n.pitch, n.vel, n.rel, n.deg, n.role])
    st, feats = structure.analyse(tm, lanes, h)
    nparts = (part_counts or {}).get(link.factory_key, 2) if link else 2
    doc["structure"] = {"timeline": st.timeline(), "conf": st.conf, "music_start": st.music_start,
                        "sections": [{"start": x.start, "end": x.end, "group": x.group, "label": x.label,
                                      "energy": x.energy} for x in st.sections],
                        "groups": {str(k): v for k, v in st.groups.items()}}
    doc["mapping"] = structure.map_to_factory(st, nparts)
    doc["factory_parts"] = nparts
    doc["chord_sheet"] = structure.chord_sheet(h, st)
    fs = (fsongs or {}).get(link.factory_key) if link else None
    if fs is not None:
        sp = parts.build(tm, lanes, h, st, feats, doc["mapping"], fs)
        doc["parts"] = {"bass": {k: {"method": v.method, "consistency": v.consistency, "bars": v.bars_used,
                                     "notes": len(v.notes)} for k, v in sp.bass.items()},
                        "percussion": {k: {"instruments": sorted({parts.PERC_NAMES[n[2]] for n in v.notes}),
                                           "consistency": v.consistency} for k, v in sp.perc.items()},
                        "sources": sp.sources, "notes": sp.notes,
                        "fills": {k: {str(n): {"kind": f.kind, "count": f.count, "notes": len(f.loop.notes)}
                                      for n, f in v.items()} for k, v in sp.fill_bass.items()},
                        "fill_perc": {k: {str(n): f.kind for n, f in v.items()} for k, v in sp.fill_perc.items()},
                        "transition": ({"kind": sp.transition.kind, "count": sp.transition.count}
                                       if sp.transition else None)}
        if export_dir:
            doc["export"] = parts.export(sp, fs, link.entry, doc, export_dir)
    doc["bars"] = [{"bar": b.index, "units": tm.bar_units(b), "chords": chords_by_bar.get(b.index, []),
                    "notes": notes_by_bar.get(b.index, []),
                    "energy": round(feats[b.index].energy, 3), "crash": feats[b.index].crash,
                    "toms": feats[b.index].tom_hits} for b in tm.bars]
    return doc


def run(midi_dir: str, songs_dir: str, app_dir: str, out_dir: str) -> None:
    export_dir = os.path.join(out_dir, "examples")
    os.makedirs(os.path.join(out_dir, "songs"), exist_ok=True)
    files = sorted(f for f in os.listdir(midi_dir) if f.lower().endswith((".mid", ".midi")))
    fsongs = factory.load_all(songs_dir)
    links = {l.file: l for l in songindex.link_all(files, app_dir, fsongs)}
    part_counts = {fs.key: len(fs.mains) for fs in fsongs}
    fs_by_key = {fs.key: fs for fs in fsongs}
    docs, errors = [], []
    for f in files:
        try:
            d = analyse_file(os.path.join(midi_dir, f), links.get(f), part_counts, fs_by_key, export_dir)
        except Exception as ex:  # noqa: BLE001
            errors.append(f"{f}: {type(ex).__name__}: {ex}")
            continue
        docs.append(d)
        with open(os.path.join(out_dir, "songs", os.path.splitext(f)[0] + ".json"), "w") as fh:
            json.dump(d, fh, separators=(",", ":"))
    with open(os.path.join(out_dir, "links.json"), "w") as fh:
        json.dump([{"file": l.file, "score": l.score, "factory": l.factory_key,
                    "entry": asdict(l.entry) if l.entry else None} for l in links.values()], fh, indent=1)
    sheets = {}
    for d in docs:
        if d.get("chord_sheet") and d.get("index"):
            sheets[f"{d['index']['artist']} - {d['index']['title']}"] = d["chord_sheet"]
    with open(os.path.join(out_dir, "chord_sheets.json"), "w") as fh:
        json.dump(sheets, fh, indent=1, ensure_ascii=False)
    _report(docs, errors, list(links.values()), out_dir)
    _structure_report(docs, out_dir)
    _parts_report(docs, out_dir)


def _report(docs: list[dict], errors: list[str], links: list, out_dir: str) -> None:
    with_key = [d for d in docs if d.get("key")]
    linked = [l for l in links if l.entry]
    to_factory = [l for l in linked if l.factory_key]
    # tempo agreement between the MIDI and the index (folded, ±4 %)
    tempo_ok = tempo_n = 0
    for d in docs:
        if "index" in d and d.get("bpm_folded"):
            ib = d["index"]["bpm"]
            while ib > 160:
                ib /= 2
            while ib < 70:
                ib *= 2
            tempo_n += 1
            tempo_ok += abs(ib - d["bpm_folded"]) / ib <= 0.04
    g = []
    for d in with_key:
        exp = gold.expected(d["file"])
        if exp:
            g.append((d["file"], d["key"]["name"], harmony.PC[exp[0]] + ("m" if exp[1] == "minor" else ""
                                                                         if exp[1] else " (tonic)"),
                      gold.verdict(exp, d["key"]["tonic"], d["key"]["mode"]), d["key"]["conf"]))
    gv = Counter(v for *_, v, _ in g)

    def med(key: str) -> float:
        xs = [d["stats"][key] for d in with_key]
        return round(statistics.median(xs), 3) if xs else 0.0

    roles_total: Counter = Counter()
    degs_total: Counter = Counter()
    for d in with_key:
        roles_total.update(d["stats"]["roles"])
        degs_total.update(d["stats"]["degrees"])
    nroles = sum(roles_total.values()) or 1
    ndeg = sum(degs_total.values()) or 1

    md = ["# Harmonie & Intervall-Bass (E2)", "",
          f"- Songs analysiert: **{len(docs)}** (Fehler: {len(errors)}), mit Bass + Tonart: {len(with_key)}",
          f"- SongIndex-Treffer: **{len(linked)}/{len(links)}**, davon mit Factory-Song: {len(to_factory)}",
          f"- Tempo MIDI ≈ Index (±4 %, gefaltet): {tempo_ok}/{tempo_n}",
          f"- Taktgitter verschoben (Auftakt): {sum(1 for d in docs if d.get('pickup_units'))} "
          f"(1 Schlag: {sum(1 for d in docs if d.get('phase', {}).get('beat_shift'))}, "
          f"halber Takt: {sum(1 for d in docs if d.get('phase', {}).get('half_shift'))})",
          f"- Ziel-Grooves (Top): {dict(Counter(l.factory_key for l in to_factory).most_common(12))}",
          "",
          "## Tonart-Plausibilität (bekannte Songs)", "",
          f"Ergebnis: {dict(gv)} von {len(g)}", "",
          "| Datei | erkannt | erwartet | Urteil | conf |", "|---|---|---|---|---|"]
    md += [f"| {f[:52]} | {k} | {e} | {v} | {c} |" for f, k, e, v, c in sorted(g, key=lambda r: r[3])]
    md += ["", "## Korpus-Statistik (Median über Songs)", "",
           f"- Akkord-Konfidenz: {med('chord_conf_median')}",
           f"- Akkordwechsel pro Takt: {med('changes_per_bar')}",
           f"- Anteil Akkordwechsel auf der Eins: {med('changes_on_one')} "
           f"(Songs mit < 50 %: {sum(1 for d in with_key if d['stats']['changes_on_one'] < 0.5)})",
           f"- Akkord-Vokabular pro Song: {med('vocabulary')}",
           f"- Akkordton-Anteil auf Zählzeiten: {med('strong_chord_tone_share')}",
           f"- Grundton auf Akkordbeginn: {med('root_on_chord_start')}",
           f"- Rollen der Basstöne (gesamt): " + ", ".join(f"{k} {v / nroles:.1%}" for k, v in roles_total.most_common()),
           f"- Stufen (gesamt): " + ", ".join(f"{k} {v / ndeg:.1%}" for k, v in degs_total.most_common(12)),
           "", "## Songs", "",
           "| Datei | Tonart | conf | Feel | Wechsel/Takt | Akkordton | Ziel (Factory) | Erste Akkorde |",
           "|---|---|---|---|---|---|---|---|"]
    for d in sorted(with_key, key=lambda d: d["file"]):
        first = []
        for b in d["bars"]:
            for c in b["chords"]:
                if not c["carried"] and (not first or first[-1] != c["name"]):
                    first.append(c["name"])
            if len(first) >= 8:
                break
        md.append(f"| {d['file'][:44]} | {d['key']['name']} | {d['key']['conf']} | {d.get('feel')} | "
                  f"{d['stats']['changes_per_bar']} | {d['stats']['strong_chord_tone_share']} | "
                  f"{(d.get('index') or {}).get('factory') or '–'} | {' '.join(first[:8])} |")
    unl = [l.file for l in links if not l.entry]
    if unl:
        md += ["", f"## Ohne SongIndex-Treffer ({len(unl)})", ""] + [f"- {f}" for f in unl]
    if errors:
        md += ["", "## Fehler", ""] + [f"- {e}" for e in errors]
    with open(os.path.join(out_dir, "harmony_report.md"), "w") as fh:
        fh.write("\n".join(md) + "\n")
    print(f"{len(docs)} songs, {len(with_key)} with key, links {len(linked)}/{len(links)} "
          f"(factory {len(to_factory)}), gold {dict(gv)} of {len(g)}, errors {len(errors)}")


def _structure_report(docs: list[dict], out_dir: str) -> None:
    ds = [d for d in docs if d.get("structure")]
    labels: Counter = Counter()
    lens: Counter = Counter()
    for d in ds:
        for x in d["structure"]["sections"]:
            labels[x["label"]] += 1
            lens[x["end"] - x["start"]] += 1
    has = lambda d, lab: any(x["label"] == lab for x in d["structure"]["sections"])  # noqa: E731
    mapped = Counter()
    for d in ds:
        for k, v in d["mapping"].items():
            if k.isalpha() and len(k) == 1 and v:
                mapped[f"{k}={v['label']}"] += 1
    confs = sorted(d["structure"]["conf"] for d in ds)
    md = ["# Struktur der Quellsongs (E3)", "",
          f"- Songs: **{len(ds)}**; mit Verse: {sum(has(d, 'verse') for d in ds)}, Chorus: "
          f"{sum(has(d, 'chorus') for d in ds)}, Bridge: {sum(has(d, 'bridge') for d in ds)}, "
          f"Intro: {sum(has(d, 'intro') for d in ds)}, Outro: {sum(has(d, 'outro') for d in ds)}",
          f"- Sektionen nach Label: {dict(labels.most_common())}",
          f"- Sektionslängen (Takte): {dict(sorted(lens.items())[:24])}",
          f"- Wiederholungsanteil (conf) Median {confs[len(confs) // 2] if confs else 0}, P10 "
          f"{confs[len(confs) // 10] if confs else 0}",
          f"- Zuordnung auf Factory-Parts: {dict(mapped.most_common(12))}",
          "", "Timeline: Label + Gruppe (Takte). I Intro, V Verse, C Chorus, B Bridge, P Part, S Solo, O Outro.", "",
          "| Datei | Parts | conf | Timeline | A | B | C |", "|---|---|---|---|---|---|---|"]
    for d in sorted(ds, key=lambda d: d["file"]):
        m = d["mapping"]
        cell = lambda k: (m.get(k) or {}).get("label", "–")  # noqa: E731
        md.append(f"| {d['file'][:40]} | {d['factory_parts']} | {d['structure']['conf']} | "
                  f"{d['structure']['timeline'][:110]} | {cell('A')} | {cell('B')} | {cell('C')} |")
    with open(os.path.join(out_dir, "structure_report.md"), "w") as fh:
        fh.write("\n".join(md) + "\n")


def _parts_report(docs: list[dict], out_dir: str) -> None:
    ds = [d for d in docs if d.get("parts")]
    exported = [d for d in ds if d.get("export")]
    methods: Counter = Counter()
    cons: list[float] = []
    perc_inst: Counter = Counter()
    per_part: Counter = Counter()
    for d in ds:
        for k, v in d["parts"]["bass"].items():
            methods[v["method"]] += 1
            per_part[k] += 1
            if len(k) == 1:
                cons.append(v["consistency"])
        for v in d["parts"]["percussion"].values():
            perc_inst.update(v["instruments"])
    with_perc = sum(1 for d in ds if d["parts"]["percussion"])
    cons.sort()
    q = lambda f: cons[int(len(cons) * f)] if cons else 0  # noqa: E731
    md = ["# Bass- und Percussion-Parts (E4)", "",
          f"- Songs mit Parts: **{len(ds)}**, exportiert als Beispiel-Songs: **{len(exported)}** (`examples/`)",
          f"- Bass-Loops pro Slot: {dict(sorted(per_part.items()))}",
          f"- Methode: {dict(methods)}",
          f"- Konsistenz der Groove-Loops (Ähnlichkeit zu den Quelltakten): P10 {q(0.1)}, Median {q(0.5)}, P90 {q(0.9)}",
          f"- Songs mit Percussion-Loops: **{with_perc}**; Instrumente (Parts): {dict(perc_inst.most_common())}",
          f"- **Fills (E5):** Songs mit Fill-Bass {sum(1 for d in ds if d['parts'].get('fills'))}, "
          f"Fill-Bass-Dateien {sum(len(v) for d in ds for v in d['parts'].get('fills', {}).values())}, "
          f"Arten {dict(Counter(f['kind'] for d in ds for v in d['parts'].get('fills', {}).values() for f in v.values()))}",
          f"- Fill-Percussion: {sum(len(v) for d in ds for v in d['parts'].get('fill_perc', {}).values())} Dateien, "
          f"Arten {dict(Counter(k for d in ds for v in d['parts'].get('fill_perc', {}).values() for k in v.values()))}",
          f"- **Transition Bass** (spielt die App schon): {sum(1 for d in ds if d['parts'].get('transition'))} Songs, "
          f"Arten {dict(Counter(d['parts']['transition']['kind'] for d in ds if d['parts'].get('transition')))}",
          "", "| Song | Factory | A | B | C | Fills A | Transition | Percussion |", "|---|---|---|---|---|---|---|---|"]
    for d in sorted(exported, key=lambda d: d["file"]):
        b = d["parts"]["bass"]
        cell = lambda k: (f"{d['parts']['sources'].get(k, '')} {b[k]['consistency']}" if k in b else "–")  # noqa: E731
        perc = "; ".join(f"{k}: {'/'.join(v['instruments'])}" for k, v in d["parts"]["percussion"].items()) or "–"
        fa = ", ".join(f"{n}:{f['kind']}" for n, f in sorted(d["parts"].get("fills", {}).get("A", {}).items())) or "–"
        tr = (d["parts"].get("transition") or {}).get("kind", "–")
        md.append(f"| {d['file'][:40]} | {d['index']['factory']} | {cell('A')} | {cell('B')} | {cell('C')} | {fa} | {tr} | {perc} |")
    with open(os.path.join(out_dir, "parts_report.md"), "w") as fh:
        fh.write("\n".join(md) + "\n")
