#!/usr/bin/env python3
"""Download MIDIs from freemidi.org for every song in midi.json.

Based on FreeMIDI-Downloader-main/app.py (same endpoints: download3-<id> page,
getter-<id> file), but instead of walking numeric IDs it searches the site for
each "title / artist" pair and downloads the best match.

Stdlib only. Resumable: progress is stored in midi_results.json.
Usage: python3 download_midis.py [--limit N] [--delay SECONDS]
"""
import argparse
import difflib
import html
import http.cookiejar
import json
import re
import time
import unicodedata
import urllib.parse
import urllib.request

from paths import DATA

BASE = "https://freemidi.org"
SONGS_JSON = DATA / "midi.json"
OUT_DIR = DATA / "midis"
RESULTS = DATA / "midi_results.json"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
opener.addheaders = [("User-Agent", UA)]


def fetch(url, referer=None, retries=3):
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"Referer": referer} if referer else {})
            with opener.open(req, timeout=15) as r:
                return r.read()
        except Exception as e:
            if attempt == retries - 1:
                raise
            # back off hard on rate limiting (HTTP 429)
            time.sleep(30 * (attempt + 1) if "429" in str(e) else 2 * (attempt + 1))


def norm(s):
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    s = s.replace("&", " and ")
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def tokens(s):
    # squash punctuation inside words so "A-ha" == "Aha"
    t = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    t = re.sub(r"[\'\u2019.\-]", "", t)
    return set(re.sub(r"[^a-z0-9]+", " ", t).split()) - {"the", "a", "and", "x", "ft", "feat", "featuring"}


def search(title):
    html_ = fetch(f"{BASE}/search?q={urllib.parse.quote(title)}").decode("utf-8", "replace")
    cards = re.findall(
        r'<h5 class=card-title><a href="?/?(download3-(\d+)-[^"\s>]+)"?[^>]*>(.*?)</a></h5>\s*'
        r'<div class=card-text>\s*<a [^>]*>(.*?)</a>',
        html_, re.S)
    return [(path, int(i), html.unescape(t).strip(), html.unescape(a).strip()) for path, i, t, a in cards]


def title_key(t):
    t = re.sub(r"[\(\[].*?[\)\]]", " ", t)          # drop "(Live)", "[Remix]" ...
    t = unicodedata.normalize("NFKD", t).encode("ascii", "ignore").decode().lower()
    t = re.sub(r"[\'\u2019.]", "", t)                 # don't -> dont, Mr. -> Mr
    t = re.sub(r"\bin\b", "in", t).replace("&", " and ")
    t = re.sub(r"(?<=[a-z])in\b", "ing", t)            # runnin -> running
    t = re.sub(r"[^a-z0-9]+", " ", t).strip()
    return re.sub(r"^(the|a|an) ", "", t)


def title_score(want, got):
    a, b = title_key(want), title_key(got)
    if not a or not b:
        return 0.0
    if a == b:
        return 1.0
    return difflib.SequenceMatcher(None, a, b).ratio()


def pick_best(title, artist, cards, min_title=0.85, min_artist=0.5):
    """cards: iterable of (title, artist, payload). Returns the best (title, artist, payload) or None."""
    want_a = tokens(artist)
    best, best_key = None, (0, 0)
    for t, a, payload in cards:
        ts = title_score(title, t)
        at = tokens(a)
        if ts < min_title or not at or not want_a:
            continue
        a_score = len(at & want_a) / len(at)
        if a_score < min_artist:
            continue
        if (ts, a_score) > best_key:
            best, best_key = (t, a, payload), (ts, a_score)
    return best


def slug(s):
    return re.sub(r"[^A-Za-z0-9]+", "_", s).strip("_")


