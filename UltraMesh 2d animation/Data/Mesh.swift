import Foundation
import simd

struct MeshEdge: Codable, Hashable {
    var a: UInt16
    var b: UInt16

    init(_ a: UInt16, _ b: UInt16) {
        if a <= b {
            self.a = a
            self.b = b
        } else {
            self.a = b
            self.b = a
        }
    }
}

struct MeshTriangle: Codable, Hashable {
    var a: UInt16
    var b: UInt16
    var c: UInt16

    init(_ a: UInt16, _ b: UInt16, _ c: UInt16) {
        self.a = a
        self.b = b
        self.c = c
    }

    var indices: [Int] {
        [Int(a), Int(b), Int(c)]
    }

    func normalizedKey() -> [UInt16] {
        [a, b, c].sorted()
    }

    func contains(edge: MeshEdge) -> Bool {
        [
            MeshEdge(a, b),
            MeshEdge(b, c),
            MeshEdge(c, a)
        ].contains(edge)
    }

    func centroid(in vertices: [SIMD2<Float>]) -> SIMD2<Float>? {
        let triangleIndices = indices
        guard triangleIndices.allSatisfy(vertices.indices.contains) else { return nil }
        return (vertices[triangleIndices[0]] + vertices[triangleIndices[1]] + vertices[triangleIndices[2]]) / 3
    }
}

struct VertexBoneWeight: Codable, Hashable {
    var boneID: UUID
    var weight: Float
}

struct SavedMatrix4x4: Codable, Hashable {
    var m00: Float; var m01: Float; var m02: Float; var m03: Float
    var m10: Float; var m11: Float; var m12: Float; var m13: Float
    var m20: Float; var m21: Float; var m22: Float; var m23: Float
    var m30: Float; var m31: Float; var m32: Float; var m33: Float

    init(_ matrix: simd_float4x4) {
        m00 = matrix.columns.0.x; m01 = matrix.columns.0.y; m02 = matrix.columns.0.z; m03 = matrix.columns.0.w
        m10 = matrix.columns.1.x; m11 = matrix.columns.1.y; m12 = matrix.columns.1.z; m13 = matrix.columns.1.w
        m20 = matrix.columns.2.x; m21 = matrix.columns.2.y; m22 = matrix.columns.2.z; m23 = matrix.columns.2.w
        m30 = matrix.columns.3.x; m31 = matrix.columns.3.y; m32 = matrix.columns.3.z; m33 = matrix.columns.3.w
    }

    var matrix: simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(m00, m01, m02, m03),
            SIMD4<Float>(m10, m11, m12, m13),
            SIMD4<Float>(m20, m21, m22, m23),
            SIMD4<Float>(m30, m31, m32, m33)
        ))
    }
}

/// Snapshot of a sprite's world pose (rotation in radians, shear in degrees —
/// the app-wide sprite transform convention). Skinning stores one of these at bind time so linear
/// blend skinning can operate in a consistent world space:
///
///     world = Σ wᵢ · BoneNowᵢ · inverse(BoneBindᵢ) · bindPose(localVertex)
///
/// The renderer applies the sprite's *current* pose after skinning, so
/// `skinnedVertices` maps the world result back through the inverse of the
/// current pose. This makes bone rotation rigid and exact — the sprite can
/// no longer orbit, slide, or double-rotate when its bones move.
struct MeshBindPose: Codable, Hashable {
    var position: SIMD2<Float>
    /// Radians, matching `SceneImage.rotation`.
    var rotation: Float
    var scale: SIMD2<Float>
    /// Degrees, matching `SceneImage.skew`.
    var skew: SIMD2<Float>

    func worldPoint(fromLocal local: SIMD2<Float>) -> SIMD2<Float> {
        MatrixUtilities.shearedWorldTransform(
            local: local,
            position: position,
            rotation: rotation * 180 / .pi,
            shear: skew,
            scale: scale
        )
    }

    func localPoint(fromWorld world: SIMD2<Float>) -> SIMD2<Float> {
        MatrixUtilities.shearedWorldInverse(
            world: world,
            position: position,
            rotation: rotation * 180 / .pi,
            shear: skew,
            scale: scale
        )
    }
}

struct Mesh: Identifiable, Equatable {
    let id: UUID
    var name: String
    var vertices: [SIMD2<Float>]
    var uvs: [SIMD2<Float>]
    var indices: [UInt16]
    var hullVertexIndices: [UInt16]
    var internalEdges: [MeshEdge]
    var manualTriangles: [MeshTriangle]
    var vertexBoneWeights: [[VertexBoneWeight]]
    var bindVertices: [SIMD2<Float>]
    var boneInverseBindMatrices: [UUID: SavedMatrix4x4]
    /// Sprite world pose captured when the skin bind was established.
    /// `nil` for legacy projects — the current pose is used as a stable
    /// fallback so old files keep rendering sanely.
    var bindImagePose: MeshBindPose?

    static func localPosition(for uv: SIMD2<Float>, size: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(
            uv.x * size.x - (size.x * 0.5),
            (size.y * 0.5) - uv.y * size.y
        )
    }

    static func uv(for localPosition: SIMD2<Float>, size: SIMD2<Float>) -> SIMD2<Float> {
        guard size.x > 0.0001, size.y > 0.0001 else { return .zero }
        return SIMD2<Float>(
            max(0, min(1, (localPosition.x + size.x * 0.5) / size.x)),
            max(0, min(1, ((size.y * 0.5) - localPosition.y) / size.y))
        )
    }

    init(
        id: UUID = UUID(),
        name: String,
        vertices: [SIMD2<Float>] = [],
        uvs: [SIMD2<Float>] = [],
        indices: [UInt16] = [],
        hullVertexIndices: [UInt16] = [],
        internalEdges: [MeshEdge] = [],
        manualTriangles: [MeshTriangle] = [],
        vertexBoneWeights: [[VertexBoneWeight]] = [],
        bindVertices: [SIMD2<Float>] = [],
        boneInverseBindMatrices: [UUID: SavedMatrix4x4] = [:],
        bindImagePose: MeshBindPose? = nil
    ) {
        self.id = id
        self.name = name
        self.vertices = vertices
        self.uvs = uvs
        self.indices = indices
        self.hullVertexIndices = hullVertexIndices
        self.internalEdges = internalEdges
        self.manualTriangles = manualTriangles
        self.vertexBoneWeights = vertexBoneWeights
        self.bindVertices = bindVertices
        self.boneInverseBindMatrices = boneInverseBindMatrices
        self.bindImagePose = bindImagePose
    }

    var isQuadCompatible: Bool {
        vertices.count == 4 &&
        uvs.count == 4 &&
        indices == [0, 1, 2, 2, 1, 3]
    }

    func duplicated(named name: String? = nil) -> Mesh {
        Mesh(
            id: UUID(),
            name: name ?? self.name,
            vertices: vertices,
            uvs: uvs,
            indices: indices,
            hullVertexIndices: hullVertexIndices,
            internalEdges: internalEdges,
            manualTriangles: manualTriangles,
            vertexBoneWeights: vertexBoneWeights,
            bindVertices: bindVertices,
            boneInverseBindMatrices: boneInverseBindMatrices,
            bindImagePose: bindImagePose
        )
    }

    static func makeQuad(name: String, size: SIMD2<Float>) -> Mesh {
        let halfWidth = size.x * 0.5
        let halfHeight = size.y * 0.5
        return Mesh(
            name: name,
            vertices: [
                SIMD2<Float>(-halfWidth, halfHeight),
                SIMD2<Float>(halfWidth, halfHeight),
                SIMD2<Float>(-halfWidth, -halfHeight),
                SIMD2<Float>(halfWidth, -halfHeight)
            ],
            uvs: [
                SIMD2<Float>(0, 0),
                SIMD2<Float>(1, 0),
                SIMD2<Float>(0, 1),
                SIMD2<Float>(1, 1)
            ],
            indices: [0, 1, 2, 2, 1, 3],
            hullVertexIndices: [0, 1, 3, 2],
            internalEdges: [],
            manualTriangles: []
        )
    }

    func resetToQuad(size: SIMD2<Float>) -> Mesh {
        Mesh.makeQuad(name: name, size: size)
    }

    func sanitizedForRender(size: SIMD2<Float>) -> Mesh {
        guard !vertices.isEmpty else { return resetToQuad(size: size) }

        var next = self

        if next.uvs.count != next.vertices.count {
            next.uvs = next.vertices.map { Self.uv(for: $0, size: size) }
        }

        let filteredHull = next.hullVertexIndices
            .map(Int.init)
            .filter { next.vertices.indices.contains($0) }
        let dedupedHull = deduplicatedRing(filteredHull)
        if dedupedHull.count >= 3 {
            next.hullVertexIndices = dedupedHull.map(UInt16.init)
        } else {
            let convexHull = next.convexHullVertexIndices()
            if convexHull.count >= 3 {
                next.hullVertexIndices = convexHull.map(UInt16.init)
            } else {
                return resetToQuad(size: size)
            }
        }

        next.indices = next.sanitizedTriangleIndices(next.indices)
        if next.indices.isEmpty {
            let fallback = next.sanitizedTriangleIndices(next.triangulatedHullIndices())
            next.indices = fallback
        }

        // Deliberately no validation here. This runs once per sprite per frame
        // from the renderer, and a coverage check walks every triangle. The
        // repair belongs where a bad triangle list can first enter the app —
        // see `repairedIfInvalid()`, called on load.
        next = next.sanitizedSkinningData()
        return next
    }

    /// Rebuild the triangle list if it does not satisfy the invariants.
    ///
    /// Meant for project load. Files written before the kernel existed can hold
    /// a triangle list that covers only part of the silhouette: the old rebuild
    /// fired only when `indices` was COMPLETELY empty, so a list covering 97.8 %
    /// passed straight through to the renderer, the project file and the
    /// exporters without a complaint. That is why the reported holes survived a
    /// save and reload.
    ///
    /// Only the outcome is trusted. If the rebuild does not validate either, the
    /// original list is kept rather than replaced by something equally broken
    /// but differently shaped, and `wasRepaired` stays false so the caller can
    /// tell the artist the mesh needs attention.
    func repairedIfInvalid() -> (mesh: Mesh, wasRepaired: Bool) {
        guard vertices.count >= 3, hullVertexIndices.count >= 3 else { return (self, false) }
        guard !validationReport().isValid else { return (self, false) }
        guard let rebuilt = try? kernelTriangulatedIndices() else { return (self, false) }

        var candidate = self
        candidate.indices = rebuilt
        guard candidate.validationReport().isValid else { return (self, false) }
        return (candidate, true)
    }

    func hasSkinningData() -> Bool {
        !vertexBoneWeights.isEmpty && !boneInverseBindMatrices.isEmpty
    }

    func sanitizedSkinningData(maxInfluences: Int = 4) -> Mesh {
        var next = self

        if next.bindVertices.count != next.vertices.count {
            next.bindVertices = next.vertices
        }

        if next.vertexBoneWeights.count != next.vertices.count {
            next.vertexBoneWeights = Array(repeating: [], count: next.vertices.count)
        }

        for index in next.vertexBoneWeights.indices {
            var influences = next.vertexBoneWeights[index]
                .filter { $0.weight.isFinite && $0.weight > 0 && next.boneInverseBindMatrices[$0.boneID] != nil }
            if influences.isEmpty {
                next.vertexBoneWeights[index] = []
                continue
            }

            // Merge duplicate bone entries.
            var merged: [UUID: Float] = [:]
            for influence in influences {
                merged[influence.boneID, default: 0] += influence.weight
            }
            influences = merged.map { VertexBoneWeight(boneID: $0.key, weight: $0.value) }
            influences.sort { $0.weight > $1.weight }
            if influences.count > maxInfluences {
                influences = Array(influences.prefix(maxInfluences))
            }

            let total = influences.reduce(0) { $0 + max(0, $1.weight) }
            if total > 0.000001 {
                next.vertexBoneWeights[index] = influences.map { VertexBoneWeight(boneID: $0.boneID, weight: max(0, $0.weight) / total) }
            } else {
                next.vertexBoneWeights[index] = []
            }
        }

        return next
    }

    // MARK: - Skinning weight assignment

    /// A bone reduced to the segment the weight falloff is measured against.
    private struct BoneSegment {
        let id: UUID
        let start: SIMD2<Float>
        let end: SIMD2<Float>

        init(bone: Bone, world: simd_float4x4) {
            let s = MatrixUtilities.transformPoint(.zero, with: world)
            let e = MatrixUtilities.transformPoint(SIMD3<Float>(bone.length, 0, 0), with: world)
            self.id = bone.id
            self.start = SIMD2(s.x, s.y)
            self.end = SIMD2(e.x, e.y)
        }
    }

    /// The bind vertices in the frame the bone matrices live in.
    ///
    /// Bone world matrices are world space; `vertices` and `bindVertices` are in
    /// the sprite's local space. `skinnedVertices` reconciles the two by lifting
    /// the bind vertex through `bindImagePose` before applying the skin matrix,
    /// so anything that measures a vertex-to-bone distance has to lift it too.
    /// Measuring raw local coordinates against world-space bones agrees with the
    /// skinning path only for a sprite parked at the origin with no rotation and
    /// unit scale, which is why the old weights looked plausible in a fresh
    /// project and fell apart the moment the sprite was moved.
    private func bindPointsInWorldSpace(fallbackPose: MeshBindPose?) -> [SIMD2<Float>] {
        let source = bindVertices.count == vertices.count ? bindVertices : vertices
        guard let pose = bindImagePose ?? fallbackPose else { return source }
        return source.map { pose.worldPoint(fromLocal: $0) }
    }

