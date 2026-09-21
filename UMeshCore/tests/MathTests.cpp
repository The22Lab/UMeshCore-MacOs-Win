// Golden-value tests for the Math module, hand-derived from the formulas in
// `Core/Transform3D2D.swift` / `Core/MatrixUtilities.swift` (not from the
// C++ port itself, so these actually catch transcription errors).

#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/MatrixUtilities.h"
#include "umeshcore/Math/Transform3D2D.h"
#include "umeshcore/Math/Vec.h"
#include "TestHarness.h"

using namespace umeshcore;

static void testIdentity() {
    const Mat4 id = Mat4::identity();
    const Vec4 v(3, 4, 5, 1);
    const Vec4 r = id * v;
    UM_CHECK(r == v);
}

static void testTranslation() {
    const Mat4 t = MatrixUtilities::translation(Vec3(1, 2, 3));
    const Vec3 r = MatrixUtilities::transformPoint(Vec3::zero(), t);
    UM_CHECK_NEAR(r.x, 1.0, 1e-6);
    UM_CHECK_NEAR(r.y, 2.0, 1e-6);
    UM_CHECK_NEAR(r.z, 3.0, 1e-6);
}

static void testScale() {
    const Mat4 s = MatrixUtilities::scale(Vec3(2, 3, 4));
    const Vec3 r = MatrixUtilities::transformPoint(Vec3(1, 1, 1), s);
    UM_CHECK_NEAR(r.x, 2.0, 1e-6);
    UM_CHECK_NEAR(r.y, 3.0, 1e-6);
    UM_CHECK_NEAR(r.z, 4.0, 1e-6);
}

static void testRotationZQuarterTurn() {
    // rotationZ(pi/2) sends +X to +Y: col0 = (cos, sin, 0, 0) = (0, 1, 0, 0).
    const Mat4 rz = MatrixUtilities::rotationZ(kPi / 2.0f);
    const Vec3 r = MatrixUtilities::transformPoint(Vec3(1, 0, 0), rz);
    UM_CHECK_NEAR(r.x, 0.0, 1e-5);
    UM_CHECK_NEAR(r.y, 1.0, 1e-5);
}

static void testMatrixMultiplyAssociativity() {
    const Mat4 a = MatrixUtilities::translation(Vec3(1, 0, 0));
    const Mat4 b = MatrixUtilities::rotationZ(kPi / 4.0f);
    const Vec4 v(1, 0, 0, 1);
    const Vec4 lhs = (a * b) * v;
    const Vec4 rhs = a * (b * v);
    UM_CHECK_NEAR(lhs.x, rhs.x, 1e-6);
    UM_CHECK_NEAR(lhs.y, rhs.y, 1e-6);
    UM_CHECK_NEAR(lhs.z, rhs.z, 1e-6);
}

static void testTransform3D2DPureTranslation() {
    Transform3D2D t;
    t.position = Vec3(5, 6, 7);
    const Mat4 m = t.matrix();
    const Vec3 r = MatrixUtilities::transformPoint(Vec3::zero(), m);
    UM_CHECK_NEAR(r.x, 5.0, 1e-5);
    UM_CHECK_NEAR(r.y, 6.0, 1e-5);
    UM_CHECK_NEAR(r.z, 7.0, 1e-5);
}

static void testShearedAxesIdentity() {
    const auto axes = MatrixUtilities::shearedAxes(0.0f, Vec2::zero(), Vec2::one());
    UM_CHECK_NEAR(axes.x.x, 1.0, 1e-6);
    UM_CHECK_NEAR(axes.x.y, 0.0, 1e-6);
    UM_CHECK_NEAR(axes.y.x, 0.0, 1e-6);
    UM_CHECK_NEAR(axes.y.y, 1.0, 1e-6);
}

static void testShearedWorldTransformIdentity() {
    const Vec2 r = MatrixUtilities::shearedWorldTransform(
        Vec2(1, 2), Vec2::zero(), 0.0f, Vec2::zero(), Vec2::one());
    UM_CHECK_NEAR(r.x, 1.0, 1e-6);
    UM_CHECK_NEAR(r.y, 2.0, 1e-6);
}

