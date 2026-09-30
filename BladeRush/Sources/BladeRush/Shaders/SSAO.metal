// Screen-space ambient occlusion (half resolution) with a depth-aware separable blur.

fragment float fs_ssao(FullscreenOut in [[stage_in]],
                       constant FrameUniforms& U [[buffer(0)]],
                       texture2d<float> normalRough [[texture(0)]],
                       texture2d<float> linearDepth [[texture(1)]]) {
    float2 uv = in.uv;
    float d = linearDepth.sample(sPointClamp, uv).r;
    if (d >= 999.0) return 1.0;
    float3 P = viewPosFromDepth(U, uv, d);
    float3 N = normalize(normalRough.sample(sPointClamp, uv).xyz);
    float3 up = abs(N.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
    float3 T = normalize(cross(up, N));
    float3 B = cross(N, T);

    const float radius = 0.55;
    const int samples = 12;
    float noise = ign(in.position.xy, U.flags.w);
    float occlusion = 0.0;
    for (int i = 0; i < samples; i++) {
        float fi = float(i);
        float r2 = (fi + 0.5) / float(samples);
        float phi = (fract(fi * 0.618034 + noise)) * 2.0 * PI;
        float sinT = sqrt(r2);
        float cosT = sqrt(1.0 - r2);
        float3 dir = T * (cos(phi) * sinT) + B * (sin(phi) * sinT) + N * cosT;
        float scale = mix(0.12, 1.0, r2 * r2);
        float3 S = P + dir * radius * scale;
        float2 suv = viewToUV(U, S);
        if (any(suv < float2(0.0)) || any(suv > float2(1.0))) continue;
        float sceneD = linearDepth.sample(sPointClamp, suv).r;
        float sampleD = -S.z;
        float range = smoothstep(0.0, 1.0, radius / max(abs(d - sceneD), 1e-3));
        occlusion += (sceneD < sampleD - 0.025 ? 1.0 : 0.0) * range;
    }
    float ao = 1.0 - occlusion / float(samples);
    // Fade out with distance (small radius is meaningless far away).
    ao = mix(ao, 1.0, saturate((d - 40.0) / 30.0));
    return pow(saturate(ao), 1.6);
}

fragment float fs_ssao_blur(FullscreenOut in [[stage_in]],
                            constant FrameUniforms& U [[buffer(0)]],
                            constant float4& P [[buffer(1)]],      // xy texel step (direction), z depth sharpness
                            texture2d<float> aoTex [[texture(0)]],
                            texture2d<float> linearDepth [[texture(1)]]) {
    float2 uv = in.uv;
    float d0 = linearDepth.sample(sPointClamp, uv).r;
    float sum = 0.0, wsum = 0.0;
    for (int i = -3; i <= 3; i++) {
        float2 o = P.xy * float(i);
        float a = aoTex.sample(sLinearClamp, uv + o).r;
        float d = linearDepth.sample(sPointClamp, uv + o).r;
        float w = exp(-float(i * i) / 8.0) * exp(-abs(d - d0) * P.z / max(d0, 0.1));
        sum += a * w;
        wsum += w;
    }
    return sum / max(wsum, 1e-4);
}
