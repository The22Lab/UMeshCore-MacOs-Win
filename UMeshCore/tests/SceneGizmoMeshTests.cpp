// Tests for Render/SceneGizmoLayout.h + Render/SceneGizmoMeshBuilder.h,
// ported from `Render/SceneGPU/SceneGizmoLayout.swift`,
// `SceneGizmoMeshBuilder.swift` and the pure-geometry pieces of
// `SceneGizmoOverlay.swift`.
//
// A mesh builder is easy to test badly: re-deriving a vertex position
// restates the loop that produced it. So these assert the properties the
// Swift sources say the shapes must have --
//
//   - An arrow is EXACTLY `scale` long, because that length is what
//     `worldLengthForPixels` sized to hold a constant pixel size. A head
//     that overshoots is a gizmo that grows as the camera turns.
//   - A highlighted handle reads THICKER, not merely brighter.
//   - Degenerate input (zero length, zero radius) emits NOTHING, never a
//     NaN vertex -- a gizmo that silently fails to draw is the failure
//     mode `ringFrame`'s guard exists for.
//   - The emit ORDER is fixed by `sceneGizmoSortKey` whatever order the
//     caller filled the layout in, and the layers come out light diagram,
//     planes, axes, rings -- the order the SwiftUI overlay drew in, so
//     nearly coincident translucent surfaces still read the same.
//   - Every primitive is a whole number of triangles with unit normals.
//
// `Editor/verify_scene_gizmo_drag.py` does not exist in this repository
// (see CLAUDE.md).

#include "umeshcore/Render/SceneGizmoMeshBuilder.h"

#include <cmath>
#include <vector>

#include "TestHarness.h"

using namespace umeshcore;
namespace B = umeshcore::SceneGizmoMeshBuilder;

namespace {

const Vec4 kRed(1, 0.2f, 0.2f, 1);
const Vec4 kGreen(0.2f, 1, 0.2f, 1);
const Vec4 kBlue(0.2f, 0.4f, 1, 1);

bool allFinite(const std::vector<SceneGizmoVertexIn>& vertices) {
    for (const auto& v : vertices) {
        if (!std::isfinite(v.world.x) || !std::isfinite(v.world.y) || !std::isfinite(v.world.z))
            return false;
        if (!std::isfinite(v.normal.x) || !std::isfinite(v.normal.y) || !std::isfinite(v.normal.z))
            return false;
        if (!std::isfinite(v.color.w)) return false;
    }
    return true;
}

bool normalsAreUnit(const std::vector<SceneGizmoVertexIn>& vertices) {
    for (const auto& v : vertices) {
        if (std::fabs(length(v.normal) - 1.0f) > 1e-3f) return false;
    }
    return true;
}

SceneGizmoLayout translateLayout() {
    SceneGizmoLayout layout;
    layout.tool = SceneGizmoTool::kTranslate;
    layout.origin = Vec3(100, -50, 300);
    layout.scale = 80.0f;
    layout.forward = Vec3(0, 0, 1);
    layout.eye = Vec3(0, 0, -500);
    layout.axes = {
        {SceneGizmoHandleId::kAxisX, {Vec3(1, 0, 0), kRed, false, 1.0f, SceneGizmoLayout::AxisHead::kArrow}},
        {SceneGizmoHandleId::kAxisY, {Vec3(0, 1, 0), kGreen, false, 1.0f, SceneGizmoLayout::AxisHead::kArrow}},
        {SceneGizmoHandleId::kAxisZ, {Vec3(0, 0, 1), kBlue, false, 1.0f, SceneGizmoLayout::AxisHead::kArrow}}};
    layout.planes = {
        {SceneGizmoHandleId::kPlaneXY, {Vec3(1, 0, 0), Vec3(0, 1, 0), kBlue, false}},
        {SceneGizmoHandleId::kPlaneXZ, {Vec3(1, 0, 0), Vec3(0, 0, 1), kGreen, false}}};
    layout.centerHandle = SceneGizmoLayout::CenterHandle{Vec4(1, 1, 1, 1), false};
    return layout;
}

float farthestAlong(const std::vector<SceneGizmoVertexIn>& vertices, const Vec3& origin, const Vec3& dir) {
    float best = 0.0f;
    for (const auto& v : vertices) best = std::max(best, dot(v.world - origin, dir));
    return best;
}

float farthestFrom(const std::vector<SceneGizmoVertexIn>& vertices, const Vec3& origin) {
    float best = 0.0f;
    for (const auto& v : vertices) best = std::max(best, length(v.world - origin));
    return best;
}

} // namespace

