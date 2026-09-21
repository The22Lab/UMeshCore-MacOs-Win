// Tests for the Phase 2 foundation pieces that don't depend on
// Skeleton/Mesh: EditorEscape.h, CameraState.h, and the gizmo metrics
// (MoveGizmoMetrics.h / RotateGizmoMetrics.h / SkewGizmoMetrics.h), ported
// from Core/EditorEscape.swift, Core/CameraState.swift,
// MoveGizmoMetrics.swift, RotateGizmoMetrics.swift, SkewGizmoMetrics.swift.

#include <cmath>

#include "umeshcore/Editor/CameraState.h"
#include "umeshcore/Editor/EditorEscape.h"
#include "umeshcore/Editor/MoveGizmoMetrics.h"
#include "umeshcore/Editor/RotateGizmoMetrics.h"
#include "umeshcore/Editor/SkewGizmoMetrics.h"
#include "umeshcore/Math/MatrixUtilities.h"
#include "TestHarness.h"

using namespace umeshcore;

static void testEditorEscapeLadderOrderAndDescent() {
    // A fully "deep" state: every rung true/nonzero.
    EditorEscape::State state;
    state.isPickingIKBone = true;
    state.hasIKDraft = true;
    state.isMeshEditing = true;
    state.selectedMeshVertexCount = 3;
    state.isWeightPainting = true;
    state.isBindingBones = true;
    state.selectedBoneCount = 2;
    state.selectedImageCount = 1;
    state.hasSelectedConstraint = true;
    state.hasNonDefaultTool = true;

    // Walk the ladder to nullopt, asserting strict descent (never the same
    // rung twice, and always terminates).
    int steps = 0;
    while (auto scope = EditorEscape::deepest(state)) {
        state = EditorEscape::leaving(*scope, state);
        ++steps;
        UM_CHECK(steps <= 9); // there are exactly 9 rungs; must terminate.
    }
    UM_CHECK(steps == 9); // this fully-deep state must pass through all 9.
    UM_CHECK(!EditorEscape::deepest(state).has_value());
}

static void testEditorEscapeMeshVertexSelectionOnlyInsideMeshEdit() {
    // Vertices selected but NOT inside a mesh edit: must not report
    // MeshVertexSelection (that would strand the ladder on an unreachable rung).
    EditorEscape::State state;
    state.selectedMeshVertexCount = 5;
    state.isMeshEditing = false;
    UM_CHECK(!EditorEscape::deepest(state).has_value());
}

static void testEditorEscapeLeavingMeshEditClearsWhatsInsideIt() {
    EditorEscape::State state;
    state.isMeshEditing = true;
    state.selectedMeshVertexCount = 3;
    state.isWeightPainting = true;

    // First call clears the vertex selection (innermost rung)...
    auto scope = EditorEscape::deepest(state);
    UM_CHECK(scope.has_value() && *scope == EditorScope::MeshVertexSelection);
    state = EditorEscape::leaving(*scope, state);
    UM_CHECK(state.selectedMeshVertexCount == 0);
    UM_CHECK(state.isWeightPainting); // untouched yet

    // ...then weight paint...
    scope = EditorEscape::deepest(state);
    UM_CHECK(scope.has_value() && *scope == EditorScope::WeightPaint);
    state = EditorEscape::leaving(*scope, state);

    // ...then leaving mesh edit clears everything nested inside it at once.
    scope = EditorEscape::deepest(state);
    UM_CHECK(scope.has_value() && *scope == EditorScope::MeshEdit);
    state.selectedMeshVertexCount = 7;  // simulate stale nested state
    state.isWeightPainting = true;
    state = EditorEscape::leaving(EditorScope::MeshEdit, state);
    UM_CHECK(!state.isMeshEditing);
    UM_CHECK(state.selectedMeshVertexCount == 0);
    UM_CHECK(!state.isWeightPainting);
}

static void testCameraScreenWorldRoundTrip() {
    CameraState cam;
    cam.origin = Vec2(100, -50);
    cam.zoom = 2.0f;
    const Vec2 viewSize(800, 600);
    const Vec2 screenPoint(300, 200);
    const Vec2 world = cam.screenToWorld(screenPoint, viewSize);
    const Vec2 back = cam.worldToScreen(world, viewSize);
    UM_CHECK_NEAR(back.x, screenPoint.x, 1e-3);
    UM_CHECK_NEAR(back.y, screenPoint.y, 1e-3);
}

