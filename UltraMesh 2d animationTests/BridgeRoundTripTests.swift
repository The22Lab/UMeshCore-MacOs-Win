import CxxStdlib
import simd
import UMeshCore
import XCTest
@testable import UltraMesh

/// Phase 6a, stage B, first slice: `Bridge/` copies every model type between
/// the Swift structs the views hold and UMeshCore's, and back.
///
/// The property is the round trip: `X(core: x.core) == x`. Each fixture sets
/// EVERY field away from its default -- a field the bridge forgets comes
/// back as the default and fails the comparison, where a fixture built from
/// defaults would pass with the field missing.
///
/// The C++ half of the bridge has its own suite
/// (`UMeshCore/tests/SwiftModelBridgeTests.cpp`). This one exists because
/// the Swift half can only be compiled here, on the Mac: if a test in this
/// file fails, the failure is in `Bridge/*.swift`.
@MainActor
final class BridgeRoundTripTests: XCTestCase {

    // MARK: - Leaves

    /// The same bytes on both sides: the C++ string of a converted id is
    /// Foundation's `uuidString`, character for character. A byte-order
    /// mistake would still round-trip (it is undone on the way back) and
    /// only this comparison catches it.
    func testUUIDKeepsItsByteOrder() {
        let id = UUID(uuidString: "01234567-89AB-CDEF-0011-223344556677")!
        XCTAssertEqual(String(id.core.toString()), id.uuidString)
        let back = CoreUUID.uuid(id.core)
        XCTAssertEqual(back, id)
        XCTAssertEqual(CoreUUID.optional(CoreUUID.optional(nil as UUID?)), nil)
        XCTAssertEqual(CoreUUID.optional(CoreUUID.optional(id)), id)
        // The all-zero id is a value, not an absence.
        XCTAssertEqual(CoreUUID.optional(CoreUUID.optional(CoreUUID.zero)), CoreUUID.zero)
    }

    func testVectorsAndMatricesRoundTrip() {
        let v2 = SIMD2<Float>(1.5, -2)
        let v3 = SIMD3<Float>(0.25, 4, -8)
        let v4 = SIMD4<Float>(1, 0.5, 0.25, 0.125)
        XCTAssertEqual(SIMD2<Float>(core: v2.core), v2)
        XCTAssertEqual(SIMD3<Float>(core: v3.core), v3)
        XCTAssertEqual(SIMD4<Float>(core: v4.core), v4)

        // Distinct numbers in every slot, so a transposition shows.
        let m = simd_float4x4(columns: (
            SIMD4<Float>(1, 2, 3, 4), SIMD4<Float>(5, 6, 7, 8),
            SIMD4<Float>(9, 10, 11, 12), SIMD4<Float>(13, 14, 15, 16)))
        XCTAssertEqual(simd_float4x4(core: m.core), m)
        // Column 3 is the translation on both sides.
        XCTAssertEqual(SIMD4<Float>(core: umeshcore.mat4Column(m.core, 3)), SIMD4<Float>(13, 14, 15, 16))

        let t = Transform3D2D(position: v3, rotation: SIMD3<Float>(0.1, 0.2, 0.3),
                              scale: SIMD3<Float>(2, 3, 4), skew: v2)
        XCTAssertEqual(Transform3D2D(core: t.core), t)
    }

