// Tests for the edit-time half of Mesh (Phase 6a): bind fit, manual
// bind/unbind, generation, vertex insertion/removal, manual faces and hull
// clamping. Expected values are derived by hand from the geometry; the
// structural properties (every edit leaves a VALID mesh or refuses) are
// checked with the validator the kernel answers to.

#include "umeshcore/Mesh/Mesh.h"

#include <algorithm>

#include "TestHarness.h"

using namespace umeshcore;

namespace {

// A mesh whose outline is `ring` (in order) and which has been filled by
// the kernel.
Mesh outlined(const std::vector<Vec2>& ring, const Vec2& size = Vec2(100, 100)) {
    Mesh m("m");
    m.vertices = ring;
    for (const Vec2& v : ring) m.uvs.push_back(Mesh::uvFor(v, size));
    for (std::size_t i = 0; i < ring.size(); ++i) m.hullVertexIndices.push_back(static_cast<std::uint16_t>(i));
    return m.retriangulated();
}

Mesh square(float half) {
    return outlined({Vec2(-half, -half), Vec2(half, -half), Vec2(half, half), Vec2(-half, half)});
}

} // namespace

// ---- Bind fit ------------------------------------------------------------------

static void testTheFitReadsTheThreeWaysABoneCanOwnASprite() {
    const Mesh m = square(50);
    // Along: a bone twice the sprite's width crossing it.
    const Mesh::BoneFit across = m.fit(Vec2(-100, 0), Vec2(100, 0), std::nullopt);
    UM_CHECK_NEAR(across.overlap, 100.0, 1e-3);
    UM_CHECK_NEAR(across.boneFraction, 0.5, 1e-6);
    UM_CHECK_NEAR(across.crossFraction, 1.0, 1e-6); // used the whole crossing on offer
    UM_CHECK(!across.originInside);

    // Rooted: a short bone whose joint is inside.
    const Mesh::BoneFit rooted = m.fit(Vec2(0, 0), Vec2(0, 10), std::nullopt);
    UM_CHECK(rooted.originInside);
    UM_CHECK_NEAR(rooted.boneFraction, 1.0, 1e-6);

    // Nowhere near.
    const Mesh::BoneFit away = m.fit(Vec2(200, 200), Vec2(300, 200), std::nullopt);
    UM_CHECK(away.overlap == 0.0f && !away.originInside);

    // The sprite's pose brings the world bone into the outline's frame:
    // parked at x = 200, the same crossing reads the same.
    MeshBindPose pose;
    pose.position = Vec2(200, 0);
    const Mesh::BoneFit posed = m.fit(Vec2(100, 0), Vec2(300, 0), pose);
    UM_CHECK_NEAR(posed.overlap, 100.0, 1e-3);
}

// Exact on a concave outline: a line through both arms of a U is inside
// exactly the arms' widths, nothing in the gap.
static void testInsideLengthIsExactOnAConcaveOutline() {
    const Mesh u = outlined({Vec2(0, 0), Vec2(30, 0), Vec2(30, 40), Vec2(20, 40), Vec2(20, 10), Vec2(10, 10),
                             Vec2(10, 40), Vec2(0, 40)});
    UM_CHECK_NEAR(u.insideHullLength(Vec2(-5, 20), Vec2(35, 20)), 20.0, 1e-4);
    // Through the base, everything between the outer walls.
    UM_CHECK_NEAR(u.insideHullLength(Vec2(-5, 5), Vec2(35, 5)), 30.0, 1e-4);
}

// ---- Manual bind / unbind -----------------------------------------------------------

static void testBindingByHandKeepsThePaintAndUnbindingForgetsTheBone() {
    Mesh m = square(10);
    const Uuid a(1, 1), b(1, 2);
    m.boneInverseBindMatrices[a] = Mat4::identity();
    m.bindVertices = m.vertices;
    m.vertexBoneWeights.assign(m.vertices.size(), {VertexBoneWeight{a, 1.0f}});

    Mat4 world = Mat4::identity();
    world.columns[3] = Vec4(5, 0, 0, 1);
    const Mesh bound = m.addingBoneInfluence(b, world);
    UM_CHECK(bound.boundBoneIDs().contains(b));
    // Binds, does not paint: every vertex still carries only `a`.
    for (const auto& w : bound.vertexBoneWeights) UM_CHECK(w.size() == 1 && w[0].boneID == a);
    UM_CHECK_NEAR(bound.boneInverseBindMatrices.at(b).columns[3].x, -5.0, 1e-6);

    const Mesh unbound = bound.removingBoneInfluence(a);
    UM_CHECK(!unbound.boundBoneIDs().contains(a));
    for (const auto& w : unbound.vertexBoneWeights) UM_CHECK(w.empty());
    UM_CHECK(unbound.boneInverseBindMatrices.contains(b));
}

// ---- Generation -----------------------------------------------------------------------

