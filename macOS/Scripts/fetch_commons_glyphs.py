#!/usr/bin/env python3
"""Build the complete verifiable Ancient Chinese Characters catalog.

The downloader enumerates the Wikimedia Commons ACC categories for the four
period groups shown by the app. A file is accepted only when Commons metadata:

1. explicitly identifies one encoded CJK character; and
2. reports Public Domain or CC0 reuse terms.

Opaque ACC filenames are never interpreted as characters. Their character is
read from the Commons description ("depicting the character …"). Files without
that explicit mapping are recorded in a skip report instead of being guessed.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import html
import json
import re
import subprocess
import time
import unicodedata
import urllib.parse
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "Resources" / "Glyphs"
MANIFEST_PATH = ROOT / "Resources" / "glyph_catalog.json"
CACHE_DIR = ROOT / "build" / "commons-full-cache"
AUDIT_DIR = ROOT / "Audit"
SKIP_REPORT_PATH = AUDIT_DIR / "commons-full-skipped.json"
VERIFIED_REPORT_PATH = AUDIT_DIR / "commons-full-verified.json"
API = "https://commons.wikimedia.org/w/api.php"
USER_AGENT = "AncientOCR-macOS/1.2 (offline educational glyph catalog)"

# Keep familiar characters at the beginning of the catalog. Every other
# verified character follows in Unicode order, including Extension-B+ forms.
COMMON_CHARACTERS = """
一二三四五六七八九十百千萬億零半雙兩幾
天地日月星辰年歲時分春夏秋冬朝夕早晚晝夜
東西南北中上下左右前後內外大小多少高低長短方圓遠近
山川水火木金土石風雨雲雷電冰雪江河海泉井田谷丘島
人男女子父母兄弟姐妹夫妻兒孫祖宗家族身心手足目耳口鼻
頭面首髮牙舌血骨肉皮毛力氣聲色形體病醫
牛羊馬犬豕豬雞鳥魚蟲蛇龍虎鹿象兔鼠龜貝羽角尾
禾米麥豆黍稻茶竹草花果瓜桃李桑麻林森苗葉根
門戶宮室家屋城邑國邦村里道路車舟船橋市田園
刀劍弓矢戈矛盾兵王玉鼎壺皿衣冠巾鞋絲網
書文文字冊筆墨畫圖學校師友名姓言語話音歌樂
吃飲食酒肉飯火炊農工商作業工作買賣財錢金寶
行走來去出入立坐止見看聽問答說讀寫知思念想夢
有無是非可不能會要得失成敗開關起落升降進退
愛喜怒哀樂好惡善美真實新舊清明光暗白黑紅黃青綠
正反同異平安危強弱快慢冷熱乾濕深淺輕重
天帝神鬼祭祀福禍命生死亡殺戰和平禮義德法道
元本末初終先次每全各公私我你他此彼何誰
今古明昨昔未已再常永久世代周秦漢唐宋夏商
甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥
東南西北京華中原中國天下人民文化歷史古文字
"""


@dataclass(frozen=True)
class CategorySpec:
    name: str
    period: str
    fallback_note: str
    priority: int


def category_pair(
    stem: str,
    period: str,
    note: str,
    priority: int,
) -> list[CategorySpec]:
    return [
        CategorySpec(f"{stem} characters (SVG)", period, note, priority),
        CategorySpec(f"{stem} radicals (SVG)", period, note, priority + 1),
    ]


# Both "characters" and "radicals" categories are needed: Commons uses the
# latter for many complete characters whose decomposition has been curated.
CATEGORY_SPECS = [
    *category_pair("Shang oracle script", "甲骨文", "商代甲骨文字形", 10),
    *category_pair("Western Zhou oracle script", "甲骨文", "西周甲骨文字形", 12),
    *category_pair("Shang bronze script", "金文", "商代金文字形", 20),
    *category_pair("Western Zhou bronze script", "金文", "西周金文字形", 22),
    *category_pair("Spring and Autumn bronze script", "金文", "春秋金文字形", 24),
    *category_pair("Warring States bronze script", "战国文字", "战国金文字形", 26),
    *category_pair("Bronze script", "金文", "金文字形（Commons 未细分年代）", 28),
    *category_pair("Chu slip script", "战国文字", "楚系简帛文字形", 30),
    *category_pair("Chu slip and silk script", "战国文字", "楚系简帛文字形", 32),
    *category_pair("Silk script", "战国文字", "战国帛书文字形", 34),
    *category_pair("Qin slip script", "战国文字", "秦简文字形", 36),
    *category_pair("Shuowen seal script", "小篆", "《说文》小篆字形", 40),
]

DESCRIPTION_CHARACTER = re.compile(
    r"\bdepicting\s+the\s+character\s+([^\s<（(])",
    re.IGNORECASE,
)
EXACT_FILENAME_CHARACTER = re.compile(
    r"^File:(.)-(?:oracle|bronze|silk|slip|seal)(?:[-_][A-Za-z0-9]+)*\.svg$",
    re.IGNORECASE | re.DOTALL,
)
PERIOD_ORDER = {"甲骨文": 0, "金文": 1, "战国文字": 2, "小篆": 3}


def request_json(params: dict[str, str]) -> dict:
    request_params = {"maxlag": "5", **params}
    url = API + "?" + urllib.parse.urlencode(request_params)
    arguments = [
        "curl",
        "--http1.1",
        "-fsSL",
        "--retry",
        "12",
        "--retry-all-errors",
        "--retry-delay",
        "3",
        "--connect-timeout",
        "30",
        "--max-time",
        "240",
        "-A",
        USER_AGENT,
        url,
    ]
    result = subprocess.run(arguments, check=True, capture_output=True)
    data = json.loads(result.stdout)
    if "error" in data:
        raise RuntimeError(f"Commons API error: {data['error']}")
    return data


def cached_request(
    params: dict[str, str],
    namespace: str,
    refresh: bool,
) -> dict:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(
        json.dumps(params, ensure_ascii=False, sort_keys=True).encode("utf-8")
    ).hexdigest()[:24]
    path = CACHE_DIR / f"{namespace}-{digest}.json"
    if path.exists() and not refresh:
        return json.loads(path.read_text(encoding="utf-8"))
    data = request_json(params)
    path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    return data


def clean_html(value: str) -> str:
    value = re.sub(r"<[^>]+>", " ", value or "")
    return " ".join(html.unescape(value).split())


def is_allowed_license(value: str) -> bool:
    normalized = value.casefold().replace("-", " ")
    return (
        "public domain" in normalized
        or "cc0" in normalized
        or "cc zero" in normalized
    )


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


def explicit_character(title: str, raw_description: str) -> str | None:
    description = clean_html(raw_description)
    match = DESCRIPTION_CHARACTER.search(description)
    if match:
        character = unicodedata.normalize("NFC", match.group(1))
        if is_cjk_scalar(character):
            return character

    # Human-readable one-character filenames are also explicit mappings. This
    # fallback never applies to ACC-j01234-style opaque identifiers.
    match = EXACT_FILENAME_CHARACTER.match(title)
    if match:
        character = unicodedata.normalize("NFC", match.group(1))
        if is_cjk_scalar(character):
            return character
    return None


def resolved_period_and_note(
    spec: CategorySpec,
    description: str,
) -> tuple[str, str]:
    lower = description.casefold()
    if "western zhou oracle" in lower:
        return "甲骨文", "西周甲骨文字形"
    if "shang oracle" in lower:
        return "甲骨文", "商代甲骨文字形"
    if "warring states bronze" in lower:
        return "战国文字", "战国金文字形"
    if "spring and autumn bronze" in lower:
        return "金文", "春秋金文字形"
    if "western zhou bronze" in lower:
        return "金文", "西周金文字形"
    if "shang bronze" in lower:
        return "金文", "商代金文字形"
    if "qin slip" in lower:
        return "战国文字", "秦简文字形"
    if "chu" in lower and ("slip" in lower or "silk" in lower):
        return "战国文字", "楚系简帛文字形"
    if "shuowen seal" in lower:
        return "小篆", "《说文》小篆字形"
    return spec.period, spec.fallback_note


def enumerate_category(
    spec: CategorySpec,
    refresh: bool,
) -> list[str]:
    titles: list[str] = []
    continuation: str | None = None
    page_number = 0
    while True:
        params = {
            "action": "query",
            "format": "json",
            "formatversion": "2",
            "list": "categorymembers",
            "cmtitle": f"Category:{spec.name}",
            "cmnamespace": "6",
            "cmtype": "file",
            "cmlimit": "500",
        }
        if continuation:
            params["cmcontinue"] = continuation
        data = cached_request(
            params,
            f"category-{page_number}",
            refresh,
        )
        titles.extend(
            item["title"]
            for item in data.get("query", {}).get("categorymembers", [])
        )
        continuation = data.get("continue", {}).get("cmcontinue")
        if not continuation:
            break
        page_number += 1
        time.sleep(0.18)
    return titles


def discover_titles(refresh: bool) -> dict[str, CategorySpec]:
    by_title: dict[str, CategorySpec] = {}
    for index, spec in enumerate(CATEGORY_SPECS, start=1):
        titles = enumerate_category(spec, refresh)
        for title in titles:
            previous = by_title.get(title)
            if previous is None or spec.priority < previous.priority:
                by_title[title] = spec
        print(
            f"categories {index:02d}/{len(CATEGORY_SPECS)} "
            f"{spec.name}: {len(titles)} files",
            flush=True,
        )
        time.sleep(0.22)
    return by_title


def cached_export(titles: list[str], refresh: bool) -> bytes:
    """Download current file-page wikitext in a large Special:Export batch."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256("\n".join(titles).encode("utf-8")).hexdigest()[:24]
    path = CACHE_DIR / f"export-{digest}.xml"
    if path.exists() and not refresh:
        return path.read_bytes()
    result = subprocess.run(
        [
            "curl",
            "--http1.1",
            "-fsSL",
            "--retry",
            "12",
            "--retry-all-errors",
            "--retry-delay",
            "3",
            "--connect-timeout",
            "30",
            "--max-time",
            "300",
            "-A",
            USER_AGENT,
            "-X",
            "POST",
            "https://commons.wikimedia.org/wiki/Special:Export",
            "--data-urlencode",
            "pages=" + "\n".join(titles),
            "--data",
            "curonly=1",
            "--data",
            "wpDownload=1",
        ],
        check=True,
        capture_output=True,
    )
    if not result.stdout.startswith(b"<mediawiki"):
        raise RuntimeError("Commons Special:Export returned invalid XML")
    path.write_bytes(result.stdout)
    return result.stdout


