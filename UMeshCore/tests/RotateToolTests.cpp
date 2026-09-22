// Tests for RotateTool, ported from `Core/Tools/RotateTool.swift`. Expected
// values are hand-derived from that file's angle-delta/snap formulas.

#include "umeshcore/Editor/Tools/RotateTool.h"
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

static void testMouseDownIgnoredWithoutRotateRingHandle() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    scene.images.push_back(image);
    scene.selectedImageID = image.id;

    ToolInput input;
    input.activeHandle = MoveCenterHandle{}; // Not the rotate ring.

    RotateTool tool;
    tool.onMouseDown(input, scene, ImageHitTestFn{}, 1.0f, false);

    ToolInput drag;
    drag.position = Vec2(50, 50);
    drag.isDragging = true;
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);
    UM_CHECK_NEAR(scene.image(image.id)->rotation, 0.0, 1e-4);
}

static void testDragRotatesSpriteByAngleDelta() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(0, 0);
    image.rotation = 0.0f;
    scene.images.push_back(image);
    scene.selectedImageID = image.id;

    ToolInput down;
    down.activeHandle = RotateRingHandle{};
    down.startPosition = Vec2(10, 0); // angle 0.

    RotateTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);

    ToolInput drag;
    drag.activeHandle = RotateRingHandle{};
    drag.isDragging = true;
    drag.position = Vec2(0, 10); // angle pi/2 -> delta = pi/2.
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);

    UM_CHECK_NEAR(scene.image(image.id)->rotation, kPi / 2.0, 1e-2);
}

static void testShiftSnapsTo15DegreeSteps() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(0, 0);
    scene.images.push_back(image);
    scene.selectedImageID = image.id;

    ToolInput down;
    down.activeHandle = RotateRingHandle{};
    down.startPosition = Vec2(10, 0);

    RotateTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);

    // Drag to an angle close to (but not exactly) 20 degrees.
    const float angle = 20.0f * kPi / 180.0f;
    ToolInput drag;
    drag.activeHandle = RotateRingHandle{};
    drag.isDragging = true;
    drag.isShiftPressed = true;
    drag.position = Vec2(std::cos(angle) * 10.0f, std::sin(angle) * 10.0f);
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);

    // Nearest 15deg step to 20deg is 15deg.
    UM_CHECK_NEAR(scene.image(image.id)->rotation, 15.0f * kPi / 180.0f, 1e-2);
}

static void testGrabbingSpriteZeroesRotation3D() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.rotation3D = Vec3(0.3f, 0.1f, 0.0f);
    scene.images.push_back(image);
    scene.selectedImageID = image.id;

    ToolInput down;
    down.activeHandle = RotateRingHandle{};
    down.startPosition = Vec2(10, 0);

    RotateTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);

    UM_CHECK_NEAR(scene.image(image.id)->rotation3D.x, 0.0, 1e-5);
    UM_CHECK_NEAR(scene.image(image.id)->rotation3D.y, 0.0, 1e-5);
}

static void testMultiBoneGroupRotatesRigidlyByOneDelta() {
    EditorScene scene;
    Bone a = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 50.0f);
    Bone b = makeBone(std::nullopt, Vec2(100, 0), 0.0f, 50.0f);
    scene.skeleton.setBone(a);
    scene.skeleton.setBone(b);
    scene.skeleton.rootIDs.push_back(a.id);
    scene.skeleton.rootIDs.push_back(b.id);
    scene.setBoneSelection({a.id}, a.id, false);
    scene.setBoneSelection({b.id}, b.id, /*additive=*/true); // b is primary/active.

    ToolInput down;
    down.activeHandle = RotateRingHandle{};
    // b's world start is (100,0); drag starts at angle 0 relative to it.
    down.startPosition = Vec2(110, 0);

    RotateTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);

    ToolInput drag;
    drag.activeHandle = RotateRingHandle{};
    drag.isDragging = true;
    drag.position = Vec2(100, 10); // angle pi/2 relative to b's start.
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);

    // Both bones rotate by the same +90deg delta.
    UM_CHECK_NEAR(scene.skeleton.bone(a.id)->localTransform.rotation.z, kPi / 2.0, 1e-2);
    UM_CHECK_NEAR(scene.skeleton.bone(b.id)->localTransform.rotation.z, kPi / 2.0, 1e-2);
}

static void testCommitsKeyframeForEveryDraggedBone() {
    EditorScene scene;
    Bone a = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 50.0f);
    Bone b = makeBone(std::nullopt, Vec2(100, 0), 0.0f, 50.0f);
    scene.skeleton.setBone(a);
    scene.skeleton.setBone(b);
    scene.skeleton.rootIDs.push_back(a.id);
    scene.skeleton.rootIDs.push_back(b.id);
    scene.setBoneSelection({a.id}, a.id, false);
    scene.setBoneSelection({b.id}, b.id, /*additive=*/true);
    scene.isAnimationEditingEnabled = true;

    ToolInput down;
    down.activeHandle = RotateRingHandle{};
    down.startPosition = Vec2(110, 0);

    RotateTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);
    ToolInput drag;
    drag.activeHandle = RotateRingHandle{};
    drag.isDragging = true;
    drag.position = Vec2(100, 10);
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);
    tool.onMouseUp(drag, scene, ImageHitTestFn{}, 1.0f, false);

    UM_CHECK(scene.skeleton.bone(a.id)->animationClip.hasTrack(a.id, AnimationTrackProperty::Rotate));
    UM_CHECK(scene.skeleton.bone(b.id)->animationClip.hasTrack(b.id, AnimationTrackProperty::Rotate));
}

static void testUpdateSettlesSpriteRotationTowardTarget() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(0, 0);
    scene.images.push_back(image);
    scene.selectedImageID = image.id;

    ToolInput down;
    down.activeHandle = RotateRingHandle{};
    down.startPosition = Vec2(10, 0);

    RotateTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);
    ToolInput drag;
    drag.activeHandle = RotateRingHandle{};
    drag.isDragging = true;
    // A slightly-off-15deg angle so shift-release snap produces a settle gap.
    const float angle = 20.3f * kPi / 180.0f;
    drag.position = Vec2(std::cos(angle) * 10.0f, std::sin(angle) * 10.0f);
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);
    const float liveRotation = scene.image(image.id)->rotation;

    drag.isShiftPressed = true; // Release with Shift -> snaps target to 15deg.
    tool.onMouseUp(drag, scene, ImageHitTestFn{}, 1.0f, false);
    UM_CHECK_NEAR(scene.image(image.id)->rotation, liveRotation, 1e-4); // Unmoved by onMouseUp itself.

    for (int i = 0; i < 200; ++i) tool.update(scene);
    UM_CHECK_NEAR(scene.image(image.id)->rotation, 15.0f * kPi / 180.0f, 1e-3);
}

UM_TEST_MAIN_BEGIN()
    testMouseDownIgnoredWithoutRotateRingHandle();
    testDragRotatesSpriteByAngleDelta();
    testShiftSnapsTo15DegreeSteps();
    testGrabbingSpriteZeroesRotation3D();
    testMultiBoneGroupRotatesRigidlyByOneDelta();
    testCommitsKeyframeForEveryDraggedBone();
    testUpdateSettlesSpriteRotationTowardTarget();
UM_TEST_MAIN_END()
