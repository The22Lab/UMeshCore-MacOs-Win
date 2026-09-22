// Tests for Serialization/UMJsonModel.h + UMJsonBuilder.h -- the
// engine-agnostic UMJSON interchange format, ported from
// `Export/JSON/UMJSONModel.swift` and `UMJSONExportBuilder.swift`, both
// read directly. Expected values are hand-derived from that source: the
// format's own vocabulary ("stepped", not "hold"), its flat-array shapes,
// its omit-when-neutral rules, and the two animation-cleanup rules.
//
// UMJSON is write-only (Swift has no importer), so these assert the built
// document and the rendered text, not a round trip.

#include "umeshcore/Serialization/UMJsonBuilder.h"

#include "TestHarness.h"

using namespace umeshcore;

namespace {

struct Fixture {
    EditorScene scene;
    std::unordered_map<Uuid, AssetRecord, UuidHash> assets;
    Uuid rootBoneID;
    Uuid childBoneID;
    Uuid imageID;
    Uuid assetID = Uuid::generate();
};

Fixture makeFixture() {
    Fixture f;

    Bone root;
    root.name = "root";
    root.baseTransform.position = Vec3(1, 2, 0);
    root.baseTransform.rotation = Vec3(0, 0, 0.5f);
    root.length = 100.0f;
    f.rootBoneID = root.id;

    Bone child;
    child.name = "child";
    child.parentID = root.id;
    child.length = 50.0f;
    f.childBoneID = child.id;

    f.scene.skeleton.setBone(root);
    f.scene.skeleton.setBone(child);
    f.scene.skeleton.rootIDs.push_back(root.id);

    SceneImage image;
    image.name = "body";
    image.assetID = f.assetID;
    image.slotName = "torso";
    image.basePosition = Vec2(5, 6);
    image.baseRotation = 0.25f;
    image.mesh = Mesh::makeQuad("body mesh", Vec2(64, 64));
    image.animationClip = AnimationClip("body");
    f.imageID = image.id;
    f.scene.images.push_back(image);

    f.scene.playbackStartFrame = 2;
    f.scene.playbackEndFrame = 48;

    AssetRecord asset;
    asset.id = f.assetID;
    asset.name = "body";
    asset.filePath = "/projects/MyRig.umesh/Assets/1-body.png";
    asset.size = Vec2(64, 64);
    f.assets[f.assetID] = asset;

    return f;
}

UMJsonKeyframe key(int frame, float scalar, const char* interp = "linear") {
    UMJsonKeyframe k;
    k.frame = frame;
    k.interp = interp;
    k.scalar = scalar;
    return k;
}

} // namespace

static void testDocumentHeaderAndMetadata() {
    Fixture f = makeFixture();
    const UMJsonDocument doc = buildUMJsonDocument(f.scene, f.assets, {});

    UM_CHECK(doc.format == "UltraMesh");
    UM_CHECK(doc.version == "1.0.0");
    UM_CHECK(doc.compatibility.minRuntimeVersion == "1.0.0");
    UM_CHECK(doc.compatibility.featureFlags.size() == 8);
    UM_CHECK(doc.compatibility.featureFlags[0] == "ik");
    UM_CHECK(doc.compatibility.featureFlags.back() == "meshSkinning");
    UM_CHECK(!doc.exportDate.empty());

    UM_CHECK(doc.metadata.units == "pixels");
    UM_CHECK(doc.metadata.playbackStartFrame == 2);
    UM_CHECK(doc.metadata.playbackEndFrame == 48);
    UM_CHECK_NEAR(doc.metadata.framesPerSecond, 30.0, 1e-9);
    UM_CHECK(doc.metadata.projectName == "UltraMeshProject");
    UM_CHECK(doc.metadata.drawOrder.size() == 1);
}

