import Foundation

// MARK: - Errors & validation

enum UMJSONExportError: LocalizedError {
    case validationFailed(UMJSONValidationReport)
    case encodingFailed(underlying: Error)
    case ioFailure(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .validationFailed(let report):
            return "Export blocked by \(report.errors.count) validation error(s):\n" +
                report.errors.prefix(20).map { "  • \($0.message)" }.joined(separator: "\n")
        case .encodingFailed(let err):
            return "Failed to encode UltraMesh JSON: \(err.localizedDescription)"
        case .ioFailure(let url, let err):
            return "I/O failure writing \(url.lastPathComponent): \(err.localizedDescription)"
        }
    }
}

struct UMJSONValidationIssue: Equatable {
    enum Severity: String { case error, warning }
    var severity: Severity
    var message: String
}

struct UMJSONValidationReport: Equatable {
    var issues: [UMJSONValidationIssue] = []
    var errors: [UMJSONValidationIssue] { issues.filter { $0.severity == .error } }
    var warnings: [UMJSONValidationIssue] { issues.filter { $0.severity == .warning } }
    var isValid: Bool { errors.isEmpty }
}

// MARK: - Options

struct UltraMeshJSONExportRequest {
    var options: UMJSONExportOptions
    /// When false, `exportDate` is emitted as an empty string so the output is
    /// byte-for-byte reproducible (the determinism guarantee).
    var includeExportDate: Bool
    /// When true, `export` throws instead of returning if validation finds errors.
    var strict: Bool

    init(options: UMJSONExportOptions = UMJSONExportOptions(),
         includeExportDate: Bool = true,
         strict: Bool = true) {
        self.options = options
        self.includeExportDate = includeExportDate
        self.strict = strict
    }
}

// MARK: - Exporter

/// Top-level, reusable UltraMesh JSON export API. Deterministic encoder
/// (`sortedKeys`), reference validation, and a clean sectioned pipeline:
/// build → validate → encode → write.
enum UltraMeshJSONExporter {

    static let formatVersion = "1.0.0"
    static let exporterVersion = "1.0.0"

    // MARK: Public API

