#pragma once

// 1:1 port of the portable math trapped inside `SceneViewportView.swift`'s
// (1186 L) view body: viewport fit, pixel-budget application, and the
// pinch/depth-drag math for the Scene canvas. Fourth SwiftUI-debt bite
// (Risk #6), after `GraphViewport`, `TimelineGraphMath` and
// `HierarchyDisplay` -- and a smaller one than those three, precisely
// because so much of what LOOKS like logic in this file (picking, gizmo
// hit-test, projection) already delegates to code Phases 2/4/5 finished:
// `SceneProjection`, `SceneViewCamera`, `SceneRenderBudget`,
// `SceneGizmoDrag::convexContains` are all reused as-is below, not
// re-derived.
//
// ALSO CLOSES A GAP. `SceneFrontView`
// (`Data/Scene/SceneComposition.swift:147-165`) is real editor state --
// the front (shot) view's pan/zoom, saved with the project, never
// keyframed, never exported, same category as `SceneViewCamera` -- and
// `Scene/SceneComposition.h`'s own header comment already claimed it was
// "already ported, in `Render/SceneViewCamera.h`". It was not: grepped,
// zero hits anywhere in `include/` or `src/` besides that one stale line.
// It ports here, for real, and that comment is corrected to point here.
//
// WHAT PORTS:
//  - `SceneFrontView` -- the front view's pan/zoom editor state.
//  - `fittedRect()` -- where the rendered image sits in the viewport:
//    scaled uniformly to fit and centred, then the front view's pan/zoom
//    laid on top. Picking maps view points through this, so a click lands
//    on the pixel the artist SEES, not the pixel the renderer wrote.
//  - `viewPointFromImage()` / `imagePointFromView()` -- image pixels <->
//    view points, declared beside each other because they have to stay
//    exact inverses of one another: getting one wrong is a click that
//    lands somewhere other than where the thing is drawn, wrong by the
//    display scale factor on a Retina Mac or an iPad.
//  - `renderPixelSize()` -- applies the already-ported `SceneRenderBudget`
//    ladder to a viewport: the front view follows the shot's aspect, the
//    fly view is capped by its longest side, and a gesture in flight uses
//    the smaller "interactive" ceiling in both cases. Points are capped
//    to PIXELS, not the other way around -- capping in points is what
//    made a large window render worse than a small one (same pixel count
//    stretched over more points).
//  - `integerPixels()` -- a documented guard before turning a pixel size
//    into integers. Swift's `Int(_: Float)` TRAPS on NaN, on an infinity,
//    and on anything past `Int.max`; it does not clamp, it crashes the
//    process. NaN reaches here more easily than it looks:
//    `renderPixelSize` computes the shot's aspect as
//    `x / max(y, 1)`, and Swift's `max` returns its FIRST argument when
//    the comparison is false -- which every comparison with NaN is -- so
//    `max(NaN, 1)` is NaN, straight through the guard that looks like it
//    stops it. C++ does not trap the same way an out-of-range
//    float-to-int cast is undefined behavior rather than a crash -- but
//    the guard is just as load-bearing here, for that reason instead.
//  - `pinchZoomFrontView()` -- the front view's anchor-preserving zoom:
//    zoom toward the pointer so what the artist is looking at stays under
//    their fingers rather than sliding away while they zoom in on it.
//    (The fly camera's own pinch, a dolly, is already ported --
//    `SceneViewCamera::dolly` -- this covers only the front-view branch,
//    which needs `fittedRect` before and after to find where the anchor
//    landed.)
//  - `depthDragZ()` -- the Shift-drag-in-depth math: a vertical screen
//    delta scaled by the card's distance from the camera so the gesture
//    feels the same near and far, clamped to stay past the near plane.
//
// WHAT DOES NOT PORT, and why:
//  - `contains()` (Swift: point-in-convex-polygon) is NOT re-ported here.
//    It is a byte-for-byte re-derivation of `umeshcore::convexContains`,
//    already ported for the gizmo's own hit-testing
//    (`Editor/SceneGizmoDrag.h/.cpp`). A shell's card-pick loop should
//    call `convexContains` on each `LayerQuad`'s corners directly --
//    re-porting it here as "new" code would be exactly the
//    two-transcriptions-of-one-predicate failure this port already caught
//    once, in `ArcMath` (see Phase 4, piece 6 in `CLAUDE.md`).
//  - Everything that touches `SceneFrameRenderer` / `SceneMetalRenderer`
//    (`lightMarkers`, `layerQuads`, `metalFrame`, `frustumGeometry`,
//    `pickedLight`, `pickedLayer`) is renderer-OUTPUT glue, not portable
//    math -- and `CLAUDE.md`'s Phase 4 section ("Que NO portar de
//    `Render/`") already excludes the renderers themselves.
//  - `navigate()`'s orbit-vs-pan dispatch is a three-line
//    `if fingers >= 2` over `SceneViewCamera::orbit`/`pan` (already
//    ported) and `SceneFrontView::pan` (ported here) -- thin enough it is
//    not worth a dedicated function; a shell wires the three lines
//    directly.
//  - `beginCardDrag`/`updateCardDrag`/`selectWhatever` touch the god
//    object (`SceneManager`) directly for selection and undo, per
//    convention #2. The one line of real math inside them
//    (`position = drag.startPosition + (nowWorld - startWorld)`) is
//    trivial vector arithmetic over the already-ported
//    `SceneProjection::unprojectOntoPlaneZ` -- not worth a function
//    either.

