// `Mesh.tracedHull` -- Auto-Mesh: follow a sprite's opaque silhouette and
// build its outline -- with the private pipeline it runs: connected
// components, pixel-boundary tracing, smoothing, RDP simplification,
// padding, the concavity filter, keyhole stitching of several shapes into
// one ring, and the opaque-area triangle filter.
//
// Ported 1:1 from `Data/Mesh.swift`. Not ported, because nothing calls them
// (verified by grep over the whole Swift source): `constrainedToOpaqueArea`
// (its one mention elsewhere is a comment saying NOT to call it),
// `hullQuality`, `convexHull(of:)`, `insetPolygon`, `subdivideHullEdges`,
// `largestConnectedComponentMask`, `closestPointOnPolygonBoundary`, and
// `pointInsidePolygon` (whose only caller is the dead `hullQuality`).
//
// Determinism: Swift picks the next loop's seed with `Set.min(by:)`, which
// breaks ties between edges that share a start pixel in hash order, and
// sorts components with an unstable sort. Here ties go to the first in
// scan order. Same outlines whenever Swift's answer was unique.

#include "umeshcore/Mesh/Mesh.h"

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <map>

#include "umeshcore/Mesh/AlphaMask.h"

namespace umeshcore {

namespace {

using Polygon = std::vector<Vec2>;

int roundedInt(float v) { return static_cast<int>(std::lround(v)); }

std::vector<std::vector<int>> findConnectedComponents(const std::vector<bool>& mask, int width, int height) {
    std::vector<std::vector<int>> components;
    if (width <= 0 || height <= 0 || mask.size() != static_cast<std::size_t>(width * height)) return components;
    std::vector<bool> visited(mask.size(), false);
    const int neighbors[4][2] = {{-1, 0}, {1, 0}, {0, -1}, {0, 1}};
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const int index = y * width + x;
            if (!mask[static_cast<std::size_t>(index)] || visited[static_cast<std::size_t>(index)]) continue;
            visited[static_cast<std::size_t>(index)] = true;
            std::vector<int> queue{index};
            std::size_t head = 0;
            std::vector<int> component{index};
            while (head < queue.size()) {
                const int current = queue[head++];
                const int cx = current % width, cy = current / width;
                for (const auto& d : neighbors) {
                    const int nx = cx + d[0], ny = cy + d[1];
                    if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
                    const int ni = ny * width + nx;
                    if (!mask[static_cast<std::size_t>(ni)] || visited[static_cast<std::size_t>(ni)]) continue;
                    visited[static_cast<std::size_t>(ni)] = true;
                    queue.push_back(ni);
                    component.push_back(ni);
                }
            }
            components.push_back(std::move(component));
        }
    }
    return components;
}

