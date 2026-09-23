import CxxStdlib
import Foundation
import simd
import UMeshCore

// Phase 6a, stage B: the rig -- keyframes, tracks, clips, bones, the four
// constraints, and the skeleton that holds them.
//
// Every `init(core:)` / `core` pair here is a COPY, field for field. The
// Swift structs keep their own initializers' rules (a stepped key is Hold,
// a track's keys are sorted by frame); UMeshCore's types keep the same
// rules, so a value that satisfied them on one side satisfies them on the
// other, and the copy never has to repair anything.

// MARK: - Keyframe values

extension AnimationEventPayload {
    init(core: umeshcore.AnimationEventPayload) {
        self.init(
            intValue: CoreScalar.optionalInt(core.intValue),
            floatValue: CoreScalar.optionalFloat(core.floatValue),
            stringValue: CoreScalar.optionalString(core.stringValue)
        )
    }

    var core: umeshcore.AnimationEventPayload {
        var out = umeshcore.AnimationEventPayload()
        out.intValue = CoreScalar.optionalInt(intValue)
        out.floatValue = CoreScalar.optionalFloat(floatValue)
        out.stringValue = CoreScalar.optionalString(stringValue)
        return out
    }
}

extension KeyframeValue {
    /// From the flat transport form (`Interop/SwiftBridge.h`): the C++ value
    /// is a `std::variant`, which Swift cannot import, so it crosses as a
    /// case tag plus every case's payload side by side.
    ///
    /// The switch names the C++ cases directly. A misspelled or missing case
    /// is a COMPILE error here, never a silent swap, which is why the tag
    /// does not go through a name table like the String-backed enums do.
    init(core flat: umeshcore.FlatKeyframeValue) {
        switch flat.kind {
        case .Translate: self = .translate(SIMD2<Float>(core: flat.vec2))
        case .Rotate: self = .rotate(flat.scalar)
        case .Scale: self = .scale(SIMD2<Float>(core: flat.vec2))
        case .Shear: self = .shear(SIMD2<Float>(core: flat.vec2))
        case .MeshDeform: self = .meshDeform(CoreVec2.list(flat.meshDeform))
        case .Scalar: self = .scalar(flat.scalar)
        case .Flag: self = .flag(flat.flag)
        case .Vector2: self = .vector2(SIMD2<Float>(core: flat.vec2))
        case .DrawOrder: self = .drawOrder(CoreUUID.list(flat.drawOrder))
        case .Event: self = .event(AnimationEventPayload(core: flat.event))
        case .Attachment:
            self = .attachment(flat.hasAttachment ? UUID(core: flat.attachment) : nil)
        @unknown default:
            preconditionFailure("A keyframe value case UMeshCore added and the bridge does not know")
        }
    }

    var core: umeshcore.FlatKeyframeValue {
        var flat = umeshcore.FlatKeyframeValue()
        switch self {
        case .translate(let v):
            flat.kind = .Translate
            flat.vec2 = v.core
        case .rotate(let r):
            flat.kind = .Rotate
            flat.scalar = r
        case .scale(let v):
            flat.kind = .Scale
            flat.vec2 = v.core
        case .shear(let v):
            flat.kind = .Shear
            flat.vec2 = v.core
        case .meshDeform(let offsets):
            flat.kind = .MeshDeform
            flat.meshDeform = CoreVec2.list(offsets)
        case .scalar(let s):
            flat.kind = .Scalar
            flat.scalar = s
        case .flag(let b):
            flat.kind = .Flag
            flat.flag = b
        case .vector2(let v):
            flat.kind = .Vector2
            flat.vec2 = v.core
        case .drawOrder(let ids):
            flat.kind = .DrawOrder
            flat.drawOrder = CoreUUID.list(ids)
        case .event(let payload):
            flat.kind = .Event
            flat.event = payload.core
        case .attachment(let imageID):
            // An EMPTY attachment is a value ("show nothing"), so it keeps
            // its own flag instead of becoming a nil id.
            flat.kind = .Attachment
            flat.hasAttachment = imageID != nil
            flat.attachment = (imageID ?? CoreUUID.zero).core
        }
        return flat
    }
}

