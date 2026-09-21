#include <metal_stdlib>
using namespace metal;

// ── THE ONE GEOMETRIC ROUTE, NOW ON THE GPU ─────────────────────────────
//
// `CLAUDE.md` says every mesh mutation goes through one path, and Scene says
// one renderer draws both the canvas and the export. Moving to Metal keeps
// both: this shader draws into an offscreen texture, the canvas presents that
// texture and the exporter reads it back. Two consumers, one render pass, one
// piece of arithmetic.
//
// Everything here is mirrored by `Editor/gpu_mirror.py` and checked against
// `Editor/lighting_mirror.py`, which stays the normative reference for what a
// lit pixel is worth. There is no Metal toolchain in the container this was
// written in, so the mirror is what stands in for compiling it.

// ── Structs shared with Swift ───────────────────────────────────────────
//
// Hand-written on both sides, as the rest of this project already does, and
// kept in step by `verify_scene_gpu_transcription.py` rather than by a
// bridging header. A bridging header would be better and is a change to the
// Xcode project rather than to code, so it is left for the Mac.
//
// LAYOUT RULES THAT BITE: Metal aligns float3 to 16 bytes and so does
// SIMD3<Float>, which is why the padding below is explicit and why every
// struct is a multiple of 16. A float3 followed by a float in Swift packs into
// one 16-byte slot ONLY if written as a float4; spelled as two fields they
// occupy 32. The harness checks the sizes rather than trusting the reading.

struct SceneFrameUniforms {
    float4x4 viewProjection;
    float4   eyeAndNear;        // xyz eye, w nearZ
    float4   ambient;           // rgb ambient, w unused
    uint     lightCount;
    uint     pad0;
    uint     pad1;
    uint     pad2;
};

struct SceneLightUniform {
    float4 originAndRadius;     // xyz world origin, w radius
    float4 directionAndInner;   // xyz unit direction, w inner radius
    float4 tintAndBand;         // rgb colour * intensity, w fade band width
    float4 cones;               // x cosInner, y cosOuter, z depthInfluence,
                                // w normalInfluence
    uint   kind;                // 0 point, 1 spot, 2 directional
    uint   blend;               // 0 normal, 1 additive, 2 multiply, 3 screen
    uint   mask;                // 8 channel bits, in the low byte
    uint   falloffRow;          // which row of the falloff texture is this
                                // light's curve
    uint   occluderStart;       // this light's slice of the occluder buffer,
    uint   occluderCount;       // culled on the CPU by radius and cast mask
    uint   castsShadows;        // 0 unless the artist asked; off by default
    uint   pad0;
};

struct SceneOccluder {
    float4 origin;              // xyz the quad's centre in world space
    float4 axisU;               // xyz half-extent along the artwork's +x
    float4 axisV;               // xyz half-extent along the artwork's +y (UP)
    float4 normalAndOffset;     // xyz unit plane normal, w dot(normal, origin)
    float4 uvRect;              // its alpha tile in the shadow atlas
    uint   castMask;
    uint   useAlpha;            // 0 when the quad IS the silhouette
    uint   pad0;
    uint   pad1;
};

struct SceneLayerUniforms {
    float4 uvRect;              // atlas placement: x, y, width, height
    float4 tint;                // rgba, premultiplied on the way in
    uint   lightMask;           // the channels this surface receives on
    uint   receivesLight;       // 0 or 1
    uint   materialFlags;       // bit 0: a normal map is bound at texture(2)
    uint   shadowedMask;        // whose shadows may darken this surface
    float4 normalAndStrength;   // xyz plane normal in world space,
                                // w normal-map strength
    float4 tangentAndSign;      // xyz image +x in world space,
                                // w handedness for the bitangent
    float4 material;            // x smoothness, y contrast,
                                // z parallax occlusion, w spare
    float4 parallax;            // x depth (uv), y min steps, z max steps,
                                // w self-shadow steps
};

// Bit 0 of `materialFlags`. A FLAG AND NOT A TEST ON STRENGTH, because the
// promise is that a sprite with no normal map renders bit for bit as it did
// before. A flat lavender texel is bit-identical on a card facing the camera
// and NOT on a tilted one -- measured, 826 of 4 000 random tilted cards move
// by up to 1.2e-07. See `SceneLayerUniforms.materialFlags` for the whole of it.
constant uint kSceneHasNormalMap = 1u;

// ── The parallax bits ───────────────────────────────────────────────────
//
// FLAGS AND NOT TESTS ON THE NUMBERS, for the same reason bit 0 is. A surface
// with no height field must take a path where nothing is sampled, nothing is
// marched and nothing is normalised -- not a path where the march runs against
// a neutral texture and happens to land back where it started. The second one
// is a rounding error per pixel on every project that predates this feature,
// and nobody would ever report it.
//
// The Swift half of these lives in `SceneMetalRenderer` as `hasHeightMapFlag`
// and friends, one name per bit on each side.

// A real height texture is bound at texture(4) and may be sampled.
constant uint kSceneHasHeightMap = 2u;
// No height texture, but the normal map carries height in its alpha. The two
// are mutually exclusive and the renderer never sets both.
constant uint kSceneHeightFromNormalAlpha = 4u;
// Throw away fragments whose ray found no surface, or left the artwork. This
// is what makes the OUTLINE follow the relief instead of staying a rectangle.
constant uint kSceneParallaxClip = 8u;
// March a second ray towards each light, from the hit point.
constant uint kSceneParallaxSelfShadow = 16u;
// The map stores depth (near is bright) rather than height.
constant uint kSceneHeightInverted = 32u;

// "Is there anything to march against at all." The one test the fragment
// shader takes, so that the cheap path is decided once rather than by three
// separate conditions that could disagree.
constant uint kSceneParallaxAny = kSceneHasHeightMap | kSceneHeightFromNormalAlpha;

// The loop bound the compiler can see. The real step count is a uniform and is
// always <= this; a loop whose trip count is entirely unknown cannot be
// unrolled or bounded, and on a fragment shader that is the difference between
// a march and a hang. `SceneMetalRenderer.maxParallaxSteps` is the same number
// on the Swift side, and it is what clamps the uniform.
constant uint kSceneMaxParallaxSteps = 128u;
// The self-shadow march is shorter for the same reason a shadow is cheaper
// than a surface: it answers yes or no, not where.
constant uint kSceneMaxParallaxShadowSteps = 32u;

struct SceneVertexIn {
    float3 world;
    float2 uv;
};

