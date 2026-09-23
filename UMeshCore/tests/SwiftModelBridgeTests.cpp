// Tests for Interop/SwiftModelBridge.h and Interop/EditorSession.h -- the
// shapes the Mac's `Bridge/` copies the model through.
//
// Every function under test is a copy between two shapes of the same data,
// so the property is the round trip: out and back is the identity. The
// tests that go beyond a single round trip are the ones a copy can get
// wrong while each value still survives on its own:
//
//   - an optional that is EMPTY must not come back as "present with the
//     default value" (an unparented bone is not parented to the nil id);
//   - a skin slot that deliberately shows nothing must not collapse into a
//     slot the skin does not mention;
//   - a list built from a hash map must not depend on the bucket layout, or
//     two equal models would compare unequal on the Swift side;
//   - an enum's cases must pair with Swift's by NAME: every Swift raw value
//     below is copied by hand from the Swift declaration, not from this
//     port's tables.

#include "umeshcore/Interop/EditorSession.h"
#include "umeshcore/Interop/SwiftModelBridge.h"
#include "umeshcore/Serialization/SavedAnimation.h"
#include "umeshcore/Serialization/SavedEditorState.h"
#include "umeshcore/Serialization/SavedSceneImage.h"
#include "umeshcore/Serialization/SavedSkeleton.h"

#include <set>
#include <string>
#include <vector>

#include "TestHarness.h"

using namespace umeshcore;

// Each Swift enum's raw values, in the Swift file's declaration order. The
// check is that the C++ cases, read through their name functions, are
// EXACTLY this set -- one each, nothing missing, nothing extra -- and that
// index and case survive the round trip.
template <typename E, typename NameFn, typename CaseFn, typename IndexFn>
static void checkEnumPairsByName(int count, CaseFn caseAt, IndexFn indexOf, NameFn name,
                                 const std::vector<std::string>& swiftRawValues) {
    UM_CHECK(count == static_cast<int>(swiftRawValues.size()));
    std::set<std::string> seen;
    for (int i = 0; i < count; ++i) {
        const E value = caseAt(i);
        UM_CHECK(indexOf(value) == i);
        seen.insert(name(value));
    }
    UM_CHECK(seen == std::set<std::string>(swiftRawValues.begin(), swiftRawValues.end()));
}

static void testEveryEnumPairsWithSwiftByName() {
    // Data/Keyframe.swift:96-182.
    checkEnumPairsByName<AnimationTrackProperty>(
        trackPropertyCaseCount(), trackPropertyCase, trackPropertyCaseIndex, trackPropertyName,
        {"translate", "rotate", "scale", "shear", "meshDeform", "constraintMix", "ikSoftness",
         "ikBendPositive", "ikStretch", "ikCompress", "transformRotateMix", "transformTranslateMix",
         "transformScaleMix", "transformShearMix", "pathPosition", "pathSpacing", "pathPositionMix",
         "pathRotateMix", "physicsMass", "physicsDamping", "physicsStiffness", "physicsGravity",
         "physicsDrag", "physicsWind", "cameraTranslate", "cameraTranslateZ", "cameraRotate3D",
         "cameraRoll", "cameraFOV", "lightTranslate", "lightTranslateZ", "lightIntensity",
         "lightRadius", "lightSoftness", "lightDirection", "lightAngles", "lightColorR",
         "lightColorG", "lightColorB", "drawOrder", "attachment", "event"});
    // Data/Keyframe.swift:4-7.
    checkEnumPairsByName<KeyframeInterpolation>(interpolationCaseCount(), interpolationCase,
                                                interpolationCaseIndex, interpolationName,
                                                {"hold", "linear", "bezier"});
    // Data/SceneImage.swift:40-44.
    checkEnumPairsByName<ImageBlendMode>(blendModeCaseCount(), blendModeCase, blendModeCaseIndex, blendModeName,
                                         {"normal", "additive", "multiply", "screen"});
    // HierarchyModels.swift:4-8.
    checkEnumPairsByName<HierarchyItem::ItemType>(hierarchyItemTypeCaseCount(), hierarchyItemTypeCase,
                                                  hierarchyItemTypeCaseIndex, hierarchyItemTypeName,
                                                  {"image", "bone", "mesh"});
    // Data/PathConstraint.swift:30-35.
    checkEnumPairsByName<PathSpacingMode>(pathSpacingModeCaseCount(), pathSpacingModeCase,
                                          pathSpacingModeCaseIndex, pathSpacingModeName,
                                          {"length", "percent", "proportional", "fixed"});
    // Data/PathConstraint.swift:11-19.
    checkEnumPairsByName<PathRotateMode>(pathRotateModeCaseCount(), pathRotateModeCase,
                                         pathRotateModeCaseIndex, pathRotateModeName,
                                         {"tangent", "chain", "chainScale"});
    // Data/PhysicsConstraint.swift:6-11.
    checkEnumPairsByName<PhysicsType>(physicsTypeCaseCount(), physicsTypeCase, physicsTypeCaseIndex,
                                      physicsTypeName, {"spring", "jiggle", "rope", "pendulum", "cloth"});

    // Out of range reads as the first case rather than as garbage.
    UM_CHECK(interpolationCase(-1) == KeyframeInterpolation::Hold);
    UM_CHECK(interpolationCase(99) == KeyframeInterpolation::Hold);
}