// The pixel-edge boundary of the mask, as the largest closed loop of
// directed cell edges (solid on the left of travel).
Polygon traceBoundaryPixels(const std::vector<bool>& mask, int width, int height) {
    if (width <= 0 || height <= 0) return {};
    struct GridPoint {
        int x, y;
        bool operator==(const GridPoint&) const = default;
        bool operator<(const GridPoint& o) const { return y == o.y ? x < o.x : y < o.y; }
    };
    struct Edge {
        GridPoint start, end;
    };
    auto isSolid = [&](int x, int y) {
        if (x < 0 || x >= width || y < 0 || y >= height) return false;
        return static_cast<bool>(mask[static_cast<std::size_t>(y * width + x)]);
    };

    std::vector<Edge> edges;
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            if (!isSolid(x, y)) continue;
            const GridPoint tl{x, y}, tr{x + 1, y}, br{x + 1, y + 1}, bl{x, y + 1};
            if (!isSolid(x, y - 1)) edges.push_back({tl, tr});
            if (!isSolid(x + 1, y)) edges.push_back({tr, br});
            if (!isSolid(x, y + 1)) edges.push_back({br, bl});
            if (!isSolid(x - 1, y)) edges.push_back({bl, tl});
        }
    }
    if (edges.empty()) return {};

    std::map<GridPoint, std::vector<std::size_t>> byStart;
    for (std::size_t i = 0; i < edges.size(); ++i) byStart[edges[i].start].push_back(i);
    std::vector<bool> unused(edges.size(), true);
    std::size_t remaining = edges.size();
    std::vector<std::vector<GridPoint>> loops;

    while (remaining > 0) {
        // The unused edge with the smallest start; first in scan order on a tie.
        std::size_t seed = edges.size();
        for (std::size_t i = 0; i < edges.size(); ++i) {
            if (!unused[i]) continue;
            if (seed == edges.size() || edges[i].start < edges[seed].start) seed = i;
        }
        std::vector<GridPoint> loop{edges[seed].start};
        std::size_t current = seed;
        unused[current] = false;
        remaining -= 1;
        const std::size_t maxSteps = edges.size() + 8;
        for (std::size_t steps = 0; steps < maxSteps; ++steps) {
            loop.push_back(edges[current].end);
            if (edges[current].end == edges[seed].start) break;
            auto it = byStart.find(edges[current].end);
            if (it == byStart.end()) break;
            std::size_t next = edges.size();
            for (std::size_t candidate : it->second) {
                if (unused[candidate]) {
                    next = candidate;
                    break;
                }
            }
            if (next == edges.size()) break;
            current = next;
            unused[current] = false;
            remaining -= 1;
        }
        if (loop.size() >= 4 && loop.front() == loop.back()) loops.push_back(std::move(loop));
    }

    auto loopArea = [](const std::vector<GridPoint>& loop) {
        if (loop.size() < 3) return 0.0f;
        float area = 0.0f;
        std::size_t j = loop.size() - 1;
        for (std::size_t i = 0; i < loop.size(); ++i) {
            area += static_cast<float>(loop[j].x * loop[i].y - loop[i].x * loop[j].y);
            j = i;
        }
        return area * 0.5f;
    };
    if (loops.empty()) return {};
    // `max(by:)` keeps the first of equal maxima.
    std::size_t best = 0;
    for (std::size_t i = 1; i < loops.size(); ++i) {
        if (std::fabs(loopArea(loops[best])) < std::fabs(loopArea(loops[i]))) best = i;
    }
    Polygon deduped;
    for (std::size_t i = 0; i + 1 < loops[best].size(); ++i) {
        const Vec2 p(static_cast<float>(loops[best][i].x), static_cast<float>(loops[best][i].y));
        if (deduped.empty() || !(length(deduped.back() - p) < 0.001f)) deduped.push_back(p);
    }
    return deduped;
}

// Moving-average smoothing: removes the one-pixel stair-steps of a tilted
// edge and barely shifts a real corner.
Polygon smoothContour(const Polygon& contour, int windowRadius) {
    if (windowRadius <= 0 || static_cast<int>(contour.size()) <= windowRadius * 4) return contour;
    const int n = static_cast<int>(contour.size());
    const float span = static_cast<float>(windowRadius * 2 + 1);
    Polygon smoothed;
    smoothed.reserve(contour.size());
    for (int i = 0; i < n; ++i) {
        Vec2 sum = Vec2::zero();
        for (int j = -windowRadius; j <= windowRadius; ++j) sum = sum + contour[static_cast<std::size_t>(((i + j) % n + n) % n)];
        smoothed.push_back(sum / span);
    }
    return smoothed;
}

float perpendicularDistance(const Vec2& point, const Vec2& lineStart, const Vec2& lineEnd) {
    const Vec2 line = lineEnd - lineStart;
    const float lengthSq = lengthSquared(line);
    if (!(lengthSq > 0.0001f)) return length(point - lineStart);
    const float t = std::max(0.0f, std::min(1.0f, dot(point - lineStart, line) / lengthSq));
    return length(point - (lineStart + line * t));
}

