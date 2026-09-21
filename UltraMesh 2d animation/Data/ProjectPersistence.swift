import Foundation
import CryptoKit
import simd
import SwiftUI
import UniformTypeIdentifiers

struct SavedProjectDocument: Codable {
    var version: Int
    var currentFrame: Int
    var playbackLoops: Bool
    var playbackStartFrame: Int
    var playbackEndFrame: Int
    var camera: SavedCameraState
    var assets: [SavedTextureAsset]
    var images: [SavedSceneImage]
    var skeleton: SavedSkeleton
    var hierarchyItems: [SavedHierarchyItem]
    var editorState: SavedEditorState
    /// Constraint property and draw order timelines. Optional so projects saved
    /// before these timelines existed still open.
    var sceneAnimationClip: SavedAnimationClip?
    /// Authored constraint values for animated properties.
    var constraintSetupValues: [SavedConstraintSetupValues]?
    /// Project frame rate. Optional so projects saved before it existed open at
    /// the previous hardcoded 30 fps.
    var projectFramesPerSecond: Double?
    /// The authored draw order, front to back. Optional so projects saved
    /// before draw order became a list of its own still open: absent means the
    /// order of `images` applies, which is what those projects meant by it.
    var authoredDrawOrder: [UUID]?
    /// Named skins. Optional so pre-skin projects still open.
    var skins: [SavedSkin]?
    /// Event definitions. Optional for the same reason.
    var animationEvents: [SavedAnimationEvent]?
    /// The skin previewed when the project was saved.
    var activeSkinID: UUID?
    /// Scene compositions. Optional so projects saved before Scene existed open
    /// untouched, and absent entirely from projects that never enter the mode.
    var sceneCompositions: [SavedSceneComposition]?
    var selectedSceneCompositionID: UUID?
    /// The Scene fly camera — a viewpoint, saved the way a window position is.
    var sceneViewCamera: SavedSceneViewCamera?
    /// Every named animation. Optional so projects saved before this field
    /// existed open with the one animation their clips carry.
    var animations: [SavedNamedAnimation]?
    /// Which of them was loaded when the project was saved.
    var activeAnimationID: UUID?

    init(
        version: Int,
        currentFrame: Int,
        playbackLoops: Bool,
        playbackStartFrame: Int,
        playbackEndFrame: Int,
        camera: SavedCameraState,
        assets: [SavedTextureAsset],
        images: [SavedSceneImage],
        skeleton: SavedSkeleton,
        hierarchyItems: [SavedHierarchyItem],
        editorState: SavedEditorState,
        sceneAnimationClip: SavedAnimationClip? = nil,
        constraintSetupValues: [SavedConstraintSetupValues]? = nil,
        projectFramesPerSecond: Double? = nil,
        authoredDrawOrder: [UUID]? = nil,
        skins: [SavedSkin]? = nil,
        activeSkinID: UUID? = nil,
        animationEvents: [SavedAnimationEvent]? = nil,
        sceneCompositions: [SavedSceneComposition]? = nil,
        selectedSceneCompositionID: UUID? = nil,
        sceneViewCamera: SavedSceneViewCamera? = nil,
        animations: [SavedNamedAnimation]? = nil,
        activeAnimationID: UUID? = nil
    ) {
        self.version = version
        self.currentFrame = currentFrame
        self.playbackLoops = playbackLoops
        self.playbackStartFrame = playbackStartFrame
        self.playbackEndFrame = playbackEndFrame
        self.camera = camera
        self.assets = assets
        self.images = images
        self.skeleton = skeleton
        self.hierarchyItems = hierarchyItems
        self.editorState = editorState
        self.sceneAnimationClip = sceneAnimationClip
        self.constraintSetupValues = constraintSetupValues
        self.projectFramesPerSecond = projectFramesPerSecond
        self.authoredDrawOrder = authoredDrawOrder
        self.skins = skins
        self.activeSkinID = activeSkinID
        self.animationEvents = animationEvents
        self.sceneCompositions = sceneCompositions
        self.selectedSceneCompositionID = selectedSceneCompositionID
        self.sceneViewCamera = sceneViewCamera
        self.animations = animations
        self.activeAnimationID = activeAnimationID
    }

    /// A project with nothing in it.
    ///
    /// This exists so that NEW and OPEN are the same operation. `AppState`
    /// restores this document through the same path it restores a file
    /// through, which is the only arrangement in which the two cannot drift:
    /// a field added to the document is restored by both, or by neither.
    /// Writing a separate `reset()` that assigns thirty properties is how the
    /// two end up disagreeing about one of them, and the one they disagree
    /// about is whichever was added last.
    ///
    /// `verify_new_project.py` checks two things about it: that every stored
    /// property of this type is named here, so a new field cannot be silently
    /// left out; and that the values match the defaults `SceneManager` declares
    /// for the same settings. The second is the one that matters — these ARE a
    /// second copy of those defaults, and a second copy that nobody compares is
    /// a second copy that is wrong. Three of them were wrong when this was
    /// written.
    static var empty: SavedProjectDocument {
        SavedProjectDocument(
            version: 1,
            currentFrame: 0,
            playbackLoops: true,
            playbackStartFrame: 0,
            playbackEndFrame: 90,
            camera: SavedCameraState(origin: SavedPoint(.zero), zoom: 1, rotation: 0),
            assets: [],
            images: [],
            skeleton: SavedSkeleton(),
            hierarchyItems: [],
            editorState: SavedEditorState(
                selectedImageID: nil,
                selectedImageIDs: [],
                selectedKeyframe: nil,
                selectedKeyframes: [],
                editorModeRawValue: EditorMode.skeleton.rawValue,
                activeToolRawValue: ActiveTool.select.rawValue,
                timelineUnitModeRawValue: "frames",
                isTimelineSnapEnabled: true,
                isTimelineOnionSkinEnabled: false,
                isTimelineGraphVisible: true,
                meshSoftSelectionEnabled: false,
                meshSoftSelectionRadius: 90,
                meshSoftSelectionFeather: 0.55,
                meshSoftSelectionExcludeHull: false,
                timelineSelectedTrackID: nil,
                timelineSelectedFilterRawValue: "all",
                timelineZoomScale: 1.0,
                timelineSelectedGraphChannelID: nil
            ),
            sceneAnimationClip: nil,
            constraintSetupValues: nil,
            projectFramesPerSecond: nil,
            authoredDrawOrder: nil,
            skins: nil,
            activeSkinID: nil,
            animationEvents: nil,
            sceneCompositions: nil,
            selectedSceneCompositionID: nil,
            sceneViewCamera: nil,
            animations: nil,
            activeAnimationID: nil
        )
    }

