// Mesh rendering: shadow cascades, depth/normal/velocity prepass, main PBR forward+
// pass with procedural triplanar materials, and additive "ghost" afterimages.

struct VSOut {
    float4 position [[position, invariant]];
    float3 worldPos;
    float3 normal;
    float4 color;          // rgb tint, a baked AO
    float4 attr;           // y edge wear, z emissive mask, w detail
    float4 curClip;        // unjittered
    float4 prevClip;       // unjittered, previous camera + previous object
    float4 prevObjClip;    // unjittered, current camera + previous object
    float viewDepth;
    uint matSlot [[flat]];
    uint inst [[flat]];
};

struct SkinResult { float3 pos; float3 prevPos; float3 normal; };

inline SkinResult skinVertex(const device Vertex& v, const device float4x4* palette, const device float4x4* prevPalette) {
    float3 p = float3(v.position);
    float3 n = float3(v.normal);
    float4 w = float4(v.weights) / 255.0;
    uint4 b = uint4(v.bones);
    float4 sp = float4(0.0), pp = float4(0.0);
    float3 sn = float3(0.0);
    for (int i = 0; i < 4; i++) {
        float wi = w[i];
        if (wi <= 0.0) continue;
        float4x4 m = palette[b[i]];
        float4x4 pm = prevPalette[b[i]];
        sp += (m * float4(p, 1.0)) * wi;
        pp += (pm * float4(p, 1.0)) * wi;
        sn += (m * float4(n, 0.0)).xyz * wi;
    }
    SkinResult r;
    r.pos = sp.xyz;
    r.prevPos = pp.xyz;
    r.normal = sn;
    return r;
}

inline VSOut finishVertex(float3 localPos, float3 prevLocalPos, float3 localNormal, const device Vertex& v,
                          const device InstanceData& I, constant FrameUniforms& U, uint iid) {
    VSOut o;
    float4 wp = I.model * float4(localPos, 1.0);
    float4 pwp = I.prevModel * float4(prevLocalPos, 1.0);
    o.worldPos = wp.xyz;
    o.normal = normalize((I.model * float4(localNormal, 0.0)).xyz);
    o.position = U.viewProj * wp;
    o.curClip = U.viewProjNoJitter * wp;
    o.prevClip = U.prevViewProjNoJitter * pwp;
    o.prevObjClip = U.viewProjNoJitter * pwp;
    o.color = float4(v.color) / 255.0;
    o.attr = float4(v.attr) / 255.0;
    o.matSlot = min(uint(v.attr.x), 7u);
    o.inst = iid;
    o.viewDepth = -(U.view * wp).z;
    return o;
}

vertex VSOut vs_static(const device Vertex* verts [[buffer(0)]],
                       const device InstanceData* inst [[buffer(1)]],
                       constant FrameUniforms& U [[buffer(2)]],
                       uint vid [[vertex_id]], uint iid [[instance_id]]) {
    const device Vertex& v = verts[vid];
    float3 p = float3(v.position);
    return finishVertex(p, p, float3(v.normal), v, inst[iid], U, iid);
}

vertex VSOut vs_skinned(const device Vertex* verts [[buffer(0)]],
                        const device InstanceData* inst [[buffer(1)]],
                        constant FrameUniforms& U [[buffer(2)]],
                        const device float4x4* palette [[buffer(3)]],
                        const device float4x4* prevPalette [[buffer(4)]],
                        uint vid [[vertex_id]], uint iid [[instance_id]]) {
    const device Vertex& v = verts[vid];
    SkinResult s = skinVertex(v, palette, prevPalette);
    return finishVertex(s.pos, s.prevPos, s.normal, v, inst[iid], U, iid);
}

// ---------------------------------------------------------------- Shadows

struct ShadowOut { float4 position [[position, invariant]]; };

vertex ShadowOut vs_shadow_static(const device Vertex* verts [[buffer(0)]],
                                  const device InstanceData* inst [[buffer(1)]],
                                  constant FrameUniforms& U [[buffer(2)]],
                                  constant uint& cascade [[buffer(5)]],
                                  uint vid [[vertex_id]], uint iid [[instance_id]]) {
    ShadowOut o;
    float4 wp = inst[iid].model * float4(float3(verts[vid].position), 1.0);
    o.position = U.shadowViewProj[cascade] * wp;
    return o;
}

