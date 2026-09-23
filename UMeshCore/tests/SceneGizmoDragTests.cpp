// Tests for Editor/SceneGizmoDrag.h -- which handle a point grabs, and
// what a drag on it does to a layer.
//
// The file's reason for existing is that every measurement is made where
// the question lives, so the tests are built the same way round: put a
// world point under the pointer, move the pointer to where another world
// point projects, and require the layer to have moved by exactly the world
// distance between them. That is the promise
// `Editor/verify_scene_gizmo_drag.py` measured at 0.0000 px and which this
// repository cannot re-run (see CLAUDE.md).
//
// Where the Swift header names the screen-space method it replaced, the
// test COMPUTES that method alongside and shows it disagreeing -- the
// 313-pixel drift on an axis and the tens of degrees on a slanted ring are
// not quoted here, they are reproduced.

#include "umeshcore/Editor/SceneGizmoDrag.h"

#include <cmath>

#include "TestHarness.h"

using namespace umeshcore;

namespace {

constexpr float kPi = 3.14159265358979323846f;
const Vec2 kViewSize(1600, 900);

// A camera looking into the set from an angle, so nothing below is the
// easy square-on case.
SceneProjection angledCamera() {
    return SceneProjection(Vec3(-300, 220, -1400), 0.22f, -0.35f, 0.0f, 45.0f, 1.0f, 100000.0f,
                           kViewSize);
}

SceneLayer card() {
    SceneLayer layer;
    layer.position = Vec2(180, -90);
    layer.positionZ = 900;
    layer.rotation = 0.4f;
    layer.rotation3D = Vec3(0.3f, -0.45f, 0);
    layer.scale = Vec2(1.6f, 0.8f);
    return layer;
}

// The centre of a plane handle's quad, which is the point a finger aims
// at when it means "that plane".
std::optional<Vec2> planeCentre(const SceneGizmoShape& shape, SceneGizmoHandleId id) {
    for (const auto& entry : shape.planes) {
        if (entry.first != id || entry.second.empty()) continue;
        Vec2 sum;
        for (const Vec2& corner : entry.second) sum += corner;
        return sum / static_cast<float>(entry.second.size());
    }
    return std::nullopt;
}

Vec2 project(const SceneProjection& projection, const Vec3& world) {
    const auto px = projection.project(world);
    UM_CHECK(px.has_value());
    return px.value_or(Vec2::zero());
}

} // namespace

static void testAnAxisDragMovesTheCardByTheWorldDistanceItWasAskedFor() {
    const SceneProjection camera = angledCamera();
    const SceneLayer start = card();
    const SceneGizmoBasis basis = translateBasis(start, SceneGizmoTool::kTranslate);

    // Grab a point on the X axis, and point at where that point WOULD be
    // 250 world units along it. The card must move exactly 250.
    const Vec3 grabbed = basis.origin + basis.x * 60.0f;
    const float asked = 250.0f;
    const Vec2 startPx = project(camera, grabbed);
    const Vec2 nowPx = project(camera, grabbed + basis.x * asked);

    SceneLayer layer = start;
    applyLayerDrag(
        layer, start, SceneGizmoTool::kTranslate,
        SceneGizmoDrag{SceneGizmoHandleId::kAxisX, startPx, std::nullopt}, nowPx, camera,
        Vec2(200, 120));
    UM_CHECK_NEAR(layer.position.x - start.position.x, asked, 0.05);
    // Nothing else moved: the axis IS the field.
    UM_CHECK(layer.position.y == start.position.y);
    UM_CHECK(layer.positionZ == start.positionZ);

    // The method this replaced: the pointer offset projected onto the
    // axis's screen direction, divided by a pixels-per-unit read AT THE
    // PIVOT. Right only where the projection is affine.
    const Vec2 axisPx = project(camera, basis.origin + basis.x) - project(camera, basis.origin);
    const Vec2 screenDelta = nowPx - startPx;
    const float pixelsPerUnit = length(axisPx);
    const float naive = dot(screenDelta, normalize(axisPx)) / pixelsPerUnit;
    // Tens of units out on a card 900 units back -- the same class of
    // error the Swift harness measured as 313 px of drift.
    UM_CHECK(std::fabs(naive - asked) > 10.0f);

    // Z drags the depth, and it is the same exact measurement.
    const Vec3 grabbedZ = basis.origin + basis.z * 60.0f;
    SceneLayer depth = start;
    applyLayerDrag(
        depth, start, SceneGizmoTool::kTranslate,
        SceneGizmoDrag{SceneGizmoHandleId::kAxisZ, project(camera, grabbedZ), std::nullopt},
        project(camera, grabbedZ + basis.z * -400.0f), camera, Vec2(200, 120));
    UM_CHECK_NEAR(depth.positionZ - start.positionZ, -400.0, 0.1);
}

