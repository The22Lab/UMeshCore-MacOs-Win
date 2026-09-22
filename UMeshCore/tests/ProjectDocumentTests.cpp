// Tests for Serialization/ProjectDocument.h -- the `.umesh` project
// manifest (`SavedProjectDocument`). Field shapes and defaults are
// hand-derived from `Data/ProjectPersistence.swift` (including
// `SavedProjectDocument.empty`'s "new project" values), which was read
// directly -- not from this port's own output.

#include "umeshcore/Serialization/ProjectDocument.h"

#include "umeshcore/Serialization/SavedGeometry.h"
#include "TestHarness.h"

using namespace umeshcore;

static EditorScene makeScene() {
    EditorScene scene;

    Bone root;
    root.id = Uuid::generate();
    root.name = "root";
    scene.skeleton.setBone(root);
    scene.skeleton.rootIDs.push_back(root.id);

    SceneImage image;
    image.name = "body";
    image.assetID = Uuid::generate();
    image.animationClip = AnimationClip("body");
    scene.images.push_back(image);

    Skin skin("Armor");
    skin.attachments["torso"] = image.id;
    scene.skins.push_back(skin);
    scene.activeSkinID = skin.id;

    AnimationEvent event;
    event.name = "footstep";
    scene.animationEvents.push_back(event);

    ConstraintSetupValues values;
    values.set(AnimationTrackProperty::ConstraintMix, 0.5f);
    scene.constraintSetupValues[Uuid::generate()] = values;

    scene.sceneAnimationClip = AnimationClip("Scene", 60);
    scene.currentFrame = 7;
    scene.playbackStartFrame = 2;
    scene.playbackEndFrame = 48;
    return scene;
}

static void testDefaultsMatchSwiftEmptyDocument() {
    const ProjectDocument document;
    UM_CHECK(document.version == 1);
    UM_CHECK(document.currentFrame == 0);
    UM_CHECK(document.playbackLoops == true);
    UM_CHECK(document.playbackStartFrame == 0);
    UM_CHECK(document.playbackEndFrame == 90);
    UM_CHECK(document.images.empty());
    UM_CHECK(!document.activeSkinID.has_value());
}

static void testDocumentRoundTripsThroughJson() {
    const EditorScene scene = makeScene();

    AssetRecord albedo;
    albedo.id = scene.images[0].assetID;
    albedo.name = "body";
    albedo.filePath = "Assets/1-body.png";
    AssetRecord normal;
    normal.id = Uuid::generate();
    normal.name = "body_n";
    normal.filePath = "Assets/2-body_n.png";
    normal.role = AssetRole::Normal;

    const ProjectDocument document = projectDocumentFrom(scene, {albedo, normal});
    const ProjectDocument back = projectDocumentFromJson(JsonValue::parse(toJson(document).dump()));

    UM_CHECK(back.version == 1);
    UM_CHECK(back.currentFrame == 7);
    UM_CHECK(back.playbackStartFrame == 2);
    UM_CHECK(back.playbackEndFrame == 48);

    UM_CHECK(back.assets.size() == 2);
    UM_CHECK(back.assets[0].id == albedo.id);
    UM_CHECK(back.assets[0].filePath == "Assets/1-body.png");
    UM_CHECK(back.assets[0].role == AssetRole::Albedo);
    UM_CHECK(back.assets[1].role == AssetRole::Normal);

    UM_CHECK(back.images.size() == 1);
    UM_CHECK(back.images[0].name == "body");
    UM_CHECK(back.skeleton.bones().size() == 1);
    UM_CHECK(back.skeleton.rootIDs.size() == 1);
    UM_CHECK(back.skins.size() == 1 && back.skins[0].name == "Armor");
    UM_CHECK(back.activeSkinID.has_value() && *back.activeSkinID == *scene.activeSkinID);
    UM_CHECK(back.animationEvents.size() == 1 && back.animationEvents[0].name == "footstep");
    UM_CHECK(back.constraintSetupValues.size() == 1);
    UM_CHECK(back.sceneAnimationClip.has_value() && back.sceneAnimationClip->durationInFrames == 60);
}

static void testAlbedoRoleIsOmittedFromTheFile() {
    // Swift stores `role: String?` where nil means albedo, so ordinary
    // artwork writes no role at all.
    ProjectDocument document;
    AssetRecord asset;
    asset.id = Uuid::generate();
    asset.name = "plain";
    asset.filePath = "Assets/plain.png";
    document.assets.push_back(asset);

    const JsonValue j = toJson(document);
    UM_CHECK(j.find("assets")->asArray()[0].find("role") == nullptr);
    UM_CHECK(projectDocumentFromJson(j).assets[0].role == AssetRole::Albedo);
}