vertex ShadowOut vs_shadow_skinned(const device Vertex* verts [[buffer(0)]],
                                   const device InstanceData* inst [[buffer(1)]],
                                   constant FrameUniforms& U [[buffer(2)]],
                                   const device float4x4* palette [[buffer(3)]],
                                   const device float4x4* prevPalette [[buffer(4)]],
                                   constant uint& cascade [[buffer(5)]],
                                   uint vid [[vertex_id]], uint iid [[instance_id]]) {
    ShadowOut o;
    SkinResult s = skinVertex(verts[vid], palette, prevPalette);
    float4 wp = inst[iid].model * float4(s.pos, 1.0);
    o.position = U.shadowViewProj[cascade] * wp;
    return o;
}

// ---------------------------------------------------------------- Materials

struct Surface {
    float3 albedo;
    float metallic;
    float roughness;
    float3 normal;
    float3 emissive;
    float ao;
    float sheen;
    float wrap;       // diffuse wrap for skin / cloth
    float ssrMask;
};

struct Tri { float3 w; float2 uvX; float2 uvY; float2 uvZ; };

inline Tri makeTri(float3 p, float3 n, float scale) {
    Tri t;
    float3 b = pow(abs(n), float3(4.0));
    t.w = b / (b.x + b.y + b.z + 1e-5);
    t.uvX = p.zy * scale;
    t.uvY = p.xz * scale;
    t.uvZ = p.xy * scale;
    return t;
}

inline float4 triSample(texture2d<float> tex, Tri t) {
    return tex.sample(sLinearRepeat, t.uvX) * t.w.x + tex.sample(sLinearRepeat, t.uvY) * t.w.y + tex.sample(sLinearRepeat, t.uvZ) * t.w.z;
}

// Whiteout-blended triplanar normal mapping (Ben Golus).
inline float3 triNormal(texture2d<float> ntex, Tri t, float3 n, float strength, bool fine) {
    float4 sx = ntex.sample(sLinearRepeat, t.uvX);
    float4 sy = ntex.sample(sLinearRepeat, t.uvY);
    float4 sz = ntex.sample(sLinearRepeat, t.uvZ);
    float2 tx = (fine ? sx.zw : sx.xy) * 2.0 - 1.0;
    float2 ty = (fine ? sy.zw : sy.xy) * 2.0 - 1.0;
    float2 tz = (fine ? sz.zw : sz.xy) * 2.0 - 1.0;
    tx *= strength; ty *= strength; tz *= strength;
    float3 nx = float3(tx + n.zy, n.x);
    float3 ny = float3(ty + n.xz, n.y);
    float3 nz = float3(tz + n.xy, n.z);
    return normalize(nx.zyx * t.w.x + ny.xzy * t.w.y + nz.xyz * t.w.z);
}

