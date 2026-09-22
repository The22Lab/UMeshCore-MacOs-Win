#include "umeshcore/Render/SceneShaderMath.h"

#include <algorithm>
#include <cmath>

namespace umeshcore {
namespace SceneShaderMath {

namespace {

// The shading-language intrinsics this file leans on, spelled out once so
// a transcription to MSL or HLSL is a rename rather than a rewrite.
float saturate(float v) { return std::min(std::max(v, 0.0f), 1.0f); }
float clampf(float v, float lo, float hi) { return std::min(std::max(v, lo), hi); }
float mixf(float a, float b, float t) { return a + (b - a) * t; }
Vec3 clamp3(const Vec3& v, float lo, float hi) {
    return Vec3(clampf(v.x, lo, hi), clampf(v.y, lo, hi), clampf(v.z, lo, hi));
}
float smoothstepf(float edge0, float edge1, float x) {
    const float t = saturate((x - edge0) / std::max(edge1 - edge0, 1e-20f));
    return t * t * (3.0f - 2.0f * t);
}
float rsqrtf(float v) { return 1.0f / std::sqrt(v); }

} // namespace

// ---- Texture2D ---------------------------------------------------------

Texture2D Texture2D::solid(int width, int height, const Vec4& color) {
    Texture2D texture;
    texture.width = std::max(width, 1);
    texture.height = std::max(height, 1);
    texture.texels.assign(
        static_cast<std::size_t>(texture.width) * static_cast<std::size_t>(texture.height), color);
    return texture;
}

Vec4 Texture2D::texel(int x, int y) const {
    if (texels.empty()) return Vec4(0, 0, 0, 0);
    const int cx = std::min(std::max(x, 0), width - 1);   // clamp-to-edge
    const int cy = std::min(std::max(y, 0), height - 1);
    return texels[static_cast<std::size_t>(cy) * static_cast<std::size_t>(width) +
                  static_cast<std::size_t>(cx)];
}

Vec4 Texture2D::sample(const Vec2& uv) const {
    if (texels.empty()) return Vec4(0, 0, 0, 0);
    // Texel CENTRES: a linear sampler maps u to u * width - 0.5.
    const float x = uv.x * static_cast<float>(width) - 0.5f;
    const float y = uv.y * static_cast<float>(height) - 0.5f;
    const float fx = std::floor(x);
    const float fy = std::floor(y);
    const float tx = x - fx;
    const float ty = y - fy;
    const int x0 = static_cast<int>(fx);
    const int y0 = static_cast<int>(fy);
    const Vec4 a = texel(x0, y0);
    const Vec4 b = texel(x0 + 1, y0);
    const Vec4 c = texel(x0, y0 + 1);
    const Vec4 d = texel(x0 + 1, y0 + 1);
    const Vec4 top = a * (1.0f - tx) + b * tx;
    const Vec4 bottom = c * (1.0f - tx) + d * tx;
    return top * (1.0f - ty) + bottom * ty;
}

// ---- Vertex stages -----------------------------------------------------

TangentFrame tangentFrame(const Vec3& n, const Vec3& tRaw, float handed) {
    // Projected back into the plane before normalising. A no-op for a chain
    // that really is in-plane, and the cheap insurance that keeps a
    // degenerate or numerically drifted bone from tilting the frame out of
    // the card.
    Vec3 t = tRaw - n * dot(n, tRaw);
    const float lengthSquared = dot(t, t);
    // A bone scaled to nothing leaves no direction to recover. Falling back
    // to the plane's own x axis lights it flat rather than by a NaN, which
    // shows up as a black triangle that comes and goes with the pose.
    t = (lengthSquared > 1e-12f) ? t * rsqrtf(lengthSquared) : Vec3(1.0f, 0.0f, 0.0f);
    // `cross(N, T)` is image-up for a right-handed frame. The sign carries
    // the mirroring: a negatively scaled card draws its artwork reversed,
    // and a basis that is not told so lights the relief from the wrong side.
    return TangentFrame{t, cross(n, t) * handed};
}

VertexOut cardVertex(
    const SceneVertexIn& vertex, const SceneFrameUniforms& frame, const SceneLayerUniforms& layer) {
    VertexOut out;
    const Vec3 world = vertex.world;
    out.position = frame.viewProjection * Vec4(world, 1.0f);
    out.world = world;
    out.uv = vertex.uv;
    out.normal = layer.normalAndStrength.xyz();
    const TangentFrame basis =
        tangentFrame(out.normal, layer.tangentAndSign.xyz(), layer.tangentAndSign.w);
    out.tangent = basis.tangent;
    out.bitangent = basis.bitangent;
    return out;
}

VertexOut skinnedVertex(
    const SceneSkinnedVertexIn& vertex, const SceneFrameUniforms& frame,
    const std::vector<Mat4>& palette, const SceneLayerUniforms& layer) {
    const Vec4 bind(vertex.bindLocal.x, vertex.bindLocal.y, 0.0f, 1.0f);

    // NO BRANCH ON THE WEIGHT TOTAL. Slot zero of the palette is the
    // identity and an unweighted vertex is written as one influence of
    // weight 1 on it, so the unbound case is the same arithmetic as every
    // other. A branch here would diverge inside the hottest loop.
    Vec3 world = Vec3::zero();
    // THE ARTWORK'S OWN AXES, blended by the same weights as the position.
    // w = 0, because these are DIRECTIONS: the fourth column is the chain's
    // accumulated translation, and letting it in would drag the tangent
    // towards wherever the sprite happens to sit in the world.
    Vec3 tangentRaw = Vec3::zero();
    Vec3 bitangentRaw = Vec3::zero();
    for (int i = 0; i < 4; ++i) {
        const float weight = vertex.weights[i];
        if (weight <= 0.0f) continue;
        const Mat4& bone = palette[vertex.slots[i]];
        const Vec4 moved = bone * bind;
        // Divided by w, exactly as `MatrixUtilities::transformPoint` does.
        // The bone matrices keep w at one so it is a no-op -- and it is
        // done anyway, because matching the CPU exactly costs nothing here
        // and assuming it does not is how two paths drift.
        const float w = std::fabs(moved.w) < 1e-4f ? 1.0f : moved.w;
        world += (moved.xyz() / w) * weight;
        tangentRaw += (bone * Vec4(1.0f, 0.0f, 0.0f, 0.0f)).xyz() * weight;
        bitangentRaw += (bone * Vec4(0.0f, 1.0f, 0.0f, 0.0f)).xyz() * weight;
    }

    VertexOut out;
    out.position = frame.viewProjection * Vec4(world, 1.0f);
    out.world = world;
    out.uv = vertex.uv;
    out.normal = layer.normalAndStrength.xyz();
    // HANDEDNESS FROM THE SKINNED PAIR, not from the layer's: a sprite can
    // be mirrored by its own scale inside a layer that is not, and a bone
    // chain can mirror it again.
    const float handed = dot(cross(tangentRaw, bitangentRaw), out.normal) < 0.0f ? -1.0f : 1.0f;
    const TangentFrame basis = tangentFrame(out.normal, tangentRaw, handed);
    out.tangent = basis.tangent;
    out.bitangent = basis.bitangent;
    return out;
}

// ---- Lighting ----------------------------------------------------------

float sampleFalloff(const Texture2D& curves, std::uint32_t row, float u) {
    const float rows = static_cast<float>(curves.height);
    return curves
        .sample(Vec2(clampf(u, 0.0f, 1.0f), (static_cast<float>(row) + 0.5f) / rows))
        .x;
}

float lightAttenuation(
    const SceneLightUniform& light, const Vec3& point, const Texture2D& curves) {
    if (light.kind == 2u) return 1.0f; // directional

    const Vec3 origin = light.originAndRadius.xyz();
    const float radius = std::max(light.originAndRadius.w, 1e-6f);
    const float innerRadius = light.directionAndInner.w;
    const float band = light.tintAndBand.w;

    Vec3 delta = point - origin;
    // THE WHOLE OF 2.5D.
    delta.z *= light.cones.z;
    const float distance = length(delta);
    if (distance >= radius) return 0.0f;

    float radial;
    if (distance <= innerRadius) {
        radial = 1.0f;
    } else if (band > 1e-6f) {
        radial = sampleFalloff(curves, light.falloffRow, (distance - innerRadius) / band);
    } else {
        radial = 0.0f;
    }

    if (light.kind != 1u || distance <= 1e-6f) return radial; // not a spot

    const float cosine = dot(delta / distance, light.directionAndInner.xyz());
    const float cosOuter = light.cones.y;
    const float cosInner = light.cones.x;
    if (cosine <= cosOuter) return 0.0f;
    if (cosine >= cosInner) return radial;
    const float t = (cosine - cosOuter) / std::max(cosInner - cosOuter, 1e-6f);
    return radial * (t * t * (3.0f - 2.0f * t));
}

float shapedLambert(float ndotl, float smoothness, float contrast) {
    float shaped = (smoothness <= 0.0f)
                       ? std::max(0.0f, ndotl)
                       : std::max(0.0f, (ndotl + smoothness) / (1.0f + smoothness));
    if (contrast > 0.0f) {
        shaped = clampf(0.5f + (shaped - 0.5f) * (1.0f + contrast), 0.0f, 1.0f);
    }
    return shaped;
}

float lightLambert(
    const SceneLightUniform& light, const Vec3& point, const Vec3& normal, float smoothness,
    float contrast) {
    // THE INFLUENCE STAYS OUTERMOST, and its early-out stays first.
    const float influence = light.cones.w;
    if (influence <= 0.0f) return 1.0f;
    Vec3 toLight;
    if (light.kind == 2u) {
        toLight = -light.directionAndInner.xyz();
    } else {
        Vec3 delta = light.originAndRadius.xyz() - point;
        delta.z *= light.cones.z;
        const float len = length(delta);
        if (len <= 1e-6f) return 1.0f;
        toLight = delta / len;
    }
    const float shaped = shapedLambert(dot(normal, toLight), smoothness, contrast);
    return 1.0f - influence + influence * shaped;
}

// ---- Normal mapping ----------------------------------------------------

Vec3 mappedNormal(
    const SceneLayerUniforms& layer, const VertexOut& in, const Vec2& uv,
    const Texture2D& normalMap) {
    const Vec4 sampled = normalMap.sample(uv);
    // The standard tangent-space decode: the texture stores [-1, 1] folded
    // into [0, 1], so a flat surface is the familiar lavender.
    Vec3 tangentNormal = Vec3(sampled.x, sampled.y, sampled.z) * 2.0f - Vec3(1, 1, 1);
    tangentNormal.x *= layer.normalAndStrength.w;
    tangentNormal.y *= layer.normalAndStrength.w;
    const Vec3 mapped = in.tangent * tangentNormal.x + in.bitangent * tangentNormal.y +
                        in.normal * tangentNormal.z;
    const float lengthSquared = dot(mapped, mapped);
    // A texel of exactly (0.5, 0.5, 0.5) decodes to the zero vector, and a
    // strength of zero flattens any texel to it. Falling back to the
    // plane's own normal lights that pixel as the card rather than by a
    // NaN, which renders as a black speck that moves with the light.
    return (lengthSquared > 1e-12f) ? mapped * rsqrtf(lengthSquared)
                                    : layer.normalAndStrength.xyz();
}

// ---- Parallax ----------------------------------------------------------

float heightAt(
    const SceneLayerUniforms& layer, const Vec2& uv, const Texture2D& heightMap,
    const Texture2D& normalMap) {
    float height;
    if ((layer.materialFlags & kSceneHasHeightMap) != 0u) {
        height = heightMap.sample(uv).x;
    } else {
        height = normalMap.sample(uv).w;
    }
    return ((layer.materialFlags & kSceneHeightInverted) != 0u) ? (1.0f - height) : height;
}

Vec3 viewTangent(const VertexOut& in, const Vec3& eye) {
    const Vec3 v = normalize(eye - in.world);
    return Vec3(dot(v, in.tangent), dot(v, in.bitangent), dot(v, in.normal));
}

ParallaxHit parallaxMarch(
    const SceneLayerUniforms& layer, const VertexOut& in, const Vec3& viewTangentDir,
    const Texture2D& heightMap, const Texture2D& normalMap) {
    ParallaxHit result{in.uv, 0.0f, true};

    const float depth = layer.parallax.x;
    const float zGuard = std::max(viewTangentDir.z, 0.1f);
    float steps = mixf(layer.parallax.z, layer.parallax.y, saturate(viewTangentDir.z));
    steps = clampf(steps, 1.0f, static_cast<float>(kSceneMaxParallaxSteps));
    const std::uint32_t stepCount = static_cast<std::uint32_t>(steps);

    // Derived rather than pattern-matched: descending a fraction `d` of the
    // volume takes `d / Vz` along the ray, and the ray goes INTO the
    // surface, which is `-V`. So the tangent displacement is
    // `-V.xy * d / Vz`, and the v component flips again on its way into uv
    // -- leaving `(-Vx, +Vy)`.
    const Vec2 totalOffset =
        Vec2(-viewTangentDir.x, viewTangentDir.y) * (depth / zGuard);
    const Vec2 deltaUV = totalOffset / static_cast<float>(stepCount);
    const float deltaDepth = 1.0f / static_cast<float>(stepCount);

    Vec2 current = in.uv;
    float rayDepth = 0.0f;
    float surfaceDepth = 1.0f - heightAt(layer, current, heightMap, normalMap);
    // Already solid at the fragment's own texel: nothing to march. This is
    // the flat-alpha case, and it exits having moved nothing.
    bool hit = (surfaceDepth <= 0.0f);
    std::uint32_t taken = 0u;

    for (std::uint32_t i = 0u; i < kSceneMaxParallaxSteps; ++i) {
        if (hit || i >= stepCount) break;
        current += deltaUV;
        rayDepth += deltaDepth;
        taken += 1u;
        surfaceDepth = 1.0f - heightAt(layer, current, heightMap, normalMap);
        hit = (rayDepth >= surfaceDepth);
    }

    if (hit && taken > 0u) {
        const Vec2 previous = current - deltaUV;
        // Signed gaps between the ray and the surface, straddling the
        // crossing: `after` is at or below zero, `before` is above it.
        const float after = surfaceDepth - rayDepth;
        const float beforeSurface = 1.0f - heightAt(layer, previous, heightMap, normalMap);
        const float before = beforeSurface - (rayDepth - deltaDepth);
        const float span = after - before;
        // A span of zero means the two samples agree, so either endpoint is
        // the answer and the division is the only thing that could go wrong.
        const float weight = (std::fabs(span) > 1e-8f) ? clampf(after / span, 0.0f, 1.0f) : 0.0f;
        result.uv = previous * weight + current * (1.0f - weight);
        result.depth = clampf(rayDepth - weight * deltaDepth, 0.0f, 1.0f);
    } else {
        result.uv = current;
        result.depth = rayDepth;
    }
    result.hit = hit;
    return result;
}

float parallaxSelfShadow(
    const SceneLayerUniforms& layer, const Vec2& uv, float depth, const Vec3& lightTangent,
    const Texture2D& heightMap, const Texture2D& normalMap) {
    if (lightTangent.z <= 0.0f || depth <= 0.0f) return 1.0f;

    const float steps = clampf(layer.parallax.w, 1.0f, static_cast<float>(kSceneMaxParallaxShadowSteps));
    const std::uint32_t stepCount = static_cast<std::uint32_t>(steps);
    const float zGuard = std::max(lightTangent.z, 0.1f);
    // Rise out of the volume in equal fractions, sweeping uv by the same
    // geometry the view march used -- with the v flip once more.
    const float riseStep = depth / static_cast<float>(stepCount);
    const Vec2 deltaUV =
        Vec2(lightTangent.x, -lightTangent.y) * ((layer.parallax.x / zGuard) * riseStep);

    float occlusion = 0.0f;
    float rayDepth = depth;
    Vec2 current = uv;
    for (std::uint32_t i = 0u; i < kSceneMaxParallaxShadowSteps; ++i) {
        if (i >= stepCount) break;
        rayDepth -= riseStep;
        current += deltaUV;
        if (rayDepth <= 0.0f) break;
        const float surfaceDepth = 1.0f - heightAt(layer, current, heightMap, normalMap);
        if (surfaceDepth < rayDepth) {
            // SOFTNESS FROM THE DISTANCE, not from more rays: a blocker
            // found near the start is a wall right beside the crevice and
            // shadows it hard; one found at the end is far away and its
            // edge has spread.
            const float nearness = 1.0f - static_cast<float>(i) / static_cast<float>(stepCount);
            occlusion = std::max(occlusion, (rayDepth - surfaceDepth) * nearness);
        }
    }
    return clampf(1.0f - occlusion, 0.0f, 1.0f);
}

// ---- Shadows -----------------------------------------------------------

float shadowFactor(
    const SceneLightUniform& light, const std::vector<SceneOccluder>& occluders, const Vec3& point,
    std::uint32_t shadowedMask, const Texture2D& shadowAtlas) {
    if (light.castsShadows == 0u || light.occluderCount == 0u) return 1.0f;
    if ((light.mask & shadowedMask) == 0u) return 1.0f;

    Vec3 toLight;
    if (light.kind == 2u) {
        // A directional light has no position, so its occluders are tested
        // along its axis, far enough that anything in the scene is between.
        toLight = -light.directionAndInner.xyz() * 1.0e5f;
    } else {
        toLight = light.originAndRadius.xyz() - point;
        toLight.z *= light.cones.z;
    }

    float occlusion = 0.0f;
    for (std::uint32_t i = 0; i < light.occluderCount; ++i) {
        const SceneOccluder& blocker = occluders[light.occluderStart + i];
        const Vec3 normal = blocker.normalAndOffset.xyz();
        const float denominator = dot(normal, toLight);
        // Parallel to the blocker, or lying in its plane: nothing crosses.
        if (std::fabs(denominator) < 1e-6f) continue;

        const float t = (blocker.normalAndOffset.w - dot(normal, point)) / denominator;
        // STRICTLY BETWEEN THE SURFACE AND THE LIGHT. Without the upper
        // bound a blocker BEHIND the receiver shadows it -- the classic
        // fault, which reads as a scene lit from the wrong side; without
        // the lower one a surface shadows itself at every grazing angle.
        if (t <= 1e-3f || t >= 1.0f) continue;

        const Vec3 relative = (point + toLight * t) - blocker.origin.xyz();
        const Vec3 axisU = blocker.axisU.xyz();
        const Vec3 axisV = blocker.axisV.xyz();
        const float uu = dot(axisU, axisU);
        const float uv = dot(axisU, axisV);
        const float vv = dot(axisV, axisV);
        const float determinant = uu * vv - uv * uv;
        if (std::fabs(determinant) < 1e-9f) continue; // degenerate card
        const float ru = dot(relative, axisU);
        const float rv = dot(relative, axisV);
        const float a = (ru * vv - rv * uv) / determinant;
        const float b = (rv * uu - ru * uv) / determinant;
        if (std::fabs(a) > 1.0f || std::fabs(b) > 1.0f) continue;

        // The artwork's own outline. v is measured DOWN the image while
        // axisV points UP it, which is the same flip the cards' corners
        // make.
        float coverage = 1.0f;
        if (blocker.useAlpha != 0u) {
            const Vec2 local((a + 1.0f) * 0.5f, (1.0f - b) * 0.5f);
            const Vec2 uvInAtlas(
                blocker.uvRect.x + local.x * blocker.uvRect.z,
                blocker.uvRect.y + local.y * blocker.uvRect.w);
            coverage = shadowAtlas.sample(uvInAtlas).x;
        }
        // SOFTNESS FROM THE EDGE, NOT FROM MULTISAMPLING.
        const float edge = std::min(1.0f - std::fabs(a), 1.0f - std::fabs(b));
        coverage *= smoothstepf(0.0f, 0.04f, edge);

        // THE DEEPEST SHADOW WINS rather than the shadows accumulating. Two
        // cards in front of a lamp cast one shadow, not a darker one.
        occlusion = std::max(occlusion, coverage);
        if (occlusion >= 0.999f) break;
    }
    return 1.0f - occlusion;
}

// ---- Fragment ----------------------------------------------------------

std::optional<Vec4> cardFragment(
    const VertexOut& in, const SceneFrameUniforms& frame, const SceneLayerUniforms& layer,
    const FragmentBindings& bindings) {
    const Texture2D empty;
    const Texture2D& atlas = bindings.atlas ? *bindings.atlas : empty;
    const Texture2D& curves = bindings.curves ? *bindings.curves : empty;
    const Texture2D& normalMap = bindings.normalMap ? *bindings.normalMap : empty;
    const Texture2D& shadowAtlas = bindings.shadowAtlas ? *bindings.shadowAtlas : empty;
    const Texture2D& heightMap = bindings.heightMap ? *bindings.heightMap : empty;
    const std::vector<SceneLightUniform> noLights;
    const std::vector<SceneOccluder> noOccluders;
    const std::vector<SceneLightUniform>& lights = bindings.lights ? *bindings.lights : noLights;
    const std::vector<SceneOccluder>& occluders =
        bindings.occluders ? *bindings.occluders : noOccluders;

    // THE PARALLAX MARCH FIRST, because it decides WHICH TEXEL this
    // fragment is. The albedo, the normal map and the self-shadow all have
    // to agree on that; sampling the artwork at `in.uv` and only then
    // displacing would light one texel and paint another.
    Vec2 surfaceUV = in.uv;
    float parallaxDepth = 0.0f;
    bool parallaxHit = true;
    const bool marching = (layer.materialFlags & kSceneParallaxAny) != 0u;
    if (marching) {
        const Vec3 view = viewTangent(in, frame.eyeAndNear.xyz());
        // THE BACK OF A CARD IS FLAT, and that is the honest answer rather
        // than a shortcut: the relief stands out of the FRONT, so seen from
        // behind there is nothing standing towards the viewer to march
        // through. Marching anyway would carve it inwards, which is a
        // surface nobody authored.
        if (view.z > 0.0f) {
            const ParallaxHit march = parallaxMarch(layer, in, view, heightMap, normalMap);
            surfaceUV = march.uv;
            parallaxDepth = march.depth;
            parallaxHit = march.hit;
        }
    }

    // A ray that found no surface, or walked off the edge of the artwork,
    // is a place where there IS nothing -- so the fragment goes, and the
    // card's rectangle stops being the outline.
    if ((layer.materialFlags & kSceneParallaxClip) != 0u) {
        if (!parallaxHit || surfaceUV.x < 0.0f || surfaceUV.y < 0.0f || surfaceUV.x > 1.0f ||
            surfaceUV.y > 1.0f) {
            return std::nullopt; // discard_fragment()
        }
    }

    // CLAMPED, NOT WRAPPED: the atlas packs unrelated artwork edge to edge,
    // so a march that leaves the card's own tile does not fade into a
    // neighbour -- it walks into it and draws it. And it is what the normal
    // map and the self-shadow read too, because whatever texel ends up
    // PAINTED is the texel that has to be lit and shadowed.
    const Vec2 albedoUV(clampf(surfaceUV.x, 0.0f, 1.0f), clampf(surfaceUV.y, 0.0f, 1.0f));
    const Vec2 atlasUV(
        layer.uvRect.x + albedoUV.x * layer.uvRect.z,
        layer.uvRect.y + albedoUV.y * layer.uvRect.w);
    const Vec4 sampled = atlas.sample(atlasUV);
    Vec4 albedo(
        sampled.x * layer.tint.x, sampled.y * layer.tint.y, sampled.z * layer.tint.z,
        sampled.w * layer.tint.w);

    // Cheap ambient occlusion: how far down the ray landed. ON THE ALBEDO
    // and before the lights, because it stands in for the light that never
    // reaches the bottom of a crack; applied to the lit result it would
    // also dim the highlights on the ridges, the one place the relief is
    // supposed to be brightest. PREMULTIPLIED ARTWORK, so only rgb is
    // scaled: touching alpha would make a deep crevice transparent rather
    // than dark.
    if (marching && layer.material.z > 0.0f) {
        const float ao = 1.0f - layer.material.z * saturate(parallaxDepth);
        albedo.x *= ao;
        albedo.y *= ao;
        albedo.z *= ao;
    }

    if (layer.receivesLight == 0u) return albedo;

    Vec3 factor = frame.ambient.xyz();
    Vec3 additive = Vec3::zero();
    // THE BRANCH IS THE PROMISE, and it is also the cheap path: a sprite
    // with no map costs no texture fetch and no normalise. The old path is
    // not merely equivalent, it is untouched.
    Vec3 normal = layer.normalAndStrength.xyz();
    if ((layer.materialFlags & kSceneHasNormalMap) != 0u) {
        normal = mappedNormal(layer, in, albedoUV, normalMap);
    }
    const bool selfShadowing = marching && (layer.materialFlags & kSceneParallaxSelfShadow) != 0u;

    for (std::uint32_t i = 0; i < frame.lightCount; ++i) {
        const SceneLightUniform& light = lights[i];
        if ((light.mask & layer.lightMask) == 0u) continue;

        const float a = lightAttenuation(light, in.world, curves);
        // A light that reaches nothing is a no-op in every blend.
        if (a <= 0.0f) continue;
        // MULTIPLIED INTO `reach`, NEVER INTO `factor`. `factor` starts at
        // the ambient, so darkening it would let a shadow take a surface to
        // black -- and a 2D set has no bounce light to rescue it.
        const float shadow =
            shadowFactor(light, occluders, in.world, layer.shadowedMask, shadowAtlas);
        float selfShadow = 1.0f;
        if (selfShadowing) {
            Vec3 toLight;
            if (light.kind == 2u) {
                toLight = -light.directionAndInner.xyz();
            } else {
                Vec3 delta = light.originAndRadius.xyz() - in.world;
                // THE LIGHT'S 2.5D POSITION, not its true one -- the same
                // flattening the attenuation and the lambert apply.
                delta.z *= light.cones.z;
                const float len = length(delta);
                toLight = (len > 1e-6f) ? (delta / len) : Vec3(0.0f, 0.0f, 1.0f);
            }
            const Vec3 lightTangent(
                dot(toLight, in.tangent), dot(toLight, in.bitangent), dot(toLight, in.normal));
            selfShadow = parallaxSelfShadow(
                layer, albedoUV, parallaxDepth, lightTangent, heightMap, normalMap);
        }
        const float reach =
            a * shadow * selfShadow *
            lightLambert(light, in.world, normal, layer.material.x, layer.material.y);
        const Vec3 emission = light.tintAndBand.xyz() * reach;

        switch (light.blend) {
            case 0u: factor += emission; break;   // normal
            case 1u: additive += emission; break; // additive
            case 2u:                              // multiply
                factor = factor * (Vec3(1.0f - reach, 1.0f - reach, 1.0f - reach) +
                                   light.tintAndBand.xyz() * reach);
                break;
            default: { // screen
                const Vec3 one(1, 1, 1);
                factor = one - (one - factor) * (one - clamp3(emission, 0.0f, 1.0f));
                break;
            }
        }
    }

    const float alpha = albedo.w;
    const Vec3 lit = Vec3(albedo.x, albedo.y, albedo.z) * factor + additive * alpha;
    // Clamped to ALPHA, not to 1: a premultiplied pixel carrying more
    // colour than alpha composites as if it were brighter than opaque.
    const Vec3 clamped = clamp3(lit, 0.0f, alpha);
    return Vec4(clamped.x, clamped.y, clamped.z, alpha);
}

// ---- Encode and background ---------------------------------------------

EncodeVertexOut encodeVertex(std::uint32_t vertexID) {
    const Vec2 uv(
        static_cast<float>((vertexID << 1) & 2u), static_cast<float>(vertexID & 2u));
    EncodeVertexOut out;
    out.uv = uv;
    out.position = Vec4(uv.x * 2.0f - 1.0f, uv.y * -2.0f + 1.0f, 0.0f, 1.0f);
    return out;
}

Vec4 encodeFragment(const EncodeVertexOut& in, const Texture2D& source) {
    return source.sample(in.uv);
}

Vec4 backgroundFragment(const EncodeVertexOut& in, const Texture2D& ramp) {
    return ramp.sample(Vec2(0.5f, in.uv.y));
}

// ---- Gizmo -------------------------------------------------------------

Vec4 gizmoVertexClip(const SceneGizmoVertexIn& vertex, const SceneGizmoFrameUniforms& frame) {
    Vec4 clip = frame.viewProjection * Vec4(vertex.world, 1.0f);
    clip.x += frame.screenOffsetNDC.x * clip.w;
    clip.y += frame.screenOffsetNDC.y * clip.w;
    return clip;
}

Vec4 gizmoFragment(
    const Vec3& world, const Vec3& normalIn, const Vec4& color,
    const SceneGizmoFrameUniforms& frame) {
    const Vec3 normal = normalize(normalIn);
    const Vec3 key = normalize(Vec3(0.4f, 0.7f, 0.6f));
    const float lambert = saturate(dot(normal, key));
    // Floor around 0.6 rather than 0: the far side of a cylinder is never
    // black, because "which way is round" only reads from the gradient
    // between a lit face and a merely-dimmer one.
    const float shade = mixf(0.62f, 1.0f, lambert);

    const Vec3 viewDir = normalize(frame.eyeAndPad.xyz() - world);
    const float rim = std::pow(1.0f - saturate(dot(normal, viewDir)), 2.0f);

    const Vec3 rgb = Vec3(color.x, color.y, color.z) * shade + Vec3(1, 1, 1) * (rim * 0.35f);
    return Vec4(rgb.x, rgb.y, rgb.z, color.w);
}

} // namespace SceneShaderMath
} // namespace umeshcore