struct SceneSkinnedVertexIn {
    // The vertex in its BIND position, in sprite-local space. It never
    // changes while the rig animates -- the pose lives entirely in the
    // palette -- so this buffer is uploaded once and reused every frame. That
    // is the whole reason playback stops costing what it costs: today the
    // pose invalidates every cache keyed on it, because the pose is baked
    // into the vertices.
    float2 bindLocal;
    float2 uv;
    // Four slots into the palette and four weights that SUM TO ONE. The
    // normalisation happens on the CPU, in `SceneSkinPalette`, and it is not
    // tidiness: folding the sprite's bind affine into the palette is only
    // correct when the weights sum to one, and the data does not guarantee it.
    ushort4 slots;
    float4 weights;
};

struct SceneVertexOut {
    float4 position [[position]];
    // WORLD POSITION AS A VARYING. This is the whole reason the lattice goes
    // away. The CPU compositor evaluated lighting on a screen-space grid and
    // interpolated between the nodes, because reconstructing the world point
    // per pixel was the expensive part. Here the hardware interpolates it --
    // perspective-correctly, for free, exactly -- and the shading runs per
    // pixel with no grid and no error to bound.
    float3 world;
    float2 uv;
    // THE TANGENT FRAME, AS VARYINGS, so that one fragment shader serves both
    // a flat card and a skinned sprite.
    //
    // For a card these are constant across the draw and could have been read
    // straight out of the layer uniform. They are varyings anyway, because a
    // rig sprite's frame is NOT constant: each bone turns its own patch of the
    // sprite, and the frame has to turn with it. Reading the layer's frame for
    // a rig is not a small error -- a bone rotated 90 degrees leaves the relief
    // pinned to the layer's axes, so the highlight SLIDES ACROSS the sprite as
    // the arm swings instead of turning with it. It is exactly zero at bind
    // pose, which is why a test scene at rest proves nothing about it.
    //
    // Interpolated and not renormalised per vertex: the fragment normalises
    // once, after the tangent-space rotation, which is one normalise instead
    // of two and is where the precision actually matters.
    float3 tangent;
    float3 bitangent;
    float3 normal;
};

// ── Vertex ──────────────────────────────────────────────────────────────

// ── The tangent frame, built the same way on both paths ────────────────
//
// N IS NOT SKINNED, AND THAT IS NOT A SHORTCUT. A rig is a 2D rig living in
// its layer's plane: `SceneSkinPalette` folds a chain of 2D affines, every
// bind vertex has z = 0, and the matrix's z column is the plane normal itself.
// So no bone can tilt a sprite out of the plane, and the plane's normal is the
// sprite's normal exactly -- the same float the layer already carries. Skinning
// it would be arithmetic whose only possible effect is rounding error on a
// value we already know.
//
// T DOES turn, because a bone rotates the artwork within the plane, and B is
// derived from T rather than skinned alongside it. Deriving it is what keeps
// the frame a rotation: a sheared bone hands back a T and a B that are not
// perpendicular, and a normal rotated by those is neither unit nor
// perpendicular to anything. `SceneLayer.orientation()` records living through
// exactly that with the gizmo.
static inline void sceneTangentFrame(float3 n, float3 tRaw, float handed,
                                     thread float3 &tangent,
                                     thread float3 &bitangent) {
    // Projected back into the plane before normalising. A no-op for a chain
    // that really is in-plane, and the cheap insurance that keeps a degenerate
    // or numerically drifted bone from tilting the frame out of the card.
    float3 t = tRaw - n * dot(n, tRaw);
    const float lengthSquared = dot(t, t);
    // A bone scaled to nothing leaves no direction to recover. Falling back to
    // the plane's own x axis lights it flat rather than by a NaN, which shows
    // up as a black triangle that comes and goes with the pose.
    t = (lengthSquared > 1e-12) ? t * rsqrt(lengthSquared) : float3(1.0, 0.0, 0.0);
    tangent = t;
    // `cross(N, T)` is image-up for a right-handed frame -- with x, y, z
    // orthonormal and z = cross(x, y), cross(z, x) is y. The sign carries the
    // mirroring: a negatively scaled card draws its artwork reversed, and a
    // basis that is not told so lights the relief from the wrong side.
    bitangent = handed * cross(n, t);
}

vertex SceneVertexOut sceneCardVertex(const device SceneVertexIn *vertices [[buffer(0)]],
                                      constant SceneFrameUniforms &frame [[buffer(1)]],
                                      constant SceneLayerUniforms &layer [[buffer(3)]],
                                      uint vertexID [[vertex_id]]) {
    SceneVertexOut out;
    const float3 world = vertices[vertexID].world;
    // NO Y FLIP HERE. NDC +y is up and the framebuffer's +y is down, and the
    // viewport transform does that conversion in fixed function. A shader that
    // negates y as well produces a picture that is upside down and otherwise
    // perfect -- every number in it right, which is how that fault survives
    // review. `gpu_mirror.viewport` carries the same note and the foil.
    out.position = frame.viewProjection * float4(world, 1.0);
    out.world = world;
    out.uv = vertices[vertexID].uv;
    // Constant across a card, and a varying anyway so that ONE fragment
    // shader serves cards and skinned sprites alike. Two fragment shaders is
    // two places for the lighting to drift apart, which is the fault this
    // whole file was written to avoid.
    out.normal = layer.normalAndStrength.xyz;
    sceneTangentFrame(out.normal, layer.tangentAndSign.xyz, layer.tangentAndSign.w,
                      out.tangent, out.bitangent);
    return out;
}

