#include "umeshcore/Serialization/ProjectDocument.h"

#include <algorithm>
#include <array>
#include <unordered_set>

#include "umeshcore/Serialization/SavedAnimation.h"
#include "umeshcore/Serialization/SavedEditorState.h"
#include "umeshcore/Serialization/SavedGeometry.h"
#include "umeshcore/Serialization/SavedScene.h"
#include "umeshcore/Serialization/SavedSceneImage.h"
#include "umeshcore/Serialization/SavedSkeleton.h"

namespace umeshcore {

namespace {

// Every top-level key this port models. Anything else a file carries is
// preserved verbatim in `ProjectDocument::unrecognized` -- see the header.
// Everything NOT listed here falls through to `unrecognized` and is
// written back untouched rather than dropped -- today that is just
// `editorState` (platform-shell UI scalars, see SavedEditorState.h). The
// Scene-compositing sections used to fall through here; Phase 5 models
// them, so they are listed below.
constexpr std::array<const char*, 21> kKnownKeys{
    "version",
    "currentFrame",
    "playbackLoops",
    "playbackStartFrame",
    "playbackEndFrame",
    "camera",
    "assets",
    "images",
    "skeleton",
    "hierarchyItems",
    "sceneAnimationClip",
    "projectFramesPerSecond",
    "authoredDrawOrder",
    "skins",
    "animationEvents",
    "activeSkinID",
    "animations",
    "activeAnimationID",
    "sceneCompositions",
    "selectedSceneCompositionID",
    "sceneViewCamera",
};

bool isKnownKey(const std::string& key) {
    for (const char* known : kKnownKeys) {
        if (key == known) return true;
    }
    // Handled like a known key: modelled, just not in the list above
    // because it needs its own paired read.
    return key == "constraintSetupValues";
}

const char* assetRoleName(AssetRole role) {
    switch (role) {
        case AssetRole::Albedo: return "albedo";
        case AssetRole::Normal: return "normal";
        case AssetRole::Height: return "height";
    }
    return "albedo";
}

AssetRole assetRoleFromName(const std::string& name) {
    if (name == "normal") return AssetRole::Normal;
    if (name == "height") return AssetRole::Height;
    return AssetRole::Albedo; // absent/unknown means ordinary artwork.
}

JsonValue toJson(const AssetRecord& asset) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(asset.id));
    j.set("name", JsonValue::makeString(asset.name));
    j.set("filePath", JsonValue::makeString(asset.filePath));
    // Written only when it carries information, matching Swift's
    // `role: String?` where nil means albedo.
    if (asset.role != AssetRole::Albedo) j.set("role", JsonValue::makeString(assetRoleName(asset.role)));
    return j;
}

AssetRecord assetRecordFromJson(const JsonValue& j) {
    AssetRecord asset;
    asset.id = uuidFromJson(*j.find("id"));
    asset.name = j.find("name")->asString();
    asset.filePath = j.find("filePath")->asString();
    const JsonValue* role = j.find("role");
    asset.role = role != nullptr && !role->isNull() ? assetRoleFromName(role->asString()) : AssetRole::Albedo;
    // `size` is not persisted here -- see AssetRecord.h.
    return asset;
}

} // namespace

