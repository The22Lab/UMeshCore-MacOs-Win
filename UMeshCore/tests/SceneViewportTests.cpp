// Tests for Editor/SceneViewport.h, ported from the portable math inside
// `SceneViewportView.swift`'s view body.
//
// Every numeric expectation below is derived BY HAND against the ported
// formulas, before running the code, per CLAUDE.md convention #4 -- a
// test that recomputed the same arithmetic as the port would only prove
// the port agrees with itself.

#include "umeshcore/Editor/SceneViewport.h"

#include <cmath>
#include <limits>

#include "TestHarness.h"

using namespace umeshcore;

static void testFittedRectLetterboxesAndCentersWhenFlying() {
    // 1000x500 image into a 400x400 view: the width ratio (0.4) is the
    // tighter one, so it wins and the result is letterboxed top/bottom.
    const Vec2 pixelSize(1000.0f, 500.0f);
    const Vec2 viewSize(400.0f, 400.0f);
    const Bounds2D fitted = fittedRect(pixelSize, viewSize, /*isFlying=*/true, SceneFrontView{});

    UM_CHECK_NEAR(fitted.min.x, 0.0, 1e-5);
    UM_CHECK_NEAR(fitted.min.y, 100.0, 1e-5);
    UM_CHECK_NEAR(fitted.max.x, 400.0, 1e-5);
    UM_CHECK_NEAR(fitted.max.y, 300.0, 1e-5);

    // Flying has a real camera; a non-identity front view must be ignored
    // entirely -- applying it too would be two navigations fighting over
    // one set of fingers.
    SceneFrontView front;
    front.pan = Vec2(500.0f, -500.0f);
    front.zoom = 5.0f;
    const Bounds2D ignoredFront = fittedRect(pixelSize, viewSize, /*isFlying=*/true, front);
    UM_CHECK(ignoredFront.min == fitted.min);
    UM_CHECK(ignoredFront.max == fitted.max);
}

static void testFittedRectAppliesFrontViewPanAndZoomOnTopOfTheBaseFit() {
    // Same base fit as above (min (0,100), max (400,300), center (200,200)),
    // now not flying, with zoom 2 and pan (10, -5).
    const Vec2 pixelSize(1000.0f, 500.0f);
    const Vec2 viewSize(400.0f, 400.0f);
    SceneFrontView front;
    front.zoom = 2.0f;
    front.pan = Vec2(10.0f, -5.0f);

    const Bounds2D fitted = fittedRect(pixelSize, viewSize, /*isFlying=*/false, front);

    // zoomedSize = (400*2, 200*2) = (800, 400).
    // zoomedMin.x = center.x(200) - 800/2 + pan.x(10) = -190.
    // zoomedMin.y = center.y(200) - 400/2 + pan.y(-5) = -5.
    UM_CHECK_NEAR(fitted.min.x, -190.0, 1e-4);
    UM_CHECK_NEAR(fitted.min.y, -5.0, 1e-4);
    UM_CHECK_NEAR(fitted.max.x, 610.0, 1e-4);
    UM_CHECK_NEAR(fitted.max.y, 395.0, 1e-4);
}

static void testViewPointAndImagePointAreExactInverses() {
    // fitted: min (50,60), size (400,300) -- picked so the numbers are
    // clean by hand.
    const Bounds2D fitted{Vec2(50.0f, 60.0f), Vec2(450.0f, 360.0f)};
    const Vec2 pixelSize(800.0f, 600.0f);

    // The image's exact center should land at the fitted rect's center.
    const Vec2 imageCenter(400.0f, 300.0f);
    const Vec2 viewCenter = viewPointFromImage(imageCenter, pixelSize, fitted);
    UM_CHECK_NEAR(viewCenter.x, 250.0, 1e-4); // 50 + (400/800)*400 = 50+200 = 250
    UM_CHECK_NEAR(viewCenter.y, 210.0, 1e-4); // 60 + (300/600)*300 = 60+150 = 210

    // Round-tripping a grid of points must return exactly what went in --
    // a drag that reads a pixel and stores a value must land back on the
    // same pixel, to floating-point precision.
    for (float ix : {0.0f, 137.5f, 400.0f, 799.0f}) {
        for (float iy : {0.0f, 42.0f, 300.0f, 599.0f}) {
            const Vec2 image(ix, iy);
            const Vec2 view = viewPointFromImage(image, pixelSize, fitted);
            const Vec2 back = imagePointFromView(view, pixelSize, fitted);
            UM_CHECK_NEAR(back.x, ix, 1e-2);
            UM_CHECK_NEAR(back.y, iy, 1e-2);
        }
    }
}

