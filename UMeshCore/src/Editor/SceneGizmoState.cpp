#include "umeshcore/Editor/SceneGizmoState.h"

#include <algorithm>
#include <cmath>

namespace umeshcore {

namespace {
constexpr float kPi = 3.14159265358979323846f;
}

// ---- The basis ----------------------------------------------------------

std::optional<Vec3> SceneGizmoBasis::direction(SceneGizmoHandleId id) const {
    switch (id) {
        case SceneGizmoHandleId::kAxisX: return x;
        case SceneGizmoHandleId::kAxisY: return y;
        case SceneGizmoHandleId::kAxisZ: return z;
        default: return std::nullopt;
    }
}

SceneGizmoBasis layerBasis(const SceneLayer& layer) {
    const SceneLayerOrientation axes = layer.orientation();
    return SceneGizmoBasis{layer.worldOrigin(), axes.x, axes.y, axes.z};
}

SceneGizmoBasis worldBasis(const SceneLayer& layer) {
    return SceneGizmoBasis{layer.worldOrigin(), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)};
}

SceneGizmoBasis translateBasis(const SceneLayer& layer, SceneGizmoTool tool) {
    return tool == SceneGizmoTool::kTranslate ? worldBasis(layer) : layerBasis(layer);
}

SceneGizmoBasis lightBasis(const SceneLight& light) {
    if (light.kind == SceneLightKind::kPoint) {
        return SceneGizmoBasis{light.world(), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)};
    }
    const Vec3 forward = light.direction();
    const GizmoRingFrame frame = gizmoRingFrame(forward);
    return SceneGizmoBasis{light.world(), frame.u, frame.v, forward};
}

SceneGizmoBasis cameraBasis(const SceneCamera& camera) {
    return SceneGizmoBasis{
        Vec3(camera.position.x, camera.position.y, camera.positionZ), Vec3(1, 0, 0),
        Vec3(0, 1, 0), Vec3(0, 0, 1)};
}

// ---- The stabilised projection ------------------------------------------

SceneProjection gizmoProjection(
    const Vec3& origin, const SceneProjection& real, const Vec2& viewSize) {
    Vec3 forward = origin - real.eye;
    const float len = length(forward);
    // The eye sitting exactly on the origin has no direction to look along.
    if (!(len > 1e-4f)) return real;
    forward = forward / len;

    // The real camera's own right, read off its view matrix's rows -- a
    // view matrix IS a basis in its rows by construction.
    const Mat4& view = real.viewMatrix;
    Vec3 right(view.columns[0].x, view.columns[1].x, view.columns[2].x);
    right -= forward * dot(right, forward);
    if (length(right) < 1e-4f) {
        // Looking almost straight along the real camera's own up (or
        // down): its right vector has nothing left once projected out of
        // `forward`. A world axis stands in -- which one only matters in
        // that it be consistent, not which.
        right = std::fabs(forward.y) < 0.9f ? cross(Vec3(0, 1, 0), forward)
                                            : cross(Vec3(1, 0, 0), forward);
    }
    right = normalize(right);
    const Vec3 up = cross(forward, right);

    return SceneProjection::fromFrame(
        real.eye, CameraBasis{right, up, forward},
        (viewSize.y * 0.5f) / std::tan(kSceneGizmoHalfFieldOfView), real.nearZ, 1000000.0f,
        viewSize);
}

std::optional<Vec2> SceneGizmoState::map(const Vec3& world) const {
    const std::optional<Vec2> projected = projection.project(world);
    if (!projected.has_value()) return std::nullopt;
    return *projected + screenOffsetPx;
}

std::optional<SceneGizmoState> sceneGizmoState(
    const SceneGizmoBasis& basis, const SceneProjection& real, const Vec2& viewSize) {
    // THE CURRENT TRANSFORM, THIS PASS. Everything here is derived from
    // the basis just read off the element and from the camera as it is
    // now; nothing is carried over from the last frame, so the handles
    // cannot trail what they are attached to.
    const std::optional<Vec2> realOriginPx = real.project(basis.origin);
    if (!realOriginPx.has_value()) return std::nullopt;

    SceneGizmoState state;
    state.basis = basis;
    state.realProjection = real;
    state.projection = gizmoProjection(basis.origin, real, viewSize);
    // Where the gizmo camera's principal axis always lands -- dead centre
    // -- versus where the object actually is on screen.
    state.screenOffsetPx = *realOriginPx - viewSize * 0.5f;

    const float depth = real.depth(basis.origin);
    const std::optional<float> scale = real.worldLengthForPixels(kSceneGizmoHandlePixels, depth);
    if (!scale.has_value() || !(*scale > 0.0f)) return std::nullopt;
    state.scale = *scale;
    return state;
}

// ---- The shape ----------------------------------------------------------

