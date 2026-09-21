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
        return out
    }
}