static void testRenderPixelSizeFlyingCapsByTheLongestSideThenAppliesDisplayScale() {
    // view 2000x1000, displayScale 2, not provisional (ladder = 1).
    // cap = maxEditorPixels(2400) * 1 = 2400.
    // longest = max(2000,1000) * 2 = 4000.
    // scale = min(1, 2400/4000) * 2 = 0.6 * 2 = 1.2.
    // result = (2000*1.2, 1000*1.2) = (2400, 1200).
    const Vec2 result = renderPixelSize(Vec2(2000.0f, 1000.0f), /*displayScale=*/2.0f,
                                         /*isFlying=*/true, /*isProvisional=*/false,
                                         /*budgetScale=*/1.0f, Vec2(1920.0f, 1080.0f));
    UM_CHECK_NEAR(result.x, 2400.0, 1e-3);
    UM_CHECK_NEAR(result.y, 1200.0, 1e-3);
}

static void testRenderPixelSizeFlyingProvisionalUsesTheInteractiveCapAndTheLadder() {
    // view 2000x1000, displayScale 1, provisional with a ladder at 0.75.
    // base = interactiveEditorPixels(1200); cap = 1200*0.75 = 900.
    // longest = max(2000,1000)*1 = 2000.
    // scale = min(1, 900/2000)*1 = 0.45.
    // result = (2000*0.45, 1000*0.45) = (900, 450).
    const Vec2 result = renderPixelSize(Vec2(2000.0f, 1000.0f), /*displayScale=*/1.0f,
                                         /*isFlying=*/true, /*isProvisional=*/true,
                                         /*budgetScale=*/0.75f, Vec2(1920.0f, 1080.0f));
    UM_CHECK_NEAR(result.x, 900.0, 1e-3);
    UM_CHECK_NEAR(result.y, 450.0, 1e-3);
}

static void testRenderPixelSizeFrontViewFollowsTheShotAspectNotTheViewport() {
    // view 1000x1000 (square), composition 1920x1080 (16:9).
    // aspect = 1920/1080 = 1.77778; base = maxShotPixels(1800).
    // height = min(1000*1, 1800*1) = 1000; width = 1000*1.77778 = 1777.78.
    const Vec2 result = renderPixelSize(Vec2(1000.0f, 1000.0f), /*displayScale=*/1.0f,
                                         /*isFlying=*/false, /*isProvisional=*/false,
                                         /*budgetScale=*/1.0f, Vec2(1920.0f, 1080.0f));
    UM_CHECK_NEAR(result.y, 1000.0, 1e-3);
    UM_CHECK_NEAR(result.x, 1777.7778, 1e-2);
}

static void testRenderPixelSizeFallsBackToSixteenWhenTheViewportHasCollapsed() {
    // A pane mid-resize or a hidden tab: either dimension at or below one
    // point must not reach the pixel-cap math at all.
    const Vec2 collapsedWidth = renderPixelSize(Vec2(0.5f, 500.0f), 2.0f, false, false, 1.0f,
                                                 Vec2(1920.0f, 1080.0f));
    UM_CHECK_NEAR(collapsedWidth.x, 16.0, 1e-6);
    UM_CHECK_NEAR(collapsedWidth.y, 16.0, 1e-6);

    const Vec2 collapsedHeight = renderPixelSize(Vec2(500.0f, 1.0f), 2.0f, true, false, 1.0f,
                                                  Vec2(1920.0f, 1080.0f));
    UM_CHECK_NEAR(collapsedHeight.x, 16.0, 1e-6);
    UM_CHECK_NEAR(collapsedHeight.y, 16.0, 1e-6);
}

