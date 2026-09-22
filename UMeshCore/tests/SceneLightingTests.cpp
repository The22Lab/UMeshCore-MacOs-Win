// Tests for Render/SceneLighting.h, ported from `Render/SceneLighting.swift`
// (plus the falloff curve, which lives in `Data/Scene/SceneLight.swift` but
// is pure math).
//
// `Editor/verify_scene_lighting.py` and `verify_scene_material_response.py`
// do not exist in this repository (see CLAUDE.md), so the measurements they
// report cannot be re-run. What CAN be reproduced here is the FINDING behind
// the two neutral-value branches in `shapedLambert`, and that is the test
// that matters most in this file: one of those branches changes no bit and
// is there for speed, the other is load-bearing, and the Swift header says
// treating them as one rule is how its own harness first got written wrong.
//
// The rest assert the documented shape of the field: attenuation is 1 inside
// the inner radius and 0 past the rim, a spot is compared as cosines, the
// depth influence is the only mention of Z, a light set flat cannot be
// resurrected by a surface's material, `multiply` can only take light away,
// the lattice density comes from the BAND and not the radius, and a lattice
// point whose ray misses the plane gets ambient rather than a hole.

#include "umeshcore/Render/SceneLighting.h"

#include <cmath>
#include <vector>

#include "TestHarness.h"

using namespace umeshcore;

namespace {

constexpr float kPi = 3.14159265358979323846f;

SceneLightParams pointLight() {
    SceneLightParams light;
    light.kind = SceneLightKind::kPoint;
    light.world = Vec3(0, 0, 0);
    light.radius = 100.0f;
    light.softness = 0.5f; // inner 50, band 50
    light.intensity = 1.0f;
    light.color = Vec3(1, 1, 1);
    light.depthInfluence = 1.0f;
    light.normalInfluence = 0.0f;
    return light;
}

} // namespace

static void testSmoothnessZeroChangesNoBitAndContrastZeroWould() {
    // The two branches, and the two DIFFERENT reasons for them.
    //
    // This one reproduces the Swift header's measurement EXACTLY, on the
    // same sample grid it names -- "3 327 of 20 001 samples move, by up to
    // 1.5e-08" -- which no other cited figure in this port has been able
    // to do, because the harnesses that produced them are missing. It
    // holds because the arithmetic is float32 on both sides, which is the
    // whole premise of this port's math library.
    int smoothnessDrift = 0;
    int contrastDrift = 0;
    double worstContrastDrift = 0.0;
    for (int i = 0; i <= 20000; ++i) {
        const float x = static_cast<float>(i) / 20000.0f;
        // smoothness 0: `(d + 0) / (1 + 0)` is exactly `d` -- adding zero
        // is exact and dividing by one is exact. That branch is there only
        // to skip work, on every fragment of every lit sprite that never
        // asked for it.
        if ((x + 0.0f) / (1.0f + 0.0f) != x) ++smoothnessDrift;
        // contrast 0: `0.5 + (x - 0.5) * 1.0` is NOT exactly `x` in
        // float32. Without the branch, every lit pixel of every existing
        // project would move by an amount nobody could see or report.
        const float roundTrip = 0.5f + (x - 0.5f) * (1.0f + 0.0f);
        if (roundTrip != x) {
            ++contrastDrift;
            worstContrastDrift =
                std::max(worstContrastDrift, static_cast<double>(std::fabs(roundTrip - x)));
        }
        // And with the branches in place, the neutral call is the identity
        // on the clamped value, bit for bit.
        UM_CHECK(SceneLighting::shapedLambert(x, 0.0f, 0.0f) == x);
    }
    UM_CHECK(smoothnessDrift == 0);
    UM_CHECK(contrastDrift == 3327);
    UM_CHECK(worstContrastDrift <= 1.5e-08);
    // Negative N.L clamps first, so the identity holds there too.
    for (int i = 1; i <= 1000; ++i) {
        UM_CHECK(SceneLighting::shapedLambert(-static_cast<float>(i) / 1000.0f, 0.0f, 0.0f) == 0.0f);
    }
}