static void testRingFrameIsOrthonormalEverywhereIncludingThePoles() {
    const Vec3 normals[] = {Vec3(1, 0, 0),  Vec3(0, 1, 0),  Vec3(0, 0, 1),
                            Vec3(0, -1, 0), normalize(Vec3(0.3f, 0.95f, -0.1f)),
                            normalize(Vec3(-1, -1, -1))};
    for (const Vec3& n : normals) {
        const GizmoRingFrame frame = gizmoRingFrame(n);
        UM_CHECK_NEAR(length(frame.u), 1.0, 1e-4);
        UM_CHECK_NEAR(length(frame.v), 1.0, 1e-4);
        UM_CHECK_NEAR(dot(frame.u, frame.v), 0.0, 1e-4);
        UM_CHECK_NEAR(dot(frame.u, n), 0.0, 1e-4);
        UM_CHECK_NEAR(dot(frame.v, n), 0.0, 1e-4);
    }
    // The degenerate case takes the guard, not a normalised zero: a NaN
    // frame here is a gizmo that silently fails to draw.
    const GizmoRingFrame degenerate = gizmoRingFrame(Vec3(0, 0, 0));
    UM_CHECK(degenerate.u == Vec3(1, 0, 0) && degenerate.v == Vec3(0, 1, 0));
}

static void testAnArrowIsExactlyScaleLong() {
    // The length IS the contract: it is what `worldLengthForPixels`
    // computed to hold a constant pixel size, so a head that overshoots
    // makes the gizmo grow as the camera turns.
    SceneGizmoLayout layout = translateLayout();
    layout.planes.clear();
    layout.centerHandle.reset();
    layout.axes = {{SceneGizmoHandleId::kAxisX,
                    {Vec3(1, 0, 0), kRed, false, 1.0f, SceneGizmoLayout::AxisHead::kArrow}}};
    const auto mesh = B::build(layout);
    UM_CHECK_NEAR(farthestAlong(mesh, layout.origin, Vec3(1, 0, 0)), layout.scale, 1e-3);

    // A cube cap is centred ON the tip, so it reaches half an extent past
    // it -- deliberately, because it is a thing to grab rather than a
    // direction to travel.
    layout.axes[0].geometry.head = SceneGizmoLayout::AxisHead::kCube;
    const auto cubeCapped = B::build(layout);
    const float overshoot =
        farthestAlong(cubeCapped, layout.origin, Vec3(1, 0, 0)) - layout.scale;
    UM_CHECK(overshoot > 0.0f && overshoot < layout.scale * 0.2f);
}

static void testHighlightReadsThickerNotOnlyBrighter() {
    SceneGizmoLayout plain = translateLayout();
    plain.planes.clear();
    plain.centerHandle.reset();
    plain.axes = {{SceneGizmoHandleId::kAxisY,
                   {Vec3(0, 1, 0), kGreen, false, 1.0f, SceneGizmoLayout::AxisHead::kArrow}}};
    SceneGizmoLayout lit = plain;
    lit.axes[0].geometry.highlighted = true;

    const auto plainMesh = B::build(plain);
    const auto litMesh = B::build(lit);
    // Same triangle count -- the shape is the same shape.
    UM_CHECK(plainMesh.size() == litMesh.size());
    // But wider: the girth scales, the length does not.
    const Vec3 axis(0, 1, 0);
    float plainGirth = 0.0f, litGirth = 0.0f;
    for (std::size_t i = 0; i < plainMesh.size(); ++i) {
        const Vec3 dp = plainMesh[i].world - plain.origin;
        const Vec3 dl = litMesh[i].world - lit.origin;
        plainGirth = std::max(plainGirth, length(dp - axis * dot(dp, axis)));
        litGirth = std::max(litGirth, length(dl - axis * dot(dl, axis)));
    }
    UM_CHECK(litGirth > plainGirth * 1.5f);
    UM_CHECK_NEAR(farthestAlong(litMesh, lit.origin, axis), plain.scale, 1e-3);
}

