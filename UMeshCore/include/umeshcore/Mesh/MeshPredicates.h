#pragma once

// 1:1 port of `Data/MeshPredicates.swift`.
//
// `orient2d` is EXACT. It decides topology: whether a vertex is an ear,
// whether a diagonal runs inside the outline, the winding of every emitted
// triangle. A wrong sign does not give a slightly wrong mesh, it gives a
// corrupt one.
//
// The exactness argument (from the Swift source, preserved verbatim since
// it's load-bearing documentation, not decoration): orient2d expands into
// six monomials once the two cx*cy terms cancel algebraically. Mesh
// vertices are `float` (24-bit significand), so each of the six products
// needs 48 bits and lands EXACTLY in a `double` (53-bit significand), with
// the exponent nowhere near overflow -- so summing six exact doubles
// exactly (via Knuth's error-free transformation, `exactSum` below) is the
// whole proof. THIS DEPENDS ON THE INPUT BEING float, NOT double: hand it
// doubles that are not exactly representable as float and the products
// stop being exact and this silently becomes approximate. Do not "upgrade"
// mesh vertex coordinates to double for precision -- that would break this
// guarantee, not strengthen it. See UMeshCore/ROADMAP.md risk #3.

#include <algorithm>
#include <vector>

#include "umeshcore/Math/Vec.h"