static void testAnEmptyOptionalIsNotTheDefaultValue() {
    // The nil id is a legal Uuid, zero a legal vector: "absent" must survive
    // as absent, not as "present and zero".
    UM_CHECK(!optionalHasUuid(makeOptionalUuid(false, Uuid(1, 2))));
    UM_CHECK(optionalHasUuid(makeOptionalUuid(true, Uuid())));
    UM_CHECK(optionalUuid(makeOptionalUuid(true, Uuid(1, 2))) == Uuid(1, 2));

    UM_CHECK(!optionalHasVec2(makeOptionalVec2(false, Vec2(1, 2))));
    UM_CHECK(optionalHasVec2(makeOptionalVec2(true, Vec2(0, 0))));
    UM_CHECK(optionalVec2(makeOptionalVec2(true, Vec2(3, -4))) == Vec2(3, -4));

    UM_CHECK(optionalVec4(makeOptionalVec4(true, Vec4(1, 2, 3, 4))) == Vec4(1, 2, 3, 4));
    UM_CHECK(!optionalHasVec4(makeOptionalVec4(false, Vec4(1, 2, 3, 4))));

    // An EMPTY deform is a value (a key with no vertices), not "no deform".
    UM_CHECK(optionalHasVec2List(makeOptionalVec2List(true, Vec2List{})));
    UM_CHECK(!optionalHasVec2List(makeOptionalVec2List(false, Vec2List{Vec2(1, 1)})));
    UM_CHECK(optionalVec2List(makeOptionalVec2List(true, Vec2List{Vec2(1, 1), Vec2(2, 2)})).size() == 2);

    BoneImageBinding binding;
    binding.boneID = Uuid(5, 6);
    binding.localRotation = 0.25f;
    UM_CHECK(optionalBoneImageBinding(makeOptionalBoneImageBinding(true, binding)) == binding);
    UM_CHECK(!optionalHasBoneImageBinding(makeOptionalBoneImageBinding(false, binding)));

    MeshBindPose pose;
    pose.rotation = 1.5f;
    pose.skew = Vec2(3, 0);
    UM_CHECK(optionalMeshBindPose(makeOptionalMeshBindPose(true, pose)) == pose);
    UM_CHECK(!optionalHasMeshBindPose(makeOptionalMeshBindPose(false, pose)));

    UM_CHECK(optionalHasInt(makeOptionalInt(true, 0)));
    UM_CHECK(optionalInt(makeOptionalInt(true, -3)) == -3);
    UM_CHECK(optionalHasFloat(makeOptionalFloat(true, 0.0f)));
    UM_CHECK(!optionalHasFloat(makeOptionalFloat(false, 1.0f)));
    UM_CHECK(optionalHasString(makeOptionalString(true, "")));
    UM_CHECK(optionalString(makeOptionalString(true, "step")) == "step");
    UM_CHECK(!optionalHasString(makeOptionalString(false, "step")));
}

