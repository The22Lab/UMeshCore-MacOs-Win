#include "umeshcore/Constraints/PhysicsConstraintSystem.h"

#include <chrono>
#include <cmath>

#include "umeshcore/Constraints/ConstraintPropagation.h"
#include "umeshcore/Math/Angle.h"
#include "umeshcore/Model/Skeleton.h"

namespace umeshcore {

namespace {

inline float matRotZ(const Mat4& m) { return std::atan2(m.columns[0].y, m.columns[0].x); }

Mat4 rotateM(const Mat4& m, Vec3 p, float a) {
    if (!(std::abs(a) > 0.000001f)) return m;
    return MatrixUtilities::translation(p) * MatrixUtilities::rotationZ(a) *
           MatrixUtilities::translation(-p) * m;
}

inline float clampf(float v, float lo, float hi) { return std::max(lo, std::min(hi, v)); }

double monotonicSeconds() {
    static const auto start = std::chrono::steady_clock::now();
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
}

} // namespace

std::optional<BoneSimState> PhysicsConstraintSystem::renderState(Uuid boneID) const {
    auto currentIt = boneStates_.find(boneID);
    if (currentIt == boneStates_.end()) return std::nullopt;
    const BoneSimState& current = currentIt->second;
    auto previousIt = previousStates_.find(boneID);
    if (previousIt == previousStates_.end() || !previousIt->second.initialized ||
        !(renderAlpha_ > 0.0f)) {
        return current;
    }
    const BoneSimState& previous = previousIt->second;
    BoneSimState blended = current;
    blended.position = previous.position + (current.position - previous.position) * renderAlpha_;
    // The short way round, for the same reason keyframed rotation takes it:
    // a spring crossing +-pi must not appear to unwind the whole circle.
    blended.angle = previous.angle + shortestAngleDelta(previous.angle, current.angle) * renderAlpha_;
    return blended;
}

void PhysicsConstraintSystem::initializeFromSkeleton(const Skeleton& skeleton) {
    const WorldMatrices matrices = skeleton.baseWorldMatrices();
    for (const auto& constraint : skeleton.physicsConstraints) {
        if (!constraint.enabled_) continue;
        for (Uuid boneID : constraint.affectedBones) {
            if (boneStates_.contains(boneID)) continue;
            auto wIt = matrices.find(boneID);
            const Bone* bone = skeleton.bone(boneID);
            if (wIt == matrices.end() || bone == nullptr) continue;
            const Vec3 o3 = MatrixUtilities::transformPoint(Vec3::zero(), wIt->second);
            BoneSimState state;
            state.position = Vec2(o3.x, o3.y);
            state.velocity = Vec2::zero();
            state.angle = matRotZ(wIt->second);
            state.angularVelocity = 0.0f;
            state.restLength = bone->length;
            state.initialized = true;
            boneStates_[boneID] = state;
        }
    }
}

void PhysicsConstraintSystem::beginFrame(const Skeleton& skeleton) {
    if (!isActive) return;
    const double now = frameTime_.has_value() ? *frameTime_ : monotonicSeconds();
    if (!hasInitialized_) {
        lastStepTime_ = now;
        accumulator_ = 0.0;
        renderAlpha_ = 0.0f;
        hasInitialized_ = true;
        initializeFromSkeleton(skeleton);
        previousStates_ = boneStates_;
        return;
    }

    const double elapsed = now - lastStepTime_;
    // Zero or negative: the same frame asking twice, or the playhead
    // scrubbed backwards. Neither is time passing.
    if (!(elapsed > 0.0)) return;
    lastStepTime_ = now;
    accumulator_ += elapsed;

    int steps = 0;
    while (accumulator_ >= kFixedStep && steps < kMaxStepsPerFrame) {
        previousStates_ = boneStates_;
        step(skeleton, static_cast<float>(kFixedStep));
        accumulator_ -= kFixedStep;
        ++steps;
    }
    if (steps == kMaxStepsPerFrame) {
        // Gave up catching up. Drop the debt rather than carry it forward.
        accumulator_ = 0.0;
    }
    renderAlpha_ = static_cast<float>(accumulator_ / kFixedStep);
}

void PhysicsConstraintSystem::applyConstraint(
    const PhysicsConstraint& c, const Skeleton& skeleton, WorldMatrices& worldMatrices) {
    if (!isActive) return;
    const float mix = clampf(c.mix_, 0.0f, 1.0f);
    const auto& childrenByParent = skeleton.childrenIndexForPropagation();
    for (Uuid boneID : c.affectedBones) {
        auto state = renderState(boneID);
        if (!state.has_value() || !state->initialized) continue;
        auto oldWIt = worldMatrices.find(boneID);
        if (oldWIt == worldMatrices.end()) continue;
        const Vec3 oldO3 = MatrixUtilities::transformPoint(Vec3::zero(), oldWIt->second);
        const Vec2 oldO(oldO3.x, oldO3.y);
        const Vec2 newO = oldO + (state->position - oldO) * mix;
        const Vec3 dT(newO.x - oldO.x, newO.y - oldO.y, 0);
        Mat4 newW = MatrixUtilities::translation(dT) * oldWIt->second;
        const float cur = matRotZ(newW);
        const float delta = shortestAngleDelta(cur, state->angle) * mix;
        if (std::abs(delta) > 0.00001f) {
            const Vec3 piv(newO.x, newO.y, 0);
            newW = rotateM(newW, piv, delta);
        }
        worldMatrices[boneID] = newW;
        ConstraintPropagation::cascade(boneID, std::nullopt, skeleton, childrenByParent, worldMatrices);
    }
}

void PhysicsConstraintSystem::reset() {
    boneStates_.clear();
    previousStates_.clear();
    lastStepTime_ = 0.0;
    accumulator_ = 0.0;
    renderAlpha_ = 0.0f;
    hasInitialized_ = false;
}

void PhysicsConstraintSystem::resetConstraint(const PhysicsConstraint& c) {
    for (Uuid id : c.affectedBones) {
        boneStates_.erase(id);
        previousStates_.erase(id);
    }
    if (boneStates_.empty()) hasInitialized_ = false;
}

std::unordered_map<Uuid, std::pair<Vec2, float>, UuidHash>
PhysicsConstraintSystem::captureSimulatedPositions() const {
    std::unordered_map<Uuid, std::pair<Vec2, float>, UuidHash> result;
    for (const auto& [id, state] : boneStates_) {
        if (state.initialized) result[id] = {state.position, state.angle};
    }
    return result;
}

void PhysicsConstraintSystem::step(const Skeleton& skeleton, float dt) {
    // Refresh any newly-added bones (not yet in state).
    initializeFromSkeleton(skeleton);

    const WorldMatrices base = skeleton.baseWorldMatrices();
    for (const auto& c : skeleton.physicsConstraints) {
        if (!c.enabled_ || !(c.mix_ > 0.0001f)) continue;
        switch (c.physicsType) {
            case PhysicsType::Spring:
            case PhysicsType::Pendulum:
            case PhysicsType::Cloth:
                stepSpring(c, base, dt);
                break;
            case PhysicsType::Jiggle:
                stepJiggle(c, base, dt);
                break;
            case PhysicsType::Rope:
                stepRope(c, skeleton, base, dt);
                break;
        }
    }
}

// Damped spring toward animated rest position. Root bone (index 0) is pinned.
void PhysicsConstraintSystem::stepSpring(const PhysicsConstraint& c, const WorldMatrices& base, float dt) {
    const PhysicsSettings& s = c.settings;
    for (std::size_t i = 0; i < c.affectedBones.size(); ++i) {
        const Uuid boneID = c.affectedBones[i];
        auto it = boneStates_.find(boneID);
        if (it == boneStates_.end()) continue;
        BoneSimState st = it->second;

        if (i == 0) {
            auto wIt = base.find(boneID);
            if (wIt != base.end()) {
                const Vec3 o3 = MatrixUtilities::transformPoint(Vec3::zero(), wIt->second);
                st.position = Vec2(o3.x, o3.y);
                st.velocity = Vec2::zero();
                st.angle = matRotZ(wIt->second);
                boneStates_[boneID] = st;
            }
            continue;
        }
        auto wIt = base.find(boneID);
        if (!st.initialized || wIt == base.end()) continue;

        const Vec3 restO3 = MatrixUtilities::transformPoint(Vec3::zero(), wIt->second);
        const Vec2 restPos(restO3.x, restO3.y);
        const float restAngle = matRotZ(wIt->second);

        const Vec2 springF = (restPos - st.position) * s.stiffness;
        const Vec2 gravF = Vec2(0, -s.gravity) * s.mass;
        const Vec2 windF = s.wind;
        const Vec2 dragF = st.velocity * -s.drag;
        const Vec2 accel = (springF + gravF + windF + dragF) / std::max(s.mass, 0.01f);

        st.velocity = (st.velocity + accel * dt) * std::pow(1.0f - s.damping, dt);
        st.velocity.x = clampf(st.velocity.x, -2000.0f, 2000.0f);
        st.velocity.y = clampf(st.velocity.y, -2000.0f, 2000.0f);
        st.position = st.position + st.velocity * dt;

        const float angSpring = shortestAngleDelta(st.angle, restAngle) * s.stiffness * 0.4f;
        const float angDrag = -st.angularVelocity * s.drag * 2.0f;
        st.angularVelocity = (st.angularVelocity + (angSpring + angDrag) * dt) * std::pow(1.0f - s.damping, dt);
        st.angle += st.angularVelocity * dt;

        // Angle limits.
        if (i > 0) {
            const Uuid parentID = c.affectedBones[i - 1];
            auto parentIt = boneStates_.find(parentID);
            if (parentIt != boneStates_.end()) {
                const float rel = shortestAngleDelta(parentIt->second.angle, st.angle);
                if (rel < s.angleLimitMin || rel > s.angleLimitMax) {
                    const float clamped = clampf(rel, s.angleLimitMin, s.angleLimitMax);
                    st.angle = parentIt->second.angle + clamped;
                    st.angularVelocity *= 0.5f;
                }
            }
        }

        boneStates_[boneID] = st;
    }
}

// High stiffness, low damping -- allows overshoot and bounce.
void PhysicsConstraintSystem::stepJiggle(const PhysicsConstraint& c, const WorldMatrices& base, float dt) {
    const PhysicsSettings& s = c.settings;
    const float ks = s.stiffness * 2.0f;
    const float kd = s.damping * 0.5f;

    for (std::size_t i = 0; i < c.affectedBones.size(); ++i) {
        const Uuid boneID = c.affectedBones[i];
        auto it = boneStates_.find(boneID);
        if (it == boneStates_.end()) continue;
        BoneSimState st = it->second;
        if (i == 0) {
            auto wIt = base.find(boneID);
            if (wIt != base.end()) {
                const Vec3 o3 = MatrixUtilities::transformPoint(Vec3::zero(), wIt->second);
                st.position = Vec2(o3.x, o3.y);
                st.velocity = Vec2::zero();
                st.angle = matRotZ(wIt->second);
                boneStates_[boneID] = st;
            }
            continue;
        }
        auto wIt = base.find(boneID);
        if (!st.initialized || wIt == base.end()) continue;

        const Vec3 restO3 = MatrixUtilities::transformPoint(Vec3::zero(), wIt->second);
        const Vec2 restPos(restO3.x, restO3.y);
        const float restAngle = matRotZ(wIt->second);

        const Vec2 springF = (restPos - st.position) * ks;
        const Vec2 gravF = Vec2(0, -s.gravity * 0.25f) * s.mass;
        const Vec2 dragF = st.velocity * (-s.drag * 3.0f);
        const Vec2 accel = (springF + gravF + dragF) / std::max(s.mass, 0.01f);

        st.velocity = (st.velocity + accel * dt) * std::pow(1.0f - kd, dt);
        st.position = st.position + st.velocity * dt;

        const float angSpring = shortestAngleDelta(st.angle, restAngle) * ks * 0.6f;
        st.angularVelocity = (st.angularVelocity + angSpring * dt) * std::pow(1.0f - kd, dt);
        st.angle += st.angularVelocity * dt;

        boneStates_[boneID] = st;
    }
}

// XPBD-style Verlet distance-constrained chain. No spring return -- gravity
// + air drag + distance relaxation.
void PhysicsConstraintSystem::stepRope(
    const PhysicsConstraint& c, const Skeleton& skeleton, const WorldMatrices& base, float dt) {
    (void)skeleton;
    const PhysicsSettings& s = c.settings;
    const std::vector<Uuid>& chain = c.affectedBones;
    if (chain.size() < 2) return;
    const int iters = static_cast<int>(quality);

    // Integrate forces (gravity, wind, drag) -- skip pinned root.
    for (std::size_t i = 0; i < chain.size(); ++i) {
        const Uuid boneID = chain[i];
        auto it = boneStates_.find(boneID);
        if (it == boneStates_.end()) continue;
        BoneSimState st = it->second;
        if (i == 0) {
            auto wIt = base.find(boneID);
            if (wIt != base.end()) {
                const Vec3 o3 = MatrixUtilities::transformPoint(Vec3::zero(), wIt->second);
                st.position = Vec2(o3.x, o3.y);
                st.velocity = Vec2::zero();
                st.angle = matRotZ(wIt->second);
                boneStates_[boneID] = st;
            }
            continue;
        }
        if (!st.initialized) continue;
        const Vec2 gravF = Vec2(0, -s.gravity) * s.mass;
        const Vec2 windF = s.wind;
        const Vec2 dragF = st.velocity * -s.drag;
        const Vec2 accel = (gravF + windF + dragF) / std::max(s.mass, 0.01f);
        st.velocity = (st.velocity + accel * dt) * std::pow(1.0f - s.damping, dt);
        st.velocity.x = clampf(st.velocity.x, -2000.0f, 2000.0f);
        st.velocity.y = clampf(st.velocity.y, -2000.0f, 2000.0f);
        st.position = st.position + st.velocity * dt;
        boneStates_[boneID] = st;
    }

    // Distance constraint relaxation (XPBD).
    for (int iter = 0; iter < iters; ++iter) {
        for (std::size_t i = 0; i + 1 < chain.size(); ++i) {
            const Uuid idA = chain[i];
            const Uuid idB = chain[i + 1];
            auto itA = boneStates_.find(idA);
            auto itB = boneStates_.find(idB);
            if (itA == boneStates_.end() || itB == boneStates_.end()) continue;
            BoneSimState stA = itA->second;
            BoneSimState stB = itB->second;
            const float restLen = std::max(1.0f, stA.restLength);
            const Vec2 d = stB.position - stA.position;
            const float dist = length(d);
            if (!(dist > 0.001f)) continue;
            const float err = (dist - restLen) / dist * 0.5f;
            const Vec2 corr = d * err;
            if (i > 0) {
                stA.position = stA.position + corr;
                boneStates_[idA] = stA;
            }
            stB.position = stB.position - corr;
            boneStates_[idB] = stB;
        }
    }

    // Derive angles from link directions.
    for (std::size_t i = 0; i + 1 < chain.size(); ++i) {
        const Uuid idA = chain[i];
        const Uuid idB = chain[i + 1];
        auto itA = boneStates_.find(idA);
        auto itB = boneStates_.find(idB);
        if (itA == boneStates_.end() || itB == boneStates_.end()) continue;
        BoneSimState stA = itA->second;
        const Vec2 d = itB->second.position - stA.position;
        if (lengthSquared(d) > 0.001f) {
            stA.angle = std::atan2(d.y, d.x);
            boneStates_[idA] = stA;
        }
    }
}

} // namespace umeshcore
