// Tests for EditorScene.h, ported from the corresponding `SceneManager.swift`
// selection/mutator methods. Expected values are hand-derived from those
// methods' documented behavior, not from this port's own output.

#include "umeshcore/Editor/EditorScene.h"
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

static void testSetSelectionReplacesAndClearsMeshState() {
    EditorScene scene;
    scene.isMeshLayerSelected = true;
    scene.selectedMeshVertexIndices = {1, 2, 3};

    const Uuid a = Uuid::generate();
    scene.setSelection({a}, a, /*additive=*/false);

    UM_CHECK(scene.selectedImageID.has_value() && *scene.selectedImageID == a);
    UM_CHECK(scene.selectedImageIDs.size() == 1);
    UM_CHECK(!scene.isMeshLayerSelected);
    UM_CHECK(scene.selectedMeshVertexIndices.empty());
}

static void testSetSelectionAdditiveUnionsExistingSet() {
    EditorScene scene;
    const Uuid a = Uuid::generate();
    const Uuid b = Uuid::generate();
    scene.setSelection({a}, a, false);
    scene.setSelection({b}, b, /*additive=*/true);

    UM_CHECK(scene.selectedImageIDs.size() == 2);
    UM_CHECK(scene.selectedImageID.has_value() && *scene.selectedImageID == b);
}

static void testClearSelectionResetsEverything() {
    EditorScene scene;
    const Uuid a = Uuid::generate();
    scene.setSelection({a}, a, false);
    scene.clearSelection();

    UM_CHECK(!scene.selectedImageID.has_value());
    UM_CHECK(scene.selectedImageIDs.empty());
    UM_CHECK(scene.selectedBoneIDs.empty());
}

static void testSelectBoneDisplacesSpriteSelection() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);

    const Uuid sprite = Uuid::generate();
    scene.setSelection({sprite}, sprite, false);
    scene.selectBone(bone.id);

    UM_CHECK(!scene.selectedImageID.has_value());
    UM_CHECK(scene.selectedImageIDs.empty());
    UM_CHECK(scene.selectedBoneID.has_value() && *scene.selectedBoneID == bone.id);
}

static void testToggleBoneSelectionAddsThenRemoves() {
    EditorScene scene;
    Bone a = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 50.0f);
    Bone b = makeBone(std::nullopt, Vec2(10, 0), 0.0f, 50.0f);
    scene.skeleton.setBone(a);
    scene.skeleton.setBone(b);
    scene.skeleton.rootIDs.push_back(a.id);
    scene.skeleton.rootIDs.push_back(b.id);

    scene.toggleBoneSelection(a.id);
    scene.toggleBoneSelection(b.id);
    UM_CHECK(scene.selectedBoneIDs.size() == 2);
    // Primary is the most recently added.
    UM_CHECK(scene.selectedBoneID.has_value() && *scene.selectedBoneID == b.id);

    scene.toggleBoneSelection(b.id);
    UM_CHECK(scene.selectedBoneIDs.size() == 1);
    UM_CHECK(scene.selectedBoneID.has_value() && *scene.selectedBoneID == a.id);
}

static void testSelectedBonesInChainOrderSortsParentsBeforeChildren() {
    EditorScene scene;
    Bone root = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 50.0f);
    scene.skeleton.setBone(root);
    scene.skeleton.rootIDs.push_back(root.id);
    Bone child = makeBone(root.id, Vec2(0, 0), 0.0f, 50.0f);
    scene.skeleton.setBone(child);

    // Clicked child first, then root -- selection order says child, root --
    // but chain order must still put the parent first.
    scene.setBoneSelection({child.id}, child.id, false);
    scene.setBoneSelection({root.id}, root.id, /*additive=*/true);

    const auto ordered = scene.selectedBonesInDepthOrder();
    UM_CHECK(ordered.size() == 2);
    UM_CHECK(ordered[0] == root.id);
    UM_CHECK(ordered[1] == child.id);
}

static void testPreviewPositionOverridesRenderPoseOnly() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(1, 1);
    scene.images.push_back(image);

    scene.setPreviewPosition(image.id, Vec2(50, 60));
    const SceneImage rendered = scene.renderPose(*scene.image(image.id));
    UM_CHECK_NEAR(rendered.position.x, 50.0, 1e-4);
    // The underlying model is untouched until commit.
    UM_CHECK_NEAR(scene.image(image.id)->position.x, 1.0, 1e-4);

    scene.clearPreviewPosition(image.id);
    const SceneImage afterClear = scene.renderPose(*scene.image(image.id));
    UM_CHECK_NEAR(afterClear.position.x, 1.0, 1e-4);
}

