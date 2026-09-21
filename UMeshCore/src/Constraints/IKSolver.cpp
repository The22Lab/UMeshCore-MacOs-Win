#include "umeshcore/Constraints/IKSolver.h"

#include <algorithm>
#include <cmath>

#include "umeshcore/Constraints/ConstraintPropagation.h"
#include "umeshcore/Math/Angle.h"
#include "umeshcore/Model/Skeleton.h"

namespace umeshcore::IKSolver {

namespace {

// Iteration cap for FABRIK. Converges in 4-6 passes for typical character
// rigs; 12 is generous for long whip-style chains. FIXED, not
// convergence-terminated -- see solveFABRIK's comment.
constexpr int kFabrikMaxIterations = 12;
// How far off colinear the chain's midpoint has to be before the bend hint
// stops helping; also the hint's strength at exactly colinear.
constexpr float kBendHintReach = 0.5f;

inline float clampf(float x, float lo, float hi) { return std::max(lo, std::min(hi, x)); }

// Extract the Z-axis rotation from a 2D transform matrix (assumes no
// scale/shear on the basis -- true for skeleton bones built by Bone::make).
inline float matrixRotationZ(const Mat4& m) { return std::atan2(m.columns[0].y, m.columns[0].x); }

// Pre-multiply `matrix` by R(angle) around the world-space pivot `pivot`.
// Equivalent to T(pivot) * R(angle) * T(-pivot) * matrix.
Mat4 rotateMatrix(const Mat4& matrix, Vec3 pivot, float angle) {
    if (std::abs(angle) < 0.000001f) return matrix;
    const Mat4 toOrigin = MatrixUtilities::translation(-pivot);
    const Mat4 rot = MatrixUtilities::rotationZ(angle);
    const Mat4 fromOrigin = MatrixUtilities::translation(pivot);
    return fromOrigin * rot * toOrigin * matrix;
}

// Apply a soft-IK damping curve to the target relative to `origin`. When
// the raw target distance exceeds `maxReach - softness`, the effective
// target is pulled back along the line toward `origin` so the chain never
// fully extends -- smooth ease-out instead of a hard pop at the limit.
Vec2 softenedTarget(Vec2 target, Vec2 origin, float maxReach, float softness) {
    if (!(softness > 0.0001f) || !(maxReach > 0.0001f)) return target;
    const Vec2 toTarget = target - origin;
    const float distance = length(toTarget);
    const float softZone = maxReach - softness;
    if (!(distance > softZone)) return target;
    const float over = distance - softZone;
    const float damped = softness * (1.0f - std::exp(-over / std::max(softness, 0.0001f)));
    const float newDistance = softZone + damped;
    const Vec2 dir = toTarget / std::max(distance, 0.0001f);
    return origin + dir * newDistance;
}

void solveOneBone(Uuid boneID, Vec2 target, float mix, const Skeleton& skeleton, WorldMatrices& worldMatrices) {
    const Bone* bone = skeleton.bone(boneID);
    auto worldIt = worldMatrices.find(boneID);
    if (bone == nullptr || worldIt == worldMatrices.end()) return;
    const Mat4& world = worldIt->second;

    const Vec3 originW = MatrixUtilities::transformPoint(Vec3::zero(), world);
    const Vec2 origin(originW.x, originW.y);
    const Vec2 toTarget = target - origin;
    if (!(lengthSquared(toTarget) > 0.000001f)) return;

    const Vec3 tipW = MatrixUtilities::transformPoint(Vec3(bone->length, 0, 0), world);
    const Vec2 tip(tipW.x, tipW.y);
    const Vec2 currentDir = tip - origin;
    if (!(lengthSquared(currentDir) > 0.000001f)) return;

    const float currentAngle = std::atan2(currentDir.y, currentDir.x);
    const float desiredAngle = std::atan2(toTarget.y, toTarget.x);
    const float deltaAngle = shortestAngleDelta(currentAngle, desiredAngle) * mix;

    const Mat4 rotated = rotateMatrix(world, Vec3(originW.x, originW.y, 0), deltaAngle);
    worldMatrices[boneID] = rotated;
    ConstraintPropagation::cascade(boneID, std::nullopt, skeleton, worldMatrices);
}

void solveTwoBone(
    Uuid rootID, Uuid tipID, Vec2 rawTarget, bool bendPositive, bool stretch, bool compress,
    bool uniformScale, float softness, float mix, const Skeleton& skeleton,
    WorldMatrices& worldMatrices) {
    const Bone* rootBone = skeleton.bone(rootID);
    const Bone* tipBone = skeleton.bone(tipID);
    auto rootWorldIt = worldMatrices.find(rootID);
    auto tipWorldIt = worldMatrices.find(tipID);
    if (rootBone == nullptr || tipBone == nullptr || rootWorldIt == worldMatrices.end() ||
        tipWorldIt == worldMatrices.end()) {
        return;
    }
    const Mat4 rootWorld = rootWorldIt->second;
    const Mat4 tipWorld = tipWorldIt->second;

    const Vec3 rootOriginW = MatrixUtilities::transformPoint(Vec3::zero(), rootWorld);
    const Vec2 root(rootOriginW.x, rootOriginW.y);

    const float l1 = rootBone->length;
    const float l2 = tipBone->length;
    const float maxReach = l1 + l2;
    const float minReach = std::abs(l1 - l2);

    const Vec2 target = softenedTarget(rawTarget, root, maxReach, softness);
    const Vec2 toTarget = target - root;
    const float distance = length(toTarget);

    float effectiveL1 = l1;
    float effectiveL2 = l2;
    if (distance > maxReach && stretch && maxReach > 0.0001f) {
        const float scale = distance / maxReach;
        effectiveL1 = l1 * scale;
        effectiveL2 = l2 * scale;
        (void)uniformScale; // Swift computes the same `scale` on both branches.
    } else if (distance < minReach && compress) {
        const float scale = distance / std::max(minReach, 0.0001f);
        effectiveL1 = l1 * scale;
        effectiveL2 = l2 * scale;
    }

    const float effectiveMax = effectiveL1 + effectiveL2;
    const float effectiveMin = std::abs(effectiveL1 - effectiveL2);
    const float solveD = std::max(effectiveMin + 0.0001f, std::min(effectiveMax - 0.0001f, distance));

    const float alpha = std::atan2(toTarget.y, toTarget.x);
    const float cosBeta = clampf(
        (effectiveL1 * effectiveL1 + solveD * solveD - effectiveL2 * effectiveL2) /
            (2.0f * effectiveL1 * solveD),
        -1.0f, 1.0f);
    const float beta = std::acos(cosBeta);
    const float bendSign = bendPositive ? 1.0f : -1.0f;

    const float rootDesiredAngle = alpha + beta * bendSign;
    const float cosGamma = clampf(
        (effectiveL1 * effectiveL1 + effectiveL2 * effectiveL2 - solveD * solveD) /
            (2.0f * effectiveL1 * effectiveL2),
        -1.0f, 1.0f);
    const float gamma = std::acos(cosGamma);
    // The second bone turns back TOWARD the target: opposite sign to the
    // root's bend. Same sign reflects the chain about the root and misses
    // the target by up to the full bone length -- a documented historical
    // bug, do not "simplify" this sign away.
    const float tipRelativeAngle = -(kPi - gamma) * bendSign;

    const float rootCurrentAngle = matrixRotationZ(rootWorld);
    const float tipCurrentAngle = matrixRotationZ(tipWorld);
    const float tipDesiredAngle = rootDesiredAngle + tipRelativeAngle;

    const float rootDelta = shortestAngleDelta(rootCurrentAngle, rootDesiredAngle) * mix;
    const float tipDelta = shortestAngleDelta(tipCurrentAngle, tipDesiredAngle) * mix;

    const Mat4 newRootWorld = rotateMatrix(rootWorld, Vec3(root.x, root.y, 0), rootDelta);
    worldMatrices[rootID] = newRootWorld;

    const Vec3 newRootTip3 = MatrixUtilities::transformPoint(Vec3(effectiveL1, 0, 0), newRootWorld);
    const Vec2 tipNewOrigin(newRootTip3.x, newRootTip3.y);

    const Vec3 tipOldOrigin3 = MatrixUtilities::transformPoint(Vec3::zero(), tipWorld);
    const Vec2 tipOldOrigin(tipOldOrigin3.x, tipOldOrigin3.y);
    const Vec3 translation(tipNewOrigin.x - tipOldOrigin.x, tipNewOrigin.y - tipOldOrigin.y, 0);
    const Mat4 translated = MatrixUtilities::translation(translation) * tipWorld;
    const Mat4 newTipWorld = rotateMatrix(translated, Vec3(tipNewOrigin.x, tipNewOrigin.y, 0), tipDelta);
    worldMatrices[tipID] = newTipWorld;

    // The tip is a child of the root: cascading from the root would
    // recompose it from its local transform and discard the angle just
    // solved. Skip it here; its own descendants get the second cascade.
    const auto& childrenByParent = skeleton.childrenIndexForPropagation();
    ConstraintPropagation::cascade(rootID, tipID, skeleton, childrenByParent, worldMatrices);
    ConstraintPropagation::cascade(tipID, std::nullopt, skeleton, childrenByParent, worldMatrices);
}

void writeBackJoints(
    const std::vector<Uuid>& chain, const std::vector<Vec2>& joints, float mix,
    const Skeleton& skeleton, WorldMatrices& worldMatrices) {
    const auto& childrenByParent = skeleton.childrenIndexForPropagation();
    for (std::size_t i = 0; i < chain.size(); ++i) {
        const Uuid boneID = chain[i];
        auto oldWorldIt = worldMatrices.find(boneID);
        if (oldWorldIt == worldMatrices.end()) continue;
        const Mat4 oldWorld = oldWorldIt->second;
        const Vec3 oldOrigin3 = MatrixUtilities::transformPoint(Vec3::zero(), oldWorld);
        const Vec2 oldOrigin(oldOrigin3.x, oldOrigin3.y);
        const Vec2 newOrigin = joints[i];
        const Vec2 nextJoint = joints[i + 1];

        const Vec2 dir = nextJoint - newOrigin;
        if (!(lengthSquared(dir) > 0.000001f)) continue;
        const float desiredAngle = std::atan2(dir.y, dir.x);
        const float currentAngle = matrixRotationZ(oldWorld);
        const float deltaAngle = shortestAngleDelta(currentAngle, desiredAngle) * mix;

        const Vec2 blendedOrigin = oldOrigin + (newOrigin - oldOrigin) * mix;
        const Vec3 translation(blendedOrigin.x - oldOrigin.x, blendedOrigin.y - oldOrigin.y, 0);
        const Mat4 translated = MatrixUtilities::translation(translation) * oldWorld;
        const Mat4 rotated =
            rotateMatrix(translated, Vec3(blendedOrigin.x, blendedOrigin.y, 0), deltaAngle);
        worldMatrices[boneID] = rotated;
        ConstraintPropagation::cascade(boneID, std::nullopt, skeleton, childrenByParent, worldMatrices);
    }
}

void solveFABRIK(
    const std::vector<Uuid>& chain, Vec2 rawTarget, bool bendPositive, bool stretch, bool compress,
    float softness, float mix, const Skeleton& skeleton, WorldMatrices& worldMatrices) {
    const std::size_t n = chain.size();
    if (n < 2) return;

    std::vector<float> lengths;
    lengths.reserve(n);
    std::vector<Vec2> joints; // joints[i] = origin of bone[i]; joints[n] = tip of last bone.
    joints.reserve(n + 1);

    for (Uuid boneID : chain) {
        const Bone* bone = skeleton.bone(boneID);
        auto worldIt = worldMatrices.find(boneID);
        if (bone == nullptr || worldIt == worldMatrices.end()) return;
        const Vec3 origin = MatrixUtilities::transformPoint(Vec3::zero(), worldIt->second);
        joints.emplace_back(origin.x, origin.y);
        lengths.push_back(bone->length);
    }
    const Bone* lastBone = skeleton.bone(chain.back());
    auto lastWorldIt = worldMatrices.find(chain.back());
    if (lastBone == nullptr || lastWorldIt == worldMatrices.end()) return;
    const Vec3 lastTip = MatrixUtilities::transformPoint(Vec3(lastBone->length, 0, 0), lastWorldIt->second);
    joints.emplace_back(lastTip.x, lastTip.y);

    const Vec2 rootPos = joints[0];
    float totalLength = 0.0f;
    for (float l : lengths) totalLength += l;

    const Vec2 target = softenedTarget(rawTarget, rootPos, totalLength, softness);
    const Vec2 toTarget = target - rootPos;
    const float dist = length(toTarget);

    std::vector<float> workingLengths = lengths;
    if (dist > totalLength) {
        if (stretch && totalLength > 0.0001f) {
            const float scale = dist / totalLength;
            for (auto& l : workingLengths) l *= scale;
        } else {
            // Saturated: lay the chain straight at the target direction.
            const Vec2 dir = toTarget / std::max(dist, 0.0001f);
            Vec2 cursor = rootPos;
            joints[0] = cursor;
            for (std::size_t i = 0; i < n; ++i) {
                cursor = cursor + dir * lengths[i];
                joints[i + 1] = cursor;
            }
            writeBackJoints(chain, joints, mix, skeleton, worldMatrices);
            return;
        }
    }

    if (dist < 0.0001f) return; // Target at the root -- nothing to solve.

    // Bend-direction hint: nudge the chain's midpoint perpendicular to the
    // root->target line before iterating, FADED IN by lateral distance (not
    // a hard threshold switch -- see Data/IKSolver.swift's long comment on
    // why the previous all-or-nothing version produced a visible pop at
    // full extension).
    const std::size_t mid = (n + 1) / 2;
    if (joints.size() > mid) {
        const Vec2 along = toTarget / std::max(dist, 0.0001f);
        const Vec2 perp = Vec2(-along.y, along.x) * (bendPositive ? 1.0f : -1.0f);
        const Vec2 toMid = joints[mid] - rootPos;
        const float lateral = toMid.x * perp.x + toMid.y * perp.y;
        joints[mid] = joints[mid] + perp * std::max(0.0f, kBendHintReach - std::abs(lateral));
    }

    for (int iter = 0; iter < kFabrikMaxIterations; ++iter) {
        // Forward pass: place tip at target, drag joints back.
        joints[n] = target;
        for (std::size_t ri = n; ri-- > 0;) {
            const Vec2 dir = joints[ri] - joints[ri + 1];
            const float len = length(dir);
            if (!(len > 0.0001f)) continue;
            joints[ri] = joints[ri + 1] + (dir / len) * workingLengths[ri];
        }
        // Backward pass: place root, push joints forward.
        joints[0] = rootPos;
        for (std::size_t i = 0; i < n; ++i) {
            const Vec2 dir = joints[i + 1] - joints[i];
            const float len = length(dir);
            if (!(len > 0.0001f)) continue;
            joints[i + 1] = joints[i] + (dir / len) * workingLengths[i];
        }
        // NO EARLY TERMINATION, deliberately -- a fixed iteration count is
        // what makes the solve continuous in the target; see the long
        // comment in Data/IKSolver.swift.
    }

    (void)compress; // Swift: compress falls out of the forward/backward pass naturally here.

    writeBackJoints(chain, joints, mix, skeleton, worldMatrices);
}

} // namespace

void solve(const IKConstraint& constraint, const Skeleton& skeleton, WorldMatrices& worldMatrices) {
    if (!constraint.enabled_ || !(constraint.mix_ > 0.0001f)) return;
    if (constraint.boneChain.empty()) return;

    auto targetWorldIt = worldMatrices.find(constraint.targetBoneID);
    const Bone* targetBone = skeleton.bone(constraint.targetBoneID);
    if (targetWorldIt == worldMatrices.end() || targetBone == nullptr) return;

    const Vec3 tipLocal3(targetBone->length, 0, 0);
    const Vec3 tipWorld3 = MatrixUtilities::transformPoint(tipLocal3, targetWorldIt->second);
    const Vec2 target(tipWorld3.x, tipWorld3.y);
    const float mix = std::max(0.0f, std::min(1.0f, constraint.mix_));

    // Reject degenerate cases where the target bone is inside the chain.
    for (Uuid id : constraint.boneChain) {
        if (id == constraint.targetBoneID) return;
    }

    if (constraint.boneChain.size() == 1) {
        solveOneBone(constraint.boneChain[0], target, mix, skeleton, worldMatrices);
    } else if (constraint.boneChain.size() == 2) {
        solveTwoBone(
            constraint.boneChain[0], constraint.boneChain[1], target, constraint.bendPositive,
            constraint.stretch, constraint.compress, constraint.uniformScale, constraint.softness, mix,
            skeleton, worldMatrices);
    } else {
        solveFABRIK(
            constraint.boneChain, target, constraint.bendPositive, constraint.stretch,
            constraint.compress, constraint.softness, mix, skeleton, worldMatrices);
    }
}

} // namespace umeshcore::IKSolver

namespace umeshcore {

void IKConstraint::apply(const Skeleton& skeleton, WorldMatrices& worldMatrices) const {
    IKSolver::solve(*this, skeleton, worldMatrices);
}

} // namespace umeshcore
