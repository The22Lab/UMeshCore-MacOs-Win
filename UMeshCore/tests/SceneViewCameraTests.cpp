// Tests for Render/SceneViewCamera.h, ported from `SceneViewCamera`
// (Data/Scene/SceneComposition.swift) and the camera math of
// `Render/SceneViewProjection.swift`.
//
// The properties asserted here are the ones the Swift headers say the code
// exists to hold:
//
//   - The eye the ORBIT computes is the eye the PROJECTION projects from,
//     so the pivot stays in the middle of the screen at every angle. The
//     Swift file names the alternative explicitly: "two transcriptions of
//     'forward' is how the pivot would end up somewhere other than the
//     middle of the screen".
//   - A pan of N pixels moves the picture by exactly N pixels. The
//     world-per-pixel formula and the focal length are two halves of one
//     identity; if either drifts, dragging the view slides under the
//     pointer, which is the same class of bug as the 313 px gizmo drift
//     `SceneProjection` documents.
//   - `shotFrame` is the rectangle that exactly fills the render at a
//     distance -- so its corners project to the render's corners, at any
//     distance and any shot rotation.

#include "umeshcore/Render/SceneViewCamera.h"

#include <cmath>

#include "TestHarness.h"

using namespace umeshcore;

namespace {
constexpr float kPi = 3.14159265358979323846f;
}

static void testFrontOnEyeSitsBackAlongMinusZ() {
    SceneViewCamera camera;
    camera.pivot = Vec3(10, 20, 30);
    camera.distance = 500;
    // Looking along +Z, so backing away from the pivot means going -Z.
    const Vec3 eye = camera.eye();
    UM_CHECK_NEAR(eye.x, 10.0, 1e-4);
    UM_CHECK_NEAR(eye.y, 20.0, 1e-4);
    UM_CHECK_NEAR(eye.z, -470.0, 1e-3);
}

static void testTheEyeOrbitsOnASphereAroundThePivot() {
    SceneViewCamera camera;
    camera.pivot = Vec3(-100, 50, 200);
    camera.distance = 1234;
    for (int i = 0; i < 24; ++i) {
        camera.orbit(0.31f, 0.11f);
        UM_CHECK_NEAR(length(camera.eye() - camera.pivot), 1234.0, 1e-2);
    }
}

static void testThePivotStaysInTheMiddleOfTheScreenAtEveryAngle() {
    // The one property that catches a second transcription of "forward":
    // a basis that disagrees with the orbit moves the pivot off centre.
    SceneViewCamera camera;
    camera.pivot = Vec3(40, -60, 900);
    camera.distance = 2000;
    const Vec2 viewSize(1280, 720);
    for (int i = 0; i < 16; ++i) {
        camera.orbit(0.4f, 0.09f);
        const auto centre = camera.projection(viewSize).project(camera.pivot);
        UM_CHECK(centre.has_value());
        UM_CHECK_NEAR(centre->x, 640.0, 1e-2);
        UM_CHECK_NEAR(centre->y, 360.0, 1e-2);
    }
}

static void testPitchIsClampedAwayFromThePoles() {
    SceneViewCamera camera;
    for (int i = 0; i < 100; ++i) camera.orbit(0.0f, 0.5f);
    UM_CHECK_NEAR(camera.pitch, SceneViewCamera::kPitchLimit, 1e-6);
    for (int i = 0; i < 200; ++i) camera.orbit(0.0f, -0.5f);
    UM_CHECK_NEAR(camera.pitch, -SceneViewCamera::kPitchLimit, 1e-6);
    // At the limit the up vector is still well away from the view axis,
    // which is the reason for the clamp: at the pole the horizon spins.
    UM_CHECK(std::fabs(camera.pitch) < kPi * 0.5f);
    // Yaw is NOT clamped -- turning all the way round is allowed.
    camera.orbit(100.0f, 0.0f);
    UM_CHECK(camera.yaw > 10.0f);
}

static void testDollyIsMultiplicativeAndClamped() {
    SceneViewCamera camera;
    camera.distance = 1000;
    camera.dolly(0.5f);
    UM_CHECK_NEAR(camera.distance, 500.0, 1e-3);
    // The eye can never cross the pivot and turn the view inside out.
    for (int i = 0; i < 100; ++i) camera.dolly(0.5f);
    UM_CHECK_NEAR(camera.distance, SceneViewCamera::kMinDistance, 1e-4);
    for (int i = 0; i < 200; ++i) camera.dolly(2.0f);
    UM_CHECK_NEAR(camera.distance, SceneViewCamera::kMaxDistance, 1e-1);
}