static void testNonessentialDataStripsEditorOnlyValues() {
    Fixture f = makeFixture();
    UMJsonExportOptions options;
    options.nonessentialData = false;
    const UMJsonDocument doc = buildUMJsonDocument(f.scene, f.assets, {}, options);

    // Project name, setup draw order, atlas region names and bone colors
    // are editor convenience; a runtime never reads them.
    UM_CHECK(doc.metadata.projectName.empty());
    UM_CHECK(doc.metadata.drawOrder.empty());
    UM_CHECK(doc.atlas.regions[0].name.empty());
    for (const UMJsonBone& bone : doc.bones) UM_CHECK(!bone.color.has_value());

    // With it on, all four come back.
    const UMJsonDocument full = buildUMJsonDocument(f.scene, f.assets, {});
    UM_CHECK(!full.metadata.projectName.empty());
    UM_CHECK(full.atlas.regions[0].name == "body");
    UM_CHECK(full.bones[0].color.has_value() && full.bones[0].color->size() == 4);
}

static void testBonesAreInDeterministicOrderWithRootFlagged() {
    Fixture f = makeFixture();
    const UMJsonDocument doc = buildUMJsonDocument(f.scene, f.assets, {});

    UM_CHECK(doc.bones.size() == 2);
    // DFS from the declared root, so the root comes first regardless of
    // the skeleton map's iteration order.
    UM_CHECK(doc.bones[0].id == f.rootBoneID.toString());
    UM_CHECK(doc.bones[0].root == true);
    UM_CHECK(!doc.bones[0].parent.has_value());
    UM_CHECK(doc.bones[1].id == f.childBoneID.toString());
    UM_CHECK(doc.bones[1].root == false);
    UM_CHECK(doc.bones[1].parent.has_value() && *doc.bones[1].parent == f.rootBoneID.toString());

    // Bone transforms are flat arrays, rotation is the Z component.
    UM_CHECK(doc.bones[0].transform.position.size() == 2);
    UM_CHECK_NEAR(doc.bones[0].transform.position[0], 1.0, 1e-6);
    UM_CHECK_NEAR(doc.bones[0].transform.rotation, 0.5, 1e-6);
    // A flat 2D bone carries no depth block.
    UM_CHECK(!doc.bones[0].transform.depth.has_value());
}

static void testDepthBlockOnlyAppearsWhenThereIsRealDepth() {
    Fixture f = makeFixture();
    Bone tilted = f.scene.skeleton.bones().at(f.childBoneID);
    tilted.baseTransform.rotation = Vec3(0.3f, 0, 0); // a real X tilt
    f.scene.skeleton.setBone(tilted);

    const UMJsonDocument doc = buildUMJsonDocument(f.scene, f.assets, {});
    const UMJsonBone& child = doc.bones[1];
    UM_CHECK(child.transform.depth.has_value());
    UM_CHECK_NEAR(child.transform.depth->rotationX, 0.3, 1e-6);
    UM_CHECK_NEAR(child.transform.depth->scaleZ, 1.0, 1e-6);
}

static void testAttachmentOmitsNeutralTintAndNormalBlend() {
    Fixture f = makeFixture();
    const UMJsonDocument doc = buildUMJsonDocument(f.scene, f.assets, {});
    UM_CHECK(doc.attachments.size() == 1);
    const UMJsonAttachment& a = doc.attachments[0];

    UM_CHECK(a.slot == "torso");
    UM_CHECK(a.region == f.assetID.toString());
    UM_CHECK(a.animationSpace == "world");
    UM_CHECK(!a.animationSpaceBone.has_value());
    UM_CHECK(!a.color.has_value()); // white is neutral -- omitted.
    UM_CHECK(!a.blend.has_value()); // normal is neutral -- omitted.
    UM_CHECK(!a.boneBinding.has_value());
    UM_CHECK_NEAR(a.setupPose.position[0], 5.0, 1e-6);
    UM_CHECK_NEAR(a.setupPose.rotation, 0.25, 1e-6);

    // Tinted and blended, they appear.
    f.scene.images[0].tintColor = Vec4(1, 0.5f, 0.5f, 1);
    f.scene.images[0].blendMode = ImageBlendMode::Additive;
    const UMJsonDocument tinted = buildUMJsonDocument(f.scene, f.assets, {});
    UM_CHECK(tinted.attachments[0].color.has_value());
    UM_CHECK(tinted.attachments[0].blend.has_value() && *tinted.attachments[0].blend == "additive");
}

