#pragma once

// 1:1 port of `Export/ExportSettings.swift` (158 L) -- the complete,
// serializable export configuration, plus the three string-backed enums
// it holds (`ExportKind`, `PNGSizeMode`, `PNGExportType`).
//
// ## Why this and not `ExportManager`
//
// `Export/ExportManager.swift` (135 L) is an orchestrator and almost all
// of it is platform: a `PNGFrameSource` backed by a Metal offscreen
// renderer, a `VideoExporter` built on AVFoundation's H.264 writer,
// `SceneFrameRenderer`/`SceneMetalRenderer`, `URL`s and Swift
// `async`/`Task`. None of that crosses -- the same call `CLAUDE.md` makes
// for the ~9000 lines of `Render/` shell, and for the same reason: a
// Windows build must produce its own, against DirectX and Media
// Foundation, behind a common interface the shell owns.
//
// Two things in that file ARE logic rather than wiring, and neither
// belongs here:
//   - The guard in `exportSkeleton` that refuses to write a flat `.umesh`
//     over a project PACKAGE. It is real and it matters -- the two share
//     an extension by design, so a save panel's "replace?" prompt looks
//     perfectly reasonable to whoever is clicking it, and saying yes
//     destroys the project. This port already has it, as
//     `classifyProjectFile` in `Serialization/ProjectPackage.h`, where the
//     sniffing lives.
//   - The batch loop's per-clip subdirectory naming
//     (`parentDirectory/{clipName}/`). One line of path joining around a
//     platform exporter; it comes across with whichever shell grows a
//     batch export.
//
// ## Why THIS file does cross
//
// It is the preset the Save/Load buttons write to disk "so a project's
// export setup travels with the team" -- so a Mac and a Windows build
// have to agree on it field for field and token for token, or a preset
// saved on one opens wrong on the other. That is exactly the kind of
// shared contract this library exists to hold, and it is pure data plus
// three small derived values.
//
// The enums are STRING-backed in Swift, and their tokens are the file
// format. Mapped by explicit switch, never by cast -- the rule
// `SceneGPUTypes.h` states for the wire codes and the whole Scene model
// follows. `title()` is included because it is the label the preset's own
// format list is grouped by, and a shell that spelled it differently
// would show the artist a format name that does not match the one in
// their file.

#include <optional>
#include <string>

#include "umeshcore/Serialization/Json.h"

namespace umeshcore {

// Which output the Export dialog produces. Grouped in the left-hand list
// the way export dialogs conventionally are: Data formats first, then
// Image formats.
enum class ExportKind { Json, Binary, Png };

inline const char* exportKindRawValue(ExportKind kind) {
    switch (kind) {
        case ExportKind::Json: return "json";
        case ExportKind::Binary: return "binary";
        case ExportKind::Png: return "png";
    }
    return "json";
}

inline std::optional<ExportKind> exportKindFromRawValue(const std::string& raw) {
    if (raw == "json") return ExportKind::Json;
    if (raw == "binary") return ExportKind::Binary;
    if (raw == "png") return ExportKind::Png;
    return std::nullopt;
}

inline const char* exportKindTitle(ExportKind kind) {
    switch (kind) {
        case ExportKind::Json: return "JSON";
        case ExportKind::Binary: return "Binary";
        case ExportKind::Png: return "PNG";
    }
    return "JSON";
}

inline bool exportKindIsData(ExportKind kind) { return kind != ExportKind::Png; }

// Section header in the format list.
inline const char* exportKindGroup(ExportKind kind) {
    return exportKindIsData(kind) ? "Data" : "Image";
}

// Note the LEADING DOT. It is part of the stored value, not something the
// caller adds: `ExportSettings::fileExtension` holds exactly this string
// and is composed straight onto the file name.
inline const char* exportKindDefaultExtension(ExportKind kind) {
    switch (kind) {
        case ExportKind::Json: return ".json";
        case ExportKind::Binary: return ".umesh";
        case ExportKind::Png: return ".png";
    }
    return ".json";
}

// From `Export/ExportTypes.swift`, ported here because `ExportSettings`
// holds it and nothing else of that file does.
enum class PNGSizeMode {
    // Scale the viewport by a percentage.
    Scale,
    // Explicit pixel dimensions.
    Fixed,
};

inline const char* pngSizeModeRawValue(PNGSizeMode mode) {
    return mode == PNGSizeMode::Scale ? "scale" : "fixed";
}
inline std::optional<PNGSizeMode> pngSizeModeFromRawValue(const std::string& raw) {
    if (raw == "scale") return PNGSizeMode::Scale;
    if (raw == "fixed") return PNGSizeMode::Fixed;
    return std::nullopt;
}
// "Size", not "Fixed" -- the label the artist reads is not the case name.
inline const char* pngSizeModeTitle(PNGSizeMode mode) {
    return mode == PNGSizeMode::Scale ? "Scale" : "Size";
}

// "Current pose" renders one frame; "Animation" renders a range.
enum class PNGExportType { CurrentPose, Animation };

inline const char* pngExportTypeRawValue(PNGExportType type) {
    return type == PNGExportType::CurrentPose ? "currentPose" : "animation";
}
inline std::optional<PNGExportType> pngExportTypeFromRawValue(const std::string& raw) {
    if (raw == "currentPose") return PNGExportType::CurrentPose;
    if (raw == "animation") return PNGExportType::Animation;
    return std::nullopt;
}
inline const char* pngExportTypeTitle(PNGExportType type) {
    return type == PNGExportType::CurrentPose ? "Current pose" : "Animation";
}

struct ExportSettings {
    // Which panel.
    ExportKind kind = ExportKind::Json;

