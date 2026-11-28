#!/usr/bin/env bash
# Builds the macOS installers: signed .pkg files that put everything in place, ready to play (no import).
#
#   PedalBeat-<v>.pkg                  the app with its AUv3 plug-in → /Applications
#   PedalBeat-MIDI-Songs-<v>.pkg       the songs with their own drums, bass and percussion
#   PedalBeat-bb-Songs-<v>.pkg         the bb beats and the songs' bb versions (bass, percussion)
#   PedalBeat-Kits-<v>.pkg             PedalBeat's sampled kits (open-licensed samples)
#   PedalBeat-bb-Kits-<v>.pkg          the kits decoded from bb drumsets
#   PedalBeat-Complete-<v>.pkg         all of the above in one installer (each part can be deselected)
#   PedalBeat-Uninstall-<v>.pkg        removes the app and the installed content (the user's own data optional)
#
# Content goes to /Library/Application Support/PedalBeat (Songs/*.pbcp, Kits/*.pbkit), which the sandboxed
# app and plug-in read at launch (InstalledContent; read-only entitlement). The import stays for the
# user's own MIDI files, .BBS cards and kits.
#
# Usage: ./Tools/package-macos.sh
#   NOTARIZE=1          notarize and staple every installer (needs `xcrun notarytool store-credentials`)
#   REBUILD_SONGPACK=1  rebuild both song packs first (Tools/build-songpack.sh)
#   PEDALBEAT_DATA=<path> if pedalbeat-data is not next to this repo
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="PedalBeat-macOS"
TEAM="C9LBGZNZ6P"
SIGN_ID="Developer ID Application: Petar Gerov (${TEAM})"
INSTALLER_ID="Developer ID Installer: Petar Gerov (${TEAM})"
VERSION="$(grep -E '^\s*MARKETING_VERSION:' project.yml | head -1 | awk '{print $2}' | tr -d '"')"
VERSION="${VERSION:-1.0}"
BUILD_DIR="${ROOT}/build/package"
ARCHIVE="${BUILD_DIR}/PedalBeat.xcarchive"
COMPONENTS="${BUILD_DIR}/components"
APP_NAME="PedalBeat"
NOTARY_PROFILE="${NOTARY_PROFILE:-PedalBeat}"
DATA="${PEDALBEAT_DATA:-$ROOT/../pedalbeat-data}"
CONTENT_ROOT="/Library/Application Support/PedalBeat"

MIDI_PACK="$ROOT/Extension/Resources/Content/SongPack.pbcp"
BB_PACK="$ROOT/build/content/bb Songs.pbcp"

echo "==> Fetching Solitito / ONNX Runtime assets (if needed)"
"$ROOT/Tools/fetch-solitito.sh"

if [[ ! -f "$MIDI_PACK" || "${REBUILD_SONGPACK:-0}" == "1" ]]; then
  echo "==> Building the song packs"
  "$ROOT/Tools/build-songpack.sh"
elif [[ ! -f "$BB_PACK" ]]; then
  echo "==> Building the song packs (bb Songs is missing)"
  SKIP_LANEEXTRACT=1 "$ROOT/Tools/build-songpack.sh"
fi
for p in "$MIDI_PACK" "$BB_PACK"; do
  [[ -f "$p" ]] && echo "==> $(basename "$p"): $(du -h "$p" | cut -f1) from $(date -r "$p" '+%Y-%m-%d %H:%M')"
done

echo "==> Regenerating Xcode project"
if command -v xcodegen >/dev/null; then
  xcodegen generate
fi

echo "==> Archiving ${SCHEME} (Developer ID)"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${COMPONENTS}"

xcodebuild archive \
  -project PedalBeat.xcodeproj \
  -scheme "${SCHEME}" \
  -configuration Release \
  -archivePath "${ARCHIVE}" \
  -destination "generic/platform=macOS" \
  DEVELOPMENT_TEAM="${TEAM}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${SIGN_ID}" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  ENABLE_HARDENED_RUNTIME=YES

APP="${ARCHIVE}/Products/Applications/${APP_NAME}.app"
APPEX="${APP}/Contents/PlugIns/PedalBeatAU.appex"
if [[ ! -d "${APP}" ]]; then
  echo "Archive did not produce ${APP_NAME}.app" >&2
  find "${ARCHIVE}" -name "*.app" 2>/dev/null || true
  exit 1
