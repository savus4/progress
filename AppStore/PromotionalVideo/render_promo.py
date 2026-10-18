#!/usr/bin/env python3
"""Render custom motion artwork around the original intro movie, without app UI."""

import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
SOURCE = REPO / "progress/Resources/Introduction.mp4"
FONT = "/System/Library/Fonts/SFNS.ttf"
DURATION = 17.0
FPS = 30
CHAPTERS = [
    dict(start=0.0, end=4.2, title=["One photo", "a day."],
         detail="A portrait of you, everyday."),
    dict(start=4.2, end=8.4, title=["Every day", "adds up."],
         detail="Quicker than you think."),
    dict(start=8.4, end=12.6, title=["Your story,", "in motion."],
         detail="Turn your days into a time-lapse."),
    dict(start=12.6, end=17.0, title=["It’s not too", "late to start."],
         detail="Begin today!"),
]
LAYOUTS = {
    "portrait": dict(size=(886, 1920), video=(72, 568, 742, 1113), radius=42,
                     copy=(72, 144, 742, 370),
                     headline=120, line=130, detail=38, level="4.0", bitrate="10M"),
    "search": dict(size=(1920, 1280), video=(1130, 392, 320, 480), radius=20,
                   copy=(450, 460, 620, 360),
                   headline=108, line=116, detail=34, level="5.0", bitrate="12M",
                   safe=(420, 384, 1500, 896)),
    "header": dict(size=(3840, 1646), video=(2280, 526, 386, 579), radius=24,
                   copy=(1140, 576, 1050, 470),
                   headline=164, line=176, detail=46, level="5.1", bitrate="20M",
                   safe=(1100, 496, 2740, 1151)),
}


def run(args):
    subprocess.run([str(a) for a in args], check=True)


def probe(path):
    return json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path),
    ]))


def font(size, weight="Regular"):
    result = ImageFont.truetype(FONT, size)
    result.set_variation_by_name(weight)
    return result


def text(draw, xy, value, size, fill, weight="Regular", max_width=None):
    face = font(size, weight)
    if max_width is not None:
        assert draw.textlength(value, font=face) <= max_width, (value, size, max_width)
    draw.text(xy, value, font=face, fill=fill, anchor="lt")


