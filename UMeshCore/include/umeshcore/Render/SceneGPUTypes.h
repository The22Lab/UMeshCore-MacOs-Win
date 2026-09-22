#pragma once

// 1:1 port of `Render/SceneGPU/SceneGPUTypes.swift` -- the POD structs the
// scene shader reads, byte for byte.
//
// These are a WIRE FORMAT, not ordinary data types. The same bytes are
// declared three times in the Swift project (Swift, MSL) and will be
// declared a fourth time in HLSL for the DirectX backend; nothing but the
// layout keeps them in step. The Swift header states the failure exactly:
// drift here "produces a picture where one light is right and the next is
// reading a neighbour's radius". That is not a crash and not obviously
// wrong on screen -- it is a lighting bug that reads as an artistic
// mistake.
//
// WHY THE PADDING IS SPELLED OUT. Metal aligns `float3` to 16 bytes, and
// so does Swift's `SIMD3<Float>`. A `float3` followed by a `float` written
// as two fields occupies 32 bytes, not 16; packing them into a `float4` by
// hand is the only way the declarations can be read off against each other
// without counting. C++ is the odd one out here -- `Vec3` is 12 bytes with
// 4-byte alignment -- so every struct below is `alignas(16)` and every
// hole is a named `pad` field. Nothing is left to the compiler.
//
// THE MISSING HARNESS, AND WHAT REPLACES IT. The Swift files say they are
// kept in step by `Editor/verify_scene_gpu_transcription.py`, which
// compares the declarations field by field and checks every size is a
// multiple of 16. That script does not exist in this repository (see
// CLAUDE.md). So the check is moved INTO the code: every struct below
// carries `static_assert`s on its size, its alignment and the offset of
// every field, against the numbers derived by hand from the Metal
// declarations in `SceneGPU/SceneShaders.metal`. A compiler that would lay
// these out differently does not compile the library. That is strictly
// stronger than a script nobody runs, and it is the only part of this file
// that must be re-checked when the shader side is authored (Phase 4 piece
// 9).
//
// NOT PORTED, and why:
//   - `SceneLightUniform.init(_ prepared:falloffRow:)`. It transcribes a
//     `SceneLighting.PreparedLight`, which is Phase 4 piece 7, off a
//     `SceneLight`, which is Phase 5. The Swift initializer derives
//     nothing -- "`PreparedLight` stays the one place the numbers are
//     derived" -- so it is a field-by-field copy that costs nothing to
//     write once those types land, and writing it now would mean inventing
//     them.
//   - `kindCode` / `blendCode` keep their VALUES here, as enums, because
//     the values are the wire contract and the shader compares against
//     them. What is deliberately not here is the mapping FROM the model's
//     enums: Swift writes that as an explicit `switch` rather than giving
//     the enums an Int raw value, because those enums are `String`-backed
//     for the file format and a raw value would make the wire format
//     depend on Swift declaration order -- reordering the cases would then
//     silently change every saved scene. The same rule holds for the C++
//     model when Phase 5 lands it: map with a switch, never a cast.

#include <cstddef>
#include <cstdint>

#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

// ---- Per frame ---------------------------------------------------------

struct alignas(16) SceneFrameUniforms {
    Mat4 viewProjection = Mat4::identity();
    Vec4 eyeAndNear;  // xyz eye, w nearZ
    Vec4 ambient;     // rgb ambient, w unused
    std::uint32_t lightCount = 0;
    std::uint32_t pad0 = 0;
    std::uint32_t pad1 = 0;
    std::uint32_t pad2 = 0;
};

static_assert(sizeof(SceneFrameUniforms) == 112, "frame uniforms are 112 bytes in MSL");
static_assert(alignof(SceneFrameUniforms) == 16, "");
static_assert(offsetof(SceneFrameUniforms, viewProjection) == 0, "");
static_assert(offsetof(SceneFrameUniforms, eyeAndNear) == 64, "");
static_assert(offsetof(SceneFrameUniforms, ambient) == 80, "");
static_assert(offsetof(SceneFrameUniforms, lightCount) == 96, "");

// ---- Lights ------------------------------------------------------------

// The codes the shader compares against. Values are the WIRE contract --
// see the header's note on why the model's enums must be mapped onto these
// with an explicit switch rather than by a cast.
enum class SceneLightKindCode : std::uint32_t { kPoint = 0, kSpot = 1, kDirectional = 2 };
enum class SceneLightBlendCode : std::uint32_t {
    kNormal = 0,
    kAdditive = 1,
    kMultiply = 2,
    kScreen = 3
};

