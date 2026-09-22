// Tests for Serialization/SavedSceneImage.h -- JSON conversions for
// `SavedMesh`, `SavedSceneImage` and `SavedSkin`. Expected values and
// fallback behavior are hand-derived from `Data/ProjectPersistence.swift`'s
// `restoredMesh()`/`restoredSceneImage()`/`SavedSkin.restored()`, which
// were read directly -- not from this port's own output.

#include "umeshcore/Serialization/SavedSceneImage.h"

#include "umeshcore/Serialization/SavedAnimation.h"
#include "umeshcore/Serialization/SavedGeometry.h"
#include "TestHarness.h"

using namespace umeshcore;

static Mesh makeQuadMesh(const Uuid& boneID) {
    Mesh mesh("body");
    mesh.vertices = {Vec2(-10, 10), Vec2(10, 10), Vec2(-10, -10), Vec2(10, -10)};
    mesh.uvs = {Vec2(0, 0), Vec2(1, 0), Vec2(0, 1), Vec2(1, 1)};
    mesh.indices = {0, 1, 2, 2, 1, 3};
    mesh.hullVertexIndices = {0, 1, 3, 2};
    mesh.internalEdges = {MeshEdge(0, 3)};
    mesh.manualTriangles = {MeshTriangle{0, 1, 2}};
    mesh.bindVertices = mesh.vertices;
    for (int i = 0; i < 4; ++i) mesh.vertexBoneWeights.push_back({VertexBoneWeight{boneID, 1.0f}});
    mesh.boneInverseBindMatrices[boneID] = Mat4::identity();
    MeshBindPose pose;
    pose.position = Vec2(5, 6);
    pose.rotation = 0.25f;
    mesh.bindImagePose = pose;
    return mesh;
}

static void testMeshRoundTrip() {
    const Uuid boneID = Uuid::generate();
    const Mesh mesh = makeQuadMesh(boneID);
    const Mesh back = meshFromJson(toJson(mesh));

    UM_CHECK(back.id == mesh.id);
    UM_CHECK(back.name == "body");
    UM_CHECK(back.vertices.size() == 4);
    UM_CHECK(back.uvs.size() == 4);
    UM_CHECK(back.indices == mesh.indices);
    UM_CHECK(back.hullVertexIndices == mesh.hullVertexIndices);
    UM_CHECK(back.internalEdges.size() == 1);
    UM_CHECK(back.internalEdges[0].a == 0 && back.internalEdges[0].b == 3);
    UM_CHECK(back.manualTriangles.size() == 1);
    UM_CHECK(back.manualTriangles[0].c == 2);
    UM_CHECK(back.bindVertices.size() == 4);
    UM_CHECK(back.vertexBoneWeights.size() == 4);
    UM_CHECK(back.vertexBoneWeights[0][0].boneID == boneID);
    UM_CHECK(back.boneInverseBindMatrices.size() == 1);
    UM_CHECK(back.bindImagePose.has_value());
    UM_CHECK_NEAR(back.bindImagePose->position.x, 5.0, 1e-6);
    UM_CHECK_NEAR(back.bindImagePose->rotation, 0.25, 1e-6);
}

