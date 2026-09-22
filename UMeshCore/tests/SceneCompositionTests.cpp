// Tests for Scene/SceneComposition.h, Scene/SceneCamera.h and
// Scene/SceneLight.h, ported from `Data/Scene/SceneComposition.swift`,
// `SceneCamera.swift` and `SceneLight.swift`.
//
// The properties each file names a bug for:
//
//   - Draw order is `sortingOrder` ascending with the ARRAY's order
//     breaking ties. The tie-break is the whole reason the sort is written
//     out: neither Swift's `sorted(by:)` nor `std::sort` is stable, so two
//     cards on one layer could swap between runs and an artist would watch
//     their set restack itself for no reason.
//   - The hierarchy lists FRONT-MOST FIRST while drawing goes back first.
//     The two disagreeing about which end is the front is a bug this
//     project has already shipped once.
//   - Depth reorders nothing: changing `positionZ` must not move a card in
//     the draw order, however far it goes.
//   - `SceneCamera` and `SceneViewCamera` are different cameras. The shot
//     projection comes from the scene camera and must not pick up the fly
//     camera's numbers.
//   - A light's derived quantities come from the Phase 4 math, not from a
//     second transcription -- so the model's answers and the math's are
//     the same answers, checked here rather than assumed.

#include "umeshcore/Scene/SceneComposition.h"

#include <cmath>
#include <string>

#include "umeshcore/Math/MatrixUtilities.h"
#include "umeshcore/Render/SceneViewCamera.h"

#include "TestHarness.h"

using namespace umeshcore;

namespace {

SceneLayer card(std::uint64_t id, int sortingOrder, const std::string& name) {
    SceneLayer layer;
    layer.id = Uuid(id, id);
    layer.name = name;
    layer.sortingOrder = sortingOrder;
    layer.content = ScenePlateContent{Uuid(9, 9)};
    return layer;
}

std::vector<std::string> names(const std::vector<SceneLayer>& layers) {
    std::vector<std::string> out;
    for (const SceneLayer& layer : layers) out.push_back(layer.name);
    return out;
}

} // namespace

// ---- Draw order ----

static void testDrawOrderIsBackFirstBySortingOrder() {
    SceneComposition scene;
    scene.layers = {card(1, 30, "foreground"), card(2, 0, "backdrop"), card(3, 10, "midground")};
    UM_CHECK(names(scene.drawOrderedLayers()) ==
             std::vector<std::string>({"backdrop", "midground", "foreground"}));
}

static void testTiesBreakOnTheArrayOrderAndStayThere() {
    // Every card on one layer: the answer must be the creation order,
    // exactly, and must not depend on which sort the library uses.
    SceneComposition scene;
    scene.layers = {card(1, 5, "a"), card(2, 5, "b"), card(3, 5, "c"), card(4, 5, "d"),
                    card(5, 5, "e"), card(6, 5, "f"), card(7, 5, "g"), card(8, 5, "h"),
                    card(9, 5, "i"), card(10, 5, "j"), card(11, 5, "k"), card(12, 5, "l"),
                    card(13, 5, "m"), card(14, 5, "n"), card(15, 5, "o"), card(16, 5, "p"),
                    card(17, 5, "q"), card(18, 5, "r"), card(19, 5, "s"), card(20, 5, "t")};
    // Twenty entries on purpose: a short run can pass on an unstable sort
    // by luck, because most implementations insertion-sort small ranges.
    const std::vector<std::string> expected = {"a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
                                               "k", "l", "m", "n", "o", "p", "q", "r", "s", "t"};
    UM_CHECK(names(scene.drawOrderedLayers()) == expected);
    // And again, to catch an implementation that is merely arbitrary
    // rather than unstable.
    UM_CHECK(names(scene.drawOrderedLayers()) == expected);
}

