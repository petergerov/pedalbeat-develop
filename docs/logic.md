# PedalBeat in Logic Pro: multi-output with AU effects

PedalBeat can send each drum group to its own channel in Logic, so you can put different AU effects on the kick, snare, hats and so on. You can't load AU effects *inside* PedalBeat; Logic's own effect slots do that job.

## The outputs

PedalBeat has 7 stereo outputs:

| Logic output | PedalBeat output | What plays on it |
|---|---|---|
| 1-2 | **Master** | The **full mix** (every drum) |
| 3-4 | Kick | Kick |
| 5-6 | Snare | Snare, rim, clap |
| 7-8 | Hats | Closed, pedal and open hi-hat |
| 9-10 | Toms | High, mid and low tom |
| 11-12 | Cymbals | Ride, ride bell, crash |
| 13-14 | Perc | Cowbell, shaker, tambourine, brush sweep |

> **Important:** Master always carries the full mix, and the other six outputs carry *copies* of their drums. If Master and the group outputs all play at the same time, you hear every drum twice. Turn the Master channel down (step 3) when you mix with the group channels.

The **Volume** setting in PedalBeat and the per-voice levels from **Mix Song** apply to all outputs. The tone filter of the synthesized kits Vintage, Lo-Fi and Brushes applies only to Master, so those kits sound brighter on the group outputs.

---

## 1. Load PedalBeat with multiple outputs

1. Run the PedalBeat app once after installing it, so macOS registers the plug-in.
2. In Logic, create a **Software Instrument** track.
3. Click the **Instrument** slot and choose **AU Instruments → PedalBeat → PedalBeat Drums → Multi Output (7xStereo)**. The exact wording may differ slightly between Logic versions. Choosing **Stereo** gives you only the Master output.
4. In the PedalBeat window, choose a song and kit.

## 2. Add a channel for each output

1. Open the **Mixer** (`X`).
2. On the PedalBeat channel strip, click the small **+** button below Mute/Solo. Each click adds an **Aux** channel for the next output pair (3-4, then 5-6, and so on).
3. Click it 6 times to get Kick, Snare, Hats, Toms, Cymbals and Perc.
4. Double-click each aux's name and rename it after its output, as in the table above.

You can also add an aux yourself and set its **Input** to the PedalBeat output pair you want.

To automate an aux or see it in the Tracks area, Control-click it in the Mixer and choose **Create Track**.

## 3. Turn down the Master channel

The PedalBeat instrument channel plays output 1-2, the full mix. When you mix with the group auxes:

- pull the instrument channel's fader all the way down (−∞), **or**
- use it on purpose as a **parallel bus**: put a heavy compressor on it and blend it in quietly under the group channels.

The aux channels keep playing either way, because they are fed directly by PedalBeat's outputs, not by the instrument channel's fader.

## 4. Add AU effects to each group

Put effects in each aux channel's **Audio FX** slots, just as on any audio track. Some starting points:

| Channel | Example effects |
|---|---|
| Kick | Channel EQ (low boost around 60 Hz, cut around 300 Hz) → Compressor |
| Snare | Channel EQ → Compressor → send to a reverb |
| Hats | Channel EQ high-pass around 300 Hz, a little saturation |
| Toms | Channel EQ → Compressor → send to the reverb |
| Cymbals | Channel EQ high-pass, little or no compression |
| Perc | Stereo delay or reverb send |

Any AU effect works here: Logic's own or third-party AU/AUv3 plug-ins.

### Shared reverb

1. On the Snare aux, click a **Send** slot and choose a bus, for example **Bus 1**. Logic creates a new aux for that bus.
2. Put a reverb (for example **ChromaVerb** or **Space Designer**) on that new aux, set to 100 % wet.
3. Use the same bus on the Toms and Perc auxes, with a different send level on each.

## 5. Tempo and transport

In the PedalBeat window or under **Controls** in the plug-in header, turn on:

- **Sync Tempo to Host**: PedalBeat follows Logic's tempo.
- **Start/Stop with Host**: PedalBeat starts and stops with Logic's transport.

## 6. Control PedalBeat from Logic

PedalBeat listens on every MIDI channel. In a MIDI region on the PedalBeat track, or from a footswitch or controller routed to that track:

| Note | Logic name | Action |
|---|---|---|
| 0 | C-2 | Pedal tap: start (intro), fill while playing, resume when paused |
| 1 | C#-2 | Start / stop |
| 2 | D-2 | Fill |
| 3 | D#-2 | Transition to the next part |
| 4 | E-2 | Outro |
| 5 | F-2 | Stop now |
| 6 | F#-2 | Accent |
| 7 | G-2 | Pause / resume |
| 8 | G#-2 | Next song |
| 9 | A-2 | Previous song |

Logic names middle C (note 60) "C3", so note 0 is "C-2".

- **CC 80–85** (value 64 or more): 80 pedal tap, 81 transition, 82 outro, 83 accent, 84 pause/resume, 85 stop.
- **Program change**: chooses the song.
- **GM drum notes** (e.g. 36 kick, 38 snare, 42 hi-hat) play the kit live, and they go to the matching group outputs too.

A tap that arrives with less than a beat left in the bar is played on the next downbeat.

## 7. Record each group as audio (stems)

1. Set an aux's **Output** to an unused bus, for example **Bus 10**.
2. Create an audio track with **Input: Bus 10** and record-enable it.
3. Do the same for each group, then record. Each audio track records one group.

## Troubleshooting

- **No "Multi Output" choice, only Stereo:** open **Logic Pro → Settings → Plug-in Manager**, select PedalBeat and click **Reset & Rescan Selection**, then restart Logic. Logic also needs restarting after you install a new PedalBeat version.
- **PedalBeat isn't listed at all:** run the PedalBeat app once, then check it in Terminal with `auval -v aumu pdbt PdBt`.
- **Drums sound doubled or too loud:** the Master channel (output 1-2) is still up; see step 3.
- **An aux is silent:** check that its Input is a PedalBeat output pair, and that the current song or kit uses drums from that group.
