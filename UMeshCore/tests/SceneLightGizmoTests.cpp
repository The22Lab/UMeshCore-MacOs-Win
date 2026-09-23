// Tests for Editor/SceneLightGizmo.h and the light/camera halves of
// Editor/SceneGizmoDrag.h, ported from `Render/SceneLightGizmo.swift` and
// the light and camera drags of `SceneGizmoOverlay.swift`.
//
// A light's handles answer on the world plane through the light that FACES
// THE CAMERA, and the Swift header gives a counting argument for it rather
// than a preference: a pointer gives two numbers, a radius wants one and a
// direction wants two, so the map from pointer to value is a bijection
// only once the missing degree of freedom is pinned -- and pinning it to
// the plane the artist is looking at is what keeps the grabbed point under
// the pointer. So that is what these tests check: drag a handle to where
// something should be, and require it to be there.

#include "umeshcore/Editor/SceneGizmoDrag.h"

#include <cmath>

#include "TestHarness.h"

using namespace umeshcore;

namespace {

constexpr float kPi = 3.14159265358979323846f;
const Vec2 kViewSize(1600, 900);

SceneProjection angledCamera() {
    return SceneProjection(
        Vec3(-260, 180, -1500), 0.18f, -0.3f, 0.0f, 45.0f, 1.0f, 100000.0f, kViewSize);
}

SceneLight spotLight() {
    SceneLight light;
    light.kind = SceneLightKind::kSpot;
    light.position = Vec2(120, -40);
    light.positionZ = 200;
    light.radius = 700;
    light.softness = 0.4f;
    light.azimuth = 0.5f;
    light.elevation = -0.2f;
    light.innerAngle = 15.0f * kPi / 180.0f;
    light.outerAngle = 35.0f * kPi / 180.0f;
    return light;
}

Vec2 project(const SceneProjection& projection, const Vec3& world) {
    const auto px = projection.project(world);
    UM_CHECK(px.has_value());
    return px.value_or(Vec2::zero());
}

} // namespace

static void testWhichHandlesALightHasAndInWhatOrder() {
    // A directional light has no position and no falloff -- a direction
    // and nothing else.
    const auto directional = lightHandlesFor(SceneLightKind::kDirectional);
    UM_CHECK(directional.size() == 1 && directional[0] == SceneLightHandle::kDirection);

    // A point light has no beam to aim.
    const auto point = lightHandlesFor(SceneLightKind::kPoint);
    UM_CHECK(point.size() == 2);
    for (SceneLightHandle handle : point) UM_CHECK(handle != SceneLightHandle::kDirection);

    // A spot has all five, ANGLES FIRST: the two arcs sit on the radius
    // ring at the cone's edge, so where they overlap the more specific
    // handle has to win.
    const auto spot = lightHandlesFor(SceneLightKind::kSpot);
    UM_CHECK(spot.size() == 5);
    UM_CHECK(spot[0] == SceneLightHandle::kInnerAngle);
    UM_CHECK(spot[1] == SceneLightHandle::kOuterAngle);
    UM_CHECK(spot[3] == SceneLightHandle::kRadius);
}

static void testAHandleExistsOnlyWhereItMeansSomething() {
    const SceneProjection camera = angledCamera();
    SceneLight light;
    light.kind = SceneLightKind::kDirectional;
    // No radius on a light that has no place: asking gives nothing rather
    // than a number derived from something else.
    UM_CHECK(!lightHandlePosition(SceneLightHandle::kRadius, light, camera, 100.0f).has_value());
    UM_CHECK(!lightHandlePosition(SceneLightHandle::kInnerAngle, light, camera, 100.0f)
                  .has_value());
    UM_CHECK(lightHandlePosition(SceneLightHandle::kDirection, light, camera, 100.0f).has_value());

    // A point light has no beam.
    light.kind = SceneLightKind::kPoint;
    light.radius = 500;
    UM_CHECK(!lightHandlePosition(SceneLightHandle::kDirection, light, camera, 100.0f).has_value());
    // And a radius of zero has no rim to grab.
    light.radius = 0;
    UM_CHECK(!lightHandlePosition(SceneLightHandle::kRadius, light, camera, 100.0f).has_value());
}