    /// Inverse-distance falloff over a fixed set of bones, normalised per vertex.
    ///
    /// Only bones inside the blend zone of the nearest one take part, so a
    /// distant bone cannot bleed into an unrelated region; every vertex still
    /// ends up on at least the nearest bone, because a vertex with no influence
    /// is a vertex that stops following the rig.
    private static func distributedWeights(
        points: [SIMD2<Float>],
        segments: [BoneSegment],
        maxInfluences: Int,
        distancePower: Float,
        blendZoneFactor: Float,
        minWeightThreshold: Float
    ) -> [[VertexBoneWeight]] {
        let epsilon: Float = 0.0001

        return points.map { point in
            let dists: [(id: UUID, d: Float)] = segments.map { seg in
                (seg.id, max(Mesh.pointDistanceToSegment(point, seg.start, seg.end), epsilon))
            }
            guard let dMin = dists.min(by: { $0.d < $1.d })?.d else { return [] }

            let blendCeiling = dMin * (1.0 + blendZoneFactor)
            var scored: [VertexBoneWeight] = []
            for entry in dists {
                guard entry.d <= blendCeiling else { continue }
                // Linear fade: 1.0 at dMin, 0.0 at blendCeiling.
                let fade = (blendCeiling - entry.d) / (blendCeiling - dMin + epsilon)
                let raw = (1.0 / pow(entry.d, distancePower)) * fade
                if raw > minWeightThreshold {
                    scored.append(VertexBoneWeight(boneID: entry.id, weight: raw))
                }
            }

            if scored.isEmpty, let nearest = dists.min(by: { $0.d < $1.d }) {
                return [VertexBoneWeight(boneID: nearest.id, weight: 1.0)]
            }

            scored.sort { $0.weight > $1.weight }
            if scored.count > maxInfluences {
                scored = Array(scored.prefix(maxInfluences))
            }
            return scored
        }
    }

    /// Redistribute weights among the bones this image is ALREADY bound to.
    ///
    /// This is what the Auto-Weight button runs, and it binds nothing: the
    /// inverse-bind matrices, the bind pose and the bind vertices are left
    /// exactly as the bind left them, and no bone is added to the set. The
    /// previous behaviour handed the whole `Skeleton` to `autoBindWeights`,
    /// which wrote an inverse-bind matrix for every bone in the scene — and
    /// since `SceneManager.boundBoneIDs` counts a bone as bound the moment it
    /// has one, a single press bound all sixteen bones of the rig to one sprite,
    /// including the bones belonging to other images.
    ///
    /// Bones are placed at the pose captured when the image was bound, recovered
    /// from the stored inverse-bind matrix rather than read from the live
    /// skeleton. That keeps the result independent of whatever pose the rig
    /// happens to be in when the artist presses the button, and puts the bones
    /// in the same frame as `bindVertices`.
    ///
    /// - Parameter boneIDs: the bones the image is bound to. Anything not in
    ///   this set, not in the skeleton any more, or with no inverse-bind matrix
    ///   is skipped.
    func autoWeights(
        skeleton: Skeleton,
        boneIDs: Set<UUID>,
        maxInfluences: Int = 4,
        distancePower: Float = 4.0,
        blendZoneFactor: Float = 0.35,
        minWeightThreshold: Float = 0.0001,
        imagePose: MeshBindPose? = nil
    ) -> Mesh {
        var next = self
        guard !vertices.isEmpty, !boneIDs.isEmpty else { return next }

        // `orderedBones`, not the matrix dictionary: Swift dictionary iteration
        // is not stable across runs, and a tie between two equidistant bones
        // would otherwise resolve differently from one launch to the next.
        let segments: [BoneSegment] = skeleton.orderedBones.compactMap { bone in
            guard boneIDs.contains(bone.id),
                  let inverseBind = boneInverseBindMatrices[bone.id]?.matrix else { return nil }
            return BoneSegment(bone: bone, world: simd_inverse(inverseBind))
        }
        guard !segments.isEmpty else { return next }

        if next.bindVertices.count != next.vertices.count {
            next.bindVertices = next.vertices
        }

        next.vertexBoneWeights = Mesh.distributedWeights(
            points: next.bindPointsInWorldSpace(fallbackPose: imagePose),
            segments: segments,
            maxInfluences: maxInfluences,
            distancePower: distancePower,
            blendZoneFactor: blendZoneFactor,
            minWeightThreshold: minWeightThreshold
        )

        return next.sanitizedSkinningData(maxInfluences: maxInfluences)
    }

    /// Bind this mesh to every bone in the skeleton at the current pose.
    ///
    /// This one really does bind — it captures bind vertices, bind pose and an
    /// inverse-bind matrix per bone. It is the "skin this sprite to the whole
    /// rig" operation, not Auto-Weight; see `autoWeights` for the latter.
    func autoBindWeights(
        skeleton: Skeleton,
        maxInfluences: Int = 4,
        distancePower: Float = 4.0,
        blendZoneFactor: Float = 0.35,
        minWeightThreshold: Float = 0.0001,
        imagePose: MeshBindPose? = nil
    ) -> Mesh {
        var next = self
        guard !vertices.isEmpty else { return next }

        let worldMatrices = skeleton.worldMatrices()
        let segments: [BoneSegment] = skeleton.orderedBones.compactMap { bone in
            guard let world = worldMatrices[bone.id] else { return nil }
            return BoneSegment(bone: bone, world: world)
        }
        guard !segments.isEmpty else { return next }

        next.bindVertices = vertices
        next.bindImagePose = imagePose ?? next.bindImagePose
        next.boneInverseBindMatrices = Dictionary(uniqueKeysWithValues: segments.compactMap { seg in
            guard let world = worldMatrices[seg.id] else { return nil }
            return (seg.id, SavedMatrix4x4(simd_inverse(world)))
        })

        next.vertexBoneWeights = Mesh.distributedWeights(
            points: next.bindPointsInWorldSpace(fallbackPose: imagePose),
            segments: segments,
            maxInfluences: maxInfluences,
            distancePower: distancePower,
            blendZoneFactor: blendZoneFactor,
            minWeightThreshold: minWeightThreshold
        )

        return next.sanitizedSkinningData(maxInfluences: maxInfluences)
    }

    /// Bind one bone to this mesh and rebalance the weights over everything
    /// bound so far.
    ///
    /// The new bone's weights are not appended, the whole distribution is
    /// recomputed. Appending a raw inverse-distance score alongside the
    /// already-normalised weights of the bones bound earlier compared two
    /// different scales: the first bone bound came out of normalisation at 1.0,
    /// while the second arrived as 1/d², so on a sprite a hundred units from its
    /// bone the second bone entered at 0.0001 and never visibly took hold. That
    /// is half of "the weights don't distribute properly" — the second bone was
    /// bound but weightless.
    ///
    /// Recomputing puts every bound bone on one scale, and it runs the same
    /// routine Auto-Weight runs, so binding a bone and pressing Auto-Weight
    /// cannot produce two different answers.

    // MARK: - Auto Bind

    /// How a bone sits over this sprite, in the sprite's own frame.
    ///
    /// The three numbers are what Auto Bind decides on. Each catches a shape
    /// the others miss, which is why all three are kept rather than reduced to
    /// one score:
    ///
    /// - `boneFraction` — a bone lying ALONG the sprite. The plain reading of
    ///   "this bone is over that sprite".
    /// - `crossFraction` — a long bone crossing a small sprite. A spine 190
    ///   long crossing a belt 20 tall covers a tenth of its own length, so no
    ///   bone-side threshold would ever accept it, yet it is plainly the bone
    ///   that drives the belt. Measured against how far the sprite reaches
    ///   along the bone, i.e. how much of the available crossing was used.
    /// - `originInside` — a joint planted in the sprite. A forearm bone rooted
    ///   at the elbow of a short sleeve covers almost none of it and still owns
    ///   it, because the sprite turns about that joint.
    struct BoneFit {
        /// Length of the bone lying inside the outline, in sprite units.
        var overlap: Float
        /// `overlap` over the bone's length, 0…1.
        var boneFraction: Float
        /// `overlap` over the sprite's span along the bone, 0…1.
        var crossFraction: Float
        /// Whether the bone's joint is inside the outline.
        var originInside: Bool

        static let none = BoneFit(overlap: 0, boneFraction: 0, crossFraction: 0,
                                  originInside: false)
    }

    /// Length of `a`–`b` that lies inside the outline.
    ///
    /// Exact rather than sampled: every crossing of the segment with the ring is
    /// found, the segment is cut at those parameters, and each piece is
    /// classified by testing its midpoint. Sampling at a fixed step misses a
    /// thin sprite entirely and reports a different answer at a different zoom.
    ///
    /// The straddle test goes through `MeshPredicates`, so a bone running
    /// exactly along an outline edge or exactly through a vertex is classified
    /// the same way on every run instead of according to rounding.
    func insideHullLength(from a: SIMD2<Float>, to b: SIMD2<Float>) -> Float {
        let ring = hullVertexIndices.map(Int.init)
        guard ring.count >= 3 else { return 0 }
        let total = simd_distance(a, b)
        guard total > 0 else { return 0 }

        var cuts: [Float] = [0, 1]
        for i in ring.indices {
            let c = vertices[ring[i]]
            let d = vertices[ring[(i + 1) % ring.count]]
            guard MeshPredicates.segmentsTouchOrCross(a, b, c, d) else { continue }
            let denominator = (b.x - a.x) * (d.y - c.y) - (b.y - a.y) * (d.x - c.x)
            // Parallel, so there is no single crossing point. Any piece of the
            // bone lying along this edge is bounded by the neighbouring edges'
            // crossings, which are found on their own iterations.
            guard abs(denominator) > 1e-9 else { continue }
            let t = ((c.x - a.x) * (d.y - c.y) - (c.y - a.y) * (d.x - c.x)) / denominator
            if t > 0, t < 1 { cuts.append(t) }
        }
        cuts.sort()

        var inside: Float = 0
        for index in 1..<cuts.count {
            let lo = cuts[index - 1]
            let hi = cuts[index]
            guard hi - lo > 1e-7 else { continue }
            let mid = (lo + hi) * 0.5
            let point = a + (b - a) * mid
            if MeshKernel.pointInRing(points: vertices, ring: ring, point) {
                inside += (hi - lo) * total
            }
        }
        return inside
    }

    /// How far the outline reaches along `direction`, which is the most overlap
    /// a bone pointing that way could possibly have had here.
    private func hullSpan(along direction: SIMD2<Float>) -> Float {
        let ring = hullVertexIndices.map(Int.init)
        guard ring.count >= 3 else { return 0 }
        let length = simd_length(direction)
        guard length > 1e-9 else { return 0 }
        let unit = direction / length
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for index in ring {
            let projection = simd_dot(vertices[index], unit)
            lo = min(lo, projection)
            hi = max(hi, projection)
        }
        return max(0, hi - lo)
    }

    /// Measure a bone against this sprite's outline.
    ///
    /// - Parameters:
    ///   - start: the bone's joint, in world space.
    ///   - end: the bone's tip, in world space.
    ///   - pose: the sprite's pose, used to bring both into the outline's frame.
    ///     Bone world matrices are world space and `vertices` are local, and
    ///     comparing the two directly only agrees for a sprite parked at the
    ///     origin unrotated and unscaled.
    func fit(boneStart start: SIMD2<Float>, boneEnd end: SIMD2<Float>,
             pose: MeshBindPose?) -> BoneFit {
        let ring = hullVertexIndices.map(Int.init)
        guard ring.count >= 3 else { return .none }

        let localStart = pose?.localPoint(fromWorld: start) ?? start
        let localEnd = pose?.localPoint(fromWorld: end) ?? end
        let rooted = MeshKernel.pointInRing(points: vertices, ring: ring, localStart)

        let boneLength = simd_distance(localStart, localEnd)
        // A tip bone has no segment to measure; its joint is the whole of it.
        guard boneLength > 1e-6 else {
            return BoneFit(overlap: 0, boneFraction: rooted ? 1 : 0,
                           crossFraction: 0, originInside: rooted)
        }

        let overlap = insideHullLength(from: localStart, to: localEnd)
        let span = hullSpan(along: localEnd - localStart)
        return BoneFit(
            overlap: overlap,
            boneFraction: min(1, overlap / boneLength),
            crossFraction: span > 1e-9 ? min(1, overlap / span) : 0,
            originInside: rooted
        )
    }

    /// Binds one bone to this mesh, by hand.
    ///
    /// The skeleton is not a parameter any more: nothing here looks at the rig.
    /// It was only ever passed through to `autoWeights`, and that call is gone
    /// — see below.
    func addingBoneInfluence(
        bone: Bone,
        worldMatrix: simd_float4x4,
        maxInfluences: Int = 4,
        imagePose: MeshBindPose? = nil
    ) -> Mesh {
        var next = self
        if next.bindVertices.count != next.vertices.count {
            next.bindVertices = next.vertices
        }
        if next.bindImagePose == nil {
            next.bindImagePose = imagePose
        }
        if next.vertexBoneWeights.count != next.vertices.count {
            next.vertexBoneWeights = Array(repeating: [], count: next.vertices.count)
        }
        next.boneInverseBindMatrices[bone.id] = SavedMatrix4x4(simd_inverse(worldMatrix))

        // BINDS, AND DOES NOT PAINT. This used to end in `autoWeights` over
        // every bound bone, and `autoWeights` assigns `vertexBoneWeights`
        // wholesale — so adding one bone by hand with Bind Bones threw away
        // every weight the artist had painted, and the nodes came back in the
        // machine's colours.
        //
        // Auto-Bind and Auto-Weight were split apart for exactly this reason:
        // binding decides WHICH bones drive a sprite, painting decides HOW
        // MUCH. The manual button was never split with them. The bone is bound
        // with no weight anywhere, which `boundBoneIDs` counts as bound — so
        // it takes its place in the bound list, gets its colour, and the brush
        // can address it. `sanitizedSkinningData` still runs, because the
        // per-vertex invariants have to hold, but it only normalises what is
        // already there; it never invents a weight.
        return next.sanitizedSkinningData(maxInfluences: maxInfluences)
    }

