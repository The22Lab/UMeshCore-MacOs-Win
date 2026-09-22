// Tests for Editor/SceneGizmoState.h -- the Scene gizmo's shape for one
// frame, extracted from `SceneGizmoOverlay.swift`.
//
// The extraction's value is that ONE state answers "what does the gizmo
// look like right now" for both consumers, so the first test is the one
// that pins the stabilised camera to the real one: a recentre-then-slide
// that did not land back on the object's true pixel would put the drawn
// manipulator somewhere the pointer is not.
//
// The rest assert what the Swift source says each piece exists to prevent:
// one uniform scale rather than three differently sized arrows, an axis
// too foreshortened to trust refusing its handle instead of dividing a
// delta by almost nothing, a ring CUT at the near plane rather than closed
// across the gap, and a plane handle withdrawn on the same fact that would
// make its ray-plane intersection ill-conditioned.

#include "umeshcore/Editor/SceneGizmoState.h"

#include <cmath>

#include "TestHarness.h"

using namespace umeshcore;

namespace {

const Vec2 kViewSize(1600, 900);

SceneProjection realCamera(const Vec3& eye = Vec3(0, 0, -1200), float yaw = 0.0f) {
    return SceneProjection(eye, 0.0f, yaw, 0.0f, 45.0f, 1.0f, 100000.0f, kViewSize);
}

SceneLayer shearedCard() {
    SceneLayer layer;
    layer.position = Vec2(140, -60);
    layer.positionZ = 200;
    layer.rotation = 0.6f;
    layer.rotation3D = Vec3(0.3f, -0.5f, 0);
    layer.scale = Vec2(2.4f, 0.7f);
    layer.shear = Vec2(0.5f, -0.3f);
    return layer;
}

} // namespace

static void testTheStabilisedCameraLandsBackOnTheObjectsOwnPixel() {
    // The recentre-then-slide, end to end: the gizmo camera puts the pivot
    // dead centre, and the screen offset puts it back where the real
    // camera says it is. If those two disagree the manipulator is drawn
    // somewhere the pointer is not.
    const SceneProjection real = realCamera();
    const SceneLayer layer = shearedCard();
    const auto state = sceneGizmoState(layerBasis(layer), real, kViewSize);
    UM_CHECK(state.has_value());

    const auto centred = state->projection.project(state->basis.origin);
    UM_CHECK(centred.has_value());
    UM_CHECK_NEAR(centred->x, kViewSize.x * 0.5, 1e-2); // dead centre
    UM_CHECK_NEAR(centred->y, kViewSize.y * 0.5, 1e-2);

    const auto slid = state->map(state->basis.origin);
    const auto truth = real.project(state->basis.origin);
    UM_CHECK(slid.has_value() && truth.has_value());
    UM_CHECK_NEAR(slid->x, truth->x, 1e-2);
    UM_CHECK_NEAR(slid->y, truth->y, 1e-2);

    // Same eye, so anything reading `.eye` reads the same point either
    // way -- the stabilised camera is a shape device, not a second
    // viewpoint.
    UM_CHECK(state->projection.eye == real.eye);
}

static void testTheGizmoCameraIsNearlyOrthographicComparedToTheReal() {
    // The narrow fixed field of view is the whole reason for the
    // stabilisation: an object at the edge of a wide frame is drawn
    // undistorted.
    const SceneProjection real = realCamera();
    const Vec3 offAxis(2500, 1400, 400);
    const SceneProjection gizmo = gizmoProjection(offAxis, real, kViewSize);
    UM_CHECK(gizmo.focalLength > real.focalLength * 5.0f);

    // A degenerate case takes the real projection rather than dividing by
    // zero: an eye sitting exactly on the origin has no direction to look
    // along, and NaNs here would be a gizmo that silently fails to draw.
    const SceneProjection fallback = gizmoProjection(real.eye, real, kViewSize);
    UM_CHECK(fallback.focalLength == real.focalLength);
}

