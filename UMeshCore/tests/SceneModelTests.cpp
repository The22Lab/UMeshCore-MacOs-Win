// Tests for SceneImage.h and UndoRedoManager.h, ported from
// `Data/SceneImage.swift` and `UndoRedoManager.swift`.

#include "umeshcore/Editor/UndoRedoManager.h"
#include "umeshcore/Model/SceneImage.h"
#include "TestHarness.h"

using namespace umeshcore;

static void testSceneImageEffectiveSlotNameFallsBackToName() {
    SceneImage img;
    img.name = "Left Hand";
    img.slotName = "";
    UM_CHECK(img.effectiveSlotName() == "Left Hand");

    img.slotName = "hand-slot";
    UM_CHECK(img.effectiveSlotName() == "hand-slot");
}

static void testTransformAnimationSpaceWorldVsBoneLocal() {
    const auto world = TransformAnimationSpace::world();
    UM_CHECK(!world.boneID.has_value());

    const Uuid bone = Uuid::generate();
    const auto local = TransformAnimationSpace::boneLocal(bone);
    UM_CHECK(local.boneID.has_value() && *local.boneID == bone);
}

static void testUndoRedoRoundTrip() {
    UndoRedoManager manager;
    UM_CHECK(!manager.canUndo());
    UM_CHECK(!manager.canRedo());

    SceneSnapshot stateA;
    stateA.sceneAnimationClip = AnimationClip("A");
    manager.push(stateA);
    UM_CHECK(manager.canUndo());
    UM_CHECK(!manager.canRedo());

    SceneSnapshot stateB;
    stateB.sceneAnimationClip = AnimationClip("B");
    auto restored = manager.undo(stateB);
    UM_CHECK(restored.has_value());
    UM_CHECK(restored->sceneAnimationClip.name == "A");
    UM_CHECK(!manager.canUndo());
    UM_CHECK(manager.canRedo());

    auto redone = manager.redo(*restored);
    UM_CHECK(redone.has_value());
    UM_CHECK(redone->sceneAnimationClip.name == "B");
    UM_CHECK(manager.canUndo());
    UM_CHECK(!manager.canRedo());
}

static void testUndoOnEmptyStackReturnsNullopt() {
    UndoRedoManager manager;
    SceneSnapshot current;
    UM_CHECK(!manager.undo(current).has_value());
    UM_CHECK(!manager.redo(current).has_value());
}

static void testPushClearsRedoStack() {
    UndoRedoManager manager;
    SceneSnapshot a, b, c;
    manager.push(a);
    auto restored = manager.undo(b);
    UM_CHECK(manager.canRedo());
    manager.push(c); // a fresh push should clear the redo stack.
    UM_CHECK(!manager.canRedo());
}

UM_TEST_MAIN_BEGIN()
    testSceneImageEffectiveSlotNameFallsBackToName();
    testTransformAnimationSpaceWorldVsBoneLocal();
    testUndoRedoRoundTrip();
    testUndoOnEmptyStackReturnsNullopt();
    testPushClearsRedoStack();
UM_TEST_MAIN_END()
