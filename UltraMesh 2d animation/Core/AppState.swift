import Foundation
import Combine

enum EditorMode: String, Codable, CaseIterable {
    case skeleton
    case animation
    /// Staging: finished animations placed in a set with depth and a camera.
    /// No rigging and no keying of the rig happen here — Editor and Animator
    /// keep those — which is why entering it shuts every rig mode off.
    ///
    /// It was parked — left out of `selectable` — while Editor and Animator
    /// were being finished, and re-enabled once its canvas showed the set.
    /// `restorable` stays: it is what keeps a project saved in any mode that
    /// is later withdrawn from reopening somewhere it cannot leave.
    case scene

    /// The modes the UI offers. Every gate — the switch, the Scene export —
    /// reads this list rather than repeating the decision, so parking or
    /// un-parking a mode is one edit here.
    static let selectable: [EditorMode] = [.skeleton, .animation, .scene]

    /// Where a saved mode should actually land.
    ///
    /// A project saved in a mode that is no longer offered would otherwise
    /// reopen into a workspace with no way out of it — the switch would not
    /// show the button that is lit.
    static func restorable(rawValue: String) -> EditorMode {
        let decoded = EditorMode(rawValue: rawValue) ?? .skeleton
        return selectable.contains(decoded) ? decoded : .skeleton
    }

    /// Names shown in the UI.
    ///
    /// The CASE names and raw values stay `skeleton` / `animation`: the raw
    /// value is what `SavedEditorState.editorModeRawValue` persists, so
    /// renaming them would make every existing project reopen in the wrong
    /// mode. Only the label the artist reads changes.
    var title: String {
        switch self {
        case .skeleton:
            return "Editor"
        case .animation:
            return "Animator"
        case .scene:
            return "Scene"
        }
    }

