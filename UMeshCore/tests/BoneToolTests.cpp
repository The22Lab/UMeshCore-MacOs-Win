// Tests for BoneTool, ported from `Core/Tools/BoneTool.swift`. Expected
// values are hand-derived from that file's hit-test radii/priority rules
// and the create/moveRoot/moveTip interaction logic.

#include "umeshcore/Editor/Tools/BoneTool.h"
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

// No-camera convention used throughout this port's tool tests: screen
// coordinates are world coordinates offset by half the view size (matching
// hitTestBonePart's own `camera?.worldToScreen(...) ?? (point + viewSize*0.5)`
// fallback), so `position` (world) and `screenPosition` (screen) must be
// kept consistent with that relationship, not set equal to each other.
static ToolInput makeInput(Vec2 screenPos, bool shift = false, bool cmd = false) {
    ToolInput input;
    const Vec2 viewSize(1000, 1000);
    input.position = screenPos - viewSize * 0.5f;
    input.screenPosition = screenPos;
    input.viewSize = viewSize;
    input.isShiftPressed = shift;
    input.isCommandPressed = cmd;
    return input;
}

static void testClickOnJointSelectsAndArmsMoveRoot() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);

    BoneTool tool;
    // No-camera hit-testing convention: screenPoint = worldPoint + viewSize/2,
    // so screen (500,500) is world (0,0) -- the bone's start joint.
    tool.onMouseDown(makeInput(Vec2(500, 500)), scene, ImageHitTestFn{}, 1.0f, false);

    // Drag the root past the 4pt threshold.
    ToolInput drag = makeInput(Vec2(550, 500));
    drag.isDragging = true;
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);

    UM_CHECK(scene.selectedBoneID.has_value() && *scene.selectedBoneID == bone.id);
    UM_CHECK_NEAR(scene.skeleton.bone(bone.id)->localTransform.position.x, 50.0, 1e-1);
}

static void testShiftClickOnTipTogglesSelectionRatherThanResizing() {
    // Verified discrepancy (see BoneTool.h's file header): `onMouseDown`
    // checks isShiftPressed/isCommandPressed and toggles multi-selection
    // BEFORE ever calling interactionForHit, so interactionForHit's own
    // "Shift resizes the tip" branch is unreachable in the real app today.
    // A Shift-click (or Shift-drag) on a tip behaves exactly like a
    // Shift-click anywhere else on the bone: it toggles selection and
    // starts no interaction at all -- it does not resize.
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f); // tip at world (100,0) -> screen (600,500).
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);

    BoneTool tool;
    tool.onMouseDown(makeInput(Vec2(600, 500), /*shift=*/true), scene, ImageHitTestFn{}, 1.0f, false);
    UM_CHECK(scene.selectedBoneIDs.count(bone.id) == 1);

    ToolInput drag = makeInput(Vec2(650, 500), /*shift=*/true);
    drag.isDragging = true;
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);

    // No interaction was armed, so the drag call did nothing.
    UM_CHECK_NEAR(scene.skeleton.bone(bone.id)->length, 100.0, 1e-4);
}

static void testPlainDragFromTipChainsNewBone() {
    EditorScene scene;
    Bone parent = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f); // tip at world (100,0) -> screen (600,500).
    scene.skeleton.setBone(parent);
    scene.skeleton.rootIDs.push_back(parent.id);
    scene.selectBone(parent.id);

    const std::size_t boneCountBefore = scene.skeleton.bones().size();

    BoneTool tool;
    // No Shift: a plain drag from the tip chains a new bone.
    tool.onMouseDown(makeInput(Vec2(600, 500)), scene, ImageHitTestFn{}, 1.0f, false);
    ToolInput drag = makeInput(Vec2(700, 500));
    drag.isDragging = true;
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);
    tool.onMouseUp(drag, scene, ImageHitTestFn{}, 1.0f, false);

    UM_CHECK(scene.skeleton.bones().size() == boneCountBefore + 1);
    // The new bone's parent must be the one whose tip was dragged from.
    bool foundChildOfParent = false;
    for (const auto& entry : scene.skeleton.bones()) {
        if (entry.second.parentID.has_value() && *entry.second.parentID == parent.id) foundChildOfParent = true;
    }
    UM_CHECK(foundChildOfParent);
}

