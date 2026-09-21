#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct CheckerUniforms {
    float2 viewportSize;
    float2 checkerSize;
    float3 darkColor;
    float3 lightColor;
    float zoom;
    float2 cameraPosition;
};

/// Below this the squares are too small to read and turn to moiré, so the cell
/// doubles. In drawable pixels, because that is the unit `zoom` is in.
constant float kMinScreenCell = 12.0;

vertex VertexOut checkerVertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

/// Parity of the square a world point falls in, as a 0...1 blend weight.
///
/// `fabs` is not decoration: fmod keeps the DIVIDEND's sign, so left of and
/// below the origin the parity comes back as -1 and `mix` extrapolates past
/// the palette. The old shader could not reach that case — its input was a
/// screen pixel, which is never negative. World space is signed.
static float checkerParity(float2 world, float cell) {
    float2 grid = floor(world / cell);
    return fabs(fmod(grid.x + grid.y, 2.0));
}

fragment float4 checkerFragment(VertexOut in [[stage_in]],
                                constant CheckerUniforms &u [[buffer(0)]]) {
    float2 pixel = in.uv * u.viewportSize;

    // The board belongs to the world, not to the display. This used to checker
    // straight off `pixel`, ignoring the zoom and camera it was handed, so the
    // artwork slid across a pattern nailed to the screen.
    //
    // Mirror of CameraState.screenToWorld exactly as the rest of the Metal
    // path calls it — with the DRAWABLE size as the view size, which is what
    // the axis cross (guideVertices(viewSize: drawableSize)), the sprites
    // (drawSceneImages(drawableSize:)) and the input path all pass. So `zoom`
    // is already drawable pixels per world unit and there is NO scale factor
    // here: multiplying by one made the board travel that many times too far,
    // a parallax against the very cross that marks the origin.
    //
    // Screen y runs down, world y runs up.
    float zoomPixels = max(u.zoom, 1e-6);
    float2 centred = pixel - u.viewportSize * 0.5;
    float2 world = float2(centred.x / zoomPixels + u.cameraPosition.x,
                          -(centred.y / zoomPixels) + u.cameraPosition.y);

    // The cell is in world units now, so it scales with zoom — and this camera
    // spans 0.05x to 20x. At the bottom of that range the base cell is under a
    // pixel across, so it doubles as it shrinks, blended over the step so the
    // change does not pop. At ordinary zooms `lod` is 0 and this is exactly the
    // base cell.
    float baseCell = max(u.checkerSize.x, 0.0001);
    float screenCell = max(baseCell * zoomPixels, 1e-6);
    float lod = max(0.0, log2(kMinScreenCell / screenCell));
    float low = floor(lod);
    float frac = lod - low;

    float near = checkerParity(world, baseCell * exp2(low));
    float far = checkerParity(world, baseCell * exp2(low + 1.0));
    float checker = mix(near, far, frac);

    float3 color = mix(u.darkColor, u.lightColor, checker);
    return float4(color, 1.0);
}