    @MainActor
    init(
        currentFrame: Int,
        playbackLoops: Bool,
        playbackStartFrame: Int,
        playbackEndFrame: Int,
        camera: CameraState,
        assets: [TextureAsset],
        images: [SceneImage],
        skeleton: Skeleton,
        hierarchyItems: [HierarchyItem],
        editorState: SavedEditorState,
        sceneAnimationClip: AnimationClip? = nil,
        constraintSetupValues: [UUID: ConstraintSetupValues] = [:],
        projectFramesPerSecond: Double? = nil,
        authoredDrawOrder: [UUID] = [],
        skins: [Skin] = [],
        activeSkinID: UUID? = nil,
        animationEvents: [AnimationEvent] = [],
        sceneCompositions: [SceneComposition] = [],
        selectedSceneCompositionID: UUID? = nil,
        sceneViewCamera: SceneViewCamera? = nil,
        animations: [SavedNamedAnimation] = [],
        activeAnimationID: UUID? = nil
    ) {
        self.version = 1
        self.currentFrame = currentFrame
        self.playbackLoops = playbackLoops
        self.playbackStartFrame = max(playbackStartFrame, 0)
        self.playbackEndFrame = max(playbackEndFrame, self.playbackStartFrame)
        self.camera = SavedCameraState(camera: camera)
        self.assets = assets.map(SavedTextureAsset.init)
        self.images = images.map(SavedSceneImage.init)
        self.skeleton = SavedSkeleton(skeleton: skeleton)
        self.hierarchyItems = hierarchyItems.map(SavedHierarchyItem.init)
        self.editorState = editorState
        self.sceneAnimationClip = sceneAnimationClip.map(SavedAnimationClip.init(clip:))
        self.constraintSetupValues = constraintSetupValues.isEmpty
            ? nil
            : constraintSetupValues.map { SavedConstraintSetupValues(constraintID: $0.key, values: $0.value) }
        self.projectFramesPerSecond = projectFramesPerSecond
        self.authoredDrawOrder = authoredDrawOrder
        self.skins = skins.isEmpty ? nil : skins.map(SavedSkin.init(skin:))
        self.activeSkinID = activeSkinID
        self.animationEvents = animationEvents.isEmpty
            ? nil
            : animationEvents.map(SavedAnimationEvent.init(event:))
        // Only written once the mode has been used, keeping files byte-stable
        // for projects that never touch Scene.
        self.sceneCompositions = sceneCompositions.isEmpty
            ? nil
            : sceneCompositions.map(SavedSceneComposition.init)
        self.selectedSceneCompositionID = selectedSceneCompositionID
        self.sceneViewCamera = sceneCompositions.isEmpty
            ? nil
            : sceneViewCamera.map(SavedSceneViewCamera.init)
        self.animations = animations.isEmpty ? nil : animations
        self.activeAnimationID = activeAnimationID
    }

    func restoredSceneCompositions() -> [SceneComposition] {
        sceneCompositions?.map { $0.restored() } ?? []
    }

    /// The saved selection, dropped if it no longer resolves to a stored scene.
    func restoredSelectedSceneCompositionID() -> UUID? {
        guard let selectedSceneCompositionID,
              sceneCompositions?.contains(where: { $0.id == selectedSceneCompositionID }) == true
        else { return nil }
        return selectedSceneCompositionID
    }

    func restoredSceneViewCamera() -> SceneViewCamera? {
        sceneViewCamera?.restored()
    }

    func restoredAnimationEvents() -> [AnimationEvent] {
        animationEvents?.map { $0.restored() } ?? []
    }

    func restoredSkins() -> [Skin] {
        skins?.map { $0.restored() } ?? []
    }

    /// The saved active skin, dropped if it no longer resolves to a stored skin.
    func restoredActiveSkinID() -> UUID? {
        guard let activeSkinID,
              skins?.contains(where: { $0.id == activeSkinID }) == true else { return nil }
        return activeSkinID
    }

    /// Restored frame rate, falling back to the rate the editor used before this
    /// became a document property.
    func restoredProjectFramesPerSecond() -> Double {
        guard let rate = projectFramesPerSecond, rate >= 1 else { return 30 }
        return min(rate, 240)
    }

    /// Restored constraint/draw-order clip, or an empty clip for older projects.
    func restoredSceneAnimationClip() -> AnimationClip {
        sceneAnimationClip?.restoredAnimationClip() ?? AnimationClip(name: "Scene")
    }

    /// Every named animation in the file. Empty for a project saved before the
    /// library was persisted — the clips on the bones and sprites are still
    /// there, so such a project opens with exactly what it had.
    func restoredAnimations() -> [NamedAnimation] {
        (animations ?? []).map { $0.restored() }
    }

    func restoredActiveAnimationID() -> UUID? {
        activeAnimationID
    }

    func restoredConstraintSetupValues() -> [UUID: ConstraintSetupValues] {
        guard let constraintSetupValues else { return [:] }
        var out: [UUID: ConstraintSetupValues] = [:]
        out.reserveCapacity(constraintSetupValues.count)
        for entry in constraintSetupValues {
            out[entry.constraintID] = entry.restored()
        }
        return out
    }
}

struct SavedAnimationEvent: Codable {
    var id: UUID
    var name: String
    var defaultInt: Int
    var defaultFloat: Float
    var defaultString: String
    var audioPath: String
    var volume: Float
    var balance: Float

    init(event: AnimationEvent) {
        id = event.id
        name = event.name
        defaultInt = event.defaultInt
        defaultFloat = event.defaultFloat
        defaultString = event.defaultString
        audioPath = event.audioPath
        volume = event.volume
        balance = event.balance
    }

    func restored() -> AnimationEvent {
        AnimationEvent(
            id: id,
            name: name,
            defaultInt: defaultInt,
            defaultFloat: defaultFloat,
            defaultString: defaultString,
            audioPath: audioPath,
            volume: volume,
            balance: balance
        )
    }
}

/// Codable mirror of `Skin`.
///
/// `attachments` is stored as an array of entries rather than a dictionary
/// because a slot that is deliberately empty carries a `nil` sprite, and a
/// `[String: UUID?]` does not survive a JSON round trip cleanly: an explicit
/// null and an absent key would both decode as absent, collapsing the very
/// distinction the skin model depends on.
/// One clip in a named animation, with the bone or sprite it belongs to.
///
/// A pair rather than a dictionary because that is how the rest of this file
/// writes UUID-keyed maps — `SavedBoneInverseBindMatrix` does the same. JSON has
/// no dictionary key type for UUID, and Swift's fallback encoding for one is an
/// array of alternating keys and values, which is unreadable in a diff.
struct SavedNamedAnimationClip: Codable {
    var targetID: UUID
    var clip: SavedAnimationClip

    @MainActor
    init(targetID: UUID, clip: AnimationClip) {
        self.targetID = targetID
        self.clip = SavedAnimationClip(clip: clip)
    }
}

/// A named animation, whole.
///
/// The library holds every animation the artist has made, and the project file
/// had no field for any of them. Only the ACTIVE animation's clips survived a
/// save — because those live on the bones and sprites and were written with
/// them — so reopening a project silently left one animation and dropped the
/// rest, with the file looking perfectly healthy.
///
/// The scene clip and the setup values travel with it for the reason
/// `NamedAnimation` states: without them an animation loses every draw order and
/// constraint key, and leaves constraints stranded at whatever the outgoing
/// animation last evaluated.
struct SavedNamedAnimation: Codable {
    var id: UUID
    var name: String
    var boneClips: [SavedNamedAnimationClip]
    var imageClips: [SavedNamedAnimationClip]
    var sceneClip: SavedAnimationClip
    var constraintSetupValues: [SavedConstraintSetupValues]
    var duration: Int

    @MainActor
    init(animation: NamedAnimation) {
        id = animation.id
        name = animation.name
        // Sorted so two saves of the same project produce the same file:
        // dictionary order in Swift is not stable between runs.
        boneClips = animation.boneClips
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { SavedNamedAnimationClip(targetID: $0.key, clip: $0.value) }
        imageClips = animation.imageClips
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { SavedNamedAnimationClip(targetID: $0.key, clip: $0.value) }
        sceneClip = SavedAnimationClip(clip: animation.sceneClip)
        constraintSetupValues = animation.constraintSetupValues
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { SavedConstraintSetupValues(constraintID: $0.key, values: $0.value) }
        duration = animation.duration
    }

    func restored() -> NamedAnimation {
        var bones: [UUID: AnimationClip] = [:]
        for entry in boneClips {
            bones[entry.targetID] = entry.clip.restoredAnimationClip()
        }
        var images: [UUID: AnimationClip] = [:]
        for entry in imageClips {
            images[entry.targetID] = entry.clip.restoredAnimationClip()
        }
        var setup: [UUID: ConstraintSetupValues] = [:]
        for entry in constraintSetupValues {
            setup[entry.constraintID] = entry.restored()
        }
        return NamedAnimation(
            id: id,
            name: name,
            boneClips: bones,
            imageClips: images,
            sceneClip: sceneClip.restoredAnimationClip(),
            constraintSetupValues: setup,
            duration: duration
        )
    }
}

struct SavedSkin: Codable {
    struct Entry: Codable {
        var slot: String
        var imageID: UUID?
    }

    var id: UUID
    var name: String
    var attachments: [Entry]
    var includedSkinIDs: [UUID]

