# Song-Pack: Songs mit eigenen Drums, Bass und Percussion

Stand: 23.11.2026. Hier steht alles, was es braucht, um die mitgelieferten Songs neu zu erstellen und auszuliefern, plus die offenen Punkte.

## 1. Was der Nutzer bekommt

- **Ohne Import:** Im Songs-Tab spielen rund 930 bekannte Songs ihre **eigenen Drums** (Groove A/B, Fills, Intro, Ending).
- **Bass:** Dazu meist eine **Basslinie** (856 Songs) im Grundton der Songtonart. Bass Follow transponiert von dort.
- **Percussion:** Wo vorhanden, kommt die **Percussion** dazu: Shaker, Tambourin, Clap (356 Songs).
- **Installer (macOS):** `Tools/package-macos.sh` baut signierte `.pkg`-Installer, die alles **fertig installieren**, ohne Import: `PedalBeat-<v>.pkg` (App nach `/Applications`), `PedalBeat-MIDI-Songs-<v>.pkg`, `PedalBeat-bb-Songs-<v>.pkg`, `PedalBeat-Kits-<v>.pkg` (14 Kits aus `pedalbeat-data/kits`, mit Credits), `PedalBeat-bb-Kits-<v>.pkg` (12 Kits aus `pedalbeat-data/bb-kits`) und `PedalBeat-Complete-<v>.pkg` mit allen (einzeln abwählbar). Inhalte landen in `/Library/Application Support/PedalBeat` (`Songs/*.pbcp`, `Kits/*.pbkit`; `InstalledContent`). App und Plug-in lesen den Ordner beim Start, sandboxed über die Entitlement-Ausnahme `com.apple.security.temporary-exception.files.absolute-path.read-only` (in `project.yml`). Installierte Kits stehen im Kit-Menü, sind aber nicht löschbar (ein Import derselben Kit-ID ersetzt sie). Song-Pakete laden der Reihe nach; ein Song oder eine Percussion-Spur, die schon geladen ist, wird übersprungen. Der Import bleibt für eigene MIDI-Dateien, .BBS-Karten und Kits. `NOTARIZE=1` notarisiert alle Installer, `COPY_BBS=0` / `COPY_KITS=0` lassen Teile weg. **Deinstallation:** `PedalBeat-Uninstall-<v>.pkg` (ohne Payload, nur Skripte aus `Tools/uninstall/`) entfernt `/Applications/PedalBeat.app` (nur mit Bundle-ID `com.pedalbeat.app`), `/Library/Application Support/PedalBeat` und die Installer-Belege und leert den Audio-Unit-Cache. Optional (unter „Anpassen“, standardmäßig aus) auch die eigenen Daten des angemeldeten Nutzers: die Sandbox-Container von App und Plug-in mit Importen, Mixes und Einstellungen.
- **Zwei Versionen pro Song:** Ein Song kann eine **MIDI-Version** haben (eigene Drums aus der MIDI-Datei, mit Bass und Percussion; `drum songs › Artist`) und eine **bb-Version** (der BB-Beat, dem der Song-Index ihn zuordnet, mit allen Parts und Fills, dazu der Bass des Songs, wo er passt, sonst ein Bass aus der Kick des Beats, und die Percussion des Songs; `bb songs › Artist` / „Titel · Beat“). Der Songs-Tab zeigt für jede vorhandene Version eine Zeile (Kennung **BB** bzw. **MIDI**, `PedalViewModel.SongRow`); das Filter-Menü zeigt nur eine Art. Ohne beide spielt der ähnliche Factory-Groove (≈). Gibt es keine importierte bb-Version, baut die App sie aus BB-Beat und MIDI-Song zur Laufzeit (`SongLibrary.beat(_:withBassAndPercussionOf:)`). Die Percussion hängt per Artist + Titel an beiden Versionen (`SongIndex.linkKey` schneidet „ · Beat“ ab). Song-Ordner beider Arten stehen nicht im Beats-Tab.
- **Song-Pakete:** `Tools/build-songpack.sh` baut beide. **MIDI Songs** (`Extension/Resources/Content/SongPack.pbcp`): `drum_songs` mit Bass und die Percussion aus `pedalbeat-data/build/songpack`; unter iOS in die App eingebaut, unter macOS kommt es per Installer. **bb Songs** (`build/content/bb Songs.pbcp`; seit 25.11.2026 unter iOS ebenfalls in die App eingebaut, unter macOS per Installer): die bb-Beats (Inhalt von Singular Sound; aus `pedalbeat-data/bbsongs`, sonst die `.BBS` aus `bbs-content/SONGS`), die bb-Versionen (von `Tools/BBSongs` mit dem Import- und Export-Code der App erzeugt und zur Kontrolle wieder importiert: 851 Versionen von 822 Songs, 1362 Parts mit dem Bass des Songs, 451 generiert; Pack-Schlüssel `pack/bb/…`, `ContentPack.bbSongKey`) und deren Percussion. `BUILD_BB=0` lässt es weg. Ein Import beider Song-Ordner zusätzlich zu den Paketen belegt etwa die Hälfte der `SongStore`-Kapazität.
- **Mit bb-Beat (eingebaut oder importiert):** Hat ein Song einen bb-Beat (sein Stil, z. B. *Hotel California* → „Ballad 2“), spielt dieser Beat **unverändert** mit allen Parts und Fills. Bass und Percussion des Pack-Songs kommen dazu (Part *i* bekommt den Bass von Groove *i*, bei weniger Grooves den letzten). **Passt dieser Bass nicht zum Part, spielt der generierte Bass**, der der Bassdrum des bb-Parts folgt (`BassGenerator`, Stil nach bb-Genre, Grundton der Tonart des Songs). „Passt“ heißt: Der Bass spielt mindestens die Hälfte der Bassdrum-Schläge mit, und mindestens 80 % seiner Noten liegen auf dem Raster des Beats (gerade 16tel oder Triolen). Intro- und Transition-Bass bleiben nur, wenn sie passen; das Ending bekommt sonst eine generierte Linie. Mit den echten Daten: 862 Songs, 1833 Parts, davon 464 (25 %) generiert; bei 553 Songs passt der eigene Bass überall, bei 139 nirgends. Nur wenn die Taktlänge nicht passt, spielt der Beat allein: 52 von 966 Songs, meist wegen falscher Taktart im Extraktor.
- **Markierung:** Diese Songs erscheinen nur im Songs-Tab („♪ original drums“, Klatsch-Symbol bei Percussion), nicht im Beats-Tab.
- **Percussion als eigene Spur:** Sie verhält sich wie der Bass, mit Schalter „Percussion“, Level und je einem Schalter für Shaker, Tambourin und Clap.
- **Mitgeliefert:** iOS: beide Song-Pakete stecken im Plugin (`PedalBeatAU.appex/Content/SongPack.pbcp`, 2,3 MB, und `Content/bb Songs.pbcp`, 2,7 MB; `ContentPack.builtInPacks` lädt alle `.pbcp` dort nach Dateiname, zusammen ca. 75 ms). Fehlt eines beim Bauen, warnt die Build-Phase „Embed Song Pack“ und baut es nicht ein. macOS: die App enthält nur die Grooves; die Song-Pakete (2,3 MB und 2,7 MB, zusammen ca. 75 ms) kommen mit den Installern.

