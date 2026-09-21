import Foundation
import simd

// MARK: - Physics Type

enum PhysicsType: String, Codable, CaseIterable, Equatable {
    case spring     // Hair, tails, capes — damped spring toward rest pose
    case jiggle     // Cartoon bounce, muscles — overshooting spring
    case rope       // Chains, tentacles, whips — distance-constrained chain
    case pendulum   // Jewelry, hanging objects — phase 2 (evaluated as spring)
    case cloth      // Fabric, large capes — phase 2 (evaluated as spring)

    var displayName: String {
        switch self {
        case .spring:   return "Spring"
        case .jiggle:   return "Jiggle"
        case .rope:     return "Rope"
        case .pendulum: return "Pendulum"
        case .cloth:    return "Cloth"
        }
    }

    var systemImage: String {
        switch self {
        case .spring:   return "waveform.path"
        case .jiggle:   return "water.waves"
        case .rope:     return "link"
        case .pendulum: return "metronome"
        case .cloth:    return "square.on.square"
        }
    }
}

// MARK: - Physics Settings

struct PhysicsSettings: Equatable {
    /// Simulated inertia. Higher mass = slower response, more overshoot.
    var mass: Float = 1.0
    /// Velocity decay per frame. 0 = perpetual, 1 = instant snap (no dynamics).
    var damping: Float = 0.88
    /// Return-to-rest spring stiffness (world units / s²).
    var stiffness: Float = 120.0
    /// Downward gravitational acceleration (world units / s²).
    var gravity: Float = 400.0
    /// Air-drag coefficient proportional to velocity.
    var drag: Float = 0.04
    /// Constant world-space wind force applied to all simulated bones.
    var wind: SIMD2<Float> = .zero
    /// Maximum bone stretch multiplier relative to authored length.
    var stretchLimit: Float = 1.3
    /// Angle constraint range relative to parent (radians). Spring and Jiggle only.
    var angleLimitMin: Float = -.pi
    var angleLimitMax: Float = .pi
}

// MARK: - Physics Preset

enum PhysicsPreset: String, CaseIterable, Equatable {
    case hair, tail, cape, rope, chain, jiggle, breast, custom

    var displayName: String { rawValue.capitalized }

    var physicsType: PhysicsType {
        switch self {
        case .hair, .tail, .cape, .breast: return .spring
        case .rope, .chain:                return .rope
        case .jiggle:                      return .jiggle
        case .custom:                      return .spring
        }
    }

    func settings() -> PhysicsSettings {
        var s = PhysicsSettings()
        switch self {
        case .hair:
            s.mass = 0.5; s.damping = 0.90; s.stiffness = 90;  s.gravity = 280; s.drag = 0.05
        case .tail:
            s.mass = 1.0; s.damping = 0.82; s.stiffness = 60;  s.gravity = 500; s.drag = 0.03
        case .cape:
            s.mass = 0.8; s.damping = 0.80; s.stiffness = 110; s.gravity = 350; s.drag = 0.06
        case .rope:
            s.mass = 1.5; s.damping = 0.75; s.stiffness = 0;   s.gravity = 600; s.drag = 0.02
        case .chain:
            s.mass = 2.0; s.damping = 0.68; s.stiffness = 0;   s.gravity = 800; s.drag = 0.01
        case .jiggle:
            s.mass = 0.4; s.damping = 0.60; s.stiffness = 220; s.gravity = 0;   s.drag = 0.09
        case .breast:
            s.mass = 0.6; s.damping = 0.72; s.stiffness = 150; s.gravity = 200; s.drag = 0.07
        case .custom:
            break
        }
        return s
    }
}

// MARK: - Physics Constraint

/// Artistic physics constraint. Drives a bone chain using spring/rope/jiggle
/// dynamics relative to the chain's animated rest pose. Physics runs LAST in
/// the evaluation order (after IK and Path), so it adds secondary motion on
/// top of the fully solved rig.
///
/// Simulation state lives in `PhysicsConstraintSystem.shared`. The constraint's
/// `apply()` reads that state; the system is stepped once per frame from
/// `Skeleton.worldMatrices()` when `PhysicsConstraintSystem.shared.isActive` is true.
struct PhysicsConstraint: BoneConstraint, Identifiable, Equatable {
    let id: UUID
    var name: String
    var enabled: Bool
    /// Should be > 100 so physics runs after IK (0–50) and Path (0–50).
    var order: Int
    var mix: Float

    var physicsType: PhysicsType
    /// Chain of bone IDs, root (index 0, pinned) → tips (simulated).
    var affectedBones: [UUID]
    var settings: PhysicsSettings

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        order: Int = 100,
        mix: Float = 1.0,
        physicsType: PhysicsType = .spring,
        affectedBones: [UUID] = [],
        settings: PhysicsSettings = PhysicsSettings()
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.order = order
        self.mix = mix
        self.physicsType = physicsType
        self.affectedBones = affectedBones
        self.settings = settings
    }

    static func == (lhs: PhysicsConstraint, rhs: PhysicsConstraint) -> Bool {
        lhs.id == rhs.id
    }

    func apply(skeleton: Skeleton, worldMatrices: inout [UUID: simd_float4x4]) {
        PhysicsConstraintSystem.shared.applyConstraint(self, skeleton: skeleton, worldMatrices: &worldMatrices)
    }
}
