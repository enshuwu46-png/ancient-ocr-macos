#!/usr/bin/env python3
"""Add sourced Chinese character meanings from Chinese Wiktionary.

The script uses the public MediaWiki API in batches, keeps a resumable cache,
and only extracts text explicitly placed in the Chinese ``释义`` section. It
does not manufacture period-specific meanings from glyph dates.
"""

from __future__ import annotations

import argparse
import bz2
import concurrent.futures
import html
import json
import re
import subprocess
import time
import urllib.parse
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
METADATA = ROOT / "Resources" / "character_metadata.json"
AUDIT = ROOT / "Audit" / "wiktionary-definition-summary.json"
API = "https://zh.wiktionary.org/w/api.php"
USER_AGENT = "AncientOCR/1.0.0 (offline dictionary builder)"
LANGUAGE_HEADING = re.compile(r"^==\s*(?:汉语|漢語)\s*==\s*$", re.MULTILINE)
DEFINITION_HEADING = re.compile(r"^===\s*(?:释义|釋義)\s*===\s*$", re.MULTILINE)
NEXT_HEADING = re.compile(r"^={2,3}[^=].*?={2,3}\s*$", re.MULTILINE)
WIKITEXT_LANGUAGE_HEADING = re.compile(r"^==\s*(?:汉语|漢語)\s*==\s*$", re.MULTILINE)
WIKITEXT_DEFINITION_HEADING = re.compile(r"^===\s*(?:释义|釋義)\s*===\s*$", re.MULTILINE)
WIKITEXT_NEXT_HEADING = re.compile(r"^={2,3}[^=].*?={2,3}\s*$", re.MULTILINE)


def clean_definition(extract: str) -> str | None:
    language = LANGUAGE_HEADING.search(extract)
    if not language:
        return None
    next_language = re.search(r"^==[^=].*?==\s*$", extract[language.end():], re.MULTILINE)
    language_end = language.end() + (next_language.start() if next_language else len(extract))
    chinese_section = extract[language.end():language_end]
    heading = DEFINITION_HEADING.search(chinese_section)
    if not heading:
        return None
    remainder = chinese_section[heading.end():]
    next_heading = NEXT_HEADING.search(remainder)
    block = remainder[:next_heading.start()] if next_heading else remainder

    meanings: list[str] = []
    for raw_line in block.splitlines():
        line = re.sub(r"\s+", " ", raw_line).strip(" \t•*#")
        if not line:
            continue
        # The first parenthesized line is normally a pronunciation inventory,
        # not a meaning. Keep parenthesized usage labels on later lines.
        if not meanings and line.startswith(("（", "(")) and any(
            marker in line for marker in ("ㄅ", "ㄆ", "ㄇ", "粤", "粵", "切", "mǎ")
        ):
            continue
        if line.startswith(("见：", "見：", "参见", "參見")):
            continue
        meanings.append(line.rstrip("。；"))
        if len(meanings) >= 8:
            break
    if not meanings:
        return None
    value = "；".join(meanings)
    return value[:900].rstrip("；")


def fetch_batch(characters: list[str]) -> dict[str, str]:
    parameters = {
        "action": "query",
        "prop": "extracts",
        "explaintext": "1",
        "exlimit": "max",
        "redirects": "1",
        "titles": "|".join(characters),
        "format": "json",
        "formatversion": "2",
        "uselang": "zh-hans",
    }
    command = ["curl", "-fsSLG", "--max-time", "60", "-A", USER_AGENT, API]
    for key, value in parameters.items():
        command.extend(["--data-urlencode", f"{key}={value}"])
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    payload = json.loads(completed.stdout)
    result: dict[str, str] = {}
    for page in payload.get("query", {}).get("pages", []):
        title = page.get("title")
        extract = page.get("extract")
        if isinstance(title, str) and isinstance(extract, str):
            definition = clean_definition(extract)
            if definition:
                result[title] = definition
    return result


