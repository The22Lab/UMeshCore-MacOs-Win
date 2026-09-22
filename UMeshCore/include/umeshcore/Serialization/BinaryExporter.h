#pragma once

// Port of `Export/BinaryExporter.swift`'s chunk-writing logic for the six
// chunk kinds this port can currently produce: META, ASSETS, SKELETON,
// IMAGES, MESHES, ANIMATIONS.
//
// NOT ported: `writeScenesChunk` (the SCENES chunk). It serializes
// `SceneManager.sceneCompositions` -- staged multi-layer compositions with
// their own camera/lights/background (`SceneComposition`/`SceneLayer`/
// `SceneCamera`/`SceneLight`/`SceneAmbient`/`SceneFill`, all in
// `Data/Scene/`) -- none of which are ported yet; ROADMAP.md already scopes
// Scene compositing to Phase 5. This is a safe, self-describing omission,
// not a silent gap: the Swift source itself only ever writes the SCENES
// chunk `if !scene.sceneCompositions.isEmpty` (a rig that never used Scene
// mode already produces a file identical to one from before that chunk
// existed), and `EditorScene` has no `sceneCompositions` field at all, so
// this port's equivalent condition is unconditionally false today. When
// Phase 5 lands `SceneComposition`, add `writeScenesChunk` the same way.
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

private:
    void writeMetaChunk(BinaryWriter& writer, const EditorScene& scene) const;
    void writeAssetsChunk(
        BinaryWriter& writer, const EditorScene& scene,
        const std::unordered_map<Uuid, AssetRecord, UuidHash>& assets) const;
    void writeSkeletonChunk(BinaryWriter& writer, const EditorScene& scene) const;
    void writeImagesChunk(BinaryWriter& writer, const EditorScene& scene) const;
    void writeMeshesChunk(BinaryWriter& writer, const EditorScene& scene) const;
    void writeAnimationsChunk(BinaryWriter& writer, const EditorScene& scene) const;
    void writeKeyframe(BinaryWriter& writer, const Keyframe& keyframe) const;
    void writeTransform(BinaryWriter& writer, const Transform3D2D& transform) const;

    BinaryExportOptions options_;
};

} // namespace umeshcore
