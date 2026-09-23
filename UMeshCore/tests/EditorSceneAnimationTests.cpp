// Tests for EditorScene's animation half, absorbed from SceneManager in
// Phase 6a: the transport, the canvas modes a tool change leaves, the
// escape ladder, the key button, keyframe selection / copy / paste /
// duplicate, and animation events.
//
// One test pins a Swift BUG the port fixes (convention #3), named as such:
// events never fired during playback.

#include "umeshcore/Editor/EditorScene.h"
#include "umeshcore/Editor/ToolManager.h"

#include <algorithm>
#include <cmath>

#include "TestHarness.h"

using namespace umeshcore;

namespace {

Uuid addSprite(EditorScene& scene, const std::string& name) {
    return scene.addImage(Uuid::generate(), name, Vec2(64, 64), Vec2(0, 0), std::nullopt);
}

// An event definition keyed at each of `frames`.
Uuid eventKeyedAt(EditorScene& scene, const std::string& name, const std::vector<int>& frames) {
    const Uuid id = scene.createAnimationEvent(name);
    for (int f : frames) {
        scene.currentFrame = f;
        scene.keyEvent(id, AnimationEventPayload{});
    }
    scene.currentFrame = 0;
    return id;
}

std::vector<int> firedFrames(const EditorScene& scene) {
    std::vector<int> out;
    for (const auto& e : scene.recentlyFiredEvents) out.push_back(e.frame);
    return out;
}

std::vector<int> frames(const std::vector<Keyframe>& keys) {
    std::vector<int> out;
    for (const Keyframe& k : keys) out.push_back(k.frame);
    return out;
}

} // namespace

// ---- Transport --------------------------------------------------------------

// SWIFT BUG, FIXED: `tickPlayback` wrote `currentFrame` without calling
// `fireEventsCrossed`, so an event keyed at frame 5 fired when the artist
// scrubbed over it and never while the clip played.
static void testEventsFireWhilePlaying() {
    EditorScene scene;
    eventKeyedAt(scene, "footstep", {5});
    scene.play(/*now=*/100.0, /*looping=*/false, 0, 20, /*fps=*/10.0);
    scene.tickPlayback(100.0 + 0.45); // frame 4.5: not yet
    UM_CHECK(scene.recentlyFiredEvents.empty());
    scene.tickPlayback(100.0 + 0.55); // frame 5.5: crossed 5
    UM_CHECK(firedFrames(scene) == std::vector<int>{5});
    UM_CHECK(scene.recentlyFiredEvents[0].name == "footstep");
    scene.tickPlayback(100.0 + 0.58); // same whole frame: nothing new
    UM_CHECK(scene.recentlyFiredEvents.size() == 1);
}

// The loop wrap is two forward spans over the SESSION's bounds, each in
// frame order, appended in the order they were crossed.
static void testALoopWrapFiresTheEndOfTheOldLapThenTheStartOfTheNew() {
    EditorScene scene; // project range 0...90
    eventKeyedAt(scene, "a", {9});
    eventKeyedAt(scene, "b", {1});
    eventKeyedAt(scene, "c", {50}); // outside the loop the session plays
    scene.play(0.0, /*looping=*/true, 0, 9, 10.0);
    scene.tickPlayback(0.85); // 0 -> 8 crosses 1
    UM_CHECK(firedFrames(scene) == std::vector<int>{1});
    scene.clearFiredEvents();
    // 12.5 frames in: wraps to 2.5. Crossed 9 (old lap), then 0..2 (new).
    scene.tickPlayback(1.25);
    UM_CHECK(scene.currentFrame == 2);
    UM_CHECK(firedFrames(scene) == (std::vector<int>{9, 1}));
}

static void testScrubbingBackwardsFiresNothing() {
    EditorScene scene;
    eventKeyedAt(scene, "hit", {5});
    scene.setCurrentFrame(10);
    UM_CHECK(firedFrames(scene) == std::vector<int>{5});
    scene.setCurrentFrame(2);
    UM_CHECK(scene.recentlyFiredEvents.size() == 1);
    scene.setCurrentFrame(5); // inclusive of the destination
    UM_CHECK(firedFrames(scene) == (std::vector<int>{5, 5}));
}