def try_freemidi(s, entry, delay):
    cards = search(s["title"])
    time.sleep(delay)
    q2 = re.sub(r"\s*[\(\[].*?[\)\]]", "", s["title"]).strip()
    if not cards and q2 and q2 != s["title"]:
        cards = search(q2)
        time.sleep(delay)
    m = pick_best(s["title"], s["artist"], [(t, a, (path, mid_id)) for path, mid_id, t, a in cards])
    if not m:
        return
    t, a, (path, mid_id) = m
    page = f"{BASE}/{path}"
    fetch(page)  # visit the page first (sets cookies, like a browser)
    time.sleep(delay)
    data = fetch(f"{BASE}/getter-{mid_id}", referer=page)
    if not data.startswith(b"MThd"):
        raise ValueError("freemidi: response is not a MIDI file")
    fname = f"{slug(s['artist'])}__{slug(s['title'])}__fm{mid_id}.mid"
    (OUT_DIR / fname).write_bytes(data)
    entry.update(status="ok", source="freemidi", file=fname, url=page,
                 matched_title=t, matched_artist=a)


def try_midiworld(s, entry, delay):
    """Fallback: https://www.midiworld.com/search/?q=<title> -> 'Title (Artist) - download/<id>'."""
    page = fetch(f"https://www.midiworld.com/search/?q={urllib.parse.quote_plus(s['title'])}").decode("utf-8", "replace")
    time.sleep(delay)
    cards = [(html.unescape(t).strip(), html.unescape(a).strip(), int(i)) for t, a, i in re.findall(
        r"<li>\s*(.*?)\s*\(([^()]*)\)\s*-\s*<a href=\"https://www\.midiworld\.com/download/(\d+)\"", page, re.S)]
    cards = [(t, a, i) for t, a, i in cards]
    m = pick_best(s["title"], s["artist"], [(t, a, i) for t, a, i in cards])
    if not m:
        return
    t, a, i = m
    data = fetch(f"https://www.midiworld.com/download/{i}")
    if not data.startswith(b"MThd"):
        raise ValueError("midiworld: response is not a MIDI file")
    fname = f"{slug(s['artist'])}__{slug(s['title'])}__mw{i}.mid"
    (OUT_DIR / fname).write_bytes(data)
    entry.update(status="ok", source="midiworld", file=fname,
                 url=f"https://www.midiworld.com/download/{i}", matched_title=t, matched_artist=a)


def try_bitmidi(s, entry, delay):
    """Third source: https://bitmidi.com. Titles there are file names, so match on words in the name."""
    def words(x):
        x = unicodedata.normalize("NFKD", x).encode("ascii", "ignore").decode().lower()
        return set(re.sub(r"[^a-z0-9]+", " ", re.sub(r"[\'\u2019\-]", "", x.replace(".", " "))).split())

    want_t = [w for w in title_key(s["title"]).split()]
    want_a = tokens(s["artist"])
    if not want_t or not want_a:
        return
    best, best_key = None, None
    for q in (f'{s["artist"]} {s["title"]}', s["title"]):
        page = fetch(f"https://bitmidi.com/search?q={urllib.parse.quote(q)}").decode("utf-8", "replace")
        time.sleep(delay)
        for href, name in re.findall(r'href="(/[^"/]+-mid)" title="([^"]*)"', page):
            name = html.unescape(name)
            nw = words(re.sub(r"\.mid$", "", name, flags=re.I))
            t_hit = sum(w in nw for w in want_t) / len(want_t)
            a_hit = len(want_a & nw) / len(want_a)
            # "A HA" in the file name vs artist "A-ha": compare with spaces removed
            if a_hit < 1 and "".join(sorted(want_a)) and "".join(want_a) in "".join(re.sub(r"[^a-z0-9]", "", name.lower()) for _ in [0]):
                a_hit = 1.0
            if t_hit < 1.0 or a_hit < 0.5:
                continue
            key = (a_hit, -len(nw))  # best artist overlap, then the least extra words
            if best_key is None or key > best_key:
                best, best_key = (href, name), key
        if best:
            break
    if not best:
        return
    href, name = best
    detail = fetch(f"https://bitmidi.com{href}").decode("utf-8", "replace")
    m = re.search(r'href="(/uploads/\d+\.mid)"', detail)
    if not m:
        return
    time.sleep(delay)
    data = fetch(f"https://bitmidi.com{m.group(1)}", referer=f"https://bitmidi.com{href}")
    if not data.startswith(b"MThd"):
        raise ValueError("bitmidi: response is not a MIDI file")
    fname = f"{slug(s['artist'])}__{slug(s['title'])}__bm{m.group(1).split('/')[-1][:-4]}.mid"
    (OUT_DIR / fname).write_bytes(data)
    entry.update(status="ok", source="bitmidi", file=fname, url=f"https://bitmidi.com{href}",
                 matched_title=name, matched_artist="")


