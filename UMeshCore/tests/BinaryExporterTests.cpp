// Tests for Serialization/BinaryExporter.h, ported/derived from
// `Export/BinaryExporter.swift`. Since the Swift app has no reader for this
// format (see UMeshBinaryFormat.h's file header), these tests build a scene,
// export it, and read it back with BinaryReader -- exact byte layout is
// verified against the Swift source's write order field-by-field, not
// against a golden file.

#include "umeshcore/Serialization/BinaryExporter.h"

#include <cstdio>
#include <fstream>

#include "umeshcore/Serialization/BinaryReader.h"
#include "TestHarness.h"

using namespace umeshcore;

namespace {

Bone makeBone(std::optional<Uuid> parent, Vec2 localPos, float rotationZ, float length) {
    Bone b;
    b.id = Uuid::generate();
    b.name = "bone";
    b.parentID = parent;
    b.localTransform.position = Vec3(localPos.x, localPos.y, 0);
    b.localTransform.rotation = Vec3(0, 0, rotationZ);
    b.baseTransform = b.localTransform;
    b.length = length;
    b.animationClip = AnimationClip("bone");
    return b;
}

Mesh makeTestMesh(const Uuid& boneID) {
    Mesh mesh("quadMesh");
    mesh.vertices = {Vec2(-10, 10), Vec2(10, 10), Vec2(-10, -10), Vec2(10, -10)};
    mesh.uvs = {Vec2(0, 0), Vec2(1, 0), Vec2(0, 1), Vec2(1, 1)};
    mesh.indices = {0, 1, 2, 2, 1, 3};
    mesh.hullVertexIndices = {0, 1, 3, 2};
    mesh.internalEdges = {MeshEdge(0, 3)};
    mesh.manualTriangles = {MeshTriangle{0, 1, 2}};
    mesh.bindVertices = mesh.vertices;
    for (int i = 0; i < 4; ++i) mesh.vertexBoneWeights.push_back({VertexBoneWeight{boneID, 1.0f}});
    mesh.boneInverseBindMatrices[boneID] = Mat4::identity();
    return mesh;
}

// Builds a small but non-trivial scene: 2 bones (root + child), 2 sprites
// (one bound to the root bone with a full animation clip including a
// meshDeform and an attachment track, one unbound referencing a missing
// asset), and animation tracks on both bones (translate w/ tangents, event,
// drawOrder) covering every KeyframeValue case.
struct TestFixture {
    EditorScene scene;
    Uuid rootBoneID;
    Uuid childBoneID;
    Uuid image1ID;
    Uuid image2ID;
    Uuid foundAssetID = Uuid::generate();
    Uuid missingAssetID = Uuid::generate();
    std::unordered_map<Uuid, AssetRecord, UuidHash> assets;
};

TestFixture makeFixture() {
    TestFixture f;

    Bone root = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    Bone child = makeBone(root.id, Vec2(100, 0), 0.5f, 60.0f);
    f.rootBoneID = root.id;
    f.childBoneID = child.id;

    root.animationClip.setTracks({AnimationTrack(
        root.id, AnimationTrackProperty::Translate,
        {Keyframe(
            0, TranslateValue{Vec2(1, 2)}, KeyframeInterpolation::Bezier, Vec2(0.1f, 0.2f),
            Vec2(0.3f, 0.4f), Vec2(0.5f, 0.6f), Vec2(0.7f, 0.8f))})});

    const Uuid drawOrderA = Uuid::generate();
    const Uuid drawOrderB = Uuid::generate();
    child.animationClip.setTracks(
        {AnimationTrack(
             child.id, AnimationTrackProperty::Event,
             {Keyframe(5, EventValue{AnimationEventPayload{42, std::nullopt, std::string("boom")}})}),
         AnimationTrack(
             child.id, AnimationTrackProperty::DrawOrder,
             {Keyframe(10, DrawOrderValue{{drawOrderA, drawOrderB}})})});

    f.scene.skeleton.setBone(root);
    f.scene.skeleton.setBone(child);
    f.scene.skeleton.rootIDs.push_back(root.id);

    SceneImage image1;
    image1.id = Uuid::generate();
    image1.name = "hero_body";
    image1.assetID = f.foundAssetID;
    image1.mesh = makeTestMesh(root.id);
    image1.animationClip = AnimationClip("sprite1");
    BoneImageBinding binding;
    binding.boneID = root.id;
    binding.localPosition = Vec2(1, 2);
    image1.boneBinding = binding;
    image1.animationTransformSpace = TransformAnimationSpace::boneLocal(root.id);
    image1.animationClip.setTracks(
        {AnimationTrack(
             image1.id, AnimationTrackProperty::MeshDeform,
             {Keyframe(
                 0,
                 MeshDeformValue{{Vec2(0.1f, 0.1f), Vec2(-0.1f, 0.1f), Vec2(0.1f, -0.1f), Vec2(-0.1f, -0.1f)}},
                 KeyframeInterpolation::Linear)}),
         AnimationTrack(
             image1.id, AnimationTrackProperty::Attachment,
             {Keyframe(0, AttachmentValue{drawOrderA})})});
    f.image1ID = image1.id;

    SceneImage image2;
    image2.id = Uuid::generate();
    image2.name = "missing_asset_sprite";
    image2.assetID = f.missingAssetID;
    image2.isHidden = true;
    image2.animationClip = AnimationClip("sprite2");
    f.image2ID = image2.id;

    f.scene.images = {image1, image2};
    f.scene.playbackStartFrame = 3;
    f.scene.playbackEndFrame = 120;

    AssetRecord found;
    found.id = f.foundAssetID;
    found.name = "hero_body";
    found.filePath = "/some/project/assets/hero_body.png";
    found.size = Vec2(256, 256);
    f.assets[f.foundAssetID] = found;
    // f.missingAssetID intentionally left out of the map.

    return f;
}

} // namespace

