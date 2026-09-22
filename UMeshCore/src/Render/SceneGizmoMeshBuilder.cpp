#include "umeshcore/Render/SceneGizmoMeshBuilder.h"

#include <algorithm>
#include <cmath>

namespace umeshcore {
namespace SceneGizmoMeshBuilder {

namespace {

constexpr float kPi = 3.14159265358979323846f;

void append(std::vector<SceneGizmoVertexIn>& into, const std::vector<SceneGizmoVertexIn>& more) {
    into.insert(into.end(), more.begin(), more.end());
}

// The layout carries its entries in whatever order the caller filled them;
// the buffer must not. See `sceneGizmoSortKey`.
template <typename Geometry>
std::vector<SceneGizmoLayout::Entry<Geometry>> inSortOrder(
    const std::vector<SceneGizmoLayout::Entry<Geometry>>& entries) {
    std::vector<SceneGizmoLayout::Entry<Geometry>> sorted = entries;
    std::stable_sort(
        sorted.begin(), sorted.end(),
        [](const SceneGizmoLayout::Entry<Geometry>& a, const SceneGizmoLayout::Entry<Geometry>& b) {
            return sceneGizmoSortKey(a.id) < sceneGizmoSortKey(b.id);
        });
    return sorted;
}

std::vector<SceneGizmoVertexIn> axisMesh(
    const SceneGizmoLayout::AxisGeometry& axis, const Vec3& origin, float scale) {
    const float thickness = axis.highlighted ? kHighlightedThicknessScale : 1.0f;
    Vec4 color = axis.color;
    color.w *= axis.awayAlpha;
    const Vec3 direction = normalize(axis.direction);

    const float shaftLength = scale * kShaftFraction;
    const Vec3 shaftEnd = origin + direction * shaftLength;
    const Vec3 tip = origin + direction * scale;
    const float shaftRadius = scale * kShaftRadiusFraction * thickness;
    const float headRadius = scale * kHeadRadiusFraction * thickness;

    std::vector<SceneGizmoVertexIn> vertices =
        cylinder(origin, shaftEnd, shaftRadius, kAxisSides, color);
    if (axis.head == SceneGizmoLayout::AxisHead::kArrow) {
        append(vertices, cone(shaftEnd, tip, headRadius, kAxisSides, color));
    } else {
        append(vertices, cube(tip, scale * kCubeHalfExtentFraction * thickness, direction, color));
    }
    return vertices;
}

std::vector<SceneGizmoVertexIn> ringMesh(
    const SceneGizmoLayout::RingGeometry& ring, const Vec3& origin, float scale) {
    const float thickness = ring.highlighted ? kHighlightedThicknessScale : 1.0f;
    Vec4 color = ring.color;
    color.w *= ring.awayAlpha;
    return torus(
        origin, normalize(ring.normal), scale, scale * kTubeRadiusFraction * thickness,
        kRingSegments, kTubeSides, color);
}

// The fourth ring: honestly screen-space, so it is built BILLBOARDED to
// face the gizmo camera's own view axis rather than lying in any world
// plane.
std::vector<SceneGizmoVertexIn> viewRingMesh(const SceneGizmoLayout& layout) {
    const float thin = layout.scale * kTubeRadiusFraction * 0.7f;
    return torus(
        layout.origin, layout.forward, layout.scale * kSceneGizmoViewRingScale, thin, kRingSegments,
        kTubeSides, layout.viewRingColor);
}

std::vector<SceneGizmoVertexIn> planeMesh(
    const SceneGizmoLayout::PlaneGeometry& plane, const Vec3& origin, float scale) {
    const Vec3 a = plane.a;
    const Vec3 b = plane.b;
    const float lo = kSceneGizmoPlaneOffset * scale;
    const float hi = (kSceneGizmoPlaneOffset + kSceneGizmoPlaneSize) * scale;
    Vec4 color = plane.color;
    color.w *= plane.highlighted ? 0.85f : kPlaneQuadColorAlpha;
    const Vec3 normal = normalize(cross(a, b));
    const Vec3 p00 = origin + a * lo + b * lo;
    const Vec3 p10 = origin + a * hi + b * lo;
    const Vec3 p11 = origin + a * hi + b * hi;
    const Vec3 p01 = origin + a * lo + b * hi;
    const auto v = [&](const Vec3& p) { return SceneGizmoVertexIn(p, normal, color); };
    // BOTH winding orders, so the quad reads the same lit from either side
    // -- the gizmo pipeline draws with no back-face culling, but a
    // one-sided quad would still go dark from behind without this.
    return {v(p00), v(p10), v(p11), v(p00), v(p11), v(p01),
            v(p00), v(p11), v(p10), v(p00), v(p01), v(p11)};
}

// The free-move / uniform-scale marker: a small cube at the origin,
// oriented off `forward` since any orientation reads fine at this size --
// it is a dot, not a directional cue.
std::vector<SceneGizmoVertexIn> centerHandleMesh(
    const SceneGizmoLayout::CenterHandle& center, const SceneGizmoLayout& layout) {
    Vec4 color = center.color;
    const float thickness = center.highlighted ? kHighlightedThicknessScale : 1.0f;
    color.w = center.highlighted ? 1.0f : 0.9f;
    return cube(
        layout.origin, layout.scale * kCubeHalfExtentFraction * 0.8f * thickness, layout.forward,
        color);
}

// The influence sphere (and where its fade starts), a spot's cone, the aim
// beam, and a small sphere at the light itself and at each of its handles.
//
// TINTED WITH THE LIGHT'S OWN COLOUR: it is how an artist tells two lights
// apart at a glance without reading a label, and it is why this never
// reaches for the axis palette -- that palette means X, Y and Z, and
// chrome borrowing it would be claiming to be an axis.
std::vector<SceneGizmoVertexIn> lightDiagramMesh(
    const SceneGizmoLayout::LightDiagram& diagram, float scale) {
    std::vector<SceneGizmoVertexIn> vertices;
    // A disabled light reads in a flatter, dimmer version of its own
    // colour -- present, placeable, visibly off.
    const float dim = diagram.isEnabled ? 1.0f : 0.55f;
    const auto tinted = [&](float alpha) {
        return Vec4(diagram.tint.x, diagram.tint.y, diagram.tint.z, alpha * dim);
    };

    const float tubeRadius = scale * kLightTubeRadiusFraction;

    // The band between the inner edge and the rim is where the light
    // fades, so the rim is drawn at full strength and the inner edge
    // thinner and dimmer -- one is where the light ends, the other is
    // where it starts to go.
    if (diagram.influenceRadius > 0.0f) {
        append(vertices, torus(
                             diagram.centre, diagram.viewAxis, diagram.influenceRadius, tubeRadius,
                             kRingSegments, kTubeSides, tinted(0.6f)));
    }
    if (diagram.innerRadius > 0.0f) {
        append(vertices, torus(
                             diagram.centre, diagram.viewAxis, diagram.innerRadius,
                             tubeRadius * 0.7f, kRingSegments, kTubeSides, tinted(0.32f)));
    }
    for (const auto& edge : diagram.outerEdges) {
        append(vertices, cylinder(edge.from, edge.to, tubeRadius, kTubeSides, tinted(0.6f)));
    }
    for (const auto& edge : diagram.innerEdges) {
        append(vertices, cylinder(edge.from, edge.to, tubeRadius * 0.7f, kTubeSides, tinted(0.32f)));
    }
    append(vertices, tubeAlongPolyline(diagram.outerArc, tubeRadius, kTubeSides, tinted(0.6f)));
    append(
        vertices, tubeAlongPolyline(diagram.innerArc, tubeRadius * 0.7f, kTubeSides, tinted(0.32f)));

    // The beam: a shaft plus an arrowhead, so it reads as a direction
    // rather than a radius that happens to be drawn as a line.
    if (diagram.beam.has_value()) {
        const Vec3 span = diagram.beam->to - diagram.beam->from;
        const Vec3 shaftEnd = diagram.beam->from + span * (1.0f - kLightBeamHeadLengthFraction);
        append(
            vertices, cylinder(diagram.beam->from, shaftEnd, tubeRadius, kTubeSides, tinted(0.95f)));
        append(vertices, cone(
                             shaftEnd, diagram.beam->to, scale * kLightBeamHeadRadiusFraction,
                             kTubeSides, tinted(0.95f)));
    }

    // The light itself, drawn LAST of the chrome so the cone's edges,
    // which all meet here, sit behind it rather than poking through it.
    append(
        vertices,
        sphere(diagram.centre, scale * kLightCentreSphereRadiusFraction, tinted(0.95f)));

    for (const auto& handle : diagram.handles) {
        const float thickness = handle.highlighted ? kHighlightedThicknessScale : 1.0f;
        append(vertices, sphere(
                             handle.position, scale * kLightHandleSphereRadiusFraction * thickness,
                             tinted(handle.highlighted ? 1.0f : 0.85f)));
    }
    return vertices;
}

} // namespace

std::vector<SceneGizmoVertexIn> build(const SceneGizmoLayout& layout) {
    std::vector<SceneGizmoVertexIn> vertices;

    if (layout.lightDiagram.has_value()) {
        append(vertices, lightDiagramMesh(*layout.lightDiagram, layout.scale));
    }
    for (const auto& plane : inSortOrder(layout.planes)) {
        append(vertices, planeMesh(plane.geometry, layout.origin, layout.scale));
    }
    for (const auto& axis : inSortOrder(layout.axes)) {
        append(vertices, axisMesh(axis.geometry, layout.origin, layout.scale));
    }
    for (const auto& ring : inSortOrder(layout.rings)) {
        append(vertices, ringMesh(ring.geometry, layout.origin, layout.scale));
    }
    if (layout.showViewRing) {
        append(vertices, viewRingMesh(layout));
    }
    if (layout.centerHandle.has_value()) {
        append(vertices, centerHandleMesh(*layout.centerHandle, layout));
    }
    return vertices;
}

std::vector<SceneGizmoVertexIn> cylinder(
    const Vec3& base, const Vec3& tip, float radius, int sides, const Vec4& color) {
    const Vec3 axis = tip - base;
    const float len = length(axis);
    if (!(len > 1e-6f) || !(radius > 1e-6f) || sides < 3) return {};
    const Vec3 dir = axis / len;
    const GizmoRingFrame frame = gizmoRingFrame(dir);

    std::vector<SceneGizmoVertexIn> vertices;
    vertices.reserve(static_cast<std::size_t>(sides) * 6);
    for (int i = 0; i < sides; ++i) {
        const float a0 = static_cast<float>(i) / static_cast<float>(sides) * 2.0f * kPi;
        const float a1 = static_cast<float>(i + 1) / static_cast<float>(sides) * 2.0f * kPi;
        const Vec3 n0 = frame.u * std::cos(a0) + frame.v * std::sin(a0);
        const Vec3 n1 = frame.u * std::cos(a1) + frame.v * std::sin(a1);
        const Vec3 b0 = base + n0 * radius, b1 = base + n1 * radius;
        const Vec3 t0 = tip + n0 * radius, t1 = tip + n1 * radius;
        vertices.emplace_back(b0, n0, color);
        vertices.emplace_back(b1, n1, color);
        vertices.emplace_back(t0, n0, color);
        vertices.emplace_back(b1, n1, color);
        vertices.emplace_back(t1, n1, color);
        vertices.emplace_back(t0, n0, color);
    }
    return vertices;
}

std::vector<SceneGizmoVertexIn> cone(
    const Vec3& base, const Vec3& apex, float radius, int sides, const Vec4& color) {
    const Vec3 axis = apex - base;
    const float len = length(axis);
    if (!(len > 1e-6f) || !(radius > 1e-6f) || sides < 3) return {};
    const Vec3 dir = axis / len;
    const GizmoRingFrame frame = gizmoRingFrame(dir);

    std::vector<SceneGizmoVertexIn> vertices;
    vertices.reserve(static_cast<std::size_t>(sides) * 6);
    for (int i = 0; i < sides; ++i) {
        const float a0 = static_cast<float>(i) / static_cast<float>(sides) * 2.0f * kPi;
        const float a1 = static_cast<float>(i + 1) / static_cast<float>(sides) * 2.0f * kPi;
        const Vec3 n0 = frame.u * std::cos(a0) + frame.v * std::sin(a0);
        const Vec3 n1 = frame.u * std::cos(a1) + frame.v * std::sin(a1);
        const Vec3 p0 = base + n0 * radius, p1 = base + n1 * radius;
        // Side face: normals tilted a little toward the apex direction so
        // the cone shades as a cone rather than a flat-sided fan -- a
        // cheap stand-in for the true slant normal.
        const Vec3 side0 = normalize(n0 + dir * 0.35f);
        const Vec3 side1 = normalize(n1 + dir * 0.35f);
        const Vec3 apexNormal = normalize(normalize(n0 + n1) + dir * 0.35f);
        vertices.emplace_back(p0, side0, color);
        vertices.emplace_back(p1, side1, color);
        vertices.emplace_back(apex, apexNormal, color);
        // The base cap, so the head does not read as hollow from the side.
        vertices.emplace_back(base, -dir, color);
        vertices.emplace_back(p1, -dir, color);
        vertices.emplace_back(p0, -dir, color);
    }
    return vertices;
}

std::vector<SceneGizmoVertexIn> cube(
    const Vec3& center, float halfExtent, const Vec3& along, const Vec4& color) {
    if (!(halfExtent > 1e-6f)) return {};
    const GizmoRingFrame frame = gizmoRingFrame(along);
    const Vec3 u = frame.u, v = frame.v;
    const struct {
        Vec3 normal, right, up;
    } faces[6] = {{along, u, v},  {-along, u, -v}, {u, v, along},
                  {-u, v, -along}, {v, along, u},  {-v, along, -u}};

    std::vector<SceneGizmoVertexIn> vertices;
    vertices.reserve(6 * 6);
    for (const auto& f : faces) {
        const Vec3 face = center + f.normal * halfExtent;
        const Vec3 p00 = face - f.right * halfExtent - f.up * halfExtent;
        const Vec3 p10 = face + f.right * halfExtent - f.up * halfExtent;
        const Vec3 p11 = face + f.right * halfExtent + f.up * halfExtent;
        const Vec3 p01 = face - f.right * halfExtent + f.up * halfExtent;
        vertices.emplace_back(p00, f.normal, color);
        vertices.emplace_back(p10, f.normal, color);
        vertices.emplace_back(p11, f.normal, color);
        vertices.emplace_back(p00, f.normal, color);
        vertices.emplace_back(p11, f.normal, color);
        vertices.emplace_back(p01, f.normal, color);
    }
    return vertices;
}

std::vector<SceneGizmoVertexIn> torus(
    const Vec3& center, const Vec3& normal, float radius, float tubeRadius, int ringSegments,
    int tubeSides, const Vec4& color) {
    if (!(radius > 1e-6f) || !(tubeRadius > 1e-6f) || ringSegments < 3 || tubeSides < 3) return {};
    const GizmoRingFrame frame = gizmoRingFrame(normal);

    const auto radial = [&](float angle) {
        return frame.u * std::cos(angle) + frame.v * std::sin(angle);
    };
    struct TubePoint {
        Vec3 position;
        Vec3 normal;
    };
    const auto tubePoint = [&](const Vec3& ringCenter, const Vec3& radialDir, float phase) {
        const Vec3 n = radialDir * std::cos(phase) + normal * std::sin(phase);
        return TubePoint{ringCenter + n * tubeRadius, n};
    };

    std::vector<SceneGizmoVertexIn> vertices;
    vertices.reserve(static_cast<std::size_t>(ringSegments) * static_cast<std::size_t>(tubeSides) * 6);
    for (int i = 0; i < ringSegments; ++i) {
        const float t0 = static_cast<float>(i) / static_cast<float>(ringSegments) * 2.0f * kPi;
        const float t1 = static_cast<float>(i + 1) / static_cast<float>(ringSegments) * 2.0f * kPi;
        const Vec3 radial0 = radial(t0), radial1 = radial(t1);
        const Vec3 c0 = center + radial0 * radius, c1 = center + radial1 * radius;
        for (int j = 0; j < tubeSides; ++j) {
            const float p0 = static_cast<float>(j) / static_cast<float>(tubeSides) * 2.0f * kPi;
            const float p1 = static_cast<float>(j + 1) / static_cast<float>(tubeSides) * 2.0f * kPi;
            const TubePoint a0 = tubePoint(c0, radial0, p0);
            const TubePoint a1 = tubePoint(c0, radial0, p1);
            const TubePoint b0 = tubePoint(c1, radial1, p0);
            const TubePoint b1 = tubePoint(c1, radial1, p1);
            vertices.emplace_back(a0.position, a0.normal, color);
            vertices.emplace_back(b0.position, b0.normal, color);
            vertices.emplace_back(a1.position, a1.normal, color);
            vertices.emplace_back(b0.position, b0.normal, color);
            vertices.emplace_back(b1.position, b1.normal, color);
            vertices.emplace_back(a1.position, a1.normal, color);
        }
    }
    return vertices;
}

std::vector<SceneGizmoVertexIn> sphere(
    const Vec3& center, float radius, const Vec4& color, int latSegments, int lonSegments) {
    if (!(radius > 1e-6f) || latSegments < 2 || lonSegments < 3) return {};
    struct SpherePoint {
        Vec3 position;
        Vec3 normal;
    };
    const auto point = [&](int lat, int lon) {
        const float theta = static_cast<float>(lat) / static_cast<float>(latSegments) * kPi;
        const float phi = static_cast<float>(lon) / static_cast<float>(lonSegments) * 2.0f * kPi;
        const Vec3 n(
            std::sin(theta) * std::cos(phi), std::cos(theta), std::sin(theta) * std::sin(phi));
        return SpherePoint{center + n * radius, n};
    };
    std::vector<SceneGizmoVertexIn> vertices;
    vertices.reserve(static_cast<std::size_t>(latSegments) * static_cast<std::size_t>(lonSegments) * 6);
    for (int lat = 0; lat < latSegments; ++lat) {
        for (int lon = 0; lon < lonSegments; ++lon) {
            const SpherePoint p00 = point(lat, lon);
            const SpherePoint p01 = point(lat, lon + 1);
            const SpherePoint p10 = point(lat + 1, lon);
            const SpherePoint p11 = point(lat + 1, lon + 1);
            vertices.emplace_back(p00.position, p00.normal, color);
            vertices.emplace_back(p10.position, p10.normal, color);
            vertices.emplace_back(p11.position, p11.normal, color);
            vertices.emplace_back(p00.position, p00.normal, color);
            vertices.emplace_back(p11.position, p11.normal, color);
            vertices.emplace_back(p01.position, p01.normal, color);
        }
    }
    return vertices;
}

std::vector<SceneGizmoVertexIn> tubeAlongPolyline(
    const std::vector<Vec3>& points, float radius, int sides, const Vec4& color) {
    if (points.size() < 2) return {};
    std::vector<SceneGizmoVertexIn> vertices;
    for (std::size_t i = 0; i + 1 < points.size(); ++i) {
        append(vertices, cylinder(points[i], points[i + 1], radius, sides, color));
    }
    return vertices;
}

} // namespace SceneGizmoMeshBuilder
} // namespace umeshcore
