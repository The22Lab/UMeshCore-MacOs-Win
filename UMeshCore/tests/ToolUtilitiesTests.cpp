// Tests for ToolUtilities.h, ported from `Core/ToolUtilities.swift`.
// Expected values are hand-derived from the gizmo metrics and hit-test
// formulas, not from this implementation's own output.

#include <cmath>

#include "umeshcore/Editor/MoveGizmoMetrics.h"
#include "umeshcore/Editor/RotateGizmoMetrics.h"
#include "umeshcore/Editor/SkewGizmoMetrics.h"
#include "umeshcore/Editor/ToolUtilities.h"
#include "umeshcore/Model/Skeleton.h"
#include "TestHarness.h"

using namespace umeshcore;
using namespace umeshcore::ToolUtilities;

static Bone makeBone(std::optional<Uuid> parent, Vec2 localPos, float rotationZ, float length) {
    Bone b;
    b.id = Uuid::generate();
    b.name = "bone";
    b.parentID = parent;
    b.localTransform.position = Vec3(localPos.x, localPos.y, 0);
    b.localTransform.rotation = Vec3(0, 0, rotationZ);
    b.baseTransform = b.localTransform;
    b.length = length;
    b.animationClip = AnimationClip("bone");
    return b;
}

static void testSnapFunctions() {
    UM_CHECK_NEAR(snap(7.3f, 2.0f), 8.0, 1e-4);
    UM_CHECK_NEAR(snap(6.9f, 2.0f), 6.0, 1e-4);
    UM_CHECK_NEAR(snap(5.0f, 0.0f), 5.0, 1e-4); // grid<=0: no-op.
    UM_CHECK_NEAR(snapAngle(kPi / 4.0f + 0.05f, 90.0f), kPi / 2.0, 1e-3); // rounds to nearest 90deg.
    UM_CHECK_NEAR(snapScale(1.24f, 0.1f), 1.2, 1e-4);
}

static void testConstrainAxisPicksDominantAxis() {
    const Vec2 xDominant = constrainAxis(Vec2(10, 3));
    UM_CHECK_NEAR(xDominant.x, 10.0, 1e-4);
    UM_CHECK_NEAR(xDominant.y, 0.0, 1e-4);
    const Vec2 yDominant = constrainAxis(Vec2(2, 8));
    UM_CHECK_NEAR(yDominant.x, 0.0, 1e-4);
    UM_CHECK_NEAR(yDominant.y, 8.0, 1e-4);
}

static void testDistancePointToSegmentClampsToEndpoints() {
    // Point beyond the segment's end: distance is to the endpoint, not the
    // infinite line.
    const float d = distancePointToSegment(Vec2(20, 5), Vec2(0, 0), Vec2(10, 0));
    UM_CHECK_NEAR(d, std::sqrt(10.0 * 10.0 + 5.0 * 5.0), 1e-3);
    // Point directly above the middle of the segment.
    UM_CHECK_NEAR(distancePointToSegment(Vec2(5, 3), Vec2(0, 0), Vec2(10, 0)), 3.0, 1e-4);
}

static void testMoveGizmoHitTestPicksNearestAxis() {
    SceneImage image;
    image.position = Vec2(0, 0);
    image.rotation = 0.0f;

    // Move gizmo axes are drawn at MoveGizmoMetrics::kAxisLengthPx in
    // screen space (device pixels) with no camera (identity projection,
    // screen = world + viewSize/2). Click near the X axis tip.
    const Vec2 viewSize(1000, 1000);
    const Vec2 centerScreen = viewSize * 0.5f;
    const Vec2 nearXAxisTip = centerScreen + Vec2(MoveGizmoMetrics::kAxisLengthPx - 2.0f, 0.0f);

    auto handle = hitTestGizmo(
        ActiveTool::Move, nearXAxisTip, viewSize, &image, Vec2::zero(), std::nullopt, std::nullopt, nullptr,
        false, false, nullptr, /*hitScale=*/1.0f, /*touchOptimized=*/false);
    UM_CHECK(handle.has_value());
    UM_CHECK(std::holds_alternative<MoveXHandle>(*handle));
}

static void testMoveGizmoCenterWinsNearOrigin() {
    SceneImage image;
    image.position = Vec2(0, 0);
    const Vec2 viewSize(1000, 1000);
    const Vec2 centerScreen = viewSize * 0.5f;

    auto handle = hitTestGizmo(
        ActiveTool::Move, centerScreen, viewSize, &image, Vec2::zero(), std::nullopt, std::nullopt, nullptr,
        false, false, nullptr, 1.0f, false);
    UM_CHECK(handle.has_value());
    UM_CHECK(std::holds_alternative<MoveCenterHandle>(*handle));
}

static void testRotateGizmoTrackHitTest() {
    SceneImage image;
    image.position = Vec2(0, 0);
    const Vec2 viewSize(1000, 1000);
    const Vec2 centerScreen = viewSize * 0.5f;
    // Click exactly at the track radius.
    const Vec2 onTrack = centerScreen + Vec2(RotateGizmoMetrics::kTrackRadiusPx, 0.0f);

    auto handle = hitTestGizmo(
        ActiveTool::Rotate, onTrack, viewSize, &image, Vec2::zero(), std::nullopt, std::nullopt, nullptr, false,
        false, nullptr, 1.0f, false);
    UM_CHECK(handle.has_value());
    UM_CHECK(std::holds_alternative<RotateRingHandle>(*handle));
}