    /// Every bone this mesh is bound to.
    ///
    /// The one definition of "bound". A bone counts if it has an inverse-bind
    /// matrix — Auto Bind wrote one for it — or if any vertex carries its
    /// weight. The two halves matter separately: `autoWeights` only reaches the
    /// bones a vertex is nearest to, so a genuinely bound bone can end up with
    /// no weight anywhere, and it is still bound.
    ///
    /// This used to be stated twice. The bound-bones list asked both questions
    /// and `refreshBoneBindingColors` asked only the second, so a bone Auto
    /// Bind had bound sat in the list with no colour — and a bone with no
    /// colour is a bone weight paint cannot address.
    var boundBoneIDs: Set<UUID> {
        var ids = Set(boneInverseBindMatrices.keys)
        for influences in vertexBoneWeights {
            for influence in influences {
                ids.insert(influence.boneID)
            }
        }
        return ids
    }

    func removingBoneInfluence(boneID: UUID, maxInfluences: Int = 4) -> Mesh {
        var next = self
        next.boneInverseBindMatrices.removeValue(forKey: boneID)
        if next.boneInverseBindMatrices.isEmpty {
            next.bindImagePose = nil
        }
        guard !next.vertexBoneWeights.isEmpty else { return next }
        for index in next.vertexBoneWeights.indices {
            next.vertexBoneWeights[index].removeAll { $0.boneID == boneID }
        }
        return next.sanitizedSkinningData(maxInfluences: maxInfluences)
    }

    /// Linear blend skinning, evaluated in world space.
    ///
    /// - Parameters:
    ///   - skeleton: Current skeleton state.
    ///   - currentPose: The sprite's current world pose. When provided, bind
    ///     vertices are lifted into world space through the pose captured at
    ///     bind time (`bindImagePose`), skinned there, and mapped back through
    ///     the inverse of `currentPose`. Because the renderer re-applies the
    ///     current pose afterwards, the final world position is exact —
    ///     rotating a bone moves the sprite rigidly around the bone origin.
    ///   - worldMatrices: Optional precomputed matrices (one computation per
    ///     frame instead of one per image).
    /// - Parameter presanitized: pass true when the receiver already went
    ///   through `sanitizedForRender` (which ends in `sanitizedSkinningData`).
    ///   Re-sanitizing is idempotent but copies every skinning array again, and
    ///   this runs per sprite per frame.
    func skinnedVertices(
        skeleton: Skeleton,
        currentPose: MeshBindPose? = nil,
        worldMatrices cachedMatrices: [UUID: simd_float4x4]? = nil,
        presanitized: Bool = false
    ) -> [SIMD2<Float>] {
        let prepared = presanitized ? self : sanitizedSkinningData()
        guard prepared.bindVertices.count == prepared.vertices.count,
              prepared.vertexBoneWeights.count == prepared.vertices.count,
              !prepared.boneInverseBindMatrices.isEmpty else {
            return prepared.vertices
        }

        let worldMatrices = cachedMatrices ?? skeleton.worldMatrices()
        // Legacy meshes have no stored bind pose; treating the current pose as
        // the bind pose keeps them stable (identity when bones haven't moved).
        let bindPose = prepared.bindImagePose ?? currentPose
        var deformed: [SIMD2<Float>] = prepared.vertices

        for index in prepared.bindVertices.indices {
            let bindLocal = prepared.bindVertices[index]
            let influences = prepared.vertexBoneWeights[index]
            guard !influences.isEmpty else {
                deformed[index] = bindLocal
                continue
            }

            // Bind position in the space the inverse-bind matrices expect.
            // With a pose available that is true world space; without one we
            // fall back to the legacy local-space behavior.
            let bindPoint: SIMD2<Float>
            if let bindPose, currentPose != nil {
                bindPoint = bindPose.worldPoint(fromLocal: bindLocal)
            } else {
                bindPoint = bindLocal
            }

            var accumulated = SIMD2<Float>(repeating: 0)
            var totalWeight: Float = 0
            let bind3 = SIMD3<Float>(bindPoint.x, bindPoint.y, 0)

            for influence in influences {
                guard influence.weight > 0,
                      let current = worldMatrices[influence.boneID],
                      let invBind = prepared.boneInverseBindMatrices[influence.boneID]?.matrix else { continue }
                let skinMatrix = current * invBind
                let transformed = MatrixUtilities.transformPoint(bind3, with: skinMatrix)
                accumulated += SIMD2<Float>(transformed.x, transformed.y) * influence.weight
                totalWeight += influence.weight
            }

            if totalWeight > 0.000001 {
                let blended = accumulated / totalWeight
                if currentPose != nil, let bindPose {
                    // Back through the BIND pose, not the current one.
                    //
                    // The renderer applies the current pose on top of whatever
                    // comes out of here. Mapping back through the current pose
                    // therefore cancelled it exactly — so once a sprite was
                    // skinned, Translate, Rotate, Scale and Shear wrote its
                    // transform and nothing on screen moved. It read as "the
                    // tools only work on bones after binding".
                    //
                    // Through the bind pose, the sprite's own transform is left
                    // for the renderer to apply: bones drive the mesh exactly
                    // as before (when nothing has moved the sprite the two
                    // poses are equal and this is the same expression), and the
                    // artist's delta since bind composes on top of it.
                    deformed[index] = bindPose.localPoint(fromWorld: blended)
                } else {
                    deformed[index] = blended
                }
            } else {
                deformed[index] = bindLocal
            }
        }

        return deformed
    }

    func generated(size: SIMD2<Float>, density: Float = 30) -> Mesh {
        if isQuadCompatible {
            return generatedGrid(size: size, subdivisions: 2)
        }

        guard hullVertexIndices.count >= 3 else { return self }
        let bounds = localBounds(for: hullVertexIndices.map(Int.init), vertices: vertices)
        let width = bounds.max.x - bounds.min.x
        let height = bounds.max.y - bounds.min.y
        let maxDimension = max(width, height)
        let minDimension = min(width, height)
        let area = width * height
        let aspectRatio = maxDimension / max(minDimension, 1)
        // For thin/elongated shapes the short axis must set the spacing, otherwise the
        // grid is wider than the shape and sampledInteriorPoints returns nothing.
        let baseSpacing = aspectRatio > 2.5 ? max(minDimension * 0.55, 8) : maxDimension / 5
        // Density (0…100) inversely scales spacing: more density → smaller spacing → more
        // interior points. At density=50 we approximate the previous default behavior;
        // lower values give sparser, more uniform layouts (which the user prefers).
        let d = max(0, min(100, density))
        let spacingMultiplier: Float = 1.7 - (d / 100.0) * 1.3   // 1.7 → 0.4
        let spacing = max(6, min(80, baseSpacing * spacingMultiplier))
        let estimatedCount = Int(area / (spacing * spacing * 0.86)) + 4
        let maxCount = max(0, min(200, estimatedCount))
        let interiorPoints = sampledInteriorPoints(spacing: spacing, maxCount: maxCount) { point in
            pointInsideHull(point)
        }
        return meshWithRetriangulatedInteriorPoints(interiorPoints, size: size)
    }

    func tracedHull(
        size: SIMD2<Float>,
        alphaSampler: (Int, Int) -> Float,
        detail: Float = 30,
        padding: Float = 1.2,
        concavity: Float = 100,
        alphaThreshold: Float = 0.08
    ) -> Mesh {
        let width = max(Int(size.x.rounded()), 1)
        let height = max(Int(size.y.rounded()), 1)
        var mask = Array(repeating: false, count: width * height)
        var occupiedCount = 0
        var weightedCenter = SIMD2<Float>(repeating: 0)
        var weightSum: Float = 0
        for y in 0..<height {
            for x in 0..<width {
                let alpha = alphaSampler(x, y)
                let solid = alpha > alphaThreshold
                mask[y * width + x] = solid
                if solid {
                    occupiedCount += 1
                    weightedCenter += SIMD2<Float>(Float(x), Float(y)) * alpha
                    weightSum += alpha
                }
            }
        }

        guard occupiedCount > 0 else {
            return resetToQuad(size: size)
        }

        // Find ALL connected components (not just the largest) so PNGs containing
        // multiple separate shapes (e.g. left+right eye sprites) get every shape
        // traced. Components below 5 % of the largest are discarded as noise.
        let components = findConnectedComponents(mask: mask, width: width, height: height)
        let sortedComponents = components.sorted { $0.count > $1.count }
        guard let largestComponent = sortedComponents.first else {
            return resetToQuad(size: size)
        }
        let minComponentSize = max(8, Int(Float(largestComponent.count) * 0.05))
        let keptComponents = sortedComponents.filter { $0.count >= minComponentSize }

        // Build a separate, simplified hull for each kept component using the
        // existing single-shape pipeline. Each hull is independent: corners,
        // smoothing, padding, concavity filter — all apply per-component.
        var componentHulls: [[SIMD2<Float>]] = []
        componentHulls.reserveCapacity(keptComponents.count)
        for component in keptComponents {
            var componentMask = Array(repeating: false, count: mask.count)
            for idx in component { componentMask[idx] = true }
            if let hull = simplifiedHullFromComponentMask(
                componentMask,
                width: width,
                height: height,
                size: size,
                detail: detail,
                padding: padding,
                concavity: concavity
            ), hull.count >= 3 {
                componentHulls.append(hull)
            }
        }

        // Fallback: if every component produced an empty hull (extreme edge case),
        // fall back to the radial sampler the legacy code already provides.
        var finalHull: [SIMD2<Float>]
        if componentHulls.isEmpty {
            if weightSum > 0 {
                let center = weightedCenter / weightSum
                let radial = legacyRadialHullSamples(
                    size: size,
                    width: width,
                    height: height,
                    center: center,
                    alphaThreshold: alphaThreshold,
                    alphaSampler: alphaSampler
                )
                guard radial.count >= 3 else { return resetToQuad(size: size) }
                finalHull = radial
            } else {
                return resetToQuad(size: size)
            }
        } else if componentHulls.count == 1 {
            finalHull = componentHulls[0]
        } else {
            // Multiple components: stitch them into one closed loop with keyhole
            // bridges. Bridges live in transparent area so triangles spanning them
            // are removed downstream by filterTrianglesToOpaqueArea.
            finalHull = stitchHullsViaKeyhole(componentHulls)
        }

        let uvs = finalHull.map { Self.uv(for: $0, size: size) }
        let hullIndices = Array(0..<finalHull.count).map(UInt16.init)
        var mesh = Mesh(
            name: name,
            vertices: finalHull,
            uvs: uvs,
            indices: [],
            hullVertexIndices: hullIndices,
            internalEdges: [],
            manualTriangles: []
        )
        let hullTriangles = mesh.triangulatedHullIndices()
        // Use a stricter visibility threshold for triangulation than the boundary detection.
        // The boundary trace uses 0.08 to capture anti-aliased rims, but a triangle edge that
        // travels over alpha < 0.5 is visually crossing transparent territory.
        let visibleThreshold: Float = max(alphaThreshold, 0.5)
        let filteredHullTriangles = mesh.filterTrianglesToOpaqueArea(
            triangles: hullTriangles,
            size: size,
            alphaSampler: alphaSampler,
            alphaThreshold: visibleThreshold,
            minOpaqueSamples: 6
        )
        mesh.indices = filteredHullTriangles.isEmpty ? hullTriangles : filteredHullTriangles
        return mesh
    }

    func constrainedToOpaqueArea(
        size: SIMD2<Float>,
        alphaSampler: (Int, Int) -> Float,
        alphaThreshold: Float = 0.08
    ) -> Mesh {
        var next = self
        let sourceTriangles: [UInt16] = next.indices.isEmpty
            ? next.triangulatedIndicesWithInternalEdges()
            : next.indices
        let filtered = next.filterTrianglesToOpaqueArea(
            triangles: sourceTriangles,
            size: size,
            alphaSampler: alphaSampler,
            alphaThreshold: alphaThreshold
        )
        // Keep mesh stable: avoid aggressive pruning/reconnection passes that can
        // create sparse or broken networks. Use robust opaque-area filtering only.
        next.indices = filtered.isEmpty ? sourceTriangles : filtered
        return next
    }

    private func legacyRadialHullSamples(
        size: SIMD2<Float>,
        width: Int,
        height: Int,
        center: SIMD2<Float>,
        alphaThreshold: Float,
        alphaSampler: (Int, Int) -> Float
    ) -> [SIMD2<Float>] {
        let detail = max(20, min(64, Int((Float(width + height) / 52).rounded(.up))))
        let maxDistance = Int(max(size.x, size.y))
        var samples: [SIMD2<Float>] = []
        samples.reserveCapacity(detail)

        for step in 0..<detail {
            let angle = (Float(step) / Float(detail)) * (Float.pi * 2)
            let direction = SIMD2<Float>(cos(angle), sin(angle))
            var hit: SIMD2<Float>?
            for distance in stride(from: maxDistance, through: 1, by: -1) {
                let point = center + direction * Float(distance)
                let x = Int(point.x.rounded())
                let y = Int(point.y.rounded())
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                if alphaSampler(x, y) > alphaThreshold {
                    hit = SIMD2<Float>(Float(x), Float(y))
                    break
                }
            }
            if let hit {
                let local = SIMD2<Float>(hit.x - size.x * 0.5, size.y * 0.5 - hit.y)
                if samples.last.map({ simd_distance($0, local) > 2.5 }) ?? true {
                    samples.append(local)
                }
            }
        }

        let simplified = simplifyHull(samples, minimumDistance: 4)
        return simplified.count >= 3 ? simplified : samples
    }

