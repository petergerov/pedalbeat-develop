# Bass-Extraktions-Engine (Konzept / Vorarbeit)

Status: **Entwurf, nichts implementiert.** Ziel: aus Referenz-MIDIs (`pedalbeat-data/midi-songs/midis/`) pro Song-Part (Intro, Verse, Chorus, Bridge, Outro) einen **sehr guten Bass-Loop** und passende **Fills** ableiten. Dieselbe Engine soll später **Shaker / Tambourine / Clap** (Percussion-Spur) erzeugen.

Verwandt: `docs/bass-guitar-plan.md` (Bass-Track, Synth, Fill-Regel), `Core/Bass/BassGenerator.swift` (heutiger Regel-Generator).

---

## 1. Was heute schwach ist

`BassGenerator` baut den Bass nur aus **Kicks des PedalBeat-Drum-Patterns** + festen Tonfolgen (Root/Quinte/Oktave). Das heißt:

- keine **Akkordfolge** (jede Bar = Grundton E) → klingt nach Platzhalter
- keine **echten Bass-Idiome** (Oktavsprünge, Ghost-Notes, Synkopen-Pickups, Slides, Walking mit Skalenbezug)
- Rhythmus nur aus Kicks abgeleitet; Funk/Latin/Reggae-Bässe sind aber oft **unabhängig** von der Kick
- keine echten **Fills / Pickups** in den nächsten Part
- keine Qualitätsmessung

Die Referenz-MIDIs enthalten genau das, was fehlt: echte Basslinien von echten Songs.

---

## 2. Bestandsaufnahme der MIDIs (Stichprobe, Python-Skript)

Schneller Survey über das Ordner-Listing (~230 Dateien; `midi.json` listet 1871 Songs, also wächst das Material):

| Befund | Wert (grobe Heuristik) |
|---|---|
| Dateien mit erkanntem Bass (Programm 33–40 oder Name „bass“) | ~218 von ~232 |
| Dateien mit Drum-Spur (nur Kanal 10) | ~175 |
| Bass **und** Drums | ~169 |
| Taktart 4/4 | ~214 (Rest: 3/4, 5/4, 6/8, 1/4, keine Angabe) |
| Dateien mit **mehreren** Bass-Spuren | ~22 |
| PPQ (Auflösung) | stark verschieden: 96, 120, 192, 240, 384, 480, 960 |

Wichtige Erkenntnisse:

1. **Format-0-Dateien** (eine Spur, alle Kanäle gemischt) sind häufig (~60). Dort muss nach **Kanal** getrennt werden, nicht nach Spur. Die „218 mit Bass“-Zahl ist deshalb ein Obergrenzen-Wert.
2. Auflösung ist uneinheitlich → alles früh auf **Beats/Bars als Brüche** normalisieren, nicht auf rohe Ticks.
3. Qualität ist **gemischt** (Karaoke/Fan-Transkriptionen, teils stark quantisiert, teils live eingespielt, teils mit Tempowechseln). Die Engine braucht eine **Vertrauens-Bewertung** pro Song, nicht blindes Vertrauen.
4. Nicht jede MIDI hat Drums → Struktur-Erkennung darf nicht von Drums abhängen.

---

## 3. Architektur: Offline-Pipeline + Runtime-Generator

Zwei Schichten, damit die Qualität nicht an App-Laufzeit hängt:

```
[ Offline, Python in Tools/laneextract/ ]
  MIDI-Korpus ──► Analyse ──► Parts + Fills ──► Review ──► Ausgabe
                                  │                          │
                                  ▼                          ▼
                       Style-Bank (Templates, JSON)   "Groove A Bass.mid",
                                                      "Fill 1 Bass.mid", song.json
[ Runtime, Swift ]
  BassGenerator (neu)  ◄── Style-Bank: wählt Template passend zu Drum-Pattern + Akkordfolge
```

- **Offline** darf teuer und gründlich sein (Self-Similarity, Clustering, Kandidatenranking, HTML-Report zum Prüfen).
- **Runtime** nutzt für Songs **ohne** handgeschriebenen Bass die **Style-Bank** (Rhythmus-Templates + Intervall-Konturen), statt Root/Quinte-Zyklen.
- Handgeschriebene Bass-MIDIs („Groove A Bass.mid“) haben immer **Vorrang** (wie heute: `song.hasBass`).

Empfehlung: Offline-Tool in **Python** (schnelles Iterieren, Plot/HTML-Report, `mido`/`pretty_midi` per pip; auf diesem Rechner nicht installiert, Survey lief mit eigenem Mini-SMF-Parser). Das Format der Ausgabe bleibt das vorhandene (Bass als eigene MIDI-Dateien + `song.json`-Layout), damit der Swift-Import nichts Neues braucht.

---

## 4. Pipeline im Detail

### Stage 0 — Einlesen & Normalisieren
- SMF Format 0/1, Tempo-Map, Taktart-Map, Marker-/Text-/Lyric-Events (liefern oft Part-Namen wie „Chorus“).
- Spuren **und** Kanäle splitten; Noten als `(startBeat, durBeat, pitch, vel, channel)` in **Beats** (Brüche), nicht Ticks.
- Taktgitter bauen; **Auftakt** (Pickup) erkennen; Songs mit Taktart-/Tempowechsel markieren oder in Segmente teilen.
- Quantisierungsgitter schätzen: 16tel, Triolen (12er Raster), **Swing-Ratio** (Position des Off-8tels). Auf das Gitter snappen, Swing als Parameter speichern, nicht wegquantisieren.

### Stage 1 — Rollen der Spuren erkennen
Pro Spur/Kanal ein Score aus:
- GM-Programm 32–39 (Bass), Spurname, Medianhöhe < ~E3, **Monophonie-Anteil** > 90 %, Notendichte.
- Drums: Kanal 10.
- Harmonie-Spuren (Gitarre/Keys/Pads): alles andere → für Akkorderkennung.