def make_background(size):
    w, h = size
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    u, v = x / w, y / h
    amount = np.clip(0.2 + 0.52 * v + 0.16 * u, 0, 1)
    start = np.array([5, 29, 96], dtype=np.float32)
    end = np.array([0, 108, 227], dtype=np.float32)
    rgb = start + (end - start) * amount[..., None]
    glow = np.exp(-(((u - 0.98) / 0.53) ** 2 + ((v - 0.77) / 0.43) ** 2) * 1.4)
    rgb += glow[..., None] * np.array([0, 75, 28], dtype=np.float32)
    grain = np.random.default_rng(18).normal(0, 0.35, (h, w, 1))
    canvas = Image.fromarray(np.clip(rgb + grain, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    ornament = Image.new("RGBA", size)
    draw = ImageDraw.Draw(ornament)
    center = (w * 0.82, h * 0.64)
    base = min(w, h) * 0.68
    for ratio, alpha, thickness in [(1.0, 16, 2), (1.16, 10, 2), (0.84, 12, 2)]:
        r = base * ratio
        draw.ellipse((center[0] - r, center[1] - r, center[0] + r, center[1] + r),
                     outline=(182, 240, 255, alpha), width=thickness)
    # A large translucent arc gives the composition continuity with the app icon.
    r = base * 0.92
    draw.arc((center[0] - r, center[1] - r, center[0] + r, center[1] + r),
             start=205, end=323, fill=(173, 238, 255, 13), width=max(16, int(w * 0.013)))
    return Image.alpha_composite(canvas, ornament).convert("RGB")


def make_artwork(name):
    layout = LAYOUTS[name]
    w, h = layout["size"]
    vx, vy, vw, vh = layout["video"]
    radius = layout["radius"]
    folder = ROOT / "Artwork" / name
    folder.mkdir(parents=True, exist_ok=True)
    make_background((w + 80, h + 80)).save(folder / "background.png")

    shadow = Image.new("RGBA", (w, h))
    draw = ImageDraw.Draw(shadow)
    draw.rounded_rectangle((vx - 12, vy + 16, vx + vw + 12, vy + vh + 28),
                           radius=radius + 12, fill=(0, 8, 36, 125))
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))
    plate = Image.new("RGBA", (w, h))
    plate.alpha_composite(shadow)
    draw = ImageDraw.Draw(plate)
    # Quiet offset outlines suggest a growing stack of photographs.
    draw.rounded_rectangle((vx - 28, vy - 17, vx + vw + 17, vy + vh + 16),
                           radius=radius + 8, outline=(180, 236, 255, 46), width=2)
    draw.rounded_rectangle((vx - 48, vy - 32, vx + vw + 32, vy + vh + 30),
                           radius=radius + 16, outline=(180, 236, 255, 22), width=2)
    draw.rounded_rectangle((vx - 4, vy - 4, vx + vw + 4, vy + vh + 4),
                           radius=radius + 4, fill=(235, 250, 255, 245))
    if name == "portrait":
        left, right = layout["copy"][0], w - layout["copy"][0]
        draw.line((left, 1782, right, 1782), fill=(183, 238, 255, 58), width=1)
        text(draw, (left, 1820), "ONE DAY AT A TIME", 24, (195, 237, 255, 230), "Medium")
        label_width = draw.textlength("YOUR STORY", font=font(24, "Medium"))
        text(draw, (right - label_width, 1820), "YOUR STORY", 24, (195, 237, 255, 230), "Medium")
    plate.save(folder / "frame.png")

    mask = Image.new("L", (vw, vh), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, vw - 1, vh - 1), radius=radius, fill=255)
    mask.save(folder / "video-mask.png")

    cx, cy, cw, ch = layout["copy"]
    for index, chapter in enumerate(CHAPTERS):
        caption = Image.new("RGBA", (cw, ch))
        draw = ImageDraw.Draw(caption)
        for row, line in enumerate(chapter["title"]):
            text(draw, (0, row * layout["line"]), line, layout["headline"],
                 (255, 255, 255, 255) if row == 0 else (173, 235, 255, 255),
                 "Bold", max_width=cw)
        detail_y = 2 * layout["line"] + 32
        text(draw, (0, detail_y), chapter["detail"], layout["detail"],
             (220, 243, 255, 240), max_width=cw)
        bounds = caption.getbbox()
        assert bounds is not None and bounds[3] < ch, (name, chapter["title"], bounds, ch)
        caption.save(folder / f"copy-{index}.png")
        if "safe" in layout:
            sx, sy, ex, ey = layout["safe"]
            assert sx <= cx + bounds[0] <= cx + bounds[2] <= ex
            assert sy <= cy + bounds[1] - 12 <= cy + bounds[3] <= ey
            assert sx <= vx and vx + vw <= ex and sy <= vy and vy + vh <= ey
    return folder


