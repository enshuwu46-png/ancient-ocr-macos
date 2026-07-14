#!/usr/bin/env python3
"""Build catalog metadata from the official Unicode Unihan archive.

Direct simplified/traditional/Z variants are safe search aliases. Semantic and
specialized semantic variants are displayed as related forms but deliberately
are not treated as exact aliases.
"""

from __future__ import annotations

import argparse
import collections
import json
import re
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "Resources" / "glyph_catalog.json"
OUTPUT = ROOT / "Resources" / "character_metadata.json"
AUDIT = ROOT / "Audit" / "unihan-metadata-summary.json"
DIRECT_PROPERTIES = {"kSimplifiedVariant", "kTraditionalVariant", "kZVariant"}
RELATED_PROPERTIES = {"kSemanticVariant", "kSpecializedSemanticVariant"}
CODEPOINT = re.compile(r"U\+([0-9A-F]{4,6})")


def parse_character(value: str) -> str:
    return chr(int(value.removeprefix("U+"), 16))


def parse_targets(value: str) -> set[str]:
    return {chr(int(match, 16)) for match in CODEPOINT.findall(value)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "archive",
        type=Path,
        help="official Unihan.zip from unicode.org",
    )
    args = parser.parse_args()

    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    characters = sorted({row["character"] for row in manifest}, key=ord)
    direct: dict[str, set[str]] = collections.defaultdict(set)
    related: dict[str, set[str]] = collections.defaultdict(set)
    definitions: dict[str, str] = {}

    with zipfile.ZipFile(args.archive) as archive:
        variant_lines = archive.read("Unihan_Variants.txt").decode("utf-8").splitlines()
        reading_lines = archive.read("Unihan_Readings.txt").decode("utf-8").splitlines()

    for line in variant_lines:
        if not line or line.startswith("#"):
            continue
        source_code, property_name, value = line.split("\t", 2)
        source = parse_character(source_code)
        targets = parse_targets(value) - {source}
        if property_name in DIRECT_PROPERTIES:
            for target in targets:
                # These three properties describe encoded-form equivalence, so
                # make the display/search relation available from either side.
                direct[source].add(target)
                direct[target].add(source)
        elif property_name in RELATED_PROPERTIES:
            for target in targets:
                # Semantic variants can be context-dependent. Show both sides,
                # but never insert them as exact search aliases.
                related[source].add(target)
                related[target].add(source)

    for line in reading_lines:
        if not line or line.startswith("#"):
            continue
        source_code, property_name, value = line.split("\t", 2)
        if property_name == "kDefinition":
            definitions[parse_character(source_code)] = value.strip()

    rows = []
    for character in characters:
        rows.append({
            "character": character,
            "directVariants": sorted(direct[character], key=ord),
            "relatedVariants": sorted(related[character] - direct[character], key=ord),
            "definition": definitions.get(character),
        })

    OUTPUT.write_text(
        json.dumps(rows, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    summary = {
        "unicode_version": "17.0.0",
        "source": "https://www.unicode.org/Public/UCD/latest/ucd/Unihan.zip",
        "characters": len(rows),
        "with_direct_variants": sum(bool(row["directVariants"]) for row in rows),
        "with_related_variants": sum(bool(row["relatedVariants"]) for row in rows),
        "with_definitions": sum(bool(row["definition"]) for row in rows),
        "direct_variant_edges": sum(len(row["directVariants"]) for row in rows),
        "related_variant_edges": sum(len(row["relatedVariants"]) for row in rows),
    }
    AUDIT.parent.mkdir(parents=True, exist_ok=True)
    AUDIT.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