static void testDragFromEmptyCanvasCreatesRootBone() {
    EditorScene scene; // No bones at all.

    BoneTool tool;
    tool.onMouseDown(makeInput(Vec2(100, 100)), scene, ImageHitTestFn{}, 1.0f, false);
    ToolInput drag = makeInput(Vec2(200, 100));
    drag.isDragging = true;
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);
    tool.onMouseUp(drag, scene, ImageHitTestFn{}, 1.0f, false);

    UM_CHECK(scene.skeleton.bones().size() == 1);
    UM_CHECK(scene.selectedBoneID.has_value());
    const Bone& created = *scene.skeleton.bone(*scene.selectedBoneID);
    UM_CHECK(!created.parentID.has_value());
    // World start (100,100), end (200,100) -> length 100.
    UM_CHECK_NEAR(created.length, 100.0, 1e-1);
}

static void testShortDragOnEmptyCanvasClearsSelectionInsteadOfCreating() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);
    scene.selectBone(bone.id);

    BoneTool tool;
    // Click far from the bone (empty canvas), release with almost no
    // movement -- below the 8-unit create threshold.
    tool.onMouseDown(makeInput(Vec2(100, 100)), scene, ImageHitTestFn{}, 1.0f, false);
    tool.onMouseUp(makeInput(Vec2(102, 100)), scene, ImageHitTestFn{}, 1.0f, false);

    UM_CHECK(scene.skeleton.bones().size() == 1); // No new bone created.
    UM_CHECK(!scene.selectedBoneID.has_value()); // Selection was cleared.
}

static void testCmdClickTogglesSelectionWithoutStartingDrag() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);

    BoneTool tool;
    tool.onMouseDown(makeInput(Vec2(500, 500), /*shift=*/false, /*cmd=*/true), scene, ImageHitTestFn{}, 1.0f, false);
    UM_CHECK(scene.selectedBoneIDs.count(bone.id) == 1);

    // A subsequent drag call must do nothing (no interaction was armed).
    ToolInput drag = makeInput(Vec2(600, 500));
    drag.isDragging = true;
    tool.onMouseDrag(drag, scene, ImageHitTestFn{}, 1.0f, false);
    UM_CHECK_NEAR(scene.skeleton.bone(bone.id)->localTransform.position.x, 0.0, 1e-4);
}

static void testJointHitBeatsNearbySegment() {
    // A bone whose segment passes near a click, but a DIFFERENT bone's
    // joint is also within range -- the joint must win even though the
    // segment might be numerically closer.
    EditorScene scene;
    // Bone A: a long horizontal segment passing very close to screen (500,500).
    Bone segmentBone = makeBone(std::nullopt, Vec2(-400, 0), 0.0f, 800.0f); // spans world x -400..400 at y=0.
    // Bone B: its start joint sits close to (500,500) too, within jointRadius (12px default).
    Bone jointBone = makeBone(std::nullopt, Vec2(3, 0), 0.0f, 50.0f); // world start (3,0) -> screen (503,500).
    scene.skeleton.setBone(segmentBone);
    scene.skeleton.setBone(jointBone);
    scene.skeleton.rootIDs.push_back(segmentBone.id);
    scene.skeleton.rootIDs.push_back(jointBone.id);

    BoneTool tool;
    // Click at screen (503,500): 3px from jointBone's start AND ~0px from
    // segmentBone's shaft (y=0 line). Joint must win.
    tool.onMouseDown(makeInput(Vec2(503, 500)), scene, ImageHitTestFn{}, 1.0f, false);
    UM_CHECK(scene.selectedBoneID.has_value() && *scene.selectedBoneID == jointBone.id);
}

UM_TEST_MAIN_BEGIN()
    testClickOnJointSelectsAndArmsMoveRoot();
    testShiftClickOnTipTogglesSelectionRatherThanResizing();
    testPlainDragFromTipChainsNewBone();
    testDragFromEmptyCanvasCreatesRootBone();
    testShortDragOnEmptyCanvasClearsSelectionInsteadOfCreating();
    testCmdClickTogglesSelectionWithoutStartingDrag();
    testJointHitBeatsNearbySegment();
UM_TEST_MAIN_END()
