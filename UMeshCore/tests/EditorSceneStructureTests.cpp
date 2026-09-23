// Tests for the structural half of EditorScene absorbed from SceneManager
// in Phase 6a: hierarchy rows, draw order, deletion, reparenting, draw
// order keys, skins/slots/attachments, plus the two utilities that came
// with them (`naturalCompare`, `IKBuilderRules`).
//
// Two of these tests pin Swift BUGS that the port fixes rather than
// replicates (convention #3), and say so by name:
//   - undo used to delete every attachment key in the project;
//   - "sort draw order by bone depth" sorted the wrong way round.

#include "umeshcore/Core/NaturalCompare.h"
#include "umeshcore/Editor/EditorScene.h"
#include "umeshcore/Editor/IKBuilder.h"

#include <algorithm>

#include "TestHarness.h"

using namespace umeshcore;

namespace {

Uuid addSprite(EditorScene& scene, const std::string& name) {
    return scene.addImage(Uuid::generate(), name, Vec2(64, 64), Vec2(0, 0), std::nullopt);
}

std::vector<Uuid> ids(const std::vector<SceneImage>& images) {
    std::vector<Uuid> out;
    for (const SceneImage& img : images) out.push_back(img.id);
    return out;
}

std::size_t indexOf(const std::vector<Uuid>& v, Uuid id) {
    return static_cast<std::size_t>(std::find(v.begin(), v.end(), id) - v.begin());
}

} // namespace

// ---- Creation ---------------------------------------------------------------

static void testAddImageGoesToTheFrontAndIsSelected() {
    EditorScene scene;
    const Uuid a = addSprite(scene, "A");
    const Uuid b = addSprite(scene, "B");
    // Newest at index 0 of both lists, as `images.insert(at: 0)` does.
    UM_CHECK(scene.images.front().id == b && scene.images.back().id == a);
    UM_CHECK(scene.hierarchyItems.front().id == b);
    UM_CHECK(scene.hierarchyItems[0].order == 0 && scene.hierarchyItems[1].order == 1);
    UM_CHECK(scene.selectedImageID == b);
    UM_CHECK(scene.images.front().mesh.name == "B Mesh");
    UM_CHECK(scene.images.front().animationClip.name == "B");
}

static void testABoneGetsARowSoItsSubtreeIsListed() {
    // A bone with no row drops its WHOLE subtree out of the tree walk, so
    // the row is not cosmetic.
    EditorScene scene;
    const Uuid root = scene.addBone(Vec2(0, 0), Vec2(100, 0));
    const Uuid child = scene.addBone(Vec2(100, 0), Vec2(200, 0), root);
    const std::vector<Uuid> shown = scene.displayHierarchyIDs();
    UM_CHECK(shown.size() == 2 && shown[0] == root && shown[1] == child);
    UM_CHECK(scene.hierarchyItems.size() == 2);
    UM_CHECK(scene.hierarchyItems[1].type == HierarchyItem::ItemType::Bone);
    UM_CHECK(scene.selectedBoneID == child);
}

// ---- Draw order -------------------------------------------------------------

static void testAMovedSpriteLandsOnTheRowItWasDroppedOn() {
    // The Swift comment's bug: an index taken BEFORE the removal landed a
    // downward drag one row too far. By identity, the moved id always ends
    // up on the row it was dropped on, in both directions.
    const Uuid A(1, 1), B(1, 2), C(1, 3), D(1, 4);
    const std::vector<Uuid> order{A, B, C, D};

    const auto down1 = EditorScene::movingIDToRow(A, 1, order);
    UM_CHECK(down1.has_value() && *down1 == (std::vector<Uuid>{B, A, C, D}));
    const auto down2 = EditorScene::movingIDToRow(A, 2, order);
    UM_CHECK(down2.has_value() && indexOf(*down2, A) == 2);
    const auto up = EditorScene::movingIDToRow(D, 1, order);
    UM_CHECK(up.has_value() && *up == (std::vector<Uuid>{A, D, B, C}));
    // Past the end means "the back".
    const auto past = EditorScene::movingIDToRow(A, 99, order);
    UM_CHECK(past.has_value() && indexOf(*past, A) == 3);
    // Onto itself: unchanged.
    UM_CHECK(EditorScene::movingIDToRow(B, 1, order) == order);
    UM_CHECK(!EditorScene::movingIDToRow(Uuid(9, 9), 1, order).has_value());
}

