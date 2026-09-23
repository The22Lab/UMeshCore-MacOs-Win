// Tests for EditorScene's constraint half, absorbed from SceneManager in
// Phase 6a: the IK builder's live draft, create/duplicate/delete/reorder
// for the four constraint kinds, and the auto-key / setup-record rules the
// inspector depends on.

#include "umeshcore/Editor/EditorScene.h"

#include <algorithm>

#include "TestHarness.h"

using namespace umeshcore;

namespace {

struct Arm {
    EditorScene scene;
    Uuid shoulder, elbow, hand, handle;
};

Arm makeArm() {
    Arm a;
    a.shoulder = a.scene.addBone(Vec2(0, 0), Vec2(100, 0));
    a.elbow = a.scene.addBone(Vec2(100, 0), Vec2(200, 0), a.shoulder);
    a.hand = a.scene.addBone(Vec2(200, 0), Vec2(260, 0), a.elbow);
    a.handle = a.scene.addBone(Vec2(300, 60), Vec2(320, 60));
    return a;
}

std::vector<Uuid> ikIDs(const EditorScene& s) {
    std::vector<Uuid> out;
    for (const auto& c : s.skeleton.ikConstraints) out.push_back(c.id());
    return out;
}

} // namespace

static void testTheBuilderSeedsOnlyAContiguousSelection() {
    Arm a = makeArm();
    // Selected in a scrambled click order: the chain order still comes out
    // root to tip, and it is contiguous, so it seeds the chain.
    a.scene.setBoneSelection({a.hand, a.shoulder, a.elbow}, std::nullopt, false);
    a.scene.beginIKBuilder();
    UM_CHECK(a.scene.ikBuilder.has_value());
    UM_CHECK(a.scene.ikBuilder->chain == (std::vector<Uuid>{a.shoulder, a.elbow, a.hand}));
    UM_CHECK(a.scene.ikBuilder->pickingSlot == IKBuilderSlot::Target);
    UM_CHECK(a.scene.ikBuilder->name == "IK 1");

    // A scattered selection seeds only its root, so the panel does not open
    // already invalid.
    a.scene.setBoneSelection({a.shoulder, a.hand}, std::nullopt, false);
    a.scene.beginIKBuilder();
    UM_CHECK(a.scene.ikBuilder->chain == std::vector<Uuid>{a.shoulder});

    // Nothing selected: picking starts on the chain slot.
    a.scene.selectBone(std::nullopt);
    a.scene.beginIKBuilder();
    UM_CHECK(a.scene.ikBuilder->chain.empty());
    UM_CHECK(a.scene.ikBuilder->pickingSlot == IKBuilderSlot::Chain);
}

static void testTheBuilderCommitsOnlyAValidDraft() {
    Arm a = makeArm();
    // `addBone` selects the bone it made; start the builder from nothing.
    a.scene.selectBone(std::nullopt);
    a.scene.beginIKBuilder();
    UM_CHECK(a.scene.ikBuilderHandleBonePick(a.shoulder));
    UM_CHECK(a.scene.ikBuilderHandleBonePick(a.hand)); // fills in the elbow
    UM_CHECK(a.scene.ikBuilder->chain.size() == 3);
    UM_CHECK(!a.scene.commitIKBuilder().has_value()); // no target yet
    UM_CHECK(a.scene.skeleton.ikConstraints.empty());

    a.scene.ikBuilderSetPicking(IKBuilderSlot::Target);
    a.scene.ikBuilderHandleBonePick(a.handle);
    a.scene.ikBuilderSetMix(1.7f); // clamped
    UM_CHECK(a.scene.ikBuilder->mix == 1.0f);
    a.scene.ikBuilderSetName("  Arm IK  ");
    const auto id = a.scene.commitIKBuilder();
    UM_CHECK(id.has_value());
    UM_CHECK(!a.scene.ikBuilder.has_value());
    UM_CHECK(a.scene.selectedConstraintID == id);
    const IKConstraint& c = a.scene.skeleton.ikConstraints[0];
    UM_CHECK(c.name() == "Arm IK" && c.targetBoneID == a.handle && c.order() == 0);

    // Setting the target to a chain bone pulls it out of the chain.
    a.scene.beginIKBuilder();
    a.scene.ikBuilderSetChain({a.shoulder, a.elbow});
    a.scene.ikBuilderSetTarget(a.elbow);
    UM_CHECK(a.scene.ikBuilder->chain == std::vector<Uuid>{a.shoulder});
}