    func insertingHullVertex(localPosition: SIMD2<Float>, afterHullEdge edgeIndex: Int) -> (mesh: Mesh, insertedIndex: Int)? {
        guard hullVertexIndices.count >= 2,
              hullVertexIndices.indices.contains(edgeIndex) else {
            return nil
        }

        let startIndex = Int(hullVertexIndices[edgeIndex])
        let endIndex = Int(hullVertexIndices[(edgeIndex + 1) % hullVertexIndices.count])
        guard vertices.indices.contains(startIndex),
              vertices.indices.contains(endIndex),
              uvs.indices.contains(startIndex),
              uvs.indices.contains(endIndex) else {
            return nil
        }

        let start = vertices[startIndex]
        let end = vertices[endIndex]
        let segment = end - start
        let segmentLengthSquared = simd_length_squared(segment)
        let t: Float
        if segmentLengthSquared > 0.0001 {
            t = max(0, min(1, simd_dot(localPosition - start, segment) / segmentLengthSquared))
        } else {
            t = 0.5
        }
        let interpolatedUV = simd_mix(uvs[startIndex], uvs[endIndex], SIMD2<Float>(repeating: t))

        var next = self
        let insertedIndex = next.vertices.count
        next.vertices.append(localPosition)
        next.uvs.append(interpolatedUV)
        if !next.bindVertices.isEmpty {
            next.bindVertices.append(localPosition)
        }
        if !next.vertexBoneWeights.isEmpty {
            next.vertexBoneWeights.append([])
        }
        next.hullVertexIndices.insert(UInt16(insertedIndex), at: edgeIndex + 1)
        // One geometric path for every mutation. If the outline cannot be
        // filled with the new point in it, refuse rather than store a gap.
        guard let retriangulated = try? next.kernelTriangulatedIndices() else { return nil }
        next.indices = retriangulated
        next = next.sanitizedSkinningData()
        return (next, insertedIndex)
    }

    func insertingInteriorVertex(
        localPosition: SIMD2<Float>,
        size: SIMD2<Float>,
        alphaSampler: ((Int, Int) -> Float)? = nil,
        alphaThreshold: Float = 0.08
    ) -> (mesh: Mesh, insertedIndex: Int)? {
        guard hullVertexIndices.count >= 3 else { return nil }

        // Hard constraint: interior vertices can only be created inside the hull (or on its boundary).
        // This prevents any tool/path from placing interior vertices outside the edge line.
        let insideHull = pointInsideHull(localPosition) || pointOnHullBoundary(localPosition, epsilon: 1.25)
        guard insideHull else { return nil }
        var next = self
        let insertedIndex = next.vertices.count
        next.vertices.append(localPosition)
        next.uvs.append(Self.uv(for: localPosition, size: size))
        if !next.bindVertices.isEmpty {
            next.bindVertices.append(localPosition)
        }
        if !next.vertexBoneWeights.isEmpty {
            next.vertexBoneWeights.append([])
        }

        // Splitting the containing triangle and then flipping toward Delaunay
        // is precisely what the kernel does, so hand it the point and let it do
        // that once — rather than keep a second implementation of the same
        // pipeline here and have the kernel immediately overwrite its result.
        // Watertight by construction, Delaunay quality, and it refuses instead
        // of returning something partial.
        guard let retriangulated = try? next.kernelTriangulatedIndices() else { return nil }
        next.indices = retriangulated

        next = next.sanitizedSkinningData()
        return (next, insertedIndex)
    }

    /// The result of a topology change: the new mesh plus how old vertex
    /// indices map onto new ones.
    ///
    /// The remap is not a convenience — it is the whole point. Vertices, UVs,
    /// weights and bind pose travel with the mesh, but `meshAnimationDeform`
    /// and every `.meshDeform` keyframe live on `SceneImage` as plain
    /// per-vertex arrays addressed by index. Compacting the vertex list without
    /// rewriting them leaves every deform key one element too long and pointing
    /// at the wrong vertices, and `UMJSONExportBuilder` drops any key whose
    /// count does not match the mesh — so deleting a single vertex silently
    /// destroyed that sprite's entire deform animation at export time, with no
    /// symptom in the editor until the work was already gone.
    struct TopologyChange {
        var mesh: Mesh
        /// Old index -> new index. Removed vertices are absent.
        var remap: [Int: Int]

        /// Rewrite a per-vertex array so each surviving vertex keeps its value.
        /// Vertices with no old counterpart take their value from `fallback`.
        func remapped(_ perVertex: [SIMD2<Float>], fallback: [SIMD2<Float>]) -> [SIMD2<Float>] {
            var result = fallback
            for (old, new) in remap
            where perVertex.indices.contains(old) && result.indices.contains(new) {
                result[new] = perVertex[old]
            }
            return result
        }
    }

    func removingVertices(_ removed: Set<Int>) -> TopologyChange? {
        guard !removed.isEmpty else {
            return TopologyChange(
                mesh: self,
                remap: Dictionary(uniqueKeysWithValues: vertices.indices.map { ($0, $0) }))
        }
        let remainingHull = hullVertexIndices.enumerated().compactMap { offset, rawIndex -> UInt16? in
            let index = Int(rawIndex)
            return removed.contains(index) ? nil : rawIndex
        }
        guard remainingHull.count >= 3 else { return nil }

        var remap: [Int: Int] = [:]
        var nextVertices: [SIMD2<Float>] = []
        var nextUVs: [SIMD2<Float>] = []
        var nextBindVertices: [SIMD2<Float>] = []
        var nextWeights: [[VertexBoneWeight]] = []
        nextVertices.reserveCapacity(vertices.count - removed.count)
        nextUVs.reserveCapacity(uvs.count - removed.count)
        nextBindVertices.reserveCapacity(vertices.count - removed.count)
        nextWeights.reserveCapacity(vertices.count - removed.count)

        for index in vertices.indices where !removed.contains(index) {
            remap[index] = nextVertices.count
            nextVertices.append(vertices[index])
            nextUVs.append(uvs[index])
            if bindVertices.indices.contains(index) {
                nextBindVertices.append(bindVertices[index])
            }
            if vertexBoneWeights.indices.contains(index) {
                nextWeights.append(vertexBoneWeights[index])
            }
        }

        let nextHull = remainingHull.compactMap { rawIndex -> UInt16? in
            guard let mapped = remap[Int(rawIndex)] else { return nil }
            return UInt16(mapped)
        }
        guard nextHull.count >= 3 else { return nil }

        var next = self
        next.vertices = nextVertices
        next.uvs = nextUVs
        next.bindVertices = nextBindVertices
        next.vertexBoneWeights = nextWeights
        next.hullVertexIndices = nextHull
        next.internalEdges = internalEdges.compactMap { edge -> MeshEdge? in
            guard let mappedA = remap[Int(edge.a)],
                  let mappedB = remap[Int(edge.b)],
                  mappedA != mappedB else {
                return nil
            }
            return MeshEdge(UInt16(mappedA), UInt16(mappedB))
        }
        next.manualTriangles = manualTriangles.compactMap { triangle -> MeshTriangle? in
            guard let mappedA = remap[Int(triangle.a)],
                  let mappedB = remap[Int(triangle.b)],
                  let mappedC = remap[Int(triangle.c)] else {
                return nil
            }
            guard Set([mappedA, mappedB, mappedC]).count == 3 else {
                return nil
            }
            return MeshTriangle(UInt16(mappedA), UInt16(mappedB), UInt16(mappedC))
        }
        // Retriangulate through the kernel. If the reduced outline is not a
        // legal polygon — deleting a boundary point joins its two neighbours
        // with a straight segment, and on a concave silhouette that segment can
        // cross another part of the outline or double back along it — refuse the
        // whole edit rather than store a torn mesh. Verified in the Python edit
        // fuzz: 444 of 40 000 random edits produced an illegal outline, every
        // one was refused, and every mesh stayed watertight.
        do {
            next.indices = try next.kernelTriangulatedIndices()
        } catch {
            return nil
        }
        return TopologyChange(mesh: next.sanitizedSkinningData(), remap: remap)
    }

    func connectingVertices(_ first: Int, _ second: Int) -> Mesh {
        guard vertices.indices.contains(first),
              vertices.indices.contains(second),
              first != second else { return self }

        let edge = MeshEdge(UInt16(first), UInt16(second))
        // Don't add duplicate edges or hull-boundary edges.
        let hullEdges = Set(hullBoundaryEdges())
        guard !hullEdges.contains(edge),
              !internalEdges.contains(edge) else { return self }

        var next = self
        next.internalEdges.append(edge)
        // The new edge becomes a constraint the flip pass must preserve.
        guard let retriangulated = try? next.kernelTriangulatedIndices() else { return self }
        next.indices = retriangulated
        return next
    }

    func creatingFace(_ first: Int, _ second: Int, _ third: Int) -> Mesh {
        let indices = [first, second, third]
        guard indices.allSatisfy(vertices.indices.contains),
              Set(indices).count == 3 else { return self }

        // Validate the triangle: all edges must lie inside the hull.
        let a = vertices[first]
        let b = vertices[second]
        let c = vertices[third]
        guard segmentInsideHull(a, b),
              segmentInsideHull(b, c),
              segmentInsideHull(c, a) else { return self }

        let area = signedArea(a, b, c)
        guard abs(area) > 0.0001 else { return self }

        let face: MeshTriangle
        if area < 0 {
            face = MeshTriangle(UInt16(first), UInt16(second), UInt16(third))
        } else {
            face = MeshTriangle(UInt16(first), UInt16(third), UInt16(second))
        }

        // Avoid duplicate faces.
        let key = face.normalizedKey()
        guard !manualTriangles.contains(where: { $0.normalizedKey() == key }) else { return self }

        var next = self
        next.manualTriangles.append(face)
        next.indices = next.triangulatedIndicesWithInternalEdges()
        return next
    }

    func clearingInternalEdges() -> Mesh {
        var next = self
        next.internalEdges = []
        next.manualTriangles = []
        next.indices = next.triangulatedHullIndices()
        return next
    }

    func clampedPositionInsideHullIfNeeded(vertexIndex: Int, proposed: SIMD2<Float>) -> SIMD2<Float> {
        guard vertices.indices.contains(vertexIndex) else { return proposed }
        let hullSet = Set(hullVertexIndices.map(Int.init))
        guard !hullSet.contains(vertexIndex) else { return proposed }
        guard hullVertexIndices.count >= 3 else { return proposed }
        if pointInsideHull(proposed) || pointOnHullBoundary(proposed, epsilon: 0.75) {
            return proposed
        }

        let hullIndices = hullVertexIndices.map(Int.init)
        var bestPoint = proposed
        var bestDistance = Float.greatestFiniteMagnitude
        for edgeIndex in hullIndices.indices {
            let aIndex = hullIndices[edgeIndex]
            let bIndex = hullIndices[(edgeIndex + 1) % hullIndices.count]
            guard vertices.indices.contains(aIndex), vertices.indices.contains(bIndex) else { continue }
            let a = vertices[aIndex]
            let b = vertices[bIndex]
            let projected = closestPointOnSegment(point: proposed, a: a, b: b)
            let distance = simd_distance(proposed, projected)
            if distance < bestDistance {
                bestDistance = distance
                bestPoint = projected
            }
        }
        return bestPoint
    }

    func clampingInteriorVerticesInsideHull(size: SIMD2<Float>) -> Mesh {
        guard hullVertexIndices.count >= 3 else { return self }

        var next = self
        let hullSet = Set(hullVertexIndices.map(Int.init))
        let hullIndices = hullVertexIndices.map(Int.init)
        guard hullIndices.count >= 3 else { return self }

        var didAdjust = false
        for index in next.vertices.indices where !hullSet.contains(index) {
            let vertex = next.vertices[index]
            if next.pointInsideHull(vertex) || next.pointOnHullBoundary(vertex, epsilon: 0.75) {
                continue
            }

            var bestPoint = vertex
            var bestDistance = Float.greatestFiniteMagnitude
            for edgeIndex in hullIndices.indices {
                let aIndex = hullIndices[edgeIndex]
                let bIndex = hullIndices[(edgeIndex + 1) % hullIndices.count]
                guard next.vertices.indices.contains(aIndex), next.vertices.indices.contains(bIndex) else { continue }
                let a = next.vertices[aIndex]
                let b = next.vertices[bIndex]
                let projected = next.closestPointOnSegment(point: vertex, a: a, b: b)
                let distance = simd_distance(vertex, projected)
                if distance < bestDistance {
                    bestDistance = distance
                    bestPoint = projected
                }
            }

            next.vertices[index] = bestPoint
            if next.uvs.indices.contains(index) {
                next.uvs[index] = Mesh.uv(for: bestPoint, size: size)
            }
            didAdjust = true
        }

        if didAdjust {
            next.indices = next.triangulatedIndicesWithInternalEdges()
        }
        return next
    }

    func triangulatedHullIndices() -> [UInt16] {
        let polygon = hullVertexIndices.map(Int.init)
        return triangulatePolygonIndices(polygon)
    }