static void testTheSoftnessHandleCannotHideUnderTheRadiusHandle() {
    // Both sit on the facing ring, so they are put on PERPENDICULAR axes
    // of it -- otherwise a band shrunk to nothing would leave two dots on
    // top of each other and one of them unreachable.
    const SceneProjection camera = angledCamera();
    SceneLight light = spotLight();
    light.softness = 0.0001f; // the band all but gone
    const auto radius = lightHandlePosition(SceneLightHandle::kRadius, light, camera, 0.0f);
    const auto softness = lightHandlePosition(SceneLightHandle::kSoftness, light, camera, 0.0f);
    UM_CHECK(radius.has_value() && softness.has_value());
    const float apart = length(*radius - *softness);
    UM_CHECK(apart > light.radius); // a full quadrant apart, not a few units
    // Both lie in the plane facing the camera.
    const Vec3 axis = lightViewAxis(camera);
    UM_CHECK_NEAR(dot(*radius - light.world(), axis), 0.0, 1e-2);
    UM_CHECK_NEAR(dot(*softness - light.world(), axis), 0.0, 1e-2);
}

static void testDraggingTheRimPutsTheRimUnderThePointerAndKeepsTheBand() {
    const SceneProjection camera = angledCamera();
    const SceneLight start = spotLight();
    const GizmoRingFrame frame = lightFacingFrame(camera);

    // Ask for a rim at 1100 units by pointing at where that rim would be.
    const Vec3 asked = start.world() + frame.u * 1100.0f;
    SceneGizmoDrag drag;
    drag.handle = SceneGizmoHandleId::kLight;
    drag.lightHandle = SceneLightHandle::kRadius;
    drag.startPx = project(camera, start.world() + frame.u * start.radius);

    SceneLight light = start;
    applyLightDrag(
        light, start, SceneGizmoTool::kTranslate, drag, project(camera, asked), camera,
        Vec2::zero());
    UM_CHECK_NEAR(light.radius, 1100.0, 0.5);

    // THE BAND is what the artist was looking at, so it is preserved in
    // WORLD units -- softness is a fraction, so leaving it alone would
    // make the fade grow with the radius and the light would change shape
    // while being resized.
    UM_CHECK_NEAR(light.radius * light.softness, start.radius * start.softness, 0.5);
    UM_CHECK(light.softness < start.softness); // the fraction had to shrink
}

static void testDraggingTheSoftnessHandleSetsTheFractionAndClampsAtTheRim() {
    const SceneProjection camera = angledCamera();
    const SceneLight start = spotLight();
    const GizmoRingFrame frame = lightFacingFrame(camera);
    SceneGizmoDrag drag;
    drag.handle = SceneGizmoHandleId::kLight;
    drag.lightHandle = SceneLightHandle::kSoftness;
    drag.startPx = project(camera, start.world() + frame.v * start.innerRadius());

    // Inner edge at a quarter of the radius means three quarters of it is
    // fade.
    SceneLight light = start;
    applyLightDrag(
        light, start, SceneGizmoTool::kTranslate, drag,
        project(camera, start.world() + frame.v * (start.radius * 0.25f)), camera, Vec2::zero());
    UM_CHECK_NEAR(light.softness, 0.75, 1e-3);

    // Dragged past the rim it asks for a negative band, and the clamp is
    // where the value is read rather than somewhere downstream.
    SceneLight past = start;
    applyLightDrag(
        past, start, SceneGizmoTool::kTranslate, drag,
        project(camera, start.world() + frame.v * (start.radius * 1.8f)), camera, Vec2::zero());
    UM_CHECK(past.softness == 0.0f);
}