static void testOneScaleForTheWholeManipulatorAndTheSameSizeAtEveryDepth() {
    const SceneProjection real = realCamera();
    SceneLayer layer;
    layer.positionZ = 0;
    const auto state = sceneGizmoState(worldBasis(layer), real, kViewSize);
    UM_CHECK(state.has_value());

    // Three axes, ONE world length -- the arrow mesh scales uniformly.
    // What differs is what the projection does to them, which is its job.
    const auto x = projectAxis(*state, state->basis.x);
    const auto y = projectAxis(*state, state->basis.y);
    const auto z = projectAxis(*state, state->basis.z);
    UM_CHECK(x.has_value() && y.has_value());
    const float xPixels = length(x->tip - x->origin);
    const float yPixels = length(y->tip - y->origin);
    UM_CHECK_NEAR(xPixels, yPixels, 1e-2); // one scale, not three
    // Z points straight away from a camera looking down +Z, so it
    // foreshortens to nothing and its handle is refused rather than drawn
    // as a dot a drag would divide by.
    UM_CHECK(!z.has_value());

    // The scale is the world length that projects to the handle's pixel
    // size at the pivot's depth THROUGH THE REAL CAMERA.
    const auto direct =
        real.worldLengthForPixels(kSceneGizmoHandlePixels, real.depth(layer.worldOrigin()));
    UM_CHECK(direct.has_value());
    UM_CHECK_NEAR(state->scale, *direct, 1e-4);

    // And because the handles are DRAWN through the stabilised camera, the
    // length on screen is that nominal size magnified by the ratio of the
    // two focal lengths -- see the header. The number is not the point;
    // that it is a fixed ratio is.
    const float ratio = state->projection.focalLength / real.focalLength;
    UM_CHECK_NEAR(xPixels, kSceneGizmoHandlePixels * ratio, 0.5);

    // THE PROPERTY THAT MATTERS: the same size at every depth, which is
    // what an artist relies on to grab a handle.
    for (float depth : {800.0f, 3000.0f, 12000.0f}) {
        SceneLayer moved;
        moved.positionZ = depth;
        const auto farther = sceneGizmoState(worldBasis(moved), real, kViewSize);
        UM_CHECK(farther.has_value());
        UM_CHECK(farther->scale > state->scale); // further away, bigger in world
        const auto axis = projectAxis(*farther, farther->basis.x);
        UM_CHECK(axis.has_value());
        UM_CHECK_NEAR(length(axis->tip - axis->origin), xPixels, 1e-2);
    }

    // Off the view axis it shrinks a little, and that is the Swift's
    // behaviour rather than this port's: the real projection measures
    // depth along its forward while the gizmo camera measures the true
    // distance to the pivot.
    SceneLayer offAxis;
    offAxis.position = Vec2(600, 0);
    const auto side = sceneGizmoState(worldBasis(offAxis), real, kViewSize);
    UM_CHECK(side.has_value());
    const auto sideAxis = projectAxis(*side, side->basis.x);
    UM_CHECK(sideAxis.has_value());
    const float sidePixels = length(sideAxis->tip - sideAxis->origin);
    UM_CHECK(sidePixels < xPixels);
    UM_CHECK(sidePixels > xPixels * 0.7f); // bounded, not collapsing
}

static void testAnAxisPointingAwayIsDimmedNotDropped() {
    const SceneProjection real = realCamera();
    SceneLayer layer;
    const auto state = sceneGizmoState(worldBasis(layer), real, kViewSize);
    UM_CHECK(state.has_value());
    // The camera looks along +Z, so +Z goes away from the viewer and -Z
    // comes toward it.
    UM_CHECK(axisDepthAlpha(*state, Vec3(0, 0, 1)) == kSceneGizmoAwayAlpha);
    UM_CHECK(axisDepthAlpha(*state, Vec3(0, 0, -1)) == 1.0f);
    // An axis across the view is neither: it stays at full strength,
    // because neither end is further away.
    UM_CHECK(axisDepthAlpha(*state, Vec3(1, 0, 0)) == 1.0f);
}