static void testMeshOptionalArraysDefaultToEmpty() {
    // An old save file carrying only the fields that always existed.
    const std::string text =
        "{\"id\":\"" + Uuid::generate().toString() + "\",\"name\":\"old\"," +
        "\"vertices\":[{\"x\":-1,\"y\":1},{\"x\":1,\"y\":1},{\"x\":-1,\"y\":-1}]," +
        "\"uvs\":[{\"x\":0,\"y\":0},{\"x\":1,\"y\":0},{\"x\":0,\"y\":1}]," +
        "\"indices\":[0,1,2],\"hullVertexIndices\":[0,1,2]}";
    const Mesh mesh = meshFromJson(JsonValue::parse(text));

    UM_CHECK(mesh.name == "old");
    UM_CHECK(mesh.vertices.size() == 3);
    UM_CHECK(mesh.internalEdges.empty());
    UM_CHECK(mesh.manualTriangles.empty());
    UM_CHECK(mesh.boneInverseBindMatrices.empty());
    UM_CHECK(!mesh.bindImagePose.has_value());

    // `bindVertices`/`vertexBoneWeights` decode as absent (`?? []`) but do
    // NOT stay empty: the load-time `sanitizedSkinningData()` pass that
    // both implementations run normalizes them to one entry per vertex --
    // bind vertices default to the rest vertices, and every vertex gets an
    // (empty) influence list. Asserted explicitly because it is the real
    // observable result of loading an old, skinning-free mesh, not an
    // accident of this port.
    UM_CHECK(mesh.bindVertices.size() == mesh.vertices.size());
    UM_CHECK(mesh.bindVertices[0] == mesh.vertices[0]);
    UM_CHECK(mesh.vertexBoneWeights.size() == mesh.vertices.size());
    UM_CHECK(mesh.vertexBoneWeights[0].empty());
    UM_CHECK(!mesh.hasSkinningData());
}

static void testSceneImageRoundTrip() {
    const Uuid boneID = Uuid::generate();
    SceneImage image;
    image.name = "hero_body";
    image.assetID = Uuid::generate();
    image.basePosition = Vec2(1, 2);
    image.position = Vec2(3, 4);
    image.baseScale = Vec2(1, 1);
    image.scale = Vec2(2, 3);
    image.baseRotation = 0.1f;
    image.rotation = 0.2f;
    image.baseRotation3D = Vec3(0, 0.3f, 0);
    image.rotation3D = Vec3(0, 0.4f, 0);
    image.baseSkew = Vec2(0.5f, 0);
    image.skew = Vec2(0.6f, 0);
    image.mesh = makeQuadMesh(boneID);
    image.isHidden = true;
    image.slotName = "torso";
    image.normalMapAssetID = Uuid::generate();
    image.tintColor = Vec4(0.5f, 0.6f, 0.7f, 0.8f);
    image.blendMode = ImageBlendMode::Screen;
    image.animationClip = AnimationClip(
        "sprite", 12, {AnimationTrack(image.id, AnimationTrackProperty::Translate, {Keyframe(2, TranslateValue{Vec2(9, 9)})})});

    BoneImageBinding binding;
    binding.boneID = boneID;
    binding.localPosition = Vec2(7, 8);
    binding.localScale = Vec2(1.5f, 2.5f);
    binding.localRotation = 0.35f;
    image.boneBinding = binding;
    image.animationTransformSpace = TransformAnimationSpace::boneLocal(boneID);

    const SceneImage back = sceneImageFromJson(toJson(image));

    UM_CHECK(back.id == image.id);
    UM_CHECK(back.assetID == image.assetID);
    UM_CHECK(back.name == "hero_body");
    UM_CHECK_NEAR(back.position.x, 3.0, 1e-6);
    UM_CHECK_NEAR(back.scale.y, 3.0, 1e-6);
    UM_CHECK_NEAR(back.rotation3D.y, 0.4, 1e-6);
    UM_CHECK(back.isHidden);
    UM_CHECK(back.slotName == "torso");
    UM_CHECK(back.normalMapAssetID.has_value() && *back.normalMapAssetID == *image.normalMapAssetID);
    UM_CHECK_NEAR(back.tintColor.z, 0.7, 1e-6);
    UM_CHECK(back.blendMode == ImageBlendMode::Screen);
    UM_CHECK(back.mesh.vertices.size() == 4);
    UM_CHECK(back.boneBinding.has_value() && back.boneBinding->boneID == boneID);
    UM_CHECK_NEAR(back.boneBinding->localScale.y, 2.5, 1e-6);
    UM_CHECK(back.animationTransformSpace.boneID.has_value() && *back.animationTransformSpace.boneID == boneID);
    UM_CHECK(back.animationClip.tracks().size() == 1);
}

