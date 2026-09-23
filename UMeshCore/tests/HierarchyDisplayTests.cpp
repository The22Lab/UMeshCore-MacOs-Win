// Tests for Editor/HierarchyDisplay.h, ported from the non-view logic of
// `HierarchyView.swift`: `displayHierarchyIDs()` (on `SceneManager`),
// `boneLineage`, `boneDepth`, `isHiddenByCollapsedAncestor`, and the
// `display` tree builder.
//
// The tree builder's values are derived BY HAND against the fixture below
// -- walked on paper the same way the Swift source's backward pass would
// walk it -- not by running the port and reading back what it produced.
// That is the point of `testFullTreeMatchesTheHandDerivedShape`: it is the
// one test in this file that exercises every field on every row at once,
// and it is checked against arithmetic worked out from the algorithm's
// documented rules, not against the code under test.

#include "umeshcore/Editor/HierarchyDisplay.h"

#include <algorithm>

#include "umeshcore/Constraints/IKConstraint.h"

#include "TestHarness.h"

using namespace umeshcore;

namespace {

Bone makeBone(const char* name, std::optional<Uuid> parent, Uuid id) {
    Bone b;
    b.id = id;
    b.name = name;
    b.parentID = parent;
    b.length = 10.0f;
    b.animationClip = AnimationClip(name);
    return b;
}

HierarchyItem boneItem(Uuid id, const char* name, int order) {
    HierarchyItem item;
    item.id = id;
    item.name = name;
    item.type = HierarchyItem::ItemType::Bone;
    item.order = order;
    return item;
}

HierarchyItem imageItem(Uuid id, const char* name, int order) {
    HierarchyItem item;
    item.id = id;
    item.name = name;
    item.type = HierarchyItem::ItemType::Image;
    item.order = order;
    return item;
}

SceneImage boundImage(Uuid id, Uuid boneID) {
    SceneImage image;
    image.id = id;
    BoneImageBinding binding;
    binding.boneID = boneID;
    image.boneBinding = binding;
    return image;
}

SceneImage unboundImage(Uuid id) {
    SceneImage image;
    image.id = id;
    return image;
}

// A small, structurally interesting rig, reused across most tests:
//
//   R1 (root)
//   +-- C1
//   |   +-- S1 (bound sprite)
//   |   +-- G1
//   +-- C2
//   S2 (unbound sprite)
//   IK1 (constraint)
//
// hierarchyItems order: R1=0, C1=1, C2=2, G1=3, S1=4, S2=5 -- deliberately
// NOT the tree order, so a test that passed by coincidentally walking
// `hierarchyItems` in array order would fail.
struct Fixture {
    Uuid r1{1, 1}, c1{2, 2}, c2{3, 3}, g1{4, 4}, s1{5, 5}, s2{6, 6}, ik1{7, 7};
    Skeleton skeleton;
    std::vector<HierarchyItem> hierarchyItems;
    std::vector<SceneImage> images;
};

Fixture makeFixture() {
    Fixture f;
    f.skeleton = f.skeleton.addingBone(makeBone("R1", std::nullopt, f.r1));
    f.skeleton = f.skeleton.addingBone(makeBone("C1", f.r1, f.c1));
    f.skeleton = f.skeleton.addingBone(makeBone("C2", f.r1, f.c2));
    f.skeleton = f.skeleton.addingBone(makeBone("G1", f.c1, f.g1));

    IKConstraint ik("IK1", {f.c1}, f.c1);
    ik.id_ = f.ik1;
    f.skeleton.ikConstraints.push_back(ik);

    f.hierarchyItems = {
        boneItem(f.r1, "R1", 0), boneItem(f.c1, "C1", 1), boneItem(f.c2, "C2", 2),
        boneItem(f.g1, "G1", 3), imageItem(f.s1, "S1", 4), imageItem(f.s2, "S2", 5)};
    f.images = {boundImage(f.s1, f.c1), unboundImage(f.s2)};
    return f;
}

const std::unordered_set<Uuid, UuidHash> kNoCollapsed;
const std::unordered_set<HierarchySection> kAllOpen{
    HierarchySection::Skeleton, HierarchySection::Images, HierarchySection::Constraints};

template <typename T>
bool contains(const std::vector<T>& haystack, const T& needle) {
    return std::find(haystack.begin(), haystack.end(), needle) != haystack.end();
}

} // namespace

