import Foundation
import simd

/// The geometric questions the mesh kernel is allowed to ask.
///
/// Every geometric decision in the meshing code routes through this type.
/// Nothing else may compare coordinates against a hand-picked epsilon — the
/// scattered `1e-9`, `0.35` and `epsilon: 4.0` constants in the old path are
/// exactly why the same outline could triangulate one way in one place and a
/// different way in another.
///
/// `orient2d` is **exact**. It decides topology: whether a vertex is an ear,
/// whether a diagonal runs inside the outline, whether a ring is simple, the
/// winding of every emitted triangle. A wrong sign here does not give a slightly
/// wrong mesh, it gives a corrupt one — crossing triangles, a cavity that never
/// closes, a lost vertex.
///
/// The exactness argument, and why this is only a dozen lines instead of the
/// several hundred a general exact predicate needs:
///
///     orient2d = (ax-cx)(by-cy) - (ay-cy)(bx-cx)
///
/// expands into six monomials once the two `cx*cy` terms cancel algebraically:
///
///     ax*by - ax*cy - cx*by - ay*bx + ay*cx + cy*bx
///
/// Mesh vertices are `SIMD2<Float>`. A `Float` has a 24-bit significand, so each
/// of those six products needs 48 bits and lands *exactly* in a `Double`, whose
/// significand is 53 bits, with the exponent nowhere near overflow. All six
/// terms are therefore exact, and the only remaining problem is summing six
/// exact doubles exactly — which `exactSum` below does with Knuth's error-free
/// transformation. No FMA, no expansion products, no error bounds, no BigInt.
///
/// The argument depends on the input being `Float`. That is why the API takes
/// `SIMD2<Float>` and not `SIMD2<Double>`: hand it doubles that are not
/// representable as floats and the products stop being exact and it silently
/// becomes approximate.
///
/// Verified in `Meshing/verify_expansion.py` against exact rational arithmetic
/// over 200 000 random triples, 50 000 exactly-collinear ones and 50 000 sitting
/// a single Float ulp off the line: zero disagreements.
///
/// Recorded honestly: in that same harness the plain double determinant never
/// disagreed either, at any coordinate spread up to 2^64. For `Float` input it
/// is already exact in practice. The expansion is kept because it costs a
/// handful of additions and makes the guarantee unconditional instead of
/// dependent on the caller's coordinate range — not because it was observed to
/// rescue anything.
enum MeshPredicates {

    // MARK: - Error-free transformations

    /// Exact sum: returns `(s, e)` with `s == a + b` rounded and `a + b == s + e`
    /// exactly. Knuth's transformation, which assumes nothing about the relative
    /// magnitudes of `a` and `b`.
    @inline(__always)
    static func twoSum(_ a: Double, _ b: Double) -> (sum: Double, error: Double) {
        let s = a + b
        let bv = s - a
        let av = s - bv
        return (s, (a - av) + (b - bv))
    }

    /// Exact sum of exactly-representable doubles, as a non-overlapping expansion
    /// ordered smallest to largest in magnitude.
    ///
    /// Each new term is swept through the accumulated components and every
    /// rounding error is captured rather than discarded, so nothing is lost.
    @inline(__always)
    static func exactSum(_ terms: [Double]) -> [Double] {
        var expansion: [Double] = []
        expansion.reserveCapacity(terms.count)

        for term in terms {
            var carry = term
            var out: [Double] = []
            out.reserveCapacity(expansion.count + 1)
            for component in expansion {
                let (sum, error) = twoSum(carry, component)
                carry = sum
                if error != 0 { out.append(error) }
            }
            if carry != 0 { out.append(carry) }
            expansion = out
        }
        return expansion
    }

    /// Sign of an expansion: the sign of its largest component.
    ///
    /// Components are non-overlapping and ordered increasing in magnitude, so
    /// the last one dominates the sum of all the others and decides the sign.
    @inline(__always)
    static func expansionSign(_ expansion: [Double]) -> Double {
        guard let largest = expansion.last else { return 0 }
        if largest > 0 { return 1 }
        if largest < 0 { return -1 }
        return 0
    }

    // MARK: - orient2d (exact)

