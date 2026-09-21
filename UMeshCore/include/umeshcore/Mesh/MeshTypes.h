#pragma once

// Shared small types used by the mesh subsystem, factored out of
// `Data/Mesh.swift` since both MeshKernel.h and Mesh.h need MeshEdge.

#include <algorithm>
#include <array>
#include <cstdint>
#include <functional>
#include <optional>
#include <vector>

#include "umeshcore/Math/Vec.h"

namespace umeshcore {

// A canonicalized (undirected) edge between two vertex indices: a <= b
// always, so (u,v) and (v,u) hash and compare equal.
struct MeshEdge {
    std::uint16_t a;
    std::uint16_t b;

    MeshEdge(std::uint16_t x, std::uint16_t y) {
        if (x <= y) {
            a = x;
            b = y;
        } else {
            a = y;
            b = x;
        }
    }

    bool operator==(const MeshEdge&) const = default;
};

struct MeshEdgeHash {
    std::size_t operator()(const MeshEdge& e) const noexcept {
        return (static_cast<std::size_t>(e.a) << 16) | static_cast<std::size_t>(e.b);
    }
};

struct MeshTriangle {
    std::uint16_t a;
    std::uint16_t b;
    std::uint16_t c;

    bool operator==(const MeshTriangle&) const = default;

    std::array<int, 3> indices() const { return {a, b, c}; }

    std::array<std::uint16_t, 3> normalizedKey() const {
        std::array<std::uint16_t, 3> key{a, b, c};
        std::sort(key.begin(), key.end());
        return key;
    }

    bool containsEdge(const MeshEdge& edge) const {
        return MeshEdge(a, b) == edge || MeshEdge(b, c) == edge || MeshEdge(c, a) == edge;
    }

    std::optional<Vec2> centroid(const std::vector<Vec2>& vertices) const {
        if (static_cast<std::size_t>(a) >= vertices.size() || static_cast<std::size_t>(b) >= vertices.size() ||
            static_cast<std::size_t>(c) >= vertices.size()) {
            return std::nullopt;
        }
        return (vertices[a] + vertices[b] + vertices[c]) / 3.0f;
    }
};

} // namespace umeshcore