vertex SceneVertexOut sceneSkinnedVertex(
        const device SceneSkinnedVertexIn *vertices [[buffer(0)]],
        constant SceneFrameUniforms &frame [[buffer(1)]],
        const device float4x4 *palette [[buffer(2)]],
        constant SceneLayerUniforms &layer [[buffer(3)]],
        uint vertexID [[vertex_id]]) {
    const device SceneSkinnedVertexIn &vertex_in = vertices[vertexID];
    const float4 bind = float4(vertex_in.bindLocal, 0.0, 1.0);

    // NO BRANCH ON THE WEIGHT TOTAL. Slot zero of the palette is the identity,
    // and a vertex with no influences is written as one influence of weight 1
    // on slot zero, so the unbound case is the same arithmetic as every other.
    // A branch here would diverge inside the hottest loop in the renderer.
    // THREE DIMENSIONS, NOT TWO. The palette folds the whole chain -- the
    // bone, the sprite's posed transform and the layer's lift out of the
    // card's plane -- so what comes out is a scene-world point, not a plane
    // one. Writing `float3(skinned, 0)` would throw the lift away and lay
    // every rig flat in z = 0: right in the front view, where a scene is
    // usually composed, and wrong the moment the camera orbits. Measured at
    // 652 units out of place in `verify_scene_gpu_skinning.py`.
    float3 world = float3(0.0);
    // THE ARTWORK'S OWN AXES, blended by the same weights as the position.
    // `(1,0,0,0)` and `(0,1,0,0)` are image +x and image UP in sprite-local
    // space -- `Mesh.localPosition(for:size:)` maps uv.y = 0 to local +y, the
    // same convention the card's corners use, so one rule covers both.
    //
    // w = 0, because these are DIRECTIONS: the fourth column is the chain's
    // accumulated translation, and letting it in would drag the tangent
    // towards wherever the sprite happens to sit in the world.
    float3 tangentRaw = float3(0.0);
    float3 bitangentRaw = float3(0.0);
    for (uint i = 0; i < 4; ++i) {
        const float weight = vertex_in.weights[i];
        if (weight <= 0.0) { continue; }
        const float4x4 bone = palette[vertex_in.slots[i]];
        const float4 moved = bone * bind;
        // Divided by w, exactly as `MatrixUtilities.transformPoint` does. The
        // bone matrices keep w at one so it is a no-op -- and it is done
        // anyway, because matching the CPU exactly costs nothing here and
        // assuming it does not is how two paths drift.
        const float w = abs(moved.w) < 1e-4 ? 1.0 : moved.w;
        world += (moved.xyz / w) * weight;
        tangentRaw += (bone * float4(1.0, 0.0, 0.0, 0.0)).xyz * weight;
        bitangentRaw += (bone * float4(0.0, 1.0, 0.0, 0.0)).xyz * weight;
    }

    SceneVertexOut out;
    out.position = frame.viewProjection * float4(world, 1.0);
    out.world = world;
    out.uv = vertex_in.uv;
    // The layer's plane normal, unskinned -- see `sceneTangentFrame`.
    out.normal = layer.normalAndStrength.xyz;
    // HANDEDNESS FROM THE SKINNED PAIR, not from the layer's. A sprite can be
    // mirrored by its own scale inside a layer that is not, and a bone chain
    // can mirror it again; the sign of the frame the bones actually produced
    // is the only reading that survives both.
    const float handed = (dot(cross(tangentRaw, bitangentRaw), out.normal) < 0.0)
        ? -1.0 : 1.0;
    sceneTangentFrame(out.normal, tangentRaw, handed, out.tangent, out.bitangent);
    return out;
}

// ── Lighting, transcribed from `SceneLighting.PreparedLight` ────────────

static inline float sampleFalloff(texture2d<float> curves, sampler curveSampler,
                                  uint row, float u) {
    // The curve table as a 1D slice of a 2D texture, one row per distinct
    // falloff. Sampled with linear filtering and clamp-to-edge, so the
    // normalised coordinate is what the sampler wants and the off-by-one the
    // CPU path had to spell out (`u * (n - 1)` and not `u * n`) is the
    // sampler's business, not ours.
    const float rows = float(curves.get_height());
    return curves.sample(curveSampler,
                         float2(clamp(u, 0.0, 1.0), (float(row) + 0.5) / rows)).r;
}

static inline float lightAttenuation(const device SceneLightUniform &light,
                                     float3 point,
                                     texture2d<float> curves,
                                     sampler curveSampler) {
    if (light.kind == 2u) { return 1.0; }        // directional

    const float3 origin = light.originAndRadius.xyz;
    const float radius = max(light.originAndRadius.w, 1e-6);
    const float innerRadius = light.directionAndInner.w;
    const float band = light.tintAndBand.w;

    float3 delta = point - origin;
    // THE WHOLE OF 2.5D. Scaling the depth difference is the only place in the
    // model that mentions Z: 0 gives a light lying flat across every layer, 1
    // gives a real point in space.
    delta.z *= light.cones.z;
    const float distance = length(delta);
    if (distance >= radius) { return 0.0; }

    float radial;
    if (distance <= innerRadius) {
        radial = 1.0;
    } else if (band > 1e-6) {
        radial = sampleFalloff(curves, curveSampler, light.falloffRow,
                               (distance - innerRadius) / band);
    } else {
        radial = 0.0;
    }

    if (light.kind != 1u || distance <= 1e-6) { return radial; }   // not a spot

    // Cones compared as COSINES, never as angles: acos is at its least
    // accurate exactly on the axis, which is the middle of the cone, and a dot
    // product IS the cosine. Converting it to an angle only to convert back is
    // arithmetic that can only lose.
    const float cosine = dot(delta / distance, light.directionAndInner.xyz);
    const float cosOuter = light.cones.y;
    const float cosInner = light.cones.x;
    if (cosine <= cosOuter) { return 0.0; }
    if (cosine >= cosInner) { return radial; }
    const float t = (cosine - cosOuter) / max(cosInner - cosOuter, 1e-6);
    return radial * (t * t * (3.0 - 2.0 * t));
}

// How a surface turns N.L into a lit fraction: the whole of Smoothness and
// Contrast. Transcribed from `SceneLighting.shapedLambert`, which carries the
// full reasoning; the short version is that smoothness is a WRAP and not a
// blur (it reads no texel but this fragment's own, which a mip bias would not),
// and that contrast is applied HERE -- on the directional response, clamped
// back into the range Lambert already occupied -- rather than on the
// accumulated factor, where it would scale the ambient and act on a sprite
// with no light reaching it, which is a brightness filter by another name.
//
// BOTH NEUTRAL VALUES TAKE A BRANCH, FOR TWO DIFFERENT REASONS -- measured,
// not assumed. `smoothness == 0` changes no bit (`(d + 0) / (1 + 0)` is exactly
// `d` in IEEE 754) and is branched only to skip the work. `contrast == 0` IS
// load-bearing: `0.5 + (x - 0.5) * 1.0` is not exactly `x` in float32, and
// 3 327 of 20 001 samples move without it. See `SceneLighting.shapedLambert`.
static inline float sceneShapedLambert(float ndotl, float smoothness, float contrast) {
    float shaped = (smoothness <= 0.0)
        ? max(0.0, ndotl)
        : max(0.0, (ndotl + smoothness) / (1.0 + smoothness));
    if (contrast > 0.0) {
        shaped = clamp(0.5 + (shaped - 0.5) * (1.0 + contrast), 0.0, 1.0);
    }
    return shaped;
}