static void testHeaderAndChunkCountExcludesScenes() {
    TestFixture f = makeFixture();
    BinaryExporter exporter;
    const std::vector<std::uint8_t> blob = exporter.exportScene(f.scene, f.assets);

    BinaryReader reader(blob);
    const auto header = reader.readFileHeader();
    UM_CHECK(header.magic == UMeshBinaryFormat::magic);
    UM_CHECK(header.version == UMeshBinaryFormat::version);
    UM_CHECK(header.flags == 0); // reference mode -> no embeddedTextures flag.
    // META, ASSETS, SKELETON, IMAGES, MESHES, ANIMATIONS -- no SCENES.
    UM_CHECK(header.chunkCount == 6);
    UM_CHECK(header.payloadSize == reader.remaining());
}

static void testMetaChunkRoundTrips() {
    TestFixture f = makeFixture();
    BinaryExportOptions options;
    options.prettyName = "MyProject";
    BinaryExporter exporter(options);
    const std::vector<std::uint8_t> blob = exporter.exportScene(f.scene, f.assets);

    BinaryReader reader(blob);
    (void)reader.readFileHeader();
    const auto chunk = reader.readChunkHeader();
    UM_CHECK(chunk.type == static_cast<std::uint32_t>(UMeshBinaryFormat::ChunkID::Meta));

    UM_CHECK(reader.readU16() == UMeshBinaryFormat::ChunkVersion::meta);
    UM_CHECK(reader.readString() == "MyProject");
    (void)reader.readF32(); // timestamp, non-deterministic.
    // End frame is written before start frame (matches the Swift source).
    UM_CHECK(reader.readU32() == 120);
    UM_CHECK(reader.readU32() == 3);
}

static void testAssetsChunkFoundAndMissingRoundTrip() {
    TestFixture f = makeFixture();
    BinaryExporter exporter;
    const std::vector<std::uint8_t> blob = exporter.exportScene(f.scene, f.assets);

    BinaryReader reader(blob);
    (void)reader.readFileHeader();
    (void)reader.readChunkHeader(); // META
    reader.skip(reader.count() == 0 ? 0 : 0); // no-op, keep structure explicit below.

    // Re-parse from scratch, skipping META by its size instead of re-reading it.
    BinaryReader r2(blob);
    (void)r2.readFileHeader();
    const auto metaChunk = r2.readChunkHeader();
    r2.skip(metaChunk.size);

    const auto assetsChunk = r2.readChunkHeader();
    UM_CHECK(assetsChunk.type == static_cast<std::uint32_t>(UMeshBinaryFormat::ChunkID::Assets));
    UM_CHECK(r2.readU16() == UMeshBinaryFormat::ChunkVersion::assets);
    UM_CHECK(r2.readU32() == 2); // two distinct assetIDs referenced by images.

    // image1 -> foundAssetID (found).
    UM_CHECK(r2.readUuid() == f.foundAssetID);
    UM_CHECK(r2.readU8() == 1); // found
    UM_CHECK(r2.readString() == "hero_body");
    const Vec2 size = r2.readVec2();
    UM_CHECK_NEAR(size.x, 256.0, 1e-6);
    UM_CHECK(r2.readU32() == 0); // reference mode -> zero embedded bytes.
    UM_CHECK(r2.readString() == "hero_body.png"); // lastPathComponent.

    // image2 -> missingAssetID (not found).
    UM_CHECK(r2.readUuid() == f.missingAssetID);
    UM_CHECK(r2.readU8() == 0); // found = false, no further fields for this record.
}

