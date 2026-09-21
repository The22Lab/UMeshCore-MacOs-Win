import Foundation
import simd

// MARK: - Animation source

/// A single animation to export, decoupled from where it is stored. The editor
/// builds these from `AnimationLibrary.animations` (all named animations) or, as
/// a fallback, from the live scene clips for the currently active animation.
struct UMExportAnimationSource {
    var name: String
    var boneClips: [UUID: AnimationClip]
    var imageClips: [UUID: AnimationClip]
    var sceneClip: AnimationClip
    var duration: Int
}

// MARK: - Export options

struct UMJSONExportOptions {
    /// Decimal places retained for floating-point values. UltraMesh floats are
    /// 32-bit, so 6 places is lossless at typical magnitudes while keeping the
    /// file clean and diff-friendly. Set higher to preserve every bit.
    var floatPrecision: Int
    /// Embed PNG bytes (base64) into the file, making it self-contained.
    var embedTextures: Bool

    /// The "Nonessential data" option. When false, values only the *editor*
    /// needs are stripped — bone colors, setup draw order, atlas region names,
    /// the 3D `depth` block, and human-facing metadata. A runtime never reads
    /// them, so a production export is meaningfully smaller.
    var nonessentialData: Bool

    /// The "Animation clean up" option. Removes keys that cannot change what
    /// is rendered: tracks whose every key holds the setup value, and redundant
    /// middle keys on runs of three-or-more identical values. Endpoints are
    /// always kept so timing and holds are preserved exactly.
    var animationCleanUp: Bool

    /// The "Pretty print" option. Off emits the most compact valid JSON.
    var prettyPrint: Bool

    init(floatPrecision: Int = 6,
         embedTextures: Bool = false,
         nonessentialData: Bool = true,
         animationCleanUp: Bool = false,
         prettyPrint: Bool = true) {
        self.floatPrecision = floatPrecision
        self.embedTextures = embedTextures
        self.nonessentialData = nonessentialData
        self.animationCleanUp = animationCleanUp
        self.prettyPrint = prettyPrint
    }
}

// MARK: - Builder

/// Pure, deterministic builder that turns a scene snapshot into a
/// `UMJSONDocument`. Every dictionary-derived collection is sorted by a stable
/// key so exporting an unchanged project twice produces identical output.
struct UMJSONExportBuilder {

    let options: UMJSONExportOptions

    init(options: UMJSONExportOptions = UMJSONExportOptions()) {
        self.options = options
    }

    // Float rounding — the single choke point for precision + determinism.
    private func r(_ v: Float) -> Float {
        guard options.floatPrecision >= 0, v.isFinite else { return v.isFinite ? v : 0 }
        let scale = pow(10.0, Double(options.floatPrecision))
        return Float((Double(v) * scale).rounded() / scale)
    }
    private func r2(_ v: SIMD2<Float>) -> [Float] { [r(v.x), r(v.y)] }

    // MARK: Top-level

    func build(scene: SceneManager,
               assets: AssetManager,
               animations: [UMExportAnimationSource]) -> UMJSONDocument {

        let orderedBones = Self.deterministicBoneOrder(skeleton: scene.skeleton)

        return UMJSONDocument(
            format: "UltraMesh",
            version: UltraMeshJSONExporter.formatVersion,
            engineVersion: "UltraMesh 1.0",
            generator: "UltraMesh JSON Exporter \(UltraMeshJSONExporter.exporterVersion)",
            exportDate: ISO8601DateFormatter().string(from: Date()),
            compatibility: UMJSONCompatibility(
                minRuntimeVersion: "1.0.0",
                featureFlags: ["ik", "transform", "path", "physics", "skins", "events", "drawOrder", "meshSkinning"]
            ),
            metadata: buildMetadata(scene: scene),
            atlas: buildAtlas(scene: scene, assets: assets),
            bones: orderedBones.map { buildBone(scene: scene, bone: $0) },
            slots: buildSlots(scene: scene),
            attachments: buildAttachments(scene: scene),
            meshes: buildMeshes(scene: scene, assets: assets),
            skins: buildSkins(scene: scene),
            constraints: buildConstraints(scene: scene),
            physics: buildPhysics(scene: scene),
            events: buildEvents(scene: scene),
            animations: animations.map { buildAnimation(scene: scene, source: $0) }
        )
    }

