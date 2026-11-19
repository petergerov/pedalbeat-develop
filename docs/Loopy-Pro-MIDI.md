# PedalBeat in Loopy Pro — MIDI-Anleitung

So richtest du PedalBeat als AUv3 in **Loopy Pro** ein und steuerst es mit Fußschalter / MIDI-Controller über die PedalBeat-Befehle.

PedalBeat lauscht auf **jeden MIDI-Kanal**. Noten und CCs unten reichen.

---

## 1. PedalBeat laden

1. In Loopy Pro Mixer: **+** → Instrument / Audio Unit.
2. **PedalBeat** wählen (`aumu` / `pdbt` / `PdBt`).
3. PedalBeat-Fenster öffnen, Song + Kit wählen, kurz antesten (Play in der UI).

PedalBeat braucht Audio-Ausgang im Mixer (wie jedes Instrument).

---

## 2. Fußschalter / Controller an PedalBeat routen

Ziel: MIDI vom Controller kommt **bei PedalBeat an**, nicht nur in Loopy-Bindings.

1. Controller verbinden (Kabel oder **Bluetooth Devices** im Loopy-Menü).
2. Mixer: Controller sollte als **MIDI-Quelle** sichtbar sein. Falls nicht: **+** → **Add MIDI** → dein Gerät.
3. Am Controller-Kanal (oder der MIDI-Zeile) auf das **Destination**-Feld tippen.
4. Als Ziel **PedalBeat** (deine Instanz) setzen.

Mehrere Ziele sind möglich (z. B. Loopy-Clips *und* PedalBeat). Für reine Drum-Steuerung reicht PedalBeat allein.

### Channel-Filter (optional)

Wenn Keys und Pads auf verschiedenen Kanälen laufen:

- Destination-Optionen von PedalBeat öffnen.
- **Channel Filter** auf den Kanal deines Fußschalters setzen (oft Kanal 1).

PedalBeat selbst filtert Kanäle nicht — der Filter ist nur in Loopy.

---

## 3. PedalBeat MIDI-Befehle (Referenz)

### Noten (Note On, Velocity > 0)

| Note (Nummer) | Name (häufig) | Aktion |
|---|---|---|
| **0** | C-1 | **Pedal-Tap** — Start (Intro) · Fill beim Laufen · Resume wenn pausiert |
| **1** | C#-1 | Start / Stop |
| **2** | D-1 | Fill |
| **3** | D#-1 | Transition → nächster Part |
| **4** | E-1 | Outro |
| **5** | F-1 | Sofort Stop |
| **6** | F#-1 | Accent |
| **7** | G-1 | Pause / Resume |
| **8** | G#-1 | Nächster Song |
| **9** | A-1 | Vorheriger Song |

Späte Taps (weniger als ein Beat bis zur Taktgrenze) werden von PedalBeat **in den nächsten Takt geschoben**.

### Continuous Controllers (Wert ≥ 64 = Trigger)

| CC | Aktion |
|---|---|
| **80** | Pedal-Tap (wie Note 0) |
| **81** | Transition / nächster Part |
| **82** | Outro |
| **83** | Accent |
| **84** | Pause / Resume |
| **85** | Stop |

### Sonstiges

| MIDI | Aktion |
|---|---|
| **Program Change** | Song nach Nummer wählen |
| **GM Drum Notes 35–82** | Kit live spielen |
| **Note 88** | Brush Sweep |

Dieselbe Tabelle steht in PedalBeat unter **MIDI & Pedal Help**.

---

## 4. Empfohlene Fußschalter-Belegung

### Ein Taster (wie das große Pedal in der UI)

| Hardware | PedalBeat |
|---|---|
| Tap | **Note 0** oder **CC 80** |
| (Hold / Double-Tap macht PedalBeat nur in der App-UI; per MIDI lieber getrennte Noten) | — |

