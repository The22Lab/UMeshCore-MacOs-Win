// Tests for the Scene model: Model/Scene/{SceneLayer, SceneComposition,
// SceneCamera, SceneLight, SceneMaterial, SceneRenderAdapters}.h, ported
// from `Data/Scene/*.swift`.
//
// The model's headers name the bugs each piece exists to prevent, so these
// assert those properties rather than re-deriving the arithmetic:
//
//   - `orientation()` is a ROTATION even for a sheared card. The Swift
//     header records the gizmo bug that made it exist -- a frame taken by
//     differencing `planePoint` is not orthonormal once shear is on -- and
//     the test reproduces that wrong frame rather than describing it.
//   - Shear is expressed in SCALED units, which is the order being the
//     definition.
//   - The draw order is stable: two cards on one layer never swap.
//   - A layer is FLAT, which is the invariant the whole of Phase 4's
//     lighting rests on, so its corners lie exactly in its lighting plane.
//   - The camera's focal length is the distance at which one world unit
//     covers one pixel -- checked against `SceneProjection` itself, not
//     against the formula that produced it.

#include "umeshcore/Model/Scene/SceneComposition.h"
#include "umeshcore/Model/Scene/SceneRenderAdapters.h"

#include <cmath>

#include "TestHarness.h"

using namespace umeshcore;

namespace {

constexpr float kPi = 3.14159265358979323846f;

SceneLayer plate(int sortingOrder, const char* name) {
    SceneLayer layer;
    layer.id = Uuid(1, static_cast<std::uint64_t>(sortingOrder) + 100);
    layer.name = name;
    layer.sortingOrder = sortingOrder;
    layer.content = ScenePlateContent{Uuid(9, 9)};
    return layer;
}

} // namespace

static void testShearIsExpressedInScaledUnits() {
    // THE ORDER IS THE DEFINITION: scale, then shear, then roll. A scaled
    // card slants by the amount the number says rather than by that amount
    // times its scale.
    SceneLayer layer;
    layer.scale = Vec2(2, 3);
    layer.shear = Vec2(0.5f, 0);
    const Vec2 point = layer.planePoint(Vec2(0, 1));
    // scale -> (0, 3); shear x slides by the height: (1.5, 3).
    UM_CHECK_NEAR(point.x, 1.5, 1e-5);
    UM_CHECK_NEAR(point.y, 3.0, 1e-5);
    // Shearing BEFORE the scale would have given 1.0 -- the same slant
    // multiplied by the card's own width.
    UM_CHECK(std::fabs(point.x - 1.0f) > 0.4f);

    // Roll comes last, so it turns the already-sheared point.
    layer.shear = Vec2::zero();
    layer.scale = Vec2(1, 1);
    layer.rotation = kPi * 0.5f;
    const Vec2 turned = layer.planePoint(Vec2(1, 0));
    UM_CHECK_NEAR(turned.x, 0.0, 1e-5);
    UM_CHECK_NEAR(turned.y, 1.0, 1e-5);
}

static void testOrientationStaysARotationWhereDifferencingTheCardDoesNot() {
    // The whole of the gizmo bug, reproduced. A sheared card's plane axes
    // are not perpendicular; normalising the two vectors that come back
    // fixes their lengths and can do nothing about the angle between them.
    SceneLayer layer;
    layer.scale = Vec2(2.0f, 0.5f);
    layer.shear = Vec2(0.8f, 0.0f);
    layer.rotation = 0.4f;
    layer.rotation3D = Vec3(0.3f, -0.6f, 0);

    const SceneLayer::Orientation axes = layer.orientation();
    UM_CHECK_NEAR(length(axes.x), 1.0, 1e-5);
    UM_CHECK_NEAR(length(axes.y), 1.0, 1e-5);
    UM_CHECK_NEAR(length(axes.z), 1.0, 1e-5);
    UM_CHECK_NEAR(dot(axes.x, axes.y), 0.0, 1e-5);
    UM_CHECK_NEAR(dot(axes.x, axes.z), 0.0, 1e-5);
    UM_CHECK_NEAR(dot(axes.y, axes.z), 0.0, 1e-5);

    // The frame the gizmo used to build: difference the card's own
    // transform and normalise. Same card, and NOT a rotation.
    const Vec3 origin = layer.liftToWorld(layer.planePoint(Vec2(0, 0)));
    const Vec3 naiveX = normalize(layer.liftToWorld(layer.planePoint(Vec2(1, 0))) - origin);
    const Vec3 naiveY = normalize(layer.liftToWorld(layer.planePoint(Vec2(0, 1))) - origin);
    UM_CHECK(std::fabs(dot(naiveX, naiveY)) > 0.1f); // visibly not square
}

