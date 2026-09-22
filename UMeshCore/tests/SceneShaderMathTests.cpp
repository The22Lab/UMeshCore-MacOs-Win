// Tests for Render/SceneShaderMath.h -- the C++ reference for
// `SceneGPU/SceneShaders.metal` and `SceneGizmoShaders.metal`.
//
// The point of this file is not that the reference runs. It is that the
// GPU path and the CPU path can be put side by side and DIFFED, which is
// what `Editor/lighting_mirror.py` was for ("the normative reference for
// what a lit pixel is worth") and what this repository does not have. So
// the first tests below are cross-checks against `SceneLighting`, the
// already-ported CPU implementation of the same arithmetic:
//
//   - `shapedLambert` must agree BIT FOR BIT. Same formula, same order,
//     same branches -- anything less means one of the two transcriptions
//     drifted.
//   - `lightLambert` likewise.
//   - `lightAttenuation` must agree to within the ONE documented
//     difference between the two: the GPU reads its falloff through a
//     texture sampler and the CPU indexes a table, and those address
//     differently. The test measures that gap rather than assuming it
//     away -- see `testTheFalloffSamplerDisagreesWithTheTableAndByHowMuch`.
//   - A whole lit pixel, end to end, must match `SceneLighting::shade`
//     composited the way the fragment composites it.
//
// The rest pin the shader's own documented behaviours, especially the ones
// whose failure modes the source says a still frame cannot show.

#include "umeshcore/Render/SceneShaderMath.h"

#include <cmath>
#include <vector>

#include "umeshcore/Math/MatrixUtilities.h"
#include "umeshcore/Render/SceneLighting.h"

#include "TestHarness.h"

using namespace umeshcore;
namespace S = umeshcore::SceneShaderMath;

namespace {

constexpr float kPi = 3.14159265358979323846f;

// The transcription `SceneLightUniform`'s Swift initializer performs, which
// this port deferred until the lighting math existed. Written here because
// the cross-check needs it; Phase 5's renderer will want exactly this.
SceneLightUniform uniformFrom(const PreparedLight& prepared, std::uint32_t falloffRow) {
    SceneLightUniform out;
    out.originAndRadius = Vec4(prepared.origin, prepared.radius);
    out.directionAndInner = Vec4(prepared.direction, prepared.innerRadius);
    out.tintAndBand = Vec4(prepared.tint, prepared.band);
    out.cones = Vec4(
        prepared.cosInner, prepared.cosOuter, prepared.light.depthInfluence,
        prepared.light.normalInfluence);
    out.kind = static_cast<std::uint32_t>(lightKindCode(prepared.light.kind));
    out.blend = static_cast<std::uint32_t>(lightBlendCode(prepared.light.blend));
    out.mask = prepared.light.mask;
    out.falloffRow = falloffRow;
    out.castsShadows = prepared.light.castsShadows ? 1u : 0u;
    return out;
}

// The falloff table as the one-row texture the shader samples.
S::Texture2D curveTexture(const PreparedLight& prepared) {
    S::Texture2D texture;
    texture.width = static_cast<int>(prepared.table.size());
    texture.height = 1;
    texture.texels.reserve(prepared.table.size());
    for (float value : prepared.table) texture.texels.push_back(Vec4(value, value, value, 1.0f));
    return texture;
}

SceneLightParams pointLight() {
    SceneLightParams light;
    light.world = Vec3(0, 0, -200);
    light.radius = 500.0f;
    light.softness = 0.6f;
    light.color = Vec3(1.0f, 0.9f, 0.8f);
    light.intensity = 1.2f;
    light.depthInfluence = 1.0f;
    light.normalInfluence = 0.0f;
    return light;
}

SceneLayerUniforms flatLayer() {
    SceneLayerUniforms layer;
    layer.uvRect = Vec4(0, 0, 1, 1);
    layer.tint = Vec4(1, 1, 1, 1);
    layer.lightMask = 0xFF;
    layer.receivesLight = 1;
    layer.normalAndStrength = Vec4(0, 0, -1, 1);
    layer.tangentAndSign = Vec4(1, 0, 0, 1);
    return layer;
}

S::VertexOut fragmentAt(const Vec3& world, const Vec2& uv, const SceneLayerUniforms& layer) {
    SceneVertexIn vertex;
    vertex.world = world;
    vertex.uv = uv;
    SceneFrameUniforms frame;
    return S::cardVertex(vertex, frame, layer);
}

} // namespace

static void testShapedLambertAgreesBitForBitWithTheCpuPath() {
    for (int s = 0; s <= 4; ++s) {
        for (int c = 0; c <= 4; ++c) {
            const float smoothness = static_cast<float>(s) / 4.0f;
            const float contrast = static_cast<float>(c) / 4.0f;
            for (int i = 0; i <= 4000; ++i) {
                const float d = -1.0f + 2.0f * static_cast<float>(i) / 4000.0f;
                // Not "close": equal. Two transcriptions of one formula
                // that differ at all have already drifted.
                UM_CHECK(
                    S::shapedLambert(d, smoothness, contrast) ==
                    SceneLighting::shapedLambert(d, smoothness, contrast));
            }
        }
    }
}

