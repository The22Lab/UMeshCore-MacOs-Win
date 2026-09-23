// Tests for EditorScene's mirroring (Phase 6a, the rest of A1): partner
// lookup by name, pose mirror/flip, and mesh weight mirroring.
//
// Two tests pin Swift defects the port fixes (convention #3): the pose
// buttons did nothing outside Pose mode, and a name containing a
// marker-like word ("_lower") never found its partner.

#include "umeshcore/Editor/EditorScene.h"

#include "TestHarness.h"

using namespace umeshcore;

namespace {

Uuid namedBone(EditorScene& scene, const std::string& name, Vec2 start, Vec2 end) {
    const Uuid id = scene.addBone(start, end);
    Bone b = *scene.skeleton.bone(id);
    b.name = name;
    scene.skeleton.setBone(b);
    return id;
}

} // namespace

static void testTheNameConventionsPairUp() {
    UM_CHECK(EditorScene::mirroredBoneName("arm_L") == std::optional<std::string>("arm_R"));
    UM_CHECK(EditorScene::mirroredBoneName("hand.r") == std::optional<std::string>("hand.l"));
    UM_CHECK(EditorScene::mirroredBoneName("Left Leg") == std::optional<std::string>("Right Leg"));
    UM_CHECK(!EditorScene::mirroredBoneName("spine").has_value());
    // Swift's string rule, kept: the FIRST marker wins, "_l" of "_lower".
    UM_CHECK(EditorScene::mirroredBoneName("arm_lower_L") == std::optional<std::string>("arm_rower_L"));
}

// SWIFT BUG, FIXED: `arm_lower_L` looked for `arm_rower_L` and gave up.
static void testAMarkerLikeWordDoesNotHideThePartner() {
    EditorScene scene;
    const Uuid l = namedBone(scene, "arm_lower_L", Vec2(0, 0), Vec2(40, 0));
    const Uuid r = namedBone(scene, "arm_lower_R", Vec2(0, 0), Vec2(-40, 0));
    const Uuid spine = namedBone(scene, "spine", Vec2(0, 0), Vec2(0, 50));
    UM_CHECK(scene.mirroredBone(l) == std::optional<Uuid>(r));
    UM_CHECK(scene.mirroredBone(r) == std::optional<Uuid>(l));
    UM_CHECK(!scene.mirroredBone(spine).has_value()); // on the axis: itself, i.e. none

    // The documented `L_arm` convention, which Swift's table lacked.
    const Uuid pl = namedBone(scene, "L_thigh", Vec2(0, 0), Vec2(10, 0));
    const Uuid pr = namedBone(scene, "R_thigh", Vec2(0, 0), Vec2(-10, 0));
    UM_CHECK(scene.mirroredBone(pl) == std::optional<Uuid>(pr));
}

// SWIFT BUG, FIXED: in Editor mode the setup pass put the bone straight
// back on its base pose, so Flip did nothing.
static void testFlipSticksInEditorMode() {
    EditorScene scene;
    const Uuid bone = scene.addBone(Vec2(30, 10), Vec2(30, 60)); // rotation +90 degrees
    const float before = scene.skeleton.bone(bone)->localTransform.rotation.z;
    UM_CHECK_NEAR(before, 1.5707963, 1e-5);
    scene.flipBonePose(bone);
    const Bone& flipped = *scene.skeleton.bone(bone);
    UM_CHECK_NEAR(flipped.localTransform.rotation.z, -before, 1e-6);
    UM_CHECK_NEAR(flipped.localTransform.position.x, -30.0, 1e-4);
    UM_CHECK_NEAR(flipped.localTransform.position.y, 10.0, 1e-4); // Y is not reflected
    UM_CHECK(flipped.baseTransform.rotation.z == flipped.localTransform.rotation.z);
    // And it survives another pass of the animator.
    scene.applyAnimationsNow();
    UM_CHECK_NEAR(scene.skeleton.bone(bone)->localTransform.rotation.z, -before, 1e-6);
    // One undo step brings it back.
    scene.undo();
    UM_CHECK_NEAR(scene.skeleton.bone(bone)->localTransform.rotation.z, before, 1e-6);
}

