import CxxStdlib
import Foundation
import simd
import UMeshCore

// Phase 6a, stage B: sprites and what hangs off them -- the mesh, the bone
// binding, the animation space -- plus the three flat lists the panels read:
// hierarchy rows, skins, and event definitions.
//
// Same rule as the rest of `Bridge/`: a copy, field for field, both ways.

// MARK: - Mesh

extension MeshEdge {
    /// Through `makeMeshEdge`, not by assigning `a`/`b`: both sides order
    /// the two ends, and going through the constructor keeps that true.
    init(core: umeshcore.MeshEdge) { self.init(core.a, core.b) }
    var core: umeshcore.MeshEdge { umeshcore.makeMeshEdge(a, b) }
}

extension MeshTriangle {
    init(core: umeshcore.MeshTriangle) { self.init(core.a, core.b, core.c) }
    var core: umeshcore.MeshTriangle { umeshcore.makeMeshTriangle(a, b, c) }
}

extension VertexBoneWeight {
    init(core: umeshcore.VertexBoneWeight) {
        self.init(boneID: UUID(core: core.boneID), weight: core.weight)
    }

    var core: umeshcore.VertexBoneWeight {
        var out = umeshcore.VertexBoneWeight()
        out.boneID = boneID.core
        out.weight = weight
        return out
    }
}

extension MeshBindPose {
    init(core: umeshcore.MeshBindPose) {
        self.init(
            position: SIMD2<Float>(core: core.position),
            rotation: core.rotation,
            scale: SIMD2<Float>(core: core.scale),
            skew: SIMD2<Float>(core: core.skew)
        )
    }

    var core: umeshcore.MeshBindPose {
        var out = umeshcore.MeshBindPose()
        out.position = position.core
        out.rotation = rotation
        out.scale = scale.core
        out.skew = skew.core
        return out
    }
}

extension Mesh {
    init(core: umeshcore.Mesh) {
        var inverseBinds: [UUID: SavedMatrix4x4] = [:]
        for entry in umeshcore.meshInverseBinds(core) {
            inverseBinds[UUID(core: entry.boneID)] = SavedMatrix4x4(simd_float4x4(core: entry.matrix))
        }
        self.init(
            id: UUID(core: core.id),
            name: String(core.name),
            vertices: CoreVec2.list(core.vertices),
            uvs: CoreVec2.list(core.uvs),
            indices: core.indices.map { $0 },
            hullVertexIndices: core.hullVertexIndices.map { $0 },
            internalEdges: core.internalEdges.map { MeshEdge(core: $0) },
            manualTriangles: core.manualTriangles.map { MeshTriangle(core: $0) },
            vertexBoneWeights: core.vertexBoneWeights.map { row in row.map { VertexBoneWeight(core: $0) } },
            bindVertices: CoreVec2.list(core.bindVertices),
            boneInverseBindMatrices: inverseBinds,
            bindImagePose: umeshcore.optionalHasMeshBindPose(core.bindImagePose)
                ? MeshBindPose(core: umeshcore.optionalMeshBindPose(core.bindImagePose))
                : nil
        )
    }