static void testAimingIsTheExactInverseOfDirectionAndSurvivesThePole() {
    // `aimLight` must undo `SceneLight::direction()` exactly, or a light
    // would drift every time it was aimed.
    SceneLight light;
    for (float azimuth : {-2.0f, -0.3f, 0.0f, 1.1f, 2.9f}) {
        for (float elevation : {-1.2f, -0.2f, 0.0f, 0.7f, 1.4f}) {
            SceneLight source;
            source.azimuth = azimuth;
            source.elevation = elevation;
            aimLight(light, source.direction());
            UM_CHECK_NEAR(length(light.direction() - source.direction()), 0.0, 1e-5);
        }
    }

    // THE GIMBAL CASE. Straight up the Z axis has no azimuth: every
    // azimuth gives the same direction. Taking `atan2(0, 0)` would snap
    // the stored azimuth to zero, so tilting back out of the pole would
    // swing the light somewhere it was never pointed.
    SceneLight atPole;
    atPole.azimuth = 2.5f;
    atPole.elevation = 0.3f;
    aimLight(atPole, Vec3(0, 0, 1));
    UM_CHECK(atPole.azimuth == 2.5f); // left alone, not snapped
    UM_CHECK_NEAR(atPole.elevation, kPi * 0.5, 1e-5);
}

static void testARotateRingAimsTheLightAndTheBeamItselfDoesNothing() {
    const SceneProjection camera = angledCamera();
    const SceneLight start = spotLight();
    const SceneGizmoBasis basis = lightBasis(start);

    // A turn about the ring's own axis, read in the ring's plane.
    const GizmoRingFrame ring = gizmoRingFrame(basis.x);
    const auto onRing = [&](float angle) {
        return basis.origin + (ring.u * std::cos(angle) + ring.v * std::sin(angle)) * 300.0f;
    };
    SceneGizmoDrag drag;
    drag.handle = SceneGizmoHandleId::kAxisX;
    drag.startPx = project(camera, onRing(0.2f));

    SceneLight light = start;
    applyLightDrag(
        light, start, SceneGizmoTool::kRotate, drag, project(camera, onRing(0.9f)), camera,
        Vec2::zero());
    // The direction turned by the same angle about that axis.
    const Vec3 expected = rotatedAbout(start.direction(), basis.x, 0.7f);
    UM_CHECK_NEAR(length(light.direction() - expected), 0.0, 1e-3);
    // Aiming, not orienting: the light's place did not move.
    UM_CHECK(light.position == start.position && light.positionZ == start.positionZ);

    // A turn about the BEAM comes back as no change, which is correct: a
    // cone has nothing to roll.
    UM_CHECK_NEAR(
        length(rotatedAbout(start.direction(), start.direction(), 1.3f) - start.direction()), 0.0,
        1e-5);

    // A point light has nothing to aim at all.
    SceneLight point = start;
    point.kind = SceneLightKind::kPoint;
    SceneLight turned = point;
    applyLightDrag(
        turned, point, SceneGizmoTool::kRotate, drag, project(camera, onRing(0.9f)), camera,
        Vec2::zero());
    UM_CHECK(turned.azimuth == point.azimuth && turned.elevation == point.elevation);
}

