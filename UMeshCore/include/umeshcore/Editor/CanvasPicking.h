#pragma once

// Port of the arbitration half of `Core/CanvasPicking.swift`: "what is
// under the cursor -- one answer, one route." The Swift file's own header
// comment explains why this exists (a bone always won over a direct hit on
// a sprite's opaque pixel; a near miss on a thin bone could beat a direct
// hit; picking order didn't match draw order) -- the rule it settles on is
// "a hit ON something beats a hit NEAR something, whatever kind of thing it
// is, and ties are broken by what is drawn in front."
//
// NOT PORTED HERE: `CanvasPicking.imageHit` itself (alpha-channel sampling
// against a sprite's loaded texture -- needs Phase 4/5's asset pipeline,
// same gap `ToolUtilities.h` already documents for `hitTestScreen`/
// `hitTestRect`/`hitTestSelectionTarget`). Everything AROUND it -- the bone
// hit-test, and the direct-vs-near/bone-vs-image arbitration in `target()`
// below -- has no dependency on textures and is ported here in full.
//
// To keep `target()` (and therefore `ToolManager`'s selection-click
// dispatch, which calls it) usable before that pipeline exists, the image
// hit-test is injected as a callback (`ImageHitTestFn`) rather than blocking
// this whole file on it -- the same "inject what's needed" pattern
// `ToolUtilities.h` already uses throughout. A platform layer with no
// texture pipeline yet can pass a callback that always returns nullopt,
// which makes `target()` degrade to bone-only picking: a real, correct
// behavior (exactly how a rig with no art loaded already behaves), not a
// stub standing in for one.

#include <functional>
#include <optional>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Editor/CameraState.h"
#include "umeshcore/Editor/ToolUtilities.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Model/Skeleton.h"

namespace umeshcore {

// Mirrors `ToolUtilities.SelectionTarget` (Swift `enum SelectionTarget`):
// what a click ultimately resolves to.
struct SelectionTarget {
    enum class Kind { Image, Bone };
    Kind kind;
    Uuid id;

    static SelectionTarget image(Uuid id) { return SelectionTarget{Kind::Image, id}; }
    static SelectionTarget bone(Uuid id) { return SelectionTarget{Kind::Bone, id}; }

    bool operator==(const SelectionTarget&) const = default;
};

// Mirrors `CanvasPicking.Hit` for the image side -- what an alpha-based
// image hit-test reports.
struct ImageHit {
    Uuid id;
    // True when the point is ON an opaque pixel of the sprite; false when
    // it was caught only by a bounding-slop fallback for a thin/transparent
    // sprite.
    bool isDirect = false;
    // Screen-space distance in points; zero for a direct hit.
    float distance = 0.0f;
};

// Supplied by the platform layer -- see this file's header comment.
using ImageHitTestFn =
    std::function<std::optional<ImageHit>(const Vec2& screenPoint, const Vec2& viewSize, CameraState* camera)>;

// A bone or a sprite, whichever the click actually landed on -- the single
// arbitration point `ToolManager`'s selection click, `SelectTool`, and
// `MoveTool` all read through.
//
// `hitScale`/`touchOptimized`/`displayScale` are forwarded to
// `ToolUtilities::hitTestBoneDetailed` exactly as that function documents;
// `boneDirectRadius` (how near a bone has to be to count as a direct hit,
// not a near miss) is `6 * hitScale`, matching the Swift source's
// `6 * ToolUtilities.touchHitScale` now that `hitScale` is the caller-
// supplied value standing in for `touchHitScale` throughout this port.
std::optional<SelectionTarget> target(
    const Vec2& screenPoint, const Vec2& viewSize, const Skeleton& skeleton,
    std::optional<Uuid> selectedBoneID, CameraState* camera, float hitScale, bool touchOptimized,
    const ImageHitTestFn& imageHitTest, float displayScale = 2.0f);

} // namespace umeshcore
