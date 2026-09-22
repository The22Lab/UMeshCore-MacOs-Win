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
// Now also carries `applyBoneBindings`/`boundImagePose` (places a bound
// sprite on its bone: bone world matrix composed with the sprite's local
// affine, decomposed back into position/rotation/scale/skew) and
// `ensureImageAnimationSpaceConsistency`/`convertImageAnimationSpace`
// (keeps a sprite's animation tracks expressed in world space or in the
// space of whichever bone it's currently bound to, converting authored
// values and every translate/rotate keyframe when the binding changes so a
// bind/unbind never moves the sprite on screen).
//
// Still to port into this file, in the order `applyAnimations` calls them:
// `applyConstraintAnimations`, `applyDrawOrderAnimation`,
// `applyAttachmentAnimations`, `applySetupPose`, and the whole-scene
// `applyAnimations`/`solveRigPose` orchestrators themselves -- see
// ROADMAP.md's Phase 2 status. `ToolManager`'s bone/sprite mutators
// (`moveBoneRoot`, `setImagePosition`, ...) branch on whether animation
// editing is enabled and either write straight to the base pose or call
// `commitKeyframe` + re-run this pipeline, so they wait on the rest of this
// file, not just this first piece.
//
// Deliberate divergence from the Swift source: `applyBoneBindings` there
// reads bone world matrices from `SceneManager.frameWorldMatrices()`, a
// once-per-rendered-frame memoization cache keyed on a token, whose only
// purpose is to avoid re-solving the skeleton (and re-stepping physics)
// more than once per real frame -- a performance optimization, not a
// behavioral one. Here `applyBoneBindings` instead takes the world matrices
// as a parameter (a `WorldMatrices` the caller already solved), matching
// the "inject what's needed" pattern used throughout this port and the
// existing decision (see `Skeleton::worldMatrices()`'s own comment) that
// physics stepping is the caller's concern, not this library's. Behavior is
// unchanged; only where the once-per-frame memoization lives has moved.

#include <optional>
#include <unordered_map>
#include <vector>

#include "umeshcore/Animation/AnimationClip.h"
#include "umeshcore/Constraints/Constraint.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Model/Bone.h"
#include "umeshcore/Model/SceneImage.h"
#include "umeshcore/Model/Skeleton.h"

namespace umeshcore {

std::unordered_map<Uuid, Bone, UuidHash> clipSampledBones(
    const std::unordered_map<Uuid, Bone, UuidHash>& bones, float time);

// A world point/angle converted into (or out of) a bone's local space --
// shared by `convertImageAnimationSpace` and any future caller that needs
// the same "what does this look like from a different bone" math.
Vec2 convertPosition(
    const Skeleton& skeleton, Vec2 position, std::optional<Uuid> sourceBoneID,
    std::optional<Uuid> targetBoneID);
float convertRotation(
    const Skeleton& skeleton, float rotation, std::optional<Uuid> sourceBoneID,
    std::optional<Uuid> targetBoneID);

// Rewrites `image`'s base pose and every translate/rotate keyframe in its
// own clip from `sourceBoneID`'s space into `targetBoneID`'s space (world
// when a bone id is nullopt). A structural change, not a pose one: the
// sprite's on-screen position is unchanged, only which frame its authored
// values and keyframes are expressed in.
void convertImageAnimationSpace(
    const Skeleton& skeleton, SceneImage& image, std::optional<Uuid> sourceBoneID,
    std::optional<Uuid> targetBoneID);

// Converts `image` into whatever space its current `boneBinding` implies
// (bone-local when bound, world when not), if it isn't there already. Runs
// first in the pose pass because it can itself change structure.
void ensureImageAnimationSpaceConsistency(const Skeleton& skeleton, SceneImage& image);

// A bound sprite's world pose: the bone's world matrix applied to the
// sprite's local pose, decomposed back into the sprite transform
// convention. Extracted as its own function (mirroring the Swift source)
// so a point-sampling caller (a Scene-compositing instance, Phase 5) can
// share the exact math the live per-frame path uses.
SceneImageAnimationPose boundImagePose(
    const SceneImageAnimationPose& localPose, const Mat4& worldMatrix);

// Places every bound sprite in `bound` on its bone, using `worldMatrices`
// (solved once by the caller -- see the file header). `sampleClips`
// selects whether a bound sprite's own clip is sampled for its bone-local
// pose (true while animating) or the binding's stored local pose is used
// as-is (false in Setup mode, where that stored pose IS the answer).
//
// `lastBoundImageRotation` is continuity state: each bound sprite's world
// rotation is unwrapped toward the value this map held for it last call, so
// the visible angle never jumps by 2*pi while a bone sweeps across the
// +/-180 degree boundary. Owned by the caller (per live scene, not per
// call) and cleared automatically here once nothing is bound, matching the
// Swift source's `lastBoundImageRotation.removeAll()` guard. Omit this
// continuity behavior (pass a fresh empty map) for a one-shot point sample,
// which has no previous frame to unwrap toward.
void applyBoneBindings(
    std::vector<SceneImage>& bound, const WorldMatrices& worldMatrices, float time,
    bool sampleClips, std::unordered_map<Uuid, float, UuidHash>& lastBoundImageRotation);

} // namespace umeshcore