// ---- hierarchyBoneLineage / hierarchyBoneDepth -------------------------

static void testRootBoneHasEmptyLineageAndZeroDepth() {
    const Fixture f = makeFixture();
    UM_CHECK(hierarchyBoneLineage(f.skeleton, f.r1).empty());
    UM_CHECK(hierarchyBoneDepth(f.skeleton, f.r1) == 0);
}

static void testLineageIsRootFirst() {
    const Fixture f = makeFixture();
    const std::vector<Uuid> lineage = hierarchyBoneLineage(f.skeleton, f.g1);
    // G1's chain is R1 -> C1 -> G1, so the ancestors, root first, are
    // [R1, C1] -- NOT [C1, R1], which is what a naive "collect while
    // walking up" would produce without the reversal.
    UM_CHECK(lineage.size() == 2);
    if (lineage.size() == 2) {
        UM_CHECK(lineage[0] == f.r1);
        UM_CHECK(lineage[1] == f.c1);
    }
    UM_CHECK(hierarchyBoneDepth(f.skeleton, f.g1) == 2);
}

static void testLineageOfAnUnknownBoneIsEmpty() {
    const Fixture f = makeFixture();
    const Uuid unknown(999, 999);
    UM_CHECK(hierarchyBoneLineage(f.skeleton, unknown).empty());
    UM_CHECK(hierarchyBoneDepth(f.skeleton, unknown) == 0);
}

static void testCyclicParentChainIsCappedNotInfinite() {
    // A corrupt skeleton where two bones parent each other. Swift's plain
    // `while let` would hang; this port caps the walk (see the header --
    // the same precedent `EditorScene::depthOf` already set), so the call
    // returns rather than looping forever.
    Uuid a(11, 11), b(12, 12);
    Skeleton skeleton;
    skeleton = skeleton.addingBone(makeBone("A", b, a));
    Bone bBone = makeBone("B", a, b);
    skeleton.setBone(bBone);

    const std::vector<Uuid> lineage = hierarchyBoneLineage(skeleton, a);
    UM_CHECK(lineage.size() == 64);
    UM_CHECK(hierarchyBoneDepth(skeleton, a) == 64);
}

// ---- isHierarchyItemHiddenByCollapsedAncestor ---------------------------

static void testABoneRowStaysVisibleWhenItIsTheOneCollapsedNotItsAncestor() {
    // Collapsing a bone hides its CHILDREN; the bone's own row must stay
    // visible, or there would be no way to expand it again.
    const Fixture f = makeFixture();
    const std::unordered_set<Uuid, UuidHash> collapsed{f.c1};
    UM_CHECK(!isHierarchyItemHiddenByCollapsedAncestor(
        f.c1, HierarchyItem::ItemType::Bone, f.skeleton, f.images, collapsed));
}

static void testABoneRowIsHiddenWhenItsParentIsCollapsed() {
    const Fixture f = makeFixture();
    const std::unordered_set<Uuid, UuidHash> collapsed{f.c1};
    UM_CHECK(isHierarchyItemHiddenByCollapsedAncestor(
        f.g1, HierarchyItem::ItemType::Bone, f.skeleton, f.images, collapsed));
}

static void testABoneRowIsHiddenByACollapsedGrandparent() {
    const Fixture f = makeFixture();
    const std::unordered_set<Uuid, UuidHash> collapsed{f.r1};
    UM_CHECK(isHierarchyItemHiddenByCollapsedAncestor(
        f.g1, HierarchyItem::ItemType::Bone, f.skeleton, f.images, collapsed));
}

