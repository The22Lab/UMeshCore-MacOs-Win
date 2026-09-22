#pragma once

// 1:1 port of `Data/ConstraintAnimation.swift` -- generic (kind-agnostic)
// access to a constraint's animatable properties, and the "setup pose"
// bookkeeping animation needs: the live values on the constraint structs
// are what the solver reads, and animation overwrites them every frame, so
// without a separate record of the authored values, scrubbing away from a
// keyframe would leave the constraint stuck at whatever the last evaluated
// frame produced. Mirrors exactly how sprites keep `basePose` alongside
// their animated pose (see `SceneImage::basePose()`).
//
// Modeled as free functions taking `Skeleton&`/`const Skeleton&` rather
// than as `Skeleton` methods (the Swift source uses a `extension Skeleton`,
// effectively the same API surface) -- consistent with this port's existing
// pattern (see `Animation/SceneAnimator.h`) of keeping cross-subsystem
// orchestration out of the core data types themselves.
//
// `title`/`systemImage` on Swift's `ConstraintKind` (inspector display
// strings and SF Symbol names) are deliberately NOT ported, matching
// `AnimationTrackProperty`'s own title/systemImage omission -- UI chrome,
// not behavior.

#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "umeshcore/Animation/AnimationTrackProperty.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Model/Skeleton.h"

namespace umeshcore {

// Which concrete constraint store an ID lives in.
enum class ConstraintKind { Ik, Transform, Path, Physics };

// Animatable properties exposed by this constraint kind, in the order the
// inspector and the timeline list them.
const std::vector<AnimationTrackProperty>& animatableProperties(ConstraintKind kind);

// A constraint's authored ("setup pose") values for every animatable
// property. The Swift source keys its three dictionaries by
// `AnimationTrackProperty.rawValue` (the enum's String backing); this port
// keys directly by the enum instead -- `std::unordered_map` hashes a scoped
// enum out of the box, and going through a string would mean introducing
// and hand-maintaining a rawValue table that exists nowhere else in this
// port, purely to reproduce an implementation detail with no behavioral
// consequence (nothing here is serialized by this map's key spelling).
struct ConstraintSetupValues {
    std::unordered_map<AnimationTrackProperty, float> scalars;
    std::unordered_map<AnimationTrackProperty, bool> flags;
    std::unordered_map<AnimationTrackProperty, Vec2> vectors;

    std::optional<float> scalar(AnimationTrackProperty property) const;
    std::optional<bool> flag(AnimationTrackProperty property) const;
    std::optional<Vec2> vector(AnimationTrackProperty property) const;

    void set(AnimationTrackProperty property, float value);
    void set(AnimationTrackProperty property, bool value);
    void set(AnimationTrackProperty property, Vec2 value);

    bool operator==(const ConstraintSetupValues&) const = default;
};

// --- Identification --------------------------------------------------

// The store an ID belongs to, or nullopt if no constraint has that ID.
std::optional<ConstraintKind> constraintKind(const Skeleton& skeleton, Uuid id);
std::optional<std::string> constraintName(const Skeleton& skeleton, Uuid id);

inline std::vector<AnimationTrackProperty> animatableProperties(
    const Skeleton& skeleton, Uuid constraintID) {
    const auto kind = constraintKind(skeleton, constraintID);
    return kind.has_value() ? animatableProperties(*kind) : std::vector<AnimationTrackProperty>{};
}

// --- Scalar / flag / vector access ------------------------------------

std::optional<float> constraintScalar(
    const Skeleton& skeleton, Uuid id, AnimationTrackProperty property);
void setConstraintScalar(Skeleton& skeleton, Uuid id, AnimationTrackProperty property, float raw);

std::optional<bool> constraintFlag(const Skeleton& skeleton, Uuid id, AnimationTrackProperty property);
void setConstraintFlag(Skeleton& skeleton, Uuid id, AnimationTrackProperty property, bool value);

std::optional<Vec2> constraintVector(
    const Skeleton& skeleton, Uuid id, AnimationTrackProperty property);
void setConstraintVector(Skeleton& skeleton, Uuid id, AnimationTrackProperty property, Vec2 value);

// --- Setup snapshots ---------------------------------------------------

// Capture the current authored values of every animatable property of a
// constraint, so animation can restore them when a track is removed or the
// playhead sits outside the keyed range.
ConstraintSetupValues captureConstraintSetupValues(const Skeleton& skeleton, Uuid id);

// Write a whole setup snapshot back onto a constraint. Used when the
// playhead leaves an animated range and when undo restores a scene.
void applyConstraintSetupValues(Skeleton& skeleton, Uuid id, const ConstraintSetupValues& values);

} // namespace umeshcore
