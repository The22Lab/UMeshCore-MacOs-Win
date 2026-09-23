// Tests for EditorScene's Scene-mode half, absorbed from SceneManager in
// Phase 6a: compositions, layers, lights, the Scene selection, light and
// camera keys, sampling at a Scene frame, and the view/shot alignments.
//
// One test pins a Swift gap the port closes (convention #3):
// `pruneSceneSelection` had no call site, so undo left a vanished light
// selected.

#include "umeshcore/Editor/EditorScene.h"

#include <algorithm>
#include <cmath>

#include "TestHarness.h"

using namespace umeshcore;

namespace {

constexpr float kPiF = 3.14159265358979323846f;

EditorScene sceneWithComposition() {
    EditorScene scene;
    scene.ensureSceneCompositionExists();
    return scene;
}

Uuid compID(const EditorScene& scene) { return scene.sceneCompositions.front().id; }

SceneLayer plate(const std::string& name, int sortingOrder) {
    SceneLayer l;
    l.id = Uuid::generate();
    l.name = name;
    l.sortingOrder = sortingOrder;
    l.content = ScenePlateContent{Uuid::generate()};
    return l;
}

} // namespace

// ---- Compositions --------------------------------------------------------------

static void testTheFirstSceneCarriesTheRigOnTheFocalPlane() {
    EditorScene empty;
    empty.ensureSceneCompositionExists();
    UM_CHECK(empty.sceneCompositions.size() == 1);
    UM_CHECK(empty.sceneCompositions[0].layers.empty()); // nothing to show
    UM_CHECK(empty.sceneCompositions[0].name == "Scene 1");
    UM_CHECK(empty.sceneCompositions[0].durationInFrames == 91); // 0...90 inclusive
    UM_CHECK(empty.selectedSceneCompositionID == empty.sceneCompositions[0].id);

    EditorScene rigged;
    rigged.addImage(Uuid::generate(), "arm", Vec2(64, 64), Vec2(0, 0), std::nullopt);
    rigged.projectFramesPerSecond = 29.5; // Swift `.rounded()`: half away from zero
    rigged.ensureSceneCompositionExists();
    const SceneComposition& c = rigged.sceneCompositions[0];
    UM_CHECK(c.fps == 30);
    UM_CHECK(c.layers.size() == 1 && c.layers[0].name == "Rig 1");
    UM_CHECK(std::holds_alternative<SceneRigContent>(c.layers[0].content));
    // At the focal plane the projection scale is exactly 1: a rig there is
    // the size the Editor showed it. (540 / tan(22.5 deg) in front of -1200.)
    UM_CHECK_NEAR(c.layers[0].positionZ, -1200.0 + 540.0 / std::tan(22.5 * 3.14159265358979 / 180.0), 1e-2);
    UM_CHECK_NEAR(c.layers[0].positionZ, EditorScene::defaultLayerZ(c), 1e-6);

    // Idempotent.
    rigged.ensureSceneCompositionExists();
    UM_CHECK(rigged.sceneCompositions.size() == 1);
}

static void testPlatesLandInFrontWithTheirMapsAttachedButOff() {
    EditorScene scene = sceneWithComposition();
    const Uuid comp = compID(scene);
    scene.addSceneLayer(plate("back", 4), comp);
    const Uuid normal = Uuid::generate();
    std::vector<EditorScene::ScenePlateAsset> assets{
        {Uuid::generate(), "sky", true, normal, std::nullopt},
        {Uuid::generate(), "sky_n", false, std::nullopt, std::nullopt}, // a map, not a plate
        {Uuid::generate(), "hills", true, std::nullopt, std::nullopt},
    };
    const std::vector<Uuid> added = scene.addScenePlates(assets, comp);
    UM_CHECK(added.size() == 2);
    const SceneComposition& c = scene.sceneCompositions[0];
    const SceneLayer* sky = c.layer(added[0]);
    const SceneLayer* hills = c.layer(added[1]);
    UM_CHECK(sky != nullptr && hills != nullptr);
    UM_CHECK(sky->sortingOrder == 5 && hills->sortingOrder == 6); // in front of 4, in import order
    UM_CHECK(sky->material.normalMapAssetId == std::optional<Uuid>(normal));
    UM_CHECK(sky->material.parallaxMode == SceneMaterial{}.parallaxMode); // not switched on by an import
    UM_CHECK_NEAR(sky->positionZ, EditorScene::defaultLayerZ(c), 1e-6);
    // One undo entry per plate.
    scene.undo();
    UM_CHECK(scene.sceneCompositions[0].layers.size() == 2);
}

