#pragma once

// 1:1 port of `GizmoHandle` from `Core/Tooling.swift`.

#include <variant>

#include "umeshcore/Core/Uuid.h"

namespace umeshcore {

struct MoveCenterHandle { bool operator==(const MoveCenterHandle&) const = default; };
struct MoveXHandle { bool operator==(const MoveXHandle&) const = default; };
struct MoveYHandle { bool operator==(const MoveYHandle&) const = default; };
struct BoneHandle { Uuid id; bool operator==(const BoneHandle&) const = default; };
struct MeshVertexHandle { int index; bool operator==(const MeshVertexHandle&) const = default; };
struct MeshInternalEdgeHandle { int index; bool operator==(const MeshInternalEdgeHandle&) const = default; };
struct RotateRingHandle { bool operator==(const RotateRingHandle&) const = default; };
struct ScaleCornerHandle { int index; bool operator==(const ScaleCornerHandle&) const = default; };
struct SkewEdgeHandle { int index; bool operator==(const SkewEdgeHandle&) const = default; };

using GizmoHandle = std::variant<
    MoveCenterHandle, MoveXHandle, MoveYHandle, BoneHandle, MeshVertexHandle, MeshInternalEdgeHandle,
    RotateRingHandle, ScaleCornerHandle, SkewEdgeHandle>;

// Factory helpers matching the Swift case names for readable call sites
// (`GizmoHandleFactory::moveCenter()` etc. rather than spelling out the
// variant alternative every time).
namespace GizmoHandleFactory {
inline GizmoHandle moveCenter() { return MoveCenterHandle{}; }
inline GizmoHandle moveX() { return MoveXHandle{}; }
inline GizmoHandle moveY() { return MoveYHandle{}; }
inline GizmoHandle bone(Uuid id) { return BoneHandle{id}; }
inline GizmoHandle meshVertex(int index) { return MeshVertexHandle{index}; }
inline GizmoHandle meshInternalEdge(int index) { return MeshInternalEdgeHandle{index}; }
inline GizmoHandle rotateRing() { return RotateRingHandle{}; }
inline GizmoHandle scaleCorner(int index) { return ScaleCornerHandle{index}; }
inline GizmoHandle skewEdge(int index) { return SkewEdgeHandle{index}; }
} // namespace GizmoHandleFactory

} // namespace umeshcore
