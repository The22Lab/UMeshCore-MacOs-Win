#pragma once

// Port of the MODEL half of `Data/Scene/SceneLight.swift`. The math half
// -- `LightFalloffCurve`, the attenuation, the shaped lambert -- landed in
// Phase 4 as `Render/SceneLighting.h`, and this file does not restate any
// of it: `SceneLightKind` and `SceneLightBlend` are the enums declared
// there, used here rather than declared again.
//
// That is deliberate and it is the shape the port has taken everywhere
// else. Two spellings of "point, spot, directional" is two places for a
// case to be added, and the wire codes hang off the math enums already.
//
// NOT PORTED: `title`, `systemImage`, `Identifiable`, `CaseIterable`, and
// the `String` raw values. The raw values are the FILE FORMAT's business
// and belong to `Serialization/`; the rest are shell. What must survive
// the move is the rule the raw values exist for: a model enum is mapped
// onto a wire code with an explicit switch (`lightKindCode`), never a
// cast, because a cast would make the saved format depend on declaration
// order.

#include <cstdint>
#include <string>
#include <vector>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Render/SceneLighting.h"

namespace umeshcore {

// Which lights touch which layers.
//
// The cheapest thing in the whole system: a light that cannot reach a
// layer is never evaluated for it, so masking is the performance control
// as much as the artistic one -- a set with twelve lights and four masked
// groups costs what three lights cost. Eight channels, which is what fits
// in a byte and more than any 2D set has ever needed.
struct SceneLightMask {
    std::uint8_t rawValue = 0;

    constexpr SceneLightMask() = default;
    constexpr explicit SceneLightMask(std::uint8_t raw) : rawValue(raw) {}

    static constexpr SceneLightMask channel(int index) {
        return SceneLightMask(static_cast<std::uint8_t>(1u << index));
    }
    static constexpr SceneLightMask layer1() { return channel(0); }
    static constexpr SceneLightMask all() { return SceneLightMask(0xFF); }
    // No `none()`: the Swift side records why it refuses to spell one --
    // a member named `none` on a type that is ever optional makes `.none`
    // ambiguous at the call site. `SceneLightMask{}` says the same thing
    // and cannot be misread.

    constexpr bool isEmpty() const { return rawValue == 0; }
    // Do these two share a channel? The whole of masking.
    constexpr bool reaches(SceneLightMask other) const {
        return (rawValue & other.rawValue) != 0;
    }
    constexpr bool contains(SceneLightMask other) const {
        return (rawValue & other.rawValue) == other.rawValue;
    }
    constexpr SceneLightMask unionWith(SceneLightMask other) const {
        return SceneLightMask(static_cast<std::uint8_t>(rawValue | other.rawValue));
    }
    constexpr bool operator==(const SceneLightMask&) const = default;

    // 1-based channel numbers, ascending -- for a label, and in a fixed
    // order because a label that reshuffles between launches is a bug
    // report.
    std::vector<int> channelNumbers() const;
};

// A light in a Scene.
//
// Scene data, saved with the project, and animatable through the same
// tracks the camera uses. It is NOT part of the rig: a light belongs to a
// staging of a scene, not to the character, which is why it lives beside
// `SceneLayer` and never touches `SceneImage`.
struct SceneLight {
    Uuid id;
    std::string name = "Light";
    bool isEnabled = true;
    SceneLightKind kind = SceneLightKind::kPoint;

    // ---- Place ----
    Vec2 position;
    // Depth, in the same axis as `SceneLayer::positionZ` and the camera:
    // higher is further from the camera.
    float positionZ = -300.0f;
    // Which way a spot or a global light points, in the XY plane. Radians.
    float azimuth = 1.57079632679489661923f;
    // Its tilt out of that plane, toward or away from the camera. Radians,
    // positive going AWAY -- the same sign convention `positionZ` uses, so
    // a light "pointing into the set" and a layer "pushed back" agree.
    float elevation = 0.0f;

    // ---- Shape ----
    float radius = 600.0f;
    float intensity = 1.0f;
    Vec3 color = Vec3(1, 1, 1);
    LightFalloffCurve falloff;
    // Where the fade STARTS, as a fraction of the radius: the band is
    // `radius * softness` wide and the light is at full strength inside
    // it.
    //
    // ONE KNOB, NOT TWO THAT FIGHT. It would have been easy to let
    // softness feather the edge AND the curve shape the whole radius, and
    // then no setting of either would mean anything on its own. Here the
    // radius says where the light ends, softness says how much of it is
    // fade, and the curve says what the fade looks like.
    float softness = 1.0f;
    // Spot cone. Full strength inside the inner angle, nothing outside the
    // outer one, smooth between. Radians, half-angles.
    float innerAngle = 20.0f * 3.14159265358979323846f / 180.0f;
    float outerAngle = 35.0f * 3.14159265358979323846f / 180.0f;

    // ---- Behaviour ----
    SceneLightMask mask = SceneLightMask::all();
    SceneLightBlend blend = SceneLightBlend::kNormal;
    // How much the depth difference counts toward the distance. THE WHOLE
    // OF 2.5D, and the only place in the model that mentions Z.
    float depthInfluence = 1.0f;
    // How much the surface's facing counts. 0 is flat 2D lighting, 1 is
    // true Lambert.
    float normalInfluence = 0.0f;
    // Reserved for shadow casting. Stored and persisted from the start so
    // that turning shadows on later does not invalidate a saved scene.
    bool castsShadows = false;

    bool operator==(const SceneLight&) const = default;

    // Where the light actually is.
    Vec3 world() const { return Vec3(position.x, position.y, positionZ); }

    // THE SEAM between the model and the math. `SceneLightParams` is what
    // `Render/SceneLighting.h` asked to be injected, back when the model
    // did not exist; this is the one place that fills it, so no call site
    // re-derives `world` or forgets a field.
    SceneLightParams params() const;
};

} // namespace umeshcore
