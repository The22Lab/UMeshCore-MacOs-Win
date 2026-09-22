#pragma once

// The `.umesh` binary format has no reader in the Swift app today -- it is
// an export-only format there (see `UMeshBinaryFormat.h`'s file header and
// ROADMAP.md's Risk #4). This class is new code, not a port: the exact
// byte-level inverse of `BinaryWriter`, following the same primitive-by-
// primitive shape so a chunk decoder reads like its encoder in reverse.
//
// Input is untrusted (a file on disk), unlike everything else read by this
// class's writer counterpart, so every read is bounds-checked and throws
// std::out_of_range on truncated/malformed input rather than invoking
// undefined behavior.

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Serialization/UMeshBinaryFormat.h"

namespace umeshcore {

class BinaryReader {
public:
    explicit BinaryReader(const std::vector<std::uint8_t>& data) : data_(data) {}
    BinaryReader(const std::uint8_t* bytes, std::size_t size) : data_(bytes, bytes + size) {}

    std::size_t count() const { return data_.size(); }
    std::size_t position() const { return pos_; }
    std::size_t remaining() const { return data_.size() - pos_; }
    bool atEnd() const { return pos_ >= data_.size(); }

    // Repositions the cursor. Used to jump past a chunk whose type this
    // reader doesn't understand, using the chunk's own size field.
    void seek(std::size_t offset) {
        if (offset > data_.size()) throw std::out_of_range("BinaryReader::seek: offset past end of buffer");
        pos_ = offset;
    }
    void skip(std::size_t byteCount) { seek(pos_ + byteCount); }

    // ---- Fixed-width primitives (little-endian) ----

    std::uint8_t readU8() {
        requireAvailable(1);
        return data_[pos_++];
    }

    std::uint16_t readU16() {
        requireAvailable(2);
        std::uint16_t v = static_cast<std::uint16_t>(data_[pos_]) |
                           (static_cast<std::uint16_t>(data_[pos_ + 1]) << 8);
        pos_ += 2;
        return v;
    }

    std::uint32_t readU32() {
        requireAvailable(4);
        std::uint32_t v = 0;
        for (int i = 0; i < 4; ++i) v |= static_cast<std::uint32_t>(data_[pos_ + static_cast<std::size_t>(i)]) << (8 * i);
        pos_ += 4;
        return v;
    }

    std::uint64_t readU64() {
        requireAvailable(8);
        std::uint64_t v = 0;
        for (int i = 0; i < 8; ++i) v |= static_cast<std::uint64_t>(data_[pos_ + static_cast<std::size_t>(i)]) << (8 * i);
        pos_ += 8;
        return v;
    }

    std::int32_t readI32() { return static_cast<std::int32_t>(readU32()); }

    float readF32() {
        const std::uint32_t bits = readU32();
        float v;
        static_assert(sizeof(bits) == sizeof(v), "float must be 32 bits");
        std::memcpy(&v, &bits, sizeof(v));
        return v;
    }

    bool readBool() { return readU8() != 0; }

    // ---- Composite ----

    // Exact inverse of BinaryWriter::writeUuid (hi then lo, little-endian
    // UInt64 words -- see BinaryWriter.h's file header for why this is not
    // Swift's raw UUID byte tuple).
    Uuid readUuid() {
        const std::uint64_t hi = readU64();
        const std::uint64_t lo = readU64();
        return Uuid(hi, lo);
    }

    std::string readString() {
        const std::uint32_t byteLen = readU32();
        requireAvailable(byteLen);
        std::string s(reinterpret_cast<const char*>(&data_[pos_]), byteLen);
        pos_ += byteLen;
        return s;
    }

    Vec2 readVec2() {
        const float x = readF32();
        const float y = readF32();
        return Vec2(x, y);
    }

    Vec3 readVec3() {
        const float x = readF32();
        const float y = readF32();
        const float z = readF32();
        return Vec3(x, y, z);
    }

    Vec4 readVec4() {
        const float x = readF32();
        const float y = readF32();
        const float z = readF32();
        const float w = readF32();
        return Vec4(x, y, z, w);
    }

    Mat4 readMat4() {
        const Vec4 c0 = readVec4();
        const Vec4 c1 = readVec4();
        const Vec4 c2 = readVec4();
        const Vec4 c3 = readVec4();
        return Mat4(c0, c1, c2, c3);
    }

    // ---- Arrays (length-prefixed) ----

    std::vector<Vec2> readVec2Array() {
        const std::uint32_t n = readU32();
        std::vector<Vec2> out;
        out.reserve(n);
        for (std::uint32_t i = 0; i < n; ++i) out.push_back(readVec2());
        return out;
    }

    std::vector<std::uint16_t> readU16Array() {
        const std::uint32_t n = readU32();
        std::vector<std::uint16_t> out;
        out.reserve(n);
        for (std::uint32_t i = 0; i < n; ++i) out.push_back(readU16());
        return out;
    }

    std::vector<float> readF32Array() {
        const std::uint32_t n = readU32();
        std::vector<float> out;
        out.reserve(n);
        for (std::uint32_t i = 0; i < n; ++i) out.push_back(readF32());
        return out;
    }

    std::vector<std::uint8_t> readBytes(std::size_t byteCount) {
        requireAvailable(byteCount);
        std::vector<std::uint8_t> out(data_.begin() + static_cast<std::ptrdiff_t>(pos_),
                                       data_.begin() + static_cast<std::ptrdiff_t>(pos_ + byteCount));
        pos_ += byteCount;
        return out;
    }

    // ---- File / chunk framing ----

    struct FileHeader {
        std::uint32_t magic = 0;
        std::uint16_t version = 0;
        std::uint16_t flags = 0;
        std::uint32_t chunkCount = 0;
        std::uint32_t payloadSize = 0;
    };

    // Reads and validates the 24-byte file header. Throws std::runtime_error
    // if the magic doesn't match -- this is the one framing check this
    // reader makes on the caller's behalf, since every chunk decoder needs
    // it and a wrong magic means "not a .umesh file", not "malformed
    // .umesh file".
    FileHeader readFileHeader() {
        FileHeader header;
        header.magic = readU32();
        if (header.magic != UMeshBinaryFormat::magic) {
            throw std::runtime_error("BinaryReader::readFileHeader: bad magic, not a .umesh file");
        }
        header.version = readU16();
        header.flags = readU16();
        header.chunkCount = readU32();
        header.payloadSize = readU32();
        (void)readU64(); // reserved
        return header;
    }

    struct ChunkHeader {
        std::uint32_t type = 0;
        std::uint32_t size = 0;
    };

    // Reads a chunk's type/size header. Does not read or skip the payload --
    // the caller decodes `size` bytes (dispatching on `type`) or calls
    // `skip(size)` to pass over a chunk type it doesn't recognize, per the
    // format's own "readers MAY skip unknown chunks" contract.
    ChunkHeader readChunkHeader() {
        ChunkHeader header;
        header.type = readU32();
        header.size = readU32();
        return header;
    }

private:
    void requireAvailable(std::size_t n) const {
        if (n > remaining()) throw std::out_of_range("BinaryReader: read past end of buffer");
    }

    std::vector<std::uint8_t> data_;
    std::size_t pos_ = 0;
};

} // namespace umeshcore
