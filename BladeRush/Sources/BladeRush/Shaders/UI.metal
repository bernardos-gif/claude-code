// UI: signed-distance rounded rectangles (gradient fill, border, outer glow), ring arcs,
// diamonds and SDF text glyphs, all in one instanced draw. Also the debug line renderer.
// Premultiplied alpha output.

struct UIVSOut {
    float4 position [[position]];
    float2 local;                 // pixels relative to the rect origin
    float2 size [[flat]];
    float4 color [[flat]];
    float4 color2 [[flat]];
    float4 params [[flat]];
    float4 extra [[flat]];
    float2 uv01;
};

vertex UIVSOut vs_ui(const device UIQuad* quads [[buffer(0)]],
                     constant float4& V [[buffer(1)]],      // x width, y height (pixels)
                     uint vid [[vertex_id]], uint iid [[instance_id]]) {
    UIQuad q = quads[iid];
    float kind = q.params.w;
    float pad = kind > 2.5 ? 0.0 : (q.params.z > 0.0 ? q.params.z * 16.0 + 2.0 : 1.5);
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    float2 p = q.rect.xy - pad + corner * (q.rect.zw + 2.0 * pad);
    UIVSOut o;
    o.local = p - q.rect.xy;
    o.size = q.rect.zw;
    o.uv01 = kind > 2.5 ? corner : o.local / max(q.rect.zw, float2(1.0));
    o.color = q.color;
    o.color2 = q.color2;
    o.params = q.params;
    o.extra = q.extra;
    o.position = float4(p.x / V.x * 2.0 - 1.0, 1.0 - p.y / V.y * 2.0, 0.0, 1.0);
    return o;
}

inline float sdRoundBox(float2 p, float2 halfSize, float r) {
    float2 q = abs(p) - halfSize + r;
    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

inline float4 shade(float d, float4 fill, float border, float4 borderColor, float glow) {
    float inside = saturate(0.5 - d);
    float4 c = fill;
    if (border > 0.0) {
        float inner = saturate(0.5 - (d + border));
        float bm = saturate(inside - inner);
        c.rgb = mix(c.rgb, borderColor.rgb, bm * borderColor.a);
        c.a = max(c.a * inner, borderColor.a * bm) + c.a * bm * (1.0 - borderColor.a);
        c.a = max(c.a, fill.a * inner);
    }
    float a = c.a * inside;
    float3 rgb = c.rgb * a;
    if (glow > 0.0 && d > 0.0) {
        float g = exp(-d / (glow * 7.0 + 1.0)) * glow * 0.55 * fill.a;
        rgb += fill.rgb * g;
        a += g * 0.5;
    }
    return float4(rgb, saturate(a));
}

fragment float4 fs_ui(UIVSOut in [[stage_in]],
                      texture2d<float> atlas [[texture(0)]]) {
    int kind = int(in.params.w + 0.5);
    float4 fill = mix(in.color, in.color2, saturate(in.uv01.y));
    float2 halfSize = in.size * 0.5;
    float2 p = in.local - halfSize;
    if (kind == 0) {
        float r = min(in.params.x, min(halfSize.x, halfSize.y));
        float d = sdRoundBox(p, halfSize, r);
        return shade(d, fill, in.params.y, in.extra, in.params.z);
    }
    if (kind == 1) {
        // Ring arc: extra = (start, end, thickness); angle 0 = up, clockwise.
        float radius = in.params.x;
        float thick = max(in.extra.z, 1.0);
        float dist = length(p);
        float d = abs(dist - (radius - thick * 0.5)) - thick * 0.5;
        float ang = atan2(p.x, -p.y);
        if (ang < 0.0) ang += 6.2831853;
        float s = in.extra.x, e = in.extra.y;
        float inArc = (e - s >= 6.28318) ? 1.0 : ((ang >= s && ang <= e) ? 1.0 : 0.0);
        if (inArc < 0.5) {
            // Rounded caps: distance to the arc end points.
            float rr = radius - thick * 0.5;
            float2 ps = float2(sin(s), -cos(s)) * rr;
            float2 pe = float2(sin(e), -cos(e)) * rr;
            d = min(length(p - ps), length(p - pe)) - thick * 0.5;
        }
        return shade(d, fill, 0.0, float4(0.0), in.params.z);
    }
    if (kind == 2) {
        float d = (abs(p.x) + abs(p.y) - halfSize.x) * 0.7071;
        return shade(d, fill, in.params.y, in.extra, in.params.z);
    }
    if (kind == 3) {
        // SDF glyph: extra = atlas uv rect (u0, v0, u1, v1); params.x = softness boost.
        float2 uv = mix(in.extra.xy, in.extra.zw, in.uv01);
        float s = atlas.sample(sLinearClamp, uv).r;
        float w = max(fwidth(s) * 0.75, 1e-3);
        float a = smoothstep(0.5 - w, 0.5 + w, s) * in.color.a;
        if (in.params.z > 0.0) {
            float g = smoothstep(0.15, 0.5, s) * in.params.z * 0.6 * in.color.a;
            return float4(in.color.rgb * max(a, g * 0.7), max(a, g * 0.5));
        }
        return float4(in.color.rgb * a, a);
    }
    return float4(fill.rgb * fill.a, fill.a);
}

// ---------------------------------------------------------------- Debug lines

struct LineOut {
    float4 position [[position]];
    float4 color;
};

vertex LineOut vs_line(const device float4* verts [[buffer(0)]],     // pairs of (position, color)
                       constant FrameUniforms& U [[buffer(1)]],
                       uint vid [[vertex_id]]) {
    LineOut o;
    float4 p = verts[vid * 2];
    o.position = U.viewProjNoJitter * float4(p.xyz, 1.0);
    o.color = verts[vid * 2 + 1];
    return o;
}

fragment float4 fs_line(LineOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}
