#pragma once

// 1:1 port of `Data/AnimationLibrary.swift` -- the named-animation library:
// several complete animations over one rig, each a snapshot of every bone
// and sprite clip plus the scene-wide timelines, with exactly one active at
// a time. Listed in ROADMAP.md's Phase 1 as still-unported; reached here
// because Phase 3's project manifest persists it (`SavedNamedAnimation`),
// and a manifest that can't round-trip the library would lose an artist's
// other animations on save.
//
// Takes an `EditorScene&` where Swift takes `SceneManager` -- the same
// substitution the rest of this port makes, and the reason the library is
// a class holding a reference rather than free functions: Swift's is an
// `ObservableObject` owning `animations`/`activeID` alongside the scene it
// snapshots, and that ownership is real state, not UI plumbing.
//
// The Swift comments name two non-obvious rules this port keeps:
//   - `restore` deliberately does NOT snapshot the live clips first. The
//     project was just loaded, so those clips ARE the active animation's,
//     and snapshotting over the list would overwrite what came out of the
//     file with a copy of one of its own entries.
//   - `switchTo` saves the outgoing animation even when the target is
//     already active, then returns without reloading -- so the scene's
//     live clips are never overwritten with a stale library snapshot.

#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "umeshcore/Animation/AnimationClip.h"
#include "umeshcore/Constraints/ConstraintAnimation.h"
#include "umeshcore/Core/Uuid.h"

namespace umeshcore {

class EditorScene;

struct NamedAnimation {
    Uuid id = Uuid::generate();
    std::string name;
    std::unordered_map<Uuid, AnimationClip, UuidHash> boneClips;
    std::unordered_map<Uuid, AnimationClip, UuidHash> imageClips;
    // Constraint property and draw order timelines.
    AnimationClip sceneClip{"Scene"};
    // Authored constraint values captured when a property was first keyed.
    std::unordered_map<Uuid, ConstraintSetupValues, UuidHash> constraintSetupValues;
    int duration = 0;
};

class AnimationLibrary {
public:
    explicit AnimationLibrary(EditorScene& scene) : scene_(scene) {}

    const std::vector<NamedAnimation>& animations() const { return animations_; }
    const std::optional<Uuid>& activeID() const { return activeID_; }
    const NamedAnimation* active() const;

    // Puts a saved library back, as-is. See the header on why this does
    // not snapshot first. An `activeID` naming nothing in the list falls
    // back to no selection rather than a dangling one.
    void restore(std::vector<NamedAnimation> animations, std::optional<Uuid> activeID);

    // Captures the current state of every bone/sprite clip as a new
    // animation, first folding the live edits back into the outgoing one
    // so they are not lost.
    void createFromCurrentState(const std::string& name);

    void switchTo(Uuid id);
    void rename(Uuid id, const std::string& newName);
    void remove(Uuid id);

private:
    NamedAnimation snapshotCurrent(const std::string& name, std::optional<Uuid> id = std::nullopt) const;
    void applyToScene(const NamedAnimation& animation);

    EditorScene& scene_;
    std::vector<NamedAnimation> animations_;
    std::optional<Uuid> activeID_;
};

} // namespace umeshcore
