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
// Now also carries `constraintSampledSkeleton`/`applyConstraintAnimations`
// (samples `sceneAnimationClip`'s constraint-property tracks onto a
// skeleton copy while animating, or restores each animated property's
// authored value from `constraintSetupValues` in Setup mode, so the
// Setup/Animate toggle never permanently loses the authored value under an
// animated one), and `applyDrawOrderAnimation`/`applyAttachmentAnimations`/
// `slotNames` (the scene-wide, stepped-interpolation tracks: which draw
// order and which per-slot attachment are keyed at the playhead).
//
// Deliberate representation change for both: the Swift source writes its
// answer into a `SceneManager` field (`animatedDrawOrder`/
// `animatedAttachments`) and only when it differs from the previous value,
// an `@Published`-change-notification optimization. Here both are plain
// functions that return the answer directly -- change-detection, if a
// caller wants it, is the caller's to do on the returned value, matching
// this port's existing decision (see `Skeleton::worldMatrices()`'s comment)
// that platform/UI-notification concerns live above this library, not in
// it.
//
// `applySetupPose` is also here: restores every bone/sprite to its
// authored base pose (skipped for bones while `isPoseMode`, since there the
// artist is hand-posing `localTransform` directly and writing the base
// values over it every interaction would be the exact bug this function
// exists to prevent, just aimed at the wrong mode), then re-places bound
// sprites via `applyBoneBindings` with `sampleClips=false` -- a bound
// sprite's stored local pose IS the Setup-mode answer.
//
// Still to port into this file: the whole-scene `applyAnimations`/
// `solveRigPose` orchestrators themselves -- see ROADMAP.md's Phase 2
// status. `ToolManager`'s bone/sprite mutators (`moveBoneRoot`,
// `setImagePosition`, ...) branch on whether animation editing is enabled
// and either write straight to the base pose or call `commitKeyframe` +
// re-run this pipeline, so they wait on the rest of this file, not just
// this first piece.
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
#include <string>
#include <unordered_map>
#include <vector>

#include "umeshcore/Animation/AnimationClip.h"
#include "umeshcore/Constraints/Constraint.h"
#include "umeshcore/Constraints/ConstraintAnimation.h"
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

struct ConstraintSampleResult {
    Skeleton skeleton;
    // Whether any track actually wrote a value -- callers use this to avoid
    // replacing the skeleton (and whatever change-notification that would
    // trigger, on a platform layer above this one) when nothing changed.
    bool didChange = false;
};

// Constraint tracks sampled at `time`, onto a copy of `base`. Reads
// `sceneAnimationClip` and `constraintSetupValues`; mutates neither. Shared
// by the live per-frame path (`applyConstraintAnimations`, in Animate mode)
// and by a Scene-compositing instance's point sampling (Phase 5), so both
// sample constraints through the exact same code.
ConstraintSampleResult constraintSampledSkeleton(
    const Skeleton& base, const AnimationClip& sceneAnimationClip,
    const std::unordered_map<Uuid, ConstraintSetupValues, UuidHash>& constraintSetupValues, float time);

// Pushes the current frame's constraint values onto `skeleton` in place. In
// Animate mode (`isAnimationEditingEnabled`), delegates to
// `constraintSampledSkeleton` and replaces `skeleton` only if it produced a
// change. In Setup mode, restores each animated property's authored value
// from `constraintSetupValues` instead, so leaving Animate mode is
// non-destructive -- the same rule `applySetupPose` applies to bones and
// sprites, here for constraints.
void applyConstraintAnimations(
    Skeleton& skeleton, const AnimationClip& sceneAnimationClip,
    const std::unordered_map<Uuid, ConstraintSetupValues, UuidHash>& constraintSetupValues,
    bool isAnimationEditingEnabled, float time);

// The animated draw order at `time`, or nullopt when the draw order isn't
// animated (no track for `SceneAnimationTarget::drawOrder()`, or Setup
// mode) -- the caller substitutes the scene's authored/live order in that
// case. Stepped by definition: the order is whatever the most recent key
// at or before the playhead says.
std::optional<std::vector<Uuid>> applyDrawOrderAnimation(
    const AnimationClip& sceneAnimationClip, bool isAnimationEditingEnabled, float time);

// Every slot name across `images`, in first-appearance order -- a vector,
// not a set, since iterating a `std::unordered_set<std::string>` is not
// stable between runs and a slot's row in the timeline must not move on
// its own.
std::vector<std::string> slotNames(const std::vector<SceneImage>& images);

// Which attachment each keyed slot shows at `time`. A slot absent from the
// result has no attachment track at all (the caller falls back to its
// normal, non-animated attachment resolution for that slot); a slot
// present but mapped to `std::nullopt` means its track explicitly resolves
// to "show nothing" at this frame -- the same "key present vs. value
// optional" double-optional shape `Skin::SlotAttachments` already uses.
// Empty (Setup mode, or `isAnimationEditingEnabled` false) clears every
// slot's animated attachment, matching the Swift source's "no mode guard
// used to exist here" bugfix comment.
std::unordered_map<std::string, std::optional<Uuid>> applyAttachmentAnimations(
    const AnimationClip& sceneAnimationClip, const std::vector<SceneImage>& images,
    bool isAnimationEditingEnabled, float time);

// Restores every bone (unless `isPoseMode`) and every sprite to its
// authored base pose, then re-places bound sprites on their bones via
// `applyBoneBindings` (with `sampleClips=false` -- see this function's own
// doc comment). `worldMatrices`/`lastBoundImageRotation` are threaded
// straight through to that call; see `applyBoneBindings`'s doc comment for
// what each means.
void applySetupPose(
    Skeleton& skeleton, std::vector<SceneImage>& images, bool isPoseMode, float time,
    const WorldMatrices& worldMatrices, std::unordered_map<Uuid, float, UuidHash>& lastBoundImageRotation);

} // namespace umeshcore