static void testSmoothnessWrapsTheTerminatorRatherThanBlurring() {
    // It moves the terminator from N.L = 0 to N.L = -s, so a surface
    // facing slightly away still catches light; s = 1 is full
    // half-Lambert.
    UM_CHECK(SceneLighting::shapedLambert(-0.5f, 0.0f, 0.0f) == 0.0f);
    UM_CHECK(SceneLighting::shapedLambert(-0.5f, 1.0f, 0.0f) > 0.0f);
    UM_CHECK_NEAR(SceneLighting::shapedLambert(-1.0f, 1.0f, 0.0f), 0.0, 1e-6);
    UM_CHECK_NEAR(SceneLighting::shapedLambert(0.0f, 1.0f, 0.0f), 0.5, 1e-6);
    // Monotonic, and never outside the range Lambert already occupied.
    float previous = -1.0f;
    for (int i = 0; i <= 200; ++i) {
        const float d = -1.0f + 2.0f * static_cast<float>(i) / 200.0f;
        const float shaped = SceneLighting::shapedLambert(d, 0.6f, 0.4f);
        UM_CHECK(shaped >= 0.0f && shaped <= 1.0f);
        UM_CHECK(shaped >= previous - 1e-6f);
        previous = shaped;
    }
}

static void testAttenuationIsFlatInsideTheInnerRadiusAndZeroPastTheRim() {
    const PreparedLight light{pointLight()};
    UM_CHECK_NEAR(light.innerRadius, 50.0, 1e-4);
    UM_CHECK_NEAR(light.band, 50.0, 1e-4);
    UM_CHECK_NEAR(light.attenuation(Vec3(0, 0, 0)), 1.0, 1e-6);
    UM_CHECK_NEAR(light.attenuation(Vec3(49, 0, 0)), 1.0, 1e-6);
    UM_CHECK(light.attenuation(Vec3(100.1f, 0, 0)) == 0.0f);
    UM_CHECK(light.attenuation(Vec3(5000, 0, 0)) == 0.0f);
    // Across the band it only decreases -- the whole point of the pinned
    // curve is that it reaches zero AT the rim rather than stepping there.
    float previous = 1.1f;
    for (int i = 0; i <= 100; ++i) {
        const float d = 50.0f + 50.0f * static_cast<float>(i) / 100.0f;
        const float a = light.attenuation(Vec3(d, 0, 0));
        UM_CHECK(a <= previous + 1e-6f);
        previous = a;
    }
    UM_CHECK(previous < 0.01f);
}

static void testDepthInfluenceIsTheOnlyMentionOfZ() {
    SceneLightParams flat = pointLight();
    flat.depthInfluence = 0.0f;
    // Flat: a layer a thousand units behind is lit as though it sat at the
    // light's own depth. That is ordinary 2D lighting, and what an artist
    // staging a flat scene wants.
    UM_CHECK_NEAR(PreparedLight(flat).attenuation(Vec3(0, 0, 1000)), 1.0, 1e-6);
    // A real point in space: the same layer is out of reach.
    UM_CHECK(PreparedLight(pointLight()).attenuation(Vec3(0, 0, 1000)) == 0.0f);
}

static void testSpotIsComparedAsCosinesAndFadesBetweenTheCones() {
    SceneLightParams params = pointLight();
    params.kind = SceneLightKind::kSpot;
    params.azimuth = 0.0f;   // along +x
    params.elevation = 0.0f;
    params.innerAngle = 10.0f * kPi / 180.0f;
    params.outerAngle = 30.0f * kPi / 180.0f;
    params.softness = 0.0f; // hard-edged, so only the cone shapes it
    const PreparedLight light{params};

    const auto atAngle = [&](float degrees) {
        const float a = degrees * kPi / 180.0f;
        return light.attenuation(Vec3(std::cos(a) * 60.0f, std::sin(a) * 60.0f, 0));
    };
    UM_CHECK_NEAR(atAngle(0.0f), 1.0, 1e-5);   // on the axis
    UM_CHECK_NEAR(atAngle(9.0f), 1.0, 1e-5);   // inside the inner cone
    UM_CHECK(atAngle(31.0f) == 0.0f);          // outside the outer cone
    const float mid = atAngle(20.0f);
    UM_CHECK(mid > 0.0f && mid < 1.0f);        // smoothstepped between
    // Monotonic across the cone's fade.
    UM_CHECK(atAngle(15.0f) > atAngle(25.0f));
}