static void testLightLambertAgreesBitForBitWithTheCpuPath() {
    SceneLightParams params = pointLight();
    params.normalInfluence = 0.7f;
    const PreparedLight prepared{params};
    const SceneLightUniform uniform = uniformFrom(prepared, 0);
    for (int i = 0; i < 200; ++i) {
        const float t = static_cast<float>(i) / 200.0f;
        const Vec3 point(-400.0f + 800.0f * t, 120.0f * std::sin(t * 6.0f), -50.0f + 300.0f * t);
        const Vec3 normal = normalize(Vec3(std::sin(t * 3.0f), std::cos(t * 5.0f), -1.0f));
        UM_CHECK(
            S::lightLambert(uniform, point, normal, 0.3f, 0.2f) ==
            prepared.lambert(point, normal, 0.3f, 0.2f));
    }
    // The influence's early-out is the same on both sides, including its
    // position: outermost, so a surface cannot resurrect a flat light.
    const PreparedLight flat{pointLight()};
    const SceneLightUniform flatUniform = uniformFrom(flat, 0);
    UM_CHECK(S::lightLambert(flatUniform, Vec3(0, 0, 0), Vec3(0, 0, 1), 1.0f, 1.0f) == 1.0f);
}

static void testTheFalloffSamplerDisagreesWithTheTableAndByHowMuch() {
    // The shader's comment says the off-by-one "is the sampler's business,
    // not ours". It is -- and the sampler's business is texel CENTRES, so
    // it addresses `u * n - 0.5` where the CPU addresses `u * (n - 1)`.
    // The two therefore read different entries of the same table.
    //
    // THIS IS NOT A ROUNDING DIFFERENCE ON EVERY CURVE. Measured here, per
    // preset, over 20 001 samples of a 256-entry table:
    //
    //     smooth         0.29 / 255   (the default)
    //     linear         0.50 / 255
    //     inverseSquare  3.21 / 255   at u = 0.025
    //
    // The last one is over three quantisation steps, in the steepest part
    // of the steepest preset -- the GPU and the CPU compositor would put
    // visibly different numbers in the same pixel of the same frame. The
    // fix is one line on whichever side is chosen as normative (tabulate
    // at the sampler's positions, or address the table at texel centres),
    // and it belongs with the shell that first ships both paths; what must
    // not happen is for it to stay unmeasured.
    const struct {
        const char* name;
        LightFalloffCurve curve;
        double bound;
    } presets[] = {
        {"smooth", LightFalloffCurve::smooth(), 0.5 / 255.0},
        {"linear", LightFalloffCurve::linear(), 0.6 / 255.0},
        {"inverseSquare", LightFalloffCurve::inverseSquare(), 3.3 / 255.0}};

    for (const auto& preset : presets) {
        SceneLightParams params = pointLight();
        params.falloff = preset.curve;
        const PreparedLight prepared{params};
        const S::Texture2D curves = curveTexture(prepared);
        double worst = 0.0;
        for (int i = 0; i <= 20000; ++i) {
            const float u = static_cast<float>(i) / 20000.0f;
            worst = std::max(
                worst, std::fabs(static_cast<double>(S::sampleFalloff(curves, 0, u)) -
                                 static_cast<double>(prepared.falloff(u))));
        }
        UM_CHECK(worst > 0.0);          // the gap is real on every curve
        UM_CHECK(worst < preset.bound); // and this is how big it gets
    }

    // Both ends are pinned by clamp-to-edge, so the curve still starts at
    // full brightness and reaches zero at the rim whichever side reads it.
    const PreparedLight prepared{pointLight()};
    const S::Texture2D curves = curveTexture(prepared);
    UM_CHECK_NEAR(S::sampleFalloff(curves, 0, 0.0f), 1.0, 1e-6);
    UM_CHECK_NEAR(S::sampleFalloff(curves, 0, 1.0f), 0.0, 1e-6);
    UM_CHECK_NEAR(S::sampleFalloff(curves, 0, -3.0f), 1.0, 1e-6);
}

