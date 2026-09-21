import Foundation
import simd

/// Serializes a `SceneManager` snapshot into the `.umesh` binary format.
///
/// Design goals:
/// - Single allocation (Data with `reserveCapacity`) — no per-bone closures.
/// - Bulk-copy POD arrays (vertices, UVs, indices) instead of per-element writes.
/// - Self-contained chunks with per-chunk versions so runtime loaders can
///   skip what they don't understand.
///
/// This type is `Sendable`-safe by virtue of being stateless: it takes the
/// scene as input and returns a `Data` blob; nothing mutates across calls.
struct BinaryExporter {

    let options: BinaryExportOptions

    init(options: BinaryExportOptions = BinaryExportOptions()) {
        self.options = options
    }

    // MARK: - Public API

    /// Serializes the scene's skeleton, images, meshes, assets and animations.
    /// Synchronous and pure — call from a background task if you want.
    func export(scene: SceneManager, assets: AssetManager) throws -> Data {
        // Rough sizing heuristic: average bone ~ 64B, image header ~ 96B,
        // mesh ~ 32B/vertex, animation ~ 24B/keyframe. Over-reserving a single
        // 64 KiB block avoids reallocation for typical projects.
        let estimate = 64 * 1024
            + scene.images.count * 4096
            + scene.skeleton.bones.count * 256
        var writer = BinaryWriter(reservingCapacity: estimate)

        // ---------- Header ----------
        writer.writeU32(UMeshBinaryFormat.magic)
        writer.writeU16(UMeshBinaryFormat.version)
        writer.writeU16(options.textureEmbedMode == .embed
                        ? UMeshBinaryFormat.HeaderFlag.embeddedTextures.rawValue
                        : 0)
        let chunkCountOffset = writer.count
        writer.writeU32(0)               // chunkCount placeholder
        let payloadSizeOffset = writer.count
        writer.writeU32(0)               // payloadSize placeholder
        writer.writeU64(0)               // reserved

        let payloadStart = writer.count
        var chunkCount: UInt32 = 0

        // ---------- META ----------
        writeMetaChunk(into: &writer, scene: scene); chunkCount += 1

        // ---------- ASSETS ----------
        try writeAssetsChunk(into: &writer, scene: scene, assets: assets)
        chunkCount += 1

        // ---------- SKELETON ----------
        writeSkeletonChunk(into: &writer, scene: scene); chunkCount += 1

        // ---------- IMAGES + MESHES ----------
        writeImagesChunk(into: &writer, scene: scene); chunkCount += 1
        writeMeshesChunk(into: &writer, scene: scene); chunkCount += 1

        // ---------- ANIMATIONS ----------
        writeAnimationsChunk(into: &writer, scene: scene); chunkCount += 1

        // ---------- SCENES ----------
        // Only when the project has staged one. A rig that never opened Scene
        // mode produces a byte-identical file to before this chunk existed, and
        // a runtime that predates it skips an unknown chunk by its size field —
        // which is what the format was designed for.
        if !scene.sceneCompositions.isEmpty {
            writeScenesChunk(into: &writer, scene: scene); chunkCount += 1
        }

        // Patch header
        writer.patchU32(chunkCount, at: chunkCountOffset)
        writer.patchU32(UInt32(writer.count - payloadStart), at: payloadSizeOffset)
        return writer.data
    }

    /// Convenience: writes the serialized blob to `url` atomically.
    func write(scene: SceneManager, assets: AssetManager, to url: URL) throws {
        let blob = try export(scene: scene, assets: assets)
        do {
            try blob.write(to: url, options: .atomic)
        } catch {
            throw ExportError.ioFailure(url, underlying: error)
        }
    }

    // MARK: - SCENES chunk

