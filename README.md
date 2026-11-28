# PedalBeat

An original pedal-style drum machine for macOS and iPadOS/iOS. It ships as an **AUv3 instrument** (`aumu` / `pdbt` / `PdBt`) plus a standalone app.

## Features
- **Song structure**: intro, up to 8 parts with up to 8 fills each, a transition fill, an outro and an accent hit. Fills play in order or at random (never the same fill twice in a row). The display shows which fill is playing, e.g. "FILL 2/3".
- **Pedal**: tap starts the song (intro first), plays a fill, or resumes after pause. Hold for a transition to the next part. Double-tap for the outro. A press with less than a beat left in the bar is queued for the next downbeat.
- **Other controls**: start/stop, pause, jump to a part, previous/next song, tap tempo, sync tempo to the host, start/stop with the host.
- **177 original songs** in 19 genres, in 4/4, 12/8, 3/4, 6/8, 5/4 and 7/8. The three **Bass & Drums** songs add a bass line.
- **Bass**: a song can carry a bass line, played by a built-in synth bass, with a level and a mute next to Volume (host parameters Bass Volume and Mute Bass). Under fills the bass keeps playing the part's groove, so the song never drops out. Transitions and the ending play their own bass line when they have one; otherwise the part's bass keeps going. Imported MIDI brings its bass along, either from a groove file (a GM bass program, a track named bass, or a low part next to channel 10) or from separate “… Bass.mid” files next to the grooves (“Verse Bass.mid” goes with “Verse.mid”, “Ending Bass.mid” with the ending).
- **Find a beat by song**: the **Songs** tab lists 1,926 popular songs with their tempo. Search by title or artist, filter by genre, and tap a song to load its beat at the song's tempo (the display shows "♪ title"; host tempo sync is turned off, like tap tempo). Songs play the original beat the index names when your `.BBS` content is imported (see below), otherwise the closest PedalBeat groove (marked ≈). Regenerate the index with `Tools/SongIndex/generate.py`.
- **`.BBS` content**: import a drum-pedal SD card or project folder with `.BBS` song files like any folder. Every `.BBS` song becomes a song in a "BBS › Genre" group with its intro, parts, fills, transition and ending, time signature and tempo. Half-bar fills are lined up to end on the bar line, as on the pedal. PedalBeat keeps one transition per song (the first part's). Drum sounds (`.DRM`) are not imported; the beats play with PedalBeat kits. To get the songs as editable MIDI files, run `swiftc -O Core/*.swift Core/*/*.swift Tools/BBSongExport/main.swift -o build/bbsongexport && ./build/bbsongexport <content folder> bbsongs`: it writes `bbsongs/<Genre>/<NN Song>/` with `.mid` files and a `song.json`, and importing `bbsongs/` gives the same "BBS › Genre" songs. Keep the content folder and `bbsongs/` outside the repo.
- **Synthesized kits**: Studio, Vintage, Electro, Lo-Fi and Brushes, with no sample files. Swing, humanize and volume controls.
- **Sampled kits** (`.pbkit`): import multi-velocity acoustic kits with alternate takes per hit. Open-licensed kits in `kits/` include Jazz, Brushes, Studio Acoustic, Big Room, **Cajón**, Bobobo, and several **Body Percussion** variants (Stomp / Hands / Chest / Stereo). See `kits/README.md` for credits and how to rebuild them.
- **Mix Song**: like Edit Song — button / context menu opens a full mixer console with vertical faders per voice. Levels are stored per song.
- **Multi-out + real AU plugins**: the AUv3 exposes stereo buses Master / Kick / Snare / Hats / Toms / Cymbals / Perc so a DAW can insert real AU/AUv3 effects per group. Nesting plugins *inside* the PedalBeat appex is not supported. The **macOS standalone** app can load AU/AUv3 effect inserts on the master out (**AU Inserts…**).
- **Bass Follow (beta)**: the bass follows the chords you play, from MIDI chord notes or guitar audio (PedalBeat Drums FX on the guitar track, or Side Chain). Experimental: detection can be wrong or late, especially with distorted guitar.
- **MIDI in**: pedal commands (notes 0–9 by default; assign any note, CC or program change in **MIDI Settings** with Learn), program change to pick a song, and GM drum notes to play the kit live. Note 88 plays a brush sweep.
- **Brush sweeps**: a continuous stir that lasts until the next sweep or for two beats, then releases. Used in the jazz brush grooves, and played by the Brush Kit and the synthesized Brushes kit.
- **MIDI out**: every drum hit is sent on channel 10, to drive an external drum module, and the bass line on channel 2 (also when the bass is muted). Optional **MIDI Clock Out** (Start/Stop/Continue + 24 PPQN) so Loopy Pro can follow PedalBeat’s song tempo when Sync tempo to host is off.
- **Factory songs as MIDI**: `songs/<Genre>/<NN Title>/` holds every factory song as `.mid` files plus a `song.json` with the exact layout. Importing that folder recreates the songs exactly. See `songs/README.md`.
- **Import whole MIDI folders** (loop packs): every `Pack/Style` folder becomes a group in the song browser and deeper folders become songs. Loose files in a folder are grouped into songs by name and tempo. Sections (intro, verse, pre-chorus, chorus, bridge, fills, transition, ending) are recognized from file names, and fills go to the matching section. Imports are kept in a shared user library on disk. Right-click a group to remove it.
- **Song editor** for every song: right-click a song and choose **Edit Song…**, or use the Edit Song button. Factory songs open as MIDI files (Intro, Groove A–H, Groove A Fill 1…, Groove A Bass…, Transition, Ending). When you save, your version replaces the factory song in its group, marked with a pencil. **Revert to Factory Version** brings the original back, and cancelling leaves the song untouched. The conversion is lossless: all 177 factory songs round-trip note for note, including swing, pattern lengths, crash settings and bass lines. Choose which file plays as intro, each part's groove, its fills (up to 8, in order), the transition and the ending, by dragging files or using menus. Songs with a bass line also get a bass slot per part and under intro, transition and ending, plus a Bass switch. You can also add, remove and reorder parts, rename the song, or reset it to the automatic layout. Press ▶ on any file to listen to it with the current kit and tempo: grooves loop, fills, intros and endings play once. Edited songs keep their identity, so projects that use them load the edited version.
- **Import your own MIDI grooves**: use the button or drag and drop. File names containing intro, fill, trans or outro are sorted into the right song sections. Imported songs are saved with the host project.

## Build
```sh
brew install xcodegen
xcodegen generate
open PedalBeat.xcodeproj          # schemes: PedalBeat-macOS, PedalBeat-iOS
```
Run the app once and the AU appears in Logic, GarageBand, MainStage, AUM and other hosts. Check it with `auval -v aumu pdbt PdBt`.

## Engine tests
```sh
swiftc -O Core/*.swift Core/*/*.swift Tools/RenderTest/main.swift -o build/rendertest
./build/rendertest build/test kits   # validates every song and kit, renders demo WAVs
```
Set `BBS_CONTENT=<content folder>` to also test the `.BBS` import.

## Layout
- `Core/`: drum synth, sequencer and pedal state machine, song store, groove library, MIDI import. Pure Swift and safe to run on the audio thread.
  - `Core/Bass/`: the bass track: synth bass (`BassSynth`) and the generated bass lines (`BassGenerator`).
  - `Core/BassFollow/`: Bass Follow (beta), transposing the bass to live chords from MIDI or guitar audio (chord detection, chord models, Solitito ONNX). The rest of PedalBeat only talks to `BassFollow`.
- `Extension/`: the AUAudioUnit subclass and its SwiftUI interface.
- `Tools/KitBuilder/`: renders SFZ drum libraries into `.pbkit` kits, and `extract` unpacks a `.pbkit` to WAV + `kit.json`.
- `Tools/BBKitBuilder/`: packs decoded drumsets (`drumsets-decoded/`) into `.pbkit` files in `bb-kits/`.
  `build-cajon3-kits.py` stages the kits made from World Percussion samples (Cajón 3 WP, Layer World with its
  prepared WP shaker) in `pedalbeat-data/build/kit-staging/` for it.
- `Tools/SideChainProbe/`: hosts the installed AU through the AUv2 API like Logic does and feeds its track and Side Chain inputs, to check that Bass Follow gets audio.
- `kits/`: ready-to-import sampled kits.
- `songs/`: the factory songs as MIDI files (one folder per song, with `song.json`). Regenerate with `Tools/SongExport`.
- `App/`: standalone host (AVAudioEngine, with hardware MIDI input for footswitches).