    init(skin: Skin) {
        self.id = skin.id
        self.name = skin.name
        self.attachments = skin.attachments
            .map { Entry(slot: $0.key, imageID: $0.value) }
            .sorted { $0.slot < $1.slot }
        self.includedSkinIDs = skin.includedSkinIDs
    }

    func restored() -> Skin {
        var mapping: [String: UUID?] = [:]
        for entry in attachments {
            mapping.updateValue(entry.imageID, forKey: entry.slot)
        }
        return Skin(id: id, name: name, attachments: mapping, includedSkinIDs: includedSkinIDs)
    }
}

/// Codable mirror of `ConstraintSetupValues`, stored as an array so the file
/// keeps a stable, diff-friendly shape rather than a UUID-keyed dictionary.
struct SavedConstraintSetupValues: Codable {
    var constraintID: UUID
    var scalars: [String: Float]
    var flags: [String: Bool]
    var vectors: [String: SavedSIMD2]

    init(constraintID: UUID, values: ConstraintSetupValues) {
        self.constraintID = constraintID
        self.scalars = values.scalars
        self.flags = values.flags
        self.vectors = values.vectors.mapValues(SavedSIMD2.init)
    }

    func restored() -> ConstraintSetupValues {
        var out = ConstraintSetupValues()
        out.scalars = scalars
        out.flags = flags
        out.vectors = vectors.mapValues { $0.simdValue }
        return out
    }
}

struct SavedEditorState: Codable {
    var selectedImageID: UUID?
    var selectedImageIDs: [UUID]
    var selectedKeyframe: SavedSelectedKeyframe?
    var selectedKeyframes: [SavedSelectedKeyframe]
    var editorModeRawValue: String
    var activeToolRawValue: String
    var timelineUnitModeRawValue: String
    var isTimelineSnapEnabled: Bool
    var isTimelineOnionSkinEnabled: Bool
    var isTimelineGraphVisible: Bool
    var meshSoftSelectionEnabled: Bool
    var meshSoftSelectionRadius: Float
    var meshSoftSelectionFeather: Float
    var meshSoftSelectionExcludeHull: Bool
    var timelineSelectedTrackID: String?
    var timelineSelectedFilterRawValue: String
    var timelineZoomScale: Double
    var timelineSelectedGraphChannelID: String?

    init(
        selectedImageID: UUID?,
        selectedImageIDs: [UUID],
        selectedKeyframe: SavedSelectedKeyframe?,
        selectedKeyframes: [SavedSelectedKeyframe],
        editorModeRawValue: String,
        activeToolRawValue: String,
        timelineUnitModeRawValue: String,
        isTimelineSnapEnabled: Bool,
        isTimelineOnionSkinEnabled: Bool,
        isTimelineGraphVisible: Bool,
        meshSoftSelectionEnabled: Bool,
        meshSoftSelectionRadius: Float,
        meshSoftSelectionFeather: Float,
        meshSoftSelectionExcludeHull: Bool,
        timelineSelectedTrackID: String?,
        timelineSelectedFilterRawValue: String,
        timelineZoomScale: Double,
        timelineSelectedGraphChannelID: String?
    ) {
        self.selectedImageID = selectedImageID
        self.selectedImageIDs = selectedImageIDs
        self.selectedKeyframe = selectedKeyframe
        self.selectedKeyframes = selectedKeyframes
        self.editorModeRawValue = editorModeRawValue
        self.activeToolRawValue = activeToolRawValue
        self.timelineUnitModeRawValue = timelineUnitModeRawValue
        self.isTimelineSnapEnabled = isTimelineSnapEnabled
        self.isTimelineOnionSkinEnabled = isTimelineOnionSkinEnabled
        self.isTimelineGraphVisible = isTimelineGraphVisible
        self.meshSoftSelectionEnabled = meshSoftSelectionEnabled
        self.meshSoftSelectionRadius = meshSoftSelectionRadius
        self.meshSoftSelectionFeather = meshSoftSelectionFeather
        self.meshSoftSelectionExcludeHull = meshSoftSelectionExcludeHull
        self.timelineSelectedTrackID = timelineSelectedTrackID
        self.timelineSelectedFilterRawValue = timelineSelectedFilterRawValue
        self.timelineZoomScale = timelineZoomScale
        self.timelineSelectedGraphChannelID = timelineSelectedGraphChannelID
    }

    @MainActor
    init(appState: AppState) {
        selectedImageID = appState.sceneManager.selectedImageID
        selectedImageIDs = Array(appState.sceneManager.selectedImageIDs)
        selectedKeyframe = appState.sceneManager.selectedKeyframe.map(SavedSelectedKeyframe.init)
        selectedKeyframes = appState.sceneManager.selectedKeyframes.map(SavedSelectedKeyframe.init)
        editorModeRawValue = appState.editorMode.rawValue
        activeToolRawValue = appState.toolManager.currentTool.rawValue
        timelineUnitModeRawValue = appState.timelineUnitModeRawValue
        isTimelineSnapEnabled = appState.isTimelineSnapEnabled
        isTimelineOnionSkinEnabled = appState.isTimelineOnionSkinEnabled
        isTimelineGraphVisible = appState.isTimelineGraphVisible
        meshSoftSelectionEnabled = appState.sceneManager.meshSoftSelectionEnabled
        meshSoftSelectionRadius = appState.sceneManager.meshSoftSelectionRadius
        meshSoftSelectionFeather = appState.sceneManager.meshSoftSelectionFeather
        meshSoftSelectionExcludeHull = appState.sceneManager.meshSoftSelectionExcludeHull
        timelineSelectedTrackID = appState.timelineSelectedTrackID
        timelineSelectedFilterRawValue = appState.timelineSelectedFilterRawValue
        timelineZoomScale = appState.timelineZoomScale
        timelineSelectedGraphChannelID = appState.timelineSelectedGraphChannelID
    }
}

struct SavedSelectedKeyframe: Codable {
    var imageID: UUID
    var propertyRawValue: String
    var keyframeID: UUID

    init(_ selection: SelectedKeyframe) {
        imageID = selection.imageID
        propertyRawValue = selection.property.rawValue
        keyframeID = selection.keyframeID
    }

    func restoredSelection() -> SelectedKeyframe {
        SelectedKeyframe(
            imageID: imageID,
            property: AnimationTrackProperty(rawValue: propertyRawValue) ?? .translate,
            keyframeID: keyframeID
        )
    }
}

struct SavedCameraState: Codable {
    var origin: SavedPoint
    var zoom: Double
    var rotation: Double

    init(origin: SavedPoint, zoom: Double, rotation: Double) {
        self.origin = origin
        self.zoom = zoom
        self.rotation = rotation
    }

    @MainActor
    init(camera: CameraState) {
        origin = SavedPoint(camera.origin)
        zoom = Double(camera.zoom)
        rotation = Double(camera.rotation)
    }
}

struct SavedTextureAsset: Codable {
    var id: UUID
    var name: String
    var filePath: String
    /// What this image IS: artwork, or a normal map.
    ///
    /// Optional, and nil means artwork — which is what every asset in every
    /// project saved before normal maps existed was. Stored rather than
    /// re-inferred from the filename on load, because an artist may have
    /// overridden what the name claimed and a project must reopen as it was
    /// saved.
    var role: String?

    @MainActor
    init(asset: TextureAsset) {
        id = asset.id
        name = asset.name
        filePath = asset.fileURL.path
        role = asset.role == .albedo ? nil : asset.role.rawValue
    }
}

struct SavedSceneImage: Codable {
    var id: UUID
    var assetID: UUID
    var name: String
    var basePosition: SavedSIMD2
    var position: SavedSIMD2
    var baseScale: SavedScale2
    var scale: SavedScale2
    var baseRotation: Float
    var rotation: Float
    var baseRotation3D: SavedSIMD3
    var rotation3D: SavedSIMD3
    var baseSkew: SavedSIMD2
    var skew: SavedSIMD2
    var mesh: SavedMesh?
    var boneBinding: SavedBoneImageBinding?
    var isHidden: Bool
    /// Slot membership. Optional so pre-skin projects decode, where every sprite
    /// stands alone under its own name.
    var slotName: String?
    /// The sprite's paired normal map, if it has one.
    ///
    /// Optional and written only when set, so a rig that has never been given
    /// relief saves to exactly the bytes it saved before.
    var normalMapAssetID: UUID?
    /// Optional so projects saved before tinting existed still load.
    var tintColor: [Float]?
    var blendMode: String?
    var animationClip: SavedAnimationClip
    var animationTransformSpace: SavedTransformAnimationSpace?

