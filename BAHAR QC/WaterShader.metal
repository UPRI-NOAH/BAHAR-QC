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
    // undistorted patches. Strong baseline so every pixel rides obvious waves.
    float2 flowA = float2( sin(time * 0.55 + ruv.y * 0.7),
                           cos(time * 0.40 + ruv.x * 0.5) ) * 0.60;
    float2 flowB = float2( cos(time * 0.30 + ruv.x * 1.1),
                           sin(time * 0.45 + ruv.y * 0.9) ) * 0.45;
    dHdx += flowA.x + flowB.x;
    dHdz += flowA.y + flowB.y;

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

    // ===== Refraction: very-strongly-warped view of what's BELOW =====
    // The big UV-warp coefficient is the main "distortion" dial — values this
    // high push the underwater scene into the visibly-rippled territory of
    // the reference image. Reflection UV stays low so it remains mirror-like.
    float2 refractBase = screenUv + float2(dHdx, dHdz) * 0.340;
    float2 ca = float2(dHdx, dHdz) * 0.030;
    float2 uvR = clamp(refractBase + ca, 0.001, 0.999);
    float2 uvG = clamp(refractBase,      0.001, 0.999);
    float2 uvB = clamp(refractBase - ca, 0.001, 0.999);
    half3 refraction = half3(
        params.textures().custom().sample(camSampler, uvR).r,
        params.textures().custom().sample(camSampler, uvG).g,
        params.textures().custom().sample(camSampler, uvB).b
    );

    // ===== Reflection: mirrored view of what's ABOVE =====
    // Very low warp on the reflection UV — the mirror image stays mostly
    // coherent, just gently wobbling with the ripples. Refraction (above)
    // keeps the heavy wobble for the underwater distortion look.
    float2 reflectUv = float2(screenUv.x, 1.0 - screenUv.y);
    reflectUv += float2(dHdx * 0.02, dHdz * 0.03);
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

    // Very light cool tint — just a whisper of blue so the water reads as
    // water without darkening the heavily-distorted underwater scene.
    half3 waterTint = half3(0.45, 0.62, 0.85);
    half3 brightened = clamp(refraction + waterTint * half(0.12), half3(0.0), half3(1.0));
    half3 tintedRefraction = mix(refraction, brightened, half(0.22));

    // Fresnel-driven reflection: looking down at the water shows the warped
    // refraction (= heavy distortion of submerged content), looking flat at
    // the horizon shows near-pure mirror reflection. Tiny +0.05 floor keeps
    // a hint of sky reflection even straight-down so the surface still reads
    // as water rather than a hole.
    half reflectStrength = half(saturate(fresnel * 1.00 + 0.05));
    half3 finalColor = mix(tintedRefraction, reflection, reflectStrength);

    // Subtle sky sparkle.
    finalColor += half3(1.00, 0.97, 0.90) * half(sunSpec) * half(0.35);

    // Very faint trough darkening for depth cue.
    finalColor *= (half(1.0) - trough * half(0.05));

    params.surface().set_base_color(finalColor);
    params.surface().set_normal(rippleNormal);
    params.surface().set_roughness(half(0.03));
    params.surface().set_metallic(half(0.0));
    // Even more transparent — the underwater scene + the refraction warp +
    // the slight blue tint together still read as water, but more of the
    // unwarped background bleeds through for an airier, cleaner feel.
    params.surface().set_opacity(half(0.48) * half(edgeAlpha));
}