static void testAssetsChunkEmbedModeInlinesBytes() {
    TestFixture f = makeFixture();

    const std::string tempPath = "binary_exporter_test_asset.bin";
    const std::vector<std::uint8_t> fileBytes = {0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x03};
    {
        std::ofstream out(tempPath, std::ios::binary);
        out.write(reinterpret_cast<const char*>(fileBytes.data()), static_cast<std::streamsize>(fileBytes.size()));
    }
    f.assets[f.foundAssetID].filePath = tempPath;

    BinaryExportOptions options;
    options.textureEmbedMode = TextureEmbedMode::Embed;
    BinaryExporter exporter(options);
    const std::vector<std::uint8_t> blob = exporter.exportScene(f.scene, f.assets);
    std::remove(tempPath.c_str());

    BinaryReader reader(blob);
    const auto header = reader.readFileHeader();
    UM_CHECK(header.flags == static_cast<std::uint16_t>(UMeshBinaryFormat::HeaderFlag::EmbeddedTextures));

    const auto metaChunk = reader.readChunkHeader();
    reader.skip(metaChunk.size);
    const auto assetsChunk = reader.readChunkHeader();
    (void)assetsChunk;
    UM_CHECK(reader.readU16() == UMeshBinaryFormat::ChunkVersion::assets);
    UM_CHECK(reader.readU32() == 2);

    UM_CHECK(reader.readUuid() == f.foundAssetID);
    UM_CHECK(reader.readU8() == 1);
    UM_CHECK(reader.readString() == "hero_body");
    (void)reader.readVec2();
    const std::uint32_t byteCount = reader.readU32();
    UM_CHECK(byteCount == fileBytes.size());
    const auto payload = reader.readBytes(byteCount);
    UM_CHECK(payload == fileBytes);
}

static void testSkeletonChunkRoundTrips() {
    TestFixture f = makeFixture();
    BinaryExporter exporter;
    const std::vector<std::uint8_t> blob = exporter.exportScene(f.scene, f.assets);

    BinaryReader reader(blob);
    (void)reader.readFileHeader();
    const auto metaChunk = reader.readChunkHeader();
    reader.skip(metaChunk.size);
    const auto assetsChunk = reader.readChunkHeader();
    reader.skip(assetsChunk.size);

    const auto skeletonChunk = reader.readChunkHeader();
    UM_CHECK(skeletonChunk.type == static_cast<std::uint32_t>(UMeshBinaryFormat::ChunkID::Skeleton));
    UM_CHECK(reader.readU16() == UMeshBinaryFormat::ChunkVersion::skeleton);
    UM_CHECK(reader.readU32() == 2); // root + child, DFS order -> root first.

    // Root bone.
    UM_CHECK(reader.readUuid() == f.rootBoneID);
    UM_CHECK(reader.readString() == "bone");
    UM_CHECK(reader.readBool() == false); // no parent.
    (void)reader.readVec3(); (void)reader.readVec3(); (void)reader.readVec3(); (void)reader.readVec2(); // baseTransform
    (void)reader.readVec3(); (void)reader.readVec3(); (void)reader.readVec3(); (void)reader.readVec2(); // localTransform
    UM_CHECK_NEAR(reader.readF32(), 100.0, 1e-6); // length
    const Vec4 rootColor = reader.readVec4();
    UM_CHECK_NEAR(rootColor.x, 0.55, 1e-6); // unbound-bone fallback color.

    // Child bone.
    UM_CHECK(reader.readUuid() == f.childBoneID);
    UM_CHECK(reader.readString() == "bone");
    UM_CHECK(reader.readBool() == true);
    UM_CHECK(reader.readUuid() == f.rootBoneID);
    (void)reader.readVec3(); (void)reader.readVec3(); (void)reader.readVec3(); (void)reader.readVec2();
    (void)reader.readVec3(); (void)reader.readVec3(); (void)reader.readVec3(); (void)reader.readVec2();
    UM_CHECK_NEAR(reader.readF32(), 60.0, 1e-6);
    (void)reader.readVec4();

    UM_CHECK(reader.readU32() == 1); // one root id.
    UM_CHECK(reader.readUuid() == f.rootBoneID);
}

