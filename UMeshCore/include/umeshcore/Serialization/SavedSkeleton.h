#pragma once

// JSON conversions for the "rig" slice of `Data/ProjectPersistence.swift`:
// `SavedBone`, `SavedIKConstraint`, `SavedPathConstraint`,
// `SavedTransformConstraint`, `SavedPhysicsConstraint` (+ its nested
// `SavedPhysicsSettings`), and `SavedSkeleton` itself. Field shapes and
// fallback logic were confirmed field-by-field against the actual Swift
// source (not assumed) before writing this.
//
// Deliberately deferred, documented rather than silently dropped: a bone's
// `animationClip` field (`SavedBone.animationClip: SavedAnimationClip?`) is
// NOT written or read here yet -- animation-clip JSON conversion is its own
// increment, not yet built. `boneFromJson` gives every restored bone a
// fresh empty `AnimationClip(name)`, which is exactly what Swift's own
// restore path already falls back to when this optional field is absent
// (`animationClip?.restoredAnimationClip() ?? AnimationClip(name: bone.name)`),
// so an animation-free round trip through this file alone is already
// correct; a project WITH keyed animation loses it until that follow-up
// lands, same "safe, documented, not a silent gap" posture as every other
// deferred piece in this port.
//
// `SavedSkeleton`'s four constraint arrays are optional in the Swift
// source purely for backward compatibility with pre-constraint save files
// (`?? []` on restore) -- this port's writer always emits them (possibly
// empty), and the reader treats an absent array the same as an empty one,
// via `JsonValue::valueOr`.

#include "umeshcore/Constraints/IKConstraint.h"
#include "umeshcore/Constraints/PathConstraint.h"
#include "umeshcore/Constraints/PhysicsConstraint.h"
#include "umeshcore/Constraints/TransformConstraint.h"
#include "umeshcore/Model/Bone.h"
#include "umeshcore/Model/Skeleton.h"
#include "umeshcore/Serialization/Json.h"

namespace umeshcore {

JsonValue toJson(const Bone& bone);
Bone boneFromJson(const JsonValue& j);

JsonValue toJson(const IKConstraint& c);
IKConstraint ikConstraintFromJson(const JsonValue& j);

JsonValue toJson(const PathConstraint& c);
PathConstraint pathConstraintFromJson(const JsonValue& j);

JsonValue toJson(const TransformConstraint& c);
TransformConstraint transformConstraintFromJson(const JsonValue& j);

JsonValue toJson(const PhysicsSettings& s);
PhysicsSettings physicsSettingsFromJson(const JsonValue& j);

JsonValue toJson(const PhysicsConstraint& c);
PhysicsConstraint physicsConstraintFromJson(const JsonValue& j);

JsonValue toJson(const Skeleton& skeleton);
Skeleton skeletonFromJson(const JsonValue& j);

} // namespace umeshcore
