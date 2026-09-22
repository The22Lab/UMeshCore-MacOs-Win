// Tests for Serialization/SavedScene.h, ported from
// `Data/Scene/ScenePersistence.swift`, plus the manifest wiring in
// `ProjectDocument`.
//
// A persistence layer's contract is about FILES THAT ALREADY EXIST, so
// almost none of these are round trips. Each one names the file it is
// protecting:
//
//   - A project saved before layers had numbers restores in exactly the
//     order it was saved in, because the index in the file becomes the
//     layer number. Zero would give the same order by luck and stop doing
//     so the moment anybody touched one number.
//   - A project saved before materials existed restores the FLAT surface,
//     which is the only thing that keeps "renders bit for bit as before"
//     true, since `isFlat` gates a branch the shader never enters.
//   - A file naming a parallax march this build cannot run draws the
//     surface it drew before marches existed, rather than the nearest
//     guess -- which would render the artist a scene they never composed
//     and then let them save it back.
//   - A layer whose payload is missing is dropped, not invented.
//   - A hand-edited file cannot produce a camera that divides by tan(0), a
//     spot lit inside out, or a light that reaches nothing.
//   - A project that never touched Scene mode writes no Scene keys at all.
//   - And `unrecognized` still preserves what is STILL not modelled, which
//     is the guarantee moving these sections out of it must not break.

#include "umeshcore/Serialization/SavedScene.h"

#include <cmath>
#include <string>

#include "umeshcore/Math/MatrixUtilities.h"
#include "umeshcore/Serialization/ProjectDocument.h"

#include "TestHarness.h"

using namespace umeshcore;

namespace {

SceneLayer plate(std::uint64_t id, const std::string& name) {
    SceneLayer layer;
    layer.id = Uuid(id, id);
    layer.name = name;
    layer.content = ScenePlateContent{Uuid(50, 50)};
    return layer;
}

JsonValue parse(const std::string& text) { return JsonValue::parse(text); }

} // namespace

// ---- Round trips, for the fields that have no compatibility story ------

static void testLayerRoundTripsEveryField() {
    SceneLayer layer = plate(7, "plate");
    layer.isHidden = true;
    layer.opacity = 0.5f;
    layer.position = Vec2(12.0f, -30.0f);
    layer.positionZ = 400.0f;
    layer.rotation = 0.35f;
    layer.rotation3D = Vec3(0.1f, -0.2f, 0.0f);
    layer.scale = Vec2(2.0f, 3.0f);
    layer.shear = Vec2(0.25f, -0.125f);
    layer.sortingOrder = 42;
    layer.lightMask = SceneLightMask::layer3() | SceneLightMask::layer7();
    layer.receivesLight = false;

    const auto back = sceneLayerFromJson(toJson(layer), 0);
    UM_CHECK(back.has_value());
    if (!back) return;
    UM_CHECK(back->id == layer.id);
    UM_CHECK(back->name == layer.name);
    UM_CHECK(back->isHidden);
    UM_CHECK_NEAR(back->opacity, 0.5, 1e-6);
    UM_CHECK_NEAR(back->positionZ, 400.0, 1e-4);
    UM_CHECK_NEAR(back->shear.x, 0.25, 1e-6);
    UM_CHECK(back->sortingOrder == 42);
    UM_CHECK(back->lightMask == layer.lightMask);
    UM_CHECK(!back->receivesLight);
    UM_CHECK(std::holds_alternative<ScenePlateContent>(back->content));
}

static void testEachLayerKindKeepsItsOwnPayload() {
    SceneLayer rig = plate(1, "rig");
    rig.content = SceneRigContent{Uuid(3, 3), 2.5f, 12, false};
    const auto rigBack = sceneLayerFromJson(toJson(rig), 0);
    UM_CHECK(rigBack.has_value());
    if (rigBack) {
        const auto* content = std::get_if<SceneRigContent>(&rigBack->content);
        UM_CHECK(content != nullptr);
        if (content) {
            UM_CHECK(content->clipId == Uuid(3, 3));
            UM_CHECK_NEAR(content->speed, 2.5, 1e-6);
            UM_CHECK(content->startFrame == 12);
            UM_CHECK(!content->loops);
        }
    }

    SceneLayer fill = plate(2, "fill");
    fill.content = SceneFillContent{SceneFill::solid(Vec4(0.2f, 0.4f, 0.6f, 1.0f))};
    const auto fillBack = sceneLayerFromJson(toJson(fill), 0);
    UM_CHECK(fillBack.has_value());
    if (fillBack) {
        const auto* content = std::get_if<SceneFillContent>(&fillBack->content);
        UM_CHECK(content != nullptr);
        if (content) UM_CHECK_NEAR(content->fill.topColor.z, 0.6, 1e-6);
    }
}