static void testCreateFromSelectionFollowsEachKindsConvention() {
    Arm a = makeArm();
    a.scene.setBoneSelection({a.shoulder, a.elbow}, std::nullopt, false);
    const auto t1 = a.scene.createTransformConstraintFromSelection();
    UM_CHECK(t1.has_value() && a.scene.selectedConstraintID == t1);
    const TransformConstraint& tc = a.scene.skeleton.transformConstraints[0];
    // The deepest selected bone is the target; the rest are affected.
    UM_CHECK(tc.targetBoneID == a.elbow && tc.affectedBones == std::vector<Uuid>{a.shoulder});
    UM_CHECK(tc.order() == 50 && tc.name() == "Transform 1");
    a.scene.createTransformConstraintFromSelection();
    UM_CHECK(a.scene.skeleton.transformConstraints[1].order() == 51);

    // Path needs three bones: two control points and a follower.
    UM_CHECK(!a.scene.createPathConstraintFromSelection().has_value());
    a.scene.setBoneSelection({a.shoulder, a.elbow, a.hand}, std::nullopt, false);
    const auto p = a.scene.createPathConstraintFromSelection();
    UM_CHECK(p.has_value());
    const PathConstraint& pc = a.scene.skeleton.pathConstraints[0];
    UM_CHECK(pc.pathBones == (std::vector<Uuid>{a.shoulder, a.elbow}) && pc.bones == std::vector<Uuid>{a.hand});
    UM_CHECK(pc.order() == 52); // after every existing constraint

    // Physics lands at 100 or later, named from the preset.
    const auto ph = a.scene.createPhysicsConstraintFromSelection(PhysicsType::Spring, PhysicsPreset::Hair);
    UM_CHECK(ph.has_value());
    const PhysicsConstraint& pk = a.scene.skeleton.physicsConstraints[0];
    UM_CHECK(pk.name() == "Hair 1" && pk.order() == 100);
    UM_CHECK(pk.settings.mass == 0.5f && pk.affectedBones.size() == 3);
}

static void testDuplicationAndReorderingNumberAsSwiftDoes() {
    Arm a = makeArm();
    a.scene.skeleton.ikConstraints.push_back(IKConstraint("A", {a.shoulder}, a.handle));
    a.scene.skeleton.ikConstraints.push_back(IKConstraint("B", {a.elbow}, a.handle));
    const Uuid A = a.scene.skeleton.ikConstraints[0].id(), B = a.scene.skeleton.ikConstraints[1].id();
    const auto copy = a.scene.duplicateIKConstraint(A);
    UM_CHECK(copy.has_value());
    // Right after its source, and IK is renumbered by list position.
    UM_CHECK(ikIDs(a.scene) == (std::vector<Uuid>{A, *copy, B}));
    UM_CHECK(a.scene.skeleton.ikConstraints[1].name() == "A Copy");
    for (int i = 0; i < 3; ++i) UM_CHECK(a.scene.skeleton.ikConstraints[static_cast<std::size_t>(i)].order() == i);

    // Swift's move(fromOffsets:toOffset:): the destination is measured in
    // the ORIGINAL array. [A, copy, B], move {0} to 2 -> [copy, A, B].
    a.scene.moveIKConstraint({0}, 2);
    UM_CHECK(ikIDs(a.scene) == (std::vector<Uuid>{*copy, A, B}));
    a.scene.moveIKConstraint({2}, 0);
    UM_CHECK(ikIDs(a.scene) == (std::vector<Uuid>{B, *copy, A}));
    UM_CHECK(a.scene.skeleton.ikConstraints[0].order() == 0);

    // Transform duplicates are NOT renumbered, just order + 1.
    a.scene.skeleton.transformConstraints.push_back(TransformConstraint("T", a.hand, {a.elbow}));
    const Uuid T = a.scene.skeleton.transformConstraints[0].id();
    a.scene.duplicateTransformConstraint(T);
    UM_CHECK(a.scene.skeleton.transformConstraints[1].order() == 51);
}

static void testRetargetingNeverLetsABoneDriveItself() {
    Arm a = makeArm();
    a.scene.skeleton.ikConstraints.push_back(IKConstraint("IK", {a.shoulder, a.elbow}, a.handle));
    const Uuid ik = a.scene.skeleton.ikConstraints[0].id();
    a.scene.setIKTarget(ik, a.elbow);
    UM_CHECK(a.scene.skeleton.ikConstraints[0].boneChain == std::vector<Uuid>{a.shoulder});
    a.scene.addBoneToIKChain(a.elbow, ik); // it is the target now: refused
    UM_CHECK(a.scene.skeleton.ikConstraints[0].boneChain.size() == 1);

    a.scene.skeleton.transformConstraints.push_back(TransformConstraint("T", a.hand, {a.shoulder, a.elbow}));
    const Uuid t = a.scene.skeleton.transformConstraints[0].id();
    a.scene.setTransformConstraintTarget(t, a.elbow);
    UM_CHECK(a.scene.skeleton.transformConstraints[0].affectedBones == std::vector<Uuid>{a.shoulder});
}