    @MainActor
    init(image: SceneImage) {
        id = image.id
        assetID = image.assetID
        name = image.name
        basePosition = SavedSIMD2(image.basePosition)
        position = SavedSIMD2(image.position)
        baseScale = SavedScale2(image.baseScale)
        scale = SavedScale2(image.scale)
        baseRotation = image.baseRotation
        rotation = image.rotation
        baseRotation3D = SavedSIMD3(image.baseRotation3D)
        rotation3D = SavedSIMD3(image.rotation3D)
        baseSkew = SavedSIMD2(image.baseSkew)
        skew = SavedSIMD2(image.skew)
        mesh = SavedMesh(mesh: image.mesh)
        boneBinding = image.boneBinding.map(SavedBoneImageBinding.init)
        isHidden = image.isHidden
        slotName = image.slotName.isEmpty ? nil : image.slotName
        normalMapAssetID = image.normalMapAssetID
        // Only written when it differs from the neutral default, keeping saved
        // files unchanged for rigs that never touch tinting.
        let t = image.tintColor
        tintColor = (t.x == 1 && t.y == 1 && t.z == 1 && t.w == 1)
            ? nil : [t.x, t.y, t.z, t.w]
        blendMode = image.blendMode == .normal ? nil : image.blendMode.rawValue
        animationClip = SavedAnimationClip(clip: image.animationClip)
        animationTransformSpace = SavedTransformAnimationSpace(space: image.animationTransformSpace)
    }
}

struct SavedTransformAnimationSpace: Codable {
    enum Kind: String, Codable {
        case world
        case boneLocal
    }

    var kind: Kind
    var boneID: UUID?

    init(space: TransformAnimationSpace) {
        switch space {
        case .world:
            kind = .world
            boneID = nil
        case let .boneLocal(id):
            kind = .boneLocal
            boneID = id
        }
    }

    func restoredSpace(fallbackBoneID: UUID?) -> TransformAnimationSpace {
        switch kind {
        case .world:
            return .world
        case .boneLocal:
            if let resolvedBoneID = boneID ?? fallbackBoneID {
                return .boneLocal(resolvedBoneID)
            }
            return .world
        }
    }
}

struct SavedBoneImageBinding: Codable {
    var boneID: UUID
    var localPosition: SavedSIMD2
    var localScale: SavedScale2
    var localRotation: Float
    var localSkew: SavedSIMD2

    init(binding: BoneImageBinding) {
        boneID = binding.boneID
        localPosition = SavedSIMD2(binding.localPosition)
        localScale = SavedScale2(binding.localScale)
        localRotation = binding.localRotation
        localSkew = SavedSIMD2(binding.localSkew)
    }
}

struct SavedBone: Codable {
    var id: UUID
    var name: String
    var parentID: UUID?
    var basePosition: SavedSIMD3
    var baseRotation: SavedSIMD3
    var baseScale: SavedSIMD3
    var baseSkew: SavedSIMD2
    var position: SavedSIMD3
    var rotation: SavedSIMD3
    var scale: SavedSIMD3
    var skew: SavedSIMD2
    var length: Float
    var animationClip: SavedAnimationClip?
    var color: SavedSIMD4?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentID
        case basePosition
        case baseRotation
        case baseScale
        case baseSkew
        case position
        case rotation
        case scale
        case skew
        case length
        case animationClip
        case color
    }

    init(bone: Bone) {
        id = bone.id
        name = bone.name
        parentID = bone.parentID
        basePosition = SavedSIMD3(bone.baseTransform.position)
        baseRotation = SavedSIMD3(bone.baseTransform.rotation)
        baseScale = SavedSIMD3(bone.baseTransform.scale)
        baseSkew = SavedSIMD2(bone.baseTransform.skew)
        position = SavedSIMD3(bone.localTransform.position)
        rotation = SavedSIMD3(bone.localTransform.rotation)
        scale = SavedSIMD3(bone.localTransform.scale)
        skew = SavedSIMD2(bone.localTransform.skew)
        length = bone.length
        animationClip = SavedAnimationClip(clip: bone.animationClip)
        color = bone.color.map(SavedSIMD4.init)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        position = try container.decode(SavedSIMD3.self, forKey: .position)
        rotation = try container.decode(SavedSIMD3.self, forKey: .rotation)
        scale = try container.decode(SavedSIMD3.self, forKey: .scale)
        skew = try container.decode(SavedSIMD2.self, forKey: .skew)
        basePosition = try container.decodeIfPresent(SavedSIMD3.self, forKey: .basePosition) ?? position
        baseRotation = try container.decodeIfPresent(SavedSIMD3.self, forKey: .baseRotation) ?? rotation
        baseScale = try container.decodeIfPresent(SavedSIMD3.self, forKey: .baseScale) ?? scale
        baseSkew = try container.decodeIfPresent(SavedSIMD2.self, forKey: .baseSkew) ?? skew
        length = try container.decode(Float.self, forKey: .length)
        animationClip = try container.decodeIfPresent(SavedAnimationClip.self, forKey: .animationClip)
        color = try container.decodeIfPresent(SavedSIMD4.self, forKey: .color)
    }
}

struct SavedSkeleton: Codable {
    var bones: [SavedBone]
    var rootIDs: [UUID]
    /// Optional for backward compatibility — projects authored before Transform
    /// Constraints existed decode to an empty array, so old files keep loading.
    var transformConstraints: [SavedTransformConstraint]?
    /// IK, Path and Physics constraints were previously not written to disk at
    /// all, so a rig lost every constraint but its Transform ones on reopen.
    /// Optional for the same backward-compatibility reason.
    var ikConstraints: [SavedIKConstraint]?
    var pathConstraints: [SavedPathConstraint]?
    var physicsConstraints: [SavedPhysicsConstraint]?

    init() {
        bones = []; rootIDs = []
        transformConstraints = nil; ikConstraints = nil
        pathConstraints = nil; physicsConstraints = nil
    }

    init(skeleton: Skeleton) {
        bones = skeleton.orderedBones.map(SavedBone.init)
        rootIDs = skeleton.rootIDs
        transformConstraints = skeleton.transformConstraints.map(SavedTransformConstraint.init)
        ikConstraints = skeleton.ikConstraints.map(SavedIKConstraint.init)
        pathConstraints = skeleton.pathConstraints.map(SavedPathConstraint.init)
        physicsConstraints = skeleton.physicsConstraints.map(SavedPhysicsConstraint.init)
    }
}

struct SavedIKConstraint: Codable {
    var id: UUID
    var name: String
    var enabled: Bool
    var order: Int
    var mix: Float
    var boneChain: [UUID]
    var targetBoneID: UUID
    var bendPositive: Bool
    var stretch: Bool
    var compress: Bool
    var uniformScale: Bool
    var softness: Float

    init(_ c: IKConstraint) {
        id = c.id
        name = c.name
        enabled = c.enabled
        order = c.order
        mix = c.mix
        boneChain = c.boneChain
        targetBoneID = c.targetBoneID
        bendPositive = c.bendPositive
        stretch = c.stretch
        compress = c.compress
        uniformScale = c.uniformScale
        softness = c.softness
    }

    func restored() -> IKConstraint {
        IKConstraint(
            id: id,
            name: name,
            enabled: enabled,
            order: order,
            mix: mix,
            boneChain: boneChain,
            targetBoneID: targetBoneID,
            bendPositive: bendPositive,
            stretch: stretch,
            compress: compress,
            uniformScale: uniformScale,
            softness: softness
        )
    }
}