static void testTheLiftPreservesLengthsAndAngles() {
    // Linear and orthonormal: it takes a plane to a plane, which is why
    // the card's corners and the gizmo's frame can share it.
    SceneLayer layer;
    layer.rotation3D = Vec3(0.7f, 1.1f, 0);
    const Vec2 a(3, 0), b(0, 5);
    UM_CHECK_NEAR(length(layer.liftToWorld(a)), 3.0, 1e-4);
    UM_CHECK_NEAR(length(layer.liftToWorld(b)), 5.0, 1e-4);
    UM_CHECK_NEAR(dot(layer.liftToWorld(a), layer.liftToWorld(b)), 0.0, 1e-3);
    // Linear: the lift of a sum is the sum of the lifts.
    const Vec3 sum = layer.liftToWorld(a + b);
    const Vec3 parts = layer.liftToWorld(a) + layer.liftToWorld(b);
    UM_CHECK_NEAR(length(sum - parts), 0.0, 1e-4);
}

static void testACardIsFlatSoItsCornersLieInItsLightingPlane() {
    // The founding invariant, and the one Phase 4's lighting rests on: the
    // ray through any pixel meets this plane at the world point that is
    // actually there.
    SceneLayer layer;
    layer.position = Vec2(120, -40);
    layer.positionZ = 300;
    layer.rotation = 0.5f;
    layer.rotation3D = Vec3(0.4f, 0.9f, 0);
    layer.scale = Vec2(1.7f, 0.6f);
    layer.shear = Vec2(0.3f, -0.2f);

    const SceneLayer::Plane plane = layer.lightingPlane();
    UM_CHECK_NEAR(length(plane.normal), 1.0, 1e-4);
    for (const Vec3& corner : cardCorners(layer, Vec2(-200, -120), Vec2(200, 120))) {
        UM_CHECK_NEAR(dot(corner - plane.point, plane.normal), 0.0, 1e-2);
    }
    // And the corners come back in a fixed order: top-left, top-right,
    // bottom-right, bottom-left, as seen from the front.
    SceneLayer plain;
    const auto corners = cardCorners(plain, Vec2(-10, -5), Vec2(10, 5));
    UM_CHECK(corners[0].x < corners[1].x); // left, then right
    UM_CHECK(corners[0].y > corners[3].y); // top, then bottom
}

static void testTheTangentCarriesTheMirroringAndNotTheScale() {
    SceneLayer layer;
    layer.scale = Vec2(3, 1);
    const SceneLayer::TangentFrame upright = layer.lightingTangent();
    UM_CHECK_NEAR(length(upright.tangent), 1.0, 1e-5); // magnitude left out
    UM_CHECK(upright.handed == 1.0f);

    // A negative scale mirrors the card, so image +x points the other way
    // and the handedness flips -- a basis not told it is mirrored lights
    // the relief from the wrong side.
    layer.scale = Vec2(-3, 1);
    const SceneLayer::TangentFrame mirrored = layer.lightingTangent();
    UM_CHECK(mirrored.handed == -1.0f);
    UM_CHECK_NEAR(length(mirrored.tangent + upright.tangent), 0.0, 1e-5);

    // Both axes negative is a 180-degree turn, not a mirror.
    layer.scale = Vec2(-3, -1);
    UM_CHECK(layer.lightingTangent().handed == 1.0f);

    // A degenerate axis keeps the UNMIRRORED reading: sign(0) is zero, and
    // a frame multiplied by zero is not a frame.
    layer.scale = Vec2(0, 0);
    UM_CHECK(layer.lightingTangent().handed == 1.0f);
    UM_CHECK_NEAR(length(layer.lightingTangent().tangent), 1.0, 1e-5);
}