static void testAwayFacingAxisIsDimmedNotDropped() {
    // An axis you cannot see is one you cannot grab, so it dims rather
    // than disappearing.
    SceneGizmoLayout layout = translateLayout();
    layout.planes.clear();
    layout.centerHandle.reset();
    layout.axes = {{SceneGizmoHandleId::kAxisZ,
                    {Vec3(0, 0, 1), kBlue, false, kSceneGizmoAwayAlpha,
                     SceneGizmoLayout::AxisHead::kArrow}}};
    const auto mesh = B::build(layout);
    UM_CHECK(!mesh.empty());
    for (const auto& v : mesh) UM_CHECK_NEAR(v.color.w, kBlue.w * kSceneGizmoAwayAlpha, 1e-6);
}

static void testEmitOrderIsFixedWhateverOrderTheLayoutWasFilledIn() {
    // A Dictionary's order is seeded per process on the Swift side, and an
    // unordered_map gives no order worth relying on here. Two platforms
    // emitting the same buffer is the stronger version of the same rule.
    SceneGizmoLayout inOrder = translateLayout();
    SceneGizmoLayout shuffled = inOrder;
    std::swap(shuffled.axes[0], shuffled.axes[2]);
    std::swap(shuffled.planes[0], shuffled.planes[1]);

    const auto a = B::build(inOrder);
    const auto b = B::build(shuffled);
    UM_CHECK(a.size() == b.size());
    for (std::size_t i = 0; i < a.size(); ++i) {
        UM_CHECK(a[i].world == b[i].world);
        UM_CHECK(a[i].color == b[i].color);
    }
}

static void testLayersComeOutInDrawOrder() {
    // Light diagram first and under the manipulator, then planes, axes,
    // rings -- the order the SwiftUI overlay drew in, so nearly coincident
    // translucent surfaces still read the way they used to. Asserted as a
    // PREFIX property: adding a layer on top never disturbs what is below.
    SceneGizmoLayout planesOnly = translateLayout();
    planesOnly.axes.clear();
    planesOnly.centerHandle.reset();
    const auto planeMesh = B::build(planesOnly);

    SceneGizmoLayout withAxes = planesOnly;
    withAxes.axes = translateLayout().axes;
    const auto axesMesh = B::build(withAxes);
    UM_CHECK(axesMesh.size() > planeMesh.size());
    for (std::size_t i = 0; i < planeMesh.size(); ++i) {
        UM_CHECK(axesMesh[i].world == planeMesh[i].world);
    }

    SceneGizmoLayout withRings = withAxes;
    withRings.rings = {
        {SceneGizmoHandleId::kAxisX, {Vec3(1, 0, 0), kRed, false, 1.0f}}};
    const auto ringMesh = B::build(withRings);
    for (std::size_t i = 0; i < axesMesh.size(); ++i) {
        UM_CHECK(ringMesh[i].world == axesMesh[i].world);
    }
}

static void testPlaneQuadIsDoubleSided() {
    // The gizmo pipeline draws with no back-face culling, but a one-sided
    // quad would still go dark from behind -- hence both winding orders.
    SceneGizmoLayout layout = translateLayout();
    layout.axes.clear();
    layout.centerHandle.reset();
    layout.planes = {{SceneGizmoHandleId::kPlaneXY, {Vec3(1, 0, 0), Vec3(0, 1, 0), kBlue, false}}};
    const auto mesh = B::build(layout);
    UM_CHECK(mesh.size() == 12); // four triangles: two per side
    // And it sits off the origin, short of the arrowheads.
    for (const auto& v : mesh) {
        const float along = dot(v.world - layout.origin, Vec3(1, 0, 0));
        UM_CHECK(along >= kSceneGizmoPlaneOffset * layout.scale - 1e-3f);
        UM_CHECK(along <= (kSceneGizmoPlaneOffset + kSceneGizmoPlaneSize) * layout.scale + 1e-3f);
    }
    // Highlighted, it is less translucent.
    layout.planes[0].geometry.highlighted = true;
    const auto lit = B::build(layout);
    UM_CHECK(lit[0].color.w > mesh[0].color.w);
}