Mehrere Bass-Spuren: Hauptspur = höchste Dichte × Monophonie; Doppelungen (Sub-Oktave, Synth+E-Bass) zu **einer** Linie zusammenführen (tiefste/lauteste Note je Zeitpunkt, Oktave in Spielbereich falten).

### Stage 2 — Akkorde/Grundton pro Takt
- Grundton aus Bass (dauer-/betonungsgewichtetes Pitch-Class-Histogramm pro Takt/Halbtakt), **gegengeprüft** mit den Harmonie-Spuren (Chroma → Akkord-Template-Match).
- Ergebnis: Akkordfolge `[(bar, beat, rootPC, quality)]` und **Tonart** (Krumhansl-Profil über den ganzen Song).
- Bass-Töne werden dann als **Intervall zum Akkord-Grundton** gespeichert (Grundton, b3, 3, 4, 5, 6, b7, Oktave, Chromatik-Approach …), plus Oktavlage.

→ Das ist der Kern für **Transposition**: Ein Template funktioniert in jeder Tonart und über jede Akkordfolge des PedalBeat-Songs.

### Stage 3 — Struktur-Segmentierung (Parts finden)
Pro Takt ein Feature-Vektor:
- Bass: Onset-Rhythmus (16er-Maske), Pitch-Class-Histogramm
- Harmonie: Chroma
- Energie: Notenzahl, mittlere Velocity, Drum-Dichte, Crash/Becken am Taktanfang
Daraus:
1. **Self-Similarity-Matrix** über Takte (Kosinus-/Edit-Distanz).
2. Wiederholte Blöcke finden (Diagonalen, Perioden 2/4/8 Takte); Grenzen über **Novelty-Kurve** und Marker-Events.
3. **Label-Heuristik** (Verse/Chorus/Bridge/Intro/Outro): Position im Song, Energie-Rang, Wiederholungszahl, Intro = erste Blöcke mit niedriger Energie, Outro = letzter Block / Ritardando / Fade, Bridge = einmalig mit neuem Akkordmaterial. Wenn Marker-/Textevents vorhanden: haben Vorrang.
4. Ausgabe: `[Section(label, startBar, endBar, instances[], confidence)]`.

Ziel-Mapping auf PedalBeat: `Verse → Part 1 main`, `Chorus → Part 2 main`, `Bridge → Part 3`, Intro/Outro → eigene Slots. (Passt zu `PartRole` im bestehenden Generator.)

### Stage 4 — Pro Part: Prototyp-Loop bilden
Ein Part kommt im Song mehrfach vor und variiert. PedalBeat braucht **einen stabilen Loop** (1, 2 oder 4 Takte):

1. **Periode** bestimmen (1/2/4 Takte) per Autokorrelation der Takt-Features; bevorzugt kürzeste Periode, die ≥ 80 % erklärt.
2. **Konsens-Bildung** über alle Instanzen (Voting pro 16tel-Schritt):
   - Onset bleibt, wenn Auftrittswahrscheinlichkeit ≥ 0.5
   - Pitch = häufigstes Intervall zum Akkord-Grundton
   - Dauer/Velocity = Median
3. **Varianten**: Takte, die systematisch abweichen, werden **Groove B** (z. B. Chorus-Lift, zweite Hälfte der Phrase) statt weggemittelt.
4. **Seam-Check**: Letzter→erster Ton des Loops muss musikalisch passen (kein harter Sprung), sonst Anpassung des letzten Tons (Approach/Wiederholung).
5. Alternativ zum Konsens: **Medoid** (die Instanz mit der geringsten Distanz zu allen anderen) — manchmal klingt eine echte Instanz besser als ein Mittelwert. Beide als Kandidaten behalten, Scoring entscheidet.

### Stage 5 — Fills finden und extrahieren
**Erkennung:** Letzte 1–2 Takte (oder letzte Beats) vor einem Part-Wechsel, wo mindestens eines gilt:
- Drums weichen ab (Tom-/Snare-Dichte ↑, Crash auf der nächsten Eins)
- Bass weicht vom Prototyp ab (Distanz > Schwelle)
- Bass pausiert / hält auf einem Ton

**Klassifikation** der Bass-Fills (Cluster):
| Typ | Merkmal |
|---|---|
| `hold` | Bass hält Grundton/Quinte, Drum füllt |
| `dropout` | Bass setzt aus (Stop-Time), Einsatz auf der Eins |
| `pickup` | 1–4 Noten Auftakt (Approach-Chromatik, Skalenlauf) zur Eins des nächsten Parts |
| `run` | Skalen-/Arpeggio-Lauf über den ganzen Takt |
| `octave-drive` | Achtel-Oktav-Pumpen vor dem Chorus |

**Regeln für PedalBeat:**
- Default bleibt: **Bass läuft unter dem Fill weiter** (siehe Bass-Plan). Der extrahierte Fill ist **optional** (`fillBass`) und bekommt eine Confidence; nur ab Schwelle wird er überhaupt angeboten.
- Fill kürzer als ein Takt: wie bei Drums wird der Rest des Takts übersprungen → Fill-Länge in Beats speichern (1, 2, 4 Beats / 1 Takt).
- Fills **relativ zum Zielakkord** speichern (Pickup auf die Eins des nächsten Parts, nicht auf den aktuellen Grundton).
- Pro Part-Typ 2–3 Fill-Varianten (kurz/lang, ruhig/laut), damit Wiederholungen nicht gleich klingen.

### Stage 6 — Vereinfachung & Spielbarkeit
Jeder Onset bekommt einen **Importance-Score**: Position (Downbeat > Offbeat), Kick-Koinzidenz, Chord-Root, Dauer, Auftrittswahrscheinlichkeit. Daraus **Intensitätsstufen** ohne neue Daten:

| Stufe | Inhalt |
|---|---|
| `root` | nur Grundtöne auf den wichtigsten Onsets |
| `simple` | Score ≥ hoch (Verse-Default) |
| `full` | alles inkl. Ghost-Notes/Pickups (Chorus-Default) |

Danach: Bereich auf E1–G3 falten (MIDI 28–55, wie `BassGenerator.clamp`), Noten < 1/16 entfernen, Überlappungen auflösen (monophon), Sprünge > Oktave abschwächen, Velocity auf 3 Level (Ghost / normal / Akzent) normalisieren, Humanize-Jitter der Quelle entfernen.

### Stage 7 — An das PedalBeat-Drum-Pattern anpassen (wichtig!)
Die Quell-MIDI hat **ihre** Drums, PedalBeat spielt aber **eigene** Drum-Grooves. Deshalb pro Song/Part messen:

- `kickLock` = Anteil der Bass-Onsets, die auf einer Quell-Kick liegen.

Dann:
- **kickLock hoch** (Rock/Pop/Disco, > ~0.7): Onsets an die **Kicks des Ziel-Patterns** hängen, Tonhöhen-Kontur aus der Quelle übernehmen.
- **kickLock niedrig** (Funk, Reggae, Latin, Walking): Bass-Rhythmus der Quelle **behalten**, nur gegen Kollisionen/Backbeat prüfen.
- dazwischen: pro Onset entscheiden (Score).

Das ersetzt die starre `style`-Switch-Logik in `anchors(...)`.

### Stage 8 — Quality-Gate & Kandidaten-Ranking
Pro Part 3–5 Kandidaten (Konsens, Medoid, Stufen, Kick-Lock-Varianten). Score u. a.:

- Groove-Konsistenz (wie stark wiederholt sich das Muster in der Quelle)
- Kick-/Snare-Kompatibilität mit dem Ziel-Drumloop
- Notendichte im Genre-Korridor (aus Korpus-Statistik)
- Akkordtreue (Anteil Akkordtöne auf starken Zählzeiten)
- Tonvielfalt (nicht ein Ton 16×), Sprungweiten, Range
- Seam (Loop-Naht)
- Quell-Vertrauen (Stage 1–3 Confidence)

Nur Kandidaten über Schwelle werden automatisch übernommen, der Rest landet in der **Review-Liste**.

### Stage 9 — Review-Werkzeug
HTML-Report pro Song: Struktur-Zeitleiste, Piano-Roll je Part (Quelle vs. Ergebnis), Audio-Preview wäre ideal (gleiche BassSynth-Parameter nicht nötig; ein einfacher Render reicht). Aktionen: Kandidat wählen, Part-Label ändern, Fill an/aus. Du prüfst nur **niedrige Confidence**, nicht alles.

### Stage 10 — Ausgabe
- Bass-MIDI-Dateien im vorhandenen Schema („Groove A Bass.mid“, „Groove B Bass.mid“, „Ending Bass.mid“, optional „Fill 1 Bass.mid“ …).
- `song.json`-Layout mit Verweisen (wie heute).
- Sidecar `*.analysis.json`: Tonart, Akkordfolge pro Takt, Part-Grenzen, Confidence, Herkunft (welche Quell-Takte), gewählter Kandidat.

---

## 5. Style-Bank (für Songs ohne eigene Bass-MIDI)

Aus dem gesamten Korpus lernen statt nur 1:1 kopieren:

- Schlüssel: `Genre × Taktart × Tempo-Band × Part-Rolle`
- Inhalt: **Rhythmus-Templates** (16er-Maske + Velocity-Level + Dauerklasse), **Intervall-Konturen** (n-Gramme über Akkordtöne), Fill-Typen mit Häufigkeit
- Runtime-Auswahl: Template, das zum **Ziel-Drumloop** (Kick/Snare-Maske) am besten passt, Pitches aus Akkordfolge + Kontur, leichte Variation per Seed.

Hinweis Urheberrecht: Die Referenz-MIDIs sind Transkriptionen urheberrechtlich geschützter Songs. 1:1 übernommene Basslinien eines konkreten Songs sollten **nicht** ausgeliefert werden. Abstrahierte Templates (Rhythmusmaske + Intervallkontur über Genre) sind unkritischer; eigene handgeschriebene MIDIs sind frei. Vor Auslieferung bewusst entscheiden.

---

## 6. Gleiche Engine für Shaker / Tambourine / Clap (später)

Stage 0, 3, 4, 5, 8, 9, 10 sind **instrumentunabhängig**. Nur Stage 1/2/6/7 ändern sich → die Engine bekommt ein Lane-Interface:

```
protocol/Struktur LaneProfile
  - Quelle:   welche Events zählen (Bass: Pitch+Programm; Perc: GM-Noten)
  - Pitched:  ja/nein (Bass ja; Perc nein)
  - Lock:     woran hängt die Spur (Bass: Kick/Akkord; Shaker: Hi-Hat-Raster; Clap: Snare)
  - Fill-Typen
```

**Percussion-Quellen im MIDI (GM, Kanal 10):** Maracas 70, Shaker 82 (Cabasa 69), Tambourine 54, Hand Clap 39, Cowbell 56, Claves 75 …

Erwartung: Echte Shaker/Tambourine-Spuren sind in den MIDIs **selten und uneinheitlich** (Tambourine/Clap eher vorhanden, Shaker kaum). Daher zweigleisig:

1. **Extraktion**, wo vorhanden (gleiche Parts/Konsens-Logik, unpitched).
2. **Ableitung aus Drums**, wo nicht: Shaker folgt dem Hi-Hat-/Ride-Raster (z. B. 16tel mit Akzent auf Zählzeit, Backbeat-Ghosts), Tambourine auf 2 & 4 oder Achteln, Clap verstärkt die Snare (oder versetzt, Disco/Hip-Hop). Parameter pro Genre aus der Korpus-Statistik.

