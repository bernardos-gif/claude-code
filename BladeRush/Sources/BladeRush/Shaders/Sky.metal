// Procedural sky: the background pass (drawn where the depth buffer is still at the far
// plane) and the compute kernel that bakes the sky into a cubemap for specular IBL.

struct SkyVSOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle placed exactly on the far plane (depth 1) so the depth test
// (less-equal) only lets it through where no geometry was drawn.
vertex SkyVSOut vs_sky(uint vid [[vertex_id]]) {
    FullscreenOut f = fullscreenVertex(vid);
    SkyVSOut o;
    o.position = float4(f.position.xy, 1.0, 1.0);
    o.uv = f.uv;
    return o;
}

struct SkyFragOut {
    float4 color [[color(0)]];
    float2 velocity [[color(1)]];
};

inline float3 skyViewDir(constant FrameUniforms& U, float2 uv) {
    float2 ndc = float2(uv.x * 2.0 - 1.0, (1.0 - uv.y) * 2.0 - 1.0);
    float4 w = U.invViewProj * float4(ndc, 1.0, 1.0);
    return normalize(w.xyz / w.w - U.cameraPos.xyz);
}

fragment SkyFragOut fs_sky(SkyVSOut in [[stage_in]],
                           constant FrameUniforms& U [[buffer(0)]],
                           texture2d<float> noiseTex [[texture(0)]]) {
    float3 d = skyViewDir(U, in.uv);
    float3 c = skyColor(U.sky, d, normalize(U.sunDir.xyz), U.sunDir.w, noiseTex, true);
    // Subtle dithering against banding in dark gradients.
    c += (hash12(in.position.xy + fract(U.cameraPos.w) * 61.0) - 0.5) * 0.004;
    SkyFragOut o;
    o.color = float4(max(c, float3(0.0)), 1.0);
    // Sky is at infinity: reproject the direction (w = 0 ignores camera translation).
    float4 cur = U.viewProjNoJitter * float4(d, 0.0);
    float4 prev = U.prevViewProjNoJitter * float4(d, 0.0);
    float2 cuv = float2(cur.x / cur.w * 0.5 + 0.5, 1.0 - (cur.y / cur.w * 0.5 + 0.5));
    float2 puv = float2(prev.x / prev.w * 0.5 + 0.5, 1.0 - (prev.y / prev.w * 0.5 + 0.5));
    o.velocity = (prev.w > 1e-4 && cur.w > 1e-4) ? (puv - cuv) : float2(0.0);
    return o;
}

// Cube face direction for texel (u, v) in [-1, 1], Metal/D3D face order +X -X +Y -Y +Z -Z.
inline float3 cubeDir(uint face, float2 uv) {
    float u = uv.x, v = uv.y;
    float3 d;
    switch (face) {
        case 0: d = float3(1.0, -v, -u); break;
        case 1: d = float3(-1.0, -v, u); break;
        case 2: d = float3(u, 1.0, v); break;
        case 3: d = float3(u, -1.0, -v); break;
        case 4: d = float3(u, -v, 1.0); break;
        default: d = float3(-u, -v, -1.0); break;
    }
    return normalize(d);
}

kernel void sky_cube(texturecube<float, access::write> outCube [[texture(0)]],
                     texture2d<float> noiseTex [[texture(1)]],
                     constant FrameUniforms& U [[buffer(0)]],
                     uint3 gid [[thread_position_in_grid]]) {
    uint size = outCube.get_width();
    if (gid.x >= size || gid.y >= size || gid.z >= 6) return;
    float2 uv = (float2(gid.xy) + 0.5) / float(size) * 2.0 - 1.0;
    float3 d = cubeDir(gid.z, uv);
    float3 c = skyColor(U.sky, d, normalize(U.sunDir.xyz), U.sunDir.w, noiseTex, false);
    // Clamp extreme values so the box-filtered mips stay stable.
    c = min(c, float3(24.0));
    outCube.write(float4(c, 1.0), gid.xy, gid.z);
}
