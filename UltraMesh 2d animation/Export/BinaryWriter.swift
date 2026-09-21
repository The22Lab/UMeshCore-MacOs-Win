import Foundation
import simd

/// Append-only little-endian binary writer optimized for low-allocation
/// serialization. Backing storage is a single `Data` with reserved capacity,
/// so streaming a whole skeleton + animation graph is one allocation.
///
/// All `write*` methods are mutating to keep the hot loop branch-free
/// (no copy-on-write fork in normal use).
struct BinaryWriter {
    private(set) var data: Data

    init(reservingCapacity capacity: Int) {
        self.data = Data(capacity: capacity)
    }

    var count: Int { data.count }

    // MARK: - Fixed-width primitives (little-endian)

    mutating func writeU8(_ v: UInt8) {
        data.append(v)
    }

    mutating func writeU16(_ v: UInt16) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func writeU32(_ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func writeU64(_ v: UInt64) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func writeI32(_ v: Int32) {
        writeU32(UInt32(bitPattern: v))
    }

    mutating func writeF32(_ v: Float) {
        writeU32(v.bitPattern)
    }

    mutating func writeBool(_ v: Bool) {
        data.append(v ? 1 : 0)
    }

    // MARK: - Composite

    mutating func writeUUID(_ uuid: UUID) {
        var bytes = uuid.uuid
        withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
    }

    /// String length-prefixed UTF-8 (UInt32 byte length).
    mutating func writeString(_ s: String) {
        let utf8 = s.utf8
        writeU32(UInt32(utf8.count))
        if !utf8.isEmpty {
            data.append(contentsOf: utf8)
        }
    }

    mutating func writeSIMD2(_ v: SIMD2<Float>) {
        writeF32(v.x); writeF32(v.y)
    }

    mutating func writeSIMD3(_ v: SIMD3<Float>) {
        writeF32(v.x); writeF32(v.y); writeF32(v.z)
    }

    mutating func writeSIMD4(_ v: SIMD4<Float>) {
        writeF32(v.x); writeF32(v.y); writeF32(v.z); writeF32(v.w)
    }

    mutating func writeMatrix4x4(_ m: simd_float4x4) {
        writeSIMD4(m.columns.0)
        writeSIMD4(m.columns.1)
        writeSIMD4(m.columns.2)
        writeSIMD4(m.columns.3)
    }

    // MARK: - Arrays (raw bulk copy where layout matches)

    /// Writes a length-prefixed array of `SIMD2<Float>`. Backing memory is
    /// already 8 bytes per element matching the wire format, so we copy in
    /// one shot instead of looping.
    mutating func writeSIMD2Array(_ values: [SIMD2<Float>]) {
        writeU32(UInt32(values.count))
        guard !values.isEmpty else { return }
        values.withUnsafeBufferPointer { buffer in
            let raw = UnsafeRawBufferPointer(buffer)
            data.append(contentsOf: raw)
        }
    }

    /// Writes a length-prefixed array of UInt16 in one bulk copy.
    mutating func writeU16Array(_ values: [UInt16]) {
        writeU32(UInt32(values.count))
        guard !values.isEmpty else { return }
        values.withUnsafeBufferPointer { buffer in
            let raw = UnsafeRawBufferPointer(buffer)
            data.append(contentsOf: raw)
        }
    }

    /// Writes a length-prefixed array of Float in one bulk copy.
    mutating func writeF32Array(_ values: [Float]) {
        writeU32(UInt32(values.count))
        guard !values.isEmpty else { return }
        values.withUnsafeBufferPointer { buffer in
            let raw = UnsafeRawBufferPointer(buffer)
            data.append(contentsOf: raw)
        }
    }

    /// Appends the raw bytes of an existing `Data` blob (e.g. embedded texture
    /// payloads). The caller must write any length prefix before this call.
    mutating func appendData(_ payload: Data) {
        data.append(payload)
    }

    // MARK: - Chunk framing

    /// Begins a chunk: writes `type` and reserves 4 bytes for the size, which
    /// is patched in by `closeChunk(at:)`. Returns the size-field offset.
    mutating func openChunk(_ id: UMeshBinaryFormat.ChunkID) -> Int {
        writeU32(id.rawValue)
        let sizeOffset = data.count
        writeU32(0) // size placeholder, patched later
        return sizeOffset
    }

    /// Patches the chunk size at the given offset with the bytes written since.
    mutating func closeChunk(at sizeOffset: Int) {
        let payloadSize = UInt32(data.count - sizeOffset - 4)
        var le = payloadSize.littleEndian
        withUnsafeBytes(of: &le) { bytes in
            let src = Array(bytes)
            data.replaceSubrange(sizeOffset..<(sizeOffset + 4), with: src)
        }
    }

    // MARK: - Header patching

    /// Replaces 4 bytes at the given offset with a UInt32 (used to fill the
    /// header `chunkCount` and `payloadSize` after the body is known).
    mutating func patchU32(_ value: UInt32, at offset: Int) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { bytes in
            let src = Array(bytes)
            data.replaceSubrange(offset..<(offset + 4), with: src)
        }
    }
}