    /// Staged compositions: layers at depths, and the camera with its keys.
    ///
    /// Layout, all little-endian:
    ///   u16 version
    ///   u32 sceneCount
    ///     per scene:
    ///       uuid id, string name
    ///       u32 durationInFrames, u32 fps
    ///       f32 renderW, f32 renderH
    ///       f32[8] background (top rgba, bottom rgba)
    ///       f32[2] cameraPos, f32 cameraZ, f32[3] cameraRot, f32 fov,
    ///       f32 nearZ, f32 farZ
    ///       u32 layerCount
    ///         per layer: uuid, string name, u8 kind, u8 hidden, f32 opacity,
    ///                    f32[2] pos, f32 z, f32 rot, f32[3] rot3D, f32[2] scale,
    ///                    then the kind's payload
    ///       u32 cameraTrackCount
    ///         per track: u8 property, u32 keyCount, then (u32 frame, f32[n] value)
    private func writeScenesChunk(into writer: inout BinaryWriter, scene: SceneManager) {
        let off = writer.openChunk(.scenes)
        writer.writeU16(UMeshBinaryFormat.ChunkVersion.scenes)
        writer.writeU32(UInt32(scene.sceneCompositions.count))

        for composition in scene.sceneCompositions {
            writer.writeUUID(composition.id)
            writer.writeString(composition.name)
            writer.writeU32(UInt32(max(composition.durationInFrames, 1)))
            writer.writeU32(UInt32(max(composition.fps, 1)))
            writer.writeF32(composition.renderSize.x)
            writer.writeF32(composition.renderSize.y)

            for component in [composition.background.topColor, composition.background.bottomColor] {
                writer.writeF32(component.x); writer.writeF32(component.y)
                writer.writeF32(component.z); writer.writeF32(component.w)
            }

            let camera = composition.camera
            writer.writeF32(camera.position.x); writer.writeF32(camera.position.y)
            writer.writeF32(camera.positionZ)
            writer.writeF32(camera.rotation3D.x)
            writer.writeF32(camera.rotation3D.y)
            writer.writeF32(camera.rotation3D.z)
            writer.writeF32(camera.fieldOfView)
            writer.writeF32(camera.nearZ)
            writer.writeF32(camera.farZ)

            // IN DRAW ORDER, back first. The array is only the tie-break now,
            // so writing it raw would hand the runtime a stacking that is not
            // the one the editor draws — and the chunk carries no layer number
            // for it to re-sort by, on purpose: what a player needs is the
            // order, not the arithmetic that produced it.
            writer.writeU32(UInt32(composition.layers.count))
            for layer in composition.drawOrderedLayers {
                writer.writeUUID(layer.id)
                writer.writeString(layer.name)
                let kind: UInt8
                switch layer.content {
                case .rig:   kind = 0
                case .plate: kind = 1
                case .fill:  kind = 2
                }
                writer.writeU8(kind)
                writer.writeU8(layer.isHidden ? 1 : 0)
                writer.writeF32(layer.opacity)
                writer.writeF32(layer.position.x); writer.writeF32(layer.position.y)
                writer.writeF32(layer.positionZ)
                writer.writeF32(layer.rotation)
                writer.writeF32(layer.rotation3D.x)
                writer.writeF32(layer.rotation3D.y)
                writer.writeF32(layer.rotation3D.z)
                writer.writeF32(layer.scale.x); writer.writeF32(layer.scale.y)

                switch layer.content {
                case let .rig(clipID, speed, startFrame, loops):
                    writer.writeUUID(clipID)
                    writer.writeF32(speed)
                    writer.writeU32(UInt32(max(startFrame, 0)))
                    writer.writeU8(loops ? 1 : 0)
                case let .plate(assetID):
                    writer.writeUUID(assetID)
                case let .fill(fillValue):
                    for component in [fillValue.topColor, fillValue.bottomColor] {
                        writer.writeF32(component.x); writer.writeF32(component.y)
                        writer.writeF32(component.z); writer.writeF32(component.w)
                    }
                }
            }

            writeSceneCameraTracks(into: &writer, scene: scene)
        }
        writer.closeChunk(at: off)
    }

    /// The camera's keyframes. Channel counts are implied by the property, so a
    /// reader that knows the property list can skip a track it does not
    /// recognise without knowing what it meant.
    private func writeSceneCameraTracks(into writer: inout BinaryWriter, scene: SceneManager) {
        let target = SceneAnimationTarget.camera
        let tracks = scene.sceneAnimationClip.tracks.filter {
            $0.targetID == target && !$0.keyframes.isEmpty
        }
        writer.writeU32(UInt32(tracks.count))

        for track in tracks {
            let code: UInt8
            switch track.property {
            case .cameraTranslate:  code = 0
            case .cameraTranslateZ: code = 1
            case .cameraRotate3D:   code = 2
            case .cameraRoll:       code = 3
            case .cameraFOV:        code = 4
            default:                code = 255
            }
            writer.writeU8(code)
            writer.writeU32(UInt32(track.keyframes.count))
            for key in track.keyframes.sorted(by: { $0.frame < $1.frame }) {
                writer.writeU32(UInt32(max(key.frame, 0)))
                switch key.value {
                case let .vector2(v):
                    writer.writeF32(v.x); writer.writeF32(v.y)
                case let .scalar(value):
                    writer.writeF32(value)
                default:
                    // A camera track can only hold these two kinds; anything
                    // else is a bug upstream, and writing a zero keeps the
                    // stream aligned so the rest of the file still parses.
                    writer.writeF32(0)
                }
            }
        }
    }

