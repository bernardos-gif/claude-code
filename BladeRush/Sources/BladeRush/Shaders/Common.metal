// BLADE RUSH — shared shader header. Prepended to every shader file at runtime
// compilation (ShaderLibrary.swift). Struct layouts mirror the Swift side exactly.
#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------- Data layouts

struct Vertex {                 // 40 bytes (MeshTypes.swift: Vertex)
    packed_float3 position;
    packed_float3 normal;
    uchar4 color;               // rgb tint, a = baked cavity AO
    uchar4 bones;
    uchar4 weights;
    uchar4 attr;                // x material slot, y edge wear, z emissive mask, w detail
};

struct InstanceData {           // 176 bytes (RenderFrame.swift: InstanceGPU)
    float4x4 model;
    float4x4 prevModel;
    float4 tint;                // rgb multiplier, a opacity
    float4 params;              // x hit flash, y emissive boost, z telegraph glow, w flags (1000 = arena floor)
    float4 flash;               // rgb flash color, a telegraph kind
};

struct MaterialGPU {            // 64 bytes (MeshTypes.swift: MaterialDesc.packed)
    float4 baseMetal;           // rgb base color, a metallic
    float4 emissiveRough;       // rgb emissive (pre-multiplied), a roughness
    float4 kindWearDirtRust;    // x kind, y wear, z dirt, w rust
    float4 frostScaleRunesSheen;
};

struct SkyParams {              // 112 bytes (Sky.swift: SkyParams)
    float4 zenith;              // rgb, w preset id
    float4 horizon;             // rgb, w cloud cover
    float4 ground;              // rgb, w star intensity
    float4 sunColor;            // rgb, w cos(sun radius)
    float4 accent;              // rgb, w strength
    float4 params;              // x sun disc, y horizon falloff, z time, w lightning
    float4 moonDir;             // xyz, w size
};

struct FrameUniforms {          // GPUTypes.swift: FrameUniformsGPU (1248 bytes)
    float4x4 view;
    float4x4 proj;
    float4x4 viewProj;
    float4x4 invViewProj;
    float4x4 prevViewProj;
    float4x4 invProj;
    float4x4 viewProjNoJitter;
    float4x4 prevViewProjNoJitter;
    float4x4 invView;
    float4x4 shadowViewProj[3];
    float4 cameraPos;           // xyz, w time
    float4 sunDir;              // xyz toward sun, w intensity
    float4 sunColor;            // rgb, w ambient intensity
    float4 fogColor;            // rgb, w density
    float4 fogParams;           // x height, y scatter, z wetness, w lightning
    float4 rimColor;            // rgb, w intensity
    float4 sh[9];
    float4 cascadeSplits;       // view-space far distance of each cascade
    float4 screen;              // w, h, 1/w, 1/h of the internal render target
    float4 jitter;              // xy jitter (ndc), zw previous jitter
    float4 flags;               // x ssao, y contact shadows, z shadows, w frame index
    float4 tileInfo;            // x tilesX, y tilesY, z light count, w near
    float4 floorColor2;         // rgb secondary floor color, w floor pattern id
    float4 misc;                // x far, y exposure, z ssr on, w volumetrics on
    float4 shadowInfo;          // x texel size, y bias, z cascade count, w unused
    SkyParams sky;
};

struct PointLight {             // 32 bytes
    float4 positionRadius;
    float4 colorIntensity;
};

struct Particle {               // 80 bytes
    float4 posLife;
    float4 velSize;
    float4 color;
    float4 params;              // x max life, y drag, z gravity, w kind
    float4 extra;               // x growth, y spin, z stretch, w seed
};

struct TrailVertex {            // 32 bytes
    float4 position;            // xyz, w = u
    float4 color;
};

struct Decal {                  // 48 bytes
    float4 centerRadius;
    float4 params;              // x rotation, y age01, z kind, w seed
    float4 color;
};

struct UIQuad {                 // 80 bytes
    float4 rect;
    float4 color;
    float4 color2;
    float4 params;              // x radius, y border, z glow, w kind
    float4 extra;
};

#define TILE_SIZE 16
#define MAX_LIGHTS_PER_TILE 63
#define PI 3.14159265359

// ---------------------------------------------------------------- Samplers