static void testAPlaneDragIsOneExactIntersectionNotTwoAxisMeasurements() {
    const SceneProjection camera = angledCamera();
    const SceneLayer start = card();
    const SceneGizmoBasis basis = translateBasis(start, SceneGizmoTool::kTranslate);
    const PlaneAxes axes = planeAxes(SceneGizmoHandleId::kPlaneXY, basis);

    const Vec3 grabbed = basis.origin + axes.a * 40.0f + axes.b * 25.0f;
    const Vec2 startPx = project(camera, grabbed);
    const Vec2 nowPx = project(camera, grabbed + axes.a * 130.0f + axes.b * -70.0f);

    SceneLayer layer = start;
    applyLayerDrag(
        layer, start, SceneGizmoTool::kTranslate,
        SceneGizmoDrag{SceneGizmoHandleId::kPlaneXY, startPx, std::nullopt}, nowPx, camera,
        Vec2(200, 120));
    UM_CHECK_NEAR(layer.position.x - start.position.x, 130.0, 0.05);
    UM_CHECK_NEAR(layer.position.y - start.position.y, -70.0, 0.05);
    UM_CHECK(layer.positionZ == start.positionZ);

    // XZ and YZ each drive one of the horizontal fields and the depth.
    SceneLayer xz = start;
    const Vec3 grabbedXZ = basis.origin + basis.x * 30.0f;
    applyLayerDrag(
        xz, start, SceneGizmoTool::kTranslate,
        SceneGizmoDrag{SceneGizmoHandleId::kPlaneXZ, project(camera, grabbedXZ), std::nullopt},
        project(camera, grabbedXZ + basis.x * 90.0f + basis.z * 150.0f), camera, Vec2(200, 120));
    UM_CHECK_NEAR(xz.position.x - start.position.x, 90.0, 0.05);
    UM_CHECK_NEAR(xz.positionZ - start.positionZ, 150.0, 0.05);
    UM_CHECK(xz.position.y == start.position.y);
}

static void testFreeMoveSlidesAcrossTheWorldPlaneThroughTheOrigin() {
    const SceneProjection camera = angledCamera();
    const SceneLayer start = card();
    const SceneGizmoBasis basis = translateBasis(start, SceneGizmoTool::kTranslate);
    const Vec3 grabbed = basis.origin;
    const Vec2 startPx = project(camera, grabbed);
    const Vec2 nowPx = project(camera, grabbed + Vec3(210, -95, 0));

    SceneLayer layer = start;
    applyLayerDrag(
        layer, start, SceneGizmoTool::kTranslate,
        SceneGizmoDrag{SceneGizmoHandleId::kFree, startPx, std::nullopt}, nowPx, camera,
        Vec2(200, 120));
    UM_CHECK_NEAR(layer.position.x - start.position.x, 210.0, 0.05);
    UM_CHECK_NEAR(layer.position.y - start.position.y, -95.0, 0.05);
    // Across the plane, so the depth is untouched -- this is a move, not a
    // dolly.
    UM_CHECK(layer.positionZ == start.positionZ);
}