    /// Every Swift case of every String-backed enum pairs with a UMeshCore
    /// case and comes back as itself -- and the C++ side has no case the
    /// Swift side lacks (the table would have stopped the app building it).
    func testEveryEnumCasePairs() {
        XCTAssertEqual(CoreEnums.trackProperty.count, AnimationTrackProperty.allCases.count)
        for value in AnimationTrackProperty.allCases {
            XCTAssertEqual(AnimationTrackProperty(core: value.core), value)
            XCTAssertEqual(String(cString: umeshcore.trackPropertyName(value.core)), value.rawValue)
        }
        XCTAssertEqual(CoreEnums.interpolation.count, KeyframeInterpolation.allCases.count)
        for value in KeyframeInterpolation.allCases {
            XCTAssertEqual(KeyframeInterpolation(core: value.core), value)
        }
        XCTAssertEqual(CoreEnums.blendMode.count, ImageBlendMode.allCases.count)
        for value in ImageBlendMode.allCases { XCTAssertEqual(ImageBlendMode(core: value.core), value) }
        XCTAssertEqual(CoreEnums.hierarchyItemType.count, HierarchyItem.ItemType.allCases.count)
        for value in HierarchyItem.ItemType.allCases {
            XCTAssertEqual(HierarchyItem.ItemType(core: value.core), value)
        }
        XCTAssertEqual(CoreEnums.pathSpacingMode.count, PathSpacingMode.allCases.count)
        for value in PathSpacingMode.allCases { XCTAssertEqual(PathSpacingMode(core: value.core), value) }
        XCTAssertEqual(CoreEnums.pathRotateMode.count, PathRotateMode.allCases.count)
        for value in PathRotateMode.allCases { XCTAssertEqual(PathRotateMode(core: value.core), value) }
        XCTAssertEqual(CoreEnums.physicsType.count, PhysicsType.allCases.count)
        for value in PhysicsType.allCases { XCTAssertEqual(PhysicsType(core: value.core), value) }
    }

    // MARK: - Animation

    func testEveryKeyframeValueRoundTrips() {
        let a = UUID(), b = UUID()
        let values: [KeyframeValue] = [
            .translate(SIMD2(1, 2)),
            .rotate(0.5),
            .scale(SIMD2(3, 4)),
            .shear(SIMD2(0.1, -0.2)),
            .meshDeform([SIMD2(1, 1), SIMD2(-2, 3)]),
            .meshDeform([]),
            .scalar(0.25),
            .flag(true),
            .vector2(SIMD2(5, 6)),
            .drawOrder([a, b]),
            .event(AnimationEventPayload(intValue: 7, floatValue: nil, stringValue: "step")),
            .event(AnimationEventPayload(intValue: nil, floatValue: 0, stringValue: "")),
            .attachment(a),
            .attachment(nil)
        ]
        for value in values {
            XCTAssertEqual(KeyframeValue(core: value.core), value)
        }
    }

    func testKeyframesTracksAndClipsRoundTrip() {
        let bezier = Keyframe(
            frame: 12, value: .translate(SIMD2(3, 4)), interpolation: .bezier,
            inTangent: SIMD2(-1, 0.5), outTangent: SIMD2(1, -0.5),
            secondaryInTangent: SIMD2(-2, 0), secondaryOutTangent: SIMD2(2, 0))
        XCTAssertEqual(Keyframe(core: bezier.core), bezier)

        // Absent tangents stay absent (not "present and zero").
        let plain = Keyframe(frame: 0, value: .rotate(0), interpolation: .hold)
        let back = Keyframe(core: plain.core)
        XCTAssertEqual(back, plain)
        XCTAssertNil(back.inTangent)

        let track = AnimationTrack(targetID: UUID(), property: .cameraFOV, keyframes: [plain, bezier])
        XCTAssertEqual(AnimationTrack(core: track.core), track)

        let clip = AnimationClip(name: "walk", durationInFrames: 48, tracks: [
            track,
            AnimationTrack(targetID: UUID(), property: .drawOrder,
                           keyframes: [Keyframe(frame: 3, value: .drawOrder([UUID()]))])
        ])
        let clipBack = AnimationClip(core: clip.core)
        XCTAssertEqual(clipBack, clip)
        // Reached through the clip's track index, which only a real
        // assignment of `tracks` rebuilds.
        XCTAssertEqual(clipBack.keyframes(for: track.targetID, property: .cameraFOV).count, 2)
    }

    // MARK: - Rig