#include <optional>

#include "umeshcore/Editor/Bounds2D.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

// Editor state for the front (shot) view: pan/zoom, saved with the
// project, never keyframed, never exported. Lives beside the viewport
// math that reads it, not beside `SceneViewCamera` -- see the file
// banner for why `Scene/SceneComposition.h` used to (wrongly) claim it
// was already there.
struct SceneFrontView {
    Vec2 pan = Vec2::zero();
    float zoom = 1.0f;

    // Far enough out to see a set laid wide, far enough in to place a
    // card by its corner. Clamped because an unclamped zoom is a
    // viewport nobody can get back to.
    static constexpr float kMinZoom = 0.15f;
    static constexpr float kMaxZoom = 12.0f;

    void zoomBy(float factor) {
        float z = zoom * factor;
        if (z < kMinZoom) z = kMinZoom;
        if (z > kMaxZoom) z = kMaxZoom;
        zoom = z;
    }

    bool isIdentity() const { return pan == Vec2::zero() && zoom == 1.0f; }

    static SceneFrontView identity() { return SceneFrontView{}; }
};

// The render-pixel-count caps `renderPixelSize` applies, named exactly as
// Swift names its own `static let`s so the two stay easy to compare.
struct SceneViewportPixelCaps {
    static constexpr float kMaxEditorPixels = 2400.0f;
    static constexpr float kInteractiveEditorPixels = 1200.0f;
    static constexpr float kMaxShotPixels = 1800.0f;
    static constexpr float kInteractiveShotPixels = 900.0f;
};

// A pixel size safe to have come from `integerPixels` -- both components
// finite, at least 1, under 65536.
struct IntegerPixelSize {
    int width = 0;
    int height = 0;
};

// Where the rendered image sits in the viewport: scaled uniformly to fit
// `viewSize` and centred, then -- for the front view only -- the front
// view's pan and zoom laid on top. The flying view has a real camera
// already; applying pan/zoom to it too would be two navigations fighting
// over one set of fingers, so `isFlying` short-circuits before any of
// `frontView` is read.
Bounds2D fittedRect(const Vec2& pixelSize, const Vec2& viewSize, bool isFlying,
                     const SceneFrontView& frontView);

// Image pixels to view points, and back. Kept beside each other: the two
// must stay exact inverses, because a drag reads a view point, must find
// the image pixel under it, and any later read of that pixel must map
// back to the same view point it came from.
Vec2 viewPointFromImage(const Vec2& image, const Vec2& pixelSize, const Bounds2D& fitted);
Vec2 imagePointFromView(const Vec2& viewPoint, const Vec2& pixelSize, const Bounds2D& fitted);

// How many pixels this frame is allowed, applying the already-ported
// `SceneRenderBudget` ladder (the caller passes its current
// `pixelCap(full: 1)` as `budgetScale`; this function does not depend on
// `SceneRenderBudget` directly so that a shell can measure the ladder
// however it likes and this stays pure).
//
// Falls back to a tiny 16x16 frame when `viewSize` has collapsed to
// nothing (a pane mid-resize, a hidden tab) -- never to a degenerate size
// that would make a downstream `Int` conversion or GPU texture creation
// misbehave.
Vec2 renderPixelSize(const Vec2& viewSize, float displayScale, bool isFlying, bool isProvisional,
                      float budgetScale, const Vec2& compositionRenderSize);

// Guards a pixel size before it becomes an `IntegerPixelSize`. See the
// file banner for why this matters just as much in C++ as it does in
// Swift, for a different reason.
std::optional<IntegerPixelSize> integerPixels(const Vec2& size);

// The front view's anchor-preserving zoom: zoom toward `anchor` (a view
// point) so whatever is under it stays under it. `scale` is a STEP, not a
// cumulative factor -- a caller driving this from a continuous gesture
// divides out the previous cumulative value first (`MagnificationGesture`
// reports cumulative; feeding it straight in would zoom by the whole
// gesture on every event).
//
// A `scale` of 0.01 or below is a no-op (matches Swift's guard): returns
// `frontView` unchanged rather than dividing by something that has
// collapsed to nothing.
SceneFrontView pinchZoomFrontView(const SceneFrontView& frontView, float scale, const Vec2& anchor,
                                   const Vec2& pixelSize, const Vec2& viewSize);

// The Shift-drag-in-depth math: `translationHeightPoints` is the
// gesture's vertical translation in points (screen-down positive, Swift's
// convention), scaled by the card's distance from the camera so the same
// finger travel feels the same near and far, and clamped to stay past the
// camera's near plane by at least one unit.
float depthDragZ(float startZ, float cameraPositionZ, float cameraNearZ,
                  float translationHeightPoints, float viewHeightPoints);

} // namespace umeshcore