    // MARK: Metadata

    private func buildMetadata(scene: SceneManager) -> UMJSONMetadata {
        // The setup draw order is implicit in the `attachments` array order, so
        // it is redundant for a runtime and drops out with nonessential data.
        UMJSONMetadata(
            projectName: options.nonessentialData ? "UltraMeshProject" : "",
            framesPerSecond: scene.projectFramesPerSecond,
            playbackStartFrame: max(scene.playbackStartFrame, 0),
            playbackEndFrame: max(scene.playbackEndFrame, 0),
            units: "pixels",
            drawOrder: options.nonessentialData ? scene.images.map { $0.id.uuidString } : [],
            custom: [:]
        )
    }

    // MARK: Atlas

    private func buildAtlas(scene: SceneManager, assets: AssetManager) -> UMJSONAtlas {
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for image in scene.images where seen.insert(image.assetID).inserted {
            ordered.append(image.assetID)
        }
        let regions = ordered.map { assetID -> UMJSONAtlasRegion in
            let asset = assets.asset(for: assetID)
            var region = UMJSONAtlasRegion(
                id: assetID.uuidString,
                // The human-facing region name is editor convenience; the id and
                // path are what a runtime resolves against.
                name: options.nonessentialData ? (asset?.name ?? "") : "",
                width: r(asset?.size.x ?? 0),
                height: r(asset?.size.y ?? 0),
                embedded: false,
                path: asset?.fileURL.lastPathComponent,
                dataBase64: nil
            )
            if options.embedTextures, let url = asset?.fileURL, let data = try? Data(contentsOf: url) {
                region.embedded = true
                region.dataBase64 = data.base64EncodedString()
                region.path = nil
            }
            return region
        }
        return UMJSONAtlas(regions: regions)
    }

    // MARK: Bones

    private func buildBone(scene: SceneManager, bone: Bone) -> UMJSONBone {
        let t = bone.baseTransform
        // The 3D depth block is editor-only state; a 2D runtime ignores it, so
        // it is dropped when nonessential data is excluded.
        var depth: UMJSONTransformDepth? = nil
        if options.nonessentialData,
           abs(t.position.z) > 1e-6 || abs(t.rotation.x) > 1e-6 || abs(t.rotation.y) > 1e-6 || abs(t.scale.z - 1) > 1e-6 {
            depth = UMJSONTransformDepth(positionZ: r(t.position.z), rotationX: r(t.rotation.x), rotationY: r(t.rotation.y), scaleZ: r(t.scale.z))
        }
        return UMJSONBone(
            id: bone.id.uuidString,
            name: bone.name,
            parent: bone.parentID?.uuidString,
            transform: UMJSONTransform(
                position: [r(t.position.x), r(t.position.y)],
                rotation: r(t.rotation.z),
                scale: [r(t.scale.x), r(t.scale.y)],
                shear: r2(t.skew),
                depth: depth
            ),
            length: r(bone.length),
            // Bone color exists to tint gizmos in the editor. Runtimes never read it.
            color: options.nonessentialData
                ? { let c = bone.color ?? UM.unboundBone; return [r(c.x), r(c.y), r(c.z), r(c.w)] }()
                : nil,
            root: scene.skeleton.rootIDs.contains(bone.id)
        )
    }

    // MARK: Slots

    private func slotMembership(scene: SceneManager) -> [(slot: String, imageIDs: [UUID])] {
        var order: [String] = []
        var map: [String: [UUID]] = [:]
        for image in scene.images {
            let slot = image.effectiveSlotName
            if map[slot] == nil { order.append(slot) }
            map[slot, default: []].append(image.id)
        }
        return order.sorted().map { ($0, map[$0] ?? []) }
    }

    private func buildSlots(scene: SceneManager) -> [UMJSONSlot] {
        slotMembership(scene: scene).map { entry in
            UMJSONSlot(name: entry.slot, attachments: entry.imageIDs.map { $0.uuidString })
        }
    }

    // MARK: Attachments

