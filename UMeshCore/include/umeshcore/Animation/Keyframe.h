#pragma once

// 1:1 port of `Data/Keyframe.swift` (minus UI-only display strings, see
// AnimationTrackProperty.h).

#include <cstdint>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "umeshcore/Animation/AnimationEvent.h"
#include "umeshcore/Animation/AnimationTrackProperty.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

enum class KeyframeInterpolation { Hold, Linear, Bezier };

// Stable ids for slot-owned tracks. A slot has a name, not an id, so the
// track's targetID is DERIVED from the name -- deterministically, so a
// saved project resolves its tracks on the next launch (across platforms:
// this must match the Swift implementation bit-for-bit, since a project
// saved by one and opened by the other must resolve to the same track).
namespace SlotAnimationTarget {

inline Uuid id(const std::string& name) {
    // FNV-1a over the UTF-8 bytes of the name, widened to sixteen bytes via
    // a second (SplitMix64-style) round. Constants and structure copied
    // verbatim from Data/Keyframe.swift -- do not "clean up" the magic
    // numbers, they are the format.
    std::uint64_t hash = 0xcbf29ce484222325ULL;
    for (unsigned char byte : name) {
        hash ^= static_cast<std::uint64_t>(byte);
        hash *= 0x100000001b3ULL;
    }
    std::uint64_t second = 0x9e3779b97f4a7c15ULL ^ hash;
    second *= 0xff51afd7ed558ccdULL;
    second ^= second >> 33;
    // Swift builds the UUID's 16 bytes as hash's 8 bytes (big-endian)
    // followed by second's 8 bytes (big-endian), i.e. exactly {hi: hash,
    // lo: second} under this Uuid type's byte convention.
    return Uuid(hash, second);
}

} // namespace SlotAnimationTarget

// Fixed UUIDs for scene-wide tracks not owned by any bone/sprite/constraint.
// Stable across launches (and, critically, across the Swift and C++
// implementations) so saved projects keep resolving. Literal values copied
// character-for-character from Data/Keyframe.swift:87-89.
namespace SceneAnimationTarget {

inline Uuid drawOrder() { return Uuid(0x5D8A0C614E2F4B7AULL, 0x9C3D0F1E2A3B4C5DULL); }
inline Uuid camera() { return Uuid(0x1C4E9B277A634F0DULL, 0x8E512B6D9A0F3C84ULL); }

} // namespace SceneAnimationTarget

// KeyframeValue: a tagged union matching Swift's `enum KeyframeValue` with
// associated values. Wrapper structs (rather than a bare
// std::variant<Vec2,...>) exist because several cases share a payload type
// (translate/scale/shear/vector2 are all Vec2) and must stay distinguishable
// by case identity, exactly like the Swift enum cases do.
struct TranslateValue { Vec2 value; bool operator==(const TranslateValue&) const = default; };
struct RotateValue { float value; bool operator==(const RotateValue&) const = default; };
struct ScaleValue { Vec2 value; bool operator==(const ScaleValue&) const = default; };
struct ShearValue { Vec2 value; bool operator==(const ShearValue&) const = default; };
struct MeshDeformValue {
    std::vector<Vec2> value;
    bool operator==(const MeshDeformValue&) const = default;
};
struct ScalarValue { float value; bool operator==(const ScalarValue&) const = default; };
struct FlagValue { bool value; bool operator==(const FlagValue&) const = default; };
struct Vector2Value { Vec2 value; bool operator==(const Vector2Value&) const = default; };
struct DrawOrderValue {
    std::vector<Uuid> value;
    bool operator==(const DrawOrderValue&) const = default;
};
struct EventValue {
    AnimationEventPayload value;
    bool operator==(const EventValue&) const = default;
};
// nil empties the slot deliberately (different from "no key at all", which
// leaves the skin's choice standing).
struct AttachmentValue {
    std::optional<Uuid> value;
    bool operator==(const AttachmentValue&) const = default;
};

using KeyframeValue = std::variant<
    TranslateValue, RotateValue, ScaleValue, ShearValue, MeshDeformValue, ScalarValue, FlagValue,
    Vector2Value, DrawOrderValue, EventValue, AttachmentValue>;