static void testImagesChunkFlagsAndBoneBindingRoundTrip() {
    TestFixture f = makeFixture();
    BinaryExporter exporter;
    const std::vector<std::uint8_t> blob = exporter.exportScene(f.scene, f.assets);

    BinaryReader reader(blob);
    (void)reader.readFileHeader();
    for (auto id : {UMeshBinaryFormat::ChunkID::Meta, UMeshBinaryFormat::ChunkID::Assets,
                     UMeshBinaryFormat::ChunkID::Skeleton}) {
        const auto chunk = reader.readChunkHeader();
        UM_CHECK(chunk.type == static_cast<std::uint32_t>(id));
        reader.skip(chunk.size);
    }

    const auto imagesChunk = reader.readChunkHeader();
    UM_CHECK(imagesChunk.type == static_cast<std::uint32_t>(UMeshBinaryFormat::ChunkID::Images));
    UM_CHECK(reader.readU16() == UMeshBinaryFormat::ChunkVersion::images);
    UM_CHECK(reader.readU32() == 2);

    // image1: bound to root bone, boneLocal animation space, not hidden.
    UM_CHECK(reader.readUuid() == f.image1ID);
    UM_CHECK(reader.readUuid() == f.foundAssetID);
    UM_CHECK(reader.readString() == "hero_body");
    (void)reader.readVec2(); (void)reader.readF32(); (void)reader.readVec2(); (void)reader.readVec2(); (void)reader.readVec3();
    const std::uint8_t flags1 = reader.readU8();
    UM_CHECK((flags1 & UMeshBinaryFormat::ImageFlags::hasBoneBinding) != 0);
    UM_CHECK((flags1 & UMeshBinaryFormat::ImageFlags::isHidden) == 0);
    UM_CHECK((flags1 & UMeshBinaryFormat::ImageFlags::boneLocalSpace) != 0);
    UM_CHECK(reader.readUuid() == f.rootBoneID); // binding.boneID
    const Vec2 localPos = reader.readVec2();
    UM_CHECK_NEAR(localPos.x, 1.0, 1e-6);
    (void)reader.readVec2(); (void)reader.readF32(); (void)reader.readVec2(); // localScale/localRotation/localSkew
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::AnimationSpaceCode::BoneLocal));
    UM_CHECK(reader.readUuid() == f.rootBoneID);

    // image2: unbound, hidden, world animation space.
    UM_CHECK(reader.readUuid() == f.image2ID);
    UM_CHECK(reader.readUuid() == f.missingAssetID);
    UM_CHECK(reader.readString() == "missing_asset_sprite");
    (void)reader.readVec2(); (void)reader.readF32(); (void)reader.readVec2(); (void)reader.readVec2(); (void)reader.readVec3();
    const std::uint8_t flags2 = reader.readU8();
    UM_CHECK((flags2 & UMeshBinaryFormat::ImageFlags::hasBoneBinding) == 0);
    UM_CHECK((flags2 & UMeshBinaryFormat::ImageFlags::isHidden) != 0);
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::AnimationSpaceCode::World));
}