    private func buildAttachments(scene: SceneManager) -> [UMJSONAttachment] {
        scene.images.map { image in
            let space: String
            let spaceBone: String?
            switch image.animationTransformSpace {
            case .world: space = "world"; spaceBone = nil
            case .boneLocal(let bid): space = "boneLocal"; spaceBone = bid.uuidString
            }
            var binding: UMJSONBoneBinding? = nil
            if let b = image.boneBinding {
                binding = UMJSONBoneBinding(
                    bone: b.boneID.uuidString,
                    localPose: UMJSONAttachmentPose(
                        position: r2(b.localPosition),
                        rotation: r(b.localRotation),
                        scale: r2(b.localScale),
                        shear: r2(b.localSkew)
                    )
                )
            }
            return UMJSONAttachment(
                id: image.id.uuidString,
                name: image.name,
                slot: image.effectiveSlotName,
                region: image.assetID.uuidString,
                mesh: image.mesh.id.uuidString,
                hidden: image.isHidden,
                // Neutral values are left out entirely: a runtime treats an
                // absent colour as untinted, so writing it would be noise.
                color: (image.tintColor.x == 1 && image.tintColor.y == 1 &&
                        image.tintColor.z == 1 && image.tintColor.w == 1)
                    ? nil
                    : [r(image.tintColor.x), r(image.tintColor.y),
                       r(image.tintColor.z), r(image.tintColor.w)],
                blend: image.blendMode == .normal ? nil : image.blendMode.rawValue,
                animationSpace: space,
                animationSpaceBone: spaceBone,
                setupPose: UMJSONAttachmentPose(
                    position: r2(image.basePosition),
                    rotation: r(image.baseRotation),
                    scale: r2(image.baseScale),
                    shear: r2(image.baseSkew)
                ),
                boneBinding: binding
            )
        }
    }

    // MARK: Meshes

    private func buildMeshes(scene: SceneManager, assets: AssetManager) -> [UMJSONMesh] {
        scene.images.map { image in
            let assetSize = assets.asset(for: image.assetID)?.size ?? SIMD2<Float>(64, 64)
            let mesh = image.mesh.vertices.isEmpty
                ? Mesh.makeQuad(name: image.mesh.name, size: assetSize)
                : image.mesh

            let vertices = mesh.vertices.flatMap { [r($0.x), r($0.y)] }
            let uvs = mesh.uvs.flatMap { [r($0.x), r($0.y)] }
            let triangles = mesh.indices.map { Int($0) }
            let hull = mesh.hullVertexIndices.map { Int($0) }
            let edges = mesh.internalEdges.flatMap { [Int($0.a), Int($0.b)] }
            let manual = mesh.manualTriangles.flatMap { [Int($0.a), Int($0.b), Int($0.c)] }

            var bindVertices: [Float]? = nil
            var weights: [[UMJSONMeshWeight]]? = nil
            var invBind: [UMJSONInverseBind]? = nil
            var bindPose: UMJSONAttachmentPose? = nil

            if mesh.hasSkinningData() {
                bindVertices = (mesh.bindVertices.count == mesh.vertices.count ? mesh.bindVertices : mesh.vertices)
                    .flatMap { [r($0.x), r($0.y)] }
                weights = mesh.vertexBoneWeights.map { influences in
                    influences
                        .sorted { $0.boneID.uuidString < $1.boneID.uuidString }
                        .map { UMJSONMeshWeight(bone: $0.boneID.uuidString, weight: r($0.weight)) }
                }
                invBind = mesh.boneInverseBindMatrices
                    .sorted { $0.key.uuidString < $1.key.uuidString }
                    .map { pair in
                        let m = pair.value.matrix
                        return UMJSONInverseBind(bone: pair.key.uuidString, matrix: [
                            r(m.columns.0.x), r(m.columns.0.y), r(m.columns.0.z), r(m.columns.0.w),
                            r(m.columns.1.x), r(m.columns.1.y), r(m.columns.1.z), r(m.columns.1.w),
                            r(m.columns.2.x), r(m.columns.2.y), r(m.columns.2.z), r(m.columns.2.w),
                            r(m.columns.3.x), r(m.columns.3.y), r(m.columns.3.z), r(m.columns.3.w)
                        ])
                    }
                if let p = mesh.bindImagePose {
                    bindPose = UMJSONAttachmentPose(
                        position: r2(p.position), rotation: r(p.rotation),
                        scale: r2(p.scale), shear: r2(p.skew)
                    )
                }
            }

            return UMJSONMesh(
                id: mesh.id.uuidString, name: mesh.name,
                vertices: vertices, uvs: uvs, triangles: triangles,
                hull: hull, edges: edges, manualTriangles: manual,
                bindVertices: bindVertices, weights: weights,
                inverseBindMatrices: invBind, bindPose: bindPose
            )
        }
    }