static void testAttenuationAgreesWithTheCpuPathWithinThatGap() {
    for (SceneLightKind kind :
         {SceneLightKind::kPoint, SceneLightKind::kSpot, SceneLightKind::kDirectional}) {
        SceneLightParams params = pointLight();
        params.kind = kind;
        params.azimuth = 0.3f;
        params.elevation = -0.2f;
        const PreparedLight prepared{params};
        const SceneLightUniform uniform = uniformFrom(prepared, 0);
        const S::Texture2D curves = curveTexture(prepared);
        double worst = 0.0;
        for (int i = 0; i < 500; ++i) {
            const float t = static_cast<float>(i) / 500.0f;
            const Vec3 point(
                -600.0f + 1200.0f * t, 300.0f * std::sin(t * 9.0f), -400.0f + 700.0f * t);
            worst = std::max(
                worst, std::fabs(static_cast<double>(S::lightAttenuation(uniform, point, curves)) -
                                 static_cast<double>(prepared.attenuation(point))));
        }
        // The default (smooth) falloff, so the bound is that curve's gap
        // from the test above and nothing else: every other term of the
        // attenuation -- the 2.5D scaling, the radius test, the cone's
        // smoothstep -- agrees exactly.
        UM_CHECK(worst < 0.5 / 255.0);
    }
}

static void testAWholeLitPixelAgreesWithTheCpuCompositor() {
    // End to end: the fragment stage against `SceneLighting::shade` plus
    // the composite the CPU path performs. This is the comparison
    // `lighting_mirror.py` existed to make.
    SceneLightParams params = pointLight();
    params.normalInfluence = 0.6f;
    const PreparedLight prepared{params};
    const SceneLightUniform uniform = uniformFrom(prepared, 0);
    const S::Texture2D curves = curveTexture(prepared);
    const S::Texture2D atlas = S::Texture2D::solid(4, 4, Vec4(0.4f, 0.3f, 0.2f, 0.8f));

    SceneLayerUniforms layer = flatLayer();
    layer.material = Vec4(0.25f, 0.1f, 0.0f, 0.0f); // smoothness, contrast

    SceneFrameUniforms frame;
    frame.ambient = Vec4(0.3f, 0.3f, 0.35f, 0);
    frame.lightCount = 1;
    frame.eyeAndNear = Vec4(0, 0, -1000, 1);
    const std::vector<SceneLightUniform> lights{uniform};
    S::FragmentBindings bindings;
    bindings.atlas = &atlas;
    bindings.curves = &curves;
    bindings.lights = &lights;

    for (int i = 0; i < 60; ++i) {
        const float t = static_cast<float>(i) / 60.0f;
        const Vec3 world(-300.0f + 600.0f * t, 200.0f * std::cos(t * 7.0f), 40.0f * t);
        const S::VertexOut in = fragmentAt(world, Vec2(0.5f, 0.5f), layer);
        const auto gpu = S::cardFragment(in, frame, layer, bindings);
        UM_CHECK(gpu.has_value());

        // The CPU side, with the same smoothness and contrast the layer
        // carries -- `shade` reads them off the surface exactly as the
        // fragment does.
        const Vec3 normal = layer.normalAndStrength.xyz();
        const float a = prepared.attenuation(world);
        const float reach = a * prepared.lambert(world, normal, 0.25f, 0.1f);
        const Vec3 factor = frame.ambient.xyz() + prepared.tint * reach;
        const Vec4 albedo(0.4f, 0.3f, 0.2f, 0.8f);
        const Vec3 lit = Vec3(albedo.x, albedo.y, albedo.z) * factor;
        const Vec3 expected(
            std::min(lit.x, albedo.w), std::min(lit.y, albedo.w), std::min(lit.z, albedo.w));
        UM_CHECK_NEAR(gpu->x, expected.x, 1e-3);
        UM_CHECK_NEAR(gpu->y, expected.y, 1e-3);
        UM_CHECK_NEAR(gpu->z, expected.z, 1e-3);
        UM_CHECK(gpu->w == albedo.w);
    }
}

static void testTangentFrameStaysARotationAndSurvivesADegenerateBone() {
    const Vec3 n(0, 0, -1);
    const S::TangentFrame frame = S::tangentFrame(n, Vec3(0.8f, 0.3f, 0.5f), 1.0f);
    UM_CHECK_NEAR(length(frame.tangent), 1.0, 1e-5);
    UM_CHECK_NEAR(length(frame.bitangent), 1.0, 1e-5);
    UM_CHECK_NEAR(dot(frame.tangent, n), 0.0, 1e-5); // projected back into the plane
    UM_CHECK_NEAR(dot(frame.tangent, frame.bitangent), 0.0, 1e-5);

    // The handedness flips the bitangent and nothing else: a mirrored card
    // lights its relief from the other side.
    const S::TangentFrame mirrored = S::tangentFrame(n, Vec3(0.8f, 0.3f, 0.5f), -1.0f);
    UM_CHECK(mirrored.tangent == frame.tangent);
    UM_CHECK_NEAR(length(mirrored.bitangent + frame.bitangent), 0.0, 1e-5);

    // A bone scaled to nothing leaves no direction to recover: the plane's
    // own x axis, not a NaN -- which would be a black triangle that comes
    // and goes with the pose.
    const S::TangentFrame degenerate = S::tangentFrame(n, Vec3::zero(), 1.0f);
    UM_CHECK(degenerate.tangent == Vec3(1, 0, 0));
    UM_CHECK(std::isfinite(degenerate.bitangent.y));
}