static void testARotationIsReadInTheRingsOwnPlaneNotOnScreen() {
    const SceneProjection camera = angledCamera();
    const SceneLayer start = card();
    const SceneGizmoBasis basis = layerBasis(start);

    // The X ring: a circle about the card's own x axis, well off
    // square-on to this camera.
    const Vec3 normal = basis.x;
    const GizmoRingFrame frame = gizmoRingFrame(normal);
    const float radius = 260.0f;
    const auto onRing = [&](float angle) {
        return basis.origin + (frame.u * std::cos(angle) + frame.v * std::sin(angle)) * radius;
    };
    const float from = 0.35f, to = 1.15f; // a turn of 0.8 rad
    const Vec2 startPx = project(camera, onRing(from));
    const Vec2 nowPx = project(camera, onRing(to));

    SceneLayer layer = start;
    applyLayerDrag(
        layer, start, SceneGizmoTool::kRotate,
        SceneGizmoDrag{SceneGizmoHandleId::kAxisX, startPx, std::nullopt}, nowPx, camera,
        Vec2(200, 120));
    UM_CHECK_NEAR(layer.rotation3D.x - start.rotation3D.x, to - from, 1e-3);
    UM_CHECK(layer.rotation == start.rotation); // the roll is a different ring

    // The screen angle about the gizmo's projected centre -- the method
    // this replaced. Right only for a ring facing the camera; here it is
    // out by a large fraction of the turn itself.
    const Vec2 originPx = project(camera, basis.origin);
    const float screenTurn = screenAngleDelta(originPx, startPx, nowPx);
    UM_CHECK(std::fabs(screenTurn - (to - from)) > 0.15f); // ~9 degrees or more

    // The Z ring is the card's own normal, so it turns the card's ROLL.
    const GizmoRingFrame rollFrame = gizmoRingFrame(basis.z);
    const auto onRoll = [&](float angle) {
        return basis.origin +
               (rollFrame.u * std::cos(angle) + rollFrame.v * std::sin(angle)) * radius;
    };
    SceneLayer rolled = start;
    applyLayerDrag(
        rolled, start, SceneGizmoTool::kRotate,
        SceneGizmoDrag{SceneGizmoHandleId::kAxisZ, project(camera, onRoll(0.0f)), std::nullopt},
        project(camera, onRoll(-0.5f)), camera, Vec2(200, 120));
    UM_CHECK_NEAR(rolled.rotation - start.rotation, -0.5, 1e-3);
    UM_CHECK(rolled.rotation3D.x == start.rotation3D.x);
}

static void testTheViewRingIsHonestlyAScreenAngle() {
    // Its plane IS the screen, so a screen angle is not an approximation
    // here -- it is the definition. And it is the ring that always works:
    // the three world rings each vanish edge-on at some angle.
    const SceneProjection camera = angledCamera();
    const SceneLayer start = card();
    const Vec2 originPx = project(camera, start.worldOrigin());
    const Vec2 startPx = originPx + Vec2(120, 0);
    const Vec2 nowPx = originPx + Vec2(0, 120);

    SceneLayer layer = start;
    applyLayerDrag(
        layer, start, SceneGizmoTool::kRotate,
        SceneGizmoDrag{SceneGizmoHandleId::kViewRing, startPx, std::nullopt}, nowPx, camera,
        Vec2(200, 120));
    UM_CHECK_NEAR(layer.rotation - start.rotation, kPi * 0.5, 1e-5);
    UM_CHECK(layer.rotation3D == start.rotation3D);
}

static void testScaleIsARatioOfDistancesAndCannotGoThroughZero() {
    const SceneProjection camera = angledCamera();
    const SceneLayer start = card();
    const Vec2 originPx = project(camera, start.worldOrigin());
    const Vec2 startPx = originPx + Vec2(100, 0);

    SceneLayer doubled = start;
    applyLayerDrag(
        doubled, start, SceneGizmoTool::kScale,
        SceneGizmoDrag{SceneGizmoHandleId::kAxisX, startPx, std::nullopt}, originPx + Vec2(200, 0),
        camera, Vec2(200, 120));
    UM_CHECK_NEAR(doubled.scale.x, start.scale.x * 2.0f, 1e-4);
    UM_CHECK(doubled.scale.y == start.scale.y);

    // Uniform takes both axes by the same factor.
    SceneLayer uniform = start;
    applyLayerDrag(
        uniform, start, SceneGizmoTool::kScale,
        SceneGizmoDrag{SceneGizmoHandleId::kUniform, startPx, std::nullopt},
        originPx + Vec2(50, 0), camera, Vec2(200, 120));
    UM_CHECK_NEAR(uniform.scale.x, start.scale.x * 0.5f, 1e-4);
    UM_CHECK_NEAR(uniform.scale.y, start.scale.y * 0.5f, 1e-4);

    // Dragged onto the pivot, the card does not invert or vanish.
    SceneLayer collapsed = start;
    applyLayerDrag(
        collapsed, start, SceneGizmoTool::kScale,
        SceneGizmoDrag{SceneGizmoHandleId::kUniform, startPx, std::nullopt}, originPx, camera,
        Vec2(200, 120));
    UM_CHECK(collapsed.scale.x >= 0.01f && collapsed.scale.y >= 0.01f);

    // ALWAYS FROM `start`: pushing past the clamp and back comes home,
    // rather than ratcheting on the value the clamp swallowed.
    SceneLayer home = collapsed;
    applyLayerDrag(
        home, start, SceneGizmoTool::kScale,
        SceneGizmoDrag{SceneGizmoHandleId::kUniform, startPx, std::nullopt},
        originPx + Vec2(100, 0), camera, Vec2(200, 120));
    UM_CHECK_NEAR(home.scale.x, start.scale.x, 1e-4);
    UM_CHECK_NEAR(home.scale.y, start.scale.y, 1e-4);
}

