//
//  WaterShader.metal
//  BAHAR QC
//
//  Two halves:
//    1. `cameraYCbCrToRGB` — compute kernel that converts ARKit's biplanar
//       YpCbCr `capturedImage` into a viewport-aligned RGBA texture, applying
//       the inverse displayTransform so the shader can sample with screen UVs.
//    2. `waterSurface` — RealityKit CustomMaterial surface shader. Procedural
//       ripples, true screen-space reflection of the live camera feed (mirrored
//       across the screen midline + refracted by the ripple normal), and
//       fresnel-driven mixing with a water tint.
//
//  RealityKit's surface_parameters uses ROW-VECTOR multiplication:
//      clipPos = float4(worldPos, 1) * worldToView * viewToProjection;
//  Not the column-vector form you'd expect from generic Metal.
//

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

// MARK: - Noise / ripple helpers

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Three-octave FBM in world-meter UV. Each octave drifts in a rotated
// direction so the surface has natural, non-uniform structure: large slow
// swells with finer chop riding on top. Base frequency chosen so multiple
// ripple bands are visible within the on-screen water area at typical
// viewing distances.
static float ripples(float2 uv, float t) {
    const float2x2 rot = float2x2( 0.80, -0.60,
                                   0.60,  0.80);
    float2 dir = float2(1.0, 0.6);
    float sum = 0.0;
    float amp = 0.55;
    float freq = 0.80;
    float norm = 0.0;
    for (int i = 0; i < 3; i++) {
        sum  += amp * valueNoise(uv * freq + dir * (t * (0.20 + 0.08 * float(i))));
        norm += amp;
        freq *= 2.35;
        amp  *= 0.55;
        dir   = rot * dir;
    }
    return sum / norm;
}

// MARK: - YpCbCr → RGB compute kernel

kernel void cameraYCbCrToRGB(
    texture2d<float, access::sample> yTex     [[texture(0)]],
    texture2d<float, access::sample> cbcrTex  [[texture(1)]],
    texture2d<float, access::write>  outTex   [[texture(2)]],
    constant float3x3& invDisplay             [[buffer(0)]],
    uint2 gid                                 [[thread_position_in_grid]]
) {
    const uint outW = outTex.get_width();
    const uint outH = outTex.get_height();
    if (gid.x >= outW || gid.y >= outH) { return; }

    float2 viewportUv = (float2(gid) + 0.5) / float2(outW, outH);
    float3 mapped = invDisplay * float3(viewportUv, 1.0);
    float2 cameraUv = mapped.xy / mapped.z;

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float  y    = yTex.sample(s, cameraUv).r;
    float2 cbcr = cbcrTex.sample(s, cameraUv).rg;

    // BT.601 full range — Apple's standard ARKit metal sample matrix.
    const float4x4 ycbcrToRGB = float4x4(
        float4( 1.0000,  1.0000,  1.0000, 0.0),
        float4( 0.0000, -0.3441,  1.7720, 0.0),
        float4( 1.4020, -0.7141,  0.0000, 0.0),
        float4(-0.7010,  0.5291, -0.8860, 1.0)
    );
    outTex.write(ycbcrToRGB * float4(y, cbcr, 1.0), gid);
}

// MARK: - Water vertex displacement (geometry modifier)
//
// Pushes the plane vertices up/down by the ripple height field. The plane
// mesh must be subdivided (many vertices) for this to produce visible waves;
// the default `MeshResource.generatePlane` quad only has 4 corner vertices
// and won't show ripples. See ARContainerView.makeSubdividedPlane().

[[visible]]
void waterGeometry(realitykit::geometry_parameters params)
{
    const float  time     = params.uniforms().time();
    const float3 modelPos = params.geometry().model_position();
    // Plane lies in XZ; use that as the noise UV (in metres).
    const float2 uv = modelPos.xz;
    const float  h  = ripples(uv, time);
    // Big amplitude so the waterline visibly bobs up and down across objects
    // even at shallow flood depths. Peak-to-peak ~50 cm — dramatic but reads
    // as wavy water rather than a stormy ocean.
    const float amplitude = 0.25;
    const float offset    = (h - 0.5) * 2.0 * amplitude;
    params.geometry().set_model_position_offset(float3(0.0, offset, 0.0));
}