static inline float lightLambert(const device SceneLightUniform &light,
                                 float3 point, float3 normal,
                                 float smoothness, float contrast) {
    // THE INFLUENCE STAYS OUTERMOST, and its early-out stays first. Smoothness
    // and contrast belong to the SURFACE and shape the directional response;
    // `normalInfluence` belongs to the LIGHT and decides how much of that
    // response is used at all. Any other order would let a sprite's material
    // resurrect a light the artist deliberately set to flat 2D -- which makes
    // a lighting decision unmakeable, and that is never forgivable.
    const float influence = light.cones.w;
    if (influence <= 0.0) { return 1.0; }
    float3 toLight;
    if (light.kind == 2u) {
        toLight = -light.directionAndInner.xyz;
    } else {
        float3 delta = light.originAndRadius.xyz - point;
        delta.z *= light.cones.z;
        const float len = length(delta);
        if (len <= 1e-6) { return 1.0; }
        toLight = delta / len;
    }
    const float shaped = sceneShapedLambert(dot(normal, toLight), smoothness, contrast);
    return 1.0 - influence + influence * shaped;
}

// ── The normal map ──────────────────────────────────────────────────────
//
// THIS IS THE WHOLE OF THE FEATURE. Everything else -- the tangent frame, the
// uniform, the asset role, the inspector row -- exists so that this function
// has something to read. Nothing in the shading below changed to accommodate
// it, exactly as `SceneLight.normalInfluence` predicted it would not have to:
// a normal map changes only WHERE the normal comes from.
//
// SAMPLED WITH RAW `in.uv`, NOT THROUGH `layer.uvRect`. A normal map is not
// atlased. It cannot safely be: the atlas packs unrelated artwork edge to
// edge, and a linear sampler at a card's boundary picks up the neighbour --
// which on an albedo page is a faint fringe and on a normal page is a band of
// surface pointing somewhere else entirely. `AssetManager` already loads every
// asset as a standalone texture with `.SRGB: false` and `.origin: .topLeft`,
// which is what a normal map wants and what an albedo page would have to undo.
//
// THE UV IS PASSED IN AND NOT READ FROM `in`, because the parallax march moves
// it. Sampling `in.uv` here while the albedo is sampled at the displaced
// coordinate would light one texel and paint another -- the relief and its
// shading drift apart by exactly the displacement, which reads as a surface
// whose highlights lag behind its bumps as the camera moves.
static inline float3 sceneMappedNormal(constant SceneLayerUniforms &layer,
                                       SceneVertexOut in,
                                       float2 uv,
                                       texture2d<float> normalMap,
                                       sampler mapSampler) {
    const float3 texel = normalMap.sample(mapSampler, uv).xyz;
    // The standard tangent-space decode: the texture stores [-1, 1] folded
    // into [0, 1], so a flat surface is the familiar lavender (0.5, 0.5, 1).
    float3 tangentNormal = texel * 2.0 - 1.0;
    // STRENGTH SCALES X AND Y AND LEAVES Z ALONE. That is not a choice between
    // equivalent options: scaling all three is a no-op, because the vector is
    // normalised immediately after and a uniform scale cannot survive that.
    // Tilting x and y against a fixed z is what actually flattens or steepens
    // the slope, which is what an artist means by "less relief".
    tangentNormal.xy *= layer.normalAndStrength.w;
    const float3 mapped = tangentNormal.x * in.tangent
                        + tangentNormal.y * in.bitangent
                        + tangentNormal.z * in.normal;
    const float lengthSquared = dot(mapped, mapped);
    // A texel of exactly (0.5, 0.5, 0.5) decodes to the zero vector, and a
    // strength of zero flattens any texel to it. Falling back to the plane's
    // own normal lights that pixel as the card, rather than by a NaN -- which
    // renders as a black speck that moves with the light.
    return (lengthSquared > 1e-12)
        ? mapped * rsqrt(lengthSquared)
        : layer.normalAndStrength.xyz;
}

// ── Parallax occlusion mapping ──────────────────────────────────────────
//
// A normal map tilts the LIGHT and leaves the GEOMETRY flat: orbit the camera
// and the relief does not move, because there is nothing there to move. The
// march below is what gives it depth. For each fragment it walks the view ray
// down through a height field, finds where the ray first goes under the
// surface, and shades THAT texel instead -- so a ridge hides what is behind it,
// the whole surface parallaxes against the card as the camera swings, and in
// the silhouette modes the outline itself follows the relief.
//
// ALL OF IT IS BEHIND `kSceneParallaxAny`. A surface with no height field takes
// a path that samples nothing and marches nothing, which is the same promise
// the normal map's own flag carries and the same reason: "renders exactly as
// before" has to mean bit for bit, and a march against a neutral texture is
// not bit for bit, it is a rounding error per pixel on every old project.

/// Where the view ray met the surface.
struct SceneParallaxHit {
    /// The texel to shade. Every later sample -- albedo, normal map, the
    /// self-shadow march -- uses this and not `in.uv`.
    float2 uv;
    /// How far down the volume the hit was: 0 at the top, 1 at the bottom.
    float depth;
    /// False when the ray ran out of steps without ever going under the
    /// surface. Only the silhouette modes care, and for them it is the whole
    /// point: a miss is a place where there IS no surface, so the fragment is
    /// thrown away and the card's rectangle stops being the outline.
    bool hit;
};

/// The height at a texel: 1 stands proud, 0 lies at the bottom of the volume.
///
/// WHITE IS HIGH, which is what a displacement bake writes, and
/// `kSceneHeightInverted` is for the depth generators that write the other way
/// round. Asking the artist to run a levels pass over every file they own would
/// be the alternative.
///
/// TWO SOURCES, NEVER BOTH. A dedicated map is read from its red channel; with
/// no dedicated map the height comes from the normal map's ALPHA, which is
/// where most bakers already leave the field they generated the normals from.
/// The renderer sets exactly one of the two bits, so this cannot read a
/// texture that is not there.
///
/// THE DEGENERATE CASE IS A NO-OP, AND THAT IS WHY THE ALPHA FALLBACK IS SAFE
/// TO OFFER. A normal map whose alpha is 1 everywhere describes a flat surface
/// at the very top of the volume: the march's first test passes, the hit is at
/// the fragment's own texel, and the displacement is zero. An artist who turns
/// parallax on with such a map sees no change -- not garbage.
static inline float sceneHeightAt(constant SceneLayerUniforms &layer,
                                  float2 uv,
                                  texture2d<float> heightMap,
                                  texture2d<float> normalMap,
                                  sampler mapSampler) {
    float height;
    if ((layer.materialFlags & kSceneHasHeightMap) != 0u) {
        height = heightMap.sample(mapSampler, uv).r;
    } else {
        height = normalMap.sample(mapSampler, uv).a;
    }
    return ((layer.materialFlags & kSceneHeightInverted) != 0u) ? (1.0 - height) : height;
}

