// Tests for Render/SceneCulling.h, ported from `Render/SceneCulling.swift`.
//
// The Swift file states one property above all others, and it is not
// symmetric: the culler may KEEP something invisible, it may never DISCARD
// something visible. So the central test here does not check plane
// coefficients -- that would only restate the extraction formula. It sweeps
// thousands of random cameras and points, asks `SceneProjection` (the same
// matrix the frustum is pulled out of) whether a point lands inside the
// viewport between near and far, and asserts that `culls` never throws away
// one that does. The conservative half is asserted too: the documented
// straddling case, a hull genuinely outside the frustum that is kept
// because it is not outside any single plane.
//
// Everything else follows the same rule as the rest of this port: assert
// what the Swift header promises (outward rounding, y down, unknown means
// whole frame), not what the code happens to compute.

#include "umeshcore/Render/SceneCulling.h"

#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

#include "umeshcore/Render/SceneProjection.h"

#include "TestHarness.h"

using namespace umeshcore;

namespace {

// A camera at the origin looking straight down +Z, 1000x800 pixels --
// the same fixture SceneProjectionTests uses, so a failure here can be
// read against one there.
SceneProjection frontOn() {
    return SceneProjection(
        Vec3(0, 0, -500), 0.0f, 0.0f, 0.0f, 60.0f, 1.0f, 10000.0f, Vec2(1000, 800));
}

// Half the world height the viewport covers at a given depth, from the
// projection's own `pixels = focalLength * length / depth`.
float halfHeightAtDepth(const SceneProjection& p, float depth) {
    return 0.5f * p.viewSize.y * depth / p.focalLength;
}

float halfWidthAtDepth(const SceneProjection& p, float depth) {
    return 0.5f * p.viewSize.x * depth / p.focalLength;
}

// A deterministic generator, so a failure is reproducible from the seed
// alone. Not std::mt19937: this file asserts geometry, and a hand-written
// LCG keeps the test readable and its sequence stable across libraries.
struct Lcg {
    std::uint64_t state = 0x2545F4914F6CDD1Dull;
    float unit() { // [0, 1)
        state = state * 6364136223846793005ull + 1442695040888963407ull;
        return static_cast<float>((state >> 40) & 0xFFFFFF) / 16777216.0f;
    }
    float range(float lo, float hi) { return lo + (hi - lo) * unit(); }
};

} // namespace

static void testSixPlanesAllNormalised() {
    const SceneProjection p = frontOn();
    const SceneFrustum frustum(p.viewProjection());
    UM_CHECK(frustum.planes.size() == static_cast<std::size_t>(SceneFrustum::Count));
    for (const Vec4& plane : frustum.planes) {
        // Normalised is what makes `margin` a world distance rather than
        // an arbitrary scale -- the header's reason for normalising at all.
        UM_CHECK_NEAR(length(plane.xyz()), 1.0, 1e-5);
    }
}

static void testPlanesFaceInward() {
    const SceneProjection p = frontOn();
    const SceneFrustum frustum(p.viewProjection());
    // A point at the middle of the frustum: in front of every plane. If
    // the rows had been gathered as columns, this is the check that fails
    // -- a transposed frustum culls what is in front of the camera.
    const Vec3 middle(0, 0, 0); // eye is at z=-500, so 500 ahead
    for (const Vec4& plane : frustum.planes) {
        UM_CHECK(SceneFrustum::distance(plane, middle) > 0.0f);
    }
    UM_CHECK(!frustum.culls({middle}));
}

static void testNearPlaneDistanceIsAWorldDistance() {
    const SceneProjection p = frontOn();
    const SceneFrustum frustum(p.viewProjection());
    // Eye at z=-500 looking down +Z with nearZ=1, so the near plane sits
    // at z=-499 and a point 5 units past it is 5 units inside.
    const float d = SceneFrustum::distance(frustum.planes[SceneFrustum::Near], Vec3(0, 0, -494));
    UM_CHECK_NEAR(d, 5.0, 1e-3);
    // And the sign flips on the other side of it.
    UM_CHECK(SceneFrustum::distance(frustum.planes[SceneFrustum::Near], Vec3(0, 0, -500)) < 0.0f);
}