static void testAShearOfOneIsADragByTheCardsOwnExtent() {
    const SceneProjection camera = angledCamera();
    SceneLayer start = card();
    start.shear = Vec2::zero();
    const SceneGizmoBasis basis = layerBasis(start);
    const Vec2 half(200, 120); // the card's own half size, injected

    // Slide the X handle ACROSS its axis by the card's half width: a
    // shear of exactly 1, whatever size the card is.
    const Vec3 grabbed = basis.origin + basis.x * 90.0f;
    SceneLayer layer = start;
    applyLayerDrag(
        layer, start, SceneGizmoTool::kShear,
        SceneGizmoDrag{SceneGizmoHandleId::kAxisX, project(camera, grabbed), std::nullopt},
        project(camera, grabbed + basis.y * half.x), camera, half);
    UM_CHECK_NEAR(layer.shear.y, 1.0, 1e-3);
    UM_CHECK(layer.shear.x == start.shear.x);

    // The Y handle drives the other slant, and with the opposite sign --
    // sliding it one way slants the card the other.
    SceneLayer other = start;
    applyLayerDrag(
        other, start, SceneGizmoTool::kShear,
        SceneGizmoDrag{SceneGizmoHandleId::kAxisY, project(camera, grabbed), std::nullopt},
        project(camera, grabbed + basis.x * half.y), camera, half);
    UM_CHECK_NEAR(other.shear.x, -1.0, 1e-3);

    // Same drag on a card twice the size: half the shear, because the
    // slant is the offset over the card's OWN extent.
    SceneLayer big = start;
    applyLayerDrag(
        big, start, SceneGizmoTool::kShear,
        SceneGizmoDrag{SceneGizmoHandleId::kAxisX, project(camera, grabbed), std::nullopt},
        project(camera, grabbed + basis.y * half.x), camera, half * 2.0f);
    UM_CHECK_NEAR(big.shear.y, 0.5, 1e-3);
}

static void testTheShearZHandleIsARateAndSaysSo() {
    // Not a slant with a geometric size: "how much tip per how much drag".
    // So it is measured in pixels, and it works even where a ray would
    // have nothing to meet.
    const SceneProjection camera = angledCamera();
    const SceneLayer start = card();
    const SceneGizmoScreenAxis axis{Vec2(800, 450), Vec2(900, 450), Vec2(1, 0)};
    SceneLayer layer = start;
    applyLayerDrag(
        layer, start, SceneGizmoTool::kShear,
        SceneGizmoDrag{SceneGizmoHandleId::kAxisZ, Vec2(800, 450), axis}, Vec2(850, 470), camera,
        Vec2(200, 120));
    // Along the handle pitches, across it yaws.
    UM_CHECK_NEAR(layer.rotation3D.x - start.rotation3D.x, 50.0 * kSceneGizmoRadiansPerPixel, 1e-6);
    UM_CHECK_NEAR(layer.rotation3D.y - start.rotation3D.y, 20.0 * kSceneGizmoRadiansPerPixel, 1e-6);
    // Without the axis there is no along/across to split, so nothing moves
    // rather than something moving by an invented amount.
    SceneLayer untouched = start;
    applyLayerDrag(
        untouched, start, SceneGizmoTool::kShear,
        SceneGizmoDrag{SceneGizmoHandleId::kAxisZ, Vec2(800, 450), std::nullopt}, Vec2(850, 470),
        camera, Vec2(200, 120));
    UM_CHECK(untouched.rotation3D == start.rotation3D);
}

