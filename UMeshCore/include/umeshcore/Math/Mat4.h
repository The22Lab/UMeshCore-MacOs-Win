#pragma once

// Column-major 4x4 matrix matching Swift `simd_float4x4` exactly: same
// column storage order, same `*` semantics for matrix*matrix (matrix_multiply)
// and matrix*vector (matrix_multiply / transform), so that any formula
// transcribed from `MatrixUtilities.swift` reads identically here.

#include "umeshcore/Math/Vec.h"

namespace umeshcore {

struct Mat4 {
    // columns[c] is the c-th column of the matrix, i.e. Mat4 * Vec4(1,0,0,0) == columns[0].
    Vec4 columns[4];

    constexpr Mat4() = default;
    constexpr Mat4(const Vec4& c0, const Vec4& c1, const Vec4& c2, const Vec4& c3)
        : columns{c0, c1, c2, c3} {}

    static constexpr Mat4 identity() {
        return Mat4(
            Vec4(1, 0, 0, 0),
            Vec4(0, 1, 0, 0),
            Vec4(0, 0, 1, 0),
            Vec4(0, 0, 0, 1));
    }

    static constexpr Mat4 diagonal(const Vec4& d) {
        return Mat4(
            Vec4(d.x, 0, 0, 0),
            Vec4(0, d.y, 0, 0),
            Vec4(0, 0, d.z, 0),
            Vec4(0, 0, 0, d.w));
    }
};

// Matrix * vector: r = sum_c columns[c] * v[c] (columns are the basis images).
inline Vec4 operator*(const Mat4& m, const Vec4& v) {
    return m.columns[0] * v.x + m.columns[1] * v.y + m.columns[2] * v.z + m.columns[3] * v.w;
}

// Matrix * matrix: result column j = lhs * rhs.columns[j]. Satisfies
// (A * B) * v == A * (B * v), matching Swift's `simd_float4x4 * simd_float4x4`.
inline Mat4 operator*(const Mat4& lhs, const Mat4& rhs) {
    return Mat4(
        lhs * rhs.columns[0],
        lhs * rhs.columns[1],
        lhs * rhs.columns[2],
        lhs * rhs.columns[3]);
}

inline bool operator==(const Mat4& a, const Mat4& b) {
    return a.columns[0] == b.columns[0] && a.columns[1] == b.columns[1] &&
           a.columns[2] == b.columns[2] && a.columns[3] == b.columns[3];
}

} // namespace umeshcore