def character_from_wikitext(title: str, wikitext: str) -> str | None:
    """Read the explicit character argument from ACClicense, never its ID."""
    for match in re.finditer(r"\{\{\s*ACClicense\s*\|(.+?)\}\}", wikitext, re.I | re.S):
        for raw_token in match.group(1).split("|"):
            token = raw_token.strip()
            if "=" in token:
                token = token.split("=", 1)[1].strip()
            token = unicodedata.normalize("NFC", html.unescape(token))
            if is_cjk_scalar(token):
                return token
    return explicit_character(title, wikitext)


def verified_license_from_wikitext(wikitext: str) -> str | None:
    normalized = re.sub(r"\s+", "", wikitext).casefold()
    if "{{acclicense|" in normalized:
        return "Public domain (ACClicense)"
    if any(marker in normalized for marker in (
        "{{self|cc-zero",
        "{{cc-zero",
        "{{cc0",
        "{{self|cc0",
    )):
        return "CC0 1.0"
    if any(marker in normalized for marker in (
        "{{pdancientscript",
        "{{pd-ancient-script",
        "{{pd-old",
    )):
        return "Public domain"
    return None


def export_pages(payload: bytes) -> list[tuple[str, int, str]]:
    root = ET.fromstring(payload)
    output: list[tuple[str, int, str]] = []
    for page in root.findall("{*}page"):
        title = page.findtext("{*}title") or ""
        page_id_text = page.findtext("{*}id") or "0"
        revision = page.find("{*}revision")
        text_node = revision.find("{*}text") if revision is not None else None
        wikitext = text_node.text if text_node is not None and text_node.text else ""
        try:
            page_id = int(page_id_text)
        except ValueError:
            page_id = 0
        output.append((title, page_id, wikitext))
    return output


