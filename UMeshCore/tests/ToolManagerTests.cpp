// Tests for ToolManager, ported from `Core/ToolManager.swift`. Expected
// values are hand-derived from that file's dispatch/selection-click logic
// for the subset that's ported (see ToolManager.h's file header for what
// isn't, and why: IK builder, Bind Mode, MeshTool, PhysicsPreviewTool, the
// sprite marquee, and the provably-dead rotation-hover methods).

#include "umeshcore/Editor/ToolManager.h"
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

// No-camera convention: screenPoint = worldPoint + viewSize/2.
static ToolInput makeInput(Vec2 screenPos, bool shift = false, bool cmd = false, int clickCount = 1) {
    ToolInput input;
    const Vec2 viewSize(1000, 1000);
    input.position = screenPos - viewSize * 0.5f;
    input.screenPosition = screenPos;
    input.startPosition = input.position;
    input.startScreenPosition = screenPos;
    input.viewSize = viewSize;
    input.isShiftPressed = shift;
    input.isCommandPressed = cmd;
    input.clickCount = clickCount;
    return input;
}

static ImageHitTestFn stubImageHit(std::optional<ImageHit> result) {
    return [result](const Vec2&, const Vec2&, CameraState*) { return result; };
}

static void testDispatchesToActiveTool() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(0, 0);
    scene.images.push_back(image);
    scene.selectedImageID = image.id;
    scene.selectedImageIDs = {image.id};

    ToolManager manager;
    manager.currentTool = ActiveTool::Move;

    const Vec2 center(500, 500);
    manager.handleMouseDown(makeInput(center), scene, stubImageHit(std::nullopt), 1.0f, false);
    ToolInput drag = makeInput(center + Vec2(50, 0));
    drag.isDragging = true;
    manager.handleMouseDrag(drag, scene, stubImageHit(std::nullopt), 1.0f, false);

    // MoveTool wrote a live preview position, proving the click/drag was
    // actually forwarded to it.
    UM_CHECK(scene.previewPositions.find(image.id) != scene.previewPositions.end());
}

static void testMissingToolIsASafeNoOp() {
    EditorScene scene;
    ToolManager manager;
    manager.currentTool = ActiveTool::Mesh; // Not wired in -- see file header.

    // Must not crash, and must not mutate anything.
    manager.handleMouseDown(makeInput(Vec2(500, 500)), scene, stubImageHit(std::nullopt), 1.0f, false);
    ToolInput drag = makeInput(Vec2(550, 500));
    drag.isDragging = true;
    manager.handleMouseDrag(drag, scene, stubImageHit(std::nullopt), 1.0f, false);
    manager.handleMouseUp(drag, scene, stubImageHit(std::nullopt), 1.0f, false);
    manager.update(scene);
    UM_CHECK(scene.images.empty());
}

static void testClickOnBoneSelectsItThroughArbitration() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);

    ToolManager manager;
    manager.currentTool = ActiveTool::Select;
    manager.handleMouseDown(makeInput(Vec2(500, 500)), scene, stubImageHit(std::nullopt), 1.0f, false);

    UM_CHECK(scene.selectedBoneID.has_value() && *scene.selectedBoneID == bone.id);
}

static void testClickOnImageSelectsItAndArmsDefaultHandle() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(0, 0);
    scene.images.push_back(image);

    const Uuid imageID = image.id;
    ToolManager manager;
    manager.currentTool = ActiveTool::Move;
    manager.handleMouseDown(
        makeInput(Vec2(500, 500)), scene, stubImageHit(ImageHit{imageID, true, 0.0f}), 1.0f, false);

    UM_CHECK(scene.selectedImageID.has_value() && *scene.selectedImageID == imageID);
    // Move's default handle is moveCenter (ToolUtilities::defaultHandle).
    UM_CHECK(manager.activeHandle.has_value());
    UM_CHECK(std::holds_alternative<MoveCenterHandle>(*manager.activeHandle));
}

static void testClickOnEmptySelectCanvasClearsSelection() {
    EditorScene scene;
    const Uuid imageID = Uuid::generate();
    scene.setSelection({imageID}, imageID, false);

    ToolManager manager;
    manager.currentTool = ActiveTool::Select;
    manager.handleMouseDown(makeInput(Vec2(500, 500)), scene, stubImageHit(std::nullopt), 1.0f, false);

    UM_CHECK(!scene.selectedImageID.has_value());
}