Spezifisches:
- **Datenmodell**: `PercEvent(tick, instrument, velocity)`, `PercPattern` mit **Lanes** (shaker/tambourine/clap getrennt), analog zu `BassPattern`; MIDI-Out Kanal 10 oder eigener Kanal.
- **Merkmale pro Part**: Dichte (8tel/16tel/Triolen), Akzentkurve (Velocity-Muster 4 Schritte), Swing, Offen/Geschlossen (Shake-Richtung via zwei Velocity-Level), Aussetzer im Intro.
- **Fills**: Roll/Crescendo in den nächsten Part, Stop vor der Eins, Tambourine-Hit auf der Eins des neuen Parts.
- **Dynamik pro Part-Rolle**: Verse dünner, Chorus dichter → wieder über Importance-Score/Intensitätsstufen (Stage 6).

Damit sich später kein Umbau lohnt: **jetzt schon** Datenmodell und Engine-Ausgabe lane-generisch halten (`kind: bass | shaker | tambourine | clap`), Bass ist die erste Instanz.

---

## 7. Meilensteine

| M | Ergebnis |
|---|---|
| E0 | Survey-Skript als Tool (SMF-Parser/`mido`), Korpus-Report: Format, Spuren, Rollen, Taktarten, Qualitätsscore |
| E1 | Rollenerkennung + Taktgitter + Bass-Extraktion (nur Auftakt/Normalisierung) |
| E2 | Akkord-/Tonart-Erkennung, Intervall-Darstellung |
| E3 | Struktur-Segmentierung + Labels (Review per HTML-Timeline) |
| E4 | Prototyp-Loop + Varianten + Intensitätsstufen |
| E5 | Fill-Erkennung/-Klassifikation |
| E6 | Drum-Lock auf PedalBeat-Patterns, Kandidaten-Ranking, Quality-Gate |
| E7 | Ausgabe im bestehenden Format + Review-Report; Tests an ~10 Referenzsongs mit bekanntem Ergebnis |
| E8 | Style-Bank + neuer Runtime-`BassGenerator` |
| P1+ | Percussion-Lanes auf derselben Engine |

Test-Strategie: eine kleine **Gold-Liste** von Songs, deren Bass-Parts du von Hand korrigierst → Engine wird gegen diese Referenz gemessen (Part-Grenzen ±1 Takt, Onset-F-Score, Pitch-Übereinstimmung). Deine handgeschriebenen MIDIs sind damit gleichzeitig Trainings-/Eichmaterial.

---

## 8. Entscheidungen (Stand: Antwort des Entwicklers)

1. **Tool-Ort:** `Tools/laneextract/` in diesem Repo (Python, nur Standardbibliothek; früher `pedalbeat-data/tools/laneextract/`). Die Daten bleiben in `pedalbeat-data`.
2. **Auslieferung:** Ergebnisse zunächst nur als **Beispiele**; produktive Auslieferung erst, wenn alle Songs/MIDIs vorliegen.
3. **Raster:** fein. Engine rechnet mit 16tel **und** Triolen (12er-Raster), Swing wird als Parameter gespeichert.
4. **Loop-Länge:** unentschieden. Vorschlag: Default **1 Takt**; 2 Takte nur, wenn die Quelle klar eine 2-Takt-Periode hat (Stage 4: Periode erklärt deutlich mehr als 1 Takt). Als Groove B/A-Wechsel statt langer Loops anbieten. Noch zu klären: Wie verhält sich ein 2-Takt-Bass unter einem 1-Takt-Drum-Loop in der Engine (beide loopen mit eigener Länge)?

Noch offen: Urheberrecht (Abschnitt 5), Fill-Bass-Default (Abschnitt 4, Stage 5), weitere MIDIs aus `midi.json` nachladen.

## 9. Stand E1 (umgesetzt)

**Entscheidung: Drums kommen aus den bestehenden PedalBeat-Songs und -Parts**, nicht aus den Referenz-MIDIs. Die 174 Factory-Songs (`pedalbeat-data/songs/<Genre>/<Song>/`, `song.json` + Drum-MIDIs) sind das **Ziel**; die Referenz-MIDIs liefern nur Bass-Material (Rhythmus + Intervall-Kontur). Die Drums der Quell-MIDIs dienen nur noch zur Messung (z. B. `kickLock`) und zur Struktur-Erkennung der Quelle.

Folge für die Pipeline: Stage 7 („An das Drum-Pattern anpassen“) ist der **Hauptpfad**. Pro Factory-Part wird aus dem Korpus das Bass-Template gesucht, das zu Genre, Taktart/Grid, Tempo und Kick/Snare/Hat-Maske des Parts passt. Fills und Intro/Transition/Ending der Factory-Songs bekommen ihre Bass-Antwort aus denselben Templates.

### Werkzeug

```
cd Tools/laneextract
python3 -m laneextract report  ../../../pedalbeat-data/midi-songs/midis <out>   # Quell-Korpus
python3 -m laneextract factory ../../../pedalbeat-data/songs            <out>   # Ziel: Factory-Drums
```

