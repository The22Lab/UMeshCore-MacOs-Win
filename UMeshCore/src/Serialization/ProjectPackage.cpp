#include "umeshcore/Serialization/ProjectPackage.h"

#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <unordered_map>

#include "umeshcore/Serialization/Sha256.h"
#include "umeshcore/Serialization/UMeshBinaryFormat.h"

namespace umeshcore {

namespace fs = std::filesystem;

namespace {

std::vector<std::uint8_t> readFileBytes(const fs::path& path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) throw std::runtime_error("ProjectPackage: cannot read file: " + path.string());
    const std::streamsize size = file.tellg();
    file.seekg(0, std::ios::beg);
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(size));
    if (size > 0 && !file.read(reinterpret_cast<char*>(bytes.data()), size)) {
        throw std::runtime_error("ProjectPackage: cannot read file: " + path.string());
    }
    return bytes;
}

void writeFileBytes(const fs::path& path, const std::uint8_t* data, std::size_t size) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file) throw std::runtime_error("ProjectPackage: cannot write file: " + path.string());
    if (size > 0) file.write(reinterpret_cast<const char*>(data), static_cast<std::streamsize>(size));
    if (!file) throw std::runtime_error("ProjectPackage: cannot write file: " + path.string());
}

// Port of `ProjectPersistence.sanitizedFilename`: the characters a file
// name cannot carry become '_', surrounding whitespace goes, spaces become
// '-', and an empty result becomes "Asset".
std::string sanitizedFilename(const std::string& name) {
    static const std::string kInvalid = "/:\\?%*|\"<>";
    std::string cleaned;
    cleaned.reserve(name.size());
    for (char c : name) cleaned.push_back(kInvalid.find(c) != std::string::npos ? '_' : c);

    const auto isSpace = [](unsigned char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; };
    std::size_t begin = 0;
    while (begin < cleaned.size() && isSpace(static_cast<unsigned char>(cleaned[begin]))) ++begin;
    std::size_t end = cleaned.size();
    while (end > begin && isSpace(static_cast<unsigned char>(cleaned[end - 1]))) --end;
    std::string trimmed = cleaned.substr(begin, end - begin);

    for (char& c : trimmed) {
        if (c == ' ') c = '-';
    }
    return trimmed.empty() ? std::string("Asset") : trimmed;
}

// Swift checks `path.hasPrefix("/")`, which is POSIX-only. std::filesystem
// knows what "absolute" means on whichever platform this runs, so a
// Windows `C:\...` path is left alone too -- the same intent, correctly on
// both targets.
bool isAbsolutePath(const std::string& path) {
    return !path.empty() && fs::path(path).is_absolute();
}

bool startsWithRuntimeExportMagic(const fs::path& path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) return false;
    char head[4] = {};
    if (!file.read(head, 4)) return false;
    const std::uint32_t magic = static_cast<std::uint32_t>(static_cast<unsigned char>(head[0])) |
                                (static_cast<std::uint32_t>(static_cast<unsigned char>(head[1])) << 8) |
                                (static_cast<std::uint32_t>(static_cast<unsigned char>(head[2])) << 16) |
                                (static_cast<std::uint32_t>(static_cast<unsigned char>(head[3])) << 24);
    return magic == UMeshBinaryFormat::magic;
}

} // namespace

ProjectFileKind classifyProjectFile(const std::string& path) {
    std::error_code ec;
    const fs::path target(path);
    if (!fs::exists(target, ec)) return ProjectFileKind::Missing;

    if (fs::is_directory(target, ec)) {
        return fs::exists(target / kProjectManifestFilename, ec) ? ProjectFileKind::ProjectPackage
                                                                 : ProjectFileKind::Missing;
    }
    // Checked before anything parses the bytes: a runtime export is valid
    // binary that simply is not a project.
    if (startsWithRuntimeExportMagic(target)) return ProjectFileKind::RuntimeExport;
    return ProjectFileKind::LegacyFlatFile;
}