def make_review(name):
    layout = LAYOUTS[name]
    review = ROOT / "Review"
    frames = []
    for i in range(1, 5):
        with Image.open(review / f"{name}-chapter-{i}.png") as source:
            image = source.convert("RGB")
        if "safe" in layout:
            image = image.crop(layout["safe"])
            image.save(review / f"{name}-chapter-{i}-safe.png")
        frames.append(image)
    tile_width = 270 if name == "portrait" else 540
    tile_height = round(frames[0].height * tile_width / frames[0].width)
    columns = 4 if name == "portrait" else 2
    rows = 4 // columns
    board = Image.new("RGB", (columns * tile_width, rows * tile_height))
    for i, image in enumerate(frames):
        image = image.resize((tile_width, tile_height), Image.Resampling.LANCZOS)
        board.paste(image, ((i % columns) * tile_width, (i // columns) * tile_height))
    suffix = "storyboard" if name == "portrait" else "safe-storyboard"
    board.save(review / f"{name}-{suffix}.jpg", quality=95)


def render(name, artwork_only=False):
    layout = LAYOUTS[name]
    w, h = layout["size"]
    vx, vy, vw, vh = layout["video"]
    cx, cy, _, _ = layout["copy"]
    art = make_artwork(name)
    if artwork_only:
        return None
    output = ROOT / f"work-in-progress-{name}.mp4"
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "warning", "-y", "-i", SOURCE]
    images = ["background.png", "frame.png", "video-mask.png"] + [f"copy-{i}.png" for i in range(4)]
    for image in images:
        cmd += ["-loop", "1", "-framerate", str(FPS), "-i", art / image]
    cmd += ["-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000"]
    filters = [
        f"[1:v]crop={w}:{h}:x='40+12*sin(t*0.34)':y='40+10*cos(t*0.28)',setsar=1[bg]",
        "[bg][2:v]overlay=0:0[framed]",
        f"[0:v]trim=duration={DURATION},setpts=PTS-STARTPTS,fps={FPS},"
        f"scale={vw}:{vh}:flags=lanczos,format=rgb24[video]",
        "[3:v]format=gray[mask]",
        "[video][mask]alphamerge[rounded]",
        f"[framed][rounded]overlay={vx}:{vy}:shortest=1[base]",
    ]
    previous = "base"
    for i, chapter in enumerate(CHAPTERS):
        start, end = chapter["start"], chapter["end"]
        fade = f"[{i + 4}:v]format=rgba,fade=t=in:st={start}:d=0.28:alpha=1"
        if i != 3:
            fade += f",fade=t=out:st={end - 0.22}:d=0.22:alpha=1"
        filters.append(fade + f"[caption{i}]")
        filters.append(
            f"[{previous}][caption{i}]overlay=x={cx}:"
            f"y='{cy}-10*(1-min(1,max(0,(t-{start})/0.45)))':"
            f"enable='between(t,{start},{end})'[chapter{i}]"
        )
        previous = f"chapter{i}"
    filters.append(f"[{previous}]format=yuv420p[out]")
    cmd += [
        "-filter_complex_threads", "1", "-filter_complex", ";".join(filters),
        "-map", "[out]", "-map", "8:a:0", "-t", str(DURATION),
        "-c:v", "libx264", "-preset", "medium", "-profile:v", "high",
        "-level:v", layout["level"], "-b:v", layout["bitrate"],
        "-maxrate", layout["bitrate"], "-bufsize", "20M" if name == "portrait" else "40M", "-pix_fmt", "yuv420p",
        "-r", str(FPS), "-g", "60", "-color_range", "tv", "-colorspace", "bt709",
        "-color_primaries", "bt709", "-color_trc", "bt709",
        "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2",
        "-movflags", "+faststart", "-map_metadata", "-1", output,
    ]
    run(cmd)
    info = probe(output)
    video = next(s for s in info["streams"] if s["codec_type"] == "video")
    source_duration = float(probe(SOURCE)["format"]["duration"])
    assert (video["width"], video["height"]) == (w, h)
    assert Fraction(video["avg_frame_rate"]) == FPS
    assert int(video["level"]) == int(layout["level"].replace(".", ""))
    assert int(video["nb_frames"]) == 510
    assert float(info["format"]["duration"]) <= source_duration
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", output, "-f", "null", "-"])
    review = ROOT / "Review"
    review.mkdir(exist_ok=True)
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", "1.8",
         "-i", output, "-frames:v", "1", ROOT / f"{name}-poster.png"])
    for i, moment in enumerate((1.8, 5.8, 10.0, 14.4)):
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", str(moment),
             "-i", output, "-frames:v", "1", review / f"{name}-chapter-{i + 1}.png"])
    make_review(name)
    (ROOT / f"{name}-manifest.json").write_text(json.dumps({
        "created": "2026-10-18", "source": str(SOURCE.relative_to(REPO)),
        "source_duration": source_duration, "chapters": CHAPTERS, "layout": layout,
        "ffprobe": info,
        "validation": "510 frames; full decode; exact dimensions; 30 fps; duration <= intro source",
    }, indent=2) + "\n")
    print(f"Created {name}: {w} x {h}, {info['format']['duration']} s, "
          f"{output.stat().st_size / 1_000_000:.1f} MB", flush=True)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--layout", choices=list(LAYOUTS) + ["all"], default="all")
    parser.add_argument("--artwork-only", action="store_true")
    args = parser.parse_args()
    for name in LAYOUTS if args.layout == "all" else [args.layout]:
        render(name, args.artwork_only)
