# Work in Progress — App Store creative assets

Created 18 October 2026. Coordinated English artwork using the app's existing
“One photo a day.” copy, blue/cyan icon palette, daily portrait imagery, and
current photo library interface.

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

The header pairs the headline with three portrait cards. The search creative
shows the app's library using a capture from the running iPhone 18 Pro simulator
as its visual reference. The artwork was composed with the built-in imagegen
tool; the interface and photographs in the finished creative are generated
composites, not pixel-identical screenshots or unaltered source photographs.

Apple's downloadable PSDs were inspected to check the central safe areas:

- Header, 3840 × 1646 template: approximately x=1097–2743, y=493–1154.
- Search, 3840 × 2560 template: approximately x=836–3004, y=765–1795.
  The review guides scale this rectangle to the 1920 × 1280 export.

Essential headline text, header faces, and the key search-library content are
placed inside these bounds. The search panel's status bar and lower photo rows
may extend beyond them. `Review/` contains annotated full images and safe-area
crops for inspection; **do not upload these review files**. `preview.html`
displays the exports and review crops together.

## Sources and reproducibility

- `Sources/header-artwork.png` and `Sources/search-artwork.png`: selected
  imagegen artwork before technical export.
- `Sources/library-reference.png`: native 1206 × 2622 app-library capture from
  the iPhone 18 Pro simulator.
- Portrait references: frames sampled at 0.2, 6.1, and 15.1 seconds from the
  existing `progress/Resources/Introduction.mp4`.
- Palette reference: `progress/Assets.xcassets/AppIcon.appiconset/AppIcon-light.png`.
- `prompts.md`: full generation and safe-area adjustment prompts.
- `manifest.json`: dimensions, source raster sizes, encoding, and SHA-256 checksums.

The generated sources are smaller than the final upload dimensions.
`export_assets.py` uses Lanczos resampling to reach Apple's exact supported
sizes and embeds an sRGB profile. These are resized exports, not native 4K
renders. It strips alpha and extraneous metadata and checks the final encoding.

Regenerate the exports and review crops with Python and Pillow:

```sh
python3 AppStore/CreativeAssets/export_assets.py
```

## Apple references

- [Asset best practices](https://developer.apple.com/app-store/asset-best-practices/)
- [Creative asset specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications)
- [Managing and previewing creative assets](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets)
- [Header PSD template](https://developer.apple.com/go/?id=photoshop-product-page-header-template)
- [Search results PSD template](https://developer.apple.com/go/?id=photoshop-search-results-template)
