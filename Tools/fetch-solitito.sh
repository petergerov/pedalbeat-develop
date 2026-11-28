#!/usr/bin/env bash
# Download Solitito guitar ONNX + dsp weights and ONNX Runtime (macOS universal + iOS).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOL="$ROOT/ThirdParty/Solitito"
ORT="$ROOT/ThirdParty/onnxruntime"
mkdir -p "$SOL" "$ORT/include" "$ORT/lib"

echo "==> Solitito model assets"
if [[ ! -f "$SOL/best_model_v2_take6_chords.onnx" ]]; then
  curl -sL -o "$SOL/best_model_v2_take6_chords.onnx" \
    "https://huggingface.co/greblus/solitito-ai/resolve/main/best_model_v2_take6_chords.onnx"
fi
if [[ ! -f "$SOL/dsp_weights.json" ]]; then
  curl -sL -o "$SOL/dsp_weights.json" \
    "https://huggingface.co/greblus/solitito-ai/resolve/main/dsp_weights.json"
fi
if [[ ! -f "$SOL/LICENSE" ]]; then
  curl -sL -o "$SOL/LICENSE" \
    "https://raw.githubusercontent.com/greblus/solitito/solitito-ai/LICENSE"
fi

echo "==> ONNX Runtime 1.20.1 (NuGet: osx universal dylib + iOS static xcframework)"
if [[ ! -f "$ORT/lib/libonnxruntime.dylib" || ! -d "$ORT/ios/onnxruntime.xcframework" ]]; then
  TMP="$(mktemp -d)"
  curl -sL -o "$TMP/ort.nupkg" "https://www.nuget.org/api/v2/package/Microsoft.ML.OnnxRuntime/1.20.1"
  unzip -qo "$TMP/ort.nupkg" -d "$TMP/nup"
  cp "$TMP/nup/build/native/include/"*.h "$ORT/include/"
  if [[ ! -f "$ORT/lib/libonnxruntime.dylib" ]]; then
    lipo -create \
      "$TMP/nup/runtimes/osx-arm64/native/libonnxruntime.dylib" \
      "$TMP/nup/runtimes/osx-x64/native/libonnxruntime.dylib" \
      -output "$ORT/lib/libonnxruntime.dylib"
    install_name_tool -id @rpath/libonnxruntime.dylib "$ORT/lib/libonnxruntime.dylib"
  fi
  # iOS: static framework, linked into PedalBeatAU-iOS (nothing to embed).
  rm -rf "$ORT/ios"
  mkdir -p "$ORT/ios"
  unzip -qo "$TMP/nup/runtimes/ios/native/onnxruntime.xcframework.zip" -d "$ORT/ios"
  cp "$TMP/nup/LICENSE" "$ORT/LICENSE"
  cp "$TMP/nup/ThirdPartyNotices.txt" "$ORT/ThirdPartyNotices.txt" 2>/dev/null || true
  rm -rf "$TMP"
fi

# Sync into AU Resources (hardlink when possible) for XcodeGen bundling.
RES="$ROOT/Extension/Resources/Solitito"
mkdir -p "$RES"
for f in best_model_v2_take6_chords.onnx dsp_weights.json LICENSE; do
  ln -f "$SOL/$f" "$RES/$f" 2>/dev/null || cp -f "$SOL/$f" "$RES/$f"
done

ls -lh "$SOL/best_model_v2_take6_chords.onnx" "$SOL/dsp_weights.json" "$ORT/lib/libonnxruntime.dylib"
du -sh "$ORT/ios/onnxruntime.xcframework"
ls -lh "$RES"
echo "done"
