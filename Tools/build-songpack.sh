#!/usr/bin/env bash
# Builds the two song packs (Core/ContentPack.swift):
#
#   MIDI Songs       Extension/Resources/Content/SongPack.pbcp: the songs with their own drums, bass lines and
#                    percussion (shaker, tambourine, clap). Built into the iOS plug-in; on macOS the MIDI Songs
#                    installer puts it in /Library/Application Support/PedalBeat/Songs.
#   bb Songs  build/content/bb Songs.pbcp: the bb beats and every song's bb version
#                    (its beat with the song's bass and percussion). Built into the iOS plug-in too; on macOS
#                    the bb Songs installer puts it in /Library/Application Support/PedalBeat/Songs.
#
# Steps:
#   1. laneextract songpack: the bass for each drum song, cut from the bars its drum grooves come from
#      (Tools/laneextract: pedalbeat-data/midi-songs → pedalbeat-data/build/songpack)
#   2. Tools/SongPack: imports that folder with the app's own import code and writes the MIDI Songs pack.
#   3. Tools/BBSongs: the bb versions as song folders (beats from pedalbeat-data/bbsongs, else the .BBS
#      files of bbs-content/SONGS), then Tools/SongPack on them plus the beats: the bb Songs pack.
#
# The scripts live in this repo (Tools/laneextract, Tools/midi-songs); pedalbeat-data only holds the data.
#
# Usage: ./Tools/build-songpack.sh          (PEDALBEAT_DATA=<path> if pedalbeat-data is not next to this repo;
#                                             SKIP_LANEEXTRACT=1 to reuse build/songpack;
#                                             BB_BEATS=<folder> for other bb beats, BUILD_BB=0 to skip step 3)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="${PEDALBEAT_DATA:-$ROOT/../pedalbeat-data}"
SRC="$DATA/build/songpack"
OUT="$ROOT/Extension/Resources/Content/SongPack.pbcp"
BB_OUT="$ROOT/build/content/bb Songs.pbcp"
BB_BEATS="${BB_BEATS:-$DATA/bbsongs}"
if ! compgen -G "${BB_BEATS}/*/*/song.json" >/dev/null; then BB_BEATS="$DATA/bbs-content/SONGS"; fi

if [[ "${SKIP_LANEEXTRACT:-0}" != "1" ]]; then
  echo "==> laneextract songpack ($DATA/midi-songs → $SRC)"
  (cd "$ROOT/Tools/laneextract" && python3 -m laneextract songpack "$DATA/midi-songs" "$SRC")
fi

echo "==> Building the song pack tools"
"$ROOT/Tools/fetch-solitito.sh" >/dev/null
mkdir -p "$ROOT/build/songpack-tool" "$ROOT/build/bbsongs-tool"
clang++ -std=c++17 -O2 -c "$ROOT/Core/BassFollow/SolititoORT.cpp" -I "$ROOT/ThirdParty/onnxruntime/include" -I "$ROOT/Core" \
  -o "$ROOT/build/songpack-tool/SolititoORT.o"
tool() {   # <main.swift> <output>
  swiftc -O -import-objc-header "$ROOT/Core/PedalBeat-Bridging-Header.h" -I "$ROOT/Core" -I "$ROOT/ThirdParty/onnxruntime/include" \
    "$ROOT"/Core/*.swift "$ROOT"/Core/*/*.swift "$1" "$ROOT/build/songpack-tool/SolititoORT.o" \
    -L "$ROOT/ThirdParty/onnxruntime/lib" -lonnxruntime -lc++ -Xlinker -rpath -Xlinker "$ROOT/ThirdParty/onnxruntime/lib" -o "$2"
}
tool "$ROOT/Tools/SongPack/main.swift" "$ROOT/build/songpack-tool/songpack"
tool "$ROOT/Tools/BBSongs/main.swift" "$ROOT/build/bbsongs-tool/bbsongs"

echo "==> Writing $OUT (MIDI Songs)"
"$ROOT/build/songpack-tool/songpack" "$SRC" "$OUT"

if [[ "${BUILD_BB:-1}" != "1" ]]; then
  echo "==> BUILD_BB=0: no bb Songs pack"
elif ! compgen -G "${BB_BEATS}/*" >/dev/null; then
  echo "==> No bb beats at ${BB_BEATS}: no bb Songs pack" >&2
else
  BB_SRC="$ROOT/build/bb-songs-src"
  echo "==> bb versions of the songs ($BB_BEATS → $BB_SRC)"
  "$ROOT/build/bbsongs-tool/bbsongs" "$BB_BEATS" "$SRC" "$BB_SRC"
  if [[ -f "$BB_BEATS/config.csv" ]]; then ditto "$BB_BEATS" "$BB_SRC/bb Beats/SONGS"; BBS_ARG=("$BB_SRC/bb Beats/SONGS")
  else ditto "$BB_BEATS" "$BB_SRC/bb Beats"; BBS_ARG=(); fi
  echo "==> Writing $BB_OUT (bb Songs)"
  mkdir -p "$(dirname "$BB_OUT")"
  "$ROOT/build/songpack-tool/songpack" "$BB_SRC" "$BB_OUT" ${BBS_ARG[@]+"${BBS_ARG[@]}"}
fi
