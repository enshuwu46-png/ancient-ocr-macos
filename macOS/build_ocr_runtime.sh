#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${PYTHON:-python3}"
VENV="$ROOT/build/ocr-runtime-venv"
DIST="$ROOT/build/ocr-runtime-dist"
WORK="$ROOT/build/ocr-runtime-work"
SPEC="$ROOT/build/ocr-runtime-spec"
STAGED="$ROOT/build/ocr_runtime.new"
TARGET="$ROOT/Resources/ocr_runtime"
BACKUP="$ROOT/build/ocr_runtime.previous.$(date +%Y%m%d-%H%M%S)"

# The embedded runner must be built on Apple Silicon for the arm64 app.
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "OCR 运行时必须在 Apple Silicon Mac 上构建。" >&2
  exit 1
fi

"$PYTHON" -m venv "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip
"$VENV/bin/python" -m pip install -r "$ROOT/requirements-ocr-runtime.txt"

rm -rf "$DIST" "$WORK" "$SPEC" "$STAGED"
"$VENV/bin/python" -m PyInstaller \
  --noconfirm \
  --clean \
  --onedir \
  --name ocr_runner \
  --collect-submodules torchvision \
  --collect-all ultralytics \
  --exclude-module polars \
  --distpath "$DIST" \
  --workpath "$WORK" \
  --specpath "$SPEC" \
  "$ROOT/Scripts/ocr_runner.py"

# Replace the checked-out runtime only after PyInstaller completed successfully.
cp -R "$DIST/ocr_runner" "$STAGED"
if [[ -d "$TARGET" ]]; then
  mv "$TARGET" "$BACKUP"
fi
mv "$STAGED" "$TARGET"
chmod +x "$TARGET/ocr_runner"
file "$TARGET/ocr_runner"