    // MARK: Skins

    private func buildSkins(scene: SceneManager) -> [UMJSONSkin] {
        scene.skins.map { skin in
            let slots = skin.attachments.keys.sorted().map { slot -> UMJSONSkinSlot in
                // attachments[slot] is UUID?? — described key with inner optional.
                let inner = skin.attachments[slot] ?? nil
                return UMJSONSkinSlot(slot: slot, attachment: inner?.uuidString)
            }
            return UMJSONSkin(
                id: skin.id.uuidString, name: skin.name,
                slots: slots, includes: skin.includedSkinIDs.map { $0.uuidString }
            )
        }
    }

    // MARK: Constraints

    private func buildConstraints(scene: SceneManager) -> UMJSONConstraints {
        let ik = scene.skeleton.ikConstraints.map { c in
            UMJSONIKConstraint(
                id: c.id.uuidString, name: c.name, enabled: c.enabled, order: c.order, mix: r(c.mix),
                bones: c.boneChain.map { $0.uuidString }, target: c.targetBoneID.uuidString,
                bendPositive: c.bendPositive, stretch: c.stretch, compress: c.compress,
                uniformScale: c.uniformScale, softness: r(c.softness)
            )
        }
        let transform = scene.skeleton.transformConstraints.map { c in
            UMJSONTransformConstraint(
                id: c.id.uuidString, name: c.name, enabled: c.enabled, order: c.order, mix: r(c.mix),
                target: c.targetBoneID.uuidString, bones: c.affectedBones.map { $0.uuidString },
                copyPosition: c.copyPosition, copyRotation: c.copyRotation,
                copyScale: c.copyScale, copyShear: c.copyShear,
                positionMix: r(c.positionMix), rotationMix: r(c.rotationMix),
                scaleMix: r(c.scaleMix), shearMix: r(c.shearMix),
                offsetPosition: [r(c.offsetPositionX), r(c.offsetPositionY)],
                offsetRotation: r(c.offsetRotation),
                offsetScale: [r(c.offsetScaleX), r(c.offsetScaleY)],
                offsetShear: r(c.offsetShear)
            )
        }
        let path = scene.skeleton.pathConstraints.map { c in
            UMJSONPathConstraint(
                id: c.id.uuidString, name: c.name, enabled: c.enabled, order: c.order, mix: r(c.mix),
                pathBones: c.pathBones.map { $0.uuidString }, bones: c.bones.map { $0.uuidString },
                position: r(c.position), spacing: r(c.spacing), spacingMode: c.spacingMode.rawValue,
                positionMix: r(c.positionMix), rotateMix: r(c.rotateMix),
                offsetRotation: r(c.offsetRotation), closed: c.closed, reversed: c.reversed,
                rotateMode: c.rotateMode.rawValue
            )
        }
        return UMJSONConstraints(ik: ik, transform: transform, path: path)
    }

    // MARK: Physics

    private func buildPhysics(scene: SceneManager) -> [UMJSONPhysics] {
        scene.skeleton.physicsConstraints.map { c in
            let s = c.settings
            return UMJSONPhysics(
                id: c.id.uuidString, name: c.name, enabled: c.enabled, order: c.order, mix: r(c.mix),
                type: c.physicsType.rawValue, bones: c.affectedBones.map { $0.uuidString },
                settings: UMJSONPhysicsSettings(
                    mass: r(s.mass), damping: r(s.damping), stiffness: r(s.stiffness),
                    gravity: r(s.gravity), drag: r(s.drag), wind: r2(s.wind),
                    stretchLimit: r(s.stretchLimit),
                    angleLimitMin: r(s.angleLimitMin), angleLimitMax: r(s.angleLimitMax)
                )
            )
        }
    }

    // MARK: Events