static void testInverseBindsRoundTripAndAreSorted() {
    Mesh mesh("m");
    const Uuid a(9, 0), b(1, 0), c(5, 5);
    const Mat4 ma = Mat4::diagonal(Vec4(2, 2, 2, 1));
    const Mat4 mb = Mat4::identity();
    Mat4 mc = Mat4::identity();
    mc.columns[3] = Vec4(10, -4, 0, 1);
    mesh.boneInverseBindMatrices[a] = ma;
    mesh.boneInverseBindMatrices[b] = mb;
    mesh.boneInverseBindMatrices[c] = mc;

    const BoneInverseBindList list = meshInverseBinds(mesh);
    UM_CHECK(list.size() == 3);
    // Sorted by id, whatever the buckets say.
    UM_CHECK(list[0].boneID == b && list[1].boneID == c && list[2].boneID == a);
    UM_CHECK(list[1].matrix == mc);

    Mesh copy("copy");
    copy.boneInverseBindMatrices[Uuid(77, 77)] = Mat4::identity(); // replaced, not merged
    setMeshInverseBinds(copy, list);
    UM_CHECK(copy.boneInverseBindMatrices == mesh.boneInverseBindMatrices);

    // A bone listed twice keeps its last matrix.
    setMeshInverseBinds(copy, BoneInverseBindList{{a, ma}, {a, mc}});
    UM_CHECK(copy.boneInverseBindMatrices.size() == 1);
    UM_CHECK(copy.boneInverseBindMatrices.at(a) == mc);

    // Column i is the i-th column: the translation lives in column 3.
    UM_CHECK(mat4Column(mc, 3) == Vec4(10, -4, 0, 1));
    UM_CHECK(mat4Column(mc, 0) == Vec4(1, 0, 0, 0));
}

static void testAnEmptiedSlotIsNotAnUnmentionedSlot() {
    Skin skin("Winter");
    skin.setAttachment(Uuid(1, 1), "hand");
    skin.setAttachment(std::nullopt, "hat"); // deliberately shows nothing

    const SkinSlotEntryList entries = skinSlotEntries(skin);
    UM_CHECK(entries.size() == 2);
    UM_CHECK(entries[0].slot == "hand" && entries[0].hasImage && entries[0].imageID == Uuid(1, 1));
    UM_CHECK(entries[1].slot == "hat" && !entries[1].hasImage);

    Skin back("Winter");
    setSkinSlotEntries(back, entries);
    UM_CHECK(back.attachments == skin.attachments);
    // "hat" is present-and-empty; "shoe" is absent. Different answers.
    UM_CHECK(back.attachment("hat").has_value() && !back.attachment("hat")->has_value());
    UM_CHECK(!back.attachment("shoe").has_value());
}

static void testSkeletonBonesRoundTripWithTheirHierarchy() {
    Skeleton skeleton;
    Bone root = Bone::makeRoot("root", Vec2(0, 0), Vec2(10, 0));
    Bone child = Bone::make("child", Vec2(10, 0), Vec2(20, 0), root.id, std::nullopt);
    child.color = Vec4(0.5f, 0.25f, 1, 1);
    skeleton.setBone(root);
    skeleton.setBone(child);
    skeleton.rootIDs = {root.id};

    const BoneList bones = skeletonBones(skeleton);
    UM_CHECK(bones.size() == 2);
    UM_CHECK(bones[0].id < bones[1].id);

    Skeleton back;
    back.rootIDs = skeleton.rootIDs;
    setSkeletonBones(back, bones);
    UM_CHECK(back.bones() == skeleton.bones());
    // The children index is derived from the parent links; setting the table
    // has to rebuild it, or the rig would solve as if flat.
    UM_CHECK(back.childrenOf(root.id) == std::vector<Uuid>{child.id});
}

