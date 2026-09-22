#pragma once

// The package layer around the `.umesh` project manifest: the directory
// itself, its `Assets/` folder, and the SHA-256 content deduplication that
// writes identical source images once. Ports `ProjectPersistence.save`/
// `load`/`makeProjectFileWrapper`/`makeBundledAssets`/`resolvingAssetPaths`
// (`Data/ProjectPersistence.swift`).
//
// On-disk shape, matching Swift exactly:
//
//     MyProject.umesh/          (a directory, not an archive)
//       project.json            the manifest -- see ProjectDocument.h
//       Assets/
//         1-Body.png
//         2-Arm.png
//
// Swift builds this with `FileWrapper`; this port uses `std::filesystem`.
// Both write atomically: the package is assembled beside the destination
// and moved into place, so a failure partway through cannot leave the
// previous project half-overwritten.
//
// `loadProjectPackage` also accepts the LEGACY FLAT FILE shape -- a bare
// `project.json`-style file with its images as siblings -- which Swift's
// reader still supports for projects saved before the package format. Asset
// paths are resolved against the package directory (or the file's parent,
// in the legacy case), and absolute paths are left alone.
//
// Three different things share the `.umesh` extension, so the reader sniffs
// before parsing: a project package (directory with a manifest), a legacy
// flat project file, and a Unity RUNTIME EXPORT (the chunked binary format
// in `UMeshBinaryFormat.h`, whose first four bytes are `UMSH`). Swift added
// this check because letting an export reach the JSON decoder produced "the
// data couldn't be read because it isn't in the correct format" -- true,
// useless, and indistinguishable from a corrupt project.

#include <string>

#include "umeshcore/Serialization/ProjectDocument.h"

namespace umeshcore {

inline constexpr const char* kProjectManifestFilename = "project.json";
inline constexpr const char* kBundledAssetsDirectoryName = "Assets";

enum class ProjectFileKind {
    ProjectPackage, // A directory holding project.json.
    LegacyFlatFile, // A bare manifest file, assets alongside it.
    RuntimeExport,  // The chunked binary export -- valid, but not a project.
    Missing,        // Nothing at that path.
};

ProjectFileKind classifyProjectFile(const std::string& path);

// Writes the package to `packagePath`, copying each asset's source file
// into `Assets/` and deduplicating by content digest. Returns the document
// AS STORED: every asset's `filePath` rewritten to its package-relative
// path, which is what the manifest on disk carries.
//
// Throws std::runtime_error if an asset's source file cannot be read, or
// if the package cannot be written. Overwrites an existing project at that
// path (the save-over case), but only once the new one is fully assembled.
ProjectDocument saveProjectPackage(const ProjectDocument& document, const std::string& packagePath);

// Reads a package (or a legacy flat file), resolving each asset's
// `filePath` back to an absolute path. Throws std::runtime_error if the
// path holds a runtime export, is missing, or has no readable manifest.
ProjectDocument loadProjectPackage(const std::string& path);

} // namespace umeshcore