static void testTiesBreakWithinEachLayerNotAcrossThem() {
    SceneComposition scene;
    scene.layers = {card(1, 10, "ten-first"), card(2, 0, "zero-first"), card(3, 10, "ten-second"),
                    card(4, 0, "zero-second")};
    UM_CHECK(names(scene.drawOrderedLayers()) ==
             std::vector<std::string>({"zero-first", "zero-second", "ten-first", "ten-second"}));
}

static void testDepthDoesNotReorderAnything() {
    // The founding rule. Pushing a card back in Z changes how big it draws
    // and how fast it slides, and nothing about who covers whom.
    SceneComposition scene;
    scene.layers = {card(1, 0, "near-in-z"), card(2, 1, "far-in-z")};
    const std::vector<std::string> before = names(scene.drawOrderedLayers());
    scene.layers[0].positionZ = 50000.0f;
    scene.layers[1].positionZ = -50000.0f;
    UM_CHECK(names(scene.drawOrderedLayers()) == before);
}

static void testNegativeSortingOrdersSortBehindZero() {
    SceneComposition scene;
    scene.layers = {card(1, 0, "zero"), card(2, -5, "behind")};
    UM_CHECK(names(scene.drawOrderedLayers()) == std::vector<std::string>({"behind", "zero"}));
}

static void testFrontToBackIsExactlyTheReverse() {
    // The hierarchy's convention: top row is front-most. The two ends
    // disagreeing is a bug this project already shipped once.
    SceneComposition scene;
    scene.layers = {card(1, 0, "backdrop"), card(2, 20, "foreground"), card(3, 10, "midground")};
    UM_CHECK(names(scene.frontToBackLayers()) ==
             std::vector<std::string>({"foreground", "midground", "backdrop"}));
}

static void testEmptySceneHasEmptyOrders() {
    const SceneComposition scene;
    UM_CHECK(scene.drawOrderedLayers().empty());
    UM_CHECK(scene.frontToBackLayers().empty());
    UM_CHECK(scene.visibleLayers().empty());
}

// ---- Visibility ----

static void testVisibleDropsHiddenAndFullyTransparentLayers() {
    SceneComposition scene;
    SceneLayer hidden = card(1, 0, "hidden");
    hidden.isHidden = true;
    SceneLayer transparent = card(2, 1, "transparent");
    transparent.opacity = 0.0f;
    SceneLayer barelyThere = card(3, 2, "barely-there");
    barelyThere.opacity = 0.0005f;
    SceneLayer faint = card(4, 3, "faint");
    faint.opacity = 0.01f;
    scene.layers = {hidden, transparent, barelyThere, faint, card(5, 4, "solid")};
    // 0.001 is the threshold, and it is exclusive: a layer AT it
    // contributes nothing a viewer could see, and skipping it early saves
    // a whole lighting pass over the card.
    UM_CHECK(names(scene.visibleLayers()) == std::vector<std::string>({"faint", "solid"}));
}

static void testVisibleKeepsDrawOrder() {
    SceneComposition scene;
    scene.layers = {card(1, 30, "front"), card(2, 0, "back")};
    UM_CHECK(names(scene.visibleLayers()) == std::vector<std::string>({"back", "front"}));
}

// ---- Lookup and the new-layer number ----

static void testLookupByIdFindsAndMisses() {
    SceneComposition scene;
    scene.layers = {card(1, 0, "a"), card(2, 0, "b")};
    SceneLight light;
    light.id = Uuid(77, 77);
    light.name = "key";
    scene.lights = {light};

    const SceneLayer* found = scene.layer(Uuid(2, 2));
    UM_CHECK(found != nullptr);
    if (found) UM_CHECK(found->name == "b");
    UM_CHECK(scene.layer(Uuid(404, 404)) == nullptr);

    const SceneLight* foundLight = scene.light(Uuid(77, 77));
    UM_CHECK(foundLight != nullptr);
    if (foundLight) UM_CHECK(foundLight->name == "key");
    UM_CHECK(scene.light(Uuid(404, 404)) == nullptr);
}