    var core: umeshcore.Mesh {
        var out = umeshcore.Mesh()
        out.id = id.core
        out.name = std.string(name)
        out.vertices = CoreVec2.list(vertices)
        out.uvs = CoreVec2.list(uvs)

        var indexList = umeshcore.U16List()
        for index in indices { indexList.push_back(index) }
        out.indices = indexList

        var hullList = umeshcore.U16List()
        for index in hullVertexIndices { hullList.push_back(index) }
        out.hullVertexIndices = hullList

        var edges = umeshcore.MeshEdgeList()
        for edge in internalEdges { edges.push_back(edge.core) }
        out.internalEdges = edges

        var triangles = umeshcore.MeshTriangleList()
        for triangle in manualTriangles { triangles.push_back(triangle.core) }
        out.manualTriangles = triangles

        var table = umeshcore.VertexWeightTable()
        for row in vertexBoneWeights {
            var weights = umeshcore.VertexWeightList()
            for weight in row { weights.push_back(weight.core) }
            table.push_back(weights)
        }
        out.vertexBoneWeights = table

        out.bindVertices = CoreVec2.list(bindVertices)

        var binds = umeshcore.BoneInverseBindList()
        for (boneID, matrix) in boneInverseBindMatrices {
            var entry = umeshcore.BoneInverseBind()
            entry.boneID = boneID.core
            entry.matrix = matrix.matrix.core
            binds.push_back(entry)
        }
        umeshcore.setMeshInverseBinds(&out, binds)

        out.bindImagePose = umeshcore.makeOptionalMeshBindPose(
            bindImagePose != nil,
            (bindImagePose ?? MeshBindPose(position: .zero, rotation: 0, scale: .one, skew: .zero)).core
        )
        return out
    }
}

// MARK: - Sprites

extension BoneImageBinding {
    init(core: umeshcore.BoneImageBinding) {
        self.init(
            boneID: UUID(core: core.boneID),
            localPosition: SIMD2<Float>(core: core.localPosition),
            localScale: SIMD2<Float>(core: core.localScale),
            localRotation: core.localRotation,
            localSkew: SIMD2<Float>(core: core.localSkew)
        )
    }

    var core: umeshcore.BoneImageBinding {
        var out = umeshcore.BoneImageBinding()
        out.boneID = boneID.core
        out.localPosition = localPosition.core
        out.localScale = localScale.core
        out.localRotation = localRotation
        out.localSkew = localSkew.core
        return out
    }
}

extension TransformAnimationSpace {
    /// UMeshCore spells the enum as "an optional bone": none is world space.
    init(core: umeshcore.TransformAnimationSpace) {
        if let boneID = CoreUUID.optional(core.boneID) {
            self = .boneLocal(boneID)
        } else {
            self = .world
        }
    }

    var core: umeshcore.TransformAnimationSpace {
        var out = umeshcore.TransformAnimationSpace()
        out.boneID = CoreUUID.optional(boneID)
        return out
    }
}

extension SceneImage {
    init(core: umeshcore.SceneImage) {
        let binding: BoneImageBinding? = umeshcore.optionalHasBoneImageBinding(core.boneBinding)
            ? BoneImageBinding(core: umeshcore.optionalBoneImageBinding(core.boneBinding))
            : nil
        self.init(
            id: UUID(core: core.id),
            assetID: UUID(core: core.assetID),
            name: String(core.name),
            basePosition: SIMD2<Float>(core: core.basePosition),
            position: SIMD2<Float>(core: core.position),
            baseScale: SIMD2<Float>(core: core.baseScale),
            scale: SIMD2<Float>(core: core.scale),
            baseRotation: core.baseRotation,
            rotation: core.rotation,
            baseRotation3D: SIMD3<Float>(core: core.baseRotation3D),
            rotation3D: SIMD3<Float>(core: core.rotation3D),
            baseSkew: SIMD2<Float>(core: core.baseSkew),
            skew: SIMD2<Float>(core: core.skew),
            mesh: Mesh(core: core.mesh),
            meshAnimationDeform: CoreVec2.optionalList(core.meshAnimationDeform),
            boneBinding: binding,
            isHidden: core.isHidden,
            slotName: String(core.slotName),
            normalMapAssetID: CoreUUID.optional(core.normalMapAssetID),
            tintColor: SIMD4<Float>(core: core.tintColor),
            blendMode: ImageBlendMode(core: core.blendMode),
            animationClip: AnimationClip(core: core.animationClip),
            animationTransformSpace: TransformAnimationSpace(core: core.animationTransformSpace)
        )
    }