static void testMovingALayerSwapsNumbersAndKeepsTheGrouping() {
    EditorScene scene = sceneWithComposition();
    const Uuid comp = compID(scene);
    const SceneLayer a = plate("a", 10), b = plate("b", 20), c = plate("c", 30);
    for (const auto& l : {a, b, c}) scene.addSceneLayer(l, comp);
    scene.moveSceneLayer(a.id, comp, /*forward=*/true);
    const SceneComposition& s = scene.sceneCompositions[0];
    UM_CHECK(s.layer(a.id)->sortingOrder == 20 && s.layer(b.id)->sortingOrder == 10);
    UM_CHECK(s.layer(c.id)->sortingOrder == 30); // 10/20/30 survives, not 0/1/2
    // At the front there is nowhere to go.
    scene.moveSceneLayer(c.id, comp, true);
    UM_CHECK(scene.sceneCompositions[0].layer(c.id)->sortingOrder == 30);

    // Two cards on one number: the tie (array order) is what moves.
    EditorScene tied = sceneWithComposition();
    const Uuid tc = compID(tied);
    const SceneLayer x = plate("x", 0), y = plate("y", 0);
    tied.addSceneLayer(x, tc);
    tied.addSceneLayer(y, tc);
    UM_CHECK(tied.sceneCompositions[0].drawOrderedLayers().back().id == y.id);
    tied.moveSceneLayer(x.id, tc, true);
    UM_CHECK(tied.sceneCompositions[0].drawOrderedLayers().back().id == x.id);
}

// ---- Lights and the selection ------------------------------------------------------

static void testANewLightIsPlacedWhereItWillBeSeen() {
    EditorScene scene = sceneWithComposition();
    const Uuid comp = compID(scene);
    const std::optional<Uuid> spot = scene.addSceneLight(SceneLightKind::kSpot, comp);
    UM_CHECK(spot.has_value());
    UM_CHECK(scene.selectedSceneLightID() == spot);
    const SceneLight light = *scene.selectedSceneLight();
    UM_CHECK(light.name == "Spot 1");
    const float focal = scene.sceneCompositions[0].camera.focalLength(1080.0f);
    UM_CHECK_NEAR(light.positionZ, -1200.0f + focal * 0.66f, 1e-3);
    UM_CHECK_NEAR(light.radius, std::sqrt(1920.0 * 1920.0 + 1080.0 * 1080.0) * 0.75, 1e-2);
    UM_CHECK_NEAR(light.elevation, kPiF / 2, 1e-6); // pointing into the set
    const std::optional<Uuid> global = scene.addSceneLight(SceneLightKind::kDirectional, comp);
    UM_CHECK(scene.sceneCompositions[0].light(*global)->name == "Global 2");

    // Light order is blend order, and moving is a real swap.
    scene.moveSceneLight(*global, comp, /*forward=*/false);
    UM_CHECK(scene.sceneCompositions[0].lights[0].id == *global);

    // Removing the selected light clears the selection.
    scene.selectSceneLight(spot);
    scene.removeSceneLight(*spot, comp);
    UM_CHECK(scene.sceneSelection.isEmpty());
}

// SWIFT GAP, CLOSED: `pruneSceneSelection` existed and was never called,
// so undoing "add light" left the vanished light selected.
static void testUndoDropsASelectionWhoseLightIsGone() {
    EditorScene scene = sceneWithComposition();
    const std::optional<Uuid> light = scene.addSceneLight(SceneLightKind::kPoint, compID(scene));
    UM_CHECK(scene.selectedSceneLightID() == light);
    scene.undo();
    UM_CHECK(scene.sceneCompositions[0].lights.empty());
    UM_CHECK(!scene.selectedSceneLightID().has_value());
    // Redo brings the light back, not the selection -- nothing re-selects.
    scene.redo();
    UM_CHECK(scene.sceneCompositions[0].lights.size() == 1);
}

// ---- Sampling at a Scene frame ---------------------------------------------------------