    // MARK: - META chunk

    private func writeMetaChunk(into writer: inout BinaryWriter, scene: SceneManager) {
        let off = writer.openChunk(.meta)
        writer.writeU16(UMeshBinaryFormat.ChunkVersion.meta)
        writer.writeString(options.prettyName ?? "UltraMeshExport")
        // Timestamp (seconds since 1970)
        writer.writeF32(Float(Date().timeIntervalSince1970))
        // Scene playback hints
        writer.writeU32(UInt32(max(scene.playbackEndFrame, 0)))
        writer.writeU32(UInt32(max(scene.playbackStartFrame, 0)))
        writer.closeChunk(at: off)
    }

    // MARK: - ASSETS chunk

    private func writeAssetsChunk(into writer: inout BinaryWriter,
                                  scene: SceneManager,
                                  assets: AssetManager) throws {
        let off = writer.openChunk(.assets)
        writer.writeU16(UMeshBinaryFormat.ChunkVersion.assets)

        // Collect distinct asset IDs referenced by scene images
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for image in scene.images where seen.insert(image.assetID).inserted {
            ordered.append(image.assetID)
        }

        writer.writeU32(UInt32(ordered.count))

        for assetID in ordered {
            writer.writeUUID(assetID)
            guard let asset = assets.asset(for: assetID) else {
                writer.writeString("")
                writer.writeSIMD2(.zero)
                writer.writeU32(0)         // no embedded bytes
                continue
            }
            writer.writeString(asset.name)
            writer.writeSIMD2(asset.size)

            if options.textureEmbedMode == .embed,
               let payload = try? Data(contentsOf: asset.fileURL) {
                writer.writeU32(UInt32(payload.count))
                writer.appendData(payload)
            } else {
                // Reference mode: store relative path so the runtime can find it.
                writer.writeU32(0)
                writer.writeString(asset.fileURL.lastPathComponent)
            }
        }

        writer.closeChunk(at: off)
    }

    // MARK: - SKELETON chunk

    private func writeSkeletonChunk(into writer: inout BinaryWriter, scene: SceneManager) {
        let off = writer.openChunk(.skeleton)
        writer.writeU16(UMeshBinaryFormat.ChunkVersion.skeleton)

        let bones = scene.skeleton.orderedBones    // DFS-ordered, roots first
        writer.writeU32(UInt32(bones.count))

        for bone in bones {
            writer.writeUUID(bone.id)
            writer.writeString(bone.name)
            // Compact parent: 1-byte presence flag, then UUID only if present.
            if let pid = bone.parentID {
                writer.writeBool(true)
                writer.writeUUID(pid)
            } else {
                writer.writeBool(false)
            }
            writeTransform(into: &writer, transform: bone.baseTransform)
            writeTransform(into: &writer, transform: bone.localTransform)
            writer.writeF32(bone.length)
            writer.writeSIMD4(bone.color ?? UM.unboundBone)
        }

        // Root IDs
        writer.writeU32(UInt32(scene.skeleton.rootIDs.count))
        for id in scene.skeleton.rootIDs {
            writer.writeUUID(id)
        }

        writer.closeChunk(at: off)
    }

    private func writeTransform(into writer: inout BinaryWriter, transform: Transform3D2D) {
        writer.writeSIMD3(transform.position)
        writer.writeSIMD3(transform.rotation)
        writer.writeSIMD3(transform.scale)
        writer.writeSIMD2(transform.skew)
    }

    // MARK: - IMAGES chunk

