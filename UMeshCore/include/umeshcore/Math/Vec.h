#pragma once

// Minimal float2/float3/float4 vector types matching the numeric semantics
// of Swift's `simd` SIMD2<Float>/SIMD3<Float>/SIMD4<Float> exactly (same
// component order, same operator behavior, IEEE-754 float32 throughout).
//
// This is a deliberately small, dependency-free library rather than GLM:
// UMeshCore's contract with the Swift reference implementation requires
// bit-reproducible numerics (see MeshPredicates' exact-arithmetic proof,
// which depends on vertices being exactly float32), so every operation here
// is written to match a specific Swift `simd` call site rather than to be a
// general-purpose math library.

#include <cmath>

namespace umeshcore {

struct Vec2 {
    float x = 0.0f;
    float y = 0.0f;

    constexpr Vec2() = default;
    constexpr Vec2(float x_, float y_) : x(x_), y(y_) {}
    static constexpr Vec2 zero() { return Vec2(0.0f, 0.0f); }
    static constexpr Vec2 one() { return Vec2(1.0f, 1.0f); }

    constexpr Vec2 operator+(const Vec2& o) const { return {x + o.x, y + o.y}; }
    constexpr Vec2 operator-(const Vec2& o) const { return {x - o.x, y - o.y}; }
    constexpr Vec2 operator-() const { return {-x, -y}; }
    constexpr Vec2 operator*(const Vec2& o) const { return {x * o.x, y * o.y}; }
    constexpr Vec2 operator*(float s) const { return {x * s, y * s}; }
    constexpr Vec2 operator/(float s) const { return {x / s, y / s}; }
    Vec2& operator+=(const Vec2& o) { x += o.x; y += o.y; return *this; }
    Vec2& operator-=(const Vec2& o) { x -= o.x; y -= o.y; return *this; }
    Vec2& operator*=(float s) { x *= s; y *= s; return *this; }
    constexpr bool operator==(const Vec2& o) const { return x == o.x && y == o.y; }
    constexpr bool operator!=(const Vec2& o) const { return !(*this == o); }
};

inline constexpr Vec2 operator*(float s, const Vec2& v) { return v * s; }
inline float dot(const Vec2& a, const Vec2& b) { return a.x * b.x + a.y * b.y; }
inline float length(const Vec2& v) { return std::sqrt(dot(v, v)); }
inline float lengthSquared(const Vec2& v) { return dot(v, v); }
inline Vec2 normalize(const Vec2& v) {
    const float len = length(v);
    return len > 0.0f ? v / len : Vec2::zero();
}
// Matches Swift `simd_mix(a, b, t)` component-wise lerp used throughout the
// animation/skinning code.
inline Vec2 mix(const Vec2& a, const Vec2& b, float t) { return a + (b - a) * t; }
inline float cross(const Vec2& a, const Vec2& b) { return a.x * b.y - a.y * b.x; }

struct Vec3 {
    float x = 0.0f;
    float y = 0.0f;
    float z = 0.0f;

    constexpr Vec3() = default;
    constexpr Vec3(float x_, float y_, float z_) : x(x_), y(y_), z(z_) {}
    static constexpr Vec3 zero() { return Vec3(0.0f, 0.0f, 0.0f); }
    static constexpr Vec3 one() { return Vec3(1.0f, 1.0f, 1.0f); }

    constexpr Vec3 operator+(const Vec3& o) const { return {x + o.x, y + o.y, z + o.z}; }
    constexpr Vec3 operator-(const Vec3& o) const { return {x - o.x, y - o.y, z - o.z}; }
    constexpr Vec3 operator-() const { return {-x, -y, -z}; }
    constexpr Vec3 operator*(const Vec3& o) const { return {x * o.x, y * o.y, z * o.z}; }
    constexpr Vec3 operator*(float s) const { return {x * s, y * s, z * s}; }
    constexpr Vec3 operator/(float s) const { return {x / s, y / s, z / s}; }
    Vec3& operator+=(const Vec3& o) { x += o.x; y += o.y; z += o.z; return *this; }
    Vec3& operator-=(const Vec3& o) { x -= o.x; y -= o.y; z -= o.z; return *this; }
    constexpr bool operator==(const Vec3& o) const { return x == o.x && y == o.y && z == o.z; }
    constexpr bool operator!=(const Vec3& o) const { return !(*this == o); }
};

inline constexpr Vec3 operator*(float s, const Vec3& v) { return v * s; }
inline float dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline float length(const Vec3& v) { return std::sqrt(dot(v, v)); }
inline Vec3 normalize(const Vec3& v) {
    const float len = length(v);
    return len > 0.0f ? v / len : Vec3::zero();
}
inline Vec3 cross(const Vec3& a, const Vec3& b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

struct Vec4 {
    float x = 0.0f;
    float y = 0.0f;
    float z = 0.0f;
    float w = 0.0f;

    constexpr Vec4() = default;
    constexpr Vec4(float x_, float y_, float z_, float w_) : x(x_), y(y_), z(z_), w(w_) {}
    constexpr Vec4(const Vec3& xyz, float w_) : x(xyz.x), y(xyz.y), z(xyz.z), w(w_) {}
    static constexpr Vec4 zero() { return Vec4(0.0f, 0.0f, 0.0f, 0.0f); }

    constexpr Vec3 xyz() const { return {x, y, z}; }

    constexpr Vec4 operator+(const Vec4& o) const { return {x + o.x, y + o.y, z + o.z, w + o.w}; }
    constexpr Vec4 operator-(const Vec4& o) const { return {x - o.x, y - o.y, z - o.z, w - o.w}; }
    constexpr Vec4 operator*(float s) const { return {x * s, y * s, z * s, w * s}; }
    constexpr bool operator==(const Vec4& o) const {
        return x == o.x && y == o.y && z == o.z && w == o.w;
    }

    constexpr float operator[](int i) const {
        return i == 0 ? x : (i == 1 ? y : (i == 2 ? z : w));
    }
    constexpr float& operator[](int i) {
        return i == 0 ? x : (i == 1 ? y : (i == 2 ? z : w));
    }
};

inline constexpr Vec4 operator*(float s, const Vec4& v) { return v * s; }

} // namespace umeshcore