static void testALightSetFlatCannotBeResurrectedByASurface() {
    // normalInfluence is the LIGHT's, and it is the outermost step: a
    // sprite's material may not undo the artist's decision.
    SceneLightParams params = pointLight();
    params.normalInfluence = 0.0f;
    const PreparedLight flat{params};
    const Vec3 facingAway(0, 0, -1);
    UM_CHECK(flat.lambert(Vec3(0, 0, 10), facingAway, 1.0f, 1.0f) == 1.0f);
    UM_CHECK(flat.lambert(Vec3(0, 0, 10), Vec3(0, 1, 0), 0.0f, 0.0f) == 1.0f);

    // With the influence up, facing matters -- and the influence still
    // bounds how much.
    params.normalInfluence = 0.5f;
    const PreparedLight lit{params};
    const float away = lit.lambert(Vec3(0, 0, 40), Vec3(0, 0, 1), 0.0f, 0.0f);
    UM_CHECK_NEAR(away, 0.5, 1e-5); // 1 - influence + influence * 0
    const float toward = lit.lambert(Vec3(0, 0, 40), Vec3(0, 0, -1), 0.0f, 0.0f);
    UM_CHECK_NEAR(toward, 1.0, 1e-5);
}

static void testDirectionalLightReachesEverywhere() {
    SceneLightParams params = pointLight();
    params.kind = SceneLightKind::kDirectional;
    const PreparedLight light{params};
    UM_CHECK(light.attenuation(Vec3(100000, -50000, 90000)) == 1.0f);
}

static void testBlendsRouteWhereTheDesignSaysTheyDo() {
    const Vec3 point(0, 0, 0);
    const Vec3 normal(0, 0, -1);
    const SceneAmbient ambient; // neutral white

    SceneLightParams normalBlend = pointLight();
    normalBlend.color = Vec3(0.2f, 0.4f, 0.6f);
    const auto lit = SceneLighting::shade({PreparedLight(normalBlend)}, ambient, point, normal);
    UM_CHECK_NEAR(lit.factor.x, 1.2, 1e-5); // ambient + emission
    UM_CHECK(lit.additive == Vec3::zero());

    SceneLightParams additive = normalBlend;
    additive.blend = SceneLightBlend::kAdditive;
    const auto add = SceneLighting::shade({PreparedLight(additive)}, ambient, point, normal);
    // Emission, added AFTER the multiply, so a dark sprite cannot cancel it.
    UM_CHECK(add.factor == ambient.rgb());
    UM_CHECK_NEAR(add.additive.z, 0.6, 1e-5);

    SceneLightParams gel = normalBlend;
    gel.blend = SceneLightBlend::kMultiply;
    const auto multiplied = SceneLighting::shade({PreparedLight(gel)}, ambient, point, normal);
    // A gel can only TAKE light away, and only where it reaches.
    UM_CHECK(multiplied.factor.x <= ambient.rgb().x + 1e-6f);
    UM_CHECK(multiplied.factor.z <= ambient.rgb().z + 1e-6f);
    UM_CHECK(multiplied.factor.x < multiplied.factor.z); // its own colour survives
    const auto outOfReach = SceneLighting::shade(
        {PreparedLight(gel)}, ambient, Vec3(1000, 0, 0), normal);
    UM_CHECK(outOfReach.factor == ambient.rgb());

    SceneLightParams screen = normalBlend;
    screen.blend = SceneLightBlend::kScreen;
    screen.intensity = 4.0f; // deliberately over-bright
    const auto screened = SceneLighting::shade({PreparedLight(screen)}, ambient, point, normal);
    // Screen against a factor already at 1 stays at 1: it can brighten,
    // never overshoot.
    UM_CHECK(screened.factor.x <= 1.0f + 1e-6f);
}

