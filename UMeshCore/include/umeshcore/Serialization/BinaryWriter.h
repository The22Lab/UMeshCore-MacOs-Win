#pragma once

// Port of `Export/BinaryWriter.swift` -- an append-only little-endian
// binary writer, backed by a single growable buffer so streaming a whole
// skeleton + animation graph is close to one allocation.
//
// The Swift source's `writeSIMD2Array`/`writeU16Array`/`writeF32Array` use
// `withUnsafeBufferPointer` to bulk-copy already-little-endian-compatible
// memory in one shot, purely as a performance optimization -- not part of
// this port's behavioral contract (the Swift source's own comment frames it
// as an implementation-detail speed-up, and every real Mac/Windows target
// this port runs on is little-endian already). This port writes array
// elements through the same scalar primitives used everywhere else instead,
// producing byte-identical output without depending on host endianness or
// undefined-behavior-adjacent pointer reinterpretation.
//
// UUID byte layout is a deliberate, documented divergence: Swift's
// `writeUUID` copies `UUID.uuid`'s raw 16-byte RFC-4122 tuple verbatim.
// This port's `Uuid` (see Core/Uuid.h) is explicitly NOT required to
// bit-match Swift's UUID generator -- its own header says so -- so
// `writeUuid` instead writes `hi` then `lo` as two little-endian UInt64
// words. This is a self-consistent, round-trippable 16-byte encoding (see
// `BinaryReader::readUuid`, its exact inverse); it does not need to match
// the Swift binary exporter byte-for-byte since that exporter has no reader
// counterpart in the Swift app to interoperate with (see
// `UMeshBinaryFormat.h`'s file header).

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Serialization/UMeshBinaryFormat.h"

namespace umeshcore {

class BinaryWriter {
public:
    explicit BinaryWriter(std::size_t reservingCapacity = 0) { data_.reserve(reservingCapacity); }

    const std::vector<std::uint8_t>& data() const { return data_; }
    std::size_t count() const { return data_.size(); }

    // ---- Fixed-width primitives (little-endian) ----

    void writeU8(std::uint8_t v) { data_.push_back(v); }

    void writeU16(std::uint16_t v) {
        data_.push_back(static_cast<std::uint8_t>(v & 0xFF));
        data_.push_back(static_cast<std::uint8_t>((v >> 8) & 0xFF));
    }

    void writeU32(std::uint32_t v) {
        for (int i = 0; i < 4; ++i) data_.push_back(static_cast<std::uint8_t>((v >> (8 * i)) & 0xFF));
    }

    void writeU64(std::uint64_t v) {
        for (int i = 0; i < 8; ++i) data_.push_back(static_cast<std::uint8_t>((v >> (8 * i)) & 0xFF));
    }

    void writeI32(std::int32_t v) { writeU32(static_cast<std::uint32_t>(v)); }

    void writeF32(float v) {
        std::uint32_t bits;
        static_assert(sizeof(bits) == sizeof(v), "float must be 32 bits");
        std::memcpy(&bits, &v, sizeof(bits));
        writeU32(bits);
    }

    void writeBool(bool v) { data_.push_back(v ? 1 : 0); }

    // ---- Composite ----

    // See file header: writes `hi` then `lo` as little-endian UInt64 words,
    // NOT Swift's raw UUID byte tuple. Exact inverse of readUuid.
    void writeUuid(const Uuid& id) {
        writeU64(id.hi);
        writeU64(id.lo);
    }

    // Length-prefixed UTF-8 (UInt32 byte length).
    void writeString(const std::string& s) {
        writeU32(static_cast<std::uint32_t>(s.size()));
        data_.insert(data_.end(), s.begin(), s.end());
    }

    void writeVec2(const Vec2& v) {
        writeF32(v.x);
        writeF32(v.y);
    }

    void writeVec3(const Vec3& v) {
        writeF32(v.x);
        writeF32(v.y);
        writeF32(v.z);
    }

    void writeVec4(const Vec4& v) {
        writeF32(v.x);
        writeF32(v.y);
        writeF32(v.z);
        writeF32(v.w);
    }

    void writeMat4(const Mat4& m) {
        writeVec4(m.columns[0]);
        writeVec4(m.columns[1]);
        writeVec4(m.columns[2]);
        writeVec4(m.columns[3]);
    }

    // ---- Arrays (length-prefixed) ----

    void writeVec2Array(const std::vector<Vec2>& values) {
        writeU32(static_cast<std::uint32_t>(values.size()));
        for (const Vec2& v : values) writeVec2(v);
    }

    void writeU16Array(const std::vector<std::uint16_t>& values) {
        writeU32(static_cast<std::uint32_t>(values.size()));
        for (std::uint16_t v : values) writeU16(v);
    }

    void writeF32Array(const std::vector<float>& values) {
        writeU32(static_cast<std::uint32_t>(values.size()));
        for (float v : values) writeF32(v);
    }

    // Appends the raw bytes of an existing payload (e.g. embedded texture
    // data). The caller must write any length prefix before this call.
    void appendData(const std::vector<std::uint8_t>& payload) {
        data_.insert(data_.end(), payload.begin(), payload.end());
    }

    // ---- Chunk framing ----

    // Begins a chunk: writes `type` and reserves 4 bytes for the size,
    // which is patched in by closeChunk(at:). Returns the size-field offset.
    std::size_t openChunk(UMeshBinaryFormat::ChunkID id) {
        writeU32(static_cast<std::uint32_t>(id));
        const std::size_t sizeOffset = data_.size();
        writeU32(0); // size placeholder, patched later
        return sizeOffset;
    }

    // Patches the chunk size at the given offset with the bytes written since.
    void closeChunk(std::size_t sizeOffset) {
        const std::uint32_t payloadSize = static_cast<std::uint32_t>(data_.size() - sizeOffset - 4);
        patchU32(payloadSize, sizeOffset);
    }

    // ---- Header patching ----

    // Replaces 4 bytes at the given offset with a UInt32 (used to fill the
    // header chunkCount/payloadSize after the body is known).
    void patchU32(std::uint32_t value, std::size_t offset) {
        for (int i = 0; i < 4; ++i) {
            data_[offset + static_cast<std::size_t>(i)] = static_cast<std::uint8_t>((value >> (8 * i)) & 0xFF);
        }
    }

private:
    std::vector<std::uint8_t> data_;
};

} // namespace umeshcore