## 2. Datenfluss

Die Skripte liegen in diesem Repo (`Tools/midi-songs`, `Tools/laneextract`), die Daten in `pedalbeat-data`.

```
pedalbeat-data/midi-songs/
  midis/  +  midi_songs_available.json          Quell-MIDIs (1092 Songs, alle im SongIndex)
     │  Tools/midi-songs/extract_drums.py       (braucht `pip install mido`)
     ├─► drum_songs/<Artist>/<Titel>/           Drums je Song: Groove A/B, Fills, Intro, Ending, song.json
     ├─► shaker_songs/ tambourine_songs/ clap_songs/<Artist>/<Titel>/   Percussion je Song
     │
     │  laneextract songpack                    (Tools/laneextract, reines Python)
     ▼
pedalbeat-data/build/songpack/
  drum_songs/…   Drum-Dateien unverändert + "Groove A Bass.mid" …, song.json mit Bass und "bassRoot"
  shaker_songs/ tambourine_songs/ clap_songs/   unverändert kopiert
  songpack_report.md, songpack.json
     │  Tools/SongPack (Swift, nutzt den Import-Code der App)
     ▼
pedalbeat-develop/Extension/Resources/Content/SongPack.pbcp     (gitignored, wird gebaut)
     │  project.yml: Build-Phase „Embed Song Pack“ (nur iOS; dazu build/content/bb Songs.pbcp)
     ▼
iOS-App → PedalBeatAU.appex/Content/SongPack.pbcp + bb Songs.pbcp
macOS   → per Installer nach /Library/Application Support/PedalBeat/Songs
```