    private func writeImagesChunk(into writer: inout BinaryWriter, scene: SceneManager) {
        let off = writer.openChunk(.images)
        writer.writeU16(UMeshBinaryFormat.ChunkVersion.images)

        let images = scene.images
        writer.writeU32(UInt32(images.count))

        for image in images {
            writer.writeUUID(image.id)
            writer.writeUUID(image.assetID)
            writer.writeString(image.name)

            // Base pose
            writer.writeSIMD2(image.basePosition)
            writer.writeF32(image.baseRotation)
            writer.writeSIMD2(image.baseScale)
            writer.writeSIMD2(image.baseSkew)
            writer.writeSIMD3(image.baseRotation3D)

            // Flags
            var flags = UMeshBinaryFormat.ImageFlags(rawValue: 0)
            if image.boneBinding != nil { flags.insert(.hasBoneBinding) }
            if image.isHidden { flags.insert(.isHidden) }
            if case .boneLocal = image.animationTransformSpace { flags.insert(.boneLocalSpace) }
            writer.writeU8(flags.rawValue)

            // Bone binding (optional)
            if let binding = image.boneBinding {
                writer.writeUUID(binding.boneID)
                writer.writeSIMD2(binding.localPosition)
                writer.writeSIMD2(binding.localScale)
                writer.writeF32(binding.localRotation)
                writer.writeSIMD2(binding.localSkew)
            }

            // Animation space (only the bone ID if .boneLocal)
            switch image.animationTransformSpace {
            case .world:
                writer.writeU8(UMeshBinaryFormat.AnimationSpaceCode.world.rawValue)
            case .boneLocal(let boneID):
                writer.writeU8(UMeshBinaryFormat.AnimationSpaceCode.boneLocal.rawValue)
                writer.writeUUID(boneID)
            }
        }

        writer.closeChunk(at: off)
    }

    // MARK: - MESHES chunk

    private func writeMeshesChunk(into writer: inout BinaryWriter, scene: SceneManager) {
        let off = writer.openChunk(.meshes)
        writer.writeU16(UMeshBinaryFormat.ChunkVersion.meshes)

        let images = scene.images
        writer.writeU32(UInt32(images.count))

        for image in images {
            let mesh = image.mesh
            writer.writeUUID(image.id)           // owner key
            writer.writeUUID(mesh.id)
            writer.writeString(mesh.name)
            writer.writeSIMD2Array(mesh.vertices)
            writer.writeSIMD2Array(mesh.uvs)
            writer.writeU16Array(mesh.indices)
            writer.writeU16Array(mesh.hullVertexIndices)

            // Internal edges
            writer.writeU32(UInt32(mesh.internalEdges.count))
            for e in mesh.internalEdges {
                writer.writeU16(e.a); writer.writeU16(e.b)
            }
            // Manual triangles
            writer.writeU32(UInt32(mesh.manualTriangles.count))
            for t in mesh.manualTriangles {
                writer.writeU16(t.a); writer.writeU16(t.b); writer.writeU16(t.c)
            }

            // Bind vertices (rest pose for skinning)
            writer.writeSIMD2Array(mesh.bindVertices)

            // Vertex bone weights: [[VertexBoneWeight]]
            writer.writeU32(UInt32(mesh.vertexBoneWeights.count))
            for influences in mesh.vertexBoneWeights {
                writer.writeU8(UInt8(min(influences.count, 255)))
                for w in influences.prefix(255) {
                    writer.writeUUID(w.boneID)
                    writer.writeF32(w.weight)
                }
            }

            // Inverse bind matrices
            writer.writeU32(UInt32(mesh.boneInverseBindMatrices.count))
            for (boneID, m) in mesh.boneInverseBindMatrices {
                writer.writeUUID(boneID)
                writer.writeMatrix4x4(m.matrix)
            }
        }

        writer.closeChunk(at: off)
    }

    // MARK: - ANIMATIONS chunk

