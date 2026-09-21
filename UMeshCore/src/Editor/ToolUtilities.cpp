#include "umeshcore/Editor/ToolUtilities.h"

#include <algorithm>
#include <cmath>
#include <limits>

#include "umeshcore/Editor/MeshOverlayMetrics.h"
#include "umeshcore/Editor/MoveGizmoMetrics.h"
#include "umeshcore/Editor/RotateGizmoMetrics.h"
#include "umeshcore/Editor/SkewGizmoMetrics.h"
#include "umeshcore/Math/Angle.h"
#include "umeshcore/Math/MatrixUtilities.h"

namespace umeshcore::ToolUtilities {

namespace {
inline Vec2 project(CameraState* camera, const Vec2& worldPoint, const Vec2& viewSize) {
    if (camera != nullptr) return camera->worldToScreen(worldPoint, viewSize);
    return worldPoint + viewSize * 0.5f;
}
} // namespace

float snap(float value, float grid) {
    if (!(grid > 0.0f)) return value;
    return std::round(value / grid) * grid;
}

float snapAngle(float radians, float stepDegrees) {
    const float step = stepDegrees * kPi / 180.0f;
    if (!(step > 0.0f)) return radians;
    return std::round(radians / step) * step;
}

float snapScale(float value, float step) {
    if (!(step > 0.0f)) return value;
    return std::round(value / step) * step;
}

Vec2 snapScale(const Vec2& value, float step) { return Vec2(snapScale(value.x, step), snapScale(value.y, step)); }

Vec2 snap(const Vec2& point, float grid) { return Vec2(snap(point.x, grid), snap(point.y, grid)); }

Vec2 constrainAxis(const Vec2& delta) {
    return std::abs(delta.x) > std::abs(delta.y) ? Vec2(delta.x, 0) : Vec2(0, delta.y);
}

float distancePointToSegment(const Vec2& point, const Vec2& a, const Vec2& b) {
    const Vec2 ab = b - a;
    const float t = std::max(0.0f, std::min(1.0f, dot(point - a, ab) / std::max(0.0001f, dot(ab, ab))));
    const Vec2 proj = a + ab * t;
    return length(point - proj);
}

bool pointNearSegment(const Vec2& point, const Vec2& start, const Vec2& end, float radius) {
    const Vec2 segment = end - start;
    const float lengthSquared_ = lengthSquared(segment);
    if (!(lengthSquared_ > 0.0001f)) return length(point - start) <= radius;
    const float t = std::max(0.0f, std::min(1.0f, dot(point - start, segment) / lengthSquared_));
    const Vec2 closest = start + segment * t;
    return length(point - closest) <= radius;
}

bool pointInTriangle(const Vec2& point, const Vec2& a, const Vec2& b, const Vec2& c) {
    const Vec2 v0 = c - a;
    const Vec2 v1 = b - a;
    const Vec2 v2 = point - a;
    const float dot00 = dot(v0, v0);
    const float dot01 = dot(v0, v1);
    const float dot02 = dot(v0, v2);
    const float dot11 = dot(v1, v1);
    const float dot12 = dot(v1, v2);
    const float invDenom = 1.0f / std::max(0.0001f, (dot00 * dot11 - dot01 * dot01));
    const float u = (dot11 * dot02 - dot01 * dot12) * invDenom;
    const float v = (dot00 * dot12 - dot01 * dot02) * invDenom;
    return u >= 0.0f && v >= 0.0f && (u + v) <= 1.0f;
}

bool pointInQuad(const Vec2& point, const std::array<Vec2, 4>& quad) {
    return pointInTriangle(point, quad[0], quad[1], quad[3]) || pointInTriangle(point, quad[0], quad[3], quad[2]);
}

float distanceToQuad(const Vec2& point, const std::array<Vec2, 4>& quad) {
    const float d0 = distancePointToSegment(point, quad[0], quad[1]);
    const float d1 = distancePointToSegment(point, quad[1], quad[3]);
    const float d2 = distancePointToSegment(point, quad[3], quad[2]);
    const float d3 = distancePointToSegment(point, quad[2], quad[0]);
    return std::min({d0, d1, d2, d3});
}

std::array<Vec2, 4> edgeMidpoints(const std::array<Vec2, 4>& corners) {
    return {
        (corners[0] + corners[1]) * 0.5f, (corners[1] + corners[3]) * 0.5f, (corners[2] + corners[3]) * 0.5f,
        (corners[0] + corners[2]) * 0.5f};
}

LocalFrame localFrame(const std::vector<Vec2>& meshVertices, const Vec2& assetSize) {
    if (meshVertices.empty()) return LocalFrame{Vec2::zero(), assetSize};
    Vec2 minPoint = meshVertices[0];
    Vec2 maxPoint = meshVertices[0];
    for (std::size_t i = 1; i < meshVertices.size(); ++i) {
        minPoint = Vec2(std::min(minPoint.x, meshVertices[i].x), std::min(minPoint.y, meshVertices[i].y));
        maxPoint = Vec2(std::max(maxPoint.x, meshVertices[i].x), std::max(maxPoint.y, meshVertices[i].y));
    }
    return LocalFrame{(minPoint + maxPoint) * 0.5f, maxPoint - minPoint};
}

std::array<Vec2, 4> transformedCorners(
    const SceneImage& image, const LocalFrame& frame, std::optional<Vec2> shearOverride) {
    const float halfWidth = frame.size.x * 0.5f;
    const float halfHeight = frame.size.y * 0.5f;
    const Vec2& center = frame.center;
    const std::array<Vec2, 4> local = {
        Vec2(center.x - halfWidth, center.y + halfHeight), Vec2(center.x + halfWidth, center.y + halfHeight),
        Vec2(center.x - halfWidth, center.y - halfHeight), Vec2(center.x + halfWidth, center.y - halfHeight)};
    const float rotationDeg = image.rotation * 180.0f / kPi;
    const Vec2 shear = shearOverride.value_or(image.skew);
    std::array<Vec2, 4> out;
    for (std::size_t i = 0; i < 4; ++i) {
        out[i] = MatrixUtilities::shearedWorldTransform(local[i], image.position, rotationDeg, shear, image.scale);
    }
    return out;
}

std::vector<Vec2> transformedVertices(
    const SceneImage& image, const std::vector<Vec2>& localVertices, std::optional<Vec2> shearOverride) {
    const float rotationDeg = image.rotation * 180.0f / kPi;
    const Vec2 shear = shearOverride.value_or(image.skew);
    std::vector<Vec2> out;
    out.reserve(localVertices.size());
    for (const auto& vertex : localVertices) {
        out.push_back(
            MatrixUtilities::shearedWorldTransform(vertex, image.position, rotationDeg, shear, image.scale));
    }
    return out;
}

Vec2 localCoordinates(const Vec2& worldPoint, const SceneImage& image) {
    return MatrixUtilities::shearedWorldInverse(
        worldPoint, image.position, image.rotation * 180.0f / kPi, image.skew, image.scale);
}

Mesh resolvedMesh(const SceneImage& image, const Vec2& assetSize) {
    if (image.mesh.vertices.empty() || image.mesh.uvs.size() != image.mesh.vertices.size() ||
        image.mesh.indices.empty()) {
        return Mesh::makeQuad(image.name + " Mesh", assetSize);
    }
    return image.mesh.sanitizedForRender(assetSize);
}

std::optional<Mesh> overlayMesh(const SceneImage& image, const Vec2& assetSize) {
    if (image.mesh.vertices.empty() || image.mesh.uvs.size() != image.mesh.vertices.size()) return std::nullopt;
    if (image.mesh.indices.empty()) return image.mesh;
    return image.mesh.sanitizedForRender(assetSize);
}

std::vector<Vec2> editLocalVertices(const SceneImage& image, const Vec2& assetSize, bool showDeformed) {
    return editLocalVertices(image, assetSize, showDeformed, resolvedMesh(image, assetSize));
}

std::vector<Vec2> editLocalVertices(
    const SceneImage& image, const Vec2& assetSize, bool showDeformed, const Mesh& mesh) {
    (void)assetSize;
    if (showDeformed && image.meshAnimationDeform.has_value() &&
        image.meshAnimationDeform->size() == mesh.vertices.size()) {
        return *image.meshAnimationDeform;
    }
    return mesh.vertices;
}

std::vector<Vec2> skinnedLocalVertices(
    const SceneImage& image, const Vec2& assetSize, bool showDeformed, const Skeleton& skeleton, const Mesh& mesh,
    const WorldMatrices* cachedMatrices) {
    const std::vector<Vec2> localVertices = editLocalVertices(image, assetSize, showDeformed, mesh);
    if (!showDeformed) return localVertices;
    const bool hasMatchingVertexCount = mesh.vertices.size() == localVertices.size();
    if (!hasMatchingVertexCount || !mesh.hasSkinningData()) return localVertices;

    const std::vector<Vec2> skinned =
        mesh.skinnedVertices(skeleton, meshPose(image), cachedMatrices, /*presanitized=*/true);
    return skinned.size() == localVertices.size() ? skinned : localVertices;
}

std::unordered_map<int, float> softSelectionWeights(
    const SceneImage& image, const Vec2& assetSize, const std::unordered_set<int>& selectedIndices,
    bool showDeformed, float radius, float feather, bool excludeHull) {
    if (selectedIndices.empty()) return {};
    const Mesh mesh = resolvedMesh(image, assetSize);
    const std::vector<Vec2> localVertices = editLocalVertices(image, assetSize, showDeformed);
    if (localVertices.empty()) return {};

    const float clampedRadius = std::max(radius, 0.0001f);
    const float clampedFeather = std::max(0.0f, std::min(1.0f, feather));
    const float innerRadius = clampedRadius * (1.0f - clampedFeather);
    const float falloffRange = std::max(clampedRadius - innerRadius, 0.0001f);
    std::unordered_set<int> hullSet;
    if (excludeHull) {
        for (std::uint16_t idx : mesh.hullVertexIndices) hullSet.insert(idx);
    }

    std::vector<Vec2> selectedPositions;
    for (int index : selectedIndices) {
        if (static_cast<std::size_t>(index) < localVertices.size()) selectedPositions.push_back(localVertices[index]);
    }
    if (selectedPositions.empty()) return {};

    std::unordered_map<int, float> weights;
    weights.reserve(localVertices.size());

    for (std::size_t index = 0; index < localVertices.size(); ++index) {
        if (selectedIndices.contains(static_cast<int>(index))) {
            weights[static_cast<int>(index)] = 1.0f;
            continue;
        }
        if (hullSet.contains(static_cast<int>(index))) continue;

        float minDistance = std::numeric_limits<float>::max();
        for (const auto& selected : selectedPositions) {
            minDistance = std::min(minDistance, length(localVertices[index] - selected));
        }
        if (!(minDistance <= clampedRadius)) continue;

        if (minDistance <= innerRadius) {
            weights[static_cast<int>(index)] = 1.0f;
        } else {
            const float normalized = 1.0f - ((minDistance - innerRadius) / falloffRange);
            const float eased = normalized * normalized * (3.0f - 2.0f * normalized);
            if (eased > 0.001f) weights[static_cast<int>(index)] = eased;
        }
    }

    return weights;
}

std::optional<MeshProjection> meshProjection(
    const SceneImage& image, const Vec2& assetSize, const Skeleton& skeleton, bool showDeformed,
    bool weightPainting, CameraState* camera, const Vec2& viewSize, float hitScale,
    const WorldMatrices* cachedMatrices) {
    const Mesh mesh = resolvedMesh(image, assetSize);
    // Skinned, to match what the overlay draws.
    const std::vector<Vec2> localVertices =
        skinnedLocalVertices(image, assetSize, showDeformed, skeleton, mesh, cachedMatrices);
    const std::vector<Vec2> worldVertices = transformedVertices(image, localVertices);

    MeshProjection projection;
    projection.imageID = image.id;
    projection.mesh = mesh;
    projection.screenVertices.reserve(worldVertices.size());
    for (const auto& world : worldVertices) projection.screenVertices.push_back(project(camera, world, viewSize));
    projection.grabRadius = MeshOverlayMetrics::grabRadiusPx(weightPainting) * hitScale;
    return projection;
}

std::optional<int> hitTestMeshVertex(const Vec2& screenPoint, const MeshProjection& projection) {
    const float radius = projection.grabRadius;
    std::optional<int> bestIndex;
    float bestDistance = std::numeric_limits<float>::max();
    for (std::size_t index = 0; index < projection.screenVertices.size(); ++index) {
        const float distance = length(screenPoint - projection.screenVertices[index]);
        if (distance <= radius && distance < bestDistance) {
            bestDistance = distance;
            bestIndex = static_cast<int>(index);
        }
    }
    return bestIndex;
}

std::optional<int> hitTestMeshHullEdge(const Vec2& screenPoint, const MeshProjection& projection, float hitScale) {
    const Mesh& mesh = projection.mesh;
    const auto& screenVertices = projection.screenVertices;
    if (mesh.hullVertexIndices.size() <= 1) return std::nullopt;
    const float radius = 10.0f * hitScale;
    std::optional<int> bestEdge;
    float bestDistance = std::numeric_limits<float>::max();
    for (std::size_t edgeIndex = 0; edgeIndex < mesh.hullVertexIndices.size(); ++edgeIndex) {
        const std::size_t startIndex = mesh.hullVertexIndices[edgeIndex];
        const std::size_t endIndex = mesh.hullVertexIndices[(edgeIndex + 1) % mesh.hullVertexIndices.size()];
        if (startIndex >= screenVertices.size() || endIndex >= screenVertices.size()) continue;
        const float distance = distancePointToSegment(screenPoint, screenVertices[startIndex], screenVertices[endIndex]);
        if (distance <= radius && distance < bestDistance) {
            bestDistance = distance;
            bestEdge = static_cast<int>(edgeIndex);
        }
    }
    return bestEdge;
}

std::optional<int> hitTestMeshInternalEdge(
    const Vec2& screenPoint, const MeshProjection& projection, float hitScale) {
    const Mesh& mesh = projection.mesh;
    const auto& screenVertices = projection.screenVertices;
    const float radius = 10.0f * hitScale;
    std::optional<int> bestEdge;
    float bestDistance = std::numeric_limits<float>::max();
    for (std::size_t edgeIndex = 0; edgeIndex < mesh.internalEdges.size(); ++edgeIndex) {
        const std::size_t startIndex = mesh.internalEdges[edgeIndex].a;
        const std::size_t endIndex = mesh.internalEdges[edgeIndex].b;
        if (startIndex >= screenVertices.size() || endIndex >= screenVertices.size()) continue;
        const float distance = distancePointToSegment(screenPoint, screenVertices[startIndex], screenVertices[endIndex]);
        if (distance <= radius && distance < bestDistance) {
            bestDistance = distance;
            bestEdge = static_cast<int>(edgeIndex);
        }
    }
    return bestEdge;
}

std::unordered_set<int> hitTestMeshVertices(const ScreenRect& rect, const MeshProjection& projection) {
    std::unordered_set<int> hits;
    for (std::size_t index = 0; index < projection.screenVertices.size(); ++index) {
        if (rect.contains(projection.screenVertices[index])) hits.insert(static_cast<int>(index));
    }
    return hits;
}

std::optional<std::pair<Uuid, float>> hitTestBoneDetailed(
    const Vec2& screenPoint, const Vec2& viewSize, const Skeleton& skeleton, std::optional<Uuid> selectedBoneID,
    CameraState* camera, bool touchOptimized, float displayScale) {
    const auto segments = skeleton.worldLineSegments();
    if (segments.empty()) return std::nullopt;

    if (touchOptimized) {
        // Touch-optimised bone picking: finger-sized capture areas plus a
        // probability score, so a single tap lands on the bone the user
        // most plausibly meant -- see the Swift source's long comment on
        // the four scoring rules (joints beat shafts, small bones beat
        // large ones, later-drawn bones win ties, the current selection is
        // slightly de-prioritised).
        const float scale = displayScale;
        const float jointRadius = 26.0f * scale;
        const float lineRadius = 16.0f * scale;

        struct Candidate {
            Uuid id;
            float score;
            float distance;
        };
        std::vector<Candidate> candidates;
        candidates.reserve(4);

        for (std::size_t index = 0; index < segments.size(); ++index) {
            const auto& entry = segments[index];
            const Vec2 startScreen = project(camera, entry.start, viewSize);
            const Vec2 endScreen = project(camera, entry.end, viewSize);

            const float jointDistance = std::min(length(screenPoint - startScreen), length(screenPoint - endScreen));
            const float lineDistance = distancePointToSegment(screenPoint, startScreen, endScreen);

            const bool isJointHit = jointDistance <= jointRadius;
            const bool isLineHit = lineDistance <= lineRadius;
            if (!isJointHit && !isLineHit) continue;

            float score;
            if (isJointHit) {
                score = jointDistance / jointRadius;
                score -= 0.35f;
            } else {
                score = lineDistance / lineRadius;
            }

            const float screenLength = length(startScreen - endScreen);
            if (screenLength < 44.0f * scale) score -= 0.18f;

            score -= static_cast<float>(index) / static_cast<float>(std::max<std::size_t>(segments.size(), 1)) * 0.05f;

            if (selectedBoneID.has_value() && entry.bone.id == *selectedBoneID) score += 0.22f;

            candidates.push_back(Candidate{entry.bone.id, score, std::min(jointDistance, lineDistance)});
        }

        if (candidates.empty()) return std::nullopt;
        const Candidate* best = &candidates[0];
        for (const auto& c : candidates) {
            if (c.score < best->score) best = &c;
        }
        return std::make_pair(best->id, best->distance);
    }

    // Mouse: nearest joint within radius wins outright; else nearest shaft.
    const float jointRadius = 12.0f;
    const float lineRadius = 9.0f;
    std::optional<Uuid> bestID;
    float bestDistance = std::numeric_limits<float>::max();

    for (const auto& entry : segments) {
        const Vec2 startScreen = project(camera, entry.start, viewSize);
        const Vec2 endScreen = project(camera, entry.end, viewSize);
        const float jointDistance = std::min(length(screenPoint - startScreen), length(screenPoint - endScreen));
        if (jointDistance <= jointRadius && jointDistance < bestDistance) {
            bestDistance = jointDistance;
            bestID = entry.bone.id;
            continue;
        }
        const float lineDistance = distancePointToSegment(screenPoint, startScreen, endScreen);
        if (lineDistance <= lineRadius && lineDistance < bestDistance) {
            bestDistance = lineDistance;
            bestID = entry.bone.id;
        }
    }

    if (!bestID.has_value()) return std::nullopt;
    return std::make_pair(*bestID, bestDistance);
}

bool segmentIntersectsRect(const Vec2& a, const Vec2& b, const ScreenRect& rect) {
    if (rect.contains(a) || rect.contains(b)) return true;

    const Vec2 d = b - a;
    float t0 = 0.0f, t1 = 1.0f;
    const std::array<std::pair<float, float>, 4> clips = {
        std::pair{-d.x, a.x - rect.min.x}, std::pair{d.x, rect.max.x - a.x}, std::pair{-d.y, a.y - rect.min.y},
        std::pair{d.y, rect.max.y - a.y}};
    for (const auto& [p, q] : clips) {
        if (p == 0.0f) {
            if (q < 0.0f) return false; // parallel to this edge, and outside it
            continue;
        }
        const float r = q / p;
        if (p < 0.0f) {
            if (r > t1) return false;
            t0 = std::max(t0, r);
        } else {
            if (r < t0) return false;
            t1 = std::min(t1, r);
        }
    }
    return t0 <= t1;
}

std::vector<Uuid> bonesIntersecting(
    const ScreenRect& rect, const Vec2& viewSize, const Skeleton& skeleton, CameraState* camera) {
    std::vector<Uuid> hits;
    for (const auto& entry : skeleton.worldLineSegments()) {
        const Vec2 startScreen = project(camera, entry.start, viewSize);
        const Vec2 endScreen = project(camera, entry.end, viewSize);
        if (segmentIntersectsRect(startScreen, endScreen, rect)) hits.push_back(entry.bone.id);
    }
    return hits;
}

bool meshModeMayChangeSelection(Uuid hitID, std::optional<Uuid> selectedID, int clickCount) {
    if (!selectedID.has_value()) return true;
    return clickCount >= 2 || hitID == *selectedID;
}

bool weightPaintMayChangeBone(
    Uuid hitID, std::optional<Uuid> armedBoneID, const std::unordered_set<Uuid, UuidHash>& boundBoneIDs,
    int clickCount) {
    if (!boundBoneIDs.contains(hitID)) return false;
    if (!armedBoneID.has_value()) return true;
    return clickCount >= 2 || hitID == *armedBoneID;
}

GizmoHandle defaultHandle(ActiveTool tool) {
    switch (tool) {
        case ActiveTool::Move:
        case ActiveTool::Select:
        case ActiveTool::Bone:
        case ActiveTool::Mesh:
        case ActiveTool::PhysicsPreview:
            return GizmoHandleFactory::moveCenter();
        case ActiveTool::Rotate:
            return GizmoHandleFactory::rotateRing();
        case ActiveTool::Scale:
            return GizmoHandleFactory::scaleCorner(0);
        case ActiveTool::Skew:
            return GizmoHandleFactory::skewEdge(0);
    }
    return GizmoHandleFactory::moveCenter();
}

Vec2 project3DToScreen(
    const Vec2& point, const Vec2& center, float rotationZ, const Vec3& rotation3D, const Vec2& viewSize,
    CameraState* camera) {
    (void)rotationZ;
    const Vec2 screenPoint = project(camera, point, viewSize);
    const Vec2 centerScreen = project(camera, center, viewSize);

    const float pitch = rotation3D.x;
    const float yaw = rotation3D.y;
    const Mat4 rotation3DMatrix = MatrixUtilities::rotationY(yaw) * MatrixUtilities::rotationX(pitch);
    const Mat4 perspective = MatrixUtilities::perspective(-1.0f / 500.0f);
    const Mat4 matrix = perspective * rotation3DMatrix;

    const Vec3 local(screenPoint.x - centerScreen.x, screenPoint.y - centerScreen.y, 0);
    const Vec3 projected = MatrixUtilities::transformPoint(local, matrix);
    return Vec2(centerScreen.x + projected.x, centerScreen.y + projected.y);
}

std::optional<GizmoHandle> hitTestGizmo(
    ActiveTool tool, const Vec2& screenPoint, const Vec2& viewSize, const SceneImage* selectedImage,
    const Vec2& selectedImageAssetSize, std::optional<Skeleton::LineSegment> selectedBoneSegment,
    std::optional<Uuid> selectedBoneID, const Skeleton* skeleton, bool showMeshDeformed, bool weightPainting,
    CameraState* camera, float hitScale, bool touchOptimized, float displayScale) {
    std::optional<Vec2> center;
    if (selectedImage != nullptr) {
        center = selectedImage->position;
    } else if (selectedBoneSegment.has_value()) {
        center = selectedBoneSegment->start;
    }
    if (!center.has_value()) return std::nullopt;

    const float zoom = camera != nullptr ? camera->zoom : 1.0f;
    const Vec2 centerScreen = project(camera, *center, viewSize);

    switch (tool) {
        case ActiveTool::Move:
        case ActiveTool::Select: {
            const float axisLength =
                MoveGizmoMetrics::kAxisLengthPx * std::sqrt(std::max(zoom, 0.001f)) / std::max(zoom, 0.001f);
            const Vec2 xHandle = *center + Vec2(axisLength, 0);
            const Vec2 yHandle = *center + Vec2(0, axisLength);
            const Vec2 xScreen = project(camera, xHandle, viewSize);
            const Vec2 yScreen = project(camera, yHandle, viewSize);

            const float drawnAxisPx = std::max(length(xScreen - centerScreen), 0.0001f);
            const float pxPerMetric = drawnAxisPx / MoveGizmoMetrics::kAxisLengthPx;
            const float centreGrab = MoveGizmoMetrics::centerGrabPx(hitScale) * pxPerMetric;
            const float inner = MoveGizmoMetrics::axisGrabInnerPx(hitScale) * pxPerMetric;
            const float outer = MoveGizmoMetrics::axisGrabOuterPx(hitScale) * pxPerMetric;
            const float across = MoveGizmoMetrics::axisGrabAcrossPx(hitScale) * pxPerMetric;

            auto acrossAxis = [&](const Vec2& tip) -> std::optional<float> {
                const Vec2 axis = tip - centerScreen;
                const float len = length(axis);
                if (!(len > 0.0001f)) return std::nullopt;
                const Vec2 unit = axis / len;
                const Vec2 toPoint = screenPoint - centerScreen;
                const float along = dot(toPoint, unit);
                if (!(along >= inner) || !(along <= outer)) return std::nullopt;
                const float sideways = std::abs(toPoint.x * -unit.y + toPoint.y * unit.x);
                return sideways <= across ? std::optional<float>(sideways) : std::nullopt;
            };

            std::optional<GizmoHandle> bestHandle;
            std::optional<float> bestDistance;
            const float centreDistance = length(screenPoint - centerScreen);
            if (centreDistance <= centreGrab) {
                bestHandle = GizmoHandleFactory::moveCenter();
                bestDistance = centreDistance;
            }
            if (auto sideways = acrossAxis(xScreen); sideways.has_value() && (!bestDistance.has_value() || *sideways < *bestDistance)) {
                bestHandle = GizmoHandleFactory::moveX();
                bestDistance = sideways;
            }
            if (auto sideways = acrossAxis(yScreen); sideways.has_value() && (!bestDistance.has_value() || *sideways < *bestDistance)) {
                bestHandle = GizmoHandleFactory::moveY();
                bestDistance = sideways;
            }
            return bestHandle;
        }
        case ActiveTool::Bone: {
            if (skeleton == nullptr) return std::nullopt;
            auto boneID = hitTestBone(
                screenPoint, viewSize, *skeleton, selectedBoneID, camera, touchOptimized, displayScale);
            if (!boneID.has_value()) return std::nullopt;
            return GizmoHandleFactory::bone(*boneID);
        }
        case ActiveTool::Rotate: {
            const float distance = length(screenPoint - centerScreen);
            if (RotateGizmoMetrics::grabsTrack(distance, hitScale)) return GizmoHandleFactory::rotateRing();

            std::optional<float> rotation;
            if (selectedImage != nullptr) {
                rotation = selectedImage->rotation;
            } else if (selectedBoneSegment.has_value()) {
                const Vec2 d = selectedBoneSegment->end - selectedBoneSegment->start;
                rotation = std::atan2(d.y, d.x);
            }
            if (rotation.has_value() && distance > 0.001f) {
                const Vec2 tipWorld =
                    *center + Vec2(std::cos(*rotation), std::sin(*rotation)) *
                                  (RotateGizmoMetrics::kNeedleOuterPx / std::max(zoom, 0.0001f));
                const Vec2 tipScreen = project(camera, tipWorld, viewSize);
                const Vec2 needleDirection = tipScreen - centerScreen;
                if (length(needleDirection) > 0.001f) {
                    const Vec2 toPoint = screenPoint - centerScreen;
                    float delta = std::atan2(
                        needleDirection.x * toPoint.y - needleDirection.y * toPoint.x, dot(needleDirection, toPoint));
                    while (delta > kPi) delta -= 2.0f * kPi;
                    while (delta < -kPi) delta += 2.0f * kPi;
                    if (RotateGizmoMetrics::grabsNeedle(distance, delta, hitScale)) {
                        return GizmoHandleFactory::rotateRing();
                    }
                }
            }
            return std::nullopt;
        }
        case ActiveTool::Scale: {
            if (selectedImage == nullptr && selectedBoneSegment.has_value()) {
                const float axisLength = 94.0f / std::max(zoom, 0.001f);
                const Vec2 xHandle = *center + Vec2(axisLength, 0);
                const Vec2 xScreen = project(camera, xHandle, viewSize);
                if (pointNearSegment(screenPoint, centerScreen, xScreen, 13.0f * hitScale)) {
                    return GizmoHandleFactory::scaleCorner(0);
                }
                if (length(screenPoint - xScreen) < 16.0f * hitScale) return GizmoHandleFactory::scaleCorner(2);
                return std::nullopt;
            }
            const float axisLength = 80.0f / std::max(zoom, 0.001f);
            const Vec2 xHandle = *center + Vec2(axisLength, 0);
            const Vec2 yHandle = *center + Vec2(0, axisLength);
            const Vec2 uHandle = *center + Vec2(axisLength * 0.78f, axisLength * 0.78f);
            const Vec2 xScreen = project(camera, xHandle, viewSize);
            const Vec2 yScreen = project(camera, yHandle, viewSize);
            const Vec2 uScreen = project(camera, uHandle, viewSize);
            if (pointNearSegment(screenPoint, centerScreen, xScreen, 13.0f * hitScale)) return GizmoHandleFactory::scaleCorner(0);
            if (pointNearSegment(screenPoint, centerScreen, yScreen, 13.0f * hitScale)) return GizmoHandleFactory::scaleCorner(1);
            if (length(screenPoint - uScreen) < 16.0f * hitScale) return GizmoHandleFactory::scaleCorner(2);
            return std::nullopt;
        }
        case ActiveTool::Skew: {
            if (selectedImage == nullptr) return std::nullopt;
            const float distance = length(screenPoint - centerScreen);
            if (!SkewGizmoMetrics::grabsTrack(distance, hitScale)) return std::nullopt;

            const float limit = SkewGizmoMetrics::kMaxSweepDegrees * kPi / 180.0f;
            std::optional<GizmoHandle> bestHandle;
            std::optional<float> bestDistance;
            const std::array<float, 2> axes = {0.0f, kPi / 2.0f};
            for (std::size_t index = 0; index < axes.size(); ++index) {
                const float degrees = index == 0 ? selectedImage->skew.x : selectedImage->skew.y;
                const float angle = std::max(-limit, std::min(limit, degrees * kPi / 180.0f));
                const Vec2 world = *center + Vec2(std::cos(axes[index] + angle), std::sin(axes[index] + angle)) *
                                                  (SkewGizmoMetrics::kTrackRadiusPx / std::max(zoom, 0.0001f));
                const Vec2 screen = project(camera, world, viewSize);
                const float reach = length(screenPoint - screen);
                if (!bestDistance.has_value() || reach < *bestDistance) {
                    bestHandle = GizmoHandleFactory::skewEdge(static_cast<int>(index));
                    bestDistance = reach;
                }
            }
            return bestHandle;
        }
        case ActiveTool::Mesh: {
            if (selectedImage == nullptr || skeleton == nullptr) return std::nullopt;
            auto projection = meshProjection(
                *selectedImage, selectedImageAssetSize, *skeleton, showMeshDeformed, weightPainting, camera,
                viewSize, hitScale);
            if (!projection.has_value()) return std::nullopt;
            if (auto vertex = hitTestMeshVertex(screenPoint, *projection)) {
                return GizmoHandleFactory::meshVertex(*vertex);
            }
            if (auto edge = hitTestMeshInternalEdge(screenPoint, *projection, hitScale)) {
                return GizmoHandleFactory::meshInternalEdge(*edge);
            }
            return std::nullopt;
        }
        case ActiveTool::PhysicsPreview:
            return std::nullopt;
    }
    return std::nullopt;
}

} // namespace umeshcore::ToolUtilities
