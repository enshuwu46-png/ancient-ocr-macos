#!/usr/bin/env bash
set -Eeuo pipefail

echo "========================================"
echo "Ancient OCR inference starting"
echo "Current directory: $(pwd)"
echo "Python: $(command -v python || true)"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-not set}"
echo "========================================"

INPUT_DIR="/saisdata/50/eval/images"
OUTPUT_DIR="/saisresult"
OUTPUT_FILE="${OUTPUT_DIR}/prediction.json"

DETECTOR="/app/models/detector_best.pt"
RECOGNIZER="/app/models/recognizer_best.pt"
SCRIPT="/app/code/generate_submission.py"

echo "Checking required files..."

for file in "$DETECTOR" "$RECOGNIZER" "$SCRIPT"; do
    if [ ! -s "$file" ]; then
        echo "ERROR: required file is missing or empty: $file"
        exit 10
    fi
done

echo "Checking evaluation data..."

if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: evaluation image directory does not exist: $INPUT_DIR"
    echo "Available directories under /saisdata:"
    find /saisdata -maxdepth 5 -type d 2>/dev/null || true
    exit 11
fi

IMAGE_COUNT=$(find "$INPUT_DIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.tif' -o -iname '*.tiff' \) | wc -l)

echo "Evaluation image count: $IMAGE_COUNT"

if [ "$IMAGE_COUNT" -eq 0 ]; then
    echo "ERROR: no supported images found in $INPUT_DIR"
    exit 12
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_FILE"

echo "Checking Python packages..."

python - <<'PY'
import torch
import torchvision
import ultralytics

print("torch:", torch.__version__)
print("torchvision:", torchvision.__version__)
print("ultralytics:", ultralytics.__version__)
print("CUDA available:", torch.cuda.is_available())

if torch.cuda.is_available():
    print("CUDA device:", torch.cuda.get_device_name(0))
PY

echo "Starting inference..."

python "$SCRIPT" \
    --detector "$DETECTOR" \
    --recognizer "$RECOGNIZER" \
    --images "$INPUT_DIR" \
    --output "$OUTPUT_FILE" \
    --imgsz 1280 \
    --conf 0.30 \
    --iou 0.60 \
    --padding 0.10

echo "Checking prediction.json..."

python - <<'PY'
import json
from pathlib import Path

path = Path("/saisresult/prediction.json")

if not path.is_file():
    raise FileNotFoundError(f"Missing output file: {path}")

data = json.loads(path.read_text(encoding="utf-8"))

if not isinstance(data, dict):
    raise TypeError("prediction.json root must be a dictionary")

total_boxes = 0

for image_id, rows in data.items():
    if not isinstance(image_id, str):
        raise TypeError("image_id must be a string")
    if not isinstance(rows, list):
        raise TypeError(f"Predictions for {image_id} must be a list")
    for row in rows:
        if not isinstance(row, dict):
            raise TypeError(f"Prediction entry for {image_id} must be a dictionary")
        if set(row.keys()) != {"bbox", "text"}:
            raise ValueError(f"Invalid fields for {image_id}: {sorted(row.keys())}")
        bbox = row["bbox"]
        text = row["text"]
        if not isinstance(bbox, list) or len(bbox) != 4:
            raise ValueError(f"Invalid bbox for {image_id}: {bbox}")
        if not all(isinstance(v, int) for v in bbox):
            raise TypeError(f"bbox values must be integers: {bbox}")
        if bbox[2] <= 0 or bbox[3] <= 0:
            raise ValueError(f"Invalid bbox size: {bbox}")
        if not isinstance(text, str) or not text:
            raise ValueError(f"Invalid text for {image_id}: {text!r}")
        total_boxes += 1

print("Output validation passed")
print("Images:", len(data))
print("Prediction boxes:", total_boxes)
print("Output:", path)
PY

echo "========================================"
echo "Ancient OCR inference completed"
echo "========================================"