/// The view ray, in the surface's own tangent space.
///
/// THE V COMPONENT IS NEGATED, and this is the one line in the whole feature
/// that is wrong in a way a still frame cannot show. `in.uv.y` grows DOWN the
/// image while the bitangent points UP it -- the same flip the card's corners
/// make ("uv.y = 0 is the image's TOP") and the same one the shadow test
/// spells out as `(1 - b) * 0.5`. Taken at face value the relief displaces the
/// wrong way along v: it looks like relief, it parallaxes as the camera moves,
/// and it moves against the light instead of with it.
static inline float3 sceneViewTangent(SceneVertexOut in, float3 eye) {
    const float3 v = normalize(eye - in.world);
    return float3(dot(v, in.tangent), dot(v, in.bitangent), dot(v, in.normal));
}

/// Steep parallax march with a secant refinement on the last two samples.
///
/// The refinement is what makes this OCCLUSION mapping rather than plain offset
/// mapping: the coarse march brackets the crossing, and one linear solve
/// between the two straddling samples puts the hit where it belongs. Without
/// it the relief steps visibly along the ray -- the classic staircase that
/// every screenshot of "parallax mapping done cheaply" has on it.
///
/// STEPS ARE SPENT WHERE THEY SHOW. Head on, the ray barely moves sideways and
/// a handful of samples resolve it; at a grazing angle it crosses half the
/// texture and needs all of them. `mix(max, min, |Vz|)` is that, and it is why
/// the artist gets one Quality knob instead of two step counts.
///
/// THE GRAZING GUARD IS NOT OPTIONAL. The offset is proportional to 1/Vz, so a
/// card seen edge on asks for an offset that tends to infinity and the first
/// step lands outside the artwork. Flooring Vz at 0.1 caps the total sweep at
/// ten times the depth, which is past anything that reads as surface.
static inline SceneParallaxHit sceneParallaxMarch(constant SceneLayerUniforms &layer,
                                                  SceneVertexOut in,
                                                  float3 viewTangent,
                                                  texture2d<float> heightMap,
                                                  texture2d<float> normalMap,
                                                  sampler mapSampler) {
    SceneParallaxHit result;
    result.uv = in.uv;
    result.depth = 0.0;
    result.hit = true;

    const float depth = layer.parallax.x;
    const float zGuard = max(viewTangent.z, 0.1);
    float steps = mix(layer.parallax.z, layer.parallax.y, clamp(viewTangent.z, 0.0, 1.0));
    steps = clamp(steps, 1.0, float(kSceneMaxParallaxSteps));
    const uint stepCount = uint(steps);

    // The sweep across the artwork, from the top of the volume to its floor.
    //
    // Derived rather than pattern-matched: descending a fraction `d` of the
    // volume takes `d / Vz` along the ray, and the ray goes INTO the surface,
    // which is `-V`. So the tangent displacement is `-V.xy * d / Vz`, and the
    // v component flips again on its way into uv -- leaving `(-Vx, +Vy)`.
    const float2 totalOffset = float2(-viewTangent.x, viewTangent.y) * (depth / zGuard);
    const float2 deltaUV = totalOffset / float(stepCount);
    const float deltaDepth = 1.0 / float(stepCount);

    float2 current = in.uv;
    float rayDepth = 0.0;
    float surfaceDepth = 1.0 - sceneHeightAt(layer, current, heightMap, normalMap, mapSampler);
    // Already solid at the fragment's own texel: nothing to march. This is the
    // flat-alpha case above, and it exits having moved nothing.
    bool hit = (surfaceDepth <= 0.0);
    uint taken = 0u;

    for (uint i = 0u; i < kSceneMaxParallaxSteps; ++i) {
        if (hit || i >= stepCount) { break; }
        current += deltaUV;
        rayDepth += deltaDepth;
        taken += 1u;
        surfaceDepth = 1.0 - sceneHeightAt(layer, current, heightMap, normalMap, mapSampler);
        hit = (rayDepth >= surfaceDepth);
    }

    if (hit && taken > 0u) {
        const float2 previous = current - deltaUV;
        // Signed gaps between the ray and the surface, straddling the
        // crossing: `after` is at or below zero, `before` is above it.
        const float after = surfaceDepth - rayDepth;
        const float beforeSurface =
            1.0 - sceneHeightAt(layer, previous, heightMap, normalMap, mapSampler);
        const float before = beforeSurface - (rayDepth - deltaDepth);
        const float span = after - before;
        // A span of zero means the two samples agree, so either endpoint is
        // the answer and the division is the only thing that could go wrong.
        const float weight = (fabs(span) > 1e-8) ? clamp(after / span, 0.0, 1.0) : 0.0;
        result.uv = previous * weight + current * (1.0 - weight);
        result.depth = clamp(rayDepth - weight * deltaDepth, 0.0, 1.0);
    } else {
        result.uv = current;
        result.depth = rayDepth;
    }
    result.hit = hit;
    return result;
}

