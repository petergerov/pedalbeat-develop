# PedalBeat in Loopy Pro — MIDI-Anleitung

So richtest du PedalBeat als AUv3 in **Loopy Pro** ein und steuerst es mit Fußschalter / MIDI-Controller über die PedalBeat-Befehle.

PedalBeat lauscht auf **jeden MIDI-Kanal**. Welcher Schalter was auslöst, legst du in PedalBeat unter **MIDI Settings** per **Learn** fest; ohne eigene Belegung gelten die Noten 0–9 (Abschnitt 3).

---

## 1. PedalBeat laden

1. In Loopy Pro Mixer: **+** → Instrument / Audio Unit.
2. **PedalBeat** wählen (`aumu` / `pdbt` / `PdBt`).
3. PedalBeat-Fenster öffnen, Song + Kit wählen, kurz antesten (Play in der UI).

PedalBeat braucht Audio-Ausgang im Mixer (wie jedes Instrument).

---

## 2. Fußschalter / Controller an PedalBeat routen

Ziel: MIDI vom Controller kommt **bei PedalBeat an**, nicht nur in Loopy-Bindings.

1. Controller verbinden (Kabel oder **Bluetooth Devices** im Loopy-Menü; in PedalBeat auch unter **MIDI Settings → Connect Bluetooth MIDI Device**).
2. Mixer: Controller sollte als **MIDI-Quelle** sichtbar sein. Falls nicht: **+** → **Add MIDI** → dein Gerät.
3. Am Controller-Kanal (oder der MIDI-Zeile) auf das **Destination**-Feld tippen.
4. Als Ziel **PedalBeat** (deine Instanz) setzen.

Mehrere Ziele sind möglich (z. B. Loopy-Clips *und* PedalBeat). Für reine Drum-Steuerung reicht PedalBeat allein.

### Channel-Filter (optional)

Wenn Keys und Pads auf verschiedenen Kanälen laufen:

- Destination-Optionen von PedalBeat öffnen.
- **Channel Filter** auf den Kanal deines Fußschalters setzen (oft Kanal 1).

PedalBeat selbst filtert Kanäle nicht — der Filter ist nur in Loopy.

### Schalter zuweisen (MIDI Settings)

Du musst den Controller nicht auf bestimmte Noten umstellen:

1. In PedalBeat **MIDI Settings** öffnen (unten, neben **Help**).
2. Bei der Aktion (z. B. **Pedal Tap**) auf **Learn** tippen.
3. Den Fußschalter, die Taste oder das Pad drücken — Note, CC oder Program Change, jeder Kanal.

Dieser Druck legt nur die Belegung fest und löst nichts aus. **Last Received** zeigt, was bei PedalBeat ankommt; steht dort nichts, stimmt das Routing oben noch nicht. Zeile wischen (am Mac: Rechtsklick) → **Clear** entfernt eine Belegung, **Reset to Defaults** stellt die Noten 0–9 wieder her. Die Belegung gilt für alle Projekte und Hosts auf dem Gerät.

---

## 3. PedalBeat MIDI-Befehle (Standardbelegung)

### Noten (Note On, Velocity > 0)

| Note (Nummer) | Name in PedalBeat | Aktion |
|---|---|---|
| **0** | C-2 | **Pedal-Tap** — Start (Intro) · Fill beim Laufen · Resume wenn pausiert |
| **1** | C#-2 | Start / Stop |
| **2** | D-2 | Fill |
| **3** | D#-2 | Transition → nächster Part |
| **4** | E-2 | Outro |
| **5** | F-2 | Sofort Stop |
| **6** | F#-2 | Accent |
| **7** | G-2 | Pause / Resume |
| **8** | G#-2 | Nächster Song |
| **9** | A-2 | Vorheriger Song |

PedalBeat benennt Noten wie Logic und GarageBand (Note 60 = C3). Viele Controller und Apps zählen eine Oktave höher und nennen Note 0 „C-1“ — entscheidend ist die Nummer.

Späte Taps (weniger als ein Beat bis zur Taktgrenze) werden von PedalBeat **in den nächsten Takt geschoben**.

### Control Changes

CC 80–85 sind nicht mehr vorbelegt. Sendet dein Fußschalter CCs, weise sie per **Learn** zu. Ein Schalter, der beim Drücken 127 und beim Loslassen 0 sendet, löst nur beim Drücken aus. Sendet ein Pedal pro Druck nur einen Wert unter 64, erkennt Learn das, und jeder Druck löst aus.