Polygon rdp(const Polygon& pts, std::size_t lo, std::size_t hi, float epsilon) {
    if (hi - lo + 1 <= 2) return Polygon(pts.begin() + static_cast<long>(lo), pts.begin() + static_cast<long>(hi) + 1);
    const Vec2 first = pts[lo], last = pts[hi];
    float maxDistance = 0.0f;
    std::size_t index = lo;
    for (std::size_t i = lo + 1; i < hi; ++i) {
        const float d = perpendicularDistance(pts[i], first, last);
        if (d > maxDistance) {
            maxDistance = d;
            index = i;
        }
    }
    if (maxDistance > epsilon) {
        Polygon left = rdp(pts, lo, index, epsilon);
        const Polygon right = rdp(pts, index, hi, epsilon);
        left.pop_back();
        left.insert(left.end(), right.begin(), right.end());
        return left;
    }
    return {first, last};
}

Polygon simplifyHullRDP(const Polygon& points, float epsilon) {
    if (points.size() <= 3) return points;
    Polygon closed = points;
    if (length(closed.front() - closed.back()) > 0.001f) closed.push_back(closed.front());
    Polygon simplified = rdp(closed, 0, closed.size() - 1, epsilon);
    if (simplified.size() > 3 && length(simplified.front() - simplified.back()) < 0.001f) simplified.pop_back();
    return simplified;
}

// Offsets every vertex outward along its corner bisector, with a mitre
// limit (1.5x) and a cap of half the shorter adjacent edge, so sharp or
// thin shapes do not spike or self-intersect.
Polygon expandPolygonOutward(const Polygon& polygon, float expansion) {
    if (polygon.size() < 3 || !(expansion > 0)) return polygon;
    const std::size_t count = polygon.size();
    float signedArea = 0.0f;
    for (std::size_t i = 0; i < count; ++i) {
        const Vec2 a = polygon[i], b = polygon[(i + 1) % count];
        signedArea += (b.x - a.x) * (b.y + a.y);
    }
    const float outwardSign = signedArea > 0 ? -1.0f : 1.0f;
    Polygon result;
    result.reserve(count);
    for (std::size_t index = 0; index < count; ++index) {
        const Vec2 prev = polygon[(index + count - 1) % count];
        const Vec2 curr = polygon[index];
        const Vec2 next = polygon[(index + 1) % count];
        const Vec2 edgeIn = curr - prev, edgeOut = next - curr;
        const float lenIn = length(edgeIn), lenOut = length(edgeOut);
        if (!(lenIn > 0.0001f) && !(lenOut > 0.0001f)) {
            result.push_back(curr);
            continue;
        }
        const Vec2 normalIn = lenIn > 0.0001f ? Vec2(edgeIn.y, -edgeIn.x) / lenIn * outwardSign : Vec2::zero();
        const Vec2 normalOut = lenOut > 0.0001f ? Vec2(edgeOut.y, -edgeOut.x) / lenOut * outwardSign : Vec2::zero();
        Vec2 bisector = normalIn + normalOut;
        const float bisectorLength = length(bisector);
        if (bisectorLength > 0.0001f) {
            bisector = bisector / bisectorLength;
        } else {
            bisector = lenOut > 0.0001f ? normalOut : normalIn;
        }
        const float cosHalf = std::max(0.4f, dot(normalIn, bisector));
        const float edgeCap = lenIn > 0.0001f && lenOut > 0.0001f ? std::max(expansion, std::min(lenIn, lenOut) * 0.5f)
                                                                  : expansion * 1.5f;
        const float magnitude = std::min({expansion / cosHalf, expansion * 1.5f, edgeCap});
        result.push_back(curr + bisector * magnitude);
    }
    return result;
}

float polygonArea(const Polygon& polygon) {
    if (polygon.size() < 3) return 0.0f;
    float area = 0.0f;
    std::size_t j = polygon.size() - 1;
    for (std::size_t i = 0; i < polygon.size(); ++i) {
        area += polygon[j].x * polygon[i].y - polygon[i].x * polygon[j].y;
        j = i;
    }
    return area * 0.5f;
}