    private func constrainedSkeleton() -> Skeleton {
        let root = Bone(name: "root", localTransform: Transform3D2D(position: SIMD3(1, 2, 0)), length: 40)
        let arm = Bone(
            name: "arm", parentID: root.id,
            baseTransform: Transform3D2D(rotation: SIMD3(0, 0, 0.5)),
            localTransform: Transform3D2D(rotation: SIMD3(0, 0, 0.75), skew: SIMD2(0.1, 0)),
            length: 30,
            animationClip: AnimationClip(name: "arm", durationInFrames: 10, tracks: [
                AnimationTrack(targetID: UUID(), property: .rotate,
                               keyframes: [Keyframe(frame: 0, value: .rotate(1))])
            ]),
            color: SIMD4(0.5, 0.25, 1, 1))
        var skeleton = Skeleton(bones: [root.id: root, arm.id: arm], rootIDs: [root.id])
        skeleton.ikConstraints = [IKConstraint(
            name: "ik", enabled: false, order: 7, mix: 0.5, boneChain: [root.id, arm.id],
            targetBoneID: arm.id, bendPositive: false, stretch: true, compress: true,
            uniformScale: true, softness: 12)]
        skeleton.transformConstraints = [TransformConstraint(
            name: "follow", enabled: false, order: 3, mix: 0.25, targetBoneID: root.id,
            affectedBones: [arm.id], copyPosition: true, copyRotation: false, copyScale: true,
            copyShear: true, positionMix: 0.1, rotationMix: 0.2, scaleMix: 0.3, shearMix: 0.4,
            offsetPositionX: 1, offsetPositionY: 2, offsetRotation: 3, offsetScaleX: 4,
            offsetScaleY: 5, offsetShear: 6)]
        skeleton.pathConstraints = [PathConstraint(
            name: "path", enabled: false, order: 9, mix: 0.75, pathBones: [root.id],
            bones: [arm.id], position: 0.5, spacing: 12, spacingMode: .proportional,
            positionMix: 0.6, rotateMix: 0.7, offsetRotation: 0.8, closed: true, reversed: true,
            rotateMode: .chainScale)]
        var settings = PhysicsSettings()
        settings.mass = 2
        settings.wind = SIMD2(3, -1)
        settings.angleLimitMin = -1
        skeleton.physicsConstraints = [PhysicsConstraint(
            name: "hair", enabled: false, order: 101, mix: 0.9, physicsType: .rope,
            affectedBones: [arm.id], settings: settings)]
        return skeleton
    }

    func testBonesAndTheSkeletonRoundTrip() {
        let skeleton = constrainedSkeleton()
        for bone in skeleton.bones.values {
            XCTAssertEqual(Bone(core: bone.core), bone)
        }

        let back = Skeleton(core: skeleton.core)
        XCTAssertEqual(back.bones, skeleton.bones)
        XCTAssertEqual(back.rootIDs, skeleton.rootIDs)
        XCTAssertEqual(back.ikConstraints, skeleton.ikConstraints)
        XCTAssertEqual(back.transformConstraints, skeleton.transformConstraints)
        XCTAssertEqual(back.pathConstraints, skeleton.pathConstraints)
        XCTAssertEqual(back.physicsConstraints, skeleton.physicsConstraints)
    }

    // MARK: - Sprites