| Modul | Aufgabe |
|---|---|
| `smf.py` | SMF-Parser (Dauern, Tempo-/Taktart-Map, Marker, **PedalBeat-„PB1“-Meta**: exakte Pattern-Länge, Signatur-Label, Swing) |
| `roles.py` | Lanes je Spur+Kanal, Bass-Score, Bass-Doubles |
| `timemap.py` | Taktgitter (Taktartwechsel, unplausible Signaturen ignoriert), Tempo = dauergewichteter Median, `bpm_folded` (70–160), Warnungen |
| `quant.py` | Bass auf das **1/12-Viertel-Raster** (16tel = 3, Achtel = 6, Triolen-Achtel = 4), monophone Reduktion (tiefster Ton je Onset), Feel: straight / triplet / mixed / loose, Off-Grid-Anteil |
| `factory.py` | Lädt Factory-Songs/-Parts: Rollen (intro/main/fill/transition/outro), Lanes kick/snare/hat/ride/crash/tom/perc als Positionslisten, Grid (straight/triplet), Swing, Masken |
| `report.py` | `corpus_report.{json,md}`, `bass_bars/<song>.json` (quantisierter Bass pro Takt), `factory_drums.json`, `factory_report.md` |

### Ergebnis Quell-Korpus (333 Dateien, wächst, 0 Lesefehler)
- 309 mit Bass-Lane, 304 über Quality-Schwelle 0.65 (Median 0.95): die Quellen sind überwiegend sauber. Schwache Ausreißer (z. B. *Sunshine of Your Love*, *Crossroads*: Bass-Lane deckt nur 5–10 % der Takte) werden jetzt markiert.
- Bass-Feel: 259 straight, 31 triplet, 7 mixed, 12 loose.
- 37 Dateien mit Taktart-, 59 mit Tempowechsel (teils Live-Tempo mit bis zu 38 Werten → eigener „Live-Tempo“-Pfad in E3, hier nur Warnung).
- Unplausible Meta-Events (z. B. „149/4“) werden ignoriert; BPM-Doppeldeutigkeit (*Wicked Game* 240) wird über `bpm_folded` abgefangen.
- Perkussion im Drum-Kanal (Noten): Tambourine ~24 000, Cabasa ~14 600, Maracas ~5 900, Clap ~5 300, Shaker ~3 500, Cowbell ~2 500 → Material für die spätere Percussion-Spur.

### Ergebnis Factory-Songs (Ziel)
- 174 Songs, 2326 Patterns, **451 Parts (main)** in 18 Genres.
- Signaturen: 4/4 ×136, 12/8 ×24, 3/4 ×5, 6/8 ×5, 5/4 ×2, 7/8 ×2. Die 12/8-Songs sind 4/4 mit Triolen → Grid „triplet“ (60 Parts), „straight“ 383, „mixed“ 8.
- **Mains sind 1 Takt (428) oder 2 Takte (23), alle Fills genau 1 Takt (1353).** Daraus folgt für die offene Loop-Frage: Bass-Loops über **1 Takt**, optional **2 Takte nur dort, wo auch der Drum-Part 2 Takte hat** — kein Konflikt mit dem Loop-Modell.
- Keine Ladewarnungen; alle `song.json`-Layouts lesbar.

### Bekannte Schwächen / nächste Schritte
- Die Qualitäts-Schwelle trennt nur die offensichtlichen Ausreißer; Feintuning folgt, wenn E2–E4 echte Fehlerfälle zeigen.
- Auftakt (Pickup) wird noch nicht erkannt; Live-Tempo-Songs haben nur Warnungen.
- Bass-Doubles werden erkannt, aber noch nicht zusammengeführt.
- Nächstes: **E2** Akkordgrundton/Tonart pro Takt und Intervall-Darstellung der quantisierten Bass-Takte; danach **E3** Struktur der Quellen.

## 10. Stand E2 (umgesetzt)

```
python3 -m laneextract analyse ../../midi-songs/midis ../../songs <pedalbeat-develop> <out>
```
Ausgabe: `<out>/songs/<datei>.json` (pro Takt: Akkorde + Bass als Intervalle), `links.json`, `harmony_report.md`.

### Neue Module
| Modul | Aufgabe |
|---|---|
| `songindex.py` | Liest `Core/SongIndexData.swift` + `styleMap`/`genreFallback` aus `Core/SongIndex.swift` direkt aus dem App-Code. Kette: MIDI-Datei → SongIndex-Eintrag (BPM, Genre, Beat-Style) → `Target(genre, groove)` → **Factory-Song** (gleiche Regel wie `SongLibrary.song(for:)`). |
| `harmony.py` | Akkord pro Takt oder Halbtakt (8 Qualitäten: maj, min, 7, maj7, m7, sus4, dim, 5) aus Begleit-Chroma + gewichtetem Bass. Tonart: Krumhansl-Profil + Tonika-Akkord + Kadenzen (V/IV/bVII→I) + erster/letzter Akkord. Bass als `rel` (Halbtöne über dem Akkordgrundton), Stufe (R, b3, 5, b7 …) und Rolle (`chord`, `passing`, `approach`, `anticipation`). |
| `phase.py` | Auftakt/Taktphase: Snare pro Schlag + Bestätigung durch die Akkordwechsel-Phase; halber Takt über Akkordwechsel in Taktmitte. |
| `gold.py` | Plausibilitäts-Liste mit 37 bekannten Tonarten, davon 5 als transponiert korrigiert, nachdem ich ihre Akkordfolgen geprüft habe. |