// MARK: - Water surface shader

[[visible]]
void waterSurface(realitykit::surface_parameters params)
{
    const float  time     = params.uniforms().time();
    const float3 worldPos = params.geometry().world_position();
    const float2 ruv      = worldPos.xz;

    // Finite-difference ripple normal from the height field.
    const float eps = 0.012;
    float h    = ripples(ruv, time);
    float hX1  = ripples(ruv + float2(eps, 0.0), time);
    float hX0  = ripples(ruv - float2(eps, 0.0), time);
    float hZ1  = ripples(ruv + float2(0.0, eps), time);
    float hZ0  = ripples(ruv - float2(0.0, eps), time);
    float dHdx = (hX1 - hX0) / (2.0 * eps);
    float dHdz = (hZ1 - hZ0) / (2.0 * eps);

    // Always-on directional flow added to the gradient — FBM noise has natural
    // dead zones at its peaks/troughs (gradient ≈ 0), which show up as flat,
    // undistorted patches.
    float2 flowA = float2( sin(time * 0.55 + ruv.y * 0.7),
                           cos(time * 0.40 + ruv.x * 0.5) ) * 0.55;
    float2 flowB = float2( cos(time * 0.30 + ruv.x * 1.1),
                           sin(time * 0.45 + ruv.y * 0.9) ) * 0.40;
    dHdx += flowA.x + flowB.x;
    dHdz += flowA.y + flowB.y;

    // Clamp gradient magnitude so we predictably stay inside the UV range
    // even with very aggressive warp coefficients — past about 0.45 the
    // refraction sample hits the screen edge and stops looking distorted.
    float gradLen = length(float2(dHdx, dHdz));
    const float gradLimit = 1.6;
    if (gradLen > gradLimit) {
        float s = gradLimit / gradLen;
        dHdx *= s;
        dHdz *= s;
    }

    // Heavy bump — used for the lighting normal. Refraction/reflection UV
    // warps below use dHdx/dHdz directly (bump strength not applied), so
    // those have their own warp coefficients.
    const float bumpStrength = 0.55;
    float3 rippleNormal = normalize(float3(-dHdx * bumpStrength,
                                            1.0,
                                           -dHdz * bumpStrength));

    // Soft edge fade for the 30 m plane.
    float2 quv = params.geometry().uv0();
    float2 fromCenter = abs(quv - 0.5) * 2.0;
    float edgeAlpha = 1.0 - smoothstep(0.92, 1.0, max(fromCenter.x, fromCenter.y));

    // ===== Live screen-space reflection of the camera feed =====
    // World → view → clip → NDC → screen UV. ROW-vector convention.
    float4x4 worldToView = params.uniforms().world_to_view();
    float4x4 viewToProj  = params.uniforms().view_to_projection();
    float4 clipPos = float4(worldPos, 1.0) * worldToView * viewToProj;
    float2 ndc = clipPos.xy / clipPos.w;
    float2 screenUv;
    screenUv.x = ndc.x * 0.5 + 0.5;
    screenUv.y = 1.0 - (ndc.y * 0.5 + 0.5);   // Metal Y-flip

    constexpr sampler camSampler(filter::linear, address::clamp_to_edge);

    // ===== Refraction: heavily-warped view of what's BELOW =====
    // Two-layer warp:
    //  (a) the main gradient (dHdx/dHdz) — drives the BIG wave distortion that
    //      matches the vertex-displaced surface waves.
    //  (b) an extra high-frequency "chop" noise layer — tight localized warp
    //      that visibly bends the silhouette of submerged objects.
    // The chop term is independent of the vertex waves, so the surface wave
    // shape stays as the user likes while underwater objects get extra bend.
    const float chopFreq = 3.5;
    const float chopEps  = 0.008;
    float chopX1 = ripples((ruv + float2(chopEps, 0.0)) * chopFreq, time * 1.4);
    float chopX0 = ripples((ruv - float2(chopEps, 0.0)) * chopFreq, time * 1.4);
    float chopZ1 = ripples((ruv + float2(0.0, chopEps)) * chopFreq, time * 1.4);
    float chopZ0 = ripples((ruv - float2(0.0, chopEps)) * chopFreq, time * 1.4);
    float dCdx   = (chopX1 - chopX0) / (2.0 * chopEps);
    float dCdz   = (chopZ1 - chopZ0) / (2.0 * chopEps);

    float2 mainWarp  = float2(dHdx, dHdz) * 0.250;
    float2 chopWarp  = float2(dCdx, dCdz) * 0.080;
    float2 refractBase = screenUv + mainWarp + chopWarp;
    float2 ca = (mainWarp + chopWarp) * 0.10;
    float2 uvR = clamp(refractBase + ca, 0.001, 0.999);
    float2 uvG = clamp(refractBase,      0.001, 0.999);
    float2 uvB = clamp(refractBase - ca, 0.001, 0.999);
    half3 refraction = half3(
        params.textures().custom().sample(camSampler, uvR).r,
        params.textures().custom().sample(camSampler, uvG).g,
        params.textures().custom().sample(camSampler, uvB).b
    );

    // ===== Reflection: mirrored view of what's ABOVE, also wobbled =====
    // Reference image has heavy distortion on the *reflected* content too
    // (the guy's torso reflected onto the water is wavy, not crisp mirror).
    // Still lighter than refraction warp so it reads as reflection rather
    // than chaos.
    float2 reflectUv = float2(screenUv.x, 1.0 - screenUv.y);
    reflectUv += float2(dHdx * 0.10, dHdz * 0.12);
    reflectUv = clamp(reflectUv, 0.001, 0.999);
    half3 reflection = half3(params.textures().custom().sample(camSampler, reflectUv).rgb);

    // Ripple height bands for subtle tonal variation.
    float rippleHeight = h - 0.5;
    half crest  = half(saturate(rippleHeight * 1.6));
    half trough = half(saturate(-rippleHeight * 1.4));

    // Fresnel via view_direction (fragment → viewer). Softer exponent so
    // reflection contributes at most angles, not only at glancing — the
    // reference image has bright reflections all over the water surface.
    float3 viewDir = params.geometry().view_direction();
    float NdotV = saturate(dot(rippleNormal, viewDir));
    float fresnel = pow(1.0 - NdotV, 1.8);

    // Light sky sparkle — kept very subtle. The reference is more glassy than
    // sparkly; we don't want point highlights distracting from the wobble.
    float3 sunDir = normalize(float3(0.40, 0.85, 0.30));
    float3 halfV  = normalize(sunDir + viewDir);
    float sunSpec = pow(saturate(dot(rippleNormal, halfV)), 80.0);

    // Stronger cool-blue tint applied to BOTH refraction (under water) AND
    // reflection (mirror on the surface) — otherwise the blue only shows when
    // looking down at the water, and glancing-angle reflections look grey.
    half3 waterTint = half3(0.20, 0.50, 0.95);
    half3 brightenedRefr = clamp(refraction + waterTint * half(0.35), half3(0.0), half3(1.0));
    half3 tintedRefraction = mix(refraction, brightenedRefr, half(0.55));
    half3 brightenedRefl = clamp(reflection + waterTint * half(0.30), half3(0.0), half3(1.0));
    half3 tintedReflection = mix(reflection, brightenedRefl, half(0.45));

    // Fresnel-driven reflection: looking down at the water shows the warped
    // refraction (= heavy distortion of submerged content), looking flat at
    // the horizon shows near-pure mirror reflection. Tiny +0.05 floor keeps
    // a hint of sky reflection even straight-down so the surface still reads
    // as water rather than a hole.
    half reflectStrength = half(saturate(fresnel * 1.00 + 0.05));
    half3 finalColor = mix(tintedRefraction, tintedReflection, reflectStrength);

    // Subtle sky sparkle.
    finalColor += half3(1.00, 0.97, 0.90) * half(sunSpec) * half(0.35);

    // Very faint trough darkening for depth cue.
    finalColor *= (half(1.0) - trough * half(0.05));

    params.surface().set_base_color(finalColor);
    params.surface().set_normal(rippleNormal);
    params.surface().set_roughness(half(0.03));
    params.surface().set_metallic(half(0.0));
    // A touch less transparent so the blue tint reads as blue water rather
    // than grey haze. Submerged content still shows through via the warped
    // refraction sample beneath the tint.
    params.surface().set_opacity(half(0.62) * half(edgeAlpha));
}
