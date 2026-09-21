import Foundation
import simd

// ── The structs shared with `SceneGizmoShaders.metal` ──────────────────────
//
// Hand-written on both sides, exactly as `SceneGPUTypes.swift` mirrors
// `SceneShaders.metal` — there is no bridging header in this project, so
// these two files have to be edited in lockstep by hand. The rule that bites:
// Metal aligns `float3` to 16 bytes and so does `SIMD3<Float>`, so a `float3`
// followed by a scalar in a UNIFORM struct (bound `constant`) packs cleanly
// only when the scalar is folded into a `float4` alongside it — spelled as
// two separate fields it costs 32 bytes instead of 16. `SceneGizmoFrameUniforms`
// below follows that rule, the same way `SceneFrameUniforms` does.
//
// `SceneGizmoVertexIn` is PER-VERTEX data, not a uniform, and does not need
// the same care: `float3` then `float3` then `float4` already lands each
// field on a 16-byte boundary on both sides with no manual padding, the same
// way `SceneVertexIn` (`float3 world; float2 uv;`) already does.

/// What the gizmo's vertex/fragment shaders need once per draw.
struct SceneGizmoFrameUniforms {
    var viewProjection: simd_float4x4
    /// xyz the real camera's eye (what shading is lit relative to), w unused.
    var eyeAndPad: SIMD4<Float>
    /// xy the rigid clip-space slide that moves the stabilised shape onto the
    /// object's true screen position — see `SceneGizmoLayout.screenOffsetNDC`
    /// — zw unused.
    var screenOffsetNDC: SIMD4<Float>
}

/// One vertex of the gizmo mesh — a cone/cylinder/torus-tube triangle,
/// entirely in world space; the vertex shader does the recentre-then-slide
/// itself.
struct SceneGizmoVertexIn {
    var world: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD4<Float>
}
