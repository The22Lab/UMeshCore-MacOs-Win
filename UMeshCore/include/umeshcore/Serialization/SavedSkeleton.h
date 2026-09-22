#pragma once

// JSON conversions for the "rig" slice of `Data/ProjectPersistence.swift`:
// `SavedBone`, `SavedIKConstraint`, `SavedPathConstraint`,
// `SavedTransformConstraint`, `SavedPhysicsConstraint` (+ its nested
// `SavedPhysicsSettings`), and `SavedSkeleton` itself. Field shapes and
// fallback logic were confirmed field-by-field against the actual Swift
// source (not assumed) before writing this.
//
// A bone's `animationClip` (`SavedBone.animationClip: SavedAnimationClip?`)
// round-trips through `Serialization/SavedAnimation.h`, and is optional on
// the wire exactly as in Swift: a bone whose clip has no tracks writes no
// `animationClip` field at all, and a bone read without one gets a fresh
// `AnimationClip(name)` -- Swift's own fallback
// (`animationClip?.restoredAnimationClip() ?? AnimationClip(name: bone.name)`).
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

// Swift's `rawValue` spellings for the constraint enums. Shared rather
// than duplicated because UMJSON writes the same strings (its builder
// reads `spacingMode.rawValue` too) -- one vocabulary, two formats.
// `...FromName` falls back the way Swift's `?? .default` does.
const char* pathSpacingModeName(PathSpacingMode mode);
PathSpacingMode pathSpacingModeFromName(const std::string& name);
const char* pathRotateModeName(PathRotateMode mode);
PathRotateMode pathRotateModeFromName(const std::string& name);
const char* physicsTypeName(PhysicsType type);
PhysicsType physicsTypeFromName(const std::string& name);

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