def query_assets(
    by_title: dict[str, CategorySpec],
    refresh: bool,
) -> tuple[list[dict], list[dict]]:
    """Parse explicit mappings and PD/CC0 templates from Commons page source."""
    assets: list[dict] = []
    skipped_by_title: dict[str, dict] = {}
    returned_titles: set[str] = set()
    titles = sorted(by_title)
    batch_size = 400
    total_batches = (len(titles) + batch_size - 1) // batch_size
    for batch_index, offset in enumerate(range(0, len(titles), batch_size), start=1):
        batch_titles = titles[offset:offset + batch_size]
        for title, page_id, wikitext in export_pages(
            cached_export(batch_titles, refresh)
        ):
            returned_titles.add(title)
            spec = by_title.get(title)
            if spec is None:
                skipped_by_title[title] = {
                    "title": title,
                    "reason": "category mapping missing",
                }
                continue
            character = character_from_wikitext(title, wikitext)
            if character is None:
                skipped_by_title[title] = {
                    "title": title,
                    "reason": "no explicit single-CJK mapping",
                }
                continue
            license_name = verified_license_from_wikitext(wikitext)
            if license_name is None:
                skipped_by_title[title] = {
                    "title": title,
                    "reason": "page source has no verified Public Domain/CC0 template",
                }
                continue
            if page_id <= 0:
                skipped_by_title[title] = {
                    "title": title,
                    "reason": "stable page id missing",
                }
                continue
            period, note = resolved_period_and_note(spec, wikitext)
            filename = title.removeprefix("File:")
            normalized_filename = filename.replace(" ", "_")
            encoded_title = urllib.parse.quote(title.replace(" ", "_"), safe=":_-().")
            assets.append({
                "character": character,
                "period": period,
                "asset": f"commons-{page_id}.png",
                "source": "Wikimedia Commons · Ancient Chinese Characters",
                "sourceNumber": title,
                "sourceURL": f"https://commons.wikimedia.org/wiki/{encoded_title}",
                "transcription": character,
                "license": license_name,
                "notes": note + " · 公有领域/CC0",
                "downloadURL": (
                    "https://commons.wikimedia.org/w/thumb.php?"
                    + urllib.parse.urlencode({"f": normalized_filename, "width": "250"})
                ),
            })
        print(
            f"source verification {batch_index}/{total_batches}: "
            f"accepted {len(assets)}, skipped {len(skipped_by_title)}",
            flush=True,
        )
        time.sleep(0.20)

    for title in set(by_title) - returned_titles:
        skipped_by_title[title] = {
            "title": title,
            "reason": "Special:Export did not return page",
        }
    return assets, [skipped_by_title[title] for title in sorted(skipped_by_title)]


