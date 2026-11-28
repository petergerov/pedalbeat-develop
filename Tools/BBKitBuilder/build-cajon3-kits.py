#!/usr/bin/env python3
"""Assemble PedalBeat kits from the best World Percussion samples (ghost-dense).

Cajón 3 SFZ kit is built separately via kitbuilder (Gogodze + Swirly + FreePats).
This script stages:
  - Hand Percussion (WP11+WP12): Shaker / Tambourine / Clap / Maracas + light cajón fill
  - Cajón 3 WP Accent (optional BB companion): multi-velocity WP cajón with soft=ghost layers
  - Layer World: the World kit of the Percussion-layer picker (shaker / tambourine / clap / maracas)
  - Shaker kits for the shaker stack (ShakerStack): Virtuosity (forward + back strokes), World Plus

Output: <pedalbeat-data>/build/kit-staging/ (PEDALBEAT_DATA=<path>, default ../pedalbeat-data next to this repo).
Then pack a staged kit:  ./build/bbkitbuilder ../pedalbeat-data/build/kit-staging <out> "03. Layer World"
"""

from __future__ import annotations

import array
import json
import math
import os
import shutil
import wave
from pathlib import Path

DATA = Path(os.environ.get("PEDALBEAT_DATA", Path(__file__).resolve().parents[3] / "pedalbeat-data")).resolve()
WP11 = DATA / "tmp" / "11. World Percussion"
WP12 = DATA / "tmp" / "12. World Percussion Plus"
# Prefer decoded copies if tmp is incomplete
for p in (DATA / "drumsets-decoded" / "11. World Percussion", DATA / "drumsets-decoded" / "12. World Percussion Plus"):
    if p.is_dir() and (p / "kit.json").is_file():
        if "11." in p.name:
            WP11 = p
        else:
            WP12 = p

STAGING = DATA / "build" / "kit-staging"
GOGO = DATA / "build" / "kits-src" / "karoryfer.gogodze-phu-vol-i" / "Samples" / "cajon" / "dyn"
SWIRLY = DATA / "build" / "kits-src" / "karoryfer.swirly-drums" / "Samples" / "cajon_kick"
VIRTUOSITY_SHAKER = DATA / "build" / "kits-src" / "virtuosity_drums" / "Samples" / "perc" / "mid" / "shaker"
# Shaker stack kits: levels set so every shaker sound plays about as loud as the Layer World one.
VIRTUOSITY_VOLUME = 355
VIRTUOSITY_BACK_VOLUME = 470      # back strokes about 2.5 dB under the forward ones (recorded 5 dB under)
WPPLUS_VOLUME = 110


def load_kit(pack: Path) -> dict:
    return json.loads((pack / "kit.json").read_text())


def find_inst(kit: dict, midi: int | None = None, name_substr: str | None = None) -> dict:
    for inst in kit["instruments"]:
        if midi is not None and inst["midi"] != midi:
            continue
        if name_substr is not None and name_substr.lower() not in inst["name"].lower():
            continue
        return inst
    raise KeyError(f"instrument midi={midi} name~{name_substr}")


