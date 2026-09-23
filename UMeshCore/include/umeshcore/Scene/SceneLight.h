#pragma once

// Port of the MODEL half of `Data/Scene/SceneLight.swift`: `SceneLight`,
// `SceneAmbient`, and the file-format names of the two enums.
//
// The MATH half already landed in Phase 4, in `Render/SceneLighting.h` --
// `LightFalloffCurve`, `lightDirection`, `lightInnerRadius`,
// `lightBandWidth`, and `SceneLightParams`, which is precisely "everything
// the lighting math reads off a light". So this file does not restate any
// of it. `SceneLight::params()` fills a `SceneLightParams` and every
// derived quantity is asked of the existing function. A second
// transcription of `direction` or of the band width is exactly the failure
// this port keeps recording (three copies of world-to-screen that already
// disagreed), and a light's falloff would be a particularly bad place for
// it: the band width is what the lattice density is chosen from, so two
// versions would not look wrong, they would look SLIGHTLY grainy.
//
// ONE ENUM, TWO NAMES. `SceneLightKind` and `SceneLightBlend` are the
// enums `Render/SceneLighting.h` already declares; this file adds their
// `rawValue` strings, which are the FILE FORMAT's spelling. Declaring a
// second pair of "model" enums and mapping between them would double the
// switch count for nothing -- what actually has to be explicit is the
// mapping from a case to a stored token, and that is what
// `sceneLightKindName` and friends are. Never a cast: a cast would make
// the saved file depend on declaration order, which is the rule
// `SceneGPUTypes.h` states for the wire codes and the Scene model follows.
//
// A light is NOT part of the rig. It belongs to a staging of a scene, not
// to the character, which is why it lives beside `SceneLayer` and never
// touches `SceneImage`.

#include <optional>
#include <string>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Render/SceneLighting.h"
#include "umeshcore/Scene/SceneLightMask.h"

namespace umeshcore {

// ---- The file format's spelling of the two enums -----------------------

// Three kinds, and deliberately only three at this level: everything an
// artist listed -- lamps, fire, magic, torches, spots, a sun -- is one of
// these with different numbers, and a fourth case would be a fourth
// attenuation formula to keep in step with the other three. Area lights
// and cookies, when they come, are a POINT light with something extra
// sampled, not a new kind.
inline const char* sceneLightKindName(SceneLightKind kind) {
    switch (kind) {
        case SceneLightKind::kPoint: return "point";
        case SceneLightKind::kSpot: return "spot";
        case SceneLightKind::kDirectional: return "directional";
    }
    return "point";
}

// The kind as the inspector names it -- and as a new light is named
// ("Point 1", "Global 3"), which is why it is model-side. Not the file
// spelling: `directional` shows as "Global".
inline const char* sceneLightKindTitle(SceneLightKind kind) {
    switch (kind) {
        case SceneLightKind::kPoint: return "Point";
        case SceneLightKind::kSpot: return "Spot";
        case SceneLightKind::kDirectional: return "Global";
    }
    return "Point";
}

inline std::optional<SceneLightKind> sceneLightKindFromName(const std::string& name) {
    if (name == "point") return SceneLightKind::kPoint;
    if (name == "spot") return SceneLightKind::kSpot;
    if (name == "directional") return SceneLightKind::kDirectional;
    return std::nullopt;
}

// Whether the light has a PLACE at all. A directional light does not: it
// is a direction and nothing else, so moving it would be a control that
// changes nothing -- which is worse than not having it.
inline bool sceneLightIsPositional(SceneLightKind kind) {
    return kind != SceneLightKind::kDirectional;
}

// `normal` and the three others are not variations of one operation. A
// normal light adds into the factor that MULTIPLIES the artwork, so it
// illuminates: a black sprite stays black however much you point at it,
// which is what light does. An additive light is added AFTER that
// multiply, so it emits: it survives a black sprite, which is what fire
// and magic need and what every artist reaches for first.
inline const char* sceneLightBlendName(SceneLightBlend blend) {
    switch (blend) {
        case SceneLightBlend::kNormal: return "normal";
        case SceneLightBlend::kAdditive: return "additive";
        case SceneLightBlend::kMultiply: return "multiply";
        case SceneLightBlend::kScreen: return "screen";
    }
    return "normal";
}

inline std::optional<SceneLightBlend> sceneLightBlendFromName(const std::string& name) {
    if (name == "normal") return SceneLightBlend::kNormal;
    if (name == "additive") return SceneLightBlend::kAdditive;
    if (name == "multiply") return SceneLightBlend::kMultiply;
    if (name == "screen") return SceneLightBlend::kScreen;
    return std::nullopt;
}

// ---- The light ---------------------------------------------------------

struct SceneLight {
    Uuid id;
    std::string name = "Light";
    bool isEnabled = true;
    SceneLightKind kind = SceneLightKind::kPoint;