static void testTheResolvedOrderDropsTheDeadAndAppendsTheNew() {
    EditorScene scene;
    const Uuid a = addSprite(scene, "A");
    const Uuid b = addSprite(scene, "B");
    const Uuid c = addSprite(scene, "C"); // images: [C, B, A]
    scene.setAuthoredDrawOrder({a, Uuid(7, 7), c});
    // The authored ones in their order, the ghost gone, B (never authored)
    // appended in the order `images` holds it.
    UM_CHECK(scene.resolvedDrawOrder() == (std::vector<Uuid>{a, c, b}));

    // Once authored, a move rewrites the authored list.
    scene.moveImageInDrawOrder(b, 0);
    UM_CHECK(scene.authoredDrawOrder == (std::vector<Uuid>{b, a, c}));
    UM_CHECK(ids(scene.renderOrderedImages()) == (std::vector<Uuid>{b, a, c}));
}

static void testTheRenderOrderHonoursAKeyAndHidesWhatTheSkinHides() {
    EditorScene scene;
    const Uuid a = addSprite(scene, "A");
    const Uuid b = addSprite(scene, "B");
    const Uuid c = addSprite(scene, "C"); // [C, B, A]

    // A keyed order wins; a sprite the key does not name sits behind.
    scene.animatedDrawOrder = std::vector<Uuid>{a, c};
    UM_CHECK(ids(scene.renderOrderedImages()) == (std::vector<Uuid>{a, c, b}));

    // Two sprites in one slot with no skin: the first visible shows, the
    // other is hidden from the render order.
    scene.animatedDrawOrder = std::nullopt;
    scene.assignSlot("hand", {a, b});
    UM_CHECK(scene.isHiddenByActiveSkin(a) != scene.isHiddenByActiveSkin(b));
    const std::vector<Uuid> drawn = ids(scene.renderOrderedImages());
    UM_CHECK(drawn.size() == 2);
    UM_CHECK(std::find(drawn.begin(), drawn.end(), c) != drawn.end());
}

static void testSortByBoneDepthPutsTheDeeperBoneInFront() {
    // BUG FIXED: Swift sorted ascending, putting unbound sprites at the
    // FRONT and the forearm BEHIND the upper arm -- the reverse of what the
    // command promises. Index 0 is the front.
    EditorScene scene;
    const Uuid upper = scene.addBone(Vec2(0, 0), Vec2(100, 0));
    const Uuid fore = scene.addBone(Vec2(100, 0), Vec2(200, 0), upper);
    const Uuid loose = addSprite(scene, "loose");
    const Uuid upperArt = addSprite(scene, "upperArt");
    const Uuid foreArt = addSprite(scene, "foreArt");
    scene.bindImage(upperArt, upper);
    scene.bindImage(foreArt, fore);
    scene.setAuthoredDrawOrder({loose, upperArt, foreArt});

    scene.sortDrawOrderByBoneDepth();
    UM_CHECK(scene.authoredDrawOrder == (std::vector<Uuid>{foreArt, upperArt, loose}));
    // Idempotent: a second run pushes no undo and changes nothing.
    const auto before = scene.authoredDrawOrder;
    scene.sortDrawOrderByBoneDepth();
    UM_CHECK(scene.authoredDrawOrder == before);
}

// ---- Keys and undo ----------------------------------------------------------