static void testViewRingSitsOutsideTheWorldRings() {
    SceneGizmoLayout layout = translateLayout();
    layout.axes.clear();
    layout.planes.clear();
    layout.centerHandle.reset();
    layout.rings = {{SceneGizmoHandleId::kAxisX, {Vec3(1, 0, 0), kRed, false, 1.0f}}};
    const auto worldRing = B::build(layout);

    SceneGizmoLayout viewOnly = layout;
    viewOnly.rings.clear();
    viewOnly.showViewRing = true;
    viewOnly.viewRingColor = Vec4(1, 1, 1, 0.8f);
    const auto viewRing = B::build(viewOnly);

    // Outside, so the two kinds never overlap.
    UM_CHECK(farthestFrom(viewRing, layout.origin) > farthestFrom(worldRing, layout.origin));
    // And billboarded to the camera's forward rather than lying in a world
    // plane: every vertex is within a tube's radius of the plane through
    // the origin whose normal is `forward`.
    const float tube = layout.scale * B::kTubeRadiusFraction * 0.7f;
    for (const auto& v : viewRing) {
        UM_CHECK(std::fabs(dot(v.world - layout.origin, viewOnly.forward)) <= tube + 1e-3f);
    }
}

static void testEveryPrimitiveIsWholeTrianglesWithUnitNormals() {
    const std::vector<std::vector<SceneGizmoVertexIn>> meshes = {
        B::cylinder(Vec3(0, 0, 0), Vec3(0, 10, 0), 1.0f, B::kAxisSides, kRed),
        B::cone(Vec3(0, 10, 0), Vec3(0, 13, 0), 2.0f, B::kAxisSides, kRed),
        B::cube(Vec3(1, 2, 3), 1.5f, normalize(Vec3(1, 1, 0)), kGreen),
        B::torus(Vec3(0, 0, 0), Vec3(0, 0, 1), 20.0f, 0.5f, B::kRingSegments, B::kTubeSides, kBlue),
        B::sphere(Vec3(4, 4, 4), 2.0f, kGreen),
        B::tubeAlongPolyline({Vec3(0, 0, 0), Vec3(1, 1, 0), Vec3(2, 0, 0)}, 0.2f, 6, kBlue)};
    for (const auto& mesh : meshes) {
        UM_CHECK(!mesh.empty());
        UM_CHECK(mesh.size() % 3 == 0);
        UM_CHECK(allFinite(mesh));
        UM_CHECK(normalsAreUnit(mesh));
    }
}

static void testTorusPointsLieInItsOwnTube() {
    const float radius = 20.0f, tube = 0.5f;
    const auto mesh = B::torus(
        Vec3(5, 5, 5), normalize(Vec3(0, 1, 1)), radius, tube, B::kRingSegments, B::kTubeSides, kBlue);
    for (const auto& v : mesh) {
        const float d = length(v.world - Vec3(5, 5, 5));
        UM_CHECK(d >= radius - tube - 1e-3f && d <= radius + tube + 1e-3f);
    }
    // A sphere's points are all at its radius, by definition.
    for (const auto& v : B::sphere(Vec3(1, 2, 3), 4.0f, kRed)) {
        UM_CHECK_NEAR(length(v.world - Vec3(1, 2, 3)), 4.0, 1e-3);
    }
}

static void testDegenerateInputEmitsNothingRatherThanNaNs() {
    UM_CHECK(B::cylinder(Vec3(1, 1, 1), Vec3(1, 1, 1), 1.0f, 12, kRed).empty());
    UM_CHECK(B::cylinder(Vec3(0, 0, 0), Vec3(0, 1, 0), 0.0f, 12, kRed).empty());
    UM_CHECK(B::cone(Vec3(0, 0, 0), Vec3(0, 0, 0), 1.0f, 12, kRed).empty());
    UM_CHECK(B::cube(Vec3(0, 0, 0), 0.0f, Vec3(0, 1, 0), kRed).empty());
    UM_CHECK(B::torus(Vec3(0, 0, 0), Vec3(0, 0, 1), 0.0f, 1.0f, 64, 10, kRed).empty());
    UM_CHECK(B::torus(Vec3(0, 0, 0), Vec3(0, 0, 1), 10.0f, 0.0f, 64, 10, kRed).empty());
    UM_CHECK(B::sphere(Vec3(0, 0, 0), 0.0f, kRed).empty());
    UM_CHECK(B::tubeAlongPolyline({Vec3(0, 0, 0)}, 1.0f, 6, kRed).empty());
    // A zero-scale gizmo is a degenerate layout, not a crash. Every round
    // primitive guards itself out; the plane quad has no guard on either
    // side of the port (its corners are offsets, not radii), so what
    // survives is four triangles collapsed onto the origin -- degenerate,
    // but finite, and drawn as nothing.
    SceneGizmoLayout layout = translateLayout();
    layout.scale = 0.0f;
    const auto collapsed = B::build(layout);
    UM_CHECK(allFinite(collapsed));
    for (const auto& v : collapsed) UM_CHECK(v.world == layout.origin);
    layout.planes.clear();
    UM_CHECK(B::build(layout).empty());
}

