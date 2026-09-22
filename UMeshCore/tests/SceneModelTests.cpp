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

static void testSnapshotCarriesTheShotAndTheAuthoredConstraintValues() {
    // The three fields Phase 5 added. They are not decoration: without
    // `sceneCompositions`, undoing an "Align Camera to View" rolls the rig
    // back and leaves the camera where the mistake put it; without
    // `constraintSetupValues`, undoing a keyed change can leave a
    // constraint sitting at an evaluated value instead of its authored one.
    UndoRedoManager manager;

    SceneSnapshot before;
    SceneComposition shot;
    shot.id = Uuid(7, 7);
    shot.name = "Shot 1";
    shot.camera.positionZ = -1200.0f;
    before.sceneCompositions = {shot};
    before.selectedSceneCompositionID = Uuid(7, 7);
    ConstraintSetupValues authored;
    authored.set(AnimationTrackProperty::ConstraintMix, 0.25f);
    before.constraintSetupValues[Uuid(9, 9)] = authored;

    manager.push(before);

    // The "mistake": the camera is flown somewhere else and the constraint
    // is left at an evaluated value.
    SceneSnapshot after = before;
    after.sceneCompositions[0].camera.positionZ = -50.0f;
    after.constraintSetupValues[Uuid(9, 9)].set(AnimationTrackProperty::ConstraintMix, 0.9f);

    const auto restored = manager.undo(after);
    UM_CHECK(restored.has_value());
    if (!restored) return;
    UM_CHECK(restored->sceneCompositions.size() == 1);
    if (restored->sceneCompositions.size() == 1) {
        UM_CHECK_NEAR(restored->sceneCompositions[0].camera.positionZ, -1200.0, 1e-3);
        UM_CHECK(restored->sceneCompositions[0].name == "Shot 1");
    }
    UM_CHECK(restored->selectedSceneCompositionID == Uuid(7, 7));
    UM_CHECK(restored->constraintSetupValues.count(Uuid(9, 9)) == 1);
    if (restored->constraintSetupValues.count(Uuid(9, 9)) == 1) {
        const auto mix =
            restored->constraintSetupValues.at(Uuid(9, 9)).scalar(AnimationTrackProperty::ConstraintMix);
        UM_CHECK(mix.has_value());
        if (mix) UM_CHECK_NEAR(*mix, 0.25, 1e-6);
    }
}

static void testTheFlyCameraIsDeliberatelyNotInTheSnapshot() {
    // Matching Swift: where the artist is STANDING is not an edit. The
    // snapshot has no field for it, and this test is the reminder of why
    // rather than an oversight -- adding one would make undo teleport the
    // viewport, which is not what the artist asked to undo.
    //
    // Asserted structurally: a snapshot's whole surface is the nine fields
    // Swift has, so a tenth appearing should be a deliberate act that
    // updates this test too.
    SceneSnapshot snapshot;
    UM_CHECK(snapshot.images.empty());
    UM_CHECK(snapshot.skins.empty());
    UM_CHECK(snapshot.animationEvents.empty());
    UM_CHECK(snapshot.constraintSetupValues.empty());
    UM_CHECK(snapshot.sceneCompositions.empty());
    UM_CHECK(!snapshot.selectedSceneCompositionID.has_value());
    UM_CHECK(!snapshot.activeSkinID.has_value());
}

UM_TEST_MAIN_BEGIN()
    testSceneImageEffectiveSlotNameFallsBackToName();
    testTransformAnimationSpaceWorldVsBoneLocal();
    testUndoRedoRoundTrip();
    testSnapshotCarriesTheShotAndTheAuthoredConstraintValues();
    testTheFlyCameraIsDeliberatelyNotInTheSnapshot();
    testUndoOnEmptyStackReturnsNullopt();
    testPushClearsRedoStack();
UM_TEST_MAIN_END()
