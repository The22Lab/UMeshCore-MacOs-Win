// Tests for Render/SceneProjection.h, ported from
// `Render/SceneProjection.swift`. The Swift file documents, at length, the
// bugs each piece exists to prevent -- so these assert those PROPERTIES
// (project/unproject are exact inverses; a partly-visible quad yields a
// polygon rather than nothing; a corner behind the eye still has a
// projective image; a gizmo scale is one number for all axes) rather than
// re-deriving matrix entries, which would only restate the implementation.

#include "umeshcore/Render/SceneProjection.h"

#include "umeshcore/Math/MatrixUtilities.h"
#include <cmath>

#include "TestHarness.h"

using namespace umeshcore;

namespace {

// A camera at the origin looking straight down +Z, 1000x800 pixels.
SceneProjection frontOn() {
    return SceneProjection(Vec3(0, 0, -500), 0.0f, 0.0f, 0.0f, 60.0f, 1.0f, 10000.0f, Vec2(1000, 800));
}

} // namespace

static void testCameraLooksDownPositiveZ() {
    const SceneProjection p = frontOn();
    // A point further along +Z than the eye is IN FRONT of it: positive
    // depth. This is the convention the whole file hangs on.
    UM_CHECK(p.depth(Vec3(0, 0, 0)) > 0.0f);
    UM_CHECK(p.depth(Vec3(0, 0, -1000)) < 0.0f);
    UM_CHECK_NEAR(p.depth(Vec3(0, 0, 0)), 500.0, 1e-3);
}

static void testCentreProjectsToScreenCentre() {
    const SceneProjection p = frontOn();
    const auto centre = p.project(Vec3(0, 0, 0));
    UM_CHECK(centre.has_value());
    UM_CHECK_NEAR(centre->x, 500.0, 1e-3);
    UM_CHECK_NEAR(centre->y, 400.0, 1e-3);
}

static void testScreenYGrowsDownward() {
    const SceneProjection p = frontOn();
    // World +Y is up, so it must land ABOVE centre, i.e. at a SMALLER
    // screen y.
    const auto up = p.project(Vec3(0, 100, 0));
    UM_CHECK(up.has_value());
    UM_CHECK(up->y < 400.0f);
    const auto down = p.project(Vec3(0, -100, 0));
    UM_CHECK(down.has_value() && down->y > 400.0f);
}

static void testPointBehindTheEyeHasNoProjection() {
    const SceneProjection p = frontOn();
    // Behind the eye: nullopt, not a clamped or mirrored number. A point
    // behind the eye has no honest projection, and answering with one puts
    // garbage on screen that reads as a rendering bug.
    UM_CHECK(!p.project(Vec3(0, 0, -600)).has_value());
    // And exactly at the eye.
    UM_CHECK(!p.project(Vec3(0, 0, -500)).has_value());
}

static void testProjectAndUnprojectAreExactInverses() {
    // The one property that matters for dragging: if these drift, the
    // cursor and the card it is holding separate -- by more the further
    // away the card is, so it presents as a different bug at every depth.
    const SceneProjection p = frontOn();
    for (float z : {0.0f, 250.0f, 1500.0f}) {
        for (const Vec2& world : {Vec2(0, 0), Vec2(120, -80), Vec2(-300, 220)}) {
            const auto screen = p.project(Vec3(world.x, world.y, z));
            UM_CHECK(screen.has_value());
            const auto back = p.unprojectOntoPlaneZ(*screen, z);
            UM_CHECK(back.has_value());
            UM_CHECK_NEAR(back->x, world.x, 1e-2);
            UM_CHECK_NEAR(back->y, world.y, 1e-2);
        }
    }
}

static void testRotatedCameraStillRoundTrips() {
    // A yawed/pitched camera is where the "axis-aligned squash" the Swift
    // header describes used to go wrong, so the inverse must hold here too.
    const SceneProjection p(
        Vec3(120, -40, -600), /*pitch=*/0.2f, /*yaw=*/-0.35f, /*roll=*/0.0f, 45.0f, 1.0f, 10000.0f,
        Vec2(1280, 720));
    const Vec3 world(80, 30, 100);
    const auto screen = p.project(world);
    UM_CHECK(screen.has_value());

    // Through the generic plane hit, since the plane z=100 is not special.
    const auto hit = p.hitPlane(*screen, Vec3(0, 0, 100), Vec3(0, 0, 1));
    UM_CHECK(hit.has_value());
    UM_CHECK_NEAR(hit->x, world.x, 1e-2);
    UM_CHECK_NEAR(hit->y, world.y, 1e-2);
    UM_CHECK_NEAR(hit->z, world.z, 1e-2);
}

