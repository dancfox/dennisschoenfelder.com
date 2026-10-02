#!/usr/bin/env python3
"""Bring a full-resolution original into the web collection.

The masters in Drive run 12-94 MB; what the site serves is a 2000px, ~1 MB
derivative. This reproduces that derivative with the same encoder settings the
existing twelve were made with, so a new plate is not visibly softer or
sharper than its neighbours.

    python3 tools/import-photo.py ~/Downloads/the-original.jpg
    python3 tools/import-photo.py original.jpg --slug low-fog-two

Needs Pillow:  python3 -m pip install --user Pillow
"""
import argparse, pathlib, re, sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required:  python3 -m pip install --user Pillow")

# Matched to the existing collection: 2000px long edge, 4:2:0, quality ~95.
MAX_EDGE, QUALITY, SUBSAMPLING = 2000, 95, 2
IMAGES = pathlib.Path(__file__).resolve().parent.parent / "images"


def next_number() -> int:
    ns = [int(m.group(1)) for p in IMAGES.glob("*.jpg")
          if (m := re.match(r"(\d+)-", p.name))]
    return max(ns, default=0) + 1


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("source", type=pathlib.Path, help="the full-resolution original")
    ap.add_argument("--slug", default="untitled",
                    help="filename slug; renamed later once the plate is titled")
    ap.add_argument("--max-edge", type=int, default=MAX_EDGE)
    a = ap.parse_args()

    if not a.source.is_file():
        sys.exit(f"not a file: {a.source}")

    im = Image.open(a.source)
    im = im.convert("RGB")           # drop any alpha/CMYK the master carries
    w, h = im.size
    scale = a.max_edge / max(w, h)
    if scale < 1:
        im = im.resize((round(w * scale), round(h * scale)), Image.LANCZOS)

    dest = IMAGES / f"{next_number():02d}-{a.slug}.jpg"
    # No exif= argument, so camera metadata (including GPS for the refuge)
    # is dropped rather than published.
    im.save(dest, "JPEG", quality=QUALITY, subsampling=SUBSAMPLING,
            optimize=True)

    kb = dest.stat().st_size / 1024
    print(f"{a.source.name}\n  {w}x{h} -> {im.size[0]}x{im.size[1]}"
          f"  {a.source.stat().st_size/1024/1024:.1f} MB -> {kb:.0f} KB")
    print(f"  wrote {dest.relative_to(dest.parent.parent)}")
    print("\nNext:\n  git add images/ && git commit -m 'Add photograph' && "
          "git push -u origin claude/dennis-site-review-213x1b")


if __name__ == "__main__":
    main()
