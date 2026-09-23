// Tests for opening and saving a project through EditorScene (Phase 6a A8):
// `restoreProject`, `projectDocumentFrom`, and the `restored*()` validation
// in `applyProjectDocument`.
//
// One test pins a Swift BUG the port fixes (convention #3): opening a
// project kept the previous project's undo history.

#include "umeshcore/Editor/EditorScene.h"
#include "umeshcore/Serialization/ProjectDocument.h"

#include <cmath>

#include "TestHarness.h"

using namespace umeshcore;

namespace {

// Through JSON text, so what is tested is what a file would carry.
ProjectDocument throughFile(const EditorScene& scene) {
    return projectDocumentFromJson(JsonValue::parse(toJson(projectDocumentFrom(scene, {})).dump()));
}

} // namespace

static void testEveryModelFieldSurvivesSaveAndOpen() {
    EditorScene source;
    const Uuid sprite = source.addImage(Uuid::generate(), "arm", Vec2(64, 32), Vec2(10, 20), std::nullopt);
    const Uuid bone = source.addBone(Vec2(0, 0), Vec2(80, 0));
    source.bindImage(sprite, bone);
    source.createSkin(std::string("red"), true);
    const Uuid event = source.createAnimationEvent(std::string("step"));
    source.currentFrame = 4;
    source.keyEvent(event, AnimationEventPayload{});
    source.setProjectFramesPerSecond(24.0, 0.0);
    source.playbackLoops = false;
    source.setPlaybackRange(2, 48);
    source.setAuthoredDrawOrder({sprite});
    source.ensureSceneCompositionExists();
    source.sceneViewCamera.distance = 777.0f;
    source.setCurrentFrame(12);

    EditorScene opened;
    applyProjectDocument(throughFile(source), opened);

    UM_CHECK(opened.images.size() == 1 && opened.images[0].id == sprite);
    UM_CHECK(opened.images[0].boneBinding.has_value() && opened.images[0].boneBinding->boneID == bone);
    UM_CHECK(opened.skeleton.bone(bone) != nullptr);
    UM_CHECK(opened.hierarchyItems.size() == source.hierarchyItems.size());
    UM_CHECK(opened.skins.size() == 1 && opened.activeSkinID == source.activeSkinID);
    UM_CHECK(opened.animationEvents.size() == 1 && opened.animationEvents[0].name == "step");
    UM_CHECK(opened.sceneAnimationClip.hasTrack(event, AnimationTrackProperty::Event));
    UM_CHECK(opened.projectFramesPerSecond == 24.0);
    UM_CHECK(!opened.playbackLoops);
    UM_CHECK(opened.playbackStartFrame == 2 && opened.playbackEndFrame == 48);
    UM_CHECK(opened.authoredDrawOrder == std::vector<Uuid>{sprite});
    UM_CHECK(opened.sceneCompositions == source.sceneCompositions);
    UM_CHECK(opened.selectedSceneCompositionID == source.selectedSceneCompositionID);
    UM_CHECK(opened.sceneViewCamera.distance == 777.0f);
    UM_CHECK(opened.currentFrame == 12);
}

// SWIFT BUG, FIXED: `SceneManager` outlives every project and
// `restoreProject` never cleared its undo manager, so Undo after Open put
// the previous project's sprites back.
static void testOpeningAProjectStartsAFreshHistory() {
    EditorScene other;
    const Uuid theirs = other.addImage(Uuid::generate(), "B", Vec2(8, 8), Vec2(0, 0), std::nullopt);
    const ProjectDocument b = throughFile(other);

    EditorScene scene;
    scene.addImage(Uuid::generate(), "A", Vec2(8, 8), Vec2(0, 0), std::nullopt);
    scene.pushUndoState();
    scene.renameHierarchyItem(scene.images[0].id, "A renamed");
    UM_CHECK(scene.undoRedo.canUndo());

    applyProjectDocument(b, scene);
    UM_CHECK(!scene.undoRedo.canUndo());
    scene.undo();
    UM_CHECK(scene.images.size() == 1 && scene.images[0].id == theirs);
}

// The file keeps what it says; opening drops what no longer resolves.
static void testOpeningDropsReferencesThatNoLongerResolve() {
    ProjectDocument doc;
    doc.activeSkinID = Uuid(7, 7);             // no such skin
    doc.selectedSceneCompositionID = Uuid(8, 8); // no such Scene
    doc.projectFramesPerSecond = 0.5;
    EditorScene::RestoredProject p = restoredProject(doc);
    UM_CHECK(!p.activeSkinID.has_value());
    UM_CHECK(!p.selectedSceneCompositionID.has_value());
    UM_CHECK(p.projectFramesPerSecond == 30.0); // below 1: "not set"

    doc.projectFramesPerSecond = 500.0;
    UM_CHECK(restoredProject(doc).projectFramesPerSecond == 240.0);
    doc.projectFramesPerSecond = std::nan("");
    UM_CHECK(restoredProject(doc).projectFramesPerSecond == 30.0);
    doc.projectFramesPerSecond = std::nullopt;
    UM_CHECK(restoredProject(doc).projectFramesPerSecond == 30.0);
}

// Nothing that pointed into the old project survives the open: the bone
// selection in ALL three fields, the Scene selection, the clipboard.
static void testNothingPointsIntoTheOldProject() {
    EditorScene scene;
    const Uuid a = scene.addBone(Vec2(0, 0), Vec2(40, 0));
    const Uuid b = scene.addBone(Vec2(40, 0), Vec2(80, 0), a);
    scene.setBoneSelection({a, b}, std::nullopt, false);
    scene.ensureSceneCompositionExists();
    scene.selectSceneLight(scene.addSceneLight(SceneLightKind::kPoint, scene.sceneCompositions[0].id));
    scene.copiedKeyframes.push_back(CopiedKeyframePayload{a, AnimationTrackProperty::Rotate});

    applyProjectDocument(ProjectDocument{}, scene);
    UM_CHECK(!scene.selectedBoneID.has_value());
    UM_CHECK(scene.selectedBoneIDs.empty() && scene.boneSelectionOrder.empty());
    UM_CHECK(scene.sceneSelection.isEmpty());
    UM_CHECK(scene.copiedKeyframes.empty());
    UM_CHECK(scene.sceneCompositions.empty());
}

// A project that never used Scene mode writes none of its keys.
static void testAProjectWithoutScenesWritesNoSceneKeys() {
    EditorScene scene;
    scene.sceneViewCamera.distance = 42.0f; // moved, but there is no set
    const JsonValue j = toJson(projectDocumentFrom(scene, {}));
    UM_CHECK(j.find("sceneCompositions") == nullptr);
    UM_CHECK(j.find("sceneViewCamera") == nullptr);
}

UM_TEST_MAIN_BEGIN()
    testEveryModelFieldSurvivesSaveAndOpen();
    testOpeningAProjectStartsAFreshHistory();
    testOpeningDropsReferencesThatNoLongerResolve();
    testNothingPointsIntoTheOldProject();
    testAProjectWithoutScenesWritesNoSceneKeys();
UM_TEST_MAIN_END()
