#!/usr/bin/env python3
"""Validate Unicode-derived character metadata before packaging."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "Resources" / "glyph_catalog.json"
METADATA = ROOT / "Resources" / "character_metadata.json"


def main() -> None:
    glyph_rows = json.loads(MANIFEST.read_text(encoding="utf-8"))
    expected = {row["character"] for row in glyph_rows}
    rows = json.loads(METADATA.read_text(encoding="utf-8"))
    found = {row.get("character") for row in rows}
    if len(rows) != len(expected) or found != expected:
        raise SystemExit("character metadata does not cover the complete glyph catalog")

    for row in rows:
        character = row["character"]
        for field in ("directVariants", "relatedVariants"):
            values = row.get(field)
            if not isinstance(values, list) or len(values) != len(set(values)):
                raise SystemExit(f"invalid {field} for {character}")
            if character in values or any(len(value) != 1 for value in values):
                raise SystemExit(f"unsafe {field} value for {character}")
        if set(row["directVariants"]) & set(row["relatedVariants"]):
            raise SystemExit(f"overlapping variant classes for {character}")
        definition = row.get("definition")
        if definition is not None and not isinstance(definition, str):
            raise SystemExit(f"invalid definition for {character}")
        chinese_definition = row.get("chineseDefinition")
        definition_source = row.get("definitionSource")
        if chinese_definition is not None and not isinstance(chinese_definition, str):
            raise SystemExit(f"invalid Chinese definition for {character}")
        permitted_sources = (
            "https://zh.wiktionary.org/wiki/",
            "https://language.moe.gov.tw/001/Upload/Files/site_content/",
        )
        if chinese_definition and not (
            isinstance(definition_source, str)
            and definition_source.startswith(permitted_sources)
        ):
            raise SystemExit(f"missing definition source for {character}")

    print(json.dumps({
        "characters": len(rows),
        "with_direct_variants": sum(bool(row["directVariants"]) for row in rows),
        "with_related_variants": sum(bool(row["relatedVariants"]) for row in rows),
        "with_unihan_definition": sum(bool(row.get("definition")) for row in rows),
        "with_chinese_definition": sum(bool(row.get("chineseDefinition")) for row in rows),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
