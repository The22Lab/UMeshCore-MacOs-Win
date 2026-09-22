// Tests for Export/ExportSettings.h, ported from
// `Export/ExportSettings.swift`.
//
// A preset is written by the Save button "so a project's export setup
// travels with the team", which makes this a SHARED FORMAT between the Mac
// and Windows builds. So the tests are about what a file written by one
// build means to the other:
//
//   - Tokens, not ordinals. Reordering an enum must not silently re-read
//     every preset ever written.
//   - Round trip through JSON, field for field.
//   - A preset from an older or newer build still opens: every field
//     defaults, and an unknown enum token keeps the default rather than
//     failing the whole preset (a documented divergence from Swift's
//     `Codable`, which would throw).
//   - `restoreDefaults` keeps the folder -- one click must not force the
//     artist to re-pick it -- and resets the extension to the KIND's
//     default, not the struct's.
//   - Scale mode renders MORE DETAIL rather than bigger pixels, which is
//     what `zoomMultiplier` is for.

#include "umeshcore/Export/ExportSettings.h"

#include <string>

#include "TestHarness.h"

using namespace umeshcore;

// ---- The enums are a file format ---------------------------------------

static void testEnumTokensRoundTripAndAreNotOrdinals() {
    for (const ExportKind kind : {ExportKind::Json, ExportKind::Binary, ExportKind::Png}) {
        const auto back = exportKindFromRawValue(exportKindRawValue(kind));
        UM_CHECK(back.has_value() && *back == kind);
    }
    for (const PNGSizeMode mode : {PNGSizeMode::Scale, PNGSizeMode::Fixed}) {
        const auto back = pngSizeModeFromRawValue(pngSizeModeRawValue(mode));
        UM_CHECK(back.has_value() && *back == mode);
    }
    for (const PNGExportType type : {PNGExportType::CurrentPose, PNGExportType::Animation}) {
        const auto back = pngExportTypeFromRawValue(pngExportTypeRawValue(type));
        UM_CHECK(back.has_value() && *back == type);
    }
    // The stored tokens are Swift's `rawValue`s, so a C++ rename cannot
    // rewrite every preset on disk.
    UM_CHECK(std::string(exportKindRawValue(ExportKind::Binary)) == "binary");
    UM_CHECK(std::string(pngSizeModeRawValue(PNGSizeMode::Fixed)) == "fixed");
    UM_CHECK(std::string(pngExportTypeRawValue(PNGExportType::CurrentPose)) == "currentPose");
    UM_CHECK(!exportKindFromRawValue("gltf").has_value());
}

static void testTitlesAreTheLabelsNotTheCaseNames() {
    // The artist reads these, and a shell that spelled them differently
    // would show a format name that does not match the one in their file.
    UM_CHECK(std::string(exportKindTitle(ExportKind::Json)) == "JSON");
    UM_CHECK(std::string(exportKindTitle(ExportKind::Png)) == "PNG");
    // "Size", not "Fixed".
    UM_CHECK(std::string(pngSizeModeTitle(PNGSizeMode::Fixed)) == "Size");
    UM_CHECK(std::string(pngExportTypeTitle(PNGExportType::CurrentPose)) == "Current pose");
}

static void testDataAndImageGrouping() {
    UM_CHECK(exportKindIsData(ExportKind::Json));
    UM_CHECK(exportKindIsData(ExportKind::Binary));
    UM_CHECK(!exportKindIsData(ExportKind::Png));
    UM_CHECK(std::string(exportKindGroup(ExportKind::Binary)) == "Data");
    UM_CHECK(std::string(exportKindGroup(ExportKind::Png)) == "Image");
}

static void testDefaultExtensionsCarryTheLeadingDot() {
    // Part of the stored value, not something the caller adds: it is
    // composed straight onto the file name.
    UM_CHECK(std::string(exportKindDefaultExtension(ExportKind::Json)) == ".json");
    UM_CHECK(std::string(exportKindDefaultExtension(ExportKind::Binary)) == ".umesh");
    UM_CHECK(std::string(exportKindDefaultExtension(ExportKind::Png)) == ".png");
}

// ---- restoreDefaults ---------------------------------------------------

static void testRestoreDefaultsKeepsTheOutputLocation() {
    // One click must not force the artist to re-pick the folder.
    ExportSettings settings;
    settings.kind = ExportKind::Png;
    settings.outputPath = "/Volumes/Work/Shots";
    settings.fileName = "hero_walk";
    settings.smoothing = 1;
    settings.scalePercent = 400;
    settings.renderBones = true;

    settings.restoreDefaults();

    UM_CHECK(settings.outputPath == "/Volumes/Work/Shots");
    UM_CHECK(settings.fileName == "hero_walk");
    UM_CHECK(settings.kind == ExportKind::Png);
    // Everything else is back to the fresh value.
    UM_CHECK(settings.smoothing == 8);
    UM_CHECK(settings.scalePercent == 100);
    UM_CHECK(!settings.renderBones);
}