    var core: umeshcore.SceneImage {
        var out = umeshcore.SceneImage()
        out.id = id.core
        out.assetID = assetID.core
        out.name = std.string(name)
        out.basePosition = basePosition.core
        out.position = position.core
        out.baseScale = baseScale.core
        out.scale = scale.core
        out.baseRotation = baseRotation
        out.rotation = rotation
        out.baseRotation3D = baseRotation3D.core
        out.rotation3D = rotation3D.core
        out.baseSkew = baseSkew.core
        out.skew = skew.core
        out.mesh = mesh.core
        out.meshAnimationDeform = CoreVec2.optionalList(meshAnimationDeform)
        out.boneBinding = umeshcore.makeOptionalBoneImageBinding(
            boneBinding != nil,
            (boneBinding ?? BoneImageBinding(
                boneID: CoreUUID.zero, localPosition: .zero, localScale: .one,
                localRotation: 0, localSkew: .zero)).core
        )
        out.isHidden = isHidden
        out.slotName = std.string(slotName)
        out.normalMapAssetID = CoreUUID.optional(normalMapAssetID)
        out.tintColor = tintColor.core
        out.blendMode = blendMode.core
        out.animationClip = animationClip.core
        out.animationTransformSpace = animationTransformSpace.core
        return out
    }
}

// MARK: - Hierarchy, skins, events

extension HierarchyItem {
    init(core: umeshcore.HierarchyItem) {
        self.init(
            id: UUID(core: core.id),
            name: String(core.name),
            type: HierarchyItem.ItemType(core: core.type),
            isHidden: core.isHidden,
            children: core.children.map { HierarchyItem(core: $0) },
            order: Int(core.order)
        )
    }

    var core: umeshcore.HierarchyItem {
        var out = umeshcore.HierarchyItem()
        out.id = id.core
        out.name = std.string(name)
        out.type = type.core
        out.isHidden = isHidden
        var list = umeshcore.HierarchyItemList()
        for child in children { list.push_back(child.core) }
        out.children = list
        out.order = CoreScalar.int32(order)
        return out
    }
}

extension Skin {
    init(core: umeshcore.Skin) {
        // A present key with a nil value is a slot the skin EMPTIES, which is
        // not the same as a slot it does not mention. `hasImage` carries it.
        var attachments: [String: UUID?] = [:]
        for entry in umeshcore.skinSlotEntries(core) {
            let imageID: UUID? = entry.hasImage ? UUID(core: entry.imageID) : nil
            attachments[String(entry.slot)] = .some(imageID)
        }
        self.init(
            id: UUID(core: core.id),
            name: String(core.name),
            attachments: attachments,
            includedSkinIDs: CoreUUID.list(core.includedSkinIDs)
        )
    }

    var core: umeshcore.Skin {
        var out = umeshcore.Skin()
        out.id = id.core
        out.name = std.string(name)
        var entries = umeshcore.SkinSlotEntryList()
        for (slot, imageID) in attachments {
            var entry = umeshcore.SkinSlotEntry()
            entry.slot = std.string(slot)
            entry.hasImage = imageID != nil
            entry.imageID = (imageID ?? CoreUUID.zero).core
            entries.push_back(entry)
        }
        umeshcore.setSkinSlotEntries(&out, entries)
        out.includedSkinIDs = CoreUUID.list(includedSkinIDs)
        return out
    }
}

extension AnimationEvent {
    init(core: umeshcore.AnimationEvent) {
        self.init(
            id: UUID(core: core.id),
            name: String(core.name),
            defaultInt: Int(core.defaultInt),
            defaultFloat: core.defaultFloat,
            defaultString: String(core.defaultString),
            audioPath: String(core.audioPath),
            volume: core.volume,
            balance: core.balance
        )
    }

    var core: umeshcore.AnimationEvent {
        var out = umeshcore.AnimationEvent()
        out.id = id.core
        out.name = std.string(name)
        out.defaultInt = CoreScalar.int32(defaultInt)
        out.defaultFloat = defaultFloat
        out.defaultString = std.string(defaultString)
        out.audioPath = std.string(audioPath)
        out.volume = volume
        out.balance = balance
        return out
    }
}