### Sonstiges

| MIDI | Aktion |
|---|---|
| **Program Change** | Song nach Nummer wählen (0 = erster Song); in MIDI Settings abschaltbar |
| **GM Drum Notes 35–82** | Kit live spielen |
| **Note 88** | Brush Sweep |

Eine Note, die du einer Aktion zuweist, spielt keinen Drum-Sound mehr. Ein per Learn zugewiesener Program Change löst immer seine Aktion aus statt einen Song zu wählen. Die Standardbelegung steht auch in PedalBeat unter **Help**.

---

## 4. Empfohlene Fußschalter-Belegung

### Ein Taster (wie das große Pedal in der UI)

| Hardware | PedalBeat |
|---|---|
| Tap | **Note 0** (oder per Learn jeder andere Schalter) |
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

Die Tabellen gehen von der Standardbelegung aus. Sendet dein Controller andere Noten oder CCs, weise die Aktionen per **Learn** deinen Schaltern zu (Abschnitt 2).

---

## 5. Controller sendet „falsche“ Noten → remappen

Viele Fußcontroller senden z. B. C3 (Note 60) statt Note 0.

**Option A — Learn in PedalBeat (am einfachsten):** **MIDI Settings** → bei der Aktion **Learn** → Schalter drücken. Am Controller musst du nichts ändern.

**Option B — am Controller:** MIDI-Note auf 0, 3, 4 … stellen (falls möglich).

**Option C — StreamByter (kostenlos) in Loopy,** wenn du MIDI umbauen willst, bevor es PedalBeat erreicht:

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

Andere Nachrichten gehen auch: Pad einmal antippen, während in PedalBeat **Learn** wartet.

So steuerst du PedalBeat direkt, ohne Loopy-MIDI-Learn auf AU-Parameter (Pedal-Befehle sind **keine** AU-Parameter, sondern MIDI-Noten/CCs).

---

## 7. Tempo mit Loopy syncen

### Loopy → PedalBeat (Host ist Master)

In PedalBeat:

- **Sync tempo to host** an — folgt Loopy’s Projekt-Tempo.
- Optional **Start/stop with host**, wenn Transport mitlaufen soll.

Loopy: Projekt-BPM setzen; PedalBeat spielt im gleichen Grid.

### PedalBeat → Loopy (Song setzt das Tempo über MIDI Clock)

Die Host-API liefert Tempo nur vom Host zum Plugin. PedalBeat kann aber **MIDI Clock** auf seinem MIDI-Out senden; Loopy folgt dem.

**Einmal einrichten**

1. In PedalBeat **Sync tempo to host** **aus** (im Tab **Songs** beim Laden schon so).
2. **MIDI Clock Out** **an**.
3. In Loopy Mixer: **+** → **Add MIDI** → Instanz **PedalBeat** (MIDI-Out der AU).
4. Loopy-Uhr / Sync → **MIDI Clock Source** = diese PedalBeat-Quelle (andere Quellen aus).
5. Optional **Sync Start/Stop**, damit Loopy mit PedalBeat startet und stoppt.

**Nutzen:** Song wählen → Pedal tippen → PedalBeat sendet Start + 24 PPQN; Loopy übernimmt das Tempo. Pause = Stop, Resume = Continue.

**Wichtig:** Nicht gleichzeitig **Sync tempo to host** und Loopy-Follow auf PedalBeat-Clock — sonst Feedback-Schleife.

---

## 8. Kurzer Check

1. PedalBeat geladen, Song gewählt.  
2. Controller → Destination PedalBeat.  
3. Note **0** senden → Intro startet.  
4. Nochmal Note **0** → Fill.  
5. Note **3** → Transition / nächster Part.  
6. Note **4** → Outro.

Wenn nichts passiert: In PedalBeat **MIDI Settings** öffnen und auf **Last Received** schauen. Kommt nichts an → Destination und Channel Filter prüfen. Kommt etwas an → Belegung prüfen oder den Schalter per **Learn** zuweisen.

---

## Siehe auch

- PedalBeat UI: **MIDI Settings** (Belegung, Learn, Last Received) und **Help**
- Loopy Wiki: [MIDI Essential Tips](https://wiki.loopypro.com/MIDI_Essential_Tips_and_Tricks), [MIDI Learn](https://wiki.loopypro.com/Getting_Started_With_MIDI_Learn)
