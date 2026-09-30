// Post-processing: bloom mip chain, depth of field, motion blur and the final composite
// (exposure, ACES, grading, chromatic aberration, radial blur, vignette, grain, flashes).

struct PostGPU {                 // GPUTypes.swift: PostGPU (128 bytes)
    float4 grade;                // x exposure, y contrast, z saturation, w split strength
    float4 tint;                 // rgb tint, w vignette
    float4 shadows;              // rgb lift color, w grain
    float4 highlights;           // rgb gain color, w chromatic aberration
    float4 radial;               // xy center, z radial blur strength, w bloom strength
    float4 flash;                // rgb, a strength
    float4 effects;              // x desaturate, y low health, z slow motion, w letterbox
    float4 misc;                 // x time, y sharpen, z output width, w output height
};

// ---------------------------------------------------------------- Bloom

// 13-tap downsample (Jimenez, CoD:AW). P.zw = source texel size.
inline float3 downsample13(texture2d<float> src, float2 uv, float2 ts, bool karis) {
    float3 a = src.sample(sLinearClamp, uv + ts * float2(-2.0, -2.0)).rgb;
    float3 b = src.sample(sLinearClamp, uv + ts * float2(0.0, -2.0)).rgb;
    float3 c = src.sample(sLinearClamp, uv + ts * float2(2.0, -2.0)).rgb;
    float3 d = src.sample(sLinearClamp, uv + ts * float2(-2.0, 0.0)).rgb;
    float3 e = src.sample(sLinearClamp, uv).rgb;
    float3 f = src.sample(sLinearClamp, uv + ts * float2(2.0, 0.0)).rgb;
    float3 g = src.sample(sLinearClamp, uv + ts * float2(-2.0, 2.0)).rgb;
    float3 h = src.sample(sLinearClamp, uv + ts * float2(0.0, 2.0)).rgb;
    float3 i = src.sample(sLinearClamp, uv + ts * float2(2.0, 2.0)).rgb;
    float3 j = src.sample(sLinearClamp, uv + ts * float2(-1.0, -1.0)).rgb;
    float3 k = src.sample(sLinearClamp, uv + ts * float2(1.0, -1.0)).rgb;
    float3 l = src.sample(sLinearClamp, uv + ts * float2(-1.0, 1.0)).rgb;
    float3 m = src.sample(sLinearClamp, uv + ts * float2(1.0, 1.0)).rgb;
    if (karis) {
        // Weighted by 1 / (1 + luma) per group to kill fireflies.
        float3 g0 = (j + k + l + m) * 0.25;
        float3 g1 = (a + b + d + e) * 0.25;
        float3 g2 = (b + c + e + f) * 0.25;
        float3 g3 = (d + e + g + h) * 0.25;
        float3 g4 = (e + f + h + i) * 0.25;
        float w0 = 0.5 / (1.0 + luminance(g0));
        float w1 = 0.125 / (1.0 + luminance(g1));
        float w2 = 0.125 / (1.0 + luminance(g2));
        float w3 = 0.125 / (1.0 + luminance(g3));
        float w4 = 0.125 / (1.0 + luminance(g4));
        return (g0 * w0 + g1 * w1 + g2 * w2 + g3 * w3 + g4 * w4) / (w0 + w1 + w2 + w3 + w4);
    }
    float3 r = e * 0.125;
    r += (a + c + g + i) * 0.03125;
    r += (b + d + f + h) * 0.0625;
    r += (j + k + l + m) * 0.125;
    return r;
}

fragment float4 fs_bloom_prefilter(FullscreenOut in [[stage_in]],
                                   constant float4& P [[buffer(0)]],   // x threshold, y knee, zw source texel
                                   texture2d<float> src [[texture(0)]]) {
    float3 c = downsample13(src, in.uv, P.zw, true);
    c = min(c, float3(64.0));
    float br = max(c.r, max(c.g, c.b));
    float knee = P.x * P.y + 1e-4;
    float soft = clamp(br - P.x + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee);
    float contrib = max(soft, br - P.x) / max(br, 1e-4);
    return float4(c * contrib, 1.0);
}

fragment float4 fs_bloom_down(FullscreenOut in [[stage_in]],
                              constant float4& P [[buffer(0)]],
                              texture2d<float> src [[texture(0)]]) {
    return float4(downsample13(src, in.uv, P.zw, false), 1.0);
}

