#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# Resolve the installed SDK instead of tying the repository to one machine.
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
MODULE_CACHE="${TMPDIR:-/tmp}/ancient-ocr-swift-cache"
APP="${APP_OUTPUT:-$ROOT/../温古茶.app}"
MODEL_SOURCE="$ROOT/Resources/Models"
if [[ ! -f "$MODEL_SOURCE/detector_best.pt" ]]; then
  MODEL_SOURCE="$ROOT/../models"
fi
RUNTIME_SOURCE="$ROOT/Resources/ocr_runtime"
if [[ ! -x "$RUNTIME_SOURCE/ocr_runner" ]]; then
  RUNTIME_SOURCE="$APP/Contents/Resources/ocr_runtime"
fi

if [[ ! -f "$MODEL_SOURCE/detector_best.pt" || ! -f "$MODEL_SOURCE/recognizer_best.pt" ]]; then
  echo "缺少 detector_best.pt 或 recognizer_best.pt。" >&2
  exit 1
fi
if [[ ! -x "$RUNTIME_SOURCE/ocr_runner" ]]; then
  echo "缺少 arm64 OCR 运行时；请先运行 ./build_ocr_runtime.sh。" >&2
  exit 1
fi

mkdir -p "$ROOT/build" "$MODULE_CACHE" \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources/Models" \
  "$APP/Contents/Resources/Glyphs" \
  "$APP/Contents/Resources/ocr_runtime"

# Refuse to build a bundle with missing, unlicensed, or duplicate glyph rows.
python3 "$ROOT/Scripts/validate_glyph_catalog.py"
python3 "$ROOT/Scripts/validate_recognition_labels.py"
python3 "$ROOT/Scripts/validate_character_metadata.py"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFT_MODULECACHE_PATH="$MODULE_CACHE" \
"$SWIFTC" \
  -sdk "$SDK" \
  -target arm64-apple-macosx15.0 \
  -swift-version 5 \
  -O \
  -parse-as-library \
  "$ROOT"/Sources/*.swift \
  -o "$ROOT/build/AncientOCR" \
  -framework SwiftUI \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  -lsqlite3

cp "$ROOT/build/AncientOCR" "$APP/Contents/MacOS/AncientOCR"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/recognition_labels.json" "$APP/Contents/Resources/recognition_labels.json"
cp "$ROOT/Resources/glyph_catalog.json" "$APP/Contents/Resources/glyph_catalog.json"
cp "$ROOT/Resources/character_metadata.json" "$APP/Contents/Resources/character_metadata.json"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
rsync -a "$ROOT/Resources/Glyphs/" "$APP/Contents/Resources/Glyphs/"
cp "$MODEL_SOURCE/detector_best.pt" "$APP/Contents/Resources/Models/detector_best.pt"
cp "$MODEL_SOURCE/recognizer_best.pt" "$APP/Contents/Resources/Models/recognizer_best.pt"
if [[ "$RUNTIME_SOURCE" != "$APP/Contents/Resources/ocr_runtime" ]]; then
  rsync -a "$RUNTIME_SOURCE/" "$APP/Contents/Resources/ocr_runtime/"
fi
chmod +x "$APP/Contents/MacOS/AncientOCR" "$APP/Contents/Resources/ocr_runtime/ocr_runner"
codesign --force --deep --sign - "$APP"

echo "$APP"