static void testASiblingBranchIsUnaffected() {
    const Fixture f = makeFixture();
    const std::unordered_set<Uuid, UuidHash> collapsed{f.c1};
    UM_CHECK(!isHierarchyItemHiddenByCollapsedAncestor(
        f.c2, HierarchyItem::ItemType::Bone, f.skeleton, f.images, collapsed));
}

static void testABoundImageIsHiddenWhenItsOwnBoneIsCollapsed() {
    // The asymmetry with the bone case, documented in the header: a
    // sprite bound to a bone sits AT that bone's level, so collapsing the
    // bone itself -- not just an ancestor of it -- hides the sprite.
    const Fixture f = makeFixture();
    const std::unordered_set<Uuid, UuidHash> collapsed{f.c1};
    UM_CHECK(isHierarchyItemHiddenByCollapsedAncestor(
        f.s1, HierarchyItem::ItemType::Image, f.skeleton, f.images, collapsed));
}

static void testABoundImageIsHiddenByACollapsedAncestorOfItsBone() {
    const Fixture f = makeFixture();
    const std::unordered_set<Uuid, UuidHash> collapsed{f.r1};
    UM_CHECK(isHierarchyItemHiddenByCollapsedAncestor(
        f.s1, HierarchyItem::ItemType::Image, f.skeleton, f.images, collapsed));
}

static void testAnUnboundImageIsNeverHiddenByCollapse() {
    const Fixture f = makeFixture();
    // Collapse literally everything; an unbound sprite has no bone chain
    // to be hidden by.
    const std::unordered_set<Uuid, UuidHash> collapsed{f.r1, f.c1, f.c2, f.g1};
    UM_CHECK(!isHierarchyItemHiddenByCollapsedAncestor(
        f.s2, HierarchyItem::ItemType::Image, f.skeleton, f.images, collapsed));
}

static void testAnImageRowWithNoMatchingSceneImageIsNotHidden() {
    // Defensive: an id that names no `SceneImage` at all (should not
    // happen, but nothing here assumes it can't) reads as unbound rather
    // than crashing or hiding.
    const Fixture f = makeFixture();
    const Uuid unknown(999, 999);
    UM_CHECK(!isHierarchyItemHiddenByCollapsedAncestor(
        unknown, HierarchyItem::ItemType::Image, f.skeleton, f.images, kNoCollapsed));
}

// ---- displayHierarchyIDs -------------------------------------------------

static void testWalksBonesDepthFirstEachFollowedByItsOwnBoundSpritesThenChildren() {
    const Fixture f = makeFixture();
    const std::vector<Uuid> ids = displayHierarchyIDs(f.hierarchyItems, f.images, f.skeleton);
    // R1, then C1 (R1's first child by order), then S1 (bound to C1,
    // appended BEFORE C1's own children), then G1 (C1's child), then C2
    // (R1's second child), then S2 (unbound, unreached by the bone walk,
    // appended in the authored-order tail).
    const std::vector<Uuid> expected = {f.r1, f.c1, f.s1, f.g1, f.c2, f.s2};
    UM_CHECK(ids == expected);
}

