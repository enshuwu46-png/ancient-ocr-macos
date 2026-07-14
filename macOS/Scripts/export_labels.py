#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    labels = list(checkpoint["labels"])
    rows = []
    for class_id, label in enumerate(labels):
        normalized = label if len(label) == 1 else None
        rows.append({
            "classId": class_id,
            "labelName": label,
            "normalizedChar": normalized,
            "notes": None if normalized else "checkpoint 原始不透明标签；待权威映射",
        })
    args.output.write_text(
        json.dumps(rows, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    print(f"exported {len(rows)} labels to {args.output}")


if __name__ == "__main__":
    main()

