#pragma once

// 1:1 port of the non-UI portions of `Data/Keyframe.swift`'s
// `AnimationTrackProperty` (+ `TrackValueKind` / `AnimationTrackDomain`).
//
// `title` / `systemImage` (inspector display strings and SF Symbol names)
// are deliberately NOT ported here -- they carry no behavior, only affect
// Mac/Windows-native UI chrome, and belong with Phase 6's platform-side
// panel wiring, not the portable core.

#include <array>
#include <optional>

namespace umeshcore {

enum class TrackValueKind {
    Vector2,   // Two independent float channels (x/y).
    Scalar,    // A single float channel.
    Flag,      // A boolean. Always evaluated as stepped.
    Deform,    // Per-vertex mesh offsets (FFD).
    DrawOrder, // A full permutation of sprite IDs.
    Event,     // A discrete event firing with its payload.
    Attachment // Which attachment a slot shows. Always stepped.
};

enum class AnimationTrackDomain {
    Node,       // targetID is a bone ID or a sprite ID.
    Constraint, // targetID is a constraint ID (IK, transform, path, physics).
    Scene,      // targetID is one of SceneAnimationTarget's fixed IDs.
    Slot        // targetID is a slot, derived from its name by SlotAnimationTarget.
};

enum class AnimationTrackProperty {
    // Bone / sprite transform tracks
    Translate,
    Rotate,
    Scale,
    Shear,
    MeshDeform,

    // Constraint tracks - target is a constraint ID
    ConstraintMix, // Master blend, present on every constraint type.
    IkSoftness,
    IkBendPositive,
    IkStretch,
    IkCompress,
    TransformRotateMix,
    TransformTranslateMix,
    TransformScaleMix,
    TransformShearMix,
    PathPosition,
    PathSpacing,
    PathPositionMix,
    PathRotateMix,
    PhysicsMass,
    PhysicsDamping,
    PhysicsStiffness,
    PhysicsGravity,
    PhysicsDrag,
    PhysicsWind,

    // Scene tracks
    CameraTranslate,
    CameraTranslateZ,
    CameraRotate3D,
    CameraRoll,
    CameraFOV,
    LightTranslate,
    LightTranslateZ,
    LightIntensity,
    LightRadius,
    LightSoftness,
    LightDirection,
    LightAngles,
    LightColorR,
    LightColorG,
    LightColorB,
    DrawOrder,
    Attachment,
    Event,