static void testTheHitTestPrefersAnAreaToALineAndNeverTiesByChance() {
    const SceneProjection real = SceneProjection(
        Vec3(0, 0, -1200), 0.0f, 0.0f, 0.0f, 45.0f, 1.0f, 100000.0f, kViewSize);
    SceneLayer layer;
    layer.positionZ = 0;
    const auto state = sceneGizmoState(worldBasis(layer), real, kViewSize);
    UM_CHECK(state.has_value());
    const auto shape = buildGizmoShape(*state);
    UM_CHECK(shape.has_value());

    // Nowhere near anything: no handle, rather than the nearest one.
    UM_CHECK(!hitTestGizmo(*shape, shape->originPx + Vec2(900, 700), SceneGizmoTool::kTranslate)
                  .has_value());

    // THE CENTRE HANDLE IS UNREACHABLE while any axis is drawn, and that
    // is the Swift's behaviour rather than this port's. Every axis segment
    // starts AT the origin, so the distance to an axis is never greater
    // than the distance to the centre, and the tie goes to whoever was
    // tested first -- the axis. Over the whole neighbourhood of the
    // origin, not one grab is the centre.
    int centreHits = 0, handleHits = 0;
    for (int dx = -30; dx <= 30; ++dx) {
        for (int dy = -30; dy <= 30; ++dy) {
            const auto hit = hitTestGizmo(
                *shape, shape->originPx + Vec2(static_cast<float>(dx), static_cast<float>(dy)),
                SceneGizmoTool::kTranslate);
            if (!hit.has_value()) continue;
            ++handleHits;
            if (hit->id == SceneGizmoHandleId::kFree) ++centreHits;
        }
    }
    UM_CHECK(handleHits > 2000);
    UM_CHECK(centreHits == 0);

    // The ordering itself is right, though, and this is what proves it:
    // with no axis drawn, the centre answers -- free move for translate,
    // uniform for scale, and NOTHING for shear, because there is no
    // "slant everything equally".
    SceneGizmoShape bare;
    bare.originPx = shape->originPx;
    const auto centreMove = hitTestGizmo(bare, bare.originPx, SceneGizmoTool::kTranslate);
    UM_CHECK(centreMove.has_value() && centreMove->id == SceneGizmoHandleId::kFree);
    const auto centreScale = hitTestGizmo(bare, bare.originPx, SceneGizmoTool::kScale);
    UM_CHECK(centreScale.has_value() && centreScale->id == SceneGizmoHandleId::kUniform);
    UM_CHECK(!hitTestGizmo(bare, bare.originPx, SceneGizmoTool::kShear).has_value());

    // Inside a plane quad, the plane wins even though the axes run right
    // past it: a quad is an area, and a plane near an arrow must not lose
    // to it.
    const auto quad = planeCentre(*shape, SceneGizmoHandleId::kPlaneXY);
    UM_CHECK(quad.has_value());
    const auto insidePlane = hitTestGizmo(*shape, *quad, SceneGizmoTool::kTranslate);
    UM_CHECK(insidePlane.has_value() && insidePlane->id == SceneGizmoHandleId::kPlaneXY);
    // The same point under the SCALE tool is not a plane at all -- planes
    // are a translate affordance.
    const auto scaleThere = hitTestGizmo(*shape, *quad, SceneGizmoTool::kScale);
    UM_CHECK(!scaleThere.has_value() || scaleThere->id != SceneGizmoHandleId::kPlaneXY);

    // An axis carries its screen direction out of the hit test, because
    // the shear tool's Z handle needs it while dragging.
    const SceneGizmoScreenAxis* axis = nullptr;
    for (const auto& entry : shape->axes) {
        if (entry.first == SceneGizmoHandleId::kAxisX) axis = &entry.second;
    }
    UM_CHECK(axis != nullptr);
    const auto onAxis = hitTestGizmo(
        *shape, (axis->origin + axis->tip) * 0.5f, SceneGizmoTool::kTranslate);
    UM_CHECK(onAxis.has_value() && onAxis->id == SceneGizmoHandleId::kAxisX);
    UM_CHECK(onAxis->axis.has_value());
}

static void testRotateGrabsTheNearestRingAndTheViewRingByItsRadius() {
    const SceneProjection real = SceneProjection(
        Vec3(0, 0, -1200), 0.3f, 0.4f, 0.0f, 45.0f, 1.0f, 100000.0f, kViewSize);
    SceneLayer layer;
    layer.positionZ = 0;
    const auto state = sceneGizmoState(layerBasis(layer), real, kViewSize);
    UM_CHECK(state.has_value());
    const auto shape = buildGizmoShape(*state);
    UM_CHECK(shape.has_value());
    UM_CHECK(!shape->rings.empty());

    // A point taken straight off one ring's polyline grabs that ring.
    const auto& firstRing = shape->rings.front();
    UM_CHECK(!firstRing.second.empty() && firstRing.second.front().size() >= 2);
    const Vec2 onRing = firstRing.second.front().front();
    const auto hit = hitTestGizmo(*shape, onRing, SceneGizmoTool::kRotate);
    UM_CHECK(hit.has_value());

    // The view ring sits outside the world rings, at a fixed radius from
    // the origin -- a radial test, because that ring is screen-space.
    const float outer = shape->ringRadiusPx * kSceneGizmoViewRingScale;
    const auto viewHit = hitTestGizmo(
        *shape, shape->originPx + Vec2(outer, 0), SceneGizmoTool::kRotate);
    UM_CHECK(viewHit.has_value());
}