def fetch_resilient(characters: list[str]) -> dict[str, str]:
    """Retry transient Wikimedia/CDN failures, then split a failing batch."""
    last_error: Exception | None = None
    for attempt in range(5):
        try:
            return fetch_batch(characters)
        except Exception as error:
            last_error = error
            time.sleep(min(8, 2 ** attempt))
    if len(characters) > 1:
        middle = len(characters) // 2
        return fetch_resilient(characters[:middle]) | fetch_resilient(characters[middle:])
    print(f"Wiktionary skipped {characters[0]} after retries: {last_error}", flush=True)
    return {}


def strip_wikitext(value: str) -> str:
    value = re.sub(r"<!--.*?-->", "", value, flags=re.DOTALL)
    value = re.sub(r"<ref\b[^>]*>.*?</ref>|<ref\b[^>]*/>", "", value, flags=re.DOTALL)
    value = re.sub(r"<[^>]+>", "", value)
    value = re.sub(
        r"\[\[([^\]|]+)\|([^\]]+)\]\]",
        lambda match: match.group(2),
        value,
    )
    value = re.sub(r"\[\[([^\]]+)\]\]", lambda match: match.group(1), value)
    # Templates normally add labels, pronunciation, or examples. Removing them
    # is safer than presenting unexpanded template syntax as a definition.
    previous = None
    while previous != value:
        previous = value
        value = re.sub(r"\{\{[^{}]*\}\}", "", value)
    value = value.replace("'''", "").replace("''", "")
    value = re.sub(r"\[(?:https?://\S+)(?:\s+([^\]]+))?\]", r"\1", value)
    value = re.sub(r"\s+", " ", html.unescape(value)).strip(" ：:;；。")
    return value


def clean_wikitext_definition(wikitext: str) -> str | None:
    language = WIKITEXT_LANGUAGE_HEADING.search(wikitext)
    if not language:
        return None
    following_language = re.search(
        r"^==[^=].*?==\s*$",
        wikitext[language.end():],
        re.MULTILINE,
    )
    language_end = (
        language.end() + following_language.start()
        if following_language else len(wikitext)
    )
    chinese_section = wikitext[language.end():language_end]
    heading = WIKITEXT_DEFINITION_HEADING.search(chinese_section)
    if not heading:
        return None
    remainder = chinese_section[heading.end():]
    next_heading = WIKITEXT_NEXT_HEADING.search(remainder)
    block = remainder[:next_heading.start()] if next_heading else remainder
    meanings: list[str] = []
    for raw_line in block.splitlines():
        stripped = raw_line.lstrip()
        if not stripped.startswith("#") or stripped.startswith(("#:", "#*")):
            continue
        # Keep only top-level senses. Nested definitions usually depend on a
        # parent sense and become misleading when flattened.
        content = stripped[1:].strip()
        if content.startswith("#"):
            continue
        meaning = strip_wikitext(content)
        if len(meaning) < 2 or meaning.lower() in {"rfdef", "rfd-sense"}:
            continue
        meanings.append(meaning)
        if len(meanings) >= 8:
            break
    if not meanings:
        return None
    return "；".join(meanings)[:900].rstrip("；")


def definitions_from_dump(dump_path: Path, wanted: set[str]) -> dict[str, str | None]:
    """Stream the official compressed dump without expanding it on disk."""
    result: dict[str, str | None] = {}
    with bz2.open(dump_path, "rb") as source:
        for _, element in ET.iterparse(source, events=("end",)):
            if not element.tag.endswith("page"):
                continue
            title_node = next((node for node in element if node.tag.endswith("title")), None)
            title = title_node.text if title_node is not None else None
            if title in wanted:
                text_node = next(
                    (node for node in element.iter() if node.tag.endswith("text")),
                    None,
                )
                wikitext = text_node.text if text_node is not None else None
                result[title] = clean_wikitext_definition(wikitext or "")
                if len(result) % 100 == 0:
                    print(f"Wiktionary dump {len(result)}/{len(wanted)}", flush=True)
            element.clear()
    return result


