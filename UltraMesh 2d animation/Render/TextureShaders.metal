#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position;
    float2 uv;
    // RGBA tint; the alpha channel doubles as the sprite's opacity.
    float4 tint;
};

struct QuadVertex {
    float2 local;
    float2 uv;
};

struct SpriteInstance {
    float4 positionScale;
    float4 halfSizeSkew;
    float4 rotationAndPad;
    float4 uvRect;
    float4 tint;
};

struct SpriteSceneUniforms {
    float4 viewportAndZoom;
    float4 cameraOrigin;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 tint;
};

vertex VertexOut textureVertex(const device VertexIn *vertices [[buffer(0)]],
                               uint vertexID [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.uv = vertices[vertexID].uv;
    out.tint = vertices[vertexID].tint;
    return out;
}

vertex VertexOut textureInstancedVertex(const device QuadVertex *quadVertices [[buffer(0)]],
                                        const device SpriteInstance *instances [[buffer(1)]],
                                        constant SpriteSceneUniforms &scene [[buffer(2)]],
                                        uint vertexID [[vertex_id]],
                                        uint instanceID [[instance_id]]) {
    QuadVertex quad = quadVertices[vertexID];
    SpriteInstance instance = instances[instanceID];

    float2 local = quad.local * instance.halfSizeSkew.xy;
    float rotation = instance.rotationAndPad.x;
    float shearX = instance.halfSizeSkew.z;
    float shearY = instance.halfSizeSkew.w;

    constexpr float degreesToRadians = 0.017453292519943295f;
    float xAxisAngle = (rotation + shearY) * degreesToRadians;
    float yAxisAngle = (rotation + 90.0 + shearX) * degreesToRadians;
    float2 xAxis = float2(cos(xAxisAngle), sin(xAxisAngle)) * instance.positionScale.z;
    float2 yAxis = float2(cos(yAxisAngle), sin(yAxisAngle)) * instance.positionScale.w;
    float2 world = instance.positionScale.xy + xAxis * local.x + yAxis * local.y;

    float2 viewSize = scene.viewportAndZoom.xy;
    float zoom = scene.viewportAndZoom.z;
    float2 cameraOrigin = scene.cameraOrigin.xy;
    float2 centered = (world - cameraOrigin) * zoom;
    float2 screen = float2(centered.x + viewSize.x * 0.5, -centered.y + viewSize.y * 0.5);
    float2 ndc = float2(
        (screen.x / (viewSize.x * 0.5)) - 1.0,
        1.0 - (screen.y / (viewSize.y * 0.5))
    );

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.uv = instance.uvRect.xy + quad.uv * instance.uvRect.zw;
    out.tint = instance.tint;
    return out;
}

fragment float4 textureFragment(VertexOut in [[stage_in]],
                                texture2d<float> colorTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 color = colorTexture.sample(textureSampler, in.uv);
    // Component-wise tint; the tint's alpha acts as the sprite's opacity.
    color *= in.tint;
    // Premultiply. For normal blending this is identical to straight alpha
    // (the pipeline pairs it with one/oneMinusSourceAlpha), but it is what
    // stops additive and screen from over-brightening at partial alpha.
    color.rgb *= color.a;
    return color;
}

// MARK: - Alpha-contour selection outline

struct OutlineUniforms {
    /// The sprite's own region in the atlas: xy = origin, zw = size.
    float4 uvRect;
    /// Premultiplied-ready RGBA the rim is painted in.
    float4 color;
    /// Rim thickness in DRAWABLE PIXELS, so it looks the same at every zoom.
    float thickness;
    float pad0, pad1, pad2;
};

/// Alpha outside the sprite's own atlas region is zero, not clamped.
///
/// Clamping is the obvious thing and it is wrong here. The packer TRIMS art to
/// its opaque bounds, so a sprite that fills its region has opaque texels hard
/// against the region border — clamp, and every ring sample along that border
/// reads opaque, no edge is ever detected, and the rim silently disappears
/// exactly where the art is biggest. Reading zero outside the region is also
/// simply true: there is no sprite there.
static inline float regionAlpha(texture2d<float> tex, sampler s, float2 uv, float4 rect) {
    float2 lo = rect.xy;
    float2 hi = rect.xy + rect.zw;
    if (uv.x < lo.x || uv.y < lo.y || uv.x > hi.x || uv.y > hi.y) return 0.0;
    return tex.sample(s, uv).a;
}

/// A rim that follows the alpha silhouette, drawn just INSIDE it.
///
/// Inside rather than outside, and that is forced rather than chosen: a traced
/// sprite's mesh hull hugs its own silhouette, so there is no transparent
/// margin left inside the triangles for an outer rim to live in. An outer rim
/// would be clipped away precisely on the sprites that have been traced most
/// carefully.
///
/// Thickness is converted from pixels to UV through the fragment's own
/// derivatives, so it is constant on screen at any zoom, under any rotation,
/// and across a mesh whose triangles are stretched by deformation.
fragment float4 alphaOutlineFragment(VertexOut in [[stage_in]],
                                     texture2d<float> colorTexture [[texture(0)]],
                                     constant OutlineUniforms &outline [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);

    float own = regionAlpha(colorTexture, textureSampler, in.uv, outline.uvRect);
    // Outside the silhouette there is no rim to draw: the rim lives inside it.
    if (own <= 0.02) discard_fragment();

    // One screen pixel, expressed in UV. dfdx/dfdy give the exact Jacobian of
    // this fragment's UV with respect to screen position, which is what makes
    // the thickness survive rotation, shear and mesh deformation.
    float2 duvdx = dfdx(in.uv);
    float2 duvdy = dfdy(in.uv);

    // Sixteen samples on a ring at the rim's thickness. Below about twelve the
    // ring aliases into a visible polygon on near-horizontal edges.
    const int kSamples = 16;
    float nearestOutside = 1.0;
    for (int i = 0; i < kSamples; ++i) {
        float angle = (6.28318530718 * float(i)) / float(kSamples);
        float2 offsetPixels = float2(cos(angle), sin(angle)) * outline.thickness;
        float2 uv = in.uv + duvdx * offsetPixels.x + duvdy * offsetPixels.y;
        nearestOutside = min(nearestOutside,
                             regionAlpha(colorTexture, textureSampler, uv, outline.uvRect));
    }

    // Deep inside, every ring sample is opaque and there is no rim. Near the
    // edge at least one sample falls outside, and the rim comes up smoothly so
    // it antialiases instead of stair-stepping.
    float rim = 1.0 - smoothstep(0.02, 0.65, nearestOutside);
    // Fade by the sprite's own coverage as well, so a soft alpha edge gets a
    // soft rim rather than a hard band floating on a gradient.
    rim *= smoothstep(0.02, 0.35, own);
    if (rim <= 0.003) discard_fragment();

    float4 color = outline.color;
    color.a *= rim;
    color.rgb *= color.a;   // premultiplied, like textureFragment
    return color;
}
