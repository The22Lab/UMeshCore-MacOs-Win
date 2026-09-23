#include "umeshcore/Editor/SceneLightGizmo.h"

#include "umeshcore/Editor/SceneGizmoState.h" // kSceneGizmoHandlePixels

#include <algorithm>
#include <cmath>

namespace umeshcore {

namespace {
constexpr float kPi = 3.14159265358979323846f;
}

std::vector<SceneLightHandle> lightHandlesFor(SceneLightKind kind) {
    switch (kind) {
        case SceneLightKind::kPoint:
            return {SceneLightHandle::kSoftness, SceneLightHandle::kRadius};
        case SceneLightKind::kSpot:
            // Angles before radius: the two arcs sit ON the radius ring at
            // the cone's edge, so where they overlap the more specific
            // handle wins.
            return {
                SceneLightHandle::kInnerAngle, SceneLightHandle::kOuterAngle,
                SceneLightHandle::kSoftness, SceneLightHandle::kRadius,
                SceneLightHandle::kDirection};
        case SceneLightKind::kDirectional:
            // No position and no falloff -- a direction and nothing else.
            return {SceneLightHandle::kDirection};
    }
    return {};
}

GizmoRingFrame lightFacingFrame(const SceneProjection& projection) {
    const Mat4& view = projection.viewMatrix;
    const Vec3 right(view.columns[0].x, view.columns[1].x, view.columns[2].x);
    const Vec3 up(view.columns[0].y, view.columns[1].y, view.columns[2].y);
    const float rl = length(right), ul = length(up);
    if (!(rl > 1e-6f) || !(ul > 1e-6f)) return GizmoRingFrame{Vec3(1, 0, 0), Vec3(0, 1, 0)};
    return GizmoRingFrame{right / rl, up / ul};
}

Vec3 lightViewAxis(const SceneProjection& projection) {
    const Mat4& view = projection.viewMatrix;
    const Vec3 forward(view.columns[0].z, view.columns[1].z, view.columns[2].z);
    const float len = length(forward);
    return len > 1e-6f ? forward / len : Vec3(0, 0, 1);
}

std::vector<Vec3> lightRing(
    const Vec3& centre, float radius, const GizmoRingFrame& frame, int samples) {
    if (!(radius > 0.0f) || samples < 3) return {};
    std::vector<Vec3> out;
    out.reserve(static_cast<std::size_t>(samples) + 1);
    for (int index = 0; index <= samples; ++index) {
        const float a = static_cast<float>(index) / static_cast<float>(samples) * 2.0f * kPi;
        out.push_back(centre + frame.u * (std::cos(a) * radius) + frame.v * (std::sin(a) * radius));
    }
    return out;
}

Vec3 lightConePlane(const Vec3& axis, const SceneProjection& projection) {
    const Vec3 right = lightFacingFrame(projection).u;
    Vec3 u = right - axis * dot(right, axis);
    const float len = length(u);
    if (len > 1e-4f) return u / len;
    // Seen down the beam: every direction across the axis is equally
    // side-on, so any perpendicular is as honest as another.
    return gizmoRingFrame(axis).u;
}

ConeRim lightConeRim(
    const Vec3& centre, const Vec3& axis, const Vec3& across, float halfAngle, float distance) {
    const float a = std::min(std::max(halfAngle, 0.0f), kPi);
    const Vec3 along = axis * (std::cos(a) * distance);
    const Vec3 side = across * (std::sin(a) * distance);
    return ConeRim{centre + along + side, centre + along - side};
}

std::vector<Vec3> lightConeArc(
    const Vec3& centre, const Vec3& axis, const Vec3& across, float halfAngle, float distance,
    int samples) {
    const float a = std::min(std::max(halfAngle, 0.0f), kPi);
    if (!(distance > 0.0f) || samples < 2) return {};
    std::vector<Vec3> out;
    out.reserve(static_cast<std::size_t>(samples) + 1);
    for (int index = 0; index <= samples; ++index) {
        const float t = -a + 2.0f * a * static_cast<float>(index) / static_cast<float>(samples);
        out.push_back(centre + axis * (std::cos(t) * distance) + across * (std::sin(t) * distance));
    }
    return out;
}

std::optional<Vec3> lightHandlePosition(
    SceneLightHandle handle, const SceneLight& light, const SceneProjection& projection,
    float directionLength) {
    const Vec3 centre = light.world();
    const GizmoRingFrame frame = lightFacingFrame(projection);
    switch (handle) {
        case SceneLightHandle::kRadius:
            if (!sceneLightIsPositional(light.kind) || !(light.radius > 0.0f)) return std::nullopt;
            return centre + frame.u * light.radius;
        case SceneLightHandle::kSoftness:
            if (!sceneLightIsPositional(light.kind) || !(light.radius > 0.0f)) return std::nullopt;
            // On the inner edge of the band, and on the VERTICAL axis of
            // the ring so it can never sit on top of the radius handle
            // however small the band gets.
            return centre + frame.v * light.innerRadius();
        case SceneLightHandle::kDirection:
            if (light.kind == SceneLightKind::kPoint) return std::nullopt;
            return centre + light.direction() * directionLength;
        case SceneLightHandle::kInnerAngle:
        case SceneLightHandle::kOuterAngle: {
            if (light.kind != SceneLightKind::kSpot || !(light.radius > 0.0f)) return std::nullopt;
            const Vec3 across = lightConePlane(light.direction(), projection);
            const float angle = handle == SceneLightHandle::kInnerAngle ? light.innerAngle
                                                                        : light.outerAngle;
            return lightConeRim(centre, light.direction(), across, angle, light.radius).a;
        }
    }
    return std::nullopt;
}

// ---- What a drag means --------------------------------------------------

float lightRadiusForHit(const Vec3& hit, const Vec3& centre) {
    return std::max(length(hit - centre), 0.0f);
}

std::optional<float> lightHalfAngleForHit(const Vec3& hit, const Vec3& centre, const Vec3& axis) {
    const Vec3 d = hit - centre;
    const float len = length(d);
    if (!(len > 1e-5f)) return std::nullopt;
    const float cosine = std::min(std::max(dot(d / len, axis), -1.0f), 1.0f);
    return std::acos(cosine);
}

float lightSoftnessForHit(const Vec3& hit, const Vec3& centre, float radius) {
    if (!(radius > 1e-5f)) return 1.0f;
    const float inner = length(hit - centre);
    return std::min(std::max(1.0f - inner / radius, 0.0f), 1.0f);
}

void aimLight(SceneLight& light, const Vec3& direction) {
    const float len = length(direction);
    if (!(len > 1e-6f)) return;
    const Vec3 d = direction / len;
    light.elevation = std::asin(std::min(std::max(d.z, -1.0f), 1.0f));
    const float horizontal = length(Vec2(d.x, d.y));
    // THE GIMBAL CASE: straight along Z has no azimuth, and taking
    // `atan2(0, 0)` would snap the stored one to zero.
    if (!(horizontal > 1e-5f)) return;
    light.azimuth = std::atan2(d.y, d.x);
}

Vec3 rotatedAbout(const Vec3& direction, const Vec3& axis, float angle) {
    const float len = length(axis);
    if (!(len > 1e-6f)) return direction;
    const Vec3 k = axis / len;
    const float c = std::cos(angle), s = std::sin(angle);
    return direction * c + cross(k, direction) * s + k * (dot(k, direction) * (1.0f - c));
}

// ---- The one geometry both consumers read -------------------------------

LightWorldGeometry lightWorldGeometry(const SceneLight& light, const SceneProjection& projection) {
    LightWorldGeometry out;
    const Vec3 centre = light.world();
    out.centre = centre;
    out.viewAxis = lightViewAxis(projection);

    // A fixed number of PIXELS for a directional light, which has no
    // radius to borrow, and the rim for the others -- so a spot's aim
    // handle sits where its light actually stops.
    float beamWorld = 0.0f;
    if (light.kind == SceneLightKind::kDirectional) {
        const float depth = projection.depth(centre);
        beamWorld = projection.worldLengthForPixels(kSceneGizmoHandlePixels, depth).value_or(0.0f);
    } else {
        beamWorld = light.radius;
    }

    out.influenceRadius =
        (sceneLightIsPositional(light.kind) && light.radius > 0.0f) ? light.radius : 0.0f;
    out.innerRadius = (out.influenceRadius > 0.0f && light.innerRadius() > light.radius * 0.02f)
                          ? light.innerRadius()
                          : 0.0f;

    if (light.kind != SceneLightKind::kPoint && beamWorld > 0.0f) {
        out.beam = SceneGizmoLayout::Segment{centre, centre + light.direction() * beamWorld};
    }

    if (light.kind == SceneLightKind::kSpot && light.radius > 0.0f) {
        const Vec3 across = lightConePlane(light.direction(), projection);
        const auto edges = [&](float angle) {
            const ConeRim rim =
                lightConeRim(centre, light.direction(), across, angle, light.radius);
            return std::vector<SceneGizmoLayout::Segment>{
                SceneGizmoLayout::Segment{centre, rim.a},
                SceneGizmoLayout::Segment{centre, rim.b}};
        };
        out.outerEdges = edges(light.outerAngle);
        out.innerEdges = edges(light.innerAngle);
        out.outerArc = lightConeArc(
            centre, light.direction(), across, light.outerAngle, light.radius);
        out.innerArc = lightConeArc(
            centre, light.direction(), across, light.innerAngle, light.radius);
    }

    for (SceneLightHandle handle : lightHandlesFor(light.kind)) {
        const std::optional<Vec3> world =
            lightHandlePosition(handle, light, projection, beamWorld);
        if (world.has_value()) out.handlePositions.emplace_back(handle, *world);
    }
    return out;
}

SceneGizmoLayout::LightDiagram lightDiagram(
    const LightWorldGeometry& geometry, const SceneLight& light,
    const std::optional<SceneLightHandle>& highlighted) {
    SceneGizmoLayout::LightDiagram diagram;
    diagram.centre = geometry.centre;
    // A disabled light's diagram is flattened to WHITE, and the mesh builder
    // then dims it by `isEnabled`. The two together are the "off" look --
    // Swift's mesh builder calls its dim "the same reading `drawLight` gave
    // it by mixing `light.colour` down towards white". Keeping the hue here
    // would draw an off light as a faded version of its own colour instead.
    diagram.tint = light.isEnabled ? Vec4(light.color.x, light.color.y, light.color.z, 1.0f)
                                   : Vec4(1.0f, 1.0f, 1.0f, 1.0f);
    diagram.isEnabled = light.isEnabled;
    diagram.viewAxis = geometry.viewAxis;
    diagram.influenceRadius = geometry.influenceRadius;
    diagram.innerRadius = geometry.innerRadius;
    diagram.beam = geometry.beam;
    diagram.outerEdges = geometry.outerEdges;
    diagram.innerEdges = geometry.innerEdges;
    diagram.outerArc = geometry.outerArc;
    diagram.innerArc = geometry.innerArc;
    for (const auto& entry : geometry.handlePositions) {
        diagram.handles.push_back(SceneGizmoLayout::LightHandle{
            entry.second, highlighted.has_value() && *highlighted == entry.first});
    }
    return diagram;
}

} // namespace umeshcore