## 3. Neu erstellen, Schritt für Schritt

1. **Quell-MIDIs** (nur wenn neue Songs dazukommen): `midis/` und `midi_songs_available.json` kommen aus den Download-Skripten in `Tools/midi-songs/` (`download_midis.py`, `lakh_match.py`, dann `build_map.py`), siehe `Tools/midi-songs/README.md`.

2. **Drums und Percussion schneiden** (nur bei neuen MIDIs oder nach einer Änderung am Extraktor):
   ```sh
   cd pedalbeat-develop
   pip install mido                       # fehlt auf dieser Maschine noch
   python3 Tools/midi-songs/extract_drums.py               # → pedalbeat-data/midi-songs/drum_songs/
   python3 Tools/midi-songs/extract_drums.py --kind shaker
   python3 Tools/midi-songs/extract_drums.py --kind tambourine
   python3 Tools/midi-songs/extract_drums.py --kind clap
   # Daten woanders: MIDI_SONGS=/pfad/zu/midi-songs oder PEDALBEAT_DATA=/pfad/zu/pedalbeat-data
   ```

3. **Bass dazu und Pack bauen** (ein Befehl, im App-Repo):
   ```sh
   cd pedalbeat-develop
   ./Tools/build-songpack.sh              # laneextract songpack + Swift-Builder → SongPack.pbcp
   SKIP_LANEEXTRACT=1 ./Tools/build-songpack.sh   # nur das Pack neu, build/songpack wiederverwenden
   PEDALBEAT_DATA=/pfad/zu/pedalbeat-data ./Tools/build-songpack.sh   # falls nicht daneben
   ```
   Nur den Bass-Schritt allein:
   ```sh
   cd Tools/laneextract
   python3 -m laneextract songpack ../../../pedalbeat-data/midi-songs ../../../pedalbeat-data/build/songpack
   ```

4. **Prüfen:**
   - **`songpack_report.md`** lesen: Songs mit Bass, Konsistenz, „listen first“-Liste.
   - **Ausgabe des Builders:** Songs, Bass-Dateien zurückgelesen (muss „x of x“ sein), Ladezeit, Füllstand des Stores.
   - **Engine-Tests:** Der Befehl in der README linkt seit Solitito nicht mehr. So geht es:
     ```sh
     clang++ -std=c++17 -O2 -c Core/BassFollow/SolititoORT.cpp -I ThirdParty/onnxruntime/include -I Core -o build/SolititoORT.o
     swiftc -O -import-objc-header Core/PedalBeat-Bridging-Header.h -I Core -I ThirdParty/onnxruntime/include \
       Core/*.swift Core/*/*.swift Tools/RenderTest/main.swift build/SolititoORT.o -L ThirdParty/onnxruntime/lib -lonnxruntime -lc++ \
       -Xlinker -rpath -Xlinker "$PWD/ThirdParty/onnxruntime/lib" -o build/rendertest
     ./build/rendertest build/test
     ```
     Abschnitt 12 prüft die Percussion, Abschnitt 13 das Song-Pack. „audio detect A major“ schlägt schon vor diesen Änderungen fehl.

5. **App und Paket:**
   ```sh
   xcodegen generate                      # nach neuen Dateien in Core/ oder Extension/
   ./Tools/package-macos.sh               # baut die Packs, falls sie fehlen; prüft, dass die .appex keins enthält
   REBUILD_SONGPACK=1 ./Tools/package-macos.sh    # Pack vorher neu bauen
   NOTARIZE=1 ./Tools/package-macos.sh            # mit Notarisierung (notarytool-Profil nötig)
   ```
   Ergebnis: die `.pkg`-Installer in `build/package/` (siehe oben). Die iOS-App bekommt das MIDI-Songs-Pack über ihre Build-Phase „Embed Song Pack“.

## 4. Formate

- **Ordner je Song:** `<pack>/<Artist>/<Titel>/` mit `song.json` (`format`, `name`, `genre` = „drum songs › Artist“, `layout`).
  - `<pack>` ist `drum_songs` bzw. `shaker_songs`, `tambourine_songs` oder `clap_songs`.
  - Die Gruppe in `genre` bleibt beim Import erhalten, auch wenn man den Elternordner importiert.
- **`layout`:**
  - `parts[].main/fills/bass`, `intro`, `outro`, `introBass`, `outroBass`
  - neu `bassRoot`: Tonklasse 0 = C … 11 = B, ohne Angabe E. `SongData.bassRootPitchClass` übernimmt ihn, Bass Follow rechnet von dort.
