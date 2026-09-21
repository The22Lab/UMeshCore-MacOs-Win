import CoreGraphics

/// The affine transform mapping one triangle onto another.
///
/// This is the primitive that lets CoreGraphics — which has no textured
/// triangles — draw a mesh: clip to the destination triangle, concatenate this
/// transform, draw the whole source image. It lived as a private helper inside
/// `CoreGraphicsFrameSource`; the Scene renderer needs the identical mapping,
/// and a second transcription of a 3×3 inverse is exactly the kind of
/// duplicate that drifts, so it is one function now.
enum TriangleAffine {
    /// Returns A such that A(src_i) = dst_i for i = 0,1,2, or nil when the
    /// source triangle is degenerate.
    static func transform(
        src: (CGPoint, CGPoint, CGPoint),
        dst: (CGPoint, CGPoint, CGPoint)
    ) -> CGAffineTransform? {
        let (s0, s1, s2) = src
        let (d0, d1, d2) = dst

        // det of the 3×3 homogeneous source matrix [s0|s1|s2]
        let det = s0.x * (s1.y - s2.y) - s1.x * (s0.y - s2.y) + s2.x * (s0.y - s1.y)
        guard abs(det) > 1e-6 else { return nil }
        let inv = 1.0 / det

        // A = dst_matrix * inv(src_matrix), rows 0 and 1 only (affine part)
        let a  = (d0.x*(s1.y-s2.y) + d1.x*(s2.y-s0.y) + d2.x*(s0.y-s1.y)) * inv
        let b  = (d0.y*(s1.y-s2.y) + d1.y*(s2.y-s0.y) + d2.y*(s0.y-s1.y)) * inv
        let c  = (d0.x*(s2.x-s1.x) + d1.x*(s0.x-s2.x) + d2.x*(s1.x-s0.x)) * inv
        let d  = (d0.y*(s2.x-s1.x) + d1.y*(s0.x-s2.x) + d2.y*(s1.x-s0.x)) * inv
        let tx = (d0.x*(s1.x*s2.y-s2.x*s1.y) + d1.x*(s2.x*s0.y-s0.x*s2.y) + d2.x*(s0.x*s1.y-s1.x*s0.y)) * inv
        let ty = (d0.y*(s1.x*s2.y-s2.x*s1.y) + d1.y*(s2.x*s0.y-s0.x*s2.y) + d2.y*(s0.x*s1.y-s1.x*s0.y)) * inv

        // CGAffineTransform: x' = a*x + c*y + tx,  y' = b*x + d*y + ty
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}

/// Whether a posed mesh is, after all, just an affine image of its texture.
///
/// ## Why this is worth asking
///
/// A rig sprite is drawn triangle by triangle: a path, a clip region, a matrix
/// and a resampled image blit, per triangle. Eight sprites of 120 triangles,
/// two instances, is 1 920 of those in a frame — measured at 38.8 ms, which is
/// over a 30 fps budget before anything else in the scene is drawn. That is
/// what "the animations run slowly when I press play" is: during playback the
/// pose changes every frame, so none of it can be cached.
///
/// But most sprites in most rigs are not deformed at all. A head bound rigidly
/// to one bone, a prop, a torso piece — every vertex moves by the SAME matrix,
/// so the whole sprite is one affine map of its image and 120 triangles are 120
/// ways of drawing the same thing.
///
/// ## What separates them
///
/// Solve the affine through three vertices and measure every other vertex
/// against it. Measured on a 36-vertex mesh: a rigidly bound sprite deviates by
/// 4.6e-14 units, a sheared one by 0, an arm bent across two bones by 190, and
/// a hand-pushed deform by 12.8. There is no grey area to tune a threshold in.
enum MeshAffinity {

    /// Three vertices that span the mesh, chosen DETERMINISTICALLY.
    ///
    /// Furthest from the first, then furthest from that, then furthest from the
    /// line between them — the standard way to find a well-spread triangle in
    /// one pass. Deterministic because the alternative is picking by index and
    /// hoping: three vertices that happen to be nearly collinear give an
    /// ill-conditioned solve, and the answer would then depend on the mesh's
    /// vertex order.
    static func spanningIndices(_ points: [CGPoint]) -> (Int, Int, Int)? {
        guard points.count >= 3 else { return nil }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = a.x - b.x, dy = a.y - b.y
            return dx * dx + dy * dy
        }
        var i = 0
        for k in points.indices where distance(points[k], points[0]) > distance(points[i], points[0]) {
            i = k
        }
        var j = 0
        for k in points.indices where distance(points[k], points[i]) > distance(points[j], points[i]) {
            j = k
        }
        guard distance(points[i], points[j]) > 1e-12 else { return nil }
        let ax = points[j].x - points[i].x, ay = points[j].y - points[i].y
        var best = 0
        var bestArea: CGFloat = 0
        for k in points.indices {
            let bx = points[k].x - points[i].x, by = points[k].y - points[i].y
            let area = abs(ax * by - ay * bx)
            if area > bestArea { bestArea = area; best = k }
        }
        guard bestArea > 1e-9 else { return nil }
        return (i, j, best)
    }

    /// The affine mapping `source` onto `destination`, when ONE does within
    /// `tolerance` destination units. Nil when the mesh is genuinely deformed.
    ///
    /// The tolerance is in DESTINATION units — pixels — because that is where
    /// the error would be seen. A tolerance in mesh units would mean something
    /// different at every bake scale.
    static func affine(source: [CGPoint], destination: [CGPoint],
                       tolerance: CGFloat) -> CGAffineTransform? {
        guard source.count == destination.count, source.count >= 3,
              let (i, j, k) = spanningIndices(source),
              let candidate = TriangleAffine.transform(
                src: (source[i], source[j], source[k]),
                dst: (destination[i], destination[j], destination[k]))
        else { return nil }
        for index in source.indices {
            let mapped = source[index].applying(candidate)
            let dx = mapped.x - destination[index].x
            let dy = mapped.y - destination[index].y
            guard dx * dx + dy * dy <= tolerance * tolerance else { return nil }
        }
        return candidate
    }
}
