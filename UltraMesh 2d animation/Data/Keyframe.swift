import Foundation
import simd

enum KeyframeInterpolation: String, CaseIterable, Equatable {
    case hold
    case linear
    case bezier
}

/// What kind of payload a track's keyframes carry. Drives generic handling in
/// the timeline (which graph channels to draw), the inspector (which editor to
/// show) and persistence, so adding a new animatable property does not require
/// touching every switch in the editor.
enum TrackValueKind: Equatable {
    /// Two independent float channels (x / y).
    case vector2
    /// A single float channel.
    case scalar
    /// A boolean. Always evaluated as stepped, as boolean timelines must be.
    case flag
    /// Per-vertex mesh offsets (FFD).
    case deform
    /// A full permutation of sprite IDs.
    case drawOrder
    /// A discrete event firing with its payload.
    case event
    /// Which attachment a slot shows. Discrete, like `.flag`: there is no
    /// halfway between two PNGs, so an attachment track is always stepped.
    case attachment
}

/// Which entity a track's `targetID` refers to. Used to route evaluation and to
/// build timeline rows without guessing from the ID alone.
enum AnimationTrackDomain: Equatable {
    /// `targetID` is a bone ID or a sprite ID.
    case node
    /// `targetID` is a constraint ID (IK, transform, path or physics).
    case constraint
    /// `targetID` is one of `SceneAnimationTarget`'s fixed IDs.
    case scene
    /// `targetID` is a SLOT, derived from its name by `SlotAnimationTarget`.
    ///
    /// Slots are named rather than identified, because that is what they
    /// already are: `SceneImage.slotName` groups the sprites that are variants
    /// of one attachment point, and `Skin.attachments` maps the name to the
    /// sprite. The timeline addresses the same thing the skins do.
    case slot
}

/// Stable ids for slot-owned tracks.
///
/// A slot has a name, not an id, so the track's `targetID` is derived from the
/// name — deterministically, so a saved project resolves its tracks on the next
/// launch. Renaming a slot therefore orphans its attachment track — the price of
/// a derived id, and the reason `SceneManager.renameSlot` moves
/// the track across so the artist never meets it.
enum SlotAnimationTarget {
    static func id(forSlotNamed name: String) -> UUID {
        // FNV-1a over the name, widened to sixteen bytes. Deterministic across
        // launches and platforms, which `hashValue` is explicitly not.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Array(name.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        var second: UInt64 = 0x9e3779b97f4a7c15 ^ hash
        second = second &* 0xff51afd7ed558ccd
        second ^= second >> 33
        var bytes = [UInt8]()
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((hash >> UInt64(shift)) & 0xff))
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((second >> UInt64(shift)) & 0xff))
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Fixed UUIDs for scene-wide tracks that are not owned by any bone, sprite or
/// constraint. They are stable across launches so saved projects keep resolving.
enum SceneAnimationTarget {
    /// Owner of the draw order timeline.
    static let drawOrder = UUID(uuidString: "5D8A0C61-4E2F-4B7A-9C3D-0F1E2A3B4C5D")!
    /// Owner of the Scene camera timelines.
    static let camera = UUID(uuidString: "1C4E9B27-7A63-4F0D-8E51-2B6D9A0F3C84")!
}

enum AnimationTrackProperty: String, CaseIterable, Identifiable, Hashable {

    // MARK: Bone / sprite transform tracks

    case translate
    case rotate
    case scale
    case shear
    case meshDeform

    // MARK: Constraint tracks - target is a constraint ID

    /// Master blend, present on every constraint type.
    case constraintMix

    case ikSoftness
    case ikBendPositive
    case ikStretch
    case ikCompress

    case transformRotateMix
    case transformTranslateMix
    case transformScaleMix
    case transformShearMix

    case pathPosition
    case pathSpacing
    case pathPositionMix
    case pathRotateMix

    case physicsMass
    case physicsDamping
    case physicsStiffness
    case physicsGravity
    case physicsDrag
    case physicsWind

    // MARK: Scene tracks

    /// The Scene camera. `targetID` is `SceneAnimationTarget.camera`.
    ///
    /// The camera is the ONLY thing a Scene keyframes — layers are placed and
    /// stay put, because Scene assembles finished animations rather than making
    /// new ones. Five properties rather than one composite so each row in the
    /// timeline is a channel the artist can key and ease on its own, which is
    /// how every other transform here already works.
    case cameraTranslate
    case cameraTranslateZ
    /// Pitch and yaw. Roll is `cameraRoll`, kept apart so the two can be keyed
    /// independently without fighting over the z channel of one vector.
    case cameraRotate3D
    case cameraRoll
    case cameraFOV

