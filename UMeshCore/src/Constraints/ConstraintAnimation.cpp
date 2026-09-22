#include "umeshcore/Constraints/ConstraintAnimation.h"

#include <algorithm>

namespace umeshcore {

const std::vector<AnimationTrackProperty>& animatableProperties(ConstraintKind kind) {
    using P = AnimationTrackProperty;
    static const std::vector<P> ik{P::ConstraintMix, P::IkSoftness, P::IkBendPositive, P::IkStretch, P::IkCompress};
    static const std::vector<P> transform{
        P::ConstraintMix, P::TransformTranslateMix, P::TransformRotateMix, P::TransformScaleMix,
        P::TransformShearMix};
    static const std::vector<P> path{
        P::ConstraintMix, P::PathPosition, P::PathSpacing, P::PathPositionMix, P::PathRotateMix};
    static const std::vector<P> physics{
        P::ConstraintMix, P::PhysicsMass, P::PhysicsDamping, P::PhysicsStiffness, P::PhysicsGravity,
        P::PhysicsDrag, P::PhysicsWind};
    switch (kind) {
        case ConstraintKind::Ik: return ik;
        case ConstraintKind::Transform: return transform;
        case ConstraintKind::Path: return path;
        case ConstraintKind::Physics: return physics;
    }
    return ik;
}

std::optional<float> ConstraintSetupValues::scalar(AnimationTrackProperty property) const {
    auto it = scalars.find(property);
    return it == scalars.end() ? std::nullopt : std::optional<float>(it->second);
}
std::optional<bool> ConstraintSetupValues::flag(AnimationTrackProperty property) const {
    auto it = flags.find(property);
    return it == flags.end() ? std::nullopt : std::optional<bool>(it->second);
}
std::optional<Vec2> ConstraintSetupValues::vector(AnimationTrackProperty property) const {
    auto it = vectors.find(property);
    return it == vectors.end() ? std::nullopt : std::optional<Vec2>(it->second);
}
void ConstraintSetupValues::set(AnimationTrackProperty property, float value) { scalars[property] = value; }
void ConstraintSetupValues::set(AnimationTrackProperty property, bool value) { flags[property] = value; }
void ConstraintSetupValues::set(AnimationTrackProperty property, Vec2 value) { vectors[property] = value; }

std::optional<ConstraintKind> constraintKind(const Skeleton& skeleton, Uuid id) {
    const auto has = [id](const auto& v) {
        return std::any_of(v.begin(), v.end(), [id](const auto& c) { return c.id_ == id; });
    };
    if (has(skeleton.ikConstraints)) return ConstraintKind::Ik;
    if (has(skeleton.transformConstraints)) return ConstraintKind::Transform;
    if (has(skeleton.pathConstraints)) return ConstraintKind::Path;
    if (has(skeleton.physicsConstraints)) return ConstraintKind::Physics;
    return std::nullopt;
}

std::optional<std::string> constraintName(const Skeleton& skeleton, Uuid id) {
    for (const auto& c : skeleton.ikConstraints) if (c.id_ == id) return c.name_;
    for (const auto& c : skeleton.transformConstraints) if (c.id_ == id) return c.name_;
    for (const auto& c : skeleton.pathConstraints) if (c.id_ == id) return c.name_;
    for (const auto& c : skeleton.physicsConstraints) if (c.id_ == id) return c.name_;
    return std::nullopt;
}

std::optional<float> constraintScalar(const Skeleton& skeleton, Uuid id, AnimationTrackProperty property) {
    using P = AnimationTrackProperty;
    for (const auto& c : skeleton.ikConstraints) {
        if (c.id_ != id) continue;
        switch (property) {
            case P::ConstraintMix: return c.mix_;
            case P::IkSoftness: return c.softness;
            default: return std::nullopt;
        }
    }
    for (const auto& c : skeleton.transformConstraints) {
        if (c.id_ != id) continue;
        switch (property) {
            case P::ConstraintMix: return c.mix_;
            case P::TransformTranslateMix: return c.positionMix;
            case P::TransformRotateMix: return c.rotationMix;
            case P::TransformScaleMix: return c.scaleMix;
            case P::TransformShearMix: return c.shearMix;
            default: return std::nullopt;
        }
    }
    for (const auto& c : skeleton.pathConstraints) {
        if (c.id_ != id) continue;
        switch (property) {
            case P::ConstraintMix: return c.mix_;
            case P::PathPosition: return c.position;
            case P::PathSpacing: return c.spacing;
            case P::PathPositionMix: return c.positionMix;
            case P::PathRotateMix: return c.rotateMix;
            default: return std::nullopt;
        }
    }
    for (const auto& c : skeleton.physicsConstraints) {
        if (c.id_ != id) continue;
        switch (property) {
            case P::ConstraintMix: return c.mix_;
            case P::PhysicsMass: return c.settings.mass;
            case P::PhysicsDamping: return c.settings.damping;
            case P::PhysicsStiffness: return c.settings.stiffness;
            case P::PhysicsGravity: return c.settings.gravity;
            case P::PhysicsDrag: return c.settings.drag;
            default: return std::nullopt;
        }
    }
    return std::nullopt;
}

void setConstraintScalar(Skeleton& skeleton, Uuid id, AnimationTrackProperty property, float raw) {
    using P = AnimationTrackProperty;
    const float value = clamped(property, raw);

    for (auto& c : skeleton.ikConstraints) {
        if (c.id_ != id) continue;
        switch (property) {
            case P::ConstraintMix: c.mix_ = value; break;
            case P::IkSoftness: c.softness = value; break;
            default: break;
        }
        return;
    }
    for (auto& c : skeleton.transformConstraints) {
        if (c.id_ != id) continue;
        switch (property) {
            case P::ConstraintMix: c.mix_ = value; break;
            case P::TransformTranslateMix: c.positionMix = value; break;
            case P::TransformRotateMix: c.rotationMix = value; break;
            case P::TransformScaleMix: c.scaleMix = value; break;
            case P::TransformShearMix: c.shearMix = value; break;
            default: break;
        }
        return;
    }
    for (auto& c : skeleton.pathConstraints) {
        if (c.id_ != id) continue;
        switch (property) {
            case P::ConstraintMix: c.mix_ = value; break;
            case P::PathPosition: c.position = value; break;
            case P::PathSpacing: c.spacing = value; break;
            case P::PathPositionMix: c.positionMix = value; break;
            case P::PathRotateMix: c.rotateMix = value; break;
            default: break;
        }
        return;
    }
    for (auto& c : skeleton.physicsConstraints) {
        if (c.id_ != id) continue;
        switch (property) {
            case P::ConstraintMix: c.mix_ = value; break;
            case P::PhysicsMass: c.settings.mass = std::max(value, 0.0001f); break;
            case P::PhysicsDamping: c.settings.damping = value; break;
            case P::PhysicsStiffness: c.settings.stiffness = value; break;
            case P::PhysicsGravity: c.settings.gravity = value; break;
            case P::PhysicsDrag: c.settings.drag = value; break;
            default: break;
        }
        return;
    }
}

std::optional<bool> constraintFlag(const Skeleton& skeleton, Uuid id, AnimationTrackProperty property) {
    using P = AnimationTrackProperty;
    for (const auto& c : skeleton.ikConstraints) {
        if (c.id_ != id) continue;
        switch (property) {
            case P::IkBendPositive: return c.bendPositive;
            case P::IkStretch: return c.stretch;
            case P::IkCompress: return c.compress;
            default: return std::nullopt;
        }
    }
    return std::nullopt;
}

void setConstraintFlag(Skeleton& skeleton, Uuid id, AnimationTrackProperty property, bool value) {
    using P = AnimationTrackProperty;
    for (auto& c : skeleton.ikConstraints) {
        if (c.id_ != id) continue;
        switch (property) {
            case P::IkBendPositive: c.bendPositive = value; break;
            case P::IkStretch: c.stretch = value; break;
            case P::IkCompress: c.compress = value; break;
            default: break;
        }
        return;
    }
}

std::optional<Vec2> constraintVector(const Skeleton& skeleton, Uuid id, AnimationTrackProperty property) {
    if (property != AnimationTrackProperty::PhysicsWind) return std::nullopt;
    for (const auto& c : skeleton.physicsConstraints) {
        if (c.id_ == id) return c.settings.wind;
    }
    return std::nullopt;
}

void setConstraintVector(Skeleton& skeleton, Uuid id, AnimationTrackProperty property, Vec2 value) {
    if (property != AnimationTrackProperty::PhysicsWind) return;
    for (auto& c : skeleton.physicsConstraints) {
        if (c.id_ != id) continue;
        c.settings.wind = value;
        return;
    }
}

ConstraintSetupValues captureConstraintSetupValues(const Skeleton& skeleton, Uuid id) {
    ConstraintSetupValues out;
    for (AnimationTrackProperty property : animatableProperties(skeleton, id)) {
        switch (valueKind(property)) {
            case TrackValueKind::Scalar:
                if (auto v = constraintScalar(skeleton, id, property)) out.set(property, *v);
                break;
            case TrackValueKind::Flag:
                if (auto v = constraintFlag(skeleton, id, property)) out.set(property, *v);
                break;
            case TrackValueKind::Vector2:
                if (auto v = constraintVector(skeleton, id, property)) out.set(property, *v);
                break;
            case TrackValueKind::Deform:
            case TrackValueKind::DrawOrder:
            case TrackValueKind::Event:
            case TrackValueKind::Attachment:
                break;
        }
    }
    return out;
}

void applyConstraintSetupValues(Skeleton& skeleton, Uuid id, const ConstraintSetupValues& values) {
    for (AnimationTrackProperty property : animatableProperties(skeleton, id)) {
        switch (valueKind(property)) {
            case TrackValueKind::Scalar:
                if (auto v = values.scalar(property)) setConstraintScalar(skeleton, id, property, *v);
                break;
            case TrackValueKind::Flag:
                if (auto v = values.flag(property)) setConstraintFlag(skeleton, id, property, *v);
                break;
            case TrackValueKind::Vector2:
                if (auto v = values.vector(property)) setConstraintVector(skeleton, id, property, *v);
                break;
            case TrackValueKind::Deform:
            case TrackValueKind::DrawOrder:
            case TrackValueKind::Event:
            case TrackValueKind::Attachment:
                break;
        }
    }
}

} // namespace umeshcore
