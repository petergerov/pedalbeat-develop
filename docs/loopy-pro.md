# How to use PedalBeat in Loopy Pro

Step-by-step setup: load PedalBeat as an AUv3, route a footswitch to it, assign buttons with Learn, and sync tempo.

PedalBeat listens on **every MIDI channel**. What each button does is set in PedalBeat → **MIDI Settings** with **Learn**. Until you change that, notes **0–9** are the defaults (see step 5).

---

## 1. Load PedalBeat

1. Open **Loopy Pro**.
2. In the mixer, tap **+** → **Instrument** / **Audio Unit**.
3. Choose **PedalBeat** (`aumu` / `pdbt` / `PdBt`).
4. Open the PedalBeat window.
5. Pick a **song** and a **kit**, then tap the on-screen pedal once so you hear drums.

PedalBeat needs a mixer output like any other instrument.

---

## 2. Connect your footswitch or controller

1. Plug in USB, or pair Bluetooth:
   - Loopy menu → **Bluetooth Devices**, or
   - PedalBeat → **MIDI Settings** → **Connect Bluetooth MIDI Device** (iPad/iPhone).
2. In the Loopy mixer, your controller should appear as a **MIDI source**.  
   If it doesn’t: mixer **+** → **Add MIDI** → pick the device.
3. On that MIDI row, tap **Destination**.
4. Set the destination to **PedalBeat** (your instance).

You can also send to Loopy clips *and* PedalBeat. For drums only, PedalBeat alone is enough.

### Optional: channel filter

If keys and pads share one device on different channels:

1. Open PedalBeat’s destination options in Loopy.
2. Set **Channel Filter** to your footswitch channel (often channel 1).

PedalBeat itself does not filter channels — Loopy does.

---

## 3. Assign buttons with Learn (recommended)

You do **not** need to reprogram the controller to notes 0–9.

1. In PedalBeat, open **MIDI Settings** (bottom row, next to **Help**).
2. Tap **Learn** on an action (e.g. **Pedal Tap**).
3. Press the footswitch, key, or pad you want.  
   Note, Control Change, or Program Change — any channel.
4. The row shows what you assigned (e.g. `Note 60 (C3)` or `CC 64`).
5. Repeat for **Transition / Next Part**, **Outro**, and anything else you need.

While Learn is waiting, that press is **not** played as a command or a drum hit.

**Last Received** shows the last message that reached PedalBeat. If it stays empty, fix the destination in step 2 before Learning again.

- Swipe a row (Mac: right-click) → **Clear** to remove one assignment.
- **Reset to Defaults** restores notes 0–9.
- Mappings are saved on the device for every project and every host.

---

## 4. Quick check

With a song loaded and MIDI routed to PedalBeat:

| Do this | Expected |
|---|---|
| Pedal Tap (default note **0**, or your Learned switch) | Intro starts |
| Pedal Tap again while playing | Fill |
| Transition (default note **3**) | Transition → next part |
| Outro (default note **4**) | Outro, then stop |

If nothing happens:

1. Open **MIDI Settings** and watch **Last Received**.
2. Nothing arrives → Loopy destination / channel filter.
3. Something arrives → Learn that switch to the action you want.

---

## 5. Default MIDI map (if you don’t use Learn)

Note On, velocity &gt; 0. PedalBeat labels notes like Logic (note 60 = C3).

| Note | Name | Action |
|---|---|---|
| **0** | C-2 | **Pedal Tap** — start (intro) · fill while playing · resume when paused |
| **1** | C#-2 | Start / Stop |
| **2** | D-2 | Fill |
| **3** | D#-2 | Transition / next part |
| **4** | E-2 | Outro |
| **5** | F-2 | Stop now |
| **6** | F#-2 | Accent |
| **7** | G-2 | Pause / Resume |
| **8** | G#-2 | Next song |
| **9** | A-2 | Previous song |

A late tap (less than a beat left in the bar) is queued for the next downbeat.

| Other MIDI | Behavior |
|---|---|
| **Program Change** *n* | Select song *n* (0 = first). Toggle off in MIDI Settings if you don’t want that. |
| **GM drum notes 35–82** | Play the kit live |
| **Note 88** | Brush sweep |

A note assigned to an action no longer plays a drum sound. A Program Change assigned with Learn always runs that action instead of selecting a song.

CC 80–85 are **not** defaults anymore — assign CCs with Learn if your pedal sends them.

---

## 6. Suggested footswitch layouts

Defaults below; with Learn, use whatever messages your hardware already sends.

### One switch

| Press | Action |
|---|---|
| Tap | Pedal Tap (start → fills → resume) |

Hold / double-tap exist only on the **on-screen** pedal. Over MIDI, use separate switches for Transition and Outro.

### Two switches

| Foot | Action |
|---|---|
| Left | Pedal Tap |
| Right | Transition / next part |
| Right (or third switch) | Outro |