static void testABoneMissingFromHierarchyItemsDropsItsWholeSubtreeFromTheWalk() {
    // `childBones`/`boundImages` are built from the SKELETON and IMAGES,
    // independent of `hierarchyItems`; the walk itself only descends into
    // a bone that has a `HierarchyItem`. A bone the artist's data is
    // missing a row for therefore takes its whole subtree out of the
    // tree-shaped part of the walk -- but anything under it that DOES
    // have a `HierarchyItem` is not lost, only flattened into the
    // unreached tail, in authored order.
    Fixture f = makeFixture();
    // Remove C1's OWN hierarchy item, but leave G1's (C1's child) in
    // place.
    f.hierarchyItems.erase(
        std::remove_if(
            f.hierarchyItems.begin(), f.hierarchyItems.end(),
            [&](const HierarchyItem& item) { return item.id == f.c1; }),
        f.hierarchyItems.end());

    const std::vector<Uuid> ids = displayHierarchyIDs(f.hierarchyItems, f.images, f.skeleton);
    UM_CHECK(!contains(ids, f.c1));
    // G1 and S1 still appear -- in the tail, in their authored order
    // (G1's order=3 precedes S1's order=4) -- rather than vanishing along
    // with their now-absent parent row.
    UM_CHECK(contains(ids, f.g1));
    UM_CHECK(contains(ids, f.s1));
    const auto indexOf = [&ids](Uuid id) {
        return static_cast<int>(std::find(ids.begin(), ids.end(), id) - ids.begin());
    };
    UM_CHECK(indexOf(f.g1) < indexOf(f.s1));
    // And the reachable part of the tree (R1, C2) is unaffected.
    UM_CHECK(ids.front() == f.r1);
    UM_CHECK(contains(ids, f.c2));
}

static void testEmptyProjectProducesAnEmptyWalk() {
    const std::vector<HierarchyItem> noItems;
    const std::vector<SceneImage> noImages;
    const Skeleton empty;
    UM_CHECK(displayHierarchyIDs(noItems, noImages, empty).empty());
}

// ---- buildHierarchyDisplay: sections, visibility, counts ----------------

static void testSkeletonHeaderAppearsOnlyWhenThereAreBones() {
    const Fixture f = makeFixture();
    const HierarchyDisplay withBones =
        buildHierarchyDisplay(f.hierarchyItems, f.images, f.skeleton, kNoCollapsed, kAllOpen);
    UM_CHECK(std::holds_alternative<HierarchyRowSection>(withBones.entries.front().kind));

    const std::vector<HierarchyItem> noBoneItems = {imageItem(f.s2, "S2", 0)};
    const std::vector<SceneImage> justAnImage = {unboundImage(f.s2)};
    const Skeleton noBones;
    const HierarchyDisplay withoutBones =
        buildHierarchyDisplay(noBoneItems, justAnImage, noBones, kNoCollapsed, kAllOpen);
    for (const HierarchyDisplayEntry& entry : withoutBones.entries) {
        if (const auto* section = std::get_if<HierarchyRowSection>(&entry.kind)) {
            UM_CHECK(section->section != HierarchySection::Skeleton);
        }
    }
}

static void testCollapsingTheSkeletonSectionHidesRowsButKeepsTheHeader() {
    const Fixture f = makeFixture();
    const std::unordered_set<HierarchySection> onlyImagesAndConstraintsOpen{
        HierarchySection::Images, HierarchySection::Constraints};
    const HierarchyDisplay display =
        buildHierarchyDisplay(f.hierarchyItems, f.images, f.skeleton, kNoCollapsed, onlyImagesAndConstraintsOpen);

    bool sawSkeletonHeader = false;
    for (const HierarchyDisplayEntry& entry : display.entries) {
        if (const auto* section = std::get_if<HierarchyRowSection>(&entry.kind)) {
            if (section->section == HierarchySection::Skeleton) sawSkeletonHeader = true;
        }
        // No bone or bone-bound-image row should have made it through.
        UM_CHECK(entry.targetID != f.r1);
        UM_CHECK(entry.targetID != f.c1);
        UM_CHECK(entry.targetID != f.s1);
    }
    UM_CHECK(sawSkeletonHeader);
}

static void testImagesHeaderIsInsertedLazilyOnlyOnceAnUnboundImageIsSeen() {
    const Fixture f = makeFixture();
    const HierarchyDisplay display =
        buildHierarchyDisplay(f.hierarchyItems, f.images, f.skeleton, kNoCollapsed, kAllOpen);
    int sectionCount = 0;
    for (const HierarchyDisplayEntry& entry : display.entries) {
        if (const auto* section = std::get_if<HierarchyRowSection>(&entry.kind)) {
            if (section->section == HierarchySection::Images) sectionCount += 1;
        }
    }
    UM_CHECK(sectionCount == 1);
}

