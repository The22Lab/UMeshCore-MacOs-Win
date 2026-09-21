#include "umeshcore/Mesh/MeshKernel.h"

#include <algorithm>
#include <limits>
#include <unordered_map>
#include <unordered_set>

#include "umeshcore/Mesh/MeshPredicates.h"
#include "umeshcore/Mesh/MeshTypes.h"

namespace umeshcore::MeshKernel {

double signedArea2(const std::vector<Vec2>& points, const std::vector<int>& ring) {
    double total = 0.0;
    const int n = static_cast<int>(ring.size());
    for (int i = 0; i < n; ++i) {
        const Vec2& p1 = points[ring[i]];
        const Vec2& p2 = points[ring[(i + 1) % n]];
        total += static_cast<double>(p1.x) * static_cast<double>(p2.y) -
                 static_cast<double>(p2.x) * static_cast<double>(p1.y);
    }
    return total;
}

double polygonArea(const std::vector<Vec2>& points, const std::vector<int>& ring) {
    return std::abs(signedArea2(points, ring)) / 2.0;
}

bool pointInRing(const std::vector<Vec2>& points, const std::vector<int>& ring, const Vec2& p) {
    bool inside = false;
    const int n = static_cast<int>(ring.size());
    const double px = p.x, py = p.y;
    for (int i = 0; i < n; ++i) {
        const Vec2& a = points[ring[i]];
        const Vec2& b = points[ring[(i + 1) % n]];
        const double x1 = a.x, y1 = a.y, x2 = b.x, y2 = b.y;
        if ((y1 > py) != (y2 > py)) {
            const double xint = (x2 - x1) * (py - y1) / (y2 - y1) + x1;
            if (px < xint) inside = !inside;
        }
    }
    return inside;
}

bool pointInTriangle(const std::vector<Vec2>& points, int ia, int ib, int ic, const Vec2& p) {
    const double d1 = MeshPredicates::orient2d(points[ia], points[ib], p);
    const double d2 = MeshPredicates::orient2d(points[ib], points[ic], p);
    const double d3 = MeshPredicates::orient2d(points[ic], points[ia], p);
    const bool hasNegative = d1 < 0.0 || d2 < 0.0 || d3 < 0.0;
    const bool hasPositive = d1 > 0.0 || d2 > 0.0 || d3 > 0.0;
    return !(hasNegative && hasPositive);
}

namespace {

void validateRing(const std::vector<Vec2>& points, const std::vector<int>& ring, bool isHole) {
    const Failure failKind = isHole ? Failure::HoleRingSelfIntersecting : Failure::RingSelfIntersecting;
    {
        std::unordered_set<int> seen(ring.begin(), ring.end());
        if (seen.size() != ring.size()) throw TriangulationError(failKind);
    }
    for (int index : ring) {
        if (index < 0 || static_cast<std::size_t>(index) >= points.size()) {
            throw TriangulationError(failKind);
        }
    }

    const int n = static_cast<int>(ring.size());
    for (int i = 0; i < n; ++i) {
        const Vec2 a1 = points[ring[i]];
        const Vec2 a2 = points[ring[(i + 1) % n]];
        if (a1 == a2) throw TriangulationError(failKind);

        // Consecutive edges may run straight on (180deg, harmless) but must
        // not fold back over each other -- see the Swift source's comment
        // on how a folded-back middle vertex silently disappears otherwise.
        const Vec2 c = points[ring[(i + 2) % n]];
        if (MeshPredicates::orient2d(a1, a2, c) == 0.0) {
            const double back = (static_cast<double>(c.x) - static_cast<double>(a2.x)) *
                                     (static_cast<double>(a1.x) - static_cast<double>(a2.x)) +
                                 (static_cast<double>(c.y) - static_cast<double>(a2.y)) *
                                     (static_cast<double>(a1.y) - static_cast<double>(a2.y));
            if (back > 0.0) {
                throw TriangulationError(isHole ? Failure::HoleRingSelfIntersecting : Failure::RingFoldsBack);
            }
        }

        for (int j = i + 1; j < n; ++j) {
            if (j == i + 1 || (i == 0 && j == n - 1)) continue; // shares a corner
            const Vec2 b1 = points[ring[j]];
            const Vec2 b2 = points[ring[(j + 1) % n]];
            if (MeshPredicates::segmentsTouchOrCross(a1, a2, b1, b2)) {
                throw TriangulationError(failKind);
            }
        }
    }
}

// True when the segment ring[i] -> ring[j] leaves vertex i into the
// interior (O'Rourke's cone test).
bool inCone(const std::vector<Vec2>& points, const std::vector<int>& ring, int i, int j) {
    const int n = static_cast<int>(ring.size());
    const Vec2& a0 = points[ring[i == 0 ? n - 1 : i - 1]];
    const Vec2& a = points[ring[i]];
    const Vec2& a1 = points[ring[(i + 1) % n]];
    const Vec2& b = points[ring[j]];

    if (MeshPredicates::orient2d(a, a1, a0) >= 0.0) { // convex or collinear
        return MeshPredicates::orient2d(a, b, a0) > 0.0 && MeshPredicates::orient2d(b, a, a1) > 0.0;
    }
    return !(MeshPredicates::orient2d(a, b, a1) >= 0.0 && MeshPredicates::orient2d(b, a, a0) >= 0.0);
}

// True when the segment ring[i] -> ring[j] meets the ring only at its ends.
bool diagonalIsClear(const std::vector<Vec2>& points, const std::vector<int>& ring, int i, int j) {
    const int n = static_cast<int>(ring.size());
    const Vec2& a = points[ring[i]];
    const Vec2& b = points[ring[j]];
    for (int k = 0; k < n; ++k) {
        const int k2 = (k + 1) % n;
        const Vec2& c = points[ring[k]];
        const Vec2& d = points[ring[k2]];
        if (k != i && k != j && k2 != i && k2 != j) {
            if (MeshPredicates::segmentsProperlyIntersect(a, b, c, d)) return false;
        }
        // A third vertex sitting exactly on the diagonal would end up on the
        // boundary edge of both halves -- the orphaning this fixes.
        if (k != i && k != j && !(c == a) && !(c == b) && MeshPredicates::pointOnSegment(c, a, b)) {
            return false;
        }
    }
    return true;
}

std::optional<std::tuple<int, int, int>> wound(const std::vector<Vec2>& points, int a, int b, int c) {
    const double area = MeshPredicates::orient2d(points[a], points[b], points[c]);
    if (area == 0.0) return std::nullopt;
    return area > 0.0 ? std::make_tuple(a, b, c) : std::make_tuple(a, c, b);
}

// Forward decl: earClipCounterClockwise recurses into itself when it must
// split the ring on a diagonal.
std::vector<int> earClipCounterClockwise(const std::vector<Vec2>& points, const std::vector<int>& idx);

} // namespace

std::optional<std::pair<int, int>> findDiagonal(const std::vector<Vec2>& points, const std::vector<int>& ring) {
    const int n = static_cast<int>(ring.size());
    if (n < 4) return std::nullopt;

    std::vector<std::tuple<double, int, int>> candidates;
    for (int i = 0; i < n; ++i) {
        for (int j = i + 2; j < n; ++j) {
            if (i == 0 && j == n - 1) continue; // adjacent the other way round
            const Vec2& pa = points[ring[i]];
            const Vec2& pb = points[ring[j]];
            if (pa == pb) continue;
            const double dx = static_cast<double>(pa.x) - static_cast<double>(pb.x);
            const double dy = static_cast<double>(pa.y) - static_cast<double>(pb.y);
            candidates.emplace_back(dx * dx + dy * dy, i, j);
        }
    }
    // Swift's Array.sort() has been a stable sort since Swift 5.
    std::stable_sort(candidates.begin(), candidates.end(), [](const auto& a, const auto& b) {
        return std::get<0>(a) < std::get<0>(b);
    });

    for (const auto& candidate : candidates) {
        const int i = std::get<1>(candidate);
        const int j = std::get<2>(candidate);
        // Cone first: it is O(1) and rejects most pairs.
        if (!inCone(points, ring, i, j) || !inCone(points, ring, j, i)) continue;
        if (!diagonalIsClear(points, ring, i, j)) continue;
        // Midpoint containment catches the one case the local tests cannot:
        // a chord that leaves and re-enters through the same pocket of a
        // very concave outline.
        const Vec2& a = points[ring[i]];
        const Vec2& b = points[ring[j]];
        const Vec2 mid((a.x + b.x) * 0.5f, (a.y + b.y) * 0.5f);
        if (!pointInRing(points, ring, mid)) continue;
        return std::make_pair(i, j);
    }
    return std::nullopt;
}

namespace {

std::vector<int> earClipCounterClockwise(const std::vector<Vec2>& points, const std::vector<int>& idx) {
    const int n = static_cast<int>(idx.size());
    if (n < 3) return {};
    if (n == 3) {
        if (MeshPredicates::orient2d(points[idx[0]], points[idx[1]], points[idx[2]]) != 0.0) {
            return idx;
        }
        return {};
    }

    std::vector<int> prev(n), next(n);
    for (int i = 0; i < n; ++i) {
        prev[i] = (i + n - 1) % n;
        next[i] = (i + 1) % n;
    }
    std::vector<bool> alive(n, true);

    auto isEar = [&](int i) -> bool {
        const int a = prev[i], b = i, c = next[i];
        if (!(MeshPredicates::orient2d(points[idx[a]], points[idx[b]], points[idx[c]]) > 0.0)) {
            return false; // reflex or degenerate, not an ear
        }
        // Containment is closed on purpose: a vertex lying exactly on the
        // base of the ear must block it (see Swift source comment).
        for (int k = 0; k < n; ++k) {
            if (!alive[k] || k == a || k == b || k == c) continue;
            if (pointInTriangle(points, idx[a], idx[b], idx[c], points[idx[k]])) return false;
        }
        return true;
    };

    std::vector<int> out;
    out.reserve(static_cast<std::size_t>(n - 2) * 3);

    int remaining = n;
    int cur = 0;
    int misses = 0;

    while (remaining > 3) {
        if (misses > remaining) break; // no ear anywhere: fall through to the split
        if (!alive[cur]) {
            cur = next[cur];
            continue;
        }

        if (isEar(cur)) {
            const int a = prev[cur], b = cur, c = next[cur];
            out.push_back(idx[a]);
            out.push_back(idx[b]);
            out.push_back(idx[c]);
            alive[cur] = false;
            next[a] = c;
            prev[c] = a;
            remaining -= 1;
            misses = 0;
            cur = a; // the neighbourhood changed; retry here
        } else {
            misses += 1;
            cur = next[cur];
        }
    }

    if (remaining > 3) {
        // No strictly convex ear anywhere -- split on a valid interior
        // diagonal instead, keeping every vertex.
        int start = -1;
        for (int i = 0; i < n; ++i) {
            if (alive[i]) { start = i; break; }
        }
        if (start < 0) throw TriangulationError(Failure::CannotTileWithoutLosingVertex);

        std::vector<int> stuck;
        int pos = start;
        do {
            stuck.push_back(idx[pos]);
            pos = next[pos];
        } while (pos != start);

        auto split = findDiagonal(points, stuck);
        if (!split.has_value()) {
            // Nothing left that keeps every vertex. Refusing is the right
            // escalation: the caller leaves the mesh untouched.
            throw TriangulationError(Failure::CannotTileWithoutLosingVertex);
        }
        const int i = split->first;
        const int j = split->second;
        std::vector<int> ringA(stuck.begin() + i, stuck.begin() + j + 1); // stuck[i...j]
        std::vector<int> ringB;
        ringB.insert(ringB.end(), stuck.begin() + j, stuck.end());       // stuck[j...]
        ringB.insert(ringB.end(), stuck.begin(), stuck.begin() + i + 1); // stuck[...i]

        // `out` already holds the ears clipped before the ring got stuck;
        // dropping it here would punch exactly the hole this type prevents.
        std::vector<int> halfA = earClipCounterClockwise(points, ringA);
        std::vector<int> halfB = earClipCounterClockwise(points, ringB);
        std::vector<int> result = out;
        result.insert(result.end(), halfA.begin(), halfA.end());
        result.insert(result.end(), halfB.begin(), halfB.end());
        return result;
    }

    // Three vertices left: emit the last triangle unless it is degenerate.
    int start = -1;
    for (int i = 0; i < n; ++i) {
        if (alive[i]) { start = i; break; }
    }
    if (start >= 0) {
        std::vector<int> last;
        int pos = start;
        for (int k = 0; k < 3; ++k) {
            last.push_back(idx[pos]);
            pos = next[pos];
        }
        if (MeshPredicates::orient2d(points[last[0]], points[last[1]], points[last[2]]) != 0.0) {
            out.insert(out.end(), last.begin(), last.end());
        }
    }

    return out;
}

} // namespace

std::vector<int> bridgeHoles(
    const std::vector<Vec2>& points, const std::vector<int>& outer,
    const std::vector<std::vector<int>>& holes) {
    std::vector<int> ring = outer;
    std::vector<std::vector<int>> remaining = holes;

    while (!remaining.empty()) {
        // Take the hole whose closest approach to the current ring is
        // smallest, so an early bridge cannot box in a later one.
        double bestDistance = std::numeric_limits<double>::infinity();
        std::size_t bestHole = 0;
        int bestRingPos = 0;
        int bestHolePos = 0;

        for (std::size_t holeIndex = 0; holeIndex < remaining.size(); ++holeIndex) {
            const auto& hole = remaining[holeIndex];
            for (std::size_t ringPos = 0; ringPos < ring.size(); ++ringPos) {
                const Vec2& a = points[ring[ringPos]];
                for (std::size_t holePos = 0; holePos < hole.size(); ++holePos) {
                    const Vec2& b = points[hole[holePos]];
                    const double dx = static_cast<double>(a.x - b.x);
                    const double dy = static_cast<double>(a.y - b.y);
                    const double d = dx * dx + dy * dy;
                    if (d < bestDistance) {
                        bestDistance = d;
                        bestHole = holeIndex;
                        bestRingPos = static_cast<int>(ringPos);
                        bestHolePos = static_cast<int>(holePos);
                    }
                }
            }
        }

        std::vector<int> hole = remaining[bestHole];
        remaining.erase(remaining.begin() + static_cast<std::ptrdiff_t>(bestHole));

        // Walk the hole from its bridge point all the way round and back,
        // then return along the channel to the outer ring.
        std::vector<int> rotated;
        rotated.reserve(hole.size() + 1);
        rotated.insert(rotated.end(), hole.begin() + bestHolePos, hole.end());
        rotated.insert(rotated.end(), hole.begin(), hole.begin() + bestHolePos);
        rotated.push_back(hole[static_cast<std::size_t>(bestHolePos)]);

        std::vector<int> newRing;
        newRing.reserve(ring.size() + rotated.size());
        newRing.insert(newRing.end(), ring.begin(), ring.begin() + bestRingPos + 1);
        newRing.insert(newRing.end(), rotated.begin(), rotated.end());
        newRing.insert(newRing.end(), ring.begin() + bestRingPos, ring.end());
        ring = std::move(newRing);
    }

    return ring;
}

std::vector<int> absorbOrphanRingVertices(
    const std::vector<Vec2>& points, const std::vector<int>& ring, const std::vector<int>& triangles) {
    std::unordered_set<int> used(triangles.begin(), triangles.end());
    std::unordered_set<int> seen;
    std::vector<int> orphans;
    for (int v : ring) {
        if (seen.insert(v).second && !used.contains(v)) orphans.push_back(v);
    }
    if (orphans.empty()) return triangles;

    std::vector<int> result = triangles;
    for (int v : orphans) {
        const Vec2 p = points[static_cast<std::size_t>(v)];
        std::vector<int> rebuilt;
        rebuilt.reserve(result.size() + 3);
        bool placed = false;

        for (std::size_t t = 0; t < result.size(); t += 3) {
            const int ia = result[t], ib = result[t + 1], ic = result[t + 2];
            std::optional<std::tuple<int, int, int>> split;

            const std::tuple<int, int, int> rotations[3] = {{ia, ib, ic}, {ib, ic, ia}, {ic, ia, ib}};
            for (const auto& rotation : rotations) {
                const int u = std::get<0>(rotation), w = std::get<1>(rotation), x = std::get<2>(rotation);
                if (u == v || w == v || x == v) continue;
                if (points[static_cast<std::size_t>(u)] == p || points[static_cast<std::size_t>(w)] == p) continue;
                if (!MeshPredicates::pointOnSegment(
                        p, points[static_cast<std::size_t>(u)], points[static_cast<std::size_t>(w)])) {
                    continue;
                }
                // Skip a split that would be degenerate; leave it alone.
                if (MeshPredicates::orient2d(points[static_cast<std::size_t>(u)], p, points[static_cast<std::size_t>(x)]) == 0.0 ||
                    MeshPredicates::orient2d(p, points[static_cast<std::size_t>(w)], points[static_cast<std::size_t>(x)]) == 0.0) {
                    continue;
                }
                split = std::make_tuple(u, w, x);
                break;
            }

            if (split.has_value()) {
                const int u = std::get<0>(*split), w = std::get<1>(*split), x = std::get<2>(*split);
                rebuilt.push_back(u);
                rebuilt.push_back(v);
                rebuilt.push_back(x);
                rebuilt.push_back(v);
                rebuilt.push_back(w);
                rebuilt.push_back(x);
                placed = true;
            } else {
                rebuilt.push_back(ia);
                rebuilt.push_back(ib);
                rebuilt.push_back(ic);
            }
        }

        if (placed) result = rebuilt;
    }
    return result;
}

std::vector<int> earClip(const std::vector<Vec2>& points, const std::vector<int>& ring) {
    std::vector<int> idx = ring;
    if (signedArea2(points, idx) < 0.0) std::reverse(idx.begin(), idx.end());
    std::vector<int> tiled = earClipCounterClockwise(points, idx);
    return absorbOrphanRingVertices(points, ring, tiled);
}

std::vector<int> splitInsert(
    const std::vector<Vec2>& points, const std::vector<int>& triangles, int pointIndex) {
    const Vec2 p = points[static_cast<std::size_t>(pointIndex)];
    for (std::size_t t = 0; t < triangles.size(); t += 3) {
        const int ia = triangles[t], ib = triangles[t + 1], ic = triangles[t + 2];
        if (!pointInTriangle(points, ia, ib, ic, p)) continue;
        if (p == points[static_cast<std::size_t>(ia)] || p == points[static_cast<std::size_t>(ib)] ||
            p == points[static_cast<std::size_t>(ic)]) {
            return triangles;
        }

        std::vector<int> rebuilt(triangles.begin(), triangles.begin() + static_cast<std::ptrdiff_t>(t));
        rebuilt.insert(rebuilt.end(), triangles.begin() + static_cast<std::ptrdiff_t>(t + 3), triangles.end());
        const std::tuple<int, int, int> candidateTris[3] = {
            {ia, ib, pointIndex}, {ib, ic, pointIndex}, {ic, ia, pointIndex}};
        for (const auto& tri : candidateTris) {
            const int x = std::get<0>(tri), y = std::get<1>(tri), z = std::get<2>(tri);
            if (MeshPredicates::orient2d(
                    points[static_cast<std::size_t>(x)], points[static_cast<std::size_t>(y)],
                    points[static_cast<std::size_t>(z)]) != 0.0) {
                rebuilt.push_back(x);
                rebuilt.push_back(y);
                rebuilt.push_back(z);
            }
        }
        return rebuilt;
    }
    return triangles;
}

std::vector<int> lawsonFlips(
    const std::vector<Vec2>& points, const std::vector<int>& triangles,
    const std::vector<std::pair<int, int>>& constrained, int maxPasses) {
    std::unordered_set<MeshEdge, MeshEdgeHash> constrainedSet;
    for (const auto& [a, b] : constrained) {
        if (a <= std::numeric_limits<std::uint16_t>::max() && b <= std::numeric_limits<std::uint16_t>::max() &&
            a >= 0 && b >= 0) {
            constrainedSet.insert(MeshEdge(static_cast<std::uint16_t>(a), static_cast<std::uint16_t>(b)));
        }
    }

    std::vector<std::tuple<int, int, int>> tris;
    tris.reserve(triangles.size() / 3);
    for (std::size_t t = 0; t < triangles.size(); t += 3) {
        tris.emplace_back(triangles[t], triangles[t + 1], triangles[t + 2]);
    }

    for (int pass = 0; pass < maxPasses; ++pass) {
        std::unordered_map<MeshEdge, std::vector<int>, MeshEdgeHash> edgeOwners;
        edgeOwners.reserve(tris.size() * 3);
        // Swift keeps first-seen order explicitly because Dictionary
        // iteration order is randomized per process; std::unordered_map has
        // the same underspecified-order problem for a different reason, so
        // this explicit `edgeOrder` vector is preserved for the same
        // determinism guarantee, not merely mirroring Swift's rationale.
        std::vector<MeshEdge> edgeOrder;
        edgeOrder.reserve(tris.size() * 3);

        for (std::size_t ti = 0; ti < tris.size(); ++ti) {
            const auto& [ta, tb, tc] = tris[ti];
            const std::pair<int, int> edgesOfTri[3] = {{ta, tb}, {tb, tc}, {tc, ta}};
            for (const auto& [u, v] : edgesOfTri) {
                if (u > std::numeric_limits<std::uint16_t>::max() ||
                    v > std::numeric_limits<std::uint16_t>::max() || u < 0 || v < 0) {
                    continue;
                }
                MeshEdge edge(static_cast<std::uint16_t>(u), static_cast<std::uint16_t>(v));
                auto it = edgeOwners.find(edge);
                if (it == edgeOwners.end()) {
                    edgeOrder.push_back(edge);
                    edgeOwners.emplace(edge, std::vector<int>{static_cast<int>(ti)});
                } else {
                    it->second.push_back(static_cast<int>(ti));
                }
            }
        }

        std::unordered_set<int> dirty;
        int flips = 0;
        for (const MeshEdge& edge : edgeOrder) {
            auto ownersIt = edgeOwners.find(edge);
            if (ownersIt == edgeOwners.end() || ownersIt->second.size() != 2) continue;
            if (constrainedSet.contains(edge)) continue;
            const int t1 = ownersIt->second[0], t2 = ownersIt->second[1];
            if (dirty.contains(t1) || dirty.contains(t2)) continue;
            const int u = edge.a, v = edge.b;

            const auto& tri1 = tris[static_cast<std::size_t>(t1)];
            const auto& tri2 = tris[static_cast<std::size_t>(t2)];
            auto findOther = [&](const std::tuple<int, int, int>& tri) -> std::optional<int> {
                const int vals[3] = {std::get<0>(tri), std::get<1>(tri), std::get<2>(tri)};
                for (int val : vals) {
                    if (val != u && val != v) return val;
                }
                return std::nullopt;
            };
            const auto pOpt = findOther(tri1);
            const auto qOpt = findOther(tri2);
            if (!pOpt.has_value() || !qOpt.has_value() || *pOpt == *qOpt) continue;
            const int p = *pOpt, q = *qOpt;

            // Delaunay test: is q inside the circumcircle of (u, v, p)?
            Vec2 a = points[static_cast<std::size_t>(u)];
            Vec2 b = points[static_cast<std::size_t>(v)];
            const Vec2 c = points[static_cast<std::size_t>(p)];
            if (MeshPredicates::orient2d(a, b, c) < 0.0) std::swap(a, b);
            if (!(MeshPredicates::incircle(a, b, c, points[static_cast<std::size_t>(q)]) > 0.0)) continue;

            // Legal only when the quad is strictly convex, checked with the
            // exact orientation predicate, never the filtered in-circle value.
            if (!MeshPredicates::segmentsProperlyIntersect(
                    points[static_cast<std::size_t>(u)], points[static_cast<std::size_t>(v)],
                    points[static_cast<std::size_t>(p)], points[static_cast<std::size_t>(q)])) {
                continue;
            }

            const auto new1 = wound(points, p, u, q);
            const auto new2 = wound(points, p, q, v);
            if (!new1.has_value() || !new2.has_value()) continue;

            tris[static_cast<std::size_t>(t1)] = *new1;
            tris[static_cast<std::size_t>(t2)] = *new2;
            dirty.insert(t1);
            dirty.insert(t2);
            ++flips;
        }

        if (flips == 0) break;
    }

    std::vector<int> out;
    out.reserve(tris.size() * 3);
    for (const auto& [a, b, c] : tris) {
        out.push_back(a);
        out.push_back(b);
        out.push_back(c);
    }
    return out;
}

std::vector<std::uint16_t> triangulate(
    const std::vector<Vec2>& points, const Boundary& boundary, const std::vector<int>& interior,
    const std::vector<std::pair<int, int>>& constraints, bool improve) {
    if (points.size() > static_cast<std::size_t>(std::numeric_limits<std::uint16_t>::max()) + 1) {
        throw TriangulationError(Failure::TooManyVertices, static_cast<int>(points.size()));
    }
    if (boundary.outer.size() < 3) throw TriangulationError(Failure::RingTooSmall);
    validateRing(points, boundary.outer, false);
    for (const auto& hole : boundary.holes) {
        if (hole.size() < 3) throw TriangulationError(Failure::HoleRingTooSmall);
        validateRing(points, hole, true);
    }

    // Normalise winding: outer counter-clockwise, holes clockwise, so the
    // bridge channel closes correctly and the hole interior stays excluded.
    std::vector<int> outerRing = boundary.outer;
    if (signedArea2(points, outerRing) < 0.0) std::reverse(outerRing.begin(), outerRing.end());

    std::vector<std::vector<int>> holeRings;
    holeRings.reserve(boundary.holes.size());
    for (const auto& hole : boundary.holes) {
        std::vector<int> ring = hole;
        if (signedArea2(points, ring) > 0.0) std::reverse(ring.begin(), ring.end());
        holeRings.push_back(std::move(ring));
    }

    std::vector<int> polygon = holeRings.empty() ? outerRing : bridgeHoles(points, outerRing, holeRings);

    std::vector<int> triangles = earClip(points, polygon);

    for (int index : interior) {
        if (index < 0 || static_cast<std::size_t>(index) >= points.size()) continue;
        triangles = splitInsert(points, triangles, index);
    }

    if (improve) {
        // Ring edges are constraints too: flipping one would cut a corner
        // off the silhouette.
        std::vector<std::pair<int, int>> edges = constraints;
        std::vector<const std::vector<int>*> allRings;
        allRings.push_back(&outerRing);
        for (const auto& hr : holeRings) allRings.push_back(&hr);
        for (const auto* ringPtr : allRings) {
            const auto& ring = *ringPtr;
            for (std::size_t i = 0; i < ring.size(); ++i) {
                edges.emplace_back(ring[i], ring[(i + 1) % ring.size()]);
            }
        }
        triangles = lawsonFlips(points, triangles, edges);
    }

    std::vector<std::uint16_t> result;
    result.reserve(triangles.size());
    for (int t : triangles) result.push_back(static_cast<std::uint16_t>(t));
    return result;
}

} // namespace umeshcore::MeshKernel
