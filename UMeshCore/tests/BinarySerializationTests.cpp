// Tests for Serialization/UMeshBinaryFormat.h, BinaryWriter.h and
// BinaryReader.h -- ported/derived from `Export/UMeshBinaryFormat.swift` and
// `Export/BinaryWriter.swift` (see UMeshBinaryFormat.h's file header: this
// is a *format*, and BinaryReader is new code with no Swift counterpart).
//
// Wire-code expected values are hand-checked against
// `UMeshBinaryFormat.swift`'s literal `case ... = N` numbers, not derived
// from this port itself.

#include "umeshcore/Serialization/BinaryReader.h"
#include "umeshcore/Serialization/BinaryWriter.h"
#include "umeshcore/Serialization/UMeshBinaryFormat.h"
#include "TestHarness.h"

using namespace umeshcore;

static void testFourCCAndMagic() {
    // 'U'=0x55 'M'=0x4D 'S'=0x53 'H'=0x48 -> little-endian UInt32 0x48534D55.
    UM_CHECK(UMeshBinaryFormat::magic == 0x48534D55u);
    UM_CHECK(UMeshBinaryFormat::fourCC('U', 'M', 'S', 'H') == UMeshBinaryFormat::magic);
    UM_CHECK(UMeshBinaryFormat::version == ((1 << 8) | 0));
}

static void testChunkIDValuesMatchSwiftLiterals() {
    using ID = UMeshBinaryFormat::ChunkID;
    UM_CHECK(static_cast<std::uint32_t>(ID::Meta) == 0x4154454Du);
    UM_CHECK(static_cast<std::uint32_t>(ID::Assets) == 0x53544144u);
    UM_CHECK(static_cast<std::uint32_t>(ID::Skeleton) == 0x4C454B53u);
    UM_CHECK(static_cast<std::uint32_t>(ID::Images) == 0x53474D49u);
    UM_CHECK(static_cast<std::uint32_t>(ID::Meshes) == 0x4853454Du);
    UM_CHECK(static_cast<std::uint32_t>(ID::Animations) == 0x4D494E41u);
    UM_CHECK(static_cast<std::uint32_t>(ID::Scenes) == 0x4E454353u);
}

static void testTrackPropertyWireCodesMatchSwiftLiterals() {
    using P = AnimationTrackProperty;
    using C = UMeshBinaryFormat::TrackPropertyCode;

    // Spot-check every code against Swift's literal numbers (append-only,
    // interspersed with the C++ enum's own declaration order -- see the
    // header's warning against static_cast).
    UM_CHECK(UMeshBinaryFormat::toWireCode(P::Translate) == C::Translate);
    UM_CHECK(static_cast<int>(C::Translate) == 0);
    UM_CHECK(static_cast<int>(UMeshBinaryFormat::toWireCode(P::MeshDeform)) == 4);
    UM_CHECK(static_cast<int>(UMeshBinaryFormat::toWireCode(P::ConstraintMix)) == 5);
    UM_CHECK(static_cast<int>(UMeshBinaryFormat::toWireCode(P::PhysicsWind)) == 23);
    UM_CHECK(static_cast<int>(UMeshBinaryFormat::toWireCode(P::DrawOrder)) == 24);
    UM_CHECK(static_cast<int>(UMeshBinaryFormat::toWireCode(P::Event)) == 25);
    UM_CHECK(static_cast<int>(UMeshBinaryFormat::toWireCode(P::CameraTranslate)) == 26);
    UM_CHECK(static_cast<int>(UMeshBinaryFormat::toWireCode(P::CameraFOV)) == 30);
    UM_CHECK(static_cast<int>(UMeshBinaryFormat::toWireCode(P::Attachment)) == 31);
    UM_CHECK(static_cast<int>(UMeshBinaryFormat::toWireCode(P::LightTranslate)) == 32);
    UM_CHECK(static_cast<int>(UMeshBinaryFormat::toWireCode(P::LightColorB)) == 41);

    // Every real case (excluding the Count sentinel) round-trips through
    // toWireCode/fromWireCode back to itself.
    for (AnimationTrackProperty p : allAnimationTrackProperties()) {
        const auto code = UMeshBinaryFormat::toWireCode(p);
        const auto back = UMeshBinaryFormat::fromWireCode(code);
        UM_CHECK(back.has_value() && *back == p);
    }
}