static void testMeshesChunkRoundTrips() {
    TestFixture f = makeFixture();
    BinaryExporter exporter;
    const std::vector<std::uint8_t> blob = exporter.exportScene(f.scene, f.assets);

    BinaryReader reader(blob);
    (void)reader.readFileHeader();
    for (auto id : {UMeshBinaryFormat::ChunkID::Meta, UMeshBinaryFormat::ChunkID::Assets,
                     UMeshBinaryFormat::ChunkID::Skeleton, UMeshBinaryFormat::ChunkID::Images}) {
        const auto chunk = reader.readChunkHeader();
        UM_CHECK(chunk.type == static_cast<std::uint32_t>(id));
        reader.skip(chunk.size);
    }

    const auto meshesChunk = reader.readChunkHeader();
    UM_CHECK(meshesChunk.type == static_cast<std::uint32_t>(UMeshBinaryFormat::ChunkID::Meshes));
    UM_CHECK(reader.readU16() == UMeshBinaryFormat::ChunkVersion::meshes);
    UM_CHECK(reader.readU32() == 2); // one mesh per image, including the empty default mesh on image2.

    // image1's mesh.
    UM_CHECK(reader.readUuid() == f.image1ID);
    (void)reader.readUuid(); // mesh.id
    UM_CHECK(reader.readString() == "quadMesh");
    const auto vertices = reader.readVec2Array();
    UM_CHECK(vertices.size() == 4);
    const auto uvs = reader.readVec2Array();
    UM_CHECK(uvs.size() == 4);
    const auto indices = reader.readU16Array();
    UM_CHECK(indices.size() == 6);
    const auto hull = reader.readU16Array();
    UM_CHECK(hull.size() == 4);
    UM_CHECK(reader.readU32() == 1); // internalEdges
    UM_CHECK(reader.readU16() == 0);
    UM_CHECK(reader.readU16() == 3);
    UM_CHECK(reader.readU32() == 1); // manualTriangles
    UM_CHECK(reader.readU16() == 0);
    UM_CHECK(reader.readU16() == 1);
    UM_CHECK(reader.readU16() == 2);
    const auto bindVertices = reader.readVec2Array();
    UM_CHECK(bindVertices.size() == 4);
    UM_CHECK(reader.readU32() == 4); // vertexBoneWeights, one influence list per vertex.
    for (int i = 0; i < 4; ++i) {
        UM_CHECK(reader.readU8() == 1); // one influence
        UM_CHECK(reader.readUuid() == f.rootBoneID);
        UM_CHECK_NEAR(reader.readF32(), 1.0, 1e-6);
    }
    UM_CHECK(reader.readU32() == 1); // boneInverseBindMatrices
    UM_CHECK(reader.readUuid() == f.rootBoneID);
    const Mat4 inverseBind = reader.readMat4();
    UM_CHECK_NEAR(inverseBind.columns[0].x, 1.0, 1e-6);
}

