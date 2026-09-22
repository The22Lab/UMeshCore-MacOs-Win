// Tests for Render/SceneGPUTypes.h, ported from
// `Render/SceneGPU/SceneGPUTypes.swift`.
//
// The layout itself is checked at COMPILE time by the `static_assert`s in
// the header -- that is what stands in for
// `Editor/verify_scene_gpu_transcription.py`, which this repository does
// not have (see CLAUDE.md). What is left for runtime is the part a size
// check cannot see: that a field written by name lands on the WORD the
// shader reads it from. The shader indexes these structs as float4s and
// uints; a field that compiles to the right size but the wrong word is
// exactly the "one light reading a neighbour's radius" failure the Swift
// header names.
//
// So these tests write a distinct value into every field and read the
// struct back as a flat array of words, the way the GPU does.

#include "umeshcore/Render/SceneGPUTypes.h"

#include <cstring>

#include "TestHarness.h"

using namespace umeshcore;

namespace {

// The struct as the shader sees it: a flat run of 4-byte words.
template <typename T>
void words(const T& value, float* asFloat, std::uint32_t* asUint) {
    std::memcpy(asFloat, &value, sizeof(T));
    std::memcpy(asUint, &value, sizeof(T));
}

} // namespace

static void testFrameUniformsLandWhereTheShaderReadsThem() {
    SceneFrameUniforms frame;
    frame.viewProjection = Mat4::diagonal(Vec4(2, 3, 4, 5));
    frame.eyeAndNear = Vec4(10, 11, 12, 13);
    frame.ambient = Vec4(0.1f, 0.2f, 0.3f, 0);
    frame.lightCount = 7;

    float f[28];
    std::uint32_t u[28];
    words(frame, f, u);
    // The matrix occupies words 0..15, column-major, so the diagonal is at
    // 0, 5, 10, 15 -- the order Metal's float4x4 expects.
    UM_CHECK(f[0] == 2.0f && f[5] == 3.0f && f[10] == 4.0f && f[15] == 5.0f);
    UM_CHECK(f[16] == 10.0f && f[19] == 13.0f); // eyeAndNear: xyz eye, w nearZ
    UM_CHECK(f[20] == 0.1f && f[23] == 0.0f);   // ambient: rgb, w unused
    UM_CHECK(u[24] == 7u);
    UM_CHECK(u[25] == 0u && u[26] == 0u && u[27] == 0u); // pads stay zero
}

static void testLightUniformFieldOrder() {
    SceneLightUniform light;
    light.originAndRadius = Vec4(1, 2, 3, 400);
    light.directionAndInner = Vec4(0, 0, 1, 50);
    light.tintAndBand = Vec4(0.5f, 0.6f, 0.7f, 20);
    light.cones = Vec4(0.9f, 0.8f, 0.25f, 0.75f);
    light.kind = static_cast<std::uint32_t>(SceneLightKindCode::kSpot);
    light.blend = static_cast<std::uint32_t>(SceneLightBlendCode::kScreen);
    light.mask = 0x0Fu;
    light.falloffRow = 3;
    light.setOccluders(11, 4);
    light.castsShadows = 1;

    float f[24];
    std::uint32_t u[24];
    words(light, f, u);
    UM_CHECK(f[3] == 400.0f);  // radius rides in origin.w
    UM_CHECK(f[7] == 50.0f);   // inner radius in direction.w
    UM_CHECK(f[11] == 20.0f);  // band in tint.w
    UM_CHECK(f[12] == 0.9f && f[15] == 0.75f);
    UM_CHECK(u[16] == 1u && u[17] == 3u && u[18] == 0x0Fu && u[19] == 3u);
    // The occluder slice is per light, not global -- and it is the last
    // thing written, after the whole frame's occluders are known.
    UM_CHECK(u[20] == 11u && u[21] == 4u);
    UM_CHECK(u[22] == 1u && u[23] == 0u);
}

static void testOccluderCarriesItsPlaneOffset() {
    SceneOccluder occluder;
    occluder.origin = Vec4(5, 6, 7, 0);
    occluder.axisU = Vec4(100, 0, 0, 0);
    occluder.axisV = Vec4(0, 80, 0, 0);
    // w is dot(normal, origin), carried rather than recomputed: the shader
    // needs it once per occluder per fragment.
    occluder.normalAndOffset = Vec4(0, 0, 1, 7);
    occluder.uvRect = Vec4(0.25f, 0.5f, 0.125f, 0.125f);
    occluder.castMask = 0xFFu;
    occluder.useAlpha = 1;

    float f[24];
    std::uint32_t u[24];
    words(occluder, f, u);
    UM_CHECK(f[0] == 5.0f && f[4] == 100.0f && f[9] == 80.0f);
    UM_CHECK(f[14] == 1.0f && f[15] == 7.0f);
    UM_CHECK(f[16] == 0.25f);
    UM_CHECK(u[20] == 0xFFu && u[21] == 1u && u[22] == 0u && u[23] == 0u);
}

static void testLayerUniformDefaultsAreTheOldPath() {
    // The promise the whole normal-map feature hangs on: a surface that
    // asks for nothing renders as it did before. So the defaults must be
    // the no-feature path -- no flags, no shadows, no relief -- and the
    // tangent must still be a usable frame rather than zero.
    const SceneLayerUniforms layer;
    UM_CHECK(layer.materialFlags == 0u);
    UM_CHECK(layer.shadowedMask == 0u);
    UM_CHECK(layer.tangentAndSign == Vec4(1, 0, 0, 1));
    UM_CHECK(layer.material == Vec4(0, 0, 0, 0));
    // ZERO WHEN THERE IS NO MARCH: a stale depth left here would be read
    // by nothing -- until a new flag opens a second door onto it.
    UM_CHECK(layer.parallax == Vec4(0, 0, 0, 0));
}