static void testBehindTheEyeIsCulled() {
    const SceneProjection p = frontOn();
    const SceneFrustum frustum(p.viewProjection());
    UM_CHECK(frustum.culls({Vec3(0, 0, -600)}));
    // `project` agrees: a point behind the near plane has no projection.
    UM_CHECK(!p.project(Vec3(0, 0, -600)).has_value());
}

static void testBeyondFarIsCulled() {
    const SceneProjection p = frontOn(); // farZ = 10000, eye at z=-500
    const SceneFrustum frustum(p.viewProjection());
    UM_CHECK(frustum.culls({Vec3(0, 0, 20000)}));
    UM_CHECK(!frustum.culls({Vec3(0, 0, 5000)}));
}

static void testEmptyHullIsCulled() {
    const SceneFrustum frustum(frontOn().viewProjection());
    // Nothing to draw. Culling it is not the asymmetric error: there is no
    // visible geometry to lose.
    UM_CHECK(frustum.culls({}));
}

static void testMarginPushesPlanesOutward() {
    const SceneProjection p = frontOn();
    const SceneFrustum frustum(p.viewProjection());
    // Two units to the left of the left plane, at depth 500.
    const float halfW = halfWidthAtDepth(p, 500.0f);
    const Vec3 justOutside(-(halfW + 2.0f), 0, 0);
    UM_CHECK(frustum.culls({justOutside}));
    UM_CHECK(!frustum.culls({justOutside}, 3.0f));  // margin in WORLD units
    UM_CHECK(frustum.culls({justOutside}, 1.0f));   // still not enough
}

static void testStraddlingHullIsKeptEvenThoughItIsOutside() {
    // The documented conservatism, made concrete: a segment that passes
    // outside the top-left corner of the frustum without ever entering it.
    // Every plane has one endpoint inside it, so no single plane proves
    // the segment invisible, and the culler keeps it. That is wasted work
    // and is the ALLOWED direction of error.
    const SceneProjection p = frontOn();
    const SceneFrustum frustum(p.viewProjection());
    const float depth = 500.0f;
    const float z = -500.0f + depth;
    const float halfW = halfWidthAtDepth(p, depth);
    const float halfH = halfHeightAtDepth(p, depth);

    const Vec3 a(-3.0f * halfW, 0.5f * halfH, z); // outside left, inside top
    const Vec3 b(-0.5f * halfW, 3.0f * halfH, z); // inside left, outside top

    // First establish INDEPENDENTLY, through the projection, that the
    // whole segment really is off screen -- otherwise this would only be
    // asserting that the culler agrees with itself.
    for (int i = 0; i <= 20; ++i) {
        const float t = static_cast<float>(i) / 20.0f;
        const Vec3 point = a + (b - a) * t;
        const auto screen = p.project(point);
        UM_CHECK(screen.has_value());
        if (screen) {
            const bool onScreen = screen->x >= 0.0f && screen->x <= p.viewSize.x &&
                                  screen->y >= 0.0f && screen->y <= p.viewSize.y;
            UM_CHECK(!onScreen);
        }
    }
    // Each endpoint alone IS provably outside one plane, so each alone is
    // culled...
    UM_CHECK(frustum.culls({a}));
    UM_CHECK(frustum.culls({b}));
    // ...but together they straddle, and the hull is kept.
    UM_CHECK(!frustum.culls({a, b}));
}

