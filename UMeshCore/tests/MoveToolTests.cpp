// Tests for MoveTool, ported from `Core/Tools/MoveTool.swift`. Expected
// values are hand-derived from that file's documented behavior. Mesh-vertex
// dragging is not ported (see MoveTool.h) and so isn't tested here.

#include "umeshcore/Editor/Tools/MoveTool.h"
#include "TestHarness.h"

using namespace umeshcore;

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

static ToolInput makeInput(Vec2 screenPos, Vec2 startScreenPos, Vec2 viewSize, bool dragging, bool shift = false) {
    ToolInput input;
    input.position = screenPos - viewSize * 0.5f;
    input.startPosition = startScreenPos - viewSize * 0.5f;
    input.screenPosition = screenPos;
    input.startScreenPosition = startScreenPos;
    input.viewSize = viewSize;
    input.isDragging = dragging;
    input.isShiftPressed = shift;
    return input;
}

static void testDragSelectedSpriteUpdatesPreviewThenCommitsOnMouseUp() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(0, 0);
    scene.images.push_back(image);
    scene.selectedImageID = image.id;
    scene.selectedImageIDs = {image.id};

    const Vec2 viewSize(1000, 1000);
    const Vec2 centerScreen = viewSize * 0.5f; // World (0,0).

    MoveTool tool;
    // No image hit test wired (empty callback) -- falls back to
    // scene.selectedImageID, exactly like Swift's `?? scene.selectedImageID`.
    tool.onMouseDown(makeInput(centerScreen, centerScreen, viewSize, false), scene, ImageHitTestFn{}, 1.0f, false);

    // Drag past the 4pt threshold.
    const Vec2 dragScreen = centerScreen + Vec2(50, 0);
    tool.onMouseDrag(makeInput(dragScreen, centerScreen, viewSize, true), scene, ImageHitTestFn{}, 1.0f, false);

    // Preview position updated; the model's own position is untouched.
    UM_CHECK_NEAR(scene.previewPositions.at(image.id).x, 50.0, 1e-2);
    UM_CHECK_NEAR(scene.image(image.id)->position.x, 0.0, 1e-4);

    tool.onMouseUp(makeInput(dragScreen, centerScreen, viewSize, false), scene, ImageHitTestFn{}, 1.0f, false);

    // Committed: preview cleared, real position updated.
    UM_CHECK(scene.previewPositions.find(image.id) == scene.previewPositions.end());
    UM_CHECK_NEAR(scene.image(image.id)->position.x, 50.0, 1e-2);
}

static void testClickWithoutDragClearsPreviewAndLeavesPositionUnchanged() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(3, 4);
    scene.images.push_back(image);
    scene.selectedImageID = image.id;
    scene.selectedImageIDs = {image.id};

    const Vec2 viewSize(1000, 1000);
    const Vec2 centerScreen = viewSize * 0.5f;

    MoveTool tool;
    tool.onMouseDown(makeInput(centerScreen, centerScreen, viewSize, false), scene, ImageHitTestFn{}, 1.0f, false);
    // No drag call at all -- a plain click.
    tool.onMouseUp(makeInput(centerScreen, centerScreen, viewSize, false), scene, ImageHitTestFn{}, 1.0f, false);

    UM_CHECK(scene.previewPositions.find(image.id) == scene.previewPositions.end());
    UM_CHECK_NEAR(scene.image(image.id)->position.x, 3.0, 1e-4);
}

static void testDragSelectedBoneMovesRootAndCommitsKeyframeWhenAnimating() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);
    scene.selectBone(bone.id);
    scene.isAnimationEditingEnabled = true;
    scene.currentFrame = 2;
    scene.animationTime = 2.0f;

    const Vec2 viewSize(1000, 1000);
    const Vec2 centerScreen = viewSize * 0.5f;

    MoveTool tool;
    tool.onMouseDown(makeInput(centerScreen, centerScreen, viewSize, false), scene, ImageHitTestFn{}, 1.0f, false);
    const Vec2 dragScreen = centerScreen + Vec2(30, 0);
    tool.onMouseDrag(makeInput(dragScreen, centerScreen, viewSize, true), scene, ImageHitTestFn{}, 1.0f, false);
    tool.onMouseUp(makeInput(dragScreen, centerScreen, viewSize, false), scene, ImageHitTestFn{}, 1.0f, false);

    const Bone& moved = *scene.skeleton.bone(bone.id);
    UM_CHECK_NEAR(moved.localTransform.position.x, 30.0, 1e-2);
    UM_CHECK(moved.animationClip.hasTrack(bone.id, AnimationTrackProperty::Translate));
}

static void testDragMovesMultipleSelectedBonesByTheSameDelta() {
    EditorScene scene;
    Bone a = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 50.0f);
    Bone b = makeBone(std::nullopt, Vec2(100, 0), 0.0f, 50.0f);
    scene.skeleton.setBone(a);
    scene.skeleton.setBone(b);
    scene.skeleton.rootIDs.push_back(a.id);
    scene.skeleton.rootIDs.push_back(b.id);
    scene.setBoneSelection({a.id}, a.id, false);
    scene.setBoneSelection({b.id}, b.id, /*additive=*/true);

    const Vec2 viewSize(1000, 1000);
    // The primary/active bone is `b` (most recently added) -- drag starts there.
    const Vec2 bScreen = viewSize * 0.5f + Vec2(100, 0);

    MoveTool tool;
    tool.onMouseDown(makeInput(bScreen, bScreen, viewSize, false), scene, ImageHitTestFn{}, 1.0f, false);
    const Vec2 dragScreen = bScreen + Vec2(10, 0);
    tool.onMouseDrag(makeInput(dragScreen, bScreen, viewSize, true), scene, ImageHitTestFn{}, 1.0f, false);
    tool.onMouseUp(makeInput(dragScreen, bScreen, viewSize, false), scene, ImageHitTestFn{}, 1.0f, false);

    // Both bones move by the same +10 delta.
    UM_CHECK_NEAR(scene.skeleton.bone(a.id)->localTransform.position.x, 10.0, 1e-2);
    UM_CHECK_NEAR(scene.skeleton.bone(b.id)->localTransform.position.x, 110.0, 1e-2);
}

static void testAxisConstraintLocksPerpendicularComponent() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(0, 0);
    scene.images.push_back(image);
    scene.selectedImageID = image.id;
    scene.selectedImageIDs = {image.id};

    const Vec2 viewSize(1000, 1000);
    const Vec2 centerScreen = viewSize * 0.5f;

    MoveTool tool;
    ToolInput down = makeInput(centerScreen, centerScreen, viewSize, false);
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);

    // Drag diagonally, but with moveX active -- Y must stay locked to start.
    ToolInput drag = makeInput(centerScreen + Vec2(40, 40), centerScreen, viewSize, true);
    drag.activeHandle = MoveXHandle{};
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);

    UM_CHECK_NEAR(scene.previewPositions.at(image.id).x, 40.0, 1e-2);
    UM_CHECK_NEAR(scene.previewPositions.at(image.id).y, 0.0, 1e-2);
}

UM_TEST_MAIN_BEGIN()
    testDragSelectedSpriteUpdatesPreviewThenCommitsOnMouseUp();
    testClickWithoutDragClearsPreviewAndLeavesPositionUnchanged();
    testDragSelectedBoneMovesRootAndCommitsKeyframeWhenAnimating();
    testDragMovesMultipleSelectedBonesByTheSameDelta();
    testAxisConstraintLocksPerpendicularComponent();
UM_TEST_MAIN_END()
