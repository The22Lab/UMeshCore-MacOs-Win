import Foundation
import simd

/// The camera's frustum, as six planes in world space.
///
/// ## Pulled out of the matrix, not rebuilt from the camera
///
/// The planes are extracted from the combined view-projection matrix
/// (Gribb & Hartmann), which is the whole reason this can be trusted: they come
/// from THE SAME matrix the drawing divides by. Rebuilding them from the
/// camera's field of view, aspect and near/far — the obvious way, and the way
/// that reads more clearly — gives a frustum that agrees with the projection
/// only as long as nobody changes either, and the symptom when they drift is an
/// object that pops out at the edge of the screen while still visibly on it.
///
/// ## What a culler is allowed to get wrong
///
/// One direction only. It may KEEP something that turns out not to be visible —
/// that is wasted work, and the harness measures how much (1.3 % of cases over
/// 20 000 random cameras). It may never DISCARD something that is visible: that
/// is an object vanishing, which is the bug this whole file exists because of.
///
/// So the test is the conservative one: a layer is culled only when its entire
/// convex hull lies outside ONE plane. A hull straddling two planes is kept
/// even if it is in fact outside the frustum, because deciding otherwise needs
/// a separating-axis test and the cost of being wrong is not symmetric.
///
/// ## Near and far
///
/// Both planes are here, and both are honoured by the renderer — the far one
/// only since `SceneProjection.clipAndProject` grew a far cut. Before that, the
/// frustum's far plane discarded cards the renderer would have drawn, because
/// `farZ` went into the projection matrix and then nothing ever read it back.
/// `Editor/verify_scene_culling.py` measures that disagreement at 51 layers out
/// of 20 000, every one of them putting pixels on the canvas. A culler whose
/// planes the renderer does not honour is not a culler; it is a way to lose
/// objects.
struct SceneFrustum {

    /// Inward-facing, normalised: a point is inside a plane when
    /// `dot(plane.xyz, point) + plane.w >= 0`.
    let planes: [SIMD4<Float>]

    init(viewProjection m: simd_float4x4) {
        // simd matrices are column-major, so a ROW has to be gathered across
        // the columns. Reading `m.columns.0` as a row is the classic way to get
        // a frustum that is transposed and culls everything behind you.
        func row(_ r: Int) -> SIMD4<Float> {
            SIMD4<Float>(m.columns.0[r], m.columns.1[r], m.columns.2[r], m.columns.3[r])
        }
        let r0 = row(0), r1 = row(1), r2 = row(2), r3 = row(3)
        // Clip z runs 0...w here, not -w...w — this projection is the
        // Metal/Direct3D convention, which `SceneProjection` writes out
        // explicitly. So NEAR is row 2 alone rather than `w + z`; using the
        // OpenGL form would put the near plane half a frustum too far back.
        // left, right, bottom, top, near, far — in that order, so an index into
        // this array means the same plane wherever it is read.
        self.planes = [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r2, r3 - r2]
            .map(SceneFrustum.normalised)
    }

    /// Scaled so `w` is a real distance. Only needed so that a margin can be
    /// expressed in world units; the sign test works either way.
    private static func normalised(_ plane: SIMD4<Float>) -> SIMD4<Float> {
        let length = simd_length(SIMD3<Float>(plane.x, plane.y, plane.z))
        return length > 1e-12 ? plane / length : plane
    }

    static func distance(_ plane: SIMD4<Float>, to point: SIMD3<Float>) -> Float {
        simd_dot(SIMD3<Float>(plane.x, plane.y, plane.z), point) + plane.w
    }

    /// True when the whole hull is outside one plane, and the layer can be
    /// skipped.
    ///
    /// `margin` pushes every plane outward. It is not a fudge for an
    /// approximate bound — the bounds handed here are exact — it is there so a
    /// caller with a genuinely uncertain hull can say by how much, in world
    /// units, rather than by inventing a scale factor.
    func culls(_ hull: [SIMD3<Float>], margin: Float = 0) -> Bool {
        guard !hull.isEmpty else { return true }
        for plane in planes
        where !hull.contains(where: { Self.distance(plane, to: $0) >= -margin }) {
            return true
        }
        return false
    }
}

/// A whole-pixel rectangle of the frame, y DOWN — the projection's convention,
/// so no flip lives in here.
///
/// Integer because it addresses a bitmap. Rounded OUTWARD, never to nearest: a
/// rectangle rounded inward loses the anti-aliased edge of whatever it bounds,
/// and a half-pixel of a sprite's outline going missing reads as the artwork
/// being wrong rather than as a rounding rule.
struct FrameRegion: Equatable {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    var width: Int { maxX - minX }
    var height: Int { maxY - minY }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// The outward-rounded box of some screen points, clipped to a frame.
    ///
    /// `pad` covers what RESAMPLING spills past the geometry — a perspective
    /// transform reads its source through a reconstruction kernel, so the
    /// output reaches a little beyond the quad its corners describe. It does
    /// NOT stand in for uncertainty about where the geometry is: the hulls this
    /// is given are exact, and a pad covering for a doubtful bound would be the
    /// arbitrary number this whole exercise is meant to avoid.
    static func bounding(_ points: [SIMD2<Float>], pad: Float,
                         frameWidth: Int, frameHeight: Int) -> FrameRegion {
        guard let first = points.first else {
            return FrameRegion(minX: 0, minY: 0, maxX: 0, maxY: 0)
        }
        var lo = first, hi = first
        for point in points.dropFirst() {
            lo = simd_min(lo, point)
            hi = simd_max(hi, point)
        }
        guard lo.x.isFinite, lo.y.isFinite, hi.x.isFinite, hi.y.isFinite else {
            return FrameRegion(minX: 0, minY: 0, maxX: frameWidth, maxY: frameHeight)
        }
        return FrameRegion(
            minX: max(Int((lo.x - pad).rounded(.down)), 0),
            minY: max(Int((lo.y - pad).rounded(.down)), 0),
            maxX: min(Int((hi.x + pad).rounded(.up)), frameWidth),
            maxY: min(Int((hi.y + pad).rounded(.up)), frameHeight))
    }

    static func whole(width: Int, height: Int) -> FrameRegion {
        FrameRegion(minX: 0, minY: 0, maxX: width, maxY: height)
    }
}
