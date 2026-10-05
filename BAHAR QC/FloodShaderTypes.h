//
//  FloodShaderTypes.h
//  BAHAR QC
//
//  Uniforms shared by FloodController.swift (via the bridging header) and
//  FloodWater.metal, so both sides agree on the exact memory layout.
//  Only edit this struct here — never in a Swift copy.
//

#pragma once
#include <simd/simd.h>

typedef struct {
    simd_float4x4 invProjection;    // clip -> camera space
    simd_float4x4 cameraToWorld;    // camera space -> world
    simd_float4x4 viewProjection;   // world -> clip
    simd_float3   cameraPosition;
    simd_float3   waterTint;
    simd_float3   underwaterTint;
    simd_float3   skyColor;
    simd_float3   sunDirection;     // world space, pointing toward the sun
    float enabled;                  // 0 or 1
    float time;
    float waterHeight;              // calm water level, world Y (m)
    float waveAmp, waveSpeed, waveScale;
    float rippleScale, rippleStrength, rippleSpeed;
    float refractionStrength, waterTintStrength;
    float reflectionStrength, reflectionBias, fresnelPower, reflectionDistance;
    float specularPower, specularIntensity;
    float fadeStart, fadeEnd;
    float underwaterTintStrength;
    float wobbleAmount, wobbleScale, wobbleSpeed;
    float vignette;
    float meniscusWidth, meniscusStrength;
    float debugMode;                // 0 off, 1 horizon (ray.y < 0 red), 2 hit-point 1 m checkerboard
} FloodUniforms;
