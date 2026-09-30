// Tiled light culling (Forward+). One 16x16 threadgroup per screen tile: find the tile's
// depth bounds from the prepass linear depth, then test every point light against the tile
// frustum. Output layout per tile: [count, index0, index1, ... index62].

kernel void cull_lights(constant FrameUniforms& U [[buffer(0)]],
                        const device PointLight* lights [[buffer(1)]],
                        device uint* tiles [[buffer(2)]],
                        texture2d<float> linearDepth [[texture(0)]],
                        uint2 gid [[thread_position_in_grid]],
                        uint2 tgid [[threadgroup_position_in_grid]],
                        uint lid [[thread_index_in_threadgroup]]) {
    threadgroup atomic_uint minDepthBits;
    threadgroup atomic_uint maxDepthBits;
    threadgroup atomic_uint visibleCount;
    threadgroup uint visibleList[MAX_LIGHTS_PER_TILE];

    if (lid == 0) {
        atomic_store_explicit(&minDepthBits, as_type<uint>(1e9f), memory_order_relaxed);
        atomic_store_explicit(&maxDepthBits, 0u, memory_order_relaxed);
        atomic_store_explicit(&visibleCount, 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint w = linearDepth.get_width();
    uint h = linearDepth.get_height();
    if (gid.x < w && gid.y < h) {
        float d = linearDepth.read(gid).r;
        if (d < 999.0) {
            // Positive floats keep their ordering when compared as unsigned ints.
            atomic_fetch_min_explicit(&minDepthBits, as_type<uint>(d), memory_order_relaxed);
            atomic_fetch_max_explicit(&maxDepthBits, as_type<uint>(d), memory_order_relaxed);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float minD = as_type<float>(atomic_load_explicit(&minDepthBits, memory_order_relaxed));
    float maxD = as_type<float>(atomic_load_explicit(&maxDepthBits, memory_order_relaxed));

    // Tile side planes through the eye (view space, inward normals).
    float2 px0 = float2(tgid) * float(TILE_SIZE);
    float2 px1 = px0 + float(TILE_SIZE);
    float xl = (px0.x * U.screen.z * 2.0 - 1.0) / U.proj[0][0];
    float xr = (px1.x * U.screen.z * 2.0 - 1.0) / U.proj[0][0];
    float yt = (1.0 - px0.y * U.screen.w * 2.0) / U.proj[1][1];
    float yb = (1.0 - px1.y * U.screen.w * 2.0) / U.proj[1][1];
    float3 nL = normalize(float3(1.0, 0.0, xl));
    float3 nR = normalize(float3(-1.0, 0.0, -xr));
    float3 nB = normalize(float3(0.0, 1.0, yb));
    float3 nT = normalize(float3(0.0, -1.0, -yt));

    uint lightCount = uint(U.tileInfo.z);
    bool empty = minD > maxD;
    if (!empty) {
        for (uint i = lid; i < lightCount; i += TILE_SIZE * TILE_SIZE) {
            PointLight pl = lights[i];
            float r = pl.positionRadius.w;
            float3 vp = (U.view * float4(pl.positionRadius.xyz, 1.0)).xyz;
            float depth = -vp.z;
            if (depth + r < minD || depth - r > maxD) continue;
            if (dot(nL, vp) < -r || dot(nR, vp) < -r || dot(nB, vp) < -r || dot(nT, vp) < -r) continue;
            uint slot = atomic_fetch_add_explicit(&visibleCount, 1u, memory_order_relaxed);
            if (slot < MAX_LIGHTS_PER_TILE) visibleList[slot] = i;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint tilesX = uint(U.tileInfo.x);
    uint base = (tgid.y * tilesX + tgid.x) * (MAX_LIGHTS_PER_TILE + 1);
    uint count = min(atomic_load_explicit(&visibleCount, memory_order_relaxed), uint(MAX_LIGHTS_PER_TILE));
    if (lid == 0) tiles[base] = count;
    for (uint i = lid; i < count; i += TILE_SIZE * TILE_SIZE) {
        tiles[base + 1 + i] = visibleList[i];
    }
}