static void testRigFrameFreezesClampsAndWrapsWithoutGoingNegative() {
    SceneLayer layer;
    layer.content = SceneRigContent{Uuid(2, 2), 1.0f, 10, true};
    UM_CHECK(layer.rigFrame(5, 60).value() == 15);
    // A speed of zero freezes on the start frame rather than dividing the
    // timeline by nothing.
    std::get<SceneRigContent>(layer.content).speed = 0.0f;
    UM_CHECK(layer.rigFrame(999, 60).value() == 10);

    // Looping wraps, and a negative index must not come back: C++'s % (like
    // Swift's) keeps the sign of the dividend.
    std::get<SceneRigContent>(layer.content).speed = -1.0f;
    std::get<SceneRigContent>(layer.content).startFrame = 0;
    for (int frame = 0; frame < 200; ++frame) {
        const int wrapped = layer.rigFrame(frame, 60).value();
        UM_CHECK(wrapped >= 0 && wrapped < 60);
    }
    UM_CHECK(layer.rigFrame(1, 60).value() == 59);

    // Not looping clamps to the clip instead.
    std::get<SceneRigContent>(layer.content).loops = false;
    UM_CHECK(layer.rigFrame(1, 60).value() == 0);
    std::get<SceneRigContent>(layer.content).speed = 5.0f;
    UM_CHECK(layer.rigFrame(100, 60).value() == 59);

    // A clip with no frames freezes rather than dividing by zero.
    UM_CHECK(layer.rigFrame(7, 0).value() == 0);

    // Anything that is not a rig has no frame at all.
    SceneLayer plate;
    plate.content = ScenePlateContent{Uuid(3, 3)};
    UM_CHECK(!plate.rigFrame(5, 60).has_value());
    SceneLayer fill;
    UM_CHECK(!fill.rigFrame(5, 60).has_value());
    UM_CHECK(contentIsFill(fill.content));
}

static void testDrawOrderIsStableAndDepthDoesNotReorderAnything() {
    SceneComposition scene;
    SceneLayer back = plate(0, "back");
    SceneLayer middleA = plate(10, "middleA");
    SceneLayer middleB = plate(10, "middleB");
    SceneLayer front = plate(30, "front");
    // The one in front in Z, but on the BACK layer: depth must not
    // reorder anything.
    back.positionZ = -5000;
    front.positionZ = 5000;
    scene.layers = {front, middleA, back, middleB};

    const auto order = scene.drawOrderedLayers();
    UM_CHECK(order.size() == 4);
    UM_CHECK(order[0].name == "back");
    // Ties broken by the array's own order, which is the artist's creation
    // order -- run after run, not by chance.
    UM_CHECK(order[1].name == "middleA");
    UM_CHECK(order[2].name == "middleB");
    UM_CHECK(order[3].name == "front");

    const auto reversed = scene.frontToBackLayers();
    UM_CHECK(reversed[0].name == "front" && reversed[3].name == "back");

    // Stable across repeated calls, and a swap in the array moves the tie
    // the other way -- which is the artist's decision, not the sort's.
    UM_CHECK(scene.drawOrderedLayers()[1].name == "middleA");
    scene.layers = {front, middleB, back, middleA};
    UM_CHECK(scene.drawOrderedLayers()[1].name == "middleB");
}

static void testVisibleLayersAndFrontSortingOrder() {
    SceneComposition scene;
    SceneLayer hidden = plate(5, "hidden");
    hidden.isHidden = true;
    SceneLayer ghost = plate(6, "ghost");
    ghost.opacity = 0.0005f; // below the threshold: nothing to draw
    SceneLayer shown = plate(7, "shown");
    scene.layers = {hidden, ghost, shown};

    const auto visible = scene.visibleLayers();
    UM_CHECK(visible.size() == 1 && visible[0].name == "shown");

    // A new layer lands in front of everything.
    UM_CHECK(scene.frontSortingOrder() == 8);
    UM_CHECK(SceneComposition{}.frontSortingOrder() == 0);

    // Lookup by id, and a miss is a miss rather than a default.
    UM_CHECK(scene.layer(shown.id) != nullptr);
    UM_CHECK(scene.layer(Uuid(7, 7)) == nullptr);
}

static void testTheCameraFocalLengthIsOnePixelPerUnit() {
    // Checked against `SceneProjection` itself rather than against the
    // formula that produced it: at the focal distance a one-unit segment
    // must cover exactly one pixel of view height, which is what makes a
    // Scene with its layers on the focal plane land on the pixels the 2D
    // path already produced.
    SceneCamera camera;
    camera.positionZ = -1000;
    const Vec2 renderSize(1920, 1080);
    const float focal = camera.focalLength(renderSize.y);
    const SceneProjection projection = sceneProjection(camera, renderSize);

    const float planeZ = camera.positionZ + focal;
    const auto centre = projection.project(Vec3(0, 0, planeZ));
    const auto oneUnitUp = projection.project(Vec3(0, 1, planeZ));
    UM_CHECK(centre.has_value() && oneUnitUp.has_value());
    UM_CHECK_NEAR(centre->y - oneUnitUp->y, 1.0, 1e-3);
    UM_CHECK_NEAR(centre->x, 960.0, 1e-3);
    UM_CHECK_NEAR(centre->y, 540.0, 1e-3);

    // And the shot's frame at that distance is exactly the render size.
    const auto frame = shotFrame(camera, renderSize, focal);
    UM_CHECK_NEAR(length(frame[1] - frame[0]), 1920.0, 1e-2);
    UM_CHECK_NEAR(length(frame[2] - frame[1]), 1080.0, 1e-2);
}

