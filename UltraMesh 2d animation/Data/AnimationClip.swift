import Foundation
import simd

struct AnimationTrack: Identifiable, Equatable {
    let id: UUID
    var targetID: UUID
    var property: AnimationTrackProperty
    var keyframes: [Keyframe]

    init(
        id: UUID = UUID(),
        targetID: UUID,
        property: AnimationTrackProperty,
        keyframes: [Keyframe] = []
    ) {
        self.id = id
        self.targetID = targetID
        self.property = property
        self.keyframes = keyframes.sorted { $0.frame < $1.frame }
    }
}

struct SceneImageAnimationPose: Equatable {
    var position: SIMD2<Float>
    var scale: SIMD2<Float>
    var rotation: Float
    var skew: SIMD2<Float>
}

struct AnimationClip: Identifiable, Equatable {
    let id: UUID
    var name: String
    var durationInFrames: Int
    var tracks: [AnimationTrack] {
        didSet { rebuildTrackIndex() }
    }

    /// Which track holds a target's property.
    ///
    /// Finding a track used to be `tracks.first(where:)` — a linear scan over
    /// every track in the clip, run once per property per target per FRAME. The
    /// number of tracks is targets times properties, so the per-frame cost was
    /// quadratic in the size of the rig: a 25-sprite, 40-bone rig meant 260
    /// lookups a frame each scanning 325 tracks, 84 500 UUID comparisons before
    /// any interpolation happened, and four times that for twice the rig.
    ///
    /// Not a cache — a cache can be stale. It is rebuilt by `tracks.didSet`, so
    /// there is no path that changes the array without it following, and an
    /// index that outlived its array would be a crash rather than a slow frame.
    ///
    /// Excluded from `Equatable`: it is derived, and comparing it would make two
    /// equal clips compare unequal for no reason a caller could see.
    private var trackIndex: [TrackKey: Int] = [:]

    struct TrackKey: Hashable {
        let targetID: UUID
        let property: AnimationTrackProperty
    }

    init(id: UUID = UUID(), name: String, durationInFrames: Int = 0, tracks: [AnimationTrack] = []) {
        self.id = id
        self.name = name
        self.durationInFrames = durationInFrames
        self.tracks = tracks
        rebuildTrackIndex()
    }

