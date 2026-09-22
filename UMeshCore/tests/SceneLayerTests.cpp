// Tests for Scene/SceneLayer.h and Scene/SceneMaterial.h, ported from
// `Data/Scene/SceneLayer.swift` and `Data/Scene/SceneMaterial.swift`.
//
// Both Swift files state their contracts as properties with a bug behind
// each one, so these assert the properties rather than re-running the
// formulas:
//
//   - `orientation()` is a ROTATION even for a sheared card. The gizmo bug
//     that split it from `planePoint` was exactly a frame whose vectors
//     had the right lengths and the wrong angle between them, so length
//     alone does not catch it -- orthogonality does.
//   - `planePoint` shears in SCALED units, which is the term that
//     distinguishes the right order from the plausible wrong one.
//   - `liftToWorld` is orthonormal, which is what lets the card's corners
//     and the gizmo's frame share it.
//   - `lightingTangent` reads only the SIGN of the scale, so a card
//     stretched 3x lights identically and a mirrored one does not.
//   - `rigFrame` wraps into the clip from either direction, which is where
//     Swift's sign-preserving `%` would otherwise index backwards.
//   - A flat material leaves every material path untaken -- the bit-for-bit
//     promise, checked as an equality with the default rather than as a
//     list of fields, so a field added later cannot quietly escape it.

#include "umeshcore/Scene/SceneLayer.h"

#include <cmath>
#include <limits>

#include "umeshcore/Math/MatrixUtilities.h"

#include "TestHarness.h"

using namespace umeshcore;

namespace {

SceneLayer plate() {
    SceneLayer layer;
    layer.id = Uuid(1, 1);
    layer.name = "plate";
    layer.content = ScenePlateContent{Uuid(2, 2)};
    return layer;
}

SceneLayer rig(float speed, int startFrame, bool loops) {
    SceneLayer layer = plate();
    layer.content = SceneRigContent{Uuid(3, 3), speed, startFrame, loops};
    return layer;
}

bool nearlyEqual(float a, float b, float eps) { return std::fabs(a - b) <= eps; }

} // namespace

// ---- planePoint: scale, then shear, then roll ----

static void testShearIsExpressedInScaledUnits() {
    // THE ORDER IS THE DEFINITION. With scale 2 and shear.x = 0.5, the
    // point (0,1) scales to (0,2) and then slants by 0.5 * 2 = 1. The
    // plausible wrong order -- shear the local point first, then scale --
    // would slant it by 0.5 and then scale that to 1 as well for THIS
    // point, so the test uses a non-uniform scale where the two differ.
    SceneLayer layer = plate();
    layer.scale = Vec2(2.0f, 4.0f);
    layer.shear = Vec2(0.5f, 0.0f);
    const Vec2 p = layer.planePoint(Vec2(0.0f, 1.0f));
    // sy = 4, hx = 0 + 4 * 0.5 = 2, hy = 4.
    UM_CHECK_NEAR(p.x, 2.0, 1e-5);
    UM_CHECK_NEAR(p.y, 4.0, 1e-5);
    // Shearing before the scale would have given hx = 0.5 * 2 = 1.
    UM_CHECK(!nearlyEqual(p.x, 1.0f, 1e-3f));
}

static void testRollComesAfterTheShear() {
    SceneLayer layer = plate();
    layer.shear = Vec2(1.0f, 0.0f);
    layer.rotation = kPi / 2.0f;
    // (0,1) -> shear -> (1,1) -> roll 90 deg -> (-1,1).
    const Vec2 p = layer.planePoint(Vec2(0.0f, 1.0f));
    UM_CHECK_NEAR(p.x, -1.0, 1e-5);
    UM_CHECK_NEAR(p.y, 1.0, 1e-5);
}

static void testIdentityLayerLeavesAPointAlone() {
    const Vec2 p = plate().planePoint(Vec2(3.0f, -7.0f));
    UM_CHECK_NEAR(p.x, 3.0, 1e-6);
    UM_CHECK_NEAR(p.y, -7.0, 1e-6);
}

// ---- liftToWorld: linear and orthonormal ----

static void testLiftPreservesLengthsAndAngles() {
    SceneLayer layer = plate();
    layer.rotation3D = Vec3(0.4f, -0.9f, 0.0f);
    const Vec3 a = layer.liftToWorld(Vec2(1.0f, 0.0f));
    const Vec3 b = layer.liftToWorld(Vec2(0.0f, 1.0f));
    UM_CHECK_NEAR(length(a), 1.0, 1e-5);
    UM_CHECK_NEAR(length(b), 1.0, 1e-5);
    UM_CHECK_NEAR(dot(a, b), 0.0, 1e-5);
    // Linear: the lift of a sum is the sum of the lifts.
    const Vec3 sum = layer.liftToWorld(Vec2(2.0f, -3.0f));
    const Vec3 combined = a * 2.0f + b * -3.0f;
    UM_CHECK_NEAR(sum.x, combined.x, 1e-5);
    UM_CHECK_NEAR(sum.y, combined.y, 1e-5);
    UM_CHECK_NEAR(sum.z, combined.z, 1e-5);
}

