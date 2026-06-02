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
// swells with finer chop riding on top. Output is normalised so it still sits
// roughly in 0…1 like the original 2-octave noise (downstream crest/shadow
// thresholds are tuned around that range).
static float ripples(float2 uv, float t) {
    const float2x2 rot = float2x2( 0.80, -0.60,
                                   0.60,  0.80);
    float2 dir = float2(1.0, 0.6);
    float sum = 0.0;
    float amp = 0.55;
    float freq = 1.0;
    float norm = 0.0;
    for (int i = 0; i < 3; i++) {
        sum  += amp * valueNoise(uv * freq + dir * (t * (0.25 + 0.10 * float(i))));
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

    // Heavy bump — pushes the surface toward a glassy, strongly-distorted look
    // (matches the reference). The refraction/reflection UV warp below uses
    // these gradients directly, so this dial controls "how wavy" the water
    // reads to the eye.
    const float bumpStrength = 0.45;
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

    // ===== Refraction: strongly-warped view of what's BELOW =====
    // The big UV-warp coefficient is the main "distortion" dial — large values
    // give the heavy wobble you see when looking through real shallow water.
    // Chromatic aberration retained but small; the dominant effect is the warp.
    float2 refractBase = screenUv + float2(dHdx, dHdz) * 0.090;
    float2 ca = float2(dHdx, dHdz) * 0.010;
    float2 uvR = clamp(refractBase + ca, 0.001, 0.999);
    float2 uvG = clamp(refractBase,      0.001, 0.999);
    float2 uvB = clamp(refractBase - ca, 0.001, 0.999);
    half3 refraction = half3(
        params.textures().custom().sample(camSampler, uvR).r,
        params.textures().custom().sample(camSampler, uvG).g,
        params.textures().custom().sample(camSampler, uvB).b
    );

    // ===== Reflection: mirrored view of what's ABOVE =====
    // Lighter warp than refraction so the reflection stays spatially coherent
    // and reads as a real mirror image rather than a noisy field. Refraction
    // (above) keeps the heavy wobble for the underwater distortion look.
    float2 reflectUv = float2(screenUv.x, 1.0 - screenUv.y);
    reflectUv += float2(dHdx * 0.05, dHdz * 0.07);
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

    // Near-neutral water tint — barely any blue cast. The reference reads as
    // "clear water" rather than "pool water"; the colour comes from the
    // reflection/refraction of the scene, not from a colour overlay.
    half3 waterTint = half3(0.55, 0.62, 0.66);
    half3 brightened = clamp(refraction + waterTint * half(0.10), half3(0.0), half3(1.0));
    half3 tintedRefraction = mix(refraction, brightened, half(0.30));

    // Reflection contributes substantially across the whole surface, not just
    // at the horizon — this is what makes the water look wet and mirror-like.
    half reflectStrength = half(saturate(fresnel * 0.85 + 0.15));
    half3 finalColor = mix(tintedRefraction, reflection, reflectStrength);

    // Subtle sky sparkle.
    finalColor += half3(1.00, 0.97, 0.90) * half(sunSpec) * half(0.35);

    // Very faint trough darkening for depth cue.
    finalColor *= (half(1.0) - trough * half(0.05));

    params.surface().set_base_color(finalColor);
    params.surface().set_normal(rippleNormal);
    params.surface().set_roughness(half(0.03));
    params.surface().set_metallic(half(0.0));
    // Mostly opaque — the surface should read as a real wet/reflective layer
    // sitting over the scene rather than a colour film over it. Underwater
    // content shows through via the refraction sample, not via alpha-blend.
    params.surface().set_opacity(half(0.85) * half(edgeAlpha));
}