constexpr sampler sLinearRepeat(coord::normalized, filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
constexpr sampler sLinearClamp(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);
constexpr sampler sPointClamp(coord::normalized, filter::nearest, address::clamp_to_edge);
constexpr sampler sShadow(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);

// ---------------------------------------------------------------- Helpers

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle: 3 vertices, uv in [0,1] with (0,0) at the top-left.
inline FullscreenOut fullscreenVertex(uint vid) {
    FullscreenOut o;
    float2 p = float2((vid << 1) & 2, vid & 2);
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// Every shader library gets its own copy (Common.metal is prepended to each file).
vertex FullscreenOut vs_fullscreen(uint vid [[vertex_id]]) { return fullscreenVertex(vid); }

inline float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

inline float hash13(float3 p3) {
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

// Interleaved gradient noise (Jimenez) for dithering ray marches.
inline float ign(float2 pixel, float frame) {
    pixel += 5.588238 * fmod(frame, 64.0);
    return fract(52.9829189 * fract(0.06711056 * pixel.x + 0.00583715 * pixel.y));
}

inline float3 evalSH(constant FrameUniforms& U, float3 n) {
    float3 r = U.sh[0].xyz * 0.282095;
    r += U.sh[1].xyz * 0.488603 * n.y + U.sh[2].xyz * 0.488603 * n.z + U.sh[3].xyz * 0.488603 * n.x;
    r += U.sh[4].xyz * 1.092548 * n.x * n.y + U.sh[5].xyz * 1.092548 * n.y * n.z;
    r += U.sh[6].xyz * 0.315392 * (3.0 * n.z * n.z - 1.0);
    r += U.sh[7].xyz * 1.092548 * n.x * n.z + U.sh[8].xyz * 0.546274 * (n.x * n.x - n.y * n.y);
    return max(r, 0.0);
}

// View-space position from linear depth (positive distance along -Z) and uv.
inline float3 viewPosFromDepth(constant FrameUniforms& U, float2 uv, float linearDepth) {
    float2 ndc = float2(uv.x * 2.0 - 1.0, (1.0 - uv.y) * 2.0 - 1.0);
    float x = ndc.x / U.proj[0][0];
    float y = ndc.y / U.proj[1][1];
    return float3(x * linearDepth, y * linearDepth, -linearDepth);
}

inline float2 viewToUV(constant FrameUniforms& U, float3 vp) {
    float4 c = U.proj * float4(vp, 1.0);
    float2 ndc = c.xy / c.w;
    return float2(ndc.x * 0.5 + 0.5, 1.0 - (ndc.y * 0.5 + 0.5));
}

// ---------------------------------------------------------------- Sky

inline float skyNoise(float2 p, texture2d<float> noiseTex) {
    return noiseTex.sample(sLinearRepeat, p, level(0)).r;
}

inline float3 skyColor(constant SkyParams& S, float3 d, float3 sunDir, float sunIntensity, texture2d<float> noiseTex, bool withSun) {
    float preset = S.zenith.w;
    float y = d.y;
    float3 col;
    if (y >= 0.0) {
        float t = pow(1.0 - y, 3.0);
        col = mix(S.zenith.rgb, S.horizon.rgb, t);
    } else {
        col = mix(S.horizon.rgb * 0.6, S.ground.rgb, saturate(-y * 4.0));
    }
    float time = S.params.z;
    // Stars.
    if (S.ground.w > 0.0 && y > 0.0) {
        float3 sd = d * 300.0;
        float st = hash13(floor(sd));
        float star = step(0.9965, st) * saturate(y * 3.0);
        float tw = 0.6 + 0.4 * sin(time * 3.0 + st * 60.0);
        col += float3(star * S.ground.w * 2.5 * tw);
    }
    // Aurora ribbons.
    if (preset == 3.0 && y > 0.0) {
        float2 p = d.xz / (y + 0.25);
        float n1 = skyNoise(p * 0.08 + float2(time * 0.01, 0.0), noiseTex);
        float n2 = skyNoise(p * 0.15 - float2(0.0, time * 0.015), noiseTex);
        float band = exp(-pow((n1 - 0.5) * 7.0, 2.0)) * saturate(y * 2.0) * (1.0 - saturate((y - 0.7) * 3.0));
        col += S.accent.rgb * band * (0.8 + n2) * S.accent.w * 1.6;
        col += float3(0.6, 0.2, 0.9) * band * n2 * 0.4;
    }
    // Clouds (flat layer projection).
    float cover = S.horizon.w;
    if (cover > 0.01 && y > 0.0) {
        float2 cp = d.xz / (y + 0.12) * 0.35 + float2(time * 0.004, time * 0.002);
        float c = skyNoise(cp, noiseTex) * 0.65 + skyNoise(cp * 2.3 + 1.7, noiseTex) * 0.35;
        float mask = smoothstep(1.0 - cover, 1.0 - cover + 0.35, c) * saturate(y * 6.0);
        float3 cloudCol = mix(S.horizon.rgb * 0.55, S.zenith.rgb * 1.4 + S.horizon.rgb * 0.3, saturate(c));
        float sunLit = pow(saturate(dot(d, sunDir)), 4.0);
        cloudCol += S.sunColor.rgb * sunLit * 0.6 * S.params.x;
        col = mix(col, cloudCol, mask * 0.9);
    }
    // Sun glow + disc.
    float sd = saturate(dot(d, sunDir));
    col += S.sunColor.rgb * (pow(sd, 8.0) * 0.35 + pow(sd, 64.0) * 0.8) * sunIntensity * 0.25 * S.params.x;
    if (withSun && sd > S.sunColor.w && S.params.x > 0.0) {
        float edge = smoothstep(S.sunColor.w, S.sunColor.w + 0.0004, sd);
        col += S.sunColor.rgb * sunIntensity * 18.0 * edge;
    }
    // Moon / eclipse / blood moon.
    if (S.accent.w > 0.0 && (preset == 2.0 || preset == 4.0 || preset == 6.0 || preset == 9.0)) {
        float3 md = normalize(S.moonDir.xyz);
        float m = dot(d, md);
        float size = cos(S.moonDir.w);
        if (preset == 2.0 || preset == 9.0) {
            // Eclipse: black disc with a burning corona.
            float corona = pow(saturate((m - size + 0.02) / 0.02), 2.0) * (1.0 - step(size, m));
            float halo = pow(saturate(m), 180.0) * 2.0 + pow(saturate(m), 24.0) * 0.4;
            float rays = skyNoise(float2(atan2(d.x - md.x, d.y - md.y) * 2.0, time * 0.05), noiseTex);
            col += S.accent.rgb * (corona * 6.0 + halo * (0.6 + rays)) * S.accent.w;
            if (m > size) col = mix(col, float3(0.0), 0.98);
        } else {
            float disc = smoothstep(size, size + 0.0008, m);
            float3 moonCol = preset == 4.0 ? S.accent.rgb * 2.2 : float3(0.9, 0.93, 1.0) * 1.8;
            float crater = skyNoise(d.xy * 12.0, noiseTex);
            col = mix(col, moonCol * (0.75 + 0.25 * crater), disc);
            col += S.accent.rgb * pow(saturate(m), 60.0) * 0.5 * S.accent.w;
        }
    }
    // Underground glow from below.
    if (preset == 5.0) {
        col += S.accent.rgb * pow(saturate(-y + 0.2), 2.0) * S.accent.w * 0.8;
    }
    // Lightning flash.
    col += float3(0.6, 0.7, 1.0) * S.params.w * 1.5 * saturate(y + 0.3);
    return col;
}

// ---------------------------------------------------------------- PBR

inline float D_GGX(float NoH, float a) {
    float a2 = a * a;
    float d = NoH * NoH * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d + 1e-7);
}

inline float V_SmithGGXCorrelated(float NoV, float NoL, float a) {
    float a2 = a * a;
    float gv = NoL * sqrt(NoV * NoV * (1.0 - a2) + a2);
    float gl = NoV * sqrt(NoL * NoL * (1.0 - a2) + a2);
    return 0.5 / (gv + gl + 1e-6);
}

inline float3 F_Schlick(float3 f0, float VoH) {
    float f = pow(1.0 - VoH, 5.0);
    return f0 + (1.0 - f0) * f;
}

// Analytic environment BRDF approximation (Karis, mobile).
inline float3 envBRDFApprox(float3 specColor, float roughness, float NoV) {
    const float4 c0 = float4(-1.0, -0.0275, -0.572, 0.022);
    const float4 c1 = float4(1.0, 0.0425, 1.04, -0.04);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * NoV)) * r.x + r.y;
    float2 ab = float2(-1.04, 1.04) * a004 + r.zw;
    return specColor * ab.x + ab.y;
}

// ---------------------------------------------------------------- Tonemapping

// ACES fitted (Stephen Hill).
inline float3 acesFitted(float3 color) {
    const float3x3 inM = float3x3(float3(0.59719, 0.07600, 0.02840), float3(0.35458, 0.90834, 0.13383), float3(0.04823, 0.01566, 0.83777));
    const float3x3 outM = float3x3(float3(1.60475, -0.10208, -0.00327), float3(-0.53108, 1.10813, -0.07276), float3(-0.07367, -0.00605, 1.07602));
    float3 v = inM * color;
    float3 a = v * (v + 0.0245786) - 0.000090537;
    float3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
    return saturate(outM * (a / b));
}