JsonValue toJson(const ProjectDocument& document) {
    // Anything the file carried that this port does not model goes back
    // out first, so a modelled key always wins if the two ever collide.
    JsonValue j = JsonValue::makeObject(document.unrecognized);

    j.set("version", JsonValue::makeNumber(document.version));
    j.set("currentFrame", JsonValue::makeNumber(document.currentFrame));
    j.set("playbackLoops", JsonValue::makeBool(document.playbackLoops));
    j.set("playbackStartFrame", JsonValue::makeNumber(document.playbackStartFrame));
    j.set("playbackEndFrame", JsonValue::makeNumber(document.playbackEndFrame));

    JsonValue::Array assets;
    assets.reserve(document.assets.size());
    for (const AssetRecord& asset : document.assets) assets.push_back(toJson(asset));
    j.set("assets", JsonValue::makeArray(std::move(assets)));

    JsonValue::Array images;
    images.reserve(document.images.size());
    for (const SceneImage& image : document.images) images.push_back(toJson(image));
    j.set("images", JsonValue::makeArray(std::move(images)));

    j.set("skeleton", toJson(document.skeleton));
    j.set("camera", toJson(document.camera));

    JsonValue::Array hierarchy;
    hierarchy.reserve(document.hierarchyItems.size());
    for (const HierarchyItem& item : document.hierarchyItems) hierarchy.push_back(toJson(item));
    j.set("hierarchyItems", JsonValue::makeArray(std::move(hierarchy)));

    JsonValue::Array animations;
    animations.reserve(document.animations.size());
    for (const NamedAnimation& animation : document.animations) animations.push_back(toJson(animation));
    j.set("animations", JsonValue::makeArray(std::move(animations)));

    if (document.activeAnimationID.has_value()) {
        j.set("activeAnimationID", toJson(*document.activeAnimationID));
    }

    if (document.sceneAnimationClip.has_value()) {
        j.set("sceneAnimationClip", toJson(*document.sceneAnimationClip));
    }
    if (document.projectFramesPerSecond.has_value()) {
        j.set("projectFramesPerSecond", JsonValue::makeNumber(*document.projectFramesPerSecond));
    }

    JsonValue::Array drawOrder;
    drawOrder.reserve(document.authoredDrawOrder.size());
    for (const Uuid& id : document.authoredDrawOrder) drawOrder.push_back(toJson(id));
    j.set("authoredDrawOrder", JsonValue::makeArray(std::move(drawOrder)));

    JsonValue::Array skins;
    skins.reserve(document.skins.size());
    for (const Skin& skin : document.skins) skins.push_back(toJson(skin));
    j.set("skins", JsonValue::makeArray(std::move(skins)));

    JsonValue::Array events;
    events.reserve(document.animationEvents.size());
    for (const AnimationEvent& event : document.animationEvents) events.push_back(toJson(event));
    j.set("animationEvents", JsonValue::makeArray(std::move(events)));

    if (document.activeSkinID.has_value()) j.set("activeSkinID", toJson(*document.activeSkinID));

    // A UUID-keyed map becomes a sorted array of records, the Swift
    // source's own convention for every such map (JSON has no UUID key,
    // and a sorted array keeps the file diff-stable).
    std::vector<std::pair<Uuid, ConstraintSetupValues>> setupValues(
        document.constraintSetupValues.begin(), document.constraintSetupValues.end());
    std::sort(setupValues.begin(), setupValues.end(), [](const auto& a, const auto& b) {
        return a.first.toString() < b.first.toString();
    });
    JsonValue::Array setup;
    setup.reserve(setupValues.size());
    for (const auto& [constraintID, values] : setupValues) {
        setup.push_back(constraintSetupValuesToJson(constraintID, values));
    }
    j.set("constraintSetupValues", JsonValue::makeArray(std::move(setup)));

    // Scene mode, written only once it has been USED. An empty
    // `sceneCompositions` omits the key entirely rather than writing `[]`,
    // which is what keeps a file byte-stable for a project that never
    // touches Scene -- the same rule Swift applies to `skins`,
    // `animationEvents` and `animations`.
    if (!document.sceneCompositions.empty()) {
        JsonValue::Array compositions;
        compositions.reserve(document.sceneCompositions.size());
        for (const SceneComposition& composition : document.sceneCompositions) {
            compositions.push_back(toJson(composition));
        }
        j.set("sceneCompositions", JsonValue::makeArray(std::move(compositions)));
        // Tied to the COMPOSITIONS, not to its own emptiness: it records
        // where the artist was standing, and there is nowhere to stand in
        // a project with no set.
        if (document.sceneViewCamera.has_value()) {
            j.set("sceneViewCamera", toJson(*document.sceneViewCamera));
        }
    }
    if (document.selectedSceneCompositionID.has_value()) {
        j.set("selectedSceneCompositionID", toJson(*document.selectedSceneCompositionID));
    }

    return j;
}

