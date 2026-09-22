// Implementations for the Scene model headers. One translation unit
// because the five types are one model and their bodies are short; the
// headers are where the reasoning lives, per this port's convention.

#include "umeshcore/Model/Scene/SceneCamera.h"
#include "umeshcore/Model/Scene/SceneComposition.h"
#include "umeshcore/Model/Scene/SceneLayer.h"
#include "umeshcore/Model/Scene/SceneLight.h"
#include "umeshcore/Model/Scene/SceneMaterial.h"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace umeshcore {

namespace {
float clampFinite(float value, float fallback, float lo, float hi) {
    const float v = std::isfinite(value) ? value : fallback;
    return std::min(std::max(v, lo), hi);
}
} // namespace

// ---- SceneMaterial -----------------------------------------------------

SceneMaterial SceneMaterial::sanitized() const {
    SceneMaterial out = *this;
    out.normalStrength = clampFinite(normalStrength, 1.0f, 0.0f, 8.0f);
    out.smoothness = clampFinite(smoothness, 0.0f, 0.0f, 1.0f);
    out.contrast = clampFinite(contrast, 0.0f, 0.0f, 4.0f);
    out.parallaxDepth = clampFinite(parallaxDepth, 0.05f, 0.0f, 0.5f);
    out.parallaxQuality = clampFinite(parallaxQuality, 0.5f, 0.0f, 1.0f);
    out.parallaxOcclusionStrength = clampFinite(parallaxOcclusionStrength, 0.0f, 0.0f, 1.0f);
    return out;
}

// ---- SceneLightMask / SceneLight --------------------------------------

std::vector<int> SceneLightMask::channelNumbers() const {
    std::vector<int> out;
    for (int i = 0; i < 8; ++i) {
        if (reaches(channel(i))) out.push_back(i + 1);
    }
    return out;
}

SceneLightParams SceneLight::params() const {
    SceneLightParams out;
    out.kind = kind;
    out.blend = blend;
    out.mask = mask.rawValue;
    out.isEnabled = isEnabled;
    out.world = world();
    out.azimuth = azimuth;
    out.elevation = elevation;
    out.radius = radius;
    out.intensity = intensity;
    out.color = color;
    out.softness = softness;
    out.innerAngle = innerAngle;
    out.outerAngle = outerAngle;
    out.depthInfluence = depthInfluence;
    out.normalInfluence = normalInfluence;
    out.castsShadows = castsShadows;
    out.falloff = falloff;
    return out;
}

// ---- SceneCamera -------------------------------------------------------

float SceneCamera::focalLength(float viewHeight) const {
    const float half = fieldOfView * 3.14159265358979323846f / 180.0f * 0.5f;
    return (viewHeight * 0.5f) / std::max(std::tan(half), 0.000001f);
}

// ---- SceneLayer --------------------------------------------------------

Vec2 SceneLayer::planePoint(const Vec2& local) const {
    const float sx = local.x * scale.x;
    const float sy = local.y * scale.y;
    const float hx = sx + sy * shear.x;
    const float hy = sy + sx * shear.y;
    const float c = std::cos(rotation), s = std::sin(rotation);
    return Vec2(hx * c - hy * s, hx * s + hy * c);
}

Vec3 SceneLayer::liftToWorld(const Vec2& point) const {
    const float cp = std::cos(rotation3D.x), sp = std::sin(rotation3D.x);
    const float cy = std::cos(rotation3D.y), sy = std::sin(rotation3D.y);
    const float y1 = point.y * cp;
    const float z1 = point.y * sp;
    return Vec3(point.x * cy + z1 * sy, y1, -point.x * sy + z1 * cy);
}

SceneLayer::Orientation SceneLayer::orientation() const {
    const float c = std::cos(rotation), s = std::sin(rotation);
    const Vec3 x = liftToWorld(Vec2(c, s));
    const Vec3 y = liftToWorld(Vec2(-s, c));
    return Orientation{x, y, cross(x, y)};
}

SceneLayer::Plane SceneLayer::lightingPlane() const {
    return Plane{worldOrigin(), orientation().z};
}

SceneLayer::TangentFrame SceneLayer::lightingTangent() const {
    const Orientation axes = orientation();
    // `sign` of zero is zero, and a frame multiplied by zero is not a
    // frame. A degenerate axis keeps the unmirrored reading, which is what
    // the card looked like before it was flattened.
    const float sx = scale.x < 0.0f ? -1.0f : 1.0f;
    const float sy = scale.y < 0.0f ? -1.0f : 1.0f;
    return TangentFrame{axes.x * sx, sx * sy};
}