static void testTheConeAnglesAreReadInTheConesOwnPlaneAndStayOrdered() {
    const SceneProjection camera = angledCamera();
    const SceneLight start = spotLight();
    const Vec3 across = lightConePlane(start.direction(), camera);

    // Point at the rim of a 50-degree cone, in the plane the arc is drawn
    // in, and the outer angle must come back as 50 degrees.
    const float asked = 50.0f * kPi / 180.0f;
    const ConeRim rim =
        lightConeRim(start.world(), start.direction(), across, asked, start.radius);
    SceneGizmoDrag drag;
    drag.handle = SceneGizmoHandleId::kLight;
    drag.lightHandle = SceneLightHandle::kOuterAngle;
    drag.startPx = Vec2::zero();

    SceneLight light = start;
    applyLightDrag(
        light, start, SceneGizmoTool::kTranslate, drag, project(camera, rim.a), camera,
        Vec2::zero());
    UM_CHECK_NEAR(light.outerAngle, asked, 1e-3);
    UM_CHECK(light.innerAngle == start.innerAngle); // still inside, untouched

    // Squeezed below the inner angle, the inner one follows it down --
    // otherwise the smoothstep between them would run backwards, which
    // reads as a spot lit inside out.
    const float tight = 5.0f * kPi / 180.0f;
    const ConeRim tightRim =
        lightConeRim(start.world(), start.direction(), across, tight, start.radius);
    SceneLight squeezed = start;
    applyLightDrag(
        squeezed, start, SceneGizmoTool::kTranslate, drag, project(camera, tightRim.a), camera,
        Vec2::zero());
    UM_CHECK_NEAR(squeezed.outerAngle, tight, 1e-3);
    UM_CHECK(squeezed.innerAngle <= squeezed.outerAngle + 1e-6f);

    // The inner handle cannot push past the outer one either.
    SceneGizmoDrag innerDrag = drag;
    innerDrag.lightHandle = SceneLightHandle::kInnerAngle;
    const ConeRim wide = lightConeRim(
        start.world(), start.direction(), across, 80.0f * kPi / 180.0f, start.radius);
    SceneLight inner = start;
    applyLightDrag(
        inner, start, SceneGizmoTool::kTranslate, innerDrag, project(camera, wide.a), camera,
        Vec2::zero());
    UM_CHECK_NEAR(inner.innerAngle, start.outerAngle, 1e-5);
}

static void testALightsHandlesAreTestedFirstAndByNearest() {
    const SceneProjection real = SceneProjection(
        Vec3(0, 0, -1500), 0.0f, 0.0f, 0.0f, 45.0f, 1.0f, 100000.0f, kViewSize);
    const SceneLight light = spotLight();
    const auto state = sceneGizmoState(lightBasis(light), real, kViewSize);
    UM_CHECK(state.has_value());
    const LightWorldGeometry geometry = lightWorldGeometry(light, real);
    const auto shape = buildGizmoShape(*state, &geometry);
    UM_CHECK(shape.has_value());
    UM_CHECK(!shape->lightHandles.empty());

    // Straight onto a dot: that dot, and it carries which one it is.
    const auto& entry = shape->lightHandles.front();
    const auto hit = hitTestGizmo(*shape, entry.second, SceneGizmoTool::kTranslate);
    UM_CHECK(hit.has_value());
    UM_CHECK(hit->id == SceneGizmoHandleId::kLight);
    UM_CHECK(hit->lightHandle.has_value());

    // Nearest wins, not first in the list: a point a little off one dot
    // and far from the others picks the near one whatever its position in
    // the fixed order.
    if (shape->lightHandles.size() >= 2) {
        const Vec2 second = shape->lightHandles[1].second;
        const auto nearSecond = hitTestGizmo(*shape, second, SceneGizmoTool::kTranslate);
        UM_CHECK(nearSecond.has_value());
        UM_CHECK(nearSecond->lightHandle.value() == shape->lightHandles[1].first);
    }

    // Beyond the grab radius it is not a light handle at all.
    const auto far = hitTestGizmo(
        *shape, entry.second + Vec2(kSceneLightGrabPixels * 4.0f, 0), SceneGizmoTool::kTranslate);
    UM_CHECK(!far.has_value() || far->id != SceneGizmoHandleId::kLight);
    // And a bigger radius for touch reaches further, which is the whole
    // reason it is a parameter.
    const auto touch = hitTestGizmo(
        *shape, entry.second + Vec2(20.0f, 0), SceneGizmoTool::kTranslate,
        kSceneLightGrabTouchPixels);
    const auto mouse = hitTestGizmo(
        *shape, entry.second + Vec2(20.0f, 0), SceneGizmoTool::kTranslate, kSceneLightGrabPixels);
    UM_CHECK(touch.has_value() && touch->id == SceneGizmoHandleId::kLight);
    UM_CHECK(!mouse.has_value() || mouse->id != SceneGizmoHandleId::kLight);
}

