#pragma once

// Port of `Render/SceneLighting.swift` -- the ONE place a Scene decides how
// much light reaches a point -- plus the falloff curve it evaluates, which
// lives in `Data/Scene/SceneLight.swift` but is pure math.
//
// WHERE LIGHTING IS RESOLVED, AND WHY IT IS NOT WHERE YOU WOULD GUESS. Per
// LAYER, in SCREEN space, against the layer's own plane. The obvious place
// is the card's texture -- multiply a sprite by a light map -- and here it
// would be wrong in a way that shows: a Scene layer can be a rig instance
// whose sprites are mesh-deformed, so a texel's position in the texture
// says very little about where it ends up in the world, and a deformed arm
// would carry the lighting of where the arm was drawn flat. A Scene layer
// IS flat, though, by the model's founding invariant, so every pixel it
// draws lies in one known plane: intersect the ray through a pixel with
// that plane and you have the exact world point, whatever the layer
// contains. One lattice per layer rather than one per sprite, and a rig
// with forty deformed sprites costs what a plate costs.
//
// WHAT IS INTERPOLATED. Shading every pixel exactly would mean a bracketed
// Newton solve per light per pixel, so the field is evaluated on a lattice
// and interpolated bilinearly -- and the lattice spacing comes from the
// light's FADE BAND, not from its radius and not from the card. The band
// is where the curvature is; everywhere else the field is flat or zero and
// interpolation is exact. The Swift harness measured the error as
// `0.9 / (cells per band)^2`, which is where the two density constants
// below come from: 20 cells holds it to 0.79/255 (under a quantisation
// step) and 10 to 3.09/255.
//
// The harness itself (`Editor/verify_scene_lighting.py`) does not exist in
// this repository -- see CLAUDE.md -- so those numbers cannot be re-run
// from here. The tests assert the properties they were measuring.
//
// WHAT IS NOT PORTED, and why:
//   - `LightField::composite(from:into:)`. It reads a CoreGraphics bitmap
//     and writes another one: it IS the CPU rasterizer this phase
//     deliberately does not carry across (CLAUDE.md, Phase 4 -- the target
//     is the GPU path, and no Windows equivalent of the CoreGraphics
//     rasterizer exists or should be built). Its ARITHMETIC is not lost,
//     because it is what the fragment shader does, and it belongs with the
//     rest of the shader math in Phase 4's last piece:
//         lit = clamp(src * factor + additive * srcAlpha, 0, srcAlpha)
//         dst = lit + dst * (1 - srcAlpha)
//     The additive term is scaled by alpha because it is added to the
//     SURFACE, which only exists where there is alpha; added flat, an
//     additive light lights up the transparent margin of every sprite and
//     surrounds its subject with a rectangle of glow.
//   - `SceneLight` itself. Phase 5 owns the model. What the math reads off
//     a light is `SceneLightParams` below -- the injection point, per the
//     port's "inject what's needed" rule.

#include <cstdint>
#include <functional>
#include <optional>
#include <vector>

#include "umeshcore/Math/Vec.h"
#include "umeshcore/Render/SceneGPUTypes.h"

namespace umeshcore {

// ---- The falloff curve -------------------------------------------------

// One stop of a falloff curve: a position across the fade band, the value
// there, and the two Bezier handles.
//
// The same shape a `Keyframe` has, minus the frame -- because it IS a
// keyframe, evaluated by the editor's own `AnimationCurve` on a normalised
// axis instead of on frames. That is the point: intensity, radius and
// falloff are all eased by one curve engine, so a falloff can be dragged
// in the Graph editor beside a translate track and behave identically.
// Lighting has no Bezier code of its own.
struct LightFalloffStop {
    float position = 0.0f;
    float value = 0.0f;
    std::optional<Vec2> inTangent;
    std::optional<Vec2> outTangent;
};

// How a light fades across its band.
//
// PINNED AT BOTH ENDS: the first stop is (0, 1) and the last is (1, 0),
// always, enforced on construction rather than clamped on read. Those two
// are what make the light continuous where the band meets full brightness
// and where it meets darkness -- a curve that ended at 0.2 would draw a
// hard circle around every lamp in the set, and an artist would report it
// as "the light has an edge" without ever suspecting the curve.
class LightFalloffCurve {
public:
    // A falloff is evaluated once per lattice point per light per frame,
    // and evaluating it exactly means a bracketed Newton solve each time.
    // Tabulated instead: the Swift harness measured the table against the
    // exact curve at 0.038/255 worst case, an eighth of a quantisation
    // step.
    static constexpr int kTableEntries = 256;