static void testThePredicatesUnderneath() {
    // A segment, clamped at its ends rather than treated as a line.
    UM_CHECK_NEAR(distanceToSegment(Vec2(5, 3), Vec2(0, 0), Vec2(10, 0)), 3.0, 1e-5);
    UM_CHECK_NEAR(distanceToSegment(Vec2(-4, 0), Vec2(0, 0), Vec2(10, 0)), 4.0, 1e-5);
    UM_CHECK_NEAR(distanceToSegment(Vec2(1, 1), Vec2(2, 2), Vec2(2, 2)), std::sqrt(2.0), 1e-5);

    // A convex quad, either winding.
    const std::vector<Vec2> quad = {Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)};
    UM_CHECK(convexContains(quad, Vec2(5, 5)));
    UM_CHECK(!convexContains(quad, Vec2(11, 5)));
    const std::vector<Vec2> reversed = {Vec2(0, 10), Vec2(10, 10), Vec2(10, 0), Vec2(0, 0)};
    UM_CHECK(convexContains(reversed, Vec2(5, 5)));
    UM_CHECK(!convexContains({Vec2(0, 0), Vec2(1, 1)}, Vec2(0.5f, 0.5f))); // not a polygon
}

// ---- The GPU's input ----------------------------------------------------

namespace {

std::optional<SceneGizmoState> cardState(SceneGizmoTool tool) {
    return sceneGizmoState(translateBasis(card(), tool), angledCamera(), kViewSize);
}

template <typename Geometry>
bool hasEntry(const std::vector<SceneGizmoLayout::Entry<Geometry>>& entries,
              SceneGizmoHandleId id) {
    for (const auto& e : entries) {
        if (e.id == id) return true;
    }
    return false;
}

bool vec4Equal(const Vec4& a, const Vec4& b) {
    return a.x == b.x && a.y == b.y && a.z == b.z && a.w == b.w;
}

} // namespace

static void testTheLayoutDrawsWhatTheHitTestOffers() {
    // The Swift's whole reason for building both from one state: the
    // manipulator the GPU draws and the one the pointer is tested against
    // are the same shape by construction.
    const auto state = cardState(SceneGizmoTool::kTranslate);
    UM_CHECK(state.has_value());
    if (!state.has_value()) return;
    const auto shape = buildGizmoShape(*state);
    UM_CHECK(shape.has_value());
    if (!shape.has_value()) return;
    const SceneGizmoLayout layout =
        buildGizmoLayout(*state, SceneGizmoTool::kTranslate, std::nullopt);

    // Axes: the SAME set, because both refuse on `projectAxis`.
    UM_CHECK(layout.axes.size() == shape->axes.size());
    for (const auto& entry : shape->axes) UM_CHECK(hasEntry(layout.axes, entry.first));
    UM_CHECK(!layout.axes.empty());

    // Planes: every quad the pointer can grab is drawn. (The converse need
    // not hold -- the hit test also withdraws a quad whose corner fails to
    // project, which the rasterizer would simply clip.)
    for (const auto& entry : shape->planes) UM_CHECK(hasEntry(layout.planes, entry.first));
    // And the drawn set is exactly the ones facing the camera.
    for (SceneGizmoHandleId id : {SceneGizmoHandleId::kPlaneXY, SceneGizmoHandleId::kPlaneXZ,
                                  SceneGizmoHandleId::kPlaneYZ}) {
        UM_CHECK(hasEntry(layout.planes, id) == planeFacesCamera(*state, id));
    }
}

