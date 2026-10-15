//
//  FloodWater.metal
//  BAHAR QC
//
//  Full-screen flood water post-process (ARView.renderCallbacks.postProcess).
//  No water mesh: every pixel builds a world-space view ray, intersects it with
//  the water plane analytically and shades it — above-water surface, underwater
//  grade, and the per-pixel waterline all come from this one kernel.
//

#include <metal_stdlib>
using namespace metal;
#include "FloodShaderTypes.h"

constexpr sampler linClamp(filter::linear, address::clamp_to_edge);
constexpr sampler nearClamp(filter::nearest, address::clamp_to_edge);   // r32Float isn't filterable everywhere

// ---- waves (world space, meters) ----
float waveHeight(float2 xz, constant FloodUniforms& u) {
    float2 p = xz * u.waveScale;
    float  s = u.time * u.waveSpeed;
    float  h = sin(dot(p, float2( 0.80,  0.60)) * 1.0 + s * 1.10) * 0.50
             + sin(dot(p, float2(-0.40,  0.92)) * 1.7 + s * 1.60) * 0.30
             + sin(dot(p, float2( 0.95, -0.31)) * 2.9 + s * 2.30) * 0.20;
    return u.waterHeight + h * u.waveAmp;
}

float2 hash22(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float gradNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float a = dot(hash22(i),                  f);
    float b = dot(hash22(i + float2(1, 0)), f - float2(1, 0));
    float c = dot(hash22(i + float2(0, 1)), f - float2(0, 1));
    float d = dot(hash22(i + float2(1, 1)), f - float2(1, 1));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

float rippleHeight(float2 p, float t) {
    return gradNoise(p + float2(t, t * 0.7)) * 0.6
         + gradNoise(p * 2.3 - float2(t * 1.3, -t * 0.4)) * 0.4;
}

float3 surfaceNormal(float2 xz, float dist, constant FloodUniforms& u) {
    const float e = 0.05;
    float hL = waveHeight(xz - float2(e, 0), u), hR = waveHeight(xz + float2(e, 0), u);
    float hD = waveHeight(xz - float2(0, e), u), hU = waveHeight(xz + float2(0, e), u);
    float3 N = normalize(float3(hL - hR, 2.0 * e, hD - hU));

    float2 p  = xz * u.rippleScale;
    float  t  = u.time * u.rippleSpeed;
    const float r = 0.08;
    float  h0 = rippleHeight(p, t);
    float2 g  = float2(rippleHeight(p + float2(r, 0), t) - h0,
                       rippleHeight(p + float2(0, r), t) - h0) / r;
    float strength = u.rippleStrength / (1.0 + dist * 0.15);   // calmer far away (less aliasing)
    return normalize(N + float3(-g.x, 0, -g.y) * strength);
}

float2 worldToUV(float3 w, constant FloodUniforms& u, thread bool& inFront) {
    float4 c = u.viewProjection * float4(w, 1);
    inFront = c.w > 0;
    float2 ndc = c.xy / c.w;
    return float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);   // Metal textures: origin top-left
}

float3 underwaterGrade(float3 c, constant FloodUniforms& u) {
    float  l = dot(c, float3(0.299, 0.587, 0.114));
    float3 tinted = mix(c * u.underwaterTint, l * u.underwaterTint * 1.1, 0.35);
    return mix(c, tinted, u.underwaterTintStrength);
}

