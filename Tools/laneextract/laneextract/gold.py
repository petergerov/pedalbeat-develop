"""Plausibility check for key detection: songs whose key is well known.

Values are the keys of the original recordings. A MIDI transcription can be transposed, so a
mismatch means "look at it", not "the detector is wrong". mode None = tonic only (modal rock songs).
Match is by a lower-case substring of the file name.
"""
from __future__ import annotations

from .harmony import PC

N = {n: i for i, n in enumerate(PC)}

KEYS: dict[str, tuple[str, str | None]] = {
    "rolling_in_the_deep": ("C", "minor"),
    "hotel_california": ("B", "minor"),
    "smoke_on_the_water": ("G", "minor"),
    "cranberries__zombie": ("E", "minor"),
    "house_of_the_rising_sun": ("A", "minor"),
    "black_sabbath__paranoid": ("E", "minor"),
    "coldplay__yellow": ("B", "major"),
    "uptown_funk": ("D", "minor"),
    "back_to_black": ("D", "minor"),
    "amy_winehouse__rehab": ("C", "major"),
    "bad_moon_rising": ("D", "major"),
    "have_you_ever_seen_the_rain": ("C", "major"),
    "livin_on_a_prayer": ("E", "minor"),
    "summer_of_69": ("D", "major"),
    "stand_by_me": ("A", "major"),
    "take_on_me": ("A", "major"),
    "viva_la_vida": ("Ab", "major"),
    "sultans_of_swing": ("D", "minor"),
    "all_the_small_things": ("C", "major"),
    "three_little_birds": ("A", "major"),
    "redemption_song": ("G", "major"),
    "don_t_fear_the_reaper": ("A", "minor"),
    "ed_sheeran__perfect": ("Ab", "major"),
    "thinking_out_loud": ("D", "major"),
    "cream__sunshine_of_your_love": ("D", None),
    "ramblin_man": ("G", "major"),
    "a_horse_with_no_name": ("E", "minor"),
    "just_the_two_of_us": ("F", "minor"),
    "uptown_girl": ("E", "major"),
    "like_a_rolling_stone": ("C", "major"),
    "wanted_dead_or_alive": ("D", None),
    "born_to_run": ("E", "major"),
    "dancing_in_the_dark": ("B", "major"),
    "space_oddity": ("C", "major"),
    "bowie__heroes": ("D", "major"),
    "enjoy_the_silence": ("C", "minor"),
    "american_pie": ("G", "major"),
    "wicked_game": ("B", None),
}


# Transcriptions that are transposed against the record (checked against their chord sequence):
# the expectation is the key the file is actually written in.
TRANSPOSED: dict[str, tuple[str, str | None]] = {
    "ben_e_king__stand_by_me": ("F", "major"),          # F C Dm Bb  (record: A)
    "john_lennon__stand_by_me": ("G", "major"),         # G D Em C   (record: A)
    "dancing_in_the_dark": ("C", "major"),              # C F Dm Am  (record: B)
    "just_the_two_of_us": ("E", "minor"),               # Cmaj7 B7 Em (record: Fm)
    "wicked_game": ("A", None),                         # Am G D     (record: Bm A E)
}


def expected(filename: str) -> tuple[int, str | None] | None:
    f = filename.lower()
    for k, (t, m) in TRANSPOSED.items():
        if k in f:
            return N[t], m
    for k, (t, m) in KEYS.items():
        if k in f:
            return N[t], m
    return None


def verdict(exp: tuple[int, str | None], tonic: int, mode: str) -> str:
    t, m = exp
    if tonic == t and (m is None or m == mode):
        return "exact"
    if tonic == t:
        return "parallel"
    rel = (t + 9) % 12 if m == "major" else (t + 3) % 12 if m == "minor" else None
    if rel is not None and tonic == rel and mode != m:
        return "relative"
    if tonic in ((t + 7) % 12, (t + 5) % 12):
        return "fifth"
    return "other"