    /// A Scene LIGHT. `targetID` is the light's own id, not a fixed one — a
    /// scene holds as many lights as the artist makes, where it holds exactly
    /// one camera.
    ///
    /// Every one of these rides the tracks, the curves and the Graph editor
    /// that already exist. A light blinking is an intensity curve; a torch
    /// sweeping a room is a direction curve. There is no lighting-specific
    /// animation anywhere, which was the point.
    case lightTranslate
    case lightTranslateZ
    case lightIntensity
    case lightRadius
    case lightSoftness
    /// Azimuth and elevation, as one vector so a sweep eases as one move.
    case lightDirection
    /// Inner and outer cone half-angles.
    case lightAngles
    /// Colour, as THREE scalar channels.
    ///
    /// A track carries at most two independently-eased channels — it has one
    /// pair of tangents and one secondary pair — and a colour has three. The
    /// choice was between inventing a third tangent pair across the whole
    /// keyframe format, or three rows. Three rows, which is what After Effects
    /// shows in its own graph editor for a colour, and which gives per-channel
    /// easing rather than the single shared ease a packed colour would have
    /// had. The inspector still shows one swatch.
    case lightColorR
    case lightColorG
    case lightColorB

    case drawOrder
    /// Which attachment a slot shows. `targetID` is the slot, from
    /// `SlotAnimationTarget`. One row per slot.
    case attachment
    /// Event timeline. `targetID` is an `AnimationEvent` id, so each event name
    /// gets its own row.
    case event

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translate:              return "Translate"
        case .rotate:                 return "Rotate"
        case .scale:                  return "Scale"
        case .shear:                  return "Shear"
        case .meshDeform:             return "Deform"
        case .constraintMix:          return "Mix"
        case .ikSoftness:             return "Softness"
        case .ikBendPositive:         return "Bend Positive"
        case .ikStretch:              return "Stretch"
        case .ikCompress:             return "Compress"
        case .transformRotateMix:     return "Rotate Mix"
        case .transformTranslateMix:  return "Translate Mix"
        case .transformScaleMix:      return "Scale Mix"
        case .transformShearMix:      return "Shear Mix"
        case .pathPosition:           return "Position"
        case .pathSpacing:            return "Spacing"
        case .pathPositionMix:        return "Position Mix"
        case .pathRotateMix:          return "Rotate Mix"
        case .physicsMass:            return "Mass"
        case .physicsDamping:         return "Damping"
        case .physicsStiffness:       return "Stiffness"
        case .physicsGravity:         return "Gravity"
        case .physicsDrag:            return "Drag"
        case .physicsWind:            return "Wind"
        case .cameraTranslate:        return "Position"
        case .cameraTranslateZ:       return "Depth"
        case .cameraRotate3D:         return "Rotation X/Y"
        case .cameraRoll:             return "Roll"
        case .cameraFOV:              return "FOV"
        case .lightTranslate:         return "Position"
        case .lightTranslateZ:        return "Depth"
        case .lightIntensity:         return "Intensity"
        case .lightRadius:            return "Radius"
        case .lightSoftness:          return "Softness"
        case .lightDirection:         return "Direction"
        case .lightAngles:            return "Cone"
        case .lightColorR:            return "Colour R"
        case .lightColorG:            return "Colour G"
        case .lightColorB:            return "Colour B"
        case .drawOrder:              return "Draw Order"
        case .attachment:             return "Attachment"
        case .event:                  return "Event"
        }
    }

    var systemImage: String {
        switch self {
        case .translate:
            return "arrow.up.and.down.and.arrow.left.and.right"
        case .rotate:
            return "arrow.clockwise"
        case .scale:
            return "arrow.up.left.and.arrow.down.right"
        case .shear:
            return "square.on.square.dashed"
        case .meshDeform:
            return "grid"
        case .cameraTranslate, .cameraTranslateZ:
            return "video"
        case .cameraRotate3D, .cameraRoll:
            return "rotate.3d"
        case .cameraFOV:
            return "camera.aperture"
        case .lightTranslate, .lightTranslateZ:
            return "lightbulb"
        case .lightIntensity, .lightRadius, .lightSoftness:
            return "sun.max"
        case .lightDirection, .lightAngles:
            return "flashlight.on.fill"
        case .lightColorR, .lightColorG, .lightColorB:
            return "paintpalette"
        case .drawOrder:
            return "square.stack.3d.up"
        case .attachment:
            return "rectangle.on.rectangle"
        case .event:
            return "bolt"
        case .ikBendPositive, .ikStretch, .ikCompress:
            return "checkmark.square"
        default:
            return "slider.horizontal.3"
        }
    }

    var domain: AnimationTrackDomain {
        switch self {
        case .translate, .rotate, .scale, .shear, .meshDeform:
            return .node
        case .attachment:
            return .slot
        case .drawOrder, .event,
             .cameraTranslate, .cameraTranslateZ, .cameraRotate3D, .cameraRoll, .cameraFOV,
             .lightTranslate, .lightTranslateZ, .lightIntensity, .lightRadius,
             .lightSoftness, .lightDirection, .lightAngles,
             .lightColorR, .lightColorG, .lightColorB:
            return .scene
        default:
            return .constraint
        }
    }

    var valueKind: TrackValueKind {
        switch self {
        case .translate, .scale, .shear, .physicsWind,
             .cameraTranslate, .cameraRotate3D,
             .lightTranslate, .lightDirection, .lightAngles:
            return .vector2
        case .rotate,
             .cameraTranslateZ, .cameraRoll, .cameraFOV,
             .constraintMix,
             .ikSoftness,
             .transformRotateMix, .transformTranslateMix, .transformScaleMix, .transformShearMix,
             .pathPosition, .pathSpacing, .pathPositionMix, .pathRotateMix,
             .physicsMass, .physicsDamping, .physicsStiffness, .physicsGravity, .physicsDrag,
             .lightTranslateZ, .lightIntensity, .lightRadius, .lightSoftness,
             .lightColorR, .lightColorG, .lightColorB:
            return .scalar
        case .ikBendPositive, .ikStretch, .ikCompress:
            return .flag
        case .meshDeform:
            return .deform
        case .drawOrder:
            return .drawOrder
        case .attachment:
            return .attachment
        case .event:
            return .event
        }
    }

    /// Boolean and draw-order tracks have no meaningful in-between value, so the
    /// editor forces stepped interpolation on them.
    var forcesSteppedInterpolation: Bool {
        switch valueKind {
        case .flag, .drawOrder, .event, .attachment:
            return true
        case .vector2, .scalar, .deform:
            return false
        }
    }

    /// Inclusive editing range for scalar constraint properties, used by the
    /// inspector sliders and to clamp animated results. `nil` means unbounded.
    var valueRange: ClosedRange<Float>? {
        switch self {
        case .constraintMix,
             .transformRotateMix, .transformTranslateMix, .transformScaleMix, .transformShearMix,
             .pathPositionMix, .pathRotateMix,
             .pathPosition,
             .physicsDamping:
            return 0...1
        case .ikSoftness, .physicsMass, .physicsStiffness, .physicsDrag:
            return 0...10_000
        case .lightSoftness, .lightColorR, .lightColorG, .lightColorB:
            return 0...1
        default:
            return nil
        }
    }

    /// Properties exposed by each constraint type, in inspector display order.
    static let ikProperties: [AnimationTrackProperty] = [
        .constraintMix, .ikSoftness, .ikBendPositive, .ikStretch, .ikCompress
    ]

    static let transformProperties: [AnimationTrackProperty] = [
        .constraintMix, .transformTranslateMix, .transformRotateMix, .transformScaleMix, .transformShearMix
    ]

    static let pathProperties: [AnimationTrackProperty] = [
        .constraintMix, .pathPosition, .pathSpacing, .pathPositionMix, .pathRotateMix
    ]

    static let physicsProperties: [AnimationTrackProperty] = [
        .constraintMix, .physicsMass, .physicsDamping, .physicsStiffness,
        .physicsGravity, .physicsDrag, .physicsWind
    ]

    /// Transform tracks in the order the timeline lists them for a node.
    static let nodeProperties: [AnimationTrackProperty] = [
        .translate, .rotate, .scale, .shear, .meshDeform
    ]

    /// Camera rows in the order the Scene timeline lists them.
    static let cameraProperties: [AnimationTrackProperty] = [
        .cameraTranslate, .cameraTranslateZ, .cameraRotate3D, .cameraRoll, .cameraFOV
    ]

    /// Light rows, in the order the Scene timeline lists them.
    ///
    /// A LIST, walked in this order everywhere a light is keyed or cleared. The
    /// camera's equivalent is walked to delete a key at a frame, and doing that
    /// through a Set would delete in whatever order the process's hash seed
    /// produced — which shows up as a key that survives one launch in ten.
    static let lightProperties: [AnimationTrackProperty] = [
        .lightTranslate, .lightTranslateZ, .lightIntensity, .lightRadius,
        .lightSoftness, .lightDirection, .lightAngles,
        .lightColorR, .lightColorG, .lightColorB
    ]

    /// The colour channels, paired with where each one reads and writes.
    ///
    /// One list, so the three places that handle a light's colour — sampling,
    /// keying, clearing — cannot disagree about which row is green.
    static let lightColourChannels: [(property: AnimationTrackProperty,
                                      axis: WritableKeyPath<SIMD3<Float>, Float>)] = [
        (.lightColorR, \.x), (.lightColorG, \.y), (.lightColorB, \.z)
    ]
}