ProjectDocument projectDocumentFromJson(const JsonValue& j) {
    ProjectDocument document;

    const JsonValue* version = j.find("version");
    if (version != nullptr) document.version = version->asInt();
    const JsonValue* currentFrame = j.find("currentFrame");
    if (currentFrame != nullptr) document.currentFrame = currentFrame->asInt();
    const JsonValue* playbackLoops = j.find("playbackLoops");
    if (playbackLoops != nullptr) document.playbackLoops = playbackLoops->asBool();
    const JsonValue* playbackStartFrame = j.find("playbackStartFrame");
    if (playbackStartFrame != nullptr) document.playbackStartFrame = playbackStartFrame->asInt();
    const JsonValue* playbackEndFrame = j.find("playbackEndFrame");
    if (playbackEndFrame != nullptr) document.playbackEndFrame = playbackEndFrame->asInt();

    const JsonValue* assets = j.find("assets");
    if (assets != nullptr) {
        for (const JsonValue& asset : assets->asArray()) document.assets.push_back(assetRecordFromJson(asset));
    }

    const JsonValue* images = j.find("images");
    if (images != nullptr) {
        for (const JsonValue& image : images->asArray()) document.images.push_back(sceneImageFromJson(image));
    }

    const JsonValue* skeleton = j.find("skeleton");
    if (skeleton != nullptr) document.skeleton = skeletonFromJson(*skeleton);

    const JsonValue* camera = j.find("camera");
    if (camera != nullptr && !camera->isNull()) document.camera = cameraStateFromJson(*camera);

    const JsonValue* hierarchy = j.find("hierarchyItems");
    if (hierarchy != nullptr && !hierarchy->isNull()) {
        for (const JsonValue& item : hierarchy->asArray()) {
            document.hierarchyItems.push_back(hierarchyItemFromJson(item));
        }
    }

    const JsonValue* animations = j.find("animations");
    if (animations != nullptr && !animations->isNull()) {
        for (const JsonValue& animation : animations->asArray()) {
            document.animations.push_back(namedAnimationFromJson(animation));
        }
    }

    const JsonValue* activeAnimationID = j.find("activeAnimationID");
    if (activeAnimationID != nullptr && !activeAnimationID->isNull()) {
        document.activeAnimationID = uuidFromJson(*activeAnimationID);
    }

    const JsonValue* sceneAnimationClip = j.find("sceneAnimationClip");
    if (sceneAnimationClip != nullptr && !sceneAnimationClip->isNull()) {
        document.sceneAnimationClip = animationClipFromJson(*sceneAnimationClip);
    }

    const JsonValue* fps = j.find("projectFramesPerSecond");
    if (fps != nullptr && !fps->isNull()) document.projectFramesPerSecond = fps->asDouble();

    const JsonValue* authoredDrawOrder = j.find("authoredDrawOrder");
    if (authoredDrawOrder != nullptr && !authoredDrawOrder->isNull()) {
        for (const JsonValue& id : authoredDrawOrder->asArray()) document.authoredDrawOrder.push_back(uuidFromJson(id));
    }

    const JsonValue* skins = j.find("skins");
    if (skins != nullptr && !skins->isNull()) {
        for (const JsonValue& skin : skins->asArray()) document.skins.push_back(skinFromJson(skin));
    }

    const JsonValue* events = j.find("animationEvents");
    if (events != nullptr && !events->isNull()) {
        for (const JsonValue& event : events->asArray()) {
            document.animationEvents.push_back(animationEventFromJson(event));
        }
    }

    const JsonValue* activeSkinID = j.find("activeSkinID");
    if (activeSkinID != nullptr && !activeSkinID->isNull()) document.activeSkinID = uuidFromJson(*activeSkinID);

    const JsonValue* setup = j.find("constraintSetupValues");
    if (setup != nullptr && !setup->isNull()) {
        for (const JsonValue& entry : setup->asArray()) {
            document.constraintSetupValues[constraintSetupValuesIDFromJson(entry)] =
                constraintSetupValuesFromJson(entry);
        }
    }

    const JsonValue* compositions = j.find("sceneCompositions");
    if (compositions != nullptr && compositions->isArray()) {
        for (const JsonValue& composition : compositions->asArray()) {
            document.sceneCompositions.push_back(sceneCompositionFromJson(composition));
        }
    }
    const JsonValue* selected = j.find("selectedSceneCompositionID");
    if (selected != nullptr && !selected->isNull()) {
        document.selectedSceneCompositionID = uuidFromJson(*selected);
    }
    const JsonValue* viewCamera = j.find("sceneViewCamera");
    if (viewCamera != nullptr && !viewCamera->isNull()) {
        document.sceneViewCamera = sceneViewCameraFromJson(*viewCamera);
    }

    // Keep everything this port does not model yet, verbatim.
    for (const auto& [key, value] : j.asObject()) {
        if (!isKnownKey(key)) document.unrecognized[key] = value;
    }

    return document;
}