- **Zuordnung:** Eine Percussion-Spur spielt mit dem Drum Song gleichen Interpreten und Titels. Der Schlüssel ist `SongIndex.linkKey` (normalisiert: Groß-/Kleinschreibung und Satzzeichen egal).
- **Percussion pro Abschnitt:**
  - Part n spielt Part n der Spur (bzw. ihren letzten Part).
  - Fill und Transition: der eigene Fill der Spur, sonst läuft ihr Groove weiter.
  - Intro und Ending: nur mit eigenem, sonst still.
- **`SongPack.pbcp`** (`Core/ContentPack.swift`): Binär, little-endian, „PBCP“ + Version 1, dann Songs (`SongData` komplett, inkl. Bass), dann Percussion-Spuren.
  - Song-Keys sind `pack/<linkKey>` und bleiben über Neubauten stabil, damit Host-Projekte ihre Songs wiederfinden.
  - Formatänderungen gehen nur mit neuer Versionsnummer. Eine kaputte oder alte Datei wird abgelehnt, die App läuft dann ohne Pack.

## 5. Verhalten in der App (Code-Stellen)

- **Laden:** `SongLibrary.loadContentPack(at:)` läuft im AU-Init vor der User-Library (`PedalBeatAudioUnit.init`).
  - Pack-Songs sind `isUser == false` und werden nicht in `imports.plist` gespeichert.
  - Ihre Percussion ist `builtIn`: „Remove“ entfernt nur Importe. Wird ein Import entfernt, der eine eingebaute Spur ersetzt hatte, kommt die eingebaute zurück.
- **Songs-Tab:** Reihenfolge in `PedalViewModel.resolve`: bb-Beat des Stils (mit Bass und Percussion des Songs über `SongLibrary.beat(_:withBassAndPercussionOf:)`), dann die eigenen Drums, dann der ähnliche Factory-Groove. Der kombinierte Song wird beim Laden einmal gebaut, gecacht und nicht in den Listen gezeigt; Fill-Bass bleibt dabei weg, weil er zu den Fills des Songs gehört. `PedalViewModel.songDrums` nimmt Pack-Songs; ein importierter oder bearbeiteter Song gleichen Namens hat Vorrang. Der Beats-Tab blendet Pack-Songs aus (`isPackSong`).
- **Tempo:** Es gilt der Index-BPM. Liegt das eigene Drum-Tempo beim Doppelten oder der Hälfte, gilt das eigene (`SongIndex.playTempo`). Das betrifft 71 Songs, etwa *Kryptonite*: Index 198, Drums 99.
- **Bearbeiten:** Wie bei Factory-Songs. Speichern legt eine User-Kopie an (gleicher Key, ersetzt den Pack-Song), „Revert“ holt das Original zurück.
- **Percussion-Engine:** `Core/Percussion.swift`, `SongStore` (Spuren und Verknüpfungstabelle), `Sequencer` (`setPercLayer`, `emitPercussion`), Parameter in `DrumEngine` und im AU (`percOn`, `percVolume`, `percShaker`, `percTambourine`, `percClap`), UI `PercussionSection` in `MainView`.
- **Ordner-Import der App:** liest bis zu 20 000 Dateien (`PedalViewModel.maxFolderFiles`, vorher 5000).

## 5a. Beats ohne Song: generierter Bass und generierte Percussion

Alles, was kein Song ist (Factory-Grooves, bb-Beats, eigene Imports), bekommt beim Hinzufügen (`SongLibrary.add`):

- **Bass:** Hat der Beat keinen, erzeugt `BassGenerator` einen, der der Bassdrum folgt. Der Stil kommt aus dem Genre (`style(forAnyGenre:)`, auch bb-Namen). Er ist **an**, der Bass-Schalter schaltet ihn ab. Factory-Beats hatten ihn schon.
- **Percussion:** `PercussionGenerator` legt Layer über die Drums des Beats. Shaker und Maracas folgen dem Hi-Hat-/Ride-Raster samt Swing und Triolen, Tamburin und Clap den Snare-Backbeats (ohne Snare: 2 und 4). Der Stil bestimmt, wer in Strophe, Refrain und Bridge spielt:

  | Stil | Strophe | Refrain | Bridge |
  |---|---|---|---|
  | Rock, Ballade, Pop | Shaker 8tel | Tamburin 8tel | Shaker + Tamburin Backbeat |
  | Country | Shaker | Shaker + Tamburin Backbeat | wie Refrain |
  | Funk | Shaker 16tel | Shaker + Clap | Clap |
  | Blues, Jazz, Shuffle | Shaker auf dem Beat | + Tamburin Backbeat | wie Refrain |
  | Reggae | Shaker | Shaker + Tamburin | Shaker |
  | Dance, Techno | Shaker 16tel | + Clap | + Clap |
  | Hip-Hop, R&B | Shaker | Shaker + Clap | Clap |
  | Latin, Bossa | Maracas | Maracas 16tel | Maracas + Tamburin |
  | Walzer, Folk | Shaker | Shaker + Tamburin auf 2 und 3 | Shaker |

  Ein Beat mit nur einem Part hat nur die Strophen-Besetzung. Intro und Ending bekommen keine Percussion, unter Fills läuft sie weiter.
