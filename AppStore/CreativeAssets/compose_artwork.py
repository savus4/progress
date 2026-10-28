#!/usr/bin/env python3
"""Compose the supplied photos in native graphics without regenerating faces."""

import importlib.util
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
PHOTOS = (
    ("september-06.png", "sites/work-in-progress-daily/dist/assets/Progress Photo 2026-09-06 17.20.heic"),
    ("september-16.png", "sites/work-in-progress-daily/dist/assets/Progress Photo 2026-09-16 18.00.heic"),
    ("october-17.png", "sites/work-in-progress-daily/dist/assets/Progress Photo 2026-10-17 16.34.heic"),
)
LAYOUTS = {
    "header": dict(size=(3840, 1646), safe=(1100, 496, 2740, 1151),
                   bounds=(680, 420, 3180, 1210),
                   text=(711, 561), font=223, line=239,
                   cards=((2137, 826, 434, 651, 4), (2525, 808, 481, 721, 0), (2912, 826, 434, 651, -4))),
    "search": dict(size=(1920, 1280), safe=(420, 384, 1500, 896),
                   text=(450, 518), font=94, line=102,
                   cards=((1058, 640, 180, 270, 4), (1232, 632, 200, 300, 0), (1392, 640, 180, 270, -4))),
}


def graphics():
    path = ROOT.parent / "PromotionalVideo" / "render_promo.py"
    spec = importlib.util.spec_from_file_location("wip_motion_graphics", path)
    module = importlib.util.module_from_spec(spec)
    # Load the drawing helpers without modifying tracked Python bytecode caches.
    exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)
    return module


def photo_crop(photo):
    # Align the face consistently while trimming excess sky/ceiling and edges.
    width, height = photo.size
    crop_height = round(height * 0.8)
    crop_width = round(crop_height * 2 / 3)
    left = (width - crop_width) // 2
    top = round(height * 0.14)
    box = (left, top, left + crop_width, top + crop_height)
    return photo.crop(box), box


def card(photo, width, height, angle):
    border = 3
    radius = round(width * 0.07)
    tile = Image.new("RGBA", (width + border * 2, height + border * 2))
    ImageDraw.Draw(tile).rounded_rectangle((0, 0, tile.width - 1, tile.height - 1),
                                          radius=radius + border, fill=(239, 250, 255, 250))
    image = photo.resize((width, height), Image.Resampling.LANCZOS).convert("RGBA")
    mask = Image.new("L", image.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, width - 1, height - 1), radius=radius, fill=255)
    image.putalpha(mask)
    tile.alpha_composite(image, (border, border))
    return tile.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)


def compose(placements=None):
    motion = graphics()
    photos = []
    provenance = []
    for name, original in PHOTOS:
        with Image.open(ROOT / "Sources" / "Photos" / name) as raw:
            cropped, box = photo_crop(raw.convert("RGB"))
            photos.append(cropped)
            provenance.append(dict(source=original, normalized=f"Sources/Photos/{name}",
                                   normalized_dimensions=list(raw.size), crop_box=list(box)))

    for name, layout in LAYOUTS.items():
        if placements is not None and name not in placements:
            continue
        canvas = motion.make_background(layout["size"]).convert("RGBA")
        # The expanded header is intentionally allowed beyond Apple's central
        # guide. Keep that guide separate from the actual composition bounds.
        safe = layout.get("bounds", layout["safe"])
        # Side cards sit behind the slightly larger central photo.
        for index in (0, 2, 1):
            cx, cy, width, height, angle = layout["cards"][index]
            tile = card(photos[index], width, height, angle)
            left, top = round(cx - tile.width / 2), round(cy - tile.height / 2)
            assert safe[0] <= left and left + tile.width <= safe[2]
            assert safe[1] <= top and top + tile.height <= safe[3]
            shadow = Image.new("RGBA", canvas.size)
            silhouette = Image.new("RGBA", tile.size, (0, 9, 35, 120))
            silhouette.putalpha(tile.getchannel("A").point(lambda a: round(a * 0.45)))
            shadow.alpha_composite(silhouette, (left, top + 9))
            canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(10)))
            canvas.alpha_composite(tile, (left, top))

        draw = ImageDraw.Draw(canvas)
        font = ImageFont.truetype(motion.FONT, layout["font"])
        font.set_variation_by_name("Bold")
        x, y = layout["text"]
        for row, line in enumerate(("One photo", "a day.")):
            position = (x, y + row * layout["line"])
            bounds = draw.textbbox(position, line, font=font, anchor="lt")
            assert safe[0] <= bounds[0] and bounds[2] <= safe[2]
            assert safe[1] <= bounds[1] and bounds[3] <= safe[3]
            assert bounds[2] < layout["cards"][0][0] - layout["cards"][0][2] / 2 - 14
            draw.text(position, line, font=font, anchor="lt",
                      fill=(255, 255, 255, 255) if row == 0 else (173, 235, 255, 255))
        output = "header-artwork.png" if name == "header" else "search-artwork.png"
        canvas.convert("RGB").save(ROOT / "Sources" / output, optimize=True)
    return provenance


if __name__ == "__main__":
    compose()