static void testUnmodelledKeysSurviveTheRoundTrip() {
    // A real project file carries sections this port does not model yet.
    // They must come back out byte-for-byte, not be dropped.
    ProjectDocument seed;
    JsonValue j = toJson(seed);
    j.set("hierarchyItems", JsonValue::parse("[{\"name\":\"Root\",\"order\":3}]"));
    j.set("editorState", JsonValue::parse("{\"timelineZoomScale\":1.75}"));
    j.set("sceneCompositions", JsonValue::parse("[{\"name\":\"Shot 1\",\"fps\":24}]"));
    j.set("camera", JsonValue::parse("{\"zoom\":2.5,\"rotation\":0.25}"));
    j.set("animations", JsonValue::parse("[{\"name\":\"Walk\"}]"));

    const ProjectDocument document = projectDocumentFromJson(j);
    UM_CHECK(document.unrecognized.size() == 5);

    const JsonValue written = toJson(document);
    UM_CHECK(written.find("hierarchyItems") != nullptr);
    UM_CHECK(written.find("hierarchyItems")->asArray()[0].find("order")->asInt() == 3);
    UM_CHECK_NEAR(written.find("editorState")->find("timelineZoomScale")->asDouble(), 1.75, 1e-9);
    UM_CHECK(written.find("sceneCompositions")->asArray()[0].find("name")->asString() == "Shot 1");
    UM_CHECK_NEAR(written.find("camera")->find("zoom")->asDouble(), 2.5, 1e-9);
    UM_CHECK(written.find("animations")->asArray()[0].find("name")->asString() == "Walk");
}

static void testModelledKeysAreNotTreatedAsUnrecognized() {
    const ProjectDocument document = projectDocumentFromJson(toJson(projectDocumentFrom(makeScene(), {})));
    UM_CHECK(document.unrecognized.empty());
}

static void testApplyRestoresSceneAndClearsTransientState() {
    const EditorScene source = makeScene();
    const ProjectDocument document = projectDocumentFrom(source, {});

    // A scene with stale selection/preview/undo state, as if a project
    // were open and being replaced by another.
    EditorScene target;
    const Uuid staleID = Uuid::generate();
    target.setSelection({staleID}, staleID, false);
    target.setPreviewPosition(staleID, Vec2(5, 5));
    target.pushUndoState();

    applyProjectDocument(document, target);

    UM_CHECK(target.images.size() == 1 && target.images[0].name == "body");
    UM_CHECK(target.skeleton.bones().size() == 1);
    UM_CHECK(target.skins.size() == 1);
    UM_CHECK(target.animationEvents.size() == 1);
    UM_CHECK(target.constraintSetupValues.size() == 1);
    UM_CHECK(target.currentFrame == 7);
    UM_CHECK(target.playbackEndFrame == 48);
    UM_CHECK(target.sceneAnimationClip.durationInFrames == 60);

    // Nothing from the previous scene survives a load.
    UM_CHECK(!target.selectedImageID.has_value());
    UM_CHECK(target.previewPositions.empty());
    UM_CHECK(!target.undoRedo.canUndo());
}

static void testApplyWithoutSceneClipFallsBackToAnEmptyOne() {
    ProjectDocument document;
    UM_CHECK(!document.sceneAnimationClip.has_value());

    EditorScene scene;
    applyProjectDocument(document, scene);
    UM_CHECK(scene.sceneAnimationClip.name == "Scene");
    UM_CHECK(scene.sceneAnimationClip.tracks().empty());
}

static void testMissingOptionalSectionsDecodeAsEmpty() {
    // A minimal file: only the fields a very old project would carry.
    const JsonValue j = JsonValue::parse(
        "{\"version\":1,\"currentFrame\":0,\"playbackLoops\":true,\"playbackStartFrame\":0,"
        "\"playbackEndFrame\":90,\"assets\":[],\"images\":[],"
        "\"skeleton\":{\"bones\":[],\"rootIDs\":[]}}");
    const ProjectDocument document = projectDocumentFromJson(j);

    UM_CHECK(document.skins.empty());
    UM_CHECK(document.animationEvents.empty());
    UM_CHECK(document.constraintSetupValues.empty());
    UM_CHECK(document.authoredDrawOrder.empty());
    UM_CHECK(!document.sceneAnimationClip.has_value());
    UM_CHECK(!document.projectFramesPerSecond.has_value());
    UM_CHECK(!document.activeSkinID.has_value());
}

UM_TEST_MAIN_BEGIN()
    testDefaultsMatchSwiftEmptyDocument();
    testDocumentRoundTripsThroughJson();
    testAlbedoRoleIsOmittedFromTheFile();
    testUnmodelledKeysSurviveTheRoundTrip();
    testModelledKeysAreNotTreatedAsUnrecognized();
    testApplyRestoresSceneAndClearsTransientState();
    testApplyWithoutSceneClipFallsBackToAnEmptyOne();
    testMissingOptionalSectionsDecodeAsEmpty();
UM_TEST_MAIN_END()
