#pragma once

// 1:1 port of `Data/PhysicsConstraint.swift`.

#include <string>
#include <vector>

#include "umeshcore/Constraints/Constraint.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/MatrixUtilities.h" // kPi
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

enum class PhysicsType {
    Spring,   // Hair, tails, capes -- damped spring toward rest pose.
    Jiggle,   // Cartoon bounce, muscles -- overshooting spring.
    Rope,     // Chains, tentacles, whips -- distance-constrained chain.
    Pendulum, // Jewelry, hanging objects -- evaluated as spring.
    Cloth     // Fabric, large capes -- evaluated as spring.
};

struct PhysicsSettings {
    float mass = 1.0f;
    // Velocity decay per second. 0 = perpetual, 1 = instant snap.
    float damping = 0.88f;
    float stiffness = 120.0f;
    float gravity = 400.0f;
    float drag = 0.04f;
    Vec2 wind = Vec2::zero();
    float stretchLimit = 1.3f;
    float angleLimitMin = -kPi;
    float angleLimitMax = kPi;

    bool operator==(const PhysicsSettings&) const = default;
};

enum class PhysicsPreset { Hair, Tail, Cape, Rope, Chain, Jiggle, Breast, Custom };

inline PhysicsType physicsTypeFor(PhysicsPreset preset) {
    switch (preset) {
        case PhysicsPreset::Hair:
        case PhysicsPreset::Tail:
        case PhysicsPreset::Cape:
        case PhysicsPreset::Breast:
            return PhysicsType::Spring;
        case PhysicsPreset::Rope:
        case PhysicsPreset::Chain:
            return PhysicsType::Rope;
        case PhysicsPreset::Jiggle:
            return PhysicsType::Jiggle;
        case PhysicsPreset::Custom:
            return PhysicsType::Spring;
    }
    return PhysicsType::Spring;
}

inline PhysicsSettings settingsFor(PhysicsPreset preset) {
    PhysicsSettings s;
    switch (preset) {
        case PhysicsPreset::Hair:
            s.mass = 0.5f; s.damping = 0.90f; s.stiffness = 90.0f; s.gravity = 280.0f; s.drag = 0.05f;
            break;
        case PhysicsPreset::Tail:
            s.mass = 1.0f; s.damping = 0.82f; s.stiffness = 60.0f; s.gravity = 500.0f; s.drag = 0.03f;
            break;
        case PhysicsPreset::Cape:
            s.mass = 0.8f; s.damping = 0.80f; s.stiffness = 110.0f; s.gravity = 350.0f; s.drag = 0.06f;
            break;
        case PhysicsPreset::Rope:
            s.mass = 1.5f; s.damping = 0.75f; s.stiffness = 0.0f; s.gravity = 600.0f; s.drag = 0.02f;
            break;
        case PhysicsPreset::Chain:
            s.mass = 2.0f; s.damping = 0.68f; s.stiffness = 0.0f; s.gravity = 800.0f; s.drag = 0.01f;
            break;
        case PhysicsPreset::Jiggle:
            s.mass = 0.4f; s.damping = 0.60f; s.stiffness = 220.0f; s.gravity = 0.0f; s.drag = 0.09f;
            break;
        case PhysicsPreset::Breast:
            s.mass = 0.6f; s.damping = 0.72f; s.stiffness = 150.0f; s.gravity = 200.0f; s.drag = 0.07f;
            break;
        case PhysicsPreset::Custom:
            break;
    }
    return s;
}

// Iteration count for the rope solver's XPBD relaxation.
enum class PhysicsQuality { Low = 4, Medium = 8, High = 12, Ultra = 20 };

// Artistic physics constraint. Drives a bone chain using spring/rope/jiggle
// dynamics relative to the chain's animated rest pose. Runs LAST in the
// evaluation order (after IK and Path).
//
// Simulation state lives in a `PhysicsSimState` OWNED BY the rig instance
// that holds this skeleton (see PhysicsConstraintSystem.h) -- deliberately
// NOT a process-wide singleton the way the Swift source's
// `PhysicsConstraintSystem.shared` is; see UMeshCore/ROADMAP.md risk #2.
// `apply()` therefore needs a simulation instance passed in, which the
// generic `BoneConstraint::apply(skeleton, worldMatrices)` signature has no
// room for -- so unlike IK/Path/Transform, PhysicsConstraint::apply here is
// a no-op, and the real entry point is
// `PhysicsConstraintSystem::applyConstraint`, called directly by whatever
// owns both the skeleton and its physics sim state (mirroring
// `Skeleton.worldMatrices(steppingPhysics:)`'s special-casing of physics in
// the Swift source).
class PhysicsConstraint : public BoneConstraint {
public:
    Uuid id_ = Uuid::generate();
    std::string name_;
    bool enabled_ = true;
    // Should be > 100 so physics runs after IK (0-50) and Path (0-50).
    int order_ = 100;
    float mix_ = 1.0f;

    PhysicsType physicsType = PhysicsType::Spring;
    // Chain of bone IDs, root (index 0, pinned) -> tips (simulated).
    std::vector<Uuid> affectedBones;
    PhysicsSettings settings;

    PhysicsConstraint() = default;
    explicit PhysicsConstraint(std::string name) : name_(std::move(name)) {}

    Uuid id() const override { return id_; }
    const std::string& name() const override { return name_; }
    bool enabled() const override { return enabled_; }
    int order() const override { return order_; }
    float mix() const override { return mix_; }

    void apply(const Skeleton& skeleton, WorldMatrices& worldMatrices) const override {
        (void)skeleton;
        (void)worldMatrices;
        // See class comment: physics is applied out-of-band via
        // PhysicsConstraintSystem::applyConstraint, not this generic hook.
    }
};

} // namespace umeshcore
