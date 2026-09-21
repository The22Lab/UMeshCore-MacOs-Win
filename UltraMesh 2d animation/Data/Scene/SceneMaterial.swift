import Foundation
import simd

/// How a surface answers a light: its relief, and how sharply it responds.
///
/// ## Why this is one struct and not six fields on `SceneLayer`
///
/// Every value here is read at the same moment, by the same shader, about the
/// same surface, and every one of them has to travel the same three roads:
/// into `SceneLayerUniforms`, into the JSON, and into the `.umesh` chunk. Six
/// loose fields is six chances for one of them to miss a road -- which in this
/// project has a name and a scar, because `meshAnimationDeform` and the
/// `.meshDeform` keyframes travel together for exactly this reason.
///
/// ## The default is not "a sensible starting point"
///
/// `SceneMaterial.flat` is the surface Scene has always drawn: no map, no
/// wrap, no contrast. That is a HARD requirement rather than a taste --
/// a project made before any of this existed has to render bit for bit as it
/// did, and it will, because `flat` leaves `materialFlags` clear and the
/// shader never enters the branch at all.
struct SceneMaterial: Equatable {
    /// The normal map paired with this surface's artwork, if it has one.
    ///
    /// A SEPARATE ASSET, not a second channel of the sprite's own. It is a
    /// different image with different dimensions in general, it must not be
    /// atlased, and it is authored and re-exported on its own schedule.
    var normalMapAssetID: UUID?

    /// How much of the map's relief to use: 0 is flat, 1 is as painted.
    ///
    /// It scales the map's x and y against a fixed z, which is what tilts the
    /// surface more or less steeply. Scaling all three would do nothing at
    /// all -- the vector is normalised straight after, and a uniform scale
    /// cannot survive that.
    ///
    /// Above 1 is allowed and is useful: a map baked from a gentle height
    /// field is often flatter than the artist wants, and exaggerating it here
    /// beats re-baking it.
    var normalStrength: Float = 1

    /// How far the light wraps around the relief, in [0, 1].
    ///
    /// NOT A BLUR, and the distinction is the whole design. It is a wrap on
    /// the lambert term -- the terminator moves from `N·L = 0` to `N·L = -s`
    /// and the gradient compresses -- so it reads only this pixel's own
    /// normal. Implementing it as a mip bias on the normal-map sample would
    /// average neighbouring texels, which is literally a blur and is the one
    /// thing this control must not be: it would soften the ARTWORK's relief
    /// rather than the LIGHT's falloff across it, and the two look similar in
    /// a still and behave nothing alike when a light moves.
    var smoothness: Float = 0

    /// How sharply the surface separates lit from unlit.
    ///
    /// NOT A FRAMEBUFFER FILTER. It is applied to the shaped lambert term and
    /// nowhere else, pivoted about 0.5 and clamped back into [0, 1]. Put on
    /// the accumulated `factor` instead it would scale the ambient and act on
    /// a sprite with no lights on it at all, which is a brightness/contrast
    /// adjustment wearing a lighting control's name; put on the attenuation it
    /// would reshape the light's radius and cone, which belong to the light
    /// and not to the surface. On the lambert it can only redistribute the
    /// DIRECTIONAL response, and the clamp keeps it inside the range Lambert
    /// already occupied, so no pixel can reach anywhere it could not before.
    var contrast: Float = 0

    /// Which light channels this surface casts a shadow on.
    ///
    /// Empty casts nothing, which is what every project that predates shadows
    /// wants and what every new layer starts as: shadows cost per fragment,
    /// per light, per occluder, and a set where everything casts by default is
    /// a set that is slow before the artist has asked for anything.
    var shadowCastMask: SceneLightMask = []

    /// Which light channels' shadows may darken this surface.
    var shadowedMask: SceneLightMask = []

    // ── Parallax occlusion ──────────────────────────────────────────────
    //
    // A normal map lies about the light and tells the truth about the
    // geometry: the surface is still flat, so orbiting the camera slides
    // nothing. The parallax march is what makes the relief MOVE -- it walks
    // the view ray through a height field and displaces the UV, so a bump
    // occludes what is behind it and the whole surface has depth the camera
    // can see around.
    //
    // OFF BY DEFAULT, AND THE DEFAULT IS A PROMISE, not a taste. `.off` leaves
    // every parallax bit of `materialFlags` clear and the shader never enters
    // the branch, so a project made before any of this renders bit for bit as
    // it did -- the same guarantee `normalMapAssetID` already carries, for the
    // same reason and by the same mechanism.

    /// Which march this surface runs, if any.
    var parallaxMode: SceneParallaxMode = .off

    /// The height field this surface is displaced by.
    ///
    /// NIL IS NOT "NONE". Nil means "fall back to the normal map's alpha",
    /// which is where a great many baking tools already put the height they
    /// used to generate the normals -- so the commonest pair of files needs no
    /// second pick in a menu. When there is no normal map either, nil really is
    /// none and the march is skipped.
    ///
    /// A SEPARATE ASSET, not a channel of the sprite's own artwork, and never
    /// atlased: the march reads texels far from the fragment's own, so a
    /// neighbour packed edge to edge on an atlas page would be walked into
    /// directly rather than merely bled from.
    var heightMapAssetID: UUID?

    /// How deep the volume under the surface is, in UV units.
    ///
    /// UV AND NOT WORLD UNITS. The march happens in tangent space against a
    /// texture, so the only length it can express is a fraction of the
    /// artwork, and a card scaled 3x wide keeps the same relief rather than
    /// stretching it -- the same approximation the scale-free tangent frame
    /// already makes for normal maps.
    ///
    /// Small numbers do the work: 0.05 is a pronounced brick, 0.2 is a cliff.
    /// Above 0.5 the silhouette shell would have to be wider than the card.
    var parallaxDepth: Float = 0.05