struct alignas(16) SceneLightUniform {
    Vec4 originAndRadius;    // xyz world origin, w radius
    Vec4 directionAndInner;  // xyz unit direction, w inner radius
    Vec4 tintAndBand;        // rgb colour * intensity, w fade band width
    Vec4 cones;              // x cosInner, y cosOuter, z depthInfluence, w normalInfluence
    std::uint32_t kind = 0;
    std::uint32_t blend = 0;
    std::uint32_t mask = 0;  // 8 channel bits, in the low byte
    std::uint32_t falloffRow = 0;
    // This light's slice of the occluder buffer, culled on the CPU.
    //
    // PER LIGHT AND NOT GLOBAL. Shadowing is O(lights x occluders) per
    // fragment, and most occluders are nowhere near most lights -- so the
    // CPU drops the ones outside the radius and outside the cast mask once
    // per frame, instead of the GPU rejecting them once per pixel.
    std::uint32_t occluderStart = 0;
    std::uint32_t occluderCount = 0;
    // 0 unless the artist asked this light for shadows. Off by default, so
    // every project that predates them pays nothing at all.
    std::uint32_t castsShadows = 0;
    std::uint32_t pad0 = 0;

    // Separate from construction because the slice is decided once the
    // whole frame's occluders are known, and the uniform is built before
    // that.
    void setOccluders(std::uint32_t start, std::uint32_t count) {
        occluderStart = start;
        occluderCount = count;
    }
};

static_assert(sizeof(SceneLightUniform) == 96, "light uniform is 96 bytes in MSL");
static_assert(alignof(SceneLightUniform) == 16, "");
static_assert(offsetof(SceneLightUniform, originAndRadius) == 0, "");
static_assert(offsetof(SceneLightUniform, directionAndInner) == 16, "");
static_assert(offsetof(SceneLightUniform, tintAndBand) == 32, "");
static_assert(offsetof(SceneLightUniform, cones) == 48, "");
static_assert(offsetof(SceneLightUniform, kind) == 64, "");
static_assert(offsetof(SceneLightUniform, occluderStart) == 80, "");
static_assert(offsetof(SceneLightUniform, castsShadows) == 88, "");

// ---- Shadow casters ----------------------------------------------------

// One thing that can stand between a light and a surface.
//
// A PARALLELOGRAM, NOT A RECTANGLE. A Scene card can be sheared, and a
// sheared card's two axes are not perpendicular. Testing "inside" by
// projecting onto each axis separately is right for a rectangle and wrong
// for every sheared one -- the shadow comes out the shape the card would
// have had without its slant. The shader solves the 2x2 system instead,
// which is exact for a parallelogram and costs about ten instructions.
//
// FLAT, AND THAT IS NOT A SIMPLIFICATION. Every Scene layer is flat by the
// model's founding rule, so an occluder IS a plane segment and a ray
// crosses it exactly once. That is why the alpha silhouette costs ONE
// texture read per occluder per light rather than a march along the ray,
// and it is the whole reason the expensive-looking option is affordable.
struct alignas(16) SceneOccluder {
    Vec4 origin;           // xyz the quad's centre in world space, w unused
    Vec4 axisU;            // xyz half-extent along the artwork's +x, w unused
    Vec4 axisV;            // xyz half-extent along the artwork's +y (image UP), w unused
    // xyz the plane's unit normal, w `dot(normal, origin)`. The offset is
    // carried rather than recomputed because the shader needs it once per
    // occluder per fragment and the CPU needs it once per frame.
    Vec4 normalAndOffset;
    Vec4 uvRect;           // where this occluder's alpha tile sits in the shadow atlas
    std::uint32_t castMask = 0;
    // 1 when the alpha tile is real, 0 when the quad is the whole
    // silhouette. A fill has no artwork to cut a hole in, and an asset
    // whose alpha could not be read must cast its rectangle rather than
    // nothing -- a missing file should not silently stop a character
    // casting a shadow.
    std::uint32_t useAlpha = 0;
    std::uint32_t pad0 = 0;
    std::uint32_t pad1 = 0;
};

static_assert(sizeof(SceneOccluder) == 96, "occluder is 96 bytes in MSL");
static_assert(alignof(SceneOccluder) == 16, "");
static_assert(offsetof(SceneOccluder, normalAndOffset) == 48, "");
static_assert(offsetof(SceneOccluder, uvRect) == 64, "");
static_assert(offsetof(SceneOccluder, castMask) == 80, "");

// ---- Per surface -------------------------------------------------------

