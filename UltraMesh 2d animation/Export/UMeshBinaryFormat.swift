import Foundation

// MARK: - UltraMesh Binary Format (.umesh)
//
// Wire layout (little-endian throughout):
//
//   Header (24 bytes)
//     magic       : UInt32  'UMSH' (0x48534D55)
//     version     : UInt16  major << 8 | minor
//     flags       : UInt16
//     chunkCount  : UInt32
//     payloadSize : UInt32  bytes after header
//     reserved    : UInt64
//
//   Chunk (variable)
//     type        : UInt32  FourCC
//     size        : UInt32  bytes of payload (excludes this header)
//     payload     : size bytes
//
// Chunks are independent and self-describing; readers MAY skip unknown chunks
// using the size field. Versioning is per-chunk: each chunk payload begins
// with its own UInt16 schema version so individual sections can evolve.

enum UMeshBinaryFormat {

    /// File magic — bytes 'U' 'M' 'S' 'H' read sequentially.
    static let magic: UInt32 = fourCC("UMSH")

    /// Format major × 256 + minor. Bump on any layout change.
    static let version: UInt16 = (1 << 8) | 0   // 1.0

    /// Reserved header flags.
    enum HeaderFlag: UInt16 {
        case embeddedTextures = 0x0001
    }

    /// Top-level chunk identifiers (FourCC).
    enum ChunkID: UInt32 {
        case meta       = 0x4154454D  // 'META'
        case assets     = 0x53544144  // 'DATS' — texture asset registry
        case skeleton   = 0x4C454B53  // 'SKEL'
        case images     = 0x53474D49  // 'IMGS'
        case meshes     = 0x4853454D  // 'MESH'
        case animations = 0x4D494E41  // 'ANIM'
        case scenes     = 0x4E454353  // 'SCEN' — staged compositions + camera
    }

    // Per-chunk schema versions — bump only the affected chunk on evolution.
    enum ChunkVersion {
        static let meta:       UInt16 = 1
        static let assets:     UInt16 = 1
        static let skeleton:   UInt16 = 1
        static let images:     UInt16 = 1
        static let meshes:     UInt16 = 1
        static let animations: UInt16 = 1
        static let scenes:     UInt16 = 1
    }

    /// Computes a 4-character ASCII code as a little-endian UInt32.
    /// Encoded bytes on disk read as the original string.
    static func fourCC(_ s: String) -> UInt32 {
        precondition(s.utf8.count == 4, "FourCC must be exactly 4 ASCII bytes: \(s)")
        let bytes = Array(s.utf8)
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }
}

// MARK: - Enum Wire Codes

extension UMeshBinaryFormat {

    /// Compact codes for KeyframeInterpolation. Reader maps back to enum.
    enum InterpCode: UInt8 {
        case hold   = 0
        case linear = 1
        case bezier = 2

        init(_ value: KeyframeInterpolation) {
            switch value {
            case .hold:   self = .hold
            case .linear: self = .linear
            case .bezier: self = .bezier
            }
        }
    }

    /// Compact codes for AnimationTrackProperty.
    enum TrackPropertyCode: UInt8 {
        case translate  = 0
        case rotate     = 1
        case scale      = 2
        case shear      = 3
        case meshDeform = 4

        // Constraint property timelines. Codes are append-only so previously
        // exported files keep decoding.
        case constraintMix         = 5
        case ikSoftness            = 6
        case ikBendPositive        = 7
        case ikStretch             = 8
        case ikCompress            = 9
        case transformRotateMix    = 10
        case transformTranslateMix = 11
        case transformScaleMix     = 12
        case transformShearMix     = 13
        case pathPosition          = 14
        case pathSpacing           = 15
        case pathPositionMix       = 16
        case pathRotateMix         = 17
        case physicsMass           = 18
        case physicsDamping        = 19
        case physicsStiffness      = 20
        case physicsGravity        = 21
        case physicsDrag           = 22
        case physicsWind           = 23

        /// Scene-wide draw order timeline.
        case drawOrder             = 24
        /// Event timeline.
        case event                 = 25

        // Camera timelines. Codes are append-only.
        case cameraTranslate       = 26
        case cameraTranslateZ      = 27
        case cameraRotate3D        = 28
        case cameraRoll            = 29
        case cameraFOV             = 30

        case attachment            = 31

        // Light timelines. Codes are append-only, like the camera's above: a
        // runtime that predates them skips the chunk rather than mis-reading a
        // renumbered one.
        case lightTranslate        = 32
        case lightTranslateZ       = 33
        case lightIntensity        = 34
        case lightRadius           = 35
        case lightSoftness         = 36
        case lightDirection        = 37
        case lightAngles           = 38
        case lightColorR           = 39
        case lightColorG           = 40
        case lightColorB           = 41

