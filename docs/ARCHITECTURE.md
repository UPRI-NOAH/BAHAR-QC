# BAHAR-QC — Technical Architecture

How the app is built: components, data flow, and the reasoning behind key
decisions. Companion to [PROGRESS.md](PROGRESS.md).

---

## System overview

```
┌─────────────────────────┐        ┌──────────────────────────┐
│  iOS app (Swift)        │        │  Netlify (bahar-mm)      │
│  SwiftUI + ARKit +      │ HTTPS  │                          │
│  RealityKit + Metal     ├───────►│  /api/tilequery ─────────┼──► Mapbox Tilequery API
│                         │        │  /api/tiles/{z}/{x}/{y} ─┼──► Mapbox Static Tiles API
│  MapKit mini-map        │        │  (token in env var)      │
└─────────────────────────┘        └──────────────────────────┘
                                              ▲
┌─────────────────────────┐                   │
│  Web preview            ├───────────────────┘
│  Three.js + WebXR       │   same endpoints
└─────────────────────────┘

Data: UP NOAH 100-yr flood model → Mapbox tileset `upri-noah.mm_fh_100yr_tls`
      (vector polygons, `Var` property = flood depth in meters,
       9 source-layers: mm_fh_100yr_a…h, j)
```

Two clients, one backend. The iOS app is the product; the web version is a
simplified Three.js preview for quick browser demos.

---

## iOS app components

| File | Responsibility |
|---|---|
| `ContentView.swift` | SwiftUI shell: landing page, AR HUD (MMDA depth card, GPS capsule, guidelines), snapshot capture/share, mini-map placement |
| `ARContainerView.swift` | AR session: ground detection, water plane anchoring, underwater detection, camera-reflection scheduling |
| `WaterShader.metal` | Water look: FBM wave displacement (geometry modifier) + surface shader with screen-space reflection, refraction, fresnel |
| `CameraReflection.swift` | Metal compute pipeline converting the camera feed (YpCbCr → RGB) into a texture the shader samples for live reflections |
| `FloodData.swift` | Flood depth lookup via the Netlify tilequery proxy + MMDA gauge classification + ~5 m response cache |
| `MiniMapView.swift` | Mapbox SDK map: NOAH terrain basemap + flood-depth overlay added at runtime; mini (follow-GPS) and expanded (pan/zoom) modes |
| `FloodFilterOverlay.swift` | Full-screen "underwater POV" drawn when the camera goes below the waterline |
| `LocationManager.swift` | CoreLocation wrapper (2 m distance filter) |

### Data flow (per GPS update)

1. `LocationManager` publishes a coordinate (≥2 m movement)
2. `FloodData.depth(lat:lon:)` — checks the Metro Manila bounding box, then the
   ~5 m quantized cache, then calls `/api/tilequery`
3. Response's `Var` property = flood depth in meters (max across overlapping polygons)
4. `MMDAGauge.from(depthMeters:)` classifies it (PATV / NPLV / NPATV + description)
5. HUD updates; `ARContainerView.updateDepth()` raises the water plane

### Ground detection (three cooperating strategies)

The water surface must sit at `real ground + flood depth`, so ground accuracy
directly controls where the waterline lands on a person's body:

1. **Instant estimate** — `camera height − 1.4 m` so water appears immediately
2. **Raycast refinement** — while the ground is still an estimate, ARKit
   `.estimatedPlane` raycasts fire every 10 frames from 5 probe points across
   the lower half of the screen (bottom of frame sees ground even when framing
   a person). The lowest hit wins, guarding against tables/benches
3. **Plane anchors** — once ARKit detects a real horizontal plane ≥1.5 m²
   (filters out desks/chairs), it becomes the authoritative ground

A safety rule pulls the ground down if the phone is ever physically lower than
it (the water can never sit above the lowest point the phone has been).

### The body-filter effect (why there is NO person segmentation)