// Bit 0 of `materialFlags`. A FLAG AND NOT A TEST ON `normalStrength`,
// because the whole feature hangs off the promise that a sprite without a
// normal map renders exactly as it did before -- bit for bit, not nearly.
// The obvious alternative, a flat lavender texel, decodes to +z and
// rotates back to the surface's own normal, and is bit-identical ON A CARD
// FACING THE CAMERA. It is not on a tilted one: the normal comes from a
// cross product, and the cross product of two unit vectors is not reliably
// unit in float32. The Swift harness measured 826 of 4000 random tilted
// cards coming back from that round trip changed, by up to 1.2e-07 --
// which nobody would ever report, and which a test scene facing the camera
// would not catch. So the flag gates a BRANCH, and on the old path the
// shader never samples, never rotates and never normalises.
inline constexpr std::uint32_t kSceneHasNormalMap = 1u;

// The parallax bits, flags for the same reason bit 0 is: a surface with no
// height field must take a path where nothing is sampled, marched or
// normalised -- not one where the march runs against a neutral texture and
// happens to land back where it started, which is a rounding error per
// pixel on every project that predates the feature.
inline constexpr std::uint32_t kSceneHasHeightMap = 2u;
// No height texture, but the normal map carries height in its alpha. The
// two are mutually exclusive and the renderer never sets both.
inline constexpr std::uint32_t kSceneHeightFromNormalAlpha = 4u;
// Throw away fragments whose ray found no surface, or left the artwork --
// what makes the OUTLINE follow the relief instead of staying a rectangle.
inline constexpr std::uint32_t kSceneParallaxClip = 8u;
// March a second ray towards each light, from the hit point.
inline constexpr std::uint32_t kSceneParallaxSelfShadow = 16u;
// The map stores depth (near is bright) rather than height.
inline constexpr std::uint32_t kSceneHeightInverted = 32u;
// "Is there anything to march against at all" -- the one test the fragment
// shader takes, so the cheap path is decided once rather than by three
// separate conditions that could disagree.
inline constexpr std::uint32_t kSceneParallaxAny =
    kSceneHasHeightMap | kSceneHeightFromNormalAlpha;
// The loop bound the compiler can see. The real step count is a uniform
// and is always <= this; a loop whose trip count is entirely unknown
// cannot be unrolled or bounded, and on a fragment shader that is the
// difference between a march and a hang.
inline constexpr std::uint32_t kSceneMaxParallaxSteps = 128u;
// The self-shadow march is shorter for the same reason a shadow is cheaper
// than a surface: it answers yes or no, not where.
inline constexpr std::uint32_t kSceneMaxParallaxShadowSteps = 32u;

// The surface a layer -- or one sprite of a rig -- presents to the lights.
//
// WHY THE TANGENT FRAME IS HERE AND NOT DERIVED IN THE SHADER. A normal
// map stores its normals in TANGENT space: +x right across the image, +y
// up it, +z out of it. Turning one into a world normal needs the three
// world axes those correspond to, and there is exactly one honest source:
// `SceneLayer.orientation()` (Phase 5), which is orthonormal and carries
// NO scale and NO shear. A sheared card's plane axes are not
// perpendicular, so a normal rotated by them is no longer unit and no
// longer perpendicular to anything -- the same fault the gizmo had, where
// a sheared card handed it a frame that was not a rotation and every arrow
// came out skewed. An orthonormal basis also has the convenience that its
// inverse transpose is itself.
//
// The honest cost: because the frame is scale-free, relief does not
// stretch with a non-uniformly scaled card. A bump on a card scaled 3x
// wide still lights round -- for an emboss that is the reading an artist
// wants, and it is the same approximation the flat normal already made.
struct alignas(16) SceneLayerUniforms {
    Vec4 uvRect;  // atlas placement: x, y, width, height
    Vec4 tint;    // rgba, premultiplied on the way in
    std::uint32_t lightMask = 0;
    std::uint32_t receivesLight = 0;
    // What this surface has, one bit each -- the `kScene*` constants above.
    std::uint32_t materialFlags = 0;
    // Which light channels' shadows may darken this surface. Zero receives
    // none, which is what every project that predates shadows wants.
    std::uint32_t shadowedMask = 0;
    // xyz the layer's plane normal in world space, w the normal-map
    // strength. Strength 0 is a flat surface and 1 is the map as painted;
    // it is the AMPLITUDE knob, deliberately separate from smoothness,
    // which reshapes the response rather than the relief.
    Vec4 normalAndStrength;
    // xyz the tangent -- image +x -- in world space, w the handedness.
    // The handedness is `sign(scale.x * scale.y)` and the shader derives
    // the bitangent as `handed * cross(N, T)`. A negative scale mirrors the
    // card, and a mirrored basis that is not told it is mirrored lights the
    // relief from the wrong side -- plausible in a still, wrong the moment
    // a light moves across it.
    Vec4 tangentAndSign = Vec4(1, 0, 0, 1);
    // x smoothness, y contrast, z parallax occlusion strength, w spare.
    Vec4 material;
    // x depth of the height volume in UV units, y minimum march steps,
    // z maximum march steps, w steps of the self-shadow march.
    //
    // ZERO WHEN THERE IS NO MARCH, and that is not merely tidy: the shader
    // reaches this field only inside the parallax branch, so a stale depth
    // left here by a layer that turned the feature off would be read by
    // nothing -- until the day a new flag opens a second door onto it.
    //
    // MIN AND MAX AS FLOATS, not uints: they are interpolated against the
    // view angle (`mix(max, min, |Vz|)`) before anything counts with them,
    // so storing them as integers would only mean converting them back.
    Vec4 parallax;
};