inline Surface evalMaterial(constant FrameUniforms& U, MaterialGPU M, float3 P, float3 N, float4 vcolor, float4 attr,
                            bool isFloor, texture2d<float> detailA, texture2d<float> detailN) {
    Surface s;
    int kind = int(M.kindWearDirtRust.x + 0.5);
    float wear = M.kindWearDirtRust.y, dirt = M.kindWearDirtRust.z, rust = M.kindWearDirtRust.w;
    float frost = M.frostScaleRunesSheen.x, scale = max(0.05, M.frostScaleRunesSheen.y), runes = M.frostScaleRunesSheen.z;
    float sheen = M.frostScaleRunesSheen.w;
    float3 base = M.baseMetal.rgb * vcolor.rgb;
    float bakedAO = vcolor.a;
    float edge = attr.y;
    float emissiveMask = attr.z;
    float detailSeed = attr.w;

    Tri t = makeTri(P, N, 1.6 * scale);
    float4 a = triSample(detailA, t);
    Tri tBig = makeTri(P, N, 0.35 * scale);
    float4 aBig = triSample(detailA, tBig);

    s.albedo = base;
    s.metallic = M.baseMetal.a;
    s.roughness = M.emissiveRough.a;
    s.normal = N;
    s.emissive = M.emissiveRough.rgb * (0.4 + 0.6 * max(emissiveMask, M.emissiveRough.r + M.emissiveRough.g + M.emissiveRough.b > 0.0 ? 1.0 : 0.0));
    s.ao = bakedAO;
    s.sheen = sheen;
    s.wrap = 0.0;
    s.ssrMask = 0.0;

    // Common grime in cavities.
    float cavity = 1.0 - bakedAO;
    float grime = saturate(cavity * 1.6 * dirt + (aBig.r - 0.5) * 0.3 * dirt);

    if (isFloor) {
        float3 c2 = U.floorColor2.rgb;
        float pattern = U.floorColor2.w;
        float2 xz = P.xz;
        if (kind == 2 && pattern > 0.5 && pattern < 1.5) {
            // Flagstones.
            float2 g = xz / 1.15;
            float row = floor(g.y);
            g.x += fmod(row, 2.0) * 0.5;
            float2 cell = floor(g);
            float2 f = fract(g);
            float grout = smoothstep(0.0, 0.035, min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y)));
            float h = hash12(cell);
            s.albedo = mix(c2 * 0.6, base * (0.75 + 0.45 * h) * (0.8 + 0.4 * a.r), grout);
            s.roughness = mix(0.95, M.emissiveRough.a * (0.85 + 0.3 * a.b), grout);
            s.normal = triNormal(detailN, t, N, 0.6 * grout + 0.2, false);
            s.ao *= mix(0.6, 1.0, grout);
        } else if (kind == 17) {
            // Planks / tatami.
            bool tatami = pattern > 1.5;
            float w = tatami ? 0.9 : 0.32;
            float gz = P.z / w;
            float plank = floor(gz);
            float fz = fract(gz);
            float h = hash12(float2(plank, 3.1));
            float along = P.x + h * 17.0;
            float seg = floor(along / (tatami ? 1.8 : 2.4));
            float fx = fract(along / (tatami ? 1.8 : 2.4));
            float gap = smoothstep(0.0, 0.03, min(fz, 1.0 - fz)) * smoothstep(0.0, 0.01, min(fx, 1.0 - fx));
            float grain = sin(along * 30.0 + a.r * 6.0 + h * 10.0) * 0.5 + 0.5;
            float3 tint = base * (0.7 + 0.5 * hash12(float2(plank, seg)));
            s.albedo = mix(c2 * 0.4, tint * (0.85 + 0.25 * grain), gap);
            if (tatami) s.albedo = mix(s.albedo, s.albedo * (0.9 + 0.2 * a.b), 0.5);
            s.roughness = mix(0.9, M.emissiveRough.a * (0.9 + 0.2 * grain), gap);
            s.normal = triNormal(detailN, t, N, tatami ? 0.5 : 0.25, tatami);
        } else if (kind == 15) {
            // Polished marble with veins and inlaid checker.
            float v = abs(sin(P.x * 1.7 + P.z * 0.6 + aBig.r * 9.0 + a.r * 2.0));
            float vein = 1.0 - smoothstep(0.0, 0.06, v);
            float2 cell = floor(xz / 2.0);
            float checker = fmod(abs(cell.x + cell.y), 2.0);
            float3 m = mix(base, mix(base, c2, 0.85), checker);
            s.albedo = mix(m, m * 0.35, vein * 0.8);
            s.roughness = M.emissiveRough.a + a.b * 0.05;
        } else if (kind == 7) {
            // Obsidian with glowing veins in the secondary color.
            float cracks = 1.0 - smoothstep(0.0, 0.05, aBig.g);
            s.albedo = base * (0.7 + 0.3 * a.r);
            s.roughness = M.emissiveRough.a + a.b * 0.05;
            s.emissive += c2 * cracks * (luminance(c2) > 0.05 ? 2.5 : 0.0) * (0.6 + 0.4 * sin(U.cameraPos.w * 1.5 + P.x));
            s.metallic = 0.3;
        } else if (kind == 16) {
            s.albedo = base * (0.9 + 0.15 * a.b);
            s.roughness = 0.8;
            float glint = step(0.985, hash13(floor(P * 60.0)));
            s.emissive += float3(glint * 0.6);
            s.normal = triNormal(detailN, t, N, 0.3, true);
        } else if (kind == 6) {
            float cracks = 1.0 - smoothstep(0.0, 0.03, aBig.g);
            s.albedo = mix(base, c2, cracks * 0.8 + a.r * 0.2);
            s.roughness = M.emissiveRough.a + cracks * 0.3;
            s.metallic = 0.0;
        } else {
            // Natural ground (dirt, rock, moss, sand, bone, lava).
            float3 m = mix(c2, base, smoothstep(0.3, 0.7, aBig.r));
            s.albedo = m * (0.8 + 0.4 * a.b);
            s.roughness = M.emissiveRough.a * (0.9 + 0.2 * a.b);
            s.normal = triNormal(detailN, t, N, 0.7, false);
            if (kind == 14) {
                float cracks = 1.0 - smoothstep(0.0, 0.08, aBig.g);
                s.emissive += float3(1.0, 0.35, 0.08) * cracks * 3.0;
            }
        }
        // Wet puddles (screen-space reflections).
        float wet = U.fogParams.z;
        if (wet > 0.0) {
            float puddle = smoothstep(0.52, 0.62, aBig.r * 0.7 + a.r * 0.3) * wet;
            s.roughness = mix(s.roughness, 0.03, max(puddle, wet * 0.35));
            s.albedo *= mix(1.0, 0.55, puddle);
            s.normal = normalize(mix(s.normal, N, puddle));
            s.ssrMask = saturate(max(puddle, wet * 0.6)) * saturate(1.0 - s.roughness * 2.5);
        }
        s.ssrMask = max(s.ssrMask, saturate(1.0 - s.roughness * 3.0) * 0.8);
        return s;
    }

    switch (kind) {
        case 1: case 11: case 12: {   // metal, gold, rusted iron
            float scratch = a.a;
            float exposed = saturate(edge * 1.4 + scratch * wear * 0.6);
            s.albedo = mix(base, base * 1.35 + 0.05, exposed * wear);
            s.roughness = saturate(M.emissiveRough.a + (a.b - 0.5) * 0.18 - exposed * 0.15 + grime * 0.3);
            s.normal = triNormal(detailN, t, N, 0.18, false);
            float rustMask = smoothstep(0.55, 0.75, aBig.r * 0.6 + a.b * 0.4 + rust * 0.45 + cavity * 0.3 - edge * 0.3) * saturate(rust * 1.5 + (kind == 12 ? 0.3 : 0.0));
            float3 rustCol = mix(float3(0.28, 0.1, 0.04), float3(0.5, 0.22, 0.08), a.b);
            s.albedo = mix(s.albedo, rustCol, rustMask);
            s.metallic = mix(s.metallic, 0.15, rustMask);
            s.roughness = mix(s.roughness, 0.9, rustMask);
            s.albedo = mix(s.albedo, s.albedo * 0.4, grime * 0.6);
            s.ssrMask = saturate(0.5 - s.roughness);
            break;
        }
        case 2: case 13: case 9: case 18: {   // stone, dirt, moss, sand
            s.albedo = base * (0.7 + 0.5 * a.r) * mix(1.0, 0.55, 1.0 - smoothstep(0.02, 0.12, a.g));
            s.roughness = saturate(M.emissiveRough.a + (a.b - 0.5) * 0.2);
            s.normal = triNormal(detailN, t, N, 0.8, false);
            // Moss grows on upward surfaces and in cavities.
            float moss = saturate((N.y - 0.4) * 2.0) * smoothstep(0.55, 0.75, aBig.r) * (kind == 9 ? 1.0 : 0.35) * dirt;
            s.albedo = mix(s.albedo, float3(0.1, 0.16, 0.05) * (0.7 + 0.6 * a.b), moss);
            s.albedo = mix(s.albedo, s.albedo * 0.5, grime * 0.6);
            break;
        }
        case 3: case 17: {   // wood
            float rings = sin((P.y + P.x * 0.2) * 55.0 * scale + a.r * 8.0) * 0.5 + 0.5;
            s.albedo = base * (0.7 + 0.5 * rings * (0.6 + 0.4 * a.b));
            s.roughness = saturate(M.emissiveRough.a + (rings - 0.5) * 0.1);
            s.normal = triNormal(detailN, t, N, 0.25, true);
            s.albedo = mix(s.albedo, s.albedo * 0.45, grime);
            break;
        }
        case 4: {   // leather
            s.albedo = base * (0.8 + 0.35 * a.b) * mix(1.0, 1.35, edge * wear);
            s.roughness = saturate(M.emissiveRough.a + (a.b - 0.5) * 0.2 - edge * wear * 0.2);
            s.normal = triNormal(detailN, t, N, 0.35, true);
            s.albedo = mix(s.albedo, s.albedo * 0.5, grime);
            break;
        }
        case 5: {   // fabric
            Tri tf = makeTri(P, N, 5.0 * scale);
            float4 af = triSample(detailA, tf);
            s.albedo = base * (0.85 + 0.25 * af.b);
            s.roughness = 0.9;
            s.normal = triNormal(detailN, tf, N, 0.6, true);
            s.sheen = max(sheen, 0.3);
            s.wrap = 0.25;
            s.albedo = mix(s.albedo, s.albedo * 0.55, grime);
            break;
        }
        case 6: case 21: {   // ice, crystal
            float cracks = 1.0 - smoothstep(0.0, 0.05, a.g);
            s.albedo = mix(base, float3(0.95, 0.98, 1.0), cracks * 0.6);
            s.roughness = saturate(M.emissiveRough.a + cracks * 0.3);
            s.metallic = 0.0;
            s.wrap = 0.5;
            s.ssrMask = 0.5;
            break;
        }
        case 7: {   // obsidian armor
            s.albedo = base * (0.8 + 0.3 * a.r);
            s.roughness = saturate(M.emissiveRough.a + a.b * 0.08);
            s.normal = triNormal(detailN, t, N, 0.1, false);
            s.ssrMask = 0.4;
            break;
        }
        case 8: {   // bone
            s.albedo = base * (0.85 + 0.2 * a.b);
            s.albedo = mix(s.albedo, float3(0.25, 0.2, 0.15), grime * 0.8);
            s.roughness = 0.6;
            s.normal = triNormal(detailN, t, N, 0.3, true);
            break;
        }
        case 10: {   // skin
            s.albedo = base * (0.92 + 0.12 * a.b);
            s.roughness = saturate(0.5 + (a.b - 0.5) * 0.1);
            s.normal = triNormal(detailN, t, N, 0.08, true);
            s.wrap = 0.45;
            break;
        }
        case 14: {   // lava rock
            float cracks = 1.0 - smoothstep(0.0, 0.07, a.g);
            s.albedo = base * (0.6 + 0.4 * a.r);
            s.emissive += float3(1.0, 0.35, 0.06) * cracks * 3.0;
            s.roughness = 0.8;
            break;
        }
        case 15: {   // marble
            float v = abs(sin(P.y * 2.0 + P.x * 1.3 + aBig.r * 9.0));
            s.albedo = mix(base, base * 0.4, (1.0 - smoothstep(0.0, 0.08, v)) * 0.7);
            s.roughness = M.emissiveRough.a;
            break;
        }
        case 19: {   // hair
            s.albedo = base * (0.8 + 0.4 * a.a);
            s.roughness = 0.45;
            s.normal = triNormal(detailN, t, N, 0.4, true);
            s.sheen = 0.5;
            break;
        }
        case 20: {   // water
            s.albedo = base;
            s.roughness = 0.05;
            s.ssrMask = 0.9;
            break;
        }
        default: {
            s.albedo = base * (0.9 + 0.2 * a.b);
            s.roughness = saturate(M.emissiveRough.a + (a.b - 0.5) * 0.1);
            s.albedo = mix(s.albedo, s.albedo * 0.5, grime * 0.5);
            break;
        }
    }
    // Emissive engravings (runes) along cell edges.
    if (runes > 0.0) {
        float rune = (1.0 - smoothstep(0.0, 0.04, a.g)) * smoothstep(0.4, 0.6, aBig.r);
        s.emissive += M.emissiveRough.rgb * rune * runes * 1.5;
    }
    // Frost on top faces and cavities.
    if (frost > 0.0) {
        float f = saturate((N.y * 0.6 + cavity * 0.8 + a.r * 0.4 - 0.4) * frost * 1.6);
        s.albedo = mix(s.albedo, float3(0.85, 0.92, 1.0), f);
        s.roughness = mix(s.roughness, 0.55, f);
        s.metallic *= 1.0 - f;
    }
    (void)detailSeed;
    return s;
}