    LightFalloffCurve() : LightFalloffCurve(smoothStops()) {}
    explicit LightFalloffCurve(std::vector<LightFalloffStop> stops);

    const std::vector<LightFalloffStop>& stops() const { return stops_; }

    // Value at a normalised position across the band.
    float value(float position) const;
    std::vector<float> table(int entries = kTableEntries) const;

    // A straight fade: both control points on the chord.
    static LightFalloffCurve linear();
    // The default. FLAT tangents at both ends, which is exactly smoothstep
    // -- written out rather than left to the auto tangent, and that is not
    // stylistic: with two stops and no neighbours `AnimationCurve`'s auto
    // slope is the slope of the CHORD, so a two-stop "auto" curve is a
    // straight line, and the default would have been linear while being
    // called smooth.
    static LightFalloffCurve smooth();
    // The physical fall, sampled as stops so it stays ONE curve type
    // rather than a special case in the evaluator. Renormalised to reach 0
    // at the rim: an unrenormalised inverse square never reaches zero, so
    // the pinning would drag its last stop down anyway and put a kink
    // there. Renormalising says so out loud instead.
    static LightFalloffCurve inverseSquare();

private:
    static std::vector<LightFalloffStop> smoothStops();
    std::vector<LightFalloffStop> stops_;
};

// ---- What the math reads off a light -----------------------------------

// The math enums. Phase 5's model enums are `String`-backed for the file
// format and map onto these, and onto the GPU wire codes, by an explicit
// switch -- never a cast, because a raw value would make the wire format
// depend on declaration order (see SceneGPUTypes.h).
enum class SceneLightKind { kPoint, kSpot, kDirectional };
enum class SceneLightBlend { kNormal, kAdditive, kMultiply, kScreen };

// The switch the wire format is entitled to, in one place each.
SceneLightKindCode lightKindCode(SceneLightKind kind);
SceneLightBlendCode lightBlendCode(SceneLightBlend blend);

// Everything the lighting math reads off a `SceneLight`. Phase 5's model
// fills one of these; nothing here knows about ids, names or persistence.
struct SceneLightParams {
    SceneLightKind kind = SceneLightKind::kPoint;
    SceneLightBlend blend = SceneLightBlend::kNormal;
    // Eight channel bits, in the low byte.
    std::uint8_t mask = 0xFF;
    bool isEnabled = true;

    Vec3 world;      // position.xy + positionZ
    float azimuth = 1.57079632679489661923f;
    float elevation = 0.0f;
    float radius = 600.0f;
    float intensity = 1.0f;
    Vec3 color = Vec3(1, 1, 1);
    // 0 is a hard-edged disc, 1 fades from the centre.
    float softness = 1.0f;
    float innerAngle = 20.0f * 3.14159265358979323846f / 180.0f;
    float outerAngle = 35.0f * 3.14159265358979323846f / 180.0f;
    // How much the depth difference counts toward the distance. THE WHOLE
    // OF 2.5D: 0 makes the light flat across every layer, 1 makes it a
    // real point in space. Nothing else in the model mentions Z, which is
    // what keeps it from being a special case threaded through every
    // formula.
    float depthInfluence = 1.0f;
    // How much the surface's facing counts. 0 is flat 2D lighting, 1 is
    // true Lambert.
    float normalInfluence = 0.0f;
    bool castsShadows = false;
    LightFalloffCurve falloff;
};

// The unit vector the light points along.
Vec3 lightDirection(float azimuth, float elevation);
// Where the fade begins, in world units.
float lightInnerRadius(const SceneLightParams& light);
// How wide the gradient is, in world units -- the number the lattice
// density is chosen from, because the gradient is the only thing
// interpolation can get wrong.
float lightBandWidth(const SceneLightParams& light);
// A mask reaches another when they share a channel.
inline bool lightMaskReaches(std::uint8_t a, std::uint8_t b) { return (a & b) != 0; }

// ---- A light with everything per-frame worked out once -----------------

class PreparedLight {
public:
    SceneLightParams light;
    std::vector<float> table; // the falloff, tabulated
    Vec3 origin;
    Vec3 direction;
    float radius = 0.000001f;
    float innerRadius = 0.0f;
    float band = 0.0f;
    // Cones compared as COSINES, never as angles: acos is at its least
    // accurate exactly on the axis, which is the middle of the cone, and a
    // dot product IS the cosine -- converting it to an angle only to
    // convert back is arithmetic that can only lose.
    float cosInner = 1.0f;
    float cosOuter = -1.0f;
    Vec3 tint;