static void testSceneImageFallbacksForOldFiles() {
    // No mesh, no slotName, no tintColor, no blendMode, and no explicit
    // animation space -- but a bone binding, which the space must be
    // inferred from (tier 2 of the three-tier fallback).
    const Uuid boneID = Uuid::generate();
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(Uuid::generate()));
    j.set("assetID", toJson(Uuid::generate()));
    j.set("name", JsonValue::makeString("legacy"));
    j.set("basePosition", toJson(Vec2::zero()));
    j.set("position", toJson(Vec2::zero()));
    j.set("baseScale", toJson(Vec2::one()));
    j.set("scale", toJson(Vec2::one()));
    j.set("baseRotation", JsonValue::makeNumber(0));
    j.set("rotation", JsonValue::makeNumber(0));
    j.set("baseRotation3D", toJson(Vec3::zero()));
    j.set("rotation3D", toJson(Vec3::zero()));
    j.set("baseSkew", toJson(Vec2::zero()));
    j.set("skew", toJson(Vec2::zero()));
    j.set("isHidden", JsonValue::makeBool(false));
    j.set("animationClip", toJson(AnimationClip("legacy")));
    BoneImageBinding binding;
    binding.boneID = boneID;
    j.set("boneBinding", toJson(binding));

    const SceneImage image = sceneImageFromJson(j);
    UM_CHECK(image.mesh.name == "legacy Mesh"); // `?? Mesh(name: "\(name) Mesh")`.
    UM_CHECK(image.slotName.empty());
    UM_CHECK_NEAR(image.tintColor.x, 1.0, 1e-6); // white default.
    UM_CHECK_NEAR(image.tintColor.w, 1.0, 1e-6);
    UM_CHECK(image.blendMode == ImageBlendMode::Normal);
    // Inferred from the binding, since no explicit space was saved.
    UM_CHECK(image.animationTransformSpace.boneID.has_value());
    UM_CHECK(*image.animationTransformSpace.boneID == boneID);
}

static void testSceneImageWithoutBindingOrSpaceIsWorld() {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(Uuid::generate()));
    j.set("assetID", toJson(Uuid::generate()));
    j.set("name", JsonValue::makeString("loose"));
    j.set("basePosition", toJson(Vec2::zero()));
    j.set("position", toJson(Vec2::zero()));
    j.set("baseScale", toJson(Vec2::one()));
    j.set("scale", toJson(Vec2::one()));
    j.set("baseRotation", JsonValue::makeNumber(0));
    j.set("rotation", JsonValue::makeNumber(0));
    j.set("baseRotation3D", toJson(Vec3::zero()));
    j.set("rotation3D", toJson(Vec3::zero()));
    j.set("baseSkew", toJson(Vec2::zero()));
    j.set("skew", toJson(Vec2::zero()));
    j.set("isHidden", JsonValue::makeBool(false));
    j.set("animationClip", toJson(AnimationClip("loose")));

    const SceneImage image = sceneImageFromJson(j);
    UM_CHECK(!image.animationTransformSpace.boneID.has_value()); // world.
    UM_CHECK(!image.boneBinding.has_value());
}

static void testSceneImageScaleAcceptsUniformScalar() {
    // SavedScale2's old-file shorthand reaches sprite scale fields too.
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(Uuid::generate()));
    j.set("assetID", toJson(Uuid::generate()));
    j.set("name", JsonValue::makeString("uniform"));
    j.set("basePosition", toJson(Vec2::zero()));
    j.set("position", toJson(Vec2::zero()));
    j.set("baseScale", JsonValue::makeNumber(1.0));
    j.set("scale", JsonValue::makeNumber(2.5)); // bare number, not {x,y}.
    j.set("baseRotation", JsonValue::makeNumber(0));
    j.set("rotation", JsonValue::makeNumber(0));
    j.set("baseRotation3D", toJson(Vec3::zero()));
    j.set("rotation3D", toJson(Vec3::zero()));
    j.set("baseSkew", toJson(Vec2::zero()));
    j.set("skew", toJson(Vec2::zero()));
    j.set("isHidden", JsonValue::makeBool(false));
    j.set("animationClip", toJson(AnimationClip("uniform")));

    const SceneImage image = sceneImageFromJson(j);
    UM_CHECK_NEAR(image.scale.x, 2.5, 1e-6);
    UM_CHECK_NEAR(image.scale.y, 2.5, 1e-6);
}