static void testTheFlyPreviewOfTheShotKeepsTheShotsFraming() {
    // `shotAsViewProjection` differs from `sceneProjection` only in its
    // clip planes -- it is the set seen from the side, where the shot's
    // own near plane would clip the preview for reasons that belong to the
    // render. Everything the artist judges framing by must agree.
    SceneCamera camera;
    camera.rotation3D = Vec3(0.2f, -0.35f, 0.1f);
    camera.nearZ = 500.0f; // deliberately aggressive
    const Vec2 renderSize(1280, 720);
    const SceneProjection shot = sceneProjection(camera, renderSize);
    const SceneProjection preview = shotAsViewProjection(camera, renderSize);

    UM_CHECK(shot.focalLength == preview.focalLength);
    UM_CHECK(preview.nearZ < shot.nearZ);
    const Vec3 point(120, -80, 900);
    const auto a = shot.project(point);
    const auto b = preview.project(point);
    UM_CHECK(a.has_value() && b.has_value());
    UM_CHECK_NEAR(a->x, b->x, 1e-2);
    UM_CHECK_NEAR(a->y, b->y, 1e-2);
}

static void testAMaterialThatAsksForNothingIsFlatAndSanitisingKeepsItSo() {
    const SceneMaterial flat;
    UM_CHECK(flat.isFlat());
    UM_CHECK(flat == SceneMaterial::flat());
    UM_CHECK(flat.sanitized() == flat); // the promise survives the clamp
    UM_CHECK(flat.parallaxMode == SceneParallaxMode::kOff);
    UM_CHECK(!parallaxClips(SceneParallaxMode::kOff));
    UM_CHECK(!parallaxClips(SceneParallaxMode::kOcclusion));
    UM_CHECK(parallaxClips(SceneParallaxMode::kSilhouetteClip));
    UM_CHECK(parallaxClips(SceneParallaxMode::kSilhouetteShell));
    // Only the shell grows the quad, which is the difference that lets a
    // layer paint outside the rectangle its own gizmo shows.
    UM_CHECK(!parallaxExpandsCard(SceneParallaxMode::kSilhouetteClip));
    UM_CHECK(parallaxExpandsCard(SceneParallaxMode::kSilhouetteShell));

    SceneMaterial mapped;
    mapped.normalStrength = 0.5f;
    UM_CHECK(!mapped.isFlat());
}

static void testSanitisingRefusesTheValuesThatLookLikeOtherBugs() {
    SceneMaterial broken;
    // A negative smoothness takes the slow path and computes a wrap with a
    // NEGATIVE width, which pushes the terminator the wrong way and looks
    // like an inverted light.
    broken.smoothness = -0.4f;
    // A negative depth walks the ray BACKWARDS out of the surface, which
    // does not look like a bad number -- it looks like the artwork sliding
    // off its own card.
    broken.parallaxDepth = -0.2f;
    // NaN makes the step count NaN, so the loop runs zero times and the
    // feature silently disables itself on one layer and nowhere else.
    broken.parallaxQuality = std::nanf("");
    broken.contrast = 99.0f;
    broken.normalStrength = std::nanf("");
    broken.parallaxOcclusionStrength = 5.0f;

    const SceneMaterial clean = broken.sanitized();
    UM_CHECK(clean.smoothness == 0.0f);
    UM_CHECK(clean.parallaxDepth == 0.0f);
    UM_CHECK(clean.parallaxQuality == 0.5f);   // the default, not zero
    UM_CHECK(clean.normalStrength == 1.0f);    // the default, not zero
    UM_CHECK(clean.contrast == 4.0f);          // clamped, not defaulted
    UM_CHECK(clean.parallaxOcclusionStrength == 1.0f);
    // Above 1 stays allowed where the header says it is useful.
    SceneMaterial strong;
    strong.normalStrength = 3.0f;
    UM_CHECK(strong.sanitized().normalStrength == 3.0f);
}

