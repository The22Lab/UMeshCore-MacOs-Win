#pragma once

// Shared small types used by the mesh subsystem, factored out of
// `Data/Mesh.swift` since both MeshKernel.h and Mesh.h need MeshEdge.

#include <cstdint>
#include <functional>

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
};

} // namespace umeshcore
