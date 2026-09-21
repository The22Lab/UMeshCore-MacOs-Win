#pragma once

// 1:1 port of `Data/MeshValidator.swift`.
//
// Invariants a mesh must satisfy, checked after every mutation. `.coverage`
// (I7) is the invariant that catches a triangle list silently covering
// less than 100% of its region (the shipped bug this type exists to
// prevent); the others catch failure modes a triangulation can exhibit
// while still having the right total area.

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include "umeshcore/Math/Vec.h"

namespace umeshcore::MeshValidator {

// Invariant identifiers, kept stable so they can be quoted in a bug report.
enum class Invariant {
    IndexBounds,          // I1
    Degenerate,            // I2
    Winding,                // I3
    Manifold,                // I4
    BoundaryMatchesRings,    // I5
    Coverage,                 // I7
    OrphanVertices,            // I8
    Constraints,                // I9
    TrianglesInHoles,            // I10
    IndexCeiling,                 // I11
};

std::string invariantCode(Invariant i);

struct Report {
    std::vector<std::pair<Invariant, std::string>> failures;
    std::vector<std::pair<Invariant, std::string>> warnings;

    bool isValid() const { return failures.empty(); }

    void fail(Invariant invariant, std::string message) {
        failures.emplace_back(invariant, std::move(message));
    }
    void warn(Invariant invariant, std::string message) {
        warnings.emplace_back(invariant, std::move(message));
    }

    // One-line summary suitable for a log or an inspector tooltip.
    std::string summary() const;
    // Short phrase for the health indicator next to the vertex count.
    std::string shortStatus() const;
};

// Check every invariant against a triangle list. `coverageTolerance` is a
// relative area tolerance -- kept tight since the pipeline is exact by
// construction, so anything above rounding noise means real geometry went
// missing.
Report validate(
    const std::vector<Vec2>& points, const std::vector<std::uint16_t>& triangles,
    const std::vector<int>& outer, const std::vector<std::vector<int>>& holes = {},
    const std::vector<std::pair<int, int>>& constraints = {}, double coverageTolerance = 1e-6);

// Fraction of the region actually covered. 1.0 is watertight.
double coverageRatio(
    const std::vector<Vec2>& points, const std::vector<std::uint16_t>& triangles,
    const std::vector<int>& outer, const std::vector<std::vector<int>>& holes = {});

} // namespace umeshcore::MeshValidator
