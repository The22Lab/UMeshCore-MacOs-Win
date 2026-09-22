#pragma once

// 1:1 port of `Data/Scene/SceneMaterial.swift` -- how a surface answers a
// light: its relief, and how sharply it responds.
//
// WHY THIS IS ONE STRUCT AND NOT SIX FIELDS ON `SceneLayer`. Every value
// here is read at the same moment, by the same shader, about the same
// surface, and every one has to travel the same three roads: into
// `SceneLayerUniforms`, into the JSON, and into the `.umesh` chunk. Six
// loose fields is six chances for one to miss a road -- which in this
// project has a name and a scar, because `meshAnimationDeform` and the
// `.meshDeform` keyframes travel together for exactly that reason.
//
// THE DEFAULT IS NOT "A SENSIBLE STARTING POINT". `flat()` is the surface
// Scene has always drawn: no map, no wrap, no contrast. That is a hard
// requirement rather than a taste -- a project made before any of this
// existed has to render bit for bit as it did, and it will, because `flat`
// leaves `materialFlags` clear and the shader never enters the branch.
//
// NOT PORTED: `title` and the SF Symbol names on `SceneParallaxMode`, and
// the `Codable`/`Identifiable` conformances. Labels and icons are shell,
// and the file format is `Serialization/`'s business, not the model's.

#include <cstdint>
#include <optional>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Model/Scene/SceneLight.h"

namespace umeshcore {

// Which parallax march a surface runs.
//
// WHY THE SILHOUETTE IS TWO CASES AND NOT A TOGGLE. A plain occlusion
// march can only move texels around INSIDE the card, so a brick wall gets
// deep relief with a suspiciously straight edge. Making the outline follow
// the height field means discarding the fragments the ray misses, and
// there are two honest answers to "misses where":
//   - kSilhouetteClip discards inside the card's own bounds, so the
//     outline can only bite INWARDS. One comparison, and it can never make
//     a layer overlap something it did not overlap before.
//   - kSilhouetteShell first grows the quad by the depth of the volume, so
//     the relief can stand PROUD of where the card's edge used to be --
//     the reading people mean by "silhouette POM". It draws more pixels,
//     and it lets a layer paint outside the rectangle its own gizmo shows.
// A single toggle would have to choose one of those silently.
enum class SceneParallaxMode { kOff, kOcclusion, kSilhouetteClip, kSilhouetteShell };

// True when fragments whose ray found no surface are thrown away.
inline bool parallaxClips(SceneParallaxMode mode) {
    return mode == SceneParallaxMode::kSilhouetteClip ||
           mode == SceneParallaxMode::kSilhouetteShell;
}
// True when the drawn quad is grown so the relief can overhang the card.
inline bool parallaxExpandsCard(SceneParallaxMode mode) {
    return mode == SceneParallaxMode::kSilhouetteShell;
}

struct SceneMaterial {
    // The normal map paired with this surface's artwork, if it has one. A
    // SEPARATE ASSET, not a second channel of the sprite's own: a
    // different image with different dimensions in general, it must not be
    // atlased, and it is authored on its own schedule.
    std::optional<Uuid> normalMapAssetID;

    // How much of the map's relief to use: 0 is flat, 1 is as painted. It
    // scales the map's x and y against a fixed z -- scaling all three
    // would do nothing at all, because the vector is normalised straight
    // after. Above 1 is allowed and useful: a map baked from a gentle
    // height field is often flatter than the artist wants.
    float normalStrength = 1.0f;

    // How far the light wraps around the relief, in [0, 1]. NOT A BLUR:
    // it moves the terminator and compresses the gradient, reading only
    // this pixel's own normal. A mip bias on the normal-map sample would
    // average neighbours, which would soften the ARTWORK's relief rather
    // than the LIGHT's falloff across it.
    float smoothness = 0.0f;

    // How sharply the surface separates lit from unlit. NOT A FRAMEBUFFER
    // FILTER: applied to the shaped lambert and nowhere else, pivoted
    // about 0.5 and clamped back into [0, 1].
    float contrast = 0.0f;

    // Which light channels this surface casts a shadow on. Empty casts
    // nothing, which is what every project that predates shadows wants and
    // what every new layer starts as -- shadows cost per fragment, per
    // light, per occluder.
    SceneLightMask shadowCastMask;
    // Which light channels' shadows may darken this surface.
    SceneLightMask shadowedMask;

    // OFF BY DEFAULT, AND THE DEFAULT IS A PROMISE: `kOff` leaves every
    // parallax bit of `materialFlags` clear and the shader never enters
    // the branch, so a project made before any of this renders bit for bit
    // as it did.
    SceneParallaxMode parallaxMode = SceneParallaxMode::kOff;

    // The height field this surface is displaced by.
    //
    // NULLOPT IS NOT "NONE". It means "fall back to the normal map's
    // alpha", which is where a great many baking tools already put the
    // height they generated the normals from. When there is no normal map
    // either, nullopt really is none and the march is skipped.
    std::optional<Uuid> heightMapAssetID;

    // How deep the volume under the surface is, in UV UNITS and not world
    // units: the march happens in tangent space against a texture, so the
    // only length it can express is a fraction of the artwork. Small
    // numbers do the work -- 0.05 is a pronounced brick, 0.2 is a cliff.
    float parallaxDepth = 0.05f;

    // ONE CONTROL AND NOT TWO. The march wants a minimum and a maximum
    // step count and interpolates between them by view angle; an artist
    // wants to know whether this surface is worth the milliseconds.
    float parallaxQuality = 0.5f;

    // True when the map stores DEPTH rather than HEIGHT. White is high is
    // what a displacement bake writes; a depth generator writes the
    // opposite, and inverting it here beats asking an artist to run a
    // levels pass over every file they own.
    bool heightInverted = false;

    // Whether the relief shadows itself -- a second march, per light, from
    // the hit point towards the lamp. The expensive half of the feature,
    // so it is off until asked.
    bool parallaxSelfShadow = false;

    // How much the depth of the hit darkens the surface, in [0, 1]. Cheap
    // ambient occlusion, applied to the ALBEDO before the lights because
    // it stands in for the light that never reaches the bottom of a crack.
    float parallaxOcclusionStrength = 0.0f;

    bool operator==(const SceneMaterial&) const = default;

    // The surface Scene drew before any of this existed.
    static SceneMaterial flat() { return SceneMaterial{}; }

    // True when the shader can skip the whole material path. READ BY THE
    // RENDERER TO SET THE FLAG, so "renders exactly as before" is decided
    // in one place rather than re-derived at each call site that builds a
    // `SceneLayerUniforms`.
    bool isFlat() const { return *this == flat(); }

    // Clamped into the ranges the shader assumes, on the way in from a
    // file. The shader's branches are `smoothness <= 0` and
    // `contrast <= 0`; a negative value out of a hand-edited or truncated
    // file would take the slow path and compute a wrap with a NEGATIVE
    // width, which pushes the terminator the wrong way and looks like an
    // inverted light. Same reasoning for the march: a negative depth walks
    // the ray BACKWARDS out of the surface, which does not look like a bad
    // number -- it looks like the artwork sliding off its own card -- and
    // a quality of NaN makes the step count NaN, so the loop runs zero
    // times and the feature silently disables itself on one layer.
    SceneMaterial sanitized() const;
};

} // namespace umeshcore