The "person standing in flood" effect needs the water surface to cross the
body at the waterline. ARKit person segmentation cannot do this — it composites
the *entire* person in front of virtual content, which cut a person-shaped hole
in the water. Instead, we exploit plain geometry: a horizontal water plane at
`ground + depth` projects onto the person's body at exactly the flood height
(their upper body rises above the plane in screen space; the submerged half is
behind the semi-transparent surface). No ML, no masks — just a correctly-placed
plane and 0.62 opacity.

### Water rendering

- **Geometry:** 30 m plane subdivided 80×80 so the vertex shader can shape real
  waves (FBM), amplitude scaled by flood depth (shallow = ripples, deep = swells)
- **Surface:** screen-space reflection of the live camera feed (via
  `CameraReflection` texture), refraction with chromatic aberration, fresnel
  blend, sun sparkle
- **MMDA sync:** the plane is hidden entirely below the 8-inch (0.2032 m) MMDA
  noise floor so AR always agrees with the HUD reading
- **Visual target:** the reference image (`sample_peg.jpg`) — glassy, calm,
  near-colorless water whose color comes from the reflected/refracted
  surroundings, with the submerged body and ground visible through it. This is
  why the shader is reflection-dominant with a low tint mix (0.28 refraction /
  0.32 reflection) and 0.62 opacity: outdoors the surface reads grey-green from
  the environment, not blue, even though the tint constant is cyan. A murky
  opaque-brown "photoreal" look was deliberately rejected — it would hide the
  submerged body and kill the signature effect

---

## Backend (Netlify)

Site: `https://bahar-mm.netlify.app` · production deploys from `main`.

| Function | Purpose |
|---|---|
| `netlify/functions/tilequery.js` | Point query → flood depth. Enforces `radius=5&limit=1` server-side (a 25 m radius previously bled neighboring flood polygons into safe locations) |

**Why the depth lookup is proxied instead of calling Mapbox directly:**

- The token lives in one server-side env var, rotatable without an App Store
  resubmission
- Query rules (radius/limit) are enforced server-side, so old app versions
  can't send bad queries
- Web, iOS, and future Android share the same endpoint

**Cost:** one extra network hop (~50–150 ms) and Netlify function limits
(125k invocations/month free — ample at current scale).

### Mini-map (Mapbox Maps iOS SDK)

The mini-map uses the **Mapbox Maps SDK v11** (SPM: `mapbox-maps-ios`) — a
native vector renderer, the mobile sibling of the Mapbox GL JS engine that
noah-frontend and mmda-app use. This means the flood overlay is added **at
runtime in Swift** with the exact same source + step-expression pattern as the
web maps — no Studio style, no tile proxy needed:

- Basemap: the NOAH terrain style (`upri-noah/ckupb1t4ybxq517s530madpso`)
- Overlay: vector source `upri-noah.mm_fh_100yr_tls`, 9 fill layers
  (`mm_fh_100yr_a…h, j`), colored by `Var` (depth in meters) with the
  Flow_Legend_v2 ramp: 0.20 yellow · 0.51 orange · 1.01 magenta · 2.01 purple
  · 5.01 cobalt, at 0.65 opacity
- Token: a **public (`pk.`) access token** in `BAHAR-QC-Info.plist` under
  `MBXAccessToken`. Public tokens are designed to ship in clients (the web
  apps expose theirs the same way); the *secret* token for the depth lookup
  stays on Netlify. SDK v11 binaries download without credentials — no
  `~/.netrc` needed.

---

## Flood classification (MMDA gauge)

| Depth | Inches | Category | Meaning |
|---|---|---|---|
| < 0.2032 m | < 8" | — | "LITTLE TO NONE" — no AR water shown |
| 0.20–0.33 m | 8–13" | PATV | Passable to all vehicle types (gutter / half-knee) |
| 0.33–0.66 m | 13–26" | NPLV | Not passable to light vehicles (half-tire / knee) |
| > 0.66 m | 26"+ | NPATV | Not passable to any vehicle (tire / waist / chest) |