static void testKindIsAStringNotAnOrdinal() {
    // An int raw value would make the on-disk format depend on the
    // declaration order of an enum, so inserting a case between two others
    // would silently re-read every saved scene as something else.
    SceneLayer rig = plate(1, "rig");
    rig.content = SceneRigContent{Uuid(3, 3), 1.0f, 0, true};
    const JsonValue j = toJson(rig);
    const JsonValue* kind = j.find("kind");
    UM_CHECK(kind != nullptr && kind->isString());
    if (kind && kind->isString()) UM_CHECK(kind->asString() == "rig");

    SceneMaterial material;
    material.parallaxMode = SceneParallaxMode::SilhouetteShell;
    const JsonValue* mode = toJson(material).find("parallaxMode");
    UM_CHECK(mode != nullptr && mode->isString());
    if (mode && mode->isString()) UM_CHECK(mode->asString() == "silhouetteShell");
}

// ---- Files that predate a feature --------------------------------------

static void testMissingSortingOrderBecomesTheIndexInTheFile() {
    // Before layers had numbers the stacking WAS the array order, so the
    // index reproduces exactly the draw order the file was saved with.
    const JsonValue j = parse(
        R"({"layers":[{"kind":"plate","assetID":"00000000-0000-0000-0000-000000000001","name":"a"},)"
        R"({"kind":"plate","assetID":"00000000-0000-0000-0000-000000000002","name":"b"},)"
        R"({"kind":"plate","assetID":"00000000-0000-0000-0000-000000000003","name":"c"}]})");
    const SceneComposition scene = sceneCompositionFromJson(j);
    UM_CHECK(scene.layers.size() == 3);
    if (scene.layers.size() == 3) {
        UM_CHECK(scene.layers[0].sortingOrder == 0);
        UM_CHECK(scene.layers[1].sortingOrder == 1);
        UM_CHECK(scene.layers[2].sortingOrder == 2);
        // Which means the draw order comes back as the file's order.
        const std::vector<SceneLayer> ordered = scene.drawOrderedLayers();
        UM_CHECK(ordered[0].name == "a" && ordered[2].name == "c");
    }
}

static void testMissingMaterialRestoresTheFlatSurface() {
    // The bit-for-bit promise: `isFlat` gates a branch the shader never
    // enters, so a project predating materials must come back flat and not
    // merely neutral-looking.
    const auto layer = sceneLayerFromJson(
        parse(R"({"kind":"plate","assetID":"00000000-0000-0000-0000-000000000001"})"), 0);
    UM_CHECK(layer.has_value());
    if (layer) UM_CHECK(isFlat(layer->material));
}

static void testMissingShearAndLightFieldsRestoreTheOldReading() {
    const auto layer = sceneLayerFromJson(
        parse(R"({"kind":"plate","assetID":"00000000-0000-0000-0000-000000000001"})"), 0);
    UM_CHECK(layer.has_value());
    if (!layer) return;
    // A missing slant is no slant.
    UM_CHECK(layer->shear == Vec2::zero());
    // Channel 1 and receiving, which is what makes a light added to an old
    // scene later actually reach anything.
    UM_CHECK(layer->lightMask == SceneLightMask::layer1());
    UM_CHECK(layer->receivesLight);
}

static void testAnExplicitlyEmptyLayerMaskStillLandsOnChannelOne() {
    // A layer on no channel is a card no light can ever touch, which is
    // indistinguishable from the file being wrong.
    const auto layer = sceneLayerFromJson(
        parse(R"({"kind":"plate","assetID":"00000000-0000-0000-0000-000000000001","lightMask":0})"),
        0);
    UM_CHECK(layer.has_value());
    if (layer) UM_CHECK(layer->lightMask == SceneLightMask::layer1());
}

static void testSceneWithoutLightsRestoresNeutralAmbient() {
    // The identity case the renderer skips outright.
    const SceneComposition scene = sceneCompositionFromJson(parse(R"({"layers":[]})"));
    UM_CHECK(scene.lights.empty());
    UM_CHECK(scene.ambient == SceneAmbient::neutral());
}

// ---- Files from a LATER build ------------------------------------------

static void testUnknownParallaxModeFallsBackToOffNotToAGuess() {
    // A file written by a later build naming a march this one cannot run
    // has to draw the surface it drew before marches existed.
    const SceneMaterial material =
        sceneMaterialFromJson(parse(R"({"parallaxMode":"conePrepass","parallaxDepth":0.2})"));
    UM_CHECK(material.parallaxMode == SceneParallaxMode::Off);
    // The rest of the record is still read -- only the mode is refused.
    UM_CHECK_NEAR(material.parallaxDepth, 0.2, 1e-6);
}