static void testUntiltedLiftIsTheIdentityPlane() {
    const Vec3 v = plate().liftToWorld(Vec2(5.0f, 9.0f));
    UM_CHECK_NEAR(v.x, 5.0, 1e-6);
    UM_CHECK_NEAR(v.y, 9.0, 1e-6);
    UM_CHECK_NEAR(v.z, 0.0, 1e-6);
}

// ---- orientation(): a rotation, even when the card is not ----

static void testOrientationStaysARotationUnderShearAndScale() {
    // The bug this split exists for: a frame differenced off `planePoint`
    // has the shear in it, and normalising its vectors fixes their lengths
    // while leaving the angle between them wrong. So check the ANGLE.
    SceneLayer layer = plate();
    layer.shear = Vec2(0.8f, -0.3f);
    layer.scale = Vec2(3.0f, 0.25f);
    layer.rotation = 0.7f;
    layer.rotation3D = Vec3(0.5f, 1.1f, 0.0f);
    const SceneLayerOrientation axes = layer.orientation();

    UM_CHECK_NEAR(length(axes.x), 1.0, 1e-5);
    UM_CHECK_NEAR(length(axes.y), 1.0, 1e-5);
    UM_CHECK_NEAR(length(axes.z), 1.0, 1e-5);
    UM_CHECK_NEAR(dot(axes.x, axes.y), 0.0, 1e-5);
    UM_CHECK_NEAR(dot(axes.x, axes.z), 0.0, 1e-5);
    UM_CHECK_NEAR(dot(axes.y, axes.z), 0.0, 1e-5);
    // Right-handed: z is x cross y, so x cross y dotted with z is +1.
    UM_CHECK_NEAR(dot(cross(axes.x, axes.y), axes.z), 1.0, 1e-5);
}

static void testOrientationIgnoresScaleAndShearEntirely() {
    // Same rotation, wildly different card: the frames must be identical,
    // which is the property `planePoint` cannot have.
    SceneLayer plain = plate();
    plain.rotation = 0.4f;
    plain.rotation3D = Vec3(-0.2f, 0.6f, 0.0f);
    SceneLayer squashed = plain;
    squashed.scale = Vec2(12.0f, 0.05f);
    squashed.shear = Vec2(-1.7f, 2.4f);

    const SceneLayerOrientation a = plain.orientation();
    const SceneLayerOrientation b = squashed.orientation();
    UM_CHECK_NEAR(a.x.x, b.x.x, 1e-6);
    UM_CHECK_NEAR(a.x.y, b.x.y, 1e-6);
    UM_CHECK_NEAR(a.x.z, b.x.z, 1e-6);
    UM_CHECK_NEAR(a.z.x, b.z.x, 1e-6);
    UM_CHECK_NEAR(a.z.y, b.z.y, 1e-6);
    UM_CHECK_NEAR(a.z.z, b.z.z, 1e-6);
}

static void testUntiltedLayerFacesTheCamera() {
    // Looking down +Z, an untilted card's normal is +Z. If this came back
    // -Z every light in the set would be behind every card.
    const SceneLayer::Plane plane = plate().lightingPlane();
    UM_CHECK_NEAR(plane.normal.x, 0.0, 1e-6);
    UM_CHECK_NEAR(plane.normal.y, 0.0, 1e-6);
    UM_CHECK_NEAR(plane.normal.z, 1.0, 1e-6);
}

static void testLightingPlanePassesThroughTheLayerOrigin() {
    SceneLayer layer = plate();
    layer.position = Vec2(120.0f, -45.0f);
    layer.positionZ = 300.0f;
    const SceneLayer::Plane plane = layer.lightingPlane();
    UM_CHECK_NEAR(plane.point.x, 120.0, 1e-6);
    UM_CHECK_NEAR(plane.point.y, -45.0, 1e-6);
    UM_CHECK_NEAR(plane.point.z, 300.0, 1e-6);
}

// ---- lightingTangent: the sign of the scale, never its size ----

