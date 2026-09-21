import Foundation
import simd

struct Skeleton {
    var bones: [UUID: Bone] {
        didSet {
            // Only a change to the PARENT LINKS can invalidate the index, and
            // almost nothing that writes `bones` touches those. Playback
            // replaces the whole table once a frame with new poses and the
            // same hierarchy; recolouring a binding and dragging a keyframe
            // write a bone each, in a loop. Comparing costs a hash per bone
            // and allocates nothing; rebuilding allocates an array per parent.
            if Self.parentLinksDiffer(bones, oldValue) { rebuildChildrenIndex() }
        }
    }
    var rootIDs: [UUID]

    /// Who each bone's children are, kept rather than recomputed.
    ///
    /// Building it walks every bone and allocates an array per parent. That is
    /// cheap once. It was not happening once: `baseWorldMatrices` builds one,
    /// and then EVERY constraint builds its own — IK, path, transform and
    /// physics each open with `skeleton.childrenIndexForPropagation()`. A solve
    /// of a rig with C enabled constraints rebuilt the same index 1 + C times,
    /// and the rig is solved every displayed frame.
    ///
    /// It is a pure function of the parent links, and the parent links change
    /// when the artist reparents a bone — not when the animation plays. So it
    /// is derived state, rebuilt by the write that can invalidate it. Same
    /// shape as `AnimationClip.trackIndex`, for the same reason.
    ///
    /// `didSet` does not fire during `init`, so `init` builds it explicitly.
    /// Every other way to obtain a `Skeleton` is a copy of one that already
    /// has it.
    private var cachedChildrenIndex: [UUID: [UUID]] = [:]

    /// Concrete constraint stores. New constraint types are added as additional
    /// typed properties (TransformConstraint, PathConstraint, …) without disturbing
    /// existing data. `allConstraints` exposes them as a sorted protocol-typed view
    /// for the solver pass.
    var ikConstraints: [IKConstraint] = []
    var transformConstraints: [TransformConstraint] = []
    var pathConstraints: [PathConstraint] = []
    var physicsConstraints: [PhysicsConstraint] = []

    init(bones: [UUID: Bone] = [:], rootIDs: [UUID] = [],
         ikConstraints: [IKConstraint] = [],
         transformConstraints: [TransformConstraint] = [],
         pathConstraints: [PathConstraint] = [],
         physicsConstraints: [PhysicsConstraint] = []) {
        self.bones = bones
        self.rootIDs = rootIDs
        self.ikConstraints = ikConstraints
        self.transformConstraints = transformConstraints
        self.pathConstraints = pathConstraints
        self.physicsConstraints = physicsConstraints
        rebuildChildrenIndex()
    }

    /// Whether two bone tables describe different hierarchies.
    ///
    /// Exactly the inputs `rebuildChildrenIndex` reads: which bones exist, and
    /// who each one's parent is. Everything else about a bone — its pose, its
    /// length, its colour, its clip — is invisible to the index.
    private static func parentLinksDiffer(_ lhs: [UUID: Bone], _ rhs: [UUID: Bone]) -> Bool {
        if lhs.count != rhs.count { return true }
        for (id, bone) in lhs {
            guard let other = rhs[id], other.parentID == bone.parentID else { return true }
        }
        return false
    }

    private mutating func rebuildChildrenIndex() {
        var index: [UUID: [UUID]] = [:]
        index.reserveCapacity(bones.count)
        for bone in bones.values {
            guard let parentID = bone.parentID else { continue }
            index[parentID, default: []].append(bone.id)
        }
        cachedChildrenIndex = index
    }

    /// Every constraint regardless of concrete type, ready for evaluation.
    var allConstraints: [any BoneConstraint] {
        var out: [any BoneConstraint] = []
        out.reserveCapacity(ikConstraints.count + transformConstraints.count + pathConstraints.count + physicsConstraints.count)
        for c in ikConstraints        { out.append(c) }
        for c in transformConstraints { out.append(c) }
        for c in pathConstraints      { out.append(c) }
        for c in physicsConstraints   { out.append(c) }
        return out
    }