namespace umeshcore::MeshPredicates {

// Exact sum: returns (sum, error) with sum == a+b rounded and
// a+b == sum+error exactly. Knuth's transformation; assumes nothing about
// the relative magnitudes of a and b.
inline void twoSum(double a, double b, double& sum, double& error) {
    sum = a + b;
    const double bv = sum - a;
    const double av = sum - bv;
    error = (a - av) + (b - bv);
}

// Exact sum of exactly-representable doubles, as a non-overlapping
// expansion ordered smallest to largest in magnitude. Each new term is
// swept through the accumulated components and every rounding error is
// captured rather than discarded.
inline std::vector<double> exactSum(const std::vector<double>& terms) {
    std::vector<double> expansion;
    expansion.reserve(terms.size());

    for (double term : terms) {
        double carry = term;
        std::vector<double> out;
        out.reserve(expansion.size() + 1);
        for (double component : expansion) {
            double sum, error;
            twoSum(carry, component, sum, error);
            carry = sum;
            if (error != 0.0) out.push_back(error);
        }
        if (carry != 0.0) out.push_back(carry);
        expansion = std::move(out);
    }
    return expansion;
}

// Sign of an expansion: the sign of its largest component. Components are
// non-overlapping and ordered increasing in magnitude, so the last one
// dominates the sum of all the others and decides the sign.
inline double expansionSign(const std::vector<double>& expansion) {
    if (expansion.empty()) return 0.0;
    const double largest = expansion.back();
    if (largest > 0.0) return 1.0;
    if (largest < 0.0) return -1.0;
    return 0.0;
}

// Sign of the area of triangle (a, b, c). Returns > 0 when c lies left of
// the directed line a->b (counter-clockwise), < 0 when right, exactly 0
// when the three points are collinear. Magnitude carries no meaning, only
// the sign does. EXACT (see file header).
inline double orient2d(const Vec2& a, const Vec2& b, const Vec2& c) {
    const double ax = static_cast<double>(a.x), ay = static_cast<double>(a.y);
    const double bx = static_cast<double>(b.x), by = static_cast<double>(b.y);
    const double cx = static_cast<double>(c.x), cy = static_cast<double>(c.y);

    // Six exact products. The cx*cy pair present in the factored form
    // cancels algebraically and is simply never computed.
    return expansionSign(exactSum({ax * by, -(ax * cy), -(cx * by), -(ay * bx), ay * cx, cy * bx}));
}

// Twice the signed area of a triangle. Exact SIGN, but the magnitude is a
// plain double -- use for area sums, never for a sign decision.
inline double signedArea2(const Vec2& a, const Vec2& b, const Vec2& c) {
    return (static_cast<double>(b.x) - static_cast<double>(a.x)) *
               (static_cast<double>(c.y) - static_cast<double>(a.y)) -
           (static_cast<double>(c.x) - static_cast<double>(a.x)) *
               (static_cast<double>(b.y) - static_cast<double>(a.y));
}

// Is `d` inside the circle through a, b, c? > 0 strictly inside, < 0
// outside, 0 cocircular. Assumes (a,b,c) counter-clockwise.
//
// NOT exact, deliberately: the determinant is degree four in the
// coordinates (96-bit products), which doesn't fit a double, and the
// exactSum trick doesn't extend. It doesn't need to be exact -- it only
// decides which diagonal of a convex quad the Lawson pass prefers, and
// that swap is area/coverage-preserving by construction regardless of
// which way this leans; see MeshKernel's lawsonFlips.
inline double incircle(const Vec2& a, const Vec2& b, const Vec2& c, const Vec2& d) {
    const double adx = static_cast<double>(a.x) - static_cast<double>(d.x);
    const double ady = static_cast<double>(a.y) - static_cast<double>(d.y);
    const double bdx = static_cast<double>(b.x) - static_cast<double>(d.x);
    const double bdy = static_cast<double>(b.y) - static_cast<double>(d.y);
    const double cdx = static_cast<double>(c.x) - static_cast<double>(d.x);
    const double cdy = static_cast<double>(c.y) - static_cast<double>(d.y);

    const double bdxcdy = bdx * cdy, cdxbdy = cdx * bdy;
    const double cdxady = cdx * ady, adxcdy = adx * cdy;
    const double adxbdy = adx * bdy, bdxady = bdx * ady;

    const double alift = adx * adx + ady * ady;
    const double blift = bdx * bdx + bdy * bdy;
    const double clift = cdx * cdx + cdy * cdy;

    return alift * (bdxcdy - cdxbdy) + blift * (cdxady - adxcdy) + clift * (adxbdy - bdxady);
}

// True when p lies exactly on the closed segment ab.
inline bool pointOnSegment(const Vec2& p, const Vec2& a, const Vec2& b) {
    if (orient2d(a, b, p) != 0.0) return false;
    return p.x >= std::min(a.x, b.x) && p.x <= std::max(a.x, b.x) && p.y >= std::min(a.y, b.y) &&
           p.y <= std::max(a.y, b.y);
}

// True when the OPEN segments cross. Shared endpoints do not count. The
// right test for a diagonal against edges sharing a corner with it; the
// wrong test for deciding whether a ring is a legal polygon (see below).
inline bool segmentsProperlyIntersect(const Vec2& p1, const Vec2& p2, const Vec2& q1, const Vec2& q2) {
    const double d1 = orient2d(p1, p2, q1);
    const double d2 = orient2d(p1, p2, q2);
    const double d3 = orient2d(q1, q2, p1);
    const double d4 = orient2d(q1, q2, p2);
    return ((d1 > 0.0) != (d2 > 0.0)) && ((d3 > 0.0) != (d4 > 0.0));
}

// Inclusive segment intersection: touching and overlap count as meeting.
// Two edges lying on top of each other never cross transversally, so a
// proper-intersection test alone calls a folded-over outline simple.
inline bool segmentsTouchOrCross(const Vec2& a1, const Vec2& a2, const Vec2& b1, const Vec2& b2) {
    const double d1 = orient2d(a1, a2, b1);
    const double d2 = orient2d(a1, a2, b2);
    const double d3 = orient2d(b1, b2, a1);
    const double d4 = orient2d(b1, b2, a2);
    if (((d1 > 0.0) != (d2 > 0.0)) && ((d3 > 0.0) != (d4 > 0.0))) return true;
    return (d1 == 0.0 && pointOnSegment(b1, a1, a2)) || (d2 == 0.0 && pointOnSegment(b2, a1, a2)) ||
           (d3 == 0.0 && pointOnSegment(a1, b1, b2)) || (d4 == 0.0 && pointOnSegment(a2, b1, b2));
}

} // namespace umeshcore::MeshPredicates