static void testUndoKeepsAttachmentKeys() {
    // BUG FIXED: Swift's prune kept only scene-domain tracks and asked of
    // every other one "is this a live constraint?". An attachment track
    // belongs to a slot, so it failed every time -- and the prune runs on
    // every undo.
    EditorScene scene;
    const Uuid a = addSprite(scene, "A");
    scene.setAnimationEditingEnabled(true);
    scene.keyAttachment("hand", a);
    const Uuid slotTrack = SlotAnimationTarget::id("hand");
    UM_CHECK(scene.sceneAnimationClip.hasTrack(slotTrack, AnimationTrackProperty::Attachment));

    scene.pushUndoState();
    scene.renameHierarchyItem(a, "renamed");
    scene.undo();
    UM_CHECK(scene.sceneAnimationClip.hasTrack(slotTrack, AnimationTrackProperty::Attachment));
    UM_CHECK(scene.attachmentHasKeyAtPlayhead("hand"));
}

static void testPruneDropsDeadConstraintTracksAndRewritesDrawOrderKeys() {
    EditorScene scene;
    const Uuid a = addSprite(scene, "A");
    const Uuid b = addSprite(scene, "B");
    scene.setAnimationEditingEnabled(true);
    scene.keyDrawOrder({a, b});
    // A constraint track whose constraint does not exist.
    scene.sceneAnimationClip.upsertKeyframe(Uuid(4, 4), AnimationTrackProperty::ConstraintMix, 0,
                                            ScalarValue{0.5f});
    scene.deleteHierarchy(b);
    scene.pruneSceneAnimationTracks();

    UM_CHECK(!scene.sceneAnimationClip.hasTrack(Uuid(4, 4), AnimationTrackProperty::ConstraintMix));
    const auto& keys =
        scene.sceneAnimationClip.keyframesFor(SceneAnimationTarget::drawOrder(), AnimationTrackProperty::DrawOrder);
    UM_CHECK(keys.size() == 1);
    const std::vector<Uuid>* order = drawOrderValue(keys[0].value);
    UM_CHECK(order != nullptr && *order == std::vector<Uuid>{a});
}

// ---- Deletion, rename, duplicate, reparent ------------------------------------

static void testDeletingABoneOrphansItsChildrenAndDropsWhatNamedIt() {
    EditorScene scene;
    const Uuid root = scene.addBone(Vec2(0, 0), Vec2(100, 0));
    const Uuid mid = scene.addBone(Vec2(100, 0), Vec2(200, 0), root);
    const Uuid tip = scene.addBone(Vec2(200, 0), Vec2(300, 0), mid);
    const Uuid art = addSprite(scene, "art");
    scene.bindImage(art, mid);
    scene.skeleton.ikConstraints.push_back(IKConstraint("ik", {mid}, tip));
    scene.setBoneSelection({mid, tip}, mid, false);

    scene.deleteHierarchy(mid);
    UM_CHECK(scene.skeleton.bone(mid) == nullptr);
    const Bone* orphan = scene.skeleton.bone(tip);
    UM_CHECK(orphan != nullptr && !orphan->parentID.has_value());
    UM_CHECK(std::find(scene.skeleton.rootIDs.begin(), scene.skeleton.rootIDs.end(), tip) !=
             scene.skeleton.rootIDs.end());
    UM_CHECK(scene.skeleton.ikConstraints.empty());
    UM_CHECK(!scene.image(art)->boneBinding.has_value());
    UM_CHECK(scene.boneSelectionOrder == std::vector<Uuid>{tip});
    UM_CHECK(scene.selectedBoneID == tip);
}