static void testNeverCullsAnythingTheProjectionPutsOnScreen() {
    // The property the whole file exists for, swept over random cameras.
    // A point the projection places strictly inside the viewport, strictly
    // between near and far, must never be culled. A failure here is an
    // object vanishing on screen.
    Lcg rng;
    int visibleSamples = 0;
    for (int i = 0; i < 20000; ++i) {
        const Vec3 eye(rng.range(-800, 800), rng.range(-800, 800), rng.range(-800, 800));
        const float pitch = rng.range(-1.4f, 1.4f);
        const float yaw = rng.range(-3.2f, 3.2f);
        const float roll = rng.range(-3.2f, 3.2f);
        const float fov = rng.range(20.0f, 110.0f);
        const float nearZ = rng.range(0.5f, 20.0f);
        const float farZ = nearZ + rng.range(200.0f, 8000.0f);
        const Vec2 viewSize(rng.range(200.0f, 1920.0f), rng.range(200.0f, 1080.0f));
        const SceneProjection p(eye, pitch, yaw, roll, fov, nearZ, farZ, viewSize);
        const SceneFrustum frustum(p.viewProjection());

        const Vec3 point(rng.range(-2000, 2000), rng.range(-2000, 2000), rng.range(-2000, 2000));
        const auto screen = p.project(point);
        if (!screen) continue;
        const float depth = p.depth(point);
        // Inset by half a pixel and 0.1 % of the depth range: a point
        // exactly ON a boundary can land either side of it in float, and
        // this test is about points that are unambiguously visible, not
        // about where the tie breaks.
        const bool clearlyVisible = screen->x > 0.5f && screen->x < viewSize.x - 0.5f &&
                                    screen->y > 0.5f && screen->y < viewSize.y - 0.5f &&
                                    depth > nearZ * 1.001f + 0.01f &&
                                    depth < farZ * 0.999f;
        if (!clearlyVisible) continue;
        ++visibleSamples;
        if (frustum.culls({point})) {
            UM_CHECK(!"culler discarded a point the projection puts on screen");
            break;
        }
    }
    // Guard against the sweep silently testing nothing.
    UM_CHECK(visibleSamples > 500);
}

static void testDegenerateMatrixDoesNotProduceNaNPlanes() {
    // A singular view-projection (all zeros) has no normal to divide by.
    // The planes are left unscaled rather than turned into NaN: a NaN
    // plane compares false everywhere and would cull the entire scene,
    // which is the one direction this file may not fail in.
    const SceneFrustum frustum(Mat4(Vec4::zero(), Vec4::zero(), Vec4::zero(), Vec4::zero()));
    for (const Vec4& plane : frustum.planes) {
        UM_CHECK(std::isfinite(plane.x) && std::isfinite(plane.y) && std::isfinite(plane.z) &&
                 std::isfinite(plane.w));
    }
}

// ---- FrameRegion ----

static void testBoundingRoundsOutwardNeverToNearest() {
    // 10.2 rounds DOWN to 10 and 20.7 rounds UP to 21: a box that rounded
    // to nearest would drop the anti-aliased edge at both ends.
    const FrameRegion r = FrameRegion::bounding({Vec2(10.2f, 20.7f), Vec2(30.4f, 40.1f)},
                                                 0.0f, 1000, 800);
    UM_CHECK(r == FrameRegion(10, 20, 31, 41));
}

static void testBoundingIsYDownWithNoFlip() {
    // The points are screen points already (y down), so the smaller y is
    // minY. A flip hiding in here would silently mirror every region.
    const FrameRegion r = FrameRegion::bounding({Vec2(5.0f, 700.0f), Vec2(5.0f, 100.0f)},
                                                 0.0f, 1000, 800);
    UM_CHECK(r.minY == 100 && r.maxY == 700);
}

static void testPadExpandsEveryEdge() {
    const FrameRegion r = FrameRegion::bounding({Vec2(100.0f, 100.0f), Vec2(200.0f, 200.0f)},
                                                 2.5f, 1000, 800);
    UM_CHECK(r == FrameRegion(97, 97, 203, 203));
}

static void testBoundingClipsToTheFrame() {
    const FrameRegion r = FrameRegion::bounding({Vec2(-50.0f, -80.0f), Vec2(5000.0f, 5000.0f)},
                                                 4.0f, 1000, 800);
    UM_CHECK(r == FrameRegion(0, 0, 1000, 800));
}

static void testWhollyOffScreenRegionIsEmpty() {
    const FrameRegion r = FrameRegion::bounding({Vec2(2000.0f, 10.0f), Vec2(3000.0f, 20.0f)},
                                                 0.0f, 1000, 800);
    UM_CHECK(r.isEmpty());
    UM_CHECK(r.width() <= 0);
}

