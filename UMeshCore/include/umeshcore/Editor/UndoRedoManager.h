#pragma once

// 1:1 port of `UltraMesh 2d animation/UndoRedoManager.swift`.
//
// SceneSnapshot omits two Swift fields not yet ported: `constraintSetupValues`
// (Data/ConstraintAnimation.swift, authored-vs-animated constraint value
// bookkeeping) and `sceneCompositions`/`selectedSceneCompositionID` (Scene
// compositing, Phase 5). Both are pure additive fields in the Swift struct,
// so adding them here later is a mechanical, non-breaking change -- this
// class's undo/redo stack logic itself does not need to change when they
// land, only the SceneSnapshot struct grows.

#include <optional>
#include <vector>

#include "umeshcore/Animation/AnimationClip.h"
#include "umeshcore/Animation/AnimationEvent.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Model/SceneImage.h"
#include "umeshcore/Model/Skeleton.h"
#include "umeshcore/Model/Skin.h"

namespace umeshcore {

// Snapshot of mutable scene state -- copying is O(N) but safe (plain value
// types throughout).
struct SceneSnapshot {
    std::vector<SceneImage> images;
    Skeleton skeleton;
    // Scene-wide animation tracks: constraint properties and draw order.
    AnimationClip sceneAnimationClip = AnimationClip("Scene");
    std::vector<Skin> skins;
    std::optional<Uuid> activeSkinID;
    std::vector<AnimationEvent> animationEvents;
};

class UndoRedoManager {
public:
    // Push the current state before a mutation. Clears the redo stack.
    void push(SceneSnapshot snapshot) {
        undoStack_.push_back(std::move(snapshot));
        if (undoStack_.size() > kMaxDepth) undoStack_.erase(undoStack_.begin());
        redoStack_.clear();
        sync();
    }

    // Returns the state to restore, saving `current` for redo.
    std::optional<SceneSnapshot> undo(SceneSnapshot current) {
        if (undoStack_.empty()) return std::nullopt;
        SceneSnapshot previous = std::move(undoStack_.back());
        undoStack_.pop_back();
        redoStack_.push_back(std::move(current));
        sync();
        return previous;
    }

    // Returns the state to restore, saving `current` for undo.
    std::optional<SceneSnapshot> redo(SceneSnapshot current) {
        if (redoStack_.empty()) return std::nullopt;
        SceneSnapshot next = std::move(redoStack_.back());
        redoStack_.pop_back();
        undoStack_.push_back(std::move(current));
        sync();
        return next;
    }

    bool canUndo() const { return canUndo_; }
    bool canRedo() const { return canRedo_; }

private:
    static constexpr std::size_t kMaxDepth = 80;

    std::vector<SceneSnapshot> undoStack_;
    std::vector<SceneSnapshot> redoStack_;
    bool canUndo_ = false;
    bool canRedo_ = false;

    void sync() {
        canUndo_ = !undoStack_.empty();
        canRedo_ = !redoStack_.empty();
    }
};

} // namespace umeshcore