/// How much of a light the relief hides from itself.
///
/// A second march, from the hit point back UP towards the lamp: every texel
/// whose surface stands above the ray is something between this crevice and
/// the light. It is the half of the feature that makes displaced texture read
/// as volume -- without it a deep relief lights as though it were painted on.
///
/// MULTIPLIED INTO `reach` AND NOT INTO `factor`, exactly as the occluder
/// shadows are, and for the reason the fragment shader already records: the
/// ambient is the floor a 2D set has instead of bounce light, and a shadow
/// that can eat it takes the surface to black.
///
/// A LIGHT BELOW THE SURFACE RETURNS 1, not 0. Its `N.L` is already negative,
/// so the shaped Lambert has taken the contribution away; darkening it again
/// here would be the same fact counted twice, and it shows up as a terminator
/// that is a hard black line instead of a rolled edge.
///
/// SOFTNESS FROM THE DISTANCE, not from more rays. A blocker found near the
/// start of the march is a wall right beside the crevice and shadows it hard;
/// one found at the end is far away and its edge has spread. Weighting by
/// march position gives that for one multiply, where a multi-tap penumbra
/// would multiply the whole cost by its tap count.
static inline float sceneParallaxSelfShadow(constant SceneLayerUniforms &layer,
                                            float2 uv, float depth,
                                            float3 lightTangent,
                                            texture2d<float> heightMap,
                                            texture2d<float> normalMap,
                                            sampler mapSampler) {
    if (lightTangent.z <= 0.0 || depth <= 0.0) { return 1.0; }

    float steps = clamp(layer.parallax.w, 1.0, float(kSceneMaxParallaxShadowSteps));
    const uint stepCount = uint(steps);
    const float zGuard = max(lightTangent.z, 0.1);
    // Rise out of the volume in equal fractions, sweeping uv by the same
    // geometry the view march used -- with the v flip once more.
    const float riseStep = depth / float(stepCount);
    const float2 deltaUV = float2(lightTangent.x, -lightTangent.y)
                         * (layer.parallax.x / zGuard) * riseStep;

    float occlusion = 0.0;
    float rayDepth = depth;
    float2 current = uv;
    for (uint i = 0u; i < kSceneMaxParallaxShadowSteps; ++i) {
        if (i >= stepCount) { break; }
        rayDepth -= riseStep;
        current += deltaUV;
        if (rayDepth <= 0.0) { break; }
        const float surfaceDepth =
            1.0 - sceneHeightAt(layer, current, heightMap, normalMap, mapSampler);
        if (surfaceDepth < rayDepth) {
            const float nearness = 1.0 - float(i) / float(stepCount);
            occlusion = max(occlusion, (rayDepth - surfaceDepth) * nearness);
        }
    }
    return clamp(1.0 - occlusion, 0.0, 1.0);
}

// ── Shadows ─────────────────────────────────────────────────────────────
//
// One analytic test per occluder: intersect the segment from the fragment to
// the light with the occluder's plane, ask whether the hit is inside the quad,
// and read one texel of the occluder's alpha to get its real silhouette.
//
// ONE TEXEL, not a march. A Scene layer is FLAT -- the model's founding rule --
// so an occluder is a plane segment and a ray crosses it exactly once. That is
// the whole reason the silhouette option is affordable: it costs the same one
// sample per occluder per light that a rectangle would have cost, and gives a
// character's outline instead of its bounding box.
//
// THE RAY USES THE LIGHT'S 2.5D DIRECTION, not the true one. `lightAttenuation`
// and `lightLambert` both scale the z of the difference by `depthInfluence`
// before doing anything with it, so the light SHADES as though it sat
// somewhere flattened towards the cards. A shadow cast from the true position
// would fall away from a light that is not where it appears to be, and the two
// would visibly disagree on the same sprite.
//
// That also explains the k = 0 case without a special case: a light with no
// depth influence has a direction with no z, the cards' normals are ±z, the
// denominator is zero, and nothing is occluded. A flat 2D light casts no
// shadow, which is what flat 2D means.
static inline float sceneShadowFactor(const device SceneLightUniform &light,
                                      const device SceneOccluder *occluders,
                                      float3 point, uint shadowedMask,
                                      texture2d<float> shadowAtlas,
                                      sampler atlasSampler) {
    if (light.castsShadows == 0u || light.occluderCount == 0u) { return 1.0; }
    if ((light.mask & shadowedMask) == 0u) { return 1.0; }

    float3 toLight;
    if (light.kind == 2u) {
        // A directional light has no position, so its occluders are tested
        // along its axis, far enough that anything in the scene is between.
        toLight = -light.directionAndInner.xyz * 1.0e5;
    } else {
        toLight = light.originAndRadius.xyz - point;
        toLight.z *= light.cones.z;
    }

    float occlusion = 0.0;
    for (uint i = 0; i < light.occluderCount; ++i) {
        const device SceneOccluder &blocker = occluders[light.occluderStart + i];
        const float3 normal = blocker.normalAndOffset.xyz;
        const float denominator = dot(normal, toLight);
        // Parallel to the blocker, or lying in its plane: nothing crosses it.
        if (fabs(denominator) < 1e-6) { continue; }

        const float t = (blocker.normalAndOffset.w - dot(normal, point)) / denominator;
        // STRICTLY BETWEEN THE SURFACE AND THE LIGHT. Without the upper bound
        // a blocker BEHIND the receiver shadows it, which is the classic fault
        // and reads as a scene lit from the wrong side; without the lower one a
        // surface shadows itself at every grazing angle. The floor is above
        // zero so a card does not occlude the pixel it is drawing.
        if (t <= 1e-3 || t >= 1.0) { continue; }

        // WHERE IN THE QUAD, solved as a 2x2 system rather than by projecting
        // onto each axis. A sheared card's axes are not perpendicular, and
        // projecting separately gives the shadow the shape the card would have
        // had without its slant.
        const float3 relative = (point + toLight * t) - blocker.origin.xyz;
        const float3 axisU = blocker.axisU.xyz;
        const float3 axisV = blocker.axisV.xyz;
        const float uu = dot(axisU, axisU);
        const float uv = dot(axisU, axisV);
        const float vv = dot(axisV, axisV);
        const float determinant = uu * vv - uv * uv;
        if (fabs(determinant) < 1e-9) { continue; }        // degenerate card
        const float ru = dot(relative, axisU);
        const float rv = dot(relative, axisV);
        const float a = (ru * vv - rv * uv) / determinant;
        const float b = (rv * uu - ru * uv) / determinant;
        if (fabs(a) > 1.0 || fabs(b) > 1.0) { continue; }

        // The artwork's own outline. v is measured DOWN the image while axisV
        // points UP it, which is the same flip the cards' corners make.
        float coverage = 1.0;
        if (blocker.useAlpha != 0u) {
            const float2 local = float2((a + 1.0) * 0.5, (1.0 - b) * 0.5);
            const float2 uvInAtlas = blocker.uvRect.xy + local * blocker.uvRect.zw;
            coverage = shadowAtlas.sample(atlasSampler, uvInAtlas).r;
        }
        // SOFTNESS FROM THE EDGE, NOT FROM MULTISAMPLING. Taking more rays
        // multiplies the cost by the tap count for an effect a ramp gives for
        // free -- and the alpha tile is already low resolution, so its own
        // filtering carries most of the softness before this is reached.
        const float edge = min(1.0 - fabs(a), 1.0 - fabs(b));
        coverage *= smoothstep(0.0, 0.04, edge);

        // THE DEEPEST SHADOW WINS rather than the shadows accumulating. Two
        // cards in front of a lamp cast one shadow, not a darker one: light is
        // either blocked or it is not, and adding occlusion would make a
        // crowd of sprites black out the set behind them.
        occlusion = max(occlusion, coverage);
        if (occlusion >= 0.999) { break; }
    }
    return 1.0 - occlusion;
}