static void testInterpCodeRoundTrips() {
    for (auto interp :
         {KeyframeInterpolation::Hold, KeyframeInterpolation::Linear, KeyframeInterpolation::Bezier}) {
        const auto code = UMeshBinaryFormat::toWireCode(interp);
        const auto back = UMeshBinaryFormat::fromWireCode(code);
        UM_CHECK(back.has_value() && *back == interp);
    }
    UM_CHECK(static_cast<int>(UMeshBinaryFormat::InterpCode::Hold) == 0);
    UM_CHECK(static_cast<int>(UMeshBinaryFormat::InterpCode::Linear) == 1);
    UM_CHECK(static_cast<int>(UMeshBinaryFormat::InterpCode::Bezier) == 2);
}

static void testKeyframeFlagsBitmask() {
    UMeshBinaryFormat::KeyframeFlags flags;
    UM_CHECK(!flags.contains(UMeshBinaryFormat::KeyframeFlags::inTangent));
    flags.insert(UMeshBinaryFormat::KeyframeFlags::inTangent);
    flags.insert(UMeshBinaryFormat::KeyframeFlags::secondaryOutTangent);
    UM_CHECK(flags.contains(UMeshBinaryFormat::KeyframeFlags::inTangent));
    UM_CHECK(!flags.contains(UMeshBinaryFormat::KeyframeFlags::outTangent));
    UM_CHECK(flags.contains(UMeshBinaryFormat::KeyframeFlags::secondaryOutTangent));
    UM_CHECK(flags.rawValue == 0b1001);
}

static void testImageFlagsBitmask() {
    UMeshBinaryFormat::ImageFlags flags(
        UMeshBinaryFormat::ImageFlags::hasBoneBinding | UMeshBinaryFormat::ImageFlags::boneLocalSpace);
    UM_CHECK(flags.contains(UMeshBinaryFormat::ImageFlags::hasBoneBinding));
    UM_CHECK(!flags.contains(UMeshBinaryFormat::ImageFlags::isHidden));
    UM_CHECK(flags.contains(UMeshBinaryFormat::ImageFlags::boneLocalSpace));
}

static void testWriterReaderRoundTripsScalars() {
    BinaryWriter writer;
    writer.writeU8(0xAB);
    writer.writeU16(0xBEEF);
    writer.writeU32(0xDEADBEEF);
    writer.writeU64(0x0123456789ABCDEFULL);
    writer.writeI32(-12345);
    writer.writeF32(3.14159f);
    writer.writeBool(true);
    writer.writeBool(false);
    writer.writeString("hello, umesh");

    BinaryReader reader(writer.data());
    UM_CHECK(reader.readU8() == 0xAB);
    UM_CHECK(reader.readU16() == 0xBEEF);
    UM_CHECK(reader.readU32() == 0xDEADBEEF);
    UM_CHECK(reader.readU64() == 0x0123456789ABCDEFULL);
    UM_CHECK(reader.readI32() == -12345);
    UM_CHECK_NEAR(reader.readF32(), 3.14159f, 1e-6);
    UM_CHECK(reader.readBool() == true);
    UM_CHECK(reader.readBool() == false);
    UM_CHECK(reader.readString() == "hello, umesh");
    UM_CHECK(reader.atEnd());
}

static void testWriterReaderRoundTripsComposites() {
    BinaryWriter writer;
    const Uuid id = Uuid::generate();
    writer.writeUuid(id);
    writer.writeVec2(Vec2(1.5f, -2.5f));
    writer.writeVec3(Vec3(1.0f, 2.0f, 3.0f));
    writer.writeVec4(Vec4(1.0f, 2.0f, 3.0f, 4.0f));
    writer.writeMat4(Mat4::identity());

    const std::vector<Vec2> vecArray{Vec2(0, 0), Vec2(1, 1), Vec2(2, 4)};
    writer.writeVec2Array(vecArray);
    const std::vector<std::uint16_t> u16Array{1, 2, 3, 65535};
    writer.writeU16Array(u16Array);
    const std::vector<float> f32Array{0.5f, -0.5f, 100.0f};
    writer.writeF32Array(f32Array);

    BinaryReader reader(writer.data());
    UM_CHECK(reader.readUuid() == id);

    const Vec2 v2 = reader.readVec2();
    UM_CHECK_NEAR(v2.x, 1.5, 1e-6);
    UM_CHECK_NEAR(v2.y, -2.5, 1e-6);

    const Vec3 v3 = reader.readVec3();
    UM_CHECK_NEAR(v3.x, 1.0, 1e-6);
    UM_CHECK_NEAR(v3.z, 3.0, 1e-6);

    const Vec4 v4 = reader.readVec4();
    UM_CHECK_NEAR(v4.w, 4.0, 1e-6);

    const Mat4 m = reader.readMat4();
    UM_CHECK_NEAR(m.columns[0].x, 1.0, 1e-6);
    UM_CHECK_NEAR(m.columns[3].w, 1.0, 1e-6);

    const auto readVecArray = reader.readVec2Array();
    UM_CHECK(readVecArray.size() == 3);
    UM_CHECK_NEAR(readVecArray[2].y, 4.0, 1e-6);

    const auto readU16 = reader.readU16Array();
    UM_CHECK(readU16.size() == 4);
    UM_CHECK(readU16[3] == 65535);

    const auto readF32 = reader.readF32Array();
    UM_CHECK(readF32.size() == 3);
    UM_CHECK_NEAR(readF32[1], -0.5, 1e-6);

    UM_CHECK(reader.atEnd());
}