static void testTheSkinnedPathKeepsTheLayersLift() {
    // The 652-unit bug: the palette folds the layer's lift out of the
    // card's plane, so the skinned position is a SCENE-WORLD point.
    // Flattening it to z = 0 is right in the front view and wrong the
    // moment the camera orbits.
    SceneSkinnedVertexIn vertex;
    vertex.bindLocal = Vec2(40, -25);
    vertex.uv = Vec2(0.5f, 0.5f);
    vertex.slots[0] = 1;
    vertex.weights = Vec4(1, 0, 0, 0);

    const std::vector<Mat4> palette = {
        Mat4::identity(), MatrixUtilities::translation(Vec3(10, 5, 652))};
    const SceneFrameUniforms frame;
    const S::VertexOut out = S::skinnedVertex(vertex, frame, palette, flatLayer());
    UM_CHECK_NEAR(out.world.x, 50.0, 1e-4);
    UM_CHECK_NEAR(out.world.y, -20.0, 1e-4);
    UM_CHECK_NEAR(out.world.z, 652.0, 1e-3);

    // Slot zero is the identity, so an unweighted vertex needs no branch:
    // one influence of weight 1 on slot 0 lands on the bind position.
    SceneSkinnedVertexIn unweighted;
    unweighted.bindLocal = Vec2(7, 9);
    unweighted.weights = Vec4(1, 0, 0, 0);
    const S::VertexOut rest = S::skinnedVertex(unweighted, frame, palette, flatLayer());
    UM_CHECK_NEAR(rest.world.x, 7.0, 1e-5);
    UM_CHECK_NEAR(rest.world.y, 9.0, 1e-5);
    UM_CHECK_NEAR(rest.world.z, 0.0, 1e-5);

    // The normal is the LAYER's, unskinned -- no bone can tilt a sprite
    // out of its plane, so skinning it could only add rounding error.
    UM_CHECK(rest.normal == flatLayer().normalAndStrength.xyz());
}

static void testANormalMapAtRestChangesNothingAndStrengthOnlyTilts() {
    SceneLayerUniforms layer = flatLayer();
    const S::VertexOut in = fragmentAt(Vec3(0, 0, 0), Vec2(0.5f, 0.5f), layer);

    // Flat lavender decodes to +z, which rotates back to the surface's own
    // normal.
    const S::Texture2D flat = S::Texture2D::solid(2, 2, Vec4(0.5f, 0.5f, 1.0f, 1.0f));
    const Vec3 atRest = S::mappedNormal(layer, in, Vec2(0.5f, 0.5f), flat);
    UM_CHECK_NEAR(length(atRest - in.normal), 0.0, 1e-6);

    // A tilted texel, at three strengths: strength only changes HOW FAR
    // the normal tilts, because scaling all three components would be a
    // no-op after the normalise.
    const S::Texture2D tilted = S::Texture2D::solid(2, 2, Vec4(0.9f, 0.6f, 1.0f, 1.0f));
    float previousTilt = -1.0f;
    for (float strength : {0.0f, 0.5f, 1.0f}) {
        layer.normalAndStrength = Vec4(0, 0, -1, strength);
        const Vec3 mapped = S::mappedNormal(layer, in, Vec2(0.5f, 0.5f), tilted);
        UM_CHECK_NEAR(length(mapped), 1.0, 1e-5);
        const float tilt = 1.0f - std::fabs(dot(mapped, in.normal));
        UM_CHECK(tilt > previousTilt);
        previousTilt = tilt;
    }
    // Strength 0 is exactly the plane's normal, which is what makes the
    // amplitude knob honest at its bottom end.
    layer.normalAndStrength = Vec4(0, 0, -1, 0.0f);
    UM_CHECK_NEAR(
        length(S::mappedNormal(layer, in, Vec2(0.5f, 0.5f), tilted) - in.normal), 0.0, 1e-6);

    // A texel of exactly (0.5, 0.5, 0.5) decodes to the zero vector: the
    // plane's normal, not a NaN.
    layer.normalAndStrength = Vec4(0, 0, -1, 1.0f);
    const S::Texture2D grey = S::Texture2D::solid(2, 2, Vec4(0.5f, 0.5f, 0.5f, 1.0f));
    UM_CHECK(S::mappedNormal(layer, in, Vec2(0.5f, 0.5f), grey) == layer.normalAndStrength.xyz());
}