// ── Fragment ────────────────────────────────────────────────────────────

fragment float4 sceneCardFragment(SceneVertexOut in [[stage_in]],
                                  constant SceneFrameUniforms &frame [[buffer(0)]],
                                  constant SceneLayerUniforms &layer [[buffer(1)]],
                                  const device SceneLightUniform *lights [[buffer(2)]],
                                  const device SceneOccluder *occluders [[buffer(3)]],
                                  texture2d<float> atlas [[texture(0)]],
                                  texture2d<float> curves [[texture(1)]],
                                  texture2d<float> normalMap [[texture(2)]],
                                  texture2d<float> shadowAtlas [[texture(3)]],
                                  texture2d<float> heightMap [[texture(4)]],
                                  sampler atlasSampler [[sampler(0)]],
                                  sampler curveSampler [[sampler(1)]]) {
    // ── The parallax march, before anything is sampled ──────────────────
    //
    // FIRST, because it decides WHICH TEXEL this fragment is. The albedo, the
    // normal map and the self-shadow all have to agree on that; sampling the
    // artwork at `in.uv` and only then displacing would light one texel and
    // paint another.
    //
    // The whole block is behind one flag test, so a surface with no height
    // field reaches the albedo sample having executed nothing but this
    // comparison -- which is what keeps every project that predates the
    // feature rendering bit for bit as it did.
    float2 surfaceUV = in.uv;
    float parallaxDepth = 0.0;
    bool parallaxHit = true;
    const bool marching = (layer.materialFlags & kSceneParallaxAny) != 0u;
    if (marching) {
        const float3 viewTangent = sceneViewTangent(in, frame.eyeAndNear.xyz);
        // THE BACK OF A CARD IS FLAT, and that is the honest answer rather
        // than a shortcut. The relief stands out of the FRONT of the surface;
        // seen from behind there is nothing standing out towards the viewer to
        // march through. Marching anyway would need a negative step and would
        // carve the relief inwards, which is a surface nobody authored.
        if (viewTangent.z > 0.0) {
            const SceneParallaxHit march =
                sceneParallaxMarch(layer, in, viewTangent, heightMap, normalMap, atlasSampler);
            surfaceUV = march.uv;
            parallaxDepth = march.depth;
            parallaxHit = march.hit;
        }
    }

    // ── The silhouette ──────────────────────────────────────────────────
    //
    // A ray that found no surface, or that walked off the edge of the
    // artwork, is a place where there IS nothing -- so the fragment goes, and
    // the card's rectangle stops being the outline. This is the entire
    // difference between parallax occlusion mapping and SILHOUETTE parallax
    // occlusion mapping, and it costs one comparison and a discard.
    //
    // ON THE SHELL the quad was grown by the depth before it was drawn (see
    // `SceneMetalRenderer.cardGeometry`), so `in.uv` arrives outside [0, 1]
    // around the border and most of that margin discards -- which is how the
    // relief comes to stand PROUD of where the card's edge used to be.
    if ((layer.materialFlags & kSceneParallaxClip) != 0u) {
        if (!parallaxHit || any(surfaceUV < float2(0.0)) || any(surfaceUV > float2(1.0))) {
            discard_fragment();
        }
    }

    // CLAMPED, NOT WRAPPED. The atlas packs unrelated artwork
    // edge to edge, so a march that leaves the card's own tile does not fade
    // into a neighbour -- it walks into it and draws it. The clamp keeps the
    // displacement inside the artwork; the silhouette modes above have already
    // thrown those fragments away, so for them this changes nothing.
    //
    // AND IT IS WHAT THE NORMAL MAP AND THE SELF-SHADOW READ TOO, not the raw
    // `surfaceUV`. Whatever texel ends up PAINTED is the texel that has to be
    // lit and shadowed; letting the albedo clamp while the relief kept marching
    // would light the edge of an occlusion-mode card by a texel it is not
    // showing.
    const float2 albedoUV = clamp(surfaceUV, float2(0.0), float2(1.0));
    const float2 atlasUV = layer.uvRect.xy + albedoUV * layer.uvRect.zw;
    float4 albedo = atlas.sample(atlasSampler, atlasUV) * layer.tint;

    // Cheap ambient occlusion: how far down the ray landed. ON THE ALBEDO and
    // before the lights, because it stands in for the light that never reaches
    // the bottom of a crack. Applied to the lit result instead it would also
    // dim the highlights sitting on the ridges, which is the one place the
    // relief is supposed to be brightest.
    //
    // PREMULTIPLIED ARTWORK, so only rgb is scaled: touching alpha here would
    // make a deep crevice transparent rather than dark.
    if (marching && layer.material.z > 0.0) {
        albedo.rgb *= 1.0 - layer.material.z * clamp(parallaxDepth, 0.0, 1.0);
    }

    if (layer.receivesLight == 0u) { return albedo; }

    // Lights are applied in LIST ORDER. `multiply` and `screen` do not commute
    // with the rest, and the order is the artist's list rather than a set's
    // iteration order for the reason `CLAUDE.md` gives: a Swift Set is seeded
    // per process, so an order taken from one would change the render between
    // launches of the same project.
    float3 factor = frame.ambient.rgb;
    float3 additive = float3(0.0);
    // THE BRANCH IS THE PROMISE, and it is also the cheap path: a sprite with
    // no map costs no texture fetch and no normalise, which is most sprites in
    // most scenes. The promise is that it renders bit for bit as it did, and
    // the neutral-texel alternative keeps that only on a card facing the
    // camera -- see `kSceneHasNormalMap`. So the old path here is not merely
    // equivalent, it is untouched: no sample, no rotation, no normalise.
    float3 normal = layer.normalAndStrength.xyz;
    if ((layer.materialFlags & kSceneHasNormalMap) != 0u) {
        // AT THE DISPLACED TEXEL. Without the march this is `in.uv` exactly,
        // so the old path is untouched.
        normal = sceneMappedNormal(layer, in, albedoUV, normalMap, atlasSampler);
    }
    const bool selfShadowing = marching
        && (layer.materialFlags & kSceneParallaxSelfShadow) != 0u;

    for (uint i = 0; i < frame.lightCount; ++i) {
        const device SceneLightUniform &light = lights[i];
        if ((light.mask & layer.lightMask) == 0u) { continue; }

        const float a = lightAttenuation(light, in.world, curves, curveSampler);
        // A light that reaches nothing is a no-op in every blend: multiply
        // scales the factor by one and screen screens with zero. There is no
        // blend that needs an exception here.
        if (a <= 0.0) { continue; }
        // MULTIPLIED INTO `reach`, NEVER INTO `factor`. `factor` starts at the
        // ambient, so darkening it would let a shadow take a surface to black
        // -- and a 2D set has no bounce light to rescue it. On `reach` a shadow
        // can only remove this lamp's contribution, and the ambient stays the
        // floor, which is what a shadow looks like.
        const float shadow = sceneShadowFactor(light, occluders, in.world,
                                               layer.shadowedMask,
                                               shadowAtlas, atlasSampler);
        // THE RELIEF'S OWN SHADOW, on the same footing as the occluders' and
        // in the same product. Two separate things can stand between this
        // texel and the lamp -- another card, and the bump next to it -- and
        // the light that gets past both is the light that gets past each.
        float selfShadow = 1.0;
        if (selfShadowing) {
            float3 toLight;
            if (light.kind == 2u) {
                toLight = -light.directionAndInner.xyz;
            } else {
                float3 delta = light.originAndRadius.xyz - in.world;
                // THE LIGHT'S 2.5D POSITION, not its true one -- the same
                // flattening `lightAttenuation` and `lightLambert` apply
                // before they do anything. A self-shadow cast from a position
                // the rest of the shading does not believe in falls away from
                // the highlight it belongs to.
                delta.z *= light.cones.z;
                const float len = length(delta);
                toLight = (len > 1e-6) ? (delta / len) : float3(0.0, 0.0, 1.0);
            }
            const float3 lightTangent = float3(dot(toLight, in.tangent),
                                               dot(toLight, in.bitangent),
                                               dot(toLight, in.normal));
            selfShadow = sceneParallaxSelfShadow(layer, albedoUV, parallaxDepth,
                                                 lightTangent, heightMap,
                                                 normalMap, atlasSampler);
        }
        const float reach = a * shadow * selfShadow
            * lightLambert(light, in.world, normal,
                           layer.material.x, layer.material.y);
        const float3 emission = light.tintAndBand.rgb * reach;

        switch (light.blend) {
            case 0u: factor += emission; break;                  // normal
            case 1u: additive += emission; break;                // additive
            case 2u:                                             // multiply
                factor *= float3(1.0 - reach) + light.tintAndBand.rgb * reach;
                break;
            default:                                             // screen
                factor = 1.0 - (1.0 - factor) * (1.0 - clamp(emission, 0.0, 1.0));
                break;
        }
    }

    // PREMULTIPLIED, AND THE ADDITIVE TERM IS SCALED BY ALPHA.
    //
    // The albedo has alpha folded into its colour, so the multiplicative
    // factor applies as it is. The additive term is a quantity of light
    // ARRIVING AT A SURFACE, and a surface that is nine tenths transparent
    // catches a tenth of it. Adding it unscaled is the one lighting bug that
    // looks plausible in a still: the sprite lights correctly and a faint
    // rectangular glow appears around it, where the artwork is transparent and
    // the light is not. Foiled in `verify_scene_gpu_pipeline.py`.
    const float alpha = albedo.a;
    float3 lit = albedo.rgb * factor + additive * alpha;
    // Clamped to ALPHA, not to 1: a premultiplied pixel that carries more
    // colour than alpha composites as if it were brighter than opaque.
    return float4(clamp(lit, 0.0, alpha), alpha);
}