static void testAmbientOnlyAndIdentity() {
    const SceneLighting empty({}, SceneAmbient::neutral());
    UM_CHECK(empty.isIdentity());
    // A scene composed before lighting existed takes no arithmetic at all.
    SceneAmbient dim;
    dim.intensity = 0.4f;
    const SceneLighting dimmed({}, dim);
    UM_CHECK(!dimmed.isIdentity());
    // A disabled light is dropped at construction, not filtered later.
    SceneLightParams off = pointLight();
    off.isEnabled = false;
    UM_CHECK(SceneLighting({off}, SceneAmbient::neutral()).lights.empty());
}

static void testMaskDecidesWhichLightsReachASurface() {
    SceneLightParams channelOne = pointLight();
    channelOne.mask = 0x01;
    SceneLightParams channelTwo = pointLight();
    channelTwo.mask = 0x02;
    const SceneLighting lighting({channelOne, channelTwo}, SceneAmbient::neutral());
    UM_CHECK(lighting.lightsReaching(0x01).size() == 1);
    UM_CHECK(lighting.lightsReaching(0x03).size() == 2);
    UM_CHECK(lighting.lightsReaching(0x04).empty());
}

static void testFalloffPresetsAreTheCurvesTheirCommentsClaim() {
    // Flat tangents at both ends give exactly 1 - 3u^2 + 2u^3, which is
    // what makes "smooth" smooth rather than secretly linear.
    const LightFalloffCurve smooth = LightFalloffCurve::smooth();
    for (int i = 0; i <= 50; ++i) {
        const float u = static_cast<float>(i) / 50.0f;
        UM_CHECK_NEAR(smooth.value(u), 1.0 - 3.0 * u * u + 2.0 * u * u * u, 1e-4);
    }
    // Both control points on the chord give a straight fade.
    const LightFalloffCurve linear = LightFalloffCurve::linear();
    for (int i = 0; i <= 50; ++i) {
        const float u = static_cast<float>(i) / 50.0f;
        UM_CHECK_NEAR(linear.value(u), 1.0 - u, 1e-4);
    }
    // Pinned at both ends, always -- a curve that ended at 0.2 would draw
    // a hard circle around every lamp.
    for (const LightFalloffCurve& curve :
         {LightFalloffCurve::smooth(), LightFalloffCurve::linear(),
          LightFalloffCurve::inverseSquare()}) {
        UM_CHECK_NEAR(curve.value(0.0f), 1.0, 1e-6);
        UM_CHECK_NEAR(curve.value(1.0f), 0.0, 1e-6);
        UM_CHECK_NEAR(curve.value(-5.0f), 1.0, 1e-6); // clamped, not extrapolated
        UM_CHECK_NEAR(curve.value(9.0f), 0.0, 1e-6);
    }
    // The physical fall drops faster early than a straight line does.
    UM_CHECK(LightFalloffCurve::inverseSquare().value(0.25f) < linear.value(0.25f));
    // An under-specified curve falls back to the default rather than
    // indexing out of bounds.
    const LightFalloffCurve underSpecified{std::vector<LightFalloffStop>{}};
    UM_CHECK_NEAR(underSpecified.value(0.5f), 0.5, 1e-4);
    UM_CHECK(underSpecified.stops().size() == 2);
}

static void testTabulatedFalloffTracksTheCurve() {
    const PreparedLight light{pointLight()};
    const LightFalloffCurve curve = LightFalloffCurve::smooth();
    for (int i = 0; i <= 100; ++i) {
        const float u = static_cast<float>(i) / 100.0f;
        // 256 entries, linearly interpolated: the Swift harness measured
        // the table at 0.038/255 against the exact curve.
        UM_CHECK_NEAR(light.falloff(u), curve.value(u), 1.0 / 255.0 / 8.0);
    }
}

