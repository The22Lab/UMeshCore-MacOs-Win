#pragma once

// JSON conversions for the animation slice of `Data/ProjectPersistence.swift`:
// `SavedAnimationClip`, `SavedAnimationTrack`, `SavedKeyframe`,
// `SavedKeyframeValue`, `SavedAnimationEvent`, and
// `SavedConstraintSetupValues`. Every field shape and every decode fallback
// below was read off the real Swift source (`restoredAnimationClip()`,
// `restoredAnimationTrack()`, `restoredKeyframe()`, `restoredValue()`),
// not inferred.
//
// `SavedKeyframeValue` is Swift's hand-rolled tagged union: one `kind`
// string plus a bag of mutually-exclusive optional payload fields. Three
// of its cases carry real, deliberate semantics this port reproduces
// exactly rather than "cleaning up":
//   - `.scale` decodes `vector2 ?? SIMD2(repeating: scalar ?? 1)` -- old
//     files wrote a uniform scale as a single `scalar`, and the neutral
//     value for a *missing* scale is 1, not 0.
//   - `.attachment` is stored as an id ARRAY of 0 or 1 elements, never an
//     optional single id: "slot deliberately empty" (empty array) and
//     "no attachment key at all" (absent field) are different statements,
//     and a JSON `null` cannot tell them apart. Swift's own comment says
//     as much.
//   - `.event`'s three payload fields each stay independently optional end
//     to end, because absent means "inherit the event definition's
//     default" and must NOT decode as 0/"".
// An unrecognized `kind` falls back to `.translate(zero)`, matching
// Swift's `default:` arm.
//
// `trackPropertyName`/`trackPropertyFromName` is the first place in this
// port to need Swift's `AnimationTrackProperty.rawValue` strings. That does
// not reopen the earlier decision (documented in
// `Constraints/ConstraintAnimation.h`) to key `ConstraintSetupValues` by
// the enum rather than by a rawValue string: this table lives at the
// serialization boundary, which is exactly where a wire spelling belongs,
// and the in-memory representation still never touches it. Note also that
// these strings are a SEPARATE vocabulary from
// `UMeshBinaryFormat::TrackPropertyCode`'s numeric codes -- two different
// formats, two different encodings of the same enum, neither derived from
// the other.

#include <string>

#include "umeshcore/Animation/AnimationClip.h"
#include "umeshcore/Animation/AnimationEvent.h"
#include "umeshcore/Animation/AnimationLibrary.h"
#include "umeshcore/Animation/AnimationTrackProperty.h"
#include "umeshcore/Animation/Keyframe.h"
#include "umeshcore/Constraints/ConstraintAnimation.h"
#include "umeshcore/Serialization/Json.h"

namespace umeshcore {

// Swift's `AnimationTrackProperty.rawValue` (its case name).
const char* trackPropertyName(AnimationTrackProperty property);
// Unknown/unrecognized falls back to Translate, matching Swift's
// `AnimationTrackProperty(rawValue:) ?? .translate`.
AnimationTrackProperty trackPropertyFromName(const std::string& name);

const char* interpolationName(KeyframeInterpolation interpolation);
// Unknown falls back to Linear, matching Swift's `?? .linear`.
KeyframeInterpolation interpolationFromName(const std::string& name);

JsonValue toJson(const KeyframeValue& value);
KeyframeValue keyframeValueFromJson(const JsonValue& j);

JsonValue toJson(const Keyframe& keyframe);
Keyframe keyframeFromJson(const JsonValue& j);

JsonValue toJson(const AnimationTrack& track);
AnimationTrack animationTrackFromJson(const JsonValue& j);

JsonValue toJson(const AnimationClip& clip);
AnimationClip animationClipFromJson(const JsonValue& j);

JsonValue toJson(const AnimationEvent& event);
AnimationEvent animationEventFromJson(const JsonValue& j);

// `SavedConstraintSetupValues` pairs the values with their constraint's id,
// since the live form is a `Uuid -> ConstraintSetupValues` map and JSON has
// no UUID-keyed object (the Swift source stores every such relationship as
// an array of records for exactly this reason).
JsonValue constraintSetupValuesToJson(const Uuid& constraintID, const ConstraintSetupValues& values);
Uuid constraintSetupValuesIDFromJson(const JsonValue& j);
ConstraintSetupValues constraintSetupValuesFromJson(const JsonValue& j);

// `SavedNamedAnimation` -- one entry of the animation library. Its two
// `Uuid -> AnimationClip` maps become arrays of `SavedNamedAnimationClip`
// records (`{targetID, clip}`), sorted on write, for the same JSON-has-no-
// UUID-key reason as above.
JsonValue toJson(const NamedAnimation& animation);
NamedAnimation namedAnimationFromJson(const JsonValue& j);

} // namespace umeshcore