static void testBoundAttachmentReportsBoneLocalSpace() {
    Fixture f = makeFixture();
    BoneImageBinding binding;
    binding.boneID = f.rootBoneID;
    binding.localPosition = Vec2(7, 8);
    f.scene.images[0].boneBinding = binding;
    f.scene.images[0].animationTransformSpace = TransformAnimationSpace::boneLocal(f.rootBoneID);

    const UMJsonDocument doc = buildUMJsonDocument(f.scene, f.assets, {});
    const UMJsonAttachment& a = doc.attachments[0];
    UM_CHECK(a.animationSpace == "boneLocal");
    UM_CHECK(a.animationSpaceBone.has_value() && *a.animationSpaceBone == f.rootBoneID.toString());
    UM_CHECK(a.boneBinding.has_value());
    UM_CHECK(a.boneBinding->bone == f.rootBoneID.toString());
    UM_CHECK_NEAR(a.boneBinding->localPose.position[1], 8.0, 1e-6);
}

static void testMeshIsFlattenedAndSkinningOmittedWhenUnweighted() {
    Fixture f = makeFixture();
    const UMJsonDocument doc = buildUMJsonDocument(f.scene, f.assets, {});
    UM_CHECK(doc.meshes.size() == 1);
    const UMJsonMesh& m = doc.meshes[0];

    // A quad: 4 vertices flattened to 8 floats, 6 triangle indices.
    UM_CHECK(m.vertices.size() == 8);
    UM_CHECK(m.uvs.size() == 8);
    UM_CHECK(m.triangles.size() == 6);
    // Unweighted, so every skinning field stays absent.
    UM_CHECK(!m.bindVertices.has_value());
    UM_CHECK(!m.weights.has_value());
    UM_CHECK(!m.inverseBindMatrices.has_value());
    UM_CHECK(!m.bindPose.has_value());
}

static void testSkinnedMeshEmitsSortedWeightsAndMatrices() {
    Fixture f = makeFixture();
    Mesh mesh = f.scene.images[0].mesh;
    for (std::size_t i = 0; i < mesh.vertices.size(); ++i) {
        mesh.vertexBoneWeights.push_back({VertexBoneWeight{f.rootBoneID, 1.0f}});
    }
    mesh.bindVertices = mesh.vertices;
    mesh.boneInverseBindMatrices[f.rootBoneID] = Mat4::identity();
    f.scene.images[0].mesh = mesh;

    const UMJsonDocument doc = buildUMJsonDocument(f.scene, f.assets, {});
    const UMJsonMesh& m = doc.meshes[0];
    UM_CHECK(m.bindVertices.has_value() && m.bindVertices->size() == 8);
    UM_CHECK(m.weights.has_value() && m.weights->size() == 4);
    UM_CHECK((*m.weights)[0][0].bone == f.rootBoneID.toString());
    UM_CHECK(m.inverseBindMatrices.has_value() && m.inverseBindMatrices->size() == 1);
    // Column-major, 16 floats.
    UM_CHECK((*m.inverseBindMatrices)[0].matrix.size() == 16);
    UM_CHECK_NEAR((*m.inverseBindMatrices)[0].matrix[0], 1.0, 1e-6);
}