struct SavedPathConstraint: Codable {
    var id: UUID
    var name: String
    var enabled: Bool
    var order: Int
    var mix: Float
    var pathBones: [UUID]
    var bones: [UUID]
    var position: Float
    var spacing: Float
    var spacingMode: String
    var positionMix: Float
    var rotateMix: Float
    var offsetRotation: Float
    /// Optional: paths saved before closed loops, reversal and rotate modes
    /// existed decode to the previous behaviour.
    var closed: Bool?
    var reversed: Bool?
    var rotateMode: String?

    init(_ c: PathConstraint) {
        id = c.id
        name = c.name
        enabled = c.enabled
        order = c.order
        mix = c.mix
        pathBones = c.pathBones
        bones = c.bones
        position = c.position
        spacing = c.spacing
        spacingMode = c.spacingMode.rawValue
        positionMix = c.positionMix
        rotateMix = c.rotateMix
        offsetRotation = c.offsetRotation
        closed = c.closed
        reversed = c.reversed
        rotateMode = c.rotateMode.rawValue
    }

    func restored() -> PathConstraint {
        PathConstraint(
            id: id,
            name: name,
            enabled: enabled,
            order: order,
            mix: mix,
            pathBones: pathBones,
            bones: bones,
            position: position,
            spacing: spacing,
            spacingMode: PathSpacingMode(rawValue: spacingMode) ?? .length,
            positionMix: positionMix,
            rotateMix: rotateMix,
            offsetRotation: offsetRotation,
            closed: closed ?? false,
            reversed: reversed ?? false,
            rotateMode: rotateMode.flatMap(PathRotateMode.init(rawValue:)) ?? .tangent
        )
    }
}

struct SavedPhysicsSettings: Codable {
    var mass: Float
    var damping: Float
    var stiffness: Float
    var gravity: Float
    var drag: Float
    var wind: SavedSIMD2
    var stretchLimit: Float
    var angleLimitMin: Float
    var angleLimitMax: Float

    init(_ s: PhysicsSettings) {
        mass = s.mass
        damping = s.damping
        stiffness = s.stiffness
        gravity = s.gravity
        drag = s.drag
        wind = SavedSIMD2(s.wind)
        stretchLimit = s.stretchLimit
        angleLimitMin = s.angleLimitMin
        angleLimitMax = s.angleLimitMax
    }

    func restored() -> PhysicsSettings {
        var out = PhysicsSettings()
        out.mass = mass
        out.damping = damping
        out.stiffness = stiffness
        out.gravity = gravity
        out.drag = drag
        out.wind = wind.simdValue
        out.stretchLimit = stretchLimit
        out.angleLimitMin = angleLimitMin
        out.angleLimitMax = angleLimitMax
        return out
    }
}

struct SavedPhysicsConstraint: Codable {
    var id: UUID
    var name: String
    var enabled: Bool
    var order: Int
    var mix: Float
    var physicsType: String
    var affectedBones: [UUID]
    var settings: SavedPhysicsSettings

    init(_ c: PhysicsConstraint) {
        id = c.id
        name = c.name
        enabled = c.enabled
        order = c.order
        mix = c.mix
        physicsType = c.physicsType.rawValue
        affectedBones = c.affectedBones
        settings = SavedPhysicsSettings(c.settings)
    }

    func restored() -> PhysicsConstraint {
        PhysicsConstraint(
            id: id,
            name: name,
            enabled: enabled,
            order: order,
            mix: mix,
            physicsType: PhysicsType(rawValue: physicsType) ?? .spring,
            affectedBones: affectedBones,
            settings: settings.restored()
        )
    }
}

struct SavedTransformConstraint: Codable {
    var id: UUID
    var name: String
    var enabled: Bool
    var order: Int
    var mix: Float

    var targetBoneID: UUID
    var affectedBones: [UUID]

    var copyPosition: Bool
    var copyRotation: Bool
    var copyScale: Bool
    var copyShear: Bool

    var positionMix: Float
    var rotationMix: Float
    var scaleMix: Float
    var shearMix: Float

    var offsetPositionX: Float
    var offsetPositionY: Float
    var offsetRotation: Float
    var offsetScaleX: Float
    var offsetScaleY: Float
    var offsetShear: Float

    init(_ constraint: TransformConstraint) {
        id = constraint.id
        name = constraint.name
        enabled = constraint.enabled
        order = constraint.order
        mix = constraint.mix
        targetBoneID = constraint.targetBoneID
        affectedBones = constraint.affectedBones
        copyPosition = constraint.copyPosition
        copyRotation = constraint.copyRotation
        copyScale = constraint.copyScale
        copyShear = constraint.copyShear
        positionMix = constraint.positionMix
        rotationMix = constraint.rotationMix
        scaleMix = constraint.scaleMix
        shearMix = constraint.shearMix
        offsetPositionX = constraint.offsetPositionX
        offsetPositionY = constraint.offsetPositionY
        offsetRotation = constraint.offsetRotation
        offsetScaleX = constraint.offsetScaleX
        offsetScaleY = constraint.offsetScaleY
        offsetShear = constraint.offsetShear
    }

    func restored() -> TransformConstraint {
        TransformConstraint(
            id: id,
            name: name,
            enabled: enabled,
            order: order,
            mix: mix,
            targetBoneID: targetBoneID,
            affectedBones: affectedBones,
            copyPosition: copyPosition,
            copyRotation: copyRotation,
            copyScale: copyScale,
            copyShear: copyShear,
            positionMix: positionMix,
            rotationMix: rotationMix,
            scaleMix: scaleMix,
            shearMix: shearMix,
            offsetPositionX: offsetPositionX,
            offsetPositionY: offsetPositionY,
            offsetRotation: offsetRotation,
            offsetScaleX: offsetScaleX,
            offsetScaleY: offsetScaleY,
            offsetShear: offsetShear
        )
    }
}

struct SavedVertexBoneWeight: Codable {
    var boneID: UUID
    var weight: Float

    init(_ value: VertexBoneWeight) {
        boneID = value.boneID
        weight = value.weight
    }

    var restored: VertexBoneWeight {
        VertexBoneWeight(boneID: boneID, weight: weight)
    }
}

struct SavedBoneInverseBindMatrix: Codable {
    var boneID: UUID
    var matrix: SavedMatrix4x4

    init(boneID: UUID, matrix: SavedMatrix4x4) {
        self.boneID = boneID
        self.matrix = matrix
    }
}

struct SavedMeshBindPose: Codable {
    var position: SavedSIMD2
    var rotation: Float
    var scale: SavedSIMD2
    var skew: SavedSIMD2

    init(pose: MeshBindPose) {
        position = SavedSIMD2(pose.position)
        rotation = pose.rotation
        scale = SavedSIMD2(pose.scale)
        skew = SavedSIMD2(pose.skew)
    }

    var restored: MeshBindPose {
        MeshBindPose(
            position: position.simdValue,
            rotation: rotation,
            scale: scale.simdValue,
            skew: skew.simdValue
        )
    }
}

