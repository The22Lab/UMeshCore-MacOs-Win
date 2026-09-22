// Tests for Serialization/Sha256.h and Serialization/ProjectPackage.h --
// the `.umesh` package layer (directory + Assets/ + content dedup), ported
// from `Data/ProjectPersistence.swift`'s save/load/makeBundledAssets/
// resolvingAssetPaths. SHA-256 is checked against the published FIPS 180-4
// test vectors, not against this port's own output.
//
// These tests touch the filesystem, under a unique directory beneath the
// system temp dir, removed again at the end of each case.

#include "umeshcore/Serialization/ProjectPackage.h"

#include <filesystem>
#include <fstream>

#include "umeshcore/Serialization/Sha256.h"
#include "TestHarness.h"

namespace fs = std::filesystem;
using namespace umeshcore;

namespace {

fs::path makeScratchDir(const std::string& label) {
    const fs::path dir = fs::temp_directory_path() / ("umeshcore-" + label + "-" + Uuid::generate().toString());
    fs::create_directories(dir);
    return dir;
}

void writeBytes(const fs::path& path, const std::string& contents) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file.write(contents.data(), static_cast<std::streamsize>(contents.size()));
}

std::string readText(const fs::path& path) {
    std::ifstream file(path, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
}

AssetRecord makeAsset(const std::string& name, const fs::path& filePath) {
    AssetRecord asset;
    asset.id = Uuid::generate();
    asset.name = name;
    asset.filePath = filePath.string();
    return asset;
}

} // namespace