static void testLatticeDensityComesFromTheBandNotTheRadius() {
    // A wide light with a hair-thin edge: chosen from the radius, the
    // lattice would step straight over the gradient.
    SceneLightParams wide = pointLight();
    wide.radius = 4000.0f;
    wide.softness = 0.01f; // band = 40 world units on a 4000 radius
    const SceneLighting lighting({wide}, SceneAmbient::neutral());
    const auto worldAt = [](float x, float y) {
        return std::optional<Vec3>(Vec3(x, y, 0));
    };
    const auto field = LightField::build(
        lighting, 0xFF, Vec3(0, 0, -1), LightField::ScreenBounds{0, 0, 800, 600},
        SceneLighting::kCellsPerBandFinal, 1.0f, worldAt);
    UM_CHECK(field.has_value());
    // band 40 * 1 px per unit / 20 cells = 2 px per cell -> 400 columns,
    // capped at the lattice ceiling.
    UM_CHECK(field->columns == SceneLighting::kMaximumLatticeSide);
    UM_CHECK(field->rows == 300);

    // The interactive density is coarser, by exactly the ratio of the two
    // constants.
    const auto coarse = LightField::build(
        lighting, 0xFF, Vec3(0, 0, -1), LightField::ScreenBounds{0, 0, 800, 600},
        SceneLighting::kCellsPerBandInteractive, 1.0f, worldAt);
    UM_CHECK(coarse.has_value());
    UM_CHECK(coarse->rows < field->rows);

    // No gradient anywhere: nothing for a lattice to resolve, so it takes
    // the widest cell rather than the finest.
    SceneLightParams hard = pointLight();
    hard.softness = 0.0f;
    const auto flat = LightField::build(
        SceneLighting({hard}, SceneAmbient::neutral()), 0xFF, Vec3(0, 0, -1),
        LightField::ScreenBounds{0, 0, 960, 960}, SceneLighting::kCellsPerBandFinal, 1.0f, worldAt);
    UM_CHECK(flat.has_value());
    UM_CHECK(flat->columns == 10); // 960 / 96
}

static void testFieldIsAbsentWhenNothingCanReachTheSurface() {
    SceneLightParams params = pointLight();
    params.mask = 0x01;
    const SceneLighting lighting({params}, SceneAmbient::neutral());
    const auto worldAt = [](float x, float y) { return std::optional<Vec3>(Vec3(x, y, 0)); };
    // Wrong channel AND a neutral ambient: the caller draws the layer the
    // way it always did.
    UM_CHECK(!LightField::build(
                  lighting, 0x02, Vec3(0, 0, -1), LightField::ScreenBounds{0, 0, 100, 100},
                  SceneLighting::kCellsPerBandFinal, 1.0f, worldAt)
                  .has_value());
    // A non-neutral ambient still needs a field, even with no light.
    SceneAmbient dim;
    dim.intensity = 0.3f;
    UM_CHECK(LightField::build(
                 SceneLighting({params}, dim), 0x02, Vec3(0, 0, -1),
                 LightField::ScreenBounds{0, 0, 100, 100}, SceneLighting::kCellsPerBandFinal, 1.0f,
                 worldAt)
                 .has_value());
}

static void testARayThatMissesThePlaneGetsAmbientRatherThanAHole() {
    SceneLightParams params = pointLight();
    params.radius = 10000.0f;
    SceneAmbient ambient;
    ambient.intensity = 0.25f;
    const SceneLighting lighting({params}, ambient);
    // The right half of the field misses the plane entirely -- a layer
    // seen edge-on, or meeting the ray behind the eye.
    const auto worldAt = [](float x, float) -> std::optional<Vec3> {
        if (x > 50.0f) return std::nullopt;
        return Vec3(x, 0, 0);
    };
    const auto field = LightField::build(
        lighting, 0xFF, Vec3(0, 0, -1), LightField::ScreenBounds{0, 0, 100, 100},
        SceneLighting::kCellsPerBandFinal, 1.0f, worldAt);
    UM_CHECK(field.has_value());
    // Ambient at the missed corner, exactly -- not a hole, not a NaN, and
    // not the neighbouring lit node's value. A hole would interpolate
    // garbage into its neighbours instead.
    const auto missed = field->sample(100.0f, 100.0f);
    UM_CHECK_NEAR(missed.factor.x, 0.25, 1e-6);
    UM_CHECK(missed.additive == Vec3::zero());
    // Every lattice point is finite, and the lit side is brighter than
    // the ambient the missed side fell back to.
    for (const Vec3& f : field->factors) {
        UM_CHECK(std::isfinite(f.x) && std::isfinite(f.y) && std::isfinite(f.z));
        UM_CHECK(f.x >= 0.25f - 1e-6f);
    }
    UM_CHECK(field->sample(0.0f, 0.0f).factor.x > 1.0f);
}