// A clip that does not loop stops on its last frame, and the wake the
// shell schedules arrives a frame LATE so it always finds the end passed.
static void testANonLoopingClipStopsOnItsLastFrame() {
    EditorScene scene;
    const std::optional<double> wake = scene.play(0.0, /*looping=*/false, 0, 9, 10.0);
    UM_CHECK(wake.has_value());
    UM_CHECK_NEAR(*wake, 1.0, 1e-12); // (9 + 1 - 0) / 10
    scene.tickPlayback(0.85);
    UM_CHECK(scene.isPlaying && scene.currentFrame == 8);
    // The wake: 10 frames in, past frame 9 -- the transport stops ON 9.
    scene.tickPlayback(*wake);
    UM_CHECK(!scene.isPlaying);
    UM_CHECK(scene.currentFrame == 9 && scene.playheadFrame == 9.0);
    UM_CHECK(!scene.playbackSession.has_value());
    // A looping clip asks for no wake.
    UM_CHECK(!scene.play(0.0, true, 0, 9, 10.0).has_value());
}

// Nothing accumulates: the playhead is a pure function of time, so ticks
// out of order land exactly where the clock says.
static void testThePlayheadIsAPureFunctionOfTime() {
    EditorScene scene;
    scene.play(50.0, true, 0, 99, 24.0);
    scene.tickPlayback(50.5);
    UM_CHECK(scene.currentFrame == 12); // 0.5 s * 24
    scene.tickPlayback(50.25);
    UM_CHECK(scene.currentFrame == 6);
    UM_CHECK_NEAR(scene.playheadFrame, 6.0, 1e-9);
    UM_CHECK_NEAR(scene.animationTime, 6.0, 1e-6);
}

static void testSetAnimationTimeKeepsTheFractionForThePose() {
    EditorScene scene;
    scene.setAnimationTime(7.75);
    UM_CHECK(scene.currentFrame == 7);
    UM_CHECK_NEAR(scene.animationTime, 7.75, 1e-6);
    UM_CHECK_NEAR(scene.playheadFrame, 7.75, 1e-12);
    scene.setAnimationTime(-3.0);
    UM_CHECK(scene.currentFrame == 0);
    // setCurrentFrame snaps the continuous time to the whole frame.
    scene.setAnimationTime(4.5);
    scene.setCurrentFrame(4);
    UM_CHECK_NEAR(scene.animationTime, 4.0, 1e-6);
}

static void testRangeAndStepClamp() {
    EditorScene scene;
    scene.setCurrentFrame(50);
    scene.setPlaybackRange(10, 5); // end below start collapses onto start
    UM_CHECK(scene.playbackStartFrame == 10 && scene.playbackEndFrame == 10);
    UM_CHECK(scene.currentFrame == 10);
    scene.setPlaybackRange(0, 20);
    scene.stepFrames(100, std::nullopt, std::nullopt);
    UM_CHECK(scene.currentFrame == 20);
    scene.stepFrames(-100, std::nullopt, std::nullopt);
    UM_CHECK(scene.currentFrame == 0);
    scene.stepFrames(3, 5, 8); // explicit bounds win over the project range
    UM_CHECK(scene.currentFrame == 5);
}