static void testRestoreDefaultsResetsTheExtensionToTheKindsNotTheStructs() {
    // The one field where "restore defaults" means the KIND's default.
    // Otherwise switching to the PNG panel and pressing Defaults would
    // leave `.json` on the name.
    ExportSettings settings;
    settings.kind = ExportKind::Binary;
    settings.fileExtension = ".nonsense";
    settings.restoreDefaults();
    UM_CHECK(settings.fileExtension == ".umesh");

    settings.kind = ExportKind::Png;
    settings.restoreDefaults();
    UM_CHECK(settings.fileExtension == ".png");
}

// ---- Derived values ----------------------------------------------------

static void testFixedModeUsesItsPixelDimensions() {
    ExportSettings settings;
    settings.sizeMode = PNGSizeMode::Fixed;
    settings.pixelWidth = 1920;
    settings.pixelHeight = 1080;
    const ExportSettings::PixelSize size = settings.resolvedPixelSize(800, 600);
    UM_CHECK(size.width == 1920 && size.height == 1080);
    // And the viewport is ignored entirely, which is the point of Size.
    UM_CHECK(settings.resolvedPixelSize(1, 1).width == 1920);
}

static void testScaleModeScalesTheViewport() {
    ExportSettings settings;
    settings.sizeMode = PNGSizeMode::Scale;
    settings.scalePercent = 200;
    const ExportSettings::PixelSize size = settings.resolvedPixelSize(800, 600);
    UM_CHECK(size.width == 1600 && size.height == 1200);

    settings.scalePercent = 50;
    const ExportSettings::PixelSize half = settings.resolvedPixelSize(801, 601);
    // Rounded, not truncated: 400.5 -> 401.
    UM_CHECK(half.width == 401 && half.height == 301);
}

static void testResolvedSizeIsNeverZeroInEitherMode() {
    // A zero-pixel render target is not a smaller image, it is a failure
    // further down.
    ExportSettings fixed;
    fixed.sizeMode = PNGSizeMode::Fixed;
    fixed.pixelWidth = 0;
    fixed.pixelHeight = -40;
    const ExportSettings::PixelSize fixedSize = fixed.resolvedPixelSize(800, 600);
    UM_CHECK(fixedSize.width == 1 && fixedSize.height == 1);

    ExportSettings scaled;
    scaled.sizeMode = PNGSizeMode::Scale;
    scaled.scalePercent = 1;
    const ExportSettings::PixelSize tiny = scaled.resolvedPixelSize(10, 10);
    UM_CHECK(tiny.width == 1 && tiny.height == 1);
    // A preset carrying 0 renders at 1%, not at nothing: the floor is
    // applied BEFORE the divide.
    scaled.scalePercent = 0;
    UM_CHECK(scaled.resolvedPixelSize(1000, 1000).width == 10);
}

static void testZoomMultiplierMakesScalingRenderMoreDetail() {
    // Not merely enlarging the same pixels -- the camera zooms with it.
    ExportSettings settings;
    settings.sizeMode = PNGSizeMode::Scale;
    settings.scalePercent = 300;
    UM_CHECK_NEAR(settings.zoomMultiplier(), 3.0, 1e-6);
    settings.scalePercent = 0;
    UM_CHECK_NEAR(settings.zoomMultiplier(), 0.01, 1e-6);

    // Size mode says everything with its dimensions, so the zoom is
    // exactly 1 -- and the scale percent is ignored rather than leaking in.
    settings.sizeMode = PNGSizeMode::Fixed;
    settings.scalePercent = 300;
    UM_CHECK_NEAR(settings.zoomMultiplier(), 1.0, 1e-6);
}

// ---- Persistence -------------------------------------------------------

static void testEveryFieldSurvivesARoundTrip() {
    ExportSettings settings;
    settings.kind = ExportKind::Png;
    settings.outputPath = "/out";
    settings.fileName = "shot";
    settings.openAfterExport = true;
    settings.fileExtension = ".png";
    settings.prettyPrint = false;
    settings.formatVersion = "2.1";
    settings.nonessentialData = false;
    settings.animationCleanUp = true;
    settings.warnings = false;
    settings.exportAll = true;
    settings.embedTextures = false;
    settings.floatPrecision = 3;
    settings.reproducible = true;
    settings.packTextureAtlas = true;
    settings.atlasMaxWidth = 4096;
    settings.atlasMaxHeight = 1024;
    settings.atlasPadding = 8;
    settings.atlasPowerOfTwo = false;
    settings.atlasStripWhitespace = false;
    settings.cropPadding = 16;
    settings.pngExportType = PNGExportType::CurrentPose;
    settings.warmUp = 4;
    settings.renderBones = true;
    settings.renderImages = false;
    settings.renderOthers = true;
    settings.renderSelection = true;
    settings.renderTitles = true;
    settings.smoothing = 2;
    settings.multisampleAA = 8;
    settings.cropViewport = true;
    settings.sizeMode = PNGSizeMode::Fixed;
    settings.scalePercent = 250;
    settings.pixelWidth = 640;
    settings.pixelHeight = 480;
    settings.useFrameRange = true;
    settings.startFrame = 12;
    settings.endFrame = 96;
    settings.fps = 60;
    settings.transparentBackground = false;
    settings.compression = 9;
    settings.bruteForce = true;
    settings.reduceColors = true;
    settings.filenamePrefix = "walk_";

    // Through text, not just through the value tree -- a preset is a file.
    const std::string text = toJson(settings).dump(true);
    const ExportSettings back = exportSettingsFromJson(JsonValue::parse(text));
    UM_CHECK(back == settings);
}