static void testTranslateKeepsTheWorldAxesWhileTheOtherToolsFollowTheCard() {
    const SceneLayer layer = shearedCard();
    const SceneGizmoBasis moving = translateBasis(layer, SceneGizmoTool::kTranslate);
    // The handle that answers "where is X" must not change answer because
    // the card turned.
    UM_CHECK(moving.x == Vec3(1, 0, 0));
    UM_CHECK(moving.y == Vec3(0, 1, 0));
    UM_CHECK(moving.z == Vec3(0, 0, 1));
    UM_CHECK(moving.origin == layer.worldOrigin());

    for (SceneGizmoTool tool :
         {SceneGizmoTool::kRotate, SceneGizmoTool::kScale, SceneGizmoTool::kShear}) {
        const SceneGizmoBasis basis = translateBasis(layer, tool);
        UM_CHECK(basis.x != Vec3(1, 0, 0)); // along the card, not the world
        // And still a ROTATION, however sheared the card is -- the whole
        // reason `orientation()` exists apart from `planePoint`.
        UM_CHECK_NEAR(length(basis.x), 1.0, 1e-5);
        UM_CHECK_NEAR(dot(basis.x, basis.y), 0.0, 1e-5);
        UM_CHECK_NEAR(dot(basis.y, basis.z), 0.0, 1e-5);
    }

    // The handle ids name the axes, and nothing else does.
    const SceneGizmoBasis basis = layerBasis(layer);
    UM_CHECK(basis.direction(SceneGizmoHandleId::kAxisY).value() == basis.y);
    UM_CHECK(!basis.direction(SceneGizmoHandleId::kPlaneXY).has_value());
    UM_CHECK(!basis.direction(SceneGizmoHandleId::kFree).has_value());
}

static void testALightsBasisIsItsBeamExceptForAPointLight() {
    SceneLight light;
    light.position = Vec2(50, 20);
    light.positionZ = -400;
    light.kind = SceneLightKind::kPoint;
    // A point light has no orientation, and handles along an invented one
    // would turn with nothing.
    const SceneGizmoBasis point = lightBasis(light);
    UM_CHECK(point.x == Vec3(1, 0, 0) && point.z == Vec3(0, 0, 1));
    UM_CHECK(point.origin == light.world());

    light.kind = SceneLightKind::kSpot;
    light.azimuth = 0.8f;
    light.elevation = -0.4f;
    const SceneGizmoBasis spot = lightBasis(light);
    // z is where it points, so translating along z walks it up its own
    // beam and the rings about x and y aim it.
    UM_CHECK_NEAR(length(spot.z - light.direction()), 0.0, 1e-5);
    UM_CHECK_NEAR(dot(spot.x, spot.z), 0.0, 1e-5);
    UM_CHECK_NEAR(dot(spot.y, spot.z), 0.0, 1e-5);
    UM_CHECK_NEAR(length(spot.x), 1.0, 1e-5);
}

static void testAWhollyVisibleRingComesBackAsOneClosedArc() {
    const SceneProjection real = realCamera();
    SceneLayer layer;
    layer.positionZ = 0;
    const auto state = sceneGizmoState(worldBasis(layer), real, kViewSize);
    UM_CHECK(state.has_value());

    const auto arcs = ringArcs(*state, Vec3(0, 0, 1), state->scale);
    UM_CHECK(arcs.size() == 1);
    UM_CHECK(arcs[0].size() == static_cast<std::size_t>(kSceneGizmoRingSamples));
    // An ellipse, or a circle here: consecutive samples are evenly spaced
    // and nothing jumps.
    float longest = 0.0f;
    for (std::size_t i = 1; i < arcs[0].size(); ++i) {
        longest = std::max(longest, length(arcs[0][i] - arcs[0][i - 1]));
    }
    UM_CHECK(longest < kSceneGizmoHandlePixels);
}

static void testARingCrossingTheNearPlaneIsCutAndNotClosedAcrossTheGap() {
    // The one thing the CPU path does that the GPU path does not have to:
    // a polyline has no notion of clip-space clipping, so joining the
    // pieces would draw a chord straight across the gap.
    const SceneProjection real = realCamera(Vec3(0, 0, -30));
    SceneLayer layer;
    layer.positionZ = 0; // 30 units in front of an eye with a 1-unit near plane
    const auto state = sceneGizmoState(worldBasis(layer), real, kViewSize);
    UM_CHECK(state.has_value());

    // A ring far larger than the pivot's distance to the eye: part of it
    // is behind the near plane.
    const auto arcs = ringArcs(*state, Vec3(0, 1, 0), 400.0f);
    UM_CHECK(arcs.size() >= 1);
    std::size_t total = 0;
    for (const auto& arc : arcs) total += arc.size();
    UM_CHECK(total < static_cast<std::size_t>(kSceneGizmoRingSamples)); // some of it was cut

    // Inside an arc, neighbouring samples stay neighbours. If the cut were
    // skipped and the pieces joined, one step would span the whole gap.
    if (arcs.size() >= 2) {
        float longestInside = 0.0f;
        for (const auto& arc : arcs) {
            for (std::size_t i = 1; i < arc.size(); ++i) {
                longestInside = std::max(longestInside, length(arc[i] - arc[i - 1]));
            }
        }
        const float acrossTheGap = length(arcs[1].front() - arcs[0].back());
        UM_CHECK(acrossTheGap > longestInside);
    }
}

