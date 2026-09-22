#pragma once

// A deliberately minimal stand-in for what `BinaryExporter.swift`'s
// `writeAssetsChunk` actually reads off Swift's `AssetManager`/
// `TextureAsset` (`Data/AssetManager.swift`, `Data/TextureAsset.swift`):
// just `name`, `size`, and a file path to embed or reference. Everything
// else those Swift types carry -- the live `MTLTexture` GPU handle, the
// texture-atlas placement, the alpha/thumbnail caches -- exists to serve
// rendering and hit-testing, not serialization, and depends on
// ImageIO/Metal APIs this headless library has no equivalent for (the same
// "inject what's needed" scoping `EditorScene`/`ImageHitTestFn` already
// apply, not a full `AssetManager` port).
//
// The exporter takes a caller-supplied `Uuid -> AssetRecord` lookup rather
// than owning a registry itself, matching how Swift's own
// `BinaryExporter.export(scene:assets:)` takes `AssetManager` as a
// separate parameter from `SceneManager`, not a field of it.

#include <string>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

// What a texture is FOR, mirroring Swift's `AssetRole`. Persisted in the
// project manifest (`SavedTextureAsset.role`), where it is optional and
// absent means Albedo -- i.e. ordinary artwork.
enum class AssetRole { Albedo, Normal, Height };

struct AssetRecord {
    Uuid id;
    std::string name;
    // Path to the asset's source file on disk. Only its final path
    // component is written in "reference" export mode (matching
    // `asset.fileURL.lastPathComponent`); the full path is used to locate
    // and read the file's bytes in "embed" mode.
    std::string filePath;
    // Pixel dimensions. NOT persisted in the project manifest: Swift's
    // `TextureAsset.size` comes from the decoded texture, so it is
    // recovered by loading the file, not read back from the file that
    // references it. The binary exporter (which has the size in hand at
    // export time) does write it.
    Vec2 size;
    AssetRole role = AssetRole::Albedo;
};

} // namespace umeshcore