static void testTangentReadsOnlyTheSignOfTheScale() {
    SceneLayer wide = plate();
    wide.rotation = 0.3f;
    wide.scale = Vec2(3.0f, 1.0f);
    SceneLayer unit = wide;
    unit.scale = Vec2(1.0f, 1.0f);
    // Relief does not stretch with the card: a bump on a 3x-wide card
    // still lights round.
    const SceneLayer::Tangent a = wide.lightingTangent();
    const SceneLayer::Tangent b = unit.lightingTangent();
    UM_CHECK_NEAR(a.tangent.x, b.tangent.x, 1e-6);
    UM_CHECK_NEAR(a.tangent.y, b.tangent.y, 1e-6);
    UM_CHECK_NEAR(a.handed, 1.0, 1e-6);
}

static void testMirroredCardFlipsTangentAndHandedness() {
    SceneLayer mirrored = plate();
    mirrored.scale = Vec2(-1.0f, 1.0f);
    const SceneLayer::Tangent t = mirrored.lightingTangent();
    // Image +x points the other way...
    UM_CHECK_NEAR(t.tangent.x, -1.0, 1e-6);
    // ...and the bitangent's handedness says so, which is what stops the
    // relief being lit from the wrong side.
    UM_CHECK_NEAR(t.handed, -1.0, 1e-6);

    SceneLayer both = plate();
    both.scale = Vec2(-2.0f, -0.5f);
    // Two flips is no flip: handedness is sign(scale.x * scale.y).
    UM_CHECK_NEAR(both.lightingTangent().handed, 1.0, 1e-6);
}

static void testZeroScaleKeepsTheUnmirroredReading() {
    // `sign` of zero is zero, and a frame multiplied by zero is not a
    // frame. A flattened card keeps the reading it had before.
    SceneLayer flat = plate();
    flat.scale = Vec2(0.0f, 0.0f);
    const SceneLayer::Tangent t = flat.lightingTangent();
    UM_CHECK_NEAR(t.tangent.x, 1.0, 1e-6);
    UM_CHECK_NEAR(t.handed, 1.0, 1e-6);
}

// ---- rigFrame ----

static void testRigFrameIsNilForAnythingButARig() {
    UM_CHECK(!plate().rigFrame(10, 60).has_value());
    SceneLayer fill = plate();
    fill.content = SceneFillContent{SceneFill::neutral()};
    UM_CHECK(!fill.rigFrame(10, 60).has_value());
}

static void testRigFrameAdvancesAndLoops() {
    const SceneLayer layer = rig(1.0f, 0, true);
    UM_CHECK(layer.rigFrame(0, 60) == 0);
    UM_CHECK(layer.rigFrame(59, 60) == 59);
    UM_CHECK(layer.rigFrame(60, 60) == 0);
    UM_CHECK(layer.rigFrame(61, 60) == 1);
}

static void testRigFrameWrapsFromBelowZero() {
    // Swift's `%` keeps the sign of the dividend and so does C++'s, which
    // is why the port has to add the duration back rather than trusting a
    // modulo to be positive. A negative speed is the case that finds it.
    const SceneLayer layer = rig(-1.0f, 0, true);
    UM_CHECK(layer.rigFrame(1, 60) == 59);
    UM_CHECK(layer.rigFrame(61, 60) == 59);
    const SceneLayer fromNegativeStart = rig(1.0f, -5, true);
    UM_CHECK(fromNegativeStart.rigFrame(0, 60) == 55);
}

static void testRigFrameClampsWhenItDoesNotLoop() {
    const SceneLayer layer = rig(1.0f, 0, false);
    UM_CHECK(layer.rigFrame(1000, 60) == 59);
    const SceneLayer backwards = rig(-1.0f, 0, false);
    UM_CHECK(backwards.rigFrame(1000, 60) == 0);
}

static void testZeroSpeedFreezesOnTheStartFrame() {
    // Rather than dividing the timeline by nothing.
    const SceneLayer layer = rig(0.0f, 17, true);
    UM_CHECK(layer.rigFrame(0, 60) == 17);
    UM_CHECK(layer.rigFrame(9999, 60) == 17);
}

static void testEmptyClipReturnsTheStartFrameUntouched() {
    const SceneLayer layer = rig(2.0f, 12, true);
    UM_CHECK(layer.rigFrame(30, 0) == 12);
    UM_CHECK(layer.rigFrame(30, -4) == 12);
}

static void testNonFiniteSpeedDoesNotReachTheIntCast() {
    // Swift traps here and C++ would be undefined; the port saturates, so
    // a corrupt file gives a frame inside the clip instead of anything.
    const SceneLayer layer = rig(std::numeric_limits<float>::quiet_NaN(), 0, true);
    const auto frame = layer.rigFrame(30, 60);
    UM_CHECK(frame.has_value());
    if (frame) UM_CHECK(*frame >= 0 && *frame < 60);
}