static void testConstraintsSectionOnlyAppearsWhenThereAreConstraints() {
    Fixture f = makeFixture();
    f.skeleton.ikConstraints.clear();
    const HierarchyDisplay display =
        buildHierarchyDisplay(f.hierarchyItems, f.images, f.skeleton, kNoCollapsed, kAllOpen);
    for (const HierarchyDisplayEntry& entry : display.entries) {
        if (const auto* section = std::get_if<HierarchyRowSection>(&entry.kind)) {
            UM_CHECK(section->section != HierarchySection::Constraints);
        }
    }
}

static void testConstraintRowsAreOmittedWhenTheSectionIsCollapsedButTheHeaderStays() {
    const Fixture f = makeFixture();
    const std::unordered_set<HierarchySection> constraintsClosed{
        HierarchySection::Skeleton, HierarchySection::Images};
    const HierarchyDisplay display =
        buildHierarchyDisplay(f.hierarchyItems, f.images, f.skeleton, kNoCollapsed, constraintsClosed);
    bool sawHeader = false;
    for (const HierarchyDisplayEntry& entry : display.entries) {
        if (const auto* section = std::get_if<HierarchyRowSection>(&entry.kind)) {
            if (section->section == HierarchySection::Constraints) sawHeader = true;
        }
        UM_CHECK(!std::holds_alternative<HierarchyRowConstraint>(entry.kind));
    }
    UM_CHECK(sawHeader);
}

static void testSectionCountsAreTotalsIndependentOfWhatIsOpenOrCollapsed() {
    const Fixture f = makeFixture();
    // Everything closed and C1's whole branch collapsed -- the counts must
    // not move, because they answer "how many bones/unbound sprites/
    // constraints does the project have", not "how many rows are showing".
    const std::unordered_set<HierarchySection> nothingOpen;
    const std::unordered_set<Uuid, UuidHash> collapsed{f.c1};
    const HierarchyDisplay display =
        buildHierarchyDisplay(f.hierarchyItems, f.images, f.skeleton, collapsed, nothingOpen);
    UM_CHECK(display.sectionCounts.at(HierarchySection::Skeleton) == 4); // R1, C1, C2, G1
    UM_CHECK(display.sectionCounts.at(HierarchySection::Images) == 1);  // S2 only -- S1 is bound
    UM_CHECK(display.sectionCounts.at(HierarchySection::Constraints) == 1);
}

static void testIndexByIDMatchesEachItemsPositionInTheSourceArray() {
    const Fixture f = makeFixture();
    const HierarchyDisplay display =
        buildHierarchyDisplay(f.hierarchyItems, f.images, f.skeleton, kNoCollapsed, kAllOpen);
    for (std::size_t i = 0; i < f.hierarchyItems.size(); ++i) {
        const Uuid id = f.hierarchyItems[i].id;
        UM_CHECK(display.indexByID.count(id) == 1);
        if (display.indexByID.count(id) == 1) {
            UM_CHECK(display.indexByID.at(id) == static_cast<int>(i));
        }
    }
}

static void testParentsWithChildrenCountsBothBoneParentsAndBoundImageTargets() {
    const Fixture f = makeFixture();
    const HierarchyDisplay display =
        buildHierarchyDisplay(f.hierarchyItems, f.images, f.skeleton, kNoCollapsed, kAllOpen);
    // R1 parents C1 and C2; C1 parents G1 AND has S1 bound to it.
    UM_CHECK(display.parentsWithChildren.count(f.r1) == 1);
    UM_CHECK(display.parentsWithChildren.count(f.c1) == 1);
    // Leaves are not "parents of children".
    UM_CHECK(display.parentsWithChildren.count(f.g1) == 0);
    UM_CHECK(display.parentsWithChildren.count(f.c2) == 0);
}

// ---- buildHierarchyDisplay: the full hand-derived shape ------------------