static void testAQuadBecomesAFreshThreeByThreeGrid() {
    const Mesh quad = Mesh::makeQuad("q", Vec2(40, 20));
    const Mesh grid = quad.generated(Vec2(40, 20));
    UM_CHECK(grid.vertices.size() == 9);
    UM_CHECK(grid.indices.size() == 8 * 3);
    UM_CHECK(grid.hullVertexIndices == (std::vector<std::uint16_t>{0, 2, 8, 6}));
    UM_CHECK(grid.id != quad.id); // Swift's memberwise init: a new mesh
    UM_CHECK(grid.vertices[4] == Vec2(0, 0)); // the centre
    // As Swift builds it, the outline lists only the four CORNERS while the
    // four edge midpoints lie on it, so the validator reports I5 (outline
    // edges that are not mesh edges). Kept as Swift and pinned here; see
    // MIGRATION.md, "found and not fixed".
    UM_CHECK(!grid.validationReport().isValid());
}

static void testGeneratedInteriorPointsStayInsideAndTheMeshIsValid() {
    const Mesh hexagon = outlined({Vec2(-100, 0), Vec2(-50, -90), Vec2(50, -90), Vec2(100, 0), Vec2(50, 90),
                                   Vec2(-50, 90)},
                                  Vec2(200, 180));
    const Mesh g = hexagon.generated(Vec2(200, 180), 50);
    UM_CHECK(g.vertices.size() > hexagon.vertices.size()); // something was added
    UM_CHECK(g.hullVertexIndices.size() == 6);
    for (std::size_t i = 6; i < g.vertices.size(); ++i) UM_CHECK(hexagon.pointInsideHull(g.vertices[i]));
    UM_CHECK(g.validationReport().isValid());
}

// ---- Vertex insertion and removal ------------------------------------------------------

static void testInsertionRefusesOutsideAndKeepsTheMeshValid() {
    const Mesh m = square(50);
    UM_CHECK(!m.insertingInteriorVertex(Vec2(80, 0), Vec2(100, 100)).has_value());
    const auto inside = m.insertingInteriorVertex(Vec2(10, 5), Vec2(100, 100));
    UM_CHECK(inside.has_value());
    UM_CHECK(inside->insertedIndex == 4);
    UM_CHECK(inside->mesh.validationReport().isValid());
    UM_CHECK(inside->mesh.indices.size() == 4 * 3); // one point splits the square into four

    // On an edge of the outline: the new point joins the ring after edge 0.
    const auto onHull = m.insertingHullVertex(Vec2(0, -50), 0);
    UM_CHECK(onHull.has_value());
    UM_CHECK(onHull->mesh.hullVertexIndices == (std::vector<std::uint16_t>{0, 4, 1, 2, 3}));
    UM_CHECK_NEAR(onHull->mesh.uvs[4].x, 0.5, 1e-6); // halfway along, halfway in u
    UM_CHECK(onHull->mesh.validationReport().isValid());
}

// Removing a vertex rewrites per-vertex data through the remap, so a deform
// key keeps pointing at the right vertices.
static void testRemovalRemapsPerVertexDataAndRefusesATornOutline() {
    const Mesh base = square(50);
    // (-10, 5) stays inside the triangle left when corner 1 goes.
    const Mesh withPoint = base.insertingInteriorVertex(Vec2(-10, 5), Vec2(100, 100))->mesh;
    const auto change = withPoint.removingVertices({1});
    UM_CHECK(change.has_value());
    UM_CHECK(!change->remap.contains(1));
    UM_CHECK(change->remap.at(4) == 3);
    UM_CHECK(change->mesh.vertices.size() == 4);
    UM_CHECK(change->mesh.validationReport().isValid());

    const std::vector<Vec2> deform{Vec2(0, 0), Vec2(1, 1), Vec2(2, 2), Vec2(3, 3), Vec2(4, 4)};
    const std::vector<Vec2> fallback(4, Vec2(-1, -1));
    const std::vector<Vec2> remapped = change->remapped(deform, fallback);
    UM_CHECK(remapped == (std::vector<Vec2>{Vec2(0, 0), Vec2(2, 2), Vec2(3, 3), Vec2(4, 4)}));

    // Two outline points from a square leave a segment, not a polygon.
    UM_CHECK(!base.removingVertices({0, 1}).has_value());
}

// ---- Edges, faces, clamping ---------------------------------------------------------------

namespace {
bool hasEdge(const Mesh& m, MeshEdge edge) {
    for (std::size_t t = 0; t + 2 < m.indices.size(); t += 3) {
        if (MeshTriangle{m.indices[t], m.indices[t + 1], m.indices[t + 2]}.containsEdge(edge)) return true;
    }
    return false;
}
} // namespace