// ---- SceneFill ----

static void testNeutralFillIsAGreyRampNotAFlatColour() {
    const SceneFill fill = SceneFill::neutral();
    UM_CHECK(!fill.isFlat());
    // Grey: all three channels equal at both stops, so nothing on the set
    // is judged against a tint.
    UM_CHECK_NEAR(fill.topColor.x, fill.topColor.y, 1e-6);
    UM_CHECK_NEAR(fill.topColor.y, fill.topColor.z, 1e-6);
    UM_CHECK(SceneFill::solid(Vec4(1, 0, 0, 1)).isFlat());
}

static void testFillContentIsTheAtmosphereCase() {
    UM_CHECK(isFill(SceneLayerContent{SceneFillContent{SceneFill::neutral()}}));
    UM_CHECK(!isFill(SceneLayerContent{ScenePlateContent{Uuid(1, 1)}}));
    UM_CHECK(!isFill(SceneLayerContent{SceneRigContent{}}));
}

// ---- SceneMaterial ----

static void testFlatMaterialIsTheDefaultInEveryField() {
    // The bit-for-bit promise, asserted as equality with a freshly
    // defaulted material rather than field by field: a field added later
    // cannot escape this check by not being listed.
    UM_CHECK(isFlat(sceneMaterialFlat()));
    UM_CHECK(sceneMaterialFlat() == SceneMaterial{});
    // And the things a flat surface must not have.
    UM_CHECK(!sceneMaterialFlat().normalMapAssetId.has_value());
    UM_CHECK(sceneMaterialFlat().parallaxMode == SceneParallaxMode::Off);
    UM_CHECK(sceneMaterialFlat().shadowCastMask.isEmpty());
}

static void testAnyChangeLeavesTheFlatPath() {
    SceneMaterial m = sceneMaterialFlat();
    m.smoothness = 0.001f;
    UM_CHECK(!isFlat(m));
}

static void testSanitizeClampsTheShadersBranchesIntoRange() {
    SceneMaterial m;
    m.normalStrength = -3.0f;
    m.smoothness = 2.5f;
    m.contrast = -0.1f;
    m.parallaxDepth = 9.0f;
    m.parallaxQuality = -1.0f;
    m.parallaxOcclusionStrength = 4.0f;
    const SceneMaterial out = sanitized(m);
    // A negative smoothness or contrast takes the SLOW path and computes a
    // wrap with a negative width, which pushes the terminator the wrong
    // way and reads as an inverted light rather than as a bad number.
    UM_CHECK_NEAR(out.normalStrength, 0.0, 1e-6);
    UM_CHECK_NEAR(out.smoothness, 1.0, 1e-6);
    UM_CHECK_NEAR(out.contrast, 0.0, 1e-6);
    UM_CHECK_NEAR(out.parallaxDepth, 0.5, 1e-6);
    UM_CHECK_NEAR(out.parallaxQuality, 0.0, 1e-6);
    UM_CHECK_NEAR(out.parallaxOcclusionStrength, 1.0, 1e-6);
}

static void testSanitizeReplacesNonFiniteWithTheDefaultNotWithZero() {
    // A NaN quality makes the step count NaN, so the loop runs zero times
    // and the feature is silently off on one layer and nowhere else.
    // Clamping it to zero would do the same thing; the fallback is the
    // DEFAULT, so the surface behaves as an untouched one would.
    const float nan = std::numeric_limits<float>::quiet_NaN();
    SceneMaterial m;
    m.normalStrength = nan;
    m.parallaxQuality = nan;
    m.parallaxDepth = std::numeric_limits<float>::infinity();
    const SceneMaterial out = sanitized(m);
    UM_CHECK_NEAR(out.normalStrength, 1.0, 1e-6);
    UM_CHECK_NEAR(out.parallaxQuality, 0.5, 1e-6);
    // An infinity is a non-finite like any other, so it takes the DEFAULT
    // too -- it is not clamped to the top of the range. (This test
    // asserted 0.5 first, and the code was right: `isFinite ? value :
    // fallback` runs before the clamp, in Swift and here.)
    UM_CHECK_NEAR(out.parallaxDepth, 0.05, 1e-6);
}

static void testSanitizeLeavesAFlatMaterialFlat() {
    // Otherwise every project predating the feature would come back off
    // the flat path on load, which is the one thing the default promises.
    UM_CHECK(isFlat(sanitized(sceneMaterialFlat())));
}