fi
# The songs come with their installers, not inside the app; the plug-in must be allowed to read them.
if compgen -G "${APPEX}/Contents/Resources/Content/*.pbcp" >/dev/null; then
  echo "PedalBeatAU.appex still has a built-in song pack (macOS gets it from the MIDI Songs installer)" >&2
  exit 1
fi
for bin in "${APP}" "${APPEX}"; do
  if ! codesign -d --entitlements - "${bin}" 2>/dev/null | grep -q "${CONTENT_ROOT}/"; then
    echo "$(basename "${bin}") may not read ${CONTENT_ROOT} (entitlement missing)" >&2
    exit 1
  fi
done

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP}"
spctl --assess --type execute --verbose "${APP}" 2>&1 || true

# MARK: Component packages

# The app: fixed in /Applications (not relocated to another copy of PedalBeat.app the user has elsewhere).
APP_ROOT="${COMPONENTS}/app-root"
mkdir -p "${APP_ROOT}"
ditto "${APP}" "${APP_ROOT}/${APP_NAME}.app"
pkgbuild --analyze --root "${APP_ROOT}" "${COMPONENTS}/app.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "${COMPONENTS}/app.plist"
pkgbuild --root "${APP_ROOT}" --component-plist "${COMPONENTS}/app.plist" --install-location /Applications \
  --identifier com.pedalbeat.pkg.app --version "${VERSION}" "${COMPONENTS}/app.pkg" >/dev/null
COMPONENT_IDS=(app)

# <id> <staged root>: content installed into /Library/Application Support/PedalBeat.
content_pkg() {
  local id="$1" root="$2"
  find "${root}" -name .DS_Store -delete
  # No extended attributes (e.g. com.apple.provenance): pkgbuild would ship them as ._ files.
  xattr -cr "${root}"
  chmod -R u=rwX,go=rX "${root}"
  pkgbuild --root "${root}" --install-location "${CONTENT_ROOT}" --identifier "com.pedalbeat.pkg.${id}" \
    --version "${VERSION}" "${COMPONENTS}/${id}.pkg" >/dev/null
  COMPONENT_IDS+=("${id}")
}

stage="${COMPONENTS}/midisongs-root"
if [[ -f "${MIDI_PACK}" ]]; then
  mkdir -p "${stage}/Songs" && cp "${MIDI_PACK}" "${stage}/Songs/MIDI Songs.pbcp"
  content_pkg midisongs "${stage}"
else echo "==> No MIDI Songs pack: no MIDI Songs installer"; fi

stage="${COMPONENTS}/bbsongs-root"
if [[ -f "${BB_PACK}" && "${COPY_BBS:-1}" == "1" ]]; then
  mkdir -p "${stage}/Songs" && cp "${BB_PACK}" "${stage}/Songs/bb Songs.pbcp"
  content_pkg bbsongs "${stage}"
else echo "==> No bb Songs pack (or COPY_BBS=0): no bb Songs installer"; fi