    /// One knob, 0 to 1, that the renderer spends on step counts.
    ///
    /// ONE CONTROL AND NOT TWO. The march wants a minimum and a maximum step
    /// count and interpolates between them by view angle; an artist wants to
    /// know whether this surface is worth the milliseconds. Exposing both
    /// numbers would be asking them to tune a ratio whose only wrong answers
    /// are the ones where min exceeds max.
    var parallaxQuality: Float = 0.5

    /// True when the map stores DEPTH rather than HEIGHT.
    ///
    /// White is high is the convention this project reads, because it is what
    /// a displacement bake writes. A depth generator writes the opposite --
    /// near is bright -- and inverting it here beats asking an artist to run a
    /// levels pass on every file they own.
    var heightInverted: Bool = false

    /// Whether the relief shadows itself.
    ///
    /// A second march, per light, from the hit point towards the lamp. It is
    /// what turns a displaced texture into something that reads as volume --
    /// and it is the expensive half of this feature, so it is off until asked.
    var parallaxSelfShadow: Bool = false

    /// How much the depth of the hit darkens the surface, in [0, 1].
    ///
    /// A cheap ambient occlusion: the march already knows how far down the
    /// ray landed, so the crevices can be darkened for the cost of one lerp.
    /// It applies to the ALBEDO, before the lights, because it stands in for
    /// the light that never reaches the bottom of a crack -- put on the lit
    /// result it would also darken the highlights sitting on the ridges.
    var parallaxOcclusionStrength: Float = 0

    /// The surface Scene drew before any of this existed.
    static let flat = SceneMaterial()

    /// True when the shader can skip the whole material path.
    ///
    /// READ BY THE RENDERER TO SET THE FLAG, so that "renders exactly as
    /// before" is decided in one place rather than re-derived at each of the
    /// two call sites that build a `SceneLayerUniforms`.
    var isFlat: Bool { self == Self.flat }

    /// Clamped into the ranges the shader assumes, on the way in from a file.
    ///
    /// The shader's branches are `smoothness <= 0` and `contrast <= 0`; a
    /// negative value from a hand-edited or truncated file would take the slow
    /// path and compute a wrap with a negative width, which pushes the
    /// terminator the wrong way and looks like an inverted light.
    var sanitized: SceneMaterial {
        var out = self
        out.normalStrength = min(max(normalStrength.isFinite ? normalStrength : 1, 0), 8)
        out.smoothness = min(max(smoothness.isFinite ? smoothness : 0, 0), 1)
        out.contrast = min(max(contrast.isFinite ? contrast : 0, 0), 4)
        // THE SAME REASONING, FOR THE SAME REASON. The march's loop bound and
        // its step size both come from these, so a negative depth out of a
        // hand-edited file walks the ray BACKWARDS out of the surface -- which
        // does not look like a bad number, it looks like the artwork sliding
        // off its own card. A quality of NaN makes the step count NaN and the
        // loop runs zero times, which silently disables the feature on one
        // layer and nowhere else.
        out.parallaxDepth = min(max(parallaxDepth.isFinite ? parallaxDepth : 0.05, 0), 0.5)
        out.parallaxQuality = min(max(parallaxQuality.isFinite ? parallaxQuality : 0.5, 0), 1)
        out.parallaxOcclusionStrength =
            min(max(parallaxOcclusionStrength.isFinite ? parallaxOcclusionStrength : 0, 0), 1)
        return out
    }
}

/// Which parallax march a surface runs.
///
/// ## Why the silhouette is two cases and not a toggle
///
/// A plain occlusion march can only move texels around INSIDE the card: the
/// quad's outline stays the rectangle it always was, so a brick wall gets deep
/// relief with a suspiciously straight edge. Making the outline follow the
/// height field means discarding the fragments the ray misses, and there are
/// two honest answers to "misses where", which look different enough that an
/// artist has to be able to pick:
///
/// - `silhouetteClip` discards inside the card's own bounds. The outline can
///   only bite INWARDS. Nothing about the geometry changes, so it costs one
///   comparison and can never make a layer overlap something it did not
///   overlap before.
/// - `silhouetteShell` first grows the quad by the depth of the volume, so the
///   relief can stand PROUD of where the card's edge used to be. That is the
///   reading people mean by "silhouette POM" -- and it draws more pixels, and
///   it lets a layer paint outside the rectangle its own gizmo shows.
///
/// A single toggle would have to choose one of those silently.
enum SceneParallaxMode: String, Codable, CaseIterable, Identifiable {
    /// The surface Scene has always drawn. No march, no branch, no cost.
    case off
    /// March and displace, clamped to the artwork. The outline stays the card.
    case occlusion
    /// March, displace, and discard where the ray leaves the volume.
    case silhouetteClip
    /// As above, on a quad grown by the depth, so the relief can overhang.
    case silhouetteShell

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:              return "Off"
        case .occlusion:        return "Occlusion"
        case .silhouetteClip:   return "Silhouette (clip)"
        case .silhouetteShell:  return "Silhouette (shell)"
        }
    }

    /// True when fragments whose ray found no surface are thrown away.
    var clips: Bool { self == .silhouetteClip || self == .silhouetteShell }

    /// True when the drawn quad is grown so the relief can overhang the card.
    var expandsCard: Bool { self == .silhouetteShell }
}
