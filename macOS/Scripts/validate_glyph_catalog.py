#!/usr/bin/env python3
"""Validate every bundled glyph before building the macOS app."""

from __future__ import annotations

import collections
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "Resources" / "glyph_catalog.json"
GLYPHS = ROOT / "Resources" / "Glyphs"
PERIODS = {"甲骨文", "金文", "战国文字", "小篆"}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def is_cjk_scalar(value: str) -> bool:
    if len(value) != 1:
        return False
    codepoint = ord(value)
    return any(
        start <= codepoint <= end
        for start, end in (
            (0x3400, 0x4DBF),
            (0x4E00, 0x9FFF),
            (0xF900, 0xFAFF),
            (0x20000, 0x2FA1F),
            (0x30000, 0x3347F),
        )
    )


def main() -> None:
    rows = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if not isinstance(rows, list) or not rows:
        raise SystemExit("glyph_catalog.json is empty or invalid")

    sources: set[str] = set()
    character_periods: set[tuple[str, str]] = set()
    ranks_by_character: dict[str, int] = {}
    errors: list[str] = []
    required = {
        "character", "period", "asset", "source", "sourceNumber",
        "sourceURL", "transcription", "license", "notes", "rank",
    }
    for index, row in enumerate(rows):
        missing = required - row.keys()
        if missing:
            errors.append(f"row {index}: missing {sorted(missing)}")
            continue
        character = row["character"]
        period = row["period"]
        source_number = row["sourceNumber"]
        asset_name = row["asset"]
        if not is_cjk_scalar(character):
            errors.append(f"row {index}: not one encoded CJK scalar: {character!r}")
        if row["transcription"] != character:
            errors.append(f"row {index}: transcription mismatch")
        if period not in PERIODS:
            errors.append(f"row {index}: unsupported period {period!r}")
        if (character, period) in character_periods:
            errors.append(f"row {index}: duplicate character/period {character}-{period}")
        character_periods.add((character, period))
        if source_number in sources:
            errors.append(f"row {index}: duplicate Commons source {source_number}")
        sources.add(source_number)
        if not source_number.startswith("File:") or not source_number.endswith(".svg"):
            errors.append(f"row {index}: invalid Commons filename {source_number!r}")
        if Path(asset_name).name != asset_name:
            errors.append(f"row {index}: unsafe asset path {asset_name!r}")
        rank = row["rank"]
        if not isinstance(rank, int) or rank < 0:
            errors.append(f"row {index}: invalid rank {rank!r}")
        elif character in ranks_by_character and ranks_by_character[character] != rank:
            errors.append(f"row {index}: inconsistent rank for {character}")
        else:
            ranks_by_character[character] = rank
        if not row["sourceURL"].startswith("https://commons.wikimedia.org/wiki/"):
            errors.append(f"row {index}: non-Commons source URL")
        if not (
            row["license"].startswith("Public domain")
            or row["license"].startswith("CC0")
        ):
            errors.append(f"row {index}: unsupported license {row['license']!r}")

        asset = GLYPHS / row["asset"]
        try:
            with asset.open("rb") as handle:
                if handle.read(8) != PNG_SIGNATURE:
                    errors.append(f"row {index}: invalid PNG {asset.name}")
            if asset.stat().st_size < 200:
                errors.append(f"row {index}: truncated PNG {asset.name}")
        except OSError:
            errors.append(f"row {index}: missing asset {asset.name}")

    expected_ranks = set(range(len(ranks_by_character)))
    if set(ranks_by_character.values()) != expected_ranks:
        errors.append("catalog character ranks are not contiguous")

    if errors:
        sample = "\n".join(errors[:30])
        raise SystemExit(f"{len(errors)} catalog errors:\n{sample}")

    period_counts = collections.Counter(row["period"] for row in rows)
    characters = {row["character"] for row in rows}
    print(json.dumps({
        "characters": len(characters),
        "glyphs": len(rows),
        "extension_b_or_later": sum(ord(character) > 0xFFFF for character in characters),
        "periods": dict(period_counts),
        "assets_bytes": sum((GLYPHS / row["asset"]).stat().st_size for row in rows),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
