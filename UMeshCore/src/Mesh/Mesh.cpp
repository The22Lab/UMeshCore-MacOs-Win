#include "umeshcore/Mesh/Mesh.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>

#include "umeshcore/Mesh/MeshKernel.h"
#include "umeshcore/Model/Bone.h"
#include "umeshcore/Model/Skeleton.h"

namespace umeshcore {

Mesh::BoneSegment Mesh::makeBoneSegment(const Bone& bone, const Mat4& world) {
    const Vec3 s = MatrixUtilities::transformPoint(Vec3::zero(), world);
    const Vec3 e = MatrixUtilities::transformPoint(Vec3(bone.length, 0, 0), world);
    return BoneSegment{bone.id, Vec2(s.x, s.y), Vec2(e.x, e.y)};
}

Mesh Mesh::sanitizedForRender(const Vec2& size) const {
    if (vertices.empty()) return resetToQuad(size);

    Mesh next = *this;

    if (next.uvs.size() != next.vertices.size()) {
        next.uvs.clear();
        next.uvs.reserve(next.vertices.size());
        for (const auto& v : next.vertices) next.uvs.push_back(uvFor(v, size));
    }

    std::vector<int> filteredHull;
    for (std::uint16_t idx : next.hullVertexIndices) {
        if (static_cast<std::size_t>(idx) < next.vertices.size()) filteredHull.push_back(idx);
    }
    const std::vector<int> dedupedHull = deduplicatedRing(filteredHull);
    if (dedupedHull.size() >= 3) {
        next.hullVertexIndices.clear();
        for (int v : dedupedHull) next.hullVertexIndices.push_back(static_cast<std::uint16_t>(v));
    } else {
        const std::vector<int> convexHull = next.convexHullVertexIndices();
        if (convexHull.size() >= 3) {
            next.hullVertexIndices.clear();
            for (int v : convexHull) next.hullVertexIndices.push_back(static_cast<std::uint16_t>(v));
        } else {
            return resetToQuad(size);
        }
    }

    next.indices = next.sanitizedTriangleIndices(next.indices);
    if (next.indices.empty()) {
        next.indices = next.sanitizedTriangleIndices(next.triangulatedHullIndices());
    }

    // Deliberately no validation here: this runs once per sprite per frame
    // from the renderer. Repair belongs where a bad triangle list can first
    // enter the app -- see repairedIfInvalid(), called on load.
    next = next.sanitizedSkinningData();
    return next;
}

std::pair<Mesh, bool> Mesh::repairedIfInvalid() const {
    if (vertices.size() < 3 || hullVertexIndices.size() < 3) return {*this, false};
    if (validationReport().isValid()) return {*this, false};

    std::vector<std::uint16_t> rebuilt;
    try {
        rebuilt = kernelTriangulatedIndices();
    } catch (const MeshKernel::TriangulationError&) {
        return {*this, false};
    }

    Mesh candidate = *this;
    candidate.indices = rebuilt;
    if (!candidate.validationReport().isValid()) return {*this, false};
    return {candidate, true};
}

Mesh Mesh::sanitizedSkinningData(int maxInfluences) const {
    Mesh next = *this;

    if (next.bindVertices.size() != next.vertices.size()) next.bindVertices = next.vertices;
    if (next.vertexBoneWeights.size() != next.vertices.size()) {
        next.vertexBoneWeights.assign(next.vertices.size(), {});
    }

    for (auto& influencesRef : next.vertexBoneWeights) {
        std::vector<VertexBoneWeight> influences;
        for (const auto& vw : influencesRef) {
            if (std::isfinite(vw.weight) && vw.weight > 0.0f && next.boneInverseBindMatrices.contains(vw.boneID)) {
                influences.push_back(vw);
            }
        }
        if (influences.empty()) {
            influencesRef.clear();
            continue;
        }

        // Merge duplicate bone entries.
        std::unordered_map<Uuid, float, UuidHash> merged;
        for (const auto& inf : influences) merged[inf.boneID] += inf.weight;
        influences.clear();
        for (const auto& [boneID, w] : merged) influences.push_back(VertexBoneWeight{boneID, w});
        std::stable_sort(influences.begin(), influences.end(), [](const auto& a, const auto& b) {
            return a.weight > b.weight;
        });
        if (static_cast<int>(influences.size()) > maxInfluences) influences.resize(static_cast<std::size_t>(maxInfluences));

        float total = 0.0f;
        for (const auto& inf : influences) total += std::max(0.0f, inf.weight);
        if (total > 0.000001f) {
            for (auto& inf : influences) inf.weight = std::max(0.0f, inf.weight) / total;
            influencesRef = influences;
        } else {
            influencesRef.clear();
        }
    }

    return next;
}

std::vector<Vec2> Mesh::bindPointsInWorldSpace(std::optional<MeshBindPose> fallbackPose) const {
    const std::vector<Vec2>& source = (bindVertices.size() == vertices.size()) ? bindVertices : vertices;
    const std::optional<MeshBindPose> pose = bindImagePose.has_value() ? bindImagePose : fallbackPose;
    if (!pose.has_value()) return source;
    std::vector<Vec2> out;
    out.reserve(source.size());
    for (const auto& v : source) out.push_back(pose->worldPoint(v));
    return out;
}

std::vector<std::vector<VertexBoneWeight>> Mesh::distributedWeights(
    const std::vector<Vec2>& points, const std::vector<BoneSegment>& segments, int maxInfluences,
    float distancePower, float blendZoneFactor, float minWeightThreshold) {
    constexpr float epsilon = 0.0001f;
    std::vector<std::vector<VertexBoneWeight>> result;
    result.reserve(points.size());

    for (const auto& point : points) {
        if (segments.empty()) {
            result.push_back({});
            continue;
        }
        std::vector<std::pair<Uuid, float>> dists;
        dists.reserve(segments.size());
        for (const auto& seg : segments) {
            dists.emplace_back(seg.id, std::max(pointDistanceToSegment(point, seg.start, seg.end), epsilon));
        }
        float dMin = dists[0].second;
        for (const auto& d : dists) dMin = std::min(dMin, d.second);

        const float blendCeiling = dMin * (1.0f + blendZoneFactor);
        std::vector<VertexBoneWeight> scored;
        for (const auto& [id, d] : dists) {
            if (!(d <= blendCeiling)) continue;
            // Linear fade: 1.0 at dMin, 0.0 at blendCeiling.
            const float fade = (blendCeiling - d) / (blendCeiling - dMin + epsilon);
            const float raw = (1.0f / std::pow(d, distancePower)) * fade;
            if (raw > minWeightThreshold) scored.push_back(VertexBoneWeight{id, raw});
        }

        if (scored.empty()) {
            Uuid nearestId = dists[0].first;
            float nearestD = dists[0].second;
            for (const auto& [id, d] : dists) {
                if (d < nearestD) {
                    nearestD = d;
                    nearestId = id;
                }
            }
            result.push_back({VertexBoneWeight{nearestId, 1.0f}});
            continue;
        }

        std::stable_sort(scored.begin(), scored.end(), [](const auto& a, const auto& b) {
            return a.weight > b.weight;
        });
        if (static_cast<int>(scored.size()) > maxInfluences) scored.resize(static_cast<std::size_t>(maxInfluences));
        result.push_back(scored);
    }
    return result;
}

Mesh Mesh::autoWeights(
    const Skeleton& skeleton, const std::unordered_set<Uuid, UuidHash>& boneIDs, int maxInfluences,
    float distancePower, float blendZoneFactor, float minWeightThreshold,
    std::optional<MeshBindPose> imagePose) const {
    Mesh next = *this;
    if (vertices.empty() || boneIDs.empty()) return next;

    // orderedBones(), not the matrix map: iteration order must be stable
    // across runs so a tie between two equidistant bones resolves the same
    // way every time.
    std::vector<BoneSegment> segments;
    for (const auto& bone : skeleton.orderedBones()) {
        if (!boneIDs.contains(bone.id)) continue;
        auto it = boneInverseBindMatrices.find(bone.id);
        if (it == boneInverseBindMatrices.end()) continue;
        segments.push_back(makeBoneSegment(bone, inverse(it->second)));
    }
    if (segments.empty()) return next;

    if (next.bindVertices.size() != next.vertices.size()) next.bindVertices = next.vertices;

    next.vertexBoneWeights = distributedWeights(
        next.bindPointsInWorldSpace(imagePose), segments, maxInfluences, distancePower, blendZoneFactor,
        minWeightThreshold);

    return next.sanitizedSkinningData(maxInfluences);
}

Mesh Mesh::autoBindWeights(
    const Skeleton& skeleton, int maxInfluences, float distancePower, float blendZoneFactor,
    float minWeightThreshold, std::optional<MeshBindPose> imagePose) const {
    Mesh next = *this;
    if (vertices.empty()) return next;

    const WorldMatrices worldMatrices = skeleton.worldMatrices();
    std::vector<BoneSegment> segments;
    for (const auto& bone : skeleton.orderedBones()) {
        auto it = worldMatrices.find(bone.id);
        if (it == worldMatrices.end()) continue;
        segments.push_back(makeBoneSegment(bone, it->second));
    }
    if (segments.empty()) return next;

    next.bindVertices = vertices;
    next.bindImagePose = imagePose.has_value() ? imagePose : next.bindImagePose;
    next.boneInverseBindMatrices.clear();
    for (const auto& seg : segments) {
        auto it = worldMatrices.find(seg.id);
        if (it == worldMatrices.end()) continue;
        next.boneInverseBindMatrices[seg.id] = inverse(it->second);
    }

    next.vertexBoneWeights = distributedWeights(
        next.bindPointsInWorldSpace(imagePose), segments, maxInfluences, distancePower, blendZoneFactor,
        minWeightThreshold);

    return next.sanitizedSkinningData(maxInfluences);
}

std::vector<Vec2> Mesh::skinnedVertices(
    const Skeleton& skeleton, std::optional<MeshBindPose> currentPose,
    const std::unordered_map<Uuid, Mat4, UuidHash>* cachedMatrices, bool presanitized) const {
    const Mesh prepared = presanitized ? *this : sanitizedSkinningData();
    if (prepared.bindVertices.size() != prepared.vertices.size() ||
        prepared.vertexBoneWeights.size() != prepared.vertices.size() ||
        prepared.boneInverseBindMatrices.empty()) {
        return prepared.vertices;
    }

    WorldMatrices localMatrices;
    const WorldMatrices* worldMatricesPtr = cachedMatrices;
    if (worldMatricesPtr == nullptr) {
        localMatrices = skeleton.worldMatrices();
        worldMatricesPtr = &localMatrices;
    }
    const WorldMatrices& worldMatrices = *worldMatricesPtr;

    // Legacy meshes have no stored bind pose; treating the current pose as
    // the bind pose keeps them stable (identity when bones haven't moved).
    const std::optional<MeshBindPose> bindPose =
        prepared.bindImagePose.has_value() ? prepared.bindImagePose : currentPose;
    std::vector<Vec2> deformed = prepared.vertices;

    for (std::size_t index = 0; index < prepared.bindVertices.size(); ++index) {
        const Vec2 bindLocal = prepared.bindVertices[index];
        const auto& influences = prepared.vertexBoneWeights[index];
        if (influences.empty()) {
            deformed[index] = bindLocal;
            continue;
        }

        // Bind position in the space the inverse-bind matrices expect: with
        // a current pose available that is true world space; without one,
        // the legacy local-space fallback.
        Vec2 bindPoint;
        if (bindPose.has_value() && currentPose.has_value()) {
            bindPoint = bindPose->worldPoint(bindLocal);
        } else {
            bindPoint = bindLocal;
        }

        Vec2 accumulated = Vec2::zero();
        float totalWeight = 0.0f;
        const Vec3 bind3(bindPoint.x, bindPoint.y, 0);

        for (const auto& influence : influences) {
            if (!(influence.weight > 0.0f)) continue;
            auto currentIt = worldMatrices.find(influence.boneID);
            auto invBindIt = prepared.boneInverseBindMatrices.find(influence.boneID);
            if (currentIt == worldMatrices.end() || invBindIt == prepared.boneInverseBindMatrices.end()) continue;
            const Mat4 skinMatrix = currentIt->second * invBindIt->second;
            const Vec3 transformed = MatrixUtilities::transformPoint(bind3, skinMatrix);
            accumulated = accumulated + Vec2(transformed.x, transformed.y) * influence.weight;
            totalWeight += influence.weight;
        }

        if (totalWeight > 0.000001f) {
            const Vec2 blended = accumulated / totalWeight;
            if (currentPose.has_value() && bindPose.has_value()) {
                // Back through the BIND pose, not the current one: the
                // renderer applies the current pose on top of this result,
                // so mapping back through it here would cancel it exactly
                // (a documented historical bug -- see Mesh.h).
                deformed[index] = bindPose->localPoint(blended);
            } else {
                deformed[index] = blended;
            }
        } else {
            deformed[index] = bindLocal;
        }
    }

    return deformed;
}

bool Mesh::pointInsideHullForKernel(const Vec2& point) const {
    const std::vector<int> hull(hullVertexIndices.begin(), hullVertexIndices.end());
    return MeshKernel::pointInRing(vertices, hull, point);
}

std::vector<std::uint16_t> Mesh::kernelTriangulatedIndices() const {
    const std::vector<int> hull(hullVertexIndices.begin(), hullVertexIndices.end());
    const std::vector<int> interior = interiorVertexIndices();
    std::vector<std::pair<int, int>> constraints;
    constraints.reserve(internalEdges.size());
    for (const auto& e : internalEdges) constraints.emplace_back(e.a, e.b);
    const MeshKernel::Boundary boundary{hull, {}};
    return MeshKernel::triangulate(vertices, boundary, interior, constraints);
}

Mesh Mesh::retriangulated() const {
    Mesh next = *this;
    next.indices = next.kernelTriangulatedIndices();
    return next;
}

MeshValidator::Report Mesh::validationReport() const {
    const std::vector<int> hull(hullVertexIndices.begin(), hullVertexIndices.end());
    return MeshValidator::validate(vertices, indices, hull, {});
}

std::vector<std::uint16_t> Mesh::sanitizedTriangleIndices(const std::vector<std::uint16_t>& triangles) const {
    if (triangles.size() < 3) return {};
    std::vector<std::uint16_t> result;
    result.reserve(triangles.size());
    std::unordered_set<std::uint64_t> seen;

    for (std::size_t i = 0; i + 2 < triangles.size(); i += 3) {
        const int ia = triangles[i], ib = triangles[i + 1], ic = triangles[i + 2];
        if (static_cast<std::size_t>(ia) >= vertices.size() || static_cast<std::size_t>(ib) >= vertices.size() ||
            static_cast<std::size_t>(ic) >= vertices.size()) {
            continue;
        }
        if (ia == ib || ib == ic || ia == ic) continue;

        const Vec2& a = vertices[ia];
        const Vec2& b = vertices[ib];
        const Vec2& c = vertices[ic];
        if (!(std::abs(signedArea(a, b, c)) > 0.0001f)) continue;

        std::array<std::uint16_t, 3> key = {
            static_cast<std::uint16_t>(ia), static_cast<std::uint16_t>(ib), static_cast<std::uint16_t>(ic)};
        std::sort(key.begin(), key.end());
        const std::uint64_t packed =
            (static_cast<std::uint64_t>(key[0]) << 32) | (static_cast<std::uint64_t>(key[1]) << 16) |
            static_cast<std::uint64_t>(key[2]);
        if (seen.contains(packed)) continue;
        seen.insert(packed);

        result.push_back(static_cast<std::uint16_t>(ia));
        result.push_back(static_cast<std::uint16_t>(ib));
        result.push_back(static_cast<std::uint16_t>(ic));
    }

    return result;
}

std::vector<int> Mesh::convexHullVertexIndices() const {
    if (vertices.size() < 3) return {};
    std::vector<std::pair<int, Vec2>> points;
    points.reserve(vertices.size());
    for (std::size_t i = 0; i < vertices.size(); ++i) points.emplace_back(static_cast<int>(i), vertices[i]);
    std::stable_sort(points.begin(), points.end(), [](const auto& lhs, const auto& rhs) {
        if (lhs.second.x == rhs.second.x) return lhs.second.y < rhs.second.y;
        return lhs.second.x < rhs.second.x;
    });

    auto cross = [](const Vec2& o, const Vec2& a, const Vec2& b) {
        return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
    };

    std::vector<std::pair<int, Vec2>> lower;
    for (const auto& pt : points) {
        while (lower.size() >= 2 &&
               cross(lower[lower.size() - 2].second, lower[lower.size() - 1].second, pt.second) <= 0.0f) {
            lower.pop_back();
        }
        lower.push_back(pt);
    }
    std::vector<std::pair<int, Vec2>> upper;
    for (auto it = points.rbegin(); it != points.rend(); ++it) {
        while (upper.size() >= 2 &&
               cross(upper[upper.size() - 2].second, upper[upper.size() - 1].second, it->second) <= 0.0f) {
            upper.pop_back();
        }
        upper.push_back(*it);
    }

    std::vector<std::pair<int, Vec2>> hull;
    if (!lower.empty()) hull.insert(hull.end(), lower.begin(), lower.end() - 1);
    if (!upper.empty()) hull.insert(hull.end(), upper.begin(), upper.end() - 1);
    if (hull.size() < 3) {
        hull.assign(points.begin(), points.begin() + static_cast<std::ptrdiff_t>(std::min<std::size_t>(3, points.size())));
    }
    std::vector<int> out;
    out.reserve(hull.size());
    for (const auto& h : hull) out.push_back(h.first);
    return out;
}

std::vector<int> Mesh::deduplicatedRing(const std::vector<int>& idx) {
    std::vector<int> result;
    if (idx.empty()) return result;
    std::unordered_set<int> seen;
    result.reserve(idx.size());
    for (int v : idx) {
        if (seen.insert(v).second) result.push_back(v);
    }
    return result;
}

std::vector<int> Mesh::cleanedPolygonIndices(const std::vector<int>& polygon) const {
    if (polygon.size() < 3) return polygon;
    std::vector<int> unique;
    unique.reserve(polygon.size());
    for (int idx : polygon) {
        if (static_cast<std::size_t>(idx) >= vertices.size()) continue;
        if (!unique.empty() && length(vertices[unique.back()] - vertices[idx]) < 0.35f) continue;
        unique.push_back(idx);
    }
    if (unique.size() > 2 && length(vertices[unique.front()] - vertices[unique.back()]) < 0.35f) {
        unique.pop_back();
    }
    if (unique.size() <= 3) return unique;

    std::vector<int> filtered;
    filtered.reserve(unique.size());
    for (std::size_t i = 0; i < unique.size(); ++i) {
        const int prev = unique[(i + unique.size() - 1) % unique.size()];
        const int curr = unique[i];
        const int next = unique[(i + 1) % unique.size()];
        const float area = std::abs(signedArea(vertices[prev], vertices[curr], vertices[next]));
        if (area > 0.00001f) filtered.push_back(curr);
    }
    return filtered.size() >= 3 ? filtered : unique;
}

float Mesh::polygonSignedArea(const std::vector<int>& idx) const {
    if (idx.size() < 3) return 0.0f;
    float area = 0.0f;
    std::size_t j = idx.size() - 1;
    for (std::size_t i = 0; i < idx.size(); ++i) {
        const Vec2& pj = vertices[idx[j]];
        const Vec2& pi = vertices[idx[i]];
        area += (pj.x * pi.y) - (pi.x * pj.y);
        j = i;
    }
    return area * 0.5f;
}

bool Mesh::pointInTriangleWithEpsilon(const Vec2& point, const Vec2& a, const Vec2& b, const Vec2& c, float epsilon) {
    const float ab = signedArea(a, b, point);
    const float bc = signedArea(b, c, point);
    const float ca = signedArea(c, a, point);
    const bool hasNeg = (ab < -epsilon) || (bc < -epsilon) || (ca < -epsilon);
    const bool hasPos = (ab > epsilon) || (bc > epsilon) || (ca > epsilon);
    return !(hasNeg && hasPos);
}

std::vector<std::uint16_t> Mesh::triangulatePolygonIndices(const std::vector<int>& polygon) const {
    if (polygon.size() < 3) return {};
    if (polygon.size() == 3) {
        std::vector<std::uint16_t> out;
        for (int v : polygon) out.push_back(static_cast<std::uint16_t>(v));
        return out;
    }
    const std::vector<int> cleaned = cleanedPolygonIndices(polygon);
    if (cleaned.size() < 3) return {};
    if (cleaned.size() == 3) {
        std::vector<std::uint16_t> out;
        for (int v : cleaned) out.push_back(static_cast<std::uint16_t>(v));
        return out;
    }

    std::vector<int> remaining = cleaned;
    std::vector<std::uint16_t> triangles;
    triangles.reserve((cleaned.size() - 2) * 3);
    constexpr float eps = 0.0001f;

    const float orientation = polygonSignedArea(remaining) >= 0.0f ? 1.0f : -1.0f;

    while (remaining.size() > 3) {
        bool earFound = false;
        std::optional<std::size_t> bestEarIndex;
        float bestEarScore = std::numeric_limits<float>::max();

        for (std::size_t i = 0; i < remaining.size(); ++i) {
            const int prevIdx = remaining[(i + remaining.size() - 1) % remaining.size()];
            const int currIdx = remaining[i];
            const int nextIdx = remaining[(i + 1) % remaining.size()];
            const Vec2& a = vertices[prevIdx];
            const Vec2& b = vertices[currIdx];
            const Vec2& c = vertices[nextIdx];
            const float turn = signedArea(a, b, c) * orientation;
            if (!(turn > eps)) continue;

            bool containsOtherVertex = false;
            for (int candidate : remaining) {
                if (candidate == prevIdx || candidate == currIdx || candidate == nextIdx) continue;
                if (pointInTriangleWithEpsilon(vertices[candidate], a, b, c, eps)) {
                    containsOtherVertex = true;
                    break;
                }
            }
            if (containsOtherVertex) continue;

            const float edgeScore = length(a - c);
            if (edgeScore < bestEarScore) {
                bestEarScore = edgeScore;
                bestEarIndex = i;
            }
            earFound = true;
        }

        if (earFound && bestEarIndex.has_value()) {
            const std::size_t i = *bestEarIndex;
            const int prevIdx = remaining[(i + remaining.size() - 1) % remaining.size()];
            const int currIdx = remaining[i];
            const int nextIdx = remaining[(i + 1) % remaining.size()];
            triangles.push_back(static_cast<std::uint16_t>(prevIdx));
            triangles.push_back(static_cast<std::uint16_t>(currIdx));
            triangles.push_back(static_cast<std::uint16_t>(nextIdx));
            remaining.erase(remaining.begin() + static_cast<std::ptrdiff_t>(i));
            continue;
        }

        // Recovery path: remove the most collinear vertex to keep
        // triangulation local instead of collapsing to a star fan.
        std::size_t weakestIndex = 0;
        float weakestMagnitude = std::numeric_limits<float>::max();
        for (std::size_t i = 0; i < remaining.size(); ++i) {
            const int prevIdx = remaining[(i + remaining.size() - 1) % remaining.size()];
            const int currIdx = remaining[i];
            const int nextIdx = remaining[(i + 1) % remaining.size()];
            const float turnMag = std::abs(signedArea(vertices[prevIdx], vertices[currIdx], vertices[nextIdx]));
            if (turnMag < weakestMagnitude) {
                weakestMagnitude = turnMag;
                weakestIndex = i;
            }
        }
        const int prevIdx = remaining[(weakestIndex + remaining.size() - 1) % remaining.size()];
        const int currIdx = remaining[weakestIndex];
        const int nextIdx = remaining[(weakestIndex + 1) % remaining.size()];
        triangles.push_back(static_cast<std::uint16_t>(prevIdx));
        triangles.push_back(static_cast<std::uint16_t>(currIdx));
        triangles.push_back(static_cast<std::uint16_t>(nextIdx));
        remaining.erase(remaining.begin() + static_cast<std::ptrdiff_t>(weakestIndex));
    }

    triangles.push_back(static_cast<std::uint16_t>(remaining[0]));
    triangles.push_back(static_cast<std::uint16_t>(remaining[1]));
    triangles.push_back(static_cast<std::uint16_t>(remaining[2]));
    return triangles;
}

} // namespace umeshcore