static void testRenameResolvesCollisionsByIdentity() {
    EditorScene scene;
    const Uuid one = scene.addBone(Vec2(0, 0), Vec2(10, 0));
    const Uuid two = scene.addBone(Vec2(0, 0), Vec2(10, 0));
    scene.renameHierarchyItem(one, "Arm");
    // Renaming the other row to "arm" collides, case-insensitively.
    UM_CHECK(scene.renameHierarchyItem(two, "arm"));
    UM_CHECK(scene.skeleton.bone(two)->name == "arm 2");
    // The row and the bone move together.
    const auto row = std::find_if(scene.hierarchyItems.begin(), scene.hierarchyItems.end(),
                                  [&](const HierarchyItem& h) { return h.id == two; });
    UM_CHECK(row != scene.hierarchyItems.end() && row->name == "arm 2");
    // Re-committing the same name is not a rename, and pushes no undo:
    // `commitEditing` runs on every blur. (`addImage` pushes no undo, as in
    // Swift, so this scene's stack starts empty.)
    EditorScene fresh;
    const Uuid sprite = addSprite(fresh, "Arm");
    UM_CHECK(!fresh.undoRedo.canUndo());
    UM_CHECK(!fresh.renameHierarchyItem(sprite, "  Arm  "));
    UM_CHECK(!fresh.renameHierarchyItem(sprite, "   "));
    UM_CHECK(!fresh.undoRedo.canUndo());
    (void)one;
}

static void testDuplicateOffsetsRenamesAndRetargets() {
    EditorScene scene;
    const Uuid a = addSprite(scene, "A");
    scene.image(a)->animationClip.upsertKeyframe(a, AnimationTrackProperty::Rotate, 3, RotateValue{1.0f});
    scene.duplicateItem(a);
    const Uuid copy = *scene.selectedImageID;
    UM_CHECK(copy != a);
    const SceneImage* dup = scene.image(copy);
    UM_CHECK(dup->name == "A Copy");
    UM_CHECK(dup->position == scene.image(a)->position + Vec2(12, -12));
    UM_CHECK(dup->mesh.id != scene.image(a)->mesh.id);
    // The copy's keys point at the copy, not the original.
    UM_CHECK(dup->animationClip.hasTrack(copy, AnimationTrackProperty::Rotate));
    UM_CHECK(!dup->animationClip.hasTrack(a, AnimationTrackProperty::Rotate));
}

static void testReparentKeepsTheBoneWhereItIsOnScreen() {
    EditorScene scene;
    const Uuid a = scene.addBone(Vec2(0, 0), Vec2(100, 0));
    const Uuid b = scene.addBone(Vec2(50, 80), Vec2(120, 150));
    const auto before = *scene.skeleton.lineSegment(b);
    scene.reparentBone(b, a);
    const auto after = *scene.skeleton.lineSegment(b);
    UM_CHECK_NEAR(after.start.x, before.start.x, 1e-3);
    UM_CHECK_NEAR(after.start.y, before.start.y, 1e-3);
    UM_CHECK_NEAR(after.end.x, before.end.x, 1e-3);
    UM_CHECK_NEAR(after.end.y, before.end.y, 1e-3);
    UM_CHECK(scene.skeleton.bone(b)->parentID == a);
    UM_CHECK(std::find(scene.skeleton.rootIDs.begin(), scene.skeleton.rootIDs.end(), b) ==
             scene.skeleton.rootIDs.end());
    // A bone cannot be parented under its own descendant.
    scene.reparentBone(a, b);
    UM_CHECK(!scene.skeleton.bone(a)->parentID.has_value());
}

// ---- Skins --------------------------------------------------------------------

static void testTheActiveSkinDecidesWhichVariantShows() {
    EditorScene scene;
    const Uuid red = addSprite(scene, "red");
    const Uuid blue = addSprite(scene, "blue");
    scene.assignSlot("hat", {red, blue});
    const Uuid skin = scene.createSkin(std::string("Blue"), true);
    UM_CHECK(scene.activeSkinID == skin);
    scene.setSkinAttachment(skin, "hat", blue);
    UM_CHECK(!scene.isHiddenByActiveSkin(blue) && scene.isHiddenByActiveSkin(red));
    UM_CHECK(scene.shownAttachment("hat") == blue);
    // An EMPTIED slot is a real choice: everything in it hides.
    scene.setSkinAttachment(skin, "hat", std::nullopt);
    UM_CHECK(scene.isHiddenByActiveSkin(red) && scene.isHiddenByActiveSkin(blue));
    // Clearing the entry falls back to the setup arrangement.
    scene.clearSkinAttachment(skin, "hat");
    UM_CHECK(scene.isHiddenByActiveSkin(red) != scene.isHiddenByActiveSkin(blue));
}