    var systemImage: String {
        switch self {
        case .skeleton:
            return "figure.arms.open"
        case .animation:
            return "timeline.selection"
        case .scene:
            return "video"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    let assetManager: AssetManager
    let sceneManager: SceneManager
    let toolManager: ToolManager
    let camera: CameraState
    let skewGizmoState: SkewGizmoState
    let rotationGizmoState: RotationGizmoState
    let exportManager: ExportManager
    let animationLibrary: AnimationLibrary
    /// The CPU compositor. Still the one that answers GEOMETRY questions about
    /// a Scene — where each card landed, where the light markers go, what the
    /// gizmo hangs off — and, while `sceneMetalRenderer` is nil, the one that
    /// draws the picture too.
    private(set) var sceneFrameRenderer: SceneFrameRenderer!

    /// The GPU renderer the Scene canvas presents.
    ///
    /// ON `MetalDeviceProvider.device`, THE SAME ONE THE RIG CANVAS AND THE
    /// ATLAS USE. Not a detail: `AssetManager` builds its atlas pages on that
    /// device, and a texture cannot be bound to a command encoder from a
    /// different one. A second `MTLCreateSystemDefaultDevice()` usually hands
    /// back the same object and on a multi-GPU Mac does not, which would make
    /// this work everywhere it was tested and crash on the machines it was not.
    ///
    /// Optional only because `init?` fails when a shader function is missing
    /// from the library — a build problem, not a machine without Metal, since
    /// `MetalDeviceProvider` already refuses to launch without one. The CPU
    /// path stays as the answer for that case; nothing else chooses between
    /// them.
    private(set) var sceneMetalRenderer: SceneMetalRenderer?
    @Published private(set) var projectFileURL: URL?
    @Published var editorMode: EditorMode = .skeleton {
        didSet {
            guard editorMode != oldValue else { return }
            sceneManager.isAnimationEditingEnabled = editorMode == .animation

            // EDITOR IS NOT AFFECTED BY ANIMATOR.
            //
            // Leaving Animator used to change nothing about playback, so a
            // clip that was running kept running: `isPlaying` stayed true, the
            // render loop kept calling `tickPlayback()`, and every frame
            // advanced the playhead and re-posed the rig the Editor was
            // showing.
            //
            // Pausing alone would not have been enough. A paused rig is still
            // an animated rig — stop at frame 37 and Editor is showing frame
            // 37 — so the setup pose is restored as well. That is what Editor
            // works from, and what a 2D skeletal editor does on leaving Animate mode.
            if oldValue == .animation, editorMode != .animation {
                sceneManager.pause()
                sceneManager.restoreSetupPose()
            }
            // ...and coming back shows the frame the playhead is still on,
            // rather than the setup pose that was just restored.
            if editorMode == .animation, oldValue != .animation {
                sceneManager.reapplyAnimationsAtPlayhead()
            }

            if editorMode != .skeleton {
                sceneManager.isMeshEditEnabled = false
                sceneManager.meshWeightPaintEnabled = false
                sceneManager.isBindingBonesMode = false
                sceneManager.hoveredBindBoneID = nil
            }
            if editorMode == .scene {
                sceneManager.isPoseMode = false
                // A Scene needs a scene. Creating the first one on entry means
                // the mode never opens onto an empty screen with no verb.
                sceneManager.ensureSceneCompositionExists()
            }
        }
    }
    @Published var timelineUnitModeRawValue: String = "frames"
    @Published var isTimelineSnapEnabled = true
    @Published var isTimelineOnionSkinEnabled = false
    @Published var isTimelineGraphVisible = true
    @Published var timelineSelectedTrackID: String?
    @Published var timelineSelectedFilterRawValue: String = "all"
    @Published var timelineZoomScale: Double = 1.0
    @Published var timelineSelectedGraphChannelID: String?
    private var cancellables = Set<AnyCancellable>()

    init() {
        self.assetManager = AssetManager(device: MetalDeviceProvider.device)
        self.sceneManager = SceneManager()
        self.skewGizmoState = SkewGizmoState()
        self.rotationGizmoState = RotationGizmoState()
        self.toolManager = ToolManager(skewState: skewGizmoState, rotationState: rotationGizmoState)
        self.camera = CameraState()
        self.toolManager.camera = self.camera
        self.toolManager.scene = self.sceneManager
        // The other direction, so a sprite being selected can finish entering
        // a canvas mode that was waiting for one. Both references are weak on
        // the side that does not own the lifetime.
        self.sceneManager.toolManager = self.toolManager
        self.sceneManager.isAnimationEditingEnabled = false
        self.exportManager = ExportManager()
        self.exportManager.pngFrameSource = CoreGraphicsFrameSource(
            scene: self.sceneManager,
            assets: self.assetManager
        )
        self.animationLibrary = AnimationLibrary(scene: self.sceneManager)
        self.sceneFrameRenderer = SceneFrameRenderer(
            scene: self.sceneManager,
            assets: self.assetManager
        )
        self.sceneMetalRenderer = SceneMetalRenderer(device: MetalDeviceProvider.device)

        bindChildObjectChanges()
    }

    private func bindChildObjectChanges() {
        let publishers: [ObservableObjectPublisher] = [
            assetManager.objectWillChange,
            sceneManager.objectWillChange
        ]

        for publisher in publishers {
            publisher
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                .store(in: &cancellables)
        }
    }

    func saveProject() {
        if let projectFileURL {
            saveProject(to: projectFileURL)
        } else {
            NotificationCenter.default.post(name: .ultraMeshRequestSaveAs, object: nil)
        }
    }

    func saveProjectAs() {
        NotificationCenter.default.post(name: .ultraMeshRequestSaveAs, object: nil)
    }

    /// Last user-facing failure, shown as an alert and cleared when dismissed.
    @Published var lastErrorMessage: String?

    /// Ask for a new project. Routed through the notification like every other
    /// file action, because the confirmation belongs with the panels in
    /// `EditorLayoutView` — starting a new project throws away unsaved work,
    /// and a menu item that does that without asking is one nobody forgives.
    func requestNewProject() {
        NotificationCenter.default.post(name: .ultraMeshRequestNewProject, object: nil)
    }

    func openProject() {
        NotificationCenter.default.post(name: .ultraMeshRequestOpenProject, object: nil)
    }

    func importPNG() {
        NotificationCenter.default.post(name: .ultraMeshRequestImportPNG, object: nil)
    }

    /// Import PNGs into the open Scene as plates. Same picker, different
    /// destination — the rig is not involved.
    func importScenePlate() {
        NotificationCenter.default.post(name: .ultraMeshRequestImportScenePlate, object: nil)
    }

    func exportSkeleton() {
        NotificationCenter.default.post(name: .ultraMeshRequestExportSkeleton, object: nil)
    }

    /// Opens the interface settings sheet.
    ///
    /// The macOS menu used to post this notification itself, which meant the
    /// only route to Settings lived inside `#if os(macOS)` and iPadOS had none.
    /// Going through AppState like every other action puts it where a toolbar
    /// button can reach it.
    func showSettings() {
        NotificationCenter.default.post(name: .ultraMeshRequestSettings, object: nil)
    }

    /// Opens the unified Export dialog (all formats + options).
    func showExportDialog() {
        NotificationCenter.default.post(name: .ultraMeshRequestExportDialog, object: nil)
    }

    func exportPNGSequence() {
        NotificationCenter.default.post(name: .ultraMeshRequestExportPNGSequence, object: nil)
    }

    /// Render the open Scene to a movie.
    func exportSceneVideo() {
        NotificationCenter.default.post(name: .ultraMeshRequestExportSceneVideo, object: nil)
    }

    /// Start again with nothing in it.
    ///
    /// The SAME restore path an opened file takes, over
    /// `SavedProjectDocument.empty`. Deliberately, and it is the whole design:
    /// a `reset()` that assigned the thirty-odd properties `restore` assigns
    /// would be a second list to keep in step, and the field they disagreed
    /// about would be whichever was added last — which is to say a new project
    /// would quietly inherit one thing from the old one. Routed through
    /// `restore`, a field is cleared by both or by neither.
    func newProject() {
        // `restore` throws only from `restoreAssets`, and an empty document has
        // no assets to fail on. Swallowed rather than surfaced because there is
        // nothing here for a person to act on — but not ignored silently: if it
        // ever does throw, the editor is left holding the previous project
        // rather than a half-cleared one, which is the safe half.
        do {
            try restore(document: .empty)
            projectFileURL = nil
        } catch {
            PlatformFeedback.errorBeep()
            lastErrorMessage = "Could not start a new project.\n\n\(error.localizedDescription)"
        }
    }

    func openProject(from sourceURL: URL) {
        do {
            try withScopedAccess(to: sourceURL) {
                let document = try ProjectPersistence.load(from: sourceURL)
                try restore(document: document)
                projectFileURL = sourceURL
            }
        } catch {
            PlatformFeedback.errorBeep()
            print("UltraMesh open failed:", error.localizedDescription)
            // A beep and a console line are invisible to someone using the app.
            // Surface it, or a project that fails to open looks identical to a
            // button that does nothing — which is exactly how this was reported.
            lastErrorMessage = "Could not open that project.\n\n\(error.localizedDescription)"
        }
    }

    /// Put the editor into the state this document describes. One body, two
    /// callers: opening a file, and starting a new project.
    ///
    /// Does NOT set `projectFileURL` — that is the one thing the two callers
    /// genuinely differ about, so it is the one thing left to them.
    private func restore(document: SavedProjectDocument) throws {
        try assetManager.restoreAssets(document.assets)
            sceneManager.restoreProject(
                images: document.restoredImages(),
                skeleton: document.restoredSkeleton(),
                hierarchyItems: document.restoredHierarchyItems(),
                currentFrame: document.currentFrame,
                playbackLoops: document.playbackLoops,
                playbackStartFrame: document.playbackStartFrame,
                playbackEndFrame: document.playbackEndFrame,
                selectedImageID: document.editorState.selectedImageID,
                selectedImageIDs: Set(document.editorState.selectedImageIDs),
                selectedKeyframe: document.editorState.selectedKeyframe?.restoredSelection(),
                selectedKeyframes: Set(document.editorState.selectedKeyframes.map { $0.restoredSelection() }),
                sceneAnimationClip: document.restoredSceneAnimationClip(),
                constraintSetupValues: document.restoredConstraintSetupValues(),
                projectFramesPerSecond: document.restoredProjectFramesPerSecond(),
                authoredDrawOrder: document.authoredDrawOrder ?? [],
                skins: document.restoredSkins(),
                activeSkinID: document.restoredActiveSkinID(),
                animationEvents: document.restoredAnimationEvents(),
                sceneCompositions: document.restoredSceneCompositions(),
                selectedSceneCompositionID: document.restoredSelectedSceneCompositionID(),
                sceneViewCamera: document.restoredSceneViewCamera()
            )
            // After restoreProject, so the clips the library's active entry
            // refers to are already on the bones and sprites. A project saved
            // before this field existed restores an empty list and keeps
            // exactly the one animation its clips carry.
            animationLibrary.restore(
                animations: document.restoredAnimations(),
                activeID: document.restoredActiveAnimationID()
            )
            camera.restore(
                origin: document.camera.origin.cgPointValue,
                zoom: CGFloat(document.camera.zoom),
                rotation: CGFloat(document.camera.rotation)
            )
            editorMode = EditorMode.restorable(rawValue: document.editorState.editorModeRawValue)
            sceneManager.isAnimationEditingEnabled = editorMode == .animation
            toolManager.setTool(ActiveTool(rawValue: document.editorState.activeToolRawValue) ?? .select)
            timelineUnitModeRawValue = document.editorState.timelineUnitModeRawValue
            isTimelineSnapEnabled = document.editorState.isTimelineSnapEnabled
            isTimelineOnionSkinEnabled = document.editorState.isTimelineOnionSkinEnabled
            isTimelineGraphVisible = document.editorState.isTimelineGraphVisible
            sceneManager.meshSoftSelectionEnabled = document.editorState.meshSoftSelectionEnabled
            sceneManager.meshSoftSelectionRadius = document.editorState.meshSoftSelectionRadius
            sceneManager.meshSoftSelectionFeather = document.editorState.meshSoftSelectionFeather
            sceneManager.meshSoftSelectionExcludeHull = document.editorState.meshSoftSelectionExcludeHull
            timelineSelectedTrackID = document.editorState.timelineSelectedTrackID
            timelineSelectedFilterRawValue = document.editorState.timelineSelectedFilterRawValue
            timelineZoomScale = document.editorState.timelineZoomScale
            timelineSelectedGraphChannelID = document.editorState.timelineSelectedGraphChannelID
    }

    func saveProject(to destinationURL: URL) {
        let document = currentProjectDocument()

        do {
            try withScopedAccess(to: destinationURL.deletingLastPathComponent()) {
                try ProjectPersistence.save(document: document, to: destinationURL)
                projectFileURL = destinationURL
            }
        } catch {
            PlatformFeedback.errorBeep()
            print("UltraMesh save failed:", error.localizedDescription)
            // Same reasoning as the open failure above: a beep and a console
            // line are invisible. A save that does nothing and says nothing is
            // indistinguishable from a button that is broken.
            lastErrorMessage = "Could not save the project.\n\n\(error.localizedDescription)"
        }
    }

    func currentProjectDocument() -> SavedProjectDocument {
        SavedProjectDocument(
            currentFrame: sceneManager.currentFrame,
            playbackLoops: sceneManager.playbackLoops,
            playbackStartFrame: sceneManager.playbackStartFrame,
            playbackEndFrame: sceneManager.playbackEndFrame,
            camera: camera,
            assets: assetManager.assets,
            images: sceneManager.images,
            skeleton: sceneManager.skeleton,
            hierarchyItems: sceneManager.hierarchyItems,
            editorState: SavedEditorState(appState: self),
            sceneAnimationClip: sceneManager.sceneAnimationClip,
            constraintSetupValues: sceneManager.constraintSetupValues,
            projectFramesPerSecond: sceneManager.projectFramesPerSecond,
            authoredDrawOrder: sceneManager.authoredDrawOrder,
            skins: sceneManager.skins,
            activeSkinID: sceneManager.activeSkinID,
            animationEvents: sceneManager.animationEvents,
            sceneCompositions: sceneManager.sceneCompositions,
            selectedSceneCompositionID: sceneManager.selectedSceneCompositionID,
            sceneViewCamera: sceneManager.sceneViewCamera,
            // The library had no field in the file at all: only the ACTIVE
            // animation's clips survived a save, because those live on the
            // bones and sprites. Every other animation was dropped silently.
            animations: animationLibrary.animations.map(SavedNamedAnimation.init),
            activeAnimationID: animationLibrary.activeID
        )
    }

    func markProjectSaved(at url: URL) {
        projectFileURL = url
    }

    var suggestedProjectName: String {
        sceneManager.selectedImageID
            .flatMap { sceneManager.image(for: $0)?.name }
            ?? projectFileURL?.deletingPathExtension().lastPathComponent
            ?? "UltraMesh Project"
    }

    private func withScopedAccess(to url: URL, perform operation: () throws -> Void) throws {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        try operation()
    }
}

extension Notification.Name {
    static let ultraMeshRequestSaveAs = Notification.Name("UltraMeshRequestSaveAs")
    static let ultraMeshRequestNewProject = Notification.Name("UltraMeshRequestNewProject")
    static let ultraMeshRequestOpenProject = Notification.Name("UltraMeshRequestOpenProject")
    static let ultraMeshRequestImportPNG = Notification.Name("UltraMeshRequestImportPNG")
    /// A PNG going straight into the open Scene as a plate, without becoming
    /// a rig sprite on the way in.
    static let ultraMeshRequestImportScenePlate = Notification.Name("UltraMeshRequestImportScenePlate")
    /// Settings left the toolbar with the mockup's cleanup; the menu is
    /// where macOS looks for it anyway.
    static let ultraMeshRequestSettings = Notification.Name("UltraMeshRequestSettings")
    static let ultraMeshRequestExportSkeleton = Notification.Name("UltraMeshRequestExportSkeleton")
    static let ultraMeshRequestExportSceneVideo = Notification.Name("UltraMeshRequestExportSceneVideo")
    static let ultraMeshRequestExportPNGSequence = Notification.Name("UltraMeshRequestExportPNGSequence")
    static let ultraMeshRequestExportDialog = Notification.Name("UltraMeshRequestExportDialog")
}
