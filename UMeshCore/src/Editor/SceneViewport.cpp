#include "umeshcore/Editor/SceneViewport.h"

#include <algorithm>
#include <cmath>

namespace umeshcore {

namespace {
// Swift's `max(v, 1)`, exactly -- not `v > 1 ? v : 1`. The two differ on
// NaN: Swift's `max(x, y)` is `y >= x ? y : x`, so `max(NaN, 1)` compares
// `1 >= NaN` (false, every NaN comparison is) and returns the FIRST
// argument, NaN, propagating it. A ternary on `v > 1` would instead
// compare `NaN > 1` (also false) and return the literal `1`, silently
// laundering the NaN into a finite denominator -- exactly the guard the
// file banner says `integerPixels` depends on downstream NOT having
// happened yet.
float clampMin1(float v) { return (1.0f >= v) ? 1.0f : v; }
} // namespace

Bounds2D fittedRect(const Vec2& pixelSize, const Vec2& viewSize, bool isFlying,
                     const SceneFrontView& frontView) {
    const float scale =
        std::min(viewSize.x / clampMin1(pixelSize.x), viewSize.y / clampMin1(pixelSize.y));
    const Vec2 size(pixelSize.x * scale, pixelSize.y * scale);
    const Vec2 baseMin((viewSize.x - size.x) * 0.5f, (viewSize.y - size.y) * 0.5f);
    const Bounds2D base{baseMin, baseMin + size};
    if (isFlying) return base;

    // The front view's pan and zoom, laid on top of the base fit.
    const Vec2 center = base.center();
    const Vec2 zoomedSize(size.x * frontView.zoom, size.y * frontView.zoom);
    const Vec2 zoomedMin(center.x - zoomedSize.x * 0.5f + frontView.pan.x,
                          center.y - zoomedSize.y * 0.5f + frontView.pan.y);
    return Bounds2D{zoomedMin, zoomedMin + zoomedSize};
}

Vec2 viewPointFromImage(const Vec2& image, const Vec2& pixelSize, const Bounds2D& fitted) {
    const Vec2 size = fitted.size();
    return Vec2(fitted.min.x + (image.x / clampMin1(pixelSize.x)) * size.x,
                fitted.min.y + (image.y / clampMin1(pixelSize.y)) * size.y);
}

Vec2 imagePointFromView(const Vec2& viewPoint, const Vec2& pixelSize, const Bounds2D& fitted) {
    const Vec2 size = fitted.size();
    return Vec2(((viewPoint.x - fitted.min.x) / clampMin1(size.x)) * pixelSize.x,
                ((viewPoint.y - fitted.min.y) / clampMin1(size.y)) * pixelSize.y);
}

Vec2 renderPixelSize(const Vec2& viewSize, float displayScale, bool isFlying, bool isProvisional,
                      float budgetScale, const Vec2& compositionRenderSize) {
    if (!(viewSize.x > 1.0f) || !(viewSize.y > 1.0f)) return Vec2(16.0f, 16.0f);

    const float pixelScale = displayScale;
    const float ladder = isProvisional ? budgetScale : 1.0f;

    if (isFlying) {
        const float base = isProvisional ? SceneViewportPixelCaps::kInteractiveEditorPixels
                                          : SceneViewportPixelCaps::kMaxEditorPixels;
        const float cap = base * ladder;
        const float longest = std::max(viewSize.x, viewSize.y) * pixelScale;
        const float scale = std::min(1.0f, cap / clampMin1(longest)) * pixelScale;
        return Vec2(viewSize.x * scale, viewSize.y * scale);
    }

    const float aspect = compositionRenderSize.x / clampMin1(compositionRenderSize.y);
    const float base = isProvisional ? SceneViewportPixelCaps::kInteractiveShotPixels
                                      : SceneViewportPixelCaps::kMaxShotPixels;
    const float height = std::min(viewSize.y * pixelScale, base * ladder);
    return Vec2(height * aspect, height);
}

std::optional<IntegerPixelSize> integerPixels(const Vec2& size) {
    if (!std::isfinite(size.x) || !std::isfinite(size.y)) return std::nullopt;
    if (size.x < 1.0f || size.y < 1.0f) return std::nullopt;
    if (size.x >= 65536.0f || size.y >= 65536.0f) return std::nullopt;
    return IntegerPixelSize{static_cast<int>(size.x), static_cast<int>(size.y)};
}

SceneFrontView pinchZoomFrontView(const SceneFrontView& frontView, float scale, const Vec2& anchor,
                                   const Vec2& pixelSize, const Vec2& viewSize) {
    if (!(scale > 0.01f)) return frontView;

    const Bounds2D before = fittedRect(pixelSize, viewSize, false, frontView);
    const Vec2 beforeSize = before.size();
    if (!(beforeSize.x > 1.0f) || !(beforeSize.y > 1.0f)) return frontView;

    const Vec2 u((anchor.x - before.min.x) / beforeSize.x, (anchor.y - before.min.y) / beforeSize.y);

    SceneFrontView result = frontView;
    result.zoomBy(scale);

    const Bounds2D after = fittedRect(pixelSize, viewSize, false, result);
    const Vec2 afterSize = after.size();
    const Vec2 landed(after.min.x + u.x * afterSize.x, after.min.y + u.y * afterSize.y);
    result.pan += Vec2(anchor.x - landed.x, anchor.y - landed.y);
    return result;
}

float depthDragZ(float startZ, float cameraPositionZ, float cameraNearZ,
                  float translationHeightPoints, float viewHeightPoints) {
    const float distance = std::max(startZ - cameraPositionZ, 1.0f);
    const float dz = -translationHeightPoints / clampMin1(viewHeightPoints) * distance * 2.0f;
    return std::max(startZ + dz, cameraPositionZ + cameraNearZ + 1.0f);
}

} // namespace umeshcore
