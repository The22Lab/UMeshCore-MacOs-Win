#include "umeshcore/Mesh/MeshValidator.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <unordered_map>
#include <unordered_set>

#include "umeshcore/Mesh/MeshKernel.h"
#include "umeshcore/Mesh/MeshPredicates.h"
#include "umeshcore/Mesh/MeshTypes.h"

namespace umeshcore::MeshValidator {

std::string invariantCode(Invariant i) {
    switch (i) {
        case Invariant::IndexBounds: return "I1";
        case Invariant::Degenerate: return "I2";
        case Invariant::Winding: return "I3";
        case Invariant::Manifold: return "I4";
        case Invariant::BoundaryMatchesRings: return "I5";
        case Invariant::Coverage: return "I7";
        case Invariant::OrphanVertices: return "I8";
        case Invariant::Constraints: return "I9";
        case Invariant::TrianglesInHoles: return "I10";
        case Invariant::IndexCeiling: return "I11";
    }
    return "?";
}

std::string Report::summary() const {
    if (isValid() && warnings.empty()) return "valid";
    std::string out;
    bool first = true;
    for (const auto& [inv, msg] : failures) {
        if (!first) out += "; ";
        out += invariantCode(inv) + ": " + msg;
        first = false;
    }
    for (const auto& [inv, msg] : warnings) {
        if (!first) out += "; ";
        out += invariantCode(inv) + " (warning): " + msg;
        first = false;
    }
    return out;
}

std::string Report::shortStatus() const {
    if (isValid()) {
        if (warnings.empty()) return "Watertight";
        return "Watertight, " + std::to_string(warnings.size()) + " note(s)";
    }
    return std::to_string(failures.size()) + " problem(s)";
}

namespace {
bool edgeIsBefore(const MeshEdge& lhs, const MeshEdge& rhs) {
    return lhs.a != rhs.a ? lhs.a < rhs.a : lhs.b < rhs.b;
}
} // namespace

Report validate(
    const std::vector<Vec2>& points, const std::vector<std::uint16_t>& triangles,
    const std::vector<int>& outer, const std::vector<std::vector<int>>& holes,
    const std::vector<std::pair<int, int>>& constraints, double coverageTolerance) {
    Report report;
    const std::size_t n = points.size();

    // I1 -- index bounds and triangle count.
    if (triangles.size() % 3 != 0) {
        report.fail(
            Invariant::IndexBounds,
            "triangle list length " + std::to_string(triangles.size()) + " is not a multiple of 3");
        return report;
    }
    for (std::uint16_t index : triangles) {
        if (static_cast<std::size_t>(index) >= n) {
            report.fail(
                Invariant::IndexBounds,
                "index " + std::to_string(index) + " out of range (0.." + std::to_string(n - 1) + ")");
            return report;
        }
    }

    std::vector<std::tuple<int, int, int>> tris;
    tris.reserve(triangles.size() / 3);
    for (std::size_t t = 0; t < triangles.size(); t += 3) {
        tris.emplace_back(triangles[t], triangles[t + 1], triangles[t + 2]);
    }

    // I2 -- no degenerate triangles, and no repeated vertex within one.
    for (const auto& [a, b, c] : tris) {
        if (a == b || b == c || a == c) {
            report.fail(
                Invariant::Degenerate,
                "triangle (" + std::to_string(a) + "," + std::to_string(b) + "," + std::to_string(c) +
                    ") repeats a vertex");
        } else if (MeshPredicates::orient2d(points[a], points[b], points[c]) == 0.0) {
            report.fail(
                Invariant::Degenerate,
                "triangle (" + std::to_string(a) + "," + std::to_string(b) + "," + std::to_string(c) +
                    ") has zero area");
        }
    }

    // I3 -- consistent winding.
    {
        std::unordered_set<int> signs;
        for (const auto& [a, b, c] : tris) {
            const double o = MeshPredicates::orient2d(points[a], points[b], points[c]);
            if (o != 0.0) signs.insert(o > 0.0 ? 1 : -1);
        }
        if (signs.size() > 1) {
            report.fail(Invariant::Winding, "triangles do not share a consistent winding");
        }
    }

    // I4 -- manifold: every undirected edge used once (boundary) or twice (interior).
    std::unordered_map<MeshEdge, int, MeshEdgeHash> edgeCount;
    edgeCount.reserve(tris.size() * 3);
    for (const auto& [a, b, c] : tris) {
        const std::pair<int, int> edges[3] = {{a, b}, {b, c}, {c, a}};
        for (const auto& [u, v] : edges) {
            edgeCount[MeshEdge(static_cast<std::uint16_t>(u), static_cast<std::uint16_t>(v))] += 1;
        }
    }
    {
        std::vector<MeshEdge> overused;
        for (const auto& [edge, count] : edgeCount) {
            if (count > 2) overused.push_back(edge);
        }
        if (!overused.empty()) {
            const MeshEdge first = *std::min_element(overused.begin(), overused.end(), edgeIsBefore);
            report.fail(
                Invariant::Manifold,
                std::to_string(overused.size()) + " edge(s) shared by more than 2 triangles, e.g. (" +
                    std::to_string(first.a) + "," + std::to_string(first.b) + ")");
        }
    }

    // I5 -- the boundary of the triangulation is exactly the ring set.
    std::unordered_set<MeshEdge, MeshEdgeHash> boundary;
    for (const auto& [edge, count] : edgeCount) {
        if (count == 1) boundary.insert(edge);
    }
    std::unordered_set<MeshEdge, MeshEdgeHash> expected;
    {
        std::vector<const std::vector<int>*> allRings;
        allRings.push_back(&outer);
        for (const auto& h : holes) allRings.push_back(&h);
        for (const auto* ringPtr : allRings) {
            const auto& ring = *ringPtr;
            if (ring.size() < 2) continue;
            for (std::size_t i = 0; i < ring.size(); ++i) {
                expected.insert(MeshEdge(
                    static_cast<std::uint16_t>(ring[i]),
                    static_cast<std::uint16_t>(ring[(i + 1) % ring.size()])));
            }
        }
    }
    {
        std::vector<MeshEdge> missing;
        for (const auto& e : expected) {
            if (!boundary.contains(e)) missing.push_back(e);
        }
        std::vector<MeshEdge> extra;
        for (const auto& e : boundary) {
            if (!expected.contains(e)) extra.push_back(e);
        }
        if (!missing.empty()) {
            const MeshEdge first = *std::min_element(missing.begin(), missing.end(), edgeIsBefore);
            report.fail(
                Invariant::BoundaryMatchesRings,
                std::to_string(missing.size()) + " outline edge(s) are not on the mesh boundary, e.g. (" +
                    std::to_string(first.a) + "," + std::to_string(first.b) +
                    ") -- this is a hole or a torn edge");
        }
        if (!extra.empty()) {
            const MeshEdge first = *std::min_element(extra.begin(), extra.end(), edgeIsBefore);
            report.fail(
                Invariant::BoundaryMatchesRings,
                std::to_string(extra.size()) + " boundary edge(s) are not outline edges, e.g. (" +
                    std::to_string(first.a) + "," + std::to_string(first.b) +
                    ") -- this is a gap inside the region");
        }
    }

    // I7 -- coverage. The invariant that would have caught the shipped bug.
    double covered = 0.0;
    for (const auto& [a, b, c] : tris) {
        covered += std::abs(MeshPredicates::signedArea2(points[a], points[b], points[c])) / 2.0;
    }
    double target = MeshKernel::polygonArea(points, outer);
    for (const auto& hole : holes) target -= MeshKernel::polygonArea(points, hole);
    if (target > 0.0) {
        const double relative = std::abs(covered - target) / target;
        if (relative > coverageTolerance) {
            const double percent = 100.0 * covered / target;
            char buf[128];
            std::snprintf(buf, sizeof(buf), "coverage %.4f %% of the region (%.6f vs %.6f)", percent, covered, target);
            report.fail(Invariant::Coverage, buf);
        }
    }

    // I8 -- no orphan outline vertices.
    std::unordered_set<int> referenced;
    for (std::uint16_t idx : triangles) referenced.insert(idx);
    std::unordered_set<int> ringVertices(outer.begin(), outer.end());
    for (const auto& hole : holes) ringVertices.insert(hole.begin(), hole.end());
    {
        std::vector<int> orphans;
        for (int v : ringVertices) {
            if (!referenced.contains(v)) orphans.push_back(v);
        }
        if (!orphans.empty()) {
            const int first = *std::min_element(orphans.begin(), orphans.end());
            report.fail(
                Invariant::OrphanVertices,
                std::to_string(orphans.size()) +
                    " outline vertex/vertices missing from the triangulation, e.g. " +
                    std::to_string(first));
        }
    }

    // I9 -- declared constraints are present as edges.
    for (const auto& [a, b] : constraints) {
        const MeshEdge key(static_cast<std::uint16_t>(a), static_cast<std::uint16_t>(b));
        if (!edgeCount.contains(key)) {
            report.fail(
                Invariant::Constraints,
                "constraint edge (" + std::to_string(key.a) + "," + std::to_string(key.b) +
                    ") is absent from the triangulation");
        }
    }

    // I10 -- no triangle centroid inside a hole.
    for (const auto& hole : holes) {
        for (const auto& [a, b, c] : tris) {
            const Vec2 centroid = (points[a] + points[b] + points[c]) / 3.0f;
            if (MeshKernel::pointInRing(points, hole, centroid)) {
                report.fail(
                    Invariant::TrianglesInHoles,
                    "triangle (" + std::to_string(a) + "," + std::to_string(b) + "," + std::to_string(c) +
                        ") lies inside a hole");
                break;
            }
        }
    }

    // I11 -- the uint16 index ceiling the file format imposes.
    if (n > static_cast<std::size_t>(std::numeric_limits<std::uint16_t>::max())) {
        report.fail(
            Invariant::IndexCeiling,
            std::to_string(n) + " vertices exceeds the uint16 index limit of 65535");
    }

    return report;
}

double coverageRatio(
    const std::vector<Vec2>& points, const std::vector<std::uint16_t>& triangles,
    const std::vector<int>& outer, const std::vector<std::vector<int>>& holes) {
    double covered = 0.0;
    for (std::size_t t = 0; t + 2 < triangles.size(); t += 3) {
        const int a = triangles[t], b = triangles[t + 1], c = triangles[t + 2];
        if (static_cast<std::size_t>(a) >= points.size() || static_cast<std::size_t>(b) >= points.size() ||
            static_cast<std::size_t>(c) >= points.size()) {
            continue;
        }
        covered += std::abs(MeshPredicates::signedArea2(points[a], points[b], points[c])) / 2.0;
    }
    double target = MeshKernel::polygonArea(points, outer);
    for (const auto& hole : holes) target -= MeshKernel::polygonArea(points, hole);
    return target > 0.0 ? covered / target : 0.0;
}

} // namespace umeshcore::MeshValidator