kits_pkg() {   # <id> <source folder> <credits file name>
  local id="$1" src="$2" credits="$3" stage="${COMPONENTS}/$1-root"
  if [[ "${COPY_KITS:-1}" != "1" ]] || ! compgen -G "${src}/*.pbkit" >/dev/null; then
    echo "==> No kits at ${src} (or COPY_KITS=0): no ${id} installer"; return
  fi
  mkdir -p "${stage}/Kits"
  cp "${src}"/*.pbkit "${stage}/Kits/"
  [[ -f "${src}/README.md" ]] && cp "${src}/README.md" "${stage}/Kits/${credits}"
  content_pkg "${id}" "${stage}"
}
kits_pkg kits "${DATA}/kits" "PedalBeat Kits - Credits and Licenses.md"
kits_pkg bbkits "${DATA}/bb-kits" "bb Kits - Read Me.md"

# MARK: Installers (product archives)

title_of() {
  case "$1" in
    app) echo "PedalBeat" ;;
    midisongs) echo "PedalBeat MIDI Songs" ;;
    bbsongs) echo "PedalBeat bb Songs" ;;
    kits) echo "PedalBeat Kits" ;;
    bbkits) echo "PedalBeat bb Kits" ;;
  esac
}
about_of() {
  case "$1" in
    app) echo "The PedalBeat app with its Audio Unit plug-in (PedalBeat Drums, PedalBeat Drums FX), in Applications." ;;
    midisongs) echo "933 popular songs with their own drums from the MIDI files, with bass lines and percussion (shaker, tambourine, clap). In the Songs tab as MIDI." ;;
    bbsongs) echo "240 bb beats (Beats tab, BBS › Genre) and 851 songs played with their bb beat, with the song's bass and percussion. In the Songs tab as BB." ;;
    kits) echo "14 sampled drum kits from open-licensed sample libraries (credits in the Kits folder)." ;;
    bbkits) echo "12 sampled drum kits from the bb drumsets." ;;
  esac
}
file_of() {
  case "$1" in
    app) echo "PedalBeat-${VERSION}.pkg" ;;
    midisongs) echo "PedalBeat-MIDI-Songs-${VERSION}.pkg" ;;
    bbsongs) echo "PedalBeat-bb-Songs-${VERSION}.pkg" ;;
    kits) echo "PedalBeat-Kits-${VERSION}.pkg" ;;
    bbkits) echo "PedalBeat-bb-Kits-${VERSION}.pkg" ;;
  esac
}

# <output.pkg> <title> <id>...: a signed installer with one choice per component.
product() {
  local out="$1" title="$2"; shift 2
  local res="${COMPONENTS}/res-$(basename "${out}" .pkg)" dist="${COMPONENTS}/$(basename "${out}" .pkg).dist"
  mkdir -p "${res}"
  {
    echo "${title} ${VERSION}"
    echo
    for id in "$@"; do echo "• $(title_of "${id}"): $(about_of "${id}")"; echo; done
    if [[ " $* " != *" app "* ]]; then echo "Needs PedalBeat (PedalBeat-${VERSION}.pkg)."; echo; fi
    echo "Everything is installed ready to play: no import needed. Songs and kits go to"
    echo "${CONTENT_ROOT} and are there the next time PedalBeat or the plug-in opens."
    echo "To remove PedalBeat again: PedalBeat-Uninstall-${VERSION}.pkg."
    if [[ " $* " == *" app "* ]]; then
      echo
      echo "After installing, open PedalBeat once so macOS registers the plug-in; in Logic, GarageBand,"
      echo "MainStage, AUM or Loopy Pro it is PedalBeat (PdBt). MIDI Settings: assign your footswitch with Learn."
    fi
  } > "${res}/Welcome.txt"
  {
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<installer-gui-script minSpecVersion="2">'
    echo "  <title>${title}</title>"
    echo '  <welcome file="Welcome.txt" mime-type="text/plain"/>'
    echo "  <options customize=\"$([[ $# -gt 1 ]] && echo allow || echo never)\" require-scripts=\"false\" hostArchitectures=\"arm64,x86_64\"/>"
    echo '  <domains enable_localSystem="true"/>'
    echo '  <allowed-os-versions><os-version min="15.0"/></allowed-os-versions>'
    echo '  <choices-outline>'
    for id in "$@"; do echo "    <line choice=\"${id}\"/>"; done
    echo '  </choices-outline>'
    for id in "$@"; do
      echo "  <choice id=\"${id}\" title=\"$(title_of "${id}")\" description=\"$(about_of "${id}" | sed 's/&/\&amp;/g; s/"/\&quot;/g; s/</\&lt;/g')\">"
      echo "    <pkg-ref id=\"com.pedalbeat.pkg.${id}\"/>"
      echo '  </choice>'
    done
    for id in "$@"; do
      echo "  <pkg-ref id=\"com.pedalbeat.pkg.${id}\" version=\"${VERSION}\" onConclusion=\"none\">${id}.pkg</pkg-ref>"
    done
    echo '</installer-gui-script>'
  } > "${dist}"
  productbuild --distribution "${dist}" --package-path "${COMPONENTS}" --resources "${res}" \
    --sign "${INSTALLER_ID}" --timestamp "${out}" >/dev/null
  if [[ "${NOTARIZE:-0}" == "1" ]]; then
    echo "==> Notarizing $(basename "${out}") (profile: ${NOTARY_PROFILE})"
    xcrun notarytool submit "${out}" --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${out}"
    xcrun stapler validate "${out}"
  fi
  echo "==> $(basename "${out}")"
}

for id in "${COMPONENT_IDS[@]}"; do product "${BUILD_DIR}/$(file_of "${id}")" "$(title_of "${id}")" "${id}"; done
product "${BUILD_DIR}/PedalBeat-Complete-${VERSION}.pkg" "PedalBeat Complete" "${COMPONENT_IDS[@]}"
[[ "${NOTARIZE:-0}" == "1" ]] || echo "==> Not notarized (set NOTARIZE=1 after configuring notarytool credentials)"

# MARK: Uninstaller

# Payload-free packages that only run Tools/uninstall/<part>/postinstall (no receipt is left behind):
#   app       the app, the installed songs and kits, the installers' receipts (always)
#   userdata  the user's own imports, mixes and settings (sandbox containers; off unless chosen)
for part in app userdata; do
  pkgbuild --nopayload --scripts "$ROOT/Tools/uninstall/${part}" --identifier "com.pedalbeat.pkg.uninstall.${part}" \
    --version "${VERSION}" "${COMPONENTS}/uninstall-${part}.pkg" >/dev/null
done
UNINSTALLER="${BUILD_DIR}/PedalBeat-Uninstall-${VERSION}.pkg"
res="${COMPONENTS}/res-uninstall"
mkdir -p "${res}"
cat > "${res}/Welcome.txt" <<EOF
PedalBeat Uninstaller ${VERSION}

Removes PedalBeat from this Mac:
• the PedalBeat app with its Audio Unit plug-in (Applications)
• the installed songs and kits (${CONTENT_ROOT})

Your own imports (songs, beats, kits), mixes and settings stay, unless you choose "Your PedalBeat data"
under Customize. Projects in Logic, GarageBand, MainStage and others keep their tracks, but PedalBeat
is missing in them until it is installed again.

Quit PedalBeat and close host projects that use it first.
EOF
cat > "${COMPONENTS}/uninstall.dist" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>PedalBeat Uninstaller</title>
  <welcome file="Welcome.txt" mime-type="text/plain"/>
  <options customize="allow" require-scripts="true" hostArchitectures="arm64,x86_64"/>
  <domains enable_localSystem="true"/>
  <choices-outline>
    <line choice="app"/>
    <line choice="userdata"/>
  </choices-outline>
  <choice id="app" title="PedalBeat, its songs and kits" enabled="false" start_selected="true"
          description="The app with its plug-in and everything the PedalBeat installers put in place.">
    <pkg-ref id="com.pedalbeat.pkg.uninstall.app"/>
  </choice>
  <choice id="userdata" title="Your PedalBeat data" start_selected="false"
          description="Your own imported songs, beats and kits, mixes and settings. Can't be undone.">
    <pkg-ref id="com.pedalbeat.pkg.uninstall.userdata"/>
  </choice>
  <pkg-ref id="com.pedalbeat.pkg.uninstall.app" version="${VERSION}" onConclusion="none">uninstall-app.pkg</pkg-ref>
  <pkg-ref id="com.pedalbeat.pkg.uninstall.userdata" version="${VERSION}" onConclusion="none">uninstall-userdata.pkg</pkg-ref>
</installer-gui-script>
EOF
productbuild --distribution "${COMPONENTS}/uninstall.dist" --package-path "${COMPONENTS}" --resources "${res}" \
  --sign "${INSTALLER_ID}" --timestamp "${UNINSTALLER}" >/dev/null
if [[ "${NOTARIZE:-0}" == "1" ]]; then
  xcrun notarytool submit "${UNINSTALLER}" --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun stapler staple "${UNINSTALLER}"
fi
echo "==> $(basename "${UNINSTALLER}")"

for _ in 1 2 3 4 5; do rm -rf "${COMPONENTS}" 2>/dev/null && break; sleep 1; done

echo
echo "Installers ready in ${BUILD_DIR}:"
ls -lh "${BUILD_DIR}"/*.pkg | awk '{print "  " $5 "\t" $NF}'
echo
codesign -dv --verbose=4 "${APP}" 2>&1 | grep -E "Authority|Identifier|Format|TeamIdentifier|Runtime" || true
