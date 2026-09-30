// Temporal anti-aliasing resolve: closest-depth velocity dilation, Catmull-Rom history
// fetch, variance clipping in YCoCg and luminance-weighted blending.

inline float3 rgbToYCoCg(float3 c) {
    return float3(dot(c, float3(0.25, 0.5, 0.25)), dot(c, float3(0.5, 0.0, -0.5)), dot(c, float3(-0.25, 0.5, -0.25)));
}

inline float3 yCoCgToRgb(float3 c) {
    return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// Karis tonemap weights stabilize fireflies.
inline float3 tmap(float3 c) { return c / (1.0 + luminance(c)); }
inline float3 tmapInv(float3 c) { return c / max(1.0 - luminance(c), 1e-4); }

inline float3 sampleHistory(texture2d<float> tex, float2 uv, float2 texSize) {
    // 5-tap Catmull-Rom approximation (bilinear taps, corners dropped).
    float2 samplePos = uv * texSize;
    float2 tc1 = floor(samplePos - 0.5) + 0.5;
    float2 f = samplePos - tc1;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 tc0 = (tc1 - 1.0) / texSize;
    float2 tc3 = (tc1 + 2.0) / texSize;
    float2 tc12 = (tc1 + w2 / w12) / texSize;
    float3 r = float3(0.0);
    r += tex.sample(sLinearClamp, float2(tc12.x, tc0.y)).rgb * (w12.x * w0.y);
    r += tex.sample(sLinearClamp, float2(tc0.x, tc12.y)).rgb * (w0.x * w12.y);
    r += tex.sample(sLinearClamp, float2(tc12.x, tc12.y)).rgb * (w12.x * w12.y);
    r += tex.sample(sLinearClamp, float2(tc3.x, tc12.y)).rgb * (w3.x * w12.y);
    r += tex.sample(sLinearClamp, float2(tc12.x, tc3.y)).rgb * (w12.x * w3.y);
    float wsum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return max(r / max(wsum, 1e-4), float3(0.0));
}

inline float3 clipToAABB(float3 c, float3 mn, float3 mx, float3 center) {
    float3 extents = max((mx - mn) * 0.5, float3(1e-4));
    float3 v = c - center;
    float3 unit = abs(v / extents);
    float m = max(unit.x, max(unit.y, unit.z));
    return m > 1.0 ? center + v / m : c;
}

fragment float4 fs_taa(FullscreenOut in [[stage_in]],
                       constant FrameUniforms& U [[buffer(0)]],
                       constant float4& P [[buffer(1)]],          // x reset, y base blend, z motion blend, w unused
                       texture2d<float> current [[texture(0)]],
                       texture2d<float> history [[texture(1)]],
                       texture2d<float> velocity [[texture(2)]],
                       texture2d<float> linearDepth [[texture(3)]]) {
    float2 uv = in.uv;
    float2 texel = U.screen.zw;
    int2 pix = int2(in.position.xy);
    int2 maxPix = int2(int(U.screen.x) - 1, int(U.screen.y) - 1);

    float3 m1 = float3(0.0), m2 = float3(0.0);
    float3 cur = float3(0.0);
    float closest = 1e9;
    int2 closestOff = int2(0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            int2 p = clamp(pix + int2(x, y), int2(0), maxPix);
            float3 c = tmap(max(current.read(uint2(p)).rgb, float3(0.0)));
            float3 ycc = rgbToYCoCg(c);
            m1 += ycc;
            m2 += ycc * ycc;
            if (x == 0 && y == 0) cur = c;
            float d = linearDepth.read(uint2(p)).r;
            if (d < closest) { closest = d; closestOff = int2(x, y); }
        }
    }
    if (P.x > 0.5) return float4(tmapInv(cur), 1.0);

    float2 vel = velocity.read(uint2(clamp(pix + closestOff, int2(0), maxPix))).xy;
    float2 prevUV = uv + vel;
    if (any(prevUV < float2(0.0)) || any(prevUV > float2(1.0))) return float4(tmapInv(cur), 1.0);

    float2 hsize = float2(float(history.get_width()), float(history.get_height()));
    float3 hist = tmap(sampleHistory(history, prevUV, hsize));

    float3 mean = m1 / 9.0;
    float3 sigma = sqrt(max(m2 / 9.0 - mean * mean, float3(0.0)));
    float motionPx = length(vel / texel);
    float gamma = mix(1.25, 0.85, saturate(motionPx / 6.0));
    float3 mn = mean - sigma * gamma;
    float3 mx = mean + sigma * gamma;
    float3 histY = clipToAABB(rgbToYCoCg(hist), mn, mx, mean);
    hist = yCoCgToRgb(histY);

    float alpha = mix(P.y, P.z, saturate(motionPx / 8.0));
    float3 result = mix(hist, cur, alpha);
    result = tmapInv(result);
    if (any(isnan(result)) || any(isinf(result))) result = float3(0.0);
    return float4(result, 1.0);
}