static void testInclusionRefusesACycleAndDeletionForgetsIt() {
    EditorScene scene;
    const Uuid base = scene.createSkin(std::string("Base"), false);
    const Uuid armor = scene.createSkin(std::string("Armor"), false);
    UM_CHECK(scene.addSkinInclusion(armor, base));
    UM_CHECK(!scene.addSkinInclusion(base, armor)); // would be a cycle
    UM_CHECK(!scene.addSkinInclusion(armor, armor));
    UM_CHECK(!scene.addSkinInclusion(armor, base)); // already included
    scene.deleteSkin(base);
    UM_CHECK(scene.skins.size() == 1 && scene.skins[0].includedSkinIDs.empty());
    // Names stay unique.
    const Uuid again = scene.createSkin(std::string("Armor"), false);
    for (const Skin& s : scene.skins) {
        if (s.id == again) UM_CHECK(s.name == "Armor 2");
    }
}

static void testShowAttachmentKeysInAnimatorAndEditsTheSkinInEditor() {
    EditorScene scene;
    const Uuid red = addSprite(scene, "red");
    const Uuid blue = addSprite(scene, "blue");
    scene.assignSlot("hat", {red, blue});
    const Uuid skin = scene.createSkin(std::string("S"), true);

    scene.showAttachment("hat", blue); // Editor: edits the skin
    UM_CHECK(scene.skins[0].attachment("hat") == std::optional<std::optional<Uuid>>(blue));
    UM_CHECK(!scene.sceneAnimationClip.hasTrack(SlotAnimationTarget::id("hat"), AnimationTrackProperty::Attachment));

    scene.setAnimationEditingEnabled(true);
    scene.showAttachment("hat", red); // Animator: keys the timeline
    UM_CHECK(scene.attachmentHasKeyAtPlayhead("hat"));
    UM_CHECK(scene.skins[0].attachment("hat") == std::optional<std::optional<Uuid>>(blue));
    (void)skin;
}

static void testDeletingASpriteEmptiesTheSkinSlotsThatShowedIt() {
    EditorScene scene;
    const Uuid red = addSprite(scene, "red");
    const Uuid blue = addSprite(scene, "blue");
    scene.assignSlot("hat", {red, blue});
    const Uuid skin = scene.createSkin(std::string("S"), true);
    scene.setSkinAttachment(skin, "hat", blue);
    scene.deleteHierarchy(blue);
    // The entry stays (the skin still has an opinion about the slot) but it
    // no longer points at a sprite that does not exist.
    const auto entry = scene.skins[0].attachment("hat");
    UM_CHECK(entry.has_value() && !entry->has_value());
}

static void testRenameSlotCarriesAnEmptyChoiceAcross() {
    EditorScene scene;
    const Uuid red = addSprite(scene, "red");
    const Uuid blue = addSprite(scene, "blue");
    scene.assignSlot("hat", {red, blue});
    const Uuid skin = scene.createSkin(std::string("S"), true);
    scene.setSkinAttachment(skin, "hat", std::nullopt);
    scene.renameSlot("hat", "cap");
    UM_CHECK(!scene.skins[0].attachment("hat").has_value());
    const auto moved = scene.skins[0].attachment("cap");
    UM_CHECK(moved.has_value() && !moved->has_value());
    UM_CHECK(scene.variantSlotNames() == std::vector<std::string>{"cap"});
}

// ---- Utilities ------------------------------------------------------------------

