#pragma once

// JSON conversions for the sprite/mesh/skin slice of
// `Data/ProjectPersistence.swift`: `SavedMesh` (+ `SavedMeshBindPose`,
// `SavedVertexBoneWeight`, `SavedBoneInverseBindMatrix`),
// `SavedSceneImage` (+ `SavedBoneImageBinding`,
// `SavedTransformAnimationSpace`), and `SavedSkin`. Field shapes and every
// decode fallback were read off the real Swift source
// (`restoredMesh()`/`restoredMeshRaw()`, `restoredSceneImage()`,
// `SavedSkin.restored()`), not inferred.
//
// Three behaviors worth calling out, all faithful to Swift:
//
//   - `meshFromJson` reproduces the LOAD-TIME REPAIR PASS, not just field
//     mapping: Swift runs `restoredMeshRaw().repairedIfInvalid().mesh`
//     where the raw build itself ends in `.sanitizedSkinningData()`. The
//     Swift comment explains why it exists -- a project written before the
//     mesh kernel existed can carry a triangle list covering only part of
//     its silhouette, that bad list was persisted, and reopening the file
//     brought the holes back. Both methods already exist on this port's
//     `Mesh`, so the same two-step runs here in the same order. A valid
//     mesh is never disturbed by either.
//
//   - `SavedSceneImage.animationTransformSpace` restores through a
//     three-tier fallback: the explicitly saved space, else inferred from
//     the sprite's bone binding (`.boneLocal(binding.boneID)`), else
//     `.world`. Older files had no explicit field and relied on the
//     binding alone.
//
//   - `SavedSkin.attachments` is an ARRAY of `{slot, imageID?}` records
//     sorted by slot, not a JSON object keyed by slot. Swift's reason is
//     the same double-optional problem this port's `SlotAttachments`
//     already documents: a dictionary whose value is itself optional
//     cannot round-trip through JSON, because "key present, value null"
//     (slot deliberately empty) and "key absent" (slot not described) both
//     decode as absent. The sorted array keeps both statements intact --
//     and this port sorts on write too, since the live map is unordered
//     and output should stay diff-stable.

#include "umeshcore/Mesh/Mesh.h"
#include "umeshcore/Model/SceneImage.h"
#include "umeshcore/Model/Skin.h"
#include "umeshcore/Serialization/Json.h"

namespace umeshcore {

JsonValue toJson(const MeshBindPose& pose);
MeshBindPose meshBindPoseFromJson(const JsonValue& j);

JsonValue toJson(const Mesh& mesh);
// Includes Swift's load-time sanitize + repair pass -- see the header.
Mesh meshFromJson(const JsonValue& j);

JsonValue toJson(const BoneImageBinding& binding);
BoneImageBinding boneImageBindingFromJson(const JsonValue& j);

const char* blendModeName(ImageBlendMode mode);
ImageBlendMode blendModeFromName(const std::string& name);

JsonValue toJson(const SceneImage& image);
SceneImage sceneImageFromJson(const JsonValue& j);

JsonValue toJson(const Skin& skin);
Skin skinFromJson(const JsonValue& j);

} // namespace umeshcore