def fetch_wikitext_batch(characters: list[str]) -> dict[str, str]:
    """Fetch source text for several pages in one lightweight query request."""
    parameters = {
        "action": "query",
        "prop": "revisions",
        "rvprop": "content",
        "rvslots": "main",
        "redirects": "1",
        "titles": "|".join(characters),
        "format": "json",
        "formatversion": "2",
    }
    command = ["curl", "-fsSLG", "--max-time", "90", "-A", USER_AGENT, API]
    for key, value in parameters.items():
        command.extend(["--data-urlencode", f"{key}={value}"])
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    payload = json.loads(completed.stdout)
    result: dict[str, str] = {}
    for page in payload.get("query", {}).get("pages", []):
        title = page.get("title")
        revisions = page.get("revisions") or []
        if not isinstance(title, str) or not revisions:
            continue
        wikitext = revisions[0].get("slots", {}).get("main", {}).get("content")
        if isinstance(wikitext, str):
            definition = clean_wikitext_definition(wikitext)
            if definition:
                result[title] = definition
    return result


def fetch_wikitext_resilient(characters: list[str]) -> dict[str, str]:
    last_error: Exception | None = None
    for attempt in range(5):
        try:
            return fetch_wikitext_batch(characters)
        except Exception as error:
            last_error = error
            time.sleep(min(8, 2 ** attempt))
    if len(characters) > 1:
        middle = len(characters) // 2
        return (
            fetch_wikitext_resilient(characters[:middle])
            | fetch_wikitext_resilient(characters[middle:])
        )
    print(f"Wiktionary skipped {characters[0]} after retries: {last_error}", flush=True)
    return {}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=Path, default=ROOT / "build" / "wiktionary-definitions.json")
    parser.add_argument("--dump", type=Path, help="official pages-articles.xml.bz2 dump")
    parser.add_argument("--batch-size", type=int, default=35)
    parser.add_argument("--delay", type=float, default=0.2)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument(
        "--missing-only",
        action="store_true",
        help="only fill rows that do not already have a sourced Chinese definition",
    )
    args = parser.parse_args()

    rows = json.loads(METADATA.read_text(encoding="utf-8"))
    cache: dict[str, str | None] = {}
    if args.cache.exists():
        cache = json.loads(args.cache.read_text(encoding="utf-8"))
    targets = [
        row["character"] for row in rows
        if not args.missing_only or not row.get("chineseDefinition")
    ]
    pending = [
        character for character in targets
        if character not in cache or (args.missing_only and not cache.get(character))
    ]

    args.cache.parent.mkdir(parents=True, exist_ok=True)
    if args.dump:
        if not args.dump.is_file():
            raise SystemExit(f"dump does not exist: {args.dump}")
        cache.update(definitions_from_dump(args.dump, set(targets)))
    else:
        batches = [
            pending[offset:offset + args.batch_size]
            for offset in range(0, len(pending), args.batch_size)
        ]
        # Revision-source queries support multiple titles. A small, bounded
        # worker pool keeps the official API practical without a high request
        # rate, and source parsing avoids mistaking usage examples for senses.
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures = {
                pool.submit(fetch_wikitext_resilient, batch): batch
                for batch in batches
            }
            completed_count = 0
            for future in concurrent.futures.as_completed(futures):
                batch = futures[future]
                definitions = future.result()
                for character in batch:
                    cache[character] = definitions.get(character)
                completed_count += len(batch)
                if completed_count % 100 < len(batch) or completed_count == len(pending):
                    args.cache.write_text(
                        json.dumps(cache, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8",
                    )
                    print(f"Wiktionary {completed_count}/{len(pending)}", flush=True)

    args.cache.write_text(
        json.dumps(cache, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    for row in rows:
        if args.missing_only and row.get("chineseDefinition"):
            continue
        row["chineseDefinition"] = cache.get(row["character"])
        row["definitionSource"] = (
            f"https://zh.wiktionary.org/wiki/{urllib.parse.quote(row['character'])}"
            if row["chineseDefinition"] else None
        )
    METADATA.write_text(
        json.dumps(rows, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    summary = {
        "source": "https://zh.wiktionary.org/",
        "license": "CC BY-SA 4.0",
        "characters": len(rows),
        "with_chinese_definition": sum(bool(row["chineseDefinition"]) for row in rows),
        "missing_chinese_definition": sum(not row["chineseDefinition"] for row in rows),
        "extraction_rule": "Chinese section / 释义 subsection only",
    }
    AUDIT.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
