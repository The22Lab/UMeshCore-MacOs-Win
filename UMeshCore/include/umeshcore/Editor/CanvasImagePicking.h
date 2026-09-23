#pragma once

// The image half of `Core/CanvasPicking.swift`: which SPRITE is under the
// cursor, decided by alpha. (The arbitration half -- a hit ON something
// beats a hit NEAR something -- is `CanvasPicking.h`'s `target()`.)
//
// Phase 2 left this out because it needs a loaded texture's alpha. It now
// reads an `AssetAlphaStore` the shell fills, and `makeImageHitTest` binds
// it into the `ImageHitTestFn` the tools already take, so the arbitration
// code did not have to change.
//
// Three passes, as Swift: a BROAD phase against the drawn vertices' box; the
// EXACT test -- point in a drawn screen-space triangle, UV by barycentric
// interpolation, alpha at that UV (not the affine inverse, which sampled
// the wrong texel on every skinned sprite); and REACH, the small distance
// that keeps a thin sprite grabbable, measured to both the silhouette and
// the opaque region and taking the farther, so it hugs the art whether the
// mesh is traced or is still the whole sheet.
//
// One difference: Swift first consults `lastDrawnGeometry`, the renderer's
// record of the frame on screen, and recomputes only on a miss. That cache
// belongs to the renderer, which stays on each platform; here the geometry
// is always computed, through the same four steps the renderer takes
// (resolve, skin, transform, project). They differ only while the transport
// is rolling between a draw and a click.

#include <optional>
#include <vector>

#include "umeshcore/Editor/AssetAlphaStore.h"
#include "umeshcore/Editor/Bounds2D.h"
#include "umeshcore/Editor/CanvasPicking.h"
#include "umeshcore/Editor/EditorScene.h"

namespace umeshcore::CanvasImagePicking {

// The reach that makes a thin sprite grabbable (12 points, scaled for touch).
inline float slopRadius(float hitScale) { return 12.0f * hitScale; }

struct ScreenGeometry {
    Mesh mesh;
    // One screen position per mesh vertex, skinned and deformed as drawn.
    std::vector<Vec2> screenVertices;
};

std::optional<ScreenGeometry> screenGeometry(const SceneImage& image, Vec2 assetSize, const EditorScene& scene,
                                             Vec2 viewSize, CameraState* camera);

// The texture coordinate under a screen point, or nullopt off the drawn shape.
std::optional<Vec2> uvAt(Vec2 point, const ScreenGeometry& geometry);
// The inverse: where a texture coordinate was drawn.
std::optional<Vec2> screenPosition(Vec2 uv, const ScreenGeometry& geometry);

// The front-most sprite whose opaque texel is under the point (direct), or
// else the nearest within reach (not direct). Hidden sprites, and sprites
// displaced by the skin or an attachment key, are not candidates.
std::optional<ImageHit> imageHit(Vec2 screenPoint, Vec2 viewSize, const EditorScene& scene,
                                 const AssetAlphaStore& assets, CameraState* camera, float hitScale);

// `ToolUtilities.hitTestScreen`: the sprite a click lands on or reaches.
std::optional<Uuid> hitTestScreen(Vec2 screenPoint, Vec2 viewSize, const EditorScene& scene,
                                  const AssetAlphaStore& assets, CameraState* camera, float hitScale);

// `ToolUtilities.hitTestRect`: every visible sprite whose drawn SILHOUETTE a
// rubber band touches -- a drawn vertex inside the band, or the band inside
// the sprite (a small band dropped on a large sprite catches no vertex).
// Front first. Art transparent everywhere is not caught.
std::vector<Uuid> hitTestRect(const ToolUtilities::ScreenRect& rect, Vec2 viewSize, const EditorScene& scene,
                              const AssetAlphaStore& assets, CameraState* camera);

// `ToolUtilities.meshProjection(scene:assets:...)`: the SELECTED sprite's
// mesh, as the overlay draws it, projected once per event.
std::optional<ToolUtilities::MeshProjection> selectedMeshProjection(const EditorScene& scene,
                                                                    const AssetAlphaStore& assets,
                                                                    CameraState* camera, Vec2 viewSize,
                                                                    float hitScale);

// `ToolUtilities.boundsForImage` / `boundsForScene`: the world box a
// sprite's (transformed) sheet covers, and the union over the visible
// sprites that have art -- what "frame the selection" / "frame all" fit
// the camera to. nullopt when no sprite qualifies. Swift reads the size off
// the Metal texture; here it is the store's `size`, which is the same
// number (`TextureAsset.size` is the texture's dimensions).
Bounds2D boundsForImage(const SceneImage& image, Vec2 assetSize);
std::optional<Bounds2D> boundsForScene(const EditorScene& scene, const AssetAlphaStore& assets);

// `imageHit` bound into the callback the tools take. The references must
// outlive the returned function.
ImageHitTestFn makeImageHitTest(const EditorScene& scene, const AssetAlphaStore& assets, float hitScale);

} // namespace umeshcore::CanvasImagePicking