### Ergebnis (412 MIDIs, 0 Fehler)
- **SongIndex-Verknüpfung 412/412**, alle mit Factory-Song (Score ≥ 0.99; die MIDIs stammen aus der SongIndex-Liste). Häufigste Ziele: Rock · Straight Eights 77, Blues · Shuffle 63, Pop · Anthem 32, Country · Country Shuffle 28, Country · Boom Chick 24.
- **Tonart:** 34/37 exakt. Abweichungen: *Wicked Game* (Datei transponiert, Tonika mehrdeutig), *Sunshine of Your Love* (Riff ohne Begleitakkorde), *Don't Fear the Reaper* (Am–G–F–G: G erkannt statt Am).
- **Akkorde:** Stichproben stimmen gut, z. B. *Hotel California* Bm F# A E G D Em F#, *Peaceful Easy Feeling* E A E B, *Hound Dog* A D A E. Median: 0.83 Wechsel pro Takt, **83 % der Wechsel auf der Eins**, 11 Akkorde pro Song.
- **Bass in Intervallen:** Grundton 71 %, Quinte 10 %, b7 3 %, Terz 3 %. Rollen: 86 % Akkordton, 11 % Durchgang, 2 % Approach, 1 % Antizipation.
- **Auftakt:** Erkennung eingebaut, aber konservativ. Im aktuellen Korpus wird **kein** Gitter verschoben. Die meisten Transkriptionen sind richtig getaktet. Frühere Treffer waren Half-Time-Grooves (Snare nur auf 3) oder bewusst auf 1 & 3 gespielte Beats.
- **Tempo:** MIDI-BPM = Index-BPM bei 226, doppelt/halb bei 23, Triolen-Verhältnis bei 14, **ohne Bezug bei 149**. Für die Pattern-Extraktion egal, weil der Bass im Tick-Raster des Factory-Songs läuft. Für die Template-Auswahl nach Tempo gilt der Index-BPM.

### Behobene Fehler während E2
1. Grundton-Quint-Bässe (Country/Rockabilly) erzeugten Scheinwechsel (`E/Bsus4`). Ein Takt wird jetzt nur geteilt, wenn sich die **Begleitung** ändert oder der Bass akkordfremde Töne spielt. Ergebnis: „Wechsel auf der Eins“ von 70 % auf 83 %, Problemsongs von 19 auf 3.
2. Half-Time-Snare wurde als verschobenes Gitter gelesen. Verschoben wird jetzt nur, wenn Schlag 1 **und** 3 stark sind und die Akkorde die Verschiebung bestätigen.

### Grenzen (bewusst)
- „Grundton auf Akkordbeginn 99 %“ und „Akkordton auf Zählzeiten 93 %“ sind **teilweise zirkulär**, weil der Bass in die Akkorderkennung eingeht. Das ist keine unabhängige Validierung.
- Riff-Songs mit dünner Begleitung (*Sunshine of Your Love*, *Stand by Me* von Ben E. King) haben unsichere Akkorde. Sie sind über `chord.conf` erkennbar.
- Akkordqualität (Moll/Dur) ist unsicherer als der Grundton, Melodietöne können sie verfälschen. Für den Bass zählt vor allem der Grundton.

### Nächster Schritt: E3
Struktur der Quellen: Self-Similarity über Takte (Bass-Rhythmus + Intervalle + Akkorde + Energie), Parts finden und als Verse/Chorus/Bridge/Intro/Outro labeln. Dann die Zuordnung auf die Parts des Factory-Songs (Groove A/B/…, Fills, Intro, Ending).

## 11. Stand E3 (umgesetzt)

**Entscheidung (Entwickler):** Die Referenz-MIDIs dienen für **alles**: Die Bass-Parts werden aus den MIDI-Basslinien gebaut, die Akkorderkennung hilft dabei. Zusätzlich entstehen pro Song Akkord-Sheets als mögliche Hilfe für die Live-Chord-Detection (`ChordDetector` hat bereits Tonart-/Progressions-Prioren).

**Wichtig für E4:** Factory-Parts sind Loops von 1–2 Takten, und Bass Follow transponiert live auf den gespielten Akkord. Ein Bass-Part ist deshalb ein **akkordrelativer** Loop: Rhythmus + Intervalle zum Grundton, nicht die absolute Linie eines Songs. Die E2-Darstellung (`rel`) liefert genau das.

### Modul `structure.py`
1. **Takt-Merkmale:** Bass absolut und akkordrelativ, Rhythmus, Akkordgrundtöne relativ zur Tonart, Energie (Notendichte, Drums, Velocity, aktive Spuren), Tom-Fills, Crash auf der Eins.
2. **Ähnlichkeitsmatrix** über Takte. Der Inhalt wird pro distinct Takt-Typ einmal berechnet, damit das schnell bleibt.
3. **Grenzen:** Foote-Novelty + **Wiederholungs-Streifen** (Diagonalen der Matrix: Anfang und Ende jeder Wiederholung) + Crash, Fill-Takt davor, 4/8-Takt-Phrasenraster, Energiesprung.
4. **Gruppierung:** Sektionen nach ausgerichteter Ähnlichkeit gruppieren. Dann wiederholte Phrasen-Paare verschmelzen (BPE, bis 16 Takte), gleiche Nachbarn zusammenlegen, einmalige Varianten der ähnlichsten Gruppe zuordnen, Stücke unter 4 Takten der vorigen Sektion zuschlagen. Alles vor der ersten Wiederholung ist Intro, alles nach der letzten Outro (≤ 16 Takte).
5. **Labels:** Die zwei wiederholten Gruppen mit der größten Abdeckung sind Strophe und Refrain; der Refrain ist die energiereichere. Weitere wiederholte Gruppen sind „part“, die längste einmalige Sektion ab 30 % des Songs ist die Bridge.
6. **Zuordnung auf den Factory-Song:** Groove A ← Strophe, B ← Refrain, C ← Bridge, weitere Parts ← „part“. Intro ← Intro, Ending ← Outro (sonst die letzten 2 Takte).
7. **Akkord-Sheet:** Tonart, Akkordvorrat (Zeitanteile), häufigste Übergänge, Progression pro Sektion. Gesammelt in `<out>/chord_sheets.json`, Schlüssel „Interpret - Titel“ wie im SongIndex.