    private func buildEvents(scene: SceneManager) -> [UMJSONEvent] {
        scene.animationEvents.map { e in
            UMJSONEvent(
                id: e.id.uuidString, name: e.name, int: e.defaultInt, float: r(e.defaultFloat),
                string: e.defaultString, audioPath: e.audioPath, volume: r(e.volume), balance: r(e.balance)
            )
        }
    }

    // MARK: Animations

    private func buildAnimation(scene: SceneManager, source: UMExportAnimationSource) -> UMJSONAnimation {
        // Bones (sorted by id for determinism).
        let boneTimelines = source.boneClips.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { boneID -> UMJSONBoneTimelines? in
            guard let clip = source.boneClips[boneID] else { return nil }
            // The bone's setup pose is what the runtime falls back to, so it is
            // the only safe basis for dropping a constant track.
            let base = scene.skeleton.bones[boneID]?.baseTransform
            let tl = UMJSONBoneTimelines(
                bone: boneID.uuidString,
                translate: keyframes(clip, boneID, .translate,
                                     setup: base.map { .vector(r($0.position.x), r($0.position.y)) }),
                rotate: keyframes(clip, boneID, .rotate,
                                  setup: base.map { .scalar(r($0.rotation.z)) }),
                scale: keyframes(clip, boneID, .scale,
                                 setup: base.map { .vector(r($0.scale.x), r($0.scale.y)) }),
                shear: keyframes(clip, boneID, .shear,
                                 setup: base.map { .vector(r($0.skew.x), r($0.skew.y)) })
            )
            return (tl.translate == nil && tl.rotate == nil && tl.scale == nil && tl.shear == nil) ? nil : tl
        }

        // Attachments.
        let attachmentTimelines = source.imageClips.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { imageID -> UMJSONAttachmentTimelines? in
            guard let clip = source.imageClips[imageID] else { return nil }
            // A bound sprite animates in its binding's local space, so that —
            // not the world base pose — is the fallback the runtime uses.
            let image = scene.images.first { $0.id == imageID }
            let pose = image.map { $0.boneBinding?.localPose ?? $0.basePose }
            let tl = UMJSONAttachmentTimelines(
                attachment: imageID.uuidString,
                translate: keyframes(clip, imageID, .translate,
                                     setup: pose.map { .vector(r($0.position.x), r($0.position.y)) }),
                rotate: keyframes(clip, imageID, .rotate,
                                  setup: pose.map { .scalar(r($0.rotation)) }),
                scale: keyframes(clip, imageID, .scale,
                                 setup: pose.map { .vector(r($0.scale.x), r($0.scale.y)) }),
                shear: keyframes(clip, imageID, .shear,
                                 setup: pose.map { .vector(r($0.skew.x), r($0.skew.y)) }),
                deform: deformKeys(clip, imageID, mesh: image?.mesh)
            )
            return (tl.translate == nil && tl.rotate == nil && tl.scale == nil
                    && tl.shear == nil && tl.deform == nil) ? nil : tl
        }

        // Constraint property timelines (from the scene clip).
        let constraintIDs = Set(scene.skeleton.allConstraints.map { $0.id })
        var constraintTimelines: [UMJSONConstraintTimelines] = []
        for cid in constraintIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            var tracks: [UMJSONConstraintTrack] = []
            for property in AnimationTrackProperty.allCases where property.domain == .constraint {
                let keys = source.sceneClip.keyframes(for: cid, property: property)
                guard !keys.isEmpty else { continue }
                tracks.append(UMJSONConstraintTrack(property: property.rawValue, keys: keys.map { convertKeyframe($0) }))
            }
            if !tracks.isEmpty {
                constraintTimelines.append(UMJSONConstraintTimelines(constraint: cid.uuidString, properties: tracks))
            }
        }

        // Draw order.
        let drawOrderKeys = source.sceneClip
            .keyframes(for: SceneAnimationTarget.drawOrder, property: .drawOrder)
            .map { kf -> UMJSONDrawOrderKey in
                let order = (kf.value.drawOrderValue ?? []).map { $0.uuidString }
                return UMJSONDrawOrderKey(frame: kf.frame, order: order)
            }

