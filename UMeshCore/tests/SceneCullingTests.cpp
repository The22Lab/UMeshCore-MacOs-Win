// Tests for Render/SceneCulling.h, ported from `Render/SceneCulling.swift`.
//
// The Swift header states the contract in terms of a one-directional
// error, so these assert THAT rather than re-deriving plane coefficients:
//
//   - Anything the projection would actually draw is never culled. This is
//     checked against `SceneProjection` itself over thousands of random
//     cameras and points, because the whole reason the planes are
//     extracted from the view-projection matrix is that they must agree
//     with the matrix the drawing divides by.
//   - Something outside a single plane IS culled (otherwise the culler
//     does nothing), including behind the eye -- the case a transposed
//     row extraction gets backwards.
//   - The far plane is honoured by the culler AND by `clipAndProject`,
//     the disagreement the Swift file records as 51 layers out of 20 000
//     that were culled while putting pixels on the canvas.
//
// `Editor/verify_scene_culling.py`, which the Swift header cites for those
// figures, does not exist in this repository (see CLAUDE.md), so the 1.3%
// / 51-layer numbers cannot be reproduced here; the properties they were
// measuring are what is pinned instead.

#include "umeshcore/Render/SceneCulling.h"

#include <cmath>
#include <vector>

#include "umeshcore/Render/SceneProjection.h"

#include "TestHarness.h"

using namespace umeshcore;

namespace {

constexpr float kNear = 1.0f;
constexpr float kFar = 5000.0f;

SceneProjection camera(float pitch = 0.0f, float yaw = 0.0f) {
    return SceneProjection(Vec3(0, 0, -500), pitch, yaw, 0.0f, 60.0f, kNear, kFar, Vec2(1000, 800));
}

std::vector<Vec3> box(const Vec3& centre, float halfSize) {
    std::vector<Vec3> hull;
    for (int i = 0; i < 8; ++i) {
        hull.push_back(Vec3(
            centre.x + ((i & 1) ? halfSize : -halfSize), centre.y + ((i & 2) ? halfSize : -halfSize),
            centre.z + ((i & 4) ? halfSize : -halfSize)));
    }
    return hull;
}

// Deterministic, dependency-free: the harness has no RNG and the point is
// coverage, not statistics.
struct Lcg {
    unsigned int state = 12345u;
    float next(float lo, float hi) {
        state = state * 1664525u + 1013904223u;
        const float unit = static_cast<float>((state >> 8) & 0xFFFFFFu) / 16777215.0f;
        return lo + unit * (hi - lo);
    }
};

} // namespace

static void testAPointOnScreenIsNeverCulled() {
    Lcg rng;
    int drawn = 0;
    for (int trial = 0; trial < 4000; ++trial) {
        const SceneProjection p = camera(rng.next(-1.2f, 1.2f), rng.next(-3.2f, 3.2f));
        const SceneFrustum frustum(p.viewProjection());
        const Vec3 world(rng.next(-3000, 3000), rng.next(-3000, 3000), rng.next(-3000, 3000));
        const auto screen = p.project(world);
        const bool onScreen = screen.has_value() && screen->x >= 0.0f && screen->x <= 1000.0f &&
                              screen->y >= 0.0f && screen->y <= 800.0f && p.depth(world) <= kFar;
        if (!onScreen) continue;
        ++drawn;
        // The asymmetric rule: keeping something invisible is waste,
        // discarding something visible is an object vanishing.
        UM_CHECK(!frustum.culls({world}));
    }
    // Guard against the test passing because nothing was ever visible.
    UM_CHECK(drawn > 200);
}

static void testSomethingWellOutsideIsActuallyCulled() {
    const SceneProjection p = camera();
    const SceneFrustum frustum(p.viewProjection());
    UM_CHECK(frustum.culls(box(Vec3(100000, 0, 1000), 10)));   // far right
    UM_CHECK(frustum.culls(box(Vec3(-100000, 0, 1000), 10)));  // far left
    UM_CHECK(frustum.culls(box(Vec3(0, 100000, 1000), 10)));   // far above
    UM_CHECK(frustum.culls(box(Vec3(0, -100000, 1000), 10)));  // far below
    // In front of the eye and on axis: kept.
    UM_CHECK(!frustum.culls(box(Vec3(0, 0, 0), 10)));
}

static void testBehindTheEyeIsCulled() {
    // The case a transposed row extraction gets exactly backwards: it
    // culls what is in front and keeps what is behind.
    const SceneProjection p = camera();
    const SceneFrustum frustum(p.viewProjection());
    UM_CHECK(frustum.culls(box(Vec3(0, 0, -2000), 10)));
    UM_CHECK(!frustum.culls(box(Vec3(0, 0, 0), 10)));
}