static void testOneGeometryFeedsBothTheHitTestAndTheDiagram() {
    // The dots the artist grabs and the rings the GPU draws come from the
    // SAME world geometry -- two functions building the same light two
    // ways is the failure this port keeps recording.
    const SceneProjection camera = angledCamera();
    const SceneLight light = spotLight();
    const LightWorldGeometry geometry = lightWorldGeometry(light, camera);
    UM_CHECK_NEAR(geometry.influenceRadius, light.radius, 1e-4);
    UM_CHECK_NEAR(geometry.innerRadius, light.innerRadius(), 1e-4);
    UM_CHECK(geometry.beam.has_value());
    UM_CHECK(geometry.outerEdges.size() == 2 && geometry.innerEdges.size() == 2);
    UM_CHECK(!geometry.outerArc.empty() && !geometry.innerArc.empty());

    const SceneGizmoLayout::LightDiagram diagram =
        lightDiagram(geometry, light, SceneLightHandle::kRadius);
    UM_CHECK(diagram.centre == light.world());
    UM_CHECK(diagram.handles.size() == geometry.handlePositions.size());
    // Exactly the grabbed one is highlighted.
    int highlighted = 0;
    for (const auto& handle : diagram.handles) {
        if (handle.highlighted) ++highlighted;
    }
    UM_CHECK(highlighted == 1);
    // Every arc point is on the cone's rim, at the light's own radius.
    for (const Vec3& point : geometry.outerArc) {
        UM_CHECK_NEAR(length(point - light.world()), light.radius, 1e-2);
    }

    // A fade that reaches the centre has NO inner ring to draw: the inner
    // edge is `radius * (1 - softness)`, so a softness at 1 collapses it
    // onto the light itself, where a circle would be a dot sitting on the
    // light's own marker. The cut is at 2% of the radius.
    SceneLight wide = light;
    wide.softness = 0.999f;
    UM_CHECK(lightWorldGeometry(wide, camera).innerRadius == 0.0f);
    // The other end is the opposite case and IS drawn: a hard-edged light
    // has its inner edge right at the rim, which is a real ring the artist
    // can still grab.
    SceneLight hard = light;
    hard.softness = 0.001f;
    UM_CHECK(lightWorldGeometry(hard, camera).innerRadius > light.radius * 0.9f);

    // A directional light borrows a fixed pixel length for its beam,
    // because it has no radius to borrow.
    SceneLight sun;
    sun.kind = SceneLightKind::kDirectional;
    const LightWorldGeometry sunGeometry = lightWorldGeometry(sun, camera);
    UM_CHECK(sunGeometry.beam.has_value());
    UM_CHECK(sunGeometry.influenceRadius == 0.0f);
    UM_CHECK(length(sunGeometry.beam->to - sunGeometry.beam->from) > 0.0f);
}

static void testTheCameraDragsItsOwnAxesAndNothingElse() {
    const SceneProjection camera = angledCamera();
    SceneCamera start;
    start.positionZ = -900;
    const SceneGizmoBasis basis = cameraBasis(start);

    const Vec3 grabbed = basis.origin + basis.x * 50.0f;
    SceneGizmoDrag drag;
    drag.handle = SceneGizmoHandleId::kAxisX;
    drag.startPx = project(camera, grabbed);

    SceneCamera moved = start;
    applyCameraDrag(
        moved, start, SceneGizmoTool::kTranslate, drag, project(camera, grabbed + basis.x * 320.0f),
        camera, Vec2::zero());
    UM_CHECK_NEAR(moved.position.x - start.position.x, 320.0, 0.1);
    UM_CHECK(moved.positionZ == start.positionZ);

    // Rotate turns the shot; the Z ring is its roll.
    const GizmoRingFrame ring = gizmoRingFrame(basis.z);
    const auto onRing = [&](float angle) {
        return basis.origin + (ring.u * std::cos(angle) + ring.v * std::sin(angle)) * 400.0f;
    };
    SceneGizmoDrag rollDrag;
    rollDrag.handle = SceneGizmoHandleId::kAxisZ;
    rollDrag.startPx = project(camera, onRing(0.0f));
    SceneCamera rolled = start;
    applyCameraDrag(
        rolled, start, SceneGizmoTool::kRotate, rollDrag, project(camera, onRing(0.6f)), camera,
        Vec2::zero());
    UM_CHECK_NEAR(rolled.rotation3D.z - start.rotation3D.z, 0.6, 1e-3);

    // A camera has neither a size nor a slant, so those tools do nothing
    // rather than something surprising.
    SceneCamera untouched = start;
    applyCameraDrag(
        untouched, start, SceneGizmoTool::kScale, drag, project(camera, grabbed), camera,
        Vec2::zero());
    UM_CHECK(untouched == start);
    applyCameraDrag(
        untouched, start, SceneGizmoTool::kShear, drag, project(camera, grabbed), camera,
        Vec2::zero());
    UM_CHECK(untouched == start);
}

