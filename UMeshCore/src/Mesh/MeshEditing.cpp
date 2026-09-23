// The edit-time half of `Data/Mesh.swift` that needs no texture -- see the
// "Editing" block in Mesh.h. Ported 1:1; the few places that differ say so.

#include "umeshcore/Mesh/Mesh.h"

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <set>

#include "umeshcore/Mesh/MeshKernel.h"
#include "umeshcore/Mesh/MeshPredicates.h"

namespace umeshcore {

namespace {

std::vector<int> ringOf(const std::vector<std::uint16_t>& hull) { return std::vector<int>(hull.begin(), hull.end()); }

bool validIndex(int i, std::size_t count) { return i >= 0 && static_cast<std::size_t>(i) < count; }

struct Bounds {
    Vec2 min;
    Vec2 max;
};

Bounds localBounds(const std::vector<int>& indices, const std::vector<Vec2>& vertices) {
    Bounds b{Vec2(FLT_MAX, FLT_MAX), Vec2(-FLT_MAX, -FLT_MAX)};
    for (int index : indices) {
        if (!validIndex(index, vertices.size())) continue;
        const Vec2 p = vertices[static_cast<std::size_t>(index)];
        b.min = Vec2(std::min(b.min.x, p.x), std::min(b.min.y, p.y));
        b.max = Vec2(std::max(b.max.x, p.x), std::max(b.max.y, p.y));
    }
    return b;
}

Vec2 closestPointOnSegment(const Vec2& point, const Vec2& a, const Vec2& b) {
    const Vec2 ab = b - a;
    const float lengthSquared = dot(ab, ab);
    if (!(lengthSquared > 0.000001f)) return a;
    const float t = std::max(0.0f, std::min(1.0f, dot(point - a, ab) / lengthSquared));
    return a + ab * t;
}

float cross3(const Vec2& p0, const Vec2& p1, const Vec2& p2) {
    const Vec2 ab = p1 - p0;
    const Vec2 ac = p2 - p0;
    return ab.x * ac.y - ab.y * ac.x;
}

// Swift's `pointInTriangle`: inclusive, with a small slack, either winding.
bool pointInTriangleLoose(const Vec2& point, const Vec2& a, const Vec2& b, const Vec2& c) {
    const float area = cross3(a, b, c);
    const float s = cross3(point, a, b);
    const float t = cross3(point, b, c);
    const float u = cross3(point, c, a);
    if (area >= 0) return s >= -0.0001f && t >= -0.0001f && u >= -0.0001f;
    return s <= 0.0001f && t <= 0.0001f && u <= 0.0001f;
}

// The nearest point on the outline, for clamping a vertex back inside.
Vec2 nearestOnOutline(const Vec2& point, const std::vector<int>& hull, const std::vector<Vec2>& vertices) {
    Vec2 best = point;
    float bestDistance = FLT_MAX;
    for (std::size_t e = 0; e < hull.size(); ++e) {
        const int ai = hull[e];
        const int bi = hull[(e + 1) % hull.size()];
        if (!validIndex(ai, vertices.size()) || !validIndex(bi, vertices.size())) continue;
        const Vec2 projected = closestPointOnSegment(point, vertices[static_cast<std::size_t>(ai)],
                                                     vertices[static_cast<std::size_t>(bi)]);
        const float d = length(point - projected);
        if (d < bestDistance) {
            bestDistance = d;
            best = projected;
        }
    }
    return best;
}

} // namespace

// ---- Bind fit -----------------------------------------------------------------

float Mesh::insideHullLength(const Vec2& a, const Vec2& b) const {
    const std::vector<int> ring = ringOf(hullVertexIndices);
    if (ring.size() < 3) return 0.0f;
    const float total = length(b - a);
    if (!(total > 0)) return 0.0f;

    std::vector<float> cuts{0.0f, 1.0f};
    for (std::size_t i = 0; i < ring.size(); ++i) {
        const Vec2 c = vertices[static_cast<std::size_t>(ring[i])];
        const Vec2 d = vertices[static_cast<std::size_t>(ring[(i + 1) % ring.size()])];
        if (!MeshPredicates::segmentsTouchOrCross(a, b, c, d)) continue;
        const float denominator = (b.x - a.x) * (d.y - c.y) - (b.y - a.y) * (d.x - c.x);
        // Parallel: any piece along this edge is bounded by its neighbours'
        // crossings, found on their own iterations.
        if (!(std::fabs(denominator) > 1e-9f)) continue;
        const float t = ((c.x - a.x) * (d.y - c.y) - (c.y - a.y) * (d.x - c.x)) / denominator;
        if (t > 0 && t < 1) cuts.push_back(t);
    }
    std::sort(cuts.begin(), cuts.end());

    float inside = 0.0f;
    for (std::size_t index = 1; index < cuts.size(); ++index) {
        const float lo = cuts[index - 1];
        const float hi = cuts[index];
        if (!(hi - lo > 1e-7f)) continue;
        const float mid = (lo + hi) * 0.5f;
        const Vec2 point = a + (b - a) * mid;
        if (MeshKernel::pointInRing(vertices, ring, point)) inside += (hi - lo) * total;
    }
    return inside;
}

float Mesh::hullSpan(const Vec2& direction) const {
    const std::vector<int> ring = ringOf(hullVertexIndices);
    if (ring.size() < 3) return 0.0f;
    const float len = length(direction);
    if (!(len > 1e-9f)) return 0.0f;
    const Vec2 unit = direction / len;
    float lo = FLT_MAX, hi = -FLT_MAX;
    for (int index : ring) {
        const float projection = dot(vertices[static_cast<std::size_t>(index)], unit);
        lo = std::min(lo, projection);
        hi = std::max(hi, projection);
    }
    return std::max(0.0f, hi - lo);
}

Mesh::BoneFit Mesh::fit(const Vec2& start, const Vec2& end, std::optional<MeshBindPose> pose) const {
    const std::vector<int> ring = ringOf(hullVertexIndices);
    if (ring.size() < 3) return BoneFit{};

    const Vec2 localStart = pose.has_value() ? pose->localPoint(start) : start;
    const Vec2 localEnd = pose.has_value() ? pose->localPoint(end) : end;
    const bool rooted = MeshKernel::pointInRing(vertices, ring, localStart);

    const float boneLength = length(localEnd - localStart);
    // A tip bone has no segment to measure; its joint is the whole of it.
    if (!(boneLength > 1e-6f)) return BoneFit{0.0f, rooted ? 1.0f : 0.0f, 0.0f, rooted};

    const float overlap = insideHullLength(localStart, localEnd);
    const float span = hullSpan(localEnd - localStart);
    return BoneFit{overlap, std::min(1.0f, overlap / boneLength), span > 1e-9f ? std::min(1.0f, overlap / span) : 0.0f,
                   rooted};
}

// ---- Manual bind / unbind --------------------------------------------------------

// BINDS, AND DOES NOT PAINT: the bone gets its inverse-bind matrix and no
// weight anywhere (which `boundBoneIDs` counts as bound), so hand-painted
// weights survive a manual bind.
Mesh Mesh::addingBoneInfluence(Uuid boneID, const Mat4& worldMatrix, int maxInfluences,
                               std::optional<MeshBindPose> imagePose) const {
    Mesh next = *this;
    if (next.bindVertices.size() != next.vertices.size()) next.bindVertices = next.vertices;
    if (!next.bindImagePose.has_value()) next.bindImagePose = imagePose;
    if (next.vertexBoneWeights.size() != next.vertices.size()) next.vertexBoneWeights.assign(next.vertices.size(), {});
    next.boneInverseBindMatrices[boneID] = inverse(worldMatrix);
    return next.sanitizedSkinningData(maxInfluences);
}

Mesh Mesh::removingBoneInfluence(Uuid boneID, int maxInfluences) const {
    Mesh next = *this;
    next.boneInverseBindMatrices.erase(boneID);
    if (next.boneInverseBindMatrices.empty()) next.bindImagePose = std::nullopt;
    if (next.vertexBoneWeights.empty()) return next;
    for (auto& influences : next.vertexBoneWeights) {
        influences.erase(std::remove_if(influences.begin(), influences.end(),
                                        [&](const VertexBoneWeight& w) { return w.boneID == boneID; }),
                         influences.end());
    }
    return next.sanitizedSkinningData(maxInfluences);
}

// ---- Generation ---------------------------------------------------------------------

Mesh Mesh::generated(const Vec2& size, float density) const {
    if (isQuadCompatible()) return generatedGrid(size, 2);
    if (hullVertexIndices.size() < 3) return *this;
    const Bounds bounds = localBounds(ringOf(hullVertexIndices), vertices);
    const float width = bounds.max.x - bounds.min.x;
    const float height = bounds.max.y - bounds.min.y;
    const float maxDimension = std::max(width, height);
    const float minDimension = std::min(width, height);
    const float area = width * height;
    const float aspectRatio = maxDimension / std::max(minDimension, 1.0f);
    // A thin shape must take its spacing from the SHORT axis, or the grid is
    // wider than the shape and samples nothing.
    const float baseSpacing = aspectRatio > 2.5f ? std::max(minDimension * 0.55f, 8.0f) : maxDimension / 5.0f;
    // Density 0...100 scales spacing 1.7x -> 0.4x.
    const float d = std::max(0.0f, std::min(100.0f, density));
    const float spacingMultiplier = 1.7f - (d / 100.0f) * 1.3f;
    const float spacing = std::max(6.0f, std::min(80.0f, baseSpacing * spacingMultiplier));
    const int estimatedCount = static_cast<int>(area / (spacing * spacing * 0.86f)) + 4;
    const int maxCount = std::max(0, std::min(200, estimatedCount));
    return meshWithRetriangulatedInteriorPoints(sampledInteriorPoints(spacing, maxCount), size);
}

// A fresh mesh, as Swift's memberwise init makes one: new id, no binding.
Mesh Mesh::generatedGrid(const Vec2& size, int subdivisions) const {
    const int columns = subdivisions + 1;
    const int rows = subdivisions + 1;
    Mesh grid(name);
    for (int row = 0; row < rows; ++row) {
        const float v = static_cast<float>(row) / static_cast<float>(subdivisions);
        for (int column = 0; column < columns; ++column) {
            const float u = static_cast<float>(column) / static_cast<float>(subdivisions);
            grid.uvs.push_back(Vec2(u, v));
            grid.vertices.push_back(localPosition(Vec2(u, v), size));
        }
    }
    for (int row = 0; row < subdivisions; ++row) {
        for (int column = 0; column < subdivisions; ++column) {
            const auto topLeft = static_cast<std::uint16_t>(row * columns + column);
            const auto topRight = static_cast<std::uint16_t>(topLeft + 1);
            const auto bottomLeft = static_cast<std::uint16_t>((row + 1) * columns + column);
            const auto bottomRight = static_cast<std::uint16_t>(bottomLeft + 1);
            grid.indices.insert(grid.indices.end(),
                                {topLeft, topRight, bottomLeft, bottomLeft, topRight, bottomRight});
        }
    }
    const auto count = static_cast<std::uint16_t>(grid.vertices.size());
    grid.hullVertexIndices = {0, static_cast<std::uint16_t>(columns - 1), static_cast<std::uint16_t>(count - 1),
                              static_cast<std::uint16_t>(count - columns)};
    return grid;
}

// Tile the outline, add the interior points, flip toward Delaunay -- the
// kernel's pipeline, run once. A point outside the outline is never added.
Mesh Mesh::meshWithRetriangulatedInteriorPoints(const std::vector<Vec2>& interiorPoints, const Vec2& size) const {
    Mesh next = *this;
    next.vertices.clear();
    for (std::uint16_t index : hullVertexIndices) {
        if (index < vertices.size()) next.vertices.push_back(vertices[index]);
    }
    next.uvs.clear();
    for (const Vec2& v : next.vertices) next.uvs.push_back(uvFor(v, size));
    next.hullVertexIndices.clear();
    for (std::size_t i = 0; i < next.vertices.size(); ++i) next.hullVertexIndices.push_back(static_cast<std::uint16_t>(i));
    next.internalEdges.clear();
    next.manualTriangles.clear();

    const std::size_t hullCount = next.vertices.size();
    for (const Vec2& point : interiorPoints) {
        const bool farEnough = std::all_of(next.vertices.begin(), next.vertices.end(),
                                           [&](const Vec2& v) { return length(v - point) >= 6.0f; });
        if (!farEnough || !next.pointInsideHullForKernel(point)) continue;
        next.vertices.push_back(point);
        next.uvs.push_back(uvFor(point, size));
    }

    try {
        next.indices = next.kernelTriangulatedIndices();
    } catch (const MeshKernel::TriangulationError&) {
        // The outline itself is not fillable: the hull fan keeps the sprite
        // drawing while the artist fixes it.
        next.vertices.resize(hullCount);
        next.uvs.resize(hullCount);
        next.indices = next.triangulatedHullIndices();
    }
    return next;
}

std::vector<Vec2> Mesh::sampledInteriorPoints(float spacing, int maxCount) const {
    if (maxCount <= 0 || hullVertexIndices.size() < 3) return {};
    const Bounds bounds = localBounds(ringOf(hullVertexIndices), vertices);
    if (!(bounds.max.x > bounds.min.x) || !(bounds.max.y > bounds.min.y)) return {};

    std::vector<Vec2> points;
    const float startY = bounds.min.y + spacing * 0.5f;
    const float endY = bounds.max.y - spacing * 0.5f;
    const float startX = bounds.min.x + spacing * 0.5f;
    const float endX = bounds.max.x - spacing * 0.5f;
    if (!(startX <= endX) || !(startY <= endY)) return {};

    int row = 0;
    float y = startY;
    while (y <= endY && static_cast<int>(points.size()) < maxCount) {
        const float offsetX = row % 2 == 0 ? 0.0f : spacing * 0.5f;
        float x = startX + offsetX;
        while (x <= endX && static_cast<int>(points.size()) < maxCount) {
            const Vec2 point(x, y);
            if (pointInsideHull(point) &&
                std::all_of(vertices.begin(), vertices.end(),
                            [&](const Vec2& v) { return length(v - point) >= spacing * 0.5f; }) &&
                std::all_of(points.begin(), points.end(),
                            [&](const Vec2& p) { return length(p - point) >= spacing * 0.85f; })) {
                points.push_back(point);
            }
            x += spacing;
        }
        y += spacing * 0.86f;
        row += 1;
    }
    return points;
}

// ---- Containment ---------------------------------------------------------------------

bool Mesh::pointInsideHull(const Vec2& point) const {
    const std::vector<int> polygon = ringOf(hullVertexIndices);
    if (polygon.size() < 3) return false;
    bool inside = false;
    int previous = polygon.back();
    for (int current : polygon) {
        const Vec2 a = vertices[static_cast<std::size_t>(previous)];
        const Vec2 b = vertices[static_cast<std::size_t>(current)];
        const bool intersects =
            ((a.y > point.y) != (b.y > point.y)) && (point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x);
        if (intersects) inside = !inside;
        previous = current;
    }
    return inside;
}

bool Mesh::pointOnHullBoundary(const Vec2& point, float epsilon) const {
    const std::vector<int> polygon = ringOf(hullVertexIndices);
    if (polygon.size() < 2) return false;
    for (std::size_t i = 0; i < polygon.size(); ++i) {
        const Vec2 a = vertices[static_cast<std::size_t>(polygon[i])];
        const Vec2 b = vertices[static_cast<std::size_t>(polygon[(i + 1) % polygon.size()])];
        if (pointDistanceToSegment(point, a, b) <= epsilon) return true;
    }
    return false;
}

bool Mesh::segmentInsideHull(const Vec2& a, const Vec2& b, int samples) const {
    if (samples < 3) return true;
    for (int step = 1; step < samples - 1; ++step) {
        const float t = static_cast<float>(step) / static_cast<float>(samples - 1);
        const Vec2 p = a + (b - a) * t;
        if (!(pointInsideHull(p) || pointOnHullBoundary(p))) return false;
    }
    return true;
}

std::vector<MeshEdge> Mesh::hullBoundaryEdges() const {
    std::vector<MeshEdge> edges;
    if (hullVertexIndices.size() < 2) return edges;
    for (std::size_t i = 0; i < hullVertexIndices.size(); ++i) {
        edges.emplace_back(hullVertexIndices[i], hullVertexIndices[(i + 1) % hullVertexIndices.size()]);
    }
    return edges;
}

// ---- Vertex insertion and removal -------------------------------------------------------

std::optional<Mesh::InsertedVertex> Mesh::insertingHullVertex(const Vec2& localPosition, int edgeIndex) const {
    if (hullVertexIndices.size() < 2 || !validIndex(edgeIndex, hullVertexIndices.size())) return std::nullopt;
    const int startIndex = hullVertexIndices[static_cast<std::size_t>(edgeIndex)];
    const int endIndex = hullVertexIndices[(static_cast<std::size_t>(edgeIndex) + 1) % hullVertexIndices.size()];
    if (!validIndex(startIndex, vertices.size()) || !validIndex(endIndex, vertices.size()) ||
        !validIndex(startIndex, uvs.size()) || !validIndex(endIndex, uvs.size())) {
        return std::nullopt;
    }
    const Vec2 start = vertices[static_cast<std::size_t>(startIndex)];
    const Vec2 end = vertices[static_cast<std::size_t>(endIndex)];
    const Vec2 segment = end - start;
    const float segmentLengthSquared = lengthSquared(segment);
    const float t = segmentLengthSquared > 0.0001f
                        ? std::max(0.0f, std::min(1.0f, dot(localPosition - start, segment) / segmentLengthSquared))
                        : 0.5f;
    const Vec2 uvA = uvs[static_cast<std::size_t>(startIndex)];
    const Vec2 uvB = uvs[static_cast<std::size_t>(endIndex)];
    const Vec2 interpolatedUV = uvA + (uvB - uvA) * t;

    Mesh next = *this;
    const int insertedIndex = static_cast<int>(next.vertices.size());
    next.vertices.push_back(localPosition);
    next.uvs.push_back(interpolatedUV);
    if (!next.bindVertices.empty()) next.bindVertices.push_back(localPosition);
    if (!next.vertexBoneWeights.empty()) next.vertexBoneWeights.push_back({});
    next.hullVertexIndices.insert(next.hullVertexIndices.begin() + edgeIndex + 1,
                                  static_cast<std::uint16_t>(insertedIndex));
    // If the outline cannot be filled with the new point in it, refuse
    // rather than store a gap.
    try {
        next.indices = next.kernelTriangulatedIndices();
    } catch (const MeshKernel::TriangulationError&) {
        return std::nullopt;
    }
    return InsertedVertex{next.sanitizedSkinningData(), insertedIndex};
}

// Only inside the outline (or on it): no tool path can place an interior
// vertex beyond the edge line.
std::optional<Mesh::InsertedVertex> Mesh::insertingInteriorVertex(const Vec2& localPosition, const Vec2& size) const {
    if (hullVertexIndices.size() < 3) return std::nullopt;
    if (!(pointInsideHull(localPosition) || pointOnHullBoundary(localPosition, 1.25f))) return std::nullopt;
    Mesh next = *this;
    const int insertedIndex = static_cast<int>(next.vertices.size());
    next.vertices.push_back(localPosition);
    next.uvs.push_back(uvFor(localPosition, size));
    if (!next.bindVertices.empty()) next.bindVertices.push_back(localPosition);
    if (!next.vertexBoneWeights.empty()) next.vertexBoneWeights.push_back({});
    try {
        next.indices = next.kernelTriangulatedIndices();
    } catch (const MeshKernel::TriangulationError&) {
        return std::nullopt;
    }
    return InsertedVertex{next.sanitizedSkinningData(), insertedIndex};
}

std::vector<Vec2> MeshTopologyChange::remapped(const std::vector<Vec2>& perVertex,
                                                 const std::vector<Vec2>& fallback) const {
    std::vector<Vec2> result = fallback;
    for (const auto& [oldIndex, newIndex] : remap) {
        if (validIndex(oldIndex, perVertex.size()) && validIndex(newIndex, result.size())) {
            result[static_cast<std::size_t>(newIndex)] = perVertex[static_cast<std::size_t>(oldIndex)];
        }
    }
    return result;
}

// Refuses the whole edit when the reduced outline is not a legal polygon
// (deleting a boundary point on a concave silhouette can make its two
// neighbours' new segment cross the outline) -- never a torn mesh.
std::optional<Mesh::TopologyChange> Mesh::removingVertices(const std::unordered_set<int>& removed) const {
    if (removed.empty()) {
        TopologyChange same{*this, {}};
        for (std::size_t i = 0; i < vertices.size(); ++i) same.remap[static_cast<int>(i)] = static_cast<int>(i);
        return same;
    }
    std::vector<std::uint16_t> remainingHull;
    for (std::uint16_t raw : hullVertexIndices) {
        if (!removed.contains(raw)) remainingHull.push_back(raw);
    }
    if (remainingHull.size() < 3) return std::nullopt;

    TopologyChange change{*this, {}};
    Mesh& next = change.mesh;
    next.vertices.clear();
    next.uvs.clear();
    next.bindVertices.clear();
    next.vertexBoneWeights.clear();
    for (std::size_t index = 0; index < vertices.size(); ++index) {
        if (removed.contains(static_cast<int>(index))) continue;
        change.remap[static_cast<int>(index)] = static_cast<int>(next.vertices.size());
        next.vertices.push_back(vertices[index]);
        next.uvs.push_back(uvs[index]);
        if (index < bindVertices.size()) next.bindVertices.push_back(bindVertices[index]);
        if (index < vertexBoneWeights.size()) next.vertexBoneWeights.push_back(vertexBoneWeights[index]);
    }

    next.hullVertexIndices.clear();
    for (std::uint16_t raw : remainingHull) {
        auto it = change.remap.find(raw);
        if (it != change.remap.end()) next.hullVertexIndices.push_back(static_cast<std::uint16_t>(it->second));
    }
    if (next.hullVertexIndices.size() < 3) return std::nullopt;

    next.internalEdges.clear();
    for (const MeshEdge& edge : internalEdges) {
        auto a = change.remap.find(edge.a), b = change.remap.find(edge.b);
        if (a == change.remap.end() || b == change.remap.end() || a->second == b->second) continue;
        next.internalEdges.emplace_back(static_cast<std::uint16_t>(a->second), static_cast<std::uint16_t>(b->second));
    }
    next.manualTriangles.clear();
    for (const MeshTriangle& triangle : manualTriangles) {
        auto a = change.remap.find(triangle.a), b = change.remap.find(triangle.b), c = change.remap.find(triangle.c);
        if (a == change.remap.end() || b == change.remap.end() || c == change.remap.end()) continue;
        if (a->second == b->second || b->second == c->second || a->second == c->second) continue;
        next.manualTriangles.push_back(MeshTriangle{static_cast<std::uint16_t>(a->second),
                                                    static_cast<std::uint16_t>(b->second),
                                                    static_cast<std::uint16_t>(c->second)});
    }
    try {
        next.indices = next.kernelTriangulatedIndices();
    } catch (const MeshKernel::TriangulationError&) {
        return std::nullopt;
    }
    next = next.sanitizedSkinningData();
    return change;
}

// ---- Edges and faces --------------------------------------------------------------------------

Mesh Mesh::connectingVertices(int first, int second) const {
    if (!validIndex(first, vertices.size()) || !validIndex(second, vertices.size()) || first == second) return *this;
    const MeshEdge edge(static_cast<std::uint16_t>(first), static_cast<std::uint16_t>(second));
    const std::vector<MeshEdge> hullEdges = hullBoundaryEdges();
    if (std::find(hullEdges.begin(), hullEdges.end(), edge) != hullEdges.end()) return *this;
    if (std::find(internalEdges.begin(), internalEdges.end(), edge) != internalEdges.end()) return *this;
    Mesh next = *this;
    next.internalEdges.push_back(edge);
    // The new edge is a constraint the flip pass must preserve.
    try {
        next.indices = next.kernelTriangulatedIndices();
    } catch (const MeshKernel::TriangulationError&) {
        return *this;
    }
    return next;
}

Mesh Mesh::creatingFace(int first, int second, int third) const {
    for (int i : {first, second, third}) {
        if (!validIndex(i, vertices.size())) return *this;
    }
    if (first == second || second == third || first == third) return *this;
    const Vec2 a = vertices[static_cast<std::size_t>(first)];
    const Vec2 b = vertices[static_cast<std::size_t>(second)];
    const Vec2 c = vertices[static_cast<std::size_t>(third)];
    // Every edge of the face must lie inside the outline.
    if (!segmentInsideHull(a, b) || !segmentInsideHull(b, c) || !segmentInsideHull(c, a)) return *this;
    const float area = signedArea(a, b, c);
    if (!(std::fabs(area) > 0.0001f)) return *this;
    const auto f = static_cast<std::uint16_t>(first), s = static_cast<std::uint16_t>(second),
               t = static_cast<std::uint16_t>(third);
    const MeshTriangle face = area < 0 ? MeshTriangle{f, s, t} : MeshTriangle{f, t, s};
    const auto key = face.normalizedKey();
    for (const MeshTriangle& existing : manualTriangles) {
        if (existing.normalizedKey() == key) return *this;
    }
    Mesh next = *this;
    next.manualTriangles.push_back(face);
    next.indices = next.triangulatedIndicesWithInternalEdges();
    return next;
}

Mesh Mesh::clearingInternalEdges() const {
    Mesh next = *this;
    next.internalEdges.clear();
    next.manualTriangles.clear();
    next.indices = next.triangulatedHullIndices();
    return next;
}

// ---- Clamping -------------------------------------------------------------------------------------

Vec2 Mesh::clampedPositionInsideHullIfNeeded(int vertexIndex, const Vec2& proposed) const {
    if (!validIndex(vertexIndex, vertices.size())) return proposed;
    const std::vector<int> hull = ringOf(hullVertexIndices);
    if (std::find(hull.begin(), hull.end(), vertexIndex) != hull.end()) return proposed;
    if (hull.size() < 3) return proposed;
    if (pointInsideHull(proposed) || pointOnHullBoundary(proposed, 0.75f)) return proposed;
    return nearestOnOutline(proposed, hull, vertices);
}

Mesh Mesh::clampingInteriorVerticesInsideHull(const Vec2& size) const {
    if (hullVertexIndices.size() < 3) return *this;
    Mesh next = *this;
    const std::vector<int> hull = ringOf(hullVertexIndices);
    const std::unordered_set<int> hullSet(hull.begin(), hull.end());
    bool didAdjust = false;
    for (std::size_t index = 0; index < next.vertices.size(); ++index) {
        if (hullSet.contains(static_cast<int>(index))) continue;
        const Vec2 vertex = next.vertices[index];
        if (next.pointInsideHull(vertex) || next.pointOnHullBoundary(vertex, 0.75f)) continue;
        const Vec2 best = nearestOnOutline(vertex, hull, next.vertices);
        next.vertices[index] = best;
        if (index < next.uvs.size()) next.uvs[index] = uvFor(best, size);
        didAdjust = true;
    }
    if (didAdjust) next.indices = next.triangulatedIndicesWithInternalEdges();
    return next;
}

std::optional<Mesh::BarycentricSample> Mesh::barycentricSample(const Vec2& point) const {
    if (indices.size() < 3) return std::nullopt;
    for (std::size_t t = 0; t + 2 < indices.size(); t += 3) {
        const int ia = indices[t], ib = indices[t + 1], ic = indices[t + 2];
        if (!validIndex(ia, vertices.size()) || !validIndex(ib, vertices.size()) || !validIndex(ic, vertices.size())) {
            continue;
        }
        const Vec2 a = vertices[static_cast<std::size_t>(ia)];
        const Vec2 b = vertices[static_cast<std::size_t>(ib)];
        const Vec2 c = vertices[static_cast<std::size_t>(ic)];
        const float total = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y);
        if (!(std::fabs(total) > 1e-12f)) continue;
        const float wa = ((b.x - point.x) * (c.y - point.y) - (c.x - point.x) * (b.y - point.y)) / total;
        const float wb = ((c.x - point.x) * (a.y - point.y) - (a.x - point.x) * (c.y - point.y)) / total;
        const float wc = 1 - wa - wb;
        const float slack = -1e-4f;
        if (wa >= slack && wb >= slack && wc >= slack) return BarycentricSample{ia, ib, ic, wa, wb, wc};
    }
    return std::nullopt;
}

