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

    // Finite-difference ripple normal from the height field. Smaller eps gives
    // crisper micro-detail in the normal now that FBM contributes high octaves.
    const float eps = 0.012;
    float h    = ripples(ruv, time);
    float hX1  = ripples(ruv + float2(eps, 0.0), time);
    float hX0  = ripples(ruv - float2(eps, 0.0), time);
    float hZ1  = ripples(ruv + float2(0.0, eps), time);
    float hZ0  = ripples(ruv - float2(0.0, eps), time);
    float dHdx = (hX1 - hX0) / (2.0 * eps);
    float dHdz = (hZ1 - hZ0) / (2.0 * eps);

    // Gentle bump — submerged content must still be clearly readable through
    // the water. Slightly stronger than before to take advantage of the richer
    // FBM normal without crossing into "distorted glass" territory.
    const float bumpStrength = 0.20;
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

    // ===== Refraction with subtle chromatic aberration =====
    // RGB channels sample at slightly different offsets along the ripple
    // gradient — gives the warped underwater view a prismatic edge that
    // sells "real water" without being distracting.
    float2 refractBase = screenUv + float2(dHdx, dHdz) * 0.028;
    float2 ca = float2(dHdx, dHdz) * 0.006;
    float2 uvR = clamp(refractBase + ca, 0.001, 0.999);
    float2 uvG = clamp(refractBase,      0.001, 0.999);
    float2 uvB = clamp(refractBase - ca, 0.001, 0.999);
    half3 refraction = half3(
        params.textures().custom().sample(camSampler, uvR).r,
        params.textures().custom().sample(camSampler, uvG).g,
        params.textures().custom().sample(camSampler, uvB).b
    );

    // ===== Reflection: mirrored view of what's ABOVE =====
    float2 reflectUv = float2(screenUv.x, 1.0 - screenUv.y);
    reflectUv += float2(dHdx * 0.04, dHdz * 0.07);
    reflectUv = clamp(reflectUv, 0.001, 0.999);
    half3 reflection = half3(params.textures().custom().sample(camSampler, reflectUv).rgb);

    // Ripple bands from the height field.
    float rippleHeight = h - 0.5;
    half crest  = half(saturate(rippleHeight * 1.6));
    half trough = half(saturate(-rippleHeight * 1.4));

    // Fresnel via view_direction (fragment → viewer). Sharper curve = stronger
    // reflection at glancing angles, near-clear when looking straight down.
    float3 viewDir = params.geometry().view_direction();
    float NdotV = saturate(dot(rippleNormal, viewDir));
    float fresnel = pow(1.0 - NdotV, 4.0);

    // Blinn-Phong sun sparkle — cheap stand-in for sky highlights, gives the
    // surface its characteristic glittering. Sun direction is fixed in world
    // space; we don't have an IBL/sky to sample from.
    float3 sunDir = normalize(float3(0.45, 0.78, 0.40));
    float3 halfV  = normalize(sunDir + viewDir);
    float sunSpec = pow(saturate(dot(rippleNormal, halfV)), 96.0);

    // Blue water tint, slightly view-angle dependent — looking straight down
    // stays clear so submerged content reads, glancing angles bias richer so
    // the water feels deeper out toward the horizon.
    half tintAmount = half(mix(0.58, 0.85, 1.0 - NdotV));
    half3 waterTint = half3(0.16, 0.46, 1.00);
    half3 brightened = clamp(refraction + waterTint * half(0.45), half3(0.0), half3(1.0));
    half3 tintedRefraction = mix(refraction, brightened, tintAmount);

    // Glancing-angle reflection dominates; straight-down reflection nearly zero.
    half reflectStrength = half(saturate(fresnel * 0.55));
    half3 finalColor = mix(tintedRefraction, reflection, reflectStrength);

    // Foam on the very brightest crests — narrow band of near-white at the
    // peaks only. Keeps the rest of the surface clear and readable.
    half foamMask = half(smoothstep(0.55, 0.85, float(crest)));
    finalColor = mix(finalColor, half3(0.92, 0.96, 1.00), foamMask * half(0.45));

    // Additive sun sparkle, warm-tinted.
    finalColor += half3(1.00, 0.96, 0.85) * half(sunSpec) * half(0.60);

    // Faint trough shading so peaks feel like peaks; tiny multiplier so we
    // don't darken the water overall.
    finalColor *= (half(1.0) - trough * half(0.06));

    params.surface().set_base_color(finalColor);
    params.surface().set_normal(rippleNormal);
    params.surface().set_roughness(half(0.04));
    params.surface().set_metallic(half(0.0));
    // RealityKit alpha-blends behind the water, so the underwater content
    // still shows through. Slightly higher than before since FBM + foam adds
    // visual weight and we want the water to feel substantial.
    params.surface().set_opacity(half(0.58) * half(edgeAlpha));
}