// ---------------------------------------------------------------- Shadows

inline float sampleShadow(constant FrameUniforms& U, depth2d_array<float> shadowMap, float3 P, float3 N, float viewDepth) {
    if (U.flags.z < 0.5) return 1.0;
    uint cascade = 0;
    if (viewDepth > U.cascadeSplits.x) cascade = 1;
    if (viewDepth > U.cascadeSplits.y) cascade = 2;
    if (viewDepth > U.cascadeSplits.z) return 1.0;
    float texel = U.shadowInfo.x * (1.0 + float(cascade) * 1.5);
    float3 offsetP = P + N * texel * 1.5;
    float4 sp = U.shadowViewProj[cascade] * float4(offsetP, 1.0);
    float3 ndc = sp.xyz / sp.w;
    float2 uv = float2(ndc.x * 0.5 + 0.5, 1.0 - (ndc.y * 0.5 + 0.5));
    if (any(uv < 0.0) || any(uv > 1.0)) return 1.0;
    float ref = ndc.z - U.shadowInfo.y * (1.0 + float(cascade));
    float2 ts = float2(1.0 / float(shadowMap.get_width()));
    float sum = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            sum += shadowMap.sample_compare(sShadow, uv + float2(x, y) * ts * 1.2, cascade, ref);
        }
    }
    float s = sum / 9.0;
    // Fade out at the far end of the last cascade.
    float fade = saturate((U.cascadeSplits.z - viewDepth) / (U.cascadeSplits.z * 0.1));
    return mix(1.0, s, fade);
}