ProjectDocument saveProjectPackage(const ProjectDocument& document, const std::string& packagePath) {
    ProjectDocument stored = document;

    const fs::path destination(packagePath);
    // Assembled beside the destination and moved into place, so a failure
    // partway through cannot leave the previous project half-overwritten.
    const fs::path staging = destination.parent_path() / (destination.filename().string() + ".saving");

    std::error_code ec;
    fs::remove_all(staging, ec);
    if (!fs::create_directories(staging / kBundledAssetsDirectoryName, ec)) {
        if (ec) throw std::runtime_error("ProjectPackage: cannot create package at " + staging.string());
    }

    // One file per picture, with the paths still index-aligned to `assets`.
    // Importing deduplicates by content now, so a project made from here on
    // will not hold two assets with the same bytes -- but one made BEFORE
    // that does, and re-saving it should not carry the duplicates forward.
    std::unordered_map<std::string, std::string> pathForDigest;
    for (std::size_t index = 0; index < stored.assets.size(); ++index) {
        AssetRecord& asset = stored.assets[index];
        const std::vector<std::uint8_t> bytes = readFileBytes(fs::path(asset.filePath));
        const std::string digest = sha256Hex(bytes);

        const auto existing = pathForDigest.find(digest);
        if (existing != pathForDigest.end()) {
            asset.filePath = existing->second;
            continue;
        }

        const fs::path sourcePath(asset.filePath);
        std::string extension = sourcePath.extension().string();
        if (!extension.empty() && extension.front() == '.') extension.erase(extension.begin());
        if (extension.empty()) extension = "png";

        const std::string bundledFilename =
            std::to_string(index + 1) + "-" + sanitizedFilename(asset.name) + "." + extension;
        writeFileBytes(staging / kBundledAssetsDirectoryName / bundledFilename, bytes.data(), bytes.size());

        const std::string relative = std::string(kBundledAssetsDirectoryName) + "/" + bundledFilename;
        pathForDigest[digest] = relative;
        asset.filePath = relative;
    }

    const std::string manifest = toJson(stored).dump(/*prettyPrinted=*/true);
    writeFileBytes(
        staging / kProjectManifestFilename, reinterpret_cast<const std::uint8_t*>(manifest.data()), manifest.size());

    fs::remove_all(destination, ec);
    fs::rename(staging, destination, ec);
    if (ec) {
        fs::remove_all(staging);
        throw std::runtime_error("ProjectPackage: cannot move package into place at " + destination.string());
    }

    return stored;
}

ProjectDocument loadProjectPackage(const std::string& path) {
    const fs::path target(path);
    fs::path manifestPath;
    fs::path projectRoot;

    switch (classifyProjectFile(path)) {
        case ProjectFileKind::RuntimeExport:
            // Named separately from "corrupt" on purpose -- see the header.
            throw std::runtime_error(
                "ProjectPackage: \"" + target.filename().string() +
                "\" is a runtime export, not a project package");
        case ProjectFileKind::Missing:
            throw std::runtime_error("ProjectPackage: no readable project at " + path);
        case ProjectFileKind::ProjectPackage:
            manifestPath = target / kProjectManifestFilename;
            projectRoot = target;
            break;
        case ProjectFileKind::LegacyFlatFile:
            manifestPath = target;
            projectRoot = target.parent_path();
            break;
    }

    const std::vector<std::uint8_t> bytes = readFileBytes(manifestPath);
    ProjectDocument document =
        projectDocumentFromJson(JsonValue::parse(std::string(bytes.begin(), bytes.end())));

    // `resolvingAssetPaths(relativeTo:)`: a package-relative path becomes
    // absolute against the project root; an already-absolute one is left
    // alone, and an empty one is not a path at all.
    for (AssetRecord& asset : document.assets) {
        if (asset.filePath.empty() || isAbsolutePath(asset.filePath)) continue;
        asset.filePath = (projectRoot / asset.filePath).string();
    }

    return document;
}

} // namespace umeshcore