static void testEmptyCanvasArmsRotateRingWhenSomethingIsAlreadySelected() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    scene.images.push_back(image);
    scene.selectedImageID = image.id;
    scene.selectedImageIDs = {image.id};

    ToolManager manager;
    manager.currentTool = ActiveTool::Rotate;
    // Click far from anything (empty canvas) -- Rotate still arms its ring
    // because something is already selected.
    manager.handleMouseDown(makeInput(Vec2(100, 100)), scene, stubImageHit(std::nullopt), 1.0f, false);

    UM_CHECK(manager.activeHandle.has_value());
    UM_CHECK(std::holds_alternative<RotateRingHandle>(*manager.activeHandle));
}

static void testBoneMarqueeInPoseModeSelectsIntersectingBones() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f); // world (0,0)-(100,0) -> screen (500,500)-(600,500).
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);
    scene.isPoseMode = true;

    ToolManager manager;
    manager.currentTool = ActiveTool::Select;
    // Start the drag on empty canvas (no gizmo grabbed).
    ToolInput down = makeInput(Vec2(300, 300));
    manager.handleMouseDown(down, scene, stubImageHit(std::nullopt), 1.0f, false);

    // Drag a marquee box that encloses the whole bone (500..600, 500).
    ToolInput drag = makeInput(Vec2(700, 700));
    drag.startScreenPosition = Vec2(300, 300);
    drag.startPosition = down.position;
    drag.isDragging = true;
    manager.handleMouseDrag(drag, scene, stubImageHit(std::nullopt), 1.0f, false);

    UM_CHECK(scene.selectedBoneIDs.count(bone.id) == 1);
    UM_CHECK(manager.selectionRect.has_value());
}

static void testHandlePointerExitClearsHoverStateOutsideADrag() {
    EditorScene scene;
    scene.hoveredImageID = Uuid::generate();

    ToolManager manager;
    ToolInput hover = makeInput(Vec2(500, 500));
    hover.isDragging = false;
    manager.lastInput = hover;
    manager.hoveredHandle = MoveCenterHandle{};

    manager.handlePointerExit(scene);

    UM_CHECK(!manager.lastInput.has_value());
    UM_CHECK(!manager.hoveredHandle.has_value());
    UM_CHECK(!scene.hoveredImageID.has_value());
}

static void testHandlePointerExitPreservesStateMidDrag() {
    EditorScene scene;
    scene.hoveredImageID = Uuid::generate();

    ToolManager manager;
    ToolInput dragging = makeInput(Vec2(500, 500));
    dragging.isDragging = true;
    manager.lastInput = dragging;
    manager.hoveredHandle = MoveCenterHandle{};

    manager.handlePointerExit(scene);

    // Mid-drag: nothing is cleared.
    UM_CHECK(manager.lastInput.has_value());
    UM_CHECK(scene.hoveredImageID.has_value());
}

static void testSetToolClearsPoseMode() {
    EditorScene scene;
    scene.isPoseMode = true;

    ToolManager manager;
    manager.setTool(scene, ActiveTool::Move);

    UM_CHECK(manager.currentTool == ActiveTool::Move);
    UM_CHECK(!scene.isPoseMode);
}

static void testQuickSwitchSetsAndClearsOverlayState() {
    EditorScene scene;
    ToolManager manager;
    manager.activateQuickSwitchTool(scene, ActiveTool::Skew, Vec2(42, 42));

    UM_CHECK(manager.currentTool == ActiveTool::Skew);
    UM_CHECK(manager.quickSwitchTool.has_value() && *manager.quickSwitchTool == ActiveTool::Skew);
    UM_CHECK(manager.quickSwitchCursorPosition.has_value());

    manager.endQuickSwitchOverlay();
    UM_CHECK(!manager.quickSwitchTool.has_value());
    UM_CHECK(!manager.quickSwitchCursorPosition.has_value());
}

UM_TEST_MAIN_BEGIN()
    testDispatchesToActiveTool();
    testMissingToolIsASafeNoOp();
    testClickOnBoneSelectsItThroughArbitration();
    testClickOnImageSelectsItAndArmsDefaultHandle();
    testClickOnEmptySelectCanvasClearsSelection();
    testEmptyCanvasArmsRotateRingWhenSomethingIsAlreadySelected();
    testBoneMarqueeInPoseModeSelectsIntersectingBones();
    testHandlePointerExitClearsHoverStateOutsideADrag();
    testHandlePointerExitPreservesStateMidDrag();
    testSetToolClearsPoseMode();
    testQuickSwitchSetsAndClearsOverlayState();
UM_TEST_MAIN_END()
