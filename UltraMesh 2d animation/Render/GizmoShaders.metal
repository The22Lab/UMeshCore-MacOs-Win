#include <metal_stdlib>
using namespace metal;

struct GizmoVertex {
    float2 position;
    float4 color;
};

struct GizmoOut {
    float4 position [[position]];
    float4 color;
};

vertex GizmoOut gizmoVertex(const device GizmoVertex *vertices [[buffer(0)]],
                            uint vertexID [[vertex_id]]) {
    GizmoOut out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.color = vertices[vertexID].color;
    return out;
}

fragment float4 gizmoFragment(GizmoOut in [[stage_in]]) {
    return in.color;
}