static void testSkewGizmoRequiresSelectedImage() {
    const Vec2 viewSize(1000, 1000);
    const Vec2 centerScreen = viewSize * 0.5f;
    const Vec2 onTrack = centerScreen + Vec2(SkewGizmoMetrics::kTrackRadiusPx, 0.0f);
    // No selected image (bone-only selection) -> skew gizmo never grabs.
    Skeleton::LineSegment seg{Vec2(0, 0), Vec2(10, 0)};
    auto handle = hitTestGizmo(
        ActiveTool::Skew, onTrack, viewSize, nullptr, Vec2::zero(), seg, std::nullopt, nullptr, false, false,
        nullptr, 1.0f, false);
    UM_CHECK(!handle.has_value());
}

static void testBoneHitTestMouseJointBeatsShaft() {
    Skeleton skeleton;
    Bone root = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    skeleton.setBone(root);
    skeleton.rootIDs.push_back(root.id);

    const Vec2 viewSize(1000, 1000);
    // Click exactly at the root's world origin (0,0) -> screen center with no camera.
    const Vec2 centerScreen = viewSize * 0.5f;
    auto hit = hitTestBone(centerScreen, viewSize, skeleton, std::nullopt, nullptr, /*touchOptimized=*/false);
    UM_CHECK(hit.has_value() && *hit == root.id);
}

static void testBonesIntersectingMarqueeCatchesCrossingShaft() {
    Skeleton skeleton;
    // A long horizontal bone whose both joints are OUTSIDE a small marquee
    // box, but whose shaft passes straight through it.
    Bone bone = makeBone(std::nullopt, Vec2(-500, 0), 0.0f, 1000.0f);
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);

    const Vec2 viewSize(1000, 1000);
    // World (0,0) projects to screen center with no camera.
    const Vec2 centerScreen = viewSize * 0.5f;
    const ScreenRect marquee{centerScreen - Vec2(10, 10), centerScreen + Vec2(10, 10)};

    const auto hits = bonesIntersecting(marquee, viewSize, skeleton, nullptr);
    UM_CHECK(hits.size() == 1);
    UM_CHECK(hits[0] == bone.id);
}

static void testSegmentIntersectsRectRejectsDiagonalNearMiss() {
    // A diagonal segment whose bounding box overlaps a rect, but the
    // segment itself passes well outside it -- the case the Swift source's
    // comment calls out as the reason for Liang-Barsky over a bbox test.
    const ScreenRect rect{Vec2(40, 40), Vec2(60, 60)};
    // Segment from (0,100) to (100,0): passes through roughly (50,50)?
    // Actually it DOES cross that rect (line x+y=100 passes through (50,50)
    // which is inside [40,60]x[40,60]) -- use a segment whose bbox overlaps
    // but which passes outside the rect instead.
    const bool crosses = segmentIntersectsRect(Vec2(0, 0), Vec2(100, 20), rect);
    UM_CHECK(!crosses); // stays below y=40 for the whole span within x in [40,60].
}

static void testSegmentIntersectsRectAcceptsCrossingShaft() {
    const ScreenRect rect{Vec2(40, 40), Vec2(60, 60)};
    const bool crosses = segmentIntersectsRect(Vec2(0, 50), Vec2(100, 50), rect);
    UM_CHECK(crosses);
}

static void testSoftSelectionWeightsFallOffWithDistance() {
    SceneImage image;
    image.mesh = Mesh::makeQuad("m", Vec2(100, 100));
    // makeQuad's 4 vertices are the hull; add a couple of interior points by
    // hand so there's something to soft-select besides the hull (excluded
    // by excludeHull=true below).
    image.mesh.vertices.push_back(Vec2(0, 0));   // index 4: at the selected vertex
    image.mesh.vertices.push_back(Vec2(10, 0));  // index 5: near
    image.mesh.vertices.push_back(Vec2(40, 0));  // index 6: far (beyond radius)
    image.mesh.uvs.assign(image.mesh.vertices.size(), Vec2::zero());

    std::unordered_set<int> selected = {4};
    const auto weights = softSelectionWeights(
        image, Vec2(100, 100), selected, /*showDeformed=*/false, /*radius=*/20.0f, /*feather=*/1.0f,
        /*excludeHull=*/true);

    UM_CHECK(weights.contains(4));
    UM_CHECK_NEAR(weights.at(4), 1.0, 1e-4);
    UM_CHECK(weights.contains(5));
    UM_CHECK(weights.at(5) > 0.0f && weights.at(5) < 1.0f);
    UM_CHECK(!weights.contains(6)); // beyond radius=20.
    // Hull vertices (0..3) excluded entirely.
    UM_CHECK(!weights.contains(0));
}

static void testResolvedMeshFallsBackToQuadWhenMeshIsEmpty() {
    SceneImage image;
    image.name = "sprite";
    const Mesh resolved = resolvedMesh(image, Vec2(40, 20));
    UM_CHECK(resolved.isQuadCompatible());
}

UM_TEST_MAIN_BEGIN()
    testSnapFunctions();
    testConstrainAxisPicksDominantAxis();
    testDistancePointToSegmentClampsToEndpoints();
    testMoveGizmoHitTestPicksNearestAxis();
    testMoveGizmoCenterWinsNearOrigin();
    testRotateGizmoTrackHitTest();
    testSkewGizmoRequiresSelectedImage();
    testBoneHitTestMouseJointBeatsShaft();
    testBonesIntersectingMarqueeCatchesCrossingShaft();
    testSegmentIntersectsRectRejectsDiagonalNearMiss();
    testSegmentIntersectsRectAcceptsCrossingShaft();
    testSoftSelectionWeightsFallOffWithDistance();
    testResolvedMeshFallsBackToQuadWhenMeshIsEmpty();
UM_TEST_MAIN_END()