    /// Sign of the area of triangle `(a, b, c)`.
    ///
    /// Returns `> 0` when `c` lies left of the directed line `a -> b`
    /// (counter-clockwise), `< 0` when right, and exactly `0` when the three
    /// points are collinear. The magnitude carries no meaning; only the sign does.
    @inline(__always)
    static func orient2d(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Double {
        let ax = Double(a.x), ay = Double(a.y)
        let bx = Double(b.x), by = Double(b.y)
        let cx = Double(c.x), cy = Double(c.y)

        // Six exact products. The `cx*cy` pair present in the factored form
        // cancels algebraically and is simply never computed.
        return expansionSign(exactSum([
            ax * by, -(ax * cy), -(cx * by), -(ay * bx), ay * cx, cy * bx
        ]))
    }

    /// Twice the signed area of a triangle. Exact sign, but the magnitude is a
    /// plain double — use it for area sums, never for a sign decision.
    @inline(__always)
    static func signedArea2(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Double {
        (Double(b.x) - Double(a.x)) * (Double(c.y) - Double(a.y))
            - (Double(c.x) - Double(a.x)) * (Double(b.y) - Double(a.y))
    }

    // MARK: - incircle (filtered)

    /// Is `d` inside the circle through `a`, `b`, `c`?
    ///
    /// Returns `> 0` strictly inside, `< 0` outside, `0` cocircular. Assumes
    /// `(a, b, c)` are counter-clockwise; the caller must normalise the winding
    /// first or the sign inverts.
    ///
    /// This one is **not** exact, deliberately. Its determinant is degree four in
    /// the coordinates, so its monomials are products of four `Float` values —
    /// 96 bits, which does not fit a `Double`, and the trick that makes
    /// `orient2d` short does not extend.
    ///
    /// It does not need to be exact. Look at what it decides: only which of the
    /// two diagonals of a convex quad the Lawson pass prefers. Whatever it
    /// answers, `MeshKernel.lawsonFlips` swaps the diagonal of a strictly convex
    /// quad and nothing else, so the union of the two triangles is identical
    /// before and after — area, coverage and watertightness are untouched by
    /// definition, and the pass count is bounded so no answer can cause a loop.
    /// Convexity itself is checked with the exact `orient2d` before any flip is
    /// applied. A near-zero misjudgment here costs at most one slightly
    /// worse-shaped triangle.
    @inline(__always)
    static func incircle(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>
    ) -> Double {
        let adx = Double(a.x) - Double(d.x), ady = Double(a.y) - Double(d.y)
        let bdx = Double(b.x) - Double(d.x), bdy = Double(b.y) - Double(d.y)
        let cdx = Double(c.x) - Double(d.x), cdy = Double(c.y) - Double(d.y)

        let bdxcdy = bdx * cdy, cdxbdy = cdx * bdy
        let cdxady = cdx * ady, adxcdy = adx * cdy
        let adxbdy = adx * bdy, bdxady = bdx * ady

        let alift = adx * adx + ady * ady
        let blift = bdx * bdx + bdy * bdy
        let clift = cdx * cdx + cdy * cdy

        return alift * (bdxcdy - cdxbdy)
            + blift * (cdxady - adxcdy)
            + clift * (adxbdy - bdxady)
    }

    // MARK: - Derived tests, built strictly on the two predicates above

    /// True when the open segments cross. Shared endpoints do not count.
    ///
    /// This is the right test for a diagonal against the edges it shares a
    /// corner with, and the wrong test for deciding whether a ring is a legal
    /// polygon — see `segmentsTouchOrCross`.
    @inline(__always)
    static func segmentsProperlyIntersect(
        _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ q1: SIMD2<Float>, _ q2: SIMD2<Float>
    ) -> Bool {
        let d1 = orient2d(p1, p2, q1)
        let d2 = orient2d(p1, p2, q2)
        let d3 = orient2d(q1, q2, p1)
        let d4 = orient2d(q1, q2, p2)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }

    /// Inclusive segment intersection: touching and overlap count as meeting.
    ///
    /// Two edges lying on top of each other never cross transversally, so a
    /// proper-intersection test calls a folded-over outline simple. That is how
    /// a degenerate ring reached the triangulator and lost a vertex.
    @inline(__always)
    static func segmentsTouchOrCross(
        _ a1: SIMD2<Float>, _ a2: SIMD2<Float>, _ b1: SIMD2<Float>, _ b2: SIMD2<Float>
    ) -> Bool {
        let d1 = orient2d(a1, a2, b1)
        let d2 = orient2d(a1, a2, b2)
        let d3 = orient2d(b1, b2, a1)
        let d4 = orient2d(b1, b2, a2)
        if ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0)) { return true }
        return (d1 == 0 && pointOnSegment(b1, a1, a2))
            || (d2 == 0 && pointOnSegment(b2, a1, a2))
            || (d3 == 0 && pointOnSegment(a1, b1, b2))
            || (d4 == 0 && pointOnSegment(a2, b1, b2))
    }

    /// True when `p` lies exactly on the closed segment `ab`.
    @inline(__always)
    static func pointOnSegment(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool {
        guard orient2d(a, b, p) == 0 else { return false }
        return p.x >= min(a.x, b.x) && p.x <= max(a.x, b.x)
            && p.y >= min(a.y, b.y) && p.y <= max(a.y, b.y)
    }
}