enum KeyframeValue: Equatable {
    case translate(SIMD2<Float>)
    case rotate(Float)
    case scale(SIMD2<Float>)
    case shear(SIMD2<Float>)
    case meshDeform([SIMD2<Float>])
    /// Generic single-float payload for constraint properties.
    case scalar(Float)
    /// Generic boolean payload. Stepped by construction.
    case flag(Bool)
    /// Generic two-float payload (physics wind, and any future vector property).
    case vector2(SIMD2<Float>)
    /// A complete draw order: sprite IDs from topmost to bottommost, matching
    /// the ordering convention of `SceneManager.images`.
    case drawOrder([UUID])
    /// An event firing. The payload only carries the fields this keyframe
    /// overrides; the rest come from the event definition.
    case event(AnimationEventPayload)
    /// The sprite a slot shows. `nil` empties the slot deliberately, which is
    /// different from having no key at all — that leaves the skin's choice
    /// standing.
    case attachment(UUID?)

    var kind: TrackValueKind {
        switch self {
        case .translate, .scale, .shear, .vector2: return .vector2
        case .rotate, .scalar:                     return .scalar
        case .flag:                                return .flag
        case .meshDeform:                          return .deform
        case .drawOrder:                           return .drawOrder
        case .event:                               return .event
        case .attachment:                          return .attachment
        }
    }
}