static void testFrontSortingOrderStartsAtZeroAndThenLeads() {
    SceneComposition scene;
    // An empty scene's first card lands on 0, not on 1 -- Swift's
    // `max() ?? -1` then `+ 1`.
    UM_CHECK(scene.frontSortingOrder() == 0);
    scene.layers = {card(1, 7, "a"), card(2, 3, "b")};
    UM_CHECK(scene.frontSortingOrder() == 8);
    // Negative orders do not make it go backwards.
    scene.layers = {card(1, -4, "a"), card(2, -9, "b")};
    UM_CHECK(scene.frontSortingOrder() == -3);
}

// ---- Defaults ----

static void testDefaultsAreTheOnesASceneOpensWith() {
    const SceneComposition scene;
    UM_CHECK(scene.name == "Scene");
    UM_CHECK(scene.durationInFrames == 90);
    UM_CHECK(scene.fps == 30);
    UM_CHECK_NEAR(scene.renderSize.x, 1920.0, 1e-6);
    UM_CHECK_NEAR(scene.renderSize.y, 1080.0, 1e-6);
    // Full white at strength 1 multiplies by exactly one, so a scene
    // composed before lighting existed renders identically.
    UM_CHECK(scene.ambient == SceneAmbient::neutral());
    UM_CHECK_NEAR(scene.ambient.rgb().x, 1.0, 1e-6);
    // A grey ramp behind everything, so a scene is never composited onto
    // nothing.
    UM_CHECK(scene.background == SceneFill::neutral());
}

// ---- SceneCamera ----

static void testFocalLengthPutsScaleAtOneOnTheFocalPlane() {
    // One world unit covers one pixel of view height at exactly this
    // distance, which is what makes a Scene whose layers sit on the focal
    // plane land on the pixels the editor's 2D path already produces.
    SceneCamera camera;
    camera.fieldOfView = 45.0f;
    const float focal = camera.focalLength(1080.0f);
    const float expected = 540.0f / std::tan(45.0f * kPi / 180.0f * 0.5f);
    UM_CHECK_NEAR(focal, expected, 1e-2);

    const SceneProjection projection = sceneProjection(camera, Vec2(1920, 1080));
    // `pixels = focalLength * length / depth`, so at depth == focalLength
    // a length of 1 covers 1 pixel.
    UM_CHECK_NEAR(projection.focalLength, focal, 1e-2);
}

static void testShotProjectionComesFromTheSceneCameraNotTheFlyCamera() {
    // Two cameras, one set of maths, and they must not be confused: the
    // shot renders from the scene camera wherever the artist happens to be
    // standing.
    SceneCamera shot;
    shot.position = Vec2(0, 0);
    shot.positionZ = -1200.0f;
    const SceneProjection fromShot = sceneProjection(shot, Vec2(1920, 1080));

    SceneViewCamera fly;
    fly.pivot = Vec3(5000, 5000, 5000);
    fly.distance = 4000.0f;
    const SceneProjection fromFly = fly.projection(Vec2(1920, 1080));

    UM_CHECK_NEAR(fromShot.eye.z, -1200.0, 1e-3);
    UM_CHECK(std::fabs(fromFly.eye.x - fromShot.eye.x) > 1.0f);
}

static void testDegenerateDepthRangeStillProducesADivisibleProjection() {
    // The Swift guards, kept verbatim: nearZ floored at 0.01 and farZ held
    // at least a unit beyond it, so a camera saved with a collapsed range
    // does not give a projection matrix that divides by zero.
    SceneCamera camera;
    camera.nearZ = 0.0f;
    camera.farZ = 0.0f;
    const SceneProjection projection = sceneProjection(camera, Vec2(800, 600));
    UM_CHECK(projection.nearZ >= 0.01f);
    const auto point = projection.project(Vec3(0, 0, camera.positionZ + 500.0f));
    UM_CHECK(point.has_value());
    if (point) UM_CHECK(std::isfinite(point->x) && std::isfinite(point->y));
}