Polygon normalizeHullWindingAndCleanup(const Polygon& hull) {
    if (hull.size() < 3) return hull;
    Polygon cleaned;
    for (const Vec2& p : hull) {
        if (cleaned.empty() || !(length(cleaned.back() - p) < 0.5f)) cleaned.push_back(p);
    }
    if (cleaned.size() < 3) return hull;
    if (polygonArea(cleaned) < 0) std::reverse(cleaned.begin(), cleaned.end());
    return cleaned;
}

// Removes the shallowest concave notch, again and again, until none is
// shallower than the threshold `concavity` implies (0: convex hull, 100:
// keep every notch). The hull is CCW.
Polygon filterConcavities(const Polygon& hull, float concavity, float maxDimension) {
    if (hull.size() < 4) return hull;
    const float c = std::max(0.0f, std::min(100.0f, concavity));
    if (c >= 99.9f) return hull;
    const float t = 1.0f - c / 100.0f;
    const float threshold = t * t * maxDimension * 0.35f;
    Polygon result = hull;
    bool changed = true;
    while (changed && result.size() >= 4) {
        changed = false;
        int shallowestIdx = -1;
        float shallowestDepth = threshold;
        const std::size_t n = result.size();
        for (std::size_t i = 0; i < n; ++i) {
            const Vec2 prev = result[(i + n - 1) % n], curr = result[i], next = result[(i + 1) % n];
            const float cross = (curr.x - prev.x) * (next.y - curr.y) - (curr.y - prev.y) * (next.x - curr.x);
            if (!(cross < 0)) continue;
            const Vec2 chord = next - prev;
            const float chordLen = length(chord);
            const float depth = chordLen > 0.001f ? std::fabs(dot(curr - prev, Vec2(-chord.y, chord.x)) / chordLen)
                                                  : length(curr - prev);
            if (depth < shallowestDepth) {
                shallowestDepth = depth;
                shallowestIdx = static_cast<int>(i);
            }
        }
        if (shallowestIdx >= 0) {
            result.erase(result.begin() + shallowestIdx);
            changed = true;
        }
    }
    return result.size() >= 3 ? result : hull;
}

// One component's outline: trace -> smooth -> RDP -> pad -> CCW -> notches.
std::optional<Polygon> simplifiedHullFromComponentMask(const std::vector<bool>& componentMask, int width, int height,
                                                       const Vec2& size, float detail, float padding,
                                                       float concavity) {
    const Polygon contourPixels = traceBoundaryPixels(componentMask, width, height);
    if (contourPixels.empty()) return std::nullopt;
    Polygon contourLocal;
    contourLocal.reserve(contourPixels.size());
    for (const Vec2& pixel : contourPixels) {
        const float px = std::min(std::max(pixel.x, 0.0f), static_cast<float>(width));
        const float py = std::min(std::max(pixel.y, 0.0f), static_cast<float>(height));
        contourLocal.push_back(Vec2(px - size.x * 0.5f, size.y * 0.5f - py));
    }
    const float clampedDetail = std::max(10.0f, std::min(100.0f, detail));
    const float detailT = (clampedDetail - 10.0f) / 90.0f;
    Vec2 minP(FLT_MAX, FLT_MAX), maxP(-FLT_MAX, -FLT_MAX);
    for (const Vec2& p : contourLocal) {
        minP = Vec2(std::min(minP.x, p.x), std::min(minP.y, p.y));
        maxP = Vec2(std::max(maxP.x, p.x), std::max(maxP.y, p.y));
    }
    const float shapeMaxDim = std::max(1.0f, std::max(maxP.x - minP.x, maxP.y - minP.y));
    const float minEpsilon = 0.6f;
    const float maxEpsilon = std::max(minEpsilon * 4.0f, shapeMaxDim * 0.04f);
    const float epsilon = maxEpsilon * std::pow(minEpsilon / maxEpsilon, detailT);

    const Polygon smoothed = smoothContour(contourLocal, 1);
    const Polygon simplified = simplifyHullRDP(smoothed, epsilon);
    const Polygon usable = simplified.size() >= 3 ? simplified : contourLocal;
    if (usable.size() < 3) return std::nullopt;

    const float outwardMargin = std::max(0.0f, std::min(4.0f, padding));
    Polygon hull = outwardMargin > 0 ? expandPolygonOutward(usable, outwardMargin) : usable;
    hull = normalizeHullWindingAndCleanup(hull);
    if (hull.size() < 3) return std::nullopt;
    hull = filterConcavities(hull, concavity, std::max(size.x, size.y));
    if (hull.size() < 3) return std::nullopt;
    return hull;
}