    /// World matrices with all enabled constraints applied in `order` ascending.
    /// Physics constraints (order ≥ 100 by default) run last. When physics preview
    /// is active, `PhysicsConstraintSystem.shared.beginFrame` is called here so the
    /// simulation steps once per render frame automatically.
    /// - Parameter steppingPhysics: whether this solve may ADVANCE the shared
    ///   physics simulation. Defaults to false, and the default is the point.
    ///
    ///   Stepping is a frame event. Exactly one call per presented frame may
    ///   do it — `SceneManager.frameWorldMatrices()`, which opts in explicitly
    ///   — and everything else observes.
    ///
    ///   It used to default to TRUE, which meant every convenience accessor
    ///   below wound the simulation forward as a side effect of being asked a
    ///   question. `worldMatrix(for:)`, `lineSegment(for:)` and
    ///   `worldRotation(for:)` are called from `moveBoneTip`,
    ///   `setBoneRotation`, `localSpritePose` and the constraint gizmo — on
    ///   every drag sample. Dragging a bone therefore ran physics at several
    ///   times its intended rate, on top of the one legitimate step per frame,
    ///   and any bone under a physics constraint drifted while the pointer
    ///   moved. Every sprite bound to such a bone drifted with it.
    ///
    ///   The Scene evaluator already relied on passing false here for the same
    ///   reason: three rig instances sampling one simulation must not run its
    ///   clock three times faster than one. That was the rule; this makes it
    ///   the default.
    func worldMatrices(steppingPhysics: Bool = false) -> [UUID: simd_float4x4] {
        var result = baseWorldMatrices()
        // Step physics simulation (no-op when isActive = false, so zero overhead normally)
        if steppingPhysics {
            PhysicsConstraintSystem.shared.beginFrame(skeleton: self)
        }
        let active = allConstraints
            .filter { $0.enabled && $0.mix > 0.0001 }
            .sorted { $0.order < $1.order }
        guard !active.isEmpty else { return result }
        for constraint in active {
            constraint.apply(skeleton: self, worldMatrices: &result)
        }
        return result
    }

    /// World matrices BEFORE any constraint runs. Exposed so editor tools can
    /// inspect the artist-authored pose independently of solver output (useful
    /// for showing the "rest" pose under a chain that has IK applied).
    func baseWorldMatrices() -> [UUID: simd_float4x4] {
        var result: [UUID: simd_float4x4] = [:]
        result.reserveCapacity(bones.count)
        let childrenByParent = childrenIndex()
        for root in rootIDs {
            computeWorldMatrix(for: root, parent: nil, result: &result, childrenByParent: childrenByParent)
        }
        return result
    }

    /// Children of a bone. Computed each call to keep `Skeleton` a pure value
    /// type with no caching state. Cheap because we iterate `bones` once.
    func childrenOf(_ boneID: UUID) -> [UUID] {
        var out: [UUID] = []
        for bone in bones.values where bone.parentID == boneID {
            out.append(bone.id)
        }
        return out
    }

    /// Parent → children map, built in one pass over the bones.
    ///
    /// Exposed for constraint propagation: walking a subtree with `childrenOf`
    /// rescans every bone at every step, which is quadratic. Building this once
    /// and passing it down makes a cascade linear in the subtree it touches.
    /// The children index. A read, not a build — see `cachedChildrenIndex`.
    func childrenIndexForPropagation() -> [UUID: [UUID]] {
        cachedChildrenIndex
    }

    private func childrenIndex() -> [UUID: [UUID]] {
        cachedChildrenIndex
    }

    var orderedBones: [Bone] {
        let rootSet = Set(rootIDs)
        return rootIDs.compactMap { bones[$0] } + bones.values.filter { !rootSet.contains($0.id) }
    }

    func bone(_ id: UUID) -> Bone? {
        bones[id]
    }

    /// Solves the WHOLE skeleton — every constraint, every bone — to answer a
    /// question about one bone. Fine once; ruinous in a loop or several times a
    /// frame. Prefer the `in:` overloads below and pass a pose you already have.
    func worldMatrix(for id: UUID) -> simd_float4x4? {
        worldMatrices()[id]
    }

    func parentWorldMatrix(for boneID: UUID?) -> simd_float4x4? {
        guard let boneID,
              let bone = bones[boneID],
              let parentID = bone.parentID else {
            return nil
        }
        return worldMatrix(for: parentID)
    }

