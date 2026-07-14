#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import sys
from contextlib import nullcontext
from pathlib import Path

import torch
import torch.nn as nn
from PIL import Image
from torchvision import models, transforms
from ultralytics import YOLO


def choose_device() -> str:
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def expand_box(box, width, height, ratio=0.10):
    x1, y1, x2, y2 = box
    box_width, box_height = x2 - x1, y2 - y1
    return (
        max(0, int(math.floor(x1 - box_width * ratio))),
        max(0, int(math.floor(y1 - box_height * ratio))),
        min(width, int(math.ceil(x2 + box_width * ratio))),
        min(height, int(math.ceil(y2 + box_height * ratio))),
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--detector", type=Path, required=True)
    parser.add_argument("--recognizer", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--top-k", type=int, default=5)
    args = parser.parse_args()

    device = choose_device()
    checkpoint = torch.load(args.recognizer, map_location="cpu", weights_only=True)
    labels = list(checkpoint["labels"])
    recognizer = models.efficientnet_b0(weights=None)
    recognizer.classifier[1] = nn.Linear(
        recognizer.classifier[1].in_features,
        len(labels),
    )
    recognizer.load_state_dict(checkpoint["model"])
    recognizer.to(device).eval()
    transform = transforms.Compose([
        transforms.Resize((224, 224)),
        transforms.ToTensor(),
        transforms.Normalize(
            (0.485, 0.456, 0.406),
            (0.229, 0.224, 0.225),
        ),
    ])
    detector = YOLO(str(args.detector))

    with Image.open(args.image) as opened:
        image = opened.convert("RGB")
    width, height = image.size
    if width * height > 40_000_000:
        raise ValueError("图片超过 4000 万像素")

    result = detector.predict(
        source=image,
        imgsz=1280,
        conf=0.30,
        iou=0.60,
        device=device,
        verbose=False,
    )[0]
    boxes = []
    detection_confidences = []
    if result.boxes is not None and len(result.boxes):
        boxes = [tuple(map(float, value)) for value in result.boxes.xyxy.cpu().tolist()]
        detection_confidences = [float(value) for value in result.boxes.conf.cpu().tolist()]

    used_fallback = not boxes
    if used_fallback:
        boxes = [(0.0, 0.0, float(width), float(height))]
        detection_confidences = [None]

    crops = [image.crop(expand_box(box, width, height)) for box in boxes]
    tensor = torch.stack([transform(crop) for crop in crops]).to(device)
    autocast = (
        torch.autocast(device_type="cuda", dtype=torch.float16)
        if device == "cuda"
        else nullcontext()
    )
    with torch.inference_mode(), autocast:
        scores = torch.softmax(recognizer(tensor).float(), dim=1)
        values, indices = scores.topk(min(max(args.top_k, 1), len(labels)), dim=1)

    detections = []
    for box, detection_confidence, row_values, row_indices in zip(
        boxes,
        detection_confidences,
        values.cpu().tolist(),
        indices.cpu().tolist(),
    ):
        x1, y1, x2, y2 = box
        detections.append({
            "bbox": [
                int(round(x1)),
                int(round(y1)),
                int(round(x2 - x1)),
                int(round(y2 - y1)),
            ],
            "detection_confidence": detection_confidence,
            "candidates": [
                {
                    "class_id": int(class_id),
                    "label_name": labels[class_id],
                    "confidence": float(confidence),
                }
                for confidence, class_id in zip(row_values, row_indices)
            ],
        })
    detections.sort(
        key=lambda item: item["detection_confidence"] or 0.0,
        reverse=True,
    )
    json.dump({
        "device": device,
        "used_full_image_fallback": used_fallback,
        "confidence_notice": "模型候选，置信度未经校准，不是确定释读。",
        "detections": detections,
    }, sys.stdout, ensure_ascii=False, separators=(",", ":"))


if __name__ == "__main__":
    main()