    private func boundMesh(boneID: UUID) -> Mesh {
        let bind = simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(-10, 4, 0, 1)))
        return Mesh(
            name: "quad",
            vertices: [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(1, 1)],
            uvs: [SIMD2(0, 1), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 0)],
            indices: [0, 1, 2, 2, 1, 3],
            hullVertexIndices: [0, 1, 3, 2],
            internalEdges: [MeshEdge(2, 1)],
            manualTriangles: [MeshTriangle(0, 1, 2)],
            vertexBoneWeights: [
                [VertexBoneWeight(boneID: boneID, weight: 1)], [],
                [VertexBoneWeight(boneID: boneID, weight: 0.5)], []
            ],
            bindVertices: [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(1, 1)],
            boneInverseBindMatrices: [boneID: SavedMatrix4x4(bind)],
            bindImagePose: MeshBindPose(position: SIMD2(5, 6), rotation: 0.5, scale: SIMD2(2, 2),
                                        skew: SIMD2(3, 0)))
    }

    func testMeshRoundTrips() {
        let mesh = boundMesh(boneID: UUID())
        XCTAssertEqual(Mesh(core: mesh.core), mesh)

        let bare = Mesh(name: "bare")
        let bareBack = Mesh(core: bare.core)
        XCTAssertEqual(bareBack, bare)
        XCTAssertNil(bareBack.bindImagePose)
    }

    func testSceneImageRoundTrips() {
        let boneID = UUID()
        let image = SceneImage(
            id: UUID(), assetID: UUID(), name: "arm",
            basePosition: SIMD2(1, 2), position: SIMD2(3, 4),
            baseScale: SIMD2(1.5, 1.5), scale: SIMD2(2, 0.5),
            baseRotation: 0.25, rotation: 0.5,
            baseRotation3D: SIMD3(0.1, 0.2, 0.3), rotation3D: SIMD3(0.4, 0.5, 0.6),
            baseSkew: SIMD2(5, 0), skew: SIMD2(0, 7),
            mesh: boundMesh(boneID: boneID),
            meshAnimationDeform: [],
            boneBinding: BoneImageBinding(boneID: boneID, localPosition: SIMD2(1, 1),
                                          localScale: SIMD2(2, 3), localRotation: 0.3,
                                          localSkew: SIMD2(4, 0)),
            isHidden: true,
            slotName: "hand",
            normalMapAssetID: UUID(),
            tintColor: SIMD4(1, 0.5, 0.25, 0.75),
            blendMode: .screen,
            animationClip: AnimationClip(name: "arm", durationInFrames: 5),
            animationTransformSpace: .boneLocal(boneID))
        let back = SceneImage(core: image.core)
        XCTAssertEqual(back, image)
        // An EMPTY deform is a key with no vertices, not "no deform".
        XCTAssertEqual(back.meshAnimationDeform, [])

        var plain = image
        plain.meshAnimationDeform = nil
        plain.boneBinding = nil
        plain.normalMapAssetID = nil
        plain.animationTransformSpace = .world
        XCTAssertEqual(SceneImage(core: plain.core), plain)
    }

    // MARK: - Panels

    func testHierarchySkinsAndEventsRoundTrip() {
        let tree = HierarchyItem(name: "root", type: .bone, isHidden: true, children: [
            HierarchyItem(name: "sprite", type: .image, order: 1),
            HierarchyItem(name: "mesh", type: .mesh, children: [
                HierarchyItem(name: "leaf", type: .image, order: 3)
            ], order: 2)
        ], order: 4)
        XCTAssertEqual(HierarchyItem(core: tree.core), tree)

        // "hat" is deliberately emptied; "shoe" is not mentioned. Different.
        let skin = Skin(name: "Winter", attachments: ["hand": UUID(), "hat": nil as UUID?],
                        includedSkinIDs: [UUID(), UUID()])
        let skinBack = Skin(core: skin.core)
        XCTAssertEqual(skinBack, skin)
        XCTAssertTrue(skinBack.attachments.keys.contains("hat"))
        let hat: UUID?? = skinBack.attachments["hat"]
        XCTAssertEqual(hat, Optional<UUID?>.some(nil))
        XCTAssertNil(skinBack.attachments["shoe"])

        let event = AnimationEvent(name: "footstep", defaultInt: 3, defaultFloat: 0.5,
                                   defaultString: "left", audioPath: "step.wav",
                                   volume: 0.75, balance: -0.25)
        XCTAssertEqual(AnimationEvent(core: event.core), event)
    }

    // MARK: - The session

    /// The scene lives in C++ and is reached through the pointer: an
    /// operation run on it is visible to the next read, with nothing copied
    /// in between.
    func testASessionHoldsOneLiveScene() {
        let core = CoreSession()
        XCTAssertEqual(core.session.pointee.scene.images.size(), 0)

        let id = core.session.pointee.scene.addBone(
            umeshcore.Vec2(0, 0), umeshcore.Vec2(0, 50), CoreUUID.optional(nil as UUID?))

        let skeleton = Skeleton(core: core.session.pointee.scene.skeleton)
        XCTAssertEqual(skeleton.bones.count, 1)
        let boneID = CoreUUID.uuid(id)
        let bone = skeleton.bones[boneID]
        XCTAssertNotNil(bone)
        XCTAssertEqual(bone?.length ?? 0, 50, accuracy: 1e-4)
    }
}