- **Abspielen:** Die Layer liegen in einem eigenen Platz je Song und Instrument (`SongStore.setAutoPercussion`). Sie spielen nur mit **Auto Percussion** (AU-Parameter `percAuto`, Schalter „Auto“ im Percussion-Bereich, Standard **aus**) und nur, wenn der Song keine eigene Percussion hat. Die Instrument-Schalter gelten auch für sie.
- **Maracas** sind ein eigenes Instrument mit eigenem Klang und Schalter (`percMaracas`, GM 70). Der Shaker sendet jetzt GM 82 (vorher 70). Eingehend: 69 und 82 → Shaker, 70 → Maracas. Shaker-Dateien mit Note 70 (die bisherigen `shaker_songs`) bleiben Shaker.
- **Zahlen** (Factory + Pack + 239 bb-Beats): 417 Beats, alle mit Bass, alle mit generierter Percussion (Shaker 379, Tamburin 283, Clap 90, Maracas 38).

## 6. Wie der Bass entsteht (`laneextract/songbass.py`)

1. **Quell-MIDI zerlegen:** genau wie `extract_drums.py` in Takte. Raster ab Tick 0, Taktart = erste Taktart der Datei, Vergleich auf 16tel-Basis.
2. **Groove-Takte finden:** Für jede Groove-Datei alle Stellen suchen, an denen genau dieses Drum-Pattern spielt.
3. **Loop bauen:** Medoid bzw. Konsens des Basses über diese Takte (`parts.build_loop`, Raster laut Bass-Feel). Bass gibt es nur, wenn er in mindestens 40 % dieser Takte spielt.
4. **Intro- und Ending-Bass:** aus den Takten, die der Extraktor für `Intro.mid` und `Ending.mid` genommen hat. Ohne Bass im Ending bekommt das Ending den ersten Ton des letzten Basstakts, bis zu zwei Schläge lang.
5. **Tonhöhen:** akkordrelativ (wie in E4), gesetzt auf den Grundton der geschätzten Songtonart, Bereich E1–G3. `song.json` bekommt `bassRoot`.

## 7. Zahlen (Lauf vom 23.11.2026)

- **Drum Songs:** 936. Davon 859 mit Bass (92 %), 933 im Pack (3 doppelte Titel), 856 davon mit Bass.
- **Grooves:** 1489 von 1609 haben Bass. Konsistenz P10 0,39 / Median 0,67 / P90 1,00.
- **Fill-Bass:** 2187 Fills in 659 Pack-Songs haben eigenen Bass. Extraktor: 2201 Dateien, 1387 Fills „same“ (≥ 70 % wie der Groove, kein eigener), 102 „silent“, 47 ohne passende Takte.
- **Intro und Ending:** Intro-Bass in 577 Songs. Ending-Bass in 772: 735 aus echten Takten, 37 als Schlusston.
- **Percussion:** 139 Shaker, 220 Tambourin, 133 Clap; 356 Pack-Songs spielen Percussion.
- **Pack:** 2,3 MB. Lädt in ca. 30 ms. Factory + Pack belegen 243 k von 1 M Events und 12,4 k von 32 k Patterns.

## 8. Offene Punkte und Grenzen

- **Nichts angehört.** Zuerst die „listen first“-Liste in `songpack_report.md` und ein paar bekannte Songs prüfen.
- **Extraktor-Fehler, 35 Songs:** Die erste Taktart ist ein Auftakt (2/4, 5/4, bei *No Rain* sogar 149/4). `extract_drums.py` schneidet dann den ganzen Song in falschen Takten, die Drums sind dort unbrauchbar und haben keinen Bass. Beispiele: *Just the Two of Us*, *Night Moves*, *No Rain*.
  - Lösung: im Extraktor die häufigste Taktart oder die Taktart-Map verwenden.
  - Liste: `songpack.json`, `reason` beginnt mit „bars of the source“.
