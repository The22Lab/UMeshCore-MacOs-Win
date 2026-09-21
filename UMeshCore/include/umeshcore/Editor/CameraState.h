#pragma once

// 1:1 port of `Core/CameraState.swift`.
//
// One platform adaptation, documented rather than hidden: Swift's
// `update(deltaTime:viewSize:)` reads the wall clock directly via
// `CACurrentMediaTime()` inside Core, which this library cannot do (no
// platform clock dependency allowed in UMeshCore). Time is passed in
// explicitly instead (`currentTime`, in seconds, any monotonic origin as
// long as it's consistent between calls) -- the same pattern already used
// by PhysicsConstraintSystem::setFrameTime for the identical reason.

#include <cmath>
#include <optional>

#include "umeshcore/Editor/Bounds2D.h"
#include "umeshcore/Editor/CanvasActivity.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

class CameraState {
public:
    Vec2 origin = Vec2::zero();
    float zoom = 1.0f;
    float rotation = 0.0f;

    // The canvas is allowed to sleep when nothing is happening, and moving
    // the camera is something happening -- every mutator below wakes this.
    // Non-owning (mirrors Swift's `weak var`); the owner is responsible for
    // keeping it valid or clearing it.
    CanvasActivity* activity = nullptr;

    // True while frame(...) is flying the camera to a new framing.
    bool isAnimating() const { return animationStartTime_.has_value(); }

    void pan(const Vec2& screenDelta) {
        wake();
        cancelAnimation();
        const Vec2 worldDelta(screenDelta.x / zoom, screenDelta.y / zoom);
        origin.x -= worldDelta.x;
        origin.y -= worldDelta.y;
    }

    void zoomAt(const Vec2& screenPoint, const Vec2& viewSize, float scrollDelta) {
        wake();
        cancelAnimation();
        const float factor = std::pow(1.003f, scrollDelta);
        const float proposed = zoom * factor;
        const float clamped = std::min(kMaxZoom, std::max(kMinZoom, proposed));
        if (!std::isfinite(clamped)) return;

        const Vec2 worldBefore = screenToWorld(screenPoint, viewSize);
        zoom = clamped;
        const Vec2 worldAfter = screenToWorld(screenPoint, viewSize);
        origin.x += worldBefore.x - worldAfter.x;
        origin.y += worldBefore.y - worldAfter.y;
    }

    // Direct multiplicative zoom anchored at screenPoint, for touch pinch
    // gestures: the zoom tracks the gesture's raw scale factor 1:1, no
    // exponential remapping/smoothing/damping. `screenPoint`/`viewSize`
    // must be in the same units the renderer uses (drawable pixels).
    void zoomBy(float scaleFactor, const Vec2& screenPoint, const Vec2& viewSize) {
        wake();
        cancelAnimation();
        if (!std::isfinite(scaleFactor) || !(scaleFactor > 0.0f)) return;
        const float clamped = std::min(kMaxZoom, std::max(kMinZoom, zoom * scaleFactor));
        if (!std::isfinite(clamped)) return;
        const Vec2 worldBefore = screenToWorld(screenPoint, viewSize);
        zoom = clamped;
        const Vec2 worldAfter = screenToWorld(screenPoint, viewSize);
        origin.x += worldBefore.x - worldAfter.x;
        origin.y += worldBefore.y - worldAfter.y;
    }

    void frame(
        const Bounds2D& bounds, const Vec2& viewSize, float padding, double duration, double currentTime) {
        wake();
        lastViewSize_ = viewSize;
        const Vec2 size(std::max(bounds.size().x, 1.0f), std::max(bounds.size().y, 1.0f));
        const Vec2 padded(size.x + padding * 2.0f, size.y + padding * 2.0f);
        const float zoomX = viewSize.x / std::max(padded.x, 1.0f);
        const float zoomY = viewSize.y / std::max(padded.y, 1.0f);
        const float targetZoom = std::min(kMaxZoom, std::max(kMinZoom, std::min(zoomX, zoomY)));
        const Vec2 targetOrigin(bounds.center().x, bounds.center().y);
        startAnimation(targetOrigin, targetZoom, duration, currentTime);
    }

    void frame(const Bounds2D& bounds, float padding, double duration, double currentTime) {
        frame(bounds, lastViewSize_, padding, duration, currentTime);
    }

    void update(double currentTime, const Vec2& viewSize) {
        lastViewSize_ = viewSize;
        if (!animationStartTime_.has_value()) return;
        const double elapsed = std::max(0.0, currentTime - *animationStartTime_);
        const double t = std::min(1.0, elapsed / std::max(0.0001, animationDuration_));
        const double eased = easeInOut(t);
        origin.x = animationStartOrigin_.x +
                   static_cast<float>((animationTargetOrigin_.x - animationStartOrigin_.x) * eased);
        origin.y = animationStartOrigin_.y +
                   static_cast<float>((animationTargetOrigin_.y - animationStartOrigin_.y) * eased);
        zoom = animationStartZoom_ + static_cast<float>((animationTargetZoom_ - animationStartZoom_) * eased);
        if (t >= 1.0) animationStartTime_ = std::nullopt;
    }

    Vec2 screenToWorld(const Vec2& point, const Vec2& viewSize) const {
        const Vec2 centered(point.x - viewSize.x * 0.5f, point.y - viewSize.y * 0.5f);
        return Vec2(centered.x / zoom + origin.x, -(centered.y / zoom) + origin.y);
    }

    Vec2 worldToScreen(const Vec2& point, const Vec2& viewSize) const {
        const Vec2 centered((point.x - origin.x) * zoom, (point.y - origin.y) * zoom);
        return Vec2(centered.x + viewSize.x * 0.5f, -centered.y + viewSize.y * 0.5f);
    }

    void restore(const Vec2& newOrigin, float newZoom, float newRotation) {
        wake();
        cancelAnimation();
        origin = newOrigin;
        zoom = std::min(kMaxZoom, std::max(kMinZoom, newZoom));
        rotation = newRotation;
    }

private:
    Vec2 lastViewSize_ = Vec2::zero();
    std::optional<double> animationStartTime_;
    double animationDuration_ = 0.0;
    Vec2 animationStartOrigin_ = Vec2::zero();
    float animationStartZoom_ = 1.0f;
    Vec2 animationTargetOrigin_ = Vec2::zero();
    float animationTargetZoom_ = 1.0f;

    static constexpr float kMinZoom = 0.05f;
    static constexpr float kMaxZoom = 20.0f;

    void wake() {
        if (activity != nullptr) activity->wake();
    }

    void startAnimation(const Vec2& targetOrigin, float targetZoom, double duration, double currentTime) {
        animationStartOrigin_ = origin;
        animationStartZoom_ = zoom;
        animationTargetOrigin_ = targetOrigin;
        animationTargetZoom_ = targetZoom;
        animationDuration_ = duration;
        animationStartTime_ = currentTime;
    }

    void cancelAnimation() { animationStartTime_ = std::nullopt; }

    static double easeInOut(double t) { return t < 0.5 ? 2.0 * t * t : 1.0 - std::pow(-2.0 * t + 2.0, 2.0) / 2.0; }
};

} // namespace umeshcore
