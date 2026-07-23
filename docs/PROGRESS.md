# BAHAR-QC — Progress Report

**Project:** BAHAR-QC (Flood Depth AR Visualizer for Metro Manila)
**Team:** UP Resilience Institute — NOAH
**Platform:** iOS (native ARKit app) · Web preview (Netlify)
**Repository:** github.com/UPRI-NOAH/BAHAR-QC

BAHAR-QC lets anyone point their iPhone camera at a person or the ground and see the
expected flood depth at their exact location as realistic AR water — powered by
UP NOAH's 100-year flood return model and classified using the official MMDA
flood gauge system (gutter / knee / waist / chest deep).

---

## Milestones

### May 2026 — Prototype
- First working prototype: Quezon City coverage, all 12 NCR flood tiles ingested
- Flood depth lookup from GPS position, MMDA-style depth card UI
- Landing page with prototype notice; "outside coverage area" handling
- Iterated on elevation correction, eventually simplified to polygon-based depth only

### June 18, 2026 — Accuracy fixes
- **Fixed stale flood readings:** lookup cache tightened from a ~55 m grid to ~5 m,
  matching the server query radius — readings no longer "bleed" across flood
  polygon boundaries when walking
- **Fixed server over-reporting:** Mapbox query tightened from 25 m radius / 5
  results to 5 m / 1 result — locations like UPRI no longer show false flood levels
- **Synced AR with the gauge:** AR water now hidden below the MMDA 8-inch (0.2032 m)
  noise floor, so the water visual always agrees with the "LITTLE TO NONE" reading
- All fixes mirrored to the web preview version

### June 19, 2026 — Design pass
- Web landing page and AR overlay redesigned to match the iOS native app design

### July 2, 2026 — Body-filter mode (first attempt)
- Enabled ARKit person segmentation intending a "standing in flood" effect

### July 6, 2026 — Body-filter corrected + mini-map
- **Field test finding:** person segmentation produced the *opposite* effect — the
  person cut a hole in the water instead of appearing submerged in it
- **Fixed:** segmentation removed; the semi-transparent water surface now crosses
  the body naturally at the waterline — upper body above water, submerged half
  visible through it (matches the reference behavior we wanted)
- **Fixed waterline height:** water sat above the waist because the ground level
  was estimated from hand height; now refined by ARKit raycasts against the real
  ground across 5 screen points — no user action needed
- **Water made more transparent** so the submerged person and ground read clearly
- **Mini-map added (complete):** live location map at the lower-left of the AR
  view showing the NOAH basemap with the flood-depth overlay (same coloring as
  the MMDA web map); tap to expand into a full pannable map. Built with the
  Mapbox Maps iOS SDK
- Added a developer depth-override for testing outside flood-prone areas
- **Porting assessment documented** (see ARCHITECTURE.md): web parity ≈1 week
  but iPhone browsers are permanently limited (no WebXR in iOS Safari); Android
  web already supports true AR via WebXR (~1–2 extra days); native Android app
  ≈3–4 weeks. Recommendation: Android-web first, native Android only if needed
- **Water look assessed against the reference (sample_peg.jpg):** the target is
  glassy, near-colorless water that takes its color from the reflected/refracted
  surroundings — field images confirm the surface already reads grey-green from
  the environment (not blue) and matches the reference character. Surface look
  is considered done; the only gap to the reference is the body-filter +
  waterline behavior awaiting field re-test. Earlier "murky brown" tuning plan
  dropped — the reference look is the goal, not photoreal turbid water

---

## Current status

| Item | Status |
|---|---|
| AR flood water with MMDA-accurate depth | ✅ Working |
| Water surface look vs. reference (sample_peg) | ✅ Achieved — glassy, environment-colored |
| Person appears submerged in water (body filter) | ✅ Fixed — pending field re-test |
| Waterline at correct body height | ✅ Fixed — pending field re-test |
| GPS flood lookup (NOAH 100-yr model) | ✅ Working |
| Mini-map: NOAH basemap + flood overlay + live location | ✅ Working (Mapbox SDK) |
| Underwater point-of-view effect | ✅ Working |
| AR snapshot & sharing | ✅ Working |

## Next steps

1. **Field re-test** of the corrected body filter in a real setting
2. **Street-level disclaimer** — the AR assumes the user is at ground level; a user
   on an upper floor would see flood water incorrectly rendered at their floor
3. Disable the developer depth-override before any release build
4. **TestFlight** distribution for stakeholder testing
5. Optional polish: reflection legibility (the reference's mirrored content is
   slightly more readable than the current marbled streaks) — only if field
   re-tests show a gap
6. **Android reach** — bring the web version to design parity (~1 week; full AR
   works on Android Chrome via WebXR); native Android app (~3–4 weeks) only if
   later justified

## Known limitations

- Coverage: Metro Manila only (NOAH 100-yr flood return model)
- Assumes user is at street level (upper-floor rendering not yet handled)
- Flood depth is from the hazard model — not a live/real-time flood feed