static void testFullTreeMatchesTheHandDerivedShape() {
    const Fixture f = makeFixture();
    const HierarchyDisplay display =
        buildHierarchyDisplay(f.hierarchyItems, f.images, f.skeleton, kNoCollapsed, kAllOpen);

    // Twelve rows: §skeleton, R1, C1, S1, mesh-S1, G1, C2, §images, S2,
    // mesh-S2, §constraints, ik-IK1 -- in exactly that order.
    UM_CHECK(display.entries.size() == 12);
    if (display.entries.size() != 12) return;

    const auto& e = display.entries;

    // Row 0: the skeleton header. Depth 0, no lineage, and it DOES show a
    // descendant continuing below it (R1 is right there).
    UM_CHECK(std::holds_alternative<HierarchyRowSection>(e[0].kind));
    UM_CHECK(e[0].depth == 0);
    UM_CHECK(e[0].continuingLevels.empty());
    UM_CHECK(e[0].showsDescendantContinuation);

    // Row 1: R1. A root bone is depth 1 (one indent in from the header).
    UM_CHECK(e[1].targetID == f.r1);
    UM_CHECK(e[1].depth == 1);
    UM_CHECK(e[1].continuingLevels == std::vector<int>{0});
    UM_CHECK(e[1].showsDescendantContinuation); // C1 follows

    // Row 2: C1, depth 2.
    UM_CHECK(e[2].targetID == f.c1);
    UM_CHECK(e[2].depth == 2);
    UM_CHECK((e[2].continuingLevels == std::vector<int>{0, 1}));
    UM_CHECK(e[2].showsDescendantContinuation); // G1 shares C1 as an ancestor, later

    // Row 3: S1, the sprite bound to C1. One indent deeper than C1.
    UM_CHECK(e[3].targetID == f.s1);
    UM_CHECK(std::holds_alternative<HierarchyRowItem>(e[3].kind));
    UM_CHECK(e[3].depth == 3);
    UM_CHECK((e[3].continuingLevels == std::vector<int>{0, 1, 2}));
    UM_CHECK(e[3].showsDescendantContinuation); // its own mesh row follows

    // Row 4: S1's mesh row -- always a leaf, one indent deeper still.
    UM_CHECK(e[4].targetID == f.s1);
    UM_CHECK(std::holds_alternative<HierarchyRowMesh>(e[4].kind));
    UM_CHECK(e[4].depth == 4);
    UM_CHECK((e[4].continuingLevels == std::vector<int>{0, 1, 2}));
    UM_CHECK(!e[4].showsDescendantContinuation);

    // Row 5: G1, C1's other child. Sibling of S1's subtree, same depth as
    // S1's own row (3), because it hangs directly off C1.
    UM_CHECK(e[5].targetID == f.g1);
    UM_CHECK(e[5].depth == 3);
    UM_CHECK((e[5].continuingLevels == std::vector<int>{0, 1}));
    UM_CHECK(!e[5].showsDescendantContinuation); // G1 is a leaf

    // Row 6: C2, R1's second child. Nothing continues past it in the
    // skeleton section -- it is the last bone row -- so BOTH its
    // continuing levels and its own descendant flag are empty/false.
    UM_CHECK(e[6].targetID == f.c2);
    UM_CHECK(e[6].depth == 2);
    UM_CHECK(e[6].continuingLevels.empty());
    UM_CHECK(!e[6].showsDescendantContinuation);

    // Row 7: the Images header, inserted right where the first unbound
    // sprite was found. It DOES show a descendant (S2 follows).
    UM_CHECK(std::holds_alternative<HierarchyRowSection>(e[7].kind));
    UM_CHECK(e[7].depth == 0);
    UM_CHECK(e[7].showsDescendantContinuation);

    // Row 8: S2, the unbound sprite.
    UM_CHECK(e[8].targetID == f.s2);
    UM_CHECK(e[8].depth == 1);
    UM_CHECK((e[8].continuingLevels == std::vector<int>{0}));
    UM_CHECK(e[8].showsDescendantContinuation);

    // Row 9: S2's mesh row.
    UM_CHECK(e[9].targetID == f.s2);
    UM_CHECK(std::holds_alternative<HierarchyRowMesh>(e[9].kind));
    UM_CHECK(e[9].depth == 2);
    UM_CHECK(e[9].continuingLevels.empty());
    UM_CHECK(!e[9].showsDescendantContinuation);

    // Row 10: the Constraints header.
    UM_CHECK(std::holds_alternative<HierarchyRowSection>(e[10].kind));
    UM_CHECK(e[10].depth == 0);
    UM_CHECK(e[10].showsDescendantContinuation);

    // Row 11: the one IK constraint row -- last, a leaf.
    UM_CHECK(e[11].targetID == f.ik1);
    UM_CHECK(std::holds_alternative<HierarchyRowConstraint>(e[11].kind));
    UM_CHECK(e[11].depth == 1);
    UM_CHECK(e[11].continuingLevels.empty());
    UM_CHECK(!e[11].showsDescendantContinuation);
}

