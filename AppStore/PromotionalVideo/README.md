# Work in Progress — 17-second promotional video

The original intro movie plays continuously inside custom blue artwork with
changing promotional copy. There is no simulator recording, device frame, or
surrounding app interface. The portraits come directly from the existing
`progress/Resources/Introduction.mp4`; the artwork and text are drawn from
editable code rather than generated photographs.

## Deliverables

| File | Layout | Resolution |
| --- | --- | --- |
| `work-in-progress-portrait.mp4` | Portrait promotional master | 886 × 1920 |
| `work-in-progress-header.mp4` | Product page header | 3840 × 1646 |
| `work-in-progress-search.mp4` | Search creative | 1920 × 1280 |

All three are **17.000 seconds**, 30 fps, H.264 MP4, with a silent AAC stereo
track and fast-start metadata. The intro source is 17.033 seconds; only its
last frame is omitted. Playback speed is unchanged. Each layout has its own
poster PNG and metadata manifest.

The header and search compositions keep the promotional copy and video card
inside the central art safe areas measured from Apple's official PSD templates.
`Review/` contains all four chapter frames and crop checks. These are locally
prepared files; they have not been uploaded or submitted to Apple.

## Changing copy

| Time | Headline | Supporting copy |
| --- | --- | --- |
| 0–4.2 s | One photo / a day. | A portrait of your everyday. |
| 4.2–8.4 s | Every day / adds up. | Small moments. A bigger story. |
| 8.4–12.6 s | Your story, / in motion. | Turn your days into a time-lapse. |
| 12.6–17 s | It’s not too / late to start. | Begin with today. |

Copy fades and moves gently into place. Background artwork drifts subtly;
the video remains fixed in its rounded card. Headlines and supporting copy
use larger type for readability. The top app name, small chapter labels, and
chapter counters have been removed. Date/location banners are part of the
original intro footage.

## Rebuild

Requires Python 3, Pillow, NumPy, FFmpeg, and the macOS system font. The copy,
chapter times, colors, and three layouts are editable in `render_promo.py`.

```sh
python3 AppStore/PromotionalVideo/render_promo.py
```

Pass `--layout portrait`, `--layout search`, or `--layout header` to render one
format. Pass `--artwork-only` to regenerate the graphics without encoding video.

Validation checks exact dimensions, 510 video frames at 30 fps, H.264 level,
duration no longer than the intro, and a full decode of each export. Artwork
generation also checks that the changing copy and video card fit the header
and search safe rectangles.

These are promotional creatives. The dedicated header/search files use Apple's
[creative video specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications).
The portrait master is a general promotional export; it is separate from the
earlier recording of the app's interface.
