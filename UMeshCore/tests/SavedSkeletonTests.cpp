// Tests for Serialization/SavedGeometry.h and Serialization/SavedSkeleton.h
// -- JSON conversions for the "rig" slice of `Data/ProjectPersistence.swift`
// (`SavedBone`, the four `Saved*Constraint` types, `SavedSkeleton`). See
// SavedSkeleton.h's file header for what's deliberately deferred (a bone's
// animation clip) and why. Round-trips values through toJson()/fromJson()
// and checks field values directly, plus the two documented fallback
// behaviors (SavedBone's base-pose defaulting, SavedScale2's
// scalar-or-object decode).

#include "umeshcore/Serialization/SavedSkeleton.h"

#include "umeshcore/Serialization/SavedGeometry.h"
#include "TestHarness.h"

using namespace umeshcore;

static void testVec2Vec3Vec4RoundTrip() {
    const Vec2 v2(1.5f, -2.5f);
    UM_CHECK(vec2FromJson(toJson(v2)) == v2);

    const Vec3 v3(1.0f, 2.0f, -3.0f);
    const Vec3 v3Back = vec3FromJson(toJson(v3));
    UM_CHECK_NEAR(v3Back.x, v3.x, 1e-6);
    UM_CHECK_NEAR(v3Back.y, v3.y, 1e-6);
    UM_CHECK_NEAR(v3Back.z, v3.z, 1e-6);

    const Vec4 v4(1.0f, 2.0f, 3.0f, 4.0f);
    const Vec4 v4Back = vec4FromJson(toJson(v4));
    UM_CHECK_NEAR(v4Back.w, v4.w, 1e-6);
}

static void testMat4RoundTrip() {
    Mat4 m = Mat4::identity();
    m.columns[3] = Vec4(10, 20, 30, 1);
    const Mat4 back = mat4FromJson(toJson(m));
    UM_CHECK_NEAR(back.columns[3].x, 10.0, 1e-6);
    UM_CHECK_NEAR(back.columns[0].x, 1.0, 1e-6);
}

static void testScale2AcceptsBareNumberOrObject() {
    // Old-file shorthand: a bare number means uniform scale.
    const Vec2 uniform = scale2FromJson(JsonValue::parse("2.5"));
    UM_CHECK_NEAR(uniform.x, 2.5, 1e-6);
    UM_CHECK_NEAR(uniform.y, 2.5, 1e-6);

    // Normal object form.
    const Vec2 nonUniform = scale2FromJson(JsonValue::parse("{\"x\": 1.0, \"y\": 3.0}"));
    UM_CHECK_NEAR(nonUniform.x, 1.0, 1e-6);
    UM_CHECK_NEAR(nonUniform.y, 3.0, 1e-6);
}

static void testUuidRoundTrip() {
    const Uuid id = Uuid::generate();
    const Uuid back = uuidFromJson(toJson(id));
    UM_CHECK(back == id);
}

static void testBoneRoundTripWithBasePose() {
    Bone bone;
    bone.id = Uuid::generate();
    bone.name = "upper_arm";
    bone.parentID = Uuid::generate();
    bone.baseTransform.position = Vec3(1, 2, 0);
    bone.baseTransform.rotation = Vec3(0, 0, 0.1f);
    bone.localTransform.position = Vec3(1, 2, 0);
    bone.localTransform.rotation = Vec3(0, 0, 0.5f); // posed away from base.
    bone.length = 80.0f;
    bone.color = Vec4(0.2f, 0.4f, 0.6f, 1.0f);

    const Bone back = boneFromJson(toJson(bone));
    UM_CHECK(back.id == bone.id);
    UM_CHECK(back.name == "upper_arm");
    UM_CHECK(back.parentID.has_value() && *back.parentID == *bone.parentID);
    UM_CHECK_NEAR(back.baseTransform.rotation.z, 0.1, 1e-6);
    UM_CHECK_NEAR(back.localTransform.rotation.z, 0.5, 1e-6); // base != local preserved.
    UM_CHECK_NEAR(back.length, 80.0, 1e-6);
    UM_CHECK(back.color.has_value());
    UM_CHECK_NEAR(back.color->x, 0.2, 1e-6);
}

static void testBoneWithoutBasePoseFallsBackToLocal() {
    // Simulates an old save file that never wrote base*: JSON with only
    // position/rotation/scale/skew, matching SavedBone's custom
    // init(from:) fallback (base == local when base* is absent).
    const std::string text =
        "{\"id\":\"" + Uuid::generate().toString() + "\",\"name\":\"leg\"," +
        "\"position\":{\"x\":5,\"y\":6,\"z\":0},\"rotation\":{\"x\":0,\"y\":0,\"z\":0.25}," +
        "\"scale\":{\"x\":1,\"y\":1,\"z\":1},\"skew\":{\"x\":0,\"y\":0},\"length\":50}";
    const Bone bone = boneFromJson(JsonValue::parse(text));
    UM_CHECK_NEAR(bone.baseTransform.position.x, 5.0, 1e-6);
    UM_CHECK_NEAR(bone.baseTransform.rotation.z, 0.25, 1e-6);
    UM_CHECK(!bone.parentID.has_value());
    UM_CHECK(!bone.color.has_value());
}