static void testALightHasNoSizeToScaleAndNoPlaneToSlant() {
    const SceneProjection camera = angledCamera();
    const SceneLight start = spotLight();
    SceneGizmoDrag drag;
    drag.handle = SceneGizmoHandleId::kAxisX;
    drag.startPx = Vec2(700, 400);

    for (SceneGizmoTool tool : {SceneGizmoTool::kScale, SceneGizmoTool::kShear}) {
        SceneLight light = start;
        applyLightDrag(light, start, tool, drag, Vec2(900, 500), camera, Vec2::zero());
        UM_CHECK(light == start);
    }
}

static void testADisabledLightsDiagramIsFlattenedToWhite() {
    // Swift's `lightDiagramLayout`: an enabled light is drawn in its own
    // colour, a disabled one in WHITE -- and the mesh builder then dims it.
    // The port used to keep the hue for both, which drew an off light as a
    // faded version of its own colour. This test is what fails if it does
    // again.
    const SceneProjection camera = angledCamera();
    SceneLight light = spotLight();
    light.color = Vec3(1.0f, 0.3f, 0.1f);

    light.isEnabled = true;
    const auto on = lightDiagram(lightWorldGeometry(light, camera), light, std::nullopt);
    UM_CHECK(on.isEnabled);
    UM_CHECK(on.tint.x == 1.0f && on.tint.y == 0.3f && on.tint.z == 0.1f && on.tint.w == 1.0f);

    light.isEnabled = false;
    const auto off = lightDiagram(lightWorldGeometry(light, camera), light, std::nullopt);
    UM_CHECK(!off.isEnabled);
    UM_CHECK(off.tint.x == 1.0f && off.tint.y == 1.0f && off.tint.z == 1.0f && off.tint.w == 1.0f);

    // Only the colour changes: switching a light off does not move a
    // single point of its diagram.
    UM_CHECK(on.handles.size() == off.handles.size());
    UM_CHECK(on.outerArc.size() == off.outerArc.size());
    UM_CHECK(on.influenceRadius == off.influenceRadius);
}

UM_TEST_MAIN_BEGIN()
    testADisabledLightsDiagramIsFlattenedToWhite();
    testWhichHandlesALightHasAndInWhatOrder();
    testAHandleExistsOnlyWhereItMeansSomething();
    testTheSoftnessHandleCannotHideUnderTheRadiusHandle();
    testDraggingTheRimPutsTheRimUnderThePointerAndKeepsTheBand();
    testDraggingTheSoftnessHandleSetsTheFractionAndClampsAtTheRim();
    testAimingIsTheExactInverseOfDirectionAndSurvivesThePole();
    testARotateRingAimsTheLightAndTheBeamItselfDoesNothing();
    testTheConeAnglesAreReadInTheConesOwnPlaneAndStayOrdered();
    testALightsHandlesAreTestedFirstAndByNearest();
    testOneGeometryFeedsBothTheHitTestAndTheDiagram();
    testTheCameraDragsItsOwnAxesAndNothingElse();
    testALightHasNoSizeToScaleAndNoPlaneToSlant();
UM_TEST_MAIN_END()