    PreparedLight() = default;
    explicit PreparedLight(const SceneLightParams& light);

    // The falloff at a normalised band position, through the table.
    float falloff(float u) const;

    // How much of this light reaches a world point, in 0...1.
    float attenuation(const Vec3& point) const;

    // N.L, shaped by the surface, then faded in by `normalInfluence`.
    //
    // THE ORDER IS THE DESIGN. `smoothness` and `contrast` belong to the
    // SURFACE and act on the directional response; `normalInfluence`
    // belongs to the LIGHT and decides how much of that response is used
    // at all. Keeping the influence outermost means a light the artist
    // deliberately set to flat 2D cannot be resurrected by a sprite's
    // material -- the one thing an artist would never forgive, because it
    // would make a lighting decision unmakeable.
    float lambert(
        const Vec3& point, const Vec3& normal, float smoothness = 0.0f,
        float contrast = 0.0f) const;

    // The RGB arriving at a point, before the blend routes it.
    Vec3 emission(const Vec3& point, const Vec3& normal) const;
};

// ---- The lighting of a scene -------------------------------------------

// The light that is there when no light is pointed at something: colour
// times intensity, clamped at zero. Full white at strength 1 means a scene
// with no lights renders EXACTLY as it did before lighting existed.
struct SceneAmbient {
    Vec3 color = Vec3(1, 1, 1);
    float intensity = 1.0f;

    Vec3 rgb() const { return color * (intensity > 0.0f ? intensity : 0.0f); }
    static SceneAmbient neutral() { return SceneAmbient{}; }
};

class SceneLighting {
public:
    // In the artist's LIST order, because `multiply` and `screen` do not
    // commute with the rest -- and a set's iteration order would make a
    // render differ between launches of the same project.
    std::vector<PreparedLight> lights;
    SceneAmbient ambient;

    SceneLighting() = default;
    SceneLighting(const std::vector<SceneLightParams>& lights, const SceneAmbient& ambient);

    // Nothing to do: no lights, and an ambient that multiplies by exactly
    // one. THE LOAD-BEARING DEFAULT -- a Scene composed before lighting
    // existed hits this, the whole lighting path is skipped, and the frame
    // is the one the renderer produced before. Not approximately:
    // identically, because no arithmetic runs on it at all.
    bool isIdentity() const;

    // The lights that can reach a surface on these channels.
    std::vector<PreparedLight> lightsReaching(std::uint8_t mask) const;

    // How a surface turns N.L into a lit fraction: the whole of Smoothness
    // and Contrast, in one function the shaders transcribe verbatim.
    //
    // SMOOTHNESS IS A WRAP, and specifically not a blur. It moves the
    // terminator from `N.L = 0` to `N.L = -s` and compresses the gradient,
    // so light wraps around the relief and transitions soften
    // monotonically; `s = 1` is full half-Lambert. Crucially it reads NO
    // TEXEL but this fragment's own -- that is the test for "is this
    // secretly a blur?", and a mip-LOD bias on the normal-map sample fails
    // it outright: it averages neighbours, so it would soften the
    // ARTWORK's relief rather than the LIGHT's falloff across it. Those
    // two look alike in a still and behave nothing alike once a light
    // moves.
    //
    // CONTRAST GOES HERE and not on the accumulated factor. On the factor
    // it would scale the ambient and act on a sprite with no lights
    // reaching it at all -- a brightness/contrast filter wearing a
    // lighting control's name. On the attenuation it would reshape the
    // light's radius and cone, which belong to the light, not the surface.
    // On the shaped lambert it can only redistribute the DIRECTIONAL
    // response, and the clamp holds it inside [0, 1], the range Lambert
    // already occupied. The albedo is untouched by construction: contrast
    // never multiplies a colour.
    //
    // BOTH NEUTRAL VALUES TAKE A BRANCH, FOR TWO DIFFERENT REASONS. They
    // look like one rule and are not, and treating them as one is how the
    // Swift harness for this first got written wrong:
    //   - `smoothness == 0` changes NO BIT either way. `(d + 0) / (1 + 0)`
    //     is exactly `d` in IEEE 754. That branch is there to skip work.
    //   - `contrast == 0` is LOAD-BEARING. `0.5 + (x - 0.5) * 1.0` is NOT
    //     exactly `x` in float32 -- 3327 of 20 001 samples moved, by up to
    //     1.5e-08. Without the branch, every lit pixel of every existing
    //     project shifts by an amount nobody could see or report.
    static float shapedLambert(float ndotl, float smoothness, float contrast);