static void testRenderPixelSizePropagatesANaNCompositionHeightRatherThanSwallowingIt() {
    // The exact failure the file banner documents: a composition with a
    // NaN render height must make `renderPixelSize`'s output NaN too, not
    // silently fall back to some finite aspect -- `integerPixels`
    // downstream is what is supposed to catch this, not this function.
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const Vec2 result = renderPixelSize(Vec2(1000.0f, 1000.0f), 1.0f, /*isFlying=*/false, false,
                                         1.0f, Vec2(1920.0f, nan));
    UM_CHECK(std::isnan(result.x));
}

static void testIntegerPixelsRejectsNaNInfinityAndOutOfRangeValues() {
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();

    UM_CHECK(!integerPixels(Vec2(nan, 100.0f)).has_value());
    UM_CHECK(!integerPixels(Vec2(inf, 100.0f)).has_value());
    UM_CHECK(!integerPixels(Vec2(0.5f, 100.0f)).has_value());   // below the floor of 1.
    UM_CHECK(!integerPixels(Vec2(65536.0f, 100.0f)).has_value()); // at the ceiling.

    const auto ok = integerPixels(Vec2(800.0f, 600.0f));
    UM_CHECK(ok.has_value());
    UM_CHECK(ok->width == 800);
    UM_CHECK(ok->height == 600);
}

static void testSceneFrontViewZoomClampsToTheNamedRange() {
    SceneFrontView front;
    front.zoom = 1.0f;
    front.zoomBy(0.01f); // would drive it under the floor.
    UM_CHECK_NEAR(front.zoom, SceneFrontView::kMinZoom, 1e-6);

    front.zoom = 1.0f;
    front.zoomBy(1000.0f); // would drive it over the ceiling.
    UM_CHECK_NEAR(front.zoom, SceneFrontView::kMaxZoom, 1e-6);

    UM_CHECK(SceneFrontView::identity().isIdentity());
    SceneFrontView notIdentity;
    notIdentity.pan = Vec2(1.0f, 0.0f);
    UM_CHECK(!notIdentity.isIdentity());
}

static void testPinchZoomHoldsTheAnchorPointUnderThePointer() {
    // A card at the exact center of a square viewport, anchor also at the
    // center: zooming in must leave the center exactly where it was --
    // the property the whole function exists to guarantee.
    const Vec2 pixelSize(1000.0f, 1000.0f);
    const Vec2 viewSize(800.0f, 800.0f);
    const Vec2 center(400.0f, 400.0f); // viewSize / 2.

    SceneFrontView front;
    for (int step = 0; step < 8; ++step) {
        front = pinchZoomFrontView(front, 1.3f, center, pixelSize, viewSize);
    }
    UM_CHECK(front.zoom > 1.0f);

    const Bounds2D fitted = fittedRect(pixelSize, viewSize, false, front);
    const Vec2 imageAtCenter = imagePointFromView(center, pixelSize, fitted);
    // The center of the viewport must still map to the center of the
    // image after eight zoom steps, to well within a pixel.
    UM_CHECK_NEAR(imageAtCenter.x, 500.0, 0.5);
    UM_CHECK_NEAR(imageAtCenter.y, 500.0, 0.5);
}