static void testConstraintsRoundTrip() {
    IKConstraint ik("Arm IK", {Uuid::generate(), Uuid::generate()}, Uuid::generate());
    ik.mix_ = 0.75f;
    ik.softness = 12.5f;
    const IKConstraint ikBack = ikConstraintFromJson(toJson(ik));
    UM_CHECK(ikBack.name_ == "Arm IK");
    UM_CHECK(ikBack.boneChain.size() == 2);
    UM_CHECK_NEAR(ikBack.softness, 12.5, 1e-6);

    PathConstraint path("Tail Path", {Uuid::generate(), Uuid::generate()}, {Uuid::generate()});
    path.spacingMode = PathSpacingMode::Proportional;
    path.rotateMode = PathRotateMode::ChainScale;
    path.closed = true;
    const PathConstraint pathBack = pathConstraintFromJson(toJson(path));
    UM_CHECK(pathBack.spacingMode == PathSpacingMode::Proportional);
    UM_CHECK(pathBack.rotateMode == PathRotateMode::ChainScale);
    UM_CHECK(pathBack.closed == true);

    TransformConstraint xform("Copy", Uuid::generate(), {Uuid::generate()});
    xform.copyScale = true;
    xform.offsetRotation = 0.3f;
    const TransformConstraint xformBack = transformConstraintFromJson(toJson(xform));
    UM_CHECK(xformBack.copyScale == true);
    UM_CHECK_NEAR(xformBack.offsetRotation, 0.3, 1e-6);

    PhysicsConstraint phys("Hair");
    phys.physicsType = PhysicsType::Jiggle;
    phys.settings.stiffness = 200.0f;
    const PhysicsConstraint physBack = physicsConstraintFromJson(toJson(phys));
    UM_CHECK(physBack.physicsType == PhysicsType::Jiggle);
    UM_CHECK_NEAR(physBack.settings.stiffness, 200.0, 1e-6);
}

static void testUnknownEnumStringFallsBackLikeSwift() {
    // An unrecognized rawValue (future format, or corrupt data) falls back
    // to the same default Swift's own `?? .default` does, rather than
    // throwing -- matches PathSpacingMode/.../.PhysicsType's documented
    // fallback behavior.
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(Uuid::generate()));
    j.set("name", JsonValue::makeString("x"));
    j.set("enabled", JsonValue::makeBool(true));
    j.set("order", JsonValue::makeNumber(0));
    j.set("mix", JsonValue::makeNumber(1));
    j.set("physicsType", JsonValue::makeString("madeUpFutureType"));
    j.set("affectedBones", JsonValue::makeArray());
    j.set("settings", toJson(PhysicsSettings{}));
    const PhysicsConstraint c = physicsConstraintFromJson(j);
    UM_CHECK(c.physicsType == PhysicsType::Spring);
}

static void testSkeletonRoundTripIncludingAllConstraintArrays() {
    Skeleton skeleton;
    Bone root;
    root.id = Uuid::generate();
    root.name = "root";
    Bone child;
    child.id = Uuid::generate();
    child.name = "child";
    child.parentID = root.id;
    skeleton.setBone(root);
    skeleton.setBone(child);
    skeleton.rootIDs.push_back(root.id);

    skeleton.ikConstraints.push_back(IKConstraint("ik", {child.id}, root.id));
    skeleton.pathConstraints.push_back(PathConstraint("path", {root.id, child.id}, {child.id}));
    skeleton.transformConstraints.push_back(TransformConstraint("xform", root.id, {child.id}));
    skeleton.physicsConstraints.push_back(PhysicsConstraint("phys"));

    const Skeleton back = skeletonFromJson(toJson(skeleton));
    UM_CHECK(back.bones().size() == 2);
    UM_CHECK(back.rootIDs.size() == 1 && back.rootIDs[0] == root.id);
    UM_CHECK(back.ikConstraints.size() == 1);
    UM_CHECK(back.pathConstraints.size() == 1);
    UM_CHECK(back.transformConstraints.size() == 1);
    UM_CHECK(back.physicsConstraints.size() == 1);
    UM_CHECK(back.bones().at(child.id).parentID.has_value() && *back.bones().at(child.id).parentID == root.id);
}

static void testSkeletonWithoutConstraintArraysDefaultsToEmpty() {
    // Simulates an old save file predating constraint persistence: the
    // four constraint arrays are absent entirely, not present-and-empty.
    JsonValue j = JsonValue::makeObject();
    j.set("bones", JsonValue::makeArray());
    j.set("rootIDs", JsonValue::makeArray());
    const Skeleton skeleton = skeletonFromJson(j);
    UM_CHECK(skeleton.ikConstraints.empty());
    UM_CHECK(skeleton.pathConstraints.empty());
    UM_CHECK(skeleton.transformConstraints.empty());
    UM_CHECK(skeleton.physicsConstraints.empty());
}

UM_TEST_MAIN_BEGIN()
    testVec2Vec3Vec4RoundTrip();
    testMat4RoundTrip();
    testScale2AcceptsBareNumberOrObject();
    testUuidRoundTrip();
    testBoneRoundTripWithBasePose();
    testBoneWithoutBasePoseFallsBackToLocal();
    testConstraintsRoundTrip();
    testUnknownEnumStringFallsBackLikeSwift();
    testSkeletonRoundTripIncludingAllConstraintArrays();
    testSkeletonWithoutConstraintArraysDefaultsToEmpty();
UM_TEST_MAIN_END()