    func lineSegment(for boneID: UUID) -> (start: SIMD2<Float>, end: SIMD2<Float>)? {
        lineSegment(for: boneID, in: worldMatrices())
    }

    /// Same, against a pose already solved this frame. No constraint solving.
    func lineSegment(for boneID: UUID,
                     in pose: [UUID: simd_float4x4]) -> (start: SIMD2<Float>, end: SIMD2<Float>)? {
        guard let bone = bones[boneID], let matrix = pose[boneID] else { return nil }
        let start3 = MatrixUtilities.transformPoint(.zero, with: matrix)
        let end3 = MatrixUtilities.transformPoint(SIMD3<Float>(bone.length, 0, 0), with: matrix)
        return (SIMD2<Float>(start3.x, start3.y), SIMD2<Float>(end3.x, end3.y))
    }

    func worldRotation(for boneID: UUID) -> Float? {
        worldRotation(for: boneID, in: worldMatrices())
    }

    func worldRotation(for boneID: UUID, in pose: [UUID: simd_float4x4]) -> Float? {
        guard let segment = lineSegment(for: boneID, in: pose) else { return nil }
        let delta = segment.end - segment.start
        guard simd_length_squared(delta) > 0.0001 else { return nil }
        return atan2(delta.y, delta.x)
    }

    func canParent(_ boneID: UUID, to candidateParentID: UUID?) -> Bool {
        guard let candidateParentID else { return true }
        guard boneID != candidateParentID else { return false }
        var current = candidateParentID
        while let bone = bones[current] {
            if bone.parentID == boneID {
                return false
            }
            guard let parentID = bone.parentID else { break }
            current = parentID
        }
        return true
    }

    func localPoint(_ worldPoint: SIMD2<Float>, relativeTo boneID: UUID?) -> SIMD2<Float> {
        guard let boneID,
              let matrix = worldMatrix(for: boneID) else {
            return worldPoint
        }
        let local = MatrixUtilities.transformPoint(
            SIMD3<Float>(worldPoint.x, worldPoint.y, 0),
            with: simd_inverse(matrix)
        )
        return SIMD2<Float>(local.x, local.y)
    }

    func worldLineSegments() -> [(bone: Bone, start: SIMD2<Float>, end: SIMD2<Float>)] {
        worldLineSegments(in: worldMatrices())
    }

    func worldLineSegments(in matrices: [UUID: simd_float4x4])
        -> [(bone: Bone, start: SIMD2<Float>, end: SIMD2<Float>)] {
        let ordered = orderedBones
        var result: [(bone: Bone, start: SIMD2<Float>, end: SIMD2<Float>)] = []
        result.reserveCapacity(ordered.count)
        for bone in ordered {
            guard let matrix = matrices[bone.id] else { continue }
            let start3 = MatrixUtilities.transformPoint(.zero, with: matrix)
            let end3 = MatrixUtilities.transformPoint(SIMD3<Float>(bone.length, 0, 0), with: matrix)
            result.append((bone, SIMD2<Float>(start3.x, start3.y), SIMD2<Float>(end3.x, end3.y)))
        }
        return result
    }

    func addingBone(_ bone: Bone) -> Skeleton {
        var next = self
        // No colour at creation: a bone earns one by being bound to a mesh, and
        // `SceneManager.refreshBoneBindingColors()` hands it out then.
        let colored = bone
        next.bones[colored.id] = colored
        if colored.parentID == nil, !next.rootIDs.contains(colored.id) {
            next.rootIDs.append(colored.id)
        }
        return next
    }

    private func computeWorldMatrix(for id: UUID,
                                    parent: simd_float4x4?,
                                    result: inout [UUID: simd_float4x4],
                                    childrenByParent: [UUID: [UUID]]) {
        guard let bone = bones[id] else { return }
        let world = bone.worldMatrix(parentMatrix: parent)
        result[id] = world
        guard let children = childrenByParent[id] else { return }
        for child in children {
            computeWorldMatrix(for: child, parent: world, result: &result, childrenByParent: childrenByParent)
        }
    }
}
