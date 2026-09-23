#pragma once

// 1:1 port of `Data/IKBuilder.swift` (201 L) -- the draft, rules and
// validation behind the IK builder panel.
//
// WHY THE BUILDER EXISTS (from the Swift header): the old flow inferred an
// IK constraint from the multi-selection, and "whichever bone sat deepest
// silently became the target". That is impossible to predict from the
// viewport and breaks outright for the common rig where the target is an
// unparented handle bone -- the SHALLOWEST bone -- so the rule picked the
// wrong one every time. Here the chain and the target are two explicit
// slots, and validation says in words what is wrong before anything is
// created.
//
// The builder's live draft (which slot is being picked, the hovered bone)
// is state on `EditorScene`; this file is the rules, which are pure
// functions of a draft and a skeleton.
//
// Two ordering details, both deterministic here where Swift is not:
//   - `hierarchicalOrder` sorts siblings by name with
//     `localizedStandardCompare`, ported as `naturalCompare` (see
//     Core/NaturalCompare.h for its one, cosmetic, divergence). Two
//     siblings with the SAME name keep whatever order Swift's dictionary
//     gave them, which differs between runs; here the tie breaks on id so
//     the list is the same every launch.
//   - The same for the unreachable-bones pass.

#include <optional>
#include <string>
#include <vector>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Model/Bone.h"
#include "umeshcore/Model/Skeleton.h"

namespace umeshcore {

enum class IKBuilderSlot { Chain, Target };

struct IKBuilderDraft {
    std::vector<Uuid> chain;
    std::optional<Uuid> targetID;
    // Set while the canvas is in pick mode for that slot.
    std::optional<IKBuilderSlot> pickingSlot;
    std::string name;
    bool bendPositive = true;
    float mix = 1.0f;

    bool isEmpty() const { return chain.empty() && !targetID.has_value(); }
    bool operator==(const IKBuilderDraft&) const = default;
};

// The message doubles as the identity: two identical complaints are one.
struct IKBuilderProblem {
    std::string message;
    // Blocking problems prevent creation; the rest are advice.
    bool isBlocking = false;
    bool operator==(const IKBuilderProblem&) const = default;
};

struct IKBuilderValidation {
    std::vector<IKBuilderProblem> problems;

    std::vector<IKBuilderProblem> blocking() const;
    std::vector<IKBuilderProblem> advisory() const;
    bool canCreate() const;
    bool operator==(const IKBuilderValidation&) const = default;
};

struct IKBuilderOrderedBone {
    Bone bone;
    int depth = 0;
};

namespace IKBuilderRules {

// Bones from `ancestor` down to `descendant`, inclusive, or nothing when
// they are not on one branch. Walks UP from the descendant (one parent
// each, nothing to search), capped at 256 steps as the Swift is.
std::optional<std::vector<Uuid>> path(Uuid ancestor, Uuid descendant, const Skeleton& skeleton);

// `candidate` is `root` or sits underneath it.
bool isDescendant(Uuid candidate, Uuid root, const Skeleton& skeleton);

// Adds a bone the way an artist expects: shoulder then hand fills in the
// elbow; clicking a bone already in the chain removes it and everything
// after it (an interior gap would break the limb); a bone on another
// branch is appended anyway so nothing the artist did disappears, and
// validation then says where the run breaks.
std::vector<Uuid> addToChain(Uuid boneID, const std::vector<Uuid>& chain, const Skeleton& skeleton);

// Bones in hierarchy order, children sorted by name, with their depth.
// Bones unreachable from a root (a corrupt or cyclic parent link) are
// still listed, at depth 0, so they stay pickable.
std::vector<IKBuilderOrderedBone> hierarchicalOrder(const Skeleton& skeleton);

IKBuilderValidation validate(const IKBuilderDraft& draft, const Skeleton& skeleton);

// One plain sentence describing what the finished constraint will do.
std::string summary(const IKBuilderDraft& draft, const Skeleton& skeleton);

} // namespace IKBuilderRules

} // namespace umeshcore