Mit **nur Note 0** bekommst du: Start → Fills → Resume.  
Transition und Outro brauchst du als **eigene** MIDI-Noten (3 und 4).

### Zwei Taster (typisch)

| Fuß | MIDI | Aktion |
|---|---|---|
| Links – kurz | Note **0** | Tap / Fill |
| Rechts – kurz | Note **3** | Transition / Next Part |
| Rechts – lang oder dritter Taster | Note **4** | Outro |

### Drei Taster

| Fuß | Note | Aktion |
|---|---|---|
| 1 | **0** | Tap / Fill |
| 2 | **3** | Transition |
| 3 | **4** | Outro |

Optional: Note **7** Pause, Note **1** Start/Stop, Note **6** Accent.

Stelle am Controller ein, dass die Pads/Switches **Note 0–9** senden (nicht C3/C4), oder nutze einen MIDI-Remapper (z. B. StreamByter) zwischen Controller und PedalBeat.

---

## 5. Controller sendet „falsche“ Noten → remappen

Viele Fußcontroller senden z. B. C3 (Note 60) statt Note 0.

**Option A — am Controller:** MIDI-Note auf 0, 3, 4 … stellen (falls möglich).

**Option B — StreamByter (kostenlos) in Loopy:**

1. Mixer **+** → **Add MIDI** → **StreamByter**.
2. Controller-Destination = **StreamByter**.
3. StreamByter-Destination = **PedalBeat**.
4. In StreamByter z. B.:

```
# Beispiel: Note 60 → Pedal-Tap (0), Note 62 → Transition (3), Note 64 → Outro (4)
IF LOAD
  ASS 0 = 0
IF NOTE ON 60 +
  SEND NOTE ON 0 $VEL
  SEND NOTE OFF 0 0
  BLOCK
IF NOTE ON 62 +
  SEND NOTE ON 3 $VEL
  SEND NOTE OFF 3 0
  BLOCK
IF NOTE ON 64 +
  SEND NOTE ON 4 $VEL
  SEND NOTE OFF 4 0
  BLOCK
```

(An deine echten Controller-Noten anpassen; Syntax ggf. in der StreamByter-Doku prüfen.)

---

## 6. On-Screen-Buttons in Loopy → PedalBeat

Wenn du Loopy-**Widgets** (Pads) statt Hardware nutzen willst:

1. Widget anlegen (Pad).
2. Action: **Send MIDI Message**.
3. Destination: **PedalBeat**.
4. Message: **Note On**, Note **0** (Tap), Velocity z. B. 100; bei Release optional Note Off.
5. Weitere Pads für Note **3** (Transition), **4** (Outro), …

So steuerst du PedalBeat direkt, ohne Loopy-MIDI-Learn auf AU-Parameter (Pedal-Befehle sind **keine** AU-Parameter, sondern MIDI-Noten/CCs).

---

## 7. Tempo mit Loopy syncen

In PedalBeat:

- **Sync tempo to host** an — folgt Loopy’s Projekt-Tempo.
- Optional **Start/stop with host**, wenn Transport mitlaufen soll.

Loopy: Projekt-BPM setzen; PedalBeat spielt im gleichen Grid.

---

## 8. Kurzer Check

1. PedalBeat geladen, Song gewählt.  
2. Controller → Destination PedalBeat.  
3. Note **0** senden → Intro startet.  
4. Nochmal Note **0** → Fill.  
5. Note **3** → Transition / nächster Part.  
6. Note **4** → Outro.

Wenn nichts passiert: Destination prüfen, Channel Filter, ob Noten wirklich 0–9 sind (MIDI-Monitor / StreamByter), Velocity > 0.

---

## Siehe auch

- PedalBeat UI: **MIDI & Pedal Help**
- Loopy Wiki: [MIDI Essential Tips](https://wiki.loopypro.com/MIDI_Essential_Tips_and_Tricks), [MIDI Learn](https://wiki.loopypro.com/Getting_Started_With_MIDI_Learn)