        // Events (per definition).
        var eventTimelines: [UMJSONEventTimeline] = []
        for e in scene.animationEvents {
            let keys = source.sceneClip.keyframes(for: e.id, property: .event)
            guard !keys.isEmpty else { continue }
            let evKeys = keys.map { kf -> UMJSONEventKey in
                let p = kf.value.eventPayload
                return UMJSONEventKey(frame: kf.frame, int: p?.intValue, float: p?.floatValue.map { r($0) }, string: p?.stringValue)
            }
            eventTimelines.append(UMJSONEventTimeline(event: e.id.uuidString, keys: evKeys))
        }

        return UMJSONAnimation(
            name: source.name,
            durationFrames: max(source.duration, 0),
            bones: boneTimelines,
            attachments: attachmentTimelines,
            constraints: constraintTimelines,
            drawOrder: drawOrderKeys,
            events: eventTimelines
        )
    }

    /// Converts a track, optionally cleaned.
    ///
    /// `setupPose` is the value the runtime falls back to when a track is
    /// absent. It is REQUIRED for the constant-track rule: dropping a track
    /// whose constant value differs from setup would silently re-pose the rig
    /// (a bone held at 45° would export flat at 0°). Passing nil disables that
    /// rule and only redundant interior keys are removed.
    private func keyframes(_ clip: AnimationClip,
                           _ targetID: UUID,
                           _ property: AnimationTrackProperty,
                           setup: SetupValue?) -> [UMJSONKeyframe]? {
        let keys = clip.keyframes(for: targetID, property: property)
        guard !keys.isEmpty else { return nil }
        let converted = keys.map { convertKeyframe($0) }
        guard options.animationCleanUp else { return converted }
        let cleaned = Self.cleanedTrack(converted, setup: setup)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Mesh-deformation keys for one attachment, or nil when the animation
    /// does not deform it.
    ///
    /// Keys whose vertex count disagrees with the mesh are dropped: the editor
    /// ignores them at playback (`editLocalVertices` requires a matching
    /// count), so exporting them would hand the runtime data the editor itself
    /// would never show.
    private func deformKeys(_ clip: AnimationClip,
                            _ imageID: UUID,
                            mesh: Mesh?) -> [UMJSONDeformKey]? {
        let keys = clip.keyframes(for: imageID, property: .meshDeform)
        guard !keys.isEmpty, let mesh, !mesh.vertices.isEmpty else { return nil }

        var out: [UMJSONDeformKey] = []
        out.reserveCapacity(keys.count)
        for key in keys {
            guard case let .meshDeform(verts) = key.value,
                  verts.count == mesh.vertices.count else { continue }
            var flat: [Float] = []
            flat.reserveCapacity(verts.count * 2)
            for v in verts {
                flat.append(r(v.x))
                flat.append(r(v.y))
            }
            // Only stepped and linear exist here — the editor's deform sampler
            // never consults tangents, so claiming "bezier" would be a lie the
            // runtime could act on.
            out.append(UMJSONDeformKey(frame: key.frame,
                                       interp: key.interpolation == .hold ? "stepped" : "linear",
                                       vertices: flat))
        }
        guard !out.isEmpty else { return nil }

        // A single key that reproduces the rest shape deforms nothing.
        if options.animationCleanUp, out.count == 1,
           out[0].vertices == mesh.vertices.flatMap({ [r($0.x), r($0.y)] }) {
            return nil
        }
        return out
    }

    /// The setup-pose value a track blends away from, in exported form.
    enum SetupValue: Equatable {
        case scalar(Float)
        case vector(Float, Float)

        func matches(_ key: UMJSONKeyframe, epsilon: Float = 1e-5) -> Bool {
            switch self {
            case .scalar(let v):
                guard let s = key.scalar else { return false }
                return abs(s - v) <= epsilon
            case .vector(let x, let y):
                guard let vec = key.vector, vec.count == 2 else { return false }
                return abs(vec[0] - x) <= epsilon && abs(vec[1] - y) <= epsilon
            }
        }
    }

    /// "Animation clean up" for a single track.
    ///
    /// Removes only keys that provably cannot change what is rendered:
    ///
    /// 1. A track whose keys all carry the same value **and** never use Bézier
    ///    **and** whose constant equals the setup value is redundant: removing
    ///    it leaves the runtime on that identical setup value. When the constant
    ///    differs from setup the track is KEPT — dropping it would re-pose the
    ///    rig, which is a silent, visible corruption.
    /// 2. Inside a run of three or more consecutive equal values, the *middle*
    ///    keys are redundant: interpolating between two equal endpoints yields
    ///    that value regardless of curve. The first and last of the run are kept
    ///    so the hold's timing survives exactly.
    ///
    /// Keys carrying Bézier tangents are never removed, because their handles
    /// shape the curve into and out of neighbours even when the values match.
    static func cleanedTrack(_ keys: [UMJSONKeyframe], setup: SetupValue?) -> [UMJSONKeyframe] {
        guard keys.count > 1 else { return keys }

        func sameValue(_ a: UMJSONKeyframe, _ b: UMJSONKeyframe) -> Bool {
            if a.scalar != b.scalar { return false }
            if a.flag != b.flag { return false }
            switch (a.vector, b.vector) {
            case (nil, nil): return true
            case let (l?, r?): return l == r
            default: return false
            }
        }
        func hasCurveData(_ k: UMJSONKeyframe) -> Bool {
            k.interp == "bezier" || k.inTangent != nil || k.outTangent != nil
                || k.secondaryInTangent != nil || k.secondaryOutTangent != nil
        }

        // Rule 1 — a constant, curve-free track is redundant ONLY when its value
        // is the setup value. Without a known setup we must keep it.
        let allEqual = keys.dropFirst().allSatisfy { sameValue($0, keys[0]) }
        if allEqual, !keys.contains(where: hasCurveData),
           let setup, setup.matches(keys[0]) {
            return []
        }

        // Rule 2 — drop interior keys of equal-value runs.
        var out: [UMJSONKeyframe] = []
        out.reserveCapacity(keys.count)
        for (index, key) in keys.enumerated() {
            let isEndpoint = (index == 0 || index == keys.count - 1)
            if isEndpoint || hasCurveData(key) {
                out.append(key)
                continue
            }
            let previous = keys[index - 1]
            let next = keys[index + 1]
            // Interior key surrounded by identical values, and neither
            // neighbour needs it as a curve anchor.
            let redundant = sameValue(previous, key) && sameValue(key, next)
                && !hasCurveData(previous) && !hasCurveData(next)
            if !redundant { out.append(key) }
        }
        return out
    }

    private func convertKeyframe(_ kf: Keyframe) -> UMJSONKeyframe {
        let interp: String
        switch kf.interpolation {
        case .hold: interp = "stepped"
        case .linear: interp = "linear"
        case .bezier: interp = "bezier"
        }

        var scalar: Float? = nil
        var vector: [Float]? = nil
        var flag: Bool? = nil
        switch kf.value {
        case .rotate(let v): scalar = r(v)
        case .scalar(let v): scalar = r(v)
        case .translate(let v): vector = r2(v)
        case .scale(let v): vector = r2(v)
        case .shear(let v): vector = r2(v)
        case .vector2(let v): vector = r2(v)
        case .flag(let v): flag = v
        case .drawOrder, .event, .meshDeform, .attachment: break
        }

        return UMJSONKeyframe(
            frame: kf.frame, interp: interp,
            scalar: scalar, vector: vector, flag: flag,
            inTangent: kf.inTangent.map { r2($0) },
            outTangent: kf.outTangent.map { r2($0) },
            secondaryInTangent: kf.secondaryInTangent.map { r2($0) },
            secondaryOutTangent: kf.secondaryOutTangent.map { r2($0) }
        )
    }

    // MARK: Deterministic bone ordering (DFS from roots, children sorted by id)

    static func deterministicBoneOrder(skeleton: Skeleton) -> [Bone] {
        var out: [Bone] = []
        var visited = Set<UUID>()

        func visit(_ id: UUID) {
            guard visited.insert(id).inserted, let bone = skeleton.bones[id] else { return }
            out.append(bone)
            for childID in skeleton.childrenOf(id).sorted(by: { $0.uuidString < $1.uuidString }) {
                visit(childID)
            }
        }

        for rootID in skeleton.rootIDs { visit(rootID) }
        // Any bone not reachable from a declared root (orphan/defensive).
        for bone in skeleton.bones.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            visit(bone.id)
        }
        return out
    }
}