    // Sentinel: not a real case, only used to size arrays / iterate allCases.
    Count
};

constexpr int kAnimationTrackPropertyCount = static_cast<int>(AnimationTrackProperty::Count);

// All 42 real cases, in declaration order (matches Swift's `allCases`,
// which is declaration order for a `CaseIterable` enum without explicit
// raw values affecting ordering).
constexpr std::array<AnimationTrackProperty, kAnimationTrackPropertyCount> allAnimationTrackProperties() {
    std::array<AnimationTrackProperty, kAnimationTrackPropertyCount> out{};
    for (int i = 0; i < kAnimationTrackPropertyCount; ++i) {
        out[static_cast<std::size_t>(i)] = static_cast<AnimationTrackProperty>(i);
    }
    return out;
}

inline AnimationTrackDomain domain(AnimationTrackProperty p) {
    using P = AnimationTrackProperty;
    switch (p) {
        case P::Translate:
        case P::Rotate:
        case P::Scale:
        case P::Shear:
        case P::MeshDeform:
            return AnimationTrackDomain::Node;
        case P::Attachment:
            return AnimationTrackDomain::Slot;
        case P::DrawOrder:
        case P::Event:
        case P::CameraTranslate:
        case P::CameraTranslateZ:
        case P::CameraRotate3D:
        case P::CameraRoll:
        case P::CameraFOV:
        case P::LightTranslate:
        case P::LightTranslateZ:
        case P::LightIntensity:
        case P::LightRadius:
        case P::LightSoftness:
        case P::LightDirection:
        case P::LightAngles:
        case P::LightColorR:
        case P::LightColorG:
        case P::LightColorB:
            return AnimationTrackDomain::Scene;
        default:
            return AnimationTrackDomain::Constraint;
    }
}

inline TrackValueKind valueKind(AnimationTrackProperty p) {
    using P = AnimationTrackProperty;
    switch (p) {
        case P::Translate:
        case P::Scale:
        case P::Shear:
        case P::PhysicsWind:
        case P::CameraTranslate:
        case P::CameraRotate3D:
        case P::LightTranslate:
        case P::LightDirection:
        case P::LightAngles:
            return TrackValueKind::Vector2;
        case P::Rotate:
        case P::CameraTranslateZ:
        case P::CameraRoll:
        case P::CameraFOV:
        case P::ConstraintMix:
        case P::IkSoftness:
        case P::TransformRotateMix:
        case P::TransformTranslateMix:
        case P::TransformScaleMix:
        case P::TransformShearMix:
        case P::PathPosition:
        case P::PathSpacing:
        case P::PathPositionMix:
        case P::PathRotateMix:
        case P::PhysicsMass:
        case P::PhysicsDamping:
        case P::PhysicsStiffness:
        case P::PhysicsGravity:
        case P::PhysicsDrag:
        case P::LightTranslateZ:
        case P::LightIntensity:
        case P::LightRadius:
        case P::LightSoftness:
        case P::LightColorR:
        case P::LightColorG:
        case P::LightColorB:
            return TrackValueKind::Scalar;
        case P::IkBendPositive:
        case P::IkStretch:
        case P::IkCompress:
            return TrackValueKind::Flag;
        case P::MeshDeform:
            return TrackValueKind::Deform;
        case P::DrawOrder:
            return TrackValueKind::DrawOrder;
        case P::Attachment:
            return TrackValueKind::Attachment;
        case P::Event:
            return TrackValueKind::Event;
        case P::Count:
            return TrackValueKind::Scalar; // unreachable
    }
    return TrackValueKind::Scalar; // unreachable
}

// Boolean and draw-order tracks have no meaningful in-between value, so the
// editor forces stepped interpolation on them.
inline bool forcesSteppedInterpolation(AnimationTrackProperty p) {
    switch (valueKind(p)) {
        case TrackValueKind::Flag:
        case TrackValueKind::DrawOrder:
        case TrackValueKind::Event:
        case TrackValueKind::Attachment:
            return true;
        case TrackValueKind::Vector2:
        case TrackValueKind::Scalar:
        case TrackValueKind::Deform:
            return false;
    }
    return false;
}

// Inclusive editing range for scalar constraint properties, used by the
// inspector sliders and to clamp animated results. nullopt means unbounded.
struct FloatRange {
    float low;
    float high;
};

inline std::optional<FloatRange> valueRange(AnimationTrackProperty p) {
    using P = AnimationTrackProperty;
    switch (p) {
        case P::ConstraintMix:
        case P::TransformRotateMix:
        case P::TransformTranslateMix:
        case P::TransformScaleMix:
        case P::TransformShearMix:
        case P::PathPositionMix:
        case P::PathRotateMix:
        case P::PathPosition:
        case P::PhysicsDamping:
            return FloatRange{0.0f, 1.0f};
        case P::IkSoftness:
        case P::PhysicsMass:
        case P::PhysicsStiffness:
        case P::PhysicsDrag:
            return FloatRange{0.0f, 10000.0f};
        case P::LightSoftness:
        case P::LightColorR:
        case P::LightColorG:
        case P::LightColorB:
            return FloatRange{0.0f, 1.0f};
        default:
            return std::nullopt;
    }
}

// Properties exposed by each constraint type, in inspector display order.
inline const std::array<AnimationTrackProperty, 5>& ikProperties() {
    static const std::array<AnimationTrackProperty, 5> v{
        AnimationTrackProperty::ConstraintMix, AnimationTrackProperty::IkSoftness,
        AnimationTrackProperty::IkBendPositive, AnimationTrackProperty::IkStretch,
        AnimationTrackProperty::IkCompress};
    return v;
}

inline const std::array<AnimationTrackProperty, 5>& transformProperties() {
    static const std::array<AnimationTrackProperty, 5> v{
        AnimationTrackProperty::ConstraintMix, AnimationTrackProperty::TransformTranslateMix,
        AnimationTrackProperty::TransformRotateMix, AnimationTrackProperty::TransformScaleMix,
        AnimationTrackProperty::TransformShearMix};
    return v;
}

inline const std::array<AnimationTrackProperty, 5>& pathProperties() {
    static const std::array<AnimationTrackProperty, 5> v{
        AnimationTrackProperty::ConstraintMix, AnimationTrackProperty::PathPosition,
        AnimationTrackProperty::PathSpacing, AnimationTrackProperty::PathPositionMix,
        AnimationTrackProperty::PathRotateMix};
    return v;
}

inline const std::array<AnimationTrackProperty, 7>& physicsProperties() {
    static const std::array<AnimationTrackProperty, 7> v{
        AnimationTrackProperty::ConstraintMix, AnimationTrackProperty::PhysicsMass,
        AnimationTrackProperty::PhysicsDamping, AnimationTrackProperty::PhysicsStiffness,
        AnimationTrackProperty::PhysicsGravity, AnimationTrackProperty::PhysicsDrag,
        AnimationTrackProperty::PhysicsWind};
    return v;
}

// Transform tracks in the order the timeline lists them for a node.
inline const std::array<AnimationTrackProperty, 5>& nodeProperties() {
    static const std::array<AnimationTrackProperty, 5> v{
        AnimationTrackProperty::Translate, AnimationTrackProperty::Rotate,
        AnimationTrackProperty::Scale, AnimationTrackProperty::Shear,
        AnimationTrackProperty::MeshDeform};
    return v;
}

inline const std::array<AnimationTrackProperty, 5>& cameraProperties() {
    static const std::array<AnimationTrackProperty, 5> v{
        AnimationTrackProperty::CameraTranslate, AnimationTrackProperty::CameraTranslateZ,
        AnimationTrackProperty::CameraRotate3D, AnimationTrackProperty::CameraRoll,
        AnimationTrackProperty::CameraFOV};
    return v;
}

// Walked in this exact, fixed order everywhere a light is keyed or cleared
// (see the Swift source's comment: iterating a Set here would delete keys
// in hash-seed order, a real observed bug).
inline const std::array<AnimationTrackProperty, 10>& lightProperties() {
    static const std::array<AnimationTrackProperty, 10> v{
        AnimationTrackProperty::LightTranslate, AnimationTrackProperty::LightTranslateZ,
        AnimationTrackProperty::LightIntensity, AnimationTrackProperty::LightRadius,
        AnimationTrackProperty::LightSoftness, AnimationTrackProperty::LightDirection,
        AnimationTrackProperty::LightAngles, AnimationTrackProperty::LightColorR,
        AnimationTrackProperty::LightColorG, AnimationTrackProperty::LightColorB};
    return v;
}

} // namespace umeshcore
