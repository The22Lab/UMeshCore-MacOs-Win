// Tests for Auto-Mesh (`Mesh::tracedHull`, Phase 6a A6c) against alpha
// masks drawn by hand, so every expectation is a fact about the drawing:
// the outline covers every opaque pixel, hugs a rectangle to within its
// padding, keeps or drops a notch by the concavity setting, and a PNG with
// two shapes still gives a ring the kernel accepts.

#include "umeshcore/Editor/EditorScene.h"
#include "umeshcore/Mesh/Mesh.h"

#include <algorithm>
#include <cfloat>

#include "TestHarness.h"

using namespace umeshcore;

namespace {

// Opaque pixels [x0, x1) x [y0, y1), y down from the top row.
void fill(AlphaMask& m, int x0, int y0, int x1, int y1, float a = 1.0f) {
    for (int y = y0; y < y1; ++y)
        for (int x = x0; x < x1; ++x) m.set(x, y, a);
}

// The pixel's centre in the sprite's local frame (y up, origin centred).
Vec2 localCentre(int x, int y, const Vec2& size) {
    return Vec2(static_cast<float>(x) + 0.5f - size.x * 0.5f, size.y * 0.5f - (static_cast<float>(y) + 0.5f));
}

struct Box {
    Vec2 min{FLT_MAX, FLT_MAX}, max{-FLT_MAX, -FLT_MAX};
};
Box boxOf(const Mesh& m) {
    Box b;
    for (std::uint16_t i : m.hullVertexIndices) {
        const Vec2 v = m.vertices[i];
        b.min = Vec2(std::min(b.min.x, v.x), std::min(b.min.y, v.y));
        b.max = Vec2(std::max(b.max.x, v.x), std::max(b.max.y, v.y));
    }
    return b;
}

float hullArea(const Mesh& m) {
    float area = 0.0f;
    const auto& h = m.hullVertexIndices;
    for (std::size_t i = 0, j = h.size() - 1; i < h.size(); j = i++) {
        area += m.vertices[h[j]].x * m.vertices[h[i]].y - m.vertices[h[i]].x * m.vertices[h[j]].y;
    }
    return std::fabs(area) * 0.5f;
}

} // namespace

static void testNothingOpaqueFallsBackToTheRectangleAndSaysSo() {
    const Vec2 size(64, 32);
    const AlphaMask empty(64, 32);
    const Mesh traced = Mesh::makeQuad("s", size).tracedHull(size, empty);
    UM_CHECK(traced.isQuadCompatible());

    EditorScene scene;
    const Uuid id = scene.addImage(Uuid::generate(), "s", size, Vec2(0, 0), std::nullopt);
    scene.traceSelectedMesh(size, empty);
    UM_CHECK(scene.image(id)->mesh.isQuadCompatible());
    UM_CHECK(scene.meshEditNotice.has_value() && scene.meshEditNotice->isWarning);
}

// A 40 x 20 opaque rectangle in a 100 x 100 image: local x in [-20, 20],
// y in [-10, 10]. The outline must contain every opaque pixel and sit
// within the padding (1.2, mitred to at most 1.8 at a corner) of the edge.
static void testARectangleIsHuggedWithinItsPadding() {
    const Vec2 size(100, 100);
    AlphaMask mask(100, 100);
    fill(mask, 30, 40, 70, 60);
    const Mesh traced = Mesh::makeQuad("s", size).tracedHull(size, mask);
    UM_CHECK(!traced.isQuadCompatible());
    for (int y = 40; y < 60; ++y)
        for (int x = 30; x < 70; ++x) UM_CHECK(traced.pointInsideHull(localCentre(x, y, size)));
    const Box b = boxOf(traced);
    UM_CHECK(b.min.x >= -20.0f - 1.81f && b.min.x <= -20.0f);
    UM_CHECK(b.max.x <= 20.0f + 1.81f && b.max.x >= 20.0f);
    UM_CHECK(b.min.y >= -10.0f - 1.81f && b.max.y <= 10.0f + 1.81f);
    UM_CHECK(traced.validationReport().isValid());

    EditorScene scene;
    const Uuid id = scene.addImage(Uuid::generate(), "s", size, Vec2(0, 0), std::nullopt);
    scene.traceSelectedMesh(size, mask);
    UM_CHECK(scene.meshEditNotice.has_value() && !scene.meshEditNotice->isWarning);
    UM_CHECK(scene.meshEditNotice->text.find("Auto-Mesh traced") == 0);
    UM_CHECK(scene.image(id)->mesh.hullVertexIndices.size() == traced.hullVertexIndices.size());
}

// An L: concavity 100 keeps the notch, concavity 0 fills it in.
static void testConcavityDecidesWhetherTheNotchSurvives() {
    const Vec2 size(100, 100);
    AlphaMask mask(100, 100);
    fill(mask, 20, 20, 40, 80); // the upright
    fill(mask, 40, 60, 80, 80); // the foot
    const Mesh keepAll = Mesh::makeQuad("s", size).tracedHull(size, mask, 30, 1.2f, 100);
    const Mesh convex = Mesh::makeQuad("s", size).tracedHull(size, mask, 30, 1.2f, 0);
    // Inside the notch, next to its concave corner (pixel 45, 50): outside
    // the L, inside once the corner is cut. (Concavity 0 removes the notch
    // VERTEX, so the fill is the triangle up to the diagonal, not the box.)
    const Vec2 notch = localCentre(45, 50, size);
    UM_CHECK(!keepAll.pointInsideHull(notch));
    UM_CHECK(convex.pointInsideHull(notch));
    UM_CHECK(hullArea(keepAll) < hullArea(convex));
}

// Two separate shapes become ONE ring through a keyhole bridge with width,
// which the kernel accepts -- so the sprite still takes new nodes (the
// zero-width bridge Swift once had made every insertion fail silently).
static void testTwoShapesMakeOneRingThatStillTakesNodes() {
    const Vec2 size(100, 60);
    AlphaMask mask(100, 60);
    fill(mask, 10, 20, 30, 40); // left eye
    fill(mask, 70, 20, 90, 40); // right eye
    const Mesh traced = Mesh::makeQuad("s", size).tracedHull(size, mask);
    for (int x : {10, 29, 70, 89}) UM_CHECK(traced.pointInsideHull(localCentre(x, 30, size)));
    // Both eyes' interiors accept a node.
    UM_CHECK(traced.insertingInteriorVertex(localCentre(20, 30, size), size).has_value());
    UM_CHECK(traced.insertingInteriorVertex(localCentre(80, 30, size), size).has_value());
    // FOUND, NOT FIXED (see MIGRATION.md): Swift says the opaque-area filter
    // drops the triangles spanning the bridge. It drops EVERY triangle -- a
    // traced outline's edges lie on or just outside the opaque pixels (the
    // padding puts them there, and at zero padding the right and bottom
    // edges round onto the first transparent pixel), so each triangle has an
    // edge touching an empty pixel -- and then falls back to the unfiltered
    // fill. The bridge's sliver triangles stay; they sample transparent
    // texels, so nothing shows. Pinned so a working filter is a visible
    // change.
    UM_CHECK(traced.indices == traced.triangulatedHullIndices());
}

UM_TEST_MAIN_BEGIN()
    testNothingOpaqueFallsBackToTheRectangleAndSaysSo();
    testARectangleIsHuggedWithinItsPadding();
    testConcavityDecidesWhetherTheNotchSurvives();
    testTwoShapesMakeOneRingThatStillTakesNodes();
UM_TEST_MAIN_END()