// In Animator the mirrored channels are keyed on the partner, like any edit.
static void testMirrorInAnimatorKeysThePartner() {
    EditorScene scene;
    const Uuid l = namedBone(scene, "arm_L", Vec2(20, 0), Vec2(20, 40));
    const Uuid r = namedBone(scene, "arm_R", Vec2(-20, 0), Vec2(-20, 40));
    scene.setAnimationEditingEnabled(true);
    scene.setCurrentFrame(6);
    UM_CHECK(scene.mirrorBonePose({l}) == 1);
    for (AnimationTrackProperty p : {AnimationTrackProperty::Translate, AnimationTrackProperty::Rotate,
                                     AnimationTrackProperty::Scale, AnimationTrackProperty::Shear}) {
        const auto keys = scene.keyframes(r, p);
        UM_CHECK(keys.size() == 1 && keys[0].frame == 6);
    }
    const Bone& partner = *scene.skeleton.bone(r);
    UM_CHECK_NEAR(partner.localTransform.position.x, -20.0, 1e-4);
    UM_CHECK_NEAR(partner.localTransform.rotation.z, -1.5707963, 1e-5);
    // The source is untouched, and a bone with no partner writes nothing.
    UM_CHECK(scene.keyframes(l, AnimationTrackProperty::Rotate).empty());
    const Uuid spine = namedBone(scene, "spine", Vec2(0, 0), Vec2(0, 30));
    UM_CHECK(scene.mirrorBonePose({spine}) == 0);
}

static void testWeightsMirrorAcrossTheAxisWithPartnersSwapped() {
    EditorScene scene;
    const Uuid l = namedBone(scene, "arm_L", Vec2(0, 0), Vec2(10, 0));
    const Uuid r = namedBone(scene, "arm_R", Vec2(0, 0), Vec2(-10, 0));
    const Uuid spine = namedBone(scene, "spine", Vec2(0, 0), Vec2(0, 10));
    const Uuid sprite = scene.addImage(Uuid::generate(), "body", Vec2(20, 20), Vec2(0, 0), std::nullopt);
    Mesh& mesh = scene.image(sprite)->mesh;
    // A symmetric square about x = 0, plus one vertex with no mirror.
    mesh.vertices = {Vec2(-10, 0), Vec2(10, 0), Vec2(-10, 10), Vec2(10, 10), Vec2(3, 5)};
    mesh.vertexBoneWeights = {
        {{l, 1.0f}}, {{spine, 1.0f}}, {{l, 1.0f}}, {{spine, 1.0f}}, {{spine, 1.0f}},
    };
    // Sanitizing keeps only influences of BOUND bones, so all three are.
    for (Uuid b : {l, r, spine}) mesh.boneInverseBindMatrices[b] = Mat4::identity();
    // Axis: the centre of x in [-10, 10] -- zero.
    const int mirrored = scene.mirrorMeshWeights(sprite, std::nullopt, 1.5f);
    UM_CHECK(mirrored == 4);
    const auto& w = scene.image(sprite)->mesh.vertexBoneWeights;
    UM_CHECK(w[0].size() == 1 && w[0][0].boneID == spine); // took (10,0)'s spine
    UM_CHECK(w[1].size() == 1 && w[1][0].boneID == r);     // took (-10,0)'s arm_L, as arm_R
    UM_CHECK(w[4].size() == 1 && w[4][0].boneID == spine); // (-3,5) is no vertex: untouched
}

UM_TEST_MAIN_BEGIN()
    testTheNameConventionsPairUp();
    testAMarkerLikeWordDoesNotHideThePartner();
    testFlipSticksInEditorMode();
    testMirrorInAnimatorKeysThePartner();
    testWeightsMirrorAcrossTheAxisWithPartnersSwapped();
UM_TEST_MAIN_END()