static void testSkinSlotsKeepDeliberatelyEmptyEntries() {
    Fixture f = makeFixture();
    Skin skin("Armor");
    skin.attachments["torso"] = f.imageID;
    skin.attachments["head"] = std::nullopt; // described AND empty
    f.scene.skins.push_back(skin);

    const UMJsonDocument doc = buildUMJsonDocument(f.scene, f.assets, {});
    UM_CHECK(doc.skins.size() == 1);
    UM_CHECK(doc.skins[0].slots.size() == 2);
    // Sorted by slot: head before torso.
    UM_CHECK(doc.skins[0].slots[0].slot == "head");
    UM_CHECK(!doc.skins[0].slots[0].attachment.has_value());
    UM_CHECK(doc.skins[0].slots[1].attachment.has_value());

    // The empty slot is an explicit null in the text, not an absent key:
    // "deliberately empty" and "not described" must stay distinguishable.
    const JsonValue j = toJson(doc);
    const JsonValue& head = j.find("skins")->asArray()[0].find("slots")->asArray()[0];
    UM_CHECK(head.find("attachment") != nullptr);
    UM_CHECK(head.find("attachment")->isNull());
}

static void testInterpolationIsSpelledSteppedNotHold() {
    Fixture f = makeFixture();
    UMJsonAnimationSource source;
    source.name = "Walk";
    source.duration = 24;
    source.boneClips[f.rootBoneID] = AnimationClip(
        "root", 24,
        {AnimationTrack(
            f.rootBoneID, AnimationTrackProperty::Rotate,
            {Keyframe(0, RotateValue{0.0f}, KeyframeInterpolation::Hold),
             Keyframe(12, RotateValue{1.0f}, KeyframeInterpolation::Bezier, Vec2(0.1f, 0.2f)),
             Keyframe(24, RotateValue{2.0f}, KeyframeInterpolation::Linear)})});

    const UMJsonDocument doc = buildUMJsonDocument(f.scene, f.assets, {source});
    UM_CHECK(doc.animations.size() == 1);
    UM_CHECK(doc.animations[0].name == "Walk");
    UM_CHECK(doc.animations[0].durationFrames == 24);
    UM_CHECK(doc.animations[0].bones.size() == 1);

    const std::vector<UMJsonKeyframe>& keys = *doc.animations[0].bones[0].rotate;
    UM_CHECK(keys.size() == 3);
    UM_CHECK(keys[0].interp == "stepped"); // NOT "hold" -- this format's word.
    UM_CHECK(keys[1].interp == "bezier");
    UM_CHECK(keys[2].interp == "linear");
    // A rotate track carries a scalar, never a vector.
    UM_CHECK(keys[0].scalar.has_value() && !keys[0].vector.has_value());
    UM_CHECK(keys[1].inTangent.has_value());
}

static void testDeformKeysAreAbsoluteAndNeverClaimBezier() {
    Fixture f = makeFixture();
    const std::vector<Vec2>& rest = f.scene.images[0].mesh.vertices;
    std::vector<Vec2> moved = rest;
    moved[0] = Vec2(rest[0].x + 5.0f, rest[0].y);

    UMJsonAnimationSource source;
    source.name = "Squash";
    source.imageClips[f.imageID] = AnimationClip(
        "body", 10,
        {AnimationTrack(
            f.imageID, AnimationTrackProperty::MeshDeform,
            {Keyframe(0, MeshDeformValue{moved}, KeyframeInterpolation::Bezier)})});

    const UMJsonDocument doc = buildUMJsonDocument(f.scene, f.assets, {source});
    UM_CHECK(doc.animations[0].attachments.size() == 1);
    const std::vector<UMJsonDeformKey>& deform = *doc.animations[0].attachments[0].deform;
    UM_CHECK(deform.size() == 1);
    // Bezier collapses to linear: the deform sampler never reads tangents,
    // so claiming otherwise would be a lie the runtime could act on.
    UM_CHECK(deform[0].interp == "linear");
    // Absolute positions, flattened -- not offsets from rest.
    UM_CHECK(deform[0].vertices.size() == rest.size() * 2);
    UM_CHECK_NEAR(deform[0].vertices[0], rest[0].x + 5.0f, 1e-5);
}