static void testNearPlaneSitsAtNearZNotHalfAFrustumBack() {
    // Under the OpenGL -w..w convention the near plane would be `w + z`,
    // which lands half a frustum too far back. Here clip z runs 0..w, so
    // the plane passes exactly through the near distance in front of the
    // eye.
    const SceneProjection p = camera();
    const SceneFrustum frustum(p.viewProjection());
    const Vec3 onPlane(0, 0, -500 + kNear);
    UM_CHECK_NEAR(SceneFrustum::distance(frustum.planes[SceneFrustum::kNear], onPlane), 0.0, 1e-3);
    UM_CHECK(SceneFrustum::distance(frustum.planes[SceneFrustum::kNear], Vec3(0, 0, 0)) > 0.0f);
    UM_CHECK(SceneFrustum::distance(frustum.planes[SceneFrustum::kNear], Vec3(0, 0, -600)) < 0.0f);
}

static void testFarPlaneAgreesWithTheRendererThatHonoursIt() {
    const SceneProjection p = camera();
    const SceneFrustum frustum(p.viewProjection());
    // Beyond farZ: the culler drops it, and the projection's far cut also
    // drops it, so nothing is lost that would have been drawn.
    const float beyond = -500.0f + kFar + 100.0f;
    UM_CHECK(frustum.culls(box(Vec3(0, 0, beyond), 10)));
    const std::vector<SceneProjection::AttributedVertex> quad = {
        {Vec3(-50, -50, beyond), Vec2(0, 0)},
        {Vec3(50, -50, beyond), Vec2(1, 0)},
        {Vec3(50, 50, beyond), Vec2(1, 1)},
        {Vec3(-50, 50, beyond), Vec2(0, 1)}};
    UM_CHECK(p.clipAndProject(quad).empty());
}

static void testPlanesAreNormalisedSoMarginIsWorldUnits() {
    const SceneProjection p = camera();
    const SceneFrustum frustum(p.viewProjection());
    for (const Vec4& plane : frustum.planes) {
        UM_CHECK_NEAR(length(plane.xyz()), 1.0, 1e-5);
    }
    // A box 100 units the wrong side of the near plane is culled, and a
    // margin of 200 world units keeps it.
    const auto hull = box(Vec3(0, 0, -700), 10);
    UM_CHECK(frustum.culls(hull));
    UM_CHECK(!frustum.culls(hull, 300.0f));
}

static void testEmptyHullCulls() {
    const SceneFrustum frustum(camera().viewProjection());
    UM_CHECK(frustum.culls({}));
}

static void testStraddlingHullIsKept() {
    // A hull crossing a plane is visible in part, so it must survive.
    const SceneProjection p = camera();
    const SceneFrustum frustum(p.viewProjection());
    UM_CHECK(!frustum.culls(box(Vec3(0, 0, -500 + kNear), 200)));
}

static void testFrameRegionRoundsOutwardAndClipsToTheFrame() {
    const FrameRegion region =
        FrameRegion::bounding({Vec2(10.2f, 20.8f), Vec2(30.6f, 40.1f)}, 0.0f, 1000, 800);
    // Outward, never to nearest: 10.2 -> 10 (floor) and 30.6 -> 31 (ceil).
    UM_CHECK(region == FrameRegion(10, 20, 31, 41));
    UM_CHECK(region.width() == 21 && region.height() == 21);
    UM_CHECK(!region.isEmpty());

    const FrameRegion padded =
        FrameRegion::bounding({Vec2(10.2f, 20.8f), Vec2(30.6f, 40.1f)}, 2.0f, 1000, 800);
    UM_CHECK(padded == FrameRegion(8, 18, 33, 43));

    // Clipped to the frame, and never negative.
    const FrameRegion clipped =
        FrameRegion::bounding({Vec2(-40, -40), Vec2(5000, 5000)}, 1.0f, 1000, 800);
    UM_CHECK(clipped == FrameRegion::whole(1000, 800));
}

static void testFrameRegionDegeneracies() {
    // No points: nothing to draw.
    UM_CHECK(FrameRegion::bounding({}, 0.0f, 1000, 800).isEmpty());
    // A NaN means a degenerate projection; redrawing the whole frame is
    // the conservative answer, matching the culler's one-directional rule.
    const FrameRegion nan = FrameRegion::bounding(
        {Vec2(std::nanf(""), 0.0f), Vec2(10, 10)}, 0.0f, 1000, 800);
    UM_CHECK(nan == FrameRegion::whole(1000, 800));
    const FrameRegion infinite =
        FrameRegion::bounding({Vec2(INFINITY, 0.0f), Vec2(10, 10)}, 0.0f, 1000, 800);
    UM_CHECK(infinite == FrameRegion::whole(1000, 800));
    // A rectangle entirely off the frame is empty, not inverted-but-drawn.
    UM_CHECK(FrameRegion::bounding({Vec2(-100, -100), Vec2(-50, -50)}, 0.0f, 1000, 800).isEmpty());
}

UM_TEST_MAIN_BEGIN()
    testAPointOnScreenIsNeverCulled();
    testSomethingWellOutsideIsActuallyCulled();
    testBehindTheEyeIsCulled();
    testNearPlaneSitsAtNearZNotHalfAFrustumBack();
    testFarPlaneAgreesWithTheRendererThatHonoursIt();
    testPlanesAreNormalisedSoMarginIsWorldUnits();
    testEmptyHullCulls();
    testStraddlingHullIsKept();
    testFrameRegionRoundsOutwardAndClipsToTheFrame();
    testFrameRegionDegeneracies();
UM_TEST_MAIN_END()