def has_valid_png(path: Path) -> bool:
    try:
        if path.stat().st_size < 200:
            return False
        with path.open("rb") as handle:
            return handle.read(8) == b"\x89PNG\r\n\x1a\n"
    except OSError:
        return False


def download_asset(asset: dict) -> tuple[str, str | None, bool]:
    candidates = [asset, *asset.get("_alternatives", [])]
    errors: list[str] = []
    for candidate in candidates:
        target = OUTPUT_DIR / candidate["asset"]
        if has_valid_png(target):
            if candidate is not asset:
                alternatives = asset.get("_alternatives", [])
                asset.clear()
                asset.update(candidate)
                asset["_alternatives"] = alternatives
            return candidate["asset"], None, True
        try:
            result = subprocess.run(
                [
                    "curl",
                    "--http1.1",
                    "-fsSL",
                    "--retry",
                    "6",
                    "--retry-all-errors",
                    "--retry-delay",
                    "1",
                    "--retry-max-time",
                    "180",
                    "--connect-timeout",
                    "30",
                    "--max-time",
                    "120",
                    "-A",
                    USER_AGENT,
                    candidate["downloadURL"],
                ],
                check=True,
                capture_output=True,
            )
            payload = result.stdout
            if len(payload) < 200 or not payload.startswith(b"\x89PNG\r\n\x1a\n"):
                errors.append(f"{candidate['sourceNumber']}: invalid PNG response")
                continue
            temporary = target.with_suffix(".png.part")
            temporary.write_bytes(payload)
            temporary.replace(target)
            if candidate is not asset:
                alternatives = asset.get("_alternatives", [])
                asset.clear()
                asset.update(candidate)
                asset["_alternatives"] = alternatives
            # thumb.php is the documented thumbnail endpoint; keep a small pause so
            # a local rebuild still remains courteous to the shared service.
            time.sleep(0.12)
            return candidate["asset"], None, False
        except Exception as error:
            errors.append(f"{candidate['sourceNumber']}: {error}")
    return asset["asset"], " | ".join(errors), False


def ordered_characters(assets: list[dict]) -> list[str]:
    available = {item["character"] for item in assets}
    output: list[str] = []
    seen: set[str] = set()
    for character in COMMON_CHARACTERS:
        if character.isspace() or character not in available or character in seen:
            continue
        seen.add(character)
        output.append(character)
    output.extend(sorted(available - seen, key=lambda value: tuple(map(ord, value))))
    return output


def representative_assets(assets: list[dict]) -> list[dict]:
    """Keep one clear source image for every character/period combination.

    Commons often stores dozens of traced variants for the same character and
    era. The query tool needs complete character and period coverage, not 241
    visually near-identical cards for one period. Human-readable canonical
    filenames are preferred; otherwise the stable ACC source order is used.
    """
    canonical = re.compile(
        r"^File:.-(?:oracle|bronze|silk|slip|seal)\.svg$",
        re.IGNORECASE | re.DOTALL,
    )

    def preference(item: dict) -> tuple[int, str, str]:
        title = item["sourceNumber"]
        if canonical.match(title):
            tier = 0
        elif EXACT_FILENAME_CHARACTER.match(title):
            tier = 1
        else:
            tier = 2
        return tier, title.casefold(), title

    grouped: dict[tuple[str, str], list[dict]] = {}
    for item in assets:
        key = item["character"], item["period"]
        grouped.setdefault(key, []).append(item)

    selected: list[dict] = []
    for group in grouped.values():
        ordered = sorted(group, key=preference)
        primary = dict(ordered[0])
        primary["_alternatives"] = ordered[1:]
        selected.append(primary)
    return selected