static void testDeformKeysWithMismatchedVertexCountAreDropped() {
    Fixture f = makeFixture();
    UMJsonAnimationSource source;
    source.name = "Bad";
    source.imageClips[f.imageID] = AnimationClip(
        "body", 10,
        {AnimationTrack(
            f.imageID, AnimationTrackProperty::MeshDeform,
            {Keyframe(0, MeshDeformValue{{Vec2(1, 1)}})})}); // 1 vertex vs the mesh's 4

    const UMJsonDocument doc = buildUMJsonDocument(f.scene, f.assets, {source});
    // The editor ignores such keys at playback, so exporting them would
    // hand the runtime data the editor itself would never show.
    UM_CHECK(doc.animations[0].attachments.empty());
}

static void testCleanupKeepsAConstantTrackThatDiffersFromSetup() {
    // Rule 1's guard: dropping this would silently re-pose the rig.
    const std::vector<UMJsonKeyframe> keys{key(0, 45.0f), key(10, 45.0f), key(20, 45.0f)};

    const std::vector<UMJsonKeyframe> atSetup = cleanedTrack(keys, UMJsonSetupValue::scalar(45.0f));
    UM_CHECK(atSetup.empty()); // equals setup -> redundant.

    const std::vector<UMJsonKeyframe> offSetup = cleanedTrack(keys, UMJsonSetupValue::scalar(0.0f));
    UM_CHECK(!offSetup.empty()); // differs from setup -> KEPT.

    const std::vector<UMJsonKeyframe> noSetup = cleanedTrack(keys, std::nullopt);
    UM_CHECK(!noSetup.empty()); // unknown setup -> kept, defensively.
}

static void testCleanupDropsInteriorKeysButKeepsEndpointsAndCurves() {
    // Rule 2: a run of equal values keeps its first and last so the hold's
    // timing survives exactly.
    const std::vector<UMJsonKeyframe> run{key(0, 1.0f), key(5, 1.0f), key(10, 1.0f), key(15, 2.0f)};
    const std::vector<UMJsonKeyframe> cleaned = cleanedTrack(run, std::nullopt);
    UM_CHECK(cleaned.size() == 3);
    UM_CHECK(cleaned[0].frame == 0);
    UM_CHECK(cleaned[1].frame == 10); // frame 5 was the redundant middle.
    UM_CHECK(cleaned[2].frame == 15);

    // A Bezier key is never dropped: its handles shape the neighbouring
    // curve even when the values match.
    std::vector<UMJsonKeyframe> withCurve = run;
    withCurve[1].interp = "bezier";
    UM_CHECK(cleanedTrack(withCurve, std::nullopt).size() == 4);
}

static void testConstraintAndEventTimelinesUseTheirOwnSections() {
    Fixture f = makeFixture();
    IKConstraint ik("Arm IK", {f.childBoneID}, f.rootBoneID);
    f.scene.skeleton.ikConstraints.push_back(ik);

    AnimationEvent event;
    event.name = "footstep";
    f.scene.animationEvents.push_back(event);

    UMJsonAnimationSource source;
    source.name = "Walk";
    source.sceneClip = AnimationClip(
        "Scene", 24,
        {AnimationTrack(
             ik.id_, AnimationTrackProperty::ConstraintMix, {Keyframe(0, ScalarValue{0.5f})}),
         AnimationTrack(
             event.id, AnimationTrackProperty::Event,
             {Keyframe(6, EventValue{AnimationEventPayload{7, std::nullopt, std::nullopt}})}),
         AnimationTrack(
             SceneAnimationTarget::drawOrder(), AnimationTrackProperty::DrawOrder,
             {Keyframe(3, DrawOrderValue{{f.imageID}})})});

    const UMJsonDocument doc = buildUMJsonDocument(f.scene, f.assets, {source});
    const UMJsonAnimation& a = doc.animations[0];

    UM_CHECK(a.constraints.size() == 1);
    UM_CHECK(a.constraints[0].constraint == ik.id_.toString());
    UM_CHECK(a.constraints[0].properties.size() == 1);
    UM_CHECK(a.constraints[0].properties[0].property == "constraintMix");

    UM_CHECK(a.events.size() == 1);
    UM_CHECK(a.events[0].event == event.id.toString());
    UM_CHECK(a.events[0].keys[0].frame == 6);
    UM_CHECK(a.events[0].keys[0].intValue.has_value() && *a.events[0].keys[0].intValue == 7);
    // Unset overrides stay absent: absent means "inherit the definition's
    // default", which is not the same as 0 or "".
    UM_CHECK(!a.events[0].keys[0].floatValue.has_value());
    UM_CHECK(!a.events[0].keys[0].stringValue.has_value());

    UM_CHECK(a.drawOrder.size() == 1);
    UM_CHECK(a.drawOrder[0].frame == 3);
    UM_CHECK(a.drawOrder[0].order.size() == 1);
}

