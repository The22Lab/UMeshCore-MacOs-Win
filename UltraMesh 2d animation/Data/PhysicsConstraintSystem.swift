import Foundation
import simd
import QuartzCore

// MARK: - Bone Simulation State

struct BoneSimState {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var angle: Float
    var angularVelocity: Float
    var restLength: Float
    var initialized: Bool
}

// MARK: - Performance Level

enum PhysicsQuality: Int, CaseIterable {
    case low = 4, medium = 8, high = 12, ultra = 20

    var displayName: String {
        switch self {
        case .low:   return "Low"
        case .medium: return "Medium"
        case .high:  return "High"
        case .ultra: return "Ultra"
        }
    }
}

// MARK: - Physics Constraint System

/// Stateful secondary-motion solver. Stores per-bone simulation state and
/// advances the simulation once per render frame. All other code remains
/// stateless — only the singleton's state mutates across frames.
///
/// Lifecycle:
///   1. `SceneManager` sets `isActive = true` when Physics Preview is toggled on.
///   2. `Skeleton.worldMatrices()` calls `shared.beginFrame(skeleton:)` if active.
///   3. `beginFrame` advances the simulation in FIXED steps, as many as the
///      elapsed presentation time calls for, and keeps the leftover.
///   4. `PhysicsConstraint.apply()` calls `shared.applyConstraint(...)` which
///      blends the simulated positions into the live world-matrix dict —
///      INTERPOLATED between the last two simulation states by that leftover.
///
/// # Why a fixed step
///
/// It used to integrate with whatever `dt` the wall clock handed it, once per
/// rendered frame. Semi-implicit Euler with a variable step is not the same
/// simulation twice: the same spring, the same keys, the same everything, run
/// at 60 Hz and at 120 Hz, diverge by 21% of their amplitude within two seconds
/// (`verify_temporal_quality.py`, test J). The animation an artist tunes on one
/// display is a different animation on another, which is not a performance
/// problem — it is a correctness one.
///
/// Irregular steps are worse than merely different. A stream of frames whose
/// intervals vary — which is every real frame stream — feeds the integrator a
/// varying `dt`, and the motion it produces varies with it. That is secondary
/// motion that jitters for reasons having nothing to do with the animation.
///
/// So the simulation gets its own clock, ticking at a fixed rate, decoupled
/// from the display. What the display asks for is a SAMPLE of it, and between
/// two ticks that sample is interpolated. Standard, and the reason it is
/// standard is that it is the only arrangement where the simulation is
/// reproducible and the picture is still smooth.
final class PhysicsConstraintSystem {
    static let shared = PhysicsConstraintSystem()
    private init() {}

    // MARK: - Public State

    var isActive: Bool = false
    var quality: PhysicsQuality = .medium

    // MARK: - Private Simulation State

    private var boneStates: [UUID: BoneSimState] = [:]
    /// The state one fixed step earlier. What the render samples is somewhere
    /// between this and `boneStates`.
    private var previousStates: [UUID: BoneSimState] = [:]
    private var lastStepTime: CFTimeInterval = 0
    private var hasInitialized: Bool = false

    /// Unspent time, always less than one fixed step.
    private var accumulator: CFTimeInterval = 0
    /// How far between `previousStates` and `boneStates` the render sits.
    private var renderAlpha: Float = 0
    /// The instant the frame being built will be presented, set by the
    /// renderer through `SceneManager.beginFramePose`. The simulation and the
    /// playhead advance against the SAME clock, so animation time and
    /// simulation time cannot drift apart.
    private var frameTime: CFTimeInterval?

    /// 120 Hz. Fine enough that a spring at any tuning an artist can set is
    /// resolved well, cheap enough that a 30 Hz display still only runs four
    /// steps a frame.
    private static let fixedStep: CFTimeInterval = 1.0 / 120.0

    /// Never simulate more than this in one frame. After a stall — a
    /// backgrounded app, a long modal loop — the honest thing is to lose the
    /// missing time rather than run a hundred steps to catch up, which would
    /// freeze the app harder and then fling the physics across the screen.
    private static let maxStepsPerFrame = 8

    // MARK: - Frame Gate

    /// Told by the renderer when the frame being built will be seen.
    func setFrameTime(_ time: CFTimeInterval) {
        frameTime = time
    }