    /// Which triangle contains `point`, and its barycentric weights there.
    ///
    /// Used to give a newly inserted vertex a deform value consistent with its
    /// neighbours, so subdividing an animated mesh does not make the new point
    /// snap back to its bind position on every deformed frame.
    func barycentricSample(at point: SIMD2<Float>)
        -> (a: Int, b: Int, c: Int, wa: Float, wb: Float, wc: Float)? {
        guard indices.count >= 3 else { return nil }
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let ia = Int(indices[t]), ib = Int(indices[t + 1]), ic = Int(indices[t + 2])
            guard vertices.indices.contains(ia),
                  vertices.indices.contains(ib),
                  vertices.indices.contains(ic) else { continue }
            let a = vertices[ia], b = vertices[ib], c = vertices[ic]

            let total = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
            guard abs(total) > 1e-12 else { continue }
            let wa = ((b.x - point.x) * (c.y - point.y) - (c.x - point.x) * (b.y - point.y)) / total
            let wb = ((c.x - point.x) * (a.y - point.y) - (a.x - point.x) * (c.y - point.y)) / total
            let wc = 1 - wa - wb
            let slack: Float = -1e-4
            guard wa >= slack, wb >= slack, wc >= slack else { continue }
            return (ia, ib, ic, wa, wb, wc)
        }
        return nil
    }

    /// Containment test against the outline, using the same exact predicates as
    /// the kernel so a point can never be accepted here and rejected there.
    func pointInsideHullForKernel(_ point: SIMD2<Float>) -> Bool {
        MeshKernel.pointInRing(points: vertices, ring: hullVertexIndices.map(Int.init), point)
    }

    /// Indices of vertices that are not on the outline.
    var interiorVertexIndices: [Int] {
        let hullSet = Set(hullVertexIndices.map(Int.init))
        return vertices.indices.filter { !hullSet.contains($0) }
    }

    /// Retriangulate through `MeshKernel`, the single geometric path.
    ///
    /// Throws rather than returning something partial. Callers treat a throw as
    /// "refuse this edit and leave the mesh alone", which is what makes an
    /// outline that cannot be filled impossible to *save* rather than merely
    /// unlikely to be drawn.
    func kernelTriangulatedIndices() throws -> [UInt16] {
        try MeshKernel.triangulate(
            points: vertices,
            boundary: MeshKernel.Boundary(outer: hullVertexIndices.map(Int.init)),
            interior: interiorVertexIndices,
            constraints: internalEdges.map { (Int($0.a), Int($0.b)) }
        )
    }

    /// Retriangulate and return the updated mesh, or throw if the outline is not fillable.
    func retriangulated() throws -> Mesh {
        var next = self
        next.indices = try next.kernelTriangulatedIndices()
        return next
    }

    /// Check this mesh against every invariant.
    func validationReport() -> MeshValidator.Report {
        MeshValidator.validate(
            points: vertices,
            triangles: indices,
            outer: hullVertexIndices.map(Int.init),
            holes: []
        )
    }

    func triangulatedIndicesWithInternalEdges() -> [UInt16] {
        // One geometric path. The branch that used to be here ran an
        // unconstrained Bowyer-Watson and then discarded triangles straddling
        // the outline, with nothing generated to replace them — measured at
        // 97.8 % coverage on the bone silhouette from the bug report and 57.1 %
        // on a comb. The kernel is watertight by construction instead.
        //
        // If it refuses, the outline is genuinely not fillable. The hull fan
        // keeps this function total for callers that cannot throw; callers that
        // can should use `retriangulated()` and refuse the edit.
        var triangles: [UInt16]
        do {
            triangles = try kernelTriangulatedIndices()
        } catch {
            triangles = triangulatedHullIndices()
        }
        if triangles.isEmpty {
            triangles = triangulatedHullIndices()
        }

        // Keep compatibility with manual-face workflow if/when used.
        let manual = sanitizedManualTriangles()
        triangles = generatedTrianglesByRemovingTrianglesCoveredByManualFaces(triangles, manualTriangles: manual)
        if !manual.isEmpty {
            for face in manual {
                triangles.append(face.a)
                triangles.append(face.b)
                triangles.append(face.c)
            }
        }
        let sanitized = sanitizedTriangleIndices(triangles)
        if !sanitized.isEmpty {
            return sanitized
        }
        return sanitizedTriangleIndices(triangulatedHullIndices())
    }

    private func sanitizedTriangleIndices(_ triangles: [UInt16]) -> [UInt16] {
        guard triangles.count >= 3 else { return [] }
        var result: [UInt16] = []
        result.reserveCapacity(triangles.count)
        var seen = Set<[UInt16]>()

        for i in stride(from: 0, to: triangles.count, by: 3) {
            guard i + 2 < triangles.count else { break }
            let ia = Int(triangles[i])
            let ib = Int(triangles[i + 1])
            let ic = Int(triangles[i + 2])
            guard vertices.indices.contains(ia),
                  vertices.indices.contains(ib),
                  vertices.indices.contains(ic) else { continue }
            guard ia != ib, ib != ic, ia != ic else { continue }

            let a = vertices[ia]
            let b = vertices[ib]
            let c = vertices[ic]
            guard abs(signedArea(a, b, c)) > 0.0001 else { continue }

            let key = [UInt16(ia), UInt16(ib), UInt16(ic)].sorted()
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            result.append(UInt16(ia))
            result.append(UInt16(ib))
            result.append(UInt16(ic))
        }

        return result
    }

    private func convexHullVertexIndices() -> [Int] {
        guard vertices.count >= 3 else { return [] }
        let points: [(index: Int, p: SIMD2<Float>)] = vertices.enumerated().map { ($0.offset, $0.element) }
            .sorted { lhs, rhs in
                if lhs.p.x == rhs.p.x { return lhs.p.y < rhs.p.y }
                return lhs.p.x < rhs.p.x
            }

        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [(index: Int, p: SIMD2<Float>)] = []
        for point in points {
            while lower.count >= 2 &&
                    cross(lower[lower.count - 2].p, lower[lower.count - 1].p, point.p) <= 0 {
                _ = lower.popLast()
            }
            lower.append(point)
        }

        var upper: [(index: Int, p: SIMD2<Float>)] = []
        for point in points.reversed() {
            while upper.count >= 2 &&
                    cross(upper[upper.count - 2].p, upper[upper.count - 1].p, point.p) <= 0 {
                _ = upper.popLast()
            }
            upper.append(point)
        }

        var hull: [(index: Int, p: SIMD2<Float>)] = Array(lower.dropLast()) + Array(upper.dropLast())
        if hull.count < 3 {
            hull = Array(points.prefix(3))
        }
        return hull.map { $0.index }
    }

    private func deduplicatedRing(_ indices: [Int]) -> [Int] {
        guard !indices.isEmpty else { return [] }
        var seen = Set<Int>()
        var result: [Int] = []
        result.reserveCapacity(indices.count)
        for idx in indices where !seen.contains(idx) {
            seen.insert(idx)
            result.append(idx)
        }
        return result
    }

    private func triangulatePolygonIndices(_ polygon: [Int]) -> [UInt16] {
        guard polygon.count >= 3 else { return [] }
        if polygon.count == 3 {
            return polygon.map(UInt16.init)
        }
        let cleaned = cleanedPolygonIndices(polygon)
        guard cleaned.count >= 3 else { return [] }
        if cleaned.count == 3 { return cleaned.map(UInt16.init) }

        var remaining = cleaned
        var triangles: [UInt16] = []
        triangles.reserveCapacity((cleaned.count - 2) * 3)
        let eps: Float = 0.0001

        let orientation = polygonSignedArea(indices: remaining) >= 0 ? Float(1) : Float(-1)

        while remaining.count > 3 {
            var earFound = false
            var bestEarIndex: Int?
            var bestEarScore = Float.greatestFiniteMagnitude

            for i in remaining.indices {
                let prevIdx = remaining[(i - 1 + remaining.count) % remaining.count]
                let currIdx = remaining[i]
                let nextIdx = remaining[(i + 1) % remaining.count]
                let a = vertices[prevIdx]
                let b = vertices[currIdx]
                let c = vertices[nextIdx]
                let turn = signedArea(a, b, c) * orientation
                if turn <= eps { continue }

                var containsOtherVertex = false
                for candidate in remaining where candidate != prevIdx && candidate != currIdx && candidate != nextIdx {
                    if pointInTriangleWithEpsilon(vertices[candidate], a, b, c, epsilon: eps) {
                        containsOtherVertex = true
                        break
                    }
                }
                if containsOtherVertex { continue }

                let edgeScore = simd_distance(a, c)
                if edgeScore < bestEarScore {
                    bestEarScore = edgeScore
                    bestEarIndex = i
                }
                earFound = true
            }

            if earFound, let i = bestEarIndex {
                let prevIdx = remaining[(i - 1 + remaining.count) % remaining.count]
                let currIdx = remaining[i]
                let nextIdx = remaining[(i + 1) % remaining.count]
                triangles.append(UInt16(prevIdx))
                triangles.append(UInt16(currIdx))
                triangles.append(UInt16(nextIdx))
                remaining.remove(at: i)
                continue
            }

            // Recovery path: remove the most collinear vertex to keep triangulation local
            // instead of collapsing to a star fan from a single root.
            var weakestIndex = 0
            var weakestMagnitude = Float.greatestFiniteMagnitude
            for i in remaining.indices {
                let prevIdx = remaining[(i - 1 + remaining.count) % remaining.count]
                let currIdx = remaining[i]
                let nextIdx = remaining[(i + 1) % remaining.count]
                let turnMag = abs(signedArea(vertices[prevIdx], vertices[currIdx], vertices[nextIdx]))
                if turnMag < weakestMagnitude {
                    weakestMagnitude = turnMag
                    weakestIndex = i
                }
            }
            let prevIdx = remaining[(weakestIndex - 1 + remaining.count) % remaining.count]
            let currIdx = remaining[weakestIndex]
            let nextIdx = remaining[(weakestIndex + 1) % remaining.count]
            triangles.append(UInt16(prevIdx))
            triangles.append(UInt16(currIdx))
            triangles.append(UInt16(nextIdx))
            remaining.remove(at: weakestIndex)
        }

        triangles.append(UInt16(remaining[0]))
        triangles.append(UInt16(remaining[1]))
        triangles.append(UInt16(remaining[2]))
        return triangles
    }

    private func cleanedPolygonIndices(_ polygon: [Int]) -> [Int] {
        guard polygon.count >= 3 else { return polygon }
        var unique: [Int] = []
        unique.reserveCapacity(polygon.count)
        for idx in polygon {
            guard vertices.indices.contains(idx) else { continue }
            if let last = unique.last, simd_distance(vertices[last], vertices[idx]) < 0.35 {
                continue
            }
            unique.append(idx)
        }
        if unique.count > 2,
           let first = unique.first,
           let last = unique.last,
           simd_distance(vertices[first], vertices[last]) < 0.35 {
            _ = unique.popLast()
        }
        guard unique.count > 3 else { return unique }

        var filtered: [Int] = []
        filtered.reserveCapacity(unique.count)
        for i in unique.indices {
            let prev = unique[(i - 1 + unique.count) % unique.count]
            let curr = unique[i]
            let next = unique[(i + 1) % unique.count]
            let area = abs(signedArea(vertices[prev], vertices[curr], vertices[next]))
            if area > 0.00001 {
                filtered.append(curr)
            }
        }
        return filtered.count >= 3 ? filtered : unique
    }

    private func polygonSignedArea(indices: [Int]) -> Float {
        guard indices.count >= 3 else { return 0 }
        var area: Float = 0
        var j = indices.count - 1
        for i in 0..<indices.count {
            let pj = vertices[indices[j]]
            let pi = vertices[indices[i]]
            area += (pj.x * pi.y) - (pi.x * pj.y)
            j = i
        }
        return area * 0.5
    }

    private func pointInTriangleWithEpsilon(
        _ point: SIMD2<Float>,
        _ a: SIMD2<Float>,
        _ b: SIMD2<Float>,
        _ c: SIMD2<Float>,
        epsilon: Float
    ) -> Bool {
        let ab = signedArea(a, b, point)
        let bc = signedArea(b, c, point)
        let ca = signedArea(c, a, point)
        let hasNeg = (ab < -epsilon) || (bc < -epsilon) || (ca < -epsilon)
        let hasPos = (ab > epsilon) || (bc > epsilon) || (ca > epsilon)
        return !(hasNeg && hasPos)
    }

    private func slicePolygon(_ polygon: [Int], from start: Int, to end: Int) -> [Int] {
        guard !polygon.isEmpty else { return [] }
        var result: [Int] = [polygon[start]]
        var index = start
        while index != end {
            index = (index + 1) % polygon.count
            result.append(polygon[index])
        }
        return result
    }

    private func generatedGrid(size: SIMD2<Float>, subdivisions: Int) -> Mesh {
        let columns = subdivisions + 1
        let rows = subdivisions + 1
        var vertices: [SIMD2<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt16] = []
        vertices.reserveCapacity(columns * rows)
        uvs.reserveCapacity(columns * rows)
        indices.reserveCapacity(subdivisions * subdivisions * 6)

        for row in 0..<rows {
            let v = Float(row) / Float(subdivisions)
            for column in 0..<columns {
                let u = Float(column) / Float(subdivisions)
                let uv = SIMD2<Float>(u, v)
                uvs.append(uv)
                vertices.append(Self.localPosition(for: uv, size: size))
            }
        }

        for row in 0..<subdivisions {
            for column in 0..<subdivisions {
                let topLeft = UInt16(row * columns + column)
                let topRight = topLeft + 1
                let bottomLeft = UInt16((row + 1) * columns + column)
                let bottomRight = bottomLeft + 1
                indices.append(contentsOf: [topLeft, topRight, bottomLeft, bottomLeft, topRight, bottomRight])
            }
        }

        let hullVertexIndices: [UInt16] = [0, UInt16(columns - 1), UInt16(vertices.count - 1), UInt16(vertices.count - columns)]
        return Mesh(
            name: name,
            vertices: vertices,
            uvs: uvs,
            indices: indices,
            hullVertexIndices: hullVertexIndices,
            internalEdges: [],
            manualTriangles: []
        )
    }

    private func meshWithRetriangulatedInteriorPoints(_ interiorPoints: [SIMD2<Float>], size: SIMD2<Float>) -> Mesh {
        var next = self
        next.vertices = hullVertexIndices.compactMap { index in
            let resolvedIndex = Int(index)
            return vertices.indices.contains(resolvedIndex) ? vertices[resolvedIndex] : nil
        }
        next.uvs = next.vertices.map { Self.uv(for: $0, size: size) }
        next.hullVertexIndices = Array(0..<next.vertices.count).map(UInt16.init)
        next.internalEdges = []
        next.manualTriangles = []

        // The kernel does exactly this: tile the outline exactly, then split the
        // containing triangle for each interior point (area-preserving), then
        // flip toward Delaunay (also area-preserving). Running it once replaces
        // a second, hand-rolled copy of the same pipeline.
        //
        // Points are filtered before being appended, so one landing outside the
        // outline is never added at all — rather than added and then removed,
        // which is how the old loop could leave a vertex with no triangle
        // referencing it.
        let hullCount = next.vertices.count
        for point in interiorPoints {
            guard next.vertices.allSatisfy({ simd_distance($0, point) >= 6 }) else { continue }
            guard next.pointInsideHullForKernel(point) else { continue }
            next.vertices.append(point)
            next.uvs.append(Self.uv(for: point, size: size))
        }

        if let triangles = try? next.kernelTriangulatedIndices() {
            next.indices = triangles
        } else {
            // The outline itself is not fillable; fall back to the hull fan so
            // the sprite still renders while the artist fixes the outline.
            next.vertices = Array(next.vertices.prefix(hullCount))
            next.uvs = Array(next.uvs.prefix(hullCount))
            next.indices = next.triangulatedHullIndices()
        }

        return next
    }


    private func insertingInteriorVertices(
        size: SIMD2<Float>,
        spacing: Float,
        maxCount: Int,
        isInside: (SIMD2<Float>) -> Bool
    ) -> Mesh {
        guard maxCount > 0, hullVertexIndices.count >= 3 else { return self }
        let hullIndices = hullVertexIndices.map(Int.init)
        let bounds = localBounds(for: hullIndices, vertices: vertices)
        guard bounds.max.x > bounds.min.x, bounds.max.y > bounds.min.y else { return self }

        var next = self
        var insertedCount = 0
        let startY = bounds.min.y + spacing * 0.5
        let endY = bounds.max.y - spacing * 0.5
        let startX = bounds.min.x + spacing * 0.5
        let endX = bounds.max.x - spacing * 0.5
        guard startX <= endX, startY <= endY else { return self }

        var row = 0
        var y = startY
        while y <= endY && insertedCount < maxCount {
            let offsetX = row.isMultiple(of: 2) ? 0 : spacing * 0.5
            var x = startX + offsetX
            while x <= endX && insertedCount < maxCount {
                let point = SIMD2<Float>(x, y)
                if isInside(point),
                   next.pointInsideHull(point),
                   next.vertices.allSatisfy({ simd_distance($0, point) >= spacing * 0.55 }),
                   let result = next.insertingInteriorVertex(localPosition: point, size: size) {
                    next = result.mesh
                    insertedCount += 1
                }
                x += spacing
            }
            y += spacing * 0.86
            row += 1
        }

        return next
    }

    private func sampledInteriorPoints(
        spacing: Float,
        maxCount: Int,
        isInside: (SIMD2<Float>) -> Bool
    ) -> [SIMD2<Float>] {
        guard maxCount > 0, hullVertexIndices.count >= 3 else { return [] }
        let hullIndices = hullVertexIndices.map(Int.init)
        let bounds = localBounds(for: hullIndices, vertices: vertices)
        guard bounds.max.x > bounds.min.x, bounds.max.y > bounds.min.y else { return [] }

        var points: [SIMD2<Float>] = []
        points.reserveCapacity(maxCount)
        let startY = bounds.min.y + spacing * 0.5
        let endY = bounds.max.y - spacing * 0.5
        let startX = bounds.min.x + spacing * 0.5
        let endX = bounds.max.x - spacing * 0.5
        guard startX <= endX, startY <= endY else { return [] }

        var row = 0
        var y = startY
        while y <= endY && points.count < maxCount {
            let offsetX = row.isMultiple(of: 2) ? 0 : spacing * 0.5
            var x = startX + offsetX
            while x <= endX && points.count < maxCount {
                let point = SIMD2<Float>(x, y)
                if isInside(point),
                   vertices.allSatisfy({ simd_distance($0, point) >= spacing * 0.5 }),
                   points.allSatisfy({ simd_distance($0, point) >= spacing * 0.85 }) {
                    points.append(point)
                }
                x += spacing
            }
            y += spacing * 0.86
            row += 1
        }

        return points
    }

    private func pointInsideHull(_ point: SIMD2<Float>) -> Bool {
        let polygon = hullVertexIndices.map(Int.init)
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.last!
        for current in polygon {
            let a = vertices[previous]
            let b = vertices[current]
            let intersects = ((a.y > point.y) != (b.y > point.y)) &&
                (point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x)
            if intersects {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }

    private func pointOnHullBoundary(_ point: SIMD2<Float>, epsilon: Float = 0.8) -> Bool {
        let polygon = hullVertexIndices.map(Int.init)
        guard polygon.count >= 2 else { return false }
        for i in polygon.indices {
            let a = vertices[polygon[i]]
            let b = vertices[polygon[(i + 1) % polygon.count]]
            if Mesh.pointDistanceToSegment(point, a, b) <= epsilon {
                return true
            }
        }
        return false
    }

    static func pointDistanceToSegment(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let abLen2 = simd_length_squared(ab)
        guard abLen2 > 0.000001 else { return simd_distance(p, a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / abLen2))
        let projection = a + ab * t
        return simd_distance(p, projection)
    }

    private func segmentInsideHull(_ a: SIMD2<Float>, _ b: SIMD2<Float>, samples: Int = 9) -> Bool {
        guard samples >= 3 else { return true }
        for step in 1..<(samples - 1) {
            let t = Float(step) / Float(samples - 1)
            let p = simd_mix(a, b, SIMD2<Float>(repeating: t))
            if !(pointInsideHull(p) || pointOnHullBoundary(p)) {
                return false
            }
        }
        return true
    }

    /// Returns true if the edge p→q properly intersects any hull boundary edge
    /// (excluding hull edges that share a vertex with p or q).
    /// This is the precise topological test used in the Delaunay filter to reject
    /// cross-concavity edges without ever misclassifying valid hull-adjacent edges.
    private func edgeCrossesHullBoundary(
        _ p: SIMD2<Float>, _ q: SIMD2<Float>,
        pidx: Int, qidx: Int
    ) -> Bool {
        let hull = hullVertexIndices.map(Int.init)
        for i in hull.indices {
            let hi = hull[i]
            let hj = hull[(i + 1) % hull.count]
            if hi == pidx || hi == qidx || hj == pidx || hj == qidx { continue }
            if segmentsProperlyIntersect(p, q, vertices[hi], vertices[hj]) { return true }
        }
        return false
    }



    private func localBounds(for indices: [Int], vertices: [SIMD2<Float>]) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        var minPoint = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var maxPoint = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for index in indices where vertices.indices.contains(index) {
            let point = vertices[index]
            minPoint = simd_min(minPoint, point)
            maxPoint = simd_max(maxPoint, point)
        }
        return (minPoint, maxPoint)
    }

    private func filterTrianglesToOpaqueArea(
        triangles: [UInt16],
        size: SIMD2<Float>,
        alphaSampler: (Int, Int) -> Float,
        alphaThreshold: Float,
        minOpaqueSamples: Int = 4
    ) -> [UInt16] {
        guard triangles.count >= 3, size.x > 1, size.y > 1 else { return triangles }
        var filtered: [UInt16] = []
        filtered.reserveCapacity(triangles.count)

        let width = max(Int(size.x.rounded()), 1)
        let height = max(Int(size.y.rounded()), 1)
        let requiredSamples = max(1, min(7, minOpaqueSamples))

        func alphaAt(_ point: SIMD2<Float>) -> Float {
            let px = max(0, min(width - 1, Int((point.x + size.x * 0.5).rounded())))
            let py = max(0, min(height - 1, Int((size.y * 0.5 - point.y).rounded())))
            return alphaSampler(px, py)
        }

        func opaqueRatioOnSegment(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, samples: Int) -> Float {
            guard samples > 1 else { return alphaAt((p0 + p1) * 0.5) > alphaThreshold ? 1 : 0 }
            var opaque = 0
            for i in 0..<samples {
                let t = Float(i) / Float(samples - 1)
                let p = simd_mix(p0, p1, SIMD2<Float>(repeating: t))
                if alphaAt(p) > alphaThreshold {
                    opaque += 1
                }
            }
            return Float(opaque) / Float(samples)
        }

        // Reject any segment that crosses a clearly empty pixel anywhere along its length.
        let emptyAlpha: Float = 0.05
        func crossesEmptyPixel(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, samples: Int) -> Bool {
            let n = max(samples, 2)
            for i in 0..<n {
                let t = Float(i) / Float(n - 1)
                let p = simd_mix(p0, p1, SIMD2<Float>(repeating: t))
                if alphaAt(p) < emptyAlpha {
                    return true
                }
            }
            return false
        }

        for chunkStart in stride(from: 0, to: triangles.count, by: 3) {
            guard chunkStart + 2 < triangles.count else { break }
            let ia = Int(triangles[chunkStart])
            let ib = Int(triangles[chunkStart + 1])
            let ic = Int(triangles[chunkStart + 2])
            guard vertices.indices.contains(ia),
                  vertices.indices.contains(ib),
                  vertices.indices.contains(ic) else { continue }

            let a = vertices[ia]
            let b = vertices[ib]
            let c = vertices[ic]

            // Reject any triangle whose edges cross visibly empty regions.
            let edgeSamples = 21
            let minEdgeOpaqueRatio: Float = 0.92
            let abRatio = opaqueRatioOnSegment(a, b, samples: edgeSamples)
            let bcRatio = opaqueRatioOnSegment(b, c, samples: edgeSamples)
            let caRatio = opaqueRatioOnSegment(c, a, samples: edgeSamples)
            if abRatio < minEdgeOpaqueRatio || bcRatio < minEdgeOpaqueRatio || caRatio < minEdgeOpaqueRatio {
                continue
            }
            if crossesEmptyPixel(a, b, samples: edgeSamples)
                || crossesEmptyPixel(b, c, samples: edgeSamples)
                || crossesEmptyPixel(c, a, samples: edgeSamples) {
                continue
            }

            // Multi-sample triangle interior to reject faces crossing transparent regions.
            let samplePoints: [SIMD2<Float>] = [
                (a + b + c) / 3.0,                               // centroid
                a * 0.6 + b * 0.2 + c * 0.2,
                a * 0.2 + b * 0.6 + c * 0.2,
                a * 0.2 + b * 0.2 + c * 0.6,
                (a + b) * 0.5,
                (b + c) * 0.5,
                (c + a) * 0.5
            ]

            var opaqueCount = 0
            for p in samplePoints {
                if alphaAt(p) > alphaThreshold {
                    opaqueCount += 1
                }
            }

            if opaqueCount >= requiredSamples {
                filtered.append(triangles[chunkStart])
                filtered.append(triangles[chunkStart + 1])
                filtered.append(triangles[chunkStart + 2])
            }
        }

        return filtered
    }



    private func hullBoundaryEdges() -> [MeshEdge] {
        guard hullVertexIndices.count >= 2 else { return [] }
        var edges: [MeshEdge] = []
        edges.reserveCapacity(hullVertexIndices.count)
        for i in hullVertexIndices.indices {
            let a = hullVertexIndices[i]
            let b = hullVertexIndices[(i + 1) % hullVertexIndices.count]
            edges.append(MeshEdge(a, b))
        }
        return edges
    }

    private func triangleIntroducesCrossings(orphan: Int, a: Int, b: Int, existingTriangles: [UInt16]) -> Bool {
        let candidateEdges: [(Int, Int)] = [(orphan, a), (orphan, b), (a, b)]
        let existingEdges = uniqueEdges(from: existingTriangles)
        for (ca, cb) in candidateEdges {
            let p1 = vertices[ca]
            let p2 = vertices[cb]
            for edge in existingEdges {
                let ea = edge.0
                let eb = edge.1
                if ca == ea || ca == eb || cb == ea || cb == eb { continue }
                let q1 = vertices[ea]
                let q2 = vertices[eb]
                if segmentsProperlyIntersect(p1, p2, q1, q2) {
                    return true
                }
            }
        }
        return false
    }

    private func uniqueEdges(from triangles: [UInt16]) -> [(Int, Int)] {
        var set = Set<MeshEdge>()
        for i in stride(from: 0, to: triangles.count, by: 3) {
            guard i + 2 < triangles.count else { break }
            let a = triangles[i]
            let b = triangles[i + 1]
            let c = triangles[i + 2]
            set.insert(MeshEdge(a, b))
            set.insert(MeshEdge(b, c))
            set.insert(MeshEdge(c, a))
        }
        return set.map { (Int($0.a), Int($0.b)) }
    }

    private func segmentsProperlyIntersect(
        _ p1: SIMD2<Float>,
        _ p2: SIMD2<Float>,
        _ q1: SIMD2<Float>,
        _ q2: SIMD2<Float>
    ) -> Bool {
        let d1 = signedArea(p1, p2, q1)
        let d2 = signedArea(p1, p2, q2)
        let d3 = signedArea(q1, q2, p1)
        let d4 = signedArea(q1, q2, p2)
        let eps: Float = 0.0001
        if abs(d1) < eps || abs(d2) < eps || abs(d3) < eps || abs(d4) < eps {
            return false
        }
        return (d1 > 0) != (d2 > 0) && (d3 > 0) != (d4 > 0)
    }

    private func simplifyHull(_ points: [SIMD2<Float>], minimumDistance: Float) -> [SIMD2<Float>] {
        guard !points.isEmpty else { return [] }
        var simplified: [SIMD2<Float>] = [points[0]]
        for point in points.dropFirst() where simd_distance(point, simplified.last!) >= minimumDistance {
            simplified.append(point)
        }
        if simplified.count > 2, simd_distance(simplified[0], simplified.last!) < minimumDistance {
            simplified.removeLast()
        }
        return simplified
    }

    private func traceBoundaryPixels(mask: [Bool], width: Int, height: Int) -> [SIMD2<Float>] {
        guard width > 0, height > 0 else { return [] }

        struct GridPoint: Hashable, Comparable {
            let x: Int
            let y: Int
            static func < (lhs: GridPoint, rhs: GridPoint) -> Bool {
                lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
            }
        }
        struct DirectedEdge: Hashable {
            let start: GridPoint
            let end: GridPoint
        }

        func isSolid(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            return mask[y * width + x]
        }

        var edges: [DirectedEdge] = []
        edges.reserveCapacity(width * height)

        for y in 0..<height {
            for x in 0..<width where isSolid(x, y) {
                let tl = GridPoint(x: x, y: y)
                let tr = GridPoint(x: x + 1, y: y)
                let br = GridPoint(x: x + 1, y: y + 1)
                let bl = GridPoint(x: x, y: y + 1)

                if !isSolid(x, y - 1) { edges.append(DirectedEdge(start: tl, end: tr)) } // top
                if !isSolid(x + 1, y) { edges.append(DirectedEdge(start: tr, end: br)) } // right
                if !isSolid(x, y + 1) { edges.append(DirectedEdge(start: br, end: bl)) } // bottom
                if !isSolid(x - 1, y) { edges.append(DirectedEdge(start: bl, end: tl)) } // left
            }
        }

        guard !edges.isEmpty else { return [] }

        var byStart: [GridPoint: [DirectedEdge]] = [:]
        for edge in edges {
            byStart[edge.start, default: []].append(edge)
        }
        var unused = Set(edges)
        var loops: [[GridPoint]] = []

        while let seed = unused.min(by: { a, b in a.start < b.start }) {
            var loop: [GridPoint] = [seed.start]
            var current = seed
            unused.remove(current)
            var guardSteps = 0
            let maxSteps = edges.count + 8

            while guardSteps < maxSteps {
                guardSteps += 1
                loop.append(current.end)
                if current.end == seed.start { break }

                guard let candidates = byStart[current.end] else { break }
                let next = candidates.first(where: { unused.contains($0) })
                guard let next else { break }
                current = next
                unused.remove(current)
            }

            if loop.count >= 4, loop.first == loop.last {
                loops.append(loop)
            }
        }

        func loopArea(_ loop: [GridPoint]) -> Float {
            guard loop.count >= 3 else { return 0 }
            var area: Float = 0
            var j = loop.count - 1
            for i in 0..<loop.count {
                let p0 = loop[j]
                let p1 = loop[i]
                area += Float(p0.x * p1.y - p1.x * p0.y)
                j = i
            }
            return area * 0.5
        }

        guard let bestLoop = loops.max(by: { abs(loopArea($0)) < abs(loopArea($1)) }) else {
            return []
        }

        var deduped: [SIMD2<Float>] = []
        deduped.reserveCapacity(bestLoop.count)
        for point in bestLoop.dropLast() {
            let p = SIMD2<Float>(Float(point.x), Float(point.y))
            if deduped.last.map({ simd_distance($0, p) < 0.001 }) != true {
                deduped.append(p)
            }
        }
        return deduped
    }

    // Light moving-average smoothing of a closed contour. Removes 1-pixel
    // marching-squares stairstep noise on tilted edges while preserving any
    // real corner or feature (corners deviate by far more than the window
    // radius, so the average barely shifts them).
    private func smoothContour(_ contour: [SIMD2<Float>], windowRadius: Int) -> [SIMD2<Float>] {
        guard windowRadius > 0, contour.count > windowRadius * 4 else { return contour }
        let n = contour.count
        var smoothed: [SIMD2<Float>] = []
        smoothed.reserveCapacity(n)
        let span = windowRadius * 2 + 1
        for i in 0..<n {
            var sum = SIMD2<Float>(repeating: 0)
            for j in -windowRadius...windowRadius {
                let idx = ((i + j) % n + n) % n
                sum += contour[idx]
            }
            smoothed.append(sum / Float(span))
        }
        return smoothed
    }

    private func simplifyHullRDP(_ points: [SIMD2<Float>], epsilon: Float) -> [SIMD2<Float>] {
        guard points.count > 3 else { return points }

        func perpendicularDistance(_ point: SIMD2<Float>, _ lineStart: SIMD2<Float>, _ lineEnd: SIMD2<Float>) -> Float {
            let line = lineEnd - lineStart
            let lengthSq = simd_length_squared(line)
            guard lengthSq > 0.0001 else { return simd_distance(point, lineStart) }
            let t = max(0, min(1, simd_dot(point - lineStart, line) / lengthSq))
            let projection = lineStart + line * t
            return simd_distance(point, projection)
        }

        func rdp(_ subset: ArraySlice<SIMD2<Float>>) -> [SIMD2<Float>] {
            guard subset.count > 2 else { return Array(subset) }
            let first = subset.first!
            let last = subset.last!
            var maxDistance: Float = 0
            var index = subset.startIndex
            for i in subset.indices.dropFirst().dropLast() {
                let d = perpendicularDistance(subset[i], first, last)
                if d > maxDistance {
                    maxDistance = d
                    index = i
                }
            }
            if maxDistance > epsilon {
                let left = rdp(subset[subset.startIndex...index])
                let right = rdp(subset[index...subset.endIndex - 1])
                return Array(left.dropLast() + right)
            }
            return [first, last]
        }

        var closed = points
        if simd_distance(closed.first!, closed.last!) > 0.001 {
            closed.append(closed.first!)
        }
        let simplified = rdp(closed[0...closed.count - 1])
        if simplified.count > 3, simd_distance(simplified.first!, simplified.last!) < 0.001 {
            return Array(simplified.dropLast())
        }
        return simplified
    }

    private func insetPolygon(_ polygon: [SIMD2<Float>], inset: Float) -> [SIMD2<Float>] {
        guard polygon.count >= 3 else { return polygon }
        let centroid = polygon.reduce(SIMD2<Float>(repeating: 0), +) / Float(polygon.count)
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(polygon.count)
        for p in polygon {
            let dir = centroid - p
            let len = simd_length(dir)
            guard len > 0.0001 else {
                result.append(p)
                continue
            }
            result.append(p + (dir / len) * inset)
        }
        return result
    }

    // Inserts intermediate vertices along any hull edge longer than maxEdgeLength.
    // Prevents RDP from collapsing straight sides to just 2 vertices on elongated shapes.
    private func subdivideHullEdges(_ hull: [SIMD2<Float>], maxEdgeLength: Float) -> [SIMD2<Float>] {
        guard hull.count >= 3, maxEdgeLength > 0 else { return hull }
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(hull.count * 3)
        for i in hull.indices {
            let a = hull[i]
            let b = hull[(i + 1) % hull.count]
            result.append(a)
            let edgeLen = simd_length(b - a)
            if edgeLen > maxEdgeLength {
                let divisions = Int((edgeLen / maxEdgeLength).rounded(.up))
                for j in 1..<divisions {
                    let t = Float(j) / Float(divisions)
                    result.append(simd_mix(a, b, SIMD2<Float>(repeating: t)))
                }
            }
        }
        return result
    }

    // Iteratively removes concave vertices whose notch depth is below the threshold
    // derived from `concavity` (0 = convex hull, 100 = keep all concavities).
    // Hull must be CCW-wound (as normalizeHullWindingAndCleanup guarantees).
    private func filterConcavities(_ hull: [SIMD2<Float>], concavity: Float, maxDimension: Float) -> [SIMD2<Float>] {
        guard hull.count >= 4 else { return hull }
        let c = max(0, min(100, concavity))
        if c >= 99.9 { return hull }
        let t = 1.0 - c / 100.0
        let threshold = t * t * maxDimension * 0.35

        var result = hull
        var changed = true
        while changed, result.count >= 4 {
            changed = false
            var shallowestIdx = -1
            var shallowestDepth = threshold
            let n = result.count
            for i in 0..<n {
                let prev = result[(i + n - 1) % n]
                let curr = result[i]
                let next = result[(i + 1) % n]
                // For CCW winding: concave vertex has negative cross product.
                let cross = (curr.x - prev.x) * (next.y - curr.y)
                           - (curr.y - prev.y) * (next.x - curr.x)
                guard cross < 0 else { continue }
                let chord = next - prev
                let chordLen = simd_length(chord)
                let depth: Float = chordLen > 0.001
                    ? abs(simd_dot(curr - prev, SIMD2<Float>(-chord.y, chord.x)) / chordLen)
                    : simd_distance(curr, prev)
                if depth < shallowestDepth {
                    shallowestDepth = depth
                    shallowestIdx = i
                }
            }
            if shallowestIdx >= 0 {
                result.remove(at: shallowestIdx)
                changed = true
            }
        }
        return result.count >= 3 ? result : hull
    }

    private func expandPolygonOutward(_ polygon: [SIMD2<Float>], expansion: Float) -> [SIMD2<Float>] {
        guard polygon.count >= 3, expansion > 0 else { return polygon }
        let count = polygon.count

        // Determine winding: positive signed area = CCW, negative = CW.
        var signedArea: Float = 0
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[(i + 1) % count]
            signedArea += (b.x - a.x) * (b.y + a.y)
        }
        // For SwiftUI/local-space (Y up), CCW => signedArea < 0, but invariant under inversion: use sign to pick normal direction.
        let outwardSign: Float = signedArea > 0 ? -1 : 1

        var result: [SIMD2<Float>] = []
        result.reserveCapacity(count)
        for index in polygon.indices {
            let prev = polygon[(index - 1 + count) % count]
            let curr = polygon[index]
            let next = polygon[(index + 1) % count]

            let edgeIn = curr - prev
            let edgeOut = next - curr
            let lenIn = simd_length(edgeIn)
            let lenOut = simd_length(edgeOut)
            guard lenIn > 0.0001 || lenOut > 0.0001 else {
                result.append(curr)
                continue
            }

            let normalIn = lenIn > 0.0001 ? SIMD2<Float>(edgeIn.y, -edgeIn.x) / lenIn * outwardSign : SIMD2<Float>(0, 0)
            let normalOut = lenOut > 0.0001 ? SIMD2<Float>(edgeOut.y, -edgeOut.x) / lenOut * outwardSign : SIMD2<Float>(0, 0)
            var bisector = normalIn + normalOut
            let bisectorLength = simd_length(bisector)
            if bisectorLength > 0.0001 {
                bisector /= bisectorLength
            } else {
                bisector = lenOut > 0.0001 ? normalOut : normalIn
            }
            // Mitre limit: cap the corner offset at 1.5× expansion to avoid
            // spike artifacts at sharp convex corners (acute angles).
            // Additionally cap by half the shorter adjacent edge to prevent
            // self-intersection on thin shapes.
            let cosHalf = max(0.4, simd_dot(normalIn, bisector))
            let edgeCap: Float = lenIn > 0.0001 && lenOut > 0.0001
                ? max(expansion, min(lenIn, lenOut) * 0.5)
                : expansion * 1.5
            let magnitude = min(expansion / cosHalf, expansion * 1.5, edgeCap)
            result.append(curr + bisector * magnitude)
        }
        return result
    }

    private func hullQuality(
        of hull: [SIMD2<Float>],
        mask: [Bool],
        width: Int,
        height: Int,
        size: SIMD2<Float>
    ) -> (recall: Float, precision: Float, f1: Float) {
        guard hull.count >= 3, width > 0, height > 0 else { return (0, 0, 0) }

        var opaqueCount = 0
        var coveredOpaque = 0
        var insideHull = 0

        for y in 0..<height {
            for x in 0..<width {
                let isOpaque = mask[y * width + x]
                if isOpaque {
                    opaqueCount += 1
                }
                let local = SIMD2<Float>(
                    Float(x) + 0.5 - size.x * 0.5,
                    size.y * 0.5 - (Float(y) + 0.5)
                )
                if pointInsidePolygon(local, polygon: hull) {
                    insideHull += 1
                    if isOpaque {
                        coveredOpaque += 1
                    }
                }
            }
        }

        guard opaqueCount > 0, insideHull > 0 else { return (0, 0, 0) }
        let recall = Float(coveredOpaque) / Float(opaqueCount)
        let precision = Float(coveredOpaque) / Float(insideHull)
        let denom = precision + recall
        let f1 = denom > 0.0001 ? (2 * precision * recall) / denom : 0
        return (recall, precision, f1)
    }

    private func normalizeHullWindingAndCleanup(_ hull: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard hull.count >= 3 else { return hull }
        var cleaned: [SIMD2<Float>] = []
        cleaned.reserveCapacity(hull.count)
        for point in hull {
            if cleaned.last.map({ simd_distance($0, point) < 0.5 }) != true {
                cleaned.append(point)
            }
        }
        guard cleaned.count >= 3 else { return hull }
        if signedArea(of: cleaned) < 0 {
            cleaned.reverse()
        }
        return cleaned
    }

    private func signedArea(of polygon: [SIMD2<Float>]) -> Float {
        guard polygon.count >= 3 else { return 0 }
        var area: Float = 0
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            area += (polygon[j].x * polygon[i].y) - (polygon[i].x * polygon[j].y)
            j = i
        }
        return area * 0.5
    }

    private func convexHull(of points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard points.count >= 3 else { return points }
        let sorted = points.sorted { lhs, rhs in
            if lhs.x == rhs.x { return lhs.y < rhs.y }
            return lhs.x < rhs.x
        }

        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [SIMD2<Float>] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                _ = lower.popLast()
            }
            lower.append(p)
        }

        var upper: [SIMD2<Float>] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                _ = upper.popLast()
            }
            upper.append(p)
        }

        _ = lower.popLast()
        _ = upper.popLast()
        let hull = lower + upper
        return hull.count >= 3 ? hull : points
    }

    // Find every connected component (4-neighbourhood) in the binary mask.
    // Returned components are arrays of flat pixel indices.
    private func findConnectedComponents(mask: [Bool], width: Int, height: Int) -> [[Int]] {
        guard width > 0, height > 0, mask.count == width * height else { return [] }
        var visited = Array(repeating: false, count: mask.count)
        var components: [[Int]] = []
        let neighbors = [(-1, 0), (1, 0), (0, -1), (0, 1)]

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard mask[index], !visited[index] else { continue }
                visited[index] = true
                var queue: [Int] = [index]
                var head = 0
                var component: [Int] = [index]
                while head < queue.count {
                    let current = queue[head]
                    head += 1
                    let cx = current % width
                    let cy = current / width
                    for (dx, dy) in neighbors {
                        let nx = cx + dx
                        let ny = cy + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let ni = ny * width + nx
                        guard mask[ni], !visited[ni] else { continue }
                        visited[ni] = true
                        queue.append(ni)
                        component.append(ni)
                    }
                }
                components.append(component)
            }
        }
        return components
    }

    // Run the existing single-shape simplification pipeline (trace → smooth →
    // RDP → pad → concavity-filter) against a mask that contains exactly one
    // connected component. Returns the cleaned-up CCW hull polygon in local
    // (image-centered) coordinates, or nil if the component is unusable.
    private func simplifiedHullFromComponentMask(
        _ componentMask: [Bool],
        width: Int,
        height: Int,
        size: SIMD2<Float>,
        detail: Float,
        padding: Float,
        concavity: Float
    ) -> [SIMD2<Float>]? {
        let contourPixels = traceBoundaryPixels(mask: componentMask, width: width, height: height)
        guard !contourPixels.isEmpty else { return nil }

        let contourLocal = contourPixels.map { pixel -> SIMD2<Float> in
            let px = min(max(pixel.x, 0), Float(width))
            let py = min(max(pixel.y, 0), Float(height))
            return SIMD2<Float>(px - size.x * 0.5, size.y * 0.5 - py)
        }

        let clampedDetail = max(10, min(100, detail))
        let detailT = (clampedDetail - 10) / 90.0

        var minP = SIMD2<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxP = SIMD2<Float>(repeating: -Float.greatestFiniteMagnitude)
        for p in contourLocal {
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        let shapeMaxDim = max(1, max(maxP.x - minP.x, maxP.y - minP.y))

        let minEpsilon: Float = 0.6
        let maxEpsilon: Float = max(minEpsilon * 4, shapeMaxDim * 0.04)
        let epsilon = maxEpsilon * pow(minEpsilon / maxEpsilon, detailT)

        let smoothedContour = smoothContour(contourLocal, windowRadius: 1)
        let simplifiedHull = simplifyHullRDP(smoothedContour, epsilon: epsilon)
        let usableHull = simplifiedHull.count >= 3 ? simplifiedHull : contourLocal
        guard usableHull.count >= 3 else { return nil }

        let outwardMargin = max(0, min(4, padding))
        var hull = outwardMargin > 0 ? expandPolygonOutward(usableHull, expansion: outwardMargin) : usableHull
        hull = normalizeHullWindingAndCleanup(hull)
        guard hull.count >= 3 else { return nil }

        let maxDimension = max(size.x, size.y)
        hull = filterConcavities(hull, concavity: concavity, maxDimension: maxDimension)
        return hull.count >= 3 ? hull : nil
    }

    // Combine multiple closed CCW hull polygons into one closed CCW polygon
    // using the keyhole-bridge technique. Each secondary hull is joined to
    // the running result via the closest vertex pair; an out-and-back bridge
    // crosses transparent space between shapes so downstream triangle filtering
    // by alpha removes any triangles spanning the bridge.
    private func stitchHullsViaKeyhole(_ hulls: [[SIMD2<Float>]]) -> [SIMD2<Float>] {
        guard let first = hulls.first else { return [] }
        var combined = first
        for i in 1..<hulls.count {
            combined = bridgeTwoHulls(primary: combined, secondary: hulls[i])
        }
        return combined
    }

    private func bridgeTwoHulls(primary: [SIMD2<Float>], secondary: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard primary.count >= 3 else { return secondary }
        guard secondary.count >= 3 else { return primary }

        var bestI = 0
        var bestJ = 0
        var bestDist: Float = .greatestFiniteMagnitude
        for i in primary.indices {
            for j in secondary.indices {
                let d = simd_distance(primary[i], secondary[j])
                if d < bestDist {
                    bestDist = d
                    bestI = i
                    bestJ = j
                }
            }
        }

        // The return leg is offset a hair perpendicular to the crossing, so the
        // bridge has a WIDTH.
        //
        // It used to return along the same line it went out on, which made the
        // two bridge traversals the same segment travelled twice and repeated
        // both anchor points. That is not a simple ring, `validateRing` refuses
        // it, `kernelTriangulatedIndices()` throws — and since every interior
        // insertion goes through the kernel, a sprite whose PNG holds more than
        // one shape stopped accepting new nodes entirely, silently, for the
        // rest of the session. Detail at 100 keeps the small components a
        // coarser trace smooths away, which is why it showed up there first.
        //
        // The kernel bridges holes exactly this way and is fine, because it
        // does so after validating and knows the channel is there. What it
        // cannot take is a zero-width bridge baked into an outline and handed
        // to it as a plain ring.
        //
        // Half a pixel, inside a shape traced at pixel resolution: less than
        // the anti-aliased rim the trace already rounds off, and the bridge
        // crosses transparent space anyway, so `filterTrianglesToOpaqueArea`
        // drops the triangles spanning it.
        let bridgeWidth: Float = 0.5
        let anchor = primary[bestI]
        let landing = secondary[bestJ]
        let span = landing - anchor
        let spanLength = simd_length(span)
        // Two outlines touching leave no direction to offset along. Rather than
        // build one out of a zero vector, keep the old shape and let the ring
        // check refuse it honestly.
        let offset: SIMD2<Float> = spanLength > 0.000001
            ? SIMD2(-span.y, span.x) / spanLength * bridgeWidth
            : .zero

        var result: [SIMD2<Float>] = []
        result.reserveCapacity(primary.count + secondary.count + 2)
        // Walk primary up to and including the bridge anchor.
        for k in 0...bestI { result.append(primary[k]) }
        // Cross the bridge and walk all of secondary.
        for k in 0..<secondary.count {
            result.append(secondary[(bestJ + k) % secondary.count])
        }
        // Return alongside the outbound leg rather than along it.
        result.append(landing + offset)
        result.append(anchor + offset)
        if bestI + 1 < primary.count {
            for k in (bestI + 1)..<primary.count { result.append(primary[k]) }
        }
        return result
    }

    private func largestConnectedComponentMask(mask: [Bool], width: Int, height: Int) -> [Bool] {
        guard width > 0, height > 0, mask.count == width * height else { return mask }
        var visited = Array(repeating: false, count: mask.count)
        var bestComponent: [Int] = []
        let neighbors = [(-1, 0), (1, 0), (0, -1), (0, 1)]

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard mask[index], !visited[index] else { continue }
                visited[index] = true
                var queue: [Int] = [index]
                var head = 0
                var component: [Int] = [index]
                while head < queue.count {
                    let current = queue[head]
                    head += 1
                    let cx = current % width
                    let cy = current / width
                    for (dx, dy) in neighbors {
                        let nx = cx + dx
                        let ny = cy + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let ni = ny * width + nx
                        guard mask[ni], !visited[ni] else { continue }
                        visited[ni] = true
                        queue.append(ni)
                        component.append(ni)
                    }
                }
                if component.count > bestComponent.count {
                    bestComponent = component
                }
            }
        }

        guard !bestComponent.isEmpty else { return mask }
        var result = Array(repeating: false, count: mask.count)
        for i in bestComponent {
            result[i] = true
        }
        return result
    }

    private func pointInsidePolygon(_ point: SIMD2<Float>, polygon: [SIMD2<Float>]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            let intersects = ((pi.y > point.y) != (pj.y > point.y)) &&
                (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x)
            if intersects {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private func closestPointOnPolygonBoundary(_ point: SIMD2<Float>, polygon: [SIMD2<Float>]) -> SIMD2<Float> {
        guard !polygon.isEmpty else { return point }
        var bestPoint = polygon[0]
        var bestDistance = Float.greatestFiniteMagnitude

        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let projected = closestPointOnSegment(point: point, a: a, b: b)
            let distance = simd_distance(point, projected)
            if distance < bestDistance {
                bestDistance = distance
                bestPoint = projected
            }
        }

        return bestPoint
    }

    private func closestPointOnSegment(point: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>) -> SIMD2<Float> {
        let ab = b - a
        let lengthSquared = simd_dot(ab, ab)
        guard lengthSquared > 0.000001 else { return a }
        let t = max(0, min(1, simd_dot(point - a, ab) / lengthSquared))
        return a + ab * t
    }

    private func sanitizedManualTriangles() -> [MeshTriangle] {
        var seen = Set<[UInt16]>()
        return manualTriangles.filter { triangle in
            let indices = triangle.indices
            guard indices.allSatisfy(vertices.indices.contains) else { return false }
            guard Set(indices).count == 3 else { return false }
            let key = triangle.normalizedKey()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private func generatedTrianglesByRemovingTrianglesCoveredByManualFaces(
        _ triangles: [UInt16],
        manualTriangles: [MeshTriangle]
    ) -> [UInt16] {
        guard !manualTriangles.isEmpty else { return triangles }
        var filtered: [UInt16] = []
        filtered.reserveCapacity(triangles.count)

        for chunkStart in stride(from: 0, to: triangles.count, by: 3) {
            guard chunkStart + 2 < triangles.count else { break }
            let triangle = MeshTriangle(triangles[chunkStart], triangles[chunkStart + 1], triangles[chunkStart + 2])
            guard let centroid = triangle.centroid(in: vertices) else { continue }

            let coveredByManualFace = manualTriangles.contains { manualTriangle in
                triangle.normalizedKey() != manualTriangle.normalizedKey() &&
                point(centroid, liesInside: manualTriangle)
            }
            if !coveredByManualFace {
                filtered.append(contentsOf: [triangle.a, triangle.b, triangle.c])
            }
        }
        return filtered
    }

    private func point(_ point: SIMD2<Float>, liesInside triangle: MeshTriangle) -> Bool {
        let triangleIndices = triangle.indices
        guard triangleIndices.allSatisfy(vertices.indices.contains) else { return false }
        return pointInTriangle(point, vertices[triangleIndices[0]], vertices[triangleIndices[1]], vertices[triangleIndices[2]])
    }

    private func pointInTriangle(_ point: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
        func cross(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>) -> Float {
            let ab = p1 - p0
            let ac = p2 - p0
            return ab.x * ac.y - ab.y * ac.x
        }

        let area = cross(a, b, c)
        let s = cross(point, a, b)
        let t = cross(point, b, c)
        let u = cross(point, c, a)
        if area >= 0 {
            return s >= -0.0001 && t >= -0.0001 && u >= -0.0001
        }
        return s <= 0.0001 && t <= 0.0001 && u <= 0.0001
    }

    private func signedArea(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        let ab = b - a
        let ac = c - a
        return ab.x * ac.y - ab.y * ac.x
    }


    private func circumcircleContains(
        point: SIMD2<Float>,
        aIndex: Int,
        bIndex: Int,
        cIndex: Int,
        points: [SIMD2<Float>]
    ) -> Bool {
        let a = points[aIndex]
        let b = points[bIndex]
        let c = points[cIndex]

        let ax = a.x - point.x
        let ay = a.y - point.y
        let bx = b.x - point.x
        let by = b.y - point.y
        let cx = c.x - point.x
        let cy = c.y - point.y

        let determinant =
            (ax * ax + ay * ay) * (bx * cy - by * cx) -
            (bx * bx + by * by) * (ax * cy - ay * cx) +
            (cx * cx + cy * cy) * (ax * by - ay * bx)

        let area = signedArea(a, b, c)
        return area > 0 ? determinant > 0.0001 : determinant < -0.0001
    }
}