// Also pins a Swift bug the port fixes: Swift captured the setup record
// AFTER writing the animated value, losing the authored one.
static void testAnEditAutoKeysInAnimatorAndKeepsTheSetupValue() {
    Arm a = makeArm();
    a.scene.skeleton.ikConstraints.push_back(IKConstraint("IK", {a.shoulder, a.elbow}, a.handle));
    const Uuid ik = a.scene.skeleton.ikConstraints[0].id();
    const auto mix = AnimationTrackProperty::ConstraintMix;

    // Animator: the edit keys the playhead and records the authored value
    // (1.0) the first time, before it is overwritten.
    a.scene.setAnimationEditingEnabled(true);
    a.scene.currentFrame = 10;
    a.scene.setConstraintScalar(ik, mix, 0.25f, true);
    UM_CHECK(a.scene.constraintPropertyHasKeyAtPlayhead(ik, mix));
    UM_CHECK(a.scene.constraintSetupValues.at(ik).scalar(mix) == std::optional<float>(1.0f));

    // Removing the last key puts the authored value back.
    a.scene.removeConstraintKeyAtPlayhead(ik, mix);
    UM_CHECK(!a.scene.isConstraintPropertyAnimated(ik, mix));
    UM_CHECK_NEAR(a.scene.constraintScalarValue(ik, mix), 1.0, 1e-6);

    // Editor, with the property animated: the edit rewrites the SETUP
    // record, so returning to Animator does not resurrect the old value.
    a.scene.setConstraintScalar(ik, mix, 0.5f, true);
    a.scene.setAnimationEditingEnabled(false);
    a.scene.setConstraintScalar(ik, mix, 0.75f, true);
    UM_CHECK(a.scene.constraintSetupValues.at(ik).scalar(mix) == std::optional<float>(0.75f));
}

static void testDeletingAConstraintTakesItsTimelinesAndSetupWithIt() {
    Arm a = makeArm();
    a.scene.skeleton.ikConstraints.push_back(IKConstraint("IK", {a.shoulder}, a.handle));
    const Uuid ik = a.scene.skeleton.ikConstraints[0].id();
    a.scene.setAnimationEditingEnabled(true);
    a.scene.setConstraintScalar(ik, AnimationTrackProperty::ConstraintMix, 0.3f, true);
    a.scene.selectedConstraintID = ik;
    a.scene.deleteConstraint(ik);
    UM_CHECK(a.scene.skeleton.ikConstraints.empty());
    UM_CHECK(!a.scene.selectedConstraintID.has_value());
    UM_CHECK(!a.scene.constraintSetupValues.contains(ik));
    UM_CHECK(!a.scene.sceneAnimationClip.hasTrack(ik, AnimationTrackProperty::ConstraintMix));
}

static void testEnablingAndThePhysicsPreview() {
    Arm a = makeArm();
    a.scene.skeleton.pathConstraints.push_back(PathConstraint("P", {a.shoulder, a.elbow}, {a.hand}));
    const Uuid p = a.scene.skeleton.pathConstraints[0].id();
    a.scene.setConstraintEnabled(p, false);
    UM_CHECK(!a.scene.skeleton.pathConstraints[0].enabled());

    a.scene.setPhysicsPreviewActive(true);
    UM_CHECK(a.scene.isPhysicsPreviewActive());
    a.scene.setPhysicsPreviewActive(false);
    UM_CHECK(!a.scene.isPhysicsPreviewActive());

    // The Swift stub bakes nothing; neither does the port.
    const AnimationClip before = a.scene.sceneAnimationClip;
    a.scene.bakePhysicsToKeys();
    UM_CHECK(a.scene.sceneAnimationClip == before);

    // Candidates exclude what the constraint already drives.
    const auto candidates = a.scene.targetCandidates({a.shoulder, a.elbow});
    UM_CHECK(candidates.size() == 2);
}

UM_TEST_MAIN_BEGIN()
    testTheBuilderSeedsOnlyAContiguousSelection();
    testTheBuilderCommitsOnlyAValidDraft();
    testCreateFromSelectionFollowsEachKindsConvention();
    testDuplicationAndReorderingNumberAsSwiftDoes();
    testRetargetingNeverLetsABoneDriveItself();
    testAnEditAutoKeysInAnimatorAndKeepsTheSetupValue();
    testDeletingAConstraintTakesItsTimelinesAndSetupWithIt();
    testEnablingAndThePhysicsPreview();
UM_TEST_MAIN_END()
