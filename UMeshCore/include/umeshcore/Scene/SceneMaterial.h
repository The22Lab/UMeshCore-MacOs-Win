#pragma once

// 1:1 port of `Data/Scene/SceneMaterial.swift` -- how a surface answers a
// light: its relief, how far the light wraps around it, how sharply it
// separates lit from unlit, and which march (if any) displaces it.
//
// ## Why this is one struct and not a dozen fields on SceneLayer
//
// Every value here is read at the same moment, by the same shader, about
// the same surface, and every one has to travel the same three roads: into
// `SceneLayerUniforms`, into the JSON, and into the `.umesh` chunk. Loose
// fields is one chance per field for one of them to miss a road -- and in
// this port that failure has a name and a scar, because
// `meshAnimationDeform` and the `.meshDeform` keyframes travel together
// for exactly this reason (see the ANIM chunk's version 2 note in
// `Serialization/UMeshBinaryFormat.h`).
//
// ## The default is a promise, not a starting point
//
// `sceneMaterialFlat()` is the surface Scene drew before any of this
// existed: no map, no wrap, no contrast, no march. A project made before
// the feature has to render BIT FOR BIT as it did, not nearly -- and it
// does, because a flat material leaves `materialFlags` clear and the
// shader never enters the branch at all. `SceneGPUTypes.h`'s
// `kSceneHasNormalMap` comment carries the measurement that forced this to
// be a flag rather than a test on `normalStrength`: 826 of 4000 random
// tilted cards came back from the "neutral texel" round trip changed, by
// up to 1.2e-07, which nobody would report and which a test scene facing
// the camera would never catch.
//
// Nothing here is a renderer: this is the MODEL the renderer reads. The
// arithmetic already lives in `Render/SceneShaderMath.h`, which is the
// normative reference for both backends.

#include <algorithm>
#include <cmath>
#include <optional>
#include <string>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Scene/SceneLightMask.h"

namespace umeshcore {

// Which parallax march a surface runs.
//
// The silhouette is TWO cases and not a toggle, and the Swift header is
// emphatic about why. A plain occlusion march only moves texels around
// inside the card, so a brick wall gets deep relief with a suspiciously
// straight edge. Making the outline follow the height field means
// discarding fragments the ray misses, and "misses where" has two honest
// answers that look different enough that an artist has to pick:
// `Clip` bites only INWARDS, costs one comparison, and can never make a
// layer overlap something it did not overlap before; `Shell` first grows
// the quad by the depth so the relief can stand PROUD of the card's edge
// -- which is what people mean by "silhouette POM", and which draws more
// pixels and lets a layer paint outside the rectangle its own gizmo
// shows. A single toggle would have to choose one of those silently.
enum class SceneParallaxMode { Off, Occlusion, SilhouetteClip, SilhouetteShell };

// The Swift `rawValue`s, which are the file format's spelling. An explicit
// mapping rather than a cast: a cast would make the format depend on
// declaration order, the rule `SceneGPUTypes.h` states for the wire codes
// and that the whole Scene model follows.
inline const char* sceneParallaxModeName(SceneParallaxMode mode) {
    switch (mode) {
        case SceneParallaxMode::Off: return "off";
        case SceneParallaxMode::Occlusion: return "occlusion";
        case SceneParallaxMode::SilhouetteClip: return "silhouetteClip";
        case SceneParallaxMode::SilhouetteShell: return "silhouetteShell";
    }
    return "off";
}

inline std::optional<SceneParallaxMode> sceneParallaxModeFromName(const std::string& name) {
    if (name == "off") return SceneParallaxMode::Off;
    if (name == "occlusion") return SceneParallaxMode::Occlusion;
    if (name == "silhouetteClip") return SceneParallaxMode::SilhouetteClip;
    if (name == "silhouetteShell") return SceneParallaxMode::SilhouetteShell;
    return std::nullopt;
}

// True when fragments whose ray found no surface are thrown away.
inline bool sceneParallaxClips(SceneParallaxMode mode) {
    return mode == SceneParallaxMode::SilhouetteClip ||
           mode == SceneParallaxMode::SilhouetteShell;
}
// True when the drawn quad is grown so the relief can overhang the card.
inline bool sceneParallaxExpandsCard(SceneParallaxMode mode) {
    return mode == SceneParallaxMode::SilhouetteShell;
}

struct SceneMaterial {
    // The normal map paired with this surface's artwork, if it has one. A
    // SEPARATE ASSET, not a second channel of the sprite's own: different
    // dimensions in general, must not be atlased, authored and
    // re-exported on its own schedule.
    std::optional<Uuid> normalMapAssetId;

    // How much of the map's relief to use: 0 flat, 1 as painted. It scales
    // the map's x and y against a FIXED z, which is what tilts the surface
    // more or less steeply -- scaling all three would do nothing at all,
    // since the vector is normalised straight after and a uniform scale
    // cannot survive that. Above 1 is allowed and useful: a map baked from
    // a gentle height field is often flatter than the artist wants.
    float normalStrength = 1.0f;

    // How far the light wraps around the relief, in [0, 1].
    //
    // NOT A BLUR, and the distinction is the whole design. It is a wrap on
    // the lambert term -- the terminator moves from `N·L = 0` to
    // `N·L = -s` and the gradient compresses -- so it reads only this
    // pixel's own normal. As a mip bias on the normal-map sample it would
    // average neighbouring texels, which is literally a blur: it would
    // soften the ARTWORK's relief instead of the LIGHT's falloff across
    // it. The two look alike in a still and behave nothing alike the
    // moment a light moves.
    float smoothness = 0.0f;