static void testAPresetFromAnOlderBuildOpensWithDefaults() {
    // Every field is optional on the way in. Swift's `Codable` would
    // throw on a missing key; refusing the whole preset over one absent
    // field is the failure this avoids, and a preset travels between
    // builds by design.
    const ExportSettings back =
        exportSettingsFromJson(JsonValue::parse(R"({"kind":"png","outputPath":"/out"})"));
    UM_CHECK(back.kind == ExportKind::Png);
    UM_CHECK(back.outputPath == "/out");
    // Everything else is the fresh default.
    UM_CHECK(back.smoothing == 8);
    UM_CHECK(back.fps == 30);
    UM_CHECK(back.filenamePrefix == "frame");
    UM_CHECK(back.sizeMode == PNGSizeMode::Scale);
    UM_CHECK(back.pngExportType == PNGExportType::Animation);
}

static void testAnEmptyPresetIsAFreshOne() {
    UM_CHECK(exportSettingsFromJson(JsonValue::parse("{}")) == ExportSettings());
}

static void testAnUnknownEnumTokenKeepsTheDefaultRatherThanFailing() {
    // A preset written by a later build naming a format this one cannot
    // produce opens on the default panel instead of not opening.
    const ExportSettings back = exportSettingsFromJson(JsonValue::parse(
        R"({"kind":"gltf","sizeMode":"letterbox","pngExportType":"turntable","fps":48})"));
    UM_CHECK(back.kind == ExportKind::Json);
    UM_CHECK(back.sizeMode == PNGSizeMode::Scale);
    UM_CHECK(back.pngExportType == PNGExportType::Animation);
    // And the fields it DOES understand still arrive.
    UM_CHECK(back.fps == 48);
}

static void testAWrongTypedFieldDoesNotPoisonTheRest() {
    // A hand-edited preset with a string where a number belongs keeps the
    // default for that field and reads the others.
    const ExportSettings back =
        exportSettingsFromJson(JsonValue::parse(R"({"fps":"sixty","compression":4})"));
    UM_CHECK(back.fps == 30);
    UM_CHECK(back.compression == 4);
}

static void testPresetKeysAreSortedSoADiffIsStable() {
    // Swift encodes with `.sortedKeys`; this port's JsonValue keeps them
    // sorted by construction. A preset lives in a repo next to the
    // project, so an unstable key order would make every save a diff.
    const std::string text = toJson(ExportSettings()).dump(true);
    const std::size_t animationCleanUp = text.find("\"animationCleanUp\"");
    const std::size_t atlasMaxWidth = text.find("\"atlasMaxWidth\"");
    const std::size_t warnings = text.find("\"warnings\"");
    UM_CHECK(animationCleanUp != std::string::npos);
    UM_CHECK(animationCleanUp < atlasMaxWidth);
    UM_CHECK(atlasMaxWidth < warnings);
}

UM_TEST_MAIN_BEGIN()
testEnumTokensRoundTripAndAreNotOrdinals();
testTitlesAreTheLabelsNotTheCaseNames();
testDataAndImageGrouping();
testDefaultExtensionsCarryTheLeadingDot();
testRestoreDefaultsKeepsTheOutputLocation();
testRestoreDefaultsResetsTheExtensionToTheKindsNotTheStructs();
testFixedModeUsesItsPixelDimensions();
testScaleModeScalesTheViewport();
testResolvedSizeIsNeverZeroInEitherMode();
testZoomMultiplierMakesScalingRenderMoreDetail();
testEveryFieldSurvivesARoundTrip();
testAPresetFromAnOlderBuildOpensWithDefaults();
testAnEmptyPresetIsAFreshOne();
testAnUnknownEnumTokenKeepsTheDefaultRatherThanFailing();
testAWrongTypedFieldDoesNotPoisonTheRest();
testPresetKeysAreSortedSoADiffIsStable();
UM_TEST_MAIN_END()