inline TrackValueKind kind(const KeyframeValue& v) {
    struct Visitor {
        TrackValueKind operator()(const TranslateValue&) const { return TrackValueKind::Vector2; }
        TrackValueKind operator()(const RotateValue&) const { return TrackValueKind::Scalar; }
        TrackValueKind operator()(const ScaleValue&) const { return TrackValueKind::Vector2; }
        TrackValueKind operator()(const ShearValue&) const { return TrackValueKind::Vector2; }
        TrackValueKind operator()(const MeshDeformValue&) const { return TrackValueKind::Deform; }
        TrackValueKind operator()(const ScalarValue&) const { return TrackValueKind::Scalar; }
        TrackValueKind operator()(const FlagValue&) const { return TrackValueKind::Flag; }
        TrackValueKind operator()(const Vector2Value&) const { return TrackValueKind::Vector2; }
        TrackValueKind operator()(const DrawOrderValue&) const { return TrackValueKind::DrawOrder; }
        TrackValueKind operator()(const EventValue&) const { return TrackValueKind::Event; }
        TrackValueKind operator()(const AttachmentValue&) const { return TrackValueKind::Attachment; }
    };
    return std::visit(Visitor{}, v);
}

// simd2Value: translate/scale/shear/vector2 -> the Vec2; everything else nullopt.
inline std::optional<Vec2> simd2Value(const KeyframeValue& v) {
    if (auto* p = std::get_if<TranslateValue>(&v)) return p->value;
    if (auto* p = std::get_if<ScaleValue>(&v)) return p->value;
    if (auto* p = std::get_if<ShearValue>(&v)) return p->value;
    if (auto* p = std::get_if<Vector2Value>(&v)) return p->value;
    return std::nullopt;
}

// floatValue: rotate/scalar -> the float; everything else nullopt.
inline std::optional<float> floatValue(const KeyframeValue& v) {
    if (auto* p = std::get_if<RotateValue>(&v)) return p->value;
    if (auto* p = std::get_if<ScalarValue>(&v)) return p->value;
    return std::nullopt;
}

inline std::optional<bool> boolValue(const KeyframeValue& v) {
    if (auto* p = std::get_if<FlagValue>(&v)) return p->value;
    return std::nullopt;
}

inline const std::vector<Uuid>* drawOrderValue(const KeyframeValue& v) {
    if (auto* p = std::get_if<DrawOrderValue>(&v)) return &p->value;
    return nullptr;
}

inline const std::vector<Vec2>* meshDeformValue(const KeyframeValue& v) {
    if (auto* p = std::get_if<MeshDeformValue>(&v)) return &p->value;
    return nullptr;
}

inline const AnimationEventPayload* eventPayload(const KeyframeValue& v) {
    if (auto* p = std::get_if<EventValue>(&v)) return &p->value;
    return nullptr;
}

struct Keyframe {
    Uuid id = Uuid::generate();
    int frame = 0;
    KeyframeValue value;
    KeyframeInterpolation interpolation = KeyframeInterpolation::Linear;
    std::optional<Vec2> inTangent;
    std::optional<Vec2> outTangent;
    std::optional<Vec2> secondaryInTangent;
    std::optional<Vec2> secondaryOutTangent;

    Keyframe() : value(ScalarValue{0.0f}) {}

    Keyframe(
        int frame_, KeyframeValue value_,
        KeyframeInterpolation interpolation_ = KeyframeInterpolation::Linear,
        std::optional<Vec2> inTangent_ = std::nullopt,
        std::optional<Vec2> outTangent_ = std::nullopt,
        std::optional<Vec2> secondaryInTangent_ = std::nullopt,
        std::optional<Vec2> secondaryOutTangent_ = std::nullopt)
        : frame(frame_),
          value(std::move(value_)),
          inTangent(inTangent_),
          outTangent(outTangent_),
          secondaryInTangent(secondaryInTangent_),
          secondaryOutTangent(secondaryOutTangent_) {
        // Boolean/drawOrder/event/attachment payloads have no in-between
        // state.
        const TrackValueKind k = kind(value);
        if (k == TrackValueKind::Flag || k == TrackValueKind::DrawOrder ||
            k == TrackValueKind::Event || k == TrackValueKind::Attachment) {
            interpolation = KeyframeInterpolation::Hold;
        } else {
            interpolation = interpolation_;
        }
    }

    bool operator==(const Keyframe&) const = default;
};

struct SelectedKeyframe {
    Uuid imageID;
    AnimationTrackProperty property;
    Uuid keyframeID;

    bool operator==(const SelectedKeyframe&) const = default;
};

struct CopiedKeyframePayload {
    Uuid imageID;
    AnimationTrackProperty property;
    int relativeFrame = 0;
    KeyframeValue value{ScalarValue{0.0f}};
    KeyframeInterpolation interpolation = KeyframeInterpolation::Linear;
    std::optional<Vec2> inTangent;
    std::optional<Vec2> outTangent;
    std::optional<Vec2> secondaryInTangent;
    std::optional<Vec2> secondaryOutTangent;
};

} // namespace umeshcore