    /// Called from Skeleton.worldMatrices(). Steps the simulation at most once
    /// per ~4 ms window (≈250 fps cap) to avoid re-simulating multiple times
    /// in a single draw pass.
    func beginFrame(skeleton: Skeleton) {
        guard isActive else { return }
        let now = frameTime ?? CACurrentMediaTime()
        guard hasInitialized else {
            lastStepTime = now
            accumulator = 0
            renderAlpha = 0
            hasInitialized = true
            initializeFromSkeleton(skeleton)
            previousStates = boneStates
            return
        }

        let elapsed = now - lastStepTime
        // Zero or negative: the same frame asking twice, or the playhead
        // scrubbed backwards. Neither is time passing.
        guard elapsed > 0 else { return }
        lastStepTime = now
        accumulator += elapsed

        var steps = 0
        while accumulator >= Self.fixedStep && steps < Self.maxStepsPerFrame {
            previousStates = boneStates
            step(skeleton: skeleton, dt: Float(Self.fixedStep))
            accumulator -= Self.fixedStep
            steps += 1
        }
        if steps == Self.maxStepsPerFrame {
            // Gave up catching up. Drop the debt rather than carry it into the
            // next frame, where it would only grow.
            accumulator = 0
        }
        renderAlpha = Float(accumulator / Self.fixedStep)
    }

    /// The state to DRAW: between the last two simulation states, by however
    /// much of a step is left over.
    ///
    /// Without this the picture would show the simulation's own tick rate
    /// rather than the display's — the same stepping the animation clock was
    /// fixed to avoid, reintroduced by the physics. Only what is drawn is
    /// interpolated; the simulation itself never sees these values.
    private func renderState(for boneID: UUID) -> BoneSimState? {
        guard let current = boneStates[boneID] else { return nil }
        guard let previous = previousStates[boneID], previous.initialized,
              renderAlpha > 0 else {
            return current
        }
        var blended = current
        blended.position = previous.position
            + (current.position - previous.position) * renderAlpha
        // The short way round, for the same reason keyframed rotation takes it:
        // a spring crossing +/-pi must not appear to unwind the whole circle.
        blended.angle = previous.angle
            + shortestAngleDelta(from: previous.angle, to: current.angle) * renderAlpha
        return blended
    }

    // MARK: - Apply to World Matrices

    func applyConstraint(_ c: PhysicsConstraint,
                         skeleton: Skeleton,
                         worldMatrices: inout [UUID: simd_float4x4]) {
        guard isActive else { return }
        let mix = min(1, max(0, c.mix))
        let childrenByParent = skeleton.childrenIndexForPropagation()
        for boneID in c.affectedBones {
            guard let state = renderState(for: boneID), state.initialized else { continue }
            guard let oldW = worldMatrices[boneID] else { continue }
            let oldO3 = MatrixUtilities.transformPoint(.zero, with: oldW)
            let oldO  = SIMD2<Float>(oldO3.x, oldO3.y)
            let newO  = oldO + (state.position - oldO) * mix
            let dT    = SIMD3<Float>(newO.x - oldO.x, newO.y - oldO.y, 0)
            var newW  = MatrixUtilities.translation(dT) * oldW
            let cur   = matRotZ(newW)
            let delta = shortestAngleDelta(from: cur, to: state.angle) * mix
            if abs(delta) > 0.00001 {
                let piv = SIMD3<Float>(newO.x, newO.y, 0)
                newW = rotateM(newW, around: piv, byZ: delta)
            }
            worldMatrices[boneID] = newW
            ConstraintPropagation.cascade(from: boneID, skeleton: skeleton,
                                          childrenByParent: childrenByParent, worldMatrices: &worldMatrices)
        }
    }

    // MARK: - Reset

    func reset() {
        boneStates.removeAll()
        previousStates.removeAll()
        lastStepTime = 0
        accumulator = 0
        renderAlpha = 0
        hasInitialized = false
    }

    func resetConstraint(_ c: PhysicsConstraint) {
        for id in c.affectedBones {
            boneStates.removeValue(forKey: id)
            previousStates.removeValue(forKey: id)
        }
        if skeleton_isEmpty { hasInitialized = false }
    }

    // MARK: - Bake Helper (returns simulated positions per bone for a skeleton)

    func captureSimulatedPositions() -> [UUID: (pos: SIMD2<Float>, angle: Float)] {
        var result: [UUID: (pos: SIMD2<Float>, angle: Float)] = [:]
        for (id, state) in boneStates where state.initialized {
            result[id] = (state.position, state.angle)
        }
        return result
    }

    // MARK: - Private Init

