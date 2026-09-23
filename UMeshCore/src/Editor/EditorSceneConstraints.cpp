// EditorScene -- constraints: the IK builder's live draft, create /
// duplicate / delete / rename / reorder / retarget for all four kinds, and
// the constraint animation entry points the inspector and timeline call.
//
// Ported from `Data/SceneManager.swift`: `// MARK: - IK builder`, the
// Transform / Physics management sections, the `// MARK: - IK / Path /
// Physics constraint management` extension, and the constraint half of
// `// MARK: - Constraint & draw order animation` (setup capture, queries,
// editing).

#include "umeshcore/Editor/EditorScene.h"

#include <algorithm>
#include <cctype>

namespace umeshcore {

namespace {

std::string trimmed(const std::string& s) {
    std::size_t b = 0, e = s.size();
    while (b < e && std::isspace(static_cast<unsigned char>(s[b]))) ++b;
    while (e > b && std::isspace(static_cast<unsigned char>(s[e - 1]))) --e;
    return s.substr(b, e - b);
}

// Swift's `Array.move(fromOffsets:toOffset:)`: the moved elements keep
// their relative order and land before the element that was at `toOffset`
// in the ORIGINAL array (so the destination is measured before anything is
// removed, which is the part a hand-rolled erase/insert gets wrong).
template <typename T>
void moveFromOffsets(std::vector<T>& v, const std::vector<int>& offsets, int toOffset) {
    std::vector<bool> moving(v.size(), false);
    for (int o : offsets) moving[static_cast<std::size_t>(o)] = true;
    std::vector<T> moved, kept;
    int insertAt = 0;
    for (std::size_t i = 0; i < v.size(); ++i) {
        if (moving[i]) {
            moved.push_back(v[i]);
        } else {
            if (static_cast<int>(i) < toOffset) insertAt += 1;
            kept.push_back(v[i]);
        }
    }
    kept.insert(kept.begin() + insertAt, moved.begin(), moved.end());
    v = std::move(kept);
}

template <typename T>
bool validOffsets(const std::vector<T>& v, const std::vector<int>& offsets) {
    if (offsets.empty()) return false;
    return std::all_of(offsets.begin(), offsets.end(),
                       [&](int o) { return o >= 0 && o < static_cast<int>(v.size()); });
}

template <typename T>
std::optional<std::size_t> indexOfID(const std::vector<T>& v, Uuid id) {
    for (std::size_t i = 0; i < v.size(); ++i) {
        if (v[i].id() == id) return i;
    }
    return std::nullopt;
}

bool containsID(const std::vector<Uuid>& v, Uuid id) { return std::find(v.begin(), v.end(), id) != v.end(); }

std::string presetDisplayName(PhysicsPreset preset) {
    // Swift: `rawValue.capitalized`.
    switch (preset) {
        case PhysicsPreset::Hair: return "Hair";
        case PhysicsPreset::Tail: return "Tail";
        case PhysicsPreset::Cape: return "Cape";
        case PhysicsPreset::Rope: return "Rope";
        case PhysicsPreset::Chain: return "Chain";
        case PhysicsPreset::Jiggle: return "Jiggle";
        case PhysicsPreset::Breast: return "Breast";
        case PhysicsPreset::Custom: return "Custom";
    }
    return "Custom";
}

} // namespace

// ---- Physics --------------------------------------------------------------------

void EditorScene::setPhysicsPreviewActive(bool active) {
    physics.isActive = active;
    if (!active) physics.reset();
}

void EditorScene::resetPhysicsSimulation() { physics.reset(); }

// Swift: "Stub: bake physics simulation to animation keyframes. Full
// implementation requires stepping the sim forward N frames and committing
// keyframes -- scheduled for Phase 2." The body is a TODO. The menu item is
// live and does nothing; porting it as something would be inventing a
// feature, so it does nothing here too. When Swift grows a body, this is
// the one to port.
void EditorScene::bakePhysicsToKeys() {}

// ---- IK builder -----------------------------------------------------------------

void EditorScene::beginIKBuilder() {
    IKBuilderDraft draft;
    draft.name = "IK " + std::to_string(skeleton.ikConstraints.size() + 1);
    const std::vector<Bone> ordered = selectedBonesInChainOrder();
    if (ordered.size() == 1) {
        draft.chain = {ordered[0].id};
    } else if (ordered.size() > 1) {
        // Only a genuinely contiguous selection seeds a chain; a scattered
        // one would open the panel already invalid.
        std::vector<Uuid> ids;
        for (const Bone& b : ordered) ids.push_back(b.id);
        const auto full = IKBuilderRules::path(ids.front(), ids.back(), skeleton);
        draft.chain = (full.has_value() && *full == ids) ? ids : std::vector<Uuid>{ids.front()};
    }
    // Picking starts on whichever slot is still empty.
    draft.pickingSlot = draft.chain.empty() ? IKBuilderSlot::Chain : IKBuilderSlot::Target;
    ikBuilder = draft;
}

void EditorScene::cancelIKBuilder() {
    ikBuilder = std::nullopt;
    ikBuilderHoveredBoneID = std::nullopt;
}

IKBuilderValidation EditorScene::ikBuilderValidation() const {
    if (!ikBuilder.has_value()) return IKBuilderValidation{};
    return IKBuilderRules::validate(*ikBuilder, skeleton);
}

bool EditorScene::ikBuilderHandleBonePick(Uuid boneID) {
    if (!ikBuilder.has_value() || !ikBuilder->pickingSlot.has_value()) return false;
    IKBuilderDraft draft = *ikBuilder;
    switch (*draft.pickingSlot) {
        case IKBuilderSlot::Chain:
            draft.chain = IKBuilderRules::addToChain(boneID, draft.chain, skeleton);
            // Clicking the bone that is the target moves it into the chain.
            if (draft.targetID == boneID) draft.targetID = std::nullopt;
            break;
        case IKBuilderSlot::Target:
            draft.targetID = (draft.targetID == boneID) ? std::nullopt : std::optional<Uuid>(boneID);
            break;
    }
    ikBuilder = draft;
    return true;
}

void EditorScene::ikBuilderSetPicking(std::optional<IKBuilderSlot> slot) {
    if (!ikBuilder.has_value()) return;
    ikBuilder->pickingSlot = (ikBuilder->pickingSlot == slot) ? std::nullopt : slot;
    if (!ikBuilder->pickingSlot.has_value()) ikBuilderHoveredBoneID = std::nullopt;
}

void EditorScene::ikBuilderSetChain(const std::vector<Uuid>& chain) {
    if (ikBuilder.has_value()) ikBuilder->chain = chain;
}

void EditorScene::ikBuilderSetTarget(std::optional<Uuid> boneID) {
    if (!ikBuilder.has_value()) return;
    ikBuilder->targetID = boneID;
    if (boneID.has_value()) {
        // A bone cannot be both the chain and what the chain reaches for.
        auto it = std::find(ikBuilder->chain.begin(), ikBuilder->chain.end(), *boneID);
        if (it != ikBuilder->chain.end()) ikBuilder->chain.erase(it);
    }
}

void EditorScene::ikBuilderSetName(const std::string& name) {
    if (ikBuilder.has_value()) ikBuilder->name = name;
}

void EditorScene::ikBuilderSetBendPositive(bool value) {
    if (ikBuilder.has_value()) ikBuilder->bendPositive = value;
}

void EditorScene::ikBuilderSetMix(float value) {
    if (ikBuilder.has_value()) ikBuilder->mix = std::max(0.0f, std::min(1.0f, value));
}

std::optional<Uuid> EditorScene::commitIKBuilder() {
    if (!ikBuilder.has_value()) return std::nullopt;
    const IKBuilderDraft draft = *ikBuilder;
    if (!IKBuilderRules::validate(draft, skeleton).canCreate() || !draft.targetID.has_value()) return std::nullopt;

    pushUndoState();
    const std::string name = trimmed(draft.name);
    IKConstraint constraint(name.empty() ? "IK " + std::to_string(skeleton.ikConstraints.size() + 1) : name,
                            draft.chain, *draft.targetID);
    std::optional<int> maxOrder;
    for (const IKConstraint& c : skeleton.ikConstraints) maxOrder = std::max(maxOrder.value_or(c.order_), c.order_);
    constraint.order_ = maxOrder.has_value() ? *maxOrder + 1 : 0;
    constraint.mix_ = draft.mix;
    constraint.bendPositive = draft.bendPositive;
    const Uuid id = constraint.id();
    skeleton.ikConstraints.push_back(constraint);
    ikBuilder = std::nullopt;
    ikBuilderHoveredBoneID = std::nullopt;
    selectedConstraintID = id;
    return id;
}

// ---- Create from selection -------------------------------------------------------

std::optional<Uuid> EditorScene::createPathConstraintFromSelection() {
    // First N-1 bones (root -> leaf) are the path, the last is the first
    // follower; three bones minimum.
    const std::vector<Bone> ordered = selectedBonesInChainOrder();
    if (ordered.size() < 3) return std::nullopt;
    pushUndoState();
    std::vector<Uuid> pathBones;
    for (std::size_t i = 0; i + 1 < ordered.size(); ++i) pathBones.push_back(ordered[i].id);
    std::optional<int> maxOrder;
    for (const BoneConstraint* c : skeleton.allConstraints()) maxOrder = std::max(maxOrder.value_or(c->order()), c->order());
    PathConstraint constraint("Path " + std::to_string(skeleton.pathConstraints.size() + 1), pathBones,
                              {ordered.back().id});
    constraint.order_ = maxOrder.has_value() ? *maxOrder + 1 : 0;
    const Uuid id = constraint.id();
    skeleton.pathConstraints.push_back(constraint);
    // Unlike Transform, Swift does not select the new path constraint.
    return id;
}

std::optional<Uuid> EditorScene::createTransformConstraintFromSelection() {
    // Every selected bone except the deepest is affected; the deepest is the
    // target. Two bones minimum.
    const std::vector<Bone> ordered = selectedBonesInChainOrder();
    if (ordered.size() < 2) return std::nullopt;
    pushUndoState();
    std::vector<Uuid> affected;
    for (std::size_t i = 0; i + 1 < ordered.size(); ++i) affected.push_back(ordered[i].id);
    // Between IK (0..49) and Physics (>= 100): transform constraints run
    // downstream of IK / Path so they can post-process them.
    std::optional<int> maxOrder;
    for (const TransformConstraint& c : skeleton.transformConstraints) {
        maxOrder = std::max(maxOrder.value_or(c.order_), c.order_);
    }
    TransformConstraint constraint("Transform " + std::to_string(skeleton.transformConstraints.size() + 1),
                                   ordered.back().id, affected);
    constraint.order_ = maxOrder.has_value() ? *maxOrder + 1 : 50;
    const Uuid id = constraint.id();
    skeleton.transformConstraints.push_back(constraint);
    selectedConstraintID = id;
    return id;
}

std::optional<Uuid> EditorScene::createPhysicsConstraintFromSelection(PhysicsType type, PhysicsPreset preset) {
    const std::vector<Bone> ordered = selectedBonesInChainOrder();
    if (ordered.empty()) return std::nullopt;
    pushUndoState();
    int maxOrder = 99;
    bool any = false;
    for (const BoneConstraint* c : skeleton.allConstraints()) {
        maxOrder = any ? std::max(maxOrder, c->order()) : c->order();
        any = true;
    }
    PhysicsConstraint constraint(presetDisplayName(preset) + " " +
                                 std::to_string(skeleton.physicsConstraints.size() + 1));
    constraint.order_ = std::max(maxOrder + 1, 100);
    constraint.mix_ = 1.0f;
    constraint.physicsType = type;
    for (const Bone& b : ordered) constraint.affectedBones.push_back(b.id);
    constraint.settings = settingsFor(preset);
    const Uuid id = constraint.id();
    skeleton.physicsConstraints.push_back(constraint);
    return id;
}

// ---- IK management ----------------------------------------------------------------

void EditorScene::renameIKConstraint(Uuid id, const std::string& newName) {
    const auto index = indexOfID(skeleton.ikConstraints, id);
    if (!index.has_value()) return;
    const std::string name = trimmed(newName);
    if (name.empty() || name == skeleton.ikConstraints[*index].name_) return;
    pushUndoState();
    skeleton.ikConstraints[*index].name_ = name;
}

void EditorScene::deleteIKConstraint(Uuid id) {
    if (!indexOfID(skeleton.ikConstraints, id).has_value()) return;
    pushUndoState();
    removeAllConstraintTracks(id);
    std::erase_if(skeleton.ikConstraints, [&](const IKConstraint& c) { return c.id() == id; });
    if (selectedConstraintID == id) selectedConstraintID = std::nullopt;
    constraintSetupValues.erase(id);
    pruneSceneAnimationTracks();
}

std::optional<Uuid> EditorScene::duplicateIKConstraint(Uuid id) {
    const auto index = indexOfID(skeleton.ikConstraints, id);
    if (!index.has_value()) return std::nullopt;
    pushUndoState();
    IKConstraint copy = skeleton.ikConstraints[*index];
    copy.id_ = Uuid::generate();
    copy.name_ = copy.name_ + " Copy";
    copy.order_ += 1;
    const Uuid copyID = copy.id();
    skeleton.ikConstraints.insert(skeleton.ikConstraints.begin() + static_cast<std::ptrdiff_t>(*index) + 1, copy);
    // IK occupies the low end of the pipeline, renumbered by list position.
    for (std::size_t i = 0; i < skeleton.ikConstraints.size(); ++i) skeleton.ikConstraints[i].order_ = static_cast<int>(i);
    selectedConstraintID = copyID;
    return copyID;
}

void EditorScene::moveIKConstraint(const std::vector<int>& fromOffsets, int toOffset) {
    if (!validOffsets(skeleton.ikConstraints, fromOffsets)) return;
    pushUndoState();
    moveFromOffsets(skeleton.ikConstraints, fromOffsets, toOffset);
    for (std::size_t i = 0; i < skeleton.ikConstraints.size(); ++i) skeleton.ikConstraints[i].order_ = static_cast<int>(i);
}

void EditorScene::setIKTarget(Uuid constraintID, Uuid boneID) {
    const auto index = indexOfID(skeleton.ikConstraints, constraintID);
    if (!index.has_value() || skeleton.ikConstraints[*index].targetBoneID == boneID) return;
    pushUndoState();
    skeleton.ikConstraints[*index].targetBoneID = boneID;
    // A bone cannot both drive the chain and be driven by it.
    std::erase(skeleton.ikConstraints[*index].boneChain, boneID);
}

void EditorScene::addBoneToIKChain(Uuid boneID, Uuid constraintID) {
    const auto index = indexOfID(skeleton.ikConstraints, constraintID);
    if (!index.has_value()) return;
    const IKConstraint& c = skeleton.ikConstraints[*index];
    if (boneID == c.targetBoneID || containsID(c.boneChain, boneID)) return;
    pushUndoState();
    skeleton.ikConstraints[*index].boneChain.push_back(boneID);
}

void EditorScene::removeBoneFromIKChain(Uuid boneID, Uuid constraintID) {
    const auto index = indexOfID(skeleton.ikConstraints, constraintID);
    if (!index.has_value() || !containsID(skeleton.ikConstraints[*index].boneChain, boneID)) return;
    pushUndoState();
    std::erase(skeleton.ikConstraints[*index].boneChain, boneID);
}

void EditorScene::setIKChainFromSelection(Uuid constraintID) {
    const auto index = indexOfID(skeleton.ikConstraints, constraintID);
    if (!index.has_value()) return;
    std::vector<Uuid> ordered;
    for (const Bone& b : selectedBonesInChainOrder()) {
        if (b.id != skeleton.ikConstraints[*index].targetBoneID) ordered.push_back(b.id);
    }
    if (ordered.empty()) return;
    pushUndoState();
    skeleton.ikConstraints[*index].boneChain = ordered;
}

void EditorScene::replaceIKConstraint(const IKConstraint& updated) {
    const auto index = indexOfID(skeleton.ikConstraints, updated.id());
    if (!index.has_value()) return;
    pushUndoState();
    skeleton.ikConstraints[*index] = updated;
    applyAnimationsNow();
}

// ---- Transform management ------------------------------------------------------------

void EditorScene::renameTransformConstraint(Uuid id, const std::string& newName) {
    const auto index = indexOfID(skeleton.transformConstraints, id);
    if (!index.has_value()) return;
    const std::string name = trimmed(newName);
    if (name.empty() || name == skeleton.transformConstraints[*index].name_) return;
    pushUndoState();
    skeleton.transformConstraints[*index].name_ = name;
}

void EditorScene::deleteTransformConstraint(Uuid id) {
    if (!indexOfID(skeleton.transformConstraints, id).has_value()) return;
    pushUndoState();
    std::erase_if(skeleton.transformConstraints, [&](const TransformConstraint& c) { return c.id() == id; });
    if (selectedConstraintID == id) selectedConstraintID = std::nullopt;
    // The prune drops the constraint's timelines and setup record with it.
    pruneSceneAnimationTracks();
}

std::optional<Uuid> EditorScene::duplicateTransformConstraint(Uuid id) {
    const auto index = indexOfID(skeleton.transformConstraints, id);
    if (!index.has_value()) return std::nullopt;
    pushUndoState();
    TransformConstraint copy = skeleton.transformConstraints[*index];
    copy.id_ = Uuid::generate();
    copy.name_ = copy.name_ + " Copy";
    copy.order_ += 1;
    const Uuid copyID = copy.id();
    // Straight after the source, so the inspector reads "original, then its
    // copy". Not renumbered (Swift renumbers only on a move).
    skeleton.transformConstraints.insert(
        skeleton.transformConstraints.begin() + static_cast<std::ptrdiff_t>(*index) + 1, copy);
    selectedConstraintID = copyID;
    return copyID;
}

void EditorScene::moveTransformConstraint(const std::vector<int>& fromOffsets, int toOffset) {
    if (!validOffsets(skeleton.transformConstraints, fromOffsets)) return;
    pushUndoState();
    moveFromOffsets(skeleton.transformConstraints, fromOffsets, toOffset);
    // Compacted into [50, 50+N) -- the transform layer of the pipeline.
    for (std::size_t i = 0; i < skeleton.transformConstraints.size(); ++i) {
        skeleton.transformConstraints[i].order_ = 50 + static_cast<int>(i);
    }
}

void EditorScene::addAffectedBone(Uuid boneID, Uuid constraintID) {
    const auto index = indexOfID(skeleton.transformConstraints, constraintID);
    if (!index.has_value()) return;
    const TransformConstraint& c = skeleton.transformConstraints[*index];
    if (boneID == c.targetBoneID || containsID(c.affectedBones, boneID)) return;
    pushUndoState();
    skeleton.transformConstraints[*index].affectedBones.push_back(boneID);
}

void EditorScene::removeAffectedBone(Uuid boneID, Uuid constraintID) {
    const auto index = indexOfID(skeleton.transformConstraints, constraintID);
    if (!index.has_value() || !containsID(skeleton.transformConstraints[*index].affectedBones, boneID)) return;
    pushUndoState();
    std::erase(skeleton.transformConstraints[*index].affectedBones, boneID);
}

void EditorScene::setTransformConstraintTarget(Uuid constraintID, Uuid boneID) {
    const auto index = indexOfID(skeleton.transformConstraints, constraintID);
    if (!index.has_value() || skeleton.transformConstraints[*index].targetBoneID == boneID) return;
    pushUndoState();
    skeleton.transformConstraints[*index].targetBoneID = boneID;
    // A bone can't drive itself.
    std::erase(skeleton.transformConstraints[*index].affectedBones, boneID);
}

// ---- Path management -----------------------------------------------------------------

void EditorScene::renamePathConstraint(Uuid id, const std::string& newName) {
    const auto index = indexOfID(skeleton.pathConstraints, id);
    if (!index.has_value()) return;
    const std::string name = trimmed(newName);
    if (name.empty() || name == skeleton.pathConstraints[*index].name_) return;
    pushUndoState();
    skeleton.pathConstraints[*index].name_ = name;
}

void EditorScene::deletePathConstraint(Uuid id) {
    if (!indexOfID(skeleton.pathConstraints, id).has_value()) return;
    pushUndoState();
    removeAllConstraintTracks(id);
    std::erase_if(skeleton.pathConstraints, [&](const PathConstraint& c) { return c.id() == id; });
    if (selectedConstraintID == id) selectedConstraintID = std::nullopt;
    constraintSetupValues.erase(id);
    pruneSceneAnimationTracks();
}

std::optional<Uuid> EditorScene::duplicatePathConstraint(Uuid id) {
    const auto index = indexOfID(skeleton.pathConstraints, id);
    if (!index.has_value()) return std::nullopt;
    pushUndoState();
    PathConstraint copy = skeleton.pathConstraints[*index];
    copy.id_ = Uuid::generate();
    copy.name_ = copy.name_ + " Copy";
    copy.order_ += 1;
    const Uuid copyID = copy.id();
    skeleton.pathConstraints.insert(skeleton.pathConstraints.begin() + static_cast<std::ptrdiff_t>(*index) + 1, copy);
    selectedConstraintID = copyID;
    return copyID;
}

void EditorScene::addFollowerToPath(Uuid boneID, Uuid constraintID) {
    const auto index = indexOfID(skeleton.pathConstraints, constraintID);
    if (!index.has_value()) return;
    const PathConstraint& c = skeleton.pathConstraints[*index];
    if (containsID(c.bones, boneID) || containsID(c.pathBones, boneID)) return;
    pushUndoState();
    skeleton.pathConstraints[*index].bones.push_back(boneID);
}

void EditorScene::removeFollowerFromPath(Uuid boneID, Uuid constraintID) {
    const auto index = indexOfID(skeleton.pathConstraints, constraintID);
    if (!index.has_value() || !containsID(skeleton.pathConstraints[*index].bones, boneID)) return;
    pushUndoState();
    std::erase(skeleton.pathConstraints[*index].bones, boneID);
}

void EditorScene::setPathControlBonesFromSelection(Uuid constraintID) {
    const auto index = indexOfID(skeleton.pathConstraints, constraintID);
    if (!index.has_value()) return;
    std::vector<Uuid> ordered;
    for (const Bone& b : selectedBonesInChainOrder()) {
        if (!containsID(skeleton.pathConstraints[*index].bones, b.id)) ordered.push_back(b.id);
    }
    if (ordered.size() < 2) return;
    pushUndoState();
    skeleton.pathConstraints[*index].pathBones = ordered;
}

// ---- Physics management --------------------------------------------------------------

void EditorScene::renamePhysicsConstraint(Uuid id, const std::string& newName) {
    const auto index = indexOfID(skeleton.physicsConstraints, id);
    if (!index.has_value()) return;
    const std::string name = trimmed(newName);
    if (name.empty() || name == skeleton.physicsConstraints[*index].name_) return;
    pushUndoState();
    skeleton.physicsConstraints[*index].name_ = name;
}

void EditorScene::deletePhysicsConstraint(Uuid id) {
    if (!indexOfID(skeleton.physicsConstraints, id).has_value()) return;
    pushUndoState();
    removeAllConstraintTracks(id);
    std::erase_if(skeleton.physicsConstraints, [&](const PhysicsConstraint& c) { return c.id() == id; });
    if (selectedConstraintID == id) selectedConstraintID = std::nullopt;
    constraintSetupValues.erase(id);
    pruneSceneAnimationTracks();
}

std::optional<Uuid> EditorScene::duplicatePhysicsConstraint(Uuid id) {
    const auto index = indexOfID(skeleton.physicsConstraints, id);
    if (!index.has_value()) return std::nullopt;
    pushUndoState();
    PhysicsConstraint copy = skeleton.physicsConstraints[*index];
    copy.id_ = Uuid::generate();
    copy.name_ = copy.name_ + " Copy";
    copy.order_ += 1;
    const Uuid copyID = copy.id();
    skeleton.physicsConstraints.insert(
        skeleton.physicsConstraints.begin() + static_cast<std::ptrdiff_t>(*index) + 1, copy);
    selectedConstraintID = copyID;
    return copyID;
}

void EditorScene::setPhysicsChainFromSelection(Uuid constraintID) {
    const auto index = indexOfID(skeleton.physicsConstraints, constraintID);
    if (!index.has_value()) return;
    std::vector<Uuid> ordered;
    for (const Bone& b : selectedBonesInChainOrder()) ordered.push_back(b.id);
    if (ordered.empty()) return;
    pushUndoState();
    skeleton.physicsConstraints[*index].affectedBones = ordered;
}

// ---- Shared -------------------------------------------------------------------------

void EditorScene::setConstraintEnabled(Uuid id, bool enabled) {
    pushUndoState();
    if (auto i = indexOfID(skeleton.ikConstraints, id)) {
        skeleton.ikConstraints[*i].enabled_ = enabled;
    } else if (auto t = indexOfID(skeleton.transformConstraints, id)) {
        skeleton.transformConstraints[*t].enabled_ = enabled;
    } else if (auto p = indexOfID(skeleton.pathConstraints, id)) {
        skeleton.pathConstraints[*p].enabled_ = enabled;
    } else if (auto ph = indexOfID(skeleton.physicsConstraints, id)) {
        skeleton.physicsConstraints[*ph].enabled_ = enabled;
    }
    applyAnimationsNow();
}

void EditorScene::deleteConstraint(Uuid id) {
    const auto kind = constraintKind(skeleton, id);
    if (!kind.has_value()) return;
    switch (*kind) {
        case ConstraintKind::Ik: deleteIKConstraint(id); break;
        case ConstraintKind::Transform: deleteTransformConstraint(id); break;
        case ConstraintKind::Path: deletePathConstraint(id); break;
        case ConstraintKind::Physics: deletePhysicsConstraint(id); break;
    }
}

std::optional<Uuid> EditorScene::duplicateConstraint(Uuid id) {
    const auto kind = constraintKind(skeleton, id);
    if (!kind.has_value()) return std::nullopt;
    switch (*kind) {
        case ConstraintKind::Ik: return duplicateIKConstraint(id);
        case ConstraintKind::Transform: return duplicateTransformConstraint(id);
        case ConstraintKind::Path: return duplicatePathConstraint(id);
        case ConstraintKind::Physics: return duplicatePhysicsConstraint(id);
    }
    return std::nullopt;
}

void EditorScene::renameConstraint(Uuid id, const std::string& newName) {
    const auto kind = constraintKind(skeleton, id);
    if (!kind.has_value()) return;
    switch (*kind) {
        case ConstraintKind::Ik: renameIKConstraint(id, newName); break;
        case ConstraintKind::Transform: renameTransformConstraint(id, newName); break;
        case ConstraintKind::Path: renamePathConstraint(id, newName); break;
        case ConstraintKind::Physics: renamePhysicsConstraint(id, newName); break;
    }
}

std::vector<Bone> EditorScene::targetCandidates(const std::vector<Uuid>& excludingDriven) const {
    std::vector<Bone> out;
    for (const Bone& b : skeleton.orderedBones()) {
        if (!containsID(excludingDriven, b.id)) out.push_back(b);
    }
    return out;
}

// ---- Constraint animation -------------------------------------------------------------

void EditorScene::ensureConstraintSetupCaptured(Uuid constraintID) {
    // Idempotent: an existing record is never overwritten, or an animated
    // value would be mistaken for the setup pose.
    if (constraintSetupValues.contains(constraintID) || !constraintKind(skeleton, constraintID).has_value()) return;
    constraintSetupValues[constraintID] = captureConstraintSetupValues(skeleton, constraintID);
}

void EditorScene::updateConstraintSetupValue(Uuid constraintID, AnimationTrackProperty property) {
    if (!constraintKind(skeleton, constraintID).has_value()) return;
    ConstraintSetupValues record = constraintSetupValues.contains(constraintID)
                                       ? constraintSetupValues.at(constraintID)
                                       : ConstraintSetupValues{};
    switch (valueKind(property)) {
        case TrackValueKind::Scalar:
            if (auto v = constraintScalar(skeleton, constraintID, property)) record.set(property, *v);
            break;
        case TrackValueKind::Flag:
            if (auto v = constraintFlag(skeleton, constraintID, property)) record.set(property, *v);
            break;
        case TrackValueKind::Vector2:
            if (auto v = constraintVector(skeleton, constraintID, property)) record.set(property, *v);
            break;
        default:
            return;
    }
    constraintSetupValues[constraintID] = record;
}

bool EditorScene::isConstraintPropertyAnimated(Uuid constraintID, AnimationTrackProperty property) const {
    return sceneAnimationClip.hasTrack(constraintID, property);
}

bool EditorScene::constraintPropertyHasKeyAtPlayhead(Uuid constraintID, AnimationTrackProperty property) const {
    for (const Keyframe& k : sceneAnimationClip.keyframesFor(constraintID, property)) {
        if (k.frame == currentFrame) return true;
    }
    return false;
}

void EditorScene::restoreAllConstraintSetupValues() {
    if (constraintSetupValues.empty()) return;
    for (const auto& [constraintID, record] : constraintSetupValues) {
        if (!constraintKind(skeleton, constraintID).has_value()) continue;
        applyConstraintSetupValues(skeleton, constraintID, record);
    }
}

void EditorScene::replaceSceneAnimation(const AnimationClip& clip,
                                        const std::unordered_map<Uuid, ConstraintSetupValues, UuidHash>& values) {
    sceneAnimationClip = clip;
    constraintSetupValues = values;
    animatedDrawOrder = std::nullopt;
    pruneSceneAnimationTracks();
    applyAnimationsNow();
}

bool EditorScene::hasAnyConstraintTrack(Uuid constraintID) const {
    for (AnimationTrackProperty p : animatableProperties(skeleton, constraintID)) {
        if (sceneAnimationClip.hasTrack(constraintID, p)) return true;
    }
    return false;
}

void EditorScene::removeAllConstraintTracks(Uuid constraintID) {
    if (!hasAnyConstraintTrack(constraintID)) return;
    pushUndoState();
    for (AnimationTrackProperty p : animatableProperties(skeleton, constraintID)) {
        const std::vector<Keyframe> keys = sceneAnimationClip.keyframesFor(constraintID, p);
        if (keys.empty()) continue;
        std::unordered_set<Uuid, UuidHash> ids;
        for (const Keyframe& k : keys) ids.insert(k.id);
        sceneAnimationClip.deleteKeyframes(constraintID, p, ids);
        restoreConstraintSetupValue(constraintID, p);
    }
    applyAnimationsNow();
}

float EditorScene::constraintScalarValue(Uuid constraintID, AnimationTrackProperty property) const {
    return constraintScalar(skeleton, constraintID, property).value_or(neutralValue(property));
}

bool EditorScene::constraintFlagValue(Uuid constraintID, AnimationTrackProperty property) const {
    return constraintFlag(skeleton, constraintID, property).value_or(false);
}

Vec2 EditorScene::constraintVectorValue(Uuid constraintID, AnimationTrackProperty property) const {
    return constraintVector(skeleton, constraintID, property).value_or(Vec2::zero());
}

// BUG FIXED, NOT REPLICATED (all three setters below). Swift writes the new
// value onto the constraint FIRST and captures the setup record AFTER, so
// the first auto-keyed edit in Animator records the ANIMATED value as the
// authored one -- the exact mistake `ensureConstraintSetupCaptured`'s own
// comment says it exists to prevent. Nothing captures earlier (verified by
// grep), so the authored value was simply lost: removing every key
// afterwards "restored" the animated value. `keyConstraintProperty`, which
// captures without writing, always had it right. Here the capture comes
// first.
void EditorScene::setConstraintScalar(Uuid constraintID, AnimationTrackProperty property, float value, bool pushUndo) {
    if (!constraintKind(skeleton, constraintID).has_value() || valueKind(property) != TrackValueKind::Scalar) return;
    if (pushUndo) pushUndoState();
    const float c = clamped(property, value);
    // Captured BEFORE the write -- see the note above.
    if (isAnimationEditingEnabled) ensureConstraintSetupCaptured(constraintID);
    umeshcore::setConstraintScalar(skeleton, constraintID, property, c);
    if (isAnimationEditingEnabled) {
        sceneAnimationClip.upsertKeyframe(constraintID, property, currentFrame, ScalarValue{c});
        selectKeyframeAt(constraintID, property, currentFrame);
    } else if (isConstraintPropertyAnimated(constraintID, property)) {
        updateConstraintSetupValue(constraintID, property);
    }
    applyAnimationsNow();
}

void EditorScene::setConstraintFlag(Uuid constraintID, AnimationTrackProperty property, bool value, bool pushUndo) {
    if (!constraintKind(skeleton, constraintID).has_value() || valueKind(property) != TrackValueKind::Flag) return;
    if (pushUndo) pushUndoState();
    if (isAnimationEditingEnabled) ensureConstraintSetupCaptured(constraintID);
    umeshcore::setConstraintFlag(skeleton, constraintID, property, value);
    if (isAnimationEditingEnabled) {
        sceneAnimationClip.upsertKeyframe(constraintID, property, currentFrame, FlagValue{value});
        selectKeyframeAt(constraintID, property, currentFrame);
    } else if (isConstraintPropertyAnimated(constraintID, property)) {
        updateConstraintSetupValue(constraintID, property);
    }
    applyAnimationsNow();
}

void EditorScene::setConstraintVector(Uuid constraintID, AnimationTrackProperty property, Vec2 value, bool pushUndo) {
    if (!constraintKind(skeleton, constraintID).has_value() || valueKind(property) != TrackValueKind::Vector2) return;
    if (pushUndo) pushUndoState();
    if (isAnimationEditingEnabled) ensureConstraintSetupCaptured(constraintID);
    umeshcore::setConstraintVector(skeleton, constraintID, property, value);
    if (isAnimationEditingEnabled) {
        sceneAnimationClip.upsertKeyframe(constraintID, property, currentFrame, Vector2Value{value});
        selectKeyframeAt(constraintID, property, currentFrame);
    } else if (isConstraintPropertyAnimated(constraintID, property)) {
        updateConstraintSetupValue(constraintID, property);
    }
    applyAnimationsNow();
}

void EditorScene::keyConstraintProperty(Uuid constraintID, AnimationTrackProperty property) {
    if (!constraintKind(skeleton, constraintID).has_value()) return;
    pushUndoState();
    ensureConstraintSetupCaptured(constraintID);
    KeyframeValue value = ScalarValue{0.0f};
    switch (valueKind(property)) {
        case TrackValueKind::Scalar:
            value = ScalarValue{clamped(property, constraintScalarValue(constraintID, property))};
            break;
        case TrackValueKind::Flag: value = FlagValue{constraintFlagValue(constraintID, property)}; break;
        case TrackValueKind::Vector2: value = Vector2Value{constraintVectorValue(constraintID, property)}; break;
        default: return;
    }
    sceneAnimationClip.upsertKeyframe(constraintID, property, currentFrame, value);
    selectKeyframeAt(constraintID, property, currentFrame);
    applyAnimationsNow();
}

void EditorScene::removeConstraintKeyAtPlayhead(Uuid constraintID, AnimationTrackProperty property) {
    for (const Keyframe& k : sceneAnimationClip.keyframesFor(constraintID, property)) {
        if (k.frame != currentFrame) continue;
        const Uuid keyID = k.id;
        pushUndoState();
        sceneAnimationClip.deleteKeyframes(constraintID, property, {keyID});
        // The last key gone: the property reverts to its authored value.
        if (!isConstraintPropertyAnimated(constraintID, property)) restoreConstraintSetupValue(constraintID, property);
        applyAnimationsNow();
        return;
    }
}

void EditorScene::removeConstraintPropertyTrack(Uuid constraintID, AnimationTrackProperty property) {
    const std::vector<Keyframe> keys = sceneAnimationClip.keyframesFor(constraintID, property);
    if (keys.empty()) return;
    pushUndoState();
    std::unordered_set<Uuid, UuidHash> ids;
    for (const Keyframe& k : keys) ids.insert(k.id);
    sceneAnimationClip.deleteKeyframes(constraintID, property, ids);
    restoreConstraintSetupValue(constraintID, property);
    applyAnimationsNow();
}

void EditorScene::restoreConstraintSetupValue(Uuid constraintID, AnimationTrackProperty property) {
    auto it = constraintSetupValues.find(constraintID);
    if (it == constraintSetupValues.end()) return;
    const ConstraintSetupValues& record = it->second;
    switch (valueKind(property)) {
        case TrackValueKind::Scalar:
            if (auto v = record.scalar(property)) umeshcore::setConstraintScalar(skeleton, constraintID, property, *v);
            break;
        case TrackValueKind::Flag:
            if (auto v = record.flag(property)) umeshcore::setConstraintFlag(skeleton, constraintID, property, *v);
            break;
        case TrackValueKind::Vector2:
            if (auto v = record.vector(property)) umeshcore::setConstraintVector(skeleton, constraintID, property, *v);
            break;
        default:
            break;
    }
}

} // namespace umeshcore