// Every channel falls back to the AUTHORED value: keying the FOV alone
// must not drag the untracked position to the origin.
static void testTheShotSamplesItsTracksAndKeepsWhatIsNotKeyed() {
    EditorScene scene = sceneWithComposition();
    SceneComposition c = scene.sceneCompositions[0];
    c.camera.position = Vec2(300, -40);
    const Uuid cam = SceneAnimationTarget::camera();
    scene.sceneAnimationClip.upsertKeyframe(cam, AnimationTrackProperty::CameraFOV, 0, ScalarValue{30.0f});
    scene.sceneAnimationClip.upsertKeyframe(cam, AnimationTrackProperty::CameraFOV, 10, ScalarValue{60.0f});
    const SceneCamera mid = scene.sceneCamera(c, 5);
    UM_CHECK_NEAR(mid.fieldOfView, 45.0, 1e-4);
    UM_CHECK(mid.position == Vec2(300, -40));
    UM_CHECK(mid.positionZ == c.camera.positionZ);

    // Clamped where sampled: a key below 1 degree never reaches tan().
    scene.sceneAnimationClip.upsertKeyframe(cam, AnimationTrackProperty::CameraFOV, 20, ScalarValue{0.25f});
    UM_CHECK(scene.sceneCamera(c, 20).fieldOfView == 1.0f);

    // No camera tracks at all: the authored camera, untouched.
    EditorScene plain = sceneWithComposition();
    UM_CHECK(plain.sceneCamera(c, 7) == c.camera);
}

static void testLightsSampleClampedAndOnlyWhereKeyed() {
    EditorScene scene = sceneWithComposition();
    const Uuid comp = compID(scene);
    const Uuid id = *scene.addSceneLight(SceneLightKind::kSpot, comp);
    const SceneComposition c = scene.sceneCompositions[0];
    const SceneLight authored = *c.light(id);
    AnimationClip& clip = scene.sceneAnimationClip;
    clip.upsertKeyframe(id, AnimationTrackProperty::LightIntensity, 0, ScalarValue{-2.0f});
    // A crossed pair: inner 1.0 beyond outer 0.5.
    clip.upsertKeyframe(id, AnimationTrackProperty::LightAngles, 0, Vector2Value{Vec2(1.0f, 0.5f)});
    clip.upsertKeyframe(id, AnimationTrackProperty::LightColorG, 0, ScalarValue{1.7f});

    const SceneLight sampled = scene.sceneLights(c, 0)[0];
    UM_CHECK(sampled.intensity == 0.0f);          // a light never subtracts
    UM_CHECK(sampled.radius == authored.radius);  // untracked: authored
    UM_CHECK(sampled.outerAngle == 0.5f);
    UM_CHECK(sampled.innerAngle == 0.5f);         // clamped to the ARRIVING outer
    UM_CHECK(sampled.color == Vec3(1.0f, 1.0f, 1.0f));
    UM_CHECK(sampled.position == authored.position);
}

static void testKeyingALightWritesEveryChannelAndRemovingClearsTheFrame() {
    EditorScene scene = sceneWithComposition();
    const Uuid comp = compID(scene);
    const Uuid id = *scene.addSceneLight(SceneLightKind::kPoint, comp);
    SceneLight light = *scene.sceneCompositions[0].light(id);
    scene.keySceneLight(light, 3);
    light.intensity = 0.5f;
    scene.keySceneLight(light, 9);
    for (AnimationTrackProperty p : lightProperties()) {
        UM_CHECK(scene.sceneAnimationClip.keyframesFor(id, p).size() == 2);
    }
    UM_CHECK(scene.sceneLightKeyFrames(id) == (std::vector<int>{3, 9}));
    scene.removeSceneLightKey(id, 3);
    UM_CHECK(scene.sceneLightKeyFrames(id) == std::vector<int>{9});

    scene.keySceneCamera(scene.sceneCompositions[0], 12);
    scene.keySceneCamera(scene.sceneCompositions[0], 2);
    UM_CHECK(scene.sceneCameraKeyFrames() == (std::vector<int>{2, 12}));
    scene.removeSceneCameraKey(12);
    UM_CHECK(scene.sceneCameraKeyFrames() == std::vector<int>{2});
    for (AnimationTrackProperty p : cameraProperties()) {
        UM_CHECK(scene.sceneAnimationClip.keyframesFor(SceneAnimationTarget::camera(), p).size() == 1);
    }
}

