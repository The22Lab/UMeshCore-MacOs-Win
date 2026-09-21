import Foundation
import simd

/// The render mesh, computed when the artist edits it rather than 120 times a
/// second.
///
/// `Mesh.sanitizedForRender` runs once per sprite per frame — the renderer
/// calls `ToolUtilities.resolvedMesh` for every sprite it draws, and that ends
/// here. CLAUDE.md already names the rule it breaks:
///
///   "`sanitizedForRender` se ejecuta una vez por sprite y por fotograma. No
///    meter ahí validación ni nada que recorra todos los triángulos."
///
/// It walks every triangle: per triangle it builds a three-element array,
/// sorts it and hashes it into a `Set<[UInt16]>`. And every vertex: a filtered
/// array, a `[UUID: Float]`, a mapped array and a sort, each one a heap
/// allocation. A 24-sprite rig of 180-vertex meshes allocates about 33,000
/// times per frame — near four million allocations a second at 120 Hz. That is
/// not a slow function; it is a mesh REPAIR pass, the kind of thing that
/// belongs at load, sitting in the draw loop. It is what makes the iPad hot.
///
/// The thing is, it is a pure function of a mesh that does not change while
/// the animation plays. Animation moves `SceneImage.meshAnimationDeform` and
/// the bone matrices — separate arrays. The bind mesh being sanitised is
/// byte-identical from one frame to the next. So the whole cost is a pure
/// function being recomputed at display rate on arguments that never moved.
///
/// # Why buffer identity, and not a value comparison
///
/// Comparing the meshes would be O(vertices + triangles) per sprite per frame,
/// which is the cost this exists to remove. Instead the key is the IDENTITY of
/// the storage each array is using: a Swift array is copy-on-write, so
/// `images = updatedImages` — which the pose pass does every frame — copies the
/// structs and SHARES their buffers. Same address, same contents, by
/// construction. A write copies the buffer first, so an edit necessarily lands
/// on a new address.
///
/// The check is one-sided and that is what makes it safe: same address implies
/// same contents; a different address may still be the same contents, and then
/// the only cost is a recompute. It can be wastefully cautious. It cannot be
/// wrong.
///
/// The entry holds the mesh it fingerprinted, which is not optional: an address
/// only identifies a buffer while that buffer is alive, and a freed one can be
/// handed straight back to a different array. Holding the source keeps every
/// address it recorded valid for as long as the entry does.
///
/// The two fields with no buffer to point at — `boneInverseBindMatrices` and
/// `bindImagePose` — are compared by value. Both are small (bones, not
/// vertices) and neither allocates to compare.
///
/// # This is a memo, not a second implementation
///
/// On a miss it calls `ToolUtilities.resolvedMesh`, the same function every
/// other caller uses. There is still exactly one answer to "what mesh does this
/// sprite draw"; this only remembers it. `verify_animation_frame_cost.py`
/// checks that, and enumerates every field an edit can touch.
///
/// Not thread-safe, and does not need to be: every caller is on the main
/// thread — `draw(in:)`, hit testing, the tools.
final class RenderMeshCache {

    /// Where an array's storage lives and how long it is.
    private struct BufferIdentity: Equatable {
        var address: UInt
        var count: Int
    }

    private struct Fingerprint: Equatable {
        var vertices: BufferIdentity
        var uvs: BufferIdentity
        var indices: BufferIdentity
        var hullVertexIndices: BufferIdentity
        var internalEdges: BufferIdentity
        var manualTriangles: BufferIdentity
        var vertexBoneWeights: BufferIdentity
        var bindVertices: BufferIdentity
        var assetSize: SIMD2<Float>
    }

    private struct Entry {
        /// Keeps the fingerprinted buffers alive. See above.
        let source: Mesh
        let fingerprint: Fingerprint
        let resolved: Mesh
        var lastTouched: UInt64
    }

    /// Above this many sprites remembered, the half that has not been asked
    /// for in longest is dropped. Sprites deleted from a project would
    /// otherwise keep their render mesh forever; a bound costs one sweep every
    /// few thousand edits and nothing at all during playback.
    private static let capacity = 512

    private var entries: [UUID: Entry] = [:]
    private var clock: UInt64 = 0

    // MARK: - Reading

    /// The mesh this sprite should draw, sanitised.
    ///
    /// Identical to `ToolUtilities.resolvedMesh(for:assetSize:)` in every case;
    /// it just does not recompute an answer it already has.
    func resolvedMesh(for image: SceneImage, assetSize: SIMD2<Float>) -> Mesh {
        clock &+= 1
        let stamp = Self.fingerprint(of: image.mesh, assetSize: assetSize)

        if var entry = entries[image.id],
           entry.fingerprint == stamp,
           entry.source.boneInverseBindMatrices == image.mesh.boneInverseBindMatrices,
           entry.source.bindImagePose == image.mesh.bindImagePose {
            entry.lastTouched = clock
            entries[image.id] = entry
            return entry.resolved
        }

        let resolved = ToolUtilities.resolvedMesh(for: image, assetSize: assetSize)
        entries[image.id] = Entry(source: image.mesh, fingerprint: stamp,
                                  resolved: resolved, lastTouched: clock)
        if entries.count > Self.capacity { evictOldestHalf() }
        return resolved
    }

    /// Forget everything. For opening a project, where every sprite is new and
    /// the old entries can only waste memory.
    func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }

    // MARK: - Internals

    private static func fingerprint(of mesh: Mesh, assetSize: SIMD2<Float>) -> Fingerprint {
        Fingerprint(
            vertices: identity(mesh.vertices),
            uvs: identity(mesh.uvs),
            indices: identity(mesh.indices),
            hullVertexIndices: identity(mesh.hullVertexIndices),
            internalEdges: identity(mesh.internalEdges),
            manualTriangles: identity(mesh.manualTriangles),
            vertexBoneWeights: identity(mesh.vertexBoneWeights),
            bindVertices: identity(mesh.bindVertices),
            assetSize: assetSize
        )
    }

    private static func identity<T>(_ array: [T]) -> BufferIdentity {
        array.withUnsafeBufferPointer { buffer in
            var address: UInt = 0
            if let base = buffer.baseAddress {
                address = UInt(bitPattern: UnsafeRawPointer(base))
            }
            return BufferIdentity(address: address, count: buffer.count)
        }
    }

    private func evictOldestHalf() {
        // Sorted by hand rather than through a heap: this runs once per few
        // hundred distinct sprites, never inside a frame.
        let ordered = entries.sorted { $0.value.lastTouched < $1.value.lastTouched }
        for (id, _) in ordered.prefix(entries.count / 2) {
            entries.removeValue(forKey: id)
        }
    }
}