    private func writeAnimationsChunk(into writer: inout BinaryWriter, scene: SceneManager) {
        let off = writer.openChunk(.animations)
        writer.writeU16(UMeshBinaryFormat.ChunkVersion.animations)

        // Collect: bones + images each carry an AnimationClip.
        // We emit one clip per source, keyed by ownerID (bone or image).
        var clips: [(ownerID: UUID, clip: AnimationClip)] = []
        for bone in scene.skeleton.orderedBones where !bone.animationClip.tracks.isEmpty {
            clips.append((bone.id, bone.animationClip))
        }
        for image in scene.images where !image.animationClip.tracks.isEmpty {
            clips.append((image.id, image.animationClip))
        }

        writer.writeU32(UInt32(clips.count))

        for (ownerID, clip) in clips {
            writer.writeUUID(ownerID)
            writer.writeUUID(clip.id)
            writer.writeString(clip.name)
            writer.writeU32(UInt32(max(clip.durationInFrames, 0)))

            // Tracks
            writer.writeU32(UInt32(clip.tracks.count))
            for track in clip.tracks {
                writer.writeUUID(track.id)
                writer.writeUUID(track.targetID)
                writer.writeU8(UMeshBinaryFormat.TrackPropertyCode(track.property).rawValue)

                // Keyframes (sorted by frame at construction time)
                writer.writeU32(UInt32(track.keyframes.count))
                for kf in track.keyframes {
                    writeKeyframe(into: &writer, keyframe: kf)
                }
            }
        }

        writer.closeChunk(at: off)
    }

    private func writeKeyframe(into writer: inout BinaryWriter, keyframe kf: Keyframe) {
        writer.writeUUID(kf.id)
        writer.writeI32(Int32(kf.frame))
        writer.writeU8(UMeshBinaryFormat.InterpCode(kf.interpolation).rawValue)

        // Value discriminant + payload
        switch kf.value {
        case .translate(let v):
            writer.writeU8(UMeshBinaryFormat.KeyframeValueCode.translate.rawValue)
            writer.writeSIMD2(v)
        case .rotate(let v):
            writer.writeU8(UMeshBinaryFormat.KeyframeValueCode.rotate.rawValue)
            writer.writeF32(v)
        case .scale(let v):
            writer.writeU8(UMeshBinaryFormat.KeyframeValueCode.scale.rawValue)
            writer.writeSIMD2(v)
        case .shear(let v):
            writer.writeU8(UMeshBinaryFormat.KeyframeValueCode.shear.rawValue)
            writer.writeSIMD2(v)
        case .scalar(let v):
            writer.writeU8(UMeshBinaryFormat.KeyframeValueCode.scalar.rawValue)
            writer.writeF32(v)
        case .flag(let v):
            writer.writeU8(UMeshBinaryFormat.KeyframeValueCode.flag.rawValue)
            writer.writeU8(v ? 1 : 0)
        case .vector2(let v):
            writer.writeU8(UMeshBinaryFormat.KeyframeValueCode.vector2.rawValue)
            writer.writeSIMD2(v)
        case .drawOrder(let ids):
            writer.writeU8(UMeshBinaryFormat.KeyframeValueCode.drawOrder.rawValue)
            writer.writeI32(Int32(ids.count))
            for id in ids { writer.writeUUID(id) }
        case .event(let payload):
            writer.writeU8(UMeshBinaryFormat.KeyframeValueCode.event.rawValue)
            writer.writeU8(payload.intValue != nil ? 1 : 0)
            writer.writeI32(Int32(payload.intValue ?? 0))
            writer.writeU8(payload.floatValue != nil ? 1 : 0)
            writer.writeF32(payload.floatValue ?? 0)
            writer.writeString(payload.stringValue ?? "")
        case .attachment(let id):
            writer.writeU8(UMeshBinaryFormat.KeyframeValueCode.attachment.rawValue)
            writer.writeU8(id != nil ? 1 : 0)
            if let id { writer.writeUUID(id) }
        case .meshDeform:
            break
        }

        // Tangents flags + values (compact: linear/hold keyframes pay 1 byte total)
        var flags = UMeshBinaryFormat.KeyframeFlags(rawValue: 0)
        if kf.inTangent != nil           { flags.insert(.inTangent) }
        if kf.outTangent != nil          { flags.insert(.outTangent) }
        if kf.secondaryInTangent != nil  { flags.insert(.secondaryInTangent) }
        if kf.secondaryOutTangent != nil { flags.insert(.secondaryOutTangent) }
        writer.writeU8(flags.rawValue)
        if let v = kf.inTangent           { writer.writeSIMD2(v) }
        if let v = kf.outTangent          { writer.writeSIMD2(v) }
        if let v = kf.secondaryInTangent  { writer.writeSIMD2(v) }
        if let v = kf.secondaryOutTangent { writer.writeSIMD2(v) }
    }
}