std::optional<SceneGizmoScreenAxis> projectAxis(
    const SceneGizmoState& state, const Vec3& direction) {
    const std::optional<Vec2> originPx = state.map(state.basis.origin);
    const std::optional<Vec2> tipPx = state.map(state.basis.origin + direction * state.scale);
    if (!originPx.has_value() || !tipPx.has_value()) return std::nullopt;
    const Vec2 span = *tipPx - *originPx;
    const float len = length(span);
    if (!(len >= kSceneGizmoMinAxisPixels)) return std::nullopt;
    return SceneGizmoScreenAxis{*originPx, *tipPx, span / len};
}

float axisDepthAlpha(const SceneGizmoState& state, const Vec3& direction) {
    const float here = state.realProjection.depth(state.basis.origin);
    const float there = state.realProjection.depth(state.basis.origin + direction);
    return there <= here ? 1.0f : kSceneGizmoAwayAlpha;
}

std::vector<std::vector<Vec2>> ringArcs(
    const SceneGizmoState& state, const Vec3& normal, float radius) {
    const GizmoRingFrame frame = gizmoRingFrame(normal);
    const auto world = [&](int index) {
        const float a = static_cast<float>(index % kSceneGizmoRingSamples) /
                        static_cast<float>(kSceneGizmoRingSamples) * 2.0f * kPi;
        return state.basis.origin +
               (frame.u * std::cos(a) + frame.v * std::sin(a)) * radius;
    };

    std::vector<std::vector<Vec2>> arcs;
    std::vector<Vec2> current;
    const float near = state.projection.nearZ;
    for (int i = 0; i < kSceneGizmoRingSamples; ++i) {
        const Vec3 w0 = world(i), w1 = world(i + 1);
        const float d0 = state.projection.depth(w0), d1 = state.projection.depth(w1);
        if (d0 >= near) {
            const std::optional<Vec2> p = state.map(w0);
            if (p.has_value()) current.push_back(*p);
        }
        if ((d0 >= near) == (d1 >= near)) continue;
        // The crossing itself, nudged a hair towards the far side so the
        // projection's own strict `w > nearZ` guard still answers for a
        // point that is exactly on the plane.
        const float t = (near - d0) / (d1 - d0);
        const Vec3 cut = w0 + (w1 - w0) * t;
        const Vec3 toward = normalize(cut - state.projection.eye);
        const std::optional<Vec2> p = state.map(cut + toward * kSceneGizmoNearNudge);
        if (p.has_value()) current.push_back(*p);
        if (current.size() >= 2) arcs.push_back(current);
        current.clear();
    }
    if (current.size() >= 2) arcs.push_back(current);
    return arcs;
}

std::optional<Vec3> planeNormal(SceneGizmoHandleId id, const SceneGizmoBasis& basis) {
    switch (id) {
        case SceneGizmoHandleId::kPlaneXY: return basis.z;
        case SceneGizmoHandleId::kPlaneXZ: return basis.y;
        case SceneGizmoHandleId::kPlaneYZ: return basis.x;
        default: return std::nullopt;
    }
}

PlaneAxes planeAxes(SceneGizmoHandleId id, const SceneGizmoBasis& basis) {
    switch (id) {
        case SceneGizmoHandleId::kPlaneXY: return PlaneAxes{basis.x, basis.y};
        case SceneGizmoHandleId::kPlaneXZ: return PlaneAxes{basis.x, basis.z};
        default: return PlaneAxes{basis.y, basis.z};
    }
}

bool planeFacesCamera(const SceneGizmoState& state, SceneGizmoHandleId id) {
    const std::optional<Vec3> normal = planeNormal(id, state.basis);
    if (!normal.has_value()) return false;
    // Turned too far edge-on and the quad is a sliver: there is nothing to
    // aim at, and the ray-plane intersection behind it becomes
    // ill-conditioned in the same breath. Offered or refused on the same
    // fact, rather than drawn and then failing when grabbed.
    const float facing =
        std::fabs(dot(normalize(state.basis.origin - state.realProjection.eye), *normal));
    return facing > kSceneGizmoMinPlaneFacing;
}

std::optional<std::vector<Vec2>> planeQuad(
    const SceneGizmoState& state, SceneGizmoHandleId id) {
    if (!planeFacesCamera(state, id)) return std::nullopt;

    const PlaneAxes axes = planeAxes(id, state.basis);
    const float lo = kSceneGizmoPlaneOffset * state.scale;
    const float hi = (kSceneGizmoPlaneOffset + kSceneGizmoPlaneSize) * state.scale;
    const Vec3 corners[4] = {
        state.basis.origin + axes.a * lo + axes.b * lo,
        state.basis.origin + axes.a * hi + axes.b * lo,
        state.basis.origin + axes.a * hi + axes.b * hi,
        state.basis.origin + axes.a * lo + axes.b * hi};

    std::vector<Vec2> screen;
    screen.reserve(4);
    for (const Vec3& corner : corners) {
        const std::optional<Vec2> p = state.map(corner);
        if (!p.has_value()) return std::nullopt; // all four, or none
        screen.push_back(*p);
    }
    return screen;
}

} // namespace umeshcore