static void testNoPointsIsEmptyButNonFiniteIsTheWholeFrame() {
    // Two different unknowns with two different answers, and getting them
    // the wrong way round is a real bug either way: nothing to draw must
    // not become a full-frame blit, and a NaN corner must not become a
    // skipped layer.
    UM_CHECK(FrameRegion::bounding({}, 0.0f, 1000, 800).isEmpty());

    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();
    // A NaN corner among finite ones is the documented divergence: Swift's
    // fmin-based `simd_min` would drop it and bound the rest, shrinking the
    // region and clipping pixels off a layer that is on screen. Here it is
    // an unknown like any other.
    UM_CHECK(FrameRegion::bounding({Vec2(10.0f, 10.0f), Vec2(nan, 20.0f)}, 0.0f, 1000, 800) ==
             FrameRegion::whole(1000, 800));
    UM_CHECK(FrameRegion::bounding({Vec2(10.0f, 10.0f), Vec2(20.0f, inf)}, 0.0f, 1000, 800) ==
             FrameRegion::whole(1000, 800));
    // A non-finite PAD is the same kind of unknown -- it lands on every
    // edge, so the box it makes is no more meaningful than a NaN corner.
    UM_CHECK(FrameRegion::bounding({Vec2(10.0f, 10.0f), Vec2(20.0f, 20.0f)}, nan, 1000, 800) ==
             FrameRegion::whole(1000, 800));
}

static void testEnormousCoordinatesStayDefined() {
    // The DIVERGENCE documented in the header: Swift converts to Int
    // before clamping and traps on a coordinate this large. Clamping
    // first gives the same region for every in-range value and a defined
    // one here.
    const FrameRegion r = FrameRegion::bounding({Vec2(-1e30f, -1e30f), Vec2(1e30f, 1e30f)},
                                                 0.0f, 1000, 800);
    UM_CHECK(r == FrameRegion::whole(1000, 800));
}

static void testWholeAndGeometryAccessors() {
    const FrameRegion whole = FrameRegion::whole(1000, 800);
    UM_CHECK(whole.width() == 1000 && whole.height() == 800);
    UM_CHECK(!whole.isEmpty());
    UM_CHECK(FrameRegion::whole(0, 800).isEmpty());
}

static void testBoundingAQuadTheProjectionProduced() {
    // End to end against the piece this exists to serve: project a card's
    // corners and bound them. The region must contain every projected
    // corner, which is the only thing the drawing path needs from it.
    const SceneProjection p = frontOn();
    const std::vector<Vec3> corners = {
        Vec3(-100, -80, 0), Vec3(100, -80, 0), Vec3(100, 80, 0), Vec3(-100, 80, 0)};
    std::vector<Vec2> screens;
    for (const Vec3& corner : corners) {
        const auto s = p.project(corner);
        UM_CHECK(s.has_value());
        if (s) screens.push_back(*s);
    }
    const FrameRegion r = FrameRegion::bounding(screens, 1.0f, 1000, 800);
    UM_CHECK(!r.isEmpty());
    for (const Vec2& s : screens) {
        UM_CHECK(static_cast<float>(r.minX) <= s.x && s.x <= static_cast<float>(r.maxX));
        UM_CHECK(static_cast<float>(r.minY) <= s.y && s.y <= static_cast<float>(r.maxY));
    }
}

UM_TEST_MAIN_BEGIN()
testSixPlanesAllNormalised();
testPlanesFaceInward();
testNearPlaneDistanceIsAWorldDistance();
testBehindTheEyeIsCulled();
testBeyondFarIsCulled();
testEmptyHullIsCulled();
testMarginPushesPlanesOutward();
testStraddlingHullIsKeptEvenThoughItIsOutside();
testNeverCullsAnythingTheProjectionPutsOnScreen();
testDegenerateMatrixDoesNotProduceNaNPlanes();
testBoundingRoundsOutwardNeverToNearest();
testBoundingIsYDownWithNoFlip();
testPadExpandsEveryEdge();
testBoundingClipsToTheFrame();
testWhollyOffScreenRegionIsEmpty();
testNoPointsIsEmptyButNonFiniteIsTheWholeFrame();
testEnormousCoordinatesStayDefined();
testWholeAndGeometryAccessors();
testBoundingAQuadTheProjectionProduced();
UM_TEST_MAIN_END()