static void testClipTracksRoundTripAndReindex() {
    AnimationClip clip("walk", 24);
    AnimationTrack track(Uuid(3, 3), AnimationTrackProperty::Rotate);
    track.keyframes.push_back(Keyframe(0, RotateValue{0.0f}));
    track.keyframes.push_back(Keyframe(12, RotateValue{1.0f}));
    setClipTracks(clip, AnimationTrackList{track});

    const AnimationTrackList tracks = clipTracks(clip);
    UM_CHECK(tracks.size() == 1 && tracks[0] == track);

    AnimationClip back("walk", 24);
    back.id = clip.id;
    setClipTracks(back, tracks);
    UM_CHECK(back == clip);
    // Reached through the track index, which only a real setter rebuilds.
    UM_CHECK(back.keyframesFor(Uuid(3, 3), AnimationTrackProperty::Rotate).size() == 2);
}

static void testConstraintsRoundTripThroughPlainData() {
    // Every field off its default, so a field the copy forgets shows up as
    // the default coming back.
    IKConstraintData ik;
    ik.id = Uuid(1, 1);
    ik.name = "arm IK";
    ik.enabled = false;
    ik.order = 7;
    ik.mix = 0.5f;
    ik.boneChain = {Uuid(2, 0), Uuid(3, 0)};
    ik.targetBoneID = Uuid(4, 0);
    ik.bendPositive = false;
    ik.stretch = true;
    ik.compress = true;
    ik.uniformScale = true;
    ik.softness = 12.0f;
    UM_CHECK(ikConstraintData(makeIKConstraint(ik)) == ik);

    TransformConstraintData tc;
    tc.id = Uuid(5, 5);
    tc.name = "follow";
    tc.enabled = false;
    tc.order = 3;
    tc.mix = 0.25f;
    tc.targetBoneID = Uuid(6, 0);
    tc.affectedBones = {Uuid(7, 0)};
    tc.copyPosition = true;
    tc.copyRotation = false;
    tc.copyScale = true;
    tc.copyShear = true;
    tc.positionMix = 0.1f;
    tc.rotationMix = 0.2f;
    tc.scaleMix = 0.3f;
    tc.shearMix = 0.4f;
    tc.offsetPositionX = 1;
    tc.offsetPositionY = 2;
    tc.offsetRotation = 3;
    tc.offsetScaleX = 4;
    tc.offsetScaleY = 5;
    tc.offsetShear = 6;
    UM_CHECK(transformConstraintData(makeTransformConstraint(tc)) == tc);

    PathConstraintData pc;
    pc.id = Uuid(8, 8);
    pc.name = "tail path";
    pc.enabled = false;
    pc.order = 9;
    pc.mix = 0.75f;
    pc.pathBones = {Uuid(9, 0), Uuid(10, 0)};
    pc.bones = {Uuid(11, 0)};
    pc.position = 0.5f;
    pc.spacing = 12.0f;
    pc.spacingMode = PathSpacingMode::Proportional;
    pc.positionMix = 0.6f;
    pc.rotateMix = 0.7f;
    pc.offsetRotation = 0.8f;
    pc.closed = true;
    pc.reversed = true;
    pc.rotateMode = PathRotateMode::ChainScale;
    UM_CHECK(pathConstraintData(makePathConstraint(pc)) == pc);

    PhysicsConstraintData ph;
    ph.id = Uuid(12, 12);
    ph.name = "hair";
    ph.enabled = false;
    ph.order = 101;
    ph.mix = 0.9f;
    ph.physicsType = PhysicsType::Rope;
    ph.affectedBones = {Uuid(13, 0), Uuid(14, 0)};
    ph.settings.mass = 2;
    ph.settings.wind = Vec2(3, -1);
    ph.settings.angleLimitMin = -1;
    UM_CHECK(physicsConstraintData(makePhysicsConstraint(ph)) == ph);

    // A default data struct makes a default constraint: the defaults agree.
    const IKConstraint defaultIK;
    IKConstraintData fromDefault = ikConstraintData(defaultIK);
    fromDefault.id = Uuid();
    UM_CHECK(fromDefault == IKConstraintData{});
    const TransformConstraint defaultTC;
    TransformConstraintData tcDefault = transformConstraintData(defaultTC);
    tcDefault.id = Uuid();
    UM_CHECK(tcDefault == TransformConstraintData{});
    const PathConstraint defaultPC;
    PathConstraintData pcDefault = pathConstraintData(defaultPC);
    pcDefault.id = Uuid();
    UM_CHECK(pcDefault == PathConstraintData{});
    const PhysicsConstraint defaultPH;
    PhysicsConstraintData phDefault = physicsConstraintData(defaultPH);
    phDefault.id = Uuid();
    UM_CHECK(phDefault == PhysicsConstraintData{});

    // Through a skeleton, in stored order, replacing what was there.
    Skeleton skeleton;
    skeleton.ikConstraints.push_back(IKConstraint("stale", {}, Uuid()));
    IKConstraintData second = ik;
    second.id = Uuid(99, 0);
    second.name = "second";
    setSkeletonIKConstraints(skeleton, IKConstraintDataList{ik, second});
    const IKConstraintDataList back = skeletonIKConstraints(skeleton);
    UM_CHECK(back.size() == 2 && back[0] == ik && back[1] == second);
    setSkeletonTransformConstraints(skeleton, TransformConstraintDataList{tc});
    setSkeletonPathConstraints(skeleton, PathConstraintDataList{pc});
    setSkeletonPhysicsConstraints(skeleton, PhysicsConstraintDataList{ph});
    UM_CHECK(skeletonTransformConstraints(skeleton) == TransformConstraintDataList{tc});
    UM_CHECK(skeletonPathConstraints(skeleton) == PathConstraintDataList{pc});
    UM_CHECK(skeletonPhysicsConstraints(skeleton) == PhysicsConstraintDataList{ph});
    // The solver sees them: they are real constraints, not just stored data.
    UM_CHECK(skeleton.allConstraints().size() == 5);
}