static void testAFlatHeightFieldMarchesNowhere() {
    // THE DEGENERATE CASE IS A NO-OP, and that is why offering the
    // normal-map alpha as a height source is safe: an alpha of 1
    // everywhere describes a flat surface at the top of the volume, so the
    // first test passes and the displacement is zero. An artist who turns
    // parallax on with such a map sees no change -- not garbage.
    SceneLayerUniforms layer = flatLayer();
    layer.materialFlags = kSceneHeightFromNormalAlpha;
    layer.parallax = Vec4(0.08f, 8, 32, 8);
    const S::Texture2D normalMap = S::Texture2D::solid(8, 8, Vec4(0.5f, 0.5f, 1.0f, 1.0f));
    const S::Texture2D heightMap;
    const S::VertexOut in = fragmentAt(Vec3(0, 0, 0), Vec2(0.5f, 0.5f), layer);
    const S::ParallaxHit hit =
        S::parallaxMarch(layer, in, Vec3(0.2f, 0.1f, 0.9f), heightMap, normalMap);
    UM_CHECK(hit.hit);
    UM_CHECK(hit.uv == in.uv);
    UM_CHECK(hit.depth == 0.0f);
}

static void testTheMarchDisplacesRefinesAndIsBoundedAtGrazingAngles() {
    SceneLayerUniforms layer = flatLayer();
    layer.materialFlags = kSceneHasHeightMap;
    layer.parallax = Vec4(0.1f, 8, 32, 8);

    // A ramp: height falls from 1 at u = 0 to 0 at u = 1, so a ray moving
    // in u meets the surface partway.
    S::Texture2D ramp;
    ramp.width = 64;
    ramp.height = 1;
    for (int x = 0; x < 64; ++x) {
        const float h = 1.0f - static_cast<float>(x) / 63.0f;
        ramp.texels.push_back(Vec4(h, h, h, 1.0f));
    }
    const S::Texture2D normalMap = S::Texture2D::solid(2, 2, Vec4(0.5f, 0.5f, 1.0f, 1.0f));
    const S::VertexOut in = fragmentAt(Vec3(0, 0, 0), Vec2(0.15f, 0.5f), layer);

    const S::ParallaxHit hit =
        S::parallaxMarch(layer, in, normalize(Vec3(0.6f, 0.0f, 0.8f)), ramp, normalMap);
    UM_CHECK(hit.hit);
    UM_CHECK(hit.uv.x != in.uv.x);   // it moved
    UM_CHECK(hit.depth > 0.0f);
    // THE SECANT REFINEMENT: the hit does not land on a step boundary,
    // which is the staircase every cheap parallax screenshot has on it.
    const float steps = std::min(std::max(hit.depth * 32.0f, 1.0f), 32.0f);
    UM_CHECK(std::fabs(steps - std::round(steps)) > 1e-4f);

    // THE GRAZING GUARD: the offset goes as 1/Vz, so a card seen edge on
    // would ask for an infinite sweep. Flooring Vz at 0.1 caps the total
    // at ten times the depth.
    const S::ParallaxHit grazing =
        S::parallaxMarch(layer, in, Vec3(0.999f, 0.0f, 0.0001f), ramp, normalMap);
    UM_CHECK(std::fabs(grazing.uv.x - in.uv.x) <= 10.0f * layer.parallax.x + 1e-4f);
}

static void testSelfShadowRefusesALightBelowTheSurface() {
    SceneLayerUniforms layer = flatLayer();
    layer.materialFlags = kSceneHasHeightMap;
    layer.parallax = Vec4(0.1f, 8, 32, 8);
    const S::Texture2D flat = S::Texture2D::solid(4, 4, Vec4(1, 1, 1, 1));
    const S::Texture2D normalMap = S::Texture2D::solid(2, 2, Vec4(0.5f, 0.5f, 1.0f, 1.0f));
    // A LIGHT BELOW THE SURFACE RETURNS 1: its N.L is already negative, so
    // the shaped Lambert has taken the contribution away, and darkening it
    // again would be the same fact counted twice -- a terminator that is a
    // hard black line instead of a rolled edge.
    UM_CHECK(S::parallaxSelfShadow(layer, Vec2(0.5f, 0.5f), 0.5f, Vec3(0, 0, -1), flat, normalMap) ==
             1.0f);
    // At the very top of the volume there is nothing above to cast.
    UM_CHECK(S::parallaxSelfShadow(layer, Vec2(0.5f, 0.5f), 0.0f, Vec3(0, 0, 1), flat, normalMap) ==
             1.0f);
}


