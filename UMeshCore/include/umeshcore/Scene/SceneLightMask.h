#pragma once

// `SceneLightMask`, lifted out of `Data/Scene/SceneLight.swift` into its
// own header.
//
// It lives alone because three different things need it and only one of
// them is a light: `SceneLayer.lightMask` says which channels a card sits
// on, `SceneMaterial.shadowCastMask`/`shadowedMask` say which channels it
// casts into and catches from, and `SceneLight.mask` says which it
// reaches. Putting the type in the light's header would make a layer
// include a light to describe itself, which is backwards -- the mask is
// the vocabulary the three share, not a property of any one of them.
//
// It is eight channels because the GPU field is a byte
// (`SceneLightParams::mask`, and the low byte of
// `SceneLayerUniforms::lightMask`). Widening it is a wire-format change,
// not a constant edit.
//
// This is the PERFORMANCE control as much as the artistic one, which is
// the part that is easy to miss when reading it as "visibility flags": a
// light that cannot reach a layer is never evaluated over it, so masking
// a set into groups makes a twelve-light scene cost what three cost.

#include <cstdint>

namespace umeshcore {

struct SceneLightMask {
    std::uint8_t rawValue = 0;

    constexpr SceneLightMask() = default;
    constexpr explicit SceneLightMask(std::uint8_t raw) : rawValue(raw) {}

    // The eight channels. Named from 1 like the inspector shows them, not
    // from 0 like the bit index -- an artist reads "layer 3" off the UI
    // and this is the name they find.
    static constexpr SceneLightMask layer(int oneBased) {
        return SceneLightMask(static_cast<std::uint8_t>(1u << (oneBased - 1)));
    }
    static constexpr SceneLightMask layer1() { return SceneLightMask(1u << 0); }
    static constexpr SceneLightMask layer2() { return SceneLightMask(1u << 1); }
    static constexpr SceneLightMask layer3() { return SceneLightMask(1u << 2); }
    static constexpr SceneLightMask layer4() { return SceneLightMask(1u << 3); }
    static constexpr SceneLightMask layer5() { return SceneLightMask(1u << 4); }
    static constexpr SceneLightMask layer6() { return SceneLightMask(1u << 5); }
    static constexpr SceneLightMask layer7() { return SceneLightMask(1u << 6); }
    static constexpr SceneLightMask layer8() { return SceneLightMask(1u << 7); }

    static constexpr SceneLightMask all() { return SceneLightMask(0xFF); }
    // Swift has no `.none`: the comment there says `SceneLightMask([])`
    // says the same thing and cannot be misread. The C++ default
    // constructor is that empty set, so there is no named constant here
    // either -- `SceneLightMask{}` is the spelling.

    static constexpr int kChannelCount = 8;

    constexpr bool isEmpty() const { return rawValue == 0; }
    constexpr bool contains(SceneLightMask other) const {
        return (rawValue & other.rawValue) == other.rawValue;
    }
    // A light reaches a surface when their masks SHARE a channel -- an
    // intersection test, not a containment one. The distinction matters:
    // a light on channels 1+2 must reach a layer on channel 2 only.
    constexpr bool reaches(SceneLightMask other) const {
        return (rawValue & other.rawValue) != 0;
    }

    constexpr SceneLightMask operator|(SceneLightMask o) const {
        return SceneLightMask(static_cast<std::uint8_t>(rawValue | o.rawValue));
    }
    constexpr SceneLightMask operator&(SceneLightMask o) const {
        return SceneLightMask(static_cast<std::uint8_t>(rawValue & o.rawValue));
    }
    constexpr SceneLightMask& operator|=(SceneLightMask o) {
        rawValue = static_cast<std::uint8_t>(rawValue | o.rawValue);
        return *this;
    }
    constexpr bool operator==(const SceneLightMask&) const = default;
};

} // namespace umeshcore