    private var skeleton_isEmpty: Bool { boneStates.isEmpty }

    private func initializeFromSkeleton(_ skeleton: Skeleton) {
        let matrices = skeleton.baseWorldMatrices()
        for constraint in skeleton.physicsConstraints where constraint.enabled {
            for boneID in constraint.affectedBones {
                guard boneStates[boneID] == nil else { continue }
                guard let w = matrices[boneID], let bone = skeleton.bones[boneID] else { continue }
                let o3 = MatrixUtilities.transformPoint(.zero, with: w)
                boneStates[boneID] = BoneSimState(
                    position: SIMD2<Float>(o3.x, o3.y),
                    velocity: .zero,
                    angle: matRotZ(w),
                    angularVelocity: 0,
                    restLength: bone.length,
                    initialized: true
                )
            }
        }
    }

    // MARK: - Master Step

    private func step(skeleton: Skeleton, dt: Float) {
        // Refresh any newly-added bones (not yet in state)
        initializeFromSkeleton(skeleton)

        let base = skeleton.baseWorldMatrices()
        for c in skeleton.physicsConstraints where c.enabled && c.mix > 0.0001 {
            switch c.physicsType {
            case .spring, .pendulum, .cloth:
                stepSpring(c, base: base, dt: dt)
            case .jiggle:
                stepJiggle(c, base: base, dt: dt)
            case .rope:
                stepRope(c, skeleton: skeleton, base: base, dt: dt)
            }
        }
    }

    // MARK: - Spring Solver
    // Damped spring toward animated rest position. Root bone (index 0) is pinned.

    private func stepSpring(_ c: PhysicsConstraint,
                             base: [UUID: simd_float4x4], dt: Float) {
        let s = c.settings
        for (i, boneID) in c.affectedBones.enumerated() {
            guard var st = boneStates[boneID] else { continue }

            if i == 0 {
                if let w = base[boneID] {
                    let o3 = MatrixUtilities.transformPoint(.zero, with: w)
                    st.position = SIMD2<Float>(o3.x, o3.y)
                    st.velocity = .zero
                    st.angle    = matRotZ(w)
                    boneStates[boneID] = st
                }
                continue
            }
            guard st.initialized, let w = base[boneID] else { continue }

            let restO3    = MatrixUtilities.transformPoint(.zero, with: w)
            let restPos   = SIMD2<Float>(restO3.x, restO3.y)
            let restAngle = matRotZ(w)

            let springF = (restPos - st.position) * s.stiffness
            let gravF   = SIMD2<Float>(0, -s.gravity) * s.mass
            let windF   = s.wind
            let dragF   = -st.velocity * s.drag
            let accel   = (springF + gravF + windF + dragF) / max(s.mass, 0.01)

            st.velocity  = (st.velocity + accel * dt) * pow(1.0 - s.damping, dt)
            st.velocity.x = clamp(st.velocity.x, -2000, 2000)
            st.velocity.y = clamp(st.velocity.y, -2000, 2000)
            st.position  += st.velocity * dt

            let angSpring = shortestAngleDelta(from: st.angle, to: restAngle) * s.stiffness * 0.4
            let angDrag   = -st.angularVelocity * s.drag * 2
            st.angularVelocity = (st.angularVelocity + (angSpring + angDrag) * dt)
                * pow(1.0 - s.damping, dt)
            st.angle += st.angularVelocity * dt

            // Angle limits
            if i > 0, let parentID = c.affectedBones[safe: i - 1],
               let parentSt = boneStates[parentID] {
                let rel = shortestAngleDelta(from: parentSt.angle, to: st.angle)
                if rel < s.angleLimitMin || rel > s.angleLimitMax {
                    let clamped = clamp(rel, s.angleLimitMin, s.angleLimitMax)
                    st.angle = parentSt.angle + clamped
                    st.angularVelocity *= 0.5
                }
            }

            boneStates[boneID] = st
        }
    }

    // MARK: - Jiggle Solver
    // High stiffness, low damping — allows overshoot and bounce.

