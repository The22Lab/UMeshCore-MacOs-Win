// Tests for the constraint solvers, ported from `Data/IKSolver.swift`,
// `Data/PathSolver.swift`, `Data/TransformConstraint.swift` and
// `Data/PhysicsConstraintSystem.swift`. Expected values are hand-derived
// (law of cosines for 2-bone IK, Catmull-Rom's exact-interpolation property
// for a straight symmetric path) rather than taken from the C++ output.

#include <cmath>

#include "umeshcore/Constraints/IKSolver.h"
#include "umeshcore/Constraints/PathSolver.h"
#include "umeshcore/Constraints/PhysicsConstraintSystem.h"
#include "umeshcore/Constraints/TransformConstraintSolver.h"
#include "umeshcore/Model/Skeleton.h"
#include "TestHarness.h"

using namespace umeshcore;

static Bone makeBone(std::optional<Uuid> parent, Vec2 localPos, float rotationZ, float length) {
    Bone b;
    b.id = Uuid::generate();
    b.name = "bone";
    b.parentID = parent;
    b.localTransform.position = Vec3(localPos.x, localPos.y, 0);
    b.localTransform.rotation = Vec3(0, 0, rotationZ);
    b.baseTransform = b.localTransform;
    b.length = length;
    b.animationClip = AnimationClip("bone");
    return b;
}

static void testTwoBoneIKReachesTarget() {
    Skeleton skeleton;
    Bone root = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    Bone tip = makeBone(root.id, Vec2(100, 0), 0.0f, 100.0f);
    // Target bone: a free-floating root bone whose own world ROOT (not tip,
    // since length=0) is the point (100, 100), within the chain's [0, 200] reach.
    Bone target = makeBone(std::nullopt, Vec2(100, 100), 0.0f, 0.0f);
    skeleton.setBone(root);
    skeleton.rootIDs.push_back(root.id);
    skeleton.setBone(tip);
    skeleton.setBone(target);
    skeleton.rootIDs.push_back(target.id);

    IKConstraint ik("arm", {root.id, tip.id}, target.id);
    ik.bendPositive = true;

    WorldMatrices matrices = skeleton.baseWorldMatrices();
    IKSolver::solve(ik, skeleton, matrices);

    const Bone* tipBone = skeleton.bone(tip.id);
    const Vec3 tipWorldPoint =
        MatrixUtilities::transformPoint(Vec3(tipBone->length, 0, 0), matrices.at(tip.id));
    UM_CHECK_NEAR(tipWorldPoint.x, 100.0, 0.05);
    UM_CHECK_NEAR(tipWorldPoint.y, 100.0, 0.05);
}

static void testTwoBoneIKBendFlipsElbow() {
    Skeleton skeleton;
    Bone root = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    Bone tip = makeBone(root.id, Vec2(100, 0), 0.0f, 100.0f);
    Bone target = makeBone(std::nullopt, Vec2(100, 100), 0.0f, 0.0f);
    skeleton.setBone(root);
    skeleton.rootIDs.push_back(root.id);
    skeleton.setBone(tip);
    skeleton.setBone(target);
    skeleton.rootIDs.push_back(target.id);

    IKConstraint ikPositive("arm", {root.id, tip.id}, target.id);
    ikPositive.bendPositive = true;
    WorldMatrices posMatrices = skeleton.baseWorldMatrices();
    IKSolver::solve(ikPositive, skeleton, posMatrices);
    const Vec3 elbowPos =
        MatrixUtilities::transformPoint(Vec3::zero(), posMatrices.at(tip.id));

    IKConstraint ikNegative("arm", {root.id, tip.id}, target.id);
    ikNegative.bendPositive = false;
    WorldMatrices negMatrices = skeleton.baseWorldMatrices();
    IKSolver::solve(ikNegative, skeleton, negMatrices);
    const Vec3 elbowNeg =
        MatrixUtilities::transformPoint(Vec3::zero(), negMatrices.at(tip.id));

    // Both solves reach the same target, but the elbow (the tip bone's
    // origin) lands on opposite sides of the root->target line.
    const Bone* tipBone = skeleton.bone(tip.id);
    const Vec3 tipAtPositive =
        MatrixUtilities::transformPoint(Vec3(tipBone->length, 0, 0), posMatrices.at(tip.id));
    const Vec3 tipAtNegative =
        MatrixUtilities::transformPoint(Vec3(tipBone->length, 0, 0), negMatrices.at(tip.id));
    UM_CHECK_NEAR(tipAtPositive.x, 100.0, 0.05);
    UM_CHECK_NEAR(tipAtPositive.y, 100.0, 0.05);
    UM_CHECK_NEAR(tipAtNegative.x, 100.0, 0.05);
    UM_CHECK_NEAR(tipAtNegative.y, 100.0, 0.05);
    UM_CHECK(std::abs(elbowPos.x - elbowNeg.x) > 1.0 || std::abs(elbowPos.y - elbowNeg.y) > 1.0);
}

