// Tests for ScaleTool, ported from `Core/Tools/ScaleTool.swift`. Expected
// values are hand-derived from that file's documented formulas.

#include "umeshcore/Editor/Tools/ScaleTool.h"
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

static ToolInput makeDragInput(Vec2 pos, Vec2 startPos, Vec2 viewSize, bool shift, GizmoHandle handle) {
    ToolInput input;
    input.position = pos;
    input.startPosition = startPos;
    input.screenPosition = pos;
    input.startScreenPosition = startPos;
    input.viewSize = viewSize;
    input.isShiftPressed = shift;
    input.activeHandle = handle;
    input.isDragging = true;
    return input;
}

static void testMouseDownIgnoredWithoutScaleCornerHandle() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    scene.images.push_back(image);
    scene.selectedImageID = image.id;

    ToolInput input;
    input.activeHandle = MoveCenterHandle{}; // Not a scale corner.

    ScaleTool tool;
    tool.onMouseDown(input, scene, ImageHitTestFn{}, 1.0f, false);
    // Nothing armed -- a drag afterward must do nothing.
    tool.onMouseDrag(
        makeDragInput(Vec2(50, 0), Vec2(0, 0), Vec2(1000, 1000), false, ScaleCornerHandle{2}), scene,
        ImageHitTestFn{}, 1.0f, false);
    UM_CHECK_NEAR(scene.image(image.id)->scale.x, 1.0, 1e-4);
}

static void testUniformCornerScalesBothAxesByDistanceRatio() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(0, 0);
    image.scale = Vec2::one();
    scene.images.push_back(image);
    scene.selectedImageID = image.id;

    ToolInput down;
    down.activeHandle = ScaleCornerHandle{2}; // Uniform corner.
    down.startPosition = Vec2(10, 0);
    down.position = Vec2(10, 0);

    ScaleTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);

    // Dragging to twice the start distance from the sprite's position
    // should double the scale on a uniform corner.
    tool.onMouseDrag(
        makeDragInput(Vec2(20, 0), Vec2(10, 0), Vec2(1000, 1000), false, ScaleCornerHandle{2}), scene,
        ImageHitTestFn{}, 1.0f, false);
    UM_CHECK_NEAR(scene.image(image.id)->scale.x, 2.0, 1e-2);
    UM_CHECK_NEAR(scene.image(image.id)->scale.y, 2.0, 1e-2);
}

static void testCornerZeroScalesOnlyX() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(0, 0);
    image.scale = Vec2::one();
    scene.images.push_back(image);
    scene.selectedImageID = image.id;

    ToolInput down;
    down.activeHandle = ScaleCornerHandle{0};
    down.startPosition = Vec2(10, 5);
    down.position = Vec2(10, 5);

    ScaleTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);
    // Drag x to 20 (doubling the x component of the start vector); y moves
    // too but must not affect scale.y on corner 0.
    tool.onMouseDrag(
        makeDragInput(Vec2(20, 50), Vec2(10, 5), Vec2(1000, 1000), false, ScaleCornerHandle{0}), scene,
        ImageHitTestFn{}, 1.0f, false);
    UM_CHECK_NEAR(scene.image(image.id)->scale.x, 2.0, 1e-2);
    UM_CHECK_NEAR(scene.image(image.id)->scale.y, 1.0, 1e-4);
}

static void testShiftSnapsScaleOnRelease() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(0, 0);
    image.scale = Vec2::one();
    scene.images.push_back(image);
    scene.selectedImageID = image.id;

    ToolInput down;
    down.activeHandle = ScaleCornerHandle{2};
    down.startPosition = Vec2(10, 0);
    down.position = Vec2(10, 0);

    ScaleTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);
    // Drag distance from mouseDownPosition (10,0) to (16.3,0) is 6.3pt,
    // past the 4pt threshold, so the drag actually takes effect.
    tool.onMouseDrag(
        makeDragInput(Vec2(16.3f, 0), Vec2(10, 0), Vec2(1000, 1000), /*shift=*/true, ScaleCornerHandle{2}), scene,
        ImageHitTestFn{}, 1.0f, false);

    // 16.3/10 = 1.63 scale factor, snapped to the nearest 0.1 step -> 1.6.
    UM_CHECK_NEAR(scene.image(image.id)->scale.x, 1.6, 1e-2);
}