    private func stepJiggle(_ c: PhysicsConstraint,
                             base: [UUID: simd_float4x4], dt: Float) {
        let s = c.settings
        let ks = s.stiffness * 2.0
        let kd = s.damping   * 0.5

        for (i, boneID) in c.affectedBones.enumerated() {
            guard var st = boneStates[boneID] else { continue }
            if i == 0 {
                if let w = base[boneID] {
                    let o3 = MatrixUtilities.transformPoint(.zero, with: w)
                    st.position = SIMD2<Float>(o3.x, o3.y)
                    st.velocity = .zero
                    st.angle    = matRotZ(w)
                    boneStates[boneID] = st
                }
                continue
            }
            guard st.initialized, let w = base[boneID] else { continue }

            let restO3    = MatrixUtilities.transformPoint(.zero, with: w)
            let restPos   = SIMD2<Float>(restO3.x, restO3.y)
            let restAngle = matRotZ(w)

            let springF = (restPos - st.position) * ks
            let gravF   = SIMD2<Float>(0, -s.gravity * 0.25) * s.mass
            let dragF   = -st.velocity * s.drag * 3
            let accel   = (springF + gravF + dragF) / max(s.mass, 0.01)

            st.velocity  = (st.velocity + accel * dt) * pow(1.0 - kd, dt)
            st.position  += st.velocity * dt

            let angSpring = shortestAngleDelta(from: st.angle, to: restAngle) * ks * 0.6
            st.angularVelocity = (st.angularVelocity + angSpring * dt) * pow(1.0 - kd, dt)
            st.angle += st.angularVelocity * dt

            boneStates[boneID] = st
        }
    }

    // MARK: - Rope Solver (XPBD distance constraints)
    // No spring return — gravity + air drag + distance-constrained Verlet chain.

    private func stepRope(_ c: PhysicsConstraint, skeleton: Skeleton,
                           base: [UUID: simd_float4x4], dt: Float) {
        let s = c.settings
        let chain = c.affectedBones
        guard chain.count >= 2 else { return }
        let iters = quality.rawValue

        // Integrate forces (gravity, wind, drag) — skip pinned root
        for (i, boneID) in chain.enumerated() {
            guard var st = boneStates[boneID] else { continue }
            if i == 0 {
                if let w = base[boneID] {
                    let o3 = MatrixUtilities.transformPoint(.zero, with: w)
                    st.position = SIMD2<Float>(o3.x, o3.y)
                    st.velocity = .zero
                    st.angle    = matRotZ(w)
                    boneStates[boneID] = st
                }
                continue
            }
            guard st.initialized else { continue }
            let gravF = SIMD2<Float>(0, -s.gravity) * s.mass
            let windF = s.wind
            let dragF = -st.velocity * s.drag
            let accel = (gravF + windF + dragF) / max(s.mass, 0.01)
            st.velocity  = (st.velocity + accel * dt) * pow(1.0 - s.damping, dt)
            st.velocity.x = clamp(st.velocity.x, -2000, 2000)
            st.velocity.y = clamp(st.velocity.y, -2000, 2000)
            st.position  += st.velocity * dt
            boneStates[boneID] = st
        }

        // Distance constraint relaxation (XPBD)
        for _ in 0..<iters {
            for i in 0..<(chain.count - 1) {
                let idA = chain[i], idB = chain[i + 1]
                guard var stA = boneStates[idA], var stB = boneStates[idB] else { continue }
                let restLen = max(1, stA.restLength)
                let d    = stB.position - stA.position
                let dist = simd_length(d)
                guard dist > 0.001 else { continue }
                let err  = (dist - restLen) / dist * 0.5
                let corr = d * err
                if i > 0 { stA.position += corr;  boneStates[idA] = stA }
                stB.position -= corr
                boneStates[idB] = stB
            }
        }

        // Derive angles from link directions
        for i in 0..<(chain.count - 1) {
            let idA = chain[i], idB = chain[i + 1]
            guard var stA = boneStates[idA], let stB = boneStates[idB] else { continue }
            let d = stB.position - stA.position
            if simd_length_squared(d) > 0.001 {
                stA.angle = atan2(d.y, d.x)
                boneStates[idA] = stA
            }
        }
    }

    // MARK: - Math helpers

    @inline(__always)
    private func matRotZ(_ m: simd_float4x4) -> Float {
        atan2(m.columns.0.y, m.columns.0.x)
    }

    @inline(__always)
    private func rotateM(_ m: simd_float4x4, around p: SIMD3<Float>, byZ a: Float) -> simd_float4x4 {
        guard abs(a) > 0.000001 else { return m }
        return MatrixUtilities.translation(p) * MatrixUtilities.rotationZ(a) * MatrixUtilities.translation(-p) * m
    }

    @inline(__always)
    private func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
        max(lo, min(hi, v))
    }
}

// MARK: - Array Safe Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