SOURCES = ["freemidi2", "midiworld2", "bitmidi2", "midis101v2", "freemidisv2"]


def squash(x):
    x = unicodedata.normalize("NFKD", x).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]", "", x)


def try_midis101(s, entry, delay):
    """https://www.midis101.com/search/<q> -> /free-midi/<id>-<slug> ; file names are squashed, so compare letters only."""
    t_sq, a_sq = squash(title_key(s["title"])), squash(s["artist"])
    a_sq2 = squash(re.sub(r"^the ", "", s["artist"].lower()))
    if len(t_sq) < 3 or not a_sq:
        return
    best = None
    for q in (f'{s["artist"]} {s["title"]}', s["title"]):
        page = fetch(f"https://www.midis101.com/search/{urllib.parse.quote(q)}").decode("utf-8", "replace")
        time.sleep(delay)
        for mid_id, slug_, name in re.findall(r'href="/free-midi/(\d+)-([^"]*)">([^<]*)</a>', page):
            n = squash(urllib.parse.unquote(name))
            if t_sq in n and (a_sq in n or a_sq2 in n):
                key = -len(n)  # least extra text = closest to "artist title"
                if best is None or key > best[0]:
                    best = (key, mid_id, slug_, name)
        if best:
            break
    if not best:
        return
    _, mid_id, slug_, name = best
    data = fetch(f"https://www.midis101.com/download/{mid_id}-{slug_}", referer=f"https://www.midis101.com/free-midi/{mid_id}-{slug_}")
    if not data.startswith(b"MThd"):
        raise ValueError("midis101: response is not a MIDI file")
    fname = f"{slug(s['artist'])}__{slug(s['title'])}__m101_{mid_id}.mid"
    (OUT_DIR / fname).write_bytes(data)
    entry.update(status="ok", source="midis101", file=fname,
                 url=f"https://www.midis101.com/free-midi/{mid_id}-{slug_}", matched_title=urllib.parse.unquote(name), matched_artist="")


_FM_ARTISTS = None


def extract_first_midi(archive_bytes):
    """Return (name, bytes) of the first .mid/.kar in a RAR/ZIP using bsdtar (read to stdout, nothing is unpacked to disk)."""
    import subprocess
    tmp = DATA / "tmp_archive"
    tmp.write_bytes(archive_bytes)
    try:
        names = subprocess.run(["bsdtar", "-tf", str(tmp)], capture_output=True, text=True, check=True).stdout.splitlines()
        for n in names:
            if n.lower().endswith((".mid", ".midi", ".kar")):
                out = subprocess.run(["bsdtar", "-xOf", str(tmp), n], capture_output=True, check=True).stdout
                return n, out
    finally:
        tmp.unlink(missing_ok=True)
    return None, None


