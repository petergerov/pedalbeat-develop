"""MIDI writing in PedalBeat's own format (mirrors Core/MIDIWriter.swift).

Type 0, 480 PPQ, tempo + time signature, the "PB1" sequencer meta (exact length, grid, label),
then the notes. Bass on channel 2 with a fingered-bass program; percussion on channel 10.
"""
from __future__ import annotations

PPQ = 480
TICKS_PER_UNIT = PPQ // 12      # 1 unit = 1/12 quarter = 40 ticks


def _vlq(v: int) -> bytes:
    v = max(v, 0)
    out = [v & 0x7F]
    v >>= 7
    while v:
        out.insert(0, (v & 0x7F) | 0x80)
        v >>= 7
    return bytes(out)


def _be32(v: int) -> bytes:
    return int(v).to_bytes(4, "big")


def _signature(label: str, bar_ticks: int) -> tuple[int, int]:
    try:
        num, den = (int(x) for x in label.split("/"))
    except ValueError:
        num, den = 4, 4
    if num * PPQ * 4 // max(den, 1) != bar_ticks:
        if bar_ticks % PPQ == 0:
            num, den = bar_ticks // PPQ, 4
        else:
            num, den = bar_ticks // (PPQ // 2), 8
    return num, den


def write(path: str, notes: list[tuple[int, int, int, int]], length: int, tempo: float, label: str,
          bar_ticks: int, beat_ticks: int, channel: int, program: int | None = None) -> None:
    """notes: (tick, duration ticks, pitch, velocity)."""
    num, den = _signature(label, bar_ticks)
    trk = bytearray()
    us = round(60_000_000 / max(tempo, 1))
    trk += b"\x00\xFF\x51\x03" + us.to_bytes(3, "big")
    log2 = 0
    while (1 << log2) < den and log2 < 6:
        log2 += 1
    trk += bytes([0, 0xFF, 0x58, 0x04, num, log2, 24, 8])
    lab = label.encode()[:15]
    meta = b"PB1" + _be32(length) + _be32(bar_ticks) + _be32(beat_ticks) + bytes([len(lab)]) + lab + _be32(0)
    trk += b"\x00\xFF\x7F" + _vlq(len(meta)) + meta
    msgs = []
    if program is not None:
        msgs.append((0, 0, bytes([0xC0 | channel, program])))
    for i, (t, d, p, v) in enumerate(sorted(notes)):
        msgs.append((t, 1, bytes([0x90 | channel, p, max(1, min(127, v))])))
        msgs.append((t + max(d, 1), 0, bytes([0x80 | channel, p, 0])))
    msgs.sort(key=lambda m: (m[0], m[1]))
    last = 0
    for t, _, b in msgs:
        trk += _vlq(t - last) + b
        last = t
    trk += _vlq(max(length, last) - last) + b"\xFF\x2F\x00"
    data = b"MThd" + _be32(6) + b"\x00\x00\x00\x01" + PPQ.to_bytes(2, "big") + b"MTrk" + _be32(len(trk)) + bytes(trk)
    with open(path, "wb") as fh:
        fh.write(data)


def copy_with_tempo(src: str, dst: str, tempo: float) -> None:
    """Copies a PedalBeat drum MIDI and replaces every tempo event (keeps everything else)."""
    d = bytearray(open(src, "rb").read())
    us = round(60_000_000 / max(tempo, 1)).to_bytes(3, "big")
    i = 0
    while True:
        i = d.find(b"\xFF\x51\x03", i)
        if i < 0:
            break
        d[i + 3:i + 6] = us
        i += 6
    with open(dst, "wb") as fh:
        fh.write(bytes(d))