// ---- View and shot ---------------------------------------------------------------------

// Standing where the shot is means the view's EYE is the shot's position --
// the property one shared "forward" exists to guarantee.
static void testStandingWhereTheShotIsPutsTheEyeOnIt() {
    EditorScene scene = sceneWithComposition();
    SceneComposition c = scene.sceneCompositions[0];
    c.camera.position = Vec2(120, -80);
    c.camera.positionZ = -900;
    c.camera.rotation3D = Vec3(0.3f, -0.7f, 0.2f);
    c.camera.fieldOfView = 38;
    scene.replaceSceneComposition(c, false);
    scene.alignSceneViewToCamera(c.id);
    const Vec3 eye = scene.sceneViewCamera.eye();
    UM_CHECK_NEAR(eye.x, 120.0, 1e-2);
    UM_CHECK_NEAR(eye.y, -80.0, 1e-2);
    UM_CHECK_NEAR(eye.z, -900.0, 1e-2);
    UM_CHECK(scene.sceneViewCamera.fieldOfView == 38.0f);

    // And back: the shot put where the artist stands is the same shot
    // (roll aside, which the orbit camera does not have).
    scene.alignSceneCameraToView(c.id);
    const SceneCamera& shot = scene.sceneCompositions[0].camera;
    UM_CHECK_NEAR(shot.position.x, 120.0, 1e-2);
    UM_CHECK_NEAR(shot.positionZ, -900.0, 1e-2);
    UM_CHECK_NEAR(shot.rotation3D.x, 0.3, 1e-6);
    UM_CHECK(shot.rotation3D.z == 0.0f);

    // At the pole the pitch is clamped, as the orbit camera requires.
    c.camera.rotation3D = Vec3(2.0f, 0, 0);
    scene.replaceSceneComposition(c, false);
    scene.alignSceneViewToCamera(c.id);
    UM_CHECK(scene.sceneViewCamera.pitch == SceneViewCamera::kPitchLimit);
}

static void testFramingFitsTheShotWithAMargin() {
    EditorScene scene = sceneWithComposition();
    const SceneComposition c = scene.sceneCompositions[0];
    scene.frameSceneView(c.id, std::nullopt);
    // Nothing selected: the shot's frame. Straight ahead from (0,0,-1200) by
    // the focal length; extent 1920; distance = 960 * 1.25 / tan(22.5 deg).
    const double focal = 540.0 / std::tan(22.5 * 3.14159265358979 / 180.0);
    UM_CHECK_NEAR(scene.sceneViewCamera.pivot.z, -1200.0 + focal, 1e-2);
    UM_CHECK_NEAR(scene.sceneViewCamera.pivot.x, 0.0, 1e-4);
    UM_CHECK_NEAR(scene.sceneViewCamera.distance, 1200.0 / std::tan(22.5 * 3.14159265358979 / 180.0), 1e-1);
    // Framing is navigation: no undo entry.
    UM_CHECK(!scene.undoRedo.canUndo());

    // A selected card: pivot on it.
    EditorScene withCard = sceneWithComposition();
    SceneLayer card = plate("card", 0);
    card.position = Vec2(50, 60);
    card.positionZ = 400;
    withCard.addSceneLayer(card, compID(withCard));
    withCard.frameSceneView(compID(withCard), card.id);
    UM_CHECK(withCard.sceneViewCamera.pivot == Vec3(50, 60, 400));
}

UM_TEST_MAIN_BEGIN()
    testTheFirstSceneCarriesTheRigOnTheFocalPlane();
    testPlatesLandInFrontWithTheirMapsAttachedButOff();
    testMovingALayerSwapsNumbersAndKeepsTheGrouping();
    testANewLightIsPlacedWhereItWillBeSeen();
    testUndoDropsASelectionWhoseLightIsGone();
    testTheShotSamplesItsTracksAndKeepsWhatIsNotKeyed();
    testLightsSampleClampedAndOnlyWhereKeyed();
    testKeyingALightWritesEveryChannelAndRemovingClearsTheFrame();
    testStandingWhereTheShotIsPutsTheEyeOnIt();
    testFramingFitsTheShotWithAMargin();
UM_TEST_MAIN_END()
