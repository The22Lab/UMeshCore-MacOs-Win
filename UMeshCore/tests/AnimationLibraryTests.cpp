// Tests for Animation/AnimationLibrary.h (ported from
// `Data/AnimationLibrary.swift`) and the JSON conversions for the project
// manifest's remaining model sections: NamedAnimation, HierarchyItem and
// CameraState. Expected behavior is hand-derived from the Swift source,
// whose two non-obvious rules (restore does not snapshot first; switchTo
// saves even when the target is already active) are asserted directly.

#include "umeshcore/Animation/AnimationLibrary.h"

#include "umeshcore/Editor/EditorScene.h"
#include "umeshcore/Serialization/SavedAnimation.h"
#include "umeshcore/Serialization/SavedEditorState.h"
#include "umeshcore/Serialization/SavedGeometry.h"
#include "TestHarness.h"

using namespace umeshcore;

namespace {

// A scene with one bone and one sprite, each carrying a one-keyframe clip
// whose value identifies which animation it came from.
EditorScene makeScene(float marker) {
    EditorScene scene;

    Bone bone;
    bone.name = "root";
    bone.animationClip = AnimationClip(
        "root", 10, {AnimationTrack(bone.id, AnimationTrackProperty::Rotate, {Keyframe(0, RotateValue{marker})})});
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);

    SceneImage image;
    image.name = "body";
    image.animationClip = AnimationClip(
        "body", 20,
        {AnimationTrack(image.id, AnimationTrackProperty::Translate, {Keyframe(0, TranslateValue{Vec2(marker, 0)})})});
    scene.images.push_back(image);

    scene.sceneAnimationClip = AnimationClip("Scene", 30);
    return scene;
}

float boneMarker(const EditorScene& scene) {
    const Bone& bone = scene.skeleton.bones().begin()->second;
    const RotateValue* value = std::get_if<RotateValue>(&bone.animationClip.tracks()[0].keyframes[0].value);
    return value != nullptr ? value->value : -1.0f;
}

} // namespace

static void testSnapshotCapturesEveryClipAndTheLongestDuration() {
    EditorScene scene = makeScene(1.0f);
    AnimationLibrary library(scene);
    library.createFromCurrentState("Walk");

    UM_CHECK(library.animations().size() == 1);
    const NamedAnimation& walk = library.animations()[0];
    UM_CHECK(walk.name == "Walk");
    UM_CHECK(walk.boneClips.size() == 1);
    UM_CHECK(walk.imageClips.size() == 1);
    // max(bone 10, image 20, scene 30).
    UM_CHECK(walk.duration == 30);
    UM_CHECK(library.activeID().has_value() && *library.activeID() == walk.id);
    UM_CHECK(library.active() != nullptr && library.active()->name == "Walk");
}

static void testSwitchingSavesOutgoingEditsAndLoadsTheTarget() {
    EditorScene scene = makeScene(1.0f);
    AnimationLibrary library(scene);
    library.createFromCurrentState("Walk");
    const Uuid walkID = *library.activeID();

    // A second animation, then edit the live clip so "Run" diverges.
    library.createFromCurrentState("Run");
    const Uuid runID = *library.activeID();
    Bone edited = scene.skeleton.bones().begin()->second;
    edited.animationClip = AnimationClip(
        "root", 10,
        {AnimationTrack(edited.id, AnimationTrackProperty::Rotate, {Keyframe(0, RotateValue{2.0f})})});
    scene.skeleton.setBone(edited);

    library.switchTo(walkID);
    UM_CHECK(*library.activeID() == walkID);
    // Walk's own value is back in the scene...
    UM_CHECK_NEAR(boneMarker(scene), 1.0, 1e-6);
    // ...and Run kept the edit that was live when we left it.
    for (const NamedAnimation& animation : library.animations()) {
        if (animation.id == runID) {
            const RotateValue* value =
                std::get_if<RotateValue>(&animation.boneClips.at(edited.id).tracks()[0].keyframes[0].value);
            UM_CHECK(value != nullptr && std::fabs(value->value - 2.0f) < 1e-6f);
        }
    }
}

static void testSwitchingToTheActiveAnimationSavesButDoesNotReload() {
    EditorScene scene = makeScene(1.0f);
    AnimationLibrary library(scene);
    library.createFromCurrentState("Only");
    const Uuid onlyID = *library.activeID();

    // Edit the live clip, then "switch" to the animation already active.
    Bone edited = scene.skeleton.bones().begin()->second;
    edited.animationClip = AnimationClip(
        "root", 10,
        {AnimationTrack(edited.id, AnimationTrackProperty::Rotate, {Keyframe(0, RotateValue{9.0f})})});
    scene.skeleton.setBone(edited);

    library.switchTo(onlyID);

    // The live edit survived -- it was saved into the entry, NOT
    // overwritten by a stale snapshot.
    UM_CHECK_NEAR(boneMarker(scene), 9.0, 1e-6);
    const RotateValue* stored =
        std::get_if<RotateValue>(&library.animations()[0].boneClips.at(edited.id).tracks()[0].keyframes[0].value);
    UM_CHECK(stored != nullptr && std::fabs(stored->value - 9.0f) < 1e-6f);
}