static void testCameraLooksAlongIncreasingZ() {
    // A layer is in front of the camera when its Z is GREATER -- the same
    // direction After Effects uses, and the same one the layer and the
    // light use, so the three never need a sign flip between them.
    const SceneCamera camera;
    const SceneProjection projection = sceneProjection(camera, Vec2(1920, 1080));
    UM_CHECK(projection.depth(Vec3(0, 0, camera.positionZ + 100.0f)) > 0.0f);
    UM_CHECK(projection.depth(Vec3(0, 0, camera.positionZ - 100.0f)) < 0.0f);
}

// ---- SceneLight ----

static void testLightDerivedValuesComeFromThePhase4Math() {
    // The model must not carry a second transcription of the direction or
    // the band width. If it did, these would drift -- and the band width
    // is what the lattice density is chosen from, so the symptom would not
    // be "wrong", it would be "slightly grainy".
    SceneLight light;
    light.azimuth = 0.7f;
    light.elevation = -0.3f;
    light.radius = 500.0f;
    light.softness = 0.4f;

    const SceneLightParams params = light.params();
    const Vec3 fromMath = lightDirection(params.azimuth, params.elevation);
    UM_CHECK_NEAR(light.direction().x, fromMath.x, 1e-6);
    UM_CHECK_NEAR(light.direction().y, fromMath.y, 1e-6);
    UM_CHECK_NEAR(light.direction().z, fromMath.z, 1e-6);
    UM_CHECK_NEAR(light.innerRadius(), lightInnerRadius(params), 1e-6);
    UM_CHECK_NEAR(light.bandWidth(), lightBandWidth(params), 1e-6);
    // And the direction really is a unit vector, which is what the
    // attenuation assumes.
    UM_CHECK_NEAR(length(light.direction()), 1.0, 1e-5);
}

static void testSoftnessIsTheOneKnobThatSplitsRadiusIntoCoreAndBand() {
    // The radius says where the light ends, softness says how much of it
    // is fade, and the curve says what the fade looks like. The three do
    // not overlap, which is the design.
    SceneLight light;
    light.radius = 600.0f;
    light.softness = 1.0f;
    UM_CHECK_NEAR(light.innerRadius(), 0.0, 1e-4);
    UM_CHECK_NEAR(light.bandWidth(), 600.0, 1e-4);
    light.softness = 0.0f;
    UM_CHECK_NEAR(light.innerRadius(), 600.0, 1e-4);
    UM_CHECK_NEAR(light.bandWidth(), 0.0, 1e-4);
    light.softness = 0.25f;
    UM_CHECK_NEAR(light.innerRadius(), 450.0, 1e-3);
    UM_CHECK_NEAR(light.bandWidth(), 150.0, 1e-3);
}

static void testParamsCarriesTheMaskAsTheByteTheMathReads() {
    SceneLight light;
    light.mask = SceneLightMask::layer2() | SceneLightMask::layer5();
    UM_CHECK(light.params().mask == light.mask.rawValue);
    UM_CHECK(lightMaskReaches(light.params().mask, SceneLightMask::layer5().rawValue));
    UM_CHECK(!lightMaskReaches(light.params().mask, SceneLightMask::layer1().rawValue));
}

static void testDirectionalLightHasNoPlace() {
    // Moving it would be a control that changes nothing, which is worse
    // than not having it.
    UM_CHECK(sceneLightIsPositional(SceneLightKind::kPoint));
    UM_CHECK(sceneLightIsPositional(SceneLightKind::kSpot));
    UM_CHECK(!sceneLightIsPositional(SceneLightKind::kDirectional));
}

