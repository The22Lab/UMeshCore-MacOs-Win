#pragma once

// 1:1 port of `Data/PhysicsConstraintSystem.swift`, EXCEPT: this is
// ordinary owned state (create one per rig/skeleton instance), never a
// process-wide singleton -- see UMeshCore/ROADMAP.md risk #2. The Swift
// source's `PhysicsConstraintSystem.shared` would step every simultaneous
// rig instance's clock N times too fast if N instances shared it; nothing
// here should be `static`.

#include <optional>
#include <unordered_map>
#include <utility>

#include "umeshcore/Constraints/Constraint.h"
#include "umeshcore/Constraints/PhysicsConstraint.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

class Skeleton;

struct BoneSimState {
    Vec2 position;
    Vec2 velocity;
    float angle = 0.0f;
    float angularVelocity = 0.0f;
    float restLength = 0.0f;
    bool initialized = false;
};

// Stateful secondary-motion solver, one per rig instance. Stores per-bone
// simulation state and advances the simulation once per render frame; all
// other constraint solvers in this library are stateless.
//
// Lifecycle (caller-driven, mirroring Skeleton.worldMatrices(steppingPhysics:)
// in the Swift source, which is now this class's caller's responsibility
// rather than something Skeleton does internally -- Skeleton has no physics
// state of its own here):
//   1. Whoever owns a Skeleton + PhysicsConstraintSystem sets `isActive`.
//   2. Once per presented frame, call setFrameTime then beginFrame(skeleton).
//   3. For each PhysicsConstraint, call applyConstraint(...) to blend the
//      simulated (and inter-frame-interpolated) positions into the live
//      world-matrix map.
//
// See the Swift source's header comment for why the simulation runs on a
// FIXED clock decoupled from the display: a variable-dt integrator is not
// the same simulation twice, and diverges measurably between display rates.
class PhysicsConstraintSystem {
public:
    bool isActive = false;
    PhysicsQuality quality = PhysicsQuality::Medium;

    // Told by the renderer when the frame being built will be presented,
    // in seconds (matches CACurrentMediaTime's units, not its epoch).
    void setFrameTime(double time) { frameTime_ = time; }

    // Steps the simulation in fixed steps for however much time elapsed
    // since the last call, up to kMaxStepsPerFrame catch-up steps.
    void beginFrame(const Skeleton& skeleton);

    void applyConstraint(
        const PhysicsConstraint& c, const Skeleton& skeleton, WorldMatrices& worldMatrices);

    void reset();
    void resetConstraint(const PhysicsConstraint& c);

    std::unordered_map<Uuid, std::pair<Vec2, float>, UuidHash> captureSimulatedPositions() const;

private:
    std::unordered_map<Uuid, BoneSimState, UuidHash> boneStates_;
    // The state one fixed step earlier; what the render samples is
    // somewhere between this and boneStates_.
    std::unordered_map<Uuid, BoneSimState, UuidHash> previousStates_;
    double lastStepTime_ = 0.0;
    bool hasInitialized_ = false;
    // Unspent time, always less than one fixed step.
    double accumulator_ = 0.0;
    // How far between previousStates_ and boneStates_ the render sits.
    float renderAlpha_ = 0.0f;
    std::optional<double> frameTime_;

    static constexpr double kFixedStep = 1.0 / 120.0;
    static constexpr int kMaxStepsPerFrame = 8;

    std::optional<BoneSimState> renderState(Uuid boneID) const;
    void initializeFromSkeleton(const Skeleton& skeleton);
    void step(const Skeleton& skeleton, float dt);
    void stepSpring(const PhysicsConstraint& c, const WorldMatrices& base, float dt);
    void stepJiggle(const PhysicsConstraint& c, const WorldMatrices& base, float dt);
    void stepRope(const PhysicsConstraint& c, const Skeleton& skeleton, const WorldMatrices& base, float dt);
};

} // namespace umeshcore