struct SavedMesh: Codable {
    var id: UUID
    var name: String
    var vertices: [SavedSIMD2]
    var uvs: [SavedSIMD2]
    var indices: [UInt16]
    var hullVertexIndices: [UInt16]
    var internalEdges: [MeshEdge]
    var manualTriangles: [MeshTriangle]
    var vertexBoneWeights: [[SavedVertexBoneWeight]]
    var bindVertices: [SavedSIMD2]
    var boneInverseBindMatrices: [SavedBoneInverseBindMatrix]
    var bindImagePose: SavedMeshBindPose?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case vertices
        case uvs
        case indices
        case hullVertexIndices
        case internalEdges
        case manualTriangles
        case vertexBoneWeights
        case bindVertices
        case boneInverseBindMatrices
        case bindImagePose
    }

    init(mesh: Mesh) {
        id = mesh.id
        name = mesh.name
        vertices = mesh.vertices.map(SavedSIMD2.init)
        uvs = mesh.uvs.map(SavedSIMD2.init)
        indices = mesh.indices
        hullVertexIndices = mesh.hullVertexIndices
        internalEdges = mesh.internalEdges
        manualTriangles = mesh.manualTriangles
        vertexBoneWeights = mesh.vertexBoneWeights.map { $0.map(SavedVertexBoneWeight.init) }
        bindVertices = mesh.bindVertices.map(SavedSIMD2.init)
        boneInverseBindMatrices = mesh.boneInverseBindMatrices.map { SavedBoneInverseBindMatrix(boneID: $0.key, matrix: $0.value) }
            .sorted { $0.boneID.uuidString < $1.boneID.uuidString }
        bindImagePose = mesh.bindImagePose.map(SavedMeshBindPose.init)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        vertices = try container.decode([SavedSIMD2].self, forKey: .vertices)
        uvs = try container.decode([SavedSIMD2].self, forKey: .uvs)
        indices = try container.decode([UInt16].self, forKey: .indices)
        hullVertexIndices = try container.decode([UInt16].self, forKey: .hullVertexIndices)
        internalEdges = try container.decodeIfPresent([MeshEdge].self, forKey: .internalEdges) ?? []
        manualTriangles = try container.decodeIfPresent([MeshTriangle].self, forKey: .manualTriangles) ?? []
        vertexBoneWeights = try container.decodeIfPresent([[SavedVertexBoneWeight]].self, forKey: .vertexBoneWeights) ?? []
        bindVertices = try container.decodeIfPresent([SavedSIMD2].self, forKey: .bindVertices) ?? []
        boneInverseBindMatrices = try container.decodeIfPresent([SavedBoneInverseBindMatrix].self, forKey: .boneInverseBindMatrices) ?? []
        bindImagePose = try container.decodeIfPresent(SavedMeshBindPose.self, forKey: .bindImagePose)
    }
}

struct SavedAnimationClip: Codable {
    var id: UUID
    var name: String
    var durationInFrames: Int
    var tracks: [SavedAnimationTrack]

    @MainActor
    init(clip: AnimationClip) {
        id = clip.id
        name = clip.name
        durationInFrames = clip.durationInFrames
        tracks = clip.tracks.map(SavedAnimationTrack.init)
    }
}

struct SavedAnimationTrack: Codable {
    var id: UUID
    var targetID: UUID
    var property: String
    var keyframes: [SavedKeyframe]

    @MainActor
    init(track: AnimationTrack) {
        id = track.id
        targetID = track.targetID
        property = track.property.rawValue
        keyframes = track.keyframes.map(SavedKeyframe.init)
    }
}

struct SavedKeyframe: Codable {
    var id: UUID
    var frame: Int
    var value: SavedKeyframeValue
    var interpolation: String
    var inTangent: SavedSIMD2?
    var outTangent: SavedSIMD2?
    var secondaryInTangent: SavedSIMD2?
    var secondaryOutTangent: SavedSIMD2?

    @MainActor
    init(keyframe: Keyframe) {
        id = keyframe.id
        frame = keyframe.frame
        value = SavedKeyframeValue(keyframe.value)
        interpolation = keyframe.interpolation.rawValue
        inTangent = keyframe.inTangent.map(SavedSIMD2.init)
        outTangent = keyframe.outTangent.map(SavedSIMD2.init)
        secondaryInTangent = keyframe.secondaryInTangent.map(SavedSIMD2.init)
        secondaryOutTangent = keyframe.secondaryOutTangent.map(SavedSIMD2.init)
    }
}

struct SavedKeyframeValue: Codable {
    var kind: String
    var scalar: Float?
    var vector2: SavedSIMD2?
    var vectorArray: [SavedSIMD2]?
    /// Boolean payload for IK bend / stretch / compress timelines.
    var flag: Bool?
    /// Sprite ID permutation for the draw order timeline.
    var idArray: [UUID]?
    /// Event payload. Each field stays optional end to end, because "not set"
    /// means "inherit the event definition's default" and must not decode as 0.
    var eventInt: Int?
    var eventFloat: Float?
    var eventString: String?

    @MainActor
    init(_ value: KeyframeValue) {
        flag = nil
        idArray = nil
        eventInt = nil
        eventFloat = nil
        eventString = nil
        switch value {
        case let .translate(vector):
            kind = "translate"
            scalar = nil
            vector2 = SavedSIMD2(vector)
            vectorArray = nil
        case let .rotate(number):
            kind = "rotate"
            scalar = number
            vector2 = nil
            vectorArray = nil
        case let .scale(number):
            kind = "scale"
            scalar = nil
            vector2 = SavedSIMD2(number)
            vectorArray = nil
        case let .shear(vector):
            kind = "shear"
            scalar = nil
            vector2 = SavedSIMD2(vector)
            vectorArray = nil
        case let .meshDeform(vertices):
            kind = "meshDeform"
            scalar = nil
            vector2 = nil
            vectorArray = vertices.map(SavedSIMD2.init)
        case let .scalar(number):
            kind = "scalar"
            scalar = number
            vector2 = nil
            vectorArray = nil
        case let .flag(value):
            kind = "flag"
            scalar = nil
            vector2 = nil
            vectorArray = nil
            flag = value
        case let .vector2(vector):
            kind = "vector2"
            scalar = nil
            vector2 = SavedSIMD2(vector)
            vectorArray = nil
        case let .drawOrder(ids):
            kind = "drawOrder"
            scalar = nil
            vector2 = nil
            vectorArray = nil
            idArray = ids
        case let .attachment(id):
            // The slot's chosen sprite. `nil` — a deliberately empty slot — is
            // an empty id array rather than an absent one, so it survives the
            // round trip as the statement it is.
            kind = "attachment"
            scalar = nil
            vector2 = nil
            vectorArray = nil
            idArray = id.map { [$0] } ?? []
        case let .event(payload):
            kind = "event"
            scalar = nil
            vector2 = nil
            vectorArray = nil
            eventInt = payload.intValue
            eventFloat = payload.floatValue
            eventString = payload.stringValue
        }
    }
}

struct SavedHierarchyItem: Codable {
    var id: UUID
    var name: String
    var type: String
    var isHidden: Bool
    var children: [SavedHierarchyItem]
    var order: Int

    @MainActor
    init(item: HierarchyItem) {
        id = item.id
        name = item.name
        type = item.type.rawValue
        isHidden = item.isHidden
        children = item.children.map(SavedHierarchyItem.init)
        order = item.order
    }
}

struct SavedSIMD2: Codable {
    var x: Float
    var y: Float

    init(_ value: SIMD2<Float>) {
        x = value.x
        y = value.y
    }
}

struct SavedScale2: Codable {
    var x: Float
    var y: Float

    init(_ value: SIMD2<Float>) {
        x = value.x
        y = value.y
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let scalar = try? single.decode(Float.self) {
            x = scalar
            y = scalar
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(Float.self, forKey: .x)
        y = try container.decode(Float.self, forKey: .y)
    }
}

struct SavedSIMD3: Codable {
    var x: Float
    var y: Float
    var z: Float

    init(_ value: SIMD3<Float>) {
        x = value.x
        y = value.y
        z = value.z
    }
}

struct SavedSIMD4: Codable {
    var x: Float
    var y: Float
    var z: Float
    var w: Float

    init(_ value: SIMD4<Float>) {
        x = value.x
        y = value.y
        z = value.z
        w = value.w
    }

    var simd: SIMD4<Float> { SIMD4<Float>(x, y, z, w) }
}

struct SavedPoint: Codable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }
}

enum ProjectPersistence {
    static let projectFileExtension = "umesh"
    static let projectContentType = UTType(exportedAs: "com.the22lab.ultramesh.project", conformingTo: .package)
    static let projectManifestFilename = "project.json"

    // MARK: - Telling the two kinds of .umesh apart

