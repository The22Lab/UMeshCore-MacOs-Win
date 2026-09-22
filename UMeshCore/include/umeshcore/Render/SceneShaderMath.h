#pragma once

// Reference implementation of `Render/SceneGPU/SceneShaders.metal` (1022 L)
// and `SceneGizmoShaders.metal` (80 L), in C++ -- Phase 4's last piece.
//
// WHY THIS EXISTS AT ALL. ROADMAP Risk #5: the same shading has to be
// written in MSL for Metal and in HLSL for DirectX, and two hand-written
// transcriptions of a hundred lines of lighting drift apart silently. The
// rule this port committed to is: author ONCE in C++, transcribe to each
// shading language, and cross-check NUMERICALLY rather than by reading
// them side by side. This file is that one authoring.
//
// AND IT REPLACES A MISSING PIECE. `SceneShaders.metal`'s own banner says
// it is "mirrored by `Editor/gpu_mirror.py` and checked against
// `Editor/lighting_mirror.py`, which stays the normative reference for
// what a lit pixel is worth", because there was no Metal toolchain in the
// container it was written in. Neither script is in this repository --
// there is no Python here at all -- so the normative reference was lost.
// This file is executable, tested, and can be diffed against a GPU capture
// on either platform, which is strictly more than a mirror nobody can run.
//
// WHAT IS A FAITHFUL TRANSCRIPTION AND WHAT IS NOT:
//   - Every formula, guard, epsilon and branch is the shader's, in the
//     shader's order. Where the MSL reads a uniform field by name
//     (`light.cones.z`), so does this, through the same POD structs in
//     `SceneGPUTypes.h` -- so a field that moves breaks both at once.
//   - Texture sampling is MODELLED, not approximated: `Texture2D::sample`
//     is bilinear with clamp-to-edge addressing on texel CENTRES, which is
//     what a Metal/Direct3D linear sampler does. That matters for one
//     specific value -- see `sampleFalloff` below, which does NOT agree
//     with the CPU path's table lookup, and the disagreement is measured
//     in the tests rather than papered over.
//   - `discard_fragment()` becomes `std::nullopt` from `cardFragment`.
//   - The vertex stages return the varyings a fragment stage consumes; the
//     rasteriser's interpolation is the caller's business, and the tests
//     feed the fragment stage directly.
//
// NOT TRANSCRIBED: the buffer/texture/sampler binding attributes, which
// are plumbing each backend spells its own way, and the `[[position]]`
// viewport transform. NO Y FLIP LIVES HERE, for the reason the shader
// states: NDC +y is up and the framebuffer's +y is down, and the viewport
// transform does that in fixed function. A shader that negates y as well
// produces a picture that is upside down and otherwise perfect -- every
// number in it right, which is how that fault survives review.

#include <cstdint>
#include <optional>
#include <vector>

#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Render/SceneGPUTypes.h"
#include "umeshcore/Render/SceneGizmoTypes.h"

namespace umeshcore {
namespace SceneShaderMath {

// A texture, sampled the way the GPU samples it: normalised coordinates,
// bilinear filtering, clamp-to-edge addressing, texel centres at
// (x + 0.5) / width. Row 0 is v = 0, which for every texture in this
// renderer is the TOP of the image -- the convention the cards' UVs, the
// background ramp and the shadow atlas all already use.
struct Texture2D {
    int width = 0;
    int height = 0;
    std::vector<Vec4> texels; // row-major, width * height