static void testEachToolBuildsOnlyTheHandlesItShows() {
    const auto state = cardState(SceneGizmoTool::kTranslate);
    UM_CHECK(state.has_value());
    if (!state.has_value()) return;

    // Rotate: three rings and the view ring. No arrows, no planes, no
    // centre square -- none of them is grabbable with this tool.
    const SceneGizmoLayout rotate = buildGizmoLayout(*state, SceneGizmoTool::kRotate, std::nullopt);
    UM_CHECK(rotate.rings.size() == 3);
    UM_CHECK(rotate.axes.empty() && rotate.planes.empty());
    UM_CHECK(rotate.showViewRing);
    UM_CHECK(!rotate.centerHandle.has_value());
    UM_CHECK(vec4Equal(rotate.viewRingColor, Vec4(1, 1, 1, 0.75f)));

    // Translate: arrows, the plane quads, and the free-move square.
    const SceneGizmoLayout translate =
        buildGizmoLayout(*state, SceneGizmoTool::kTranslate, std::nullopt);
    UM_CHECK(translate.rings.empty() && !translate.showViewRing);
    UM_CHECK(translate.centerHandle.has_value());
    for (const auto& e : translate.axes) {
        UM_CHECK(e.geometry.head == SceneGizmoLayout::AxisHead::kArrow);
    }

    // Scale: cube heads, the uniform-scale square, and NO planes -- the
    // plane handles are a translate-only affordance.
    const SceneGizmoLayout scale = buildGizmoLayout(*state, SceneGizmoTool::kScale, std::nullopt);
    UM_CHECK(scale.planes.empty() && scale.rings.empty());
    UM_CHECK(scale.centerHandle.has_value());
    UM_CHECK(!scale.axes.empty());
    for (const auto& e : scale.axes) UM_CHECK(e.geometry.head == SceneGizmoLayout::AxisHead::kCube);

    // Shear: cube heads too, and no centre square -- there is no "uniform
    // shear" to grab.
    const SceneGizmoLayout shear = buildGizmoLayout(*state, SceneGizmoTool::kShear, std::nullopt);
    UM_CHECK(shear.planes.empty() && !shear.centerHandle.has_value());
    for (const auto& e : shear.axes) UM_CHECK(e.geometry.head == SceneGizmoLayout::AxisHead::kCube);
}

static void testColoursAreTheSwiftsConstantsAndAPlaneTakesItsNormal() {
    // Numbers copied by hand from `SceneGizmoOverlay.axisColor`.
    const Vec4 red(0.94f, 0.33f, 0.35f, 1), green(0.44f, 0.83f, 0.36f, 1),
        blue(0.35f, 0.58f, 0.98f, 1), gold(0.98f, 0.82f, 0.30f, 1);
    UM_CHECK(vec4Equal(sceneGizmoAxisColor(SceneGizmoHandleId::kAxisX), red));
    UM_CHECK(vec4Equal(sceneGizmoAxisColor(SceneGizmoHandleId::kAxisY), green));
    UM_CHECK(vec4Equal(sceneGizmoAxisColor(SceneGizmoHandleId::kAxisZ), blue));
    // The blue quad is the one that keeps Z fixed.
    UM_CHECK(vec4Equal(sceneGizmoAxisColor(SceneGizmoHandleId::kPlaneXY), blue));
    UM_CHECK(vec4Equal(sceneGizmoAxisColor(SceneGizmoHandleId::kPlaneXZ), green));
    UM_CHECK(vec4Equal(sceneGizmoAxisColor(SceneGizmoHandleId::kPlaneYZ), red));
    UM_CHECK(vec4Equal(sceneGizmoAxisColor(SceneGizmoHandleId::kFree), gold));
}

static void testTheHighlightLandsOnTheHandleThePointerIsOverAndNowhereElse() {
    const auto state = cardState(SceneGizmoTool::kTranslate);
    UM_CHECK(state.has_value());
    if (!state.has_value()) return;

    SceneGizmoHit overY;
    overY.id = SceneGizmoHandleId::kAxisY;
    const SceneGizmoLayout layout = buildGizmoLayout(*state, SceneGizmoTool::kTranslate, overY);
    int lit = 0;
    for (const auto& e : layout.axes) {
        if (e.geometry.highlighted) {
            ++lit;
            UM_CHECK(e.id == SceneGizmoHandleId::kAxisY);
        }
    }
    for (const auto& e : layout.planes) UM_CHECK(!e.geometry.highlighted);
    UM_CHECK(lit == 1);
    UM_CHECK(layout.centerHandle.has_value() && !layout.centerHandle->highlighted);

    // The centre square answers to EITHER of the two ids it stands for.
    SceneGizmoHit overUniform;
    overUniform.id = SceneGizmoHandleId::kUniform;
    const SceneGizmoLayout scale = buildGizmoLayout(*state, SceneGizmoTool::kScale, overUniform);
    UM_CHECK(scale.centerHandle.has_value() && scale.centerHandle->highlighted);
}