// MARK: - Keyframes, tracks, clips

extension Keyframe {
    init(core: umeshcore.Keyframe) {
        self.init(
            id: UUID(core: core.id),
            frame: Int(core.frame),
            value: KeyframeValue(core: umeshcore.flatKeyframeValue(core)),
            interpolation: KeyframeInterpolation(core: core.interpolation),
            inTangent: CoreVec2.optional(core.inTangent),
            outTangent: CoreVec2.optional(core.outTangent),
            secondaryInTangent: CoreVec2.optional(core.secondaryInTangent),
            secondaryOutTangent: CoreVec2.optional(core.secondaryOutTangent)
        )
    }

    var core: umeshcore.Keyframe {
        var out = umeshcore.makeKeyframe(id.core, CoreScalar.int32(frame), value.core, interpolation.core)
        out.inTangent = CoreVec2.optional(inTangent)
        out.outTangent = CoreVec2.optional(outTangent)
        out.secondaryInTangent = CoreVec2.optional(secondaryInTangent)
        out.secondaryOutTangent = CoreVec2.optional(secondaryOutTangent)
        return out
    }
}

extension AnimationTrack {
    init(core: umeshcore.AnimationTrack) {
        self.init(
            id: UUID(core: core.id),
            targetID: UUID(core: core.targetID),
            property: AnimationTrackProperty(core: core.property),
            keyframes: core.keyframes.map { Keyframe(core: $0) }
        )
    }

    var core: umeshcore.AnimationTrack {
        var out = umeshcore.AnimationTrack()
        out.id = id.core
        out.targetID = targetID.core
        out.property = property.core
        var keys = umeshcore.KeyframeList()
        for keyframe in keyframes { keys.push_back(keyframe.core) }
        out.keyframes = keys
        return out
    }
}

extension AnimationClip {
    init(core: umeshcore.AnimationClip) {
        self.init(
            id: UUID(core: core.id),
            name: String(core.name),
            durationInFrames: Int(core.durationInFrames),
            tracks: umeshcore.clipTracks(core).map { AnimationTrack(core: $0) }
        )
    }

    var core: umeshcore.AnimationClip {
        var out = umeshcore.AnimationClip()
        out.id = id.core
        out.name = std.string(name)
        out.durationInFrames = CoreScalar.int32(durationInFrames)
        var list = umeshcore.AnimationTrackList()
        for track in tracks { list.push_back(track.core) }
        umeshcore.setClipTracks(&out, list)
        return out
    }
}

// MARK: - Bones

extension Bone {
    init(core: umeshcore.Bone) {
        self.init(
            id: UUID(core: core.id),
            name: String(core.name),
            parentID: CoreUUID.optional(core.parentID),
            baseTransform: Transform3D2D(core: core.baseTransform),
            localTransform: Transform3D2D(core: core.localTransform),
            length: core.length,
            animationClip: AnimationClip(core: core.animationClip),
            color: CoreVec4.optional(core.color)
        )
    }

    var core: umeshcore.Bone {
        var out = umeshcore.Bone()
        out.id = id.core
        out.name = std.string(name)
        out.parentID = CoreUUID.optional(parentID)
        out.baseTransform = baseTransform.core
        out.localTransform = localTransform.core
        out.length = length
        out.animationClip = animationClip.core
        out.color = CoreVec4.optional(color)
        return out
    }
}

// MARK: - Constraints
//
// Through UMeshCore's plain `…ConstraintData` structs: the C++ constraint
// classes are polymorphic, and the bridge does not depend on how a given
// Swift release imports a class with virtual functions.

