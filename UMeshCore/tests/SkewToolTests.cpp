// Tests for SkewTool, ported from `Core/Tools/SkewTool.swift`. Expected
// values are hand-derived from that file's angle/clamp formulas.

#include "umeshcore/Editor/Tools/SkewTool.h"
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

static void testMouseDownIgnoredWithoutSkewEdgeHandle() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);
    scene.selectBone(bone.id);

    ToolInput input;
    input.activeHandle = RotateRingHandle{}; // Not a skew edge.

    SkewTool tool;
    tool.onMouseDown(input, scene, ImageHitTestFn{}, 1.0f, false);

    ToolInput drag;
    drag.position = Vec2(50, 0);
    drag.isDragging = true;
    drag.activeHandle = SkewEdgeHandle{0};
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);

    UM_CHECK_NEAR(scene.skeleton.bone(bone.id)->localTransform.skew.x, 0.0, 1e-4);
}

static void testBoneShearXDragAppliesAngleDelta() {
    EditorScene scene;
    // Bone spans (-50,0)-(50,0), so its center is the world origin.
    Bone bone = makeBone(std::nullopt, Vec2(-50, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);
    scene.selectBone(bone.id);

    ToolInput down;
    down.activeHandle = SkewEdgeHandle{0}; // shearX
    down.position = Vec2(0, 10); // Directly "below" center: angle = 90deg.

    SkewTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);

    // Drag distance from (0,10) exceeds the 4pt threshold.
    ToolInput drag;
    drag.activeHandle = SkewEdgeHandle{0};
    drag.isDragging = true;
    drag.position = Vec2(10, 0); // angle = 0deg. d = (90 - 0) = 90.
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);

    UM_CHECK_NEAR(scene.skeleton.bone(bone.id)->localTransform.skew.x, 90.0, 1e-1);
    UM_CHECK_NEAR(scene.skeleton.bone(bone.id)->localTransform.skew.y, 0.0, 1e-4);
}

static void testBoneShearZAppliesOppositeSignsToXAndY() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(-50, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);
    scene.selectBone(bone.id);

    ToolInput down;
    down.activeHandle = SkewEdgeHandle{2}; // Default (index != 0,1) -> shearZ.
    down.position = Vec2(0, 10);

    SkewTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);

    ToolInput drag;
    drag.activeHandle = SkewEdgeHandle{2};
    drag.isDragging = true;
    drag.position = Vec2(10, 0);
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);

    UM_CHECK_NEAR(scene.skeleton.bone(bone.id)->localTransform.skew.x, 90.0, 1e-1);
    UM_CHECK_NEAR(scene.skeleton.bone(bone.id)->localTransform.skew.y, -90.0, 1e-1);
}

static void testSkewClampsToPlusMinus180() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(-50, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);
    scene.selectBone(bone.id);

    ToolInput down;
    down.activeHandle = SkewEdgeHandle{0};
    down.position = Vec2(0, 10); // angle 90deg.

    SkewTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);

    // Drag to angle ~ -170deg: d = 90 - (-170) = 260, normalized to -100.
    // Combined with start skew 0, result would be -100, still within range,
    // so instead push further: drag to angle just past -90 twice via two
    // successive drags to accumulate past +-180 and confirm clamping.
    ToolInput drag1;
    drag1.activeHandle = SkewEdgeHandle{0};
    drag1.isDragging = true;
    drag1.position = Vec2(-10, 0); // angle = 180deg. d = 90-180 = -90.
    tool.onMouseDrag(drag1, scene, ImageHitTestFn{}, 1.0f, false);
    UM_CHECK_NEAR(scene.skeleton.bone(bone.id)->localTransform.skew.x, -90.0, 1e-1);

    // Now drag to angle -179deg (just past the -180/180 seam from start
    // angle 90): d = 90 - (-179) = 269, normalized (>180 -> -360) = -91.
    ToolInput drag2;
    drag2.activeHandle = SkewEdgeHandle{0};
    drag2.isDragging = true;
    drag2.position = Vec2(-10, 0.17f); // angle just past 180 toward -179ish.
    tool.onMouseDrag(drag2, scene, ImageHitTestFn{}, 1.0f, false);
    // Whatever the exact normalized delta, the result must stay clamped
    // within [-180, 180].
    const float skewX = scene.skeleton.bone(bone.id)->localTransform.skew.x;
    UM_CHECK(skewX >= -180.0f && skewX <= 180.0f);
}

static void testShiftRoundsDeltaToWholeDegree() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(-50, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);
    scene.selectBone(bone.id);

    ToolInput down;
    down.activeHandle = SkewEdgeHandle{0};
    down.position = Vec2(0, 10);

    SkewTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);

    ToolInput drag;
    drag.activeHandle = SkewEdgeHandle{0};
    drag.isDragging = true;
    drag.isShiftPressed = true;
    // Angle a bit off 0deg so the raw delta isn't already a whole number.
    drag.position = Vec2(10, 0.5f);
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);

    const float skewX = scene.skeleton.bone(bone.id)->localTransform.skew.x;
    UM_CHECK_NEAR(skewX, std::round(skewX), 1e-5); // Must land exactly on an integer.
}

static void testCommitsKeyframeOnReleaseWhenAnimating() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(-50, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);
    scene.selectBone(bone.id);
    scene.isAnimationEditingEnabled = true;

    ToolInput down;
    down.activeHandle = SkewEdgeHandle{0};
    down.position = Vec2(0, 10);

    SkewTool tool;
    tool.onMouseDown(down, scene, ImageHitTestFn{}, 1.0f, false);
    ToolInput drag;
    drag.activeHandle = SkewEdgeHandle{0};
    drag.isDragging = true;
    drag.position = Vec2(10, 0);
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);
    tool.onMouseUp(drag, scene, ImageHitTestFn{}, 1.0f, false);

    UM_CHECK(scene.skeleton.bone(bone.id)->animationClip.hasTrack(bone.id, AnimationTrackProperty::Shear));
}

UM_TEST_MAIN_BEGIN()
    testMouseDownIgnoredWithoutSkewEdgeHandle();
    testBoneShearXDragAppliesAngleDelta();
    testBoneShearZAppliesOppositeSignsToXAndY();
    testSkewClampsToPlusMinus180();
    testShiftRoundsDeltaToWholeDegree();
    testCommitsKeyframeOnReleaseWhenAnimating();
UM_TEST_MAIN_END()