// `projectFramesPerSecond.didSet`: clamped to 1..240; a change restarts a
// running session; Swift's double-firing didSet also restarts on an
// out-of-range value that clamps to the current rate (kept, harmless).
static void testTheProjectRateClampsAndRestartsPlayback() {
    EditorScene scene;
    scene.setProjectFramesPerSecond(0.25, 0.0);
    UM_CHECK(scene.projectFramesPerSecond == 1.0);
    scene.setProjectFramesPerSecond(24.0, 0.0);
    scene.play(10.0, true, std::nullopt, std::nullopt, std::nullopt);
    UM_CHECK(scene.playbackSession->framesPerSecond == 24.0);

    scene.setProjectFramesPerSecond(300.0, 11.0);
    UM_CHECK(scene.projectFramesPerSecond == 240.0);
    UM_CHECK(scene.isPlaying && scene.playbackSession->framesPerSecond == 240.0);
    UM_CHECK(scene.playbackSession->startTime == 11.0);

    scene.setProjectFramesPerSecond(240.0, 12.0); // no change: no restart
    UM_CHECK(scene.playbackSession->startTime == 11.0);
    scene.setProjectFramesPerSecond(500.0, 13.0); // out of range: restarts
    UM_CHECK(scene.playbackSession->startTime == 13.0);
    scene.setProjectFramesPerSecond(std::nan(""), 14.0); // refused
    UM_CHECK(scene.projectFramesPerSecond == 240.0);
    UM_CHECK(scene.playbackSession->startTime == 13.0);
}

// ---- Canvas modes and the way out --------------------------------------------

static void testAToolChangeLeavesTheModesItCannotServe() {
    EditorScene scene;
    ToolManager tools;
    scene.isPoseMode = true;
    scene.pendingCanvasMode = "weights";
    scene.isMeshEditEnabled = true;
    scene.meshWeightPaintEnabled = true;
    scene.isBindingBonesMode = true;
    scene.hoveredBindBoneID = Uuid(9, 9);

    // The mesh tool keeps the mesh modes, but not pose or a pending mode.
    tools.setTool(scene, ActiveTool::Mesh);
    UM_CHECK(scene.activeCanvasTool == ActiveTool::Mesh);
    UM_CHECK(!scene.isPoseMode && !scene.pendingCanvasMode.has_value());
    UM_CHECK(scene.isMeshEditEnabled && scene.meshWeightPaintEnabled && scene.isBindingBonesMode);

    // Any other tool leaves all of them, bind hover included.
    tools.activateQuickSwitchTool(scene, ActiveTool::Move);
    UM_CHECK(scene.activeCanvasTool == ActiveTool::Move);
    UM_CHECK(!scene.isMeshEditEnabled && !scene.meshWeightPaintEnabled && !scene.isBindingBonesMode);
    UM_CHECK(!scene.hoveredBindBoneID.has_value());
}

// Picking a bone ends the sprite modes -- and, with the mesh tool in hand,
// asks the shell to put Select back (the tool manager is the shell's).
static void testPickingABoneEndsTheSpriteModes() {
    EditorScene scene;
    const Uuid bone = scene.addBone(Vec2(0, 0), Vec2(50, 0));
    scene.canvasToolChanged(ActiveTool::Mesh);
    scene.isMeshEditEnabled = true;
    scene.meshEditNotice = EditorScene::MeshEditNotice{"hull is open", true};
    scene.selectBone(bone);
    UM_CHECK(!scene.isSpriteMeshMode());
    UM_CHECK(!scene.meshEditNotice.has_value());
    UM_CHECK(scene.requestedToolChange == std::optional<ActiveTool>(ActiveTool::Select));

    // With no sprite mode running there is nothing to leave and no request.
    scene.requestedToolChange = std::nullopt;
    scene.selectBone(bone);
    UM_CHECK(!scene.requestedToolChange.has_value());
}

static void testEscapeLeavesOneRungAtATime() {
    EditorScene scene;
    const Uuid sprite = addSprite(scene, "S");
    scene.selectMeshLayer(sprite);
    scene.isMeshEditEnabled = true;
    scene.meshWeightPaintEnabled = true;
    scene.selectMeshVertices({1, 2});

    UM_CHECK(scene.exitDeepestScope(true) == std::optional<EditorScope>(EditorScope::MeshVertexSelection));
    UM_CHECK(scene.selectedMeshVertexIndices.empty() && scene.meshWeightPaintEnabled);
    UM_CHECK(scene.exitDeepestScope(true) == std::optional<EditorScope>(EditorScope::WeightPaint));
    UM_CHECK(scene.isMeshEditEnabled && !scene.meshWeightPaintEnabled);
    UM_CHECK(scene.exitDeepestScope(true) == std::optional<EditorScope>(EditorScope::MeshEdit));
    UM_CHECK(!scene.isMeshOverlayVisible());
    UM_CHECK(scene.exitDeepestScope(true) == std::optional<EditorScope>(EditorScope::ImageSelection));
    UM_CHECK(scene.selectedImageIDs.empty());
    // The tool rung is reported but left to the caller.
    UM_CHECK(scene.exitDeepestScope(true) == std::optional<EditorScope>(EditorScope::ActiveTool));
    UM_CHECK(!scene.exitDeepestScope(false).has_value());
}

