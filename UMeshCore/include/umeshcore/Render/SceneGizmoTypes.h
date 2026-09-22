#pragma once

// 1:1 port of `Render/SceneGPU/SceneGizmoTypes.swift` -- the two structs
// the gizmo's shaders read.
//
// Same wire-format rules as `SceneGPUTypes.h`, and the Swift file spells
// out the one asymmetry between its two structs: `float3` aligns to 16
// bytes, so in a UNIFORM struct a `float3` followed by a scalar has to be
// folded into a `float4` by hand (spelled as two fields it costs 32 bytes
// instead of 16) -- which is why `SceneGizmoFrameUniforms` carries
// `eyeAndPad` and `screenOffsetNDC` as float4s. `SceneGizmoVertexIn` is
// PER-VERTEX data and needs no such care in Swift or MSL: float3, float3,
// float4 already lands every field on a 16-byte boundary.
//
// It still needs care in C++, because `Vec3` here is 12 bytes with 4-byte
// alignment rather than 16 with 16. So the padding is explicit and the
// `static_assert`s below stand in for
// `Editor/verify_scene_gpu_transcription.py`, which this repository does
// not have (see CLAUDE.md).

#include <cstddef>

#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

// What the gizmo's vertex/fragment shaders need once per draw.
struct alignas(16) SceneGizmoFrameUniforms {
    // The stabilised, recentred projection -- see SceneGizmoLayout.
    Mat4 viewProjection = Mat4::identity();
    // xyz the REAL camera's eye (what shading is lit relative to), w unused.
    Vec4 eyeAndPad;
    // xy the rigid clip-space slide that moves the stabilised shape onto
    // the object's true screen position, zw unused.
    Vec4 screenOffsetNDC;
};

static_assert(sizeof(SceneGizmoFrameUniforms) == 96, "gizmo frame uniforms are 96 bytes in MSL");
static_assert(alignof(SceneGizmoFrameUniforms) == 16, "");
static_assert(offsetof(SceneGizmoFrameUniforms, eyeAndPad) == 64, "");
static_assert(offsetof(SceneGizmoFrameUniforms, screenOffsetNDC) == 80, "");

// One vertex of the gizmo mesh -- a cone/cylinder/torus-tube triangle,
// entirely in WORLD space; the vertex shader does the recentre-then-slide
// itself.
struct alignas(16) SceneGizmoVertexIn {
    Vec3 world;
    float pad0 = 0.0f;
    Vec3 normal;
    float pad1 = 0.0f;
    Vec4 color;

    SceneGizmoVertexIn() = default;
    SceneGizmoVertexIn(const Vec3& world_, const Vec3& normal_, const Vec4& color_)
        : world(world_), normal(normal_), color(color_) {}
};

static_assert(sizeof(SceneGizmoVertexIn) == 48, "gizmo vertex is 48 bytes in MSL");
static_assert(alignof(SceneGizmoVertexIn) == 16, "");
static_assert(offsetof(SceneGizmoVertexIn, world) == 0, "");
static_assert(offsetof(SceneGizmoVertexIn, normal) == 16, "");
static_assert(offsetof(SceneGizmoVertexIn, color) == 32, "");

} // namespace umeshcore