def try_freemidis(s, entry, delay):
    """https://freemidis.net : /<Artist>/ lists songs, /<Artist>/<Song>/ links /midi/<Artist>/<Song>.rar (karaoke .kar/.mid)."""
    global _FM_ARTISTS
    base = "https://freemidis.net"
    if _FM_ARTISTS is None:
        home = fetch(base + "/").decode("utf-8", "replace")
        _FM_ARTISTS = [(h, html.unescape(n)) for h, n in re.findall(r'<a href="(/[^/"]+/)" title="[^"]*MIDI Files">([^<]*)</a>', home)]
    a_sq = squash(re.sub(r"^the ", "", s["artist"].lower()))
    arts = [h for h, n in _FM_ARTISTS
            if difflib.SequenceMatcher(None, a_sq, squash(re.sub(r"^the ", "", n.lower()))).ratio() >= 0.9]
    for h in arts[:2]:
        page = fetch(base + h).decode("utf-8", "replace")
        time.sleep(delay)
        songs = [(sh, html.unescape(sn)) for sh, sn in re.findall(r"<a href='(" + re.escape(h) + r"[^/']+/)'>([^<]*)</a>", page)]
        m = pick_best(s["title"], s["artist"], [(sn, s["artist"], sh) for sh, sn in songs])
        if not m:
            continue
        t, _, sh = m
        detail = fetch(base + sh, referer=base + h).decode("utf-8", "replace")
        time.sleep(delay)
        dl = re.search(r"href='(/midi/[^']+\.(?:rar|zip|mid|kar))'", detail)
        if not dl:
            continue
        data = fetch(base + urllib.parse.quote(dl.group(1)), referer=base + sh)
        if data.startswith(b"MThd"):
            name, content = dl.group(1), data
        else:
            name, content = extract_first_midi(data)
        if not content or not content.startswith(b"MThd"):
            raise ValueError("freemidis: no MIDI in download")
        ext = ".kar" if name.lower().endswith(".kar") else ".mid"
        fname = f"{slug(s['artist'])}__{slug(s['title'])}__fms_{slug(sh.strip('/').split('/')[-1])}{ext}"
        (OUT_DIR / fname).write_bytes(content)
        entry.update(status="ok", source="freemidis.net", file=fname, url=base + sh, matched_title=t, matched_artist=s["artist"])
        return


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0, help="only process first N songs")
    ap.add_argument("--delay", type=float, default=1.0, help="seconds between requests")
    ap.add_argument("--retry-not-found", action="store_true", help="search again for songs previously not found")
    args = ap.parse_args()

    songs = json.loads(SONGS_JSON.read_text())["songs"]
    if args.limit:
        songs = songs[: args.limit]
    OUT_DIR.mkdir(exist_ok=True)
    results = json.loads(RESULTS.read_text()) if RESULTS.exists() else {}

    fm_fail, fm_pause_until = 0, 0.0
    for n, s in enumerate(songs, 1):
        key = f'{s["artist"]} - {s["title"]}'
        prev = results.get(key, {})
        if args.retry_not_found and prev.get("status") == "not_found":
            prev = {}
        if prev.get("status") == "ok":
            continue
        # sources already searched (suffix = matcher version; older entries get re-searched)
        tried = {t for t in prev.get("tried", []) if t in SOURCES}
        if set(SOURCES) <= tried:
            continue
        entry = {"title": s["title"], "artist": s["artist"], "status": "not_found"}
        try:
            if "freemidi2" not in tried and time.time() >= fm_pause_until:
                try:
                    try_freemidi(s, entry, args.delay)
                    tried.add("freemidi2")
                    fm_fail = 0
                except Exception as e:
                    fm_fail += 1
                    entry["freemidi_error"] = str(e)
                    if fm_fail >= 3:  # freemidi is down/throttling: pause it for 10 min
                        fm_pause_until = time.time() + 600
                        fm_fail = 0
                        print("freemidi unreachable, pausing it for 10 min", flush=True)
            for name, fn in (("midiworld2", try_midiworld), ("bitmidi2", try_bitmidi),
                             ("midis101v2", try_midis101), ("freemidisv2", try_freemidis)):
                if entry["status"] != "ok" and name not in tried:
                    try:
                        fn(s, entry, args.delay)
                        tried.add(name)
                    except Exception as e:
                        entry[name + "_error"] = str(e)
        except Exception as e:
            entry.update(status="error", error=str(e))
        entry["tried"] = sorted(tried)
        results[key] = entry
        print(f"[{n}/{len(songs)}] {entry['status']:<9} {entry.get('source','-'):<9} {key}", flush=True)
        RESULTS.write_text(json.dumps(results, indent=2, ensure_ascii=False))
        time.sleep(args.delay)


    # relation song -> midi file, same shape as midi.json plus "midi_file"
    mapped = []
    for s in json.loads(SONGS_JSON.read_text())["songs"]:
        r = results.get(f'{s["artist"]} - {s["title"]}', {})
        mapped.append({**s, "midi_file": f'midis/{r["file"]}' if r.get("status") == "ok" else None})
    (DATA / "midi_map.json").write_text(json.dumps(
        {"count": len(mapped), "songs": mapped}, indent=2, ensure_ascii=False))

    ok = sum(1 for r in results.values() if r["status"] == "ok")
    print(f"done: {ok} downloaded, "
          f"{sum(1 for r in results.values() if r['status']=='not_found')} not found, "
          f"{sum(1 for r in results.values() if r['status']=='error')} errors")


if __name__ == "__main__":
    main()