// 3x3 tent upsample, blended additively onto the next larger mip.
fragment float4 fs_bloom_up(FullscreenOut in [[stage_in]],
                            constant float4& P [[buffer(0)]],   // x radius, y weight, zw source texel
                            texture2d<float> src [[texture(0)]]) {
    float2 ts = P.zw * P.x;
    float2 uv = in.uv;
    float3 s = src.sample(sLinearClamp, uv).rgb * 4.0;
    s += src.sample(sLinearClamp, uv + ts * float2(-1.0, 0.0)).rgb * 2.0;
    s += src.sample(sLinearClamp, uv + ts * float2(1.0, 0.0)).rgb * 2.0;
    s += src.sample(sLinearClamp, uv + ts * float2(0.0, -1.0)).rgb * 2.0;
    s += src.sample(sLinearClamp, uv + ts * float2(0.0, 1.0)).rgb * 2.0;
    s += src.sample(sLinearClamp, uv + ts * float2(-1.0, -1.0)).rgb;
    s += src.sample(sLinearClamp, uv + ts * float2(1.0, -1.0)).rgb;
    s += src.sample(sLinearClamp, uv + ts * float2(-1.0, 1.0)).rgb;
    s += src.sample(sLinearClamp, uv + ts * float2(1.0, 1.0)).rgb;
    return float4(s * (P.y / 16.0), 1.0);
}

// ---------------------------------------------------------------- Depth of field

fragment float4 fs_dof(FullscreenOut in [[stage_in]],
                       constant FrameUniforms& U [[buffer(0)]],
                       constant float4& P [[buffer(1)]],   // x focus distance, y range, z strength, w max radius (px)
                       texture2d<float> color [[texture(0)]],
                       texture2d<float> linearDepth [[texture(1)]]) {
    float2 uv = in.uv;
    float d0 = linearDepth.sample(sPointClamp, uv).r;
    float coc0 = saturate((abs(d0 - P.x) - P.y * 0.5) / max(P.y, 0.01)) * P.z;
    float3 c0 = color.sample(sPointClamp, uv).rgb;
    if (coc0 < 0.02) return float4(c0, 1.0);
    float radius = coc0 * P.w;
    float3 acc = c0;
    float wsum = 1.0;
    const int taps = 28;
    float golden = 2.39996323;
    float rot = ign(in.position.xy, U.flags.w) * 6.2831853;
    for (int i = 1; i < taps; i++) {
        float r = sqrt(float(i) / float(taps)) * radius;
        float a = float(i) * golden + rot;
        float2 o = float2(cos(a), sin(a)) * r * U.screen.zw;
        float2 suv = uv + o;
        float sd = linearDepth.sample(sPointClamp, suv).r;
        float scoc = saturate((abs(sd - P.x) - P.y * 0.5) / max(P.y, 0.01)) * P.z * P.w;
        // A sample contributes if its own blur reaches this pixel (foreground bleeds over focus).
        float w = saturate(scoc - r + 1.0);
        if (sd > d0 + 0.5) w *= saturate(coc0 * P.w - r + 1.0);
        acc += color.sample(sLinearClamp, suv).rgb * w;
        wsum += w;
    }
    return float4(acc / wsum, 1.0);
}

// ---------------------------------------------------------------- Motion blur

fragment float4 fs_motion_blur(FullscreenOut in [[stage_in]],
                               constant FrameUniforms& U [[buffer(0)]],
                               constant float4& P [[buffer(1)]],   // x strength, y camera share, z max length (px)
                               texture2d<float> color [[texture(0)]],
                               texture2d<float> velocity [[texture(1)]],
                               texture2d<float> objVelocity [[texture(2)]],
                               texture2d<float> linearDepth [[texture(3)]]) {
    float2 uv = in.uv;
    float3 c0 = color.sample(sPointClamp, uv).rgb;
    float2 v = velocity.sample(sPointClamp, uv).xy;
    float2 ov = objVelocity.sample(sPointClamp, uv).xy;
    // Object motion blurs fully; camera motion only slightly (readability in combat).
    float2 blur = (ov + (v - ov) * P.y) * P.x;
    float2 px = blur * U.screen.xy;
    float len = length(px);
    if (len < 0.75) return float4(c0, 1.0);
    if (len > P.z) blur *= P.z / len;
    float d0 = linearDepth.sample(sPointClamp, uv).r;
    float jitter = ign(in.position.xy, U.flags.w) - 0.5;
    float3 acc = c0;
    float wsum = 1.0;
    const int samples = 10;
    for (int i = 0; i < samples; i++) {
        float t = (float(i) + jitter) / float(samples - 1) - 0.5;
        float2 suv = uv + blur * t;
        float sd = linearDepth.sample(sPointClamp, suv).r;
        // Background samples do not smear over a sharp foreground.
        float w = sd < d0 - 0.3 ? 1.0 : (length(objVelocity.sample(sPointClamp, suv).xy) > length(ov) * 0.5 ? 1.0 : 0.6);
        acc += color.sample(sLinearClamp, suv).rgb * w;
        wsum += w;
    }
    return float4(acc / wsum, 1.0);
}

