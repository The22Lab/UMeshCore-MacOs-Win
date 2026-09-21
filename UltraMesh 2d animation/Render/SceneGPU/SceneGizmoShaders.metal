#include <metal_stdlib>
using namespace metal;

// ── The Scene gizmo, drawn as real 3D geometry ──────────────────────────
//
// Structs mirrored by hand against `SceneGizmoTypes.swift` — see that file's
// banner for the layout rule (`float3` aligns to 16, so a uniform struct
// packs a trailing scalar into a `float4` rather than spelling it out).
//
// Named `sceneGizmo*` rather than `gizmo*` so as not to collide with
// `Render/GizmoShaders.metal`'s `gizmoVertex`/`gizmoFragment` — the rig
// canvas's own, unrelated, flat 2D gizmo, in the same default library.

struct SceneGizmoFrameUniforms {
    float4x4 viewProjection;
    float4   eyeAndPad;         // xyz the real camera's eye, w unused
    float4   screenOffsetNDC;   // xy the recentre-then-slide offset, zw unused
};

struct SceneGizmoVertexIn {
    float3 world;
    float3 normal;
    float4 color;
};

struct SceneGizmoVertexOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float4 color;
};

vertex SceneGizmoVertexOut sceneGizmoVertex(
        const device SceneGizmoVertexIn *vertices [[buffer(0)]],
        constant SceneGizmoFrameUniforms &frame [[buffer(1)]],
        uint vertexID [[vertex_id]]) {
    const device SceneGizmoVertexIn &in = vertices[vertexID];
    float4 clip = frame.viewProjection * float4(in.world, 1.0);

    // THE RECENTRE-THEN-SLIDE, ON THE GPU. `frame.viewProjection` is the
    // gizmo's OWN stabilised camera — same eye as the real one, recentred on
    // the gizmo's origin with a narrow FOV, so the shape it produces is
    // undistorted regardless of where the object sits in the real frame.
    // Adding the offset here, scaled by `clip.w`, is adding it to NDC after
    // the divide happens — the same rigid 2D slide
    // `SceneGizmoOverlay.gizmoState().map` applies on the CPU with
    // `+ screenOffsetPx`, expressed in clip space instead of pixels so the
    // CPU and the GPU can each do it in the space that is natural to them
    // and still land on the same pixel.
    clip.xy += frame.screenOffsetNDC.xy * clip.w;

    SceneGizmoVertexOut out;
    out.position = clip;
    out.world = in.world;
    out.normal = in.normal;
    out.color = in.color;
    return out;
}

fragment float4 sceneGizmoFragment(SceneGizmoVertexOut in [[stage_in]],
                                   constant SceneGizmoFrameUniforms &frame [[buffer(0)]]) {
    // A FIXED KEY LIGHT, not the scene's own lights. The gizmo is chrome, not
    // a lit surface in the set — it has to read as round from any camera
    // angle and under any scene lighting, including none, so it carries its
    // own light rather than asking `frame.lightCount` for one.
    const float3 normal = normalize(in.normal);
    const float3 key = normalize(float3(0.4, 0.7, 0.6));
    const float lambert = saturate(dot(normal, key));
    // Floor around 0.6 rather than 0: the far side of a cylinder is never
    // black, because "which way is round" only reads from the gradient
    // between a lit face and a merely-dimmer one, not from a lit face next
    // to a silhouette.
    const float shade = mix(0.62, 1.0, lambert);

    const float3 viewDir = normalize(frame.eyeAndPad.xyz - in.world);
    const float rim = pow(1.0 - saturate(dot(normal, viewDir)), 2.0);

    float3 rgb = in.color.rgb * shade + float3(1.0) * rim * 0.35;
    return float4(rgb, in.color.a);
}