def reuse_existing_assets(assets: list[dict]) -> int:
    """Reuse already-downloaded canonical PNGs from the previous catalog."""
    reused = 0
    for item in assets:
        title = item["sourceNumber"]
        if not title.startswith("File:") or not title.endswith(".svg"):
            continue
        legacy_name = title.removeprefix("File:").removesuffix(".svg") + ".png"
        if has_valid_png(OUTPUT_DIR / legacy_name):
            item["asset"] = legacy_name
            reused += 1
    return reused


def build_manifest(assets: list[dict]) -> list[dict]:
    characters = ordered_characters(assets)
    rank_by_character = {
        character: rank for rank, character in enumerate(characters)
    }
    assets.sort(key=lambda item: (
        rank_by_character[item["character"]],
        PERIOD_ORDER.get(item["period"], 99),
        item["sourceNumber"].casefold(),
        item["sourceNumber"],
    ))
    manifest: list[dict] = []
    seen_sources: set[str] = set()
    for source in assets:
        if source["sourceNumber"] in seen_sources:
            continue
        seen_sources.add(source["sourceNumber"])
        item = dict(source)
        item.pop("downloadURL", None)
        item.pop("_alternatives", None)
        item["rank"] = rank_by_character[item["character"]]
        manifest.append(item)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="ignore cached Commons API responses",
    )
    parser.add_argument("--workers", type=int, default=2)
    args = parser.parse_args()
    if not 1 <= args.workers <= 32:
        raise SystemExit("--workers must be between 1 and 32")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    AUDIT_DIR.mkdir(parents=True, exist_ok=True)
    by_title = discover_titles(args.refresh)
    print(f"unique source files discovered: {len(by_title)}", flush=True)
    assets, skipped = query_assets(by_title, args.refresh)
    verified_source_count = len(assets)
    VERIFIED_REPORT_PATH.write_text(
        json.dumps(
            [
                {key: value for key, value in item.items() if key != "downloadURL"}
                for item in assets
            ],
            ensure_ascii=False,
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )
    assets = representative_assets(assets)
    legacy_reused = reuse_existing_assets(assets)
    print(
        f"representative character-period glyphs: {len(assets)} "
        f"from {verified_source_count} verified sources; "
        f"legacy PNGs reused {legacy_reused}",
        flush=True,
    )

    failures: dict[str, str] = {}
    reused = 0
    downloaded = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = [executor.submit(download_asset, asset) for asset in assets]
        for index, future in enumerate(concurrent.futures.as_completed(futures), start=1):
            name, error, was_reused = future.result()
            if error:
                failures[name] = error
            elif was_reused:
                reused += 1
            else:
                downloaded += 1
            if index % 100 == 0 or index == len(futures):
                print(
                    f"downloads {index}/{len(futures)}: "
                    f"new {downloaded}, cached {reused}, failed {len(failures)}",
                    flush=True,
                )
    if failures:
        sample = ", ".join(
            f"{name}: {reason}" for name, reason in list(failures.items())[:12]
        )
        raise SystemExit(f"{len(failures)} downloads failed: {sample}")

    manifest = build_manifest(assets)
    MANIFEST_PATH.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    SKIP_REPORT_PATH.write_text(
        json.dumps(skipped, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    periods = {
        period: sum(item["period"] == period for item in manifest)
        for period in PERIOD_ORDER
    }
    print(json.dumps({
        "source_files_discovered": len(by_title),
        "verified_source_files": verified_source_count,
        "characters_with_glyphs": len({item["character"] for item in manifest}),
        "extension_b_or_later_characters": len({
            item["character"] for item in manifest if ord(item["character"]) > 0xFFFF
        }),
        "glyphs": len(manifest),
        "periods": periods,
        "skipped_unmapped_or_unlicensed": len(skipped),
        "downloaded": downloaded,
        "reused": reused,
        "manifest": str(MANIFEST_PATH),
        "skip_report": str(SKIP_REPORT_PATH),
        "verified_report": str(VERIFIED_REPORT_PATH),
    }, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