static void testUnknownLightKindAndBlendFallBackWithoutFailingTheFile() {
    const SceneLight light =
        sceneLightFromJson(parse(R"({"kind":"area","blend":"overlay","radius":123})"));
    UM_CHECK(light.kind == SceneLightKind::kPoint);
    UM_CHECK(light.blend == SceneLightBlend::kNormal);
    UM_CHECK_NEAR(light.radius, 123.0, 1e-4);
}

static void testALayerWhoseKindIsUnknownIsDroppedNotInvented() {
    const SceneComposition scene = sceneCompositionFromJson(parse(
        R"({"layers":[{"kind":"volumetric","name":"future"},)"
        R"({"kind":"plate","assetID":"00000000-0000-0000-0000-000000000001","name":"known"}]})"));
    UM_CHECK(scene.layers.size() == 1);
    if (scene.layers.size() == 1) UM_CHECK(scene.layers[0].name == "known");
}

static void testALayerMissingItsPayloadIsDropped() {
    // Restored as something it never was would be worse than absent.
    UM_CHECK(!sceneLayerFromJson(parse(R"({"kind":"rig"})"), 0).has_value());
    UM_CHECK(!sceneLayerFromJson(parse(R"({"kind":"plate"})"), 0).has_value());
    UM_CHECK(!sceneLayerFromJson(parse(R"({"kind":"fill"})"), 0).has_value());
}

// ---- Ranges enforced on the way IN -------------------------------------

static void testCorruptCameraCannotDivideByTanZero() {
    const SceneCamera camera =
        sceneCameraFromJson(parse(R"({"fieldOfView":0,"nearZ":-5,"farZ":-100})"));
    UM_CHECK(camera.fieldOfView >= 1.0f);
    UM_CHECK(camera.nearZ >= 0.01f);
    UM_CHECK(camera.farZ >= camera.nearZ + 1.0f);
    UM_CHECK(std::isfinite(camera.focalLength(1080.0f)));
    UM_CHECK(camera.focalLength(1080.0f) > 0.0f);
    // And the top end too: 400 degrees is not a camera.
    UM_CHECK(sceneCameraFromJson(parse(R"({"fieldOfView":400})")).fieldOfView <= 170.0f);
}

static void testConeCannotBeLitInsideOut() {
    // An inner angle exceeding its outer makes the smoothstep between them
    // run backwards, which reads as a spot lit inside out.
    const SceneLight light = sceneLightFromJson(parse(R"({"innerAngle":3.0,"outerAngle":0.4})"));
    UM_CHECK(light.innerAngle <= light.outerAngle);
    UM_CHECK_NEAR(light.outerAngle, 0.4, 1e-6);
    // And the outer angle itself cannot exceed pi.
    const SceneLight wide = sceneLightFromJson(parse(R"({"outerAngle":99})"));
    UM_CHECK(wide.outerAngle <= kPi + 1e-6f);
}

static void testEmptyLightMaskRestoresToAllChannels() {
    // A light that lights nothing is indistinguishable from the file being
    // wrong -- and note this is the OPPOSITE default from a layer's, which
    // lands on channel 1, because the two answer different questions.
    const SceneLight light = sceneLightFromJson(parse(R"({"mask":0})"));
    UM_CHECK(light.mask == SceneLightMask::all());
}

static void testNegativeLightScalarsAreClampedNotPassedThrough() {
    const SceneLight light = sceneLightFromJson(parse(
        R"({"radius":-50,"intensity":-2,"softness":9,"depthInfluence":-1,"normalInfluence":4})"));
    UM_CHECK_NEAR(light.radius, 0.0, 1e-6);
    UM_CHECK_NEAR(light.intensity, 0.0, 1e-6);
    UM_CHECK_NEAR(light.softness, 1.0, 1e-6);
    UM_CHECK_NEAR(light.depthInfluence, 0.0, 1e-6);
    UM_CHECK_NEAR(light.normalInfluence, 1.0, 1e-6);
    // A zero radius still leaves a band the lattice can be chosen from
    // without dividing by it.
    UM_CHECK(std::isfinite(light.bandWidth()));
}

static void testMaterialIsSanitizedOnTheWayIn() {
    const SceneMaterial material =
        sceneMaterialFromJson(parse(R"({"smoothness":-0.5,"contrast":-1,"normalStrength":99})"));
    UM_CHECK(material.smoothness >= 0.0f);
    UM_CHECK(material.contrast >= 0.0f);
    UM_CHECK(material.normalStrength <= 8.0f);
}