static void testShadowsOnlyComeFromBlockersBetweenTheSurfaceAndTheLight() {
    SceneLightParams params = pointLight();
    params.world = Vec3(0, 0, -400);
    params.castsShadows = true;
    const PreparedLight prepared{params};
    SceneLightUniform light = uniformFrom(prepared, 0);
    light.setOccluders(0, 1);

    // A card standing between the surface (at z = 0) and the lamp
    // (at z = -400), facing the camera.
    SceneOccluder blocker;
    blocker.origin = Vec4(0, 0, -200, 0);
    blocker.axisU = Vec4(100, 0, 0, 0);
    blocker.axisV = Vec4(0, 100, 0, 0);
    blocker.normalAndOffset = Vec4(0, 0, 1, -200); // dot(normal, origin)
    blocker.uvRect = Vec4(0, 0, 1, 1);
    blocker.castMask = 0xFF;
    blocker.useAlpha = 0;
    const std::vector<SceneOccluder> occluders{blocker};
    const S::Texture2D atlas = S::Texture2D::solid(4, 4, Vec4(1, 1, 1, 1));

    const float shadowed = S::shadowFactor(light, occluders, Vec3(0, 0, 0), 0xFF, atlas);
    UM_CHECK(shadowed < 0.05f); // in the middle of the blocker: full shadow

    // Outside the quad: nothing between.
    UM_CHECK(S::shadowFactor(light, occluders, Vec3(400, 0, 0), 0xFF, atlas) == 1.0f);

    // A BLOCKER BEHIND THE RECEIVER casts nothing. Without the t < 1 bound
    // this is the classic fault, and it reads as a scene lit from the
    // wrong side.
    std::vector<SceneOccluder> behind{blocker};
    behind[0].origin = Vec4(0, 0, 300, 0);
    behind[0].normalAndOffset = Vec4(0, 0, 1, 300);
    UM_CHECK(S::shadowFactor(light, behind, Vec3(0, 0, 0), 0xFF, atlas) == 1.0f);

    // A FLAT 2D LIGHT CASTS NO SHADOW, and it falls out of the arithmetic
    // rather than out of a special case: depthInfluence 0 leaves the
    // direction with no z, the cards' normals are +/-z, and the
    // denominator is zero.
    SceneLightParams flatParams = params;
    flatParams.depthInfluence = 0.0f;
    SceneLightUniform flatLight = uniformFrom(PreparedLight(flatParams), 0);
    flatLight.setOccluders(0, 1);
    UM_CHECK(S::shadowFactor(flatLight, occluders, Vec3(0, 0, 0), 0xFF, atlas) == 1.0f);

    // Not asked for, or not on this surface's channels: no work, no shadow.
    SceneLightUniform off = light;
    off.castsShadows = 0;
    UM_CHECK(S::shadowFactor(off, occluders, Vec3(0, 0, 0), 0xFF, atlas) == 1.0f);
    UM_CHECK(S::shadowFactor(light, occluders, Vec3(0, 0, 0), 0x00, atlas) == 1.0f);
}

static void testTheDeepestShadowWinsRatherThanAccumulating() {
    // Two cards in front of a lamp cast ONE shadow, not a darker one:
    // light is either blocked or it is not, and adding occlusion would
    // make a crowd of sprites black out the set behind them.
    SceneLightParams params = pointLight();
    params.world = Vec3(0, 0, -400);
    params.castsShadows = true;
    SceneLightUniform one = uniformFrom(PreparedLight(params), 0);
    one.setOccluders(0, 1);
    SceneLightUniform two = one;
    two.setOccluders(0, 2);

    SceneOccluder blocker;
    blocker.origin = Vec4(0, 0, -200, 0);
    blocker.axisU = Vec4(100, 0, 0, 0);
    blocker.axisV = Vec4(0, 100, 0, 0);
    blocker.normalAndOffset = Vec4(0, 0, 1, -200);
    blocker.uvRect = Vec4(0, 0, 1, 1);
    blocker.castMask = 0xFF;
    blocker.useAlpha = 0;
    SceneOccluder second = blocker;
    second.origin = Vec4(0, 0, -100, 0);
    second.normalAndOffset = Vec4(0, 0, 1, -100);
    const std::vector<SceneOccluder> occluders{blocker, second};
    const S::Texture2D atlas = S::Texture2D::solid(4, 4, Vec4(1, 1, 1, 1));

    const float single = S::shadowFactor(one, occluders, Vec3(0, 0, 0), 0xFF, atlas);
    const float both = S::shadowFactor(two, occluders, Vec3(0, 0, 0), 0xFF, atlas);
    UM_CHECK(both >= single - 1e-6f);
}

static void testASpriteThatAsksForNothingRendersExactlyAsItDid() {
    // The promise the whole material feature hangs on, at the fragment
    // level: no flags, no lights reaching, nothing sampled but the albedo.
    SceneLayerUniforms layer = flatLayer();
    layer.receivesLight = 0;
    layer.tint = Vec4(0.5f, 0.25f, 1.0f, 0.75f);
    const S::Texture2D atlas = S::Texture2D::solid(4, 4, Vec4(0.4f, 0.8f, 0.2f, 1.0f));
    S::FragmentBindings bindings;
    bindings.atlas = &atlas;
    SceneFrameUniforms frame;
    frame.ambient = Vec4(0.9f, 0.1f, 0.1f, 0); // must not reach this pixel

    const S::VertexOut in = fragmentAt(Vec3(0, 0, 0), Vec2(0.5f, 0.5f), layer);
    const auto out = S::cardFragment(in, frame, layer, bindings);
    UM_CHECK(out.has_value());
    // Bit for bit: albedo times tint, and nothing else touched it.
    UM_CHECK(out->x == 0.4f * 0.5f);
    UM_CHECK(out->y == 0.8f * 0.25f);
    UM_CHECK(out->z == 0.2f * 1.0f);
    UM_CHECK(out->w == 1.0f * 0.75f);
}