### Three switches

| Foot | Action |
|---|---|
| 1 | Pedal Tap |
| 2 | Transition |
| 3 | Outro |

Optional extras: Pause / Resume, Start / Stop, Accent.

---

## 7. Loopy on-screen pads → PedalBeat

1. Add a Loopy **widget** (pad).
2. Action: **Send MIDI Message**.
3. Destination: **PedalBeat**.
4. Message: **Note On**, note **0** (or any note), velocity e.g. 100.  
   Or tap the pad once while PedalBeat **Learn** is armed for that action.
5. Add more pads for Transition, Outro, etc.

Pedal commands are MIDI messages, not AU parameters — don’t use Loopy’s parameter MIDI Learn for Tap / Fill / Transition.

---

## 8. Sync tempo with Loopy

### Loopy → PedalBeat (host is master)

In PedalBeat:

1. Turn on **Sync tempo to host** — PedalBeat follows Loopy’s project BPM.
2. Optionally turn on **Start/stop with host** so PedalBeat follows Loopy transport.

Set the project tempo in Loopy; PedalBeat stays on the same grid.

### PedalBeat → Loopy (song sets the tempo via MIDI Clock)

Apple’s AU API only sends tempo *from* the host *to* the plugin, so PedalBeat cannot set Loopy’s BPM as a parameter. Instead PedalBeat can send **MIDI Clock** on its MIDI out; Loopy follows that clock.

**Setup (once per project)**

1. In PedalBeat, turn **Sync tempo to host** **off**.  
   (Loading a song from the **Songs** tab already turns it off and sets PedalBeat to that song’s BPM.)
2. Turn **MIDI Clock Out** **on**.
3. In Loopy’s mixer: **+** → **Add MIDI** → choose the **PedalBeat** instance (its MIDI out; may show as a lettered instance).
4. Loopy menu / clock → **MIDI Clock** → set **Clock Source** to that PedalBeat MIDI source.  
   Turn off other clock sources so only PedalBeat drives the clock.
5. Optional: enable **Sync Start/Stop** on that source so Loopy’s transport follows PedalBeat Start/Stop.

**In use**

1. Pick a song in PedalBeat (BPM updates).
2. Tap the pedal (or send Pedal Tap) — PedalBeat sends MIDI **Start** + 24 PPQN clock at the song tempo.
3. Loopy’s project tempo follows. Pause sends **Stop**, resume sends **Continue**, full stop sends **Stop**.

**Avoid a feedback loop:** do not leave **Sync tempo to host** on while Loopy is also following PedalBeat’s MIDI Clock.

**Manual fallback:** turn Clock Out off, read PedalBeat’s BPM, tap Loopy’s tempo display and type the same number.

---

## 9. Bass Follow (guitar → bass)

PedalBeat can transpose the bass line to the chords you play on guitar.

### Loopy Pro

1. Load PedalBeat as an instrument and pick a **Bass & Drums** song (written in E).
2. Route your guitar (or a clean DI / send) into PedalBeat’s **Guitar** input / sidechain.
3. Turn **Bass Follow** on. Status shows `FOLLOW` + chord; **GTR** when input is live.
4. Chord changes land on the next beat. Prefer a clean DI/send over heavy distortion.

### MainStage / Logic Pro (Mac) — use the FX plug-in

Apple hosts usually **do not show Side Chain** on PedalBeat as a Software Instrument. Use the Music Effect instead:

1. **Audio** channel (live guitar or DI), not an Instrument slot.
2. Insert slot → Audio Units → PedalBeat → **PedalBeat Drums FX**.
3. Assign MIDI to that channel for the pedal.
4. Turn **Bass Follow** on. Status shows **GTR** when guitar audio is arriving; guitar is passed through under the drums.

(Instrument + Side Chain may appear on some hosts/versions, but do not rely on it.)

**MIDI fallback (all hosts):** chord notes on any channel except 10 also drive Bass Follow.

---

## 10. If your controller sends “wrong” notes

Many pedals send e.g. C3 (note 60) instead of note 0.

1. **Easiest:** MIDI Settings → **Learn** → press the switch. Done.
2. Or reprogram the controller to notes 0, 3, 4…
3. Or insert **StreamByter** in Loopy (Controller → StreamByter → PedalBeat) and remap there — only needed if you want the same map for other apps.

---

## See also

- PedalBeat: **MIDI Settings** (Learn, Last Received) and **Help**
- German MIDI notes: [Loopy-Pro-MIDI.md](Loopy-Pro-MIDI.md)
- Chord follow plan: [chord-follow-plan.md](chord-follow-plan.md)
- Loopy wiki: [MIDI Essential Tips](https://wiki.loopypro.com/MIDI_Essential_Tips_and_Tricks), [MIDI Learn](https://wiki.loopypro.com/Getting_Started_With_MIDI_Learn)