        init(_ value: AnimationTrackProperty) {
            switch value {
            case .translate:              self = .translate
            case .rotate:                 self = .rotate
            case .scale:                  self = .scale
            case .shear:                  self = .shear
            case .meshDeform:             self = .meshDeform
            case .constraintMix:          self = .constraintMix
            case .ikSoftness:             self = .ikSoftness
            case .ikBendPositive:         self = .ikBendPositive
            case .ikStretch:              self = .ikStretch
            case .ikCompress:             self = .ikCompress
            case .transformRotateMix:     self = .transformRotateMix
            case .transformTranslateMix:  self = .transformTranslateMix
            case .transformScaleMix:      self = .transformScaleMix
            case .transformShearMix:      self = .transformShearMix
            case .pathPosition:           self = .pathPosition
            case .pathSpacing:            self = .pathSpacing
            case .pathPositionMix:        self = .pathPositionMix
            case .pathRotateMix:          self = .pathRotateMix
            case .physicsMass:            self = .physicsMass
            case .physicsDamping:         self = .physicsDamping
            case .physicsStiffness:       self = .physicsStiffness
            case .physicsGravity:         self = .physicsGravity
            case .physicsDrag:            self = .physicsDrag
            case .physicsWind:            self = .physicsWind
            case .drawOrder:              self = .drawOrder
            case .event:                  self = .event
            case .cameraTranslate:        self = .cameraTranslate
            case .cameraTranslateZ:       self = .cameraTranslateZ
            case .cameraRotate3D:         self = .cameraRotate3D
            case .cameraRoll:             self = .cameraRoll
            case .cameraFOV:              self = .cameraFOV
            case .attachment:             self = .attachment
            case .lightTranslate:         self = .lightTranslate
            case .lightTranslateZ:        self = .lightTranslateZ
            case .lightIntensity:         self = .lightIntensity
            case .lightRadius:            self = .lightRadius
            case .lightSoftness:          self = .lightSoftness
            case .lightDirection:         self = .lightDirection
            case .lightAngles:            self = .lightAngles
            case .lightColorR:            self = .lightColorR
            case .lightColorG:            self = .lightColorG
            case .lightColorB:            self = .lightColorB
            }
        }

        var trackProperty: AnimationTrackProperty {
            switch self {
            case .translate:              return .translate
            case .rotate:                 return .rotate
            case .scale:                  return .scale
            case .shear:                  return .shear
            case .meshDeform:             return .meshDeform
            case .constraintMix:          return .constraintMix
            case .ikSoftness:             return .ikSoftness
            case .ikBendPositive:         return .ikBendPositive
            case .ikStretch:              return .ikStretch
            case .ikCompress:             return .ikCompress
            case .transformRotateMix:     return .transformRotateMix
            case .transformTranslateMix:  return .transformTranslateMix
            case .transformScaleMix:      return .transformScaleMix
            case .transformShearMix:      return .transformShearMix
            case .pathPosition:           return .pathPosition
            case .pathSpacing:            return .pathSpacing
            case .pathPositionMix:        return .pathPositionMix
            case .pathRotateMix:          return .pathRotateMix
            case .physicsMass:            return .physicsMass
            case .physicsDamping:         return .physicsDamping
            case .physicsStiffness:       return .physicsStiffness
            case .physicsGravity:         return .physicsGravity
            case .physicsDrag:            return .physicsDrag
            case .physicsWind:            return .physicsWind
            case .drawOrder:              return .drawOrder
            case .event:                  return .event
            case .cameraTranslate:        return .cameraTranslate
            case .cameraTranslateZ:       return .cameraTranslateZ
            case .cameraRotate3D:         return .cameraRotate3D
            case .cameraRoll:             return .cameraRoll
            case .cameraFOV:              return .cameraFOV
            case .attachment:             return .attachment
            case .lightTranslate:         return .lightTranslate
            case .lightTranslateZ:        return .lightTranslateZ
            case .lightIntensity:         return .lightIntensity
            case .lightRadius:            return .lightRadius
            case .lightSoftness:          return .lightSoftness
            case .lightDirection:         return .lightDirection
            case .lightAngles:            return .lightAngles
            case .lightColorR:            return .lightColorR
            case .lightColorG:            return .lightColorG
            case .lightColorB:            return .lightColorB
            }
        }
    }

    /// Compact codes for KeyframeValue discriminant.
    enum KeyframeValueCode: UInt8 {
        case translate = 0
        case rotate    = 1
        case scale     = 2
        case shear     = 3
        case scalar    = 4
        case flag      = 5
        case vector2   = 6
        case drawOrder = 7
        case meshDeform = 8
        case event      = 9
        /// Which sprite a slot shows. One id, or none for a slot the key
        /// deliberately empties. A reader that does not know this code skips
        /// the keyframe, which the format allows by design.
        case attachment = 10
    }

    /// Compact codes for TransformAnimationSpace.
    enum AnimationSpaceCode: UInt8 {
        case world     = 0
        case boneLocal = 1
    }
}

// MARK: - Optional Flags Bitmask

extension UMeshBinaryFormat {
    /// Bits set on each keyframe header to indicate which optional tangents
    /// are present in the payload. Compact = no wasted bytes on linear/hold.
    struct KeyframeFlags: OptionSet {
        let rawValue: UInt8
        static let inTangent           = KeyframeFlags(rawValue: 1 << 0)
        static let outTangent          = KeyframeFlags(rawValue: 1 << 1)
        static let secondaryInTangent  = KeyframeFlags(rawValue: 1 << 2)
        static let secondaryOutTangent = KeyframeFlags(rawValue: 1 << 3)
    }

    struct ImageFlags: OptionSet {
        let rawValue: UInt8
        static let hasBoneBinding   = ImageFlags(rawValue: 1 << 0)
        static let isHidden         = ImageFlags(rawValue: 1 << 1)
        static let boneLocalSpace   = ImageFlags(rawValue: 1 << 2)
    }
}