// ---------------------------------------------------------------- Composite

fragment float4 fs_composite(FullscreenOut in [[stage_in]],
                             constant PostGPU& P [[buffer(0)]],
                             texture2d<float> hdr [[texture(0)]],
                             texture2d<float> bloom [[texture(1)]]) {
    float2 uv = in.uv;
    float2 center = P.radial.xy;
    float2 fromC = uv - float2(0.5);
    float3 col;

    // Chromatic aberration (radial channel offsets).
    float ca = P.highlights.w;
    if (ca > 0.001) {
        float2 off = fromC * ca * 0.012 * length(fromC) * 2.0;
        col.r = hdr.sample(sLinearClamp, uv + off).r;
        col.g = hdr.sample(sLinearClamp, uv).g;
        col.b = hdr.sample(sLinearClamp, uv - off).b;
    } else {
        col = hdr.sample(sLinearClamp, uv).rgb;
    }

    // Contrast-adaptive sharpening (restores detail after TAA / upscaling).
    if (P.misc.y > 0.0) {
        float2 ts = float2(1.0 / float(hdr.get_width()), 1.0 / float(hdr.get_height()));
        float3 n = hdr.sample(sLinearClamp, uv + float2(0.0, -ts.y)).rgb;
        float3 s = hdr.sample(sLinearClamp, uv + float2(0.0, ts.y)).rgb;
        float3 e = hdr.sample(sLinearClamp, uv + float2(ts.x, 0.0)).rgb;
        float3 w = hdr.sample(sLinearClamp, uv + float2(-ts.x, 0.0)).rgb;
        float3 mn = min(col, min(min(n, s), min(e, w)));
        float3 mx = max(col, max(max(n, s), max(e, w)));
        float3 amp = saturate(min(mn, 2.0 - mx) / max(mx, float3(1e-4)));
        float3 k = sqrt(amp) * -0.125 * P.misc.y;
        col = max((col + (n + s + e + w) * k) / (1.0 + 4.0 * k), float3(0.0));
    }

    // Radial blur toward the impact point (heavy hits, deathblows).
    if (P.radial.z > 0.001) {
        float3 acc = col;
        float2 dir = center - uv;
        for (int i = 1; i < 10; i++) {
            float t = float(i) / 10.0 * P.radial.z * 0.18;
            acc += hdr.sample(sLinearClamp, uv + dir * t).rgb;
        }
        col = acc / 10.0;
    }

    col += bloom.sample(sLinearClamp, uv).rgb * P.radial.w * 0.12;
    col *= P.grade.x;
    col = acesFitted(col);

    // Grading.
    col = saturate(0.5 + (col - 0.5) * P.grade.y);
    float lum = luminance(col);
    float sat = P.grade.z * (1.0 - P.effects.x) * (1.0 - P.effects.y * 0.45);
    col = max(mix(float3(lum), col, sat), float3(0.0));
    col *= P.tint.rgb;
    float split = P.grade.w;
    col = col * mix(float3(1.0), P.highlights.rgb, split) + P.shadows.rgb * split * 0.3 * (1.0 - saturate(col));

    // Slow motion: cool, slightly desaturated.
    if (P.effects.z > 0.0) {
        float l = luminance(col);
        col = mix(col, float3(l) * float3(0.82, 0.95, 1.15), P.effects.z * 0.4);
    }

    float2 aspect = float2(P.misc.z / max(P.misc.w, 1.0), 1.0);
    float r = length(fromC * aspect) * 1.25;
    // Low health: pulsing red edges.
    if (P.effects.y > 0.0) {
        float pulse = 0.65 + 0.35 * sin(P.misc.x * 5.5);
        float edge = smoothstep(0.35, 1.05, r) * P.effects.y * pulse;
        col = mix(col, float3(0.45, 0.0, 0.02), edge * 0.7);
    }
    // Vignette.
    col *= 1.0 - P.tint.w * smoothstep(0.35, 1.15, r);
    // Screen flash.
    col = mix(col, P.flash.rgb, saturate(P.flash.a));
    // Film grain (luminance-weighted) + dither.
    float g = hash12(in.position.xy + fract(P.misc.x * 13.7) * 431.0) - 0.5;
    col += g * P.shadows.w * (1.0 - luminance(col) * 0.6);
    col += (hash12(in.position.xy * 1.37 + 17.0) - 0.5) / 255.0;
    // Letterbox bars (cinematics).
    float bar = P.effects.w * 0.11;
    if (uv.y < bar || uv.y > 1.0 - bar) col = float3(0.0);
    return float4(saturate(col), 1.0);
}