static void testSetImagePositionSyncsBasePoseWhenNotAnimating() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    scene.images.push_back(image);
    scene.isAnimationEditingEnabled = false;

    scene.setImagePosition(image.id, Vec2(12, 34));
    UM_CHECK_NEAR(scene.image(image.id)->position.x, 12.0, 1e-4);
    // Unbound sprite -> basePosition tracks the visible position directly.
    UM_CHECK_NEAR(scene.image(image.id)->basePosition.x, 12.0, 1e-4);
    UM_CHECK_NEAR(scene.image(image.id)->basePosition.y, 34.0, 1e-4);
}

static void testSetImagePositionDoesNotTouchBasePoseWhileAnimating() {
    EditorScene scene;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.basePosition = Vec2(0, 0);
    scene.images.push_back(image);
    scene.isAnimationEditingEnabled = true;

    scene.setImagePosition(image.id, Vec2(99, 99));
    UM_CHECK_NEAR(scene.image(image.id)->position.x, 99.0, 1e-4);
    UM_CHECK_NEAR(scene.image(image.id)->basePosition.x, 0.0, 1e-4);
}

static void testMoveBoneRootWritesBaseAndLiveTransformInEditorMode() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);
    scene.isAnimationEditingEnabled = false;

    scene.moveBoneRoot(bone.id, Vec2(25, 0));
    const Bone& moved = *scene.skeleton.bone(bone.id);
    UM_CHECK_NEAR(moved.localTransform.position.x, 25.0, 1e-3);
    UM_CHECK_NEAR(moved.baseTransform.position.x, 25.0, 1e-3);
}

static void testMoveBoneRootCommitsKeyframeInAnimateMode() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);
    scene.isAnimationEditingEnabled = true;
    scene.currentFrame = 4;
    scene.animationTime = 4.0f;

    scene.moveBoneRoot(bone.id, Vec2(40, 0));
    const Bone& moved = *scene.skeleton.bone(bone.id);
    UM_CHECK(moved.animationClip.hasTrack(bone.id, AnimationTrackProperty::Translate));
    // Base transform is untouched -- only the keyframe was written.
    UM_CHECK_NEAR(moved.baseTransform.position.x, 0.0, 1e-3);
}

static void testUndoRestoresPreviousSkeletonState() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);

    scene.beginInteraction(); // Snapshots the state BEFORE the move.
    scene.moveBoneRoot(bone.id, Vec2(77, 0));
    scene.endInteraction();
    UM_CHECK_NEAR(scene.skeleton.bone(bone.id)->localTransform.position.x, 77.0, 1e-3);

    scene.undo();
    UM_CHECK_NEAR(scene.skeleton.bone(bone.id)->localTransform.position.x, 0.0, 1e-3);

    scene.redo();
    UM_CHECK_NEAR(scene.skeleton.bone(bone.id)->localTransform.position.x, 77.0, 1e-3);
}

static void testBeginInteractionPushesOnlyOncePerGesture() {
    EditorScene scene;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    scene.skeleton.setBone(bone);
    scene.skeleton.rootIDs.push_back(bone.id);

    scene.beginInteraction();
    scene.moveBoneRoot(bone.id, Vec2(10, 0));
    scene.beginInteraction(); // Still mid-gesture -- must NOT push again.
    scene.moveBoneRoot(bone.id, Vec2(20, 0));
    scene.endInteraction();

    // One undo should return all the way to the pre-gesture state (0,0),
    // not to the intermediate (10,0) a second push would have captured.
    scene.undo();
    UM_CHECK_NEAR(scene.skeleton.bone(bone.id)->localTransform.position.x, 0.0, 1e-3);
}

UM_TEST_MAIN_BEGIN()
    testSetSelectionReplacesAndClearsMeshState();
    testSetSelectionAdditiveUnionsExistingSet();
    testClearSelectionResetsEverything();
    testSelectBoneDisplacesSpriteSelection();
    testToggleBoneSelectionAddsThenRemoves();
    testSelectedBonesInChainOrderSortsParentsBeforeChildren();
    testPreviewPositionOverridesRenderPoseOnly();
    testSetImagePositionSyncsBasePoseWhenNotAnimating();
    testSetImagePositionDoesNotTouchBasePoseWhileAnimating();
    testMoveBoneRootWritesBaseAndLiveTransformInEditorMode();
    testMoveBoneRootCommitsKeyframeInAnimateMode();
    testUndoRestoresPreviousSkeletonState();
    testBeginInteractionPushesOnlyOncePerGesture();
UM_TEST_MAIN_END()
