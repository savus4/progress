# Work in Progress — App Store creative assets

Updated 28 October 2026. Coordinated English artwork using the existing
“One photo a day.” copy, blue/cyan palette, and the three supplied photographs.

## Files to upload

| Placement | File | Dimensions | Encoding |
| --- | --- | --- | --- |
| Product page header | `header.png` | 3840 × 1646 | PNG, RGB, sRGB, no alpha |
| Search results | `search-results.png` | 1920 × 1280 | PNG, RGB, sRGB, no alpha |

These are separate placement-specific creatives. Upload each to its own well in
App Store Connect → app version → Product Page Information → **Header and Search
Results**. Use the App Store Connect **Preview** control to inspect device and
orientation variants before submitting. These files have been prepared locally;
they have not been uploaded, submitted, or approved by Apple.

## Composition and review

Both placements pair the large headline with the three supplied photos in
rounded portrait cards, ordered chronologically from left to right. The faces
are the actual supplied photographs. Native graphics code draws the background,
type, frames, and shadows; no faces or photo content are regenerated.

The photos are converted from HEIC, oriented upright, converted to sRGB, and
cropped consistently to remove excess sky/ceiling and side edges. Original
HEIC files remain at their supplied paths. The caption uses white and pale cyan
to match the promotional videos.

Apple's downloadable PSDs were inspected to check the central safe areas:

- Header, 3840 × 1646 template: approximately x=1097–2743, y=493–1154.
- Search, 3840 × 2560 template: approximately x=836–3004, y=765–1795.
  The review guides scale this rectangle to the 1920 × 1280 export.

The search headline and all three portrait cards fit within these bounds.
The header composition has been enlarged by approximately 55% to reduce the
empty margins. It deliberately extends beyond Apple's conservative central
guide, so some elements can crop on placements that use the tight center crop.
Inspect the header in App Store Connect's Preview before selecting it.
`Review/` contains annotated full images and safe-area crops for inspection;
**do not upload these review files**. `preview.html` displays the exports and
review crops together.

## Sources and reproducibility

- Original photographs in `sites/work-in-progress-daily/dist/assets/`:
  - `Progress Photo 2026-09-06 17.20.heic`
  - `Progress Photo 2026-09-16 18.00.heic`
  - `Progress Photo 2026-10-17 16.34.heic`
- `Sources/Photos/`: upright, color-normalized, metadata-free copies at
  1512 × 2016, saved losslessly as PNG before the layout crop.
- `Sources/header-artwork.png` and `Sources/search-artwork.png`: composed
  artwork at the final native canvas dimensions.
- `compose_artwork.py`: editable typography, card arrangement, and crop settings.
- The background drawing is shared with `../PromotionalVideo/render_promo.py`.
- `prompts.md` and `Sources/library-reference.png`: historical first-draft inputs.
- `manifest.json`: original photo paths, normalized crop boxes, dimensions,
  encoding, and SHA-256 checksums.

The graphics and type are rendered directly at the final export dimensions.
Photo crops use Lanczos resampling. `export_assets.py` embeds an sRGB profile,
strips alpha and extraneous metadata, checks the final encoding, and updates
the ZIP containing both upload images.

Regenerate the exports and review crops with Python and Pillow:

```sh
python3 AppStore/CreativeAssets/export_assets.py
```

Use `--placement header` or `--placement search` to update one image while
preserving the other export exactly.

## Apple references

- [Asset best practices](https://developer.apple.com/app-store/asset-best-practices/)
- [Creative asset specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications)
- [Managing and previewing creative assets](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets)
- [Header PSD template](https://developer.apple.com/go/?id=photoshop-product-page-header-template)
- [Search results PSD template](https://developer.apple.com/go/?id=photoshop-search-results-template)
