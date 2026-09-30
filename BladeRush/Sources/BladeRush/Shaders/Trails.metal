// Weapon trail ribbons (additive, HDR). Vertices come from TrailBuilder: the inner edge has
// alpha 0 and the blade tip carries the fade, so the ribbon glows along the cutting edge.

struct TrailOut {
    float4 position [[position]];
    float4 color;
    float u;
};

vertex TrailOut vs_trail(const device TrailVertex* verts [[buffer(0)]],
                         constant FrameUniforms& U [[buffer(1)]],
                         uint vid [[vertex_id]]) {
    TrailVertex v = verts[vid];
    TrailOut o;
    o.position = U.viewProj * float4(v.position.xyz, 1.0);
    o.color = v.color;
    o.u = v.position.w;
    return o;
}

fragment float4 fs_trail(TrailOut in [[stage_in]],
                         constant FrameUniforms& U [[buffer(0)]]) {
    float a = saturate(in.color.a);
    // Bright cutting edge, soft body, fine streaks along the swing.
    float edge = pow(a, 3.0) * 2.2 + a * 0.35;
    float streak = 0.75 + 0.25 * hash12(float2(floor(in.u * 48.0), floor(U.cameraPos.w * 30.0)));
    float3 c = in.color.rgb * edge * streak * (1.0 - in.u * 0.5);
    return float4(c, 0.0);
}