    /// First four bytes of a Unity runtime export: 'U' 'M' 'S' 'H'.
    ///
    /// A project and a Unity export deliberately share the `.umesh` extension,
    /// so the extension cannot decide which is which — the content has to. The
    /// two are structurally unmistakable: a project is a package (a directory
    /// holding `project.json`) or, in older files, flat JSON starting with `{`;
    /// a runtime export is a flat binary starting with this magic.
    static let runtimeExportMagic: [UInt8] = [0x55, 0x4D, 0x53, 0x48]

    /// True when `url` is a flat file that begins with the runtime-export magic.
    static func isRuntimeExport(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: runtimeExportMagic.count)) ?? Data()
        return Array(head) == runtimeExportMagic
    }

    /// True when `url` is a project package: a directory holding the manifest.
    static func isProjectPackage(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        let manifest = url.appendingPathComponent(projectManifestFilename)
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    /// Failures worth explaining in the artist's own terms rather than as a
    /// decoding error from three layers down.
    enum ProjectFileError: LocalizedError {
        case isRuntimeExport(URL)
        case wouldOverwriteProject(URL)

        var errorDescription: String? {
            switch self {
            case .isRuntimeExport(let url):
                return "\u{201C}\(url.lastPathComponent)\u{201D} is a Unity runtime export, not an "
                    + "UltraMesh project.\n\nBoth use the .umesh extension: a project is a "
                    + "package you can keep editing, while an export is a single file for "
                    + "Unity to play back. Open the project you saved with File \u{25B8} Save instead."
            case .wouldOverwriteProject(let url):
                return "\u{201C}\(url.lastPathComponent)\u{201D} is an UltraMesh project, and exporting "
                    + "there would replace it.\n\nBoth use the .umesh extension, so pick a "
                    + "different name or folder for the Unity export \u{2014} the project would be "
                    + "unrecoverable."
            }
        }
    }
    static let bundledAssetsDirectoryName = "Assets"

    static func save(document: SavedProjectDocument, to url: URL) throws {
        let fileWrapper = try makeProjectFileWrapper(for: document)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        try fileWrapper.write(to: url, options: .atomic, originalContentsURL: nil)
    }

    @MainActor
    static func load(from url: URL) throws -> SavedProjectDocument {
        // Check this before anything reads the bytes. A runtime export is valid
        // binary that simply is not a project, and letting it reach the JSON
        // decoder produced "the data couldn't be read because it isn't in the
        // correct format" — true, useless, and indistinguishable from a corrupt
        // project.
        if isRuntimeExport(url) { throw ProjectFileError.isRuntimeExport(url) }

        let fileWrapper = try FileWrapper(url: url, options: .immediate)
        let data: Data
        let projectRootURL: URL

        if fileWrapper.isDirectory {
            guard
                let manifestWrapper = fileWrapper.fileWrappers?[projectManifestFilename],
                let manifestData = manifestWrapper.regularFileContents
            else {
                throw CocoaError(.fileReadCorruptFile)
            }

            data = manifestData
            projectRootURL = url
        } else {
            guard let regularFileData = fileWrapper.regularFileContents else {
                throw CocoaError(.fileReadCorruptFile)
            }

            data = regularFileData
            projectRootURL = url.deletingLastPathComponent()
        }

        let decoder = JSONDecoder()
        let document = try decoder.decode(SavedProjectDocument.self, from: data)
        return document.resolvingAssetPaths(relativeTo: projectRootURL)
    }

    static func makeProjectFileWrapper(for document: SavedProjectDocument) throws -> FileWrapper {
        var storedDocument = document
        let bundledAssets = try makeBundledAssets(from: document.assets)

        for (index, assetPath) in bundledAssets.relativePaths.enumerated() {
            storedDocument.assets[index].filePath = assetPath
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(storedDocument)

        let manifestWrapper = FileWrapper(regularFileWithContents: manifestData)
        manifestWrapper.preferredFilename = projectManifestFilename

        let assetsDirectoryWrapper = FileWrapper(directoryWithFileWrappers: bundledAssets.fileWrappers)
        assetsDirectoryWrapper.preferredFilename = bundledAssetsDirectoryName

        return FileWrapper(directoryWithFileWrappers: [
            projectManifestFilename: manifestWrapper,
            bundledAssetsDirectoryName: assetsDirectoryWrapper
        ])
    }

    private static func makeBundledAssets(from assets: [SavedTextureAsset]) throws -> (relativePaths: [String], fileWrappers: [String: FileWrapper]) {
        var relativePaths: [String] = []
        var fileWrappers: [String: FileWrapper] = [:]

        // ONE FILE PER PICTURE, and the paths still line up one-to-one with
        // `assets` so the caller's index-aligned rewrite keeps working.
        //
        // Importing deduplicates by content now, so a project made from here on
        // will not contain two assets with the same bytes. A project made
        // BEFORE that does, and re-saving it should not keep carrying the
        // duplicates forward — so identical bytes are written once and both
        // assets point at the one file.
        var pathForDigest: [String: String] = [:]

        for (index, asset) in assets.enumerated() {
            let sourceURL = URL(fileURLWithPath: asset.filePath)
            let fileData = try Data(contentsOf: sourceURL)
            let digest = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
            if let existing = pathForDigest[digest] {
                relativePaths.append(existing)
                continue
            }
            let fileExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
            let baseName = sanitizedFilename(asset.name)
            let bundledFilename = "\(index + 1)-\(baseName).\(fileExtension)"
            let wrapper = FileWrapper(regularFileWithContents: fileData)
            wrapper.preferredFilename = bundledFilename
            fileWrappers[bundledFilename] = wrapper
            let relative = "\(bundledAssetsDirectoryName)/\(bundledFilename)"
            pathForDigest[digest] = relative
            relativePaths.append(relative)
        }

        return (relativePaths, fileWrappers)
    }

    private static func sanitizedFilename(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleanedScalars = name.unicodeScalars.map { scalar in
            invalidCharacters.contains(scalar) ? "_" : Character(scalar)
        }
        let sanitized = String(cleanedScalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")

        return sanitized.isEmpty ? "Asset" : sanitized
    }
}

struct UltraMeshProjectFile: FileDocument {
    static var readableContentTypes: [UTType] { [ProjectPersistence.projectContentType] }
    static var writableContentTypes: [UTType] { [ProjectPersistence.projectContentType] }

    let fileWrapperValue: FileWrapper

    init(document: SavedProjectDocument) {
        self.fileWrapperValue = (try? ProjectPersistence.makeProjectFileWrapper(for: document))
            ?? FileWrapper(directoryWithFileWrappers: [:])
    }

    init(configuration: ReadConfiguration) throws {
        self.fileWrapperValue = configuration.file
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        fileWrapperValue
    }
}

extension SavedProjectDocument {
    static let placeholder = SavedProjectDocument(
        version: 1,
        currentFrame: 0,
        playbackLoops: true,
        playbackStartFrame: 0,
        playbackEndFrame: 90,
        camera: SavedCameraState(origin: SavedPoint(.zero), zoom: 1, rotation: 0),
        assets: [],
        images: [],
        skeleton: SavedSkeleton(skeleton: Skeleton()),
        hierarchyItems: [],
        editorState: SavedEditorState(
            selectedImageID: nil,
            selectedImageIDs: [],
            selectedKeyframe: nil,
            selectedKeyframes: [],
            editorModeRawValue: EditorMode.skeleton.rawValue,
            activeToolRawValue: ActiveTool.select.rawValue,
            timelineUnitModeRawValue: "frames",
            isTimelineSnapEnabled: true,
            isTimelineOnionSkinEnabled: false,
            isTimelineGraphVisible: true,
            meshSoftSelectionEnabled: false,
            meshSoftSelectionRadius: 90,
            meshSoftSelectionFeather: 0.55,
            meshSoftSelectionExcludeHull: false,
            timelineSelectedTrackID: nil,
            timelineSelectedFilterRawValue: "all",
            timelineZoomScale: 1.0,
            timelineSelectedGraphChannelID: nil
        )
    )

    func restoredImages() -> [SceneImage] {
        images.map { $0.restoredSceneImage() }
    }

    func restoredSkeleton() -> Skeleton {
        skeleton.restoredSkeleton()
    }

    func restoredHierarchyItems() -> [HierarchyItem] {
        hierarchyItems.map { $0.restoredHierarchyItem() }
    }

    func resolvingAssetPaths(relativeTo rootURL: URL) -> SavedProjectDocument {
        var resolvedDocument = self

        for index in resolvedDocument.assets.indices {
            let path = resolvedDocument.assets[index].filePath
            guard !path.isEmpty else { continue }

            if URL(fileURLWithPath: path).isFileURL, path.hasPrefix("/") {
                continue
            }

            resolvedDocument.assets[index].filePath = rootURL
                .appendingPathComponent(path)
                .path
        }

        return resolvedDocument
    }
}

private extension SavedSceneImage {
    func restoredSceneImage() -> SceneImage {
        let restoredBinding = boneBinding?.restoredBinding()
        let restoredTransformSpace = animationTransformSpace?.restoredSpace(fallbackBoneID: restoredBinding?.boneID)
            ?? restoredBinding.map { .boneLocal($0.boneID) }
            ?? .world

        return SceneImage(
            id: id,
            assetID: assetID,
            name: name,
            basePosition: basePosition.simdValue,
            position: position.simdValue,
            baseScale: baseScale.simdValue,
            scale: scale.simdValue,
            baseRotation: baseRotation,
            rotation: rotation,
            baseRotation3D: baseRotation3D.simdValue,
            rotation3D: rotation3D.simdValue,
            baseSkew: baseSkew.simdValue,
            skew: skew.simdValue,
            mesh: mesh?.restoredMesh() ?? Mesh(name: "\(name) Mesh"),
            boneBinding: restoredBinding,
            isHidden: isHidden,
            slotName: slotName ?? "",
            normalMapAssetID: normalMapAssetID,
            tintColor: tintColor.flatMap { $0.count == 4 ? SIMD4<Float>($0[0], $0[1], $0[2], $0[3]) : nil }
                ?? SIMD4<Float>(1, 1, 1, 1),
            blendMode: blendMode.flatMap(ImageBlendMode.init(rawValue:)) ?? .normal,
            animationClip: animationClip.restoredAnimationClip(),
            animationTransformSpace: restoredTransformSpace
        )
    }
}

private extension SavedBoneImageBinding {
    func restoredBinding() -> BoneImageBinding {
        BoneImageBinding(
            boneID: boneID,
            localPosition: localPosition.simdValue,
            localScale: localScale.simdValue,
            localRotation: localRotation,
            localSkew: localSkew.simdValue
        )
    }
}

private extension SavedMesh {
    func restoredMesh() -> Mesh {
        // Repair on the way in. A project written before the kernel existed can
        // carry a triangle list that covers only part of its silhouette — that
        // is the reported bug, and it was persisted, so reopening the file
        // brought the holes back. `repairedIfInvalid` rebuilds only when the
        // stored list actually fails an invariant, and only if the rebuild
        // itself validates, so a good mesh is never disturbed.
        restoredMeshRaw().repairedIfInvalid().mesh
    }

    private func restoredMeshRaw() -> Mesh {
        Mesh(
            id: id,
            name: name,
            vertices: vertices.map(\.simdValue),
            uvs: uvs.map(\.simdValue),
            indices: indices,
            hullVertexIndices: hullVertexIndices,
            internalEdges: internalEdges,
            manualTriangles: manualTriangles,
            vertexBoneWeights: vertexBoneWeights.map { $0.map(\.restored) },
            bindVertices: bindVertices.map(\.simdValue),
            boneInverseBindMatrices: Dictionary(uniqueKeysWithValues: boneInverseBindMatrices.map { ($0.boneID, $0.matrix) }),
            bindImagePose: bindImagePose?.restored
        ).sanitizedSkinningData()
    }
}

private extension SavedSkeleton {
    func restoredSkeleton() -> Skeleton {
        let restoredBones = bones.map { savedBone in
            Bone(
                id: savedBone.id,
                name: savedBone.name,
                parentID: savedBone.parentID,
                baseTransform: Transform3D2D(
                    position: savedBone.basePosition.simdValue,
                    rotation: savedBone.baseRotation.simdValue,
                    scale: savedBone.baseScale.simdValue,
                    skew: savedBone.baseSkew.simdValue
                ),
                localTransform: Transform3D2D(
                    position: savedBone.position.simdValue,
                    rotation: savedBone.rotation.simdValue,
                    scale: savedBone.scale.simdValue,
                    skew: savedBone.skew.simdValue
                ),
                length: savedBone.length,
                animationClip: savedBone.animationClip?.restoredAnimationClip() ?? AnimationClip(name: savedBone.name),
                color: savedBone.color?.simd
            )
        }
        return Skeleton(
            bones: Dictionary(uniqueKeysWithValues: restoredBones.map { ($0.id, $0) }),
            rootIDs: rootIDs,
            ikConstraints: (ikConstraints ?? []).map { $0.restored() },
            transformConstraints: (transformConstraints ?? []).map { $0.restored() },
            pathConstraints: (pathConstraints ?? []).map { $0.restored() },
            physicsConstraints: (physicsConstraints ?? []).map { $0.restored() }
        )
    }
}

extension SavedAnimationClip {
    func restoredAnimationClip() -> AnimationClip {
        AnimationClip(
            id: id,
            name: name,
            durationInFrames: durationInFrames,
            tracks: tracks.map { $0.restoredAnimationTrack() }
        )
    }
}

extension SavedAnimationTrack {
    func restoredAnimationTrack() -> AnimationTrack {
        AnimationTrack(
            id: id,
            targetID: targetID,
            property: AnimationTrackProperty(rawValue: property) ?? .translate,
            keyframes: keyframes.map { $0.restoredKeyframe() }
        )
    }
}

extension SavedKeyframe {
    func restoredKeyframe() -> Keyframe {
        Keyframe(
            id: id,
            frame: frame,
            value: value.restoredValue(),
            interpolation: KeyframeInterpolation(rawValue: interpolation) ?? .linear,
            inTangent: inTangent?.simdValue,
            outTangent: outTangent?.simdValue,
            secondaryInTangent: secondaryInTangent?.simdValue,
            secondaryOutTangent: secondaryOutTangent?.simdValue
        )
    }
}

extension SavedKeyframeValue {
    func restoredValue() -> KeyframeValue {
        switch kind {
        case "translate":
            return .translate(vector2?.simdValue ?? .zero)
        case "rotate":
            return .rotate(scalar ?? 0)
        case "scale":
            return .scale(vector2?.simdValue ?? SIMD2<Float>(repeating: scalar ?? 1))
        case "shear":
            return .shear(vector2?.simdValue ?? .zero)
        case "meshDeform":
            return .meshDeform(vectorArray?.map { $0.simdValue } ?? [])
        case "scalar":
            return .scalar(scalar ?? 0)
        case "flag":
            return .flag(flag ?? false)
        case "vector2":
            return .vector2(vector2?.simdValue ?? .zero)
        case "drawOrder":
            return .drawOrder(idArray ?? [])
        case "attachment":
            return .attachment((idArray ?? []).first)
        case "event":
            return .event(
                AnimationEventPayload(
                    intValue: eventInt,
                    floatValue: eventFloat,
                    stringValue: eventString
                )
            )
        default:
            return .translate(.zero)
        }
    }
}

private extension SavedHierarchyItem {
    func restoredHierarchyItem() -> HierarchyItem {
        HierarchyItem(
            id: id,
            name: name,
            type: HierarchyItem.ItemType(rawValue: type) ?? .image,
            isHidden: isHidden,
            children: children.map { $0.restoredHierarchyItem() },
            order: order
        )
    }
}

extension SavedSIMD2 {
    var simdValue: SIMD2<Float> {
        SIMD2<Float>(x, y)
    }
}

private extension SavedScale2 {
    var simdValue: SIMD2<Float> {
        SIMD2<Float>(x, y)
    }
}

extension SavedSIMD3 {
    var simdValue: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}

extension SavedPoint {
    var cgPointValue: CGPoint {
        CGPoint(x: x, y: y)
    }
}