Polygon simplifyHull(const Polygon& points, float minimumDistance) {
    if (points.empty()) return {};
    Polygon simplified{points.front()};
    for (std::size_t i = 1; i < points.size(); ++i) {
        if (length(points[i] - simplified.back()) >= minimumDistance) simplified.push_back(points[i]);
    }
    if (simplified.size() > 2 && length(simplified.front() - simplified.back()) < minimumDistance) simplified.pop_back();
    return simplified;
}

// The fallback when no component yields an outline: rays from the
// alpha-weighted centre, each stopping at the farthest opaque pixel.
Polygon legacyRadialHullSamples(const Vec2& size, int width, int height, const Vec2& center, float alphaThreshold,
                                const AlphaMask& alpha) {
    const int detail = std::max(20, std::min(64, static_cast<int>(std::ceil(static_cast<float>(width + height) / 52.0f))));
    const int maxDistance = static_cast<int>(std::max(size.x, size.y));
    Polygon samples;
    for (int step = 0; step < detail; ++step) {
        const float angle = (static_cast<float>(step) / static_cast<float>(detail)) * (3.14159265358979323846f * 2.0f);
        const Vec2 direction(std::cos(angle), std::sin(angle));
        std::optional<Vec2> hit;
        for (int distance = maxDistance; distance >= 1; --distance) {
            const Vec2 point = center + direction * static_cast<float>(distance);
            const int x = roundedInt(point.x), y = roundedInt(point.y);
            if (x < 0 || x >= width || y < 0 || y >= height) continue;
            if (alpha.at(x, y) > alphaThreshold) {
                hit = Vec2(static_cast<float>(x), static_cast<float>(y));
                break;
            }
        }
        if (hit.has_value()) {
            const Vec2 local(hit->x - size.x * 0.5f, size.y * 0.5f - hit->y);
            if (samples.empty() || length(samples.back() - local) > 2.5f) samples.push_back(local);
        }
    }
    const Polygon simplified = simplifyHull(samples, 4.0f);
    return simplified.size() >= 3 ? simplified : samples;
}

// Joins `secondary` to `primary` at their closest vertex pair with a
// bridge that has WIDTH: the return leg runs half a pixel beside the
// outbound one. A zero-width bridge repeated both anchors, the kernel's
// ring check refused the outline, and a sprite holding two shapes silently
// stopped accepting nodes for the rest of the session.
Polygon bridgeTwoHulls(const Polygon& primary, const Polygon& secondary) {
    if (primary.size() < 3) return secondary;
    if (secondary.size() < 3) return primary;
    std::size_t bestI = 0, bestJ = 0;
    float bestDist = FLT_MAX;
    for (std::size_t i = 0; i < primary.size(); ++i) {
        for (std::size_t j = 0; j < secondary.size(); ++j) {
            const float d = length(primary[i] - secondary[j]);
            if (d < bestDist) {
                bestDist = d;
                bestI = i;
                bestJ = j;
            }
        }
    }
    const float bridgeWidth = 0.5f;
    const Vec2 anchor = primary[bestI], landing = secondary[bestJ];
    const Vec2 span = landing - anchor;
    const float spanLength = length(span);
    const Vec2 offset = spanLength > 0.000001f ? Vec2(-span.y, span.x) / spanLength * bridgeWidth : Vec2::zero();
    Polygon result;
    for (std::size_t k = 0; k <= bestI; ++k) result.push_back(primary[k]);
    for (std::size_t k = 0; k < secondary.size(); ++k) result.push_back(secondary[(bestJ + k) % secondary.size()]);
    result.push_back(landing + offset);
    result.push_back(anchor + offset);
    for (std::size_t k = bestI + 1; k < primary.size(); ++k) result.push_back(primary[k]);
    return result;
}