std::optional<int> SceneLayer::rigFrame(int sceneFrame, int clipDuration) const {
    const SceneRigContent* rig = std::get_if<SceneRigContent>(&content);
    if (rig == nullptr) return std::nullopt;
    if (clipDuration <= 0) return rig->startFrame;
    const int advanced =
        rig->startFrame + static_cast<int>(std::round(static_cast<float>(sceneFrame) * rig->speed));
    if (!rig->loops) return std::min(std::max(advanced, 0), clipDuration - 1);
    // C++'s % keeps the sign of the dividend, exactly as Swift's does, so
    // a negative start frame or a negative speed would index backwards off
    // the clip without this.
    const int wrapped = advanced % clipDuration;
    return wrapped < 0 ? wrapped + clipDuration : wrapped;
}

// ---- SceneComposition --------------------------------------------------

const SceneLayer* SceneComposition::layer(const Uuid& id_) const {
    for (const SceneLayer& candidate : layers) {
        if (candidate.id == id_) return &candidate;
    }
    return nullptr;
}

const SceneLight* SceneComposition::light(const Uuid& id_) const {
    for (const SceneLight& candidate : lights) {
        if (candidate.id == id_) return &candidate;
    }
    return nullptr;
}

std::vector<SceneLayer> SceneComposition::drawOrderedLayers() const {
    std::vector<std::size_t> order(layers.size());
    std::iota(order.begin(), order.end(), std::size_t{0});
    // Stable by construction: the index is the tie-break, so two cards on
    // one layer keep the order the artist created them in, run after run.
    std::sort(order.begin(), order.end(), [this](std::size_t a, std::size_t b) {
        if (layers[a].sortingOrder != layers[b].sortingOrder) {
            return layers[a].sortingOrder < layers[b].sortingOrder;
        }
        return a < b;
    });
    std::vector<SceneLayer> out;
    out.reserve(layers.size());
    for (std::size_t index : order) out.push_back(layers[index]);
    return out;
}

std::vector<SceneLayer> SceneComposition::frontToBackLayers() const {
    std::vector<SceneLayer> out = drawOrderedLayers();
    std::reverse(out.begin(), out.end());
    return out;
}

std::vector<SceneLayer> SceneComposition::visibleLayers() const {
    std::vector<SceneLayer> out;
    for (const SceneLayer& candidate : drawOrderedLayers()) {
        if (!candidate.isHidden && candidate.opacity > 0.001f) out.push_back(candidate);
    }
    return out;
}

int SceneComposition::frontSortingOrder() const {
    int highest = -1;
    bool any = false;
    for (const SceneLayer& candidate : layers) {
        if (!any || candidate.sortingOrder > highest) highest = candidate.sortingOrder;
        any = true;
    }
    return highest + 1;
}

void SceneFrontView::zoomBy(float factor) {
    zoom = std::min(std::max(zoom * factor, kMinZoom), kMaxZoom);
}

} // namespace umeshcore

// ---- The seam with Render (SceneRenderAdapters.h) ----------------------

#include "umeshcore/Model/Scene/SceneRenderAdapters.h"

namespace umeshcore {

SceneProjection sceneProjection(const SceneCamera& shot, const Vec2& viewSize) {
    return SceneProjection(
        shot.world(), shot.rotation3D.x, shot.rotation3D.y, shot.rotation3D.z, shot.fieldOfView,
        shot.nearZ, shot.farZ, viewSize);
}

SceneProjection shotAsViewProjection(const SceneCamera& shot, const Vec2& viewSize) {
    // The fly camera's near plane and far plane, not the shot's: this is
    // the set seen from the side, where a near plane the artist set for
    // the render would clip the preview for reasons that belong to the
    // shot rather than to the view.
    return SceneProjection(
        shot.world(), shot.rotation3D.x, shot.rotation3D.y, shot.rotation3D.z, shot.fieldOfView,
        SceneViewCamera::kNearDistance, SceneViewCamera::kFarDistance, viewSize);
}

Vec3 cardPoint(const SceneLayer& layer, const Vec2& local) {
    return layer.worldOrigin() + layer.liftToWorld(layer.planePoint(local));
}

std::vector<Vec3> cardCorners(const SceneLayer& layer, const Vec2& localMin, const Vec2& localMax) {
    return {
        cardPoint(layer, Vec2(localMin.x, localMax.y)),
        cardPoint(layer, Vec2(localMax.x, localMax.y)),
        cardPoint(layer, Vec2(localMax.x, localMin.y)),
        cardPoint(layer, Vec2(localMin.x, localMin.y))};
}

std::vector<Vec3> shotFrame(const SceneCamera& shot, const Vec2& renderSize, float distance) {
    return shotFrame(shot.world(), shot.rotation3D, shot.fieldOfView, renderSize, distance);
}

} // namespace umeshcore