static void testShearedWorldRoundTrip() {
    const Vec2 position(10, -4);
    const float rotation = 37.0f;
    const Vec2 shear(8.0f, -5.0f);
    const Vec2 scale(1.5f, 0.75f);
    const Vec2 local(3.2f, -1.7f);
    const Vec2 world =
        MatrixUtilities::shearedWorldTransform(local, position, rotation, shear, scale);
    const Vec2 back =
        MatrixUtilities::shearedWorldInverse(world, position, rotation, shear, scale);
    UM_CHECK_NEAR(back.x, local.x, 1e-3);
    UM_CHECK_NEAR(back.y, local.y, 1e-3);
}

static void testDecomposeTransformRoundTrip() {
    const float rotationDeg = 30.0f;
    const Vec2 shear(5.0f, -3.0f);
    const Vec2 scale(2.0f, 1.5f);
    const auto axes = MatrixUtilities::shearedAxes(rotationDeg, shear, scale);
    const auto decomposed =
        MatrixUtilities::decomposeTransform(axes.x, axes.y, /*preservedSkewYDegrees=*/shear.y);
    UM_CHECK(decomposed.has_value());
    UM_CHECK_NEAR(decomposed->rotationRadians, rotationDeg * kPi / 180.0, 1e-3);
    UM_CHECK_NEAR(decomposed->scale.x, scale.x, 1e-3);
    UM_CHECK_NEAR(decomposed->scale.y, scale.y, 1e-3);
    UM_CHECK_NEAR(decomposed->skewDegrees.x, shear.x, 1e-2);
    UM_CHECK_NEAR(decomposed->skewDegrees.y, shear.y, 1e-6);
}

static void testShearedMatrixMatchesShearedWorldTransform() {
    const Vec2 position(4, -7);
    const float rotation = -20.0f;
    const Vec2 shear(2.0f, 1.0f);
    const Vec2 scale(1.2f, 0.9f);
    const Vec2 local(2.5f, 3.5f);

    const Vec2 viaVector =
        MatrixUtilities::shearedWorldTransform(local, position, rotation, shear, scale);
    const Mat4 m = MatrixUtilities::shearedMatrix(position, rotation, shear, scale);
    const Vec4 viaMatrix = m * Vec4(local.x, local.y, 0, 1);

    UM_CHECK_NEAR(viaVector.x, viaMatrix.x, 1e-4);
    UM_CHECK_NEAR(viaVector.y, viaMatrix.y, 1e-4);
}

static void testShearedMatrixInverseRoundTrip() {
    const Vec2 position(-3, 9);
    const float rotation = 55.0f;
    const Vec2 shear(-4.0f, 6.0f);
    const Vec2 scale(0.8f, 2.1f);

    const Mat4 m = MatrixUtilities::shearedMatrix(position, rotation, shear, scale);
    const auto inv = MatrixUtilities::shearedMatrixInverse(position, rotation, shear, scale);
    UM_CHECK(inv.has_value());

    const Vec4 p(6, -2, 0, 1);
    const Vec4 world = m * p;
    const Vec4 back = (*inv) * world;
    UM_CHECK_NEAR(back.x, p.x, 1e-3);
    UM_CHECK_NEAR(back.y, p.y, 1e-3);
}

UM_TEST_MAIN_BEGIN()
    testIdentity();
    testTranslation();
    testScale();
    testRotationZQuarterTurn();
    testMatrixMultiplyAssociativity();
    testTransform3D2DPureTranslation();
    testShearedAxesIdentity();
    testShearedWorldTransformIdentity();
    testShearedWorldRoundTrip();
    testDecomposeTransformRoundTrip();
    testShearedMatrixMatchesShearedWorldTransform();
    testShearedMatrixInverseRoundTrip();
UM_TEST_MAIN_END()
