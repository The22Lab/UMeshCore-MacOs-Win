#pragma once

// Port of `Export/ExportTypes.swift`'s `BinaryExportOptions` (the subset
// `BinaryExporter.swift` actually reads).
//
// Swift's `includeBaseAnimations` field is deliberately NOT ported here:
// grepping the whole of `Export/BinaryExporter.swift` shows it is never
// read anywhere in that file -- it's consumed by a different exporter, out
// of scope for this port until that exporter is reached.

#include <optional>
#include <string>

namespace umeshcore {

enum class TextureEmbedMode {
    Reference, // Store a filename reference; the runtime loads the file itself.
    Embed,     // Store the asset's raw bytes inline in the ASSETS chunk.
};

struct BinaryExportOptions {
    TextureEmbedMode textureEmbedMode = TextureEmbedMode::Reference;
    std::optional<std::string> prettyName;
};

} // namespace umeshcore