// ---- The key button -----------------------------------------------------------

static void testTheKeyButtonWritesTheToolsChannelAndCompletesAPartialKey() {
    EditorScene scene;
    const Uuid sprite = addSprite(scene, "S");
    UM_CHECK(!scene.toggleTransformKey()); // Editor mode: refused
    scene.setAnimationEditingEnabled(true);
    scene.setCurrentFrame(4);

    // Rotate in hand: the press keys the rotation only.
    scene.canvasToolChanged(ActiveTool::Rotate);
    UM_CHECK(scene.transformKeyState() == EditorScene::TransformKeyState::None);
    UM_CHECK(scene.toggleTransformKey());
    UM_CHECK(scene.keyframes(sprite, AnimationTrackProperty::Rotate).size() == 1);
    UM_CHECK(scene.keyframes(sprite, AnimationTrackProperty::Translate).empty());
    UM_CHECK(scene.transformKeyState() == EditorScene::TransformKeyState::Full);

    // With Move in hand the same frame is clean -- scoped to the channel.
    scene.canvasToolChanged(ActiveTool::Move);
    UM_CHECK(scene.transformKeyState() == EditorScene::TransformKeyState::None);

    // Select keys the whole transform: 1 of 4 present reads Partial, and
    // pressing COMPLETES it rather than clearing the rotation.
    scene.canvasToolChanged(ActiveTool::Select);
    UM_CHECK(scene.transformKeyState() == EditorScene::TransformKeyState::Partial);
    UM_CHECK(scene.toggleTransformKey());
    UM_CHECK(scene.transformKeyState() == EditorScene::TransformKeyState::Full);
    UM_CHECK(scene.selectedKeyframes.size() == 4);
    UM_CHECK(scene.selectedKeyframe.has_value() && scene.selectedKeyframe->property == AnimationTrackProperty::Translate);

    // Full: the press clears all four, and the selection with them.
    UM_CHECK(scene.toggleTransformKey());
    UM_CHECK(scene.transformKeyState() == EditorScene::TransformKeyState::None);
    UM_CHECK(scene.selectedKeyframes.empty() && !scene.selectedKeyframe.has_value());
    // One undo step per press.
    scene.undo();
    UM_CHECK(scene.transformKeyState() == EditorScene::TransformKeyState::Full);
}

static void testAMixedBoneSelectionReadsPartial() {
    EditorScene scene;
    const Uuid root = scene.addBone(Vec2(0, 0), Vec2(50, 0));
    const Uuid tip = scene.addBone(Vec2(50, 0), Vec2(90, 0), root);
    scene.setAnimationEditingEnabled(true);
    scene.canvasToolChanged(ActiveTool::Rotate);
    scene.selectBone(root);
    scene.toggleTransformKey();
    scene.setBoneSelection({root, tip}, std::nullopt, false);
    // Hierarchy order, root first, whatever the click order.
    UM_CHECK(scene.transformKeyTargets() == (std::vector<Uuid>{root, tip}));
    UM_CHECK(scene.transformKeyState() == EditorScene::TransformKeyState::Partial);
    scene.toggleTransformKey();
    UM_CHECK(scene.keyframes(root, AnimationTrackProperty::Rotate).size() == 1); // not cleared
    UM_CHECK(scene.keyframes(tip, AnimationTrackProperty::Rotate).size() == 1);
}