- **Ohne Bass:** 29 Songs haben keine Bass-Spur in der Quelle, bei 13 schweigt der Bass in den Groove-Takten.
- **Tempo:** Bei 202 Songs weichen Index-BPM und MIDI-Tempo um mehr als 8 % ab (nicht Faktor 2). Mal stimmt das MIDI (*Billie Jean*: MIDI 117, Index 100), mal der Index (*Take On Me*: Index 169, MIDI 155). Regel oder Index-Daten noch klären.
- **Tonart wird geschätzt** (Gold-Liste früher 34 von 37 richtig). Ohne Bass Follow spielt jeder Part sein Muster auf dem Grundton der Tonart. Wechselt der Part den Akkord, ist das ohne Follow nur eine Näherung.
- **Percussion stammt aus dem Extraktor:**
  - Ihr Groove A wird unabhängig vom Drum-Groove A gewählt.
  - Ihr „Intro“ sind die Takte vor dem Einsatz der Percussion, nicht das Song-Intro.
  - Besser wäre, sie aus denselben Takten zu schneiden wie den Bass (gleiche Technik wie `songbass.py`).
- **Ohne Drum Song:** 156 MIDIs haben keinen. Sie spielen im Songs-Tab den ähnlichen Factory-Groove.
- **Fill-Bass:** `songbass.py` schneidet ihn aus den Takten, in denen die Fill-Datei in der Quelle spielt (wie beim Groove). Er steht in `layout.parts[].fillBass` (eine Datei pro Fill, `""` = keine). Die App spielt ihn, danach setzt der Part-Bass dort ein, wo die Drums weiterspielen. Fills ohne Datei, auch die „silent“-Fills, lassen den Part-Bass weiterlaufen. Ein Schalter dafür fehlt; Fill-Bass ist immer an. Pack-Format Version 2, Version 1 lädt weiter, nur ohne Fill-Bass. Nicht angehört.
- **Ganzen `midi-songs`-Ordner importieren:** Das holt auch die Roh-MIDIs (`midis/`, `midis copy/`) und füllt den Speicher. Mit dem Pack ist kein Import nötig; wenn doch, die vier Ordner einzeln importieren.
- **Duplikate:** Wer `drum_songs` zusätzlich importiert, hat jeden Song doppelt. Der Import gewinnt im Songs-Tab.
- **Urheberrecht:** Drums und Bass stammen aus MIDI-Transkriptionen bekannter Songs (siehe `docs/bass-extraction-engine.md` §5). Mit dem Paket werden sie verteilt. Die bb-Beats (Default Content von Singular Sound) und die bb-Kits haben eigene Installer; wer sie weitergibt, verteilt sie ebenfalls. Das ist eine Entscheidung vor dem Release.
- **README:** Der Testbefehl dort ist veraltet (Solitito/ONNX); siehe Schritt 3.4.

## 9. Dateien

- **App** (`pedalbeat-develop`):
  - `Core/Percussion.swift`, `Core/ContentPack.swift`, `Core/SongStore.swift`, `Core/Sequencer.swift`
  - `Core/DrumEngine.swift`, `Core/SongLibrary.swift`, `Core/MIDIFile.swift` (`bassRoot`), `Core/MIDIFolderImport.swift`
  - `Core/Synth.swift` und `Core/SampleKit.swift` (Gain pro Schlag)
  - `Extension/PedalBeatAudioUnit.swift`, `Extension/UI/PedalViewModel.swift`, `Extension/UI/MainView.swift`
  - `Tools/SongPack/main.swift`, `Tools/build-songpack.sh`, `Tools/package-macos.sh`, `project.yml`, `.gitignore`
  - `Tools/RenderTest/main.swift` (Abschnitte 12, 13 und 14)
  - `Tools/laneextract/laneextract/songbass.py` (Bass und Fill-Bass für das Pack), `parts.py` (`bass_pitches(loop, root_pc)`), `__main__.py` (Befehl `songpack`)
  - `Tools/midi-songs/` (`extract_drums.py`, Download-Skripte, `paths.py`)
- **Daten** (`pedalbeat-data`): `midi-songs/` (Quell-MIDIs, `drum_songs/`, Percussion-Songs), `build/songpack/` (Zwischenstand)