static void testAPanOfNPixelsMovesThePictureByNPixels() {
    SceneViewCamera camera;
    camera.pivot = Vec3(0, 0, 0);
    camera.distance = 1500;
    camera.orbit(0.7f, -0.3f); // an angled view, where a wrong basis shows
    const Vec2 viewSize(1000, 800);
    const Vec3 marker = camera.pivot; // what sat at the screen centre
    const auto before = camera.projection(viewSize).project(marker);
    UM_CHECK(before.has_value());

    camera.pan(Vec2(37, -21), viewSize.y);
    const auto after = camera.projection(viewSize).project(marker);
    UM_CHECK(after.has_value());
    // World-per-pixel and focal length are inverses of each other, so the
    // marker follows the drag exactly -- one pixel per pixel.
    UM_CHECK_NEAR(after->x - before->x, 37.0, 1e-2);
    UM_CHECK_NEAR(after->y - before->y, -21.0, 1e-2);
}

static void testPanMovesThePivotAcrossTheViewPlaneOnly() {
    SceneViewCamera camera;
    camera.distance = 900;
    camera.orbit(1.1f, 0.42f);
    const Vec3 forward = cameraBasis(camera.pitch, camera.yaw, 0.0f).forward;
    const Vec3 before = camera.pivot;
    camera.pan(Vec2(120, 80), 800.0f);
    // Across the view plane: the pan never changes how far away the set is.
    UM_CHECK_NEAR(dot(camera.pivot - before, forward), 0.0, 1e-2);
    UM_CHECK_NEAR(length(camera.eye() - camera.pivot), 900.0, 1e-2);
}

static void testShotFrameExactlyFillsTheRender() {
    const Vec3 eye(120, -40, -800);
    const Vec3 rotation(0.23f, -0.51f, 0.17f);
    const Vec2 renderSize(1920, 1080);
    const SceneProjection shot(
        eye, rotation.x, rotation.y, rotation.z, 50.0f, 1.0f, 100000.0f, renderSize);
    for (float distance : {300.0f, 2000.0f, 9000.0f}) {
        const auto corners = shotFrame(eye, rotation, 50.0f, renderSize, distance);
        UM_CHECK(corners.size() == 4);
        const float expected[4][2] = {{0, 0}, {1920, 0}, {1920, 1080}, {0, 1080}};
        for (int i = 0; i < 4; ++i) {
            const auto screen = shot.project(corners[static_cast<std::size_t>(i)]);
            UM_CHECK(screen.has_value());
            // Loose in pixels, tight in relative terms: at 9000 units out
            // a 1e-3 relative error is already 2 px.
            UM_CHECK_NEAR(screen->x, expected[i][0], 0.05);
            UM_CHECK_NEAR(screen->y, expected[i][1], 0.05);
        }
    }
}

static void testShotFrameIsOneToOneAtTheFocalPlane() {
    // At the focal length for the render height, one world unit is one
    // pixel -- the plane where a new layer is placed.
    const Vec2 renderSize(1000, 800);
    const float fov = 45.0f;
    const float focal = (renderSize.y * 0.5f) / std::tan(fov * kPi / 180.0f * 0.5f);
    const auto corners = shotFrame(Vec3::zero(), Vec3::zero(), fov, renderSize, focal);
    UM_CHECK_NEAR(length(corners[1] - corners[0]), 1000.0, 1e-2);
    UM_CHECK_NEAR(length(corners[2] - corners[1]), 800.0, 1e-2);
    // Corner order: top-left, top-right, bottom-right, bottom-left, seen
    // from the front (world +Y is up).
    UM_CHECK(corners[0].x < corners[1].x);
    UM_CHECK(corners[0].y > corners[3].y);
}

UM_TEST_MAIN_BEGIN()
    testFrontOnEyeSitsBackAlongMinusZ();
    testTheEyeOrbitsOnASphereAroundThePivot();
    testThePivotStaysInTheMiddleOfTheScreenAtEveryAngle();
    testPitchIsClampedAwayFromThePoles();
    testDollyIsMultiplicativeAndClamped();
    testAPanOfNPixelsMovesThePictureByNPixels();
    testPanMovesThePivotAcrossTheViewPlaneOnly();
    testShotFrameExactlyFillsTheRender();
    testShotFrameIsOneToOneAtTheFocalPlane();
UM_TEST_MAIN_END()