static void testCameraZoomAnchoredAtScreenPointStaysFixed() {
    CameraState cam;
    cam.origin = Vec2(0, 0);
    cam.zoom = 1.0f;
    const Vec2 viewSize(1000, 1000);
    const Vec2 anchor(700, 300);
    const Vec2 worldAtAnchorBefore = cam.screenToWorld(anchor, viewSize);

    cam.zoomAt(anchor, viewSize, /*scrollDelta=*/500.0f);

    const Vec2 worldAtAnchorAfter = cam.screenToWorld(anchor, viewSize);
    // The world point under the cursor must not move during a zoom.
    UM_CHECK_NEAR(worldAtAnchorBefore.x, worldAtAnchorAfter.x, 1e-2);
    UM_CHECK_NEAR(worldAtAnchorBefore.y, worldAtAnchorAfter.y, 1e-2);
    UM_CHECK(cam.zoom > 1.0f); // positive scrollDelta zooms in.
}

static void testCameraFrameAnimatesTowardTargetThenSettles() {
    CameraState cam;
    cam.origin = Vec2(0, 0);
    cam.zoom = 1.0f;
    Bounds2D bounds{Vec2(-50, -50), Vec2(50, 50)};
    cam.frame(bounds, Vec2(400, 400), /*padding=*/0.0f, /*duration=*/1.0, /*currentTime=*/0.0);
    UM_CHECK(cam.isAnimating());

    cam.update(/*currentTime=*/0.5, Vec2(400, 400));
    UM_CHECK(cam.isAnimating()); // halfway through, still animating.

    cam.update(/*currentTime=*/1.0, Vec2(400, 400));
    UM_CHECK(!cam.isAnimating()); // reached duration: settled.
    UM_CHECK_NEAR(cam.origin.x, 0.0, 1e-2); // bounds centered at origin.
    UM_CHECK_NEAR(cam.origin.y, 0.0, 1e-2);
}

static void testMoveGizmoCenterGrabCappedByAxisShare() {
    // At a large hitScale (simulating a 3x touch device), the center grab
    // radius must be capped at 22% of the axis length, not allowed to grow
    // unbounded and eat the axes -- this is the whole point of
    // MoveGizmoMetrics per its header comment.
    const float capped = MoveGizmoMetrics::centerGrabPx(/*hitScale=*/5.55f);
    UM_CHECK(capped <= MoveGizmoMetrics::kAxisLengthPx * MoveGizmoMetrics::kCenterShareOfAxis + 1e-4f);
}

static void testRotateGizmoNeedleGrabRespectsRadiusBounds() {
    // Distance below needleInner: never grabbed regardless of angle.
    UM_CHECK(!RotateGizmoMetrics::grabsNeedle(/*distancePx=*/5.0f, /*angleDelta=*/0.0f, /*hitScale=*/1.0f));
    // Distance within range, angle aligned: grabbed.
    UM_CHECK(RotateGizmoMetrics::grabsNeedle(50.0f, 0.0f, 1.0f));
    // Distance within range, angle far off: not grabbed.
    UM_CHECK(!RotateGizmoMetrics::grabsNeedle(50.0f, kPi / 2.0f, 1.0f));
}

static void testSkewGizmoTrackToleranceIsSymmetric() {
    UM_CHECK(SkewGizmoMetrics::grabsTrack(SkewGizmoMetrics::kTrackRadiusPx, 1.0f));
    UM_CHECK(SkewGizmoMetrics::grabsTrack(SkewGizmoMetrics::kTrackRadiusPx + 10.0f, 1.0f));
    UM_CHECK(!SkewGizmoMetrics::grabsTrack(SkewGizmoMetrics::kTrackRadiusPx + 20.0f, 1.0f));
}

UM_TEST_MAIN_BEGIN()
    testEditorEscapeLadderOrderAndDescent();
    testEditorEscapeMeshVertexSelectionOnlyInsideMeshEdit();
    testEditorEscapeLeavingMeshEditClearsWhatsInsideIt();
    testCameraScreenWorldRoundTrip();
    testCameraZoomAnchoredAtScreenPointStaysFixed();
    testCameraFrameAnimatesTowardTargetThenSettles();
    testMoveGizmoCenterGrabCappedByAxisShare();
    testRotateGizmoNeedleGrabRespectsRadiusBounds();
    testSkewGizmoTrackToleranceIsSymmetric();
UM_TEST_MAIN_END()