static void testPinchZoomOffCenterAnchorStaysUnderThePointerToo() {
    // Same setup, but the anchor is NOT the viewport's center -- the case
    // that actually exercises the pan correction rather than leaving it
    // at zero by symmetry.
    const Vec2 pixelSize(1000.0f, 1000.0f);
    const Vec2 viewSize(800.0f, 800.0f);
    const Vec2 anchor(650.0f, 250.0f);

    SceneFrontView front;
    const Bounds2D beforeFit = fittedRect(pixelSize, viewSize, false, front);
    const Vec2 imageUnderAnchorBefore = imagePointFromView(anchor, pixelSize, beforeFit);

    for (int step = 0; step < 5; ++step) {
        front = pinchZoomFrontView(front, 1.5f, anchor, pixelSize, viewSize);
    }

    const Bounds2D afterFit = fittedRect(pixelSize, viewSize, false, front);
    const Vec2 imageUnderAnchorAfter = imagePointFromView(anchor, pixelSize, afterFit);

    UM_CHECK_NEAR(imageUnderAnchorAfter.x, imageUnderAnchorBefore.x, 0.5);
    UM_CHECK_NEAR(imageUnderAnchorAfter.y, imageUnderAnchorBefore.y, 0.5);
}

static void testPinchZoomIsANoOpBelowTheScaleFloor() {
    // Swift's guard: `scale > 0.01` must hold or the whole call is a
    // no-op -- a collapsed step must not divide anything by near-zero.
    SceneFrontView front;
    front.pan = Vec2(3.0f, 4.0f);
    front.zoom = 2.0f;

    const SceneFrontView result =
        pinchZoomFrontView(front, 0.01f, Vec2(100.0f, 100.0f), Vec2(500.0f, 500.0f), Vec2(500.0f, 500.0f));
    UM_CHECK(result.pan == front.pan);
    UM_CHECK_NEAR(result.zoom, front.zoom, 1e-6);
}

static void testDepthDragScalesByDistanceAndClampsPastTheNearPlane() {
    // startZ 500, camera at Z 0 with nearZ 10: distance = max(500-0,1) = 500.
    // A 100pt upward drag (negative translation) over an 800pt-tall view:
    // dz = -(-100)/800 * 500 * 2 = 0.125*500*2 = 125. z = 500+125 = 625.
    const float pushedBack =
        depthDragZ(/*startZ=*/500.0f, /*cameraPositionZ=*/0.0f, /*cameraNearZ=*/10.0f,
                   /*translationHeightPoints=*/-100.0f, /*viewHeightPoints=*/800.0f);
    UM_CHECK_NEAR(pushedBack, 625.0, 1e-3);

    // The same drag downward (positive translation) pulls the card
    // toward the camera by the same amount: z = 500-125 = 375.
    const float pulledForward =
        depthDragZ(500.0f, 0.0f, 10.0f, /*translationHeightPoints=*/100.0f, 800.0f);
    UM_CHECK_NEAR(pulledForward, 375.0, 1e-3);

    // A huge pull-forward drag must clamp at cameraPositionZ + nearZ + 1,
    // never crossing the near plane.
    const float clamped = depthDragZ(500.0f, 0.0f, 10.0f, /*translationHeightPoints=*/100000.0f, 800.0f);
    UM_CHECK_NEAR(clamped, 0.0 + 10.0 + 1.0, 1e-3);
}

UM_TEST_MAIN_BEGIN()
    testFittedRectLetterboxesAndCentersWhenFlying();
    testFittedRectAppliesFrontViewPanAndZoomOnTopOfTheBaseFit();
    testViewPointAndImagePointAreExactInverses();
    testRenderPixelSizeFlyingCapsByTheLongestSideThenAppliesDisplayScale();
    testRenderPixelSizeFlyingProvisionalUsesTheInteractiveCapAndTheLadder();
    testRenderPixelSizeFrontViewFollowsTheShotAspectNotTheViewport();
    testRenderPixelSizeFallsBackToSixteenWhenTheViewportHasCollapsed();
    testRenderPixelSizePropagatesANaNCompositionHeightRatherThanSwallowingIt();
    testIntegerPixelsRejectsNaNInfinityAndOutOfRangeValues();
    testSceneFrontViewZoomClampsToTheNamedRange();
    testPinchZoomHoldsTheAnchorPointUnderThePointer();
    testPinchZoomOffCenterAnchorStaysUnderThePointerToo();
    testPinchZoomIsANoOpBelowTheScaleFloor();
    testDepthDragScalesByDistanceAndClampsPastTheNearPlane();
UM_TEST_MAIN_END()