    // ---- Shared ----
    // Output folder (data formats) or the output file's folder (image
    // formats).
    std::string outputPath;
    // File name WITHOUT extension, composed with `fileExtension` into the
    // final path.
    std::string fileName;
    bool openAfterExport = false;

    // ---- JSON / Binary (Data) ----
    std::string fileExtension = ".json";
    bool prettyPrint = true;
    // Format version string surfaced in the file header.
    std::string formatVersion = "1.0";
    bool nonessentialData = true;
    bool animationCleanUp = false;
    bool warnings = true;
    // Export every named animation. Off = only the active one.
    bool exportAll = false;
    bool embedTextures = true;
    int floatPrecision = 6;
    bool reproducible = false;

    // ---- Texture atlas packing ----
    bool packTextureAtlas = false;
    int atlasMaxWidth = 2048;
    int atlasMaxHeight = 2048;
    int atlasPadding = 2;
    bool atlasPowerOfTwo = true;
    bool atlasStripWhitespace = true;

    // ---- PNG crop ----
    int cropPadding = 2;

    // ---- PNG (Image) ----
    PNGExportType pngExportType = PNGExportType::Animation;
    int warmUp = 1;
    bool renderBones = false;
    bool renderImages = true;
    bool renderOthers = false;
    bool renderSelection = false;
    bool renderTitles = false;
    int smoothing = 8;
    // 0 = None, else 2/4/8/16.
    int multisampleAA = 0;
    bool cropViewport = false;
    PNGSizeMode sizeMode = PNGSizeMode::Scale;
    int scalePercent = 100;
    int pixelWidth = 1024;
    int pixelHeight = 1024;
    bool useFrameRange = false;
    int startFrame = 0;
    int endFrame = 0;
    int fps = 30;
    bool transparentBackground = true;
    int compression = 6;
    bool bruteForce = false;
    bool reduceColors = false;
    std::string filenamePrefix = "frame";

    bool operator==(const ExportSettings&) const = default;

    // The "Defaults" button: restores every option of the CURRENT panel
    // while preserving the chosen output location, so one click does not
    // force the artist to re-pick the folder.
    //
    // Note it also resets `fileExtension` to the KIND's default rather
    // than keeping it, which is the one field where "restore defaults"
    // means the kind's default and not the struct's.
    void restoreDefaults();

    // Effective output pixel size for the PNG panel, honouring Scale vs
    // Size. Floored at 1 in both modes: a zero-pixel render target is not
    // a smaller image, it is a failure further down.
    struct PixelSize {
        int width = 1;
        int height = 1;
    };
    PixelSize resolvedPixelSize(int viewportWidth, int viewportHeight) const;

    // Camera zoom multiplier implied by Scale mode, so scaling up renders
    // MORE DETAIL rather than merely enlarging the same pixels. Exactly 1
    // in Size mode, where the pixel dimensions already say everything.
    float zoomMultiplier() const;
};

// Persistence. Swift encodes with `[.prettyPrinted, .sortedKeys]`; this
// port's `JsonValue` keeps keys sorted by construction (`std::map`), so
// `dump(true)` is the same document.
JsonValue toJson(const ExportSettings& settings);

// Every field is optional on the way in, defaulting to the same value a
// fresh `ExportSettings` has. Swift's `Codable` is stricter than that --
// it would throw on a preset missing a key -- and the divergence is
// deliberate: a preset travels between machines and between versions of
// the app, so a build that added a field must still open a preset written
// before it, and a build that removed one must not choke. Refusing the
// whole preset over one absent key is the failure mode this avoids.
// An unrecognised enum token falls back to the default for the same
// reason.
ExportSettings exportSettingsFromJson(const JsonValue& j);

} // namespace umeshcore