// ── The encode pass ─────────────────────────────────────────────────────
//
// The scene accumulates in a LINEAR float target so the light arithmetic has
// somewhere to put values above 1 before anything is clamped -- which the
// 8-bit CPU compositor never had, and is why a bright lamp used to flatten
// into a white disc. This pass is what turns that into the 8 bits the canvas
// presents and the exporter writes, and it is the only place the two differ:
// same texture, same numbers, one goes to a drawable and one to a buffer.

struct EncodeVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex EncodeVertexOut sceneEncodeVertex(uint vertexID [[vertex_id]]) {
    // A full-screen triangle, not a quad: one primitive, no seam down the
    // diagonal where two triangles meet, and three vertices instead of four.
    const float2 uv = float2(float((vertexID << 1) & 2u), float(vertexID & 2u));
    EncodeVertexOut out;
    out.uv = uv;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return out;
}

fragment float4 sceneEncodeFragment(EncodeVertexOut in [[stage_in]],
                                    texture2d<float> source [[texture(0)]],
                                    sampler linearSampler [[sampler(0)]]) {
    return source.sample(linearSampler, in.uv);
}

// ── The composition's background ────────────────────────────────────────
//
// A Scene has a ground behind every layer -- `SceneComposition.background`, a
// `SceneFill` that may be a two-stop vertical ramp -- and the CPU compositor
// paints it into the frame before anything else. It is NOT a layer: a fill
// LAYER sits in the artist's draw order and can have things sent behind it,
// which is why the layer pass clears to transparent rather than to a colour.
// The background is what "behind everything" means, so it is its own pass.
//
// IN SCREEN SPACE, not world space. It fills the frame at every camera angle
// and distance -- it is the ground the shot is composed against, not a card
// standing somewhere in the scene -- so it reuses the encode pass's full-screen
// triangle rather than being projected.
fragment float4 sceneBackgroundFragment(EncodeVertexOut in [[stage_in]],
                                        texture2d<float> ramp [[texture(0)]],
                                        sampler rampSampler [[sampler(0)]]) {
    // uv.y = 0 is the TOP of the frame, which is row 0 of the 1x2 ramp -- the
    // same convention `fillTexture` writes and a card's UV already uses. Taken
    // the other way the sky ends up on the floor.
    return ramp.sample(rampSampler, float2(0.5, in.uv.y));
}