static void testChunkFramingPatchesSizeCorrectly() {
    BinaryWriter writer;
    const std::size_t offset = writer.openChunk(UMeshBinaryFormat::ChunkID::Meta);
    writer.writeU16(UMeshBinaryFormat::ChunkVersion::meta);
    writer.writeString("payload");
    writer.closeChunk(offset);

    BinaryReader reader(writer.data());
    const auto header = reader.readChunkHeader();
    UM_CHECK(header.type == static_cast<std::uint32_t>(UMeshBinaryFormat::ChunkID::Meta));
    // 2 (version) + 4 (string length) + 7 (string bytes) = 13.
    UM_CHECK(header.size == 13);
    UM_CHECK(reader.remaining() == header.size);

    const std::uint16_t version = reader.readU16();
    UM_CHECK(version == UMeshBinaryFormat::ChunkVersion::meta);
    UM_CHECK(reader.readString() == "payload");
    UM_CHECK(reader.atEnd());
}

static void testFileHeaderRoundTrip() {
    BinaryWriter writer;
    writer.writeU32(UMeshBinaryFormat::magic);
    writer.writeU16(UMeshBinaryFormat::version);
    writer.writeU16(static_cast<std::uint16_t>(UMeshBinaryFormat::HeaderFlag::EmbeddedTextures));
    const std::size_t chunkCountOffset = writer.count();
    writer.writeU32(0);
    const std::size_t payloadSizeOffset = writer.count();
    writer.writeU32(0);
    writer.writeU64(0); // reserved

    const std::size_t payloadStart = writer.count();
    std::uint32_t chunkCount = 0;
    const std::size_t chunkOffset = writer.openChunk(UMeshBinaryFormat::ChunkID::Meta);
    writer.writeU16(UMeshBinaryFormat::ChunkVersion::meta);
    writer.closeChunk(chunkOffset);
    chunkCount += 1;

    writer.patchU32(chunkCount, chunkCountOffset);
    writer.patchU32(static_cast<std::uint32_t>(writer.count() - payloadStart), payloadSizeOffset);

    BinaryReader reader(writer.data());
    const auto header = reader.readFileHeader();
    UM_CHECK(header.magic == UMeshBinaryFormat::magic);
    UM_CHECK(header.version == UMeshBinaryFormat::version);
    UM_CHECK(header.flags == static_cast<std::uint16_t>(UMeshBinaryFormat::HeaderFlag::EmbeddedTextures));
    UM_CHECK(header.chunkCount == 1);
    UM_CHECK(header.payloadSize == reader.remaining());

    const auto chunk = reader.readChunkHeader();
    UM_CHECK(chunk.type == static_cast<std::uint32_t>(UMeshBinaryFormat::ChunkID::Meta));
    UM_CHECK(chunk.size == 2);
    reader.skip(chunk.size);
    UM_CHECK(reader.atEnd());
}

static void testBadMagicThrows() {
    BinaryWriter writer;
    writer.writeU32(0xBADC0FFEu);
    bool threw = false;
    try {
        BinaryReader reader(writer.data());
        (void)reader.readFileHeader();
    } catch (const std::runtime_error&) {
        threw = true;
    }
    UM_CHECK(threw);
}

static void testTruncatedReadThrows() {
    BinaryWriter writer;
    writer.writeU16(42); // only 2 bytes available.
    BinaryReader reader(writer.data());
    bool threw = false;
    try {
        (void)reader.readU32(); // needs 4 bytes.
    } catch (const std::out_of_range&) {
        threw = true;
    }
    UM_CHECK(threw);
}

UM_TEST_MAIN_BEGIN()
    testFourCCAndMagic();
    testChunkIDValuesMatchSwiftLiterals();
    testTrackPropertyWireCodesMatchSwiftLiterals();
    testInterpCodeRoundTrips();
    testKeyframeFlagsBitmask();
    testImageFlagsBitmask();
    testWriterReaderRoundTripsScalars();
    testWriterReaderRoundTripsComposites();
    testChunkFramingPatchesSizeCorrectly();
    testFileHeaderRoundTrip();
    testBadMagicThrows();
    testTruncatedReadThrows();
UM_TEST_MAIN_END()