static void testCompositionFloorsKeepAScenePlayableAndRenderable() {
    const SceneComposition scene = sceneCompositionFromJson(
        parse(R"({"durationInFrames":0,"fps":9000,"renderSize":{"x":2,"y":-8}})"));
    UM_CHECK(scene.durationInFrames >= 1);
    UM_CHECK(scene.fps <= 240 && scene.fps >= 1);
    UM_CHECK(scene.renderSize.x >= 16.0f && scene.renderSize.y >= 16.0f);
}

static void testFlyCameraIsClampedToWhereTheControlsCanReach() {
    const SceneViewCamera camera = sceneViewCameraFromJson(
        parse(R"({"distance":0.001,"pitch":99,"fieldOfView":0})"));
    UM_CHECK(camera.distance >= SceneViewCamera::kMinDistance);
    UM_CHECK(camera.pitch <= SceneViewCamera::kPitchLimit);
    UM_CHECK(camera.fieldOfView >= 1.0f);
    const SceneViewCamera far = sceneViewCameraFromJson(parse(R"({"distance":1e12})"));
    UM_CHECK(far.distance <= SceneViewCamera::kMaxDistance);
}

static void testFalloffCurveIsPinnedAtBothEndsOnTheWayIn() {
    // A curve that ended at 0.2 would draw a hard circle around every lamp
    // in the set, and an artist would report it as "the light has an edge"
    // without ever suspecting the curve.
    const SceneLight light =
        sceneLightFromJson(parse(R"({"falloff":[{"position":0,"value":0.5},)"
                                 R"({"position":1,"value":0.2}]})"));
    const std::vector<LightFalloffStop>& stops = light.falloff.stops();
    UM_CHECK(stops.size() >= 2);
    if (stops.size() >= 2) {
        UM_CHECK_NEAR(stops.front().value, 1.0, 1e-6);
        UM_CHECK_NEAR(stops.back().value, 0.0, 1e-6);
    }
}

static void testTruncatedFillColourDoesNotReadOffTheEnd() {
    const SceneFill fill = sceneFillFromJson(parse(R"({"topColor":[1,0],"bottomColor":[]})"));
    // Opaque black, the Swift fallback, rather than whatever was next in
    // memory.
    UM_CHECK(fill.topColor == Vec4(0, 0, 0, 1));
    UM_CHECK(fill.bottomColor == Vec4(0, 0, 0, 1));
}

// ---- The manifest ------------------------------------------------------

static void testAProjectThatNeverTouchedSceneWritesNoSceneKeys() {
    // Byte-stable for every project that does not use the mode.
    ProjectDocument document;
    const JsonValue j = toJson(document);
    UM_CHECK(j.find("sceneCompositions") == nullptr);
    UM_CHECK(j.find("sceneViewCamera") == nullptr);
    UM_CHECK(j.find("selectedSceneCompositionID") == nullptr);
}

static void testTheViewCameraIsTiedToTheCompositionsNotToItself() {
    // There is nowhere to stand in a project with no set, so a fly camera
    // without compositions is not written.
    ProjectDocument document;
    document.sceneViewCamera = SceneViewCamera{};
    UM_CHECK(toJson(document).find("sceneViewCamera") == nullptr);

    SceneComposition scene;
    scene.id = Uuid(4, 4);
    document.sceneCompositions = {scene};
    UM_CHECK(toJson(document).find("sceneViewCamera") != nullptr);
}

static void testSceneSectionsRoundTripThroughTheManifest() {
    ProjectDocument document;
    SceneComposition scene;
    scene.id = Uuid(11, 11);
    scene.name = "Shot 1";
    scene.durationInFrames = 120;
    scene.fps = 24;
    scene.layers = {plate(1, "backdrop"), plate(2, "hero")};
    scene.layers[1].sortingOrder = 30;
    SceneLight key;
    key.id = Uuid(21, 21);
    key.name = "key";
    key.kind = SceneLightKind::kSpot;
    key.blend = SceneLightBlend::kAdditive;
    scene.lights = {key};
    document.sceneCompositions = {scene};
    document.selectedSceneCompositionID = Uuid(11, 11);
    SceneViewCamera fly;
    fly.distance = 2400.0f;
    document.sceneViewCamera = fly;

    const ProjectDocument back = projectDocumentFromJson(toJson(document));
    UM_CHECK(back.sceneCompositions.size() == 1);
    if (back.sceneCompositions.size() == 1) {
        const SceneComposition& restored = back.sceneCompositions[0];
        UM_CHECK(restored.name == "Shot 1");
        UM_CHECK(restored.durationInFrames == 120 && restored.fps == 24);
        UM_CHECK(restored.layers.size() == 2);
        if (restored.layers.size() == 2) UM_CHECK(restored.layers[1].sortingOrder == 30);
        UM_CHECK(restored.lights.size() == 1);
        if (restored.lights.size() == 1) {
            UM_CHECK(restored.lights[0].kind == SceneLightKind::kSpot);
            UM_CHECK(restored.lights[0].blend == SceneLightBlend::kAdditive);
            UM_CHECK(restored.lights[0].name == "key");
        }
    }
    UM_CHECK(back.selectedSceneCompositionID == Uuid(11, 11));
    UM_CHECK(back.sceneViewCamera.has_value());
    if (back.sceneViewCamera) UM_CHECK_NEAR(back.sceneViewCamera->distance, 2400.0, 1e-3);
}

