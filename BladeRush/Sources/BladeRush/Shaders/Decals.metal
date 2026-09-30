// Ground decals (cracks, scorch marks, blood, frost, glowing glyphs, slash gashes). Each
// decal is a box volume; the fragment reconstructs the floor position from the prepass depth
// and only draws on arena floor pixels. Premultiplied output: rgb emissive/lit color,
// alpha darkens what is underneath.

struct DecalOut {
    float4 position [[position]];
    uint idx [[flat]];
};

constant float3 kCube[8] = {
    float3(-1, -1, -1), float3(1, -1, -1), float3(1, 1, -1), float3(-1, 1, -1),
    float3(-1, -1, 1), float3(1, -1, 1), float3(1, 1, 1), float3(-1, 1, 1)
};
constant ushort kCubeIdx[36] = {
    0, 2, 1, 0, 3, 2,  4, 5, 6, 4, 6, 7,  0, 1, 5, 0, 5, 4,
    3, 6, 2, 3, 7, 6,  0, 4, 7, 0, 7, 3,  1, 2, 6, 1, 6, 5
};

vertex DecalOut vs_decal(const device Decal* decals [[buffer(0)]],
                         constant FrameUniforms& U [[buffer(1)]],
                         uint vid [[vertex_id]], uint iid [[instance_id]]) {
    Decal d = decals[iid];
    float3 c = kCube[kCubeIdx[vid]];
    float r = d.centerRadius.w;
    float ang = d.params.x;
    float cs = cos(ang), sn = sin(ang);
    float3 local = float3(c.x * r, c.y * max(r * 0.35, 0.4), c.z * r);
    float3 world = d.centerRadius.xyz + float3(local.x * cs - local.z * sn, local.y, local.x * sn + local.z * cs);
    DecalOut o;
    o.position = U.viewProj * float4(world, 1.0);
    o.idx = iid;
    return o;
}

inline float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash12(i), b = hash12(i + float2(1.0, 0.0)), c = hash12(i + float2(0.0, 1.0)), d = hash12(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fragment float4 fs_decal(DecalOut in [[stage_in]],
                         constant FrameUniforms& U [[buffer(0)]],
                         const device Decal* decals [[buffer(1)]],
                         texture2d<float> normalRough [[texture(0)]],
                         texture2d<float> linearDepth [[texture(1)]]) {
    uint2 pix = uint2(in.position.xy);
    float4 nr = normalRough.read(pix);
    if (nr.w >= 0.0) discard_fragment();            // floor pixels only
    float d = linearDepth.read(pix).r;
    if (d >= 999.0) discard_fragment();
    float2 uv = in.position.xy * U.screen.zw;
    float3 vp = viewPosFromDepth(U, uv, d);
    float3 wp = (U.invView * float4(vp, 1.0)).xyz;
    Decal dc = decals[in.idx];
    float3 rel = wp - dc.centerRadius.xyz;
    float r = dc.centerRadius.w;
    float cs = cos(dc.params.x), sn = sin(dc.params.x);
    float2 p = float2(rel.x * cs + rel.z * sn, -rel.x * sn + rel.z * cs) / r;   // [-1, 1] inside
    if (abs(rel.y) > max(r * 0.35, 0.4) || abs(p.x) > 1.0 || abs(p.y) > 1.0) discard_fragment();
    float dist = length(p);
    float age = dc.params.y;                 // 0 new .. 1 expired
    float kind = dc.params.z;
    float seed = dc.params.w;
    float fade = (1.0 - smoothstep(0.7, 1.0, age)) * dc.color.a;
    float3 up = float3(0.0, 1.0, 0.0);
    float3 lit = evalSH(U, up) + U.sunColor.rgb * U.sunDir.w * saturate(U.sunDir.y) * 0.35;
    float3 rgb = float3(0.0);
    float a = 0.0;
    if (kind < 0.5) {
        // Radial cracks: dark fissures with a cooling glow.
        float ang = atan2(p.y, p.x);
        float rays = abs(sin(ang * 7.0 + seed * 13.0 + valueNoise(p * 6.0) * 2.5));
        float crack = (1.0 - smoothstep(0.0, 0.12 + dist * 0.1, rays)) * (1.0 - smoothstep(0.6, 1.0, dist));
        float center = 1.0 - smoothstep(0.0, 0.35, dist);
        a = saturate(crack * 0.9 + center * 0.5) * fade;
        rgb = dc.color.rgb * crack * (1.0 - age) * 1.5 * fade;
    } else if (kind < 1.5) {
        // Scorch.
        float n = valueNoise(p * 4.0 + seed * 9.0);
        a = saturate((1.0 - smoothstep(0.2, 1.0, dist + n * 0.3)) * 0.85) * fade;
        float ember = step(0.8, valueNoise(p * 14.0 + seed)) * (1.0 - age);
        rgb = float3(1.0, 0.35, 0.08) * ember * a * 2.0;
    } else if (kind < 2.5) {
        // Blood splatter.
        float n = valueNoise(p * 5.0 + seed * 7.0) * 0.5 + valueNoise(p * 11.0 + seed) * 0.3;
        float blob = 1.0 - smoothstep(0.35, 0.55, dist + (n - 0.4) * 0.8);
        a = blob * 0.85 * fade;
        rgb = float3(0.18, 0.01, 0.01) * lit * a;
    } else if (kind < 3.5) {
        // Frost patch.
        float n = valueNoise(p * 8.0 + seed * 5.0);
        float patch = 1.0 - smoothstep(0.5, 1.0, dist + n * 0.25);
        float sparkle = step(0.97, hash12(floor(wp.xz * 40.0)));
        a = patch * 0.75 * fade;
        rgb = (float3(0.75, 0.88, 1.0) * lit + dc.color.rgb * sparkle * 2.0) * a;
    } else if (kind < 4.5) {
        // Glowing glyph circle (boss sigils, hazards).
        float ring1 = 1.0 - smoothstep(0.0, 0.03, abs(dist - 0.9));
        float ring2 = 1.0 - smoothstep(0.0, 0.02, abs(dist - 0.7));
        float ang = atan2(p.y, p.x);
        float ticks = step(0.8, fract(ang / 6.2831853 * 24.0)) * step(0.72, dist) * step(dist, 0.88);
        float star = 1.0 - smoothstep(0.0, 0.025, abs(sin(ang * 2.5 + seed) * dist - 0.0));
        star *= step(dist, 0.7);
        float glow = saturate(ring1 + ring2 + ticks + star * 0.6);
        float pulse = 0.7 + 0.3 * sin(U.cameraPos.w * 4.0 + seed * 6.0);
        a = glow * 0.35 * fade;
        rgb = dc.color.rgb * glow * pulse * 2.5 * fade;
    } else {
        // Slash gash: a long thin cut along the decal's x axis.
        float along = 1.0 - smoothstep(0.7, 1.0, abs(p.x));
        float width = 0.07 * (1.0 - p.x * p.x) + 0.01;
        float cut = (1.0 - smoothstep(width * 0.5, width, abs(p.y + sin(p.x * 3.0 + seed) * 0.05))) * along;
        a = cut * 0.9 * fade;
        rgb = dc.color.rgb * cut * (1.0 - age) * 2.0 * fade;
    }
    if (a < 0.002 && luminance(rgb) < 0.002) discard_fragment();
    return float4(rgb, saturate(a));
}