static void testBilinearSampleIsExactOnALinearFieldAndClampsOutside() {
    // Bilinear interpolation reproduces a linear field exactly, which is
    // the whole argument for sampling the lattice instead of every pixel:
    // where the field is flat or linear, interpolation loses nothing.
    LightField field;
    field.originX = 0;
    field.originY = 0;
    field.width = 100;
    field.height = 100;
    field.columns = 4;
    field.rows = 4;
    for (int j = 0; j <= field.rows; ++j) {
        for (int i = 0; i <= field.columns; ++i) {
            const float x = 100.0f * static_cast<float>(i) / 4.0f;
            const float y = 100.0f * static_cast<float>(j) / 4.0f;
            field.factors.push_back(Vec3(x * 0.01f + y * 0.02f, 0, 0));
            field.additives.push_back(Vec3::zero());
        }
    }
    for (float x : {0.0f, 12.5f, 37.0f, 99.9f}) {
        for (float y : {0.0f, 3.0f, 51.0f, 100.0f}) {
            UM_CHECK_NEAR(field.sample(x, y).factor.x, x * 0.01 + y * 0.02, 1e-4);
        }
    }
    // Outside the rectangle the sample clamps to the edge rather than
    // extrapolating.
    UM_CHECK_NEAR(field.sample(-500.0f, -500.0f).factor.x, 0.0, 1e-5);
    UM_CHECK_NEAR(field.sample(5000.0f, 5000.0f).factor.x, 3.0, 1e-4);
}

static void testNonFiniteOutZeroIn() {
    const Vec3 sanitised = LightField::finite(Vec3(std::nanf(""), INFINITY, 0.5f));
    UM_CHECK(sanitised.x == 0.0f && sanitised.y == 0.0f && sanitised.z == 0.5f);
}

static void testWireCodesComeFromASwitchNotACast() {
    // The mapping Phase 5's String-backed model enums are entitled to.
    UM_CHECK(lightKindCode(SceneLightKind::kSpot) == SceneLightKindCode::kSpot);
    UM_CHECK(lightKindCode(SceneLightKind::kDirectional) == SceneLightKindCode::kDirectional);
    UM_CHECK(lightBlendCode(SceneLightBlend::kScreen) == SceneLightBlendCode::kScreen);
    UM_CHECK(lightBlendCode(SceneLightBlend::kMultiply) == SceneLightBlendCode::kMultiply);
}

UM_TEST_MAIN_BEGIN()
    testSmoothnessZeroChangesNoBitAndContrastZeroWould();
    testSmoothnessWrapsTheTerminatorRatherThanBlurring();
    testAttenuationIsFlatInsideTheInnerRadiusAndZeroPastTheRim();
    testDepthInfluenceIsTheOnlyMentionOfZ();
    testSpotIsComparedAsCosinesAndFadesBetweenTheCones();
    testALightSetFlatCannotBeResurrectedByASurface();
    testDirectionalLightReachesEverywhere();
    testBlendsRouteWhereTheDesignSaysTheyDo();
    testAmbientOnlyAndIdentity();
    testMaskDecidesWhichLightsReachASurface();
    testFalloffPresetsAreTheCurvesTheirCommentsClaim();
    testTabulatedFalloffTracksTheCurve();
    testLatticeDensityComesFromTheBandNotTheRadius();
    testFieldIsAbsentWhenNothingCanReachTheSurface();
    testARayThatMissesThePlaneGetsAmbientRatherThanAHole();
    testBilinearSampleIsExactOnALinearFieldAndClampsOutside();
    testNonFiniteOutZeroIn();
    testWireCodesComeFromASwitchNotACast();
UM_TEST_MAIN_END()