static void testSha256MatchesPublishedVectors() {
    // FIPS 180-4 / NIST published vectors.
    UM_CHECK(sha256Hex(std::string("")) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    UM_CHECK(sha256Hex(std::string("abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    UM_CHECK(
        sha256Hex(std::string("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")) ==
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    // Spans several blocks and exercises the two-block padding path.
    UM_CHECK(
        sha256Hex(std::string(1000000, 'a')) ==
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}

static void testSha256IsLengthSensitiveAtBlockBoundaries() {
    // 55/56/64 bytes are the padding edge cases (one block vs. two).
    UM_CHECK(sha256Hex(std::string(55, 'x')).size() == 64);
    UM_CHECK(sha256Hex(std::string(56, 'x')) != sha256Hex(std::string(55, 'x')));
    UM_CHECK(sha256Hex(std::string(64, 'x')) != sha256Hex(std::string(63, 'x')));
}

static void testSavesPackageDirectoryWithManifestAndAssets() {
    const fs::path scratch = makeScratchDir("save");
    const fs::path source = scratch / "body.png";
    writeBytes(source, "PNG-BODY-BYTES");

    ProjectDocument document;
    document.assets.push_back(makeAsset("Body", source));
    document.playbackEndFrame = 48;

    const fs::path packagePath = scratch / "MyProject.umesh";
    const ProjectDocument stored = saveProjectPackage(document, packagePath.string());

    UM_CHECK(fs::is_directory(packagePath));
    UM_CHECK(fs::exists(packagePath / "project.json"));
    UM_CHECK(fs::is_directory(packagePath / "Assets"));
    UM_CHECK(fs::exists(packagePath / "Assets" / "1-Body.png"));
    UM_CHECK(readText(packagePath / "Assets" / "1-Body.png") == "PNG-BODY-BYTES");

    // The returned document is the one as STORED: relative asset paths.
    UM_CHECK(stored.assets[0].filePath == "Assets/1-Body.png");
    // The caller's document is untouched.
    UM_CHECK(document.assets[0].filePath == source.string());

    fs::remove_all(scratch);
}

static void testIdenticalAssetBytesAreWrittenOnce() {
    const fs::path scratch = makeScratchDir("dedup");
    const fs::path first = scratch / "a.png";
    const fs::path second = scratch / "b.png";
    const fs::path third = scratch / "c.png";
    writeBytes(first, "SAME-BYTES");
    writeBytes(second, "SAME-BYTES"); // identical content, different file
    writeBytes(third, "DIFFERENT");

    ProjectDocument document;
    document.assets.push_back(makeAsset("First", first));
    document.assets.push_back(makeAsset("Second", second));
    document.assets.push_back(makeAsset("Third", third));

    const fs::path packagePath = scratch / "Dedup.umesh";
    const ProjectDocument stored = saveProjectPackage(document, packagePath.string());

    // Both duplicates point at the single written file; the third is its own.
    UM_CHECK(stored.assets[0].filePath == "Assets/1-First.png");
    UM_CHECK(stored.assets[1].filePath == "Assets/1-First.png");
    UM_CHECK(stored.assets[2].filePath == "Assets/3-Third.png");
    UM_CHECK(!fs::exists(packagePath / "Assets" / "2-Second.png"));

    int fileCount = 0;
    for (const auto& entry : fs::directory_iterator(packagePath / "Assets")) {
        (void)entry;
        ++fileCount;
    }
    UM_CHECK(fileCount == 2);

    fs::remove_all(scratch);
}

static void testAssetFilenamesAreSanitized() {
    const fs::path scratch = makeScratchDir("names");
    const fs::path source = scratch / "weird.png";
    writeBytes(source, "BYTES");

    ProjectDocument document;
    document.assets.push_back(makeAsset("  Left Arm/v2  ", source));

    const fs::path packagePath = scratch / "Names.umesh";
    const ProjectDocument stored = saveProjectPackage(document, packagePath.string());

    // Trimmed, spaces to '-', '/' to '_'.
    UM_CHECK(stored.assets[0].filePath == "Assets/1-Left-Arm_v2.png");
    UM_CHECK(fs::exists(packagePath / "Assets" / "1-Left-Arm_v2.png"));

    fs::remove_all(scratch);
}

static void testRoundTripThroughDiskResolvesAssetPathsBack() {
    const fs::path scratch = makeScratchDir("roundtrip");
    const fs::path source = scratch / "hero.png";
    writeBytes(source, "HERO");

    ProjectDocument document;
    document.assets.push_back(makeAsset("Hero", source));
    document.currentFrame = 11;
    document.playbackEndFrame = 60;
    Bone bone;
    bone.name = "root";
    document.skeleton.setBone(bone);
    document.skeleton.rootIDs.push_back(bone.id);

    const fs::path packagePath = scratch / "Round.umesh";
    saveProjectPackage(document, packagePath.string());
    const ProjectDocument loaded = loadProjectPackage(packagePath.string());

    UM_CHECK(loaded.currentFrame == 11);
    UM_CHECK(loaded.playbackEndFrame == 60);
    UM_CHECK(loaded.skeleton.bones().size() == 1);

    // The relative path in the manifest comes back absolute, and points at
    // a file that really exists.
    UM_CHECK(loaded.assets.size() == 1);
    UM_CHECK(fs::path(loaded.assets[0].filePath).is_absolute());
    UM_CHECK(fs::exists(loaded.assets[0].filePath));
    UM_CHECK(readText(loaded.assets[0].filePath) == "HERO");

    fs::remove_all(scratch);
}

static void testSaveOverAnExistingProjectReplacesIt() {
    const fs::path scratch = makeScratchDir("overwrite");
    const fs::path source = scratch / "one.png";
    writeBytes(source, "ONE");

    ProjectDocument first;
    first.assets.push_back(makeAsset("One", source));
    const fs::path packagePath = scratch / "Over.umesh";
    saveProjectPackage(first, packagePath.string());
    UM_CHECK(fs::exists(packagePath / "Assets" / "1-One.png"));

    ProjectDocument second;
    second.currentFrame = 5;
    saveProjectPackage(second, packagePath.string());

    // The old asset is gone, not merged into the new package.
    UM_CHECK(!fs::exists(packagePath / "Assets" / "1-One.png"));
    UM_CHECK(loadProjectPackage(packagePath.string()).currentFrame == 5);
    // No staging directory left behind.
    UM_CHECK(!fs::exists(scratch / "Over.umesh.saving"));

    fs::remove_all(scratch);
}

static void testLegacyFlatFileLoadsWithSiblingAssets() {
    const fs::path scratch = makeScratchDir("legacy");
    writeBytes(scratch / "old.png", "OLD");

    // A bare manifest with its image as a sibling -- the pre-package shape.
    ProjectDocument document;
    AssetRecord asset = makeAsset("Old", fs::path("old.png"));
    asset.filePath = "old.png"; // relative, as an old file would carry.
    document.assets.push_back(asset);
    const fs::path flat = scratch / "Legacy.umesh";
    writeBytes(flat, toJson(document).dump());

    UM_CHECK(classifyProjectFile(flat.string()) == ProjectFileKind::LegacyFlatFile);

    const ProjectDocument loaded = loadProjectPackage(flat.string());
    // Resolved against the FILE'S PARENT, not a package directory.
    UM_CHECK(loaded.assets[0].filePath == (scratch / "old.png").string());
    UM_CHECK(readText(loaded.assets[0].filePath) == "OLD");

    fs::remove_all(scratch);
}

static void testAbsoluteAssetPathsAreLeftAlone() {
    const fs::path scratch = makeScratchDir("absolute");
    const fs::path source = scratch / "abs.png";
    writeBytes(source, "ABS");

    ProjectDocument document;
    document.assets.push_back(makeAsset("Abs", source)); // absolute path
    const fs::path flat = scratch / "Abs.umesh";
    writeBytes(flat, toJson(document).dump());

    const ProjectDocument loaded = loadProjectPackage(flat.string());
    UM_CHECK(loaded.assets[0].filePath == source.string());

    fs::remove_all(scratch);
}

static void testRuntimeExportIsRejectedByName() {
    const fs::path scratch = makeScratchDir("export");
    const fs::path exportPath = scratch / "Export.umesh";
    // The chunked binary format's magic: 'U' 'M' 'S' 'H'.
    writeBytes(exportPath, std::string("UMSH") + std::string(64, '\0'));

    UM_CHECK(classifyProjectFile(exportPath.string()) == ProjectFileKind::RuntimeExport);

    bool threw = false;
    try {
        (void)loadProjectPackage(exportPath.string());
    } catch (const std::runtime_error& error) {
        threw = true;
        // Named as what it is, not as a decoding failure.
        UM_CHECK(std::string(error.what()).find("runtime export") != std::string::npos);
    }
    UM_CHECK(threw);

    fs::remove_all(scratch);
}

static void testMissingPathIsReportedNotCrashed() {
    const fs::path scratch = makeScratchDir("missing");
    const std::string missing = (scratch / "NoSuchProject.umesh").string();
    UM_CHECK(classifyProjectFile(missing) == ProjectFileKind::Missing);

    bool threw = false;
    try {
        (void)loadProjectPackage(missing);
    } catch (const std::runtime_error&) {
        threw = true;
    }
    UM_CHECK(threw);

    fs::remove_all(scratch);
}

static void testUnmodelledSectionsSurviveARealSaveLoadCycle() {
    // The end-to-end version of ProjectDocument's `unrecognized` test: a
    // section this port does not model must survive going to disk and back.
    const fs::path scratch = makeScratchDir("preserve");
    ProjectDocument document;
    document.unrecognized["sceneCompositions"] = JsonValue::parse("[{\"name\":\"Shot 1\",\"fps\":24}]");

    const fs::path packagePath = scratch / "Preserve.umesh";
    saveProjectPackage(document, packagePath.string());
    const ProjectDocument loaded = loadProjectPackage(packagePath.string());

    UM_CHECK(loaded.unrecognized.count("sceneCompositions") == 1);
    UM_CHECK(loaded.unrecognized.at("sceneCompositions").asArray()[0].find("fps")->asInt() == 24);

    fs::remove_all(scratch);
}

UM_TEST_MAIN_BEGIN()
    testSha256MatchesPublishedVectors();
    testSha256IsLengthSensitiveAtBlockBoundaries();
    testSavesPackageDirectoryWithManifestAndAssets();
    testIdenticalAssetBytesAreWrittenOnce();
    testAssetFilenamesAreSanitized();
    testRoundTripThroughDiskResolvesAssetPathsBack();
    testSaveOverAnExistingProjectReplacesIt();
    testLegacyFlatFileLoadsWithSiblingAssets();
    testAbsoluteAssetPathsAreLeftAlone();
    testRuntimeExportIsRejectedByName();
    testMissingPathIsReportedNotCrashed();
    testUnmodelledSectionsSurviveARealSaveLoadCycle();
UM_TEST_MAIN_END()