static void testPerspectiveConverges() {
    // Two points the same world distance apart, at different depths: the
    // far pair must be closer together on screen. A uniform per-layer
    // scale could fake this; a tilted card is what it could not (below).
    const SceneProjection p = frontOn();
    const auto nearLeft = p.project(Vec3(-100, 0, 100));
    const auto nearRight = p.project(Vec3(100, 0, 100));
    const auto farLeft = p.project(Vec3(-100, 0, 2000));
    const auto farRight = p.project(Vec3(100, 0, 2000));
    UM_CHECK(nearLeft.has_value() && nearRight.has_value() && farLeft.has_value() && farRight.has_value());
    UM_CHECK((nearRight->x - nearLeft->x) > (farRight->x - farLeft->x));
}

static void testTiltedCardHasANearEdgeWiderThanItsFarEdge() {
    // The failure the Swift header names first: a card scaled by ONE
    // number could not have a near edge wider than its far edge, so a
    // tilt had to be faked in screen space afterwards. A real projection
    // gets it for free.
    const SceneProjection p = frontOn();
    // A quad tilted about Y: left edge nearer than the right edge.
    const auto topNear = p.project(Vec3(-200, 150, 300));
    const auto bottomNear = p.project(Vec3(-200, -150, 300));
    const auto topFar = p.project(Vec3(200, 150, 1200));
    const auto bottomFar = p.project(Vec3(200, -150, 1200));
    UM_CHECK(topNear.has_value() && bottomNear.has_value() && topFar.has_value() && bottomFar.has_value());

    const float nearHeight = bottomNear->y - topNear->y;
    const float farHeight = bottomFar->y - topFar->y;
    UM_CHECK(nearHeight > farHeight * 1.5f);
}

static void testPartlyVisibleQuadYieldsAPolygonNotNothing() {
    // The bug this replaced: every drawing path asked `project` per corner
    // and gave up the whole primitive when one came back nil. A quad with
    // one corner behind the eye is PARTLY visible, and the visible part is
    // a polygon.
    const SceneProjection p = frontOn();
    const std::vector<SceneProjection::AttributedVertex> quad{
        {Vec3(-200, 150, -600), Vec2(0, 0)},  // behind the eye
        {Vec3(200, 150, 400), Vec2(1, 0)},
        {Vec3(200, -150, 400), Vec2(1, 1)},
        {Vec3(-200, -150, -600), Vec2(0, 1)}, // behind the eye
    };

    // Two corners are behind the eye, so the all-or-nothing rule would
    // have drawn nothing at all.
    UM_CHECK(!p.project(quad[0].world).has_value());
    UM_CHECK(!p.isWhollyVisible({quad[0].world, quad[1].world, quad[2].world, quad[3].world}));

    const std::vector<SceneProjection::ProjectedVertex> cut = p.clipAndProject(quad);
    UM_CHECK(cut.size() >= 3); // a real polygon survives
    for (const SceneProjection::ProjectedVertex& v : cut) {
        UM_CHECK(std::isfinite(v.screen.x) && std::isfinite(v.screen.y));
    }
}

static void testWhollyVisibleQuadPassesThroughUnchanged() {
    const SceneProjection p = frontOn();
    const std::vector<SceneProjection::AttributedVertex> quad{
        {Vec3(-200, 150, 400), Vec2(0, 0)},
        {Vec3(200, 150, 400), Vec2(1, 0)},
        {Vec3(200, -150, 400), Vec2(1, 1)},
        {Vec3(-200, -150, 400), Vec2(0, 1)},
    };
    UM_CHECK(p.isWhollyVisible({quad[0].world, quad[1].world, quad[2].world, quad[3].world}));

    const std::vector<SceneProjection::ProjectedVertex> cut = p.clipAndProject(quad);
    UM_CHECK(cut.size() == 4);
    // Same answer as projecting each corner directly, and the attributes
    // ride along untouched.
    for (std::size_t i = 0; i < 4; ++i) {
        const auto direct = p.project(quad[i].world);
        UM_CHECK(direct.has_value());
        UM_CHECK_NEAR(cut[i].screen.x, direct->x, 1e-3);
        UM_CHECK_NEAR(cut[i].screen.y, direct->y, 1e-3);
        UM_CHECK(cut[i].attribute == quad[i].attribute);
    }
}