    // How sharply the surface separates lit from unlit.
    //
    // NOT A FRAMEBUFFER FILTER. Applied to the shaped lambert term and
    // nowhere else, pivoted about 0.5 and clamped back into [0, 1]. On the
    // accumulated factor it would scale the ambient and act on a sprite
    // with no lights on it at all -- a brightness/contrast adjustment
    // wearing a lighting control's name. On the attenuation it would
    // reshape the light's radius and cone, which belong to the light and
    // not to the surface. On the lambert it can only redistribute the
    // DIRECTIONAL response, and the clamp keeps it inside the range
    // Lambert already occupied.
    float contrast = 0.0f;

    // Which light channels this surface casts a shadow on. EMPTY casts
    // nothing, which is what every project predating shadows wants and
    // what every new layer starts as: shadows cost per fragment, per
    // light, per occluder, and a set where everything casts by default is
    // slow before the artist has asked for anything.
    SceneLightMask shadowCastMask;
    // Which light channels' shadows may darken this surface.
    SceneLightMask shadowedMask;

    // ---- Parallax occlusion ----
    //
    // A normal map lies about the light and tells the truth about the
    // geometry: the surface is still flat, so orbiting the camera slides
    // nothing. The march is what makes the relief MOVE -- it walks the
    // view ray through a height field and displaces the UV, so a bump
    // occludes what is behind it. OFF BY DEFAULT, and the default is the
    // same promise `normalMapAssetId` carries, by the same mechanism.
    SceneParallaxMode parallaxMode = SceneParallaxMode::Off;

    // The height field this surface is displaced by.
    //
    // NULLOPT IS NOT "NONE". It means "fall back to the normal map's
    // alpha", which is where a great many baking tools already put the
    // height they generated the normals from -- so the commonest pair of
    // files needs no second pick in a menu. With no normal map either,
    // nullopt really is none and the march is skipped. A SEPARATE ASSET
    // and never atlased: the march reads texels far from the fragment's
    // own, so a neighbour packed edge to edge on an atlas page would be
    // walked into directly rather than merely bled from.
    std::optional<Uuid> heightMapAssetId;

    // How deep the volume under the surface is, in UV UNITS and not world
    // ones: the march happens in tangent space against a texture, so the
    // only length it can express is a fraction of the artwork, and a card
    // scaled 3x wide keeps the same relief rather than stretching it --
    // the same approximation the scale-free tangent frame already makes.
    // Small numbers do the work: 0.05 is a pronounced brick, 0.2 a cliff.
    float parallaxDepth = 0.05f;

    // ONE knob the renderer spends on step counts, not two. The march
    // wants a minimum and a maximum and interpolates by view angle; an
    // artist wants to know whether this surface is worth the milliseconds.
    // Exposing both would be asking them to tune a ratio whose only wrong
    // answers are the ones where min exceeds max.
    float parallaxQuality = 0.5f;

    // True when the map stores DEPTH rather than HEIGHT. White-is-high is
    // what a displacement bake writes; a depth generator writes the
    // opposite, and inverting it here beats asking an artist to run a
    // levels pass over every file they own.
    bool heightInverted = false;

    // Whether the relief shadows itself: a second march, per light, from
    // the hit point towards the lamp. It is what turns a displaced texture
    // into something that reads as volume, and it is the expensive half of
    // the feature, so it is off until asked.
    bool parallaxSelfShadow = false;

    // How much the depth of the hit darkens the surface, in [0, 1]. A
    // cheap ambient occlusion -- the march already knows how far down the
    // ray landed. It applies to the ALBEDO, before the lights, because it
    // stands in for the light that never reaches the bottom of a crack;
    // on the lit result it would also darken the highlights sitting on
    // the ridges.
    float parallaxOcclusionStrength = 0.0f;

    bool operator==(const SceneMaterial&) const = default;
};

// The surface Scene drew before any of this existed.
inline SceneMaterial sceneMaterialFlat() { return SceneMaterial{}; }

// True when the shader can skip the whole material path. READ BY THE
// RENDERER TO SET THE FLAG, so "renders exactly as before" is decided in
// one place rather than re-derived at each site that builds a
// `SceneLayerUniforms`.
inline bool isFlat(const SceneMaterial& material) { return material == SceneMaterial{}; }

// Clamped into the ranges the shader assumes, on the way in from a file.
//
// The shader's branches are `smoothness <= 0` and `contrast <= 0`, so a
// negative value out of a hand-edited or truncated file takes the SLOW
// path and computes a wrap with a negative width -- which pushes the
// terminator the wrong way and looks like an inverted light, not like a
// bad number. The march's numbers get the same treatment for the same
// reason: a negative depth walks the ray BACKWARDS out of the surface,
// which reads as the artwork sliding off its own card, and a quality of
// NaN makes the step count NaN so the loop runs zero times -- silently
// disabling the feature on one layer and nowhere else.
inline SceneMaterial sanitized(const SceneMaterial& material) {
    const auto clampFinite = [](float value, float fallback, float lo, float hi) {
        const float v = std::isfinite(value) ? value : fallback;
        return std::min(std::max(v, lo), hi);
    };
    SceneMaterial out = material;
    out.normalStrength = clampFinite(material.normalStrength, 1.0f, 0.0f, 8.0f);
    out.smoothness = clampFinite(material.smoothness, 0.0f, 0.0f, 1.0f);
    out.contrast = clampFinite(material.contrast, 0.0f, 0.0f, 4.0f);
    out.parallaxDepth = clampFinite(material.parallaxDepth, 0.05f, 0.0f, 0.5f);
    out.parallaxQuality = clampFinite(material.parallaxQuality, 0.5f, 0.0f, 1.0f);
    out.parallaxOcclusionStrength =
        clampFinite(material.parallaxOcclusionStrength, 0.0f, 0.0f, 1.0f);
    return out;
}

} // namespace umeshcore