static_assert(sizeof(SceneLayerUniforms) == 112, "layer uniforms are 112 bytes in MSL");
static_assert(alignof(SceneLayerUniforms) == 16, "");
static_assert(offsetof(SceneLayerUniforms, tint) == 16, "");
static_assert(offsetof(SceneLayerUniforms, lightMask) == 32, "");
static_assert(offsetof(SceneLayerUniforms, normalAndStrength) == 48, "");
static_assert(offsetof(SceneLayerUniforms, tangentAndSign) == 64, "");
static_assert(offsetof(SceneLayerUniforms, material) == 80, "");
static_assert(offsetof(SceneLayerUniforms, parallax) == 96, "");

// ---- Vertices ----------------------------------------------------------

// One vertex of a card, in WORLD space.
//
// World and not screen, and that is the change that makes navigation free.
// The rig canvas uploads screen-space vertices, so moving the camera one
// pixel rebuilds and re-uploads every vertex of every mesh even though
// nothing in the world moved. Here the camera is a uniform: panning and
// zooming a still scene uploads nothing at all.
//
// The two pads are the `float3` alignment rule made visible: MSL lays this
// out as world at 0, uv at 16, stride 32. C++'s `Vec3` would put uv at 12
// and the struct at 20, which is the drift this file exists to prevent.
struct alignas(16) SceneVertexIn {
    Vec3 world;
    float pad0 = 0.0f;
    Vec2 uv;
    float pad1 = 0.0f;
    float pad2 = 0.0f;
};

static_assert(sizeof(SceneVertexIn) == 32, "vertex is 32 bytes in MSL (float3 aligns to 16)");
static_assert(alignof(SceneVertexIn) == 16, "");
static_assert(offsetof(SceneVertexIn, world) == 0, "");
static_assert(offsetof(SceneVertexIn, uv) == 16, "");

// One vertex of a skinned sprite.
//
// The position is the vertex's BIND position, in sprite-local space, and
// it never changes while the rig animates -- the pose lives entirely in
// the palette. So this buffer is uploaded once and reused every frame.
//
// That is the whole of why playback stops costing what it costs. With the
// pose baked into the vertices, every cache keyed on it misses on every
// frame of an animation and the full per-triangle cost comes back:
// measured at 38.6 ms for two instances, over a 30fps budget before
// anything else in the scene is drawn. With the pose in the palette, an
// animating rig re-uploads thirty matrices and nothing else.
struct alignas(16) SceneSkinnedVertexIn {
    Vec2 bindLocal;
    Vec2 uv;
    // Four slots into the palette. Slot 0 is the identity, so an
    // unweighted vertex needs no branch in the shader.
    std::uint16_t slots[4] = {0, 0, 0, 0};
    std::uint32_t pad0 = 0;
    std::uint32_t pad1 = 0;
    // Four weights that SUM TO ONE -- normalised by `SceneSkinPalette`,
    // because folding the sprite's bind affine into the palette is exact
    // only when they do.
    Vec4 weights;
};

static_assert(sizeof(SceneSkinnedVertexIn) == 48, "skinned vertex is 48 bytes in MSL");
static_assert(alignof(SceneSkinnedVertexIn) == 16, "");
static_assert(offsetof(SceneSkinnedVertexIn, uv) == 8, "");
static_assert(offsetof(SceneSkinnedVertexIn, slots) == 16, "");
static_assert(offsetof(SceneSkinnedVertexIn, weights) == 32, "");

} // namespace umeshcore