kernel void floodWaterKernel(texture2d<float, access::sample> src [[texture(0)]],
                             texture2d<float, access::write>  dst [[texture(1)]],
                             texture2d<float, access::sample> depthMap [[texture(2)]],
                             constant FloodUniforms& u            [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]])
{
    uint W = dst.get_width(), H = dst.get_height();
    if (gid.x >= W || gid.y >= H) return;

    float2 uv    = (float2(gid) + 0.5) / float2(W, H);
    float3 scene = src.sample(linClamp, uv).rgb;
    if (u.enabled < 0.5) { dst.write(float4(scene, 1), gid); return; }

    // 1. view ray. z = 0.5 stays finite for both standard and reverse-Z infinite projections.
    float2 ndc   = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    float4 v     = u.invProjection * float4(ndc, 0.5, 1.0);
    float3 dirCS = normalize(v.xyz / v.w);
    float3 rd    = normalize((u.cameraToWorld * float4(dirCS, 0)).xyz);
    float3 ro    = u.cameraPosition;

    // 2. per-pixel waterline
    float3 lens       = ro + rd * 0.05;
    float  lensDepth  = waveHeight(lens.xz, u) - lens.y;   // > 0 means underwater
    bool   pixelUnder = lensDepth > 0.0;

    // 3. ray / water intersection, refined once with the wave height
    bool  hit = fabs(rd.y) > 1e-4;
    float t   = hit ? (u.waterHeight - ro.y) / rd.y : -1.0;
    if (hit && t > 0.0) {
        float3 p0 = ro + rd * t;
        t = (waveHeight(p0.xz, u) - ro.y) / rd.y;
    }
    hit = hit && t > 0.0;

    // 3b. real-world occlusion. Without it, a wall or person *above* the water
    // still gets painted, because the ray meets the plane somewhere behind
    // them — the waterline then climbs to eye level and follows the camera.
    // If the measured surface is closer than the water hit, it is above the
    // surface (camera above) or in the water before it (camera below): either
    // way no surface is drawn on that pixel.
    if (hit && u.hasDepth > 0.5) {
        float2 duv = (u.viewToDepthUV * float3(uv, 1.0)).xy;
        float  d   = depthMap.sample(nearClamp, duv).r;      // metres along camera -Z
        if (d > 0.0 && -dirCS.z > 1e-4) {
            float tReal = d / -dirCS.z;                      // distance along the ray
            if (tReal + 0.05 < t) hit = false;
        }
    }

    // Verification views for the ray setup (1) and floor/level placement (2).
    if (u.debugMode > 0.5) {
        float3 dbg = scene;
        if (u.debugMode < 1.5) {
            if (rd.y < 0.0) dbg = mix(scene, float3(1, 0, 0), 0.5);
        } else if (hit) {
            float2 cell = floor((ro + rd * t).xz);
            float  k    = fmod(fabs(cell.x + cell.y), 2.0);
            dbg = mix(scene, float3(k), 0.6);
        }
        dst.write(float4(dbg, 1), gid);
        return;
    }

    float3 col = scene;

    if (!pixelUnder) {
        // 4. above-water surface
        if (hit) {
            float3 p     = ro + rd * t;
            float  dist  = length(p.xz - ro.xz);
            float3 N     = surfaceNormal(p.xz, dist, u);
            float3 V     = -rd;
            float  NdotV = saturate(dot(N, V));

            float3 refr = src.sample(linClamp, uv + N.xz * u.refractionStrength).rgb;
            refr = mix(refr, refr * u.waterTint, u.waterTintStrength);

            float3 R = reflect(rd, N);
            bool   inFront;
            float2 ruv  = worldToUV(p + R * u.reflectionDistance, u, inFront);
            float2 edge = smoothstep(0.0, 0.12, ruv) * smoothstep(0.0, 0.12, 1.0 - ruv);
            float  ssrW = inFront ? edge.x * edge.y : 0.0;
            float3 refl = mix(u.skyColor, src.sample(linClamp, saturate(ruv)).rgb, ssrW);

            float F = mix(u.reflectionBias, 1.0, pow(1.0 - NdotV, u.fresnelPower)) * u.reflectionStrength;
            float3 surf = mix(refr, refl, F);

            float3 Hv = normalize(u.sunDirection + V);
            surf += pow(saturate(dot(N, Hv)), u.specularPower) * u.specularIntensity;

            float fade = 1.0 - smoothstep(u.fadeStart, u.fadeEnd, dist);
            col = mix(scene, surf, fade);
        }
    } else {
        // 5. underwater
        float  s   = u.time * u.wobbleSpeed;
        float2 wob = float2(gradNoise(uv * u.wobbleScale + s),
                            gradNoise(uv * u.wobbleScale + 17.3 - s)) * u.wobbleAmount;
        col = underwaterGrade(src.sample(linClamp, uv + wob).rgb, u);

        if (hit) {   // looking up at the underside
            float3 p     = ro + rd * t;
            float3 N     = surfaceNormal(p.xz, length(p.xz - ro.xz), u);
            float  NdotV = saturate(dot(-N, -rd));
            float3 refr  = src.sample(linClamp, uv + N.xz * u.refractionStrength * 1.5).rgb;

            float tir    = 1.0 - smoothstep(0.55, 0.75, NdotV);
            float window = 1.0 - tir;
            refr += u.skyColor * u.underwaterTint * 0.15 * window;

            // Lighter TIR colour (was tint * 0.6) and lower opacity
            const float tirOpacity = 0.25;
            float3 tirColor = mix(u.underwaterTint, float3(1.0), 0.20);

            // Soft bright ring where the window meets the TIR region
            float rim = smoothstep(0.50, 0.62, NdotV) * (1.0 - smoothstep(0.62, 0.80, NdotV));

            col  = underwaterGrade(mix(refr, tirColor, tir * tirOpacity), u);
            col += u.skyColor * u.underwaterTint * rim * 0.10;
            col  = mix(col, col + float3(0.08, 0.10, 0.10), saturate(rd.y) * 0.8);
        }

        // Lighter vignette when looking up
        float2 d  = uv - 0.5;
        float vig = u.vignette * (1.0 - 0.7 * saturate(rd.y));
        col *= saturate(1.0 - dot(d, d) * vig);

    }


    // 6. meniscus at the waterline
    float men = 1.0 - smoothstep(0.0, u.meniscusWidth, fabs(lensDepth));
    float menStrength = pixelUnder ? u.meniscusStrength * 0.6 : u.meniscusStrength;
    float3 menColor   = pixelUnder ? mix(u.underwaterTint, float3(1.0), 0.6) : float3(1.0);
    col = mix(col, menColor, men * menStrength);

    dst.write(float4(col, 1.0), gid);
}
