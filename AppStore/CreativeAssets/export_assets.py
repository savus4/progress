#!/usr/bin/env python3
"""Compose supplied photos, export upload assets, and produce local review crops."""

from hashlib import sha256
from io import BytesIO
import argparse
import json
from pathlib import Path
import sys
from zipfile import ZIP_DEFLATED, ZipFile

from PIL import Image, ImageCms, ImageDraw

sys.dont_write_bytecode = True
from compose_artwork import LAYOUTS, compose


ROOT = Path(__file__).resolve().parent
SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
ASSETS = (
    {
        "key": "header",
        "placement": "Product page header",
        "source": "header-artwork.png",
        "output": "header.png",
        "size": (3840, 1646),
        # Measured from Apple's 3840 x 1646 PSD template, inset by 3 px.
        "safe_area": (1100, 496, 2740, 1151),
    },
    {
        "key": "search",
        "placement": "Search results",
        "source": "search-artwork.png",
        "output": "search-results.png",
        "size": (1920, 1280),
        # Apple's 3840 x 2560 template, scaled to this supported 3:2 size.
        "safe_area": (420, 384, 1500, 896),
    },
)


def export(placement="all"):
    photo_sources = compose(None if placement == "all" else {placement})
    review = ROOT / "Review"
    review.mkdir(exist_ok=True)
    previous_path = ROOT / "manifest.json"
    previous = json.loads(previous_path.read_text()) if previous_path.exists() else {}
    previous_assets = {record["file"]: record for record in previous.get("assets", [])}
    records = []
    for asset in ASSETS:
        if placement != "all" and asset["key"] != placement:
            records.append(previous_assets[asset["output"]])
            continue
        with Image.open(ROOT / "Sources" / asset["source"]) as raw:
            raw.load()
            original_size = raw.size
            image = raw.convert("RGB")
            # Honor any source profile before encoding the final file as sRGB.
            if raw.info.get("icc_profile"):
                image = ImageCms.profileToProfile(
                    image,
                    ImageCms.ImageCmsProfile(BytesIO(raw.info["icc_profile"])),
                    ImageCms.createProfile("sRGB"),
                    outputMode="RGB",
                )
            target = asset["size"]
            aspect_error = abs((image.width / image.height) / (target[0] / target[1]) - 1)
            if aspect_error > 0.005:
                raise ValueError(f"Unexpected source aspect ratio: {asset['source']}")
            image = image.resize(target, Image.Resampling.LANCZOS)
            # New RGB object also strips source EXIF and miscellaneous metadata.
            final = Image.new("RGB", target)
            final.paste(image)
            output = ROOT / asset["output"]
            final.save(output, "PNG", icc_profile=SRGB, optimize=True)

        with Image.open(output) as verified:
            verified.load()
            assert verified.size == target
            assert verified.mode == "RGB"
            assert "transparency" not in verified.info
            assert verified.info.get("icc_profile")

        stem = output.stem
        safe = asset["safe_area"]
        final.crop(safe).save(review / f"{stem}-safe-crop.png", icc_profile=SRGB)
        annotated = final.copy()
        draw = ImageDraw.Draw(annotated)
        draw.rectangle(safe, outline="#ffdf36", width=max(3, target[0] // 500))
        annotated.thumbnail((1440, 960), Image.Resampling.LANCZOS)
        annotated.save(review / f"{stem}-safe-area.png", icc_profile=SRGB)
        record = {
            "placement": asset["placement"],
            "file": asset["output"],
            "width": target[0],
            "height": target[1],
            "format": "PNG",
            "color_mode": "RGB",
            "profile": "sRGB",
            "alpha": False,
            "source_dimensions": list(original_size),
            "composition": "Native canvas with the three supplied photographs; cropped and resized with Lanczos",
            "review_safe_rectangle": list(safe),
            "composition_bounds": list(LAYOUTS[asset["key"]].get("bounds", safe)),
            "crop_policy": (
                "Expanded header composition extends beyond the conservative central guide"
                if "bounds" in LAYOUTS[asset["key"]]
                else "Headline and all portrait cards fit the central guide"
            ),
            "bytes": output.stat().st_size,
            "sha256": sha256(output.read_bytes()).hexdigest(),
        }
        records.append(record)
        print(f"{asset['output']}: {target[0]} x {target[1]}, RGB PNG, no alpha")

    (ROOT / "manifest.json").write_text(
        json.dumps({"created": "2026-10-18", "updated": "2026-10-28",
                    "photo_sources": photo_sources, "assets": records}, indent=2) + "\n"
    )
    with ZipFile(ROOT.parent / "work-in-progress-app-store-creatives.zip", "w", compression=ZIP_DEFLATED) as archive:
        for asset in ASSETS:
            archive.write(ROOT / asset["output"], asset["output"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--placement", choices=("all", "header", "search"), default="all")
    export(parser.parse_args().placement)
