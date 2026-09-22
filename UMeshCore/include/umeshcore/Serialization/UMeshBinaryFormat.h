#pragma once

// 1:1 port of `Export/UMeshBinaryFormat.swift` -- the wire-format constants
// for the `.umesh` binary export format (magic/version/chunk IDs/per-chunk
// versions, and the compact enum wire codes used inside chunk payloads).
//
// This header carries no read/write logic, only the format's vocabulary --
// see `Serialization/BinaryWriter.h`/`BinaryReader.h` for the byte-level
// primitives, and future `Serialization/*Chunk.h` files (not yet ported) for
// the actual chunk encoders/decoders.
//
// IMPORTANT: `TrackPropertyCode`'s numeric values are the wire format and
// are explicitly NOT the same as `AnimationTrackProperty`'s C++ enum
// declaration order (see AnimationTrackProperty.h): that header's order
// mirrors `Data/Keyframe.swift`'s own declaration order (light properties
// before DrawOrder/Attachment/Event), while this file's codes are, per the
// Swift source's own comment, "append-only so previously exported files
// keep decoding" -- a separate, frozen numbering assigned in the order
// features shipped. Do NOT `static_cast<uint8_t>(AnimationTrackProperty)`
// anywhere near the wire format; always go through toWireCode/fromWireCode
// below, exactly as the Swift source routes through
// `TrackPropertyCode.init(_:)`/`.trackProperty` rather than `.rawValue`.
//
// Wire layout (little-endian throughout), copied verbatim from the Swift
// source's own header comment:
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
// Chunks are independent and self-describing; readers MAY skip unknown
// chunks using the size field. Versioning is per-chunk: each chunk payload
// begins with its own UInt16 schema version so individual sections can
// evolve.

#include <cstdint>
#include <optional>
#include <stdexcept>

#include "umeshcore/Animation/AnimationTrackProperty.h"
#include "umeshcore/Animation/Keyframe.h"

namespace umeshcore {
namespace UMeshBinaryFormat {

// Computes a 4-character ASCII code as a little-endian UInt32. Encoded
// bytes on disk read as the original string.
constexpr std::uint32_t fourCC(char a, char b, char c, char d) {
    return static_cast<std::uint32_t>(static_cast<unsigned char>(a)) |
           (static_cast<std::uint32_t>(static_cast<unsigned char>(b)) << 8) |
           (static_cast<std::uint32_t>(static_cast<unsigned char>(c)) << 16) |
           (static_cast<std::uint32_t>(static_cast<unsigned char>(d)) << 24);
}

// File magic -- bytes 'U' 'M' 'S' 'H' read sequentially.
inline constexpr std::uint32_t magic = fourCC('U', 'M', 'S', 'H');

// Format major * 256 + minor. Bump on any layout change.
inline constexpr std::uint16_t version = (1 << 8) | 0; // 1.0

// Reserved header flags.
enum class HeaderFlag : std::uint16_t {
    EmbeddedTextures = 0x0001,
};

// Top-level chunk identifiers (FourCC).
enum class ChunkID : std::uint32_t {
    Meta       = fourCC('M', 'E', 'T', 'A'),
    Assets     = fourCC('D', 'A', 'T', 'S'), // texture asset registry
    Skeleton   = fourCC('S', 'K', 'E', 'L'),
    Images     = fourCC('I', 'M', 'G', 'S'),
    Meshes     = fourCC('M', 'E', 'S', 'H'),
    Animations = fourCC('A', 'N', 'I', 'M'),
    Scenes     = fourCC('S', 'C', 'E', 'N'), // staged compositions + camera
};

// Per-chunk schema versions -- bump only the affected chunk on evolution.
namespace ChunkVersion {
inline constexpr std::uint16_t meta       = 1;
inline constexpr std::uint16_t assets     = 1;
inline constexpr std::uint16_t skeleton   = 1;
inline constexpr std::uint16_t images     = 1;
inline constexpr std::uint16_t meshes     = 1;
inline constexpr std::uint16_t animations = 1;
inline constexpr std::uint16_t scenes     = 1;
} // namespace ChunkVersion

// -------------------------------------------------------------------------
// Enum wire codes
// -------------------------------------------------------------------------

// Compact codes for KeyframeInterpolation. Reader maps back to the enum.
enum class InterpCode : std::uint8_t {
    Hold   = 0,
    Linear = 1,
    Bezier = 2,
};

inline InterpCode toWireCode(KeyframeInterpolation value) {
    switch (value) {
        case KeyframeInterpolation::Hold:   return InterpCode::Hold;
        case KeyframeInterpolation::Linear: return InterpCode::Linear;
        case KeyframeInterpolation::Bezier: return InterpCode::Bezier;
    }
    throw std::domain_error("UMeshBinaryFormat::toWireCode(KeyframeInterpolation): unreachable");
}

inline std::optional<KeyframeInterpolation> fromWireCode(InterpCode code) {
    switch (code) {
        case InterpCode::Hold:   return KeyframeInterpolation::Hold;
        case InterpCode::Linear: return KeyframeInterpolation::Linear;
        case InterpCode::Bezier: return KeyframeInterpolation::Bezier;
    }
    return std::nullopt;
}

// Compact codes for AnimationTrackProperty. Values are append-only and
// frozen by prior exports -- never renumber an existing case, only add new
// ones at the end (see the header comment above).
enum class TrackPropertyCode : std::uint8_t {
    Translate  = 0,
    Rotate     = 1,
    Scale      = 2,
    Shear      = 3,
    MeshDeform = 4,