Polygon stitchHullsViaKeyhole(const std::vector<Polygon>& hulls) {
    if (hulls.empty()) return {};
    Polygon combined = hulls.front();
    for (std::size_t i = 1; i < hulls.size(); ++i) combined = bridgeTwoHulls(combined, hulls[i]);
    return combined;
}

} // namespace

// Drops every triangle that crosses visibly transparent pixels: all three
// edges must be at least 92% opaque and touch no clearly empty pixel, and
// enough of seven interior samples must be opaque.
std::vector<std::uint16_t> Mesh::filterTrianglesToOpaqueArea(const std::vector<std::uint16_t>& triangles,
                                                             const Vec2& size, const AlphaMask& alpha,
                                                             float alphaThreshold, int minOpaqueSamples) const {
    if (triangles.size() < 3 || !(size.x > 1) || !(size.y > 1)) return triangles;
    const int width = std::max(roundedInt(size.x), 1);
    const int height = std::max(roundedInt(size.y), 1);
    const int requiredSamples = std::max(1, std::min(7, minOpaqueSamples));

    auto alphaAt = [&](const Vec2& point) {
        const int px = std::max(0, std::min(width - 1, roundedInt(point.x + size.x * 0.5f)));
        const int py = std::max(0, std::min(height - 1, roundedInt(size.y * 0.5f - point.y)));
        return alpha.at(px, py);
    };
    auto opaqueRatio = [&](const Vec2& p0, const Vec2& p1, int samples) {
        if (samples <= 1) return alphaAt((p0 + p1) * 0.5f) > alphaThreshold ? 1.0f : 0.0f;
        int opaque = 0;
        for (int i = 0; i < samples; ++i) {
            const float t = static_cast<float>(i) / static_cast<float>(samples - 1);
            if (alphaAt(p0 + (p1 - p0) * t) > alphaThreshold) opaque += 1;
        }
        return static_cast<float>(opaque) / static_cast<float>(samples);
    };
    const float emptyAlpha = 0.05f;
    auto crossesEmpty = [&](const Vec2& p0, const Vec2& p1, int samples) {
        const int n = std::max(samples, 2);
        for (int i = 0; i < n; ++i) {
            const float t = static_cast<float>(i) / static_cast<float>(n - 1);
            if (alphaAt(p0 + (p1 - p0) * t) < emptyAlpha) return true;
        }
        return false;
    };

    std::vector<std::uint16_t> filtered;
    for (std::size_t t = 0; t + 2 < triangles.size(); t += 3) {
        const std::size_t ia = triangles[t], ib = triangles[t + 1], ic = triangles[t + 2];
        if (ia >= vertices.size() || ib >= vertices.size() || ic >= vertices.size()) continue;
        const Vec2 a = vertices[ia], b = vertices[ib], c = vertices[ic];
        const int edgeSamples = 21;
        const float minEdgeOpaqueRatio = 0.92f;
        if (opaqueRatio(a, b, edgeSamples) < minEdgeOpaqueRatio || opaqueRatio(b, c, edgeSamples) < minEdgeOpaqueRatio ||
            opaqueRatio(c, a, edgeSamples) < minEdgeOpaqueRatio) {
            continue;
        }
        if (crossesEmpty(a, b, edgeSamples) || crossesEmpty(b, c, edgeSamples) || crossesEmpty(c, a, edgeSamples)) {
            continue;
        }
        const Vec2 samplePoints[7] = {(a + b + c) / 3.0f,          a * 0.6f + b * 0.2f + c * 0.2f,
                                      a * 0.2f + b * 0.6f + c * 0.2f, a * 0.2f + b * 0.2f + c * 0.6f,
                                      (a + b) * 0.5f,               (b + c) * 0.5f,
                                      (c + a) * 0.5f};
        int opaqueCount = 0;
        for (const Vec2& p : samplePoints) {
            if (alphaAt(p) > alphaThreshold) opaqueCount += 1;
        }
        if (opaqueCount >= requiredSamples) filtered.insert(filtered.end(), {triangles[t], triangles[t + 1], triangles[t + 2]});
    }
    return filtered;
}