static void testSceneSectionsNoLongerFallIntoUnrecognized() {
    // They used to ride in `unrecognized` precisely so a load/save cycle
    // would not destroy them. They are modelled now, so they must not be
    // BOTH modelled and preserved -- that would write each key twice
    // through two different paths.
    const JsonValue file = parse(
        R"({"version":1,"sceneCompositions":[{"name":"S","layers":[]}],)"
        R"("sceneViewCamera":{"distance":900},"editorState":{"zoom":1.5}})");
    const ProjectDocument document = projectDocumentFromJson(file);
    UM_CHECK(document.unrecognized.find("sceneCompositions") == document.unrecognized.end());
    UM_CHECK(document.unrecognized.find("sceneViewCamera") == document.unrecognized.end());
    UM_CHECK(document.sceneCompositions.size() == 1);
    // And what is STILL not modelled keeps being preserved, which is the
    // guarantee moving these out must not break.
    UM_CHECK(document.unrecognized.find("editorState") != document.unrecognized.end());
    const JsonValue written = toJson(document);
    const JsonValue* editorState = written.find("editorState");
    UM_CHECK(editorState != nullptr && editorState->isObject());
    if (editorState != nullptr && editorState->isObject()) {
        const JsonValue* zoom = editorState->find("zoom");
        UM_CHECK(zoom != nullptr);
        if (zoom) UM_CHECK_NEAR(zoom->asDouble(), 1.5, 1e-9);
    }
}

static void testAnOldFileWithNoSceneSectionsOpensUntouched() {
    const ProjectDocument document = projectDocumentFromJson(parse(R"({"version":1})"));
    UM_CHECK(document.sceneCompositions.empty());
    UM_CHECK(!document.sceneViewCamera.has_value());
    UM_CHECK(!document.selectedSceneCompositionID.has_value());
    // And writing it back does not invent the sections.
    UM_CHECK(toJson(document).find("sceneCompositions") == nullptr);
}

UM_TEST_MAIN_BEGIN()
testLayerRoundTripsEveryField();
testEachLayerKindKeepsItsOwnPayload();
testKindIsAStringNotAnOrdinal();
testMissingSortingOrderBecomesTheIndexInTheFile();
testMissingMaterialRestoresTheFlatSurface();
testMissingShearAndLightFieldsRestoreTheOldReading();
testAnExplicitlyEmptyLayerMaskStillLandsOnChannelOne();
testSceneWithoutLightsRestoresNeutralAmbient();
testUnknownParallaxModeFallsBackToOffNotToAGuess();
testUnknownLightKindAndBlendFallBackWithoutFailingTheFile();
testALayerWhoseKindIsUnknownIsDroppedNotInvented();
testALayerMissingItsPayloadIsDropped();
testCorruptCameraCannotDivideByTanZero();
testConeCannotBeLitInsideOut();
testEmptyLightMaskRestoresToAllChannels();
testNegativeLightScalarsAreClampedNotPassedThrough();
testMaterialIsSanitizedOnTheWayIn();
testCompositionFloorsKeepAScenePlayableAndRenderable();
testFlyCameraIsClampedToWhereTheControlsCanReach();
testFalloffCurveIsPinnedAtBothEndsOnTheWayIn();
testTruncatedFillColourDoesNotReadOffTheEnd();
testAProjectThatNeverTouchedSceneWritesNoSceneKeys();
testTheViewCameraIsTiedToTheCompositionsNotToItself();
testSceneSectionsRoundTripThroughTheManifest();
testSceneSectionsNoLongerFallIntoUnrecognized();
testAnOldFileWithNoSceneSectionsOpensUntouched();
UM_TEST_MAIN_END()