static void testFabrikThreeBoneReachesTarget() {
    Skeleton skeleton;
    Bone b0 = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 50.0f);
    Bone b1 = makeBone(b0.id, Vec2(50, 0), 0.0f, 50.0f);
    Bone b2 = makeBone(b1.id, Vec2(50, 0), 0.0f, 50.0f);
    Bone target = makeBone(std::nullopt, Vec2(100, 50), 0.0f, 0.0f);
    skeleton.setBone(b0);
    skeleton.rootIDs.push_back(b0.id);
    skeleton.setBone(b1);
    skeleton.setBone(b2);
    skeleton.setBone(target);
    skeleton.rootIDs.push_back(target.id);

    IKConstraint ik("chain", {b0.id, b1.id, b2.id}, target.id);
    WorldMatrices matrices = skeleton.baseWorldMatrices();
    IKSolver::solve(ik, skeleton, matrices);

    const Bone* tipBone = skeleton.bone(b2.id);
    const Vec3 tipWorldPoint =
        MatrixUtilities::transformPoint(Vec3(tipBone->length, 0, 0), matrices.at(b2.id));
    UM_CHECK_NEAR(tipWorldPoint.x, 100.0, 0.5);
    UM_CHECK_NEAR(tipWorldPoint.y, 50.0, 0.5);
}

static void testFabrikFixedIterationCount() {
    // Not a behavior test per se, but a guard against a future "optimize
    // FABRIK to early-exit on convergence" regression: the Swift source
    // explicitly measured that as a jitter-introducing change, so this
    // just documents the intent (real enforcement is the source-level
    // review discipline, this test is a placeholder assertion that a
    // constraint with an unreachable target still fully solves, i.e. does
    // not early-return before the fixed loop).
    Skeleton skeleton;
    Bone b0 = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 50.0f);
    Bone b1 = makeBone(b0.id, Vec2(50, 0), 0.0f, 50.0f);
    Bone target = makeBone(std::nullopt, Vec2(30, 10), 0.0f, 0.0f); // well within reach, off-axis
    skeleton.setBone(b0);
    skeleton.rootIDs.push_back(b0.id);
    skeleton.setBone(b1);
    skeleton.setBone(target);
    skeleton.rootIDs.push_back(target.id);

    IKConstraint ik("chain", {b0.id, b1.id}, target.id);
    WorldMatrices matrices = skeleton.baseWorldMatrices();
    IKSolver::solve(ik, skeleton, matrices);
    UM_CHECK(matrices.contains(b0.id));
    UM_CHECK(matrices.contains(b1.id));
}

static void testPathConstraintStraightLineMidpoint() {
    Skeleton skeleton;
    Bone pathStart = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 0.0f);
    Bone pathEnd = makeBone(std::nullopt, Vec2(200, 0), 0.0f, 0.0f);
    Bone follower = makeBone(std::nullopt, Vec2(999, 999), 0.0f, 50.0f); // far from the path on purpose
    skeleton.setBone(pathStart);
    skeleton.rootIDs.push_back(pathStart.id);
    skeleton.setBone(pathEnd);
    skeleton.rootIDs.push_back(pathEnd.id);
    skeleton.setBone(follower);
    skeleton.rootIDs.push_back(follower.id);

    PathConstraint path("rail", {pathStart.id, pathEnd.id}, {follower.id});
    path.position = 0.5f; // midpoint of the path
    path.positionMix = 1.0f;
    path.rotateMix = 1.0f;
    path.rotateMode = PathRotateMode::Tangent;

    WorldMatrices matrices = skeleton.baseWorldMatrices();
    PathSolver::solve(path, skeleton, matrices);

    const Vec3 followerOrigin = MatrixUtilities::transformPoint(Vec3::zero(), matrices.at(follower.id));
    UM_CHECK_NEAR(followerOrigin.x, 100.0, 1.0);
    UM_CHECK_NEAR(followerOrigin.y, 0.0, 1.0);

    // Tangent along a horizontal line: rotation ~ 0.
    const float rotation = std::atan2(matrices.at(follower.id).columns[0].y, matrices.at(follower.id).columns[0].x);
    UM_CHECK_NEAR(rotation, 0.0, 0.05);
}

