// EditorScene -- structure: hierarchy rows, draw order, deletion,
// duplication, reparenting, binding, and the draw order keys.
//
// Ported from `Data/SceneManager.swift`: `addImage`, `addBone`,
// `moveHierarchyItem`, the `// MARK: - Draw Order` section,
// `deleteHierarchy`, `duplicateItem`, `reparentBone`, `bindImage`,
// `removeBones`, `updateVisibility`, `renameHierarchyItem`,
// `normalizeOrder`, `syncImagesToHierarchy`, `applySnapshot`,
// `pruneSceneAnimationTracks` and `// MARK: Draw order keys`.

#include "umeshcore/Editor/EditorScene.h"

#include <algorithm>
#include <cctype>

#include "umeshcore/Editor/HierarchyDisplay.h"
#include "umeshcore/Editor/IKBuilder.h"

namespace umeshcore {

namespace {

std::string trimmed(const std::string& s) {
    std::size_t b = 0, e = s.size();
    while (b < e && std::isspace(static_cast<unsigned char>(s[b]))) ++b;
    while (e > b && std::isspace(static_cast<unsigned char>(s[e - 1]))) --e;
    return s.substr(b, e - b);
}

std::string lowered(const std::string& s) {
    std::string out = s;
    for (char& c : out) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return out;
}

} // namespace

// ---- Mode -----------------------------------------------------------------

void EditorScene::setAnimationEditingEnabled(bool enabled) {
    if (enabled == isAnimationEditingEnabled) return;
    isAnimationEditingEnabled = enabled;
    if (!enabled) {
        for (SceneImage& img : images) img.meshAnimationDeform = std::nullopt;
    }
}

// ---- Creation -------------------------------------------------------------

Uuid EditorScene::addImage(Uuid assetID, const std::string& assetName, Vec2 assetSize, Vec2 position,
                           std::optional<Uuid> normalMapAssetID) {
    SceneImage image;
    const Uuid id = image.id;
    image.assetID = assetID;
    image.name = assetName;
    image.basePosition = position;
    image.position = position;
    image.mesh = Mesh::makeQuad(assetName + " Mesh", assetSize);
    // PAIRED AT CREATION, by the `_n` convention: an editable value, so
    // clearing it clears it and undo undoes it.
    image.normalMapAssetID = normalMapAssetID;
    image.animationClip = AnimationClip(assetName);
    image.animationTransformSpace = TransformAnimationSpace::world();
    images.insert(images.begin(), image);

    HierarchyItem item;
    item.id = id;
    item.name = assetName;
    item.type = HierarchyItem::ItemType::Image;
    item.order = 0;
    hierarchyItems.insert(hierarchyItems.begin(), item);
    normalizeOrder();
    setSelection({id}, id, false);
    // A new sprite may land in an existing slot and become a variant.
    refreshSkinResolution();
    return id;
}

Uuid EditorScene::addBone(Vec2 start, Vec2 end, std::optional<Uuid> parentID) {
    pushUndoState();
    const int boneIndex = static_cast<int>(skeleton.bones().size()) + 1;
    const std::optional<Mat4> parentMatrix =
        parentID.has_value() ? skeleton.worldMatrix(*parentID) : std::nullopt;
    const Bone bone = Bone::make("Bone " + std::to_string(boneIndex), start, end, parentID, parentMatrix);
    skeleton = skeleton.addingBone(bone);

    int maxOrder = -1;
    for (const HierarchyItem& item : hierarchyItems) maxOrder = std::max(maxOrder, item.order);
    HierarchyItem item;
    item.id = bone.id;
    item.name = bone.name;
    item.type = HierarchyItem::ItemType::Bone;
    item.order = std::max(maxOrder + 1, 0);
    hierarchyItems.push_back(item);
    normalizeOrder();
    syncImagesToHierarchy();
    selectBone(bone.id);
    return bone.id;
}

// ---- Hierarchy ------------------------------------------------------------

std::vector<Uuid> EditorScene::displayHierarchyIDs() const {
    return umeshcore::displayHierarchyIDs(hierarchyItems, images, skeleton);
}

void EditorScene::moveHierarchyItem(Uuid id, int toDisplayIndex) {
    std::vector<Uuid> ordered = displayHierarchyIDs();
    auto source = std::find(ordered.begin(), ordered.end(), id);
    if (source == ordered.end()) return;
    ordered.erase(source);
    const int clamped = std::max(0, std::min(toDisplayIndex, static_cast<int>(ordered.size())));
    ordered.insert(ordered.begin() + clamped, id);

    std::unordered_map<Uuid, int, UuidHash> nextOrder;
    for (std::size_t i = 0; i < ordered.size(); ++i) nextOrder[ordered[i]] = static_cast<int>(i);
    for (HierarchyItem& item : hierarchyItems) {
        auto it = nextOrder.find(item.id);
        if (it != nextOrder.end()) item.order = it->second;
    }
    // Swift's `sort` is not stable either; rows without a new order keep
    // theirs, and a stable sort keeps equal orders where they were, which
    // is the only answer Swift could also have given for them.
    std::stable_sort(hierarchyItems.begin(), hierarchyItems.end(),
                     [](const HierarchyItem& a, const HierarchyItem& b) { return a.order < b.order; });
    normalizeOrder();
    syncImagesToHierarchy();
}

void EditorScene::normalizeOrder() {
    for (std::size_t i = 0; i < hierarchyItems.size(); ++i) hierarchyItems[i].order = static_cast<int>(i);
}

void EditorScene::syncImagesToHierarchy() {
    // Rank built once, every sprite given one; a sprite the tree does not
    // name keeps its place at the back instead of poisoning the comparison,
    // and ties break on current position -- a stable sort. (The Swift
    // comment records the bug this replaced: a comparator that answered
    // false both ways let one unnamed sprite scramble all the others.)
    const std::vector<Uuid> ordered = displayHierarchyIDs();
    std::unordered_map<Uuid, std::size_t, UuidHash> rank;
    for (std::size_t i = 0; i < ordered.size(); ++i) rank.emplace(ordered[i], i);
    const std::size_t unranked = ordered.size();
    const auto rankOf = [&](const SceneImage& img) {
        auto it = rank.find(img.id);
        return it == rank.end() ? unranked : it->second;
    };
    std::stable_sort(images.begin(), images.end(),
                     [&](const SceneImage& a, const SceneImage& b) { return rankOf(a) < rankOf(b); });
}

void EditorScene::rebuildHierarchyFromState() {
    std::unordered_set<Uuid, UuidHash> live;
    for (const SceneImage& img : images) live.insert(img.id);
    for (const auto& entry : skeleton.bones()) live.insert(entry.first);
    std::erase_if(hierarchyItems, [&](const HierarchyItem& item) { return !live.contains(item.id); });
}

void EditorScene::updateVisibility(Uuid itemID, bool isHidden) {
    for (HierarchyItem& item : hierarchyItems) {
        if (item.id == itemID) {
            item.isHidden = isHidden;
            break;
        }
    }
    if (SceneImage* img = image(itemID)) img->isHidden = isHidden;
}

std::string EditorScene::uniqueHierarchyName(const std::string& proposed, Uuid excluding) const {
    // Reserved by IDENTITY, not by matching name: filtering on the current
    // name excluded every row SHARING it, so two rows called "Bone"
    // produced a third.
    std::unordered_set<std::string> reserved;
    for (const HierarchyItem& item : hierarchyItems) {
        if (item.id != excluding) reserved.insert(lowered(trimmed(item.name)));
    }
    if (!reserved.contains(lowered(proposed))) return proposed;
    int suffix = 2;
    std::string candidate = proposed + " " + std::to_string(suffix);
    while (reserved.contains(lowered(candidate))) {
        suffix += 1;
        candidate = proposed + " " + std::to_string(suffix);
    }
    return candidate;
}

bool EditorScene::renameHierarchyItem(Uuid itemID, const std::string& proposed) {
    const std::string name = trimmed(proposed);
    if (name.empty()) return false;
    auto row = std::find_if(hierarchyItems.begin(), hierarchyItems.end(),
                            [&](const HierarchyItem& item) { return item.id == itemID; });
    if (row == hierarchyItems.end()) return false;
    // Re-committing the row's own name is not a rename and not a collision.
    if (name == row->name) return false;
    const std::string resolved = uniqueHierarchyName(name, itemID);
    if (resolved == row->name) return false;

    pushUndoState();
    // pushUndoState does not touch hierarchyItems, so `row` is still valid.
    row->name = resolved;
    if (SceneImage* img = image(itemID)) img->name = resolved;
    if (const Bone* existing = skeleton.bone(itemID)) {
        Bone bone = *existing;
        bone.name = resolved;
        skeleton.setBone(bone);
    }
    return true;
}

// ---- Draw order -----------------------------------------------------------

std::vector<Uuid> EditorScene::resolvedDrawOrder() const {
    std::unordered_set<Uuid, UuidHash> present;
    for (const SceneImage& img : images) present.insert(img.id);
    std::unordered_set<Uuid, UuidHash> seen;
    std::vector<Uuid> out;
    out.reserve(images.size());
    for (Uuid id : authoredDrawOrder) {
        if (present.contains(id) && seen.insert(id).second) out.push_back(id);
    }
    for (const SceneImage& img : images) {
        if (seen.insert(img.id).second) out.push_back(img.id);
    }
    return out;
}

void EditorScene::setAuthoredDrawOrder(std::vector<Uuid> order) { authoredDrawOrder = std::move(order); }

std::vector<SceneImage> EditorScene::renderOrderedImages() const {
    // ONE hidden set: what the skin displaces, plus what an attachment key
    // displaces this frame.
    std::unordered_set<Uuid, UuidHash> hidden = skinResolution.hiddenImageIDs;
    for (Uuid id : attachmentHiddenImageIDs()) hidden.insert(id);

    std::vector<SceneImage> visible;
    visible.reserve(images.size());
    for (const SceneImage& img : images) {
        if (!hidden.contains(img.id)) visible.push_back(img);
    }

    // The keyed permutation wins while one is in effect; otherwise the
    // authored list; and with neither, the array order of `images`.
    std::optional<std::vector<Uuid>> order = animatedDrawOrder;
    if (!order.has_value() && !authoredDrawOrder.empty()) order = resolvedDrawOrder();
    if (!order.has_value()) return visible;

    std::unordered_map<Uuid, std::size_t, UuidHash> byID;
    for (std::size_t i = 0; i < visible.size(); ++i) byID.emplace(visible[i].id, i);
    std::vector<SceneImage> out;
    out.reserve(visible.size());
    std::vector<bool> taken(visible.size(), false);
    for (Uuid id : *order) {
        auto it = byID.find(id);
        if (it == byID.end() || taken[it->second]) continue;
        taken[it->second] = true;
        out.push_back(visible[it->second]);
    }
    // Sprites created after the key was authored keep their authored
    // relative order and sit behind the keyed ones.
    for (std::size_t i = 0; i < visible.size(); ++i) {
        if (!taken[i]) out.push_back(visible[i]);
    }
    return out;
}

std::optional<Uuid> EditorScene::idAtRow(int row, const std::vector<Uuid>& order) {
    if (order.empty()) return std::nullopt;
    const int clamped = std::max(0, std::min(row, static_cast<int>(order.size()) - 1));
    return order[static_cast<std::size_t>(clamped)];
}

std::optional<std::vector<Uuid>> EditorScene::movingID(Uuid moved, Uuid before, const std::vector<Uuid>& order) {
    auto sourceIt = std::find(order.begin(), order.end(), moved);
    auto destIt = std::find(order.begin(), order.end(), before);
    if (sourceIt == order.end() || destIt == order.end()) return std::nullopt;
    const auto source = sourceIt - order.begin();
    const auto destination = destIt - order.begin();
    if (source == destination) return order;
    std::vector<Uuid> out = order;
    out.erase(out.begin() + source);
    auto settledIt = std::find(out.begin(), out.end(), before);
    if (settledIt == out.end()) return std::nullopt;
    const auto settled = settledIt - out.begin();
    out.insert(out.begin() + (source < destination ? settled + 1 : settled), moved);
    return out;
}

std::optional<std::vector<Uuid>> EditorScene::movingIDToRow(Uuid moved, int row, const std::vector<Uuid>& order) {
    const std::optional<Uuid> target = idAtRow(row, order);
    if (!target.has_value()) return std::nullopt;
    return movingID(moved, *target, order);
}

void EditorScene::moveImageInDrawOrder(Uuid imageID, int toDrawIndex) {
    // In Animate mode a reorder is a keyable event, resolved against the
    // order on screen.
    if (isAnimationEditingEnabled) {
        std::vector<Uuid> onScreen;
        for (const SceneImage& img : renderOrderedImages()) onScreen.push_back(img.id);
        if (auto moved = movingIDToRow(imageID, toDrawIndex, onScreen)) {
            keyDrawOrder(*moved);
            return;
        }
    }
    const std::vector<Uuid> order = resolvedDrawOrder();
    const auto moved = movingIDToRow(imageID, toDrawIndex, order);
    if (!moved.has_value() || *moved == order) return;
    pushUndoState();
    setAuthoredDrawOrder(*moved);
}

void EditorScene::nudgeImageInDrawOrder(Uuid imageID, bool forward) {
    const std::vector<SceneImage> visible = imagesInDrawOrder();
    int index = -1;
    for (std::size_t i = 0; i < visible.size(); ++i) {
        if (visible[i].id == imageID) {
            index = static_cast<int>(i);
            break;
        }
    }
    if (index < 0) return;
    const int target = forward ? index - 1 : index + 1;
    if (target < 0 || target >= static_cast<int>(visible.size())) return;
    moveImageInDrawOrder(imageID, target);
}

void EditorScene::sortDrawOrderByBoneDepth() {
    if (images.empty() || skeleton.bones().empty()) return;

    std::unordered_map<Uuid, int, UuidHash> depthByBone;
    for (const IKBuilderOrderedBone& entry : IKBuilderRules::hierarchicalOrder(skeleton)) {
        depthByBone[entry.bone.id] = entry.depth;
    }
    // The DEEPEST bone driving the sprite; a sprite driven by nothing sorts
    // before every bound one, keeping the back.
    const auto depthOfImage = [&](const SceneImage& img) {
        std::optional<int> deepest;
        for (Uuid boneID : img.mesh.boundBoneIDs()) {
            auto it = depthByBone.find(boneID);
            if (it != depthByBone.end()) deepest = std::max(deepest.value_or(it->second), it->second);
        }
        if (img.boneBinding.has_value()) {
            auto it = depthByBone.find(img.boneBinding->boneID);
            if (it != depthByBone.end()) deepest = std::max(deepest.value_or(it->second), it->second);
        }
        return deepest.value_or(-1);
    };

    const std::vector<Uuid> authored = resolvedDrawOrder();
    std::unordered_map<Uuid, int, UuidHash> depth;
    for (const SceneImage& img : images) depth[img.id] = depthOfImage(img);

    // BUG FIXED, NOT REPLICATED: the DIRECTION. The draw order list is
    // FRONT TO BACK -- index 0 is the front-most sprite (`MetalRenderer`
    // and both Scene renderers walk it `.reversed()` for exactly that
    // reason, and `DrawOrderView` labels the top row front-most). Swift
    // sorts by ASCENDING depth, which puts unbound sprites (-1) at the
    // FRONT and the deepest bone at the BACK: the exact opposite of the
    // three things its own comment promises ("a forearm over an upper
    // arm", "keeps its place at the back", "deeper draws in front"). The
    // command exists only to do that, so here the deeper bone sorts first.
    //
    // Stable: equal depths keep the order they were given, so running this
    // twice changes nothing.
    std::vector<Uuid> sorted = authored;
    std::stable_sort(sorted.begin(), sorted.end(), [&](Uuid a, Uuid b) { return depth[a] > depth[b]; });
    if (sorted == authored) return;
    pushUndoState();
    setAuthoredDrawOrder(sorted);
}

// ---- Deletion and duplication ----------------------------------------------

void EditorScene::removeBones(const std::vector<Uuid>& ids) {
    if (ids.empty()) return;
    const std::unordered_set<Uuid, UuidHash> removed(ids.begin(), ids.end());
    for (Uuid id : ids) {
        skeleton.removeBone(id);
        std::erase(skeleton.rootIDs, id);
    }
    // Orphans become roots. Swift walks `skeleton.bones.keys` -- a
    // dictionary's order, which differs between runs -- so the order they
    // join `rootIDs` was never defined; here it is the skeleton's own
    // bone order, so the same edit gives the same rig every time.
    for (const Bone& existing : skeleton.orderedBones()) {
        if (existing.parentID.has_value() && removed.contains(*existing.parentID)) {
            Bone bone = existing;
            bone.parentID = std::nullopt;
            skeleton.setBone(bone);
            if (std::find(skeleton.rootIDs.begin(), skeleton.rootIDs.end(), bone.id) == skeleton.rootIDs.end()) {
                skeleton.rootIDs.push_back(bone.id);
            }
        }
    }
    // Through the one route: dropping the ids from the ORDER keeps the set
    // and the primary agreeing with it.
    std::vector<Uuid> keptSelection;
    for (Uuid id : boneSelectionOrder) {
        if (!removed.contains(id)) keptSelection.push_back(id);
    }
    applyBoneSelection(keptSelection);

    // Constraints that name a removed bone go, so the solver never resolves
    // a dangling id. (Transform constraints are not swept, matching Swift.)
    const auto anyRemoved = [&](const std::vector<Uuid>& v) {
        return std::any_of(v.begin(), v.end(), [&](Uuid id) { return removed.contains(id); });
    };
    std::erase_if(skeleton.ikConstraints, [&](const IKConstraint& c) {
        return anyRemoved(c.boneChain) || removed.contains(c.targetBoneID);
    });
    std::erase_if(skeleton.pathConstraints,
                  [&](const PathConstraint& c) { return anyRemoved(c.pathBones) || anyRemoved(c.bones); });
    std::erase_if(skeleton.physicsConstraints,
                  [&](const PhysicsConstraint& c) { return anyRemoved(c.affectedBones); });
    for (SceneImage& img : images) {
        if (img.boneBinding.has_value() && removed.contains(img.boneBinding->boneID)) img.boneBinding = std::nullopt;
    }
    syncImagesToHierarchy();
}

void EditorScene::deleteHierarchy(Uuid itemID) {
    pushUndoState();
    std::erase_if(hierarchyItems, [&](const HierarchyItem& item) { return item.id == itemID; });
    std::erase_if(images, [&](const SceneImage& img) { return img.id == itemID; });
    pruneSkins();
    refreshSkinResolution();
    removeBones({itemID});
    selectedImageIDs.erase(itemID);
    if (selectedImageID == itemID) {
        selectedImageID = selectedImageIDs.empty() ? std::nullopt
                                                   : std::optional<Uuid>(*selectedImageIDs.begin());
    }
    normalizeOrder();
}

void EditorScene::deleteHierarchyAt(const std::vector<int>& offsets) {
    pushUndoState();
    std::vector<Uuid> ids;
    for (int offset : offsets) {
        if (offset >= 0 && offset < static_cast<int>(hierarchyItems.size())) {
            ids.push_back(hierarchyItems[static_cast<std::size_t>(offset)].id);
        }
    }
    const std::unordered_set<Uuid, UuidHash> doomed(ids.begin(), ids.end());
    std::erase_if(hierarchyItems, [&](const HierarchyItem& item) { return doomed.contains(item.id); });
    std::erase_if(images, [&](const SceneImage& img) { return doomed.contains(img.id); });
    pruneSkins();
    refreshSkinResolution();
    removeBones(ids);
    for (Uuid id : ids) selectedImageIDs.erase(id);
    if (selectedImageID.has_value() && doomed.contains(*selectedImageID)) {
        selectedImageID = selectedImageIDs.empty() ? std::nullopt
                                                   : std::optional<Uuid>(*selectedImageIDs.begin());
    }
    normalizeOrder();
}

void EditorScene::duplicateSelected() {
    if (selectedImageID.has_value()) duplicateItem(*selectedImageID);
}

void EditorScene::duplicateItem(Uuid id) {
    auto imageIt = std::find_if(images.begin(), images.end(), [&](const SceneImage& img) { return img.id == id; });
    auto rowIt = std::find_if(hierarchyItems.begin(), hierarchyItems.end(),
                              [&](const HierarchyItem& item) { return item.id == id; });
    if (imageIt == images.end() || rowIt == hierarchyItems.end()) return;
    const std::size_t imageIndex = static_cast<std::size_t>(imageIt - images.begin());
    const std::size_t rowIndex = static_cast<std::size_t>(rowIt - hierarchyItems.begin());
    pushUndoState();

    const SceneImage source = images[imageIndex];
    const HierarchyItem sourceRow = hierarchyItems[rowIndex];
    SceneImage copy = source;
    copy.id = Uuid::generate();
    const Uuid newID = copy.id;
    const std::string newName = sourceRow.name + " Copy";
    copy.name = newName;
    copy.position = source.position + Vec2(12, -12);
    copy.mesh = source.mesh.duplicated(newName + " Mesh");
    copy.animationClip = source.animationClip.retargeted(source.id, newID, newName);
    // Swift's duplicate passes these explicitly and leaves the rest at
    // their defaults: no slot, no normal map, no live deform.
    copy.slotName = "";
    copy.normalMapAssetID = std::nullopt;
    copy.meshAnimationDeform = std::nullopt;

    HierarchyItem row;
    row.id = newID;
    row.name = newName;
    row.type = sourceRow.type;
    row.isHidden = sourceRow.isHidden;
    row.children = sourceRow.children;
    row.order = sourceRow.order + 1;

    images.insert(images.begin() + static_cast<std::ptrdiff_t>(imageIndex), copy);
    hierarchyItems.insert(hierarchyItems.begin() + static_cast<std::ptrdiff_t>(rowIndex), row);
    normalizeOrder();
    setSelection({newID}, newID, false);
}

// ---- Reparenting and binding -----------------------------------------------

void EditorScene::reparentBone(Uuid id, std::optional<Uuid> parentID) {
    pushUndoState();
    const Bone* existing = skeleton.bone(id);
    const auto segment = skeleton.lineSegment(id);
    if (!skeleton.canParent(id, parentID) || !segment.has_value() || existing == nullptr) return;

    // Recreated from its WORLD segment under the new parent, so the bone
    // does not move on screen; identity and clip carry over. `color` does
    // NOT: Swift builds a fresh `Bone(...)` without passing it, so it falls
    // to nil until the next binding-colour refresh. Kept as it is.
    const Bone recreated = Bone::make(
        existing->name, segment->start, segment->end, parentID,
        parentID.has_value() ? skeleton.worldMatrix(*parentID) : std::nullopt);
    Bone bone = *existing;
    bone.parentID = recreated.parentID;
    bone.baseTransform = recreated.baseTransform;
    bone.localTransform = recreated.localTransform;
    bone.length = recreated.length;
    bone.color = std::nullopt;
    skeleton.setBone(bone);
    if (!parentID.has_value()) {
        if (std::find(skeleton.rootIDs.begin(), skeleton.rootIDs.end(), id) == skeleton.rootIDs.end()) {
            skeleton.rootIDs.push_back(id);
        }
    } else {
        std::erase(skeleton.rootIDs, id);
    }
    syncImagesToHierarchy();
    applyAnimationsNow();
}

void EditorScene::bindImage(Uuid imageID, std::optional<Uuid> boneID) {
    SceneImage* img = image(imageID);
    if (img == nullptr) return;
    ensureImageAnimationSpaceConsistency(skeleton, *img);
    const std::optional<Uuid> sourceBoneID =
        img->boneBinding.has_value() ? std::optional<Uuid>(img->boneBinding->boneID) : std::nullopt;
    if (sourceBoneID == boneID) return;
    syncImageBasePoseToVisiblePose(*img, sourceBoneID);

    if (!boneID.has_value()) {
        convertImageAnimationSpace(skeleton, *img, sourceBoneID, std::nullopt);
        img->boneBinding = std::nullopt;
        img->animationTransformSpace = TransformAnimationSpace::world();
        syncImagesToHierarchy();
        applyAnimationsNow();
        return;
    }
    if (skeleton.bone(*boneID) == nullptr) return;
    convertImageAnimationSpace(skeleton, *img, sourceBoneID, boneID);
    // The exact bone-local pose of what is visible: binding never changes
    // what is on screen, even under scaled or sheared bones.
    const SceneImageAnimationPose local = localSpritePose(skeleton, *img, boneID);
    BoneImageBinding binding;
    binding.boneID = *boneID;
    binding.localPosition = local.position;
    binding.localScale = local.scale;
    binding.localRotation = local.rotation;
    binding.localSkew = local.skew;
    img->boneBinding = binding;
    img->basePosition = local.position;
    img->baseScale = local.scale;
    img->baseRotation = local.rotation;
    img->baseSkew = local.skew;
    img->animationTransformSpace = TransformAnimationSpace::boneLocal(*boneID);
    syncImagesToHierarchy();
    applyAnimationsNow();
}

// ---- Undo -----------------------------------------------------------------

void EditorScene::applySnapshot(const SceneSnapshot& s) {
    images = s.images;
    skeleton = s.skeleton;
    sceneAnimationClip = s.sceneAnimationClip;
    constraintSetupValues = s.constraintSetupValues;
    skins = s.skins;
    activeSkinID = s.activeSkinID;
    animationEvents = s.animationEvents;
    selectedMeshVertexIndices.clear();
    selectedMeshInternalEdgeIndex = std::nullopt;
    pruneSceneAnimationTracks();
    pruneSkins();
    refreshSkinResolution();
    rebuildHierarchyFromState();
    applyAnimationsNow();
}

// ---- Draw order keys ------------------------------------------------------

void EditorScene::selectKeyframeAt(Uuid targetID, AnimationTrackProperty property, int frame) {
    for (const Keyframe& k : sceneAnimationClip.keyframesFor(targetID, property)) {
        if (k.frame == frame) {
            const SelectedKeyframe selection{targetID, property, k.id};
            selectedKeyframes = {selection};
            selectedKeyframe = selection;
            return;
        }
    }
}

void EditorScene::keyDrawOrder() {
    if (images.empty()) return;
    std::vector<Uuid> order;
    for (const SceneImage& img : images) order.push_back(img.id);
    keyDrawOrder(order);
}

void EditorScene::keyDrawOrder(const std::vector<Uuid>& order) {
    pushUndoState();
    sceneAnimationClip.upsertKeyframe(
        SceneAnimationTarget::drawOrder(), AnimationTrackProperty::DrawOrder, currentFrame,
        DrawOrderValue{order});
    selectKeyframeAt(SceneAnimationTarget::drawOrder(), AnimationTrackProperty::DrawOrder, currentFrame);
    applyAnimationsNow();
}

void EditorScene::removeDrawOrderKeyAtPlayhead() {
    for (const Keyframe& k : sceneAnimationClip.keyframesFor(SceneAnimationTarget::drawOrder(),
                                                             AnimationTrackProperty::DrawOrder)) {
        if (k.frame != currentFrame) continue;
        const Uuid keyID = k.id;
        pushUndoState();
        sceneAnimationClip.deleteKeyframes(SceneAnimationTarget::drawOrder(), AnimationTrackProperty::DrawOrder,
                                           {keyID});
        applyAnimationsNow();
        return;
    }
}

void EditorScene::removeDrawOrderTrack() {
    const std::vector<Keyframe> keys =
        sceneAnimationClip.keyframesFor(SceneAnimationTarget::drawOrder(), AnimationTrackProperty::DrawOrder);
    if (keys.empty()) return;
    pushUndoState();
    std::unordered_set<Uuid, UuidHash> ids;
    for (const Keyframe& k : keys) ids.insert(k.id);
    sceneAnimationClip.deleteKeyframes(SceneAnimationTarget::drawOrder(), AnimationTrackProperty::DrawOrder, ids);
    animatedDrawOrder = std::nullopt;
    applyAnimationsNow();
}

bool EditorScene::hasDrawOrderTrack() const {
    return sceneAnimationClip.hasTrack(SceneAnimationTarget::drawOrder(), AnimationTrackProperty::DrawOrder);
}

bool EditorScene::drawOrderHasKeyAtPlayhead() const {
    for (const Keyframe& k : sceneAnimationClip.keyframesFor(SceneAnimationTarget::drawOrder(),
                                                             AnimationTrackProperty::DrawOrder)) {
        if (k.frame == currentFrame) return true;
    }
    return false;
}

void EditorScene::pruneSceneAnimationTracks() {
    std::unordered_set<Uuid, UuidHash> liveImages;
    for (const SceneImage& img : images) liveImages.insert(img.id);
    std::vector<AnimationTrack> tracks = sceneAnimationClip.tracks();
    bool changed = false;

    // A track survives if its owner does. Scene tracks (draw order, events,
    // camera, lights) belong to the scene itself.
    //
    // BUG FIXED, NOT REPLICATED: Swift keeps only `.scene` tracks and asks
    // of every other one "is this a live constraint?". An ATTACHMENT track
    // (`.slot` domain) belongs to a slot, never a constraint, so it failed
    // that test every time -- and this runs inside `applySnapshot`, so
    // every undo silently deleted every attachment key in the project. A
    // slot track is kept here with the scene's.
    const auto size = tracks.size();
    std::erase_if(tracks, [&](const AnimationTrack& track) {
        const AnimationTrackDomain d = domain(track.property);
        if (d == AnimationTrackDomain::Scene || d == AnimationTrackDomain::Slot) return false;
        return !constraintKind(skeleton, track.targetID).has_value();
    });
    if (tracks.size() != size) changed = true;

    // A draw order key naming deleted sprites is rewritten, not dropped, so
    // the rest of the ordering survives.
    for (AnimationTrack& track : tracks) {
        if (track.property != AnimationTrackProperty::DrawOrder) continue;
        for (Keyframe& k : track.keyframes) {
            const std::vector<Uuid>* order = drawOrderValue(k.value);
            if (order == nullptr) continue;
            std::vector<Uuid> filtered;
            for (Uuid id : *order) {
                if (liveImages.contains(id)) filtered.push_back(id);
            }
            if (filtered.size() != order->size()) {
                k.value = DrawOrderValue{filtered};
                changed = true;
            }
        }
    }

    std::unordered_set<Uuid, UuidHash> liveConstraints;
    for (const BoneConstraint* c : skeleton.allConstraints()) liveConstraints.insert(c->id());
    std::erase_if(constraintSetupValues, [&](const auto& entry) { return !liveConstraints.contains(entry.first); });

    if (changed) sceneAnimationClip.setTracks(std::move(tracks));
}

} // namespace umeshcore