static void testTheAdditiveTermIsScaledByAlphaSoNoGlowRectangleAppears() {
    // The one lighting bug that looks plausible in a still: the sprite
    // lights correctly and a faint rectangular glow appears around it,
    // where the artwork is transparent and the light is not.
    SceneLightParams params = pointLight();
    params.blend = SceneLightBlend::kAdditive;
    params.intensity = 4.0f;
    const PreparedLight prepared{params};
    SceneLightUniform light = uniformFrom(prepared, 0);
    const S::Texture2D curves = curveTexture(prepared);
    const std::vector<SceneLightUniform> lights{light};

    SceneLayerUniforms layer = flatLayer();
    SceneFrameUniforms frame;
    frame.ambient = Vec4(1, 1, 1, 0);
    frame.lightCount = 1;

    // A fully transparent texel -- the margin of every sprite.
    const S::Texture2D clear = S::Texture2D::solid(4, 4, Vec4(0, 0, 0, 0));
    S::FragmentBindings bindings;
    bindings.atlas = &clear;
    bindings.curves = &curves;
    bindings.lights = &lights;
    const S::VertexOut in = fragmentAt(Vec3(0, 0, -200), Vec2(0.5f, 0.5f), layer);
    const auto margin = S::cardFragment(in, frame, layer, bindings);
    UM_CHECK(margin.has_value());
    UM_CHECK(margin->x == 0.0f && margin->y == 0.0f && margin->z == 0.0f && margin->w == 0.0f);

    // And a half-transparent one catches half of it, clamped to ALPHA --
    // a premultiplied pixel carrying more colour than alpha composites as
    // if it were brighter than opaque.
    const S::Texture2D half = S::Texture2D::solid(4, 4, Vec4(0.5f, 0.5f, 0.5f, 0.5f));
    bindings.atlas = &half;
    const auto lit = S::cardFragment(in, frame, layer, bindings);
    UM_CHECK(lit.has_value());
    UM_CHECK(lit->x <= 0.5f + 1e-6f);
    UM_CHECK(lit->x > 0.5f - 1e-3f); // the light did arrive
    UM_CHECK(lit->w == 0.5f);
}

static void testSilhouetteModeDiscardsWhereTheMarchLeavesTheArtwork() {
    // The entire difference between parallax occlusion mapping and
    // SILHOUETTE parallax occlusion mapping, and it costs one comparison
    // and a discard: a ray that walked off the edge of the artwork is a
    // place where there IS no surface, so the card's rectangle stops being
    // the outline.
    SceneLayerUniforms layer = flatLayer();
    layer.materialFlags = kSceneHasHeightMap | kSceneParallaxClip;
    layer.parallax = Vec4(0.5f, 8, 32, 8); // a deep volume, so the sweep is long
    const S::Texture2D floorHeight = S::Texture2D::solid(4, 4, Vec4(0, 0, 0, 1));
    const S::Texture2D normalMap = S::Texture2D::solid(2, 2, Vec4(0.5f, 0.5f, 1.0f, 1.0f));
    const S::Texture2D atlas = S::Texture2D::solid(4, 4, Vec4(1, 1, 1, 1));
    S::FragmentBindings bindings;
    bindings.atlas = &atlas;
    bindings.heightMap = &floorHeight;
    bindings.normalMap = &normalMap;
    SceneFrameUniforms frame;
    // Off to the card's left, so the sweep runs towards u = 1.
    frame.eyeAndNear = Vec4(-400, 0, -500, 1);
    frame.lightCount = 0;

    // Near the right edge: the march leaves the tile.
    const S::VertexOut edge = fragmentAt(Vec3(0, 0, 0), Vec2(0.98f, 0.5f), layer);
    UM_CHECK(!S::cardFragment(edge, frame, layer, bindings).has_value()); // discarded

    // The middle of the card is untouched by the silhouette rule.
    const S::VertexOut middle = fragmentAt(Vec3(0, 0, 0), Vec2(0.5f, 0.5f), layer);
    UM_CHECK(S::cardFragment(middle, frame, layer, bindings).has_value());

    // Without the clip flag the same edge fragment is DRAWN, at a clamped
    // uv: the atlas packs unrelated artwork edge to edge, so a march that
    // leaves the tile must not walk into a neighbour and draw it.
    layer.materialFlags = kSceneHasHeightMap;
    UM_CHECK(S::cardFragment(edge, frame, layer, bindings).has_value());
}