static void testEnumNamesRoundTripAndAreNotOrdinals() {
    for (const SceneLightKind kind :
         {SceneLightKind::kPoint, SceneLightKind::kSpot, SceneLightKind::kDirectional}) {
        const auto back = sceneLightKindFromName(sceneLightKindName(kind));
        UM_CHECK(back.has_value() && *back == kind);
    }
    for (const SceneLightBlend blend :
         {SceneLightBlend::kNormal, SceneLightBlend::kAdditive, SceneLightBlend::kMultiply,
          SceneLightBlend::kScreen}) {
        const auto back = sceneLightBlendFromName(sceneLightBlendName(blend));
        UM_CHECK(back.has_value() && *back == blend);
    }
    UM_CHECK(!sceneLightKindFromName("spotlight").has_value());
    UM_CHECK(!sceneLightBlendFromName("overlay").has_value());
    // The stored token is the Swift `rawValue`, not the C++ spelling, so
    // renaming a case cannot silently rewrite every saved file.
    UM_CHECK(std::string(sceneLightKindName(SceneLightKind::kDirectional)) == "directional");
    UM_CHECK(std::string(sceneLightBlendName(SceneLightBlend::kScreen)) == "screen");
}

static void testLightOrderIsAuthoredBecauseBlendsDoNotCommute() {
    // A vector and not a set: `multiply` and `screen` do not commute with
    // the others, so "which light first" is a real question with a visible
    // answer.
    SceneComposition scene;
    SceneLight first;
    first.id = Uuid(1, 1);
    first.blend = SceneLightBlend::kMultiply;
    SceneLight second;
    second.id = Uuid(2, 2);
    second.blend = SceneLightBlend::kScreen;
    scene.lights = {first, second};
    UM_CHECK(scene.lights[0].blend == SceneLightBlend::kMultiply);
    SceneComposition swapped = scene;
    swapped.lights = {second, first};
    // The model must be able to tell the two stagings apart at all.
    UM_CHECK(!(scene == swapped));
}

static void testFalloffCurvesCompareByTheirStopsNotTheirTables() {
    SceneLight a;
    SceneLight b;
    UM_CHECK(a.falloff == b.falloff);
    b.falloff = LightFalloffCurve::linear();
    UM_CHECK(!(a.falloff == b.falloff));
    // The default really is `smooth` and not `linear` -- the two-stop
    // "auto" curve would have been a straight line while being called
    // smooth, which is why the flat tangents are written out.
    UM_CHECK(a.falloff == LightFalloffCurve::smooth());
}

UM_TEST_MAIN_BEGIN()
testDrawOrderIsBackFirstBySortingOrder();
testTiesBreakOnTheArrayOrderAndStayThere();
testTiesBreakWithinEachLayerNotAcrossThem();
testDepthDoesNotReorderAnything();
testNegativeSortingOrdersSortBehindZero();
testFrontToBackIsExactlyTheReverse();
testEmptySceneHasEmptyOrders();
testVisibleDropsHiddenAndFullyTransparentLayers();
testVisibleKeepsDrawOrder();
testLookupByIdFindsAndMisses();
testFrontSortingOrderStartsAtZeroAndThenLeads();
testDefaultsAreTheOnesASceneOpensWith();
testFocalLengthPutsScaleAtOneOnTheFocalPlane();
testShotProjectionComesFromTheSceneCameraNotTheFlyCamera();
testDegenerateDepthRangeStillProducesADivisibleProjection();
testCameraLooksAlongIncreasingZ();
testLightDerivedValuesComeFromThePhase4Math();
testSoftnessIsTheOneKnobThatSplitsRadiusIntoCoreAndBand();
testParamsCarriesTheMaskAsTheByteTheMathReads();
testDirectionalLightHasNoPlace();
testEnumNamesRoundTripAndAreNotOrdinals();
testLightOrderIsAuthoredBecauseBlendsDoNotCommute();
testFalloffCurvesCompareByTheirStopsNotTheirTables();
UM_TEST_MAIN_END()