inline float contactShadow(constant FrameUniforms& U, texture2d<float> linearDepth, float3 P, float2 pixel) {
    if (U.flags.y < 0.5) return 1.0;
    float3 vp = (U.view * float4(P, 1.0)).xyz;
    float3 vl = normalize((U.view * float4(U.sunDir.xyz, 0.0)).xyz);
    float jitter = ign(pixel, U.flags.w);
    float occl = 0.0;
    const int steps = 8;
    for (int i = 1; i <= steps; i++) {
        float t = (float(i) + jitter) / float(steps) * 0.25;
        float3 q = vp + vl * t;
        if (q.z > -0.05) break;
        float2 uv = viewToUV(U, q);
        if (any(uv < 0.0) || any(uv > 1.0)) break;
        float d = linearDepth.sample(sPointClamp, uv).r;
        float diff = -q.z - d;
        if (diff > 0.02 && diff < 0.3) { occl = 1.0 - float(i) / float(steps + 2); break; }
    }
    return 1.0 - occl * 0.85;
}

// ---------------------------------------------------------------- Prepass

struct PrepassOut {
    float4 normalRough [[color(0)]];
    float2 velocity [[color(1)]];
    float linearDepth [[color(2)]];
    float2 objVelocity [[color(3)]];
};

inline float2 clipToUV(float4 c) {
    float2 ndc = c.xy / max(c.w, 1e-5);
    return float2(ndc.x * 0.5 + 0.5, 1.0 - (ndc.y * 0.5 + 0.5));
}