static void testAPlaneHandleIsWithdrawnWhenItIsASliver() {
    const SceneProjection real = realCamera();
    SceneLayer layer;
    layer.positionZ = 0;
    const auto state = sceneGizmoState(worldBasis(layer), real, kViewSize);
    UM_CHECK(state.has_value());

    // XY faces the camera square-on: offered, four corners.
    const auto facing = planeQuad(*state, SceneGizmoHandleId::kPlaneXY);
    UM_CHECK(facing.has_value() && facing->size() == 4);
    // The quad sits OFF the origin, so it never covers the free-move
    // handle, and short of the arrowheads.
    const auto originPx = state->map(state->basis.origin);
    const auto axis = projectAxis(*state, state->basis.x);
    UM_CHECK(originPx.has_value() && axis.has_value());
    // Measured against the DRAWN axis length rather than against the
    // nominal constant, because the two differ by the stabilised camera's
    // magnification (see the header).
    const float drawn = length(axis->tip - axis->origin);
    for (const Vec2& corner : *facing) {
        const float away = length(corner - *originPx);
        UM_CHECK(away > kSceneGizmoPlaneOffset * drawn * 0.9f);
        UM_CHECK(away < drawn); // short of the arrowheads
    }

    // XZ and YZ are seen edge-on from here: withdrawn, on the same fact
    // that makes the intersection behind them ill-conditioned.
    UM_CHECK(!planeQuad(*state, SceneGizmoHandleId::kPlaneXZ).has_value());
    UM_CHECK(!planeQuad(*state, SceneGizmoHandleId::kPlaneYZ).has_value());
    // And an id that names no plane is not a plane.
    UM_CHECK(!planeQuad(*state, SceneGizmoHandleId::kAxisX).has_value());

    // The pairs a plane spans, and the normal it is seen through.
    const SceneGizmoBasis basis = state->basis;
    UM_CHECK(planeNormal(SceneGizmoHandleId::kPlaneXY, basis).value() == basis.z);
    UM_CHECK(planeNormal(SceneGizmoHandleId::kPlaneXZ, basis).value() == basis.y);
    UM_CHECK(planeNormal(SceneGizmoHandleId::kPlaneYZ, basis).value() == basis.x);
    UM_CHECK(planeAxes(SceneGizmoHandleId::kPlaneXZ, basis).b == basis.z);
}

static void testAPivotBehindTheEyeHasNoGizmoAtAll() {
    const SceneProjection real = realCamera();
    SceneLayer layer;
    layer.positionZ = -5000; // well behind the eye
    UM_CHECK(!sceneGizmoState(worldBasis(layer), real, kViewSize).has_value());
}

UM_TEST_MAIN_BEGIN()
    testTheStabilisedCameraLandsBackOnTheObjectsOwnPixel();
    testTheGizmoCameraIsNearlyOrthographicComparedToTheReal();
    testOneScaleForTheWholeManipulatorAndTheSameSizeAtEveryDepth();
    testAnAxisPointingAwayIsDimmedNotDropped();
    testTranslateKeepsTheWorldAxesWhileTheOtherToolsFollowTheCard();
    testALightsBasisIsItsBeamExceptForAPointLight();
    testAWhollyVisibleRingComesBackAsOneClosedArc();
    testARingCrossingTheNearPlaneIsCutAndNotClosedAcrossTheGap();
    testAPlaneHandleIsWithdrawnWhenItIsASliver();
    testAPivotBehindTheEyeHasNoGizmoAtAll();
UM_TEST_MAIN_END()