static void testLightDiagramDrawsUnderTheManipulatorAndInItsOwnColour() {
    SceneGizmoLayout layout = translateLayout();
    SceneGizmoLayout::LightDiagram diagram;
    diagram.centre = Vec3(100, -50, 300);
    diagram.tint = Vec4(1.0f, 0.85f, 0.4f, 1);
    diagram.viewAxis = Vec3(0, 0, 1);
    diagram.influenceRadius = 400.0f;
    diagram.innerRadius = 260.0f;
    diagram.beam = SceneGizmoLayout::Segment{Vec3(100, -50, 300), Vec3(100, -50, 700)};
    diagram.outerEdges = {{Vec3(100, -50, 300), Vec3(300, -50, 700)}};
    diagram.outerArc = {Vec3(300, -50, 700), Vec3(200, -50, 740), Vec3(100, -50, 750)};
    diagram.handles = {{Vec3(500, -50, 300), false}, {Vec3(100, 350, 300), true}};
    layout.lightDiagram = diagram;

    const auto mesh = B::build(layout);
    UM_CHECK(allFinite(mesh));
    // First, and under everything: the manipulator-only build is a SUFFIX.
    SceneGizmoLayout withoutLight = layout;
    withoutLight.lightDiagram.reset();
    const auto manipulator = B::build(withoutLight);
    UM_CHECK(mesh.size() > manipulator.size());
    const std::size_t offset = mesh.size() - manipulator.size();
    for (std::size_t i = 0; i < manipulator.size(); ++i) {
        UM_CHECK(mesh[offset + i].world == manipulator[i].world);
    }
    // In the LIGHT'S own colour, never the axis palette -- that palette
    // means X, Y and Z, and chrome borrowing it would claim to be an axis.
    for (std::size_t i = 0; i < offset; ++i) {
        UM_CHECK(mesh[i].color.x == diagram.tint.x && mesh[i].color.y == diagram.tint.y);
    }
    // The influence ring keeps the ARTIST'S radius, unscaled by the
    // gizmo's screen-constant scale: 400 world units where the whole
    // manipulator is 80. Only the tube's own girth comes from the scale.
    const float tube = layout.scale * B::kLightTubeRadiusFraction;
    bool foundRim = false;
    for (const auto& v : mesh) {
        if (std::fabs(length(v.world - diagram.centre) - diagram.influenceRadius) <= tube + 1e-3f) {
            foundRim = true;
            break;
        }
    }
    UM_CHECK(foundRim);
    UM_CHECK(farthestFrom(mesh, diagram.centre) > layout.scale * 4.0f);

    // Disabled reads dimmer, same shape.
    layout.lightDiagram->isEnabled = false;
    const auto off = B::build(layout);
    UM_CHECK(off.size() == mesh.size());
    UM_CHECK(off[0].color.w < mesh[0].color.w);
}

UM_TEST_MAIN_BEGIN()
    testRingFrameIsOrthonormalEverywhereIncludingThePoles();
    testAnArrowIsExactlyScaleLong();
    testHighlightReadsThickerNotOnlyBrighter();
    testAwayFacingAxisIsDimmedNotDropped();
    testEmitOrderIsFixedWhateverOrderTheLayoutWasFilledIn();
    testLayersComeOutInDrawOrder();
    testPlaneQuadIsDoubleSided();
    testViewRingSitsOutsideTheWorldRings();
    testEveryPrimitiveIsWholeTrianglesWithUnitNormals();
    testTorusPointsLieInItsOwnTube();
    testDegenerateInputEmitsNothingRatherThanNaNs();
    testLightDiagramDrawsUnderTheManipulatorAndInItsOwnColour();
UM_TEST_MAIN_END()