fragment PrepassOut fs_prepass(VSOut in [[stage_in]],
                               constant FrameUniforms& U [[buffer(0)]],
                               const device MaterialGPU* mats [[buffer(1)]],
                               const device InstanceData* inst [[buffer(2)]],
                               bool front [[front_facing]]) {
    PrepassOut o;
    float3 N = normalize(in.normal) * (front ? 1.0 : -1.0);
    float3 vn = normalize((U.view * float4(N, 0.0)).xyz);
    MaterialGPU M = mats[in.matSlot];
    bool isFloor = inst[in.inst].params.w > 999.0;
    float rough = M.emissiveRough.a;
    float ssr = 0.0;
    if (isFloor) { ssr = saturate(U.fogParams.z * 0.8 + (1.0 - rough * 3.0) * 0.8); rough = mix(rough, 0.05, U.fogParams.z * 0.5); }
    o.normalRough = float4(vn, isFloor ? -(1.0 + ssr) : rough);
    float2 cur = clipToUV(in.curClip);
    o.velocity = clipToUV(in.prevClip) - cur;
    o.objVelocity = clipToUV(in.prevObjClip) - cur;
    o.linearDepth = in.viewDepth;
    return o;
}

// ---------------------------------------------------------------- Main

fragment float4 fs_main(VSOut in [[stage_in]],
                        constant FrameUniforms& U [[buffer(0)]],
                        const device MaterialGPU* mats [[buffer(1)]],
                        const device PointLight* lights [[buffer(2)]],
                        const device uint* tiles [[buffer(3)]],
                        const device InstanceData* inst [[buffer(4)]],
                        texture2d<float> detailA [[texture(0)]],
                        texture2d<float> detailN [[texture(1)]],
                        depth2d_array<float> shadowMap [[texture(2)]],
                        texturecube<float> skyCube [[texture(3)]],
                        texture2d<float> aoTex [[texture(4)]],
                        texture2d<float> linearDepth [[texture(5)]],
                        bool front [[front_facing]]) {
    const device InstanceData& I = inst[in.inst];
    MaterialGPU M = mats[in.matSlot];
    float3 N0 = normalize(in.normal) * (front ? 1.0 : -1.0);
    bool isFloor = I.params.w > 999.0;
    Surface s = evalMaterial(U, M, in.worldPos, N0, in.color, in.attr, isFloor, detailA, detailN);
    s.albedo *= I.tint.rgb;
    float3 N = s.normal;
    float3 V = normalize(U.cameraPos.xyz - in.worldPos);
    float NoV = saturate(dot(N, V)) + 1e-4;
    float rough = clamp(s.roughness, 0.03, 1.0);
    float a = rough * rough;
    float3 f0 = mix(float3(0.04), s.albedo, s.metallic);
    float3 diffuseColor = s.albedo * (1.0 - s.metallic);
    float2 screenUV = in.position.xy * U.screen.zw;

    // Ambient occlusion (SSAO * baked cavity).
    float ssao = U.flags.x > 0.5 ? aoTex.sample(sLinearClamp, screenUV).r : 1.0;
    float ao = saturate(s.ao * 0.85 + 0.15) * ssao;

    float3 color = float3(0.0);
    // Sun.
    float3 L = normalize(U.sunDir.xyz);
    float NoL = dot(N, L);
    float shadow = sampleShadow(U, shadowMap, in.worldPos, N0, in.viewDepth);
    if (shadow > 0.01 && NoL > -0.3) shadow *= contactShadow(U, linearDepth, in.worldPos, in.position.xy);
    {
        float3 H = normalize(L + V);
        float NoLc = saturate(NoL);
        float NoH = saturate(dot(N, H));
        float VoH = saturate(dot(V, H));
        float3 F = F_Schlick(f0, VoH);
        float3 spec = D_GGX(NoH, a) * V_SmithGGXCorrelated(NoV, NoLc, a) * F;
        float wrapped = saturate((NoL + s.wrap) / (1.0 + s.wrap));
        float3 diff = diffuseColor * (1.0 / PI) * wrapped * (1.0 - F);
        float3 sunRad = U.sunColor.rgb * U.sunDir.w;
        color += (diff + spec * NoLc) * sunRad * shadow;
        if (s.wrap > 0.3) {
            // Subsurface tint for skin / ice.
            color += diffuseColor * float3(0.6, 0.2, 0.15) * saturate(-NoL + 0.3) * sunRad * 0.08;
        }
    }
    // Point lights (tiled).
    uint2 tile = uint2(in.position.xy) / TILE_SIZE;
    uint tilesX = uint(U.tileInfo.x);
    uint base = (tile.y * tilesX + tile.x) * (MAX_LIGHTS_PER_TILE + 1);
    uint count = min(tiles[base], uint(MAX_LIGHTS_PER_TILE));
    for (uint i = 0; i < count; i++) {
        PointLight pl = lights[tiles[base + 1 + i]];
        float3 toL = pl.positionRadius.xyz - in.worldPos;
        float d2 = dot(toL, toL);
        float r = pl.positionRadius.w;
        if (d2 > r * r) continue;
        float d = sqrt(d2);
        float3 Lp = toL / max(d, 1e-4);
        float falloff = saturate(1.0 - pow(d / r, 4.0));
        falloff = falloff * falloff / (d2 + 1.0);
        float NoLp = saturate(dot(N, Lp));
        float3 H = normalize(Lp + V);
        float3 F = F_Schlick(f0, saturate(dot(V, H)));
        float3 spec = D_GGX(saturate(dot(N, H)), a) * V_SmithGGXCorrelated(NoV, NoLp, a) * F;
        float3 rad = pl.colorIntensity.rgb * pl.colorIntensity.w * falloff;
        color += (diffuseColor / PI * (1.0 - F) + spec) * NoLp * rad;
    }
    // Ambient: SH irradiance + specular IBL from the sky cubemap.
    float3 irradiance = evalSH(U, N);
    color += diffuseColor * irradiance * ao;
    float3 R = reflect(-V, N);
    float mipCount = float(skyCube.get_num_mip_levels());
    float3 prefiltered = skyCube.sample(sLinearClamp, R, level(rough * (mipCount - 1.0))).rgb;
    float specOcc = saturate(pow(NoV + ao, exp2(-16.0 * rough - 1.0)) - 1.0 + ao);
    float3 envSpec = prefiltered * envBRDFApprox(f0, rough, NoV) * specOcc * U.sunColor.w * 1.4;
    color += envSpec * (1.0 - s.ssrMask * 0.5 * U.misc.z);
    // Sheen (fabric / hair).
    if (s.sheen > 0.0) color += s.albedo * pow(1.0 - NoV, 5.0) * s.sheen * irradiance * 1.5;
    // Dramatic rim light (readability).
    float rim = pow(1.0 - NoV, 4.0) * U.rimColor.w * (isFloor ? 0.0 : 1.0);
    float rimFacing = saturate(dot(N, -normalize(float3(U.sunDir.x, 0.0, U.sunDir.z))) * 0.5 + 0.5);
    color += U.rimColor.rgb * rim * (0.35 + 0.65 * rimFacing) * (0.5 + 0.5 * ao);
    // Emissive.
    color += s.emissive * (1.0 + I.params.y);
    // Telegraph glow (fighter rims light up in the telegraph color).
    float tg = I.params.z;
    if (tg > 0.0) {
        uint kind = uint(I.flash.a + 0.5);
        float3 tc = kind == 2 ? float3(1.0, 0.1, 0.05) : (kind == 3 ? float3(0.7, 0.3, 1.0) : (kind == 4 ? float3(1.0, 0.75, 0.2) : float3(1.0)));
        color += tc * (pow(1.0 - NoV, 2.0) * 3.0 + 0.15) * tg;
    }
    // Hit flash.
    color = mix(color, I.flash.rgb * 3.0, saturate(I.params.x) * 0.55);
    return float4(color, I.tint.a);
}

// Additive fresnel silhouettes for afterimages and invisibility.
fragment float4 fs_ghost(VSOut in [[stage_in]],
                         constant FrameUniforms& U [[buffer(0)]],
                         const device InstanceData* inst [[buffer(4)]],
                         bool front [[front_facing]]) {
    const device InstanceData& I = inst[in.inst];
    float3 N = normalize(in.normal) * (front ? 1.0 : -1.0);
    float3 V = normalize(U.cameraPos.xyz - in.worldPos);
    float f = pow(1.0 - saturate(dot(N, V)), 2.5);
    float3 c = I.tint.rgb * (0.15 + f * 2.5) * I.tint.a;
    return float4(c, 0.0);
}