### Ergebnis (448 Songs mit Bass)
- Median 11 Sektionen pro Song; Längen vor allem 4, 8, 12, 16 Takte.
- Wiederholungsanteil Median 0.61; **299 Songs mit Strophe + Refrain**, 289 mit Intro, 227 mit Outro.
- Zuordnung: A = Strophe 448, B = Refrain 299 (sonst Bridge/Part), C = Bridge 137 / Part 76.
- Stichproben: *Rolling in the Deep* `I11 V16 C8 V16 C8 … B C13`, *Yellow* `I5 C20 V16 C6 B4 … V16 C20 O6`, *Kryptonite*, *Livin' on a Prayer* und *Hotel California* plausibel.
- Zwei Verbesserungen während E3: Phrasen-Paare (Hotel California: Strophe X+Y, Refrain Z+Y) und Wiederholungs-Streifen als Grenzen. Dadurch sanken die Songs ohne erkannte Wiederholung von 85 auf 44, Songs mit Strophe+Refrain stiegen von 223 auf 299.

### Grenzen
- 44 Songs (10 %) ohne erkannte Wiederholung, meist frei variierte oder live eingespielte Transkriptionen. Für sie fällt E4 auf die energiereichsten/häufigsten Takt-Typen zurück.
- Wenn Strophe und Refrain im Bass identisch sind (*Zombie*), entsteht ein langer Block. Für den Bass-Part ist das unkritisch.
- Die Labels sind Heuristik und nicht gegen Hörbeispiele validiert. Eine kleine handgeprüfte Gold-Liste der Formen wäre der nächste Qualitätshebel.

### Nächster Schritt: E4
Pro zugeordnetem Part (A, B, C …) einen **akkordrelativen Bass-Loop** bauen. Länge wie der Factory-Drum-Part (1 oder 2 Takte, Raster straight/triplet wie die Drums). Konsens über alle Takte der Sektionsgruppe: Onset-Wahrscheinlichkeit pro Rasterposition, häufigstes Intervall, Median von Dauer und Velocity. Dazu Medoid-Kandidat, Seam-Check und Range E1–G3. Ausgabe als `Groove A Bass.mid` usw. im bestehenden Format (Grundton E, `bassRootPitchClass = 4`).

## 12. Stand E4 (umgesetzt): Bass- und Percussion-Parts als Beispiel-Songs

**Entscheidung (Entwickler):** Percussion (Shaker, Tambourine, Clap, …) wird gleichzeitig gebaut, als **eigene Dateien**. Die Funktion in der App kommt später, nach dem Muster des Basses.

### Ausgabe
`pedalbeat-data/build/laneextract/examples/<Factory-Genre>/<Interpret – Titel>/` ist ein **importierbarer PedalBeat-Song** („Import MIDI, Folder or Kit…“, einzelner Song- oder Genre-Ordner):
- die Drum-Dateien des Factory-Songs, auf das **SongIndex-Tempo** des Songs gesetzt
- `Groove A Bass.mid`, `Groove B Bass.mid`, … und `Intro Bass.mid` / `Ending Bass.mid`: PedalBeat-Format (Typ 0, 480 PPQ, PB1-Meta mit exakter Länge, Kanal 2, Programm 33), **Grundton E** (App-Default `bassRootPitchClass = 4`), Lage E1–G3
- `Groove A Percussion.mid`, …: GM-Percussion auf Kanal 10, nur Instrumente, die der Factory-Groove noch nicht hat
- `song.json`: Factory-Layout + `parts[].bass`, `introBass`, `outroBass`. Zusätzlich ein Block `laneextract` (Quelle, Factory-Song, Tonart, pro Part Quell-Label, Methode, Konsistenz und die Percussion-Dateien). Die App ignoriert unbekannte Schlüssel und zusätzliche Dateien beim Import.

### Modul `parts.py` (+ `midiout.py`)
1. Pro Factory-Part die Takte der zugeordneten Sektionsgruppe, ohne den Schlusstakt jeder Sektion (Fill/Turnaround). Fenster so lang wie der Drum-Part (1 oder 2 Takte), gleiche Taktlänge.
2. Positionen auf das **Raster des Drum-Parts**: straight ↔ triplet (z. B. Swing-Achtel 8 ↔ 6).
3. Bass akkordrelativ. Antizipationen (nächster Grundton vor dem Wechsel) zielen auf den Loop-Grundton, Approach-Töne behalten ihren Halb-/Ganztonschritt zum nächsten Grundton.
4. Kandidaten: **Medoid** (echter Takt, der allen anderen am ähnlichsten ist) und **Konsens** (Onset-Wahrscheinlichkeit ≥ 0.5, häufigstes Intervall, Median von Dauer/Velocity). Bei gleicher Güte gewinnt der echte Takt.
5. Wäre ein späterer Part identisch mit einem früheren, wird die beste **andere** echte Variante aus den Quelltakten genommen (Konsistenz ≥ 0.25).
6. Intro-Bass nur, wenn das Quell-Intro in mindestens der Hälfte seiner Takte Bass hat. Ending = erster Ton des letzten Bass-Takts, klingt bis zu 2 Schläge.
7. Percussion: dieselben Fenster, pro Instrument nur, wenn es in ≥ 50 % der Fenster spielt und die Instrumentfamilie nicht schon im Factory-Groove ist (Shaker/Maracas/Cabasa = eine Familie, Clap gegen vorhandenen Clap).

### Ergebnis (482 MIDIs, 448 mit Bass)
- **436 Beispiel-Songs** exportiert. Bass-Loops: A 417, B 413, C 186, Intro 144, Ending 436. 12 Songs ohne passende Takte (meist andere Taktart als der Factory-Groove).
- Methode: Medoid 973, Variante 155, Einzeltakt 31, Konsens 1.
- Konsistenz (Ähnlichkeit des Loops zu seinen Quelltakten): P10 0.34, Median 0.54, P90 0.91.
- Groove A = B nur noch bei 28 Songs (vorher 135).
- Loop-Dichte: Median 5 Noten pro Takt (P10 2, P90 8).
- **Percussion bei 154 Songs** (291 Dateien): Tambourine 114 Parts, Clap 76, Cabasa 70, Conga 58, Maracas 35, Shaker 24, Cowbell 22, Bongo 21, …
- **Geprüft mit dem echten App-Parser** (`MIDIDrumFile` + `SongLayout` aus `Core/`, als Test-Binary kompiliert): 436 Songs, 1596 Bass-Dateien, **0 Probleme**. Percussion: Shaker, Tambourine, Clap und Cowbell bildet die App heute schon auf eigene Drums ab. Congas/Bongos landen auf Toms, Claves auf Side Stick, 50 Noten sind nicht zugeordnet (Guiro, Cuica, …). Für die Percussion-Funktion braucht die App dafür eigene Sounds.