struct Keyframe: Identifiable, Equatable {
    let id: UUID
    var frame: Int
    var value: KeyframeValue
    var interpolation: KeyframeInterpolation
    var inTangent: SIMD2<Float>?
    var outTangent: SIMD2<Float>?
    var secondaryInTangent: SIMD2<Float>?
    var secondaryOutTangent: SIMD2<Float>?

    init(
        id: UUID = UUID(),
        frame: Int,
        value: KeyframeValue,
        interpolation: KeyframeInterpolation = .linear,
        inTangent: SIMD2<Float>? = nil,
        outTangent: SIMD2<Float>? = nil,
        secondaryInTangent: SIMD2<Float>? = nil,
        secondaryOutTangent: SIMD2<Float>? = nil
    ) {
        self.id = id
        self.frame = frame
        self.value = value
        // Boolean and draw-order payloads have no in-between state.
        switch value {
        case .flag, .drawOrder, .event, .attachment:
            self.interpolation = .hold
        default:
            self.interpolation = interpolation
        }
        self.inTangent = inTangent
        self.outTangent = outTangent
        self.secondaryInTangent = secondaryInTangent
        self.secondaryOutTangent = secondaryOutTangent
    }
}

struct SelectedKeyframe: Hashable {
    /// The owning entity: a sprite ID, a bone ID, a constraint ID, or one of
    /// `SceneAnimationTarget`'s fixed IDs. The name is kept for source
    /// compatibility with the existing timeline and persistence code.
    var imageID: UUID
    var property: AnimationTrackProperty
    var keyframeID: UUID
}

struct CopiedKeyframePayload: Equatable {
    var imageID: UUID
    var property: AnimationTrackProperty
    var relativeFrame: Int
    var value: KeyframeValue
    var interpolation: KeyframeInterpolation
    var inTangent: SIMD2<Float>?
    var outTangent: SIMD2<Float>?
    var secondaryInTangent: SIMD2<Float>?
    var secondaryOutTangent: SIMD2<Float>?
}
