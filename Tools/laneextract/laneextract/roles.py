"""Lane (track/channel) role detection: bass, drums, harmony."""
from __future__ import annotations

import statistics
from dataclasses import dataclass

from .smf import Note, Song

DRUM_CHANNEL = 9
BASS_PROGRAMS = range(32, 40)   # GM 33–40 (0-based 32–39)


@dataclass
class Lane:
    track: int
    channel: int
    name: str
    program: int | None
    notes: list[Note]
    role: str = "other"          # bass | drums | harmony | other
    bass_score: float = 0.0

    @property
    def key(self) -> str:
        return f"t{self.track}c{self.channel}"


def monophony(notes: list[Note]) -> float:
    """Share of notes that do not overlap the next note (1.0 = fully monophonic)."""
    if len(notes) < 2:
        return 1.0
    ordered = sorted(notes, key=lambda n: n.start)
    ok = sum(1 for a, b in zip(ordered, ordered[1:]) if a.end <= b.start + 2)
    return ok / (len(ordered) - 1)


def split_lanes(song: Song) -> list[Lane]:
    groups: dict[tuple[int, int], list[Note]] = {}
    for n in song.notes:
        groups.setdefault((n.track, n.channel), []).append(n)
    lanes = []
    for (tr, ch), notes in sorted(groups.items()):
        lane = Lane(tr, ch, song.track_names.get(tr, ""), song.programs.get((tr, ch)), notes)
        lane.role = "drums" if ch == DRUM_CHANNEL else "other"
        lanes.append(lane)
    for lane in lanes:
        if lane.role == "drums":
            continue
        lane.bass_score = bass_score(lane)
        lane.role = "bass" if lane.bass_score >= 0.5 else "harmony"
    # at most one primary bass lane: others with lower score become 'bass_double'
    basses = sorted((l for l in lanes if l.role == "bass"), key=lambda l: -l.bass_score)
    for extra in basses[1:]:
        extra.role = "bass_double"
    return lanes


def bass_score(lane: Lane) -> float:
    notes = lane.notes
    if len(notes) < 8:
        return 0.0
    s = 0.0
    if lane.program is not None and lane.program in BASS_PROGRAMS:
        s += 0.45
    if "bass" in lane.name.lower():
        s += 0.35
    med = statistics.median(n.pitch for n in notes)
    if med < 52:
        s += 0.25
    elif med < 60:
        s += 0.1
    else:
        s -= 0.3
    s += 0.2 * monophony(notes)
    return max(0.0, min(1.0, s))