The 8-inch noise floor matches both NOAH Studio's "Little to None" wording and
the MMDA gauge's lowest classified tier, and is applied identically to the HUD
text and the AR water visibility.

---

## Testing aids

- **Depth override:** `debugDepthOverride` in `ContentView.swift` forces a flood
  depth anywhere (bypasses the NOAH lookup) for testing outside flood-prone
  areas. Must be `nil` in release builds.
- **Solo testing:** mirror the phone to a Mac (QuickTime → New Movie Recording →
  iPhone as source) or use iOS screen recording, prop the phone up, and walk
  into frame.

## Known limitations

- **Street-level assumption:** ARKit anchors water to the floor the user stands
  on. On an upper floor, flood depth (which is relative to street level) renders
  incorrectly at that floor. Planned: on-screen disclaimer and/or floor prompt.
- **Model data, not live data:** depths come from the 100-yr return period
  hazard model, not real-time sensors.
- **Coverage:** Metro Manila bounding box (14.35–14.82 N, 120.90–121.20 E).

---

## Porting roadmap (assessed July 6, 2026)

### Web parity with the iOS design — ~1 week, with a hard platform limit

Achievable (~2–4 days): mini-map via Mapbox GL JS (same style + step-expression
pattern as `MiniMapView.swift`), HUD design parity, GLSL port of the water look
(FBM waves + faked reflections, ~80% fidelity), underwater POV overlay. The
flood lookup / MMDA gauge logic is already mirrored.

**Not achievable on iOS Safari, ever:** Apple ships no WebXR, so the web
fallback (`js/ar-renderer-ios.js`) is getUserMedia + DeviceOrientation —
**3DOF only** (rotation, no position) with camera height hardcoded at 1.6 m.
No ground detection means no reliable waterline on the body, and no positional
tracking means water isn't world-locked when the photographer moves. This is a
platform restriction, not a code gap — it is why the native iOS app is the
product. On iPhone browsers the web version stays a "preview."

**Android Chrome is the exception:** it has WebXR with hit-test, and the
renderer already branches into a proper immersive-ar session there. Ground
detection and world-locking work. Closing the gap to near-native quality on
Android web is ~1–2 days on top of the visual work.

### Native Android app — ~3–4 weeks

Every iOS component has a direct counterpart:

| iOS | Android | Difficulty |
|---|---|---|
| ARKit (planes, raycasts) | ARCore `Session` / `Plane` / `hitTest()` | Easy — 1:1 mapping; the 5-point raycast + lowest-hit + ≥1.5 m² plane logic translates directly |
| RealityKit water plane | SceneView (Filament) or OpenGL ES | Medium |
| `WaterShader.metal` | Filament material / GLSL | **Long pole** — Metal→GLSL rewrite, but FBM/fresnel math copies over |
| `CameraReflection.swift` | ARCore `acquireCameraImage` | Easier than iOS |
| SwiftUI HUD | Jetpack Compose | Mechanical |
| Mapbox Maps iOS SDK | Mapbox Maps Android SDK v11 | Near copy-paste — same v11 API, same token |
| `FloodData.swift` | Retrofit/Ktor → same Netlify endpoint | Trivial (the proxy exists for this) |

The body-filter insight (no segmentation; a correctly-placed semi-transparent
plane crosses the body at the waterline) is pure geometry and carries over
unchanged.

**Caveat:** ARCore requires certified devices — most mid-range+ Androids from
~2019 on, but many budget phones are excluded, which matters in the Philippine
market.

### Recommendation

Ship the Android-web path first (mostly work we'd do anyway for web parity,
zero app-store friction — users just open bahar-mm.netlify.app), and go native
Android only if higher-fidelity rendering, offline use, or Play Store presence
is needed. The Netlify proxy and Mapbox setup support either path without
backend changes.
