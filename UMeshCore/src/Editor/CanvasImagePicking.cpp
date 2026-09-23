#include "umeshcore/Editor/CanvasImagePicking.h"

#include <algorithm>
#include <cfloat>
#include <cmath>

#include "umeshcore/Editor/ToolUtilities.h"

namespace umeshcore::CanvasImagePicking {

namespace {

bool withinReach(Vec2 point, const std::vector<Vec2>& vertices, float slop) {
    if (vertices.empty()) return false;
    Vec2 lo = vertices.front(), hi = lo;
    for (const Vec2& v : vertices) {
        lo = Vec2(std::min(lo.x, v.x), std::min(lo.y, v.y));
        hi = Vec2(std::max(hi.x, v.x), std::max(hi.y, v.y));
    }
    const float dx = std::max({lo.x - point.x, 0.0f, point.x - hi.x});
    const float dy = std::max({lo.y - point.y, 0.0f, point.y - hi.y});
    return dx * dx + dy * dy <= slop * slop;
}

float distanceToGeometry(Vec2 point, const ScreenGeometry& g) {
    float best = FLT_MAX;
    const auto& v = g.screenVertices;
    const auto& idx = g.mesh.indices;
    for (std::size_t i = 0; i + 2 < idx.size(); i += 3) {
        const std::size_t a = idx[i], b = idx[i + 1], c = idx[i + 2];
        if (a >= v.size() || b >= v.size() || c >= v.size()) continue;
        for (const auto& [s, e] : {std::pair{v[a], v[b]}, std::pair{v[b], v[c]}, std::pair{v[c], v[a]}}) {
            best = std::min(best, ToolUtilities::distancePointToSegment(point, s, e));
            if (best == 0.0f) return 0.0f;
        }
    }
    return best;
}

bool pointInPolygon(Vec2 point, const std::vector<Vec2>& polygon) {
    bool inside = false;
    std::size_t j = polygon.size() - 1;
    for (std::size_t i = 0; i < polygon.size(); ++i) {
        const Vec2 a = polygon[i], b = polygon[j];
        if ((a.y > point.y) != (b.y > point.y)) {
            const float t = (point.y - a.y) / (b.y - a.y);
            if (point.x < a.x + t * (b.x - a.x)) inside = !inside;
        }
        j = i;
    }
    return inside;
}

// Distance to the OPAQUE box, mapped to screen through the drawn triangles
// (so it follows a bone). Fewer than three corners mapped: 0, which can
// only make the reach more permissive -- the exact test has already run.
float distanceToOpaqueRegion(Vec2 point, const std::array<float, 4>& opaque, const ScreenGeometry& g) {
    std::vector<Vec2> corners;
    for (const Vec2& uv : {Vec2(opaque[0], opaque[1]), Vec2(opaque[2], opaque[1]), Vec2(opaque[2], opaque[3]),
                           Vec2(opaque[0], opaque[3])}) {
        if (auto p = screenPosition(uv, g)) corners.push_back(*p);
    }
    if (corners.size() < 3) return 0.0f;
    float best = FLT_MAX;
    for (std::size_t i = 0; i < corners.size(); ++i) {
        best = std::min(best, ToolUtilities::distancePointToSegment(point, corners[i], corners[(i + 1) % corners.size()]));
    }
    return pointInPolygon(point, corners) ? 0.0f : best;
}

} // namespace

std::optional<ScreenGeometry> screenGeometry(const SceneImage& image, Vec2 assetSize, const EditorScene& scene,
                                             Vec2 viewSize, CameraState* camera) {
    const Mesh mesh = ToolUtilities::resolvedMesh(image, assetSize);
    if (mesh.indices.size() < 3 || mesh.uvs.empty()) return std::nullopt;
    const std::vector<Vec2> local = scene.skinnedLocalVertices(image, assetSize, scene.isMeshOverlayDeformed(), mesh);
    if (local.size() != mesh.uvs.size()) return std::nullopt;
    const std::vector<Vec2> world = ToolUtilities::transformedVertices(image, local);
    const bool has3DRotation = length(image.rotation3D) > 0.0001f;
    ScreenGeometry g{mesh, {}};
    g.screenVertices.reserve(world.size());
    for (const Vec2& w : world) {
        if (camera == nullptr) {
            g.screenVertices.push_back(w + viewSize * 0.5f);
        } else if (has3DRotation) {
            g.screenVertices.push_back(ToolUtilities::project3DToScreen(w, image.position, image.rotation,
                                                                        image.rotation3D, viewSize, camera));
        } else {
            g.screenVertices.push_back(camera->worldToScreen(w, viewSize));
        }
    }
    return g;
}

std::optional<Vec2> uvAt(Vec2 point, const ScreenGeometry& g) {
    const auto& v = g.screenVertices;
    const auto& uvs = g.mesh.uvs;
    const auto& idx = g.mesh.indices;
    for (std::size_t i = 0; i + 2 < idx.size(); i += 3) {
        const std::size_t a = idx[i], b = idx[i + 1], c = idx[i + 2];
        if (a >= v.size() || b >= v.size() || c >= v.size()) continue;
        const Vec2 v0 = v[b] - v[a], v1 = v[c] - v[a], v2 = point - v[a];
        const float denominator = v0.x * v1.y - v1.x * v0.y;
        if (!(std::fabs(denominator) > 1e-7f)) continue; // degenerate sliver
        const float inverse = 1.0f / denominator;
        const float beta = (v2.x * v1.y - v1.x * v2.y) * inverse;
        const float gamma = (v0.x * v2.y - v2.x * v0.y) * inverse;
        const float alpha = 1.0f - beta - gamma;
        if (alpha >= 0 && beta >= 0 && gamma >= 0) return uvs[a] * alpha + uvs[b] * beta + uvs[c] * gamma;
    }
    return std::nullopt;
}

std::optional<Vec2> screenPosition(Vec2 uv, const ScreenGeometry& g) {
    const auto& v = g.screenVertices;
    const auto& uvs = g.mesh.uvs;
    const auto& idx = g.mesh.indices;
    for (std::size_t i = 0; i + 2 < idx.size(); i += 3) {
        const std::size_t a = idx[i], b = idx[i + 1], c = idx[i + 2];
        if (a >= v.size() || b >= v.size() || c >= v.size() || a >= uvs.size() || b >= uvs.size() ||
            c >= uvs.size()) {
            continue;
        }
        const Vec2 v0 = uvs[b] - uvs[a], v1 = uvs[c] - uvs[a], v2 = uv - uvs[a];
        const float denominator = v0.x * v1.y - v1.x * v0.y;
        if (!(std::fabs(denominator) > 1e-9f)) continue;
        const float inverse = 1.0f / denominator;
        const float beta = (v2.x * v1.y - v1.x * v2.y) * inverse;
        const float gamma = (v0.x * v2.y - v2.x * v0.y) * inverse;
        const float alpha = 1.0f - beta - gamma;
        if (alpha >= 0 && beta >= 0 && gamma >= 0) return v[a] * alpha + v[b] * beta + v[c] * gamma;
    }
    return std::nullopt;
}

std::optional<ImageHit> imageHit(Vec2 screenPoint, Vec2 viewSize, const EditorScene& scene,
                                 const AssetAlphaStore& assets, CameraState* camera, float hitScale) {
    const float slop = slopRadius(hitScale);
    std::optional<ImageHit> nearest;
    // Draw order, front first -- what the renderer draws, minus what a skin
    // or an attachment key displaced.
    for (const SceneImage& image : scene.renderOrderedImages()) {
        if (image.isHidden) continue;
        const AssetAlpha* asset = assets.find(image.assetID);
        if (asset == nullptr) continue;
        // No opaque texel anywhere: nothing a click can land on.
        if (!asset->opaqueBounds.has_value()) continue;
        const auto geometry = screenGeometry(image, asset->size, scene, viewSize, camera);
        if (!geometry.has_value()) continue;
        if (!withinReach(screenPoint, geometry->screenVertices, slop)) continue;

        if (const auto uv = uvAt(screenPoint, *geometry)) {
            // The front-most opaque texel: nothing behind it can beat this.
            if (asset->mask.alphaAtUV(uv->x, uv->y) > AlphaMask::kOpaqueCutoff) {
                return ImageHit{image.id, true, 0.0f};
            }
            // On the art's triangles but a transparent texel: the click goes
            // straight through, and is NOT a zero-distance near miss.
            continue;
        }
        const float distance = std::max(distanceToGeometry(screenPoint, *geometry),
                                        distanceToOpaqueRegion(screenPoint, *asset->opaqueBounds, *geometry));
        if (distance <= slop && (!nearest.has_value() || distance < nearest->distance)) {
            nearest = ImageHit{image.id, false, distance};
        }
    }
    return nearest;
}

std::optional<Uuid> hitTestScreen(Vec2 screenPoint, Vec2 viewSize, const EditorScene& scene,
                                  const AssetAlphaStore& assets, CameraState* camera, float hitScale) {
    const auto hit = imageHit(screenPoint, viewSize, scene, assets, camera, hitScale);
    return hit.has_value() ? std::optional<Uuid>(hit->id) : std::nullopt;
}

std::vector<Uuid> hitTestRect(const ToolUtilities::ScreenRect& rect, Vec2 viewSize, const EditorScene& scene,
                              const AssetAlphaStore& assets, CameraState* camera) {
    std::vector<Uuid> hits;
    for (const SceneImage& image : scene.renderOrderedImages()) {
        if (image.isHidden) continue;
        const AssetAlpha* asset = assets.find(image.assetID);
        if (asset == nullptr || !asset->opaqueBounds.has_value()) continue;
        const auto geometry = screenGeometry(image, asset->size, scene, viewSize, camera);
        if (!geometry.has_value()) continue;
        bool touches = false;
        for (const Vec2& v : geometry->screenVertices) {
            if (v.x >= rect.min.x && v.x <= rect.max.x && v.y >= rect.min.y && v.y <= rect.max.y) {
                touches = true;
                break;
            }
        }
        if (!touches) {
            for (const Vec2& p : {(rect.min + rect.max) * 0.5f, rect.min, Vec2(rect.max.x, rect.min.y), rect.max,
                                  Vec2(rect.min.x, rect.max.y)}) {
                if (uvAt(p, *geometry).has_value()) {
                    touches = true;
                    break;
                }
            }
        }
        if (touches) hits.push_back(image.id);
    }
    return hits;
}

std::optional<ToolUtilities::MeshProjection> selectedMeshProjection(const EditorScene& scene,
                                                                    const AssetAlphaStore& assets,
                                                                    CameraState* camera, Vec2 viewSize,
                                                                    float hitScale) {
    if (!scene.selectedImageID.has_value()) return std::nullopt;
    const SceneImage* image = scene.image(*scene.selectedImageID);
    if (image == nullptr) return std::nullopt;
    const AssetAlpha* asset = assets.find(image->assetID);
    if (asset == nullptr) return std::nullopt;
    return ToolUtilities::meshProjection(*image, asset->size, scene.skeleton, scene.isMeshOverlayDeformed(),
                                         scene.meshWeightPaintEnabled, camera, viewSize, hitScale);
}

Bounds2D boundsForImage(const SceneImage& image, Vec2 assetSize) {
    Bounds2D bounds = Bounds2D::empty();
    const auto corners = ToolUtilities::transformedCorners(image, ToolUtilities::localFrame(image.mesh.vertices, assetSize));
    for (const Vec2& c : corners) bounds.include(c);
    return bounds;
}

std::optional<Bounds2D> boundsForScene(const EditorScene& scene, const AssetAlphaStore& assets) {
    Bounds2D bounds = Bounds2D::empty();
    bool hasAny = false;
    for (const SceneImage& image : scene.images) {
        if (image.isHidden) continue;
        const AssetAlpha* asset = assets.find(image.assetID);
        if (asset == nullptr) continue;
        const Bounds2D b = boundsForImage(image, asset->size);
        if (b.isValid()) {
            bounds.include(b.min);
            bounds.include(b.max);
            hasAny = true;
        }
    }
    return hasAny ? std::optional<Bounds2D>(bounds) : std::nullopt;
}

ImageHitTestFn makeImageHitTest(const EditorScene& scene, const AssetAlphaStore& assets, float hitScale) {
    return [&scene, &assets, hitScale](const Vec2& screenPoint, const Vec2& viewSize, CameraState* camera) {
        return imageHit(screenPoint, viewSize, scene, assets, camera, hitScale);
    };
}

} // namespace umeshcore::CanvasImagePicking
