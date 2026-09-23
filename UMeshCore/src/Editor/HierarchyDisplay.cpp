#include "umeshcore/Editor/HierarchyDisplay.h"

#include <algorithm>
#include <functional>
#include <limits>

namespace umeshcore {

namespace {

// Stable ids that never collide with a real item's, matching the Swift
// source's literal `UUID(uuidString:)` constants exactly (see the header:
// nothing reads these outside this file, so they stay file-local rather
// than joining the public API).
constexpr Uuid kVirtualSkeletonID(0x0000000000000000ULL, 0x0000FFFFFFFFFFFFULL);
constexpr Uuid kVirtualImagesID(0x0000000000000000ULL, 0x0000EEEEEEEEEEEEULL);
constexpr Uuid kVirtualConstraintsID(0x0000000000000000ULL, 0x0000DDDDDDDDDDDDULL);

// One row before the backward tree-line pass runs. Swift's private
// `TreeBaseEntry`; kept as an implementation detail here too.
struct TreeBaseEntry {
    std::string id;
    Uuid targetID;
    HierarchyRowKind kind;
    int depth = 0;
    std::vector<Uuid> lineage;
};

// "something at level <level> whose id is <id>" -- what the backward pass
// remembers it has already seen, so both `continuingLevels` and
// `showsDescendantContinuation` can be answered in the one pass rather
// than by a per-row scan of every later entry.
struct AncestorKey {
    int level = 0;
    Uuid id;
    bool operator==(const AncestorKey&) const = default;
};
struct AncestorKeyHash {
    std::size_t operator()(const AncestorKey& key) const {
        return UuidHash{}(key.id) ^ (static_cast<std::size_t>(key.level) * 0x9e3779b97f4a7c15ULL);
    }
};

} // namespace

std::vector<Uuid> displayHierarchyIDs(
    const std::vector<HierarchyItem>& hierarchyItems, const std::vector<SceneImage>& images,
    const Skeleton& skeleton) {
    std::unordered_map<Uuid, const HierarchyItem*, UuidHash> itemsByID;
    itemsByID.reserve(hierarchyItems.size());
    for (const HierarchyItem& item : hierarchyItems) itemsByID[item.id] = &item;

    std::unordered_map<Uuid, std::vector<Uuid>, UuidHash> boundImages;
    for (const SceneImage& image : images) {
        if (image.boneBinding.has_value()) boundImages[image.boneBinding->boneID].push_back(image.id);
    }

    std::unordered_map<Uuid, int, UuidHash> itemOrder;
    itemOrder.reserve(hierarchyItems.size());
    for (const HierarchyItem& item : hierarchyItems) itemOrder[item.id] = item.order;

    std::unordered_map<Uuid, std::vector<Uuid>, UuidHash> childBones;
    for (const Bone& bone : skeleton.orderedBones()) {
        if (bone.parentID.has_value()) childBones[*bone.parentID].push_back(bone.id);
    }

    // Swift's `itemOrder[$0] ?? .max` -- an id with no entry sorts LAST,
    // not first, so an item that has not been through `normalizeOrder()`
    // yet does not jump the queue.
    const auto orderOf = [&itemOrder](Uuid id) -> int {
        const auto it = itemOrder.find(id);
        return it != itemOrder.end() ? it->second : std::numeric_limits<int>::max();
    };
    const auto byOrder = [&orderOf](Uuid a, Uuid b) { return orderOf(a) < orderOf(b); };

    std::vector<Uuid> orderedIDs;
    orderedIDs.reserve(hierarchyItems.size());
    std::unordered_set<Uuid, UuidHash> visited;
    visited.reserve(hierarchyItems.size());

    // A local recursive lambda needs `std::function` to name itself; the
    // rig depths this walks are never deep enough for that indirection to
    // matter.
    std::function<void(Uuid)> appendBone = [&](Uuid boneID) {
        if (itemsByID.find(boneID) == itemsByID.end() || visited.count(boneID) != 0) return;
        visited.insert(boneID);
        orderedIDs.push_back(boneID);

        std::vector<Uuid> imageIDs;
        if (const auto it = boundImages.find(boneID); it != boundImages.end()) imageIDs = it->second;
        std::stable_sort(imageIDs.begin(), imageIDs.end(), byOrder);
        for (Uuid imageID : imageIDs) {
            if (itemsByID.find(imageID) != itemsByID.end() && visited.count(imageID) == 0) {
                visited.insert(imageID);
                orderedIDs.push_back(imageID);
            }
        }

        std::vector<Uuid> childIDs;
        if (const auto it = childBones.find(boneID); it != childBones.end()) childIDs = it->second;
        std::stable_sort(childIDs.begin(), childIDs.end(), byOrder);
        for (Uuid childID : childIDs) appendBone(childID);
    };

    std::vector<Uuid> rootBoneIDs = skeleton.rootIDs;
    std::stable_sort(rootBoneIDs.begin(), rootBoneIDs.end(), byOrder);
    for (Uuid rootBoneID : rootBoneIDs) appendBone(rootBoneID);

    // Anything the walk never reached -- most commonly a sprite or bone
    // whose parent is missing -- still shows, in authored order, rather
    // than silently dropping out of the panel.
    std::vector<const HierarchyItem*> byAuthoredOrder;
    byAuthoredOrder.reserve(hierarchyItems.size());
    for (const HierarchyItem& item : hierarchyItems) byAuthoredOrder.push_back(&item);
    std::stable_sort(
        byAuthoredOrder.begin(), byAuthoredOrder.end(),
        [](const HierarchyItem* a, const HierarchyItem* b) { return a->order < b->order; });
    for (const HierarchyItem* item : byAuthoredOrder) {
        if (visited.count(item->id) == 0) {
            visited.insert(item->id);
            orderedIDs.push_back(item->id);
        }
    }

    return orderedIDs;
}

std::vector<Uuid> hierarchyBoneLineage(const Skeleton& skeleton, Uuid boneID) {
    // Collected leaf-to-root then reversed, rather than Swift's
    // `insert(_:at:0)` per step: same final order, without the O(n^2)
    // shifting a chain of any real length would otherwise pay for.
    std::vector<Uuid> lineage;
    const Bone* item = skeleton.bone(boneID);
    std::optional<Uuid> current = item != nullptr ? item->parentID : std::nullopt;
    // See the header: caps a corrupt or cyclic parent chain, matching
    // `EditorScene::depthOf`'s precedent rather than Swift's unbounded
    // `while let`.
    int safety = 0;
    while (current.has_value() && safety < 64) {
        lineage.push_back(*current);
        const Bone* parent = skeleton.bone(*current);
        current = parent != nullptr ? parent->parentID : std::nullopt;
        safety += 1;
    }
    std::reverse(lineage.begin(), lineage.end());
    return lineage;
}

int hierarchyBoneDepth(const Skeleton& skeleton, Uuid boneID) {
    // The same walk as `hierarchyBoneLineage`, so the two can never
    // disagree about how far up the chain a bone sits.
    return static_cast<int>(hierarchyBoneLineage(skeleton, boneID).size());
}

bool isHierarchyItemHiddenByCollapsedAncestor(
    Uuid itemID, HierarchyItem::ItemType type, const Skeleton& skeleton,
    const std::vector<SceneImage>& images,
    const std::unordered_set<Uuid, UuidHash>& collapsedBoneIDs) {
    if (type == HierarchyItem::ItemType::Bone) {
        // Starts at the item's PARENT: a bone's own row stays visible when
        // IT is collapsed -- collapsing hides its children, not itself.
        const Bone* item = skeleton.bone(itemID);
        std::optional<Uuid> current = item != nullptr ? item->parentID : std::nullopt;
        int safety = 0;
        while (current.has_value() && safety < 64) {
            if (collapsedBoneIDs.count(*current) != 0) return true;
            const Bone* parent = skeleton.bone(*current);
            current = parent != nullptr ? parent->parentID : std::nullopt;
            safety += 1;
        }
        return false;
    }

    // Image (and, in principle, Mesh -- see the header: no real
    // `HierarchyItem` is ever that type today, but the switch stays total
    // rather than assuming it never will be). Starts AT the bound bone
    // itself, unlike the bone case above: collapsing a bone hides the
    // sprites bound to it, which sit at the bone's own level, not below it.
    const SceneImage* boundImage = nullptr;
    for (const SceneImage& image : images) {
        if (image.id == itemID) {
            boundImage = &image;
            break;
        }
    }
    if (boundImage == nullptr || !boundImage->boneBinding.has_value()) return false;

    std::optional<Uuid> current = boundImage->boneBinding->boneID;
    int safety = 0;
    while (current.has_value() && safety < 64) {
        if (collapsedBoneIDs.count(*current) != 0) return true;
        const Bone* bone = skeleton.bone(*current);
        current = bone != nullptr ? bone->parentID : std::nullopt;
        safety += 1;
    }
    return false;
}

HierarchyDisplay buildHierarchyDisplay(
    const std::vector<HierarchyItem>& hierarchyItems, const std::vector<SceneImage>& images,
    const Skeleton& skeleton, const std::unordered_set<Uuid, UuidHash>& collapsedBoneIDs,
    const std::unordered_set<HierarchySection>& expandedSections) {
    const bool skeletonOpen = expandedSections.count(HierarchySection::Skeleton) != 0;
    const bool imagesOpen = expandedSections.count(HierarchySection::Images) != 0;

    std::unordered_map<Uuid, const HierarchyItem*, UuidHash> itemsByID;
    itemsByID.reserve(hierarchyItems.size());
    for (const HierarchyItem& item : hierarchyItems) itemsByID[item.id] = &item;

    const std::vector<Bone> orderedBones = skeleton.orderedBones();
    std::unordered_map<Uuid, int, UuidHash> boneDepths;
    boneDepths.reserve(orderedBones.size());
    for (const Bone& bone : orderedBones) boneDepths[bone.id] = hierarchyBoneDepth(skeleton, bone.id);

    const bool hasBones = !orderedBones.empty();

    std::vector<TreeBaseEntry> baseEntries;
    bool insertedImagesSection = false;

    if (hasBones) {
        baseEntries.push_back(TreeBaseEntry{
            "§skeleton", kVirtualSkeletonID, HierarchyRowKind(HierarchyRowSection{HierarchySection::Skeleton}),
            0, {}});
    }

    for (Uuid id : displayHierarchyIDs(hierarchyItems, images, skeleton)) {
        const auto itemIt = itemsByID.find(id);
        if (itemIt == itemsByID.end()) continue;
        const HierarchyItem& item = *itemIt->second;
        if (isHierarchyItemHiddenByCollapsedAncestor(id, item.type, skeleton, images, collapsedBoneIDs)) {
            continue;
        }

        if (item.type == HierarchyItem::ItemType::Bone) {
            if (!skeletonOpen) continue;
            const auto depthIt = boneDepths.find(id);
            const int rawDepth = depthIt != boneDepths.end() ? depthIt->second : 0;
            std::vector<Uuid> lineage{kVirtualSkeletonID};
            const std::vector<Uuid> ancestors = hierarchyBoneLineage(skeleton, id);
            lineage.insert(lineage.end(), ancestors.begin(), ancestors.end());
            baseEntries.push_back(TreeBaseEntry{
                id.toString(), id, HierarchyRowKind(HierarchyRowItem{HierarchyItem::ItemType::Bone}),
                rawDepth + 1, std::move(lineage)});
            continue;
        }

        // Image (or, defensively, Mesh -- see the header).
        const SceneImage* boundImage = nullptr;
        for (const SceneImage& image : images) {
            if (image.id == id) {
                boundImage = &image;
                break;
            }
        }
        if (boundImage != nullptr && boundImage->boneBinding.has_value()) {
            if (!skeletonOpen) continue;
            const Uuid boundBoneID = boundImage->boneBinding->boneID;
            const auto depthIt = boneDepths.find(boundBoneID);
            const int rawDepth = (depthIt != boneDepths.end() ? depthIt->second : 0) + 1;
            std::vector<Uuid> lineage{kVirtualSkeletonID};
            const std::vector<Uuid> ancestors = hierarchyBoneLineage(skeleton, boundBoneID);
            lineage.insert(lineage.end(), ancestors.begin(), ancestors.end());
            lineage.push_back(boundBoneID);
            baseEntries.push_back(TreeBaseEntry{
                id.toString(), id, HierarchyRowKind(HierarchyRowItem{HierarchyItem::ItemType::Image}),
                rawDepth + 1, lineage});
            std::vector<Uuid> meshLineage = lineage;
            meshLineage.push_back(id);
            baseEntries.push_back(TreeBaseEntry{
                "mesh-" + id.toString(), id, HierarchyRowKind(HierarchyRowMesh{id}), rawDepth + 2,
                std::move(meshLineage)});
        } else {
            if (!insertedImagesSection) {
                insertedImagesSection = true;
                baseEntries.push_back(TreeBaseEntry{
                    "§images", kVirtualImagesID,
                    HierarchyRowKind(HierarchyRowSection{HierarchySection::Images}), 0, {}});
            }
            if (!imagesOpen) continue;
            baseEntries.push_back(TreeBaseEntry{
                id.toString(), id, HierarchyRowKind(HierarchyRowItem{HierarchyItem::ItemType::Image}), 1,
                {kVirtualImagesID}});
            baseEntries.push_back(TreeBaseEntry{
                "mesh-" + id.toString(), id, HierarchyRowKind(HierarchyRowMesh{id}), 2,
                {kVirtualImagesID, id}});
        }
    }

    // Constraints, last, as their own section -- they belong to the
    // skeleton, not to the item tree, so they get one section rather than
    // being threaded into every bone they drive.
    const std::vector<IKConstraint>& constraints = skeleton.ikConstraints;
    if (!constraints.empty()) {
        baseEntries.push_back(TreeBaseEntry{
            "§constraints", kVirtualConstraintsID,
            HierarchyRowKind(HierarchyRowSection{HierarchySection::Constraints}), 0, {}});
        if (expandedSections.count(HierarchySection::Constraints) != 0) {
            for (const IKConstraint& constraint : constraints) {
                baseEntries.push_back(TreeBaseEntry{
                    "ik-" + constraint.id().toString(), constraint.id(),
                    HierarchyRowKind(HierarchyRowConstraint{constraint.id()}), 1, {kVirtualConstraintsID}});
            }
        }
    }

    // The tree lines, in ONE backward pass -- see `AncestorKey`'s comment.
    std::unordered_set<AncestorKey, AncestorKeyHash> seenLater;
    std::vector<std::vector<int>> continuing(baseEntries.size());
    std::vector<bool> descends(baseEntries.size(), false);
    for (std::size_t index = baseEntries.size(); index-- > 0;) {
        const TreeBaseEntry& entry = baseEntries[index];
        descends[index] = seenLater.count(AncestorKey{entry.depth, entry.targetID}) != 0;
        if (entry.depth > 0) {
            std::vector<int> levels;
            for (int level = 0; level < entry.depth; ++level) {
                if (static_cast<std::size_t>(level) >= entry.lineage.size()) continue;
                if (seenLater.count(AncestorKey{level, entry.lineage[static_cast<std::size_t>(level)]}) != 0) {
                    levels.push_back(level);
                }
            }
            continuing[index] = std::move(levels);
        }
        for (std::size_t level = 0; level < entry.lineage.size(); ++level) {
            seenLater.insert(AncestorKey{static_cast<int>(level), entry.lineage[level]});
        }
    }

    HierarchyDisplay display;
    display.entries.reserve(baseEntries.size());
    for (std::size_t index = 0; index < baseEntries.size(); ++index) {
        const TreeBaseEntry& entry = baseEntries[index];
        display.entries.push_back(HierarchyDisplayEntry{
            entry.id, entry.targetID, entry.kind, entry.depth, std::move(continuing[index]),
            descends[index]});
    }

    display.indexByID.reserve(hierarchyItems.size());
    for (std::size_t position = 0; position < hierarchyItems.size(); ++position) {
        display.indexByID[hierarchyItems[position].id] = static_cast<int>(position);
    }

    int unboundImages = 0;
    for (const Bone& bone : orderedBones) {
        if (bone.parentID.has_value()) display.parentsWithChildren.insert(*bone.parentID);
    }
    for (const SceneImage& image : images) {
        if (image.boneBinding.has_value()) {
            display.parentsWithChildren.insert(image.boneBinding->boneID);
        } else {
            unboundImages += 1;
        }
    }

    display.sectionCounts[HierarchySection::Skeleton] = static_cast<int>(orderedBones.size());
    display.sectionCounts[HierarchySection::Images] = unboundImages;
    display.sectionCounts[HierarchySection::Constraints] = static_cast<int>(constraints.size());

    return display;
}

} // namespace umeshcore