// ---- Keyframe selection, copy, paste, duplicate --------------------------------

static void testCopyPasteKeepsSpacingAndSelectsThePastedKeys() {
    EditorScene scene;
    const Uuid sprite = addSprite(scene, "S");
    scene.setAnimationEditingEnabled(true);
    scene.setCurrentFrame(10);
    scene.commitKeyframe(sprite, AnimationTrackProperty::Translate, TranslateValue{Vec2(1, 2)});
    scene.commitKeyframe(sprite, AnimationTrackProperty::Rotate, RotateValue{0.5f});
    scene.setCurrentFrame(14);
    scene.commitKeyframe(sprite, AnimationTrackProperty::Rotate, RotateValue{1.5f});

    std::vector<SelectedKeyframe> all;
    for (auto p : {AnimationTrackProperty::Translate, AnimationTrackProperty::Rotate}) {
        for (const Keyframe& k : scene.keyframes(sprite, p)) all.push_back({sprite, p, k.id});
    }
    scene.setSelectedKeyframes(all, false);
    UM_CHECK(scene.copySelectedKeyframes() == 3);
    // By frame, then by the property's file-format name ("rotate" <
    // "translate"), relative to the first.
    UM_CHECK(scene.copiedKeyframes[0].property == AnimationTrackProperty::Rotate);
    UM_CHECK(scene.copiedKeyframes[0].relativeFrame == 0);
    UM_CHECK(scene.copiedKeyframes[1].property == AnimationTrackProperty::Translate);
    UM_CHECK(scene.copiedKeyframes[2].relativeFrame == 4);

    scene.setCurrentFrame(30);
    scene.pasteCopiedKeyframes();
    UM_CHECK(frames(scene.keyframes(sprite, AnimationTrackProperty::Rotate)) == (std::vector<int>{10, 14, 30, 34}));
    UM_CHECK(frames(scene.keyframes(sprite, AnimationTrackProperty::Translate)) == (std::vector<int>{10, 30}));
    UM_CHECK(scene.selectedKeyframes.size() == 3);
    UM_CHECK(scene.selectedImageID == sprite);
    const Keyframe* pasted =
        scene.images[0].animationClip.keyframe(sprite, AnimationTrackProperty::Rotate, scene.selectedKeyframes[0].keyframeID);
    UM_CHECK(pasted != nullptr && pasted->frame == 30);
}

// Duplicates land right after the selection's span, and -- as Swift writes
// it -- `currentFrame` moves to the span's start WITHOUT moving the pose.
static void testDuplicateLandsAfterTheSpan() {
    EditorScene scene;
    const Uuid sprite = addSprite(scene, "S");
    scene.setAnimationEditingEnabled(true);
    scene.setCurrentFrame(10);
    scene.commitKeyframe(sprite, AnimationTrackProperty::Rotate, RotateValue{0.0f});
    const SelectedKeyframe first = *scene.selectedKeyframe;
    scene.setCurrentFrame(12);
    scene.commitKeyframe(sprite, AnimationTrackProperty::Rotate, RotateValue{1.0f});
    const SelectedKeyframe second = *scene.selectedKeyframe;
    scene.setCurrentFrame(40);
    scene.selectedKeyframes = {first, second};
    scene.duplicateSelectedKeyframes();
    UM_CHECK(frames(scene.keyframes(sprite, AnimationTrackProperty::Rotate)) == (std::vector<int>{10, 12, 13, 15}));
    UM_CHECK(scene.currentFrame == 10);
    UM_CHECK_NEAR(scene.animationTime, 40.0, 1e-6);
}