extension IKConstraint {
    init(core: umeshcore.IKConstraintData) {
        self.init(
            id: UUID(core: core.id),
            name: String(core.name),
            enabled: core.enabled,
            order: Int(core.order),
            mix: core.mix,
            boneChain: CoreUUID.list(core.boneChain),
            targetBoneID: UUID(core: core.targetBoneID),
            bendPositive: core.bendPositive,
            stretch: core.stretch,
            compress: core.compress,
            uniformScale: core.uniformScale,
            softness: core.softness
        )
    }

    var core: umeshcore.IKConstraintData {
        var out = umeshcore.IKConstraintData()
        out.id = id.core
        out.name = std.string(name)
        out.enabled = enabled
        out.order = CoreScalar.int32(order)
        out.mix = mix
        out.boneChain = CoreUUID.list(boneChain)
        out.targetBoneID = targetBoneID.core
        out.bendPositive = bendPositive
        out.stretch = stretch
        out.compress = compress
        out.uniformScale = uniformScale
        out.softness = softness
        return out
    }
}

extension TransformConstraint {
    init(core: umeshcore.TransformConstraintData) {
        self.init(
            id: UUID(core: core.id),
            name: String(core.name),
            enabled: core.enabled,
            order: Int(core.order),
            mix: core.mix,
            targetBoneID: UUID(core: core.targetBoneID),
            affectedBones: CoreUUID.list(core.affectedBones),
            copyPosition: core.copyPosition,
            copyRotation: core.copyRotation,
            copyScale: core.copyScale,
            copyShear: core.copyShear,
            positionMix: core.positionMix,
            rotationMix: core.rotationMix,
            scaleMix: core.scaleMix,
            shearMix: core.shearMix,
            offsetPositionX: core.offsetPositionX,
            offsetPositionY: core.offsetPositionY,
            offsetRotation: core.offsetRotation,
            offsetScaleX: core.offsetScaleX,
            offsetScaleY: core.offsetScaleY,
            offsetShear: core.offsetShear
        )
    }

    var core: umeshcore.TransformConstraintData {
        var out = umeshcore.TransformConstraintData()
        out.id = id.core
        out.name = std.string(name)
        out.enabled = enabled
        out.order = CoreScalar.int32(order)
        out.mix = mix
        out.targetBoneID = targetBoneID.core
        out.affectedBones = CoreUUID.list(affectedBones)
        out.copyPosition = copyPosition
        out.copyRotation = copyRotation
        out.copyScale = copyScale
        out.copyShear = copyShear
        out.positionMix = positionMix
        out.rotationMix = rotationMix
        out.scaleMix = scaleMix
        out.shearMix = shearMix
        out.offsetPositionX = offsetPositionX
        out.offsetPositionY = offsetPositionY
        out.offsetRotation = offsetRotation
        out.offsetScaleX = offsetScaleX
        out.offsetScaleY = offsetScaleY
        out.offsetShear = offsetShear
        return out
    }
}

extension PathConstraint {
    init(core: umeshcore.PathConstraintData) {
        self.init(
            id: UUID(core: core.id),
            name: String(core.name),
            enabled: core.enabled,
            order: Int(core.order),
            mix: core.mix,
            pathBones: CoreUUID.list(core.pathBones),
            bones: CoreUUID.list(core.bones),
            position: core.position,
            spacing: core.spacing,
            spacingMode: PathSpacingMode(core: core.spacingMode),
            positionMix: core.positionMix,
            rotateMix: core.rotateMix,
            offsetRotation: core.offsetRotation,
            closed: core.closed,
            reversed: core.reversed,
            rotateMode: PathRotateMode(core: core.rotateMode)
        )
    }

    var core: umeshcore.PathConstraintData {
        var out = umeshcore.PathConstraintData()
        out.id = id.core
        out.name = std.string(name)
        out.enabled = enabled
        out.order = CoreScalar.int32(order)
        out.mix = mix
        out.pathBones = CoreUUID.list(pathBones)
        out.bones = CoreUUID.list(bones)
        out.position = position
        out.spacing = spacing
        out.spacingMode = spacingMode.core
        out.positionMix = positionMix
        out.rotateMix = rotateMix
        out.offsetRotation = offsetRotation
        out.closed = closed
        out.reversed = reversed
        out.rotateMode = rotateMode.core
        return out
    }
}