static void testRenderedTextIsValidJsonAndDeterministic() {
    Fixture f = makeFixture();
    const UMJsonDocument doc = buildUMJsonDocument(f.scene, f.assets, {});

    const std::string pretty = writeUMJson(doc);
    UMJsonExportOptions compact;
    compact.prettyPrint = false;
    const std::string dense = writeUMJson(doc, compact);

    UM_CHECK(dense.size() < pretty.size());
    // Both parse, and the same document renders identically twice.
    const JsonValue parsed = JsonValue::parse(pretty);
    UM_CHECK(parsed.find("format")->asString() == "UltraMesh");
    UM_CHECK(writeUMJson(doc) == pretty);
}

static void testFloatPrecisionRoundsAtTheChokePoint() {
    Fixture f = makeFixture();
    Bone bone = f.scene.skeleton.bones().at(f.rootBoneID);
    bone.length = 1.23456789f;
    f.scene.skeleton.setBone(bone);

    UMJsonExportOptions coarse;
    coarse.floatPrecision = 2;
    const UMJsonDocument doc = buildUMJsonDocument(f.scene, f.assets, {}, coarse);
    UM_CHECK_NEAR(doc.bones[0].length, 1.23, 1e-6);
}

static void testAnimationSourceFromNamedAnimation() {
    NamedAnimation animation;
    animation.name = "Run";
    animation.duration = 30;
    animation.sceneClip = AnimationClip("Scene", 30);
    const Uuid boneID = Uuid::generate();
    animation.boneClips[boneID] = AnimationClip("bone", 30);

    const UMJsonAnimationSource source = animationSourceFrom(animation);
    UM_CHECK(source.name == "Run");
    UM_CHECK(source.duration == 30);
    UM_CHECK(source.boneClips.size() == 1);
    UM_CHECK(source.sceneClip.durationInFrames == 30);
}

UM_TEST_MAIN_BEGIN()
    testDocumentHeaderAndMetadata();
    testNonessentialDataStripsEditorOnlyValues();
    testBonesAreInDeterministicOrderWithRootFlagged();
    testDepthBlockOnlyAppearsWhenThereIsRealDepth();
    testAttachmentOmitsNeutralTintAndNormalBlend();
    testBoundAttachmentReportsBoneLocalSpace();
    testMeshIsFlattenedAndSkinningOmittedWhenUnweighted();
    testSkinnedMeshEmitsSortedWeightsAndMatrices();
    testSkinSlotsKeepDeliberatelyEmptyEntries();
    testInterpolationIsSpelledSteppedNotHold();
    testDeformKeysAreAbsoluteAndNeverClaimBezier();
    testDeformKeysWithMismatchedVertexCountAreDropped();
    testCleanupKeepsAConstantTrackThatDiffersFromSetup();
    testCleanupDropsInteriorKeysButKeepsEndpointsAndCurves();
    testConstraintAndEventTimelinesUseTheirOwnSections();
    testRenderedTextIsValidJsonAndDeterministic();
    testFloatPrecisionRoundsAtTheChokePoint();
    testAnimationSourceFromNamedAnimation();
UM_TEST_MAIN_END()
