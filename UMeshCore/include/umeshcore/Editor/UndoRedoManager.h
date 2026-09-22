#pragma once

// 1:1 port of `UltraMesh 2d animation/UndoRedoManager.swift`.
//
// `SceneSnapshot` now carries all NINE fields the Swift struct does. The
// last three arrived with Phase 5 and were called out here as a mechanical
// addition when their types landed; they are not decoration:
//
//   - `constraintSetupValues` -- the AUTHORED (setup pose) constraint
//     values. Restored alongside the clip so undoing a keyed change cannot
//     leave a constraint sitting at an evaluated value.
//   - `sceneCompositions` / `selectedSceneCompositionID` -- so undoing an
//     "Align Camera to View", a layer edit or a scene deletion restores
//     THE SHOT. Without them undo rolls the rig back and leaves the camera
//     where the mistake put it.
//
// The fly camera (`sceneViewCamera`) is deliberately ABSENT, matching
// Swift: where the artist is standing is not an edit.
//
// What is still not snapshotted, in Swift or here, and is worth knowing
// before assuming it is a bug: `hierarchyItems`, `authoredDrawOrder`, all
// selection, and the playback range. Hierarchy names and order are
// therefore not undoable today -- Swift's `applySnapshot` only FILTERS
// `hierarchyItems` afterwards, dropping entries whose id is neither a live
// image nor a live bone.

#include <optional>
#include <vector>

#include "umeshcore/Animation/AnimationClip.h"
#include "umeshcore/Animation/AnimationEvent.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Model/SceneImage.h"
#include "umeshcore/Model/Skeleton.h"
#include "umeshcore/Model/Skin.h"
#include "umeshcore/Constraints/ConstraintAnimation.h"
#include "umeshcore/Scene/SceneComposition.h"

#include <unordered_map>

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
    // Authored constraint values -- see the file header.
    std::unordered_map<Uuid, ConstraintSetupValues, UuidHash> constraintSetupValues;
    // The shot, so undo restores it too.
    std::vector<SceneComposition> sceneCompositions;
    std::optional<Uuid> selectedSceneCompositionID;
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
