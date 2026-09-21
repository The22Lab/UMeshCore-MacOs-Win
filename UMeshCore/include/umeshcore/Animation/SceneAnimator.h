#pragma once

// Port of `Data/SceneManager.swift`'s per-frame animation evaluation
// pipeline (`applyAnimations` and its helpers) -- started here with
// `clipSampledBones`: every bone's local transform sampled from its own
// `AnimationClip` at a given time, matching
// `SceneManager.clipSampledBones(_:atTime:)` exactly, including the
// `cyclicRotation: true` this pass uses so a bone's rotation keyframes never
// take the "long way round" through the atan2 wraparound boundary (a bone's
// `localTransform.rotation.z` is always written by `atan2`, so a two-degree
// move across that boundary must not play as a 358-degree spin).
//
// Shared, in the Swift source, by the live per-frame path
// (`applyBoneAnimations`) and by `rigPose(atFrame:)`'s point sampling for
// Scene-compositing instances (Phase 5) -- both call this exact function so
// a Scene instance is posed through the same code the canvas uses.
//
// Still to port into this file, in the order `applyAnimations` calls them:
// `applyConstraintAnimations`, `applyDrawOrderAnimation`,
// `applyAttachmentAnimations`, `applyBoneBindings`,
// `ensureImageAnimationSpaceConsistency`, `applySetupPose`, and the
// whole-scene `applyAnimations`/`solveRigPose` orchestrators themselves --
// see ROADMAP.md's Phase 2 status. `ToolManager`'s bone/sprite mutators
// (`moveBoneRoot`, `setImagePosition`, ...) branch on whether animation
// editing is enabled and either write straight to the base pose or call
// `commitKeyframe` + re-run this pipeline, so they wait on the rest of this
// file, not just this first piece.

#include <unordered_map>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Model/Bone.h"

namespace umeshcore {

std::unordered_map<Uuid, Bone, UuidHash> clipSampledBones(
    const std::unordered_map<Uuid, Bone, UuidHash>& bones, float time);

} // namespace umeshcore