static void testNaturalCompareIsTheFindersOrder() {
    UM_CHECK(naturalLess("Bone 2", "Bone 10"));
    UM_CHECK(!naturalLess("Bone 10", "Bone 2"));
    UM_CHECK(naturalCompare("arm", "Arm") == 0);
    UM_CHECK(naturalLess("arm", "Bone"));
    UM_CHECK(naturalCompare("x07", "x7") == 0);
    UM_CHECK(naturalLess("Bone", "Bone 1"));
}

static void testTheIKBuilderFillsTheChainAndSaysWhatIsWrong() {
    EditorScene scene;
    const Uuid shoulder = scene.addBone(Vec2(0, 0), Vec2(100, 0));
    const Uuid elbow = scene.addBone(Vec2(100, 0), Vec2(200, 0), shoulder);
    const Uuid hand = scene.addBone(Vec2(200, 0), Vec2(260, 0), elbow);
    const Uuid handle = scene.addBone(Vec2(300, 50), Vec2(320, 50));
    const Skeleton& s = scene.skeleton;

    // Shoulder then hand fills in the elbow.
    std::vector<Uuid> chain = IKBuilderRules::addToChain(shoulder, {}, s);
    chain = IKBuilderRules::addToChain(hand, chain, s);
    UM_CHECK(chain == (std::vector<Uuid>{shoulder, elbow, hand}));
    // Clicking an interior bone takes the tail with it.
    UM_CHECK(IKBuilderRules::addToChain(elbow, chain, s) == std::vector<Uuid>{shoulder});

    IKBuilderDraft draft;
    draft.chain = {shoulder, elbow};
    UM_CHECK(!IKBuilderRules::validate(draft, s).canCreate()); // no target
    draft.targetID = hand; // a child of the chain's tip
    UM_CHECK(!IKBuilderRules::validate(draft, s).canCreate());
    draft.targetID = handle;
    const IKBuilderValidation ok = IKBuilderRules::validate(draft, s);
    UM_CHECK(ok.canCreate() && ok.advisory().empty());
    draft.chain = {shoulder, elbow, hand};
    UM_CHECK(IKBuilderRules::validate(draft, s).advisory().size() == 1); // FABRIK note

    // Depth order: roots first, children under them.
    const auto ordered = IKBuilderRules::hierarchicalOrder(s);
    UM_CHECK(ordered.size() == 4);
    for (const auto& entry : ordered) {
        if (entry.bone.id == hand) UM_CHECK(entry.depth == 2);
        if (entry.bone.id == handle) UM_CHECK(entry.depth == 0);
    }
}

UM_TEST_MAIN_BEGIN()
    testAddImageGoesToTheFrontAndIsSelected();
    testABoneGetsARowSoItsSubtreeIsListed();
    testAMovedSpriteLandsOnTheRowItWasDroppedOn();
    testTheResolvedOrderDropsTheDeadAndAppendsTheNew();
    testTheRenderOrderHonoursAKeyAndHidesWhatTheSkinHides();
    testSortByBoneDepthPutsTheDeeperBoneInFront();
    testUndoKeepsAttachmentKeys();
    testPruneDropsDeadConstraintTracksAndRewritesDrawOrderKeys();
    testDeletingABoneOrphansItsChildrenAndDropsWhatNamedIt();
    testRenameResolvesCollisionsByIdentity();
    testDuplicateOffsetsRenamesAndRetargets();
    testReparentKeepsTheBoneWhereItIsOnScreen();
    testTheActiveSkinDecidesWhichVariantShows();
    testInclusionRefusesACycleAndDeletionForgetsIt();
    testShowAttachmentKeysInAnimatorAndEditsTheSkinInEditor();
    testDeletingASpriteEmptiesTheSkinSlotsThatShowedIt();
    testRenameSlotCarriesAnEmptyChoiceAcross();
    testNaturalCompareIsTheFindersOrder();
    testTheIKBuilderFillsTheChainAndSaysWhatIsWrong();
UM_TEST_MAIN_END()