    static Texture2D solid(int width, int height, const Vec4& color);
    Vec4 texel(int x, int y) const;
    Vec4 sample(const Vec2& uv) const;
};

// ---- Vertex stages -----------------------------------------------------

// What a vertex stage hands the rasteriser.
struct VertexOut {
    Vec4 position;
    // WORLD POSITION AS A VARYING. This is the whole reason the CPU path's
    // lattice goes away: the hardware interpolates it perspective-correctly
    // for free, and the shading runs per pixel with no grid and no error to
    // bound.
    Vec3 world;
    Vec2 uv;
    // THE TANGENT FRAME AS VARYINGS, so ONE fragment stage serves both a
    // flat card and a skinned sprite. For a card these are constant and
    // could have been read from the layer uniform; they are varyings anyway
    // because a rig sprite's frame is not constant -- each bone turns its
    // own patch, and reading the layer's frame for a rig leaves the relief
    // pinned to the layer's axes, so a highlight SLIDES ACROSS the sprite
    // as an arm swings. That error is exactly zero at bind pose, which is
    // why a test scene at rest proves nothing about it.
    Vec3 tangent;
    Vec3 bitangent;
    Vec3 normal;
};

struct TangentFrame {
    Vec3 tangent;
    Vec3 bitangent;
};

// The tangent frame, built the same way on both paths.
//
// N IS NOT SKINNED, AND THAT IS NOT A SHORTCUT. A rig is a 2D rig living
// in its layer's plane: the palette folds a chain of 2D affines, every bind
// vertex has z = 0, and the matrix's z column is the plane normal itself.
// No bone can tilt a sprite out of the plane, so the plane's normal IS the
// sprite's normal -- skinning it would be arithmetic whose only possible
// effect is rounding error on a value already known.
//
// T DOES turn, because a bone rotates the artwork within the plane, and B
// is DERIVED from T rather than skinned alongside it. Deriving it is what
// keeps the frame a rotation: a sheared bone hands back a T and a B that
// are not perpendicular, and a normal rotated by those is neither unit nor
// perpendicular to anything.
TangentFrame tangentFrame(const Vec3& n, const Vec3& tRaw, float handed);

VertexOut cardVertex(
    const SceneVertexIn& vertex, const SceneFrameUniforms& frame, const SceneLayerUniforms& layer);

// The skinned path. THREE DIMENSIONS, NOT TWO: the palette folds the whole
// chain -- the bone, the sprite's posed transform and the layer's lift out
// of the card's plane -- so what comes out is a scene-world point. Writing
// `float3(skinned, 0)` would throw the lift away and lay every rig flat at
// z = 0: right in the front view, where a scene is usually composed, and
// wrong the moment the camera orbits (measured at 652 units out of place).
VertexOut skinnedVertex(
    const SceneSkinnedVertexIn& vertex, const SceneFrameUniforms& frame,
    const std::vector<Mat4>& palette, const SceneLayerUniforms& layer);

// ---- Lighting ----------------------------------------------------------

// The curve table as a row of a 2D texture, sampled with linear filtering
// and clamp-to-edge.
//
// THIS DOES NOT AGREE WITH THE CPU PATH, and the shader's own comment is
// where the assumption hides: it says the off-by-one the CPU had to spell
// out (`u * (n - 1)`, not `u * n`) "is the sampler's business, not ours".
// A linear sampler addresses texel CENTRES -- it maps u to `u * n - 0.5`
// -- so the two land on different entries of the same table.
//
// MEASURED, because "small" was the assumption worth checking. Over a
// 256-entry table the worst gap is 0.29/255 on the default `smooth`
// curve, 0.50/255 on `linear`, and 3.21/255 on `inverseSquare` at
// u = 0.025 -- three quantisation steps, in the steepest part of the
// steepest preset, which means the GPU and the CPU compositor put
// visibly different numbers in the same pixel of the same frame. The fix
// is one line on whichever side is chosen as normative: tabulate the
// curve at the sampler's positions, or address the table at texel
// centres. It is left to the shell that first ships both paths, because
// changing either side here would silently diverge from the Swift
// original -- but it is now a number in a test rather than a sentence
// nobody checked.
float sampleFalloff(const Texture2D& curves, std::uint32_t row, float u);

float lightAttenuation(
    const SceneLightUniform& light, const Vec3& point, const Texture2D& curves);

// Transcribed from `SceneLighting::shapedLambert`, which carries the full
// reasoning. Both neutral values take a branch, for two different reasons.
float shapedLambert(float ndotl, float smoothness, float contrast);

float lightLambert(
    const SceneLightUniform& light, const Vec3& point, const Vec3& normal, float smoothness,
    float contrast);

// ---- Normal mapping ----------------------------------------------------

// STRENGTH SCALES X AND Y AND LEAVES Z ALONE -- not a choice between
// equivalent options: scaling all three is a no-op, because the vector is
// normalised immediately after and a uniform scale cannot survive that.
// Tilting x and y against a fixed z is what flattens or steepens the slope.
//
// Sampled with the RAW uv, never through `layer.uvRect`: a normal map is
// not atlased and cannot safely be, because a linear sampler at a card's
// boundary picks up the neighbour -- a faint fringe on an albedo page, a
// band of surface pointing somewhere else entirely on a normal page.
Vec3 mappedNormal(
    const SceneLayerUniforms& layer, const VertexOut& in, const Vec2& uv,
    const Texture2D& normalMap);

// ---- Parallax occlusion mapping ---------------------------------------

// The height at a texel: 1 stands proud, 0 lies at the bottom of the
// volume. WHITE IS HIGH, which is what a displacement bake writes;
// `kSceneHeightInverted` serves the generators that write depth instead.
// TWO SOURCES, NEVER BOTH -- the renderer sets exactly one bit, so this
// cannot read a texture that is not there.
float heightAt(
    const SceneLayerUniforms& layer, const Vec2& uv, const Texture2D& heightMap,
    const Texture2D& normalMap);

// The view ray in the surface's own tangent space. THE V COMPONENT IS
// NEGATED where it reaches uv, and that is the one line in the feature that
// is wrong in a way a still frame cannot show: uv.y grows DOWN the image
// while the bitangent points UP it. Taken at face value the relief
// displaces the wrong way along v -- it looks like relief, it parallaxes as
// the camera moves, and it moves against the light instead of with it.
Vec3 viewTangent(const VertexOut& in, const Vec3& eye);

struct ParallaxHit {
    Vec2 uv;      // the texel to shade; every later sample uses this
    float depth;  // 0 at the top of the volume, 1 at its floor
    bool hit;     // false when the ray ran out of steps above the surface
};

// Steep march with a secant refinement on the last two samples -- the
// refinement is what makes this OCCLUSION mapping rather than plain offset
// mapping. Without it the relief steps visibly along the ray, the classic
// staircase. Steps are spent where they show (`mix(max, min, |Vz|)`), and
// the grazing guard is not optional: the offset goes as 1/Vz, so a card
// seen edge on asks for an offset that tends to infinity.
ParallaxHit parallaxMarch(
    const SceneLayerUniforms& layer, const VertexOut& in, const Vec3& viewTangentDir,
    const Texture2D& heightMap, const Texture2D& normalMap);

// How much of a light the relief hides from itself. A LIGHT BELOW THE
// SURFACE RETURNS 1, not 0: its N.L is already negative, so the shaped
// Lambert has taken the contribution away, and darkening it again is the
// same fact counted twice -- it shows up as a terminator that is a hard
// black line instead of a rolled edge.
float parallaxSelfShadow(
    const SceneLayerUniforms& layer, const Vec2& uv, float depth, const Vec3& lightTangent,
    const Texture2D& heightMap, const Texture2D& normalMap);

// ---- Shadows -----------------------------------------------------------

// One analytic test per occluder: intersect the segment from the fragment
// to the light with the occluder's plane, ask whether the hit is inside the
// quad (as a 2x2 SOLVE, because a sheared card's axes are not
// perpendicular), and read one texel of its alpha for the real silhouette.
//
// THE RAY USES THE LIGHT'S 2.5D DIRECTION, not the true one, because the
// shading already flattens z by `depthInfluence` -- a shadow cast from a
// position the rest of the shading does not believe in falls away from the
// highlight it belongs to. That also explains the depthInfluence = 0 case
// without a special case: the direction has no z, the cards' normals are
// +/-z, the denominator is zero, and nothing is occluded. A flat 2D light
// casts no shadow, which is what flat 2D means.
float shadowFactor(
    const SceneLightUniform& light, const std::vector<SceneOccluder>& occluders, const Vec3& point,
    std::uint32_t shadowedMask, const Texture2D& shadowAtlas);

// ---- Fragment ----------------------------------------------------------

// Everything the fragment stage binds, in one place so a call site reads
// like the shader's signature.
struct FragmentBindings {
    const Texture2D* atlas = nullptr;
    const Texture2D* curves = nullptr;
    const Texture2D* normalMap = nullptr;
    const Texture2D* shadowAtlas = nullptr;
    const Texture2D* heightMap = nullptr;
    const std::vector<SceneLightUniform>* lights = nullptr;
    const std::vector<SceneOccluder>* occluders = nullptr;
};

// The card fragment stage. `std::nullopt` is `discard_fragment()`.
//
// PREMULTIPLIED, AND THE ADDITIVE TERM IS SCALED BY ALPHA. The albedo has
// alpha folded into its colour, so the multiplicative factor applies as it
// is; the additive term is light ARRIVING AT A SURFACE, and a surface nine
// tenths transparent catches a tenth of it. Adding it unscaled is the one
// lighting bug that looks plausible in a still -- the sprite lights
// correctly and a faint rectangular glow appears around it, where the
// artwork is transparent and the light is not.
std::optional<Vec4> cardFragment(
    const VertexOut& in, const SceneFrameUniforms& frame, const SceneLayerUniforms& layer,
    const FragmentBindings& bindings);

// ---- The encode pass and the background --------------------------------

struct EncodeVertexOut {
    Vec4 position;
    Vec2 uv;
};

// A full-screen TRIANGLE, not a quad: one primitive, no seam down the
// diagonal where two triangles meet, and three vertices instead of four.
EncodeVertexOut encodeVertex(std::uint32_t vertexID);

Vec4 encodeFragment(const EncodeVertexOut& in, const Texture2D& source);

// uv.y = 0 is the TOP of the frame, which is row 0 of the 1x2 ramp -- the
// same convention a card's UV already uses. Taken the other way the sky
// ends up on the floor.
Vec4 backgroundFragment(const EncodeVertexOut& in, const Texture2D& ramp);

// ---- The gizmo pass ----------------------------------------------------

// THE RECENTRE-THEN-SLIDE, ON THE GPU: the offset is added in clip space
// scaled by w, which is adding it to NDC after the divide -- the same rigid
// 2D slide the CPU applies in pixels, expressed so each side can work in
// the space natural to it and still land on the same pixel.
Vec4 gizmoVertexClip(const SceneGizmoVertexIn& vertex, const SceneGizmoFrameUniforms& frame);

// A FIXED KEY LIGHT, not the scene's own. The gizmo is chrome: it has to
// read as round from any camera angle and under any scene lighting,
// including none. The shade floor is 0.62 rather than 0 because "which way
// is round" reads from the gradient between a lit face and a merely-dimmer
// one, not from a lit face next to a silhouette.
Vec4 gizmoFragment(
    const Vec3& world, const Vec3& normal, const Vec4& color,
    const SceneGizmoFrameUniforms& frame);

} // namespace SceneShaderMath
} // namespace umeshcore