static void testDragSelectedBoneScalesAndCommitsKeyframeWhenAnimating() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);
    scene.selectBone(bone.id);
    scene.isAnimationEditingEnabled = true;

    ToolInput down;
    down.activeHandle = ScaleCornerHandle{2};
    down.startPosition = Vec2(10, 0); // 10 units from bone start (0,0).
    down.position = Vec2(10, 0);

    ScaleTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);
    // Drag to 20 units from bone start -> distance ratio 2.0.
    tool.onMouseDrag(
        makeDragInput(Vec2(20, 0), Vec2(10, 0), Vec2(1000, 1000), false, ScaleCornerHandle{2}), scene,
        ImageHitTestFn{}, 1.0f, false);
    tool.onMouseUp(
        makeDragInput(Vec2(20, 0), Vec2(10, 0), Vec2(1000, 1000), false, ScaleCornerHandle{2}), scene,
        ImageHitTestFn{}, 1.0f, false);

    const Bone& scaled = *scene.skeleton.bone(bone.id);
    UM_CHECK_NEAR(scaled.localTransform.scale.x, 2.0, 1e-2);
    UM_CHECK(scaled.animationClip.hasTrack(bone.id, AnimationTrackProperty::Scale));
}

static void testDragSelectedBoneChangesLengthWhenNotAnimating() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);
    scene.selectBone(bone.id);
    scene.isAnimationEditingEnabled = false;

    ToolInput down;
    down.activeHandle = ScaleCornerHandle{2};
    down.startPosition = Vec2(10, 0);
    down.position = Vec2(10, 0);

    ScaleTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);
    tool.onMouseDrag(
        makeDragInput(Vec2(15, 0), Vec2(10, 0), Vec2(1000, 1000), false, ScaleCornerHandle{2}), scene,
        ImageHitTestFn{}, 1.0f, false);

    // 100 * (15/10) = 150.
    UM_CHECK_NEAR(scene.skeleton.bone(bone.id)->length, 150.0, 1e-2);
}

static void testUpdateSettlesTowardTargetAfterRelease() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(0, 0);
    image.scale = Vec2::one();
    scene.images.push_back(image);
    scene.selectedImageID = image.id;

    ToolInput down;
    down.activeHandle = ScaleCornerHandle{2};
    down.startPosition = Vec2(10, 0);
    down.position = Vec2(10, 0);

    ScaleTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);
    // Drag WITHOUT Shift to a non-round factor (22.7/10 = 2.27), so the
    // live scale during the drag is exactly 2.27, unsnapped.
    tool.onMouseDrag(
        makeDragInput(Vec2(22.7f, 0), Vec2(10, 0), Vec2(1000, 1000), false, ScaleCornerHandle{2}), scene,
        ImageHitTestFn{}, 1.0f, false);
    UM_CHECK_NEAR(scene.image(image.id)->scale.x, 2.27, 1e-2);

    // Release WITH Shift: onMouseUp snaps the target (2.27 -> 2.3) but does
    // not itself move the live scale there -- update() eases it over.
    tool.onMouseUp(
        makeDragInput(Vec2(22.7f, 0), Vec2(10, 0), Vec2(1000, 1000), /*shift=*/true, ScaleCornerHandle{2}), scene,
        ImageHitTestFn{}, 1.0f, false);

    const float beforeUpdate = scene.image(image.id)->scale.x;
    UM_CHECK_NEAR(beforeUpdate, 2.27, 1e-2);
    tool.update(scene);
    const float afterOneStep = scene.image(image.id)->scale.x;
    UM_CHECK(afterOneStep > beforeUpdate);
    UM_CHECK(afterOneStep < 2.3);

    // Enough steps must converge exactly to the snapped target.
    for (int i = 0; i < 100; ++i) tool.update(scene);
    UM_CHECK_NEAR(scene.image(image.id)->scale.x, 2.3, 1e-3);
}

UM_TEST_MAIN_BEGIN()
    testMouseDownIgnoredWithoutScaleCornerHandle();
    testUniformCornerScalesBothAxesByDistanceRatio();
    testCornerZeroScalesOnlyX();
    testShiftSnapsScaleOnRelease();
    testDragSelectedBoneScalesAndCommitsKeyframeWhenAnimating();
    testDragSelectedBoneChangesLengthWhenNotAnimating();
    testUpdateSettlesTowardTargetAfterRelease();
UM_TEST_MAIN_END()