    // Constraint property timelines.
    ConstraintMix         = 5,
    IkSoftness            = 6,
    IkBendPositive        = 7,
    IkStretch             = 8,
    IkCompress             = 9,
    TransformRotateMix    = 10,
    TransformTranslateMix = 11,
    TransformScaleMix     = 12,
    TransformShearMix     = 13,
    PathPosition          = 14,
    PathSpacing           = 15,
    PathPositionMix       = 16,
    PathRotateMix         = 17,
    PhysicsMass           = 18,
    PhysicsDamping        = 19,
    PhysicsStiffness      = 20,
    PhysicsGravity        = 21,
    PhysicsDrag           = 22,
    PhysicsWind           = 23,

    // Scene-wide draw order timeline.
    DrawOrder = 24,
    // Event timeline.
    Event = 25,

    // Camera timelines.
    CameraTranslate  = 26,
    CameraTranslateZ = 27,
    CameraRotate3D   = 28,
    CameraRoll       = 29,
    CameraFOV        = 30,

    Attachment = 31,

    // Light timelines.
    LightTranslate  = 32,
    LightTranslateZ = 33,
    LightIntensity  = 34,
    LightRadius     = 35,
    LightSoftness   = 36,
    LightDirection  = 37,
    LightAngles     = 38,
    LightColorR     = 39,
    LightColorG     = 40,
    LightColorB     = 41,
};

inline TrackPropertyCode toWireCode(AnimationTrackProperty value) {
    using P = AnimationTrackProperty;
    switch (value) {
        case P::Translate:              return TrackPropertyCode::Translate;
        case P::Rotate:                 return TrackPropertyCode::Rotate;
        case P::Scale:                  return TrackPropertyCode::Scale;
        case P::Shear:                  return TrackPropertyCode::Shear;
        case P::MeshDeform:             return TrackPropertyCode::MeshDeform;
        case P::ConstraintMix:          return TrackPropertyCode::ConstraintMix;
        case P::IkSoftness:             return TrackPropertyCode::IkSoftness;
        case P::IkBendPositive:         return TrackPropertyCode::IkBendPositive;
        case P::IkStretch:              return TrackPropertyCode::IkStretch;
        case P::IkCompress:             return TrackPropertyCode::IkCompress;
        case P::TransformRotateMix:     return TrackPropertyCode::TransformRotateMix;
        case P::TransformTranslateMix:  return TrackPropertyCode::TransformTranslateMix;
        case P::TransformScaleMix:      return TrackPropertyCode::TransformScaleMix;
        case P::TransformShearMix:      return TrackPropertyCode::TransformShearMix;
        case P::PathPosition:           return TrackPropertyCode::PathPosition;
        case P::PathSpacing:            return TrackPropertyCode::PathSpacing;
        case P::PathPositionMix:        return TrackPropertyCode::PathPositionMix;
        case P::PathRotateMix:          return TrackPropertyCode::PathRotateMix;
        case P::PhysicsMass:            return TrackPropertyCode::PhysicsMass;
        case P::PhysicsDamping:         return TrackPropertyCode::PhysicsDamping;
        case P::PhysicsStiffness:       return TrackPropertyCode::PhysicsStiffness;
        case P::PhysicsGravity:         return TrackPropertyCode::PhysicsGravity;
        case P::PhysicsDrag:            return TrackPropertyCode::PhysicsDrag;
        case P::PhysicsWind:            return TrackPropertyCode::PhysicsWind;
        case P::DrawOrder:              return TrackPropertyCode::DrawOrder;
        case P::Event:                  return TrackPropertyCode::Event;
        case P::CameraTranslate:        return TrackPropertyCode::CameraTranslate;
        case P::CameraTranslateZ:       return TrackPropertyCode::CameraTranslateZ;
        case P::CameraRotate3D:         return TrackPropertyCode::CameraRotate3D;
        case P::CameraRoll:             return TrackPropertyCode::CameraRoll;
        case P::CameraFOV:              return TrackPropertyCode::CameraFOV;
        case P::Attachment:             return TrackPropertyCode::Attachment;
        case P::LightTranslate:         return TrackPropertyCode::LightTranslate;
        case P::LightTranslateZ:        return TrackPropertyCode::LightTranslateZ;
        case P::LightIntensity:         return TrackPropertyCode::LightIntensity;
        case P::LightRadius:            return TrackPropertyCode::LightRadius;
        case P::LightSoftness:          return TrackPropertyCode::LightSoftness;
        case P::LightDirection:         return TrackPropertyCode::LightDirection;
        case P::LightAngles:            return TrackPropertyCode::LightAngles;
        case P::LightColorR:            return TrackPropertyCode::LightColorR;
        case P::LightColorG:            return TrackPropertyCode::LightColorG;
        case P::LightColorB:            return TrackPropertyCode::LightColorB;
        case P::Count: break;
    }
    throw std::domain_error("UMeshBinaryFormat::toWireCode(AnimationTrackProperty): unreachable");
}

inline std::optional<AnimationTrackProperty> fromWireCode(TrackPropertyCode code) {
    using C = TrackPropertyCode;
    switch (code) {
        case C::Translate:              return AnimationTrackProperty::Translate;
        case C::Rotate:                 return AnimationTrackProperty::Rotate;
        case C::Scale:                  return AnimationTrackProperty::Scale;
        case C::Shear:                  return AnimationTrackProperty::Shear;
        case C::MeshDeform:             return AnimationTrackProperty::MeshDeform;
        case C::ConstraintMix:          return AnimationTrackProperty::ConstraintMix;
        case C::IkSoftness:             return AnimationTrackProperty::IkSoftness;
        case C::IkBendPositive:         return AnimationTrackProperty::IkBendPositive;
        case C::IkStretch:              return AnimationTrackProperty::IkStretch;
        case C::IkCompress:             return AnimationTrackProperty::IkCompress;
        case C::TransformRotateMix:     return AnimationTrackProperty::TransformRotateMix;
        case C::TransformTranslateMix:  return AnimationTrackProperty::TransformTranslateMix;
        case C::TransformScaleMix:      return AnimationTrackProperty::TransformScaleMix;
        case C::TransformShearMix:      return AnimationTrackProperty::TransformShearMix;
        case C::PathPosition:           return AnimationTrackProperty::PathPosition;
        case C::PathSpacing:            return AnimationTrackProperty::PathSpacing;
        case C::PathPositionMix:        return AnimationTrackProperty::PathPositionMix;
        case C::PathRotateMix:          return AnimationTrackProperty::PathRotateMix;
        case C::PhysicsMass:            return AnimationTrackProperty::PhysicsMass;
        case C::PhysicsDamping:         return AnimationTrackProperty::PhysicsDamping;
        case C::PhysicsStiffness:       return AnimationTrackProperty::PhysicsStiffness;
        case C::PhysicsGravity:         return AnimationTrackProperty::PhysicsGravity;
        case C::PhysicsDrag:            return AnimationTrackProperty::PhysicsDrag;
        case C::PhysicsWind:            return AnimationTrackProperty::PhysicsWind;
        case C::DrawOrder:              return AnimationTrackProperty::DrawOrder;
        case C::Event:                  return AnimationTrackProperty::Event;
        case C::CameraTranslate:        return AnimationTrackProperty::CameraTranslate;
        case C::CameraTranslateZ:       return AnimationTrackProperty::CameraTranslateZ;
        case C::CameraRotate3D:         return AnimationTrackProperty::CameraRotate3D;
        case C::CameraRoll:             return AnimationTrackProperty::CameraRoll;
        case C::CameraFOV:              return AnimationTrackProperty::CameraFOV;
        case C::Attachment:             return AnimationTrackProperty::Attachment;
        case C::LightTranslate:         return AnimationTrackProperty::LightTranslate;
        case C::LightTranslateZ:        return AnimationTrackProperty::LightTranslateZ;
        case C::LightIntensity:         return AnimationTrackProperty::LightIntensity;
        case C::LightRadius:            return AnimationTrackProperty::LightRadius;
        case C::LightSoftness:          return AnimationTrackProperty::LightSoftness;
        case C::LightDirection:         return AnimationTrackProperty::LightDirection;
        case C::LightAngles:            return AnimationTrackProperty::LightAngles;
        case C::LightColorR:            return AnimationTrackProperty::LightColorR;
        case C::LightColorG:            return AnimationTrackProperty::LightColorG;
        case C::LightColorB:            return AnimationTrackProperty::LightColorB;
    }
    return std::nullopt;
}

// Compact codes for the KeyframeValue discriminant.
enum class KeyframeValueCode : std::uint8_t {
    Translate  = 0,
    Rotate     = 1,
    Scale      = 2,
    Shear      = 3,
    Scalar     = 4,
    Flag       = 5,
    Vector2    = 6,
    DrawOrder  = 7,
    MeshDeform = 8,
    Event      = 9,
    // Which sprite a slot shows. One id, or none for a slot the key
    // deliberately empties. A reader that does not know this code skips the
    // keyframe, which the format allows by design.
    Attachment = 10,
};

// Compact codes for TransformAnimationSpace.
enum class AnimationSpaceCode : std::uint8_t {
    World     = 0,
    BoneLocal = 1,
};

// -------------------------------------------------------------------------
// Optional flags bitmask
// -------------------------------------------------------------------------

// Bits set on each keyframe header to indicate which optional tangents are
// present in the payload. Compact = no wasted bytes on linear/hold.
struct KeyframeFlags {
    std::uint8_t rawValue = 0;

    static constexpr std::uint8_t inTangent           = 1 << 0;
    static constexpr std::uint8_t outTangent          = 1 << 1;
    static constexpr std::uint8_t secondaryInTangent  = 1 << 2;
    static constexpr std::uint8_t secondaryOutTangent = 1 << 3;

    constexpr KeyframeFlags() = default;
    constexpr explicit KeyframeFlags(std::uint8_t raw) : rawValue(raw) {}

    constexpr bool contains(std::uint8_t bit) const { return (rawValue & bit) != 0; }
    constexpr void insert(std::uint8_t bit) { rawValue |= bit; }
};

struct ImageFlags {
    std::uint8_t rawValue = 0;

    static constexpr std::uint8_t hasBoneBinding = 1 << 0;
    static constexpr std::uint8_t isHidden       = 1 << 1;
    static constexpr std::uint8_t boneLocalSpace = 1 << 2;

    constexpr ImageFlags() = default;
    constexpr explicit ImageFlags(std::uint8_t raw) : rawValue(raw) {}

    constexpr bool contains(std::uint8_t bit) const { return (rawValue & bit) != 0; }
    constexpr void insert(std::uint8_t bit) { rawValue |= bit; }
};

} // namespace UMeshBinaryFormat
} // namespace umeshcore