static void testRestoreDoesNotSnapshotOverTheRestoredList() {
    // The project was just loaded, so the live clips ARE the active
    // animation's; snapshotting first would overwrite the file's contents
    // with a copy of one of its own entries.
    EditorScene scene = makeScene(5.0f);
    AnimationLibrary library(scene);

    NamedAnimation saved;
    saved.name = "FromFile";
    saved.duration = 42;
    const Uuid savedID = saved.id;

    library.restore({saved}, savedID);
    UM_CHECK(library.animations().size() == 1);
    UM_CHECK(library.animations()[0].name == "FromFile");
    UM_CHECK(library.animations()[0].duration == 42); // untouched by a snapshot.
    UM_CHECK(library.activeID().has_value() && *library.activeID() == savedID);
}

static void testRestoreWithADanglingActiveIDSelectsNothing() {
    EditorScene scene = makeScene(1.0f);
    AnimationLibrary library(scene);

    NamedAnimation saved;
    saved.name = "Real";
    library.restore({saved}, Uuid::generate()); // an id naming nothing

    UM_CHECK(library.animations().size() == 1);
    UM_CHECK(!library.activeID().has_value());
    UM_CHECK(library.active() == nullptr);
}

static void testRenameAndRemove() {
    EditorScene scene = makeScene(1.0f);
    AnimationLibrary library(scene);
    library.createFromCurrentState("First");
    const Uuid firstID = *library.activeID();
    library.createFromCurrentState("Second");
    const Uuid secondID = *library.activeID();

    library.rename(firstID, "Renamed");
    UM_CHECK(library.animations()[0].name == "Renamed");

    library.remove(secondID);
    UM_CHECK(library.animations().size() == 1);
    // Removing the active entry falls back to the first remaining one.
    UM_CHECK(library.activeID().has_value() && *library.activeID() == firstID);

    library.remove(firstID);
    UM_CHECK(library.animations().empty());
    UM_CHECK(!library.activeID().has_value());
}

static void testNamedAnimationRoundTripsThroughJson() {
    EditorScene scene = makeScene(3.0f);
    AnimationLibrary library(scene);
    ConstraintSetupValues values;
    values.set(AnimationTrackProperty::ConstraintMix, 0.25f);
    scene.constraintSetupValues[Uuid::generate()] = values;
    library.createFromCurrentState("Walk");

    const NamedAnimation& original = library.animations()[0];
    const NamedAnimation back = namedAnimationFromJson(JsonValue::parse(toJson(original).dump()));

    UM_CHECK(back.id == original.id);
    UM_CHECK(back.name == "Walk");
    UM_CHECK(back.duration == original.duration);
    UM_CHECK(back.boneClips.size() == 1);
    UM_CHECK(back.imageClips.size() == 1);
    UM_CHECK(back.sceneClip.durationInFrames == 30);
    UM_CHECK(back.constraintSetupValues.size() == 1);

    const Uuid boneID = scene.skeleton.bones().begin()->first;
    const RotateValue* value =
        std::get_if<RotateValue>(&back.boneClips.at(boneID).tracks()[0].keyframes[0].value);
    UM_CHECK(value != nullptr && std::fabs(value->value - 3.0f) < 1e-6f);
}

static void testHierarchyItemRoundTripsIncludingNesting() {
    HierarchyItem child;
    child.name = "Arm";
    child.type = HierarchyItem::ItemType::Bone;
    child.order = 2;
    child.isHidden = true;

    HierarchyItem root;
    root.name = "Body";
    root.type = HierarchyItem::ItemType::Mesh;
    root.order = 1;
    root.children.push_back(child);

    const HierarchyItem back = hierarchyItemFromJson(toJson(root));
    UM_CHECK(back == root);
    UM_CHECK(back.children[0].type == HierarchyItem::ItemType::Bone);
    UM_CHECK(back.children[0].isHidden);
}

static void testUnknownHierarchyTypeFallsBackToImage() {
    const std::string text = "{\"id\":\"" + Uuid::generate().toString() +
                             "\",\"name\":\"x\",\"type\":\"someFutureKind\",\"isHidden\":false,\"order\":0}";
    const HierarchyItem item = hierarchyItemFromJson(JsonValue::parse(text));
    UM_CHECK(item.type == HierarchyItem::ItemType::Image);
    UM_CHECK(item.children.empty());
}

static void testCameraStateRoundTrips() {
    CameraState camera;
    camera.origin = Vec2(120, -45);
    camera.zoom = 2.5f;
    camera.rotation = 0.75f;

    const CameraState back = cameraStateFromJson(toJson(camera));
    UM_CHECK_NEAR(back.origin.x, 120.0, 1e-6);
    UM_CHECK_NEAR(back.origin.y, -45.0, 1e-6);
    UM_CHECK_NEAR(back.zoom, 2.5, 1e-6);
    UM_CHECK_NEAR(back.rotation, 0.75, 1e-6);
}

UM_TEST_MAIN_BEGIN()
    testSnapshotCapturesEveryClipAndTheLongestDuration();
    testSwitchingSavesOutgoingEditsAndLoadsTheTarget();
    testSwitchingToTheActiveAnimationSavesButDoesNotReload();
    testRestoreDoesNotSnapshotOverTheRestoredList();
    testRestoreWithADanglingActiveIDSelectsNothing();
    testRenameAndRemove();
    testNamedAnimationRoundTripsThroughJson();
    testHierarchyItemRoundTripsIncludingNesting();
    testUnknownHierarchyTypeFallsBackToImage();
    testCameraStateRoundTrips();
UM_TEST_MAIN_END()
