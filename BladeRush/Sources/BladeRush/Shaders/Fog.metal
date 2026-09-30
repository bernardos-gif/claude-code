// Height fog. With volumetrics on, a half-resolution ray march accumulates in-scattered sun
// light through the cascaded shadow map (light shafts); otherwise an analytic height fog is
// applied. Output: rgb in-scatter, a transmittance (blend: src one, dst source alpha).

inline float heightDensity(constant FrameUniforms& U, float y) {
    float h = max(U.fogParams.x, 0.1);
    return U.fogColor.w * exp(-max(y, 0.0) / h);
}

inline float phaseHG(float cosT, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * cosT, 1e-4), 1.5));
}

inline float shadowAt(constant FrameUniforms& U, depth2d_array<float> shadowMap, float3 P, float viewDepth) {
    if (U.flags.z < 0.5) return 1.0;
    uint cascade = 0;
    if (viewDepth > U.cascadeSplits.x) cascade = 1;
    if (viewDepth > U.cascadeSplits.y) cascade = 2;
    if (viewDepth > U.cascadeSplits.z) return 1.0;
    float4 sp = U.shadowViewProj[cascade] * float4(P, 1.0);
    float3 ndc = sp.xyz / sp.w;
    float2 uv = float2(ndc.x * 0.5 + 0.5, 1.0 - (ndc.y * 0.5 + 0.5));
    if (any(uv < float2(0.0)) || any(uv > float2(1.0))) return 1.0;
    return shadowMap.sample_compare(sShadow, uv, cascade, ndc.z - U.shadowInfo.y * 2.0);
}

inline float3 fogAmbient(constant FrameUniforms& U) {
    return U.fogColor.rgb * (0.35 + U.sunColor.w * 0.9) + float3(0.6, 0.7, 1.0) * U.fogParams.w * 0.6;
}

fragment float4 fs_volumetric(FullscreenOut in [[stage_in]],
                              constant FrameUniforms& U [[buffer(0)]],
                              texture2d<float> linearDepth [[texture(0)]],
                              depth2d_array<float> shadowMap [[texture(1)]]) {
    float2 uv = in.uv;
    float d = linearDepth.sample(sPointClamp, uv).r;
    bool sky = d >= 999.0;
    float3 vp = viewPosFromDepth(U, uv, sky ? 90.0 : d);
    float3 wp = (U.invView * float4(vp, 1.0)).xyz;
    float3 ro = U.cameraPos.xyz;
    float3 rd = wp - ro;
    float dist = min(length(rd), 90.0);
    rd = normalize(rd);
    float viewCos = max(-normalize(vp).z, 0.05);   // view depth per unit of ray length

    const int steps = 22;
    float stepLen = dist / float(steps);
    float jitter = ign(in.position.xy, U.flags.w);
    float3 sunDir = normalize(U.sunDir.xyz);
    float phase = phaseHG(dot(rd, sunDir), 0.55) * 4.0 * PI;
    float3 sunLight = U.sunColor.rgb * U.sunDir.w * U.fogParams.y;
    float3 ambient = fogAmbient(U);
    float3 scatter = float3(0.0);
    float trans = 1.0;
    for (int i = 0; i < steps; i++) {
        float t = (float(i) + jitter) * stepLen;
        float3 P = ro + rd * t;
        float dens = heightDensity(U, P.y);
        if (dens < 1e-5) continue;
        float vis = shadowAt(U, shadowMap, P, t * viewCos);
        float ext = 1.0 - exp(-dens * stepLen);
        float3 light = ambient + sunLight * vis * phase * 0.35;
        scatter += trans * ext * light;
        trans *= 1.0 - ext;
        if (trans < 0.01) break;
    }
    // Beyond the march distance, fall back to analytic fog so far geometry still hazes.
    if (length(wp - ro) > 90.0 || sky) {
        float extra = sky ? 0.35 : 1.0;
        float far = (sky ? 150.0 : length(wp - ro) - 90.0) * extra;
        float dens = heightDensity(U, ro.y + rd.y * 60.0);
        float ext = 1.0 - exp(-dens * far);
        scatter += trans * ext * ambient;
        trans *= 1.0 - ext;
    }
    return float4(scatter, trans);
}

fragment float4 fs_fog_apply(FullscreenOut in [[stage_in]],
                             constant FrameUniforms& U [[buffer(0)]],
                             texture2d<float> volumetric [[texture(0)]],
                             texture2d<float> linearDepth [[texture(1)]]) {
    float2 uv = in.uv;
    if (U.misc.w > 0.5) {
        // Depth-aware upsample: prefer the half-res sample whose depth matches.
        float d0 = linearDepth.sample(sPointClamp, uv).r;
        float2 hs = float2(1.0 / float(volumetric.get_width()), 1.0 / float(volumetric.get_height()));
        float4 best = volumetric.sample(sLinearClamp, uv);
        float bestW = 0.0;
        float4 acc = float4(0.0);
        for (int y = -1; y <= 1; y += 2) {
            for (int x = -1; x <= 1; x += 2) {
                float2 o = float2(x, y) * hs * 0.5;
                float4 v = volumetric.sample(sPointClamp, uv + o);
                float dd = linearDepth.sample(sPointClamp, uv + o * 2.0).r;
                float w = 1.0 / (abs(dd - d0) / max(d0, 0.1) * 30.0 + 0.05);
                acc += v * w;
                bestW += w;
            }
        }
        float4 v = bestW > 0.0 ? acc / bestW : best;
        return float4(v.rgb, saturate(v.a));
    }
    // Analytic exponential height fog.
    float d = linearDepth.sample(sPointClamp, uv).r;
    bool sky = d >= 999.0;
    float3 vp = viewPosFromDepth(U, uv, sky ? 150.0 : d);
    float3 wp = (U.invView * float4(vp, 1.0)).xyz;
    float3 ro = U.cameraPos.xyz;
    float3 rd = wp - ro;
    float dist = length(rd) * (sky ? 0.35 : 1.0);
    float h = max(U.fogParams.x, 0.1);
    float dy = rd.y / max(length(rd), 1e-3);
    // Integral of density exp(-y/h) along the ray.
    float k = U.fogColor.w * exp(-max(ro.y, 0.0) / h);
    float integral = abs(dy) > 1e-3 ? k * h * (1.0 - exp(-dist * dy / h)) / dy : k * dist;
    float trans = exp(-max(integral, 0.0));
    float3 sunDir = normalize(U.sunDir.xyz);
    float glare = pow(saturate(dot(normalize(rd), sunDir)), 8.0) * U.fogParams.y;
    float3 col = fogAmbient(U) + U.sunColor.rgb * U.sunDir.w * glare * 0.3;
    return float4(col * (1.0 - trans), trans);
}