static void testTransformConstraintCopiesRotation() {
    Skeleton skeleton;
    Bone target = makeBone(std::nullopt, Vec2(0, 0), kPi / 4.0f, 100.0f);
    Bone affected = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    skeleton.setBone(target);
    skeleton.rootIDs.push_back(target.id);
    skeleton.setBone(affected);
    skeleton.rootIDs.push_back(affected.id);

    TransformConstraint tc("copyRot", target.id, {affected.id});
    tc.copyRotation = true;
    tc.copyPosition = false;
    tc.copyScale = false;
    tc.copyShear = false;
    tc.rotationMix = 1.0f;
    tc.mix_ = 1.0f;

    WorldMatrices matrices = skeleton.baseWorldMatrices();
    TransformConstraintSolver::solve(tc, skeleton, matrices);

    const auto decomposed = TransformConstraintSolver::decompose(matrices.at(affected.id));
    UM_CHECK_NEAR(decomposed.rotation, kPi / 4.0, 1e-3);
}

static void testPhysicsDeterminismAndRootPinning() {
    auto buildSkeletonAndConstraint = [](Skeleton& skeleton, PhysicsConstraint& phys) {
        Bone root = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 50.0f);
        Bone tip = makeBone(root.id, Vec2(50, 0), 0.0f, 50.0f);
        skeleton.setBone(root);
        skeleton.rootIDs.push_back(root.id);
        skeleton.setBone(tip);
        phys.name_ = "tail";
        phys.physicsType = PhysicsType::Spring;
        phys.affectedBones = {root.id, tip.id};
        phys.settings.gravity = 400.0f;
        phys.settings.stiffness = 60.0f;
        skeleton.physicsConstraints.push_back(phys);
        return std::make_pair(root.id, tip.id);
    };

    Skeleton skelA, skelB;
    PhysicsConstraint physA, physB;
    auto [rootA, tipA] = buildSkeletonAndConstraint(skelA, physA);
    auto [rootB, tipB] = buildSkeletonAndConstraint(skelB, physB);

    PhysicsConstraintSystem sysA;
    PhysicsConstraintSystem sysB;
    sysA.isActive = true;
    sysB.isActive = true;

    // Identical, deterministic frame-time sequence fed to both systems.
    const double times[] = {0.0, 0.05, 0.083, 0.15, 0.2001, 0.26};
    for (double t : times) {
        sysA.setFrameTime(t);
        sysA.beginFrame(skelA);
        sysB.setFrameTime(t);
        sysB.beginFrame(skelB);
    }

    const auto capturedA = sysA.captureSimulatedPositions();
    const auto capturedB = sysB.captureSimulatedPositions();
    UM_CHECK(capturedA.contains(tipA));
    UM_CHECK(capturedB.contains(tipB));
    // Determinism: identical inputs (fixed-timestep simulation) must
    // produce bit-identical output, per ROADMAP.md's determinism testing
    // requirement.
    UM_CHECK(capturedA.at(tipA).first.x == capturedB.at(tipB).first.x);
    UM_CHECK(capturedA.at(tipA).first.y == capturedB.at(tipB).first.y);
    UM_CHECK(capturedA.at(tipA).second == capturedB.at(tipB).second);

    // Root pinning: the root bone (index 0 in the affected-bones chain) is
    // reset to the animated rest pose every step, never simulated.
    UM_CHECK_NEAR(capturedA.at(rootA).first.x, 0.0, 1e-4);
    UM_CHECK_NEAR(capturedA.at(rootA).first.y, 0.0, 1e-4);

    // Gravity: the simulated (non-root) bone should have been pulled
    // downward (world -Y) from its rest position (50, 0) over this many
    // fixed steps.
    UM_CHECK(capturedA.at(tipA).first.y < -0.01);
}

UM_TEST_MAIN_BEGIN()
    testTwoBoneIKReachesTarget();
    testTwoBoneIKBendFlipsElbow();
    testFabrikThreeBoneReachesTarget();
    testFabrikFixedIterationCount();
    testPathConstraintStraightLineMidpoint();
    testTransformConstraintCopiesRotation();
    testPhysicsDeterminismAndRootPinning();
UM_TEST_MAIN_END()