static void testParallaxModeNamesRoundTripAndAreNotOrdinals() {
    // The file format's spelling, mapped explicitly so it cannot start
    // depending on declaration order.
    for (const SceneParallaxMode mode :
         {SceneParallaxMode::Off, SceneParallaxMode::Occlusion, SceneParallaxMode::SilhouetteClip,
          SceneParallaxMode::SilhouetteShell}) {
        const auto back = sceneParallaxModeFromName(sceneParallaxModeName(mode));
        UM_CHECK(back.has_value() && *back == mode);
    }
    UM_CHECK(!sceneParallaxModeFromName("nonsense").has_value());
}

static void testSilhouetteIsTwoCasesThatBehaveDifferently() {
    // The reason it is not a toggle: clip bites inwards only, shell grows
    // the quad so relief can overhang the card's own gizmo.
    UM_CHECK(!sceneParallaxClips(SceneParallaxMode::Occlusion));
    UM_CHECK(sceneParallaxClips(SceneParallaxMode::SilhouetteClip));
    UM_CHECK(sceneParallaxClips(SceneParallaxMode::SilhouetteShell));
    UM_CHECK(!sceneParallaxExpandsCard(SceneParallaxMode::SilhouetteClip));
    UM_CHECK(sceneParallaxExpandsCard(SceneParallaxMode::SilhouetteShell));
}

// ---- SceneLightMask ----

static void testMaskReachesOnAnySharedChannelNotOnContainment() {
    const SceneLightMask light = SceneLightMask::layer1() | SceneLightMask::layer2();
    const SceneLightMask layer = SceneLightMask::layer2();
    UM_CHECK(light.reaches(layer));
    UM_CHECK(layer.reaches(light));
    // Containment is the stricter question, and asking it here would stop
    // a two-channel light reaching a one-channel layer.
    UM_CHECK(!layer.contains(light));
    UM_CHECK(light.contains(layer));
    UM_CHECK(!SceneLightMask::layer3().reaches(layer));
}

static void testEmptyMaskReachesNothingAndAllReachesEverything() {
    UM_CHECK(SceneLightMask{}.isEmpty());
    UM_CHECK(!SceneLightMask{}.reaches(SceneLightMask::all()));
    for (int channel = 1; channel <= SceneLightMask::kChannelCount; ++channel) {
        UM_CHECK(SceneLightMask::all().reaches(SceneLightMask::layer(channel)));
    }
    UM_CHECK(SceneLightMask::all().rawValue == 0xFF);
    // Named from 1 like the inspector shows them.
    UM_CHECK(SceneLightMask::layer(1) == SceneLightMask::layer1());
    UM_CHECK(SceneLightMask::layer(8) == SceneLightMask::layer8());
}

static void testANewLayerSitsOnChannelOne() {
    UM_CHECK(plate().lightMask == SceneLightMask::layer1());
    UM_CHECK(plate().receivesLight);
}

UM_TEST_MAIN_BEGIN()
testShearIsExpressedInScaledUnits();
testRollComesAfterTheShear();
testIdentityLayerLeavesAPointAlone();
testLiftPreservesLengthsAndAngles();
testUntiltedLiftIsTheIdentityPlane();
testOrientationStaysARotationUnderShearAndScale();
testOrientationIgnoresScaleAndShearEntirely();
testUntiltedLayerFacesTheCamera();
testLightingPlanePassesThroughTheLayerOrigin();
testTangentReadsOnlyTheSignOfTheScale();
testMirroredCardFlipsTangentAndHandedness();
testZeroScaleKeepsTheUnmirroredReading();
testRigFrameIsNilForAnythingButARig();
testRigFrameAdvancesAndLoops();
testRigFrameWrapsFromBelowZero();
testRigFrameClampsWhenItDoesNotLoop();
testZeroSpeedFreezesOnTheStartFrame();
testEmptyClipReturnsTheStartFrameUntouched();
testNonFiniteSpeedDoesNotReachTheIntCast();
testNeutralFillIsAGreyRampNotAFlatColour();
testFillContentIsTheAtmosphereCase();
testFlatMaterialIsTheDefaultInEveryField();
testAnyChangeLeavesTheFlatPath();
testSanitizeClampsTheShadersBranchesIntoRange();
testSanitizeReplacesNonFiniteWithTheDefaultNotWithZero();
testSanitizeLeavesAFlatMaterialFlat();
testParallaxModeNamesRoundTripAndAreNotOrdinals();
testSilhouetteIsTwoCasesThatBehaveDifferently();
testMaskReachesOnAnySharedChannelNotOnContainment();
testEmptyMaskReachesNothingAndAllReachesEverything();
testANewLayerSitsOnChannelOne();
UM_TEST_MAIN_END()