static void testFarPlaneClipsToo() {
    // The far plane is not decoration: `farZ` went into the projection
    // matrix and then nothing read it back, so the culler discarded cards
    // the renderer would happily have drawn.
    const SceneProjection near(Vec3(0, 0, 0), 0, 0, 0, 60.0f, 1.0f, 1000.0f, Vec2(1000, 800));
    const std::vector<Vec3> beyond{Vec3(-10, 10, 5000), Vec3(10, 10, 5000), Vec3(10, -10, 5000)};
    UM_CHECK(!near.isWhollyVisible(beyond));

    const std::vector<SceneProjection::AttributedVertex> poly{
        {beyond[0], Vec2(0, 0)}, {beyond[1], Vec2(1, 0)}, {beyond[2], Vec2(1, 1)}};
    UM_CHECK(near.clipAndProject(poly).empty());
}

static void testProjectiveQuadKeepsCornersBehindTheEye() {
    // Unlike `project`, this must ANSWER for a corner behind the eye: the
    // antipode is that corner's correct projective image, and the
    // homography through all four is the true map.
    const SceneProjection p = frontOn();
    const std::vector<Vec3> corners{
        Vec3(-200, 150, -600), Vec3(200, 150, 400), Vec3(200, -150, 400), Vec3(-200, -150, -600)};
    UM_CHECK(!p.project(corners[0]).has_value()); // no honest projection...

    const auto quad = p.projectiveQuad(corners); // ...but a projective image.
    UM_CHECK(quad.has_value() && quad->size() == 4);
    for (const Vec2& v : *quad) UM_CHECK(std::isfinite(v.x) && std::isfinite(v.y));

    // The in-front corners agree with `project` exactly.
    const auto direct = p.project(corners[1]);
    UM_CHECK(direct.has_value());
    UM_CHECK_NEAR((*quad)[1].x, direct->x, 1e-3);

    // Wrong arity is refused outright.
    UM_CHECK(!p.projectiveQuad({corners[0], corners[1], corners[2]}).has_value());
}

static void testGizmoScaleIsOneNumberForEveryAxis() {
    // What sizes a gizmo to a constant pixel size: ONE scale for all three
    // axes, so the arrow mesh keeps its proportions from every angle.
    // Measuring per axis is what gave one gizmo three different arrows.
    const SceneProjection p = frontOn();
    const float depth = 800.0f;
    const auto worldLength = p.worldLengthForPixels(60.0f, depth);
    UM_CHECK(worldLength.has_value());

    // Feed it back through the projection along X and along Y: both must
    // span the same 60 pixels.
    const Vec3 centre(0, 0, depth - 500.0f + 500.0f);
    const auto atCentre = p.project(Vec3(0, 0, depth - 500.0f));
    const auto alongX = p.project(Vec3(*worldLength, 0, depth - 500.0f));
    const auto alongY = p.project(Vec3(0, *worldLength, depth - 500.0f));
    (void)centre;
    UM_CHECK(atCentre.has_value() && alongX.has_value() && alongY.has_value());
    UM_CHECK_NEAR(std::fabs(alongX->x - atCentre->x), 60.0, 0.1);
    UM_CHECK_NEAR(std::fabs(alongY->y - atCentre->y), 60.0, 0.1);

    // Nothing at or behind the near plane has an answer.
    UM_CHECK(!p.worldLengthForPixels(60.0f, 0.5f).has_value());
}

static void testRayThroughCentreLooksAlongTheViewAxis() {
    const SceneProjection p = frontOn();
    const SceneProjection::Ray r = p.rayThrough(Vec2(500, 400));
    UM_CHECK_NEAR(r.origin.z, -500.0, 1e-3);
    UM_CHECK_NEAR(length(r.direction), 1.0, 1e-5); // unit length
    UM_CHECK_NEAR(r.direction.z, 1.0, 1e-4);       // straight down +Z
    UM_CHECK_NEAR(r.direction.x, 0.0, 1e-4);
}

static void testAxisParameterTracksAlongTheAxisInWorldUnits() {
    // An AXIS handle's answer is a world distance along the axis, not a
    // screen distance rescaled by a number measured somewhere else.
    const SceneProjection p = frontOn();
    const Vec3 origin(0, 0, 400);
    const Vec3 axis(1, 0, 0);

    // A point 150 world units along the axis, projected, then read back.
    const auto screen = p.project(origin + axis * 150.0f);
    UM_CHECK(screen.has_value());
    const auto t = p.axisParameter(*screen, origin, axis);
    UM_CHECK(t.has_value());
    UM_CHECK_NEAR(*t, 150.0, 0.5);
}

static void testAxisSeenEndOnHasNoAnswer() {
    // The axis pointing straight at the camera: the ray and the axis are
    // parallel on screen, and there is no honest answer. The gizmo already
    // refuses the drag in that case.
    const SceneProjection p = frontOn();
    UM_CHECK(!p.axisParameter(Vec2(500, 400), Vec3(0, 0, 400), Vec3(0, 0, 1)).has_value());
}

