import Foundation
import simd

/// The Scene gizmo's geometry for one frame, in world space — what
/// `SceneGizmoOverlay.gizmoLayout()` hands to `SceneMetalRenderer` so it can
/// build and draw the manipulator as real GPU meshes.
///
/// NO `CGPoint`, NO `Canvas`, NO SwiftUI. This is the CPU-only description of
/// a shape; `SceneGizmoMeshBuilder` turns it into vertices, and the shape
/// itself was built by the exact same `gizmoState()` that
/// `SceneGizmoOverlay.handleSet()` builds its own screen-space geometry from
/// — so the manipulator the GPU draws and the manipulator a drag is
/// hit-tested against can never disagree about where an axis points, how
/// long it is, or which one is highlighted.
struct SceneGizmoLayout {
    /// One axis arrow: a shaft plus a cone head, along `direction` from
    /// `origin` for `scale` world units.
    struct AxisGeometry {
        var direction: SIMD3<Float>
        var color: SIMD4<Float>
        var highlighted: Bool
        /// The far end's alpha, from `depthAlpha` — 1 when the axis comes
        /// toward the viewer, dimmed when it points away. Unity's depth cue:
        /// dimmed rather than hidden, because an axis you cannot see is one
        /// you cannot grab.
        var awayAlpha: Float
        /// Which cap mesh `SceneGizmoMeshBuilder` puts at the tip — the GPU
        /// equivalent of what `handleCap(tool:at:)` used to choose by
        /// `SceneGizmoTool` before the draw moved off SwiftUI.
        var head: AxisHead
    }

    enum AxisHead {
        /// Translate: a cone, so the axis reads as a direction to slide along.
        case arrow
        /// Scale and shear: a cube, so the handle reads as something to grab
        /// and pull rather than a direction to travel — matching the square
        /// cap `handleCap` drew for scale, generalised to shear too rather
        /// than reproducing its screen-space slanted bar, which had no
        /// honest 3D equivalent (it was a 2D "slides sideways" affordance).
        case cube
    }

    /// One rotation ring: a tube-shaded circle of radius `scale`, in the
    /// plane whose normal is `normal`.
    struct RingGeometry {
        var normal: SIMD3<Float>
        var color: SIMD4<Float>
        var highlighted: Bool
        var awayAlpha: Float
    }

    /// One plane handle: a small quad spanning `a`/`b`, offset from `origin`
    /// by `SceneGizmoOverlay.planeOffset` and sized by `.planeSize`, both
    /// already scaled by `scale` at mesh-build time — the same numbers
    /// `handleSet()`'s plane-quad corners use.
    struct PlaneGeometry {
        var a: SIMD3<Float>
        var b: SIMD3<Float>
        var color: SIMD4<Float>
        var highlighted: Bool
    }

    var tool: SceneGizmoTool
    var origin: SIMD3<Float>
    /// The one uniform world length every axis/ring/plane is built at — see
    /// `SceneGizmoOverlay.gizmoScale(pivot:projection:)`.
    var scale: Float

    var axes: [SceneGizmoOverlay.HandleID: AxisGeometry]
    var rings: [SceneGizmoOverlay.HandleID: RingGeometry]
    var planes: [SceneGizmoOverlay.HandleID: PlaneGeometry]

    /// The fourth, honestly-screen-space rotate ring — turning about the view
    /// axis, billboarded to face `forward` rather than lying in a world plane.
    var showViewRing: Bool
    var viewRingColor: SIMD4<Float>

    /// The free-move / uniform-scale handle at the gizmo's own origin — the
    /// small white square `draw(_:in:)` used to fill for `tool == .translate
    /// || tool == .scale`. Nil for rotate and shear, which have no handle
    /// there.
    var centerHandle: CenterHandle?
    struct CenterHandle {
        var color: SIMD4<Float>
        var highlighted: Bool
    }

    /// The eye every axis/ring/plane's shading is lit relative to — the REAL
    /// camera's eye, not the stabilised one (they share the same eye, so
    /// there is only one honest answer to "where is the viewer").
    var eye: SIMD3<Float>
    /// The stabilised gizmo camera's own forward — what the view-ring
    /// billboards to face.
    var forward: SIMD3<Float>

    /// The stabilised, recentred projection's view-projection matrix.
    var viewProjection: simd_float4x4
    /// The rigid 2D slide, in clip-space units, that moves the stabilised
    /// shape from screen centre onto the object's true screen position:
    /// `clip.xy += screenOffsetNDC * clip.w` in the vertex shader, before the
    /// perspective divide — the exact GPU-side equivalent of the CPU's
    /// `+ screenOffsetPx` after `project(...)`.
    var screenOffsetNDC: SIMD2<Float>
}
