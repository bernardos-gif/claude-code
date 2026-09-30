// Minimal C++ emulation of the Metal Shading Language standard library, used only to
// syntax/type-check the shaders on machines without the Metal compiler (Linux CI).
// Declarations only: nothing here is meant to execute.
#pragma once
#pragma clang diagnostic ignored "-Wunknown-attributes"
#pragma clang diagnostic ignored "-Wunused-value"
#pragma clang diagnostic ignored "-Wunused-variable"

typedef unsigned int uint;
typedef unsigned char uchar;
typedef unsigned short ushort;
typedef float half;

#define DV(T, N, NAME) typedef T NAME __attribute__((ext_vector_type(N)));
DV(float, 2, float2) DV(float, 3, float3) DV(float, 4, float4)
DV(int, 2, int2) DV(int, 3, int3) DV(int, 4, int4)
DV(uint, 2, uint2) DV(uint, 3, uint3) DV(uint, 4, uint4)
DV(uchar, 2, uchar2) DV(uchar, 3, uchar3) DV(uchar, 4, uchar4)
DV(ushort, 2, ushort2) DV(ushort, 3, ushort3) DV(ushort, 4, ushort4)
typedef int bool2 __attribute__((ext_vector_type(2)));
typedef int bool3 __attribute__((ext_vector_type(3)));
typedef int bool4 __attribute__((ext_vector_type(4)));

struct packed_float3 { float x, y, z; float& operator[](int); };
struct packed_float2 { float x, y; };
struct packed_float4 { float x, y, z, w; };

template<class T> struct comps { static constexpr int value = 1; };
#define CV(NAME, N) template<> struct comps<NAME> { static constexpr int value = N; };
CV(float2, 2) CV(float3, 3) CV(float4, 4) CV(int2, 2) CV(int3, 3) CV(int4, 4) CV(uint2, 2) CV(uint3, 3) CV(uint4, 4)
CV(uchar2, 2) CV(uchar3, 3) CV(uchar4, 4) CV(ushort2, 2) CV(ushort3, 3) CV(ushort4, 4)
CV(packed_float3, 3) CV(packed_float2, 2) CV(packed_float4, 4)

template<class... A> struct sumc { static constexpr int value = 0; };
template<class H, class... A> struct sumc<H, A...> { static constexpr int value = comps<H>::value + sumc<A...>::value; };

// Vector constructor emulation: floatN(...) is rewritten to mk<floatN>(...) by check_msl.py.
template<class V, class... A> V mk(A... a) {
    static_assert(sizeof...(A) == 1 ? (sumc<A...>::value == 1 || sumc<A...>::value == comps<V>::value) : sumc<A...>::value == comps<V>::value,
                  "vector constructor component count mismatch");
    return V{};
}

template<class C, int N> struct matN {
    C columns[N];
    C& operator[](int);
    const C& operator[](int) const;
};
typedef matN<float4, 4> float4x4;
typedef matN<float3, 3> float3x3;
typedef matN<float2, 2> float2x2;
float4 operator*(const float4x4&, float4);
float3 operator*(const float3x3&, float3);
float2 operator*(const float2x2&, float2);
float4x4 operator*(const float4x4&, const float4x4&);
float3x3 operator*(const float3x3&, const float3x3&);
template<class M, class... A> M mkm(A... a) {
    static_assert(sizeof...(A) == 1 || sizeof...(A) == (int)(sizeof(M) / sizeof(M{}.columns[0])) || sizeof...(A) == (int)(sizeof(M) / sizeof(float)),
                  "matrix constructor arity");
    return M{};
}
float3x3 transpose(float3x3);
float4x4 transpose(float4x4);

// ---- Math (generated overloads for scalar + vector float types).
#define UN(F) float F(float); float2 F(float2); float3 F(float3); float4 F(float4);
UN(abs) UN(fract) UN(floor) UN(ceil) UN(sqrt) UN(rsqrt) UN(sin) UN(cos) UN(tan) UN(exp) UN(exp2) UN(log) UN(log2) UN(saturate)
UN(sign) UN(round) UN(trunc) UN(acos) UN(asin) UN(atan) UN(tanh) UN(fwidth) UN(dfdx) UN(dfdy)
int abs(int); int2 abs(int2);
#define BIN_SAME(F) float F(float, float); float2 F(float2, float2); float3 F(float3, float3); float4 F(float4, float4);
BIN_SAME(pow) BIN_SAME(fmod) BIN_SAME(atan2)
#define BIN_BC(F) BIN_SAME(F) float2 F(float2, float); float3 F(float3, float); float4 F(float4, float); \
    int F(int, int); uint F(uint, uint); uint2 F(uint2, uint2); int2 F(int2, int2); uint3 F(uint3, uint3); int3 F(int3, int3);
