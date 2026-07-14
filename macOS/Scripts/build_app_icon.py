#!/usr/bin/env python3
"""Create the macOS icon from the verified oracle-script 古 asset."""

from pathlib import Path
import subprocess

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Resources" / "Glyphs" / "古-oracle.png"
BASE = ROOT / "Resources" / "AppIcon.png"
ICONSET = ROOT / "build" / "AppIcon.iconset"
ICNS = ROOT / "Resources" / "AppIcon.icns"
BEIGE = (246, 241, 231, 255)


def main() -> None:
    glyph = Image.open(SOURCE).convert("RGBA")
    alpha_box = glyph.getchannel("A").getbbox()
    if not alpha_box:
        raise SystemExit("古-oracle.png has no visible glyph")
    glyph = glyph.crop(alpha_box)
    glyph.thumbnail((610, 610), Image.Resampling.LANCZOS)

    canvas = Image.new("RGBA", (1024, 1024), BEIGE)
    position = ((1024 - glyph.width) // 2, (1024 - glyph.height) // 2 - 8)
    canvas.alpha_composite(glyph, position)
    canvas.convert("RGB").save(BASE, quality=100)

    ICONSET.mkdir(parents=True, exist_ok=True)
    sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    for size, name in sizes:
        canvas.resize((size, size), Image.Resampling.LANCZOS).convert("RGB").save(ICONSET / name)
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)
    print(ICNS)


if __name__ == "__main__":
    main()
