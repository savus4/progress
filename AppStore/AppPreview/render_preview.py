#!/usr/bin/env python3
"""Edit the real iPhone simulator takes into a portrait App Store preview."""

from fractions import Fraction
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / "work-in-progress-app-preview.mp4"
# The opening contains one complete 17-second cycle of the app's intro movie.
SCENES = [
    ("Introduction and portrait time-lapse", "intro-loop-take.mp4", 0.4, 17.0),
    ("Browse the portrait library", "app-demo-take.mp4", 19.6, 5.2),
    ("Open Video Creator", "app-demo-take.mp4", 115.4, 3.8),
    ("Watch the generated portrait video", "result-take.mp4", 5.0, 4.0),
]
TRANSITION = 0.2
POSTER_TIME = 15.0


def run(args):
    subprocess.run(args, check=True)


def probe(path):
    return json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_format", "-show_streams",
        "-of", "json", str(path),
    ]))


def main():
    command = ["ffmpeg", "-hide_banner", "-loglevel", "warning", "-y"]
    filters = []
    for index, (_, filename, start, duration) in enumerate(SCENES):
        source = ROOT / "Sources" / filename
        assert float(probe(source)["format"]["duration"]) >= start + duration
        command += ["-ss", str(start), "-t", str(duration), "-i", str(source)]
        filters.append(
            f"[{index}:v]setpts=PTS-STARTPTS,fps=30,"
            "scale=886:1920:force_original_aspect_ratio=increase:flags=lanczos,"
            "crop=886:1920,setsar=1,format=yuv420p,settb=AVTB"
            f"[scene{index}]"
        )

    elapsed = SCENES[0][3]
    current = "scene0"
    for index in range(1, len(SCENES)):
        offset = elapsed - TRANSITION
        next_label = f"cut{index}"
        filters.append(
            f"[{current}][scene{index}]xfade=transition=fade:"
            f"duration={TRANSITION}:offset={offset:.6f}[{next_label}]"
        )
        current = next_label
        elapsed += SCENES[index][3] - TRANSITION

    filters.append(f"[{current}]format=yuv420p[final]")
    command += [
        "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
        "-filter_complex_threads", "1", "-filter_complex", ";".join(filters),
        "-map", "[final]", "-map", "4:a:0", "-t", f"{elapsed:.6f}",
        "-c:v", "libx264", "-preset", "slow", "-profile:v", "high",
        "-level:v", "4.0", "-b:v", "10M", "-maxrate", "12M",
        "-bufsize", "20M", "-pix_fmt", "yuv420p", "-r", "30",
        "-g", "60", "-color_range", "tv", "-colorspace", "bt709",
        "-color_trc", "bt709", "-color_primaries", "bt709",
        "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2",
        "-movflags", "+faststart", "-map_metadata", "-1",
        "-metadata", "title=Work in Progress — App Preview", str(OUTPUT),
    ]
    run(command)

    info = probe(OUTPUT)
    video = next(s for s in info["streams"] if s["codec_type"] == "video")
    audio = next(s for s in info["streams"] if s["codec_type"] == "audio")
    assert (video["width"], video["height"]) == (886, 1920)
    assert Fraction(video["avg_frame_rate"]) == 30
    assert video["codec_name"] == "h264"
    assert video["pix_fmt"] == "yuv420p"
    assert audio["codec_name"] == "aac" and audio["channels"] == 2
    assert 15 <= float(info["format"]["duration"]) <= 30
    assert OUTPUT.stat().st_size < 500_000_000

    review = ROOT / "Review"
    review.mkdir(exist_ok=True)
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", str(POSTER_TIME),
         "-i", str(OUTPUT), "-frames:v", "1", str(ROOT / "poster.png")])
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-i", str(OUTPUT), "-vf", "fps=1/3,scale=222:-1,tile=5x2",
         "-frames:v", "1", str(review / "contact-sheet.jpg")])
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(OUTPUT),
         "-f", "null", "-"])
    (ROOT / "manifest.json").write_text(json.dumps({
        "created": "2026-10-18",
        "source": "Actual recordings from the iPhone 18 Pro simulator",
        "scenes": [dict(title=t, source=f, source_start=s, duration=d)
                   for t, f, s, d in SCENES],
        "dissolve_seconds": TRANSITION,
        "poster_time_seconds": POSTER_TIME,
        "ffprobe": info,
        "validation": "Dimensions, duration, frame rate, codecs, size and full decode passed",
    }, indent=2) + "\n")
    print(f"Created {OUTPUT}: {info['format']['duration']} seconds, "
          f"886 x 1920, 30 fps, {OUTPUT.stat().st_size / 1_000_000:.1f} MB")


if __name__ == "__main__":
    main()
