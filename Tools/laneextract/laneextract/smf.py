"""Minimal Standard MIDI File reader (stdlib only).

Returns notes with durations (note-on/off paired), tempo map, time-signature map and
markers. Format 0 and 1 are both handled; channels are kept so format-0 files can be
split by channel later.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass, field


@dataclass
class Note:
    start: int          # ticks
    end: int            # ticks
    pitch: int
    velocity: int
    channel: int
    track: int


@dataclass
class Song:
    path: str
    fmt: int
    ppq: int
    track_names: dict[int, str] = field(default_factory=dict)
    programs: dict[tuple[int, int], int] = field(default_factory=dict)   # (track, channel) -> program
    notes: list[Note] = field(default_factory=list)
    tempos: list[tuple[int, int]] = field(default_factory=list)          # (tick, µs per beat)
    timesigs: list[tuple[int, int, int]] = field(default_factory=list)   # (tick, num, den)
    markers: list[tuple[int, str]] = field(default_factory=list)
    end_tick: int = 0
    pb: dict | None = None   # PedalBeat "PB1" meta, present in factory-song MIDIs


def _vlq(d: bytes, i: int) -> tuple[int, int]:
    v = 0
    while True:
        b = d[i]
        i += 1
        v = (v << 7) | (b & 0x7F)
        if not b & 0x80:
            return v, i


def parse(path: str) -> Song:
    d = open(path, "rb").read()
    if d[:4] != b"MThd":
        raise ValueError("not a MIDI file")
    fmt, ntracks, div = struct.unpack(">HHH", d[8:14])
    if div & 0x8000:
        raise ValueError("SMPTE time division not supported")
    song = Song(path=path, fmt=fmt, ppq=div)
    i = 14
    for ti in range(ntracks):
        if d[i:i + 4] != b"MTrk":
            break
        ln = struct.unpack(">I", d[i + 4:i + 8])[0]
        end = min(i + 8 + ln, len(d))
        i += 8
        t = 0
        running = 0
        active: dict[tuple[int, int], list[tuple[int, int]]] = {}
        try:
            while i < end:
                dt, i = _vlq(d, i)
                t += dt
                b = d[i]
                if b == 0xFF:
                    ty = d[i + 1]
                    ln2, j = _vlq(d, i + 2)
                    data = d[j:j + ln2]
                    i = j + ln2
                    if ty == 0x03:
                        song.track_names[ti] = data.decode("latin1", "replace")
                    elif ty == 0x51 and len(data) == 3:
                        song.tempos.append((t, int.from_bytes(data, "big")))
                    elif ty == 0x58 and len(data) >= 2:
                        song.timesigs.append((t, data[0], 2 ** data[1]))
                    elif ty == 0x7F and data[:3] == b"PB1" and len(data) >= 16:
                        # PedalBeat meta: exact pattern length, grid, signature label, per-note swing.
                        ll = data[15]
                        swings = data[16 + ll + 4:]
                        song.pb = {
                            "length": int.from_bytes(data[3:7], "big"),
                            "bar_ticks": int.from_bytes(data[7:11], "big"),
                            "beat_ticks": int.from_bytes(data[11:15], "big"),
                            "label": data[16:16 + ll].decode("latin1", "replace"),
                            "swing": [int.from_bytes(swings[k:k + 2], "big", signed=True)
                                      for k in range(0, len(swings) - 1, 2)],
                        }
                    elif ty in (0x06, 0x01, 0x05) and data:
                        song.markers.append((t, data.decode("latin1", "replace")))
                    elif ty == 0x2F:
                        break
                elif b in (0xF0, 0xF7):
                    ln2, j = _vlq(d, i + 1)
                    i = j + ln2
                else:
                    if b & 0x80:
                        running = b
                        i += 1
                    kind, ch = running >> 4, running & 15
                    if kind in (0x8, 0x9, 0xA, 0xB, 0xE):
                        a, c = d[i], d[i + 1]
                        i += 2
                        key = (ch, a)
                        if kind == 0x9 and c > 0:
                            active.setdefault(key, []).append((t, c))
                        elif kind == 0x8 or (kind == 0x9 and c == 0):
                            stack = active.get(key)
                            if stack:
                                s, v = stack.pop(0)
                                song.notes.append(Note(s, max(t, s + 1), a, v, ch, ti))
                    else:
                        a = d[i]
                        i += 1
                        if kind == 0xC:
                            song.programs.setdefault((ti, ch), a)
                        elif kind == 0xD:
                            pass
                        else:
                            # 0xF1..0xFF system messages are not expected here
                            if kind == 0xF:
                                pass
        except IndexError:
            pass
        # close hanging notes
        for (ch, a), stack in active.items():
            for s, v in stack:
                song.notes.append(Note(s, max(t, s + 1), a, v, ch, ti))
        song.end_tick = max(song.end_tick, t)
        i = end
    song.notes.sort(key=lambda n: (n.start, n.pitch))
    song.tempos.sort()
    song.timesigs.sort()
    return song