static void testLayerUniformFieldOrder() {
    SceneLayerUniforms layer;
    layer.uvRect = Vec4(0, 0, 0.5f, 0.25f);
    layer.tint = Vec4(1, 0.5f, 0.25f, 1);
    layer.lightMask = 0x03u;
    layer.receivesLight = 1;
    layer.materialFlags = kSceneHasNormalMap | kSceneHasHeightMap;
    layer.shadowedMask = 0x02u;
    layer.normalAndStrength = Vec4(0, 0, -1, 0.75f);
    layer.tangentAndSign = Vec4(1, 0, 0, -1);
    layer.material = Vec4(0.3f, 0.4f, 0.5f, 0);
    layer.parallax = Vec4(0.05f, 8, 32, 16);

    float f[28];
    std::uint32_t u[28];
    words(layer, f, u);
    UM_CHECK(f[2] == 0.5f && f[5] == 0.5f);
    UM_CHECK(u[8] == 0x03u && u[9] == 1u && u[10] == 3u && u[11] == 0x02u);
    UM_CHECK(f[15] == 0.75f); // strength rides in normal.w
    UM_CHECK(f[19] == -1.0f); // handedness rides in tangent.w
    UM_CHECK(f[20] == 0.3f);
    // Min and max march steps are FLOATS: they are interpolated against
    // the view angle before anything counts with them.
    UM_CHECK(f[25] == 8.0f && f[26] == 32.0f);
}

static void testMaterialFlagsAreDistinctBits() {
    // Each flag gates a branch, so two sharing a bit would turn one
    // feature on with another.
    const std::uint32_t all[] = {kSceneHasNormalMap,   kSceneHasHeightMap,
                                 kSceneHeightFromNormalAlpha, kSceneParallaxClip,
                                 kSceneParallaxSelfShadow,    kSceneHeightInverted};
    std::uint32_t seen = 0;
    for (std::uint32_t flag : all) {
        UM_CHECK(flag != 0u && (flag & (flag - 1u)) == 0u); // one bit each
        UM_CHECK((seen & flag) == 0u);                      // and not shared
        seen |= flag;
    }
    // The one test the fragment shader takes, so the cheap path is decided
    // once rather than by conditions that could disagree.
    UM_CHECK(kSceneParallaxAny == (kSceneHasHeightMap | kSceneHeightFromNormalAlpha));
    UM_CHECK((kSceneParallaxAny & kSceneHasNormalMap) == 0u);
}

static void testWireCodesAreFixedByValueNotByDeclarationOrder() {
    // These numbers ARE the wire format: the shader compares against them
    // and saved scenes are read back through them. They are asserted as
    // literals on purpose -- a test that read them off the enum would
    // agree with any reordering.
    UM_CHECK(static_cast<std::uint32_t>(SceneLightKindCode::kPoint) == 0u);
    UM_CHECK(static_cast<std::uint32_t>(SceneLightKindCode::kSpot) == 1u);
    UM_CHECK(static_cast<std::uint32_t>(SceneLightKindCode::kDirectional) == 2u);
    UM_CHECK(static_cast<std::uint32_t>(SceneLightBlendCode::kNormal) == 0u);
    UM_CHECK(static_cast<std::uint32_t>(SceneLightBlendCode::kAdditive) == 1u);
    UM_CHECK(static_cast<std::uint32_t>(SceneLightBlendCode::kMultiply) == 2u);
    UM_CHECK(static_cast<std::uint32_t>(SceneLightBlendCode::kScreen) == 3u);
}

static void testVertexLayoutsMatchTheShadersWordIndices() {
    SceneVertexIn vertex;
    vertex.world = Vec3(1, 2, 3);
    vertex.uv = Vec2(0.25f, 0.75f);
    float f[8];
    std::uint32_t u[8];
    words(vertex, f, u);
    // uv at word 4, not word 3: float3 aligns to 16 bytes. Packing it at
    // word 3 is the classic drift -- every vertex reads its neighbour's.
    UM_CHECK(f[0] == 1.0f && f[1] == 2.0f && f[2] == 3.0f);
    UM_CHECK(f[4] == 0.25f && f[5] == 0.75f);

    SceneSkinnedVertexIn skinned;
    skinned.bindLocal = Vec2(-10, 20);
    skinned.uv = Vec2(0.5f, 0.5f);
    skinned.slots[0] = 1;
    skinned.slots[3] = 9;
    skinned.weights = Vec4(0.6f, 0.4f, 0, 0);
    float sf[12];
    std::uint32_t su[12];
    words(skinned, sf, su);
    UM_CHECK(sf[0] == -10.0f && sf[2] == 0.5f);
    // Four ushorts pack into words 4 and 5; the weights start at word 8.
    UM_CHECK((su[4] & 0xFFFFu) == 1u);
    UM_CHECK((su[5] >> 16) == 9u);
    UM_CHECK(sf[8] == 0.6f && sf[9] == 0.4f);
}

UM_TEST_MAIN_BEGIN()
    testFrameUniformsLandWhereTheShaderReadsThem();
    testLightUniformFieldOrder();
    testOccluderCarriesItsPlaneOffset();
    testLayerUniformDefaultsAreTheOldPath();
    testLayerUniformFieldOrder();
    testMaterialFlagsAreDistinctBits();
    testWireCodesAreFixedByValueNotByDeclarationOrder();
    testVertexLayoutsMatchTheShadersWordIndices();
UM_TEST_MAIN_END()
