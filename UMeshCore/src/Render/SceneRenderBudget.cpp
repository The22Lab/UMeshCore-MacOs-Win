#include "umeshcore/Render/SceneRenderBudget.h"

#include <algorithm>

namespace umeshcore {

float SceneRenderBudget::scale() const {
    return kLadder[std::min(std::max(rung_, 0), kLadderSize - 1)];
}

void SceneRenderBudget::record(double milliseconds, bool isProvisional) {
    if (!isProvisional) {
        // No ratcheting: a still canvas has all the time in the world.
        rung_ = 0;
        comfortableFrames_ = 0;
        return;
    }
    const double target = kInteractiveTargetMilliseconds;
    if (milliseconds > target) {
        // ONE RUNG AT A TIME, however slow the frame was. A single
        // catastrophic frame -- a sheet animating over the canvas, the
        // project being opened -- is not evidence about the steady state,
        // and dropping three rungs for it would take three seconds of good
        // frames to undo.
        rung_ = std::min(rung_ + 1, kLadderSize - 1);
        comfortableFrames_ = 0;
        return;
    }
    if (rung_ <= 0) {
        comfortableFrames_ = 0;
        return;
    }
    // WOULD THE RUNG ABOVE FIT? Cost goes as the pixels and the pixels go
    // as the square of the scale, so the answer is this frame's cost times
    // the square of the ratio between the two rungs.
    const double ratio = static_cast<double>(kLadder[rung_ - 1] / kLadder[rung_]);
    const double predicted = milliseconds * ratio * ratio;
    if (!(predicted <= target * kClimbSafety)) {
        // Comfortable here, and would not be up there. Stay, and do not
        // accumulate credit towards a climb that would only be undone.
        comfortableFrames_ = 0;
        return;
    }
    ++comfortableFrames_;
    if (comfortableFrames_ >= kFramesBeforeClimbing) {
        --rung_;
        comfortableFrames_ = 0;
    }
}

void SceneRenderBudget::reset() {
    rung_ = 0;
    comfortableFrames_ = 0;
}

void FrameCostMeter::record(double milliseconds) {
    samples_.push_back(milliseconds);
    if (samples_.size() > kWindow) {
        samples_.erase(samples_.begin(), samples_.begin() + static_cast<std::ptrdiff_t>(samples_.size() - kWindow));
    }
}

double FrameCostMeter::milliseconds() const {
    if (samples_.empty()) return 0.0;
    std::vector<double> sorted = samples_;
    std::sort(sorted.begin(), sorted.end());
    // The upper middle for an even count, exactly as Swift's
    // `sorted[sorted.count / 2]` picks it.
    return sorted[sorted.size() / 2];
}

} // namespace umeshcore
