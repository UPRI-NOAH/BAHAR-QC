# BAHAR QC — iOS AR

**Bah**a **A**ugmented **R**eality — Metro Manila's first AR flood visualization app.

Point your camera at the ground and BahAR raises a live water plane to the
expected 100-year-return flood depth at your current GPS location, using the
UP NOAH flood depth model. Built for UPRI-NOAH as the iOS / on-the-ground
companion to the [BAHAR-QC](https://github.com/UPRI-NOAH/BAHAR-QC) web map.

> **iOS AR source lives on the [`ios-ar-water-effect`](https://github.com/UPRI-NOAH/BAHAR-QC/tree/ios-ar-water-effect) branch.**
> The `main` branch holds the Mapbox web map; the AR client (Xcode project,
> water shader, HUD, snapshot, Tilequery integration) is all on
> `ios-ar-water-effect`.

## How it fits with the rest of BAHAR-QC

- **Web side** (BAHAR-QC main repo) — a Mapbox-powered web map of Metro
  Manila showing 100-year flood depth tiles. Users browse the map at city
  scale.
- **iOS side** (this repo, `ios-ar-water-effect` branch) — same flood data,
  same coverage, but visualized in AR where the user is physically standing.
  You see the water depth on your floor / on the street, not on a map.

Both clients pull from the **same Mapbox tileset** so the depth shown in AR
matches what the web map shows at that coordinate.

## Data source

The iOS app does **not** ship a bundled flood depth file. It queries Mapbox
Tilequery through a small Netlify proxy so the Mapbox token is never embedded
in the app binary:

```
https://bahar-mm.netlify.app/api/tilequery
   ?lat=<latitude>&lng=<longitude>
```

The proxy lives in the [bahar-mm](https://bahar-mm.netlify.app) Netlify site
and forwards the request to Mapbox Tilequery against the NOAH 100-year flood
depth tileset. The iOS client parses the `Var` property of the returned
feature for the depth value (metres).

Coverage is bounded to Metro Manila (N 14.82, S 14.35, W 120.90, E 121.20).
Outside this bbox the app returns "no flood".

### Accuracy / spillover handling

Tilequery returns every polygon within a search radius of the query point,
not just the polygon directly under it. Without tight parameters the proxy
would bleed flooded polygons up to 25 m away into a safe location (e.g. UP
Resilience Institute reading as gutter level even though its tile is
classified "little to none" on NOAH Studio).

Two layers of cleanup keep the AR reading consistent with the NOAH map:

1. **Netlify proxy** (`netlify/functions/tilequery.js`) calls Mapbox with
   `radius=5&limit=1`. Five metres absorbs typical GPS jitter without
   crossing tile edges, and a single result means we report the polygon
   directly under the point.
2. **iOS noise floor** (`MMDAGauge.from`) treats depths below **2 cm**
   (≈0.8 in) as `none`. Anything that small isn't actionable and matches
   NOAH's "little to none" classification.

## What you see in the app

- **Landing screen** — NOAH + UPRI partner logos, the **BahAR** wordmark,
  one-paragraph explanation, and a Start AR button. Always renders in light
  mode regardless of device theme.
- **AR session** —
  - Live ARKit camera feed with a procedural water plane rendered at the
    detected ground anchor.
  - **MMDA gauge HUD**: depth in inches and metres, MMDA category pill
    (PATV / NPLV / NPATV), and a human-scale label (Gutter Level →
    Chest Level) with a body-part emoji.
  - **Top-left**: translucent NOAH watermark with a soft white glow.
  - **Top-right**: Exit button (glass pill).
  - **Bottom-left**: warning button — tap to reveal a category-specific
    advisory message (e.g. "Proceed slowly. Keep distance from trucks.").
  - **Bottom-right**: AR snapshot camera button. Captures the live AR view
    + HUD, saves to Photos automatically, slides in an iOS-screenshot-style
    thumbnail (swipe to dismiss, tap to share).

## Water shader

The water is a `CustomMaterial` driven by `BAHAR QC/WaterShader.metal`:

- **Geometry modifier** displaces a subdivided plane mesh (30 m × 30 m,
  80 × 80 subdivisions) using a four-layer wave height field.
- **Surface shader** does fresnel-driven mixing between:
  - a heavily warped **refraction** of the camera feed (three-scale UV
    warp + chromatic-aberration split, so submerged objects bend at
    multiple scales),
  - a separately warped **reflection** of the camera feed mirrored across
    the screen midline.
- **Height field** = FBM noise + four big-wave directional sine swells +
  three medium-chop sines + a high-frequency product-of-sines shimmer.
  The shimmer kills "dead zones" where smooth crests would otherwise
  leave the surface looking flat.
- Tinted with a cyan-blue body colour; opacity ~0.82.

The shader also includes a separate compute kernel (`cameraYCbCrToRGB`)
that converts ARKit's biplanar `capturedImage` to a viewport-aligned RGBA
texture so the water can sample it as a normal 2D image.

## MMDA gauge categories

| Code   | Range                | Human scale          | Advisory                            |
|--------|----------------------|----------------------|-------------------------------------|
| —      | 0″                   | No flood             | Safe                                |
| PATV   | < ~13″ (~0.33 m)     | Gutter → Half-knee   | Proceed slowly; avoid large vehicles|
| NPLV   | ~13–26″ (~0.66 m)    | Calf → Knee          | Light vehicles must detour          |
| NPATV  | > ~26″               | Thigh → Chest        | Do not attempt driving or wading    |

Colours match the MMDA palette:
PATV `#EAB308` · NPLV `#F97316` · NPATV `#EF4444`.

## Build / run

Requires Xcode 16+ on macOS 15+ and an A12-or-later device (ARKit). The
project uses Xcode's `PBXFileSystemSynchronizedRootGroup` synced folder, so
new files dropped into `BAHAR QC/` are picked up automatically — there is
**no** `.xcodeproj` editing required for ordinary source changes.

1. Open `BAHAR QC.xcodeproj` in Xcode.
2. Select your device (must be a real iPhone — Simulator has no AR camera).
3. ⌘R to build and run.

The Info.plist (`BAHAR QC/BAHAR-QC-Info.plist`) provides:
- `NSCameraUsageDescription` — required for ARKit.
- `NSLocationWhenInUseUsageDescription` — for the GPS lookup.
- `NSPhotoLibraryAddUsageDescription` — for the auto-save snapshot feature.

## File layout

```
BAHAR QC/
├─ BAHAR_QCApp.swift           App entry
├─ ContentView.swift           Landing + AR session, HUD, snapshot
├─ ARContainerView.swift       ARView wrapper, ground detection, water plane
├─ WaterShader.metal           Water surface + geometry + camera YCbCr kernel
├─ FloodData.swift             Mapbox Tilequery client + 55 m grid cache
├─ LocationManager.swift       CLLocationManager wrapper
├─ FloodFilterOverlay.swift    Optional underwater POV tint
├─ CameraReflection.swift      ARKit camera texture binding
├─ Assets.xcassets             NOAH / UPRI logos, app icon
└─ BAHAR-QC-Info.plist         Permissions + display strings
```

## Credits

- **UP NOAH** — flood depth model and Mapbox tileset.
- **UPRI** — project owner; institutional collaborator.
- iOS AR implementation, water shader, and HUD by the RCW and WebGIS team.
