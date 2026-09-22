#pragma once

// SHA-256 (FIPS 180-4), implemented here rather than pulled in, for the
// same "no external dependencies" reason as this port's math library, test
// harness and JSON module (see ROADMAP.md). Swift reaches for
// `CryptoKit.SHA256`, which has no portable equivalent.
//
// Used by the project package writer to deduplicate asset files by content
// (`Serialization/ProjectPackage.h`): identical bytes are written once and
// every asset that shares them points at the single file. Nothing here is
// security-sensitive -- it is a content-addressing hash, not a credential
// or signature check -- but it is the real, standard algorithm, so digests
// match Swift's for the same bytes.

#include <cstdint>
#include <string>
#include <vector>

namespace umeshcore {

// Lowercase hex, 64 characters -- the same spelling Swift's
// `SHA256.hash(data:).map { String(format: "%02x", $0) }.joined()` produces.
std::string sha256Hex(const std::uint8_t* data, std::size_t size);
std::string sha256Hex(const std::vector<std::uint8_t>& data);
std::string sha256Hex(const std::string& text);

} // namespace umeshcore