    /// Serialize a scene to UltraMesh JSON `Data`, returning the validation report.
    /// Throws `UMJSONExportError.validationFailed` when `request.strict` and errors exist.
    static func export(scene: SceneManager,
                       assets: AssetManager,
                       animations: [UMExportAnimationSource],
                       request: UltraMeshJSONExportRequest = UltraMeshJSONExportRequest()
    ) throws -> (data: Data, report: UMJSONValidationReport) {

        let builder = UMJSONExportBuilder(options: request.options)
        var document = builder.build(scene: scene, assets: assets, animations: animations)
        if !request.includeExportDate { document.exportDate = "" }

        let report = validate(document)
        if request.strict && !report.isValid {
            throw UMJSONExportError.validationFailed(report)
        }

        let encoder = JSONEncoder()
        // Sorted keys are what make the output deterministic; pretty printing is
        // the artist-facing toggle and does not affect ordering.
        encoder.outputFormatting = request.options.prettyPrint
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(document)
            return (data, report)
        } catch {
            throw UMJSONExportError.encodingFailed(underlying: error)
        }
    }

    /// Write UltraMesh JSON to `url` atomically.
    @discardableResult
    static func write(scene: SceneManager,
                      assets: AssetManager,
                      animations: [UMExportAnimationSource],
                      to url: URL,
                      request: UltraMeshJSONExportRequest = UltraMeshJSONExportRequest()
    ) throws -> UMJSONValidationReport {
        let (data, report) = try export(scene: scene, assets: assets, animations: animations, request: request)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw UMJSONExportError.ioFailure(url, underlying: error)
        }
        return report
    }

    // MARK: Validation

    /// Reference-integrity validation. Catches every broken cross-reference the
    /// runtime would choke on, plus circular parent/skin chains, before a byte
    /// is written. Non-fatal problems (missing texture bytes/paths) are warnings.
    static func validate(_ doc: UMJSONDocument) -> UMJSONValidationReport {
        var report = UMJSONValidationReport()
        func err(_ m: String) { report.issues.append(.init(severity: .error, message: m)) }
        func warn(_ m: String) { report.issues.append(.init(severity: .warning, message: m)) }

        let boneIDs = Set(doc.bones.map { $0.id })
        let attachmentIDs = Set(doc.attachments.map { $0.id })
        let meshIDs = Set(doc.meshes.map { $0.id })
        let regionIDs = Set(doc.atlas.regions.map { $0.id })
        let eventIDs = Set(doc.events.map { $0.id })
        let skinIDs = Set(doc.skins.map { $0.id })
        let constraintIDs = Set(
            doc.constraints.ik.map { $0.id }
            + doc.constraints.transform.map { $0.id }
            + doc.constraints.path.map { $0.id }
            + doc.physics.map { $0.id }
        )

        // Duplicate ids.
        checkDuplicates(doc.bones.map { $0.id }, "bone", err)
        checkDuplicates(doc.attachments.map { $0.id }, "attachment", err)
        checkDuplicates(doc.meshes.map { $0.id }, "mesh", err)

        // Bones.
        for bone in doc.bones {
            if let parent = bone.parent, !boneIDs.contains(parent) {
                err("Bone '\(bone.name)' references missing parent \(parent).")
            }
        }
        if let cycle = firstBoneCycle(doc.bones) {
            err("Circular bone parent chain detected involving \(cycle).")
        }

        // Attachments.
        for a in doc.attachments {
            if !regionIDs.contains(a.region) { err("Attachment '\(a.name)' references missing atlas region \(a.region).") }
            if let mesh = a.mesh, !meshIDs.contains(mesh) { err("Attachment '\(a.name)' references missing mesh \(mesh).") }
            if let bind = a.boneBinding, !boneIDs.contains(bind.bone) { err("Attachment '\(a.name)' is bound to missing bone \(bind.bone).") }
            if a.animationSpace == "boneLocal", let b = a.animationSpaceBone, !boneIDs.contains(b) {
                err("Attachment '\(a.name)' uses boneLocal space of missing bone \(b).")
            }
        }

        // Meshes.
        for mesh in doc.meshes {
            if let weights = mesh.weights {
                for influences in weights {
                    for w in influences where !boneIDs.contains(w.bone) {
                        err("Mesh '\(mesh.name)' has a weight on missing bone \(w.bone)."); break
                    }
                }
            }
            if let ibs = mesh.inverseBindMatrices {
                for ib in ibs where ib.matrix.count != 16 {
                    err("Mesh '\(mesh.name)' inverse-bind matrix for \(ib.bone) is not 16 floats.")
                }
            }
        }

        // Atlas.
        for region in doc.atlas.regions {
            if !region.embedded && (region.path == nil || region.path!.isEmpty) {
                warn("Atlas region '\(region.name)' has neither embedded bytes nor a path.")
            }
            if region.width <= 0 || region.height <= 0 {
                warn("Atlas region '\(region.name)' has non-positive size.")
            }
        }

        // Constraints.
        for c in doc.constraints.ik {
            validateBoneRefs(c.bones + [c.target], boneIDs, "IK constraint '\(c.name)'", err)
            if c.bones.isEmpty { err("IK constraint '\(c.name)' has an empty bone chain.") }
        }
        for c in doc.constraints.transform {
            validateBoneRefs(c.bones + [c.target], boneIDs, "Transform constraint '\(c.name)'", err)
        }
        for c in doc.constraints.path {
            validateBoneRefs(c.bones + c.pathBones, boneIDs, "Path constraint '\(c.name)'", err)
            if c.pathBones.count < 2 { err("Path constraint '\(c.name)' needs at least 2 path bones.") }
        }
        for c in doc.physics {
            validateBoneRefs(c.bones, boneIDs, "Physics constraint '\(c.name)'", err)
        }

        // Skins.
        for skin in doc.skins {
            for include in skin.includes where !skinIDs.contains(include) {
                err("Skin '\(skin.name)' includes missing skin \(include).")
            }
            for slot in skin.slots {
                if let att = slot.attachment, !attachmentIDs.contains(att) {
                    err("Skin '\(skin.name)' assigns missing attachment \(att) to slot \(slot.slot).")
                }
            }
        }
        if let cycle = firstSkinCycle(doc.skins) {
            warn("Circular skin include chain involving \(cycle) (resolved with visited-set cut).")
        }

        // Animations.
        for anim in doc.animations {
            for tl in anim.bones where !boneIDs.contains(tl.bone) {
                err("Animation '\(anim.name)' animates missing bone \(tl.bone).")
            }
            for tl in anim.attachments where !attachmentIDs.contains(tl.attachment) {
                err("Animation '\(anim.name)' animates missing attachment \(tl.attachment).")
            }
            for tl in anim.constraints where !constraintIDs.contains(tl.constraint) {
                err("Animation '\(anim.name)' animates missing constraint \(tl.constraint).")
            }
            for ev in anim.events where !eventIDs.contains(ev.event) {
                err("Animation '\(anim.name)' fires missing event \(ev.event).")
            }
            for key in anim.drawOrder {
                for id in key.order where !attachmentIDs.contains(id) {
                    err("Animation '\(anim.name)' draw order at frame \(key.frame) lists missing attachment \(id)."); break
                }
            }
        }

        return report
    }

    // MARK: Validation helpers

    private static func validateBoneRefs(_ ids: [String], _ boneIDs: Set<String>, _ label: String, _ err: (String) -> Void) {
        for id in ids where !boneIDs.contains(id) {
            err("\(label) references missing bone \(id).")
        }
    }

    private static func checkDuplicates(_ ids: [String], _ label: String, _ err: (String) -> Void) {
        var seen = Set<String>()
        for id in ids where !seen.insert(id).inserted {
            err("Duplicate \(label) id \(id).")
        }
    }

    private static func firstBoneCycle(_ bones: [UMJSONBone]) -> String? {
        let parentOf = Dictionary(uniqueKeysWithValues: bones.map { ($0.id, $0.parent) })
        for bone in bones {
            var visited = Set<String>()
            var current: String? = bone.id
            while let id = current {
                if !visited.insert(id).inserted { return bone.id }
                current = parentOf[id] ?? nil
            }
        }
        return nil
    }

    private static func firstSkinCycle(_ skins: [UMJSONSkin]) -> String? {
        let includesOf = Dictionary(uniqueKeysWithValues: skins.map { ($0.id, $0.includes) })
        var globalVisited = Set<String>()

        func dfs(_ id: String, _ onPath: inout Set<String>) -> Bool {
            if onPath.contains(id) { return true }
            if globalVisited.contains(id) { return false }
            globalVisited.insert(id)
            onPath.insert(id)
            for inc in includesOf[id] ?? [] {
                if dfs(inc, &onPath) { return true }
            }
            onPath.remove(id)
            return false
        }

        for skin in skins {
            var onPath = Set<String>()
            if dfs(skin.id, &onPath) { return skin.id }
        }
        return nil
    }
}