static void testAnimationsChunkMeshDeformFixRoundTrips() {
    TestFixture f = makeFixture();
    BinaryExporter exporter;
    const std::vector<std::uint8_t> blob = exporter.exportScene(f.scene, f.assets);

    BinaryReader reader(blob);
    (void)reader.readFileHeader();
    for (auto id : {UMeshBinaryFormat::ChunkID::Meta, UMeshBinaryFormat::ChunkID::Assets,
                     UMeshBinaryFormat::ChunkID::Skeleton, UMeshBinaryFormat::ChunkID::Images,
                     UMeshBinaryFormat::ChunkID::Meshes}) {
        const auto chunk = reader.readChunkHeader();
        UM_CHECK(chunk.type == static_cast<std::uint32_t>(id));
        reader.skip(chunk.size);
    }

    const auto animChunk = reader.readChunkHeader();
    UM_CHECK(animChunk.type == static_cast<std::uint32_t>(UMeshBinaryFormat::ChunkID::Animations));
    UM_CHECK(reader.readU16() == UMeshBinaryFormat::ChunkVersion::animations);
    UM_CHECK(UMeshBinaryFormat::ChunkVersion::animations == 2); // the meshDeform-fix version.

    // Clips: bones-with-tracks (root, child) first, then images-with-tracks (image1 only).
    UM_CHECK(reader.readU32() == 3);

    // --- Root bone clip: one Translate track, one Bezier keyframe with all 4 tangents. ---
    UM_CHECK(reader.readUuid() == f.rootBoneID);
    (void)reader.readUuid(); // clip id
    UM_CHECK(reader.readString() == "bone");
    (void)reader.readU32(); // durationInFrames
    UM_CHECK(reader.readU32() == 1); // one track
    (void)reader.readUuid(); // track id
    UM_CHECK(reader.readUuid() == f.rootBoneID); // targetID
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::TrackPropertyCode::Translate));
    UM_CHECK(reader.readU32() == 1); // one keyframe
    (void)reader.readUuid(); // keyframe id
    UM_CHECK(reader.readI32() == 0); // frame
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::InterpCode::Bezier));
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::Translate));
    const Vec2 translateValue = reader.readVec2();
    UM_CHECK_NEAR(translateValue.x, 1.0, 1e-6);
    const std::uint8_t tangentFlags = reader.readU8();
    UM_CHECK(tangentFlags == 0b1111); // all four tangents present.
    const Vec2 inT = reader.readVec2();
    UM_CHECK_NEAR(inT.x, 0.1, 1e-6);
    (void)reader.readVec2(); (void)reader.readVec2(); (void)reader.readVec2();

    // --- Child bone clip: Event track then DrawOrder track, both forced to Hold. ---
    UM_CHECK(reader.readUuid() == f.childBoneID);
    (void)reader.readUuid();
    UM_CHECK(reader.readString() == "bone");
    (void)reader.readU32();
    UM_CHECK(reader.readU32() == 2);

    (void)reader.readUuid();
    UM_CHECK(reader.readUuid() == f.childBoneID);
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::TrackPropertyCode::Event));
    UM_CHECK(reader.readU32() == 1);
    (void)reader.readUuid();
    UM_CHECK(reader.readI32() == 5);
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::InterpCode::Hold)); // forced.
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::Event));
    UM_CHECK(reader.readU8() == 1); // has int
    UM_CHECK(reader.readI32() == 42);
    UM_CHECK(reader.readU8() == 0); // no float
    UM_CHECK_NEAR(reader.readF32(), 0.0, 1e-6);
    UM_CHECK(reader.readString() == "boom");
    UM_CHECK(reader.readU8() == 0); // no tangents on a Hold keyframe.

    (void)reader.readUuid();
    UM_CHECK(reader.readUuid() == f.childBoneID);
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::TrackPropertyCode::DrawOrder));
    UM_CHECK(reader.readU32() == 1);
    (void)reader.readUuid();
    UM_CHECK(reader.readI32() == 10);
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::InterpCode::Hold));
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::DrawOrder));
    UM_CHECK(reader.readI32() == 2); // drawOrder count is written as i32, matching the Swift source.
    (void)reader.readUuid(); (void)reader.readUuid();
    UM_CHECK(reader.readU8() == 0);

    // --- image1 clip: MeshDeform track (the fixed case) then Attachment track. ---
    UM_CHECK(reader.readUuid() == f.image1ID);
    (void)reader.readUuid();
    UM_CHECK(reader.readString() == "sprite1");
    (void)reader.readU32();
    UM_CHECK(reader.readU32() == 2);

    (void)reader.readUuid();
    UM_CHECK(reader.readUuid() == f.image1ID);
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::TrackPropertyCode::MeshDeform));
    UM_CHECK(reader.readU32() == 1);
    (void)reader.readUuid();
    UM_CHECK(reader.readI32() == 0);
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::InterpCode::Linear));
    // This is the fix: a real discriminant + payload, not zero bytes.
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::MeshDeform));
    const auto offsets = reader.readVec2Array();
    UM_CHECK(offsets.size() == 4);
    UM_CHECK_NEAR(offsets[0].x, 0.1, 1e-6);
    UM_CHECK_NEAR(offsets[3].y, -0.1, 1e-6);
    UM_CHECK(reader.readU8() == 0); // no tangents.

    (void)reader.readUuid();
    UM_CHECK(reader.readUuid() == f.image1ID);
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::TrackPropertyCode::Attachment));
    UM_CHECK(reader.readU32() == 1);
    (void)reader.readUuid();
    UM_CHECK(reader.readI32() == 0);
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::InterpCode::Hold));
    UM_CHECK(reader.readU8() == static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::Attachment));
    UM_CHECK(reader.readU8() == 1); // has id
    (void)reader.readUuid();
    UM_CHECK(reader.readU8() == 0);

    UM_CHECK(reader.atEnd());
}

UM_TEST_MAIN_BEGIN()
    testHeaderAndChunkCountExcludesScenes();
    testMetaChunkRoundTrips();
    testAssetsChunkFoundAndMissingRoundTrip();
    testAssetsChunkEmbedModeInlinesBytes();
    testSkeletonChunkRoundTrips();
    testImagesChunkFlagsAndBoneBindingRoundTrip();
    testMeshesChunkRoundTrips();
    testAnimationsChunkMeshDeformFixRoundTrips();
UM_TEST_MAIN_END()
