// Screen-space reflections for wet floors, polished stone and armor. Rays are marched in
// view space against the prepass linear depth; hits fetch last frame's (TAA-resolved) HDR
// color, reprojected with the motion vectors. Additive over the lit image.

fragment float4 fs_ssr(FullscreenOut in [[stage_in]],
                       constant FrameUniforms& U [[buffer(0)]],
                       texture2d<float> normalRough [[texture(0)]],
                       texture2d<float> linearDepth [[texture(1)]],
                       texture2d<float> history [[texture(2)]],
                       texture2d<float> velocity [[texture(3)]]) {
    float2 uv = in.uv;
    float4 nr = normalRough.sample(sPointClamp, uv);
    float mask;
    if (nr.w < 0.0) {
        mask = saturate(-nr.w - 1.0);       // floor: explicit SSR strength from the prepass
    } else {
        mask = saturate(0.35 - nr.w) * 1.4;  // smooth metal / stone
    }
    if (mask < 0.01) return float4(0.0);
    float d = linearDepth.sample(sPointClamp, uv).r;
    if (d >= 999.0) return float4(0.0);

    float3 P = viewPosFromDepth(U, uv, d);
    float3 N = normalize(nr.xyz);
    float3 V = normalize(P);
    float3 R = normalize(reflect(V, N));
    float NoV = saturate(dot(N, -V));
    if (R.z > 0.6) return float4(0.0);        // pointing back at the camera: nothing on screen

    float jitter = ign(in.position.xy, U.flags.w);
    float t = 0.08 + jitter * 0.12;
    float stepLen = 0.12;
    float prevT = 0.0;
    bool hit = false;
    float2 hitUV = float2(0.0);
    for (int i = 0; i < 32; i++) {
        float3 q = P + R * t;
        if (q.z > -0.05) break;
        float2 quv = viewToUV(U, q);
        if (any(quv < float2(0.0)) || any(quv > float2(1.0))) break;
        float sd = linearDepth.sample(sPointClamp, quv).r;
        float diff = -q.z - sd;
        float thickness = 0.25 + t * 0.06;
        if (diff > 0.0 && diff < thickness) {
            // Binary refinement between the last two samples.
            float a = prevT, b = t;
            for (int k = 0; k < 5; k++) {
                float m = (a + b) * 0.5;
                float3 qm = P + R * m;
                float2 muv = viewToUV(U, qm);
                float md = linearDepth.sample(sPointClamp, muv).r;
                if (-qm.z - md > 0.0) b = m; else a = m;
            }
            hitUV = viewToUV(U, P + R * b);
            hit = true;
            break;
        }
        prevT = t;
        t += stepLen;
        stepLen *= 1.16;
    }
    if (!hit) return float4(0.0);
    float2 vel = velocity.sample(sPointClamp, hitUV).xy;
    float2 prevUV = hitUV + vel;
    if (any(prevUV < float2(0.0)) || any(prevUV > float2(1.0))) return float4(0.0);
    float3 c = min(history.sample(sLinearClamp, prevUV).rgb, float3(16.0));
    float2 edge = min(prevUV, 1.0 - prevUV);
    float edgeFade = saturate(min(edge.x, edge.y) * 10.0);
    float distFade = 1.0 - saturate(t / 30.0);
    float fresnel = 0.04 + 0.96 * pow(1.0 - NoV, 5.0);
    float w = mask * mix(fresnel, 0.6, nr.w < 0.0 ? 0.25 : 0.55) * edgeFade * distFade * U.misc.z;
    return float4(c * w, 0.0);
}