static void testCollapsingABranchHidesItsSpriteAndDescendantRowsButNotItsSiblingOrItself() {
    const Fixture f = makeFixture();
    const std::unordered_set<Uuid, UuidHash> collapsed{f.c1};
    const HierarchyDisplay display =
        buildHierarchyDisplay(f.hierarchyItems, f.images, f.skeleton, collapsed, kAllOpen);

    bool sawC1 = false, sawC2 = false;
    for (const HierarchyDisplayEntry& entry : display.entries) {
        if (entry.targetID == f.c1) sawC1 = true;
        if (entry.targetID == f.c2) sawC2 = true;
        // S1 (bound to C1) and G1 (C1's child) must not appear at all.
        UM_CHECK(entry.targetID != f.s1);
        UM_CHECK(entry.targetID != f.g1);
    }
    UM_CHECK(sawC1); // C1's own row survives its own collapse
    UM_CHECK(sawC2); // the sibling branch is untouched
}

UM_TEST_MAIN_BEGIN()
testRootBoneHasEmptyLineageAndZeroDepth();
testLineageIsRootFirst();
testLineageOfAnUnknownBoneIsEmpty();
testCyclicParentChainIsCappedNotInfinite();
testABoneRowStaysVisibleWhenItIsTheOneCollapsedNotItsAncestor();
testABoneRowIsHiddenWhenItsParentIsCollapsed();
testABoneRowIsHiddenByACollapsedGrandparent();
testASiblingBranchIsUnaffected();
testABoundImageIsHiddenWhenItsOwnBoneIsCollapsed();
testABoundImageIsHiddenByACollapsedAncestorOfItsBone();
testAnUnboundImageIsNeverHiddenByCollapse();
testAnImageRowWithNoMatchingSceneImageIsNotHidden();
testWalksBonesDepthFirstEachFollowedByItsOwnBoundSpritesThenChildren();
testABoneMissingFromHierarchyItemsDropsItsWholeSubtreeFromTheWalk();
testEmptyProjectProducesAnEmptyWalk();
testSkeletonHeaderAppearsOnlyWhenThereAreBones();
testCollapsingTheSkeletonSectionHidesRowsButKeepsTheHeader();
testImagesHeaderIsInsertedLazilyOnlyOnceAnUnboundImageIsSeen();
testConstraintsSectionOnlyAppearsWhenThereAreConstraints();
testConstraintRowsAreOmittedWhenTheSectionIsCollapsedButTheHeaderStays();
testSectionCountsAreTotalsIndependentOfWhatIsOpenOrCollapsed();
testIndexByIDMatchesEachItemsPositionInTheSourceArray();
testParentsWithChildrenCountsBothBoneParentsAndBoundImageTargets();
testFullTreeMatchesTheHandDerivedShape();
testCollapsingABranchHidesItsSpriteAndDescendantRowsButNotItsSiblingOrItself();
UM_TEST_MAIN_END()