static void testTheFullScreenTriangleCoversTheFrameTheRightWayUp() {
    // Three vertices, one primitive, no seam down a diagonal.
    const S::EncodeVertexOut a = S::encodeVertex(0);
    const S::EncodeVertexOut b = S::encodeVertex(1);
    const S::EncodeVertexOut c = S::encodeVertex(2);
    UM_CHECK(a.uv == Vec2(0, 0) && b.uv == Vec2(2, 0) && c.uv == Vec2(0, 2));
    // uv (0,0) is the TOP-LEFT: NDC (-1, +1). Taken the other way the
    // picture is upside down and otherwise perfect.
    UM_CHECK(a.position.x == -1.0f && a.position.y == 1.0f);
    UM_CHECK(b.position.x == 3.0f && b.position.y == 1.0f);
    UM_CHECK(c.position.x == -1.0f && c.position.y == -3.0f);

    // And the background ramp reads row 0 at the top of the frame -- taken
    // the other way the sky ends up on the floor.
    S::Texture2D ramp;
    ramp.width = 1;
    ramp.height = 2;
    ramp.texels = {Vec4(0.2f, 0.4f, 0.9f, 1.0f), Vec4(0.8f, 0.6f, 0.3f, 1.0f)};
    S::EncodeVertexOut top = a;
    top.uv = Vec2(0.5f, 0.0f);
    S::EncodeVertexOut bottom = a;
    bottom.uv = Vec2(0.5f, 1.0f);
    UM_CHECK_NEAR(S::backgroundFragment(top, ramp).z, 0.9, 1e-5);   // sky
    UM_CHECK_NEAR(S::backgroundFragment(bottom, ramp).x, 0.8, 1e-5); // ground
}

static void testTheGizmoCarriesItsOwnLightAndNeverGoesBlack() {
    SceneGizmoFrameUniforms frame;
    frame.eyeAndPad = Vec4(0, 0, -500, 0);
    const Vec4 red(1, 0.2f, 0.2f, 0.85f);
    // Facing away from the key light: dimmer, never black -- "which way is
    // round" reads from the gradient between a lit face and a merely
    // dimmer one.
    const Vec4 away = S::gizmoFragment(Vec3(0, 0, 0), -normalize(Vec3(0.4f, 0.7f, 0.6f)), red, frame);
    const Vec4 toward = S::gizmoFragment(Vec3(0, 0, 0), normalize(Vec3(0.4f, 0.7f, 0.6f)), red, frame);
    UM_CHECK(away.x >= red.x * 0.62f - 1e-5f);
    UM_CHECK(toward.x > away.x);
    // Alpha is the vertex's, untouched by the shading.
    UM_CHECK(away.w == red.w && toward.w == red.w);

    // The recentre-then-slide is a rigid 2D move in NDC: a vertex's clip
    // xy shifts by the offset times w, which after the divide is exactly
    // the offset.
    SceneGizmoVertexIn vertex(Vec3(10, 20, 30), Vec3(0, 0, -1), red);
    frame.viewProjection = Mat4::identity();
    frame.screenOffsetNDC = Vec4(0.25f, -0.5f, 0, 0);
    const Vec4 clip = S::gizmoVertexClip(vertex, frame);
    UM_CHECK_NEAR(clip.x / clip.w, 10.0 / 1.0 + 0.25, 1e-5);
    UM_CHECK_NEAR(clip.y / clip.w, 20.0 / 1.0 - 0.5, 1e-5);
}

UM_TEST_MAIN_BEGIN()
    testShapedLambertAgreesBitForBitWithTheCpuPath();
    testLightLambertAgreesBitForBitWithTheCpuPath();
    testTheFalloffSamplerDisagreesWithTheTableAndByHowMuch();
    testAttenuationAgreesWithTheCpuPathWithinThatGap();
    testAWholeLitPixelAgreesWithTheCpuCompositor();
    testTangentFrameStaysARotationAndSurvivesADegenerateBone();
    testTheSkinnedPathKeepsTheLayersLift();
    testANormalMapAtRestChangesNothingAndStrengthOnlyTilts();
    testAFlatHeightFieldMarchesNowhere();
    testTheMarchDisplacesRefinesAndIsBoundedAtGrazingAngles();
    testSelfShadowRefusesALightBelowTheSurface();
    testShadowsOnlyComeFromBlockersBetweenTheSurfaceAndTheLight();
    testTheDeepestShadowWinsRatherThanAccumulating();
    testASpriteThatAsksForNothingRendersExactlyAsItDid();
    testTheAdditiveTermIsScaledByAlphaSoNoGlowRectangleAppears();
    testSilhouetteModeDiscardsWhereTheMarchLeavesTheArtwork();
    testTheFullScreenTriangleCoversTheFrameTheRightWayUp();
    testTheGizmoCarriesItsOwnLightAndNeverGoesBlack();
UM_TEST_MAIN_END()