// What a connected edge IS, in Swift and here: a constraint the kernel's
// Lawson pass must not flip away. On this tall rhombus the ear clip lays
// down the long diagonal 1-3 and Delaunay flips it to the short 0-2;
// constrained, 1-3 stays.
//
// And what it is NOT: the kernel has no edge recovery, so connecting two
// vertices the ear clip did not join records the edge and changes no
// triangle (the square's 0-2, below). Pinned so a future recovery pass is a
// visible change, not a silent one.
static void testAConnectedEdgeIsNeverFlippedAway() {
    const Mesh rhombus = outlined({Vec2(-10, 0), Vec2(0, -50), Vec2(10, 0), Vec2(0, 50)});
    UM_CHECK(hasEdge(rhombus, MeshEdge(0, 2)) && !hasEdge(rhombus, MeshEdge(1, 3)));
    const Mesh kept = rhombus.connectingVertices(1, 3);
    UM_CHECK(kept.internalEdges.size() == 1);
    UM_CHECK(hasEdge(kept, MeshEdge(1, 3)));
    UM_CHECK(kept.validationReport().isValid());
    UM_CHECK(kept.clearingInternalEdges().internalEdges.empty());

    const Mesh sq = square(50);
    const bool had02 = hasEdge(sq, MeshEdge(0, 2));
    const Mesh asked = sq.connectingVertices(0, 2);
    UM_CHECK(asked.internalEdges.size() == 1);
    UM_CHECK(hasEdge(asked, MeshEdge(0, 2)) == had02); // recorded, not inserted

    // A hull edge is not an internal edge.
    UM_CHECK(sq.connectingVertices(0, 1).internalEdges.empty());
}

static void testAFaceMustLieInsideTheOutline() {
    const Mesh u = outlined({Vec2(0, 0), Vec2(30, 0), Vec2(30, 40), Vec2(20, 40), Vec2(20, 10), Vec2(10, 10),
                             Vec2(10, 40), Vec2(0, 40)});
    // Across the gap of the U: refused.
    const Mesh refused = u.creatingFace(7, 2, 3);
    UM_CHECK(refused.manualTriangles.empty());
    // Inside the base: accepted, and wound the way the rest of the mesh is.
    const Mesh accepted = u.creatingFace(0, 1, 5);
    UM_CHECK(accepted.manualTriangles.size() == 1);
    UM_CHECK(u.creatingFace(0, 1, 5).creatingFace(5, 1, 0).manualTriangles.size() == 1); // no duplicate
}

static void testAnInteriorVertexIsClampedBackOntoTheOutline() {
    const Mesh m = square(50).insertingInteriorVertex(Vec2(0, 0), Vec2(100, 100))->mesh;
    const Vec2 clamped = m.clampedPositionInsideHullIfNeeded(4, Vec2(80, 10));
    UM_CHECK_NEAR(clamped.x, 50.0, 1e-5);
    UM_CHECK_NEAR(clamped.y, 10.0, 1e-5);
    // Inside: untouched. A hull vertex: never clamped.
    UM_CHECK(m.clampedPositionInsideHullIfNeeded(4, Vec2(5, 5)) == Vec2(5, 5));
    UM_CHECK(m.clampedPositionInsideHullIfNeeded(0, Vec2(-80, -80)) == Vec2(-80, -80));

    Mesh stray = m;
    stray.vertices[4] = Vec2(0, 90);
    const Mesh fixed = stray.clampingInteriorVerticesInsideHull(Vec2(100, 100));
    UM_CHECK(fixed.vertices[4] == Vec2(0, 50));
    UM_CHECK_NEAR(fixed.uvs[4].y, 0.0, 1e-6); // the top edge is v = 0
}

static void testBarycentricWeightsRebuildThePoint() {
    const Mesh m = square(50);
    const Vec2 p(12, -7);
    const auto s = m.barycentricSample(p);
    UM_CHECK(s.has_value());
    UM_CHECK_NEAR(s->wa + s->wb + s->wc, 1.0, 1e-6);
    const Vec2 rebuilt = m.vertices[static_cast<std::size_t>(s->a)] * s->wa +
                         m.vertices[static_cast<std::size_t>(s->b)] * s->wb +
                         m.vertices[static_cast<std::size_t>(s->c)] * s->wc;
    UM_CHECK_NEAR(rebuilt.x, 12.0, 1e-4);
    UM_CHECK_NEAR(rebuilt.y, -7.0, 1e-4);
    UM_CHECK(!m.barycentricSample(Vec2(70, 0)).has_value());
}

UM_TEST_MAIN_BEGIN()
    testTheFitReadsTheThreeWaysABoneCanOwnASprite();
    testInsideLengthIsExactOnAConcaveOutline();
    testBindingByHandKeepsThePaintAndUnbindingForgetsTheBone();
    testAQuadBecomesAFreshThreeByThreeGrid();
    testGeneratedInteriorPointsStayInsideAndTheMeshIsValid();
    testInsertionRefusesOutsideAndKeepsTheMeshValid();
    testRemovalRemapsPerVertexDataAndRefusesATornOutline();
    testAConnectedEdgeIsNeverFlippedAway();
    testAFaceMustLieInsideTheOutline();
    testAnInteriorVertexIsClampedBackOntoTheOutline();
    testBarycentricWeightsRebuildThePoint();
UM_TEST_MAIN_END()