static void testMeshEdgesKeepTheirNormalization() {
    // The Swift initializer orders the two ends; a bridge that assigned the
    // fields directly would let (5, 2) and (2, 5) be two different edges.
    const MeshEdge e = makeMeshEdge(5, 2);
    UM_CHECK(e.a == 2 && e.b == 5);
    UM_CHECK(makeMeshEdge(2, 5) == e);
    const MeshTriangle t = makeMeshTriangle(4, 1, 2);
    UM_CHECK(t.a == 4 && t.b == 1 && t.c == 2); // a triangle keeps its winding
}

static void testASessionIsAHeapSceneTheShellOwns() {
    EditorSession* session = makeEditorSession();
    UM_CHECK(session != nullptr);
    UM_CHECK(session->scene.images.empty());
    UM_CHECK(session->assets.count() == 0);

    // Mutations through the pointer land in the one scene (no copy between).
    const Uuid id = session->scene.addBone(Vec2(0, 0), Vec2(0, 50), std::nullopt);
    UM_CHECK(session->scene.skeleton.bone(id) != nullptr);
    UM_CHECK(skeletonBones(session->scene.skeleton).size() == 1);

    destroyEditorSession(session);
    destroyEditorSession(nullptr); // ignored
}

UM_TEST_MAIN_BEGIN()
    testEveryEnumPairsWithSwiftByName();
    testAnEmptyOptionalIsNotTheDefaultValue();
    testInverseBindsRoundTripAndAreSorted();
    testAnEmptiedSlotIsNotAnUnmentionedSlot();
    testSkeletonBonesRoundTripWithTheirHierarchy();
    testClipTracksRoundTripAndReindex();
    testConstraintsRoundTripThroughPlainData();
    testMeshEdgesKeepTheirNormalization();
    testASessionIsAHeapSceneTheShellOwns();
UM_TEST_MAIN_END()
