#pragma once

// Column-major 4x4 matrix matching Swift `simd_float4x4` exactly: same
// column storage order, same `*` semantics for matrix*matrix (matrix_multiply)
// and matrix*vector (matrix_multiply / transform), so that any formula
// transcribed from `MatrixUtilities.swift` reads identically here.

#include <cmath>
#include <utility>

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

// General 4x4 matrix inverse via Gauss-Jordan elimination with partial
// pivoting, matching `simd_inverse`'s general (not affine-specialized)
// semantics -- Bone/Skeleton world matrices are always affine in practice,
// but this is correct for any invertible 4x4, same as the Swift call sites
// expect. Deliberately implemented as textbook elimination (rather than a
// hand-transcribed cofactor-expansion formula) since a transposed index
// in 16 lines of cofactor arithmetic is exactly the class of silent bug
// this port most needs to avoid; correctness is covered by round-trip
// tests (M * inverse(M) == identity) across translation/rotation/scale/
// skew composites in MathTests.cpp.
inline Mat4 inverse(const Mat4& m) {
    // a: the matrix in row-major double precision (rows[r][c]).
    // b: starts as identity, becomes the inverse.
    double a[4][4];
    double b[4][4];
    for (int r = 0; r < 4; ++r) {
        for (int c = 0; c < 4; ++c) {
            a[r][c] = static_cast<double>(m.columns[c][r]);
            b[r][c] = (r == c) ? 1.0 : 0.0;
        }
    }

    for (int col = 0; col < 4; ++col) {
        int pivotRow = col;
        double best = std::abs(a[col][col]);
        for (int r = col + 1; r < 4; ++r) {
            if (std::abs(a[r][col]) > best) {
                best = std::abs(a[r][col]);
                pivotRow = r;
            }
        }
        if (best < 1e-12) {
            return Mat4::identity(); // singular: same fallback as a zero determinant.
        }
        if (pivotRow != col) {
            for (int c = 0; c < 4; ++c) {
                std::swap(a[col][c], a[pivotRow][c]);
                std::swap(b[col][c], b[pivotRow][c]);
            }
        }
        const double pivot = a[col][col];
        for (int c = 0; c < 4; ++c) {
            a[col][c] /= pivot;
            b[col][c] /= pivot;
        }
        for (int r = 0; r < 4; ++r) {
            if (r == col) continue;
            const double factor = a[r][col];
            if (factor == 0.0) continue;
            for (int c = 0; c < 4; ++c) {
                a[r][c] -= factor * a[col][c];
                b[r][c] -= factor * b[col][c];
            }
        }
    }

    Mat4 result;
    for (int c = 0; c < 4; ++c) {
        result.columns[c] = Vec4(
            static_cast<float>(b[0][c]), static_cast<float>(b[1][c]), static_cast<float>(b[2][c]),
            static_cast<float>(b[3][c]));
    }
    return result;
}

} // namespace umeshcore
