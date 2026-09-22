#pragma once

// Port of `Export/BinaryExporter.swift`'s chunk-writing logic for the six
// chunk kinds this port can currently produce: META, ASSETS, SKELETON,
// IMAGES, MESHES, ANIMATIONS.
//
// All seven chunks are written now. SCENES was deferred through Phase 3
// and 4 because it serializes `SceneComposition`/`SceneLayer`/
// `SceneCamera` (`Data/Scene/`), which Phase 5 landed; the compositions
// are passed to `exportScene` EXPLICITLY, the same "inject what's needed"
// split Swift has between `SceneManager` and `AssetManager` and the one
// `assets` already uses. The two-argument overload stays, and writes no
// SCENES chunk -- matching Swift, which only ever emits it
// `if !scene.sceneCompositions.isEmpty`, so a rig that never used Scene
// mode still produces a file identical to one from before the chunk
// existed.
//
// Two things about that chunk are worth knowing before reading it:
//
//   - Layers are written IN DRAW ORDER, back first, and the chunk carries
//     NO layer number. The array order is only a tie-break now, so writing
//     it raw would hand the runtime a stacking that is not the one the
//     editor draws; and what a player needs is the order, not the
//     arithmetic that produced it.
//   - The camera tracks are written once PER COMPOSITION, and every
//     composition gets the same ones, because they come from the project's
//     single `sceneAnimationClip`. That is Swift's behaviour and the
//     format's shape, so it is reproduced rather than "fixed" -- but it
//     does mean the format cannot express per-composition camera
//     animation today. Noted here because it looks like duplication and is
//     really a model limitation.
//
// Two documented, deliberate divergences from the Swift writer -- see
// `UMeshBinaryFormat.h`'s `ChunkVersion` comments for the full reasoning,
// summarized here:
//   - ASSETS (v2): an explicit `found` flag disambiguates a missing asset
//     from a found one in reference mode, where Swift's own byte layout is
//     ambiguous between them.
//   - ANIMATIONS (v2): a `.meshDeform` keyframe value is actually written
//     (Swift's writer emits zero bytes for it, a confirmed bug with no
//     real-world byte-parity to preserve since Swift has no reader for
//     this format at all).
//
// Takes a `const EditorScene&` plus an explicit asset lookup, mirroring
// Swift's own `export(scene: SceneManager, assets: AssetManager)` taking
// them as two separate parameters rather than one god object -- see
// `AssetRecord.h`'s file header for why the asset side is a small
// standalone map instead of a ported `AssetManager`.

#include <cstdint>
#include <unordered_map>
#include <vector>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Editor/EditorScene.h"
#include "umeshcore/Serialization/AssetRecord.h"
#include "umeshcore/Serialization/BinaryExportOptions.h"
#include "umeshcore/Scene/SceneComposition.h"
#include "umeshcore/Serialization/BinaryWriter.h"

namespace umeshcore {

class BinaryExporter {
public:
    explicit BinaryExporter(BinaryExportOptions options = {}) : options_(std::move(options)) {}

    // Serializes the scene's skeleton, images, meshes, assets and
    // animations. Synchronous and pure -- same contract as the Swift
    // source's `export(scene:assets:)`.
    std::vector<std::uint8_t> exportScene(
        const EditorScene& scene, const std::unordered_map<Uuid, AssetRecord, UuidHash>& assets) const;

    // With Scene mode. `compositions` is injected rather than read off
    // `EditorScene`, which stays the minimal editor aggregate -- see the
    // header. An empty vector produces byte-identical output to the
    // overload above.
    std::vector<std::uint8_t> exportScene(
        const EditorScene& scene, const std::unordered_map<Uuid, AssetRecord, UuidHash>& assets,
        const std::vector<SceneComposition>& compositions) const;

private:
    void writeMetaChunk(BinaryWriter& writer, const EditorScene& scene) const;
    void writeAssetsChunk(
        BinaryWriter& writer, const EditorScene& scene,
        const std::unordered_map<Uuid, AssetRecord, UuidHash>& assets) const;
    void writeSkeletonChunk(BinaryWriter& writer, const EditorScene& scene) const;
    void writeImagesChunk(BinaryWriter& writer, const EditorScene& scene) const;
    void writeMeshesChunk(BinaryWriter& writer, const EditorScene& scene) const;
    void writeAnimationsChunk(BinaryWriter& writer, const EditorScene& scene) const;
    void writeScenesChunk(
        BinaryWriter& writer, const EditorScene& scene,
        const std::vector<SceneComposition>& compositions) const;
    void writeSceneCameraTracks(BinaryWriter& writer, const EditorScene& scene) const;
    void writeKeyframe(BinaryWriter& writer, const Keyframe& keyframe) const;
    void writeTransform(BinaryWriter& writer, const Transform3D2D& transform) const;

    BinaryExportOptions options_;
};

} // namespace umeshcore