static void testSelectionTogglesAndDrivesTheSpriteSelection() {
    EditorScene scene;
    const Uuid a = addSprite(scene, "A");
    const Uuid bone = scene.addBone(Vec2(0, 0), Vec2(40, 0));
    const SelectedKeyframe k1{a, AnimationTrackProperty::Rotate, Uuid(1, 1)};
    const SelectedKeyframe k2{a, AnimationTrackProperty::Rotate, Uuid(1, 2)};
    scene.selectKeyframe(k1.imageID, k1.property, k1.keyframeID, false);
    UM_CHECK(scene.selectedImageID == a && !scene.selectedBoneID.has_value());
    scene.selectKeyframe(k2.imageID, k2.property, k2.keyframeID, true);
    UM_CHECK(scene.selectedKeyframes.size() == 2);
    scene.selectKeyframe(k1.imageID, k1.property, k1.keyframeID, true); // additive toggles off
    UM_CHECK(scene.selectedKeyframes == std::vector<SelectedKeyframe>{k2});
    UM_CHECK(scene.selectedKeyframe == std::optional<SelectedKeyframe>(k2));
    // A bone's key selects the bone.
    scene.selectKeyframe(bone, AnimationTrackProperty::Rotate, Uuid(2, 1), false);
    UM_CHECK(scene.selectedBoneID == bone && !scene.selectedImageID.has_value());
}

static void testMoveSelectedKeyframesShiftsFromTheirStartFrames() {
    EditorScene scene;
    const Uuid sprite = addSprite(scene, "S");
    scene.setAnimationEditingEnabled(true);
    std::vector<EditorScene::KeyframeStart> starts;
    for (int f : {3, 6}) {
        scene.setCurrentFrame(f);
        scene.commitKeyframe(sprite, AnimationTrackProperty::Rotate, RotateValue{static_cast<float>(f)});
        starts.push_back({*scene.selectedKeyframe, f});
    }
    scene.selectedKeyframes = {starts[0].key, starts[1].key};
    // Deltas are applied to the START frames, so a drag that reports its
    // total delta twice moves once.
    scene.moveSelectedKeyframes(starts[0].key, 5, starts);
    scene.moveSelectedKeyframes(starts[0].key, 5, starts);
    UM_CHECK(frames(scene.keyframes(sprite, AnimationTrackProperty::Rotate)) == (std::vector<int>{8, 11}));
    UM_CHECK(scene.selectedKeyframe == std::optional<SelectedKeyframe>(starts[0].key));
}

static void testInterpolationIsReportedOnlyWhenUnanimous() {
    EditorScene scene;
    const Uuid sprite = addSprite(scene, "S");
    scene.setAnimationEditingEnabled(true);
    std::vector<SelectedKeyframe> keys;
    for (int f : {0, 10}) {
        scene.setCurrentFrame(f);
        scene.commitKeyframe(sprite, AnimationTrackProperty::Rotate, RotateValue{0.0f});
        keys.push_back(*scene.selectedKeyframe);
    }
    scene.selectedKeyframes = keys;
    UM_CHECK(scene.selectedKeyframeInterpolation() == std::optional<KeyframeInterpolation>(KeyframeInterpolation::Linear));
    scene.selectedKeyframes = {keys[0]};
    scene.setInterpolationForSelectedKeyframes(KeyframeInterpolation::Hold);
    scene.selectedKeyframes = keys;
    UM_CHECK(!scene.selectedKeyframeInterpolation().has_value());
}

// Deleting the last key of a constraint property puts the authored value
// back rather than leaving whatever the key held.
static void testDeletingTheLastConstraintKeyRestoresTheAuthoredValue() {
    EditorScene scene;
    const Uuid a = scene.addBone(Vec2(0, 0), Vec2(100, 0));
    const Uuid b = scene.addBone(Vec2(100, 0), Vec2(200, 0), a);
    const Uuid handle = scene.addBone(Vec2(300, 0), Vec2(320, 0));
    scene.skeleton.ikConstraints.push_back(IKConstraint("IK", {a, b}, handle));
    const Uuid ik = scene.skeleton.ikConstraints[0].id();
    scene.setAnimationEditingEnabled(true);
    scene.setConstraintScalar(ik, AnimationTrackProperty::ConstraintMix, 0.25f, true);
    UM_CHECK(scene.selectedKeyframes.size() == 1);
    scene.deleteSelectedKeyframes();
    UM_CHECK(!scene.isConstraintPropertyAnimated(ik, AnimationTrackProperty::ConstraintMix));
    UM_CHECK_NEAR(scene.constraintScalarValue(ik, AnimationTrackProperty::ConstraintMix), 1.0, 1e-6);
}