static void testTheLightModelFillsTheMathsParamsWithoutRederivingAnything() {
    SceneLight light;
    light.position = Vec2(120, -45);
    light.positionZ = -800;
    light.kind = SceneLightKind::kSpot;
    light.blend = SceneLightBlend::kScreen;
    light.radius = 900;
    light.softness = 0.25f;
    light.azimuth = 0.9f;
    light.elevation = -0.3f;
    light.mask = SceneLightMask::channel(2);

    const SceneLightParams params = light.params();
    UM_CHECK(params.world == Vec3(120, -45, -800));
    UM_CHECK(params.mask == light.mask.rawValue);
    UM_CHECK(params.kind == SceneLightKind::kSpot);

    // And the math reads it the way Phase 4 already agreed: the band comes
    // from radius and softness, the direction from the two angles.
    const PreparedLight prepared{params};
    UM_CHECK_NEAR(prepared.band, 900.0 * 0.25, 1e-3);
    UM_CHECK_NEAR(prepared.innerRadius, 900.0 * 0.75, 1e-3);
    UM_CHECK_NEAR(length(prepared.direction), 1.0, 1e-5);
    UM_CHECK_NEAR(prepared.origin.z, -800.0, 1e-4);

    // A disabled light is dropped when the lighting is built, not
    // filtered at every call site.
    SceneLight off = light;
    off.isEnabled = false;
    const SceneLighting lighting({light.params(), off.params()}, SceneAmbient::neutral());
    UM_CHECK(lighting.lights.size() == 1);
    // Masking is the performance control as much as the artistic one.
    UM_CHECK(lighting.lightsReaching(SceneLightMask::channel(2).rawValue).size() == 1);
    UM_CHECK(lighting.lightsReaching(SceneLightMask::channel(3).rawValue).empty());
}

static void testTheMaskIsEightChannelsAndReadsBackInOrder() {
    SceneLightMask mask;
    UM_CHECK(mask.isEmpty());
    mask = SceneLightMask::channel(0).unionWith(SceneLightMask::channel(4));
    UM_CHECK(!mask.isEmpty());
    UM_CHECK(mask.reaches(SceneLightMask::all()));
    UM_CHECK(!mask.reaches(SceneLightMask::channel(1)));
    // Ascending, always -- a label that reshuffles between runs is a bug
    // report.
    const std::vector<int> numbers = mask.channelNumbers();
    UM_CHECK(numbers.size() == 2 && numbers[0] == 1 && numbers[1] == 5);
    UM_CHECK(SceneLightMask::all().channelNumbers().size() == 8);
    UM_CHECK(SceneLightMask{}.channelNumbers().empty());
}

static void testTheFrontViewZoomIsClamped() {
    SceneFrontView view;
    UM_CHECK(view.isIdentity());
    view.zoomBy(100.0f);
    UM_CHECK(view.zoom == SceneFrontView::kMaxZoom);
    view.zoomBy(0.0001f);
    UM_CHECK(view.zoom == SceneFrontView::kMinZoom);
    UM_CHECK(!view.isIdentity());
}

static void testTheNeutralBackgroundIsARampAndNotATint() {
    // Grey rather than the dark blue it used to be: a blue ground is not
    // neutral, and every colour placed on the set was judged against a
    // tint. Still a ramp, so an empty scene reads as a space with a floor.
    const SceneFill neutral = SceneFill::neutral();
    UM_CHECK(!neutral.isFlat());
    UM_CHECK(neutral.topColor.x == neutral.topColor.y);
    UM_CHECK(neutral.topColor.y == neutral.topColor.z);
    UM_CHECK(neutral.bottomColor.x > neutral.topColor.x); // lighter floor
    UM_CHECK(SceneFill::solid(Vec4(1, 0, 0, 1)).isFlat());
}

UM_TEST_MAIN_BEGIN()
    testShearIsExpressedInScaledUnits();
    testOrientationStaysARotationWhereDifferencingTheCardDoesNot();
    testTheLiftPreservesLengthsAndAngles();
    testACardIsFlatSoItsCornersLieInItsLightingPlane();
    testTheTangentCarriesTheMirroringAndNotTheScale();
    testRigFrameFreezesClampsAndWrapsWithoutGoingNegative();
    testDrawOrderIsStableAndDepthDoesNotReorderAnything();
    testVisibleLayersAndFrontSortingOrder();
    testTheCameraFocalLengthIsOnePixelPerUnit();
    testTheFlyPreviewOfTheShotKeepsTheShotsFraming();
    testAMaterialThatAsksForNothingIsFlatAndSanitisingKeepsItSo();
    testSanitisingRefusesTheValuesThatLookLikeOtherBugs();
    testTheLightModelFillsTheMathsParamsWithoutRederivingAnything();
    testTheMaskIsEightChannelsAndReadsBackInOrder();
    testTheFrontViewZoomIsClamped();
    testTheNeutralBackgroundIsARampAndNotATint();
UM_TEST_MAIN_END()