    struct Shaded {
        Vec3 factor;    // multiplicative
        Vec3 additive;  // added after the multiply
    };

    // The multiplicative factor and the additive term at one world point.
    static Shaded shade(
        const std::vector<PreparedLight>& lights, const SceneAmbient& ambient, const Vec3& point,
        const Vec3& normal);

    // The smallest fade band among these lights, in world units. Absent
    // when none of them has a gradient at all -- a set of hard-edged
    // discs, where a lattice has nothing to resolve and the density is
    // bounded by the cap.
    static std::optional<float> narrowestBand(const std::vector<PreparedLight>& lights);

    // ---- Density ----
    //
    // Lattice cells across the narrowest fade band. Both measured: 20
    // cells holds the error to 0.79/255, under a quantisation step, and 10
    // to 3.09/255. The interactive path takes the coarser one -- it is the
    // picture the artist is orbiting through, replaced sixty times a
    // second.
    //
    // The measurement had to be taken OFF the lattice to mean anything: a
    // uniform probe grid lands exactly on the lattice nodes whenever its
    // spacing divides the cell and reads an error of zero, which is how
    // the first version of this constant came out four cells too coarse
    // while its harness said it was exact.
    static constexpr float kCellsPerBandFinal = 20.0f;
    static constexpr float kCellsPerBandInteractive = 10.0f;

    // A cell narrower than this buys nothing: it is already below what a
    // gradient can show across a couple of pixels. It is also the limit of
    // the guarantee above -- a light whose gradient is only a few dozen
    // pixels wide, spread over a full-frame layer, cannot get its 20
    // cells. The lever that would remove the caveat is to bound the
    // lattice by the LIGHT's screen extent instead of the LAYER's, named
    // here rather than left as a surprise.
    static constexpr float kMinimumCellPixels = 2.0f;
    // And wider than this a lattice stops resolving anything at all,
    // however broad the band -- so a light with no gradient still gets a
    // usable field.
    static constexpr float kMaximumCellPixels = 96.0f;
    // A hard ceiling on either side, so a pathological light cannot make
    // one frame cost a thousand.
    static constexpr int kMaximumLatticeSide = 384;
};

// ---- A layer's lighting, sampled over the screen it covers -------------

// Screen space, because that is where the pixels being modulated are, and
// because a layer's extent on screen is bounded by the frame however large
// its artwork is -- a 4096-pixel backdrop seen small costs what its screen
// size costs, not what its texture does.
class LightField {
public:
    // The rectangle of view pixels this field covers, y DOWN -- the
    // projection's own convention, so no flip lives in here.
    float originX = 0.0f;
    float originY = 0.0f;
    float width = 1.0f;
    float height = 1.0f;
    // Lattice samples, row-major, (columns + 1) * (rows + 1) of them.
    std::vector<Vec3> factors;
    std::vector<Vec3> additives;
    int columns = 1;
    int rows = 1;

    struct ScreenBounds {
        float minX, minY, maxX, maxY;
    };

    // `worldAt` intersects the ray through a view pixel with the layer's
    // own plane. It is a callable rather than a projection plus a plane
    // because the caller already holds both, and passing them separately
    // is an invitation to build the plane twice.
    //
    // Absent when no light can reach this surface at all -- the caller
    // then draws the layer the way it always did, with no scratch buffer
    // and no modulation.
    static std::optional<LightField> build(
        const SceneLighting& lighting, std::uint8_t mask, const Vec3& normal,
        const ScreenBounds& screenBounds, float cellsPerBand, float pixelsPerWorldUnit,
        const std::function<std::optional<Vec3>(float, float)>& worldAt);

    // Non-finite out, zero in.
    //
    // Sanitised ONCE PER LATTICE POINT rather than once per pixel, which
    // is where it costs nothing. It is not paranoia: on the Swift side the
    // bytes a pixel is written back as come from `UInt8(_:)`, which TRAPS
    // on a NaN, so a single infinity surviving out of a corrupt project
    // file would not produce a wrong colour -- it would take the editor
    // down while rendering a frame.
    static Vec3 finite(const Vec3& value);

    // Bilinear sample at a view pixel.
    SceneLighting::Shaded sample(float x, float y) const;
};

} // namespace umeshcore
