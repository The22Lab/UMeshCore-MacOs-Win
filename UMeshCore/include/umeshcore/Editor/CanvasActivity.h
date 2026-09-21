#pragma once

// Minimal stand-in for `Core/CanvasActivity.swift`'s wake door. The full
// idle/sleep-gating logic (input events, time-based probes, view-level
// events) is platform/render-loop plumbing that belongs in the Mac/Windows
// shells (Phase 6), not in the portable core. What DOES belong here is the
// seam other core types call into -- CameraState wakes the canvas on every
// mutation, exactly as `Core/CameraState.swift` does via its `weak var
// activity: CanvasActivity?` -- so that seam is defined once, here, rather
// than duplicated per platform.

namespace umeshcore {

class CanvasActivity {
public:
    virtual ~CanvasActivity() = default;
    virtual void wake() = 0;
};

} // namespace umeshcore
