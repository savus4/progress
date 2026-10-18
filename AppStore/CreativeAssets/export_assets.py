#!/usr/bin/env python3
"""Normalize approved artwork to Apple's dimensions; produce local review crops.

Requires Pillow. This script changes file size/color encoding only; composition
and image content are authored with imagegen, not redrawn here.
"""

from hashlib import sha256
from io import BytesIO
import json
from pathlib import Path

from PIL import Image, ImageCms, ImageDraw


ROOT = Path(__file__).resolve().parent
SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
ASSETS = (
    {
        "placement": "Product page header",
        "source": "header-artwork.png",
        "output": "header.png",
        "size": (3840, 1646),
        # Measured from Apple's 3840 x 1646 PSD template, inset by 3 px.
        "safe_area": (1100, 496, 2740, 1151),
    },
    {
        "placement": "Search results",
        "source": "search-artwork.png",
        "output": "search-results.png",
        "size": (1920, 1280),
        # Apple's 3840 x 2560 template, scaled to this supported 3:2 size.
        "safe_area": (420, 384, 1500, 896),
    },
)


def export():
    review = ROOT / "Review"
    review.mkdir(exist_ok=True)
    records = []
    for asset in ASSETS:
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
            "export_resampling": "Lanczos; source raster resized, not native 4K rendering",
            "review_safe_rectangle": list(safe),
            "bytes": output.stat().st_size,
            "sha256": sha256(output.read_bytes()).hexdigest(),
        }
        records.append(record)
        print(f"{asset['output']}: {target[0]} x {target[1]}, RGB PNG, no alpha")

    (ROOT / "manifest.json").write_text(
        json.dumps({"created": "2026-10-18", "assets": records}, indent=2) + "\n"
    )


if __name__ == "__main__":
    export()