    // ---- Place ----
    Vec2 position;
    // Depth, in the same axis as `SceneLayer::positionZ` and
    // `SceneCamera::positionZ`: higher is further from the camera.
    float positionZ = -300.0f;
    // Which way a spot or a global light points, in the XY plane. Radians.
    float azimuth = 1.57079632679489661923f; // pi / 2
    // Its tilt out of that plane, toward or away from the camera. Radians,
    // POSITIVE GOING AWAY -- the same sign convention `positionZ` uses, so
    // a light "pointing into the set" and a layer "pushed back" agree.
    float elevation = 0.0f;

    // ---- Shape ----
    float radius = 600.0f;
    float intensity = 1.0f;
    Vec3 color = Vec3(1, 1, 1);
    LightFalloffCurve falloff; // defaults to `smooth`
    // Where the fade STARTS, as a fraction of the radius: the band is
    // `radius * softness` wide and the light is at full strength inside
    // it.
    //
    // ONE KNOB, not two that fight. It would have been easy to let
    // softness feather the edge AND the curve shape the whole radius, and
    // then no setting of either would mean anything on its own. Here the
    // radius says where the light ends, softness says how much of it is
    // fade, and the curve says what the fade looks like.
    float softness = 1.0f;
    // Spot cone. Full strength inside the inner angle, nothing outside the
    // outer one, smooth between. Radians, HALF-angles.
    float innerAngle = 20.0f * 3.14159265358979323846f / 180.0f;
    float outerAngle = 35.0f * 3.14159265358979323846f / 180.0f;

    // ---- Behaviour ----
    SceneLightMask mask = SceneLightMask::all();
    SceneLightBlend blend = SceneLightBlend::kNormal;
    // How much the depth difference counts toward the distance. 0 makes
    // the light flat -- every layer lit as though it sat at the light's
    // own depth, which is ordinary 2D lighting and what an artist staging
    // a flat scene wants. 1 makes it a real point in space. NOTHING ELSE
    // IN THE MODEL KNOWS ABOUT Z: this single multiplier is the whole of
    // 2.5D lighting, which is what keeps it from being a special case
    // threaded through every formula.
    float depthInfluence = 1.0f;
    // How much the surface's facing counts. 0 is flat 2D lighting, 1 is
    // true Lambert. It existed before normal maps did, because a normal
    // map changes only WHERE the normal comes from -- so the day it
    // landed, nothing in the shading needed rewriting.
    float normalInfluence = 0.0f;
    // Reserved for shadow casting, stored and persisted from the start so
    // that turning shadows on later does not invalidate a saved scene.
    bool castsShadows = false;

    bool operator==(const SceneLight&) const = default;

    Vec3 world() const { return Vec3(position.x, position.y, positionZ); }

    // Everything the lighting math reads off this light, in the shape
    // `Render/SceneLighting.h` already asks for. This is the ONE place the
    // model meets the math, and the reason nothing below re-derives a
    // direction or a band width.
    SceneLightParams params() const {
        SceneLightParams out;
        out.kind = kind;
        out.blend = blend;
        out.mask = mask.rawValue;
        out.isEnabled = isEnabled;
        out.world = world();
        out.azimuth = azimuth;
        out.elevation = elevation;
        out.radius = radius;
        out.intensity = intensity;
        out.color = color;
        out.softness = softness;
        out.innerAngle = innerAngle;
        out.outerAngle = outerAngle;
        out.depthInfluence = depthInfluence;
        out.normalInfluence = normalInfluence;
        out.castsShadows = castsShadows;
        out.falloff = falloff;
        return out;
    }

    // The three derived quantities, asked of the math rather than
    // recomputed. They are here because the Swift model has them as
    // properties and callers expect to find them on a light.
    Vec3 direction() const { return lightDirection(azimuth, elevation); }
    float innerRadius() const { return lightInnerRadius(params()); }
    float bandWidth() const { return lightBandWidth(params()); }
};

// `SceneAmbient` is NOT here: it is already ported, in
// `Render/SceneLighting.h`, because the lighting solve holds one directly.
// Re-declaring the model's copy beside it is how two structs that mean the
// same thing start to differ by a field -- the failure this port keeps
// recording. Include that header (this one already does) and use it.

} // namespace umeshcore
