#pragma once

// 1:1 port of `Data/MeshKernel.swift`.
//
// The one triangulation path in UltraMesh. The pipeline (bridgeHoles ->
// earClip -> splitInsert -> lawsonFlips) cannot produce a gap in the mesh
// BY CONSTRUCTION -- each step is individually area-preserving. When an
// input cannot be triangulated without losing a vertex, `triangulate`
// throws instead of returning a partial result, so the caller can leave
// the mesh unchanged. Do not "simplify" any step to a version that trades
// this structural guarantee for a post-hoc check; that's exactly the bug
// class this design replaced (see the Swift source's header comment).

#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "umeshcore/Math/Vec.h"

namespace umeshcore::MeshKernel {

enum class Failure {
    RingTooSmall,
    RingSelfIntersecting,
    RingFoldsBack,
    HoleRingTooSmall,
    HoleRingSelfIntersecting,
    CannotTileWithoutLosingVertex,
    DidNotConverge,
    TooManyVertices,
};

// Thrown by `triangulate` and `earClip`. `vertexCount` is only meaningful
// for Failure::TooManyVertices.
struct TriangulationError : std::runtime_error {
    Failure failure;
    int vertexCount = 0;

    explicit TriangulationError(Failure f, int vertexCount_ = 0)
        : std::runtime_error(describe(f, vertexCount_)), failure(f), vertexCount(vertexCount_) {}

    static std::string describe(Failure f, int vertexCount) {
        switch (f) {
            case Failure::RingTooSmall: return "The outline needs at least three points.";
            case Failure::RingSelfIntersecting: return "The outline crosses itself.";
            case Failure::RingFoldsBack:
                return "The outline doubles back on itself, so part of it encloses no area.";
            case Failure::HoleRingTooSmall: return "A hole needs at least three points.";
            case Failure::HoleRingSelfIntersecting: return "A hole outline crosses itself.";
            case Failure::CannotTileWithoutLosingVertex:
                return "This shape cannot be filled without dropping a point.";
            case Failure::DidNotConverge: return "The outline could not be filled.";
            case Failure::TooManyVertices:
                return "A mesh cannot have more than 65535 points (this one has " +
                       std::to_string(vertexCount) + ").";
        }
        return "Unknown triangulation failure.";
    }
};

// An outer ring plus any number of hole rings, as indices into a point array.
struct Boundary {
    std::vector<int> outer;
    std::vector<std::vector<int>> holes;
};

// Triangulate a region. Returns a flat index list wound counter-clockwise.
// Throws TriangulationError on failure.
//
// `points` is never reordered, moved or renumbered, so bone weights and
// deform keyframes stay addressed by the same index. `constraints` are
// edges the Lawson pass must not flip away.
std::vector<std::uint16_t> triangulate(
    const std::vector<Vec2>& points, const Boundary& boundary,
    const std::vector<int>& interior = {},
    const std::vector<std::pair<int, int>>& constraints = {}, bool improve = true);

// --- Polygon helpers (exposed for MeshValidator and tests) ---

// Twice the signed area of a ring. Positive means counter-clockwise.
double signedArea2(const std::vector<Vec2>& points, const std::vector<int>& ring);
double polygonArea(const std::vector<Vec2>& points, const std::vector<int>& ring);

// Even-odd containment test against a ring.
bool pointInRing(const std::vector<Vec2>& points, const std::vector<int>& ring, const Vec2& p);

// Closed containment: a point exactly on an edge counts as inside.
bool pointInTriangle(const std::vector<Vec2>& points, int ia, int ib, int ic, const Vec2& p);

// --- Pipeline stages (exposed for MeshValidator and tests) ---

// 1. Join every hole ring into the outer ring with a zero-width channel,
// producing one simple polygon the ear clipper can tile directly.
std::vector<int> bridgeHoles(
    const std::vector<Vec2>& points, const std::vector<int>& outer,
    const std::vector<std::vector<int>>& holes);

// 2. Tile a simple polygon exactly (throws TriangulationError on failure).
std::vector<int> earClip(const std::vector<Vec2>& points, const std::vector<int>& ring);

// Shortest interior diagonal of the ring, as a pair of ring positions
// (i < j, non-adjacent both ways), or nullopt if the ring admits none.
std::optional<std::pair<int, int>> findDiagonal(
    const std::vector<Vec2>& points, const std::vector<int>& ring);

// Put back any ring vertex the clipper tiled around instead of through
// (a vertex collinear with its two ring neighbours contributes zero area
// and can be silently dropped by ear clipping otherwise).
std::vector<int> absorbOrphanRingVertices(
    const std::vector<Vec2>& points, const std::vector<int>& ring,
    const std::vector<int>& triangles);

// 3. Split the triangle containing a point into three (area-preserving).
std::vector<int> splitInsert(
    const std::vector<Vec2>& points, const std::vector<int>& triangles, int pointIndex);

// 4. Improve triangle shape without changing the covered region: swap the
// diagonal of a strictly-convex quad toward Delaunay. Every violating edge
// found in a pass is flipped (not just the first), for up to `maxPasses`
// passes -- do not "optimize" this to stop at the first flip, see the
// Swift source's measured regression from doing that.
std::vector<int> lawsonFlips(
    const std::vector<Vec2>& points, const std::vector<int>& triangles,
    const std::vector<std::pair<int, int>>& constrained, int maxPasses = 256);

} // namespace umeshcore::MeshKernel