// ---- Events ---------------------------------------------------------------------

static void testEventDefinitionsAndTheirKeys() {
    EditorScene scene;
    const Uuid e1 = scene.createAnimationEvent(std::nullopt);
    const Uuid e2 = scene.createAnimationEvent(std::nullopt);
    UM_CHECK(scene.animationEvent(e1)->name == "event");
    UM_CHECK(scene.animationEvent(e2)->name == "event 2");
    scene.renameAnimationEvent(e2, "  event  "); // trimmed, then made unique
    UM_CHECK(scene.animationEvent(e2)->name == "event 2");
    scene.renameAnimationEvent(e2, "  land ");
    UM_CHECK(scene.animationEvent(e2)->name == "land");

    scene.currentFrame = 7;
    scene.keyEvent(e2, AnimationEventPayload{3, std::nullopt, std::nullopt});
    UM_CHECK(scene.keyedEventIDs() == std::vector<Uuid>{e2});
    UM_CHECK(scene.eventHasKeyAtPlayhead(e2));
    UM_CHECK(scene.eventPayloadAtPlayhead(e2)->intValue == std::optional<int>(3));

    // A key's payload overrides, the definition fills the rest.
    AnimationEvent def = *scene.animationEvent(e2);
    def.defaultString = "dust";
    scene.replaceAnimationEvent(def);
    scene.setCurrentFrame(0);
    scene.setCurrentFrame(7);
    UM_CHECK(scene.recentlyFiredEvents.size() == 1);
    UM_CHECK(scene.recentlyFiredEvents[0].intValue == 3 && scene.recentlyFiredEvents[0].stringValue == "dust");

    // Deleting the definition takes its keys with it.
    scene.deleteAnimationEvent(e2);
    UM_CHECK(!scene.sceneAnimationClip.hasTrack(e2, AnimationTrackProperty::Event));
    UM_CHECK(scene.keyedEventIDs().empty());
}

static void testTheFiredReadoutKeepsTheLast32() {
    EditorScene scene;
    std::vector<int> keyed;
    for (int f = 1; f <= 40; ++f) keyed.push_back(f);
    eventKeyedAt(scene, "tick", keyed);
    scene.setCurrentFrame(40);
    UM_CHECK(scene.recentlyFiredEvents.size() == 32);
    UM_CHECK(scene.recentlyFiredEvents.front().frame == 9 && scene.recentlyFiredEvents.back().frame == 40);
}

UM_TEST_MAIN_BEGIN()
    testEventsFireWhilePlaying();
    testALoopWrapFiresTheEndOfTheOldLapThenTheStartOfTheNew();
    testScrubbingBackwardsFiresNothing();
    testANonLoopingClipStopsOnItsLastFrame();
    testThePlayheadIsAPureFunctionOfTime();
    testSetAnimationTimeKeepsTheFractionForThePose();
    testRangeAndStepClamp();
    testTheProjectRateClampsAndRestartsPlayback();
    testAToolChangeLeavesTheModesItCannotServe();
    testPickingABoneEndsTheSpriteModes();
    testEscapeLeavesOneRungAtATime();
    testTheKeyButtonWritesTheToolsChannelAndCompletesAPartialKey();
    testAMixedBoneSelectionReadsPartial();
    testCopyPasteKeepsSpacingAndSelectsThePastedKeys();
    testDuplicateLandsAfterTheSpan();
    testSelectionTogglesAndDrivesTheSpriteSelection();
    testMoveSelectedKeyframesShiftsFromTheirStartFrames();
    testInterpolationIsReportedOnlyWhenUnanimous();
    testDeletingTheLastConstraintKeyRestoresTheAuthoredValue();
    testEventDefinitionsAndTheirKeys();
    testTheFiredReadoutKeepsTheLast32();
UM_TEST_MAIN_END()