ProjectDocument projectDocumentFrom(const EditorScene& scene, std::vector<AssetRecord> assets) {
    // `AppState.currentProjectDocument`, minus what is not the scene's: the
    // 2D camera and the animation library live on `AppState` in Swift and
    // are the caller's to fill, and `editorState` is shell state carried in
    // `unrecognized`.
    ProjectDocument document;
    document.currentFrame = scene.currentFrame;
    document.playbackLoops = scene.playbackLoops;
    // `SavedProjectDocument.init` clamps the range as it writes it.
    document.playbackStartFrame = std::max(scene.playbackStartFrame, 0);
    document.playbackEndFrame = std::max(scene.playbackEndFrame, document.playbackStartFrame);
    document.assets = std::move(assets);
    document.images = scene.images;
    document.skeleton = scene.skeleton;
    document.hierarchyItems = scene.hierarchyItems;
    document.sceneAnimationClip = scene.sceneAnimationClip;
    document.constraintSetupValues = scene.constraintSetupValues;
    document.projectFramesPerSecond = scene.projectFramesPerSecond;
    document.authoredDrawOrder = scene.authoredDrawOrder;
    document.skins = scene.skins;
    document.activeSkinID = scene.activeSkinID;
    document.animationEvents = scene.animationEvents;
    document.sceneCompositions = scene.sceneCompositions;
    document.selectedSceneCompositionID = scene.selectedSceneCompositionID;
    // Tied to the compositions: nowhere to stand in a project with no set,
    // and files stay byte-stable for projects that never touch Scene.
    if (!scene.sceneCompositions.empty()) document.sceneViewCamera = scene.sceneViewCamera;
    return document;
}

// `SavedProjectDocument`'s `restored*()` layer, then `restoreProject`. The
// reader keeps what the FILE says; this is where a reference that no longer
// resolves is dropped and an out-of-range rate falls back.
EditorScene::RestoredProject restoredProject(const ProjectDocument& document) {
    EditorScene::RestoredProject p;
    p.images = document.images;
    p.skeleton = document.skeleton;
    p.hierarchyItems = document.hierarchyItems;
    p.currentFrame = document.currentFrame;
    p.playbackLoops = document.playbackLoops;
    p.playbackStartFrame = document.playbackStartFrame;
    p.playbackEndFrame = document.playbackEndFrame;
    p.sceneAnimationClip =
        document.sceneAnimationClip.has_value() ? *document.sceneAnimationClip : AnimationClip("Scene");
    p.constraintSetupValues = document.constraintSetupValues;
    // Below 1 (or NaN, whose comparison is false) is "not set": the rate the
    // editor used before this was a document property.
    const double rate = document.projectFramesPerSecond.value_or(0.0);
    p.projectFramesPerSecond = rate >= 1.0 ? std::min(rate, 240.0) : 30.0;
    p.authoredDrawOrder = document.authoredDrawOrder;
    p.skins = document.skins;
    if (document.activeSkinID.has_value() &&
        std::any_of(document.skins.begin(), document.skins.end(),
                    [&](const Skin& s) { return s.id == *document.activeSkinID; })) {
        p.activeSkinID = document.activeSkinID;
    }
    p.animationEvents = document.animationEvents;
    p.sceneCompositions = document.sceneCompositions;
    if (document.selectedSceneCompositionID.has_value() &&
        std::any_of(document.sceneCompositions.begin(), document.sceneCompositions.end(),
                    [&](const SceneComposition& c) { return c.id == *document.selectedSceneCompositionID; })) {
        p.selectedSceneCompositionID = document.selectedSceneCompositionID;
    }
    p.sceneViewCamera = document.sceneViewCamera;
    return p;
}

void applyProjectDocument(const ProjectDocument& document, EditorScene& scene) {
    scene.restoreProject(restoredProject(document));
}

} // namespace umeshcore