    static func == (lhs: AnimationClip, rhs: AnimationClip) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
            && lhs.durationInFrames == rhs.durationInFrames && lhs.tracks == rhs.tracks
    }

    private mutating func rebuildTrackIndex() {
        // Last one wins, matching what `first(where:)` answered before: a
        // duplicate pair is malformed either way, and this is not the place to
        // start rejecting it.
        var index: [TrackKey: Int] = [:]
        index.reserveCapacity(tracks.count)
        for (position, track) in tracks.enumerated() {
            index[TrackKey(targetID: track.targetID, property: track.property)] = position
        }
        trackIndex = index
    }

    /// Where a target's property lives, or nil.
    func trackIndex(for targetID: UUID, property: AnimationTrackProperty) -> Int? {
        trackIndex[TrackKey(targetID: targetID, property: property)]
    }

    func keyframes(for targetID: UUID, property: AnimationTrackProperty) -> [Keyframe] {
        trackIndex(for: targetID, property: property).map { tracks[$0].keyframes } ?? []
    }

    /// The keyframes around a frame, found once.
    ///
    /// `exact` is the key ON the frame, `previous` the last one before it,
    /// `next` the first one after. The sampling used to ask for these with three
    /// separate linear passes — `first(where: == frame)`, `last(where: < frame)`,
    /// `first(where: > frame)` — over a list that `init` and both mutators keep
    /// SORTED by frame. One binary search answers all three.
    /// Taken at a CONTINUOUS time, in fractional frames.
    ///
    /// Keyframes sit on whole frames and always will; the playhead does not.
    /// Sampling only at whole frames caps the animation at
    /// `projectFramesPerSecond` distinct poses per second no matter what the
    /// display can do — four identical frames and then a jump, which is the
    /// judder. Nothing else changes: at a whole `time` this returns exactly
    /// what the integer form below returns, so scrubbing, keyframe editing and
    /// export are untouched.
    static func keyframeSpan(_ keyframes: [Keyframe], time: Float)
        -> (exact: Int?, previous: Int?, next: Int?) {
        var low = 0
        var high = keyframes.count
        while low < high {
            let mid = (low + high) / 2
            if Float(keyframes[mid].frame) < time { low = mid + 1 } else { high = mid }
        }
        // `low` is now the first key at or after `time`.
        let exact = low < keyframes.count && Float(keyframes[low].frame) == time ? low : nil
        let previous = low > 0 ? low - 1 : nil
        let afterIndex = exact != nil ? low + 1 : low
        let next = afterIndex < keyframes.count ? afterIndex : nil
        return (exact, previous, next)
    }

    /// The same question asked about a whole frame — the timeline, the dope
    /// sheet, keyframe editing. One implementation, not two.
    static func keyframeSpan(_ keyframes: [Keyframe], frame: Int)
        -> (exact: Int?, previous: Int?, next: Int?) {
        keyframeSpan(keyframes, time: Float(frame))
    }

    func frameNumbers(for targetID: UUID, property: AnimationTrackProperty) -> [Int] {
        keyframes(for: targetID, property: property).map(\.frame)
    }

    func keyframe(for targetID: UUID, property: AnimationTrackProperty, keyframeID: UUID) -> Keyframe? {
        keyframes(for: targetID, property: property).first(where: { $0.id == keyframeID })
    }

    /// Bumped by every mutation, so a view can tell whether this clip changed
    /// without walking its keyframes.
    ///
    /// The timeline rebuilds its whole track list from these clips — a node per
    /// property per object, each id built by interpolating a UUID into a string
    /// — and it was doing that on every SwiftUI pass, twice per animated frame.
    /// Nothing in that list depends on the playhead, so it is now built once and
    /// reused until a signature that includes these revisions changes.
    private(set) var revision: Int = 0

    private mutating func didMutate() {
        revision &+= 1
    }

    mutating func upsertKeyframe(
        targetID: UUID,
        property: AnimationTrackProperty,
        frame: Int,
        value: KeyframeValue,
        interpolation: KeyframeInterpolation = .linear
    ) {
        defer { didMutate() }
        durationInFrames = max(durationInFrames, frame)

        // Boolean and draw-order timelines cannot interpolate; such timelines are shown
        // as stepped and so do we, regardless of what the caller asked for.
        let resolvedInterpolation: KeyframeInterpolation = property.forcesSteppedInterpolation ? .hold : interpolation

        if let trackIndex = trackIndex(for: targetID, property: property) {
            if let keyIndex = tracks[trackIndex].keyframes.firstIndex(where: { $0.frame == frame }) {
                tracks[trackIndex].keyframes[keyIndex].value = value
                tracks[trackIndex].keyframes[keyIndex].interpolation = resolvedInterpolation
            } else {
                tracks[trackIndex].keyframes.append(
                    Keyframe(frame: frame, value: value, interpolation: resolvedInterpolation)
                )
                tracks[trackIndex].keyframes.sort { $0.frame < $1.frame }
            }
        } else {
            tracks.append(
                AnimationTrack(
                    targetID: targetID,
                    property: property,
                    keyframes: [Keyframe(frame: frame, value: value, interpolation: resolvedInterpolation)]
                )
            )
        }
    }

    mutating func moveKeyframe(
        targetID: UUID,
        property: AnimationTrackProperty,
        keyframeID: UUID,
        toFrame destinationFrame: Int
    ) {
        defer { didMutate() }
        guard let trackIndex = trackIndex(for: targetID, property: property),
              let keyIndex = tracks[trackIndex].keyframes.firstIndex(where: { $0.id == keyframeID }) else {
            return
        }

        let clampedFrame = max(destinationFrame, 0)
        var movingKeyframe = tracks[trackIndex].keyframes[keyIndex]
        movingKeyframe.frame = clampedFrame

        if let collisionIndex = tracks[trackIndex].keyframes.firstIndex(where: { $0.frame == clampedFrame && $0.id != keyframeID }) {
            tracks[trackIndex].keyframes[collisionIndex] = movingKeyframe
            let removalIndex = keyIndex > collisionIndex ? keyIndex : keyIndex + 1
            tracks[trackIndex].keyframes.remove(at: removalIndex)
        } else {
            tracks[trackIndex].keyframes[keyIndex] = movingKeyframe
        }

        tracks[trackIndex].keyframes.sort { $0.frame < $1.frame }
        durationInFrames = max(durationInFrames, clampedFrame)
    }

    mutating func setInterpolation(
        targetID: UUID,
        property: AnimationTrackProperty,
        keyframeIDs: Set<UUID>,
        interpolation: KeyframeInterpolation
    ) {
        defer { didMutate() }
        guard !property.forcesSteppedInterpolation,
              let trackIndex = trackIndex(for: targetID, property: property) else {
            return
        }

        for keyIndex in tracks[trackIndex].keyframes.indices {
            guard keyframeIDs.contains(tracks[trackIndex].keyframes[keyIndex].id) else { continue }
            tracks[trackIndex].keyframes[keyIndex].interpolation = interpolation
        }
    }

    mutating func updateKeyframeValue(
        targetID: UUID,
        property: AnimationTrackProperty,
        keyframeID: UUID,
        value: KeyframeValue
    ) {
        defer { didMutate() }
        guard let trackIndex = trackIndex(for: targetID, property: property),
              let keyIndex = tracks[trackIndex].keyframes.firstIndex(where: { $0.id == keyframeID }) else {
            return
        }

        tracks[trackIndex].keyframes[keyIndex].value = value
    }

    mutating func updateKeyframeTangents(
        targetID: UUID,
        property: AnimationTrackProperty,
        keyframeID: UUID,
        inTangent: SIMD2<Float>?,
        outTangent: SIMD2<Float>?,
        secondaryInTangent: SIMD2<Float>? = nil,
        secondaryOutTangent: SIMD2<Float>? = nil
    ) {
        defer { didMutate() }
        guard let trackIndex = trackIndex(for: targetID, property: property),
              let keyIndex = tracks[trackIndex].keyframes.firstIndex(where: { $0.id == keyframeID }) else {
            return
        }

        tracks[trackIndex].keyframes[keyIndex].inTangent = inTangent
        tracks[trackIndex].keyframes[keyIndex].outTangent = outTangent
        tracks[trackIndex].keyframes[keyIndex].secondaryInTangent = secondaryInTangent
        tracks[trackIndex].keyframes[keyIndex].secondaryOutTangent = secondaryOutTangent
    }

    mutating func applyAutoTangents(
        targetID: UUID,
        property: AnimationTrackProperty,
        keyframeIDs: Set<UUID>
    ) {
        defer { didMutate() }
        guard let trackIndex = trackIndex(for: targetID, property: property) else {
            return
        }

        let snapshot = tracks[trackIndex].keyframes
        for keyIndex in tracks[trackIndex].keyframes.indices {
            let keyframe = tracks[trackIndex].keyframes[keyIndex]
            guard keyframeIDs.contains(keyframe.id) else { continue }

            let previous = snapshot[..<keyIndex].last
            let next = snapshot.dropFirst(keyIndex + 1).first

            switch keyframe.value {
            case let .rotate(value):
                let tangents = autoTangents(
                    currentFrame: keyframe.frame,
                    currentValue: value,
                    previous: previous.flatMap { previousKeyframe in
                        previousKeyframe.value.floatValue.map { (previousKeyframe.frame, $0) }
                    },
                    next: next.flatMap { nextKeyframe in
                        nextKeyframe.value.floatValue.map { (nextKeyframe.frame, $0) }
                    }
                )
                tracks[trackIndex].keyframes[keyIndex].inTangent = tangents.inTangent
                tracks[trackIndex].keyframes[keyIndex].outTangent = tangents.outTangent
            case let .scale(value):
                let xTangents = autoTangents(
                    currentFrame: keyframe.frame,
                    currentValue: value.x,
                    previous: previous.flatMap { previousKeyframe in
                        previousKeyframe.value.simd2Value.map { (previousKeyframe.frame, $0.x) }
                    },
                    next: next.flatMap { nextKeyframe in
                        nextKeyframe.value.simd2Value.map { (nextKeyframe.frame, $0.x) }
                    }
                )
                let yTangents = autoTangents(
                    currentFrame: keyframe.frame,
                    currentValue: value.y,
                    previous: previous.flatMap { previousKeyframe in
                        previousKeyframe.value.simd2Value.map { (previousKeyframe.frame, $0.y) }
                    },
                    next: next.flatMap { nextKeyframe in
                        nextKeyframe.value.simd2Value.map { (nextKeyframe.frame, $0.y) }
                    }
                )
                tracks[trackIndex].keyframes[keyIndex].inTangent = xTangents.inTangent
                tracks[trackIndex].keyframes[keyIndex].outTangent = xTangents.outTangent
                tracks[trackIndex].keyframes[keyIndex].secondaryInTangent = yTangents.inTangent
                tracks[trackIndex].keyframes[keyIndex].secondaryOutTangent = yTangents.outTangent
            case let .translate(value):
                let xTangents = autoTangents(
                    currentFrame: keyframe.frame,
                    currentValue: value.x,
                    previous: previous.flatMap { previousKeyframe in
                        previousKeyframe.value.simd2Value.map { (previousKeyframe.frame, $0.x) }
                    },
                    next: next.flatMap { nextKeyframe in
                        nextKeyframe.value.simd2Value.map { (nextKeyframe.frame, $0.x) }
                    }
                )
                let yTangents = autoTangents(
                    currentFrame: keyframe.frame,
                    currentValue: value.y,
                    previous: previous.flatMap { previousKeyframe in
                        previousKeyframe.value.simd2Value.map { (previousKeyframe.frame, $0.y) }
                    },
                    next: next.flatMap { nextKeyframe in
                        nextKeyframe.value.simd2Value.map { (nextKeyframe.frame, $0.y) }
                    }
                )
                tracks[trackIndex].keyframes[keyIndex].inTangent = xTangents.inTangent
                tracks[trackIndex].keyframes[keyIndex].outTangent = xTangents.outTangent
                tracks[trackIndex].keyframes[keyIndex].secondaryInTangent = yTangents.inTangent
                tracks[trackIndex].keyframes[keyIndex].secondaryOutTangent = yTangents.outTangent
            case let .shear(value):
                let xTangents = autoTangents(
                    currentFrame: keyframe.frame,
                    currentValue: value.x,
                    previous: previous.flatMap { previousKeyframe in
                        previousKeyframe.value.simd2Value.map { (previousKeyframe.frame, $0.x) }
                    },
                    next: next.flatMap { nextKeyframe in
                        nextKeyframe.value.simd2Value.map { (nextKeyframe.frame, $0.x) }
                    }
                )
                let yTangents = autoTangents(
                    currentFrame: keyframe.frame,
                    currentValue: value.y,
                    previous: previous.flatMap { previousKeyframe in
                        previousKeyframe.value.simd2Value.map { (previousKeyframe.frame, $0.y) }
                    },
                    next: next.flatMap { nextKeyframe in
                        nextKeyframe.value.simd2Value.map { (nextKeyframe.frame, $0.y) }
                    }
                )
                tracks[trackIndex].keyframes[keyIndex].inTangent = xTangents.inTangent
                tracks[trackIndex].keyframes[keyIndex].outTangent = xTangents.outTangent
                tracks[trackIndex].keyframes[keyIndex].secondaryInTangent = yTangents.inTangent
                tracks[trackIndex].keyframes[keyIndex].secondaryOutTangent = yTangents.outTangent
            case let .scalar(value):
                let tangents = autoTangents(
                    currentFrame: keyframe.frame,
                    currentValue: value,
                    previous: previous.flatMap { previousKeyframe in
                        previousKeyframe.value.floatValue.map { (previousKeyframe.frame, $0) }
                    },
                    next: next.flatMap { nextKeyframe in
                        nextKeyframe.value.floatValue.map { (nextKeyframe.frame, $0) }
                    }
                )
                tracks[trackIndex].keyframes[keyIndex].inTangent = tangents.inTangent
                tracks[trackIndex].keyframes[keyIndex].outTangent = tangents.outTangent
            case let .vector2(value):
                let xTangents = autoTangents(
                    currentFrame: keyframe.frame,
                    currentValue: value.x,
                    previous: previous.flatMap { previousKeyframe in
                        previousKeyframe.value.simd2Value.map { (previousKeyframe.frame, $0.x) }
                    },
                    next: next.flatMap { nextKeyframe in
                        nextKeyframe.value.simd2Value.map { (nextKeyframe.frame, $0.x) }
                    }
                )
                let yTangents = autoTangents(
                    currentFrame: keyframe.frame,
                    currentValue: value.y,
                    previous: previous.flatMap { previousKeyframe in
                        previousKeyframe.value.simd2Value.map { (previousKeyframe.frame, $0.y) }
                    },
                    next: next.flatMap { nextKeyframe in
                        nextKeyframe.value.simd2Value.map { (nextKeyframe.frame, $0.y) }
                    }
                )
                tracks[trackIndex].keyframes[keyIndex].inTangent = xTangents.inTangent
                tracks[trackIndex].keyframes[keyIndex].outTangent = xTangents.outTangent
                tracks[trackIndex].keyframes[keyIndex].secondaryInTangent = yTangents.inTangent
                tracks[trackIndex].keyframes[keyIndex].secondaryOutTangent = yTangents.outTangent
            case .meshDeform, .flag, .drawOrder, .event, .attachment:
                break
            }
        }
    }

    mutating func deleteKeyframes(targetID: UUID, property: AnimationTrackProperty, keyframeIDs: Set<UUID>) {
        defer { didMutate() }
        guard let trackIndex = trackIndex(for: targetID, property: property) else {
            return
        }

        tracks[trackIndex].keyframes.removeAll { keyframeIDs.contains($0.id) }
        if tracks[trackIndex].keyframes.isEmpty {
            tracks.remove(at: trackIndex)
        }
    }

    func retargeted(from sourceID: UUID, to targetID: UUID, renamedTo name: String? = nil) -> AnimationClip {
        var clip = self
        if let name {
            clip.name = name
        }
        clip.tracks = tracks.map { track in
            guard track.targetID == sourceID else { return track }
            var copy = track
            copy.targetID = targetID
            return copy
        }
        return clip
    }

    func evaluatedMeshDeform(for targetID: UUID, frame: Int, fallback: [SIMD2<Float>]) -> [SIMD2<Float>] {
        evaluatedMeshDeform(for: targetID, time: Float(frame), fallback: fallback)
    }

    func evaluatedMeshDeform(for targetID: UUID, time: Float, fallback: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let kfs = keyframes(for: targetID, property: .meshDeform)
        guard !kfs.isEmpty else { return fallback }

        // One binary search where there were three linear passes. The list is
        // sorted by frame — `init` and both mutators sort it — so the insertion
        // point answers all three questions at once.
        let span = Self.keyframeSpan(kfs, time: time)
        if let index = span.exact, case let .meshDeform(verts) = kfs[index].value {
            return verts
        }
        let previous = span.previous.map { kfs[$0] }
        let next = span.next.map { kfs[$0] }

        switch (previous, next) {
        case let (.some(lhs), .some(rhs)):
            guard case let .meshDeform(lv) = lhs.value,
                  case let .meshDeform(rv) = rhs.value,
                  lv.count == rv.count else {
                if case let .meshDeform(v) = lhs.value { return v }
                return fallback
            }
            if lhs.interpolation == .hold { return lv }
            let progress = (time - Float(lhs.frame)) / Float(max(rhs.frame - lhs.frame, 1))
            return zip(lv, rv).map { simd_mix($0, $1, SIMD2<Float>(repeating: progress)) }
        case let (.some(lhs), .none):
            if case let .meshDeform(v) = lhs.value { return v }
            return fallback
        case let (.none, .some(rhs)):
            if case let .meshDeform(v) = rhs.value { return v }
            return fallback
        case (.none, .none):
            return fallback
        }
    }

    /// True when the clip owns a track for this target/property pair, i.e. the
    /// property is animated rather than living at its setup value.
    func hasTrack(for targetID: UUID, property: AnimationTrackProperty) -> Bool {
        tracks.contains { $0.targetID == targetID && $0.property == property && !$0.keyframes.isEmpty }
    }

    /// Every target that owns at least one track in this clip.
    var animatedTargetIDs: Set<UUID> {
        Set(tracks.filter { !$0.keyframes.isEmpty }.map(\.targetID))
    }

    /// Properties animated for a given target, in `AnimationTrackProperty`
    /// declaration order so timeline rows stay stable between rebuilds.
    func animatedProperties(for targetID: UUID) -> [AnimationTrackProperty] {
        let present = Set(
            tracks.filter { $0.targetID == targetID && !$0.keyframes.isEmpty }.map(\.property)
        )
        return AnimationTrackProperty.allCases.filter { present.contains($0) }
    }

    /// Sample a single-float constraint property. Full linear / stepped / Bézier
    /// support comes for free from the shared scalar sampler.
    func evaluatedScalar(
        for targetID: UUID,
        property: AnimationTrackProperty,
        frame: Int,
        fallback: Float
    ) -> Float {
        evaluatedScalar(for: targetID, property: property, time: Float(frame), fallback: fallback)
    }

    func evaluatedScalar(
        for targetID: UUID,
        property: AnimationTrackProperty,
        time: Float,
        fallback: Float
    ) -> Float {
        sampledValue(for: targetID, property: property, time: time, fallback: fallback)
    }

    /// Sample a two-float constraint property (e.g. physics wind).
    func evaluatedVector2(
        for targetID: UUID,
        property: AnimationTrackProperty,
        frame: Int,
        fallback: SIMD2<Float>
    ) -> SIMD2<Float> {
        evaluatedVector2(for: targetID, property: property, time: Float(frame), fallback: fallback)
    }

    func evaluatedVector2(
        for targetID: UUID,
        property: AnimationTrackProperty,
        time: Float,
        fallback: SIMD2<Float>
    ) -> SIMD2<Float> {
        sampledValue(for: targetID, property: property, time: time, fallback: fallback)
    }

    /// Sample a boolean property. Booleans never interpolate: the value is the
    /// one carried by the most recent keyframe at or before `frame`.
    func evaluatedFlag(
        for targetID: UUID,
        property: AnimationTrackProperty,
        frame: Int,
        fallback: Bool
    ) -> Bool {
        evaluatedFlag(for: targetID, property: property, time: Float(frame), fallback: fallback)
    }

    /// Booleans never interpolate, so sampling between frames returns the same
    /// answer a whole frame would: the value carried by the last key at or
    /// before `time`. Stepped stays stepped.
    func evaluatedFlag(
        for targetID: UUID,
        property: AnimationTrackProperty,
        time: Float,
        fallback: Bool
    ) -> Bool {
        let kfs = keyframes(for: targetID, property: property)
        guard !kfs.isEmpty else { return fallback }
        let span = Self.keyframeSpan(kfs, time: time)
        if let index = span.exact ?? span.previous, case let atOrBefore = kfs[index] {
            return atOrBefore.value.boolValue ?? fallback
        }
        // Before the first key the setup value would pop in; the convention is to hold the
        // first key backwards instead, which reads as intentional.
        return kfs.first?.value.boolValue ?? fallback
    }

    /// Sample the draw order permutation. Stepped: there is no meaningful value
    /// between one permutation and the next.
    func evaluatedDrawOrder(frame: Int) -> [UUID]? {
        evaluatedDrawOrder(time: Float(frame))
    }

    func evaluatedDrawOrder(time: Float) -> [UUID]? {
        let kfs = keyframes(for: SceneAnimationTarget.drawOrder, property: .drawOrder)
        guard !kfs.isEmpty else { return nil }
        let span = Self.keyframeSpan(kfs, time: time)
        if let index = span.exact ?? span.previous, case let atOrBefore = kfs[index] {
            return atOrBefore.value.drawOrderValue
        }
        return kfs.first?.value.drawOrderValue
    }

    func pose(for targetID: UUID, basePose: SceneImageAnimationPose, frame: Int) -> SceneImageAnimationPose {
        pose(for: targetID, basePose: basePose, time: Float(frame))
    }

    /// The pose at a continuous time. This is what playback samples.
    ///
    /// - Parameter cyclicRotation: whether the rotation track holds an ANGLE
    ///   (equal modulo 2π) or an accumulated amount of turning. It decides
    ///   which way round the circle two keys are joined, and the answer is
    ///   different for bones and for sprites — see `evaluatedRotation`.
    func pose(for targetID: UUID,
              basePose: SceneImageAnimationPose,
              time: Float,
              cyclicRotation: Bool = false) -> SceneImageAnimationPose {
        SceneImageAnimationPose(
            position: evaluatedTranslate(for: targetID, time: time, fallback: basePose.position),
            scale: evaluatedScale(for: targetID, time: time, fallback: basePose.scale),
            rotation: evaluatedRotation(for: targetID, time: time,
                                        fallback: basePose.rotation, cyclic: cyclicRotation),
            skew: evaluatedShear(for: targetID, time: time, fallback: basePose.skew)
        )
    }

    private func evaluatedTranslate(for targetID: UUID, time: Float, fallback: SIMD2<Float>) -> SIMD2<Float> {
        sampledValue(for: targetID, property: .translate, time: time, fallback: fallback)
    }

    /// Rotation, joined the short way round when the values are angles.
    ///
    /// A BONE's rotation is written by `moveBoneTip` and `setBoneRotation` as
    /// `atan2(...)` — that is, wrapped into (-π, π]. So a bone swung from 179°
    /// to -179°, a movement of two degrees, is stored as two keys 358° apart,
    /// and a plain interpolation walks the whole way round backwards. That is
    /// the 359° -> 0° failure, and it is not hypothetical: the writer wraps and
    /// the sampler did not.
    ///
    /// A SPRITE's rotation is written by `RotateTool` as
    /// `startRotation + delta`, which accumulates and is never wrapped, so 4π
    /// genuinely means two turns. Joining those the short way would silently
    /// delete the spin.
    ///
    /// The two are not the same kind of number, so the caller says which it has.
    /// `clipSampledBones` passes true; the sprite pose pass does not.
    private func evaluatedRotation(for targetID: UUID, time: Float,
                                   fallback: Float, cyclic: Bool) -> Float {
        sampledValue(for: targetID, property: .rotate, time: time,
                     fallback: fallback, cyclic: cyclic)
    }

    private func evaluatedScale(for targetID: UUID, time: Float, fallback: SIMD2<Float>) -> SIMD2<Float> {
        sampledValue(for: targetID, property: .scale, time: time, fallback: fallback)
    }

    private func evaluatedShear(for targetID: UUID, time: Float, fallback: SIMD2<Float>) -> SIMD2<Float> {
        sampledValue(for: targetID, property: .shear, time: time, fallback: fallback)
    }

    private func sampledValue(for targetID: UUID, property: AnimationTrackProperty, time: Float, fallback: SIMD2<Float>) -> SIMD2<Float> {
        let keyframes = keyframes(for: targetID, property: property)
        guard !keyframes.isEmpty else { return fallback }

        let span = Self.keyframeSpan(keyframes, time: time)
        if let exactIndex = span.exact, case let exact = keyframes[exactIndex],
           let value = exact.value.simd2Value {
            return value
        }

        let previous = span.previous.map { keyframes[$0] }
        let next = span.next.map { keyframes[$0] }

        switch (previous, next) {
        case let (.some(lhs), .some(rhs)):
            guard let lhsValue = lhs.value.simd2Value, let rhsValue = rhs.value.simd2Value else { return fallback }
            if lhs.interpolation == .hold {
                return lhsValue
            }
            if lhs.interpolation == .bezier {
                // PER COMPONENT, and each with its own neighbours: x and y are
                // two independent curves through the same keys, so the slope
                // that keeps x continuous is not the one that keeps y
                // continuous.
                let beforeIndex = span.previous.flatMap { $0 > 0 ? $0 - 1 : nil }
                let afterIndex = span.next.flatMap { $0 + 1 < keyframes.count ? $0 + 1 : nil }
                func neighbour(_ index: Int?, _ axis: KeyPath<SIMD2<Float>, Float>)
                    -> (frame: Int, value: Float)? {
                    guard let index, let value = keyframes[index].value.simd2Value
                    else { return nil }
                    return (frame: keyframes[index].frame, value: value[keyPath: axis])
                }
                return SIMD2<Float>(
                    sampledBezierComponentValue(
                        frame: time,
                        lhsFrame: lhs.frame,
                        rhsFrame: rhs.frame,
                        lhsValue: lhsValue.x,
                        rhsValue: rhsValue.x,
                        outTangent: lhs.outTangent,
                        inTangent: rhs.inTangent,
                        beforeStart: neighbour(beforeIndex, \.x),
                        afterEnd: neighbour(afterIndex, \.x)
                    ),
                    sampledBezierComponentValue(
                        frame: time,
                        lhsFrame: lhs.frame,
                        rhsFrame: rhs.frame,
                        lhsValue: lhsValue.y,
                        rhsValue: rhsValue.y,
                        outTangent: lhs.secondaryOutTangent,
                        inTangent: rhs.secondaryInTangent,
                        beforeStart: neighbour(beforeIndex, \.y),
                        afterEnd: neighbour(afterIndex, \.y)
                    )
                )
            }
            let delta = max(rhs.frame - lhs.frame, 1)
            let progress = (time - Float(lhs.frame)) / Float(delta)
            return simd_mix(lhsValue, rhsValue, SIMD2<Float>(repeating: progress))
        case let (.some(lhs), .none):
            return lhs.value.simd2Value ?? fallback
        case let (.none, .some(rhs)):
            return rhs.value.simd2Value ?? fallback
        case (.none, .none):
            return fallback
        }
    }

    /// - Parameter cyclic: when true the two values being joined are angles
    ///   in radians, and the one on the right is rebased to within π of the one
    ///   on the left before anything else happens. Everything after that — the
    ///   hold, the Bézier, the linear blend, the easing — runs unchanged on the
    ///   rebased pair, so this decides only WHICH WAY the rotation goes and
    ///   never how it is timed.
    private func sampledValue(for targetID: UUID, property: AnimationTrackProperty, time: Float,
                              fallback: Float, cyclic: Bool = false) -> Float {
        let keyframes = keyframes(for: targetID, property: property)
        guard !keyframes.isEmpty else { return fallback }

        let span = Self.keyframeSpan(keyframes, time: time)
        if let exactIndex = span.exact, case let exact = keyframes[exactIndex],
           let value = exact.value.floatValue {
            return value
        }

        let previous = span.previous.map { keyframes[$0] }
        let next = span.next.map { keyframes[$0] }

        switch (previous, next) {
        case let (.some(lhs), .some(rhs)):
            guard let lhsValue = lhs.value.floatValue, var rhsValue = rhs.value.floatValue else { return fallback }
            if lhs.interpolation == .hold {
                return lhsValue
            }
            if cyclic {
                rhsValue = lhsValue + shortestAngleDelta(from: lhsValue, to: rhsValue)
            }
            if lhs.interpolation == .bezier {
                // THE NEIGHBOURS, so an auto tangent is the same slope on both
                // sides of a key and the motion does not corner there.
                let before = span.previous.flatMap { index -> (frame: Int, value: Float)? in
                    guard index > 0, let value = keyframes[index - 1].value.floatValue else { return nil }
                    return (frame: keyframes[index - 1].frame, value: value)
                }
                let after = span.next.flatMap { index -> (frame: Int, value: Float)? in
                    guard index + 1 < keyframes.count,
                          let value = keyframes[index + 1].value.floatValue else { return nil }
                    return (frame: keyframes[index + 1].frame, value: value)
                }
                return sampledBezierComponentValue(
                    frame: time,
                    lhsFrame: lhs.frame,
                    rhsFrame: rhs.frame,
                    lhsValue: lhsValue,
                    rhsValue: rhsValue,
                    outTangent: lhs.outTangent,
                    inTangent: rhs.inTangent,
                    beforeStart: before,
                    afterEnd: after
                )
            }
            let delta = max(rhs.frame - lhs.frame, 1)
            let progress = (time - Float(lhs.frame)) / Float(delta)
            return lhsValue + (rhsValue - lhsValue) * progress
        case let (.some(lhs), .none):
            return lhs.value.floatValue ?? fallback
        case let (.none, .some(rhs)):
            return rhs.value.floatValue ?? fallback
        case (.none, .none):
            return fallback
        }
    }

    /// One Bézier component, through the shared curve.
    ///
    /// `beforeStart` and `afterEnd` are the keys on either side of the segment,
    /// and they are what make the motion CONTINUOUS. An auto tangent derived
    /// from a segment's own two keys arrives at a keyframe with one slope and
    /// leaves with another, so the velocity breaks at every key — measured at
    /// 5, 11 and 15 units per frame on a four-segment clip. Derived from the
    /// neighbours it is the same slope on both sides, and the break is zero.
    ///
    /// Before that it was worse in the other direction: the default tangent was
    /// FLAT, so an untangented Bézier key brought the property to a dead stop
    /// and accelerated away again — peak velocity 1.97x the mean, against 1.32
    /// for constant motion. Stop, rush, stop, rush, at every key. That is what
    /// "cortado y acelerado" was.
    private func sampledBezierComponentValue(
        frame: Float,
        lhsFrame: Int,
        rhsFrame: Int,
        lhsValue: Float,
        rhsValue: Float,
        outTangent: SIMD2<Float>?,
        inTangent: SIMD2<Float>?,
        beforeStart: (frame: Int, value: Float)? = nil,
        afterEnd: (frame: Int, value: Float)? = nil
    ) -> Float {
        let segment = AnimationCurve.segment(
            start: (frame: lhsFrame, value: lhsValue),
            end: (frame: rhsFrame, value: rhsValue),
            outTangent: outTangent,
            inTangent: inTangent,
            beforeStart: beforeStart,
            afterEnd: afterEnd)
        return AnimationCurve.value(of: segment, atTime: frame)
    }

    /// Kept as a name, forwarded to the one implementation.
    private func cubicBezierParameter(forX x: Float, p0: Float, p1: Float, p2: Float, p3: Float) -> Float {
        AnimationCurve.parameter(forTime: x, p0, p1, p2, p3)
    }

    private func cubicBezierValue(at t: Float, p0: Float, p1: Float, p2: Float, p3: Float) -> Float {
        AnimationCurve.value(t, p0, p1, p2, p3)
    }

    private func autoTangents(
        currentFrame: Int,
        currentValue: Float,
        previous: (frame: Int, value: Float)?,
        next: (frame: Int, value: Float)?
    ) -> (inTangent: SIMD2<Float>, outTangent: SIMD2<Float>) {
        let incomingSpan = max(Float(currentFrame - (previous?.frame ?? max(currentFrame - 1, 0))), 1)
        let outgoingSpan = max(Float((next?.frame ?? (currentFrame + 1)) - currentFrame), 1)

        let slope: Float
        if let previous, let next {
            // CLAMPED AT A TURNING POINT.
            //
            // Catmull-Rom — (next - previous) / span — is right in the middle
            // of a run and wrong at an extremum. Keys of 0, 10, 9 give the peak
            // a slope of +0.45, so the curve keeps climbing past the key and
            // reaches 10.52 before coming down. The animator placed 10 and got
            // half a unit of overshoot they did not ask for, on every peak.
            //
            // If the value rises into the key and falls out of it, or the
            // reverse, the key is a turning point and the curve must pass
            // through it flat, because an extremum key is a statement about
            // the maximum: the animator chose that value as the highest the
            // property reaches, and a curve that sails past it is answering a
            // question nobody asked.
            //
            // Nothing else changes: a key in the middle of a rising run keeps
            // exactly the slope it had, which is what makes a smooth run
            // smooth. And this runs only when auto-tangents are ASKED for and
            // writes its result into the keyframes, so an animator's own
            // tangents, and every animation already saved, are untouched.
            // The rule itself moved to `AnimationCurve.autoSlope`, so the
            // graph derives the same one. The reasoning above is why it is
            // what it is, and stays here where it was written.
            slope = AnimationCurve.autoSlope(
                previous: (frame: previous.frame, value: previous.value),
                current: (frame: currentFrame, value: currentValue),
                next: (frame: next.frame, value: next.value))
        } else if let previous {
            slope = AnimationCurve.autoSlope(
                previous: (frame: previous.frame, value: previous.value),
                current: (frame: currentFrame, value: currentValue),
                next: nil)
        } else if let next {
            slope = AnimationCurve.autoSlope(
                previous: nil,
                current: (frame: currentFrame, value: currentValue),
                next: (frame: next.frame, value: next.value))
        } else {
            slope = 0
        }

        let inX = -incomingSpan / 3
        let outX = outgoingSpan / 3
        return (
            SIMD2<Float>(inX, slope * inX),
            SIMD2<Float>(outX, slope * outX)
        )
    }
}

extension KeyframeValue {
    var simd2Value: SIMD2<Float>? {
        switch self {
        case let .translate(value):
            return value
        case let .scale(value):
            return value
        case let .shear(value):
            return value
        case let .vector2(value):
            return value
        case .rotate, .scalar, .flag, .meshDeform, .drawOrder, .event, .attachment:
            return nil
        }
    }

    var floatValue: Float? {
        switch self {
        case let .rotate(value):
            return value
        case let .scalar(value):
            return value
        case .translate, .scale, .shear, .vector2, .flag, .meshDeform, .drawOrder, .event, .attachment:
            return nil
        }
    }

    var boolValue: Bool? {
        guard case let .flag(value) = self else { return nil }
        return value
    }

    var eventPayload: AnimationEventPayload? {
        guard case let .event(payload) = self else { return nil }
        return payload
    }

    var drawOrderValue: [UUID]? {
        guard case let .drawOrder(value) = self else { return nil }
        return value
    }

    var meshDeformValue: [SIMD2<Float>]? {
        guard case let .meshDeform(value) = self else { return nil }
        return value
    }
}