// MARK: - AnimationLibrary → export sources

extension UMExportAnimationSource {

    /// Builds the export list from the animation library. When the library has
    /// no saved animations, falls back to a single animation captured from the
    /// live scene clips (the currently active timeline), so a project that was
    /// never "saved as animation" still exports its working animation.
    @MainActor
    static func gather(scene: SceneManager, library: AnimationLibrary?) -> [UMExportAnimationSource] {
        if let library, !library.animations.isEmpty {
            return library.animations
                .sorted { $0.name < $1.name }
                .map { named in
                    UMExportAnimationSource(
                        name: named.name,
                        boneClips: named.boneClips,
                        imageClips: named.imageClips,
                        sceneClip: named.sceneClip,
                        duration: named.duration
                    )
                }
        }

        // Fallback: snapshot the live scene as one animation.
        var boneClips: [UUID: AnimationClip] = [:]
        for bone in scene.skeleton.bones.values where !bone.animationClip.tracks.isEmpty {
            boneClips[bone.id] = bone.animationClip
        }
        var imageClips: [UUID: AnimationClip] = [:]
        for image in scene.images where !image.animationClip.tracks.isEmpty {
            imageClips[image.id] = image.animationClip
        }
        let duration = max(
            boneClips.values.map { $0.durationInFrames }.max() ?? 0,
            imageClips.values.map { $0.durationInFrames }.max() ?? 0,
            scene.sceneAnimationClip.durationInFrames
        )
        guard !boneClips.isEmpty || !imageClips.isEmpty || !scene.sceneAnimationClip.tracks.isEmpty else {
            return []
        }
        return [UMExportAnimationSource(
            name: "Animation",
            boneClips: boneClips,
            imageClips: imageClips,
            sceneClip: scene.sceneAnimationClip,
            duration: duration
        )]
    }
}

// MARK: - ExportManager integration

extension ExportManager {

    /// Exports the scene as an UltraMesh JSON interchange file — the official,
    /// engine-agnostic format for the Unity runtime and every future runtime.
    /// Non-destructive: the binary `.umesh` path is untouched.
    @discardableResult
    func exportUltraMeshJSON(
        scene: SceneManager,
        assets: AssetManager,
        library: AnimationLibrary?,
        to url: URL,
        request: UltraMeshJSONExportRequest = UltraMeshJSONExportRequest()
    ) async throws -> UMJSONValidationReport {
        let animations = UMExportAnimationSource.gather(scene: scene, library: library)
        return try UltraMeshJSONExporter.write(
            scene: scene, assets: assets, animations: animations, to: url, request: request
        )
    }
}
