// GPU particles: the CPU queues spawns, a compute kernel copies them into a ring-buffer
// pool and another integrates every live particle. Rendering draws one camera-facing (or
// velocity-stretched) quad per pool slot; dead slots collapse to degenerate triangles.
// Output is premultiplied: additive kinds write alpha 0, alpha kinds write coverage.

kernel void particle_spawn(device Particle* pool [[buffer(0)]],
                           const device Particle* spawns [[buffer(1)]],
                           constant uint4& P [[buffer(2)]],        // x count, y head, z capacity
                           uint id [[thread_position_in_grid]]) {
    if (id >= P.x) return;
    pool[(P.y + id) % P.z] = spawns[id];
}

kernel void particle_update(device Particle* pool [[buffer(0)]],
                            constant float4& S [[buffer(1)]],      // x dt, y time, z floor height, w capacity
                            uint id [[thread_position_in_grid]]) {
    if (id >= uint(S.w)) return;
    Particle p = pool[id];
    if (p.posLife.w <= 0.0) return;
    float dt = S.x;
    int kind = int(p.params.w + 0.5);
    float3 pos = p.posLife.xyz;
    float3 vel = p.velSize.xyz;
    float seed = p.extra.w;
    vel.y -= p.params.z * dt;
    vel *= exp(-p.params.y * dt);
    if (kind == 3 || kind == 5) {
        // Snow / petals flutter.
        float t = S.y * 1.3 + seed * 17.0;
        vel.x += sin(t) * 0.9 * dt;
        vel.z += cos(t * 0.8) * 0.9 * dt;
    } else if (kind == 2) {
        vel.y += 0.25 * dt;   // smoke rises
    }
    pos += vel * dt;
    float floorY = S.z;
    if (pos.y < floorY) {
        if (kind == 0 || kind == 8) {
            pos.y = floorY;
            vel.y = -vel.y * 0.35;
            vel.xz *= 0.6;
        } else if (kind == 7) {
            pos.y = floorY + 0.005;
            vel = float3(0.0);
        } else if (kind == 4 || kind == 3) {
            p.posLife.w = 0.0;
        } else {
            pos.y = floorY;
            vel.y = 0.0;
        }
    }
    p.posLife.xyz = pos;
    p.velSize.xyz = vel;
    p.posLife.w = max(p.posLife.w - dt, 0.0);
    p.velSize.w = max(p.velSize.w + p.extra.x * dt, 0.0);
    pool[id] = p;
}

struct ParticleVSOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float kind [[flat]];
    float viewDepth;
    float seed [[flat]];
};

vertex ParticleVSOut vs_particle(const device Particle* pool [[buffer(0)]],
                                 constant FrameUniforms& U [[buffer(1)]],
                                 uint vid [[vertex_id]], uint iid [[instance_id]]) {
    ParticleVSOut o;
    Particle p = pool[iid];
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    o.uv = corner;
    o.kind = p.params.w;
    o.seed = p.extra.w;
    if (p.posLife.w <= 0.0 || p.velSize.w <= 0.0) {
        o.position = float4(-2.0, -2.0, 0.0, 1.0);
        o.color = float4(0.0);
        o.viewDepth = 0.0;
        return o;
    }
    int kind = int(p.params.w + 0.5);
    float life = p.posLife.w;
    float maxLife = max(p.params.x, 1e-3);
    float age = maxLife - life;
    float t = saturate(age / maxLife);
    float size = p.velSize.w;
    float3 pos = p.posLife.xyz;
    float3 vel = p.velSize.xyz;

    float3 right = float3(U.view[0][0], U.view[1][0], U.view[2][0]);
    float3 up = float3(U.view[0][1], U.view[1][1], U.view[2][1]);
    float3 fwd = -float3(U.view[0][2], U.view[1][2], U.view[2][2]);
    float3 world;
    bool stretched = kind == 0 || kind == 4 || (kind == 7 && length(vel) > 0.5);
    if (stretched) {
        float3 v = vel - fwd * dot(vel, fwd);
        float speed = length(v);
        float3 axis = speed > 1e-3 ? v / speed : up;
        float3 side = normalize(cross(axis, fwd));
        float len = size + length(vel) * p.extra.z * 0.022;
        world = pos + axis * corner.y * len + side * corner.x * size * 0.5;
    } else {
        float ang = p.extra.y * age + p.extra.w * 6.2831853;
        float c = cos(ang), s = sin(ang);
        float2 rc = float2(corner.x * c - corner.y * s, corner.x * s + corner.y * c);
        world = pos + (right * rc.x + up * rc.y) * size;
    }
    float fadeIn = (kind == 2 || kind == 3 || kind == 5) ? smoothstep(0.0, 0.12, t) : 1.0;
    float fadeOut = saturate(life / (maxLife * 0.35));
    o.color = float4(p.color.rgb, p.color.a * fadeIn * fadeOut);
    if (kind == 6) o.color.rgb *= 0.7 + 0.3 * sin(age * 30.0 + p.extra.w * 40.0);   // embers flicker
    o.position = U.viewProj * float4(world, 1.0);
    o.viewDepth = -(U.view * float4(world, 1.0)).z;
    return o;
}

fragment float4 fs_particle(ParticleVSOut in [[stage_in]],
                            constant FrameUniforms& U [[buffer(0)]],
                            texture2d<float> linearDepth [[texture(0)]]) {
    int kind = int(in.kind + 0.5);
    float2 uv = in.uv;
    float r = length(uv);
    float shape;
    switch (kind) {
        case 0: shape = pow(saturate(1.0 - abs(uv.x)), 2.0) * saturate(1.0 - abs(uv.y) * 0.9); break;      // spark streak
        case 1: shape = exp(-r * r * 3.5) * saturate(1.0 - r); break;                                      // glow
        case 2: {                                                                                          // smoke puff
            float n = hash12(floor((uv + in.seed * 7.0) * 3.0)) * 0.35 + 0.65;
            shape = smoothstep(1.0, 0.2, r) * n * 0.8;
            break;
        }
        case 3: shape = smoothstep(1.0, 0.4, r); break;                                                    // snow
        case 4: shape = saturate(1.0 - abs(uv.x)) * saturate(1.0 - abs(uv.y)) * 0.6; break;                 // rain
        case 5: shape = step(uv.x * uv.x + uv.y * uv.y * 3.0, 1.0) * 0.95; break;                           // petal
        case 6: shape = exp(-r * r * 5.0); break;                                                          // ember
        case 7: shape = smoothstep(1.0, 0.7, r); break;                                                    // blood
        default: shape = step(abs(uv.x) + abs(uv.y), 1.0); break;                                          // shard
    }
    if (shape < 0.003) discard_fragment();
    float sceneD = linearDepth.read(uint2(in.position.xy)).r;
    float softness = kind == 2 ? 0.6 : 0.08;
    float soft = saturate((sceneD - in.viewDepth) / softness);
    float a = shape * in.color.a * soft;
    bool additive = kind == 0 || kind == 1 || kind == 6;
    if (additive) return float4(in.color.rgb * a, 0.0);
    // Alpha kinds are lit by the ambient SH and a flat sun term.
    float3 light = evalSH(U, float3(0.0, 1.0, 0.0)) + U.sunColor.rgb * U.sunDir.w * saturate(U.sunDir.y + 0.3) * 0.25;
    if (kind == 8) light *= 1.2 + 0.6 * uv.y;
    float3 c = in.color.rgb * light;
    return float4(c * a, a);
}