static void testSceneImageIgnoresMalformedTintColor() {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(Uuid::generate()));
    j.set("assetID", toJson(Uuid::generate()));
    j.set("name", JsonValue::makeString("badtint"));
    j.set("basePosition", toJson(Vec2::zero()));
    j.set("position", toJson(Vec2::zero()));
    j.set("baseScale", toJson(Vec2::one()));
    j.set("scale", toJson(Vec2::one()));
    j.set("baseRotation", JsonValue::makeNumber(0));
    j.set("rotation", JsonValue::makeNumber(0));
    j.set("baseRotation3D", toJson(Vec3::zero()));
    j.set("rotation3D", toJson(Vec3::zero()));
    j.set("baseSkew", toJson(Vec2::zero()));
    j.set("skew", toJson(Vec2::zero()));
    j.set("isHidden", JsonValue::makeBool(false));
    j.set("animationClip", toJson(AnimationClip("badtint")));
    JsonValue::Array shortTint;
    shortTint.push_back(JsonValue::makeNumber(0.5));
    shortTint.push_back(JsonValue::makeNumber(0.5));
    j.set("tintColor", JsonValue::makeArray(std::move(shortTint))); // only 2 components.

    const SceneImage image = sceneImageFromJson(j);
    // Not partially applied: falls back to white entirely.
    UM_CHECK_NEAR(image.tintColor.x, 1.0, 1e-6);
    UM_CHECK_NEAR(image.tintColor.y, 1.0, 1e-6);
}

static void testSkinRoundTripKeepsEmptySlotsDistinctFromAbsentOnes() {
    const Uuid imageID = Uuid::generate();
    Skin skin("Armor");
    skin.attachments["torso"] = imageID;       // described, occupied
    skin.attachments["head"] = std::nullopt;   // described, deliberately empty
    skin.includedSkinIDs.push_back(Uuid::generate());
    // "legs" is not described at all.

    const JsonValue j = toJson(skin);
    UM_CHECK(j.find("attachments")->asArray().size() == 2);
    // Sorted by slot name: "head" before "torso".
    UM_CHECK(j.find("attachments")->asArray()[0].find("slot")->asString() == "head");
    UM_CHECK(j.find("attachments")->asArray()[0].find("imageID")->isNull());

    const Skin back = skinFromJson(j);
    UM_CHECK(back.id == skin.id);
    UM_CHECK(back.name == "Armor");
    UM_CHECK(back.attachments.size() == 2);
    UM_CHECK(back.attachments.count("head") == 1);
    UM_CHECK(!back.attachments.at("head").has_value()); // described AND empty.
    UM_CHECK(back.attachments.at("torso").has_value() && *back.attachments.at("torso") == imageID);
    UM_CHECK(back.attachments.count("legs") == 0);      // still not described.
    UM_CHECK(back.includedSkinIDs.size() == 1);
}

UM_TEST_MAIN_BEGIN()
    testMeshRoundTrip();
    testMeshOptionalArraysDefaultToEmpty();
    testSceneImageRoundTrip();
    testSceneImageFallbacksForOldFiles();
    testSceneImageWithoutBindingOrSpaceIsWorld();
    testSceneImageScaleAcceptsUniformScalar();
    testSceneImageIgnoresMalformedTintColor();
    testSkinRoundTripKeepsEmptySlotsDistinctFromAbsentOnes();
UM_TEST_MAIN_END()
