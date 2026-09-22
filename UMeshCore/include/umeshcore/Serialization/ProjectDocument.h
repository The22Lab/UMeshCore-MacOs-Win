#pragma once

// The `.umesh` project manifest -- a port of `SavedProjectDocument`, the
// root object written to `project.json` inside the project package
// (`Data/ProjectPersistence.swift`). This file covers the DOCUMENT; the
// package layout around it (the directory, the `Assets/` folder and its
// SHA-256 content deduplication) is a separate, still-unported layer.
//
// Shaped as the FILE's model, not as `EditorScene`'s: it carries fields
// this port's scene aggregate does not model (`playbackLoops`,
// `projectFramesPerSecond`, `authoredDrawOrder`) so that reading a file and
// writing it back does not silently drop them.
//
// The same reasoning, taken further, motivates `unrecognized`: any
// top-level key this port does not model yet -- today `editorState`, a bag
// of platform-shell UI scalars this port deliberately does not own (see
// `SavedEditorState.h`) -- is kept VERBATIM on read and written back out
// unchanged. The Scene-compositing sections
// (`sceneCompositions`/`selectedSceneCompositionID`/`sceneViewCamera`)
// used to ride there too; Phase 5 models them, so they have moved to real
// fields below. `unrecognized` keeps doing its job for what is still not
// modelled, and the end-to-end test that proves it still passes. Swift needs no such
// mechanism, because its `Codable` models every field; this port models a
// growing subset, and without this a load/save cycle through UMeshCore
// would destroy a real project's Scene mode and animation library. A
// deliberate addition, not a port of anything.
//
// `SavedProjectDocument.version` is written as 1 and is NOT branched on
// anywhere in the Swift source either (confirmed by grep -- it is a
// placeholder, not live migration logic). Every real backward-compatibility
// concession is per-field defaulting instead; see the `Saved*` headers.

#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "umeshcore/Animation/AnimationClip.h"
#include "umeshcore/Animation/AnimationEvent.h"
#include "umeshcore/Animation/AnimationLibrary.h"
#include "umeshcore/Constraints/ConstraintAnimation.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Editor/CameraState.h"
#include "umeshcore/Editor/EditorScene.h"
#include "umeshcore/Model/HierarchyItem.h"
#include "umeshcore/Model/SceneImage.h"
#include "umeshcore/Model/Skeleton.h"
#include "umeshcore/Model/Skin.h"
#include "umeshcore/Serialization/AssetRecord.h"
#include "umeshcore/Render/SceneViewCamera.h"
#include "umeshcore/Scene/SceneComposition.h"
#include "umeshcore/Serialization/Json.h"

namespace umeshcore {

struct ProjectDocument {
    // Matches `SavedProjectDocument.empty`'s defaults, the "new project"
    // state Swift starts from.
    int version = 1;
    int currentFrame = 0;
    bool playbackLoops = true;
    int playbackStartFrame = 0;
    int playbackEndFrame = 90;

    std::vector<AssetRecord> assets;
    std::vector<SceneImage> images;
    Skeleton skeleton;
    std::vector<HierarchyItem> hierarchyItems;
    CameraState camera;

    // Optional in the file (absent in projects saved before each landed).
    std::optional<AnimationClip> sceneAnimationClip;
    std::optional<double> projectFramesPerSecond;
    std::vector<Uuid> authoredDrawOrder;
    std::vector<Skin> skins;
    std::vector<AnimationEvent> animationEvents;
    std::optional<Uuid> activeSkinID;
    std::unordered_map<Uuid, ConstraintSetupValues, UuidHash> constraintSetupValues;
    std::vector<NamedAnimation> animations;
    std::optional<Uuid> activeAnimationID;

    // Scene mode. Written only once the mode has been USED: an empty
    // `sceneCompositions` omits the key entirely, and `sceneViewCamera`
    // is tied to the compositions rather than to its own emptiness --
    // that is what keeps files byte-stable for projects that never touch
    // Scene, and there is nowhere to stand in a project with no set.
    std::vector<SceneComposition> sceneCompositions;
    std::optional<Uuid> selectedSceneCompositionID;
    std::optional<SceneViewCamera> sceneViewCamera;

    // Top-level keys this port does not model yet, kept verbatim so a
    // round trip does not destroy them. See this file's header.
    JsonValue::Object unrecognized;
};

JsonValue toJson(const ProjectDocument& document);
ProjectDocument projectDocumentFromJson(const JsonValue& j);

// Builds a manifest from live editor state. `assets` is passed separately
// because it belongs to the asset registry, not the scene -- the same
// split Swift has between `SceneManager` and `AssetManager`, and the one
// `BinaryExporter` already uses.
ProjectDocument projectDocumentFrom(const EditorScene& scene, std::vector<AssetRecord> assets);

// Applies a manifest back onto a scene, MUTATING IT IN PLACE -- matching
// Swift, where loading calls `SceneManager.restoreProject(...)` on the
// existing instance rather than constructing a fresh one. Fields the
// document carries but `EditorScene` does not model (see the struct) are
// left on the document; they are not lost, just not represented in the
// live scene yet.
void applyProjectDocument(const ProjectDocument& document, EditorScene& scene);

} // namespace umeshcore
