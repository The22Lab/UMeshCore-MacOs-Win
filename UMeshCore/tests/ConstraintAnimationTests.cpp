// Tests for ConstraintAnimation.h, ported from `Data/ConstraintAnimation.swift`.
// Expected values are hand-derived from the property tables in that file
// (constraintScalar/setConstraintScalar's per-kind switch statements), not
// from this file's own output.

#include "umeshcore/Constraints/ConstraintAnimation.h"
#include "TestHarness.h"

using namespace umeshcore;

static void testConstraintKindIdentifiesEachStore() {
    Skeleton skeleton;
    IKConstraint ik;
    TransformConstraint transform;
    PathConstraint path;
    PhysicsConstraint physics;
    skeleton.ikConstraints.push_back(ik);
    skeleton.transformConstraints.push_back(transform);
    skeleton.pathConstraints.push_back(path);
    skeleton.physicsConstraints.push_back(physics);

    UM_CHECK(constraintKind(skeleton, ik.id_) == ConstraintKind::Ik);
    UM_CHECK(constraintKind(skeleton, transform.id_) == ConstraintKind::Transform);
    UM_CHECK(constraintKind(skeleton, path.id_) == ConstraintKind::Path);
    UM_CHECK(constraintKind(skeleton, physics.id_) == ConstraintKind::Physics);
    UM_CHECK(!constraintKind(skeleton, Uuid::generate()).has_value());
}

static void testScalarAccessRoutesByConstraintKind() {
    Skeleton skeleton;
    TransformConstraint transform;
    transform.mix_ = 0.5f;
    transform.rotationMix = 0.25f;
    skeleton.transformConstraints.push_back(transform);

    UM_CHECK_NEAR(*constraintScalar(skeleton, transform.id_, AnimationTrackProperty::ConstraintMix), 0.5, 1e-5);
    UM_CHECK_NEAR(
        *constraintScalar(skeleton, transform.id_, AnimationTrackProperty::TransformRotateMix), 0.25, 1e-5);
    // A property this constraint kind doesn't expose.
    UM_CHECK(!constraintScalar(skeleton, transform.id_, AnimationTrackProperty::PhysicsMass).has_value());
}

static void testSetConstraintScalarClampsToPropertyRange() {
    Skeleton skeleton;
    TransformConstraint transform;
    skeleton.transformConstraints.push_back(transform);

    // ConstraintMix's range is [0, 1] (see AnimationTrackProperty::valueRange).
    setConstraintScalar(skeleton, transform.id_, AnimationTrackProperty::ConstraintMix, 5.0f);
    UM_CHECK_NEAR(skeleton.transformConstraints[0].mix_, 1.0, 1e-5);

    setConstraintScalar(skeleton, transform.id_, AnimationTrackProperty::ConstraintMix, -5.0f);
    UM_CHECK_NEAR(skeleton.transformConstraints[0].mix_, 0.0, 1e-5);
}

static void testSetConstraintScalarFloorsPhysicsMass() {
    Skeleton skeleton;
    PhysicsConstraint physics;
    skeleton.physicsConstraints.push_back(physics);

    // Mass is floored at 0.0001 regardless of the animated value, so the
    // simulation never divides by (near-)zero mass.
    setConstraintScalar(skeleton, physics.id_, AnimationTrackProperty::PhysicsMass, 0.0f);
    UM_CHECK(skeleton.physicsConstraints[0].settings.mass >= 0.0001f);
}

static void testFlagAccessOnlyAppliesToIK() {
    Skeleton skeleton;
    IKConstraint ik;
    ik.bendPositive = true;
    skeleton.ikConstraints.push_back(ik);

    UM_CHECK(*constraintFlag(skeleton, ik.id_, AnimationTrackProperty::IkBendPositive) == true);
    setConstraintFlag(skeleton, ik.id_, AnimationTrackProperty::IkStretch, true);
    UM_CHECK(skeleton.ikConstraints[0].stretch == true);
}

static void testVectorAccessOnlyAppliesToPhysicsWind() {
    Skeleton skeleton;
    PhysicsConstraint physics;
    skeleton.physicsConstraints.push_back(physics);

    setConstraintVector(skeleton, physics.id_, AnimationTrackProperty::PhysicsWind, Vec2(3, -4));
    const auto wind = constraintVector(skeleton, physics.id_, AnimationTrackProperty::PhysicsWind);
    UM_CHECK(wind.has_value());
    UM_CHECK_NEAR(wind->x, 3.0, 1e-5);
    UM_CHECK_NEAR(wind->y, -4.0, 1e-5);

    // A property that isn't PhysicsWind is never vector-typed for this kind.
    UM_CHECK(!constraintVector(skeleton, physics.id_, AnimationTrackProperty::PhysicsMass).has_value());
}

static void testSetupSnapshotRoundTripsThroughApply() {
    Skeleton skeleton;
    PathConstraint path;
    path.mix_ = 0.7f;
    path.position = 0.3f;
    path.spacing = 42.0f;
    path.positionMix = 0.6f;
    path.rotateMix = 0.9f;
    skeleton.pathConstraints.push_back(path);

    const ConstraintSetupValues captured = captureConstraintSetupValues(skeleton, path.id_);

    // Mutate the live constraint away from its captured values.
    skeleton.pathConstraints[0].mix_ = 0.0f;
    skeleton.pathConstraints[0].position = 0.0f;
    skeleton.pathConstraints[0].spacing = 0.0f;

    applyConstraintSetupValues(skeleton, path.id_, captured);

    UM_CHECK_NEAR(skeleton.pathConstraints[0].mix_, 0.7, 1e-5);
    UM_CHECK_NEAR(skeleton.pathConstraints[0].position, 0.3, 1e-5);
    UM_CHECK_NEAR(skeleton.pathConstraints[0].spacing, 42.0, 1e-4);
    UM_CHECK_NEAR(skeleton.pathConstraints[0].positionMix, 0.6, 1e-5);
    UM_CHECK_NEAR(skeleton.pathConstraints[0].rotateMix, 0.9, 1e-5);
}

UM_TEST_MAIN_BEGIN()
    testConstraintKindIdentifiesEachStore();
    testScalarAccessRoutesByConstraintKind();
    testSetConstraintScalarClampsToPropertyRange();
    testSetConstraintScalarFloorsPhysicsMass();
    testFlagAccessOnlyAppliesToIK();
    testVectorAccessOnlyAppliesToPhysicsWind();
    testSetupSnapshotRoundTripsThroughApply();
UM_TEST_MAIN_END()