### Grenzen
- Nicht gehört: Die Qualität ist nur gemessen (Konsistenz, Parser), nicht durch Hören bestätigt.
- Bass-Fills: siehe Abschnitt 13. Die App spielt sie inzwischen.
- 19 exportierte Songs haben keinen Bass für Groove A, nur für spätere Parts.
- Konsistenz < 0.35 (unteres Zehntel): Die Quelle variiert stark. Diese Songs zuerst anhören.

## 13. Stand E5 (umgesetzt): Fills und Transition

### Was die App heute nutzt und was für später ist
- **`Transition Bass.mid`** steht in `song.json` als `transitionBass`, **die App spielt ihn schon**. Quelle: echte Part-Wechsel-Takte der MIDI, also der Schlusstakt einer Sektion, nach der ein anderer Part beginnt. Bevorzugt werden Arten mit Bewegung in den neuen Part (pickup, run, octave, drive).
- **`Groove X Fill N Bass.mid`** steht in `layout.parts[].fillBass` (gleiche Reihenfolge wie `fills`, `""` = keine Datei), und **die App spielt ihn**. Nach dem Fill setzt der Part-Bass dort ein, wo die Drums weiterspielen. Ohne Datei läuft der Part-Bass weiter. **`Groove X Fill N Percussion.mid`** nutzt die App noch nicht. In `song.json` → `laneextract.fills` stehen pro Fill die Art, die Häufigkeit in der Quelle und die Datei. Schweigt der Bass im Fill, steht dort `"silent": true` und es gibt keine Datei, weil der App-Parser leere MIDI-Dateien ablehnt.

### Erkennung
1. **Fill-Takte der Quelle:** der letzte Takt jeder Sektion der Part-Gruppe (Sektionen ab 2 Takten). Drum-Fill-Score = Toms (bis 4) + Crash auf der nächsten Eins + Drum-Dichte > 1,3 × Sektions-Median.
2. **Art des Basses im Fill-Takt**, verglichen mit dem Part-Loop:
   | Art | Merkmal |
   |---|---|
   | `same` | ≥ 70 % gleich wie der Loop → kein eigener Fill, der Bass spielt weiter |
   | `dropout` | keine Noten oder nichts mehr ab Taktmitte (Stop-Time) |
   | `hold` | ≤ 2 Noten, eine davon mindestens einen halben Takt lang |
   | `octave` | ≥ 6 Noten, überwiegend Oktavsprünge |
   | `run` | ≥ 5 Noten, überwiegend Halb-/Ganztonschritte |
   | `drive` | ≥ 6 Noten, immer derselbe Ton (Achtel-/16tel-Pumpen) |
   | `pickup` | ≥ 2 verschiedene Töne im letzten Schlag, ein Anlauf in die nächste Eins |
   | `variation` | sonstige Abweichung, nur mit Drum-Fill-Score ≥ 0.3 |
3. Pro Art ein Medoid aus den Quelltakten, die häufigsten Arten zuerst.
4. **Zuordnung zu Fill 1–3 nach Intensitäts-Rang:** Die Factory-Fills steigen nicht immer an (244 steigend, 140 fallend, 67 gemischt), deshalb gehen ruhigste Bass-Variante → dünnster Drum-Fill und intensivste → dichtester. Gibt es weniger Varianten als Fills, gehen sie an die dichtesten Fills. Die übrigen Fills bekommen keinen Fill-Bass, dort spielt der Part weiter.
5. Fill-Percussion: dieselben Takte, nur Instrumente des Part-Percussion-Loops; Arten `dropout` / `variation`.

### Ergebnis (516 MIDIs → 466 Beispiel-Songs)
- **Transition Bass bei 361 Songs:** pickup 150, variation 94, drive 44, hold 34, run 16, octave 15, dropout 8.
- **Fill-Bass bei 393 Songs:** 818 Fills, davon 737 Dateien und 81 „silent“. Arten: variation 251, pickup 233, dropout 116, hold 93, drive 71, run 37, octave 17.
- Fill-Percussion: 106 (dropout 64, variation 42).
- **App-Parser-Test:** 2056 Bass-Dateien in `song.json` (Grooves, Intro, Transition, Ending) und 737 Fill-Bass-Dateien, **0 Probleme**.
- Korrektur während E5: Gleichmäßige Achtel auf einem Ton galten zuerst als „pickup“ (*Livin' on a Prayer*), jetzt sind sie `drive`. Pickup verlangt Tonbewegung im letzten Schlag.

### Grenzen
- Fill-Varianten mit Häufigkeit 1 kommen aus einem einzigen Quelltakt. Typisch für Fills, aber ohne Konsens.
- Fill-Bass ist relativ zum Akkord des Fill-Takts. Der Anlauf zielt nicht explizit auf den Grundton des nächsten Parts, weil der unter Bass Follow live entsteht.
- Nicht gehört.

## 14. Offene Fragen

1. Urheberrecht: nur abstrahierte Templates ausliefern (Abschnitt 5)?
2. Fill-Bass-Default: „Bass läuft unter dem Fill weiter“ bleibt Standard, Fill-Bass nur optional?
3. Weitere MIDIs aus `midi.json` (1871 Songs) nachladen?