// ---- Manual faces ------------------------------------------------------------------------------------

std::vector<MeshTriangle> Mesh::sanitizedManualTriangles() const {
    std::set<std::array<std::uint16_t, 3>> seen;
    std::vector<MeshTriangle> out;
    for (const MeshTriangle& triangle : manualTriangles) {
        const auto idx = triangle.indices();
        if (!std::all_of(idx.begin(), idx.end(), [&](int i) { return validIndex(i, vertices.size()); })) continue;
        if (idx[0] == idx[1] || idx[1] == idx[2] || idx[0] == idx[2]) continue;
        if (!seen.insert(triangle.normalizedKey()).second) continue;
        out.push_back(triangle);
    }
    return out;
}

std::vector<std::uint16_t> Mesh::generatedTrianglesByRemovingTrianglesCoveredByManualFaces(
    const std::vector<std::uint16_t>& triangles, const std::vector<MeshTriangle>& manual) const {
    if (manual.empty()) return triangles;
    std::vector<std::uint16_t> filtered;
    for (std::size_t i = 0; i + 2 < triangles.size(); i += 3) {
        const MeshTriangle triangle{triangles[i], triangles[i + 1], triangles[i + 2]};
        const std::optional<Vec2> centroid = triangle.centroid(vertices);
        if (!centroid.has_value()) continue;
        const bool covered = std::any_of(manual.begin(), manual.end(), [&](const MeshTriangle& m) {
            if (triangle.normalizedKey() == m.normalizedKey()) return false;
            const auto idx = m.indices();
            if (!std::all_of(idx.begin(), idx.end(), [&](int k) { return validIndex(k, vertices.size()); })) {
                return false;
            }
            return pointInTriangleLoose(*centroid, vertices[static_cast<std::size_t>(idx[0])],
                                        vertices[static_cast<std::size_t>(idx[1])],
                                        vertices[static_cast<std::size_t>(idx[2])]);
        });
        if (!covered) filtered.insert(filtered.end(), {triangle.a, triangle.b, triangle.c});
    }
    return filtered;
}

// One geometric path: the kernel, and the hull fan only when the outline
// genuinely cannot be filled (so this stays total for callers that cannot
// refuse). Manual faces replace the kernel triangles they cover.
std::vector<std::uint16_t> Mesh::triangulatedIndicesWithInternalEdges() const {
    std::vector<std::uint16_t> triangles;
    try {
        triangles = kernelTriangulatedIndices();
    } catch (const MeshKernel::TriangulationError&) {
        triangles = triangulatedHullIndices();
    }
    if (triangles.empty()) triangles = triangulatedHullIndices();

    const std::vector<MeshTriangle> manual = sanitizedManualTriangles();
    triangles = generatedTrianglesByRemovingTrianglesCoveredByManualFaces(triangles, manual);
    for (const MeshTriangle& face : manual) triangles.insert(triangles.end(), {face.a, face.b, face.c});
    const std::vector<std::uint16_t> sanitized = sanitizedTriangleIndices(triangles);
    if (!sanitized.empty()) return sanitized;
    return sanitizedTriangleIndices(triangulatedHullIndices());
}

} // namespace umeshcore