Mesh Mesh::tracedHull(const Vec2& size, const AlphaMask& alpha, float detail, float padding, float concavity,
                      float alphaThreshold) const {
    const int width = std::max(roundedInt(size.x), 1);
    const int height = std::max(roundedInt(size.y), 1);
    std::vector<bool> mask(static_cast<std::size_t>(width * height), false);
    int occupiedCount = 0;
    Vec2 weightedCenter = Vec2::zero();
    float weightSum = 0.0f;
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const float a = alpha.at(x, y);
            const bool solid = a > alphaThreshold;
            mask[static_cast<std::size_t>(y * width + x)] = solid;
            if (solid) {
                occupiedCount += 1;
                weightedCenter = weightedCenter + Vec2(static_cast<float>(x), static_cast<float>(y)) * a;
                weightSum += a;
            }
        }
    }
    if (occupiedCount == 0) return resetToQuad(size);

    // EVERY component, not just the largest (two eyes in one PNG are two
    // shapes); anything under 5% of the largest is noise.
    std::vector<std::vector<int>> components = findConnectedComponents(mask, width, height);
    std::stable_sort(components.begin(), components.end(),
                     [](const auto& a, const auto& b) { return a.size() > b.size(); });
    if (components.empty()) return resetToQuad(size);
    const std::size_t minComponentSize =
        static_cast<std::size_t>(std::max(8, static_cast<int>(static_cast<float>(components.front().size()) * 0.05f)));

    std::vector<Polygon> componentHulls;
    for (const auto& component : components) {
        if (component.size() < minComponentSize) continue;
        std::vector<bool> componentMask(mask.size(), false);
        for (int idx : component) componentMask[static_cast<std::size_t>(idx)] = true;
        const auto hull = simplifiedHullFromComponentMask(componentMask, width, height, size, detail, padding, concavity);
        if (hull.has_value() && hull->size() >= 3) componentHulls.push_back(*hull);
    }

    Polygon finalHull;
    if (componentHulls.empty()) {
        if (!(weightSum > 0)) return resetToQuad(size);
        const Polygon radial =
            legacyRadialHullSamples(size, width, height, weightedCenter / weightSum, alphaThreshold, alpha);
        if (radial.size() < 3) return resetToQuad(size);
        finalHull = radial;
    } else if (componentHulls.size() == 1) {
        finalHull = componentHulls.front();
    } else {
        // Keyhole bridges cross transparent space, so the opaque-area filter
        // below drops the triangles spanning them.
        finalHull = stitchHullsViaKeyhole(componentHulls);
    }

    // A fresh mesh, as Swift's memberwise init makes one.
    Mesh mesh(name);
    mesh.vertices = finalHull;
    for (const Vec2& v : finalHull) mesh.uvs.push_back(uvFor(v, size));
    for (std::size_t i = 0; i < finalHull.size(); ++i) mesh.hullVertexIndices.push_back(static_cast<std::uint16_t>(i));
    const std::vector<std::uint16_t> hullTriangles = mesh.triangulatedHullIndices();
    // Stricter than the boundary's 0.08: a triangle edge travelling over
    // alpha below one half is visibly crossing transparency.
    const float visibleThreshold = std::max(alphaThreshold, 0.5f);
    const std::vector<std::uint16_t> filtered =
        mesh.filterTrianglesToOpaqueArea(hullTriangles, size, alpha, visibleThreshold, 6);
    mesh.indices = filtered.empty() ? hullTriangles : filtered;
    return mesh;
}

} // namespace umeshcore