static void testPlaneHitRefusesParallelAndBehind() {
    const SceneProjection p = frontOn();
    // A plane edge-on to the view direction: parallel, no intersection.
    UM_CHECK(!p.hitPlane(Vec2(500, 400), Vec3(0, 0, 400), Vec3(0, 1, 0)).has_value());
    // A plane behind the eye: the ray meets it going backwards.
    UM_CHECK(!p.hitPlane(Vec2(500, 400), Vec3(0, 0, -900), Vec3(0, 0, 1)).has_value());
}

static void testFrameAndAngleConstructorsAgree() {
    // Two cameras, one set of maths -- what keeps the fly preview and the
    // shot render from drifting apart. Built from angles and from the
    // basis those same angles produce, they must project identically.
    const Vec3 eye(50, -20, -400);
    const float pitch = 0.25f;
    const float yaw = 0.4f;
    const float fov = 55.0f;
    const Vec2 viewSize(900, 600);

    const SceneProjection fromAngles(eye, pitch, yaw, 0.0f, fov, 1.0f, 10000.0f, viewSize);
    const float half = fov * kPi / 180.0f * 0.5f;
    const SceneProjection fromBasis = SceneProjection::fromFrame(
        eye, cameraBasis(pitch, yaw, 0.0f), (viewSize.y * 0.5f) / std::tan(half), 1.0f, 10000.0f, viewSize);

    for (const Vec3& world : {Vec3(0, 0, 0), Vec3(200, 100, 600), Vec3(-150, 80, 1500)}) {
        const auto a = fromAngles.project(world);
        const auto b = fromBasis.project(world);
        UM_CHECK(a.has_value() == b.has_value());
        if (a.has_value() && b.has_value()) {
            UM_CHECK_NEAR(a->x, b->x, 1e-2);
            UM_CHECK_NEAR(a->y, b->y, 1e-2);
        }
    }
}

static void testCameraBasisIsOrthonormalIncludingUnderRoll() {
    for (float roll : {0.0f, 0.6f, -1.2f}) {
        const CameraBasis b = cameraBasis(0.3f, -0.7f, roll);
        UM_CHECK_NEAR(length(b.right), 1.0, 1e-5);
        UM_CHECK_NEAR(length(b.up), 1.0, 1e-5);
        UM_CHECK_NEAR(length(b.forward), 1.0, 1e-5);
        UM_CHECK_NEAR(dot(b.right, b.up), 0.0, 1e-5);
        UM_CHECK_NEAR(dot(b.right, b.forward), 0.0, 1e-5);
        UM_CHECK_NEAR(dot(b.up, b.forward), 0.0, 1e-5);
    }
}

static void testFieldOfViewIsClamped() {
    // 1..170 degrees. A degenerate fov would divide by a tangent at or
    // past the asymptote.
    const SceneProjection wide(Vec3(0, 0, 0), 0, 0, 0, 500.0f, 1.0f, 1000.0f, Vec2(1000, 800));
    const SceneProjection narrow(Vec3(0, 0, 0), 0, 0, 0, -20.0f, 1.0f, 1000.0f, Vec2(1000, 800));
    UM_CHECK(std::isfinite(wide.focalLength) && wide.focalLength > 0.0f);
    UM_CHECK(std::isfinite(narrow.focalLength) && narrow.focalLength > 0.0f);
    // A 170-degree view is much wider than a 1-degree one, so its focal
    // length is far smaller.
    UM_CHECK(wide.focalLength < narrow.focalLength);
}

UM_TEST_MAIN_BEGIN()
    testCameraLooksDownPositiveZ();
    testCentreProjectsToScreenCentre();
    testScreenYGrowsDownward();
    testPointBehindTheEyeHasNoProjection();
    testProjectAndUnprojectAreExactInverses();
    testRotatedCameraStillRoundTrips();
    testPerspectiveConverges();
    testTiltedCardHasANearEdgeWiderThanItsFarEdge();
    testPartlyVisibleQuadYieldsAPolygonNotNothing();
    testWhollyVisibleQuadPassesThroughUnchanged();
    testFarPlaneClipsToo();
    testProjectiveQuadKeepsCornersBehindTheEye();
    testGizmoScaleIsOneNumberForEveryAxis();
    testRayThroughCentreLooksAlongTheViewAxis();
    testAxisParameterTracksAlongTheAxisInWorldUnits();
    testAxisSeenEndOnHasNoAnswer();
    testPlaneHitRefusesParallelAndBehind();
    testFrameAndAngleConstructorsAgree();
    testCameraBasisIsOrthonormalIncludingUnderRoll();
    testFieldOfViewIsClamped();
UM_TEST_MAIN_END()
