// Tests for SelectTool, ported from `Core/Tools/SelectTool.swift`.
// Expected values are hand-derived from that file's documented behavior,
// not from this port's own output. Uses a stub image hit-test since the
// real alpha-based one isn't ported yet (see CanvasPicking.h).

#include "umeshcore/Editor/Tools/SelectTool.h"
#include "TestHarness.h"

using namespace umeshcore;

static Bone makeBone(Vec2 start, Vec2 end) { return Bone::makeRoot("bone", start, end); }

static ImageHitTestFn stubImageHit(std::optional<ImageHit> result) {
    return [result](const Vec2&, const Vec2&, CameraState*) { return result; };
}

static ToolInput makeClick(Vec2 screenPos, Vec2 viewSize, bool shift = false, bool cmd = false) {
    ToolInput input;
    input.position = screenPos - viewSize * 0.5f; // World, no camera.
    input.screenPosition = screenPos;
    input.viewSize = viewSize;
    input.isShiftPressed = shift;
    input.isCommandPressed = cmd;
    return input;
}

static void testClickOnImageSelectsIt() {
    EditorScene scene;
    const Uuid imageID = Uuid::generate();
    const Vec2 viewSize(1000, 1000);

    SelectTool tool;
    tool.onMouseDown(
        makeClick(viewSize * 0.5f, viewSize), scene, stubImageHit(ImageHit{imageID, true, 0.0f}),
        /*hitScale=*/1.0f, /*touchOptimized=*/false);

    UM_CHECK(scene.selectedImageID.has_value() && *scene.selectedImageID == imageID);
}

static void testClickOnBoneWithoutModifierReplacesSelection() {
    EditorScene scene;
    Bone bone = makeBone(Vec2(0, 0), Vec2(10, 0));
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);
    const Vec2 viewSize(1000, 1000);

    SelectTool tool;
    tool.onMouseDown(
        makeClick(viewSize * 0.5f, viewSize), scene, stubImageHit(std::nullopt), 1.0f, false);

    UM_CHECK(scene.selectedBoneID.has_value() && *scene.selectedBoneID == bone.id);
}

static void testShiftClickOnBoneTogglesMultiSelection() {
    EditorScene scene;
    Bone a = makeBone(Vec2(0, 0), Vec2(10, 0));
    Bone b = makeBone(Vec2(100, 0), Vec2(110, 0));
    scene.skeleton.setBone(a);
    scene.skeleton.setBone(b);
    scene.skeleton.rootIDs.push_back(a.id);
    scene.skeleton.rootIDs.push_back(b.id);
    const Vec2 viewSize(1000, 1000);

    SelectTool tool;
    // Plain click selects bone a.
    tool.onMouseDown(makeClick(viewSize * 0.5f, viewSize), scene, stubImageHit(std::nullopt), 1.0f, false);
    UM_CHECK(scene.selectedBoneIDs.size() == 1);

    // Shift-click on bone b extends the selection (world (100,0) -> screen
    // center + (100,0)).
    tool.onMouseDown(
        makeClick(viewSize * 0.5f + Vec2(100, 0), viewSize, /*shift=*/true), scene, stubImageHit(std::nullopt),
        1.0f, false);
    UM_CHECK(scene.selectedBoneIDs.size() == 2);
}

static void testClickOnEmptyCanvasClearsSelection() {
    EditorScene scene;
    const Uuid imageID = Uuid::generate();
    scene.setSelection({imageID}, imageID, false);
    const Vec2 viewSize(1000, 1000);

    SelectTool tool;
    tool.onMouseDown(
        makeClick(viewSize * 0.5f, viewSize), scene, stubImageHit(std::nullopt), 1.0f, false);

    UM_CHECK(!scene.selectedImageID.has_value());
}

static void testShiftClickOnEmptyCanvasPreservesSelection() {
    EditorScene scene;
    const Uuid imageID = Uuid::generate();
    scene.setSelection({imageID}, imageID, false);
    const Vec2 viewSize(1000, 1000);

    SelectTool tool;
    tool.onMouseDown(
        makeClick(viewSize * 0.5f, viewSize, /*shift=*/true), scene, stubImageHit(std::nullopt), 1.0f, false);

    // A Shift-drag that starts on empty canvas is adding a marquee to the
    // existing selection, not clearing it.
    UM_CHECK(scene.selectedImageID.has_value() && *scene.selectedImageID == imageID);
}

UM_TEST_MAIN_BEGIN()
    testClickOnImageSelectsIt();
    testClickOnBoneWithoutModifierReplacesSelection();
    testShiftClickOnBoneTogglesMultiSelection();
    testClickOnEmptyCanvasClearsSelection();
    testShiftClickOnEmptyCanvasPreservesSelection();
UM_TEST_MAIN_END()