static void testTheGpuDrawsTheGizmoWhereTheRealCameraSeesTheObject() {
    // What `viewProjection` + `screenOffsetNDC` exist for: the stabilised
    // camera puts the origin dead centre, and the offset slides it back to
    // where the REAL camera sees it. Get the sign or the divisor wrong and
    // the manipulator floats away from the card it is attached to.
    const auto state = cardState(SceneGizmoTool::kTranslate);
    UM_CHECK(state.has_value());
    if (!state.has_value()) return;
    const SceneGizmoLayout layout =
        buildGizmoLayout(*state, SceneGizmoTool::kTranslate, std::nullopt);

    const Vec3& o = layout.origin;
    const Vec4 clip = layout.viewProjection * Vec4(o.x, o.y, o.z, 1.0f);
    UM_CHECK(clip.w > 0.0f);
    const float ndcX = clip.x / clip.w + layout.screenOffsetNDC.x;
    const float ndcY = clip.y / clip.w + layout.screenOffsetNDC.y;
    // NDC y up, pixels y down.
    const Vec2 drawnPx((ndcX + 1.0f) * 0.5f * kViewSize.x, (1.0f - ndcY) * 0.5f * kViewSize.y);

    const Vec2 truePx = project(angledCamera(), o);
    UM_CHECK_NEAR(drawnPx.x, truePx.x, 0.05);
    UM_CHECK_NEAR(drawnPx.y, truePx.y, 0.05);
    // And it is not the trivial case: the card is well off centre.
    UM_CHECK(length(truePx - kViewSize * 0.5f) > 50.0f);
}

static void testALightsDiagramComesOnlyWithALightAndCarriesItsOwnHighlight() {
    SceneLight light;
    light.kind = SceneLightKind::kSpot;
    light.position = Vec2(120, -40);
    light.positionZ = 200;
    light.radius = 700;
    light.softness = 0.4f;
    light.innerAngle = 15.0f * kPi / 180.0f;
    light.outerAngle = 35.0f * kPi / 180.0f;

    const auto state = sceneGizmoState(lightBasis(light), angledCamera(), kViewSize);
    UM_CHECK(state.has_value());
    if (!state.has_value()) return;

    const SceneGizmoLayout none = buildGizmoLayout(*state, SceneGizmoTool::kTranslate, std::nullopt);
    UM_CHECK(!none.lightDiagram.has_value());

    SceneGizmoHit overRadius;
    overRadius.id = SceneGizmoHandleId::kLight;
    overRadius.lightHandle = SceneLightHandle::kRadius;
    const SceneGizmoLayout lit =
        buildGizmoLayout(*state, SceneGizmoTool::kTranslate, overRadius, &light);
    UM_CHECK(lit.lightDiagram.has_value());
    if (!lit.lightDiagram.has_value()) return;
    UM_CHECK(!lit.lightDiagram->handles.empty());
    int highlighted = 0;
    for (const auto& h : lit.lightDiagram->handles) highlighted += h.highlighted ? 1 : 0;
    UM_CHECK(highlighted == 1);

    // A highlight on an AXIS lights no dot on the diagram.
    SceneGizmoHit overX;
    overX.id = SceneGizmoHandleId::kAxisX;
    const SceneGizmoLayout axisLit =
        buildGizmoLayout(*state, SceneGizmoTool::kTranslate, overX, &light);
    UM_CHECK(axisLit.lightDiagram.has_value());
    if (!axisLit.lightDiagram.has_value()) return;
    for (const auto& h : axisLit.lightDiagram->handles) UM_CHECK(!h.highlighted);
}

UM_TEST_MAIN_BEGIN()
    testAnAxisDragMovesTheCardByTheWorldDistanceItWasAskedFor();
    testAPlaneDragIsOneExactIntersectionNotTwoAxisMeasurements();
    testFreeMoveSlidesAcrossTheWorldPlaneThroughTheOrigin();
    testARotationIsReadInTheRingsOwnPlaneNotOnScreen();
    testTheViewRingIsHonestlyAScreenAngle();
    testScaleIsARatioOfDistancesAndCannotGoThroughZero();
    testAShearOfOneIsADragByTheCardsOwnExtent();
    testTheShearZHandleIsARateAndSaysSo();
    testTheHitTestPrefersAnAreaToALineAndNeverTiesByChance();
    testRotateGrabsTheNearestRingAndTheViewRingByItsRadius();
    testThePredicatesUnderneath();
    testTheLayoutDrawsWhatTheHitTestOffers();
    testEachToolBuildsOnlyTheHandlesItShows();
    testColoursAreTheSwiftsConstantsAndAPlaneTakesItsNormal();
    testTheHighlightLandsOnTheHandleThePointerIsOverAndNowhereElse();
    testTheGpuDrawsTheGizmoWhereTheRealCameraSeesTheObject();
    testALightsDiagramComesOnlyWithALightAndCarriesItsOwnHighlight();
UM_TEST_MAIN_END()
