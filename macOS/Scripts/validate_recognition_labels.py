#!/usr/bin/env python3
"""Reject reordered or guessed recognition labels before packaging."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LABELS = ROOT / "Resources" / "recognition_labels.json"
EXPECTED_CLASSES = 4113


def main() -> None:
    rows = json.loads(LABELS.read_text(encoding="utf-8"))
    if not isinstance(rows, list) or len(rows) != EXPECTED_CLASSES:
        raise SystemExit(
            f"recognition label count must be {EXPECTED_CLASSES}, got {len(rows)}"
        )

    seen: set[str] = set()
    opaque = 0
    mapped = 0
    for index, row in enumerate(rows):
        if row.get("classId") != index:
            raise SystemExit(f"class order mismatch at index {index}")
        label = row.get("labelName")
        if not isinstance(label, str) or not label:
            raise SystemExit(f"empty label at class {index}")
        if label in seen:
            raise SystemExit(f"duplicate label {label!r}")
        seen.add(label)

        normalized = row.get("normalizedChar")
        if label.startswith("ZHFD-"):
            opaque += 1
            if normalized is not None:
                raise SystemExit(f"opaque label {label!r} must remain unmapped")
        elif normalized is not None:
            mapped += 1
            # Checkpoint labels that already are one Unicode character may map
            # only to themselves here. Simplified/traditional aliases belong in
            # the query database, never in the class-index mapping.
            if normalized != label or len(normalized) != 1:
                raise SystemExit(f"unsafe normalized label at class {index}")

    print(json.dumps({
        "classes": len(rows),
        "opaque_unmapped": opaque,
        "single_character_labels": mapped,
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