BIN_BC(min) BIN_BC(max)
float step(float, float); float2 step(float2, float2); float3 step(float3, float3); float4 step(float4, float4);
float2 step(float, float2); float3 step(float, float3); float4 step(float, float4);
#define TRI(F) float F(float, float, float); float2 F(float2, float2, float2); float3 F(float3, float3, float3); float4 F(float4, float4, float4);
TRI(mix) TRI(clamp) TRI(smoothstep) TRI(fma)
float2 mix(float2, float2, float); float3 mix(float3, float3, float); float4 mix(float4, float4, float);
float2 clamp(float2, float, float); float3 clamp(float3, float, float); float4 clamp(float4, float, float);
int clamp(int, int, int); uint clamp(uint, uint, uint); int2 clamp(int2, int2, int2);
float2 smoothstep(float, float, float2); float3 smoothstep(float, float, float3); float4 smoothstep(float, float, float4);
float dot(float2, float2); float dot(float3, float3); float dot(float4, float4);
float length(float2); float length(float3); float length(float4);
float length_squared(float2); float length_squared(float3);
float distance(float2, float2); float distance(float3, float3);
float2 normalize(float2); float3 normalize(float3); float4 normalize(float4);
float3 cross(float3, float3);
float3 reflect(float3, float3); float2 reflect(float2, float2);
float3 refract(float3, float3, float);
bool any(int2); bool any(int3); bool any(int4); bool all(int2); bool all(int3); bool all(int4); bool any(bool); bool all(bool);
float select(float, float, bool); float2 select(float2, float2, int2); float3 select(float3, float3, int3); float4 select(float4, float4, int4);
float3 select(float3, float3, bool);
template<class T, class U> T as_type(U u) { static_assert(sizeof(T) == sizeof(U), "as_type size mismatch"); return T{}; }
bool isnan(float); bool isinf(float); int3 isinf(float3); int4 isinf(float4); int2 isinf(float2);
int2 isnan(float2); int3 isnan(float3); int4 isnan(float4);
uint popcount(uint);
namespace metal { namespace fast { UN(sin) UN(cos) UN(exp) UN(exp2) UN(pow) } }
#define M_PI_F 3.14159265f
#define FLT_MAX 3.402823466e+38f
#define INFINITY (1.0f/0.0f)

// ---- Samplers.
namespace coord { enum E { normalized, pixel }; }
namespace filter { enum E { nearest, linear }; }
namespace mip_filter { enum E { none, nearest, linear }; }
namespace address { enum E { repeat, clamp_to_edge, clamp_to_zero, mirrored_repeat, clamp_to_border }; }
namespace compare_func { enum E { none, less, less_equal, greater, greater_equal, equal, not_equal, always, never }; }
namespace s_address { enum E { repeat, clamp_to_edge }; }
namespace t_address { enum E { repeat, clamp_to_edge }; }
namespace min_filter { enum E { nearest, linear }; }
namespace mag_filter { enum E { nearest, linear }; }
struct max_anisotropy { constexpr max_anisotropy(int) {} };
struct sampler {
    template<class... A> constexpr sampler(A...) {}
};
struct level { level(float); };
struct bias { bias(float); };
struct gradient2d { gradient2d(float2, float2); };

// ---- Textures.
namespace access { enum E { sample, read, write, read_write }; }
template<class T> struct v4 { typedef float4 type; };
template<> struct v4<uint> { typedef uint4 type; };
template<> struct v4<int> { typedef int4 type; };
template<class T, access::E A = access::sample> struct texture2d {
    typedef typename v4<T>::type V;
    V sample(sampler, float2) const; V sample(sampler, float2, level) const; V sample(sampler, float2, bias) const;
    V sample(sampler, float2, level, int2) const; V sample(sampler, float2, int2) const;
    V read(uint2) const; V read(uint2, uint) const; V read(int2) const;
    void write(V, uint2) const; void write(V, uint2, uint) const;
    V gather(sampler, float2) const;
    uint get_width(uint = 0) const; uint get_height(uint = 0) const; uint get_num_mip_levels() const;
};
template<class T, access::E A = access::sample> struct texture2d_array {
    typedef typename v4<T>::type V;
    V sample(sampler, float2, uint) const; V sample(sampler, float2, uint, level) const;
    V read(uint2, uint) const; void write(V, uint2, uint) const;
    uint get_width(uint = 0) const; uint get_height(uint = 0) const;
};
template<class T, access::E A = access::sample> struct texturecube {
    typedef typename v4<T>::type V;
    V sample(sampler, float3) const; V sample(sampler, float3, level) const;
    void write(V, uint2, uint) const; void write(V, uint2, uint, uint) const;
    uint get_width(uint = 0) const; uint get_height(uint = 0) const; uint get_num_mip_levels() const;
};
template<class T, access::E A = access::sample> struct texture3d {
    typedef typename v4<T>::type V;
    V sample(sampler, float3) const; V read(uint3) const; void write(V, uint3) const;
};
template<class T, access::E A = access::sample> struct depth2d {
    float sample(sampler, float2) const; float sample_compare(sampler, float2, float) const; float read(uint2) const;
    uint get_width(uint = 0) const; uint get_height(uint = 0) const;
};
template<class T, access::E A = access::sample> struct depth2d_array {
    float sample(sampler, float2, uint) const; float sample_compare(sampler, float2, uint, float) const;
    float sample_compare(sampler, float2, uint, float, level) const;
    float read(uint2, uint) const;
    uint get_width(uint = 0) const; uint get_height(uint = 0) const;
};

// ---- Atomics / sync.
struct atomic_uint { uint v; };
struct atomic_int { int v; };
enum memory_order { memory_order_relaxed };
uint atomic_fetch_min_explicit(atomic_uint*, uint, memory_order);
uint atomic_fetch_max_explicit(atomic_uint*, uint, memory_order);
uint atomic_fetch_add_explicit(atomic_uint*, uint, memory_order);
void atomic_store_explicit(atomic_uint*, uint, memory_order);
uint atomic_load_explicit(atomic_uint*, memory_order);
namespace mem_flags { enum E { mem_none, mem_device, mem_threadgroup, mem_texture }; }
void threadgroup_barrier(mem_flags::E);
void discard_fragment();

// ---- Address spaces / function qualifiers.
#define vertex
#define fragment
#define kernel
#define device
#define constant const
#define threadgroup static
#define thread