def symlink_file(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() or dst.is_symlink():
        dst.unlink()
    os.symlink(src.resolve(), dst)


def copy_samples(src_pack: Path, inst: dict, dest_kit: Path, dest_prefix: str,
                 vel_map: dict[str, str] | None = None) -> list[dict]:
    out: list[dict] = []
    for s in inst["samples"]:
        src = src_pack / s["file"]
        if not src.is_file():
            raise FileNotFoundError(src)
        vel = (vel_map or {}).get(s["velocity"], s["velocity"])
        rel = Path(dest_prefix) / vel / src.name
        symlink_file(src, dest_kit / rel)
        entry = dict(s)
        entry["velocity"] = vel
        entry["file"] = str(rel).replace("\\", "/")
        out.append(entry)
    return out


def add_wavs(files: list[Path], dest_kit: Path, dest_prefix: str, velocity: str,
             rate: int = 44100) -> list[dict]:
    out = []
    for src in files:
        if not src.is_file():
            continue
        rel = Path(dest_prefix) / velocity / src.name
        symlink_file(src, dest_kit / rel)
        out.append({
            "velocity": velocity,
            "file": str(rel).replace("\\", "/"),
            "channels": 2,
            "rate": rate,
            "bits": 16,
        })
    return out


def make_instrument(*, name: str, midi: int, volume: int, samples: list[dict]) -> dict:
    return {
        "name": name,
        "midi": midi,
        "choke": 0,
        "poly": 0,
        "volume": volume,
        "fillChoke": 0,
        "fillChokeDelay": 0,
        "percussion": True,
        "samples": samples,
    }


def build_hand_perc(dest: Path) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    k12 = load_kit(WP12)
    k11 = load_kit(WP11)

    shaker1 = find_inst(k12, midi=82, name_substr="Shaker 1")
    shaker2 = find_inst(k12, midi=51, name_substr="Shaker 2")
    shaker3 = find_inst(k12, midi=53, name_substr="Shaker 3")
    tamb12 = find_inst(k12, midi=54, name_substr="Tambourine")
    tamb11 = find_inst(k11, midi=54, name_substr="Tambourine")
    claps = find_inst(k12, midi=39, name_substr="Handclap")
    # Soft WP cajón = ghost-friendly kit fill under the hand perc.
    cajon_hi = find_inst(k12, midi=38, name_substr="Cajon Hi")
    cajon_lo = find_inst(k12, midi=36, name_substr="Cajon Low")
    hat_c = find_inst(k12, midi=42, name_substr="Hats Mini Closed")
    hat_p = find_inst(k12, midi=44, name_substr="Hats Mini Foot")
    hat_o = find_inst(k12, midi=46, name_substr="Hats Mini Open")
    cowbell = find_inst(k12, midi=56, name_substr="Cowbell")
    crash = find_inst(k12, midi=49, name_substr="Crash 1")

    tamb = copy_samples(WP12, tamb12, dest, "54-Tambourine")
    tamb += copy_samples(WP11, tamb11, dest, "54-Tambourine")

    instruments = [
        make_instrument(name="Shaker", midi=82, volume=112,
                        samples=copy_samples(WP12, shaker1, dest, "82-Shaker")),
        make_instrument(name="Tambourine", midi=54, volume=112, samples=tamb),
        make_instrument(name="Handclaps", midi=39, volume=108,
                        samples=copy_samples(WP12, claps, dest, "39-Handclaps")),
        make_instrument(name="Maracas", midi=70, volume=112,
                        samples=copy_samples(WP12, shaker3, dest, "70-Maracas")),
        # Ghost-dense snare fill: keep WP soft band as 0-40.
        make_instrument(name="Cajon Snare", midi=38, volume=92,
                        samples=copy_samples(WP12, cajon_hi, dest, "38-Cajon_Snare")),
        make_instrument(name="Cajon Bass", midi=36, volume=92,
                        samples=copy_samples(WP12, cajon_lo, dest, "36-Cajon_Bass")),
        make_instrument(name="Hats Closed", midi=42, volume=78,
                        samples=copy_samples(WP12, hat_c, dest, "42-Hats_Closed")),
        make_instrument(name="Hats Pedal", midi=44, volume=70,
                        samples=copy_samples(WP12, hat_p, dest, "44-Hats_Pedal")),
        make_instrument(name="Hats Open", midi=46, volume=78,
                        samples=copy_samples(WP12, hat_o, dest, "46-Hats_Open")),
        make_instrument(name="Shaker Accent", midi=51, volume=95,
                        samples=copy_samples(WP12, shaker2, dest, "51-Shaker_Accent")),
        make_instrument(name="Cowbell", midi=56, volume=88,
                        samples=copy_samples(WP12, cowbell, dest, "56-Cowbell")),
        make_instrument(name="Crash", midi=49, volume=82,
                        samples=copy_samples(WP12, crash, dest, "49-Crash")),
    ]

    kit = {
        "id": "pedalbeat.hand-percussion",
        "name": "Hand Percussion",
        "category": "percussion",
        "author": "GoranGrooves World Percussion / World Percussion Plus",
        "license": "Proprietary — for personal use with your own content",
        "source": "Decoded 11. World Percussion + 12. World Percussion Plus",
        "notes": (
            "Dense Shaker, Tambourine (WP11+12), Handclaps and Maracas for PedalBeat "
            "percussion layers, with a light multi-velocity cajón kit underneath."
        ),
        "file": "hand-percussion-curated",
        "version": "1.0",
        "volume": 124,
        "instruments": instruments,
    }
    (dest / "kit.json").write_text(json.dumps(kit, indent=2) + "\n")
    print(f"staged {dest.name}: {len(instruments)} instruments")


def _band_cajon_hi(src_pack: Path, inst: dict, dest: Path, prefix: str) -> list[dict]:
    """WP Cajon Hi → ghost / mid / hard velocity bands."""
    out: list[dict] = []
    for s in inst["samples"]:
        src = src_pack / s["file"]
        lo, _, hi = s["velocity"].partition("-")
        lo_i, hi_i = int(lo), int(hi)
        if hi_i <= 40:
            vel = "0-31"
        elif lo_i >= 76:
            vel = "96-127"
        else:
            vel = "32-95"
        rel = Path(prefix) / vel / src.name
        symlink_file(src, dest / rel)
        e = dict(s)
        e["velocity"] = vel
        e["file"] = str(rel).replace("\\", "/")
        out.append(e)
    return out


def build_wp_ghost_cajon(dest: Path) -> None:
    """Round WP companion: one-box feel, soft bass, sweet rim, crash = slap family."""
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    k12 = load_kit(WP12)
    k11 = load_kit(WP11)

    # Prefer real Cajón Low over the punchy WP Kick — rounder, one-box.
    cajon_lo = find_inst(k12, midi=36, name_substr="Cajon Low")
    cajon_hi = find_inst(k12, midi=38, name_substr="Cajon Hi")
    cajon_sn11 = find_inst(k11, midi=38, name_substr="Cajon Snare")
    cajon_bass11 = find_inst(k11, midi=36, name_substr="Cajon Bass")
    claps = find_inst(k12, midi=39, name_substr="Handclap")
    bongo_mut = find_inst(k12, midi=63, name_substr="Muted")
    bongo_hi = find_inst(k12, midi=62, name_substr="Hi Open")
    bongo_lo = find_inst(k12, midi=61, name_substr="CajonBongo Low")
    djembe = find_inst(k12, midi=65, name_substr="Djembe Bass")
    hat_c = find_inst(k12, midi=42, name_substr="Closed")
    hat_p = find_inst(k12, midi=44, name_substr="Foot")
    hat_o = find_inst(k12, midi=46, name_substr="Open")
    cowbell = find_inst(k12, midi=56, name_substr="Cowbell")
    tamb = find_inst(k12, midi=54, name_substr="Tambourine")
    shaker1 = find_inst(k12, midi=82, name_substr="Shaker 1")
    shaker3 = find_inst(k12, midi=53, name_substr="Shaker 3")

    # --- Snare: ghost / mid / hard ---
    snare = _band_cajon_hi(WP12, cajon_hi, dest, "38-Cajon_Snare")
    for s in cajon_sn11["samples"]:
        if not s["velocity"].startswith("0-"):
            continue
        src = WP11 / s["file"]
        rel = Path("38-Cajon_Snare") / "0-31" / ("wp11-" + src.name)
        symlink_file(src, dest / rel)
        snare.append({
            "velocity": "0-31",
            "file": str(rel).replace("\\", "/"),
            "channels": 2, "rate": 44100, "bits": 16,
        })
    if GOGO.is_dir():
        snare += add_wavs(sorted(GOGO.glob("cajon_sl5_vl1_rr*_dyn.wav")), dest, "38-Cajon_Snare", "0-31")
        snare += add_wavs(
            sorted(GOGO.glob("cajon_sl5_vl2_rr*_dyn.wav"))
            + sorted(GOGO.glob("cajon_sl5_vl3_rr*_dyn.wav")),
            dest, "38-Cajon_Snare", "32-95")
        snare += add_wavs(sorted(GOGO.glob("cajon_sl5_vl4_rr*_dyn.wav")), dest, "38-Cajon_Snare", "96-127")

    # --- Crash = same slap family as snare (hard band only), not Hand Crash ---
    crash_s: list[dict] = []
    for s in snare:
        if s["velocity"] == "96-127":
            src_name = Path(s["file"]).name
            src = dest / s["file"]
            rel = Path("49-Crash_Slap") / "0-127" / src_name
            if src.is_file() or src.is_symlink():
                symlink_file(src.resolve() if src.is_symlink() else src, dest / rel)
                crash_s.append({
                    "velocity": "0-127",
                    "file": str(rel).replace("\\", "/"),
                    "channels": 2, "rate": 44100, "bits": 16,
                })
    if not crash_s and GOGO.is_dir():
        crash_s = add_wavs(sorted(GOGO.glob("cajon_sl5_vl4_rr*_dyn.wav")), dest, "49-Crash_Slap", "0-127")

    # --- Kick: Cajón Low + WP11 bass + soft Gogodze/Swirly (no punchy WP Kick) ---
    kick_s = copy_samples(WP12, cajon_lo, dest, "36-Cajon_Bass")
    kick_s += copy_samples(WP11, cajon_bass11, dest, "36-Cajon_Bass")
    if GOGO.is_dir():
        kick_s += add_wavs(sorted(GOGO.glob("cajon_sl1_vl1_rr*_dyn.wav")), dest, "36-Cajon_Bass", "0-60")
        kick_s += add_wavs(sorted(GOGO.glob("cajon_sl1_vl2_rr*_dyn.wav")), dest, "36-Cajon_Bass", "0-60")
    if SWIRLY.is_dir():
        soft = sorted(SWIRLY.glob("cajon_kick_vl[1-4]_rr*_rear.wav"))
        kick_s += add_wavs(soft, dest, "36-Cajon_Bass", "0-60")

    instruments = [
        make_instrument(name="Cajon Bass", midi=36, volume=92, samples=kick_s),
        make_instrument(name="Cajon Snare", midi=38, volume=95, samples=snare),
        # Sweet side taps (Cajón 1 style boost).
        make_instrument(name="Cajon Side", midi=37, volume=118,
                        samples=copy_samples(WP12, bongo_mut, dest, "37-Cajon_Side")),
        make_instrument(name="Handclaps", midi=39, volume=88,
                        samples=copy_samples(WP12, claps, dest, "39-Handclaps")),
        make_instrument(name="Hats Closed", midi=42, volume=72,
                        samples=copy_samples(WP12, hat_c, dest, "42-Hats_Closed")),
        make_instrument(name="Hats Pedal", midi=44, volume=65,
                        samples=copy_samples(WP12, hat_p, dest, "44-Hats_Pedal")),
        make_instrument(name="Hats Open", midi=46, volume=72,
                        samples=copy_samples(WP12, hat_o, dest, "46-Hats_Open")),
        make_instrument(name="Crash Slap", midi=49, volume=100, samples=crash_s),
        # Ride = open tone (related box), not splash stack.
        make_instrument(name="Cajon Tone", midi=51, volume=82,
                        samples=copy_samples(WP12, bongo_hi, dest, "51-Cajon_Tone")),
        make_instrument(name="Ride Bell", midi=53, volume=78,
                        samples=copy_samples(WP12, bongo_mut, dest, "53-Ride_Bell")),
        make_instrument(name="Tom High", midi=48, volume=88,
                        samples=copy_samples(WP12, bongo_hi, dest, "48-Tom_High")),
        make_instrument(name="Tom Mid", midi=45, volume=88,
                        samples=copy_samples(WP12, bongo_lo, dest, "45-Tom_Mid")),
        make_instrument(name="Tom Low", midi=41, volume=90,
                        samples=copy_samples(WP12, djembe, dest, "41-Tom_Low")),
        make_instrument(name="Cowbell", midi=56, volume=75,
                        samples=copy_samples(WP12, cowbell, dest, "56-Cowbell")),
        make_instrument(name="Shaker", midi=82, volume=95,
                        samples=copy_samples(WP12, shaker1, dest, "82-Shaker")),
        make_instrument(name="Tambourine", midi=54, volume=95,
                        samples=copy_samples(WP12, tamb, dest, "54-Tambourine")),
        make_instrument(name="Maracas", midi=70, volume=95,
                        samples=copy_samples(WP12, shaker3, dest, "70-Maracas")),
    ]

    kit = {
        "id": "pedalbeat.cajon3-wp",
        "name": "Cajón 3 WP",
        "category": "percussion",
        "author": "GoranGrooves WP + Karoryfer Gogodze/Swirly soft layers",
        "license": "Proprietary WP samples + CC0 Gogodze/Swirly accents",
        "source": "World Percussion + Gogodze soft slap/bass + Swirly soft rear",
        "notes": (
            "Rounded WP cajón: bass = Cajón Low (not punchy Kick), snare ghosts 0–31, "
            "crash = hard slap family, sweet side taps, quieter hand perc. "
            "Companion to pedalbeat.cajon3."
        ),
        "file": "cajon3-wp-round",
        "version": "1.1",
        "volume": 108,
        "instruments": instruments,
    }
    (dest / "kit.json").write_text(json.dumps(kit, indent=2) + "\n")
    print(f"staged {dest.name}: {len(instruments)} instruments, snare={len(snare)} crash={len(crash_s)}")


# Layer World shaker: WP11 "Shaker 1" is recorded quiet and panned hard right, and its loud layer is no
# louder than its soft one. Prepared like the WP Plus shaker it replaced: channels swapped (left; the
# tambourine sits right), each hit levelled per velocity layer with the loud layer SHAKER_GAP_DB above the
# soft one (scaled down only, so nothing clips), overall level from the instrument volume.
SHAKER_GAP_DB = 3.0
SHAKER_VOLUME = 350


def _read_wav(path: Path) -> tuple[array.array, tuple]:
    with wave.open(str(path)) as w:
        p = w.getparams()
        if p.nchannels != 2 or p.sampwidth != 2:
            raise ValueError(f"{path}: 16-bit stereo expected")
        s = array.array("h")
        s.frombytes(w.readframes(p.nframes))
    return s, p


def _loudness(s: array.array) -> float:
    """RMS of the loudest 100 ms (both channels), linear."""
    frames, win, best = len(s) // 2, 4410, 0.0
    for i in range(0, max(frames - win, 1), 441):
        seg = s[i * 2:(i + win) * 2]
        best = max(best, sum(x * x for x in seg) / max(len(seg), 1))
    return math.sqrt(best)


def stage_wp11_shaker(dest_kit: Path, dest_prefix: str) -> list[dict]:
    k11 = load_kit(WP11)
    inst = find_inst(k11, midi=42, name_substr="Shaker 1")
    by_vel: dict[str, list[Path]] = {}
    for smp in inst["samples"]:
        by_vel.setdefault(smp["velocity"], []).append(WP11 / smp["file"])
    vels = sorted(by_vel, key=lambda v: int(v.split("-")[1]))   # soft first
    clips = {v: [(f, *_read_wav(f)) for f in by_vel[v]] for v in vels}
    level = {v: [_loudness(s) for _, s, _ in clips[v]] for v in vels}
    target = {vels[-1]: min(level[vels[-1]])}
    for i, v in enumerate(reversed(vels[:-1]), start=1):
        target[v] = min(target[vels[-1]] * 10 ** (-SHAKER_GAP_DB * i / 20), min(level[v]))
    out: list[dict] = []
    for v in vels:
        for (f, s, p), lv in zip(clips[v], level[v]):
            g = target[v] / lv
            swapped = array.array("h", [0]) * len(s)
            swapped[0::2] = array.array("h", (int(round(x * g)) for x in s[1::2]))   # R -> L
            swapped[1::2] = array.array("h", (int(round(x * g)) for x in s[0::2]))   # L -> R
            rel = Path(dest_prefix) / v / f.name
            (dest_kit / rel).parent.mkdir(parents=True, exist_ok=True)
            with wave.open(str(dest_kit / rel), "wb") as w:
                w.setparams(p)
                w.writeframes(swapped.tobytes())
            out.append({"velocity": v, "file": str(rel), "channels": 2, "rate": p.framerate, "bits": 16})
    return out


def build_layer_world(dest: Path) -> None:
    """Slim hand-perc kit for the Percussion-layer picker (4 voices): WP11 shaker, WP Plus tambourine and
    handclaps, FreePats maracas (WP has none; taken from the staged "04. Layer FreePats")."""
    maracas_src = STAGING / "04. Layer FreePats" / "70-Maracas"
    maracas = sorted(maracas_src.glob("*/*.wav"))
    if not maracas:
        raise FileNotFoundError(f"FreePats maracas missing: {maracas_src}")
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    k12 = load_kit(WP12)
    tamb = find_inst(k12, midi=54, name_substr="Tambourine")
    claps = find_inst(k12, midi=39, name_substr="Handclap")
    maracas_samples = []
    for f in maracas:
        rel = Path("70-Maracas") / f.parent.name / f.name
        (dest / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(f, dest / rel)
        maracas_samples.append({"velocity": f.parent.name, "file": str(rel), "channels": 2, "rate": 44100, "bits": 16})

    instruments = [
        make_instrument(name="Handclaps", midi=39, volume=108,
                        samples=copy_samples(WP12, claps, dest, "39-Handclaps")),
        make_instrument(name="Tambourine", midi=54, volume=110,
                        samples=copy_samples(WP12, tamb, dest, "54-Tambourine")),
        make_instrument(name="Shaker", midi=82, volume=SHAKER_VOLUME,
                        samples=stage_wp11_shaker(dest, "82-Shaker")),
        make_instrument(name="Maracas", midi=70, volume=110, samples=maracas_samples),
    ]
    kit = {
        "id": "pedalbeat.layer-world",
        "name": "Layer World",
        "category": "layer",
        "author": "GoranGrooves World Percussion (+Plus) + FreePats maracas",
        "license": "WP proprietary + FreePats CC0 maracas",
        "source": "World Percussion (Shaker 1) + World Percussion Plus + FreePats Maracas",
        "notes": ("WP Shaker 1 (two velocity layers, left), WP Plus Tambourine and Handclaps; "
                  "real FreePats maracas (WP has none)."),
        "file": "layer-world",
        "version": "1.2",
        "volume": 120,
        "instruments": instruments,
    }
    (dest / "kit.json").write_text(json.dumps(kit, indent=2) + "\n")
    print(f"staged {dest.name}: {len(instruments)} instruments")


def build_shaker_virtuosity(dest: Path) -> None:
    """Virtuosity Drums shaker (CC0, mid mics): forward strokes as the shaker, back strokes as
    "shakerUp", which the shaker stack plays between the beats."""
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    down = sorted(VIRTUOSITY_SHAKER.glob("LShaker_Shake1D_rr*_Mid.wav"), key=lambda f: int(f.name.split("_rr")[1].split("_")[0]))
    up = sorted(VIRTUOSITY_SHAKER.glob("LShaker_Shake1U_rr*_Mid.wav"), key=lambda f: int(f.name.split("_rr")[1].split("_")[0]))
    if not down or not up:
        raise FileNotFoundError(f"Virtuosity shaker strokes missing: {VIRTUOSITY_SHAKER}")
    forward = make_instrument(name="Shaker", midi=82, volume=VIRTUOSITY_VOLUME,
                              samples=add_wavs(down, dest, "82-Shaker", "0-127"))
    back = make_instrument(name="Shaker Back", midi=82, volume=VIRTUOSITY_BACK_VOLUME,
                           samples=add_wavs(up, dest, "82-Shaker_Up", "0-127"))
    back["key"] = "shakerUp"
    kit = {
        "id": "pedalbeat.shaker-virtuosity",
        "name": "Shaker Virtuosity",
        "category": "shaker",
        "author": "Virtuosity Drums (Austin McMahon, Virtuosity Musical Instruments)",
        "license": "CC0-1.0",
        "source": "https://github.com/sfzinstruments/virtuosity_drums",
        "notes": "Shaker with forward and back strokes (mid mics), for the PedalBeat shaker stack.",
        "file": "shaker-virtuosity",
        "version": "1.0",
        "volume": 120,
        "instruments": [forward, back],
    }
    (dest / "kit.json").write_text(json.dumps(kit, indent=2) + "\n")
    print(f"staged {dest.name}: {len(down)} forward, {len(up)} back strokes")


def build_shaker_wpplus(dest: Path) -> None:
    """The World Percussion Plus one-shot shaker (Layer World's shaker before the WP egg)."""
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    shaker1 = find_inst(load_kit(WP12), midi=82, name_substr="Shaker 1")
    kit = {
        "id": "pedalbeat.shaker-wpplus",
        "name": "Shaker World Plus",
        "category": "shaker",
        "author": "GoranGrooves World Percussion Plus",
        "license": "WP proprietary",
        "source": "World Percussion Plus (Shaker 1)",
        "notes": "One-shot shaker for the PedalBeat shaker stack.",
        "file": "shaker-wpplus",
        "version": "1.0",
        "volume": 120,
        "instruments": [make_instrument(name="Shaker", midi=82, volume=WPPLUS_VOLUME,
                                        samples=copy_samples(WP12, shaker1, dest, "82-Shaker"))],
    }
    (dest / "kit.json").write_text(json.dumps(kit, indent=2) + "\n")
    print(f"staged {dest.name}")


def main() -> None:
    STAGING.mkdir(parents=True, exist_ok=True)
    for old in list(STAGING.glob("01.*")) + list(STAGING.glob("03.*")):
        if old.is_dir():
            shutil.rmtree(old)
    build_wp_ghost_cajon(STAGING / "01. Cajon 3 WP")
    build_layer_world(STAGING / "03. Layer World")
    build_shaker_virtuosity(STAGING / "05. Shaker Virtuosity")
    build_shaker_wpplus(STAGING / "06. Shaker World Plus")
    print("done →", STAGING)


if __name__ == "__main__":
    main()