extension PhysicsSettings {
    init(core: umeshcore.PhysicsSettings) {
        self.init(
            mass: core.mass,
            damping: core.damping,
            stiffness: core.stiffness,
            gravity: core.gravity,
            drag: core.drag,
            wind: SIMD2<Float>(core: core.wind),
            stretchLimit: core.stretchLimit,
            angleLimitMin: core.angleLimitMin,
            angleLimitMax: core.angleLimitMax
        )
    }

    var core: umeshcore.PhysicsSettings {
        var out = umeshcore.PhysicsSettings()
        out.mass = mass
        out.damping = damping
        out.stiffness = stiffness
        out.gravity = gravity
        out.drag = drag
        out.wind = wind.core
        out.stretchLimit = stretchLimit
        out.angleLimitMin = angleLimitMin
        out.angleLimitMax = angleLimitMax
        return out
    }
}

extension PhysicsConstraint {
    init(core: umeshcore.PhysicsConstraintData) {
        self.init(
            id: UUID(core: core.id),
            name: String(core.name),
            enabled: core.enabled,
            order: Int(core.order),
            mix: core.mix,
            physicsType: PhysicsType(core: core.physicsType),
            affectedBones: CoreUUID.list(core.affectedBones),
            settings: PhysicsSettings(core: core.settings)
        )
    }

    var core: umeshcore.PhysicsConstraintData {
        var out = umeshcore.PhysicsConstraintData()
        out.id = id.core
        out.name = std.string(name)
        out.enabled = enabled
        out.order = CoreScalar.int32(order)
        out.mix = mix
        out.physicsType = physicsType.core
        out.affectedBones = CoreUUID.list(affectedBones)
        out.settings = settings.core
        return out
    }
}

// MARK: - Skeleton

extension Skeleton {
    /// The bone table arrives as a list (a C++ hash map with a custom hasher
    /// does not cross); `Skeleton.init` rebuilds the children index from it,
    /// exactly as it does for any other new skeleton.
    init(core: umeshcore.Skeleton) {
        var bones: [UUID: Bone] = [:]
        for bone in umeshcore.skeletonBones(core) {
            let converted = Bone(core: bone)
            bones[converted.id] = converted
        }
        self.init(
            bones: bones,
            rootIDs: CoreUUID.list(core.rootIDs),
            ikConstraints: umeshcore.skeletonIKConstraints(core).map { IKConstraint(core: $0) },
            transformConstraints: umeshcore.skeletonTransformConstraints(core).map { TransformConstraint(core: $0) },
            pathConstraints: umeshcore.skeletonPathConstraints(core).map { PathConstraint(core: $0) },
            physicsConstraints: umeshcore.skeletonPhysicsConstraints(core).map { PhysicsConstraint(core: $0) }
        )
    }

    var core: umeshcore.Skeleton {
        var out = umeshcore.Skeleton()
        out.rootIDs = CoreUUID.list(rootIDs)

        var boneList = umeshcore.BoneList()
        for bone in bones.values { boneList.push_back(bone.core) }
        umeshcore.setSkeletonBones(&out, boneList)

        var ik = umeshcore.IKConstraintDataList()
        for constraint in ikConstraints { ik.push_back(constraint.core) }
        umeshcore.setSkeletonIKConstraints(&out, ik)

        var transform = umeshcore.TransformConstraintDataList()
        for constraint in transformConstraints { transform.push_back(constraint.core) }
        umeshcore.setSkeletonTransformConstraints(&out, transform)

        var path = umeshcore.PathConstraintDataList()
        for constraint in pathConstraints { path.push_back(constraint.core) }
        umeshcore.setSkeletonPathConstraints(&out, path)

        var physics = umeshcore.PhysicsConstraintDataList()
        for constraint in physicsConstraints { physics.push_back(constraint.core) }
        umeshcore.setSkeletonPhysicsConstraints(&out, physics)
        return out
    }
}
