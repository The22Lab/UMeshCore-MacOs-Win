#include "umeshcore/Export/ExportSettings.h"

#include <algorithm>
#include <cmath>

namespace umeshcore {

namespace {

bool boolOr(const JsonValue& j, const char* key, bool fallback) {
    const JsonValue* found = j.find(key);
    return found != nullptr && found->isBool() ? found->asBool() : fallback;
}

int intOr(const JsonValue& j, const char* key, int fallback) {
    const JsonValue* found = j.find(key);
    return found != nullptr && found->isNumber() ? found->asInt() : fallback;
}

std::string stringOr(const JsonValue& j, const char* key, const std::string& fallback) {
    const JsonValue* found = j.find(key);
    return found != nullptr && found->isString() ? found->asString() : fallback;
}

} // namespace

void ExportSettings::restoreDefaults() {
    const std::string keptPath = outputPath;
    const std::string keptName = fileName;
    const ExportKind keptKind = kind;
    *this = ExportSettings();
    kind = keptKind;
    outputPath = keptPath;
    fileName = keptName;
    // The kind's default, not the struct's -- otherwise switching to the
    // PNG panel and pressing Defaults would leave `.json` on the name.
    fileExtension = exportKindDefaultExtension(keptKind);
}

ExportSettings::PixelSize ExportSettings::resolvedPixelSize(
    int viewportWidth, int viewportHeight) const {
    if (sizeMode == PNGSizeMode::Fixed) {
        return PixelSize{std::max(1, pixelWidth), std::max(1, pixelHeight)};
    }
    // `scalePercent` is floored at 1 BEFORE the divide, matching Swift, so
    // a preset carrying 0 renders at 1% rather than at nothing.
    const double factor = static_cast<double>(std::max(1, scalePercent)) / 100.0;
    // `std::llround` is round-half-away-from-zero like Swift's `.rounded()`;
    // both dimensions are non-negative here, so the tie direction only has
    // to be the same as Swift's, which it is.
    return PixelSize{
        std::max(1, static_cast<int>(std::llround(static_cast<double>(viewportWidth) * factor))),
        std::max(1, static_cast<int>(std::llround(static_cast<double>(viewportHeight) * factor)))};
}

float ExportSettings::zoomMultiplier() const {
    return sizeMode == PNGSizeMode::Scale ? static_cast<float>(std::max(1, scalePercent)) / 100.0f
                                          : 1.0f;
}

JsonValue toJson(const ExportSettings& s) {
    JsonValue j = JsonValue::makeObject();
    j.set("kind", JsonValue::makeString(exportKindRawValue(s.kind)));

    j.set("outputPath", JsonValue::makeString(s.outputPath));
    j.set("fileName", JsonValue::makeString(s.fileName));
    j.set("openAfterExport", JsonValue::makeBool(s.openAfterExport));

    j.set("fileExtension", JsonValue::makeString(s.fileExtension));
    j.set("prettyPrint", JsonValue::makeBool(s.prettyPrint));
    j.set("formatVersion", JsonValue::makeString(s.formatVersion));
    j.set("nonessentialData", JsonValue::makeBool(s.nonessentialData));
    j.set("animationCleanUp", JsonValue::makeBool(s.animationCleanUp));
    j.set("warnings", JsonValue::makeBool(s.warnings));
    j.set("exportAll", JsonValue::makeBool(s.exportAll));
    j.set("embedTextures", JsonValue::makeBool(s.embedTextures));
    j.set("floatPrecision", JsonValue::makeNumber(s.floatPrecision));
    j.set("reproducible", JsonValue::makeBool(s.reproducible));

    j.set("packTextureAtlas", JsonValue::makeBool(s.packTextureAtlas));
    j.set("atlasMaxWidth", JsonValue::makeNumber(s.atlasMaxWidth));
    j.set("atlasMaxHeight", JsonValue::makeNumber(s.atlasMaxHeight));
    j.set("atlasPadding", JsonValue::makeNumber(s.atlasPadding));
    j.set("atlasPowerOfTwo", JsonValue::makeBool(s.atlasPowerOfTwo));
    j.set("atlasStripWhitespace", JsonValue::makeBool(s.atlasStripWhitespace));

    j.set("cropPadding", JsonValue::makeNumber(s.cropPadding));

    j.set("pngExportType", JsonValue::makeString(pngExportTypeRawValue(s.pngExportType)));
    j.set("warmUp", JsonValue::makeNumber(s.warmUp));
    j.set("renderBones", JsonValue::makeBool(s.renderBones));
    j.set("renderImages", JsonValue::makeBool(s.renderImages));
    j.set("renderOthers", JsonValue::makeBool(s.renderOthers));
    j.set("renderSelection", JsonValue::makeBool(s.renderSelection));
    j.set("renderTitles", JsonValue::makeBool(s.renderTitles));
    j.set("smoothing", JsonValue::makeNumber(s.smoothing));
    j.set("multisampleAA", JsonValue::makeNumber(s.multisampleAA));
    j.set("cropViewport", JsonValue::makeBool(s.cropViewport));
    j.set("sizeMode", JsonValue::makeString(pngSizeModeRawValue(s.sizeMode)));
    j.set("scalePercent", JsonValue::makeNumber(s.scalePercent));
    j.set("pixelWidth", JsonValue::makeNumber(s.pixelWidth));
    j.set("pixelHeight", JsonValue::makeNumber(s.pixelHeight));
    j.set("useFrameRange", JsonValue::makeBool(s.useFrameRange));
    j.set("startFrame", JsonValue::makeNumber(s.startFrame));
    j.set("endFrame", JsonValue::makeNumber(s.endFrame));
    j.set("fps", JsonValue::makeNumber(s.fps));
    j.set("transparentBackground", JsonValue::makeBool(s.transparentBackground));
    j.set("compression", JsonValue::makeNumber(s.compression));
    j.set("bruteForce", JsonValue::makeBool(s.bruteForce));
    j.set("reduceColors", JsonValue::makeBool(s.reduceColors));
    j.set("filenamePrefix", JsonValue::makeString(s.filenamePrefix));
    return j;
}

ExportSettings exportSettingsFromJson(const JsonValue& j) {
    ExportSettings s;

    // An unrecognised token keeps the default rather than failing the
    // preset -- see the header: a preset travels between builds.
    const JsonValue* kind = j.find("kind");
    if (kind != nullptr && kind->isString()) {
        s.kind = exportKindFromRawValue(kind->asString()).value_or(s.kind);
    }

    s.outputPath = stringOr(j, "outputPath", s.outputPath);
    s.fileName = stringOr(j, "fileName", s.fileName);
    s.openAfterExport = boolOr(j, "openAfterExport", s.openAfterExport);

    s.fileExtension = stringOr(j, "fileExtension", s.fileExtension);
    s.prettyPrint = boolOr(j, "prettyPrint", s.prettyPrint);
    s.formatVersion = stringOr(j, "formatVersion", s.formatVersion);
    s.nonessentialData = boolOr(j, "nonessentialData", s.nonessentialData);
    s.animationCleanUp = boolOr(j, "animationCleanUp", s.animationCleanUp);
    s.warnings = boolOr(j, "warnings", s.warnings);
    s.exportAll = boolOr(j, "exportAll", s.exportAll);
    s.embedTextures = boolOr(j, "embedTextures", s.embedTextures);
    s.floatPrecision = intOr(j, "floatPrecision", s.floatPrecision);
    s.reproducible = boolOr(j, "reproducible", s.reproducible);

    s.packTextureAtlas = boolOr(j, "packTextureAtlas", s.packTextureAtlas);
    s.atlasMaxWidth = intOr(j, "atlasMaxWidth", s.atlasMaxWidth);
    s.atlasMaxHeight = intOr(j, "atlasMaxHeight", s.atlasMaxHeight);
    s.atlasPadding = intOr(j, "atlasPadding", s.atlasPadding);
    s.atlasPowerOfTwo = boolOr(j, "atlasPowerOfTwo", s.atlasPowerOfTwo);
    s.atlasStripWhitespace = boolOr(j, "atlasStripWhitespace", s.atlasStripWhitespace);

    s.cropPadding = intOr(j, "cropPadding", s.cropPadding);

    const JsonValue* pngType = j.find("pngExportType");
    if (pngType != nullptr && pngType->isString()) {
        s.pngExportType = pngExportTypeFromRawValue(pngType->asString()).value_or(s.pngExportType);
    }
    s.warmUp = intOr(j, "warmUp", s.warmUp);
    s.renderBones = boolOr(j, "renderBones", s.renderBones);
    s.renderImages = boolOr(j, "renderImages", s.renderImages);
    s.renderOthers = boolOr(j, "renderOthers", s.renderOthers);
    s.renderSelection = boolOr(j, "renderSelection", s.renderSelection);
    s.renderTitles = boolOr(j, "renderTitles", s.renderTitles);
    s.smoothing = intOr(j, "smoothing", s.smoothing);
    s.multisampleAA = intOr(j, "multisampleAA", s.multisampleAA);
    s.cropViewport = boolOr(j, "cropViewport", s.cropViewport);

    const JsonValue* sizeMode = j.find("sizeMode");
    if (sizeMode != nullptr && sizeMode->isString()) {
        s.sizeMode = pngSizeModeFromRawValue(sizeMode->asString()).value_or(s.sizeMode);
    }
    s.scalePercent = intOr(j, "scalePercent", s.scalePercent);
    s.pixelWidth = intOr(j, "pixelWidth", s.pixelWidth);
    s.pixelHeight = intOr(j, "pixelHeight", s.pixelHeight);
    s.useFrameRange = boolOr(j, "useFrameRange", s.useFrameRange);
    s.startFrame = intOr(j, "startFrame", s.startFrame);
    s.endFrame = intOr(j, "endFrame", s.endFrame);
    s.fps = intOr(j, "fps", s.fps);
    s.transparentBackground = boolOr(j, "transparentBackground", s.transparentBackground);
    s.compression = intOr(j, "compression", s.compression);
    s.bruteForce = boolOr(j, "bruteForce", s.bruteForce);
    s.reduceColors = boolOr(j, "reduceColors", s.reduceColors);
    s.filenamePrefix = stringOr(j, "filenamePrefix", s.filenamePrefix);
    return s;
}

} // namespace umeshcore
