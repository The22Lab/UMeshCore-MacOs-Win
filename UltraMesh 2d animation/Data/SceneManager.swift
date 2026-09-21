import Combine
import Foundation
import QuartzCore
import SwiftUI
import simd

enum MeshEditToolMode: String, Codable, CaseIterable {
    case modify
    case create
    case delete
}

enum MeshWeightPaintMode: String, Codable, CaseIterable {
    case add
    case subtract
    case smooth
    case replace
    case blur
}

final class SceneManager: ObservableObject {
    private(set) var images: [SceneImage] = [] {
        willSet { announceChange() }
        didSet { rigStateToken &+= 1 }
    }
    @Published var hierarchyItems: [HierarchyItem] = []
    /// So a sprite being selected can finish entering a canvas mode that was
    /// waiting for one. Weak, and set by `AppState`, mirroring the reference
    /// `ToolManager` already keeps back to the scene.
    weak var toolManager: ToolManager?

    @Published var selectedImageID: UUID? {
        didSet {
            // One place. There are a dozen ways to select a sprite — the
            // canvas, the hierarchy, the draw order panel, a shortcut — and
            // patching each of them is how one of them ends up forgotten.
            guard selectedImageID != nil, pendingCanvasMode != nil else { return }
            resolvePendingCanvasMode()
        }
    }
    @Published var selectedImageIDs: Set<UUID> = []
    var skeleton: Skeleton = Skeleton() {
        willSet { announceChange() }
        didSet {
            rigStateToken &+= 1
            skeletonToken &+= 1
        }
    }

    /// How often the panels are told the pose changed while the transport is
    /// rolling. Twelve times a second is faster than an eye reads a number and
    /// two hundred times cheaper than sixty.
    static let playbackPanelHz: Double = 12
    private var lastPanelAnnounce: CFTimeInterval = -.greatestFiniteMagnitude

    /// The one place a change to the pose reaches SwiftUI.
    ///
    /// `images` and `skeleton` were `@Published`, so each assignment announced
    /// itself, and `applyAnimations()` makes both of them once per playback
    /// frame. TWELVE views observe this object — the timeline, the hierarchy,
    /// the inspector, the draw order, the skins and events panels, the
    /// constraint menus — so a second of playback asked for 1 440 body
    /// rebuilds to show an animation whose STRUCTURE never changes: the same
    /// tracks, the same rows, frame after frame. That is the stutter.
    ///
    /// The canvas gains nothing from any of it. `MetalRenderer` reads
    /// `images` and `skeleton` straight out of here in its draw call — it is an
    /// MTKView delegate, not a SwiftUI view — and `CanvasActivity` keeps it
    /// drawing through its `isPlaying` probe. The publishes were only ever for
    /// the panels, so while the transport rolls the panels get them at a rate
    /// instead of at the frame rate.
    ///
    /// An edit made DURING playback is paced with everything else, up to a
    /// twelfth of a second late in the panels. The canvas shows it immediately,
    /// because the canvas does not go through here.
    private func announceChange() {
        guard isPlaying else {
            objectWillChange.send()
            return
        }
        let now = CACurrentMediaTime()
        guard now - lastPanelAnnounce >= 1 / Self.playbackPanelHz else { return }
        lastPanelAnnounce = now
        objectWillChange.send()
    }

    /// Let the next change through whatever the clock says.
    ///
    /// A rate limiter with no flush leaves the panels on whichever frame it
    /// last let through — stop on 30 and the inspector reads 24, and stays
    /// there. Called when the transport stops.
    private func flushPanelAnnounce() {
        lastPanelAnnounce = -.greatestFiniteMagnitude
        objectWillChange.send()
    }

    /// Changes whenever the rig's picture could have changed.
    ///
    /// Scene draws the rig from `rigPose(atFrame:)`, and both that answer and
    /// the frames rendered from it are worth keeping — an orbit re-asks for the
    /// same pose sixty times a second. A cache needs to know when the answer
    /// went stale, and the honest signal is the DATA: `images` and `skeleton`
    /// are the whole of what a rig draws from, they are value types, so any
    /// nested edit reassigns them and lands here.
    ///
    /// Bumped from `didSet` rather than by hand. `applyAnimations()` alone has
    /// 49 call sites; a token maintained at call sites is a token that misses
    /// one, and a missed bump is a Scene showing a rig that no longer exists —
    /// a staleness bug that reads as the app being broken.
    ///
    /// Not `@Published`: it changes on every playback frame, and announcing it
    /// would invalidate every observing view a second time for a number none of
    /// them display. `&+=` because it is an identity, not a count, and wrapping
    /// after 2^63 edits is still a change.
    private(set) var rigStateToken: UInt64 = 0

    /// Bumped by writes to `skeleton` alone.
    ///
    /// Distinct from `rigStateToken`, which also moves when `images` changes —
    /// and `images` changes every single frame, so it can never say "the
    /// skeleton has not moved". `worldMatrices()` reads the skeleton and the
    /// physics system and nothing else, so this is exactly the input it
    /// depends on, and it is what lets one frame solve the rig once.
    private(set) var skeletonToken: UInt64 = 0

    /// The skeleton solved for the frame in progress, and the token it was
    /// solved at.
    private var framePoseCache: (token: UInt64, matrices: [UUID: simd_float4x4])?
    private var didStepPhysicsThisFrame = false

    /// Start a frame. Called by the renderer before anything reads the pose.
    ///
    /// Solving the whole skeleton — base matrices, then IK, FABRIK, path,
    /// transform and physics constraints in order — used to happen at least
    /// TWICE per displayed frame: once inside the bone-binding pass and once
    /// again for the renderer's own `framePose`. Each rebuilt the children
    /// index and the sorted constraint list from scratch and allocated a
    /// dictionary keyed by UUID. Nothing between them changed the skeleton.
    /// - Parameter presentationTime: when this frame will be seen. Handed
    ///   straight to the physics system so the simulation advances against the
    ///   same clock the playhead does — animation time and simulation time
    ///   measured from one instant, never two.
    func beginFramePose(presentationTime: CFTimeInterval? = nil) {
        framePoseCache = nil
        didStepPhysicsThisFrame = false
        if let presentationTime {
            PhysicsConstraintSystem.shared.setFrameTime(presentationTime)
        }
    }

    /// The skeleton solved, at most once per frame per skeleton state.
    ///
    /// Physics steps on the FIRST solve of a frame and only then: it
    /// integrates over time, so solving twice would run its clock twice. A
    /// later solve in the same frame — because a tool moved a bone — observes
    /// the simulation exactly as the Scene evaluator does.
    func frameWorldMatrices() -> [UUID: simd_float4x4] {
        if let cache = framePoseCache, cache.token == skeletonToken {
            return cache.matrices
        }
        let stepping = !didStepPhysicsThisFrame
        didStepPhysicsThisFrame = true
        let matrices = skeleton.worldMatrices(steppingPhysics: stepping)
        framePoseCache = (skeletonToken, matrices)
        return matrices
    }
    @Published var selectedBoneID: UUID?
    /// Multi-bone selection (Cmd-click). `selectedBoneID` is always the primary —
    /// the most recently clicked bone — and is always also contained in this set
    /// when non-empty. The set is the source of truth for actions that need every
    /// selected bone (e.g. creating an IK chain).
    @Published var selectedBoneIDs: Set<UUID> = []
    /// The same bones, in the order they joined the selection.
    ///
    /// A Set cannot answer "which one is the active bone": Swift seeds its
    /// hashing per process, so `selectedBoneIDs.first` named a DIFFERENT bone
    /// on every launch — and that was the bone the inspector edited, and the
    /// bone a transform moved, after a Cmd-click took the previous one away.
    /// The set stays the source of truth for membership; this is the source of
    /// truth for order, and `selectedBoneID` is always its last element.
    ///
    /// Never written directly. `applyBoneSelection` keeps the three in step;
    /// one route, because three fields that can disagree will.
    @Published private(set) var boneSelectionOrder: [UUID] = []
    /// Currently highlighted constraint (any concrete type). Drives the constraint
    /// inspector card focus state and any on-canvas gizmos that should appear only
    /// while a constraint is the active selection.
    @Published var selectedConstraintID: UUID?
    @Published var boneCreationPreviewStart: SIMD2<Float>?
    @Published var boneCreationPreviewEnd: SIMD2<Float>?
    @Published var meshCreateEdgePreviewStart: SIMD2<Float>?
    @Published var meshCreateEdgePreviewEnd: SIMD2<Float>?
    /// Paced with the pose, not published on its own.
    ///
    /// `tickPlayback` writes this every frame it advances, so left as
    /// `@Published` it announced sixty times a second on its own account and
    /// undid most of the pacing above. The PLAYHEAD does not come through here
    /// — `PlayheadClock` is its own object and still moves every display tick,
    /// which is what keeps the line smooth while the panels are quiet.
    private(set) var currentFrame: Int = 0 {
        willSet { announceChange() }
    }
    @Published private(set) var isPlaying: Bool = false
    /// Where the playhead is, to a fraction of a frame.
    ///
    /// Its own object on purpose. This used to be `@Published` on the scene
    /// manager, which the whole timeline observes, and the timeline then copied
    /// it into its own `@State` through `onChange` — so every display tick
    /// re-evaluated the entire timeline body TWICE, rebuilding the track tree
    /// and rescanning every clip, sixty times a second. The motion was smooth
    /// in the model and dropped on the way to the screen, which is what "it
    /// teleports" actually was.
    ///
    /// Only the playhead view observes this, so a tick redraws a line.
    let playheadClock = PlayheadClock()

    /// Read-through for callers that only want the value.
    var playheadFractionalFrame: Double { playheadClock.frame }

    /// WHERE THE ANIMATION IS, in fractional frames. The model samples this,
    /// not `currentFrame`.
    ///
    /// `currentFrame` is a whole number and always will be: it is what the
    /// timeline selects, what a keyframe is placed on, and what export writes.
    /// But a clip evaluated only at whole frames can hold at most
    /// `projectFramesPerSecond` distinct poses per second while the display
    /// shows 120 — four out of five frames identical to the one before, then a
    /// jump. That is the judder, and it gets worse the faster the motion.
    ///
    /// Sampling at the fraction also makes the animation independent of how
    /// well the device keeps up: the pose is a function of wall-clock time, so
    /// a frame the iPad cannot deliver on schedule costs one SAMPLE of the
    /// motion, never a step of it. A heavy scene is sampled less finely; it
    /// does not run slow, and it does not drift.
    ///
    /// Not `@Published`: it moves every display tick, and announcing that is
    /// the mistake `PlayheadClock` exists to avoid.
    private(set) var animationTime: Double = 0

    /// The sanitised render mesh per sprite, recomputed only when the mesh
    /// changes. See `RenderMeshCache` — this is the single largest per-frame
    /// cost in the editor and none of its inputs move while animating.
    let renderMeshCache = RenderMeshCache()
    @Published var playbackLoops = true

    /// Frame rate of the project. This is a document property: it
    /// sets playback speed, the dope sheet's frame-to-time mapping, and the
    /// default for exports. Clamped on write so a bad value can never divide by
    /// zero in the playback clock.
    @Published var projectFramesPerSecond: Double = 30 {
        didSet {
            let clamped = min(max(projectFramesPerSecond, 1), 240)
            if clamped != projectFramesPerSecond {
                projectFramesPerSecond = clamped
                return
            }
            guard clamped != oldValue else { return }
            // Restart the playback session so the new rate takes effect
            // immediately instead of at the next play/pause cycle.
            if isPlaying {
                pause()
                play()
            }
        }
    }

    /// Duration of one frame at the project rate, for time readouts.
    var secondsPerFrame: Double {
        1.0 / max(projectFramesPerSecond, 1)
    }

    /// Wall-clock seconds a frame index corresponds to.
    func timecode(forFrame frame: Int) -> Double {
        Double(frame) * secondsPerFrame
    }
    @Published private(set) var playbackStartFrame: Int = 0
    @Published private(set) var playbackEndFrame: Int = 90
    @Published private(set) var selectedMeshVertexIndices: Set<Int> = []
    @Published var hoveredMeshVertexIndex: Int?
    @Published private(set) var selectedMeshInternalEdgeIndex: Int?
    @Published var isMeshLayerSelected = false
    @Published var meshEditToolMode: MeshEditToolMode = .modify
    /// Mesh editing. Written only by the canvas mode selector and by
    /// `canvasToolChanged`; there is no user-facing toggle any more.
    ///
    /// There used to be a "Mesh Edit" button in the Inspector, and every place
    /// that could take the artist out of mesh editing had to remember to switch
    /// it off. They did not all remember, so it stayed lit under Pose, survived
    /// a keyboard tool switch, and left the canvas interpreting clicks as mesh
    /// edits while the artist thought they were posing.
    @Published var isMeshEditEnabled = false

    /// The artist picked a different tool, so leave any mode that tool cannot
    /// serve.
    ///
    /// Mesh editing and weight painting are things the MESH tool does; binding
    /// bones is something you do to a mesh. Choosing another tool — from the
    /// palette, from the Inspector, or with a keyboard shortcut — means the
    /// artist has left those modes, and that has to happen in one place rather
    /// than at each of the fifteen call sites of `setTool`.
    func canvasToolChanged(to tool: ActiveTool) {
        activeCanvasTool = tool

        // POSE IS A CANVAS MODE TOO, and it was the one this never cleared. So
        // choosing Translate while posing left both lit — the strip said Pose,
        // the toolbar said Translate, and a canvas drag was taken as a pose
        // drag. It is cleared BEFORE the mesh tool's early return: the mesh
        // tool is the one exception to leaving mesh mode, not to leaving pose.
        isPoseMode = false
        // A mode waiting for a sprite is waiting for the artist to pick one,
        // not for them to reach for another tool.
        pendingCanvasMode = nil

        guard tool != .mesh else { return }
        isMeshEditEnabled = false
        meshWeightPaintEnabled = false
        isBindingBonesMode = false
        activeWeightPaintBoneID = nil
    }

    /// A canvas mode asked for before a sprite was selected, waiting for one.
    ///
    /// Mesh and Weights both need a sprite, and both used to refuse with
    /// "Select an image first" — which is a dead end: the artist has to work
    /// out for themselves that the button will behave differently after a
    /// click somewhere else. Arming it instead means the button says what it
    /// wants and the next sprite picked, on the canvas or in the hierarchy,
    /// enters the mode.
    ///
    /// Stored as the raw value so `SceneManager` does not have to know the
    /// `CanvasMode` type, which lives with the view that owns the strip.
    @Published var pendingCanvasMode: String?

    /// Enters the mode that was waiting, now that a sprite has been picked.
    func resolvePendingCanvasMode() {
        guard let waiting = pendingCanvasMode, let toolManager else { return }
        pendingCanvasMode = nil
        meshEditNotice = nil
        guard let mode = CanvasMode(rawValue: waiting) else { return }
        CanvasModeSelection.select(mode, scene: self, tools: toolManager)
    }

    /// The tool in hand, mirrored from `ToolManager` so the timeline can ask
    /// what the key button should write without reaching for the tool manager.
    /// Set by `canvasToolChanged`, which every path into `setTool` goes through.
    @Published private(set) var activeCanvasTool: ActiveTool = .select

    /// Whether the mesh overlay should be drawn.
    ///
    /// `isMeshLayerSelected` alone is not enough, and that is why the dotted
    /// triangles and the vertex markers kept vanishing mid-edit: it is cleared
    /// by `setSelection`, `clearSelection`, `selectBone` and
    /// `toggleBoneSelection`, all of which are reachable from the hierarchy or
    /// the timeline while mesh edit mode is still switched on. Being in mesh
    /// edit mode is the condition that actually means "show me the mesh".
    var isMeshOverlayVisible: Bool {
        isMeshEditEnabled || isMeshLayerSelected || meshWeightPaintEnabled
    }

    /// Whether a mode that works on a SPRITE'S MESH is running.
    ///
    /// Mesh edit and weight paint differ in what they do to a mesh and agree
    /// on needing one, so anything that reacts to "the artist is working on a
    /// mesh" — picking another sprite keeps the mode and moves it, picking a
    /// bone ends it — asks this rather than combining the two flags itself.
    /// Two views that each spell out "is a mesh mode on" is precisely how mesh
    /// edit came to be lit under pose.
    var isSpriteMeshMode: Bool {
        isMeshEditEnabled || meshWeightPaintEnabled
    }
    @Published var isMeshCreatingHull = false
    @Published var meshShowTriangles = true
    @Published var meshDimImage = false
    @Published var meshIsolateSelection = false
    @Published var meshShowDeformed = true

    /// Whether the mesh overlay is showing the DEFORMED mesh.
    ///
    /// `meshShowDeformed` is a Mesh-mode control and belongs to Mesh mode.
    /// Read raw it leaked: turn it off to compare against the flat UV layout,
    /// leave Mesh mode, and the vertex markers, the hit tests and the brush
    /// went on using a mesh the canvas was no longer drawing. Outside Mesh mode
    /// the canvas shows the posed sprite, so everything that draws or measures
    /// the overlay asks this rather than the flag.
    /// Screen-space geometry of the LAST FRAME DRAWN, per sprite.
    ///
    /// Written by `MetalRenderer.drawSceneImages`, which computes exactly this
    /// for every sprite anyway, and read by `CanvasPicking`. Three things fall
    /// out of that, and the third is the reason it exists:
    ///
    ///  * Picking costs nothing. Rebuilding the geometry per candidate meant
    ///    `sanitizedForRender` and a skinning pass per sprite on every hover
    ///    sample — doubling, during hover, work the renderer had just done.
    ///  * A click tests the frame the artist was LOOKING AT when they clicked,
    ///    which is more honest than re-deriving a fresher one they never saw.
    ///  * It cannot go stale in a way that matters. A missing entry means
    ///    "compute it", never "no sprite here", so the cache can only make
    ///    picking faster, never wrong.
    ///
    /// Not `@Published` and not model state: it is rewritten every frame, and
    /// publishing it would invalidate every observer 120 times a second.
    var lastDrawnGeometry: [UUID: CanvasPicking.ScreenGeometry] = [:]

    var isMeshOverlayDeformed: Bool {
        isMeshEditEnabled ? meshShowDeformed : true
    }
    @Published var meshSoftSelectionEnabled = false
    @Published var meshSoftSelectionRadius: Float = 90
    @Published var meshSoftSelectionFeather: Float = 0.55
    @Published var meshSoftSelectionExcludeHull = false
    @Published var meshAutoDetail: Float = 30
    @Published var meshAutoConcavity: Float = 100
    @Published var meshAutoPadding: Float = 1.2
    @Published var meshGenerateDensity: Float = 30
    @Published var activeWeightPaintBoneID: UUID?
    @Published var meshWeightPaintMode: MeshWeightPaintMode = .add
    @Published var meshWeightBrushRadius: Float = 52
    @Published var meshWeightBrushStrength: Float = 0.55
    @Published var meshWeightBrushFalloff: Float = 1.8
    @Published var meshWeightBrushInfluence: Float = 1.0
    @Published var meshWeightMaxInfluencesPerVertex: Int = 4
    @Published var isPoseMode: Bool = false
    @Published var meshWeightPaintEnabled: Bool = false
    @Published var showBones: Bool = true
    @Published var showWeightOverlay: Bool = false
    @Published var inspectorNavigationTarget: String? = nil
    @Published var isBindingBonesMode: Bool = false {
        didSet { if !isBindingBonesMode { hoveredBindBoneID = nil } }
    }
    @Published var hoveredBindBoneID: UUID?

    /// The sprite a click would select right now — the pre-selection.
    ///
    /// It is written from the SAME picker the click uses, and it stores what
    /// the click would actually return rather than "whatever quad the cursor is
    /// inside". A highlight that does not predict the selection is worse than
    /// none: it teaches the wrong thing about where the sprite is.
    ///
    /// Nil while a bone would win the click, so the outline never claims a
    /// sprite the click is about to pass over.
    @Published var hoveredImageID: UUID?

    // MARK: - Scene mode state

    /// The project's Scenes — staged sets of layers seen through a camera.
    /// A project can hold several, the way it holds several skins.
    @Published var sceneCompositions: [SceneComposition] = []
    @Published var selectedSceneCompositionID: UUID?
    /// Where the artist is standing in Scene mode. Editor state: saved like a
    /// window position, never keyframed, never exported.
    @Published var sceneViewCamera = SceneViewCamera()
    /// Pan and zoom over the FRONT view. Editor state like `sceneViewCamera`:
    /// saved like a window position, never keyframed, never exported.
    @Published var sceneFrontView = SceneFrontView()
    /// Whether a Scene loops when it reaches its last frame.
    ///
    /// Scene's own, not the rig's `playbackLoops`. A shot and a walk cycle want
    /// opposite defaults — a cycle repeats, a shot ends — and sharing the flag
    /// would mean an artist setting up one silently changes the other.
    @Published var sceneLoopsPlayback = true

    /// What is selected in Scene — a layer, a light, or nothing.
    ///
    /// ONE value. The layer list, the canvas, the gizmo and the inspector all
    /// read it, so a light and a card can never both look selected. See
    /// `SceneSelection` for what it replaced.
    @Published var sceneSelection: SceneSelection = .none

    /// The selected light's id, when a light is what is selected.
    var selectedSceneLightID: UUID? { sceneSelection.lightID }
    /// The selected layer's id, when a layer is what is selected.
    var selectedSceneLayerID: UUID? { sceneSelection.layerID }

    var selectedSceneComposition: SceneComposition? {
        selectedSceneCompositionID.flatMap { id in
            sceneCompositions.first { $0.id == id }
        } ?? sceneCompositions.first
    }

    /// Entering Scene mode with no scene yet creates one, so the mode never
    /// opens onto an empty screen. Not undoable on purpose: it is the mode's
    /// ground state, and undoing it would leave the workspace with nothing to
    /// show.
    func ensureSceneCompositionExists() {
        guard sceneCompositions.isEmpty else { return }
        var composition = SceneComposition(
            name: "Scene 1",
            durationInFrames: max(playbackEndFrame - playbackStartFrame + 1, 1),
            fps: Int(projectFramesPerSecond.rounded())
        )
        // The rig is what a Scene is FOR, so the first scene opens with the rig
        // already on the set — at the depth where one unit is one pixel, so it
        // appears at exactly the size the Editor showed it. Without this the
        // mode opened onto the background fill and nothing else: a dark blue
        // rectangle with no hint on it that anything was missing, which read
        // as "Scene is broken" rather than "Scene is empty".
        //
        // Only when there is a rig to show. A project with no images gets an
        // empty scene and the canvas says so.
        if !images.isEmpty {
            let focal = composition.camera.focalLength(viewHeight: composition.renderSize.y)
            composition.layers.append(SceneLayer(
                name: "Rig 1",
                positionZ: composition.camera.positionZ + focal,
                content: .rig(clipID: UUID(), speed: 1, startFrame: 0, loops: true)
            ))
        }
        sceneCompositions = [composition]
        selectedSceneCompositionID = composition.id
    }

    /// Every scene edit funnels through here: one undo entry, then the change,
    /// applied by id so a stale index can never hit another scene.
    func updateSceneComposition(
        _ id: UUID,
        undoable: Bool = true,
        _ change: (inout SceneComposition) -> Void
    ) {
        guard let index = sceneCompositions.firstIndex(where: { $0.id == id }) else { return }
        if undoable { pushUndoState() }
        var composition = sceneCompositions[index]
        change(&composition)
        sceneCompositions[index] = composition
    }

    /// Where a new layer goes: the camera's focal plane, where one world unit
    /// is one rendered pixel, so it appears at its natural size instead of
    /// somewhere the artist has to hunt for.
    ///
    /// One rule, because there are two ways to add a layer now — the Layers
    /// menu and a PNG imported straight into the Scene — and a plate that
    /// landed at a different depth depending on how it got there would be a
    /// difference nobody could explain.
    func defaultLayerZ(in composition: SceneComposition) -> Float {
        composition.camera.positionZ
            + composition.camera.focalLength(viewHeight: composition.renderSize.y)
    }

    /// Add imported PNGs to a Scene as plates, and nothing else.
    ///
    /// The rig's import makes every PNG a sprite: a row in the hierarchy, a
    /// mesh, something to bind bones to. A backdrop is none of those. The asset
    /// is shared — it saves and reloads like any other — but the rig never
    /// learns about it.
    @discardableResult
    /// `normalMaps` and `heightMaps` pair artwork ids to their relief,
    /// resolved by the caller — `SceneManager` holds no `AssetManager`, and
    /// giving it one to answer a naming question would be a dependency earned
    /// by nothing.
    func addScenePlates(assets: [TextureAsset], to compositionID: UUID,
                        normalMaps: [UUID: UUID] = [:],
                        heightMaps: [UUID: UUID] = [:]) -> [UUID] {
        guard let composition = sceneCompositions.first(where: { $0.id == compositionID }),
              !assets.isEmpty else { return [] }
        let z = defaultLayerZ(in: composition)
        var added: [UUID] = []
        var order = composition.frontSortingOrder
        // MAPS ARE NOT PLATES. `importPNGs` hands back everything it imported,
        // including the `_n` and `_h` files, and a card built from one would
        // have no atlas rect to sample through.
        for asset in assets where asset.isPlaceable {
            var material = SceneMaterial.flat
            material.normalMapAssetID = normalMaps[asset.id]
            // THE MAP IS ATTACHED, THE MARCH IS NOT TURNED ON. Importing
            // `hero_h.png` says the artist HAS a height field, not that they
            // want every plate parallaxed the moment it lands -- the mode stays
            // `.off` until they ask for it in the inspector, so an import can
            // never silently change what a scene costs or looks like.
            material.heightMapAssetID = heightMaps[asset.id]
            let layer = SceneLayer(name: asset.name, positionZ: z,
                                   sortingOrder: order,
                                   material: material,
                                   content: .plate(assetID: asset.id))
            order += 1
            added.append(layer.id)
            addSceneLayer(layer, to: compositionID)
        }
        return added
    }

    func addSceneLayer(_ layer: SceneLayer, to compositionID: UUID) {
        updateSceneComposition(compositionID) { composition in
            composition.layers.append(layer)
        }
    }

    func removeSceneLayer(_ layerID: UUID, from compositionID: UUID) {
        updateSceneComposition(compositionID) { composition in
            composition.layers.removeAll { $0.id == layerID }
        }
    }

    // MARK: - Lights

    /// Which light the inspector is editing. Editor state, like a selection.
    var selectedSceneLight: SceneLight? {
        guard let id = sceneSelection.lightID else { return nil }
        return selectedSceneComposition?.light(id)
    }

    /// Select a light, and stop selecting whatever was selected before.
    func selectSceneLight(_ id: UUID?) {
        sceneSelection = id.map { SceneSelection.light($0) } ?? .none
    }

    /// Select a layer, likewise.
    func selectSceneLayer(_ id: UUID?) {
        sceneSelection = id.map { SceneSelection.layer($0) } ?? .none
    }

    /// Drop a selection that points at something no longer in the scene.
    ///
    /// Called where a scene is replaced wholesale — opening a project, undo.
    /// A selection outliving its subject is how a gizmo ends up floating over
    /// nothing, and it cannot be prevented at the point of deletion because
    /// undo does not delete, it substitutes.
    func pruneSceneSelection() {
        guard let composition = selectedSceneComposition else {
            sceneSelection = .none
            return
        }
        switch sceneSelection {
        case .none:
            break
        case let .layer(id):
            if composition.layer(id) == nil { sceneSelection = .none }
        case let .light(id):
            if composition.light(id) == nil { sceneSelection = .none }
        }
    }

    /// A new light, placed where it will actually be seen.
    ///
    /// Between the camera and the focal plane, and with a radius that covers a
    /// good part of the frame. A light created at the origin with a default
    /// radius is the commonest way a lighting feature reads as broken: it is
    /// behind the set, or a hundred times too small for it, and the artist sees
    /// nothing change and concludes the button does not work.
    @discardableResult
    func addSceneLight(kind: SceneLightKind, to compositionID: UUID) -> UUID? {
        guard let composition = sceneCompositions.first(where: { $0.id == compositionID })
        else { return nil }
        let focal = composition.camera.focalLength(viewHeight: composition.renderSize.y)
        let plane = composition.camera.positionZ + focal
        // A radius of three quarters of the frame's diagonal at the focal
        // plane: large enough that a point light lands as a visible pool rather
        // than a dot, small enough that its edge is inside the frame and the
        // artist can see it IS a light and not a global brightness change.
        let diagonal = simd_length(composition.renderSize)
        let count = composition.lights.count + 1
        var light = SceneLight(
            name: "\(kind.title) \(count)",
            kind: kind,
            position: composition.camera.position,
            // Two thirds of the way to the focal plane, so a point light sits
            // in FRONT of a layer placed at the default depth and lights it.
            positionZ: composition.camera.positionZ + focal * 0.66,
            radius: diagonal * 0.75
        )
        if kind == .spot {
            // Pointing into the set, which is the only direction a spot created
            // at the camera can usefully point.
            light.azimuth = 0
            light.elevation = .pi / 2
        }
        updateSceneComposition(compositionID) { composition in
            composition.lights.append(light)
        }
        sceneSelection = .light(light.id)
        return light.id
    }

    func updateSceneLight(
        _ lightID: UUID,
        in compositionID: UUID,
        undoable: Bool = true,
        _ change: (inout SceneLight) -> Void
    ) {
        updateSceneComposition(compositionID, undoable: undoable) { composition in
            guard let index = composition.lights.firstIndex(where: { $0.id == lightID })
            else { return }
            var light = composition.lights[index]
            change(&light)
            composition.lights[index] = light
        }
    }

    func removeSceneLight(_ lightID: UUID, from compositionID: UUID) {
        updateSceneComposition(compositionID) { composition in
            composition.lights.removeAll { $0.id == lightID }
        }
        if sceneSelection == .light(lightID) { sceneSelection = .none }
    }

    /// Move a light in the list, which is the order the blends apply in.
    func moveSceneLight(_ lightID: UUID, in compositionID: UUID, forward: Bool) {
        updateSceneComposition(compositionID) { composition in
            guard let index = composition.lights.firstIndex(where: { $0.id == lightID })
            else { return }
            let target = forward ? index + 1 : index - 1
            guard composition.lights.indices.contains(target) else { return }
            composition.lights.swapAt(index, target)
        }
    }

    /// Move a layer one step forward or back in the draw order. The LIST is
    /// who covers whom; depth never reorders it.
    /// Move a layer one step forward or back IN DRAW ORDER.
    ///
    /// Not one step in the array: the array is only the tie-break now, so
    /// swapping two adjacent entries in it would do nothing visible whenever
    /// their layer numbers differ — which is the ordinary case.
    ///
    /// It swaps the two layers' NUMBERS. Reassigning the whole scene's numbers
    /// densely would have been tidier to read and would have thrown away
    /// whatever grouping the artist had set up — a set built on layers 10, 20
    /// and 30 would come back as 0, 1, 2 the first time anybody nudged a card.
    /// When the two are already on the same layer there is no number to swap,
    /// so the tie is what moves: their positions in the array.
    func moveSceneLayer(_ layerID: UUID, in compositionID: UUID, forward: Bool) {
        updateSceneComposition(compositionID) { composition in
            let ordered = composition.drawOrderedLayers
            guard let here = ordered.firstIndex(where: { $0.id == layerID }) else { return }
            let target = forward ? here + 1 : here - 1
            guard ordered.indices.contains(target) else { return }
            let otherID = ordered[target].id
            guard let a = composition.layers.firstIndex(where: { $0.id == layerID }),
                  let b = composition.layers.firstIndex(where: { $0.id == otherID })
            else { return }
            if composition.layers[a].sortingOrder == composition.layers[b].sortingOrder {
                composition.layers.swapAt(a, b)
            } else {
                let keep = composition.layers[a].sortingOrder
                composition.layers[a].sortingOrder = composition.layers[b].sortingOrder
                composition.layers[b].sortingOrder = keep
            }
        }
    }

    func updateSceneLayer(
        _ layerID: UUID,
        in compositionID: UUID,
        undoable: Bool = true,
        _ change: (inout SceneLayer) -> Void
    ) {
        updateSceneComposition(compositionID, undoable: undoable) { composition in
            guard let index = composition.layers.firstIndex(where: { $0.id == layerID }) else { return }
            var layer = composition.layers[index]
            change(&layer)
            composition.layers[index] = layer
        }
    }

    /// The shot at a scene frame, with the camera's own tracks applied.
    ///
    /// EVERY property falls back to the authored camera rather than to a
    /// neutral value. That is the whole of the rule and the reason it is worth
    /// stating: with a neutral fallback, keying FOV alone would "animate" the
    /// untracked position from wherever the artist put it to the origin, and
    /// the shot would teleport the moment the first key was added.
    ///
    /// Sampled on the SCENE's frame axis. A rig layer's speed and offset remap
    /// its own clip time and cannot reach this — a camera move must not
    /// accelerate because a bird was told to flap faster.
    func sceneCamera(for composition: SceneComposition, atFrame frame: Int) -> SceneCamera {
        var camera = composition.camera
        let target = SceneAnimationTarget.camera
        guard sceneAnimationClip.animatedTargetIDs.contains(target) else { return camera }

        if sceneAnimationClip.hasTrack(for: target, property: .cameraTranslate) {
            camera.position = sceneAnimationClip.evaluatedVector2(
                for: target, property: .cameraTranslate,
                frame: frame, fallback: camera.position
            )
        }
        if sceneAnimationClip.hasTrack(for: target, property: .cameraTranslateZ) {
            camera.positionZ = sceneAnimationClip.evaluatedScalar(
                for: target, property: .cameraTranslateZ,
                frame: frame, fallback: camera.positionZ
            )
        }
        if sceneAnimationClip.hasTrack(for: target, property: .cameraRotate3D) {
            let xy = sceneAnimationClip.evaluatedVector2(
                for: target, property: .cameraRotate3D,
                frame: frame,
                fallback: SIMD2<Float>(camera.rotation3D.x, camera.rotation3D.y)
            )
            camera.rotation3D.x = xy.x
            camera.rotation3D.y = xy.y
        }
        if sceneAnimationClip.hasTrack(for: target, property: .cameraRoll) {
            camera.rotation3D.z = sceneAnimationClip.evaluatedScalar(
                for: target, property: .cameraRoll,
                frame: frame, fallback: camera.rotation3D.z
            )
        }
        if sceneAnimationClip.hasTrack(for: target, property: .cameraFOV) {
            let sampled = sceneAnimationClip.evaluatedScalar(
                for: target, property: .cameraFOV,
                frame: frame, fallback: camera.fieldOfView
            )
            // Clamped where it is SAMPLED, not only where it is typed: an eased
            // curve passes through values no keyframe holds, and one that
            // overshoots toward zero would divide by tan(0) for a frame.
            camera.fieldOfView = min(max(sampled, 1), 170)
        }
        return camera
    }

    /// The scene's lights at a frame, with each light's own tracks applied.
    ///
    /// The SAME rule the camera follows, and worth restating because it is the
    /// one that decides whether keying feels safe: every property falls back to
    /// the AUTHORED value, not to a neutral one. Keying intensity alone must
    /// not drag an untracked radius to zero, or the first key an artist sets
    /// would collapse the light they were adjusting.
    ///
    /// Sampled on the SCENE's frame axis, like the camera. A rig layer's speed
    /// remaps its own clip and cannot reach here: a lamp must not flicker
    /// faster because a bird was told to flap faster.
    func sceneLights(for composition: SceneComposition, atFrame frame: Int) -> [SceneLight] {
        guard !composition.lights.isEmpty else { return [] }
        let animated = sceneAnimationClip.animatedTargetIDs
        guard !animated.isEmpty else { return composition.lights }
        return composition.lights.map { light in
            guard animated.contains(light.id) else { return light }
            return sampledSceneLight(light, atFrame: frame)
        }
    }

    /// Everything the renderer needs to light a frame, in one call.
    func sceneLighting(for composition: SceneComposition, atFrame frame: Int) -> SceneLighting {
        SceneLighting(lights: sceneLights(for: composition, atFrame: frame),
                      ambient: composition.ambient)
    }

    private func sampledSceneLight(_ light: SceneLight, atFrame frame: Int) -> SceneLight {
        var result = light
        let clip = sceneAnimationClip
        let target = light.id

        func scalar(_ property: AnimationTrackProperty, _ fallback: Float) -> Float? {
            guard clip.hasTrack(for: target, property: property) else { return nil }
            return clip.evaluatedScalar(for: target, property: property,
                                        frame: frame, fallback: fallback)
        }
        func vector(_ property: AnimationTrackProperty, _ fallback: SIMD2<Float>) -> SIMD2<Float>? {
            guard clip.hasTrack(for: target, property: property) else { return nil }
            return clip.evaluatedVector2(for: target, property: property,
                                         frame: frame, fallback: fallback)
        }

        if let p = vector(.lightTranslate, light.position) { result.position = p }
        if let z = scalar(.lightTranslateZ, light.positionZ) { result.positionZ = z }
        // Clamped where they are SAMPLED, not only where they are typed. An
        // eased curve passes through values no keyframe holds: two keys of
        // intensity 0 and 1 with overshooting tangents dip below zero between
        // them, and a negative intensity is a light that subtracts.
        if let i = scalar(.lightIntensity, light.intensity) { result.intensity = max(i, 0) }
        if let r = scalar(.lightRadius, light.radius) { result.radius = max(r, 0) }
        if let s = scalar(.lightSoftness, light.softness) {
            result.softness = min(max(s, 0), 1)
        }
        if let d = vector(.lightDirection, SIMD2<Float>(light.azimuth, light.elevation)) {
            result.azimuth = d.x
            result.elevation = d.y
        }
        if let a = vector(.lightAngles, SIMD2<Float>(light.innerAngle, light.outerAngle)) {
            // As a PAIR, and in THIS order. The inner angle is clamped
            // against `result.outerAngle`, so assigning it first would clamp it
            // against the angle the shot is leaving rather than the one it is
            // arriving at.
            //
            // What crossed angles actually do, measured rather than assumed:
            // not invert the cone — the `cosine <= cosOuter` test fires first
            // and the interpolating branch becomes unreachable — but collapse
            // its soft edge to a hard one. `SceneLighting.PreparedLight`
            // clamps the pair again, so the shading is safe either way; this
            // clamp is what stops a crossed pair reaching the inspector and
            // being written back as authored the next time the light is keyed.
            result.outerAngle = min(max(a.y, 0), .pi)
            result.innerAngle = min(max(a.x, 0), result.outerAngle)
        }
        for channel in AnimationTrackProperty.lightColourChannels {
            guard let value = scalar(channel.property, light.color[keyPath: channel.axis])
            else { continue }
            result.color[keyPath: channel.axis] = min(max(value, 0), 1)
        }
        return result
    }

    /// Key every property of a light at a frame.
    ///
    /// All of them at once, like the camera key and the rig's transform key.
    /// Keying only what changed leaves the other channels free to drift on the
    /// next key, which reads as the light wandering off on its own.
    func keySceneLight(_ light: SceneLight, atFrame frame: Int) {
        pushUndoState()
        var clip = sceneAnimationClip
        let target = light.id
        clip.upsertKeyframe(targetID: target, property: .lightTranslate,
                            frame: frame, value: .vector2(light.position))
        clip.upsertKeyframe(targetID: target, property: .lightTranslateZ,
                            frame: frame, value: .scalar(light.positionZ))
        clip.upsertKeyframe(targetID: target, property: .lightIntensity,
                            frame: frame, value: .scalar(light.intensity))
        clip.upsertKeyframe(targetID: target, property: .lightRadius,
                            frame: frame, value: .scalar(light.radius))
        clip.upsertKeyframe(targetID: target, property: .lightSoftness,
                            frame: frame, value: .scalar(light.softness))
        clip.upsertKeyframe(targetID: target, property: .lightDirection, frame: frame,
                            value: .vector2(SIMD2<Float>(light.azimuth, light.elevation)))
        clip.upsertKeyframe(targetID: target, property: .lightAngles, frame: frame,
                            value: .vector2(SIMD2<Float>(light.innerAngle, light.outerAngle)))
        for channel in AnimationTrackProperty.lightColourChannels {
            clip.upsertKeyframe(targetID: target, property: channel.property,
                                frame: frame,
                                value: .scalar(light.color[keyPath: channel.axis]))
        }
        sceneAnimationClip = clip
    }

    /// Remove every key a light has at a frame.
    func removeSceneLightKey(_ lightID: UUID, atFrame frame: Int) {
        guard sceneAnimationClip.tracks.contains(where: {
            $0.targetID == lightID && $0.keyframes.contains { $0.frame == frame }
        }) else { return }
        pushUndoState()
        var clip = sceneAnimationClip
        for property in AnimationTrackProperty.lightProperties {
            let ids = Set(
                clip.tracks
                    .first { $0.targetID == lightID && $0.property == property }?
                    .keyframes.filter { $0.frame == frame }.map(\.id) ?? []
            )
            guard !ids.isEmpty else { continue }
            clip.deleteKeyframes(targetID: lightID, property: property, keyframeIDs: ids)
        }
        sceneAnimationClip = clip
    }

    /// Frames carrying at least one key for this light, for the timeline.
    func sceneLightKeyFrames(_ lightID: UUID) -> [Int] {
        var frames = Set<Int>()
        for track in sceneAnimationClip.tracks where track.targetID == lightID {
            for key in track.keyframes { frames.insert(key.frame) }
        }
        return frames.sorted()
    }

    /// Key the whole shot at a frame — the button an artist actually presses.
    ///
    /// All five channels at once, like the rig's transform key: keying only
    /// what changed leaves the other channels free to drift on the next key,
    /// which reads as the camera wandering off on its own.
    func keySceneCamera(_ composition: SceneComposition, atFrame frame: Int) {
        pushUndoState()
        let camera = composition.camera
        let target = SceneAnimationTarget.camera
        var clip = sceneAnimationClip
        clip.upsertKeyframe(targetID: target, property: .cameraTranslate,
                            frame: frame, value: .vector2(camera.position))
        clip.upsertKeyframe(targetID: target, property: .cameraTranslateZ,
                            frame: frame, value: .scalar(camera.positionZ))
        clip.upsertKeyframe(targetID: target, property: .cameraRotate3D,
                            frame: frame,
                            value: .vector2(SIMD2<Float>(camera.rotation3D.x, camera.rotation3D.y)))
        clip.upsertKeyframe(targetID: target, property: .cameraRoll,
                            frame: frame, value: .scalar(camera.rotation3D.z))
        clip.upsertKeyframe(targetID: target, property: .cameraFOV,
                            frame: frame, value: .scalar(camera.fieldOfView))
        sceneAnimationClip = clip
    }

    /// Remove every camera key at a frame.
    func removeSceneCameraKey(atFrame frame: Int) {
        let target = SceneAnimationTarget.camera
        guard sceneAnimationClip.tracks.contains(where: {
            $0.targetID == target && $0.keyframes.contains { $0.frame == frame }
        }) else { return }
        pushUndoState()
        var clip = sceneAnimationClip
        for property in AnimationTrackProperty.cameraProperties {
            let ids = Set(
                clip.tracks
                    .first { $0.targetID == target && $0.property == property }?
                    .keyframes.filter { $0.frame == frame }.map(\.id) ?? []
            )
            guard !ids.isEmpty else { continue }
            clip.deleteKeyframes(targetID: target, property: property, keyframeIDs: ids)
        }
        sceneAnimationClip = clip
    }

    /// Frames carrying at least one camera key, for the timeline to draw.
    var sceneCameraKeyFrames: [Int] {
        let target = SceneAnimationTarget.camera
        var frames = Set<Int>()
        for track in sceneAnimationClip.tracks where track.targetID == target {
            for key in track.keyframes { frames.insert(key.frame) }
        }
        return frames.sorted()
    }

    /// Put the SHOT where the artist is standing. This is an edit — one undo
    /// entry — unlike every navigation gesture, which is none.
    func alignSceneCameraToView(compositionID: UUID) {
        let eye = sceneViewCamera.eye
        let view = sceneViewCamera
        updateSceneComposition(compositionID) { composition in
            composition.camera.position = SIMD2<Float>(eye.x, eye.y)
            composition.camera.positionZ = eye.z
            composition.camera.rotation3D = SIMD3<Float>(view.pitch, view.yaw, 0)
            composition.camera.fieldOfView = view.fieldOfView
        }
    }

    /// Bring the set into view: pivot on the selected card, or on the shot's
    /// frame when nothing is selected, at a distance that fits it.
    ///
    /// Navigation, not an edit — no undo entry. The fit is against the render
    /// frame's size at that depth rather than the card's own pixels, because the
    /// manager does not hold the asset store and a frame-sized fit is what a
    /// full-frame card wants anyway; a small prop ends up with room around it,
    /// which is the right way to be wrong.
    func frameSceneView(compositionID: UUID, layerID: UUID?) {
        guard let composition = sceneCompositions.first(where: { $0.id == compositionID }) else { return }
        let shot = composition.camera
        let focal = shot.focalLength(viewHeight: composition.renderSize.y)
        var view = sceneViewCamera

        let target: SIMD3<Float>
        let extent: Float
        if let layerID, let layer = composition.layer(layerID) {
            target = SIMD3<Float>(layer.position.x, layer.position.y, layer.positionZ)
            let depth = max(layer.positionZ - shot.positionZ, 1)
            extent = max(composition.renderSize.x, composition.renderSize.y)
                * (depth / max(focal, 0.000001))
                * max(layer.scale.x, layer.scale.y, 0.01)
        } else {
            let basis = SceneViewProjection.basis(pitch: shot.rotation3D.x, yaw: shot.rotation3D.y,
                                                  roll: shot.rotation3D.z)
            target = SIMD3<Float>(shot.position.x, shot.position.y, shot.positionZ) + basis.forward * focal
            extent = max(composition.renderSize.x, composition.renderSize.y)
        }
        view.pivot = target
        let half = view.fieldOfView * .pi / 180 * 0.5
        // 1.25: a margin, so the thing framed does not touch the edges.
        view.distance = min(max(extent * 0.5 * 1.25 / max(tan(half), 0.0001),
                                SceneViewCamera.minDistance), SceneViewCamera.maxDistance)
        sceneViewCamera = view
    }

    /// Go and stand where the shot is. Changes nothing that renders, costs no
    /// undo entry — it is a place to stand, not an edit.
    func alignSceneViewToCamera(compositionID: UUID) {
        guard let composition = sceneCompositions.first(where: { $0.id == compositionID }) else { return }
        let shot = composition.camera
        var view = sceneViewCamera
        view.pitch = min(max(shot.rotation3D.x, -SceneViewCamera.pitchLimit),
                         SceneViewCamera.pitchLimit)
        view.yaw = shot.rotation3D.y
        view.fieldOfView = shot.fieldOfView
        let cp = cos(view.pitch), sp = sin(view.pitch)
        let cy = cos(view.yaw), sy = sin(view.yaw)
        let forward = SIMD3<Float>(sy * cp, -sp, cy * cp)
        view.pivot = SIMD3<Float>(shot.position.x, shot.position.y, shot.positionZ)
            + forward * view.distance
        sceneViewCamera = view
    }

    /// True while a click on the canvas is a paint stroke rather than a pick.
    ///
    /// The brush paints `selectedImageID`, so any click that re-selects an image
    /// moves the brush to a different sprite mid-stroke. Two separate places did
    /// that: `MeshTool.onMouseDown` opened with an unconditional
    /// `selectMeshLayer(for: hitTestScreen(...))`, and `ToolManager` ran its
    /// general selection block, which on iPadOS switches on a single tap and can
    /// also hit a bone — and `selectBone` clears `selectedImageID` outright.
    ///
    /// The worst case needed no accidental click at all: `hitTestScreen` returns
    /// the TOPMOST image covering the point, so painting a sprite that sits
    /// behind another one jumped to the sprite in front on the first stroke.
    ///
    /// Deliberately narrow — the mesh tool, weight paint on, and a bone actually
    /// armed. With the Weights panel merely open the canvas still selects
    /// normally, and the Hierarchy panel changes sprite at any time.
    var isWeightPaintStroke: Bool {
        meshWeightPaintEnabled
            && activeWeightPaintBoneID != nil
            && selectedImageID != nil
    }

    // MARK: - IK builder

    /// The IK constraint being authored, or nil when the builder is closed.
    /// Held here rather than in a nested ObservableObject so SwiftUI actually
    /// re-renders: a nested observable's changes do not propagate to views
    /// watching the parent.
    @Published var ikBuilder: IKBuilderDraft?
    /// Bone under the cursor while the builder is picking from the canvas.
    @Published var ikBuilderHoveredBoneID: UUID?

    @Published var selectedKeyframe: SelectedKeyframe?
    @Published var selectedKeyframes: Set<SelectedKeyframe> = []
    @Published private(set) var copiedKeyframes: [CopiedKeyframePayload] = []

    // MARK: - Scene-wide animation (constraints + draw order)

    /// Tracks that are not owned by a bone or a sprite: every constraint
    /// property timeline and the draw order timeline. Keeping them in one clip
    /// keyed by `targetID` puts constraint and draw order timelines on the
    /// animation rather than on the entity, so a clip owns everything it drives.
    @Published var sceneAnimationClip: AnimationClip = AnimationClip(name: "Scene")

    /// Authored constraint values, i.e. the setup pose. Animation writes the
    /// live constraint structs every frame; without this record, scrubbing off
    /// the keyed range would strand a constraint at its last evaluated value.
    @Published private(set) var constraintSetupValues: [UUID: ConstraintSetupValues] = [:]

    // MARK: - Events

    /// Event definitions available to every animation, as an event list
    /// on the skeleton rather than on a single animation.
    @Published var animationEvents: [AnimationEvent] = []

    /// Events crossed by the most recent playhead advance, newest last. The
    /// editor surfaces these; a runtime would forward them to gameplay code.
    @Published private(set) var recentlyFiredEvents: [FiredAnimationEvent] = []

    /// Frame the last event scan ended on, so advancing the playhead fires each
    /// event exactly once instead of re-firing it every tick it remains past.
    private var lastEventScanFrame: Int?

    // MARK: - Skins

    /// Every named skin in the project. The setup arrangement is not a skin in
    /// this list; it is what applies when `activeSkinID` is nil. The default
    /// arrangement is the fallback rather than an entry, so it can never be
    /// deleted out from under the project.
    @Published var skins: [Skin] = []

    /// The skin currently previewed in the viewport.
    @Published var activeSkinID: UUID? {
        didSet {
            guard activeSkinID != oldValue else { return }
            refreshSkinResolution()
        }
    }

    /// Cached resolution of the active skin. Recomputed when skins, slots or
    /// the sprite list change, never per draw call.
    @Published private(set) var skinResolution: SkinResolution = .empty

    /// Sprite IDs in draw order for the current frame, or `nil` when the draw
    /// order timeline is empty and the authored order in `images` applies.
    @Published private(set) var animatedDrawOrder: [UUID]?

    /// Which attachment each slot shows this frame, for the slots the timeline
    /// has an opinion about.
    ///
    /// A slot ABSENT from this map is left to the skin — that is what "no key
    /// yet" means. A slot present with a `nil` value is deliberately empty,
    /// which is a different statement and one the artist can make.
    @Published private(set) var animatedAttachments: [String: UUID?] = [:]

    /// The authored draw order: sprite ids, front to back.
    ///
    /// ITS OWN LIST, and that is the whole point. This used to be stored as
    /// `order` values on the hierarchy items and read back through
    /// `displayHierarchyIDs()` — which does not read an order out, it REBUILDS
    /// one by walking the bone tree: bone, then the sprites bound to it, then
    /// its child bones, using `order` only to sort within a bone. So an order
    /// written across a bone boundary was thrown away the moment the list was
    /// derived again, and sprites bound to nothing were appended after the
    /// whole walk, where no value could lift them in front of a bound one.
    /// That is why it was the LAST sprites that misbehaved worst.
    ///
    /// The tree answers "what is parented to what". Draw order answers "what is
    /// in front of what". They are two questions and they now have two answers.
    ///
    /// Empty means "not authored yet", and the array order of `images` applies.
    @Published private(set) var authoredDrawOrder: [UUID] = []

    /// The authored order, with every current sprite in it exactly once.
    ///
    /// Sprites imported since the order was authored are not in it; they go to
    /// the back, in the order they arrived, rather than vanishing or being
    /// silently pinned somewhere. Ids of sprites that have been deleted drop
    /// out. Resolved on read so nothing has to remember to keep the list in
    /// step with imports and deletions.
    var resolvedDrawOrder: [UUID] {
        let present = Set(images.map(\.id))
        var seen = Set<UUID>()
        var out: [UUID] = []
        out.reserveCapacity(images.count)
        for id in authoredDrawOrder where present.contains(id) && seen.insert(id).inserted {
            out.append(id)
        }
        for image in images where seen.insert(image.id).inserted {
            out.append(image.id)
        }
        return out
    }

    /// Writes the authored draw order. The only way it changes.
    func setAuthoredDrawOrder(_ order: [UUID]) {
        authoredDrawOrder = order
    }

    /// Sprites in the order they must be drawn for the current frame. The
    /// renderer reads this instead of `images` so the authored order (which the
    /// hierarchy and selection depend on) is never reshuffled by playback.
    var renderOrderedImages: [SceneImage] {
        // ONE hidden set: what the skin displaces, plus what an attachment key
        // displaces this frame. The timeline wins for the slots it names
        // because its ids are unioned in after the skin has had its say.
        let hidden = skinResolution.hiddenImageIDs.union(attachmentHiddenImageIDs)
        let visible = hidden.isEmpty ? images : images.filter { !hidden.contains($0.id) }

        // The keyed permutation wins while one is in effect; otherwise the
        // authored list; and with neither, the array order of `images`.
        let order = animatedDrawOrder ?? (authoredDrawOrder.isEmpty ? nil : resolvedDrawOrder)
        guard let order else { return visible }

        var byID: [UUID: SceneImage] = [:]
        byID.reserveCapacity(visible.count)
        for image in visible { byID[image.id] = image }

        var out: [SceneImage] = []
        out.reserveCapacity(visible.count)
        for id in order {
            if let image = byID.removeValue(forKey: id) { out.append(image) }
        }
        // Sprites created after the key was authored are not part of the keyed
        // permutation; they keep their authored relative order and sit behind
        // the keyed ones rather than disappearing.
        if !byID.isEmpty {
            for image in visible where byID[image.id] != nil { out.append(image) }
        }
        return out
    }
    /// When true the physics simulation runs, the Physics Preview tool is active,
    /// and PhysicsConstraintSystem.shared is stepped each frame.
    @Published var isPhysicsPreviewActive: Bool = false {
        didSet {
            PhysicsConstraintSystem.shared.isActive = isPhysicsPreviewActive
            if !isPhysicsPreviewActive { PhysicsConstraintSystem.shared.reset() }
        }
    }

    var isAnimationEditingEnabled = false {
        didSet {
            guard isAnimationEditingEnabled != oldValue else { return }
            if !isAnimationEditingEnabled {
                for index in images.indices { images[index].meshAnimationDeform = nil }
            }
        }
    }
    private var playbackTask: Task<Void, Never>?

    /// Immutable description of the playback run started by `play()`.
    /// Every tick recomputes the playhead from absolute wall-clock time, so
    /// ticking is idempotent: the async safety-net task and the per-frame
    /// render-loop driver can both call `tickPlayback()` without conflict.
    private struct PlaybackSession {
        let startFrame: Int
        let startTime: CFAbsoluteTime
        let framesPerSecond: Double
        let minFrame: Int
        let maxFrame: Int
    }
    private var playbackSession: PlaybackSession?
    private var previewPositions: [UUID: SIMD2<Float>] = [:]
    /// Temporary world-position overrides set by PhysicsPreviewTool during bone dragging.
    private(set) var physicsPreviewOverrides: [UUID: SIMD2<Float>] = [:]

    let undoRedoManager = UndoRedoManager()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var interactionPushed = false

    init() {
    }

    deinit {
        playbackTask?.cancel()
    }

    // MARK: – Undo / Redo

    func pushUndoState() {
        undoRedoManager.push(currentSnapshot())
        syncUndoRedoState()
    }

    /// Call at drag/interaction start — pushes state only once per continuous gesture.
    func beginInteraction() {
        guard !interactionPushed else { return }
        interactionPushed = true
        pushUndoState()
    }

    func endInteraction() {
        interactionPushed = false
    }

    func undo() {
        let current = currentSnapshot()
        guard let previous = undoRedoManager.undo(current: current) else { return }
        applySnapshot(previous)
        syncUndoRedoState()
    }

    func redo() {
        let current = currentSnapshot()
        guard let next = undoRedoManager.redo(current: current) else { return }
        applySnapshot(next)
        syncUndoRedoState()
    }

    private func syncUndoRedoState() {
        canUndo = undoRedoManager.canUndo
        canRedo = undoRedoManager.canRedo
    }

    private func currentSnapshot() -> SceneSnapshot {
        SceneSnapshot(
            images: images,
            skeleton: skeleton,
            sceneAnimationClip: sceneAnimationClip,
            constraintSetupValues: constraintSetupValues,
            skins: skins,
            activeSkinID: activeSkinID,
            animationEvents: animationEvents,
            sceneCompositions: sceneCompositions,
            selectedSceneCompositionID: selectedSceneCompositionID
        )
    }

    private func applySnapshot(_ snapshot: SceneSnapshot) {
        images = snapshot.images
        skeleton = snapshot.skeleton
        sceneAnimationClip = snapshot.sceneAnimationClip
        constraintSetupValues = snapshot.constraintSetupValues
        skins = snapshot.skins
        activeSkinID = snapshot.activeSkinID
        animationEvents = snapshot.animationEvents
        sceneCompositions = snapshot.sceneCompositions
        selectedSceneCompositionID = snapshot.selectedSceneCompositionID
        selectedMeshVertexIndices = []
        selectedMeshInternalEdgeIndex = nil
        pruneSceneAnimationTracks()
        pruneSkins()
        refreshSkinResolution()
        rebuildHierarchyFromState()
        applyAnimations()
    }

    private func rebuildHierarchyFromState() {
        // Sync hierarchy item list after snapshot restore
        let existingImageIDs = Set(images.map(\.id))
        let existingBoneIDs = Set(skeleton.bones.keys)
        hierarchyItems = hierarchyItems.filter {
            existingImageIDs.contains($0.id) || existingBoneIDs.contains($0.id)
        }
    }

    /// `normalMapAssetID` is supplied by the caller rather than looked up
    /// here, because `SceneManager` holds no `AssetManager` and giving it one
    /// to answer a naming question would be a dependency earned by nothing.
    /// `AssetManager.pairedNormalMapID(forArtworkNamed:)` is the lookup.
    func addImage(asset: TextureAsset, position: SIMD2<Float>,
                  normalMapAssetID: UUID? = nil) {
        let id = UUID()
        let image = SceneImage(
            id: id,
            assetID: asset.id,
            name: asset.name,
            basePosition: position,
            position: position,
            baseScale: SIMD2<Float>(repeating: 1.0),
            scale: SIMD2<Float>(repeating: 1.0),
            baseRotation: 0.0,
            rotation: 0.0,
            baseRotation3D: .zero,
            rotation3D: .zero,
            baseSkew: .zero,
            skew: .zero,
            mesh: Mesh.makeQuad(name: "\(asset.name) Mesh", size: asset.size),
            boneBinding: nil,
            isHidden: false,
            // PAIRED AT CREATION, by SpriteKit's `_n` convention. An artist
            // who exported `hero.png` and `hero_n.png` together should not
            // then have to say so in a menu. It lands as an ordinary editable
            // value: clearing it clears it, and undo undoes it.
            normalMapAssetID: normalMapAssetID,
            animationClip: AnimationClip(name: asset.name),
            animationTransformSpace: .world
        )
        images.insert(image, at: 0)

        let hierarchyItem = HierarchyItem(
            id: id,
            name: asset.name,
            type: .image,
            isHidden: false,
            children: [],
            order: 0
        )
        hierarchyItems.insert(hierarchyItem, at: 0)
        normalizeOrder()
        setSelection(ids: [id], primary: id, additive: false)
        // A new sprite may land in an existing slot and become a variant, so the
        // active skin has to be re-resolved.
        refreshSkinResolution()
    }

    func moveHierarchy(from source: IndexSet, to destination: Int) {
        hierarchyItems.move(fromOffsets: source, toOffset: destination)
        normalizeOrder()
        syncImagesToHierarchy()
    }

    func moveHierarchyItem(id: UUID, toDisplayIndex destination: Int) {
        var orderedIDs = displayHierarchyIDs()
        guard let sourceIndex = orderedIDs.firstIndex(of: id) else { return }

        orderedIDs.remove(at: sourceIndex)
        let clampedDestination = max(0, min(destination, orderedIDs.count))
        orderedIDs.insert(id, at: clampedDestination)

        var nextOrderByID: [UUID: Int] = [:]
        for (index, orderedID) in orderedIDs.enumerated() {
            nextOrderByID[orderedID] = index
        }

        for index in hierarchyItems.indices {
            if let nextOrder = nextOrderByID[hierarchyItems[index].id] {
                hierarchyItems[index].order = nextOrder
            }
        }
        hierarchyItems.sort { $0.order < $1.order }
        normalizeOrder()
        syncImagesToHierarchy()
    }

    // MARK: - Draw Order (Layer Order Mode)

    /// Images in draw order, front-most first. The renderer iterates
    /// `images.reversed()`, so `images[0]` is always the top layer — this is
    /// simply the images array, exposed with explicit semantics for the UI.
    var imagesInDrawOrder: [SceneImage] {
        // While animating, the panel must agree with what the viewport shows,
        // which is the keyed permutation rather than the authored order.
        renderOrderedImages
    }

    /// Reordering while animating keys the new order instead of rewriting the
    /// authored one, because in Animate mode a reorder is a keyable event.
    /// Returns true when the reorder was handled as a keyed change.
    private func keyReorderedDrawOrder(imageID: UUID, toDrawIndex destination: Int) -> Bool {
        guard isAnimationEditingEnabled else { return false }
        let order = renderOrderedImages.map(\.id)
        guard let moved = Self.movingID(imageID, toRow: destination, in: order) else {
            return false
        }
        keyDrawOrder(moved)
        return true
    }

    /// Moves an image to a new position in the draw order (0 = front-most)
    /// while leaving bones and structural hierarchy untouched. Images are
    /// permuted among the slots they already occupy in the display order, so
    /// the change is applied immediately and never breaks bone grouping.
    /// Moves a sprite to a row of the draw order. 0 is front-most.
    ///
    /// It permutes the authored list and touches nothing else. It used to
    /// rewrite `hierarchyItems[].order` and re-derive `images` from the tree,
    /// which cannot express a draw order at all: see `authoredDrawOrder`.
    func moveImageInDrawOrder(imageID: UUID, toDrawIndex destination: Int) {
        if keyReorderedDrawOrder(imageID: imageID, toDrawIndex: destination) { return }
        // The row the artist dropped on, resolved against the list they are
        // looking at — which is now the same list being written.
        let order = resolvedDrawOrder
        guard let moved = Self.movingID(imageID, toRow: destination, in: order),
              moved != order else { return }
        pushUndoState()
        setAuthoredDrawOrder(moved)
    }

    /// The id sitting at a row of the list the artist is looking at.
    ///
    /// A row past the end means "the back", which a drop below the last row
    /// legitimately is.
    static func idAtRow(_ row: Int, in order: [UUID]) -> UUID? {
        guard !order.isEmpty else { return nil }
        return order[max(0, min(row, order.count - 1))]
    }

    /// Moves `moved` so it ends up where `target` currently is.
    ///
    /// Not `remove` then `insert(at: destination)`. That index was measured
    /// BEFORE the removal, so dragging downward — where removing shifts
    /// everything after the source left by one — landed the sprite one slot
    /// past the row it was dropped on. Dragging down by one put it back where
    /// it started, which is what "the order is not respected" looked like.
    ///
    /// Working from the target's IDENTITY instead of its index is immune to
    /// that: the target is found again after the removal, and the moved id
    /// goes before or after it according to the direction of travel.
    static func movingID(_ moved: UUID, before target: UUID, in order: [UUID]) -> [UUID]? {
        guard let source = order.firstIndex(of: moved),
              let destination = order.firstIndex(of: target) else { return nil }
        guard source != destination else { return order }
        var out = order
        out.remove(at: source)
        guard let settled = out.firstIndex(of: target) else { return nil }
        out.insert(moved, at: source < destination ? settled + 1 : settled)
        return out
    }

    /// The same move, addressed by row rather than by target id.
    static func movingID(_ moved: UUID, toRow row: Int, in order: [UUID]) -> [UUID]? {
        guard let target = idAtRow(row, in: order) else { return nil }
        return movingID(moved, before: target, in: order)
    }

    /// Reorders the draw order so a sprite driven by a deeper bone draws in
    /// front of one driven by its parent — a forearm over an upper arm.
    ///
    /// A COMMAND, NOT A RULE. It would be easy to compute this every frame
    /// instead, and wrong: draw order here is authored, in the Draw Order
    /// panel, and a rule that recomputed it from the rig would overwrite the
    /// artist's ordering silently every time a bone moved. Run once, it writes
    /// the AUTHORED order — so it is undoable, it survives saving and export,
    /// and it can be adjusted by hand afterwards like any other ordering.
    ///
    /// Depth is taken from the DEEPEST bone that drives the sprite: a skinned
    /// sprite spanning an elbow follows the forearm, which is the half that
    /// moves. A sprite driven by nothing has no depth and keeps its place at
    /// the back rather than being thrown to one end. Sprites at the same depth
    /// keep the order they were given, so this settles what the rig knows and
    /// leaves everything else alone — running it twice changes nothing.
    func sortDrawOrderByBoneDepth() {
        guard !images.isEmpty, !skeleton.bones.isEmpty else { return }

        var depthByBone: [UUID: Int] = [:]
        for entry in IKBuilderRules.hierarchicalOrder(skeleton: skeleton) {
            depthByBone[entry.bone.id] = entry.depth
        }

        func depth(of image: SceneImage) -> Int {
            var deepest: Int?
            for boneID in image.mesh.boundBoneIDs {
                if let d = depthByBone[boneID] {
                    deepest = max(deepest ?? d, d)
                }
            }
            if let bindingID = image.boneBinding?.boneID, let d = depthByBone[bindingID] {
                deepest = max(deepest ?? d, d)
            }
            // Unbound sprites sort before every bound one, keeping the back.
            return deepest ?? -1
        }

        // Compare against, and reorder, the order actually in force.
        let authored = resolvedDrawOrder
        let byID = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
        let inOrder = authored.compactMap { byID[$0] }
        let position = Dictionary(uniqueKeysWithValues: authored.enumerated().map { ($1, $0) })
        let sorted = inOrder.sorted { lhs, rhs in
            let leftDepth = depth(of: lhs), rightDepth = depth(of: rhs)
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return (position[lhs.id] ?? 0) < (position[rhs.id] ?? 0)
        }
        guard sorted.map(\.id) != authored else { return }

        // Straight into the authored list. This used to write the result into
        // the hierarchy items' `order` and re-derive from the tree, which
        // regroups every bound sprite under its bone — so the command computed
        // a correct order and then had it undone by the read.
        pushUndoState()
        setAuthoredDrawOrder(sorted.map(\.id))
    }

    /// Nudges an image one step forward (toward the viewer) or backward in
    /// the draw order. Used by keyboard shortcuts and row controls.
    func nudgeImageInDrawOrder(imageID: UUID, forward: Bool) {
        // Index against the order actually on screen, so nudging behaves the
        // same whether or not a draw order key is in effect.
        let visible = imagesInDrawOrder
        guard let index = visible.firstIndex(where: { $0.id == imageID }) else { return }
        let target = forward ? index - 1 : index + 1
        guard target >= 0, target < visible.count else { return }
        moveImageInDrawOrder(imageID: imageID, toDrawIndex: target)
    }

    func deleteHierarchy(at offsets: IndexSet) {
        pushUndoState()
        let ids = offsets.compactMap { hierarchyItems[safe: $0]?.id }
        hierarchyItems.remove(atOffsets: offsets)
        images.removeAll { ids.contains($0.id) }
        pruneSkins()
        refreshSkinResolution()
        removeBones(ids: ids)
        selectedImageIDs.subtract(ids)
        if selectedImageID != nil, ids.contains(selectedImageID!) {
            selectedImageID = selectedImageIDs.first
        }
        normalizeOrder()
    }

    func deleteHierarchy(itemID: UUID) {
        pushUndoState()
        hierarchyItems.removeAll { $0.id == itemID }
        images.removeAll { $0.id == itemID }
        pruneSkins()
        refreshSkinResolution()
        removeBones(ids: [itemID])
        selectedImageIDs.remove(itemID)
        if selectedImageID == itemID {
            selectedImageID = selectedImageIDs.first
        }
        normalizeOrder()
    }

    func duplicateSelected() {
        guard let selectedID = selectedImageID else { return }
        duplicateItem(id: selectedID)
    }

    func duplicateItem(id: UUID) {
        guard let imageIndex = images.firstIndex(where: { $0.id == id }),
              let hierarchyIndex = hierarchyItems.firstIndex(where: { $0.id == id }) else {
            return
        }
        pushUndoState()

        let sourceImage = images[imageIndex]
        let sourceHierarchy = hierarchyItems[hierarchyIndex]
        let newID = UUID()
        let newName = "\(sourceHierarchy.name) Copy"

        let duplicatedImage = SceneImage(
            id: newID,
            assetID: sourceImage.assetID,
            name: newName,
            basePosition: sourceImage.basePosition,
            position: sourceImage.position + SIMD2<Float>(12, -12),
            baseScale: sourceImage.baseScale,
            scale: sourceImage.scale,
            baseRotation: sourceImage.baseRotation,
            rotation: sourceImage.rotation,
            baseRotation3D: sourceImage.baseRotation3D,
            rotation3D: sourceImage.rotation3D,
            baseSkew: sourceImage.baseSkew,
            skew: sourceImage.skew,
            mesh: sourceImage.mesh.duplicated(named: "\(newName) Mesh"),
            boneBinding: sourceImage.boneBinding,
            isHidden: sourceImage.isHidden,
            tintColor: sourceImage.tintColor,
            blendMode: sourceImage.blendMode,
            animationClip: sourceImage.animationClip.retargeted(from: sourceImage.id, to: newID, renamedTo: newName),
            animationTransformSpace: sourceImage.animationTransformSpace
        )
        let duplicatedHierarchy = HierarchyItem(
            id: newID,
            name: newName,
            type: sourceHierarchy.type,
            isHidden: sourceHierarchy.isHidden,
            children: sourceHierarchy.children,
            order: sourceHierarchy.order + 1
        )

        images.insert(duplicatedImage, at: imageIndex)
        hierarchyItems.insert(duplicatedHierarchy, at: hierarchyIndex)
        normalizeOrder()
        setSelection(ids: [newID], primary: newID, additive: false)
    }

    func setSelection(ids: [UUID], primary: UUID?, additive: Bool) {
        if additive {
            selectedImageIDs.formUnion(ids)
        } else {
            selectedImageIDs = Set(ids)
        }
        selectedImageID = primary ?? selectedImageIDs.first
        isMeshLayerSelected = false
        hoveredMeshVertexIndex = nil
        selectedMeshVertexIndices = []
        selectedMeshInternalEdgeIndex = nil
        // The whole bone selection, not just the primary. Clearing one field of
        // three left the bones in `selectedBoneIDs` after a sprite was picked —
        // invisible, and still what a transform would have iterated.
        applyBoneSelection([])
        selectedKeyframes = selectedKeyframes.filter { selectedImageIDs.contains($0.imageID) }
        selectedKeyframe = selectedKeyframes.first
    }

    // MARK: - The way out

    /// What the escape ladder reads, right now.
    ///
    /// Assembled here because these ten facts live on this object; the ORDER
    /// they are considered in lives in `EditorEscape`, which knows nothing
    /// about the editor and can therefore be checked exhaustively.
    var escapeState: EditorEscape.State {
        EditorEscape.State(
            isPickingIKBone: ikBuilder?.pickingSlot != nil,
            hasIKDraft: ikBuilder != nil,
            selectedMeshVertexCount: selectedMeshVertexIndices.count,
            isWeightPainting: meshWeightPaintEnabled,
            isMeshEditing: isMeshEditEnabled,
            isBindingBones: isBindingBonesMode,
            selectedBoneCount: selectedBoneIDs.count,
            selectedImageCount: selectedImageIDs.count,
            hasSelectedConstraint: selectedConstraintID != nil,
            hasNonDefaultTool: false)
    }

    /// Leave one rung. Returns the rung that was left, or nil when there was
    /// nothing to leave.
    ///
    /// `hasNonDefaultTool` is the one fact this object does not hold, so the
    /// caller supplies it and handles that rung — it is the tool manager's to
    /// change. Everything else is applied here.
    @discardableResult
    func exitDeepestScope(hasNonDefaultTool: Bool) -> EditorScope? {
        var state = escapeState
        state.hasNonDefaultTool = hasNonDefaultTool
        guard let scope = EditorEscape.deepest(state) else { return nil }

        switch scope {
        case .ikBuilderPick:
            ikBuilder?.pickingSlot = nil
            ikBuilderHoveredBoneID = nil
        case .ikBuilderDraft:
            cancelIKBuilder()
        case .meshVertexSelection:
            selectedMeshVertexIndices = []
            selectedMeshInternalEdgeIndex = nil
            hoveredMeshVertexIndex = nil
        case .weightPaint:
            meshWeightPaintEnabled = false
            activeWeightPaintBoneID = nil
        case .meshEdit:
            // Everything that lives inside the edit goes with it, which is what
            // `EditorEscape.leaving` models. If it did not, the next press
            // would find a vertex selection belonging to an edit that is over.
            isMeshEditEnabled = false
            meshWeightPaintEnabled = false
            activeWeightPaintBoneID = nil
            selectedMeshVertexIndices = []
            selectedMeshInternalEdgeIndex = nil
            hoveredMeshVertexIndex = nil
            isMeshLayerSelected = false
        case .bindBones:
            isBindingBonesMode = false
            hoveredBindBoneID = nil
        case .boneSelection:
            selectBone(nil)
        case .imageSelection:
            selectedImageID = nil
            selectedImageIDs = []
            selectedConstraintID = nil
        case .activeTool:
            // The caller's, because the tool is not this object's to set.
            break
        }
        return scope
    }

    func clearSelection() {
        selectedImageID = nil
        selectedImageIDs = []
        applyBoneSelection([])
        isMeshLayerSelected = false
        hoveredMeshVertexIndex = nil
        selectedMeshVertexIndices = []
        selectedMeshInternalEdgeIndex = nil
    }

    func selectMeshLayer(for imageID: UUID) {
        setSelection(ids: [imageID], primary: imageID, additive: false)
        isMeshLayerSelected = true
    }

    /// The one place the three bone-selection fields are written.
    ///
    /// `order` is authoritative: the set is its contents and the primary is its
    /// last element. Everything else — click, Cmd-click, Shift-run, the canvas
    /// rectangle, the hierarchy, the timeline — arrives here.
    private func applyBoneSelection(_ order: [UUID]) {
        var seen = Set<UUID>()
        // First appearance wins, so a caller that passes a bone twice does not
        // get to change where it sits in the order.
        let deduped = order.filter { skeleton.bones[$0] != nil && seen.insert($0).inserted }
        boneSelectionOrder = deduped
        selectedBoneIDs = Set(deduped)
        selectedBoneID = deduped.last
    }

    /// Replace or extend the bone selection.
    ///
    /// `ids` arrive in the order they should hold — for the canvas rectangle
    /// that is skeleton order, so re-dragging the same box gives the same
    /// answer. `primary`, when given and still present, is moved to the end so
    /// it stays the active bone: a box that still contains the bone you were
    /// working on must not hand the inspector to a different one.
    func setBoneSelection(_ ids: [UUID], primary: UUID?, additive: Bool) {
        var order = additive ? boneSelectionOrder : []
        for id in ids where !order.contains(id) {
            order.append(id)
        }
        if let primary, order.contains(primary) {
            order.removeAll { $0 == primary }
            order.append(primary)
        }
        applyBoneSelection(order)
        if !order.isEmpty { boneSelectionBecameNonEmpty() }
    }

    /// What picking a bone always means, wherever the pick came from.
    ///
    /// A sprite and a bone are not both the selection, so one displaces the
    /// other — and the modes that act on a sprite's mesh have nothing left to
    /// act on. This used to be six lines copied into `selectBone` and
    /// `toggleBoneSelection`, and they had already drifted: the toggle cleared
    /// the sprite but left weight paint lit over a mesh it no longer had.
    private func boneSelectionBecameNonEmpty() {
        selectedImageID = nil
        selectedImageIDs = []
        isMeshLayerSelected = false
        hoveredMeshVertexIndex = nil
        selectedMeshVertexIndices = []
        selectedMeshInternalEdgeIndex = nil
        leaveSpriteModes()
    }

    func selectBone(_ id: UUID?) {
        applyBoneSelection(id.map { [$0] } ?? [])
        if id != nil { boneSelectionBecameNonEmpty() }
    }

    /// Ends the modes that act on a sprite, because the sprite is gone.
    ///
    /// Weight paint and mesh editing both work on the selected sprite's mesh,
    /// and `boneSelectionBecameNonEmpty` clears that selection just above.
    /// Leaving the brush lit over nothing is how it ends up painting the
    /// previous sprite,
    /// or nothing at all, while the panel still says it is running.
    ///
    /// Changing WHICH sprite is painted is the opposite case and deliberately
    /// not routed through here: the hierarchy and the canvas both select the
    /// new sprite's mesh and keep the mode, because changing what is painted
    /// is not the same as deciding to stop painting.
    private func leaveSpriteModes() {
        guard isSpriteMeshMode || isBindingBonesMode
                || pendingCanvasMode != nil else { return }
        meshWeightPaintEnabled = false
        isMeshEditEnabled = false
        isBindingBonesMode = false
        activeWeightPaintBoneID = nil
        pendingCanvasMode = nil
        meshEditNotice = nil
        if toolManager?.currentTool == .mesh {
            toolManager?.setTool(.select)
        }
    }

    /// Cmd-click semantics on a bone: toggle membership in the multi-selection.
    /// The primary `selectedBoneID` becomes the most recently added bone, or any
    /// remaining bone when the primary itself was just toggled off.
    func toggleBoneSelection(_ id: UUID) {
        if boneSelectionOrder.contains(id) {
            // The bone before it becomes active — the same one every run, which
            // `selectedBoneIDs.first` could not promise.
            applyBoneSelection(boneSelectionOrder.filter { $0 != id })
        } else {
            setBoneSelection([id], primary: id, additive: true)
        }
    }

    /// Selected bones sorted root → tip according to the skeleton hierarchy.
    ///
    /// Two callers, one order. IK wants it so a chain authored from the canvas
    /// is well-defined regardless of click order. The transforms NEED it: the
    /// bone setters take world values and convert them against the parent's
    /// CURRENT world transform, so a child written before its parent is
    /// converted against the parent's old angle and then inherits the parent's
    /// rotation on top — it turns twice. Depth order is the correctness
    /// condition, not a tidiness preference.
    ///
    /// Walked over `boneSelectionOrder` rather than the Set, and tie-broken by
    /// position in it, so siblings at equal depth come out the same way twice.
    /// `sorted(by:)` is not stable, and a Set has no order to be stable about.
    var selectedBonesInChainOrder: [Bone] {
        let entries: [(position: Int, bone: Bone)] = boneSelectionOrder.enumerated()
            .compactMap { pair in
                guard let bone = skeleton.bone(pair.element) else { return nil }
                return (position: pair.offset, bone: bone)
            }
        return entries.sorted { lhs, rhs in
            let leftDepth = depthOf(lhs.bone), rightDepth = depthOf(rhs.bone)
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return lhs.position < rhs.position
        }.map { $0.bone }
    }

    /// The same order, as ids — what a transform iterates.
    var selectedBonesInDepthOrder: [UUID] { selectedBonesInChainOrder.map(\.id) }

    private func depthOf(_ bone: Bone) -> Int {
        var depth = 0
        var current = bone.parentID
        var safety = 0
        while let parentID = current, safety < 64 {
            depth += 1
            current = skeleton.bone(parentID)?.parentID
            safety += 1
        }
        return depth
    }

    // Note: IK constraints used to be created by `createIKConstraintFromSelection`,
    // which took the deepest selected bone as the target. That rule is removed
    // rather than kept alongside the builder: for the standard setup where the
    // target is an unparented handle bone, the handle is the SHALLOWEST bone in
    // the selection, so the rule chose a bone inside the chain every time and
    // produced a constraint the solver cannot satisfy.

    // MARK: - IK builder

    /// Opens the builder, seeding it from whatever bones are already selected so
    /// an artist who selected a limb first does not have to pick it twice.
    func beginIKBuilder() {
        var draft = IKBuilderDraft()
        draft.name = "IK \(skeleton.ikConstraints.count + 1)"

        let ordered = selectedBonesInChainOrder
        if ordered.count == 1 {
            draft.chain = [ordered[0].id]
        } else if ordered.count > 1 {
            // Only seed a chain that is genuinely contiguous; a scattered
            // selection would otherwise open the panel already invalid.
            let ids = ordered.map { $0.id }
            if let full = IKBuilderRules.path(from: ids[0], to: ids[ids.count - 1], skeleton: skeleton),
               full.count == ids.count, full == ids {
                draft.chain = ids
            } else {
                draft.chain = [ids[0]]
            }
        }
        // Picking starts on whichever slot is still empty, so the first canvas
        // click always lands somewhere useful.
        draft.pickingSlot = draft.chain.isEmpty ? .chain : .target
        ikBuilder = draft
    }

    func cancelIKBuilder() {
        ikBuilder = nil
        ikBuilderHoveredBoneID = nil
    }

    var ikBuilderValidation: IKBuilderValidation {
        guard let draft = ikBuilder else { return IKBuilderValidation() }
        return IKBuilderRules.validate(draft, skeleton: skeleton)
    }

    /// Handles a bone click while the builder is picking from the canvas.
    /// Returns true when the click was consumed, so normal selection is skipped.
    @discardableResult
    func ikBuilderHandleBonePick(_ boneID: UUID) -> Bool {
        guard var draft = ikBuilder, let slot = draft.pickingSlot else { return false }
        switch slot {
        case .chain:
            draft.chain = IKBuilderRules.addToChain(boneID, chain: draft.chain, skeleton: skeleton)
            // Clicking the bone that is already the target moves it into the
            // chain; leaving it in both slots is never what was meant.
            if draft.targetID == boneID { draft.targetID = nil }
        case .target:
            draft.targetID = (draft.targetID == boneID) ? nil : boneID
        }
        ikBuilder = draft
        return true
    }

    func ikBuilderSetPicking(_ slot: IKBuilderSlot?) {
        guard var draft = ikBuilder else { return }
        draft.pickingSlot = (draft.pickingSlot == slot) ? nil : slot
        ikBuilder = draft
        if draft.pickingSlot == nil { ikBuilderHoveredBoneID = nil }
    }

    func ikBuilderSetChain(_ chain: [UUID]) {
        guard var draft = ikBuilder else { return }
        draft.chain = chain
        ikBuilder = draft
    }

    func ikBuilderSetTarget(_ boneID: UUID?) {
        guard var draft = ikBuilder else { return }
        draft.targetID = boneID
        if let boneID, let index = draft.chain.firstIndex(of: boneID) {
            // A bone cannot be both the chain and what the chain reaches for.
            draft.chain.remove(at: index)
        }
        ikBuilder = draft
    }

    func ikBuilderSetName(_ name: String) {
        guard var draft = ikBuilder else { return }
        draft.name = name
        ikBuilder = draft
    }

    func ikBuilderSetBendPositive(_ value: Bool) {
        guard var draft = ikBuilder else { return }
        draft.bendPositive = value
        ikBuilder = draft
    }

    func ikBuilderSetMix(_ value: Float) {
        guard var draft = ikBuilder else { return }
        draft.mix = Swift.max(0, Swift.min(1, value))
        ikBuilder = draft
    }

    /// Commits the draft. Returns the new constraint's id, or nil when the
    /// draft is still invalid.
    @discardableResult
    func commitIKBuilder() -> UUID? {
        guard let draft = ikBuilder else { return nil }
        guard IKBuilderRules.validate(draft, skeleton: skeleton).canCreate,
              let targetID = draft.targetID else { return nil }

        pushUndoState()
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let constraint = IKConstraint(
            name: trimmed.isEmpty ? "IK \(skeleton.ikConstraints.count + 1)" : trimmed,
            order: skeleton.ikConstraints.map(\.order).max().map { $0 + 1 } ?? 0,
            mix: draft.mix,
            boneChain: draft.chain,
            targetBoneID: targetID,
            bendPositive: draft.bendPositive
        )
        skeleton.ikConstraints.append(constraint)
        ikBuilder = nil
        ikBuilderHoveredBoneID = nil
        selectedConstraintID = constraint.id
        return constraint.id
    }

    /// Create a Path Constraint from the current multi-selection.
    /// First N-1 bones (ordered root → leaf) become path control points.
    /// The last bone becomes the first constrained follower.
    /// Minimum 3 bones required (2 path points + 1 follower).
    @discardableResult
    func createPathConstraintFromSelection() -> UUID? {
        let ordered = selectedBonesInChainOrder
        guard ordered.count >= 3 else { return nil }
        pushUndoState()
        let pathBones = ordered.dropLast().map(\.id)
        let follower  = ordered.last!.id
        let nextIndex = skeleton.pathConstraints.count + 1
        let maxOrder  = skeleton.allConstraints.map(\.order).max().map { $0 + 1 } ?? 0
        let constraint = PathConstraint(
            name: "Path \(nextIndex)",
            order: maxOrder,
            pathBones: Array(pathBones),
            bones: [follower]
        )
        skeleton.pathConstraints.append(constraint)
        return constraint.id
    }

    // MARK: - Transform Constraint Management

    /// Create a Transform Constraint from the current multi-selection.
    /// Convention (matches IK ordering): every selected bone except the deepest
    /// becomes an affected bone; the deepest selected bone becomes the target.
    /// Minimum 2 bones required (1 affected + 1 target).
    @discardableResult
    func createTransformConstraintFromSelection() -> UUID? {
        let ordered = selectedBonesInChainOrder
        guard ordered.count >= 2 else { return nil }
        pushUndoState()
        let target = ordered.last!.id
        let affected = ordered.dropLast().map(\.id)
        let nextIndex = skeleton.transformConstraints.count + 1
        // Order between IK (0…49) and Physics (≥100). Default 50 keeps Transform
        // Constraints downstream of IK / Path so they can post-process those results.
        let baseOrder = skeleton.transformConstraints.map(\.order).max().map { $0 + 1 } ?? 50
        let constraint = TransformConstraint(
            name: "Transform \(nextIndex)",
            order: baseOrder,
            targetBoneID: target,
            affectedBones: Array(affected)
        )
        skeleton.transformConstraints.append(constraint)
        selectedConstraintID = constraint.id
        return constraint.id
    }

    /// Remove a Transform Constraint by id. No-op if not found.
    func deleteTransformConstraint(_ id: UUID) {
        guard skeleton.transformConstraints.contains(where: { $0.id == id }) else { return }
        pushUndoState()
        skeleton.transformConstraints.removeAll { $0.id == id }
        if selectedConstraintID == id { selectedConstraintID = nil }
        // Drop the constraint's timelines with it, so the timeline never shows
        // rows for something that no longer exists.
        pruneSceneAnimationTracks()
    }

    /// Duplicate a Transform Constraint preserving every property except id and name.
    /// New copy is inserted directly after the source so the inspector keeps a stable
    /// "edit the original, then the copy next to it" order.
    @discardableResult
    func duplicateTransformConstraint(_ id: UUID) -> UUID? {
        guard let index = skeleton.transformConstraints.firstIndex(where: { $0.id == id }) else { return nil }
        pushUndoState()
        var copy = skeleton.transformConstraints[index]
        let suffix = skeleton.transformConstraints.count + 1
        copy = TransformConstraint(
            id: UUID(),
            name: "\(copy.name) Copy",
            enabled: copy.enabled,
            order: copy.order + 1,
            mix: copy.mix,
            targetBoneID: copy.targetBoneID,
            affectedBones: copy.affectedBones,
            copyPosition: copy.copyPosition,
            copyRotation: copy.copyRotation,
            copyScale: copy.copyScale,
            copyShear: copy.copyShear,
            positionMix: copy.positionMix,
            rotationMix: copy.rotationMix,
            scaleMix: copy.scaleMix,
            shearMix: copy.shearMix,
            offsetPositionX: copy.offsetPositionX,
            offsetPositionY: copy.offsetPositionY,
            offsetRotation: copy.offsetRotation,
            offsetScaleX: copy.offsetScaleX,
            offsetScaleY: copy.offsetScaleY,
            offsetShear: copy.offsetShear
        )
        _ = suffix // silence unused warning when refactoring naming logic later
        skeleton.transformConstraints.insert(copy, at: index + 1)
        selectedConstraintID = copy.id
        return copy.id
    }

    /// Rename a Transform Constraint.
    func renameTransformConstraint(_ id: UUID, to newName: String) {
        guard let index = skeleton.transformConstraints.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != skeleton.transformConstraints[index].name else { return }
        pushUndoState()
        skeleton.transformConstraints[index].name = trimmed
    }

    /// Reorder a Transform Constraint within the list (visual order). The numeric
    /// `order` property is renormalized so evaluation reflects the new list order.
    func moveTransformConstraint(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty,
              source.allSatisfy({ skeleton.transformConstraints.indices.contains($0) }) else { return }
        pushUndoState()
        skeleton.transformConstraints.move(fromOffsets: source, toOffset: destination)
        renormalizeTransformConstraintOrder()
    }

    /// Compact `order` values to the [50, 50+N) range so insertion / move keeps a
    /// clean monotonic sequence inside the Transform layer of the evaluation pipeline.
    private func renormalizeTransformConstraintOrder() {
        let base = 50
        for index in skeleton.transformConstraints.indices {
            skeleton.transformConstraints[index].order = base + index
        }
    }

    /// Add a bone to a Transform Constraint's affected list. No-op if already present
    /// or if the bone is the constraint's own target.
    func addAffectedBone(_ boneID: UUID, to constraintID: UUID) {
        guard let index = skeleton.transformConstraints.firstIndex(where: { $0.id == constraintID }) else { return }
        let c = skeleton.transformConstraints[index]
        guard boneID != c.targetBoneID, !c.affectedBones.contains(boneID) else { return }
        pushUndoState()
        skeleton.transformConstraints[index].affectedBones.append(boneID)
    }

    /// Remove a bone from a Transform Constraint's affected list.
    func removeAffectedBone(_ boneID: UUID, from constraintID: UUID) {
        guard let index = skeleton.transformConstraints.firstIndex(where: { $0.id == constraintID }) else { return }
        guard skeleton.transformConstraints[index].affectedBones.contains(boneID) else { return }
        pushUndoState()
        skeleton.transformConstraints[index].affectedBones.removeAll { $0 == boneID }
    }

    /// Replace the target bone of a Transform Constraint. The bone is also removed
    /// from the affected list if it happened to be there (a bone can't drive itself).
    func setTransformConstraintTarget(_ constraintID: UUID, target boneID: UUID) {
        guard let index = skeleton.transformConstraints.firstIndex(where: { $0.id == constraintID }) else { return }
        guard skeleton.transformConstraints[index].targetBoneID != boneID else { return }
        pushUndoState()
        skeleton.transformConstraints[index].targetBoneID = boneID
        skeleton.transformConstraints[index].affectedBones.removeAll { $0 == boneID }
    }

    // MARK: - Physics Constraint Management

    /// Create a Physics Constraint from the current bone selection.
    /// All selected bones (ordered root → leaf) become the affected chain.
    /// Minimum 1 bone. Root is pinned; others are simulated.
    @discardableResult
    func createPhysicsConstraintFromSelection(type: PhysicsType = .spring,
                                              preset: PhysicsPreset = .hair) -> UUID? {
        let ordered = selectedBonesInChainOrder
        guard !ordered.isEmpty else { return nil }
        pushUndoState()
        let nextIndex = skeleton.physicsConstraints.count + 1
        let maxOrder  = (skeleton.allConstraints.map(\.order).max() ?? 99) + 1
        let constraint = PhysicsConstraint(
            name: "\(preset.displayName) \(nextIndex)",
            order: max(maxOrder, 100),
            mix: 1.0,
            physicsType: type,
            affectedBones: ordered.map(\.id),
            settings: preset.settings()
        )
        skeleton.physicsConstraints.append(constraint)
        return constraint.id
    }

    /// Stop and reset the physics simulation to rest state.
    func resetPhysicsSimulation() {
        PhysicsConstraintSystem.shared.reset()
    }

    /// Stub: bake physics simulation to animation keyframes.
    /// Full implementation requires stepping the sim forward N frames and committing
    /// keyframes — scheduled for Phase 2.
    func bakePhysicsToKeys() {
        // TODO: Phase 2 — step simulation N frames, commit position/rotation keyframes
    }

    // MARK: - Physics Preview Bone Override
    // PhysicsPreviewTool uses these to let the user drag bones during simulation.

    func setPhysicsPreviewBoneOverride(_ boneID: UUID, worldPosition: SIMD2<Float>) {
        physicsPreviewOverrides[boneID] = worldPosition
    }

    func clearPhysicsPreviewBoneOverride(_ boneID: UUID) {
        physicsPreviewOverrides.removeValue(forKey: boneID)
    }

    func setBoneCreationPreview(start: SIMD2<Float>?, end: SIMD2<Float>?) {
        boneCreationPreviewStart = start
        boneCreationPreviewEnd = end
    }

    @discardableResult
    func addBone(start: SIMD2<Float>, end: SIMD2<Float>, parentID: UUID? = nil) -> UUID {
        pushUndoState()
        let boneIndex = skeleton.bones.count + 1
        let bone = Bone.make(
            name: "Bone \(boneIndex)",
            start: start,
            end: end,
            parentID: parentID,
            parentMatrix: parentID.flatMap { skeleton.worldMatrix(for: $0) }
        )
        skeleton = skeleton.addingBone(bone)

        let hierarchyItem = HierarchyItem(
            id: bone.id,
            name: bone.name,
            type: .bone,
            isHidden: false,
            children: [],
            order: max((hierarchyItems.map(\.order).max() ?? -1) + 1, 0)
        )
        hierarchyItems.append(hierarchyItem)
        normalizeOrder()
        syncImagesToHierarchy()
        selectBone(bone.id)
        return bone.id
    }

    func moveBoneRoot(id: UUID, to worldStart: SIMD2<Float>) {
        guard var bone = skeleton.bones[id] else { return }
        let localStart = skeleton.localPoint(worldStart, relativeTo: bone.parentID)
        bone.localTransform.position = SIMD3<Float>(localStart.x, localStart.y, 0)
        if !isAnimationEditingEnabled && !isPoseMode {
            bone.baseTransform.position = bone.localTransform.position
        }
        skeleton.bones[id] = bone
        if isAnimationEditingEnabled && !isPoseMode {
            commitKeyframe(for: id, property: .translate,
                           value: .translate(SIMD2<Float>(bone.localTransform.position.x, bone.localTransform.position.y)))
        } else {
            applyAnimations()
        }
    }

    func moveBoneTip(id: UUID, to worldTip: SIMD2<Float>) {
        guard var bone = skeleton.bones[id] else { return }
        let worldStart = skeleton.lineSegment(for: id)?.start ?? worldTip
        let parentSpaceTip = skeleton.localPoint(worldTip, relativeTo: bone.parentID)
        let parentSpaceStart = SIMD2<Float>(bone.localTransform.position.x, bone.localTransform.position.y)
        let delta = parentSpaceTip - parentSpaceStart
        let fallbackDelta = worldTip - worldStart
        let resolvedDelta = simd_length_squared(delta) > 0.0001 ? delta : fallbackDelta
        bone.length = max(simd_length(resolvedDelta), 12)
        bone.localTransform.rotation.z = atan2(resolvedDelta.y, resolvedDelta.x)
        if !isAnimationEditingEnabled && !isPoseMode {
            bone.baseTransform.rotation.z = bone.localTransform.rotation.z
        }
        skeleton.bones[id] = bone
        if isAnimationEditingEnabled && !isPoseMode {
            commitKeyframe(for: id, property: .rotate,
                           value: .rotate(bone.localTransform.rotation.z))
        } else {
            applyAnimations()
        }
    }

    func setBoneRotation(id: UUID, worldAngle: Float) {
        guard var bone = skeleton.bones[id] else { return }
        let parentAngle = bone.parentID.flatMap { skeleton.worldRotation(for: $0) } ?? 0
        bone.localTransform.rotation.z = worldAngle - parentAngle
        if !isAnimationEditingEnabled && !isPoseMode {
            bone.baseTransform.rotation.z = bone.localTransform.rotation.z
        }
        skeleton.bones[id] = bone
        if isAnimationEditingEnabled && !isPoseMode {
            commitKeyframe(for: id, property: .rotate,
                           value: .rotate(bone.localTransform.rotation.z))
        } else {
            applyAnimations()
        }
    }

    func setBoneLength(id: UUID, length: Float) {
        guard var bone = skeleton.bones[id] else { return }
        bone.length = max(length, 12)
        skeleton.bones[id] = bone
        applyAnimations()
    }

    func setBoneScale(id: UUID, scale: SIMD2<Float>) {
        guard var bone = skeleton.bones[id] else { return }
        bone.localTransform.scale.x = max(scale.x, 0.001)
        bone.localTransform.scale.y = max(scale.y, 0.001)
        if !isAnimationEditingEnabled && !isPoseMode {
            bone.baseTransform.scale.x = bone.localTransform.scale.x
            bone.baseTransform.scale.y = bone.localTransform.scale.y
        }
        skeleton.bones[id] = bone
        if isAnimationEditingEnabled && !isPoseMode {
            commitKeyframe(for: id, property: .scale,
                           value: .scale(SIMD2<Float>(bone.localTransform.scale.x, bone.localTransform.scale.y)))
        } else {
            applyAnimations()
        }
    }

    func setBoneSkew(id: UUID, skew: SIMD2<Float>) {
        guard var bone = skeleton.bones[id] else { return }
        bone.localTransform.skew = skew
        if !isAnimationEditingEnabled && !isPoseMode {
            bone.baseTransform.skew = skew
        }
        skeleton.bones[id] = bone
        if isAnimationEditingEnabled && !isPoseMode {
            commitKeyframe(for: id, property: .shear,
                           value: .shear(bone.localTransform.skew))
        } else {
            applyAnimations()
        }
    }

    func reparentBone(id: UUID, to parentID: UUID?) {
        pushUndoState()
        guard skeleton.canParent(id, to: parentID),
              let segment = skeleton.lineSegment(for: id),
              let existingBone = skeleton.bones[id] else {
            return
        }
        let recreated = Bone.make(
            name: existingBone.name,
            start: segment.start,
            end: segment.end,
            parentID: parentID,
            parentMatrix: parentID.flatMap { skeleton.worldMatrix(for: $0) }
        )
        let bone = Bone(
            id: id,
            name: recreated.name,
            parentID: recreated.parentID,
            baseTransform: recreated.baseTransform,
            localTransform: recreated.localTransform,
            length: recreated.length,
            animationClip: existingBone.animationClip
        )
        skeleton.bones[id] = bone
        if parentID == nil {
            if !skeleton.rootIDs.contains(id) {
                skeleton.rootIDs.append(id)
            }
        } else {
            skeleton.rootIDs.removeAll { $0 == id }
        }
        syncImagesToHierarchy()
        applyAnimations()
    }

    func bindImage(_ imageID: UUID, to boneID: UUID?) {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return }
        ensureImageAnimationSpaceConsistency(imageIndex: imageIndex)
        let sourceBoneID = images[imageIndex].boneBinding?.boneID
        guard sourceBoneID != boneID else { return }
        syncImageBasePoseToVisiblePose(imageIndex: imageIndex, relativeTo: sourceBoneID)

        guard let boneID else {
            convertImageAnimationSpace(imageIndex: imageIndex, from: sourceBoneID, to: nil)
            images[imageIndex].boneBinding = nil
            images[imageIndex].animationTransformSpace = .world
            syncImagesToHierarchy()
            applyAnimations()
            return
        }
        guard skeleton.bones[boneID] != nil else { return }
        convertImageAnimationSpace(imageIndex: imageIndex, from: sourceBoneID, to: boneID)
        // Exact bone-local pose of what is currently visible — binding never
        // changes what's on screen, even under scaled or sheared bones.
        let localPose = localSpritePose(for: images[imageIndex], relativeTo: boneID)
        images[imageIndex].boneBinding = BoneImageBinding(
            boneID: boneID,
            localPosition: localPose.position,
            localScale: localPose.scale,
            localRotation: localPose.rotation,
            localSkew: localPose.skew
        )
        images[imageIndex].basePosition = localPose.position
        images[imageIndex].baseScale = localPose.scale
        images[imageIndex].baseRotation = localPose.rotation
        images[imageIndex].baseSkew = localPose.skew
        images[imageIndex].animationTransformSpace = .boneLocal(boneID)
        syncImagesToHierarchy()
        applyAnimations()
    }

    private func removeBones(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            skeleton.bones.removeValue(forKey: id)
            skeleton.rootIDs.removeAll { $0 == id }
        }
        for boneID in skeleton.bones.keys {
            if ids.contains(skeleton.bones[boneID]?.parentID ?? UUID()) {
                skeleton.bones[boneID]?.parentID = nil
                if !skeleton.rootIDs.contains(boneID) {
                    skeleton.rootIDs.append(boneID)
                }
            }
        }
        // Through the one route: dropping the ids from the ORDER is what keeps
        // the set and the primary agreeing with it. Clearing `selectedBoneID`
        // on its own left the deleted bone in `selectedBoneIDs`.
        let deleted = Set(ids)
        applyBoneSelection(boneSelectionOrder.filter { !deleted.contains($0) })
        // Drop any constraint that references a removed bone so the solver
        // doesn't try to resolve dangling UUIDs next frame.
        let removedSet = Set(ids)
        skeleton.ikConstraints.removeAll { c in
            c.boneChain.contains(where: removedSet.contains) || removedSet.contains(c.targetBoneID)
        }
        skeleton.pathConstraints.removeAll { c in
            c.pathBones.contains(where: removedSet.contains) || c.bones.contains(where: removedSet.contains)
        }
        skeleton.physicsConstraints.removeAll { c in
            c.affectedBones.contains(where: removedSet.contains)
        }
        for index in images.indices where ids.contains(images[index].boneBinding?.boneID ?? UUID()) {
            images[index].boneBinding = nil
        }
        syncImagesToHierarchy()
    }

    func selectMeshVertices(_ indices: Set<Int>) {
        selectedMeshVertexIndices = indices
        if !indices.isEmpty {
            selectedMeshInternalEdgeIndex = nil
        }
    }

    func selectMeshInternalEdge(_ index: Int?) {
        selectedMeshInternalEdgeIndex = index
        if index != nil {
            selectedMeshVertexIndices = []
        }
    }

    func beginNewMesh() {
        isMeshCreatingHull = true
        selectedMeshVertexIndices = []
        guard let imageID = selectedImageID,
              let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return }
        pushUndoState()
        images[imageIndex].mesh.vertices = []
        images[imageIndex].mesh.uvs = []
        images[imageIndex].mesh.indices = []
        images[imageIndex].mesh.hullVertexIndices = []
    }

    /// Closes the outline being traced, and makes it a polygon.
    ///
    /// This is the only place the traced hull is triangulated. While tracing it
    /// is a polyline with no interior; closing it is what gives it one.
    func finishNewMesh() {
        isMeshCreatingHull = false
        guard let imageID = selectedImageID,
              let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return }
        guard images[imageIndex].mesh.hullVertexIndices.count >= 3 else {
            // Fewer than three nodes is not a shape. Say so rather than leaving
            // one or two orphaned points that draw as a stub and mesh as
            // nothing.
            meshEditNotice = .warning(
                "An outline needs at least three points. Trace one, or press "
                + "New Edge again to start over.")
            return
        }
        images[imageIndex].mesh.indices = images[imageIndex].mesh.triangulatedHullIndices()
    }

    func addMeshVertexToSelection(_ index: Int) {
        selectedMeshVertexIndices.insert(index)
    }

    func removeMeshVertexFromSelection(_ index: Int) {
        selectedMeshVertexIndices.remove(index)
    }

    func updateMeshVertex(imageID: UUID, vertexIndex: Int, localPosition: SIMD2<Float>) {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return }
        guard images[imageIndex].mesh.vertices.indices.contains(vertexIndex) else { return }
        let clamped = images[imageIndex].mesh.clampedPositionInsideHullIfNeeded(vertexIndex: vertexIndex, proposed: localPosition)
        if isAnimationEditingEnabled {
            if images[imageIndex].meshAnimationDeform == nil {
                images[imageIndex].meshAnimationDeform = images[imageIndex].mesh.vertices
            }
            images[imageIndex].meshAnimationDeform![vertexIndex] = clamped
        } else {
            images[imageIndex].mesh.vertices[vertexIndex] = clamped
        }
    }

    func commitMeshDeformKeyframe(imageID: UUID) {
        guard isAnimationEditingEnabled,
              let index = images.firstIndex(where: { $0.id == imageID }) else { return }
        let vertices = images[index].meshAnimationDeform ?? images[index].mesh.vertices
        guard !vertices.isEmpty else { return }
        images[index].animationClip.upsertKeyframe(
            targetID: imageID,
            property: .meshDeform,
            frame: currentFrame,
            value: .meshDeform(vertices),
            interpolation: .linear
        )
        if let keyframe = images[index].animationClip.keyframes(for: imageID, property: .meshDeform)
            .first(where: { $0.frame == currentFrame }) {
            let selection = SelectedKeyframe(imageID: imageID, property: .meshDeform, keyframeID: keyframe.id)
            selectedKeyframes = [selection]
            selectedKeyframe = selection
        }
        applyAnimations()
    }

    func updateMeshUV(imageID: UUID, vertexIndex: Int, uv: SIMD2<Float>, assetSize: SIMD2<Float>) {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return }
        guard images[imageIndex].mesh.uvs.indices.contains(vertexIndex) else { return }
        _ = assetSize
        let clamped = SIMD2<Float>(max(0, min(1, uv.x)), max(0, min(1, uv.y)))
        images[imageIndex].mesh.uvs[vertexIndex] = clamped
    }

    @discardableResult
    func insertMeshVertex(
        imageID: UUID,
        localPosition: SIMD2<Float>,
        afterHullEdge edgeIndex: Int,
        alphaSampler: ((Int, Int) -> Float)? = nil,
        assetSize: SIMD2<Float>? = nil
    ) -> Int? {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return nil }
        guard let result = images[imageIndex].mesh.insertingHullVertex(localPosition: localPosition, afterHullEdge: edgeIndex) else {
            return nil
        }
        beginInteraction()
        _ = alphaSampler
        _ = assetSize
        // Manual mesh editing must not prune triangles by alpha after inserting hull vertices.
        // That opaque-area filter is useful for auto-trace, but in edit workflow it can
        // remove coverage and create transparent wedges when leaving Mesh Edit mode.
        let previousMesh = images[imageIndex].mesh
        images[imageIndex].mesh = result.mesh
        extendDeformArrays(imageIndex: imageIndex, imageID: imageID,
                           previousMesh: previousMesh, insertedIndex: result.insertedIndex)
        selectedMeshVertexIndices = [result.insertedIndex]
        selectedMeshInternalEdgeIndex = nil
        return result.insertedIndex
    }

    @discardableResult
    func appendMeshHullVertex(imageID: UUID, localPosition: SIMD2<Float>, assetSize: SIMD2<Float>) -> Int? {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return nil }
        beginInteraction()
        let previousMesh = images[imageIndex].mesh
        let insertedIndex = images[imageIndex].mesh.vertices.count
        images[imageIndex].mesh.vertices.append(localPosition)
        images[imageIndex].mesh.uvs.append(Mesh.uv(for: localPosition, size: assetSize))
        images[imageIndex].mesh.hullVertexIndices.append(UInt16(insertedIndex))
        // An outline being traced is an OPEN polyline: it has no interior, so
        // there is nothing to triangulate. This used to triangulate from the
        // third node on, which filled the shape with the dashed triangle
        // overlay and drew a closing edge across the artwork — over the very
        // thing being traced. The polygon is made in `finishNewMesh`, at the
        // moment the artist clicks the first node again.
        if isMeshCreatingHull {
            images[imageIndex].mesh.indices = []
        } else if images[imageIndex].mesh.hullVertexIndices.count >= 3 {
            images[imageIndex].mesh.indices = images[imageIndex].mesh.triangulatedHullIndices()
        } else {
            images[imageIndex].mesh.indices = []
        }
        extendDeformArrays(imageIndex: imageIndex, imageID: imageID,
                           previousMesh: previousMesh, insertedIndex: insertedIndex)
        selectedMeshVertexIndices = [insertedIndex]
        selectedMeshInternalEdgeIndex = nil
        return insertedIndex
    }

    @discardableResult
    func insertMeshInteriorVertex(
        imageID: UUID,
        localPosition: SIMD2<Float>,
        assetSize: SIMD2<Float>,
        alphaSampler: ((Int, Int) -> Float)? = nil
    ) -> Int? {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return nil }
        guard let result = images[imageIndex].mesh.insertingInteriorVertex(
            localPosition: localPosition,
            size: assetSize,
            alphaSampler: alphaSampler
        ) else {
            // Say why. This refusal used to be silent, and it is not a
            // one-click failure: if the stored outline is the one at fault,
            // every insertion after it fails too and the mesh looks dead. That
            // is exactly how the multi-shape bridge bug was experienced.
            meshEditNotice = .warning(
                images[imageIndex].mesh.validationReport().isValid
                    ? "That point can't be added: it has to be inside the outline."
                    : "This mesh's outline is invalid, so no node can be added to it. "
                      + "Re-trace it from Mesh ▸ Auto Trace, or Reset to start over.")
            return nil
        }
        beginInteraction()
        // Do NOT run constrainedToOpaqueArea after manual interior-vertex insertion.
        // That filter removes triangles whose edges cross transparent pixels, which is
        // correct for auto-trace but breaks manual placement: the user can intentionally
        // place a node near a transparent region and the aggressive filter leaves the
        // new vertex disconnected (no triangles reference it).
        let previousMesh = images[imageIndex].mesh
        images[imageIndex].mesh = result.mesh
        extendDeformArrays(imageIndex: imageIndex, imageID: imageID,
                           previousMesh: previousMesh, insertedIndex: result.insertedIndex)
        selectedMeshVertexIndices = [result.insertedIndex]
        selectedMeshInternalEdgeIndex = nil
        return result.insertedIndex
    }

    func resetSelectedMesh(assetSize: SIMD2<Float>) {
        guard let imageID = selectedImageID,
              let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return }
        pushUndoState()
        images[imageIndex].mesh = images[imageIndex].mesh.resetToQuad(size: assetSize)
        selectedMeshVertexIndices = []
        isMeshCreatingHull = false
    }

    func generateSelectedMesh(assetSize: SIMD2<Float>) {
        guard let imageID = selectedImageID,
              let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return }
        pushUndoState()
        images[imageIndex].mesh = images[imageIndex].mesh.generated(
            size: assetSize,
            density: meshGenerateDensity
        )
        selectedMeshVertexIndices = []
        isMeshCreatingHull = false
    }

    func traceSelectedMesh(assetSize: SIMD2<Float>, alphaSampler: (Int, Int) -> Float) {
        guard let imageID = selectedImageID,
              let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return }
        pushUndoState()
        let traced = images[imageIndex].mesh.tracedHull(
            size: assetSize,
            alphaSampler: alphaSampler,
            detail: meshAutoDetail,
            padding: meshAutoPadding,
            concavity: meshAutoConcavity
        )
        images[imageIndex].mesh = traced
        selectedMeshVertexIndices = []
        isMeshCreatingHull = false

        // SAY WHAT HAPPENED. `tracedHull` falls back to a plain quad when it
        // finds nothing opaque enough to follow, so pressing Auto-Mesh on a
        // sprite whose alpha is below the threshold produced a rectangle and
        // no explanation. From the Mesh panel that is merely puzzling; from
        // the canvas shortcut, where the panel is not even open, it reads as a
        // button that does the wrong thing.
        if traced.isQuadCompatible {
            meshEditNotice = .warning(
                "Auto-Mesh found no outline to trace and fell back to the "
                + "sprite's rectangle. Check the artwork has opaque pixels, or "
                + "trace it by hand with New Edge.")
        } else {
            meshEditNotice = .info(
                "Auto-Mesh traced \(traced.hullVertexIndices.count) outline nodes.")
        }
    }

    func connectSelectedMeshVertices() {
        guard selectedMeshVertexIndices.count == 2,
              let imageID = selectedImageID,
              let imageIndex = images.firstIndex(where: { $0.id == imageID }) else {
            return
        }
        pushUndoState()
        let sorted = Array(selectedMeshVertexIndices).sorted()
        connectMeshVertices(imageIndex: imageIndex, first: sorted[0], second: sorted[1])
    }

    func connectMeshVertices(_ first: Int, _ second: Int) {
        guard let imageID = selectedImageID,
              let imageIndex = images.firstIndex(where: { $0.id == imageID }) else {
            return
        }
        pushUndoState()
        connectMeshVertices(imageIndex: imageIndex, first: first, second: second)
    }

    func clearSelectedMeshEdges() {
        guard let imageID = selectedImageID,
              let imageIndex = images.firstIndex(where: { $0.id == imageID }) else {
            return
        }
        pushUndoState()
        images[imageIndex].mesh = images[imageIndex].mesh.clearingInternalEdges()
        selectedMeshInternalEdgeIndex = nil
    }

    func createSelectedMeshFace() {
        guard selectedMeshVertexIndices.count == 3,
              let imageID = selectedImageID,
              let imageIndex = images.firstIndex(where: { $0.id == imageID }) else {
            return
        }
        pushUndoState()
        let sorted = Array(selectedMeshVertexIndices).sorted()
        images[imageIndex].mesh = images[imageIndex].mesh.creatingFace(sorted[0], sorted[1], sorted[2])
        selectedMeshInternalEdgeIndex = nil
    }

    func deleteSelectedMeshInternalEdge() {
        guard let imageID = selectedImageID,
              let imageIndex = images.firstIndex(where: { $0.id == imageID }),
              let selectedMeshInternalEdgeIndex,
              images[imageIndex].mesh.internalEdges.indices.contains(selectedMeshInternalEdgeIndex) else {
            return
        }
        pushUndoState()
        let removedEdge = images[imageIndex].mesh.internalEdges[selectedMeshInternalEdgeIndex]
        images[imageIndex].mesh.internalEdges.remove(at: selectedMeshInternalEdgeIndex)
        images[imageIndex].mesh.manualTriangles.removeAll { $0.contains(edge: removedEdge) }
        images[imageIndex].mesh.indices = images[imageIndex].mesh.triangulatedIndicesWithInternalEdges()
        self.selectedMeshInternalEdgeIndex = nil
    }

    private func connectMeshVertices(imageIndex: Int, first: Int, second: Int) {
        let previousCount = images[imageIndex].mesh.internalEdges.count
        images[imageIndex].mesh = images[imageIndex].mesh.connectingVertices(first, second)
        if images[imageIndex].mesh.internalEdges.count > previousCount {
            selectedMeshInternalEdgeIndex = images[imageIndex].mesh.internalEdges.indices.last
            selectedMeshVertexIndices = [first, second]
        }
    }

    func constrainMeshInteriorVertices(imageID: UUID, assetSize: SIMD2<Float>) {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return }
        images[imageIndex].mesh = images[imageIndex].mesh.clampingInteriorVerticesInsideHull(size: assetSize)
    }

    /// Auto-Weight: recompute the weight distribution over the bones this image
    /// is already bound to.
    ///
    /// It binds nothing. The old version handed the entire skeleton to
    /// `autoBindWeights`, which writes an inverse-bind matrix for every bone in
    /// the scene, so one press bound all sixteen bones of the rig to one sprite
    /// — including bones that belong to other images — and the Inspector duly
    /// reported "15 bound". Auto-Weight is a weight operation, not a bind
    /// operation: the artist decides which bones a sprite follows.
    func autoWeightMesh(imageID: UUID, maxInfluences: Int = 4) {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return }

        // A stale inverse-bind matrix can outlive the bone that made it, so the
        // bound set is intersected with the bones the skeleton still has.
        let bound = boundBoneIDs(imageID: imageID).filter { skeleton.bones[$0] != nil }
        guard !bound.isEmpty else {
            // Refused, and said out loud. Doing nothing in silence is exactly
            // what made the mesh tools feel broken before.
            meshEditNotice = .warning(
                "Auto-Weight only rebalances the bones this image is already bound to. "
                + "Bind at least one bone first, in Weights ▸ Binding ▸ Bind Bones.")
            return
        }

        pushUndoState()
        images[imageIndex].mesh = images[imageIndex].mesh.autoWeights(
            skeleton: skeleton,
            boneIDs: bound,
            maxInfluences: maxInfluences,
            imagePose: meshPose(for: images[imageIndex])
        )
        meshEditNotice = nil
        refreshBoneBindingColors()
    }

    func autoWeightSelectedMesh(maxInfluences: Int = 4) {
        guard let imageID = selectedImageID else { return }
        autoWeightMesh(imageID: imageID, maxInfluences: maxInfluences)
    }

    @discardableResult
    func skinImageToSkeleton(imageID: UUID, assetSize: SIMD2<Float>, maxInfluences: Int = 4) -> Bool {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }),
              !skeleton.bones.isEmpty else { return false }
        pushUndoState()
        if images[imageIndex].mesh.isQuadCompatible {
            images[imageIndex].mesh = images[imageIndex].mesh.generated(size: assetSize)
        }
        images[imageIndex].mesh = images[imageIndex].mesh.autoBindWeights(
            skeleton: skeleton,
            maxInfluences: maxInfluences,
            imagePose: meshPose(for: images[imageIndex])
        )
        meshShowDeformed = true
        return true
    }

    func unskinImage(imageID: UUID) {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return }
        pushUndoState()
        var mesh = images[imageIndex].mesh
        mesh.vertexBoneWeights = Array(repeating: [], count: mesh.vertices.count)
        mesh.boneInverseBindMatrices = [:]
        mesh.bindVertices = []
        mesh.bindImagePose = nil
        images[imageIndex].mesh = mesh
    }

    func boundBoneIDs(imageID: UUID) -> Set<UUID> {
        image(for: imageID)?.mesh.boundBoneIDs ?? []
    }

    func bindBoneToImage(imageID: UUID, boneID: UUID, assetSize: SIMD2<Float>, maxInfluences: Int = 4) {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }),
              let bone = skeleton.bones[boneID],
              let worldMatrix = skeleton.worldMatrix(for: boneID) else { return }
        pushUndoState()
        if images[imageIndex].mesh.isQuadCompatible {
            images[imageIndex].mesh = images[imageIndex].mesh.generated(size: assetSize)
        }
        images[imageIndex].mesh = images[imageIndex].mesh.addingBoneInfluence(
            bone: bone,
            worldMatrix: worldMatrix,
            maxInfluences: maxInfluences,
            imagePose: meshPose(for: images[imageIndex])
        )
        // No `meshShowDeformed = true` here any more. It made sense while this
        // repainted the mesh — there was something new to show. Now that it
        // only records the bind, nothing about the sprite has changed, and
        // turning the artist's own checkbox back on is one more thing Bind
        // Bones does that nobody asked it to. The automatic paths keep it:
        // they do change the deformation.
        //
        // Colours are not reset either, and never were here: assigning them is
        // `refreshBoneBindingColors`, which only fills in bones that have none
        // and only takes one back from a bone that is no longer bound.
        refreshBoneBindingColors()
    }

    // MARK: - Auto Bind

    /// A bone belongs to a sprite once a quarter of it lies inside the outline.
    static let autoBindMinBoneFraction: Float = 0.25
    /// ...or once it has used most of the crossing the sprite offered it.
    static let autoBindMinCrossFraction: Float = 0.60

    /// A bone is taken away from a sprite only if another holds twice as much
    /// of it...
    static let autoBindDominance: Float = 0.50
    /// ...and the sprite already has a bone that fits it twice as well.
    static let autoBindRivalFloor: Float = 0.50

    /// What Auto Bind decided about one sprite.
    struct AutoBindDecision {
        /// The bones bound, best fit first.
        var bound: [UUID] = []
        /// Bones that reached this sprite but were judged to belong to another,
        /// with the sprite that took them. Reported rather than dropped in
        /// silence: a bone deliberately left out looks exactly like a bone the
        /// detection missed.
        var yielded: [(bone: UUID, to: UUID)] = []
    }

    /// Measure every bone against every sprite outline, once.
    ///
    /// Auto Bind cannot be decided a sprite at a time. Whether a bone belongs
    /// here depends on how much of it lies elsewhere, so the whole table is
    /// built first and every sprite reads the same numbers from it.
    private func autoBindFitTable() -> [UUID: [UUID: Mesh.BoneFit]] {
        let worldMatrices = skeleton.worldMatrices()
        var segments: [(id: UUID, start: SIMD2<Float>, end: SIMD2<Float>)] = []
        // `orderedBones`, not the matrix dictionary: Swift dictionary iteration
        // is not stable across runs, so two bones fitting equally well would
        // otherwise come back in a different order from one launch to the next.
        for bone in skeleton.orderedBones {
            guard let world = worldMatrices[bone.id] else { continue }
            let start3 = MatrixUtilities.transformPoint(.zero, with: world)
            let end3 = MatrixUtilities.transformPoint(SIMD3<Float>(bone.length, 0, 0), with: world)
            segments.append((bone.id, SIMD2(start3.x, start3.y), SIMD2(end3.x, end3.y)))
        }

        var table: [UUID: [UUID: Mesh.BoneFit]] = [:]
        for image in images where image.mesh.hullVertexIndices.count >= 3 {
            let pose = meshPose(for: image)
            var row: [UUID: Mesh.BoneFit] = [:]
            for segment in segments {
                let fit = image.mesh.fit(
                    boneStart: segment.start,
                    boneEnd: segment.end,
                    pose: pose
                )
                if fit.overlap > 0 || fit.originInside {
                    row[segment.id] = fit
                }
            }
            table[image.id] = row
        }
        return table
    }

    /// Does this bone reach that sprite at all?
    ///
    /// Three ways, any one of which is enough, because each catches a shape the
    /// others miss — see `Mesh.BoneFit`. This is only the bar for being a
    /// CANDIDATE; which candidates survive is decided against the rest of the
    /// scene in `autoBindDecision`.
    private func autoBindTouches(_ fit: Mesh.BoneFit) -> Bool {
        if fit.originInside { return true }
        guard fit.overlap > 0 else { return false }
        return fit.boneFraction >= SceneManager.autoBindMinBoneFraction
            || fit.crossFraction >= SceneManager.autoBindMinCrossFraction
    }

    /// Which bones belong to this sprite, decided with the whole scene in view.
    ///
    /// Where two sprites cover the same ground, a bone belonging to one dips
    /// into the other and used to be bound to both. Deciding that on the bone
    /// alone — whichever sprite holds most of it wins — is the obvious rule and
    /// wrong on its own: the spine holds 190 units inside a torso and 20 inside
    /// a belt, so the belt loses the only bone that touches it. An earlier
    /// version of this function did exactly that, which is why the rule now
    /// takes a bone away only when BOTH sides agree:
    ///
    ///   the bone side    another sprite holds at least twice as much of it
    ///   the sprite side  this sprite has a bone that fits it twice as well
    ///
    /// The belt survives because it has nothing better, and since the best
    /// candidate is compared against itself, a sprite can never be emptied by
    /// the competition. A spine dipping into an arm sprite does not survive,
    /// because the arm already has an upper and a lower arm bone.
    ///
    /// A joint planted inside a sprite is exempt from both. The sprite turns
    /// about that joint whatever else is going on — which is what keeps a
    /// shoulder bone rooted in the torso driving the torso as well as the arm.
    func autoBindDecision(imageID: UUID) -> AutoBindDecision {
        let table = autoBindFitTable()
        return autoBindDecision(imageID: imageID, table: table)
    }

    private func autoBindDecision(
        imageID: UUID,
        table: [UUID: [UUID: Mesh.BoneFit]]
    ) -> AutoBindDecision {
        guard let here = table[imageID] else { return AutoBindDecision() }

        let candidates = skeleton.orderedBones.compactMap { bone -> (id: UUID, fit: Mesh.BoneFit)? in
            guard let fit = here[bone.id], autoBindTouches(fit) else { return nil }
            return (bone.id, fit)
        }
        guard !candidates.isEmpty else { return AutoBindDecision() }

        // Includes the bone under test, so the best-fitting candidate can never
        // be out-classed and the sprite always keeps at least one bone.
        let bestHere = candidates.map { $0.fit.boneFraction }.max() ?? 0

        var decision = AutoBindDecision()
        var scored: [(id: UUID, fraction: Float)] = []
        for candidate in candidates {
            if candidate.fit.originInside {
                scored.append((candidate.id, candidate.fit.boneFraction))
                continue
            }

            var rivalID: UUID?
            var rivalOverlap: Float = 0
            for (otherImageID, row) in table where otherImageID != imageID {
                guard let otherFit = row[candidate.id], otherFit.overlap > rivalOverlap else { continue }
                rivalOverlap = otherFit.overlap
                rivalID = otherImageID
            }

            let dominated = candidate.fit.overlap < SceneManager.autoBindDominance * rivalOverlap
            let outclassed = candidate.fit.boneFraction < SceneManager.autoBindRivalFloor * bestHere
            if dominated, outclassed, let rivalID {
                decision.yielded.append((candidate.id, rivalID))
                continue
            }
            scored.append((candidate.id, candidate.fit.boneFraction))
        }

        scored.sort { $0.fraction > $1.fraction }
        decision.bound = scored.map { $0.id }
        return decision
    }

    /// The bones that lie over this sprite, best fit first.
    func bonesOverlapping(imageID: UUID) -> [UUID] {
        autoBindDecision(imageID: imageID).bound
    }

    /// Auto Bind: bind this sprite to the bones that lie over it, and weight it.
    ///
    /// Replaces the sprite's bindings rather than adding to them — it is the
    /// automatic answer to "which bones drive this sprite", and a stale manual
    /// binding left behind would survive as exactly the kind of foreign bone
    /// this is meant to remove. One undo step puts the old set back.
    ///
    /// The bind and the weighting are one transaction: every inverse-bind
    /// matrix is captured first, then `autoWeights` runs once over the finished
    /// set. Binding the bones one at a time would rebalance the weights after
    /// each, and every intermediate result would be a distribution over a set
    /// the artist never asked for.
    ///
    /// - Returns: the number of bones bound. Zero means nothing lies over the
    ///   sprite, and nothing was changed.
    @discardableResult
    func autoBindImage(imageID: UUID, assetSize: SIMD2<Float>, maxInfluences: Int = 4) -> Int {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return 0 }

        let decision = autoBindDecision(imageID: imageID)
        let bones = decision.bound
        guard !bones.isEmpty else {
            meshEditNotice = .warning(
                "Auto Bind found no bone over this image. Move a bone onto it, "
                + "or bind one by hand in Binding ▸ Bind Bones.")
            return 0
        }

        pushUndoState()

        var mesh = images[imageIndex].mesh
        if mesh.isQuadCompatible {
            mesh = mesh.generated(size: assetSize)
        }

        let pose = meshPose(for: images[imageIndex])
        let worldMatrices = skeleton.worldMatrices()

        // Rebind from scratch, at the current pose.
        mesh.bindVertices = mesh.vertices
        mesh.bindImagePose = pose
        mesh.boneInverseBindMatrices = [:]
        for boneID in bones {
            guard let world = worldMatrices[boneID] else { continue }
            mesh.boneInverseBindMatrices[boneID] = SavedMatrix4x4(simd_inverse(world))
        }

        // AUTO BIND BINDS. IT DOES NOT PAINT.
        //
        // It used to run `autoWeights` over the whole sprite as well, so one
        // press both chose the bones and painted every vertex — which left Auto
        // Weight with nothing to do that had not already been done, and made it
        // impossible to bind a set of bones and paint them by hand: the
        // automatic weights were always laid down first and had to be cleared.
        //
        // Painting the artist has already done is kept, minus any bone that is
        // no longer bound. Dropping those is not optional: a weight naming a
        // bone with no inverse-bind matrix is a reference to a bind pose that
        // was never captured, and skinning reads it as the identity.
        if mesh.vertexBoneWeights.count != mesh.vertices.count {
            mesh.vertexBoneWeights = Array(repeating: [], count: mesh.vertices.count)
        } else {
            let stillBound = Set(mesh.boneInverseBindMatrices.keys)
            for index in mesh.vertexBoneWeights.indices {
                mesh.vertexBoneWeights[index].removeAll { !stillBound.contains($0.boneID) }
            }
        }

        images[imageIndex].mesh = mesh
        meshShowDeformed = true
        meshEditNotice = .info(autoBindSummary(decision))
        refreshBoneBindingColors()
        return mesh.boneInverseBindMatrices.count
    }

    /// What Auto Bind did, in one sentence.
    ///
    /// The yielded bones are the part worth saying out loud. A bone the rule
    /// deliberately gave to an overlapping sprite is indistinguishable, from the
    /// canvas, from a bone the detection failed to find — and the artist can act
    /// on the first (bind it by hand if they disagree) only if they know which
    /// it was.
    private func autoBindSummary(_ decision: AutoBindDecision) -> String {
        let bound = decision.bound.count
        var text = bound == 1 ? "Auto Bind: 1 bone bound" : "Auto Bind: \(bound) bones bound"
        // Say what is still missing. Auto Bind no longer paints, so a sprite
        // that has just been bound does not deform yet, and silence there reads
        // as the button having done nothing.
        guard !decision.yielded.isEmpty else {
            return text + ". Paint them with Auto-Weight, or by hand."
        }

        let names = decision.yielded.compactMap { skeleton.bones[$0.bone]?.name }
        let owners = Set(decision.yielded.compactMap { yielded in
            hierarchyItems.first(where: { $0.id == yielded.to })?.name
                ?? image(for: yielded.to)?.name
        })
        let boneList = names.isEmpty
            ? "\(decision.yielded.count) bone\(decision.yielded.count == 1 ? "" : "s")"
            : names.joined(separator: ", ")
        let ownerList = owners.sorted().joined(separator: ", ")
        text += ", and left \(boneList) to "
        text += ownerList.isEmpty ? "an overlapping image" : ownerList
        return text + " — more of the bone lies there, and this image already has a closer one."
    }

    func autoBindSelectedImage(assetSize: SIMD2<Float>, maxInfluences: Int = 4) {
        guard let imageID = selectedImageID else { return }
        autoBindImage(imageID: imageID, assetSize: assetSize, maxInfluences: maxInfluences)
    }

    /// Gives every bound bone a colour and takes it back from every bone that
    /// is not.
    ///
    /// One place, called by every method that changes a weight: a bone's colour
    /// is a statement about the meshes, so it is derived from them rather than
    /// maintained alongside them. Idempotent, so calling it twice is free and a
    /// method that is not sure whether it changed anything can just call it.
    func refreshBoneBindingColors() {
        // `Mesh.boundBoneIDs`, the same rule the bound-bones list draws — not a
        // second reading of the weights. Asking only which bones paint had
        // reached left every bone Auto Bind had bound, but that no vertex was
        // nearest to, sitting in the list with no colour and nothing to paint
        // with.
        var boundIDs: Set<UUID> = []
        for image in images {
            boundIDs.formUnion(image.mesh.boundBoneIDs)
        }

        // Document order, not dictionary order: which bone gets which colour
        // must not change between launches.
        let ordered = IKBuilderRules.hierarchicalOrder(skeleton: skeleton).map { $0.bone.id }

        for boneID in ordered {
            guard var bone = skeleton.bones[boneID] else { continue }
            if boundIDs.contains(boneID) {
                guard bone.color == nil else { continue }
                let inUse = ordered.compactMap { skeleton.bones[$0]?.color }
                bone.color = Bone.bindingColor(for: boneID, avoiding: inUse)
                skeleton.bones[boneID] = bone
            } else if bone.color != nil {
                bone.color = nil
                skeleton.bones[boneID] = bone
            }
        }
    }

    func unbindBoneFromImage(imageID: UUID, boneID: UUID, maxInfluences: Int = 4) {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return }
        pushUndoState()
        images[imageIndex].mesh = images[imageIndex].mesh.removingBoneInfluence(
            boneID: boneID,
            maxInfluences: maxInfluences
        )
        refreshBoneBindingColors()
    }

    func skinningInfluenceCount(imageID: UUID) -> (boneCount: Int, vertexCount: Int) {
        guard let image = image(for: imageID) else { return (0, 0) }
        let mesh = image.mesh
        guard !mesh.vertexBoneWeights.isEmpty else { return (0, 0) }
        var boneSet = Set<UUID>()
        var boundVertexCount = 0
        for influences in mesh.vertexBoneWeights {
            if !influences.isEmpty { boundVertexCount += 1 }
            for influence in influences { boneSet.insert(influence.boneID) }
        }
        return (boneSet.count, boundVertexCount)
    }

    func setVertexWeights(imageID: UUID, vertexIndex: Int, influences: [VertexBoneWeight], maxInfluences: Int = 4) {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return }
        pushUndoState()
        var mesh = images[imageIndex].mesh.sanitizedSkinningData(maxInfluences: maxInfluences)
        guard mesh.vertices.indices.contains(vertexIndex) else { return }

        let filtered = influences
            .filter { $0.weight.isFinite && $0.weight > 0 }
            .sorted { $0.weight > $1.weight }
        mesh.vertexBoneWeights[vertexIndex] = Array(filtered.prefix(maxInfluences))
        mesh = mesh.sanitizedSkinningData(maxInfluences: maxInfluences)
        images[imageIndex].mesh = mesh
        refreshBoneBindingColors()
    }

    /// Clears every vertex weight on a sprite's mesh.
    ///
    /// The Reset the weights panel offers: the mesh keeps its shape and its
    /// bind pose, and gives up its painting. The bones stay BOUND — their
    /// inverse-bind matrices are untouched — so they stay in the bound-bones
    /// list and keep their colours, which is what makes repainting from scratch
    /// possible. Only the bin unbinds, and only that takes a colour back.
    func clearMeshWeights(imageID: UUID) {
        guard let index = images.firstIndex(where: { $0.id == imageID }) else { return }
        pushUndoState()
        var mesh = images[index].mesh
        mesh.vertexBoneWeights = Array(repeating: [], count: mesh.vertices.count)
        images[index].mesh = mesh
        activeWeightPaintBoneID = nil
        refreshBoneBindingColors()
    }

    func normalizeMeshWeights(imageID: UUID, maxInfluences: Int = 4) {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return }
        pushUndoState()
        images[imageIndex].mesh = images[imageIndex].mesh.sanitizedSkinningData(maxInfluences: maxInfluences)
    }

    func selectedVertexInfluences(imageID: UUID) -> [VertexBoneWeight] {
        guard let vertexIndex = selectedMeshVertexIndices.sorted().first,
              let image = image(for: imageID) else { return [] }
        let mesh = image.mesh.sanitizedSkinningData(maxInfluences: max(1, meshWeightMaxInfluencesPerVertex))
        guard mesh.vertexBoneWeights.indices.contains(vertexIndex) else { return [] }
        return mesh.vertexBoneWeights[vertexIndex]
    }

    func setSelectedVertexInfluence(imageID: UUID, boneID: UUID, value: Float) {
        guard let vertexIndex = selectedMeshVertexIndices.sorted().first,
              let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return }
        var mesh = images[imageIndex].mesh.sanitizedSkinningData(maxInfluences: max(1, meshWeightMaxInfluencesPerVertex))
        guard mesh.vertexBoneWeights.indices.contains(vertexIndex) else { return }

        var map = Dictionary(uniqueKeysWithValues: mesh.vertexBoneWeights[vertexIndex].map { ($0.boneID, $0.weight) })
        if value <= 0.0001 {
            map.removeValue(forKey: boneID)
        } else {
            map[boneID] = max(0, min(1, value))
            if mesh.boneInverseBindMatrices[boneID] == nil,
               let world = skeleton.worldMatrix(for: boneID) {
                mesh.boneInverseBindMatrices[boneID] = SavedMatrix4x4(simd_inverse(world))
            }
        }

        let influences = map.map { VertexBoneWeight(boneID: $0.key, weight: $0.value) }
        mesh.vertexBoneWeights[vertexIndex] = influences
        mesh = mesh.sanitizedSkinningData(maxInfluences: max(1, meshWeightMaxInfluencesPerVertex))
        images[imageIndex].mesh = mesh
        refreshBoneBindingColors()
    }

    /// Current world pose of an image in the shared sprite affine convention.
    func meshPose(for image: SceneImage) -> MeshBindPose {
        MeshBindPose(
            position: image.position,
            rotation: image.rotation,
            scale: image.scale,
            skew: image.skew
        )
    }

    func skinnedLocalVertices(
        for image: SceneImage,
        assetSize: SIMD2<Float>,
        showDeformed: Bool,
        worldMatrices: [UUID: simd_float4x4]? = nil
    ) -> [SIMD2<Float>] {
        // Resolve (and therefore sanitize) the mesh ONCE and reuse it for both
        // the local vertices and the skinning. This used to sanitize three
        // times per call — once inside editLocalVertices, once here, and once
        // more inside skinnedVertices — each rebuilding the hull, triangles and
        // skinning tables and copying every array.
        let mesh = renderMeshCache.resolvedMesh(for: image, assetSize: assetSize)
        return skinnedLocalVertices(for: image, assetSize: assetSize,
                                    showDeformed: showDeformed,
                                    worldMatrices: worldMatrices, mesh: mesh)
    }

    /// Same, for a caller that has already resolved the mesh it wants drawn.
    ///
    /// The overlay needs this: it draws `ToolUtilities.overlayMesh`, and taking
    /// positions from a differently-resolved mesh is what put the vertex markers
    /// somewhere other than the geometry they belong to.
    func skinnedLocalVertices(
        for image: SceneImage,
        assetSize: SIMD2<Float>,
        showDeformed: Bool,
        worldMatrices: [UUID: simd_float4x4]? = nil,
        mesh: Mesh
    ) -> [SIMD2<Float>] {
        let localVertices = ToolUtilities.editLocalVertices(
            for: image, assetSize: assetSize, showDeformed: showDeformed, mesh: mesh)
        guard showDeformed else { return localVertices }
        let hasMatchingVertexCount = mesh.vertices.count == localVertices.count
        guard hasMatchingVertexCount, mesh.hasSkinningData() else { return localVertices }

        let skinned = mesh.skinnedVertices(
            skeleton: skeleton,
            currentPose: meshPose(for: image),
            worldMatrices: worldMatrices,
            presanitized: true
        )
        return skinned.count == localVertices.count ? skinned : localVertices
    }

    /// Puts a mesh's weights back exactly as they were, with no undo entry of
    /// its own.
    ///
    /// For taking back the brush stamp that the first click of a double click
    /// laid down before the second click revealed it was a bone pick. It is a
    /// return to a state that existed a moment ago, not an edit, so it must not
    /// appear in the undo stack as one.
    ///
    /// Refuses on a vertex-count mismatch: if the topology changed in between,
    /// these weights belong to a different mesh.
    func restoreMeshWeights(imageID: UUID, weights: [[VertexBoneWeight]]) {
        guard let index = images.firstIndex(where: { $0.id == imageID }),
              images[index].mesh.vertices.count == weights.count else { return }
        images[index].mesh.vertexBoneWeights = weights
        refreshBoneBindingColors()
    }

    func paintSelectedMeshWeights(worldPoint: SIMD2<Float>, assetSize: SIMD2<Float>) {
        guard let imageID = selectedImageID,
              let boneID = activeWeightPaintBoneID else { return }
        paintMeshWeights(imageID: imageID, boneID: boneID,
                         assetSize: assetSize, worldPoint: worldPoint)
    }

    /// Paints the whole segment between two pointer samples.
    ///
    /// The brush used to be stamped once per drag event, at that event's
    /// position. Drag events arrive at pointer rate, so a quick stroke left
    /// gaps: vertices under the path were never touched, and how much you
    /// painted depended on how fast you moved. Stepping along the segment by a
    /// quarter of the brush radius makes coverage a property of the path.
    func paintSelectedMeshWeights(from start: SIMD2<Float>, to end: SIMD2<Float>,
                                  assetSize: SIMD2<Float>) {
        guard let imageID = selectedImageID,
              let boneID = activeWeightPaintBoneID else { return }

        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }),
              var brush = prepareWeightBrush(imageIndex: imageIndex, boneID: boneID,
                                             assetSize: assetSize,
                                             mode: nil, radius: nil,
                                             strength: nil, falloff: nil)
        else { return }

        let span = simd_length(end - start)
        let step = max(meshWeightBrushRadius * 0.25, 0.0001)
        // +1 so a stationary press still stamps once.
        let stamps = min(Int(ceil(Double(span / step))) + 1, Self.maxPaintStampsPerDrag)

        // Prepared once, stamped many times, written back once. Calling the
        // single-point path per stamp re-sanitised the whole mesh twice and
        // rebuilt the adjacency every time — none of which depends on where the
        // stamp lands.
        for index in 0..<stamps {
            let t = stamps == 1 ? 1 : Float(index) / Float(stamps - 1)
            brush.apply(atWorld: start + (end - start) * t)
        }
        commitWeightBrush(brush, imageIndex: imageIndex)
    }

    /// A ceiling on the stamps one drag event can produce. A pointer that jumps
    /// the width of the canvas — a tablet pen re-entering, a dropped frame —
    /// must not turn into thousands of brush applications on one event.
    static let maxPaintStampsPerDrag = 64

    /// A brush prepared for one stroke: the mesh, the parameters, and the
    /// adjacency if the mode reads it.
    ///
    /// This used to be the preamble of `paintMeshWeights`, re-run for every
    /// stamp. None of it depends on where the stamp lands, and
    /// `sanitizedSkinningData` copies every array in the mesh while the
    /// adjacency allocates a `Set` per vertex — so a continuous stroke was
    /// paying O(mesh) twice per stamp for a brush loop that is O(mesh) once.
    struct MeshWeightBrush {
        var mesh: Mesh
        var weights: [[VertexBoneWeight]]
        /// Where each vertex is DRAWN, in world space.
        ///
        /// The stamp used to measure `mesh.vertices` — the rest positions —
        /// against a point converted into the sprite's local space, with the
        /// ring's radius reused as a local number. Two frames, two errors: at
        /// scale 2 the disc painted was twice the ring shown, and once a bone
        /// posed the sprite the nodes on screen were not where the brush was
        /// looking, so clicking a node painted whichever rest vertex happened
        /// to sit under the cursor. Not nothing — the wrong ones, silently.
        ///
        /// World space is the frame the ring is drawn in and the frame the
        /// pointer arrives in, so measuring there makes the three agree by
        /// construction.
        var worldPositions: [SIMD2<Float>]
        /// When set, the stroke may only touch these vertices. A selected node
        /// is painted alone until the selection changes.
        var restrictedTo: Set<Int>?
        /// Built only for `.smooth` and `.blur`; the other modes never read a
        /// neighbour. Flat arrays rather than sets: built once, read many times.
        var neighbors: [[Int]]
        let boneID: UUID
        let mode: MeshWeightPaintMode
        let radius: Float
        let strength: Float
        let falloff: Float
        let influence: Float
        let maxInfluences: Int

        private func normalized(_ influences: [VertexBoneWeight]) -> [VertexBoneWeight] {
            var merged: [UUID: Float] = [:]
            for influence in influences where influence.weight.isFinite && influence.weight > 0 {
                merged[influence.boneID, default: 0] += influence.weight
            }
            var result = merged.map { VertexBoneWeight(boneID: $0.key, weight: max(0, $0.value)) }
            result.sort { $0.weight > $1.weight }
            if result.count > maxInfluences {
                result = Array(result.prefix(maxInfluences))
            }
            let total = result.reduce(0) { $0 + $1.weight }
            guard total > 0.000001 else { return [] }
            return result.map { VertexBoneWeight(boneID: $0.boneID, weight: $0.weight / total) }
        }

        /// One stamp, in world space — the frame the ring is drawn in.
        mutating func apply(atWorld center: SIMD2<Float>) {
            for index in mesh.vertices.indices {
                if let restrictedTo, !restrictedTo.contains(index) { continue }
                guard worldPositions.indices.contains(index) else { continue }
                let distance = simd_distance(worldPositions[index], center)
                guard distance <= radius else { continue }
                let t = max(0, 1 - (distance / radius))
                let factor = pow(t, falloff) * strength
                guard factor > 0.0001 else { continue }

                var influenceMap = Dictionary(uniqueKeysWithValues: weights[index].map { ($0.boneID, $0.weight) })
                let current = influenceMap[boneID, default: 0]
                let target = max(0, min(1, influence))

                switch mode {
                case .add:
                    let newWeight = min(1, current + (target - current) * factor)
                    if newWeight > current + 0.0001 {
                        influenceMap[boneID] = newWeight
                        // Reduce other bones proportionally so the active bone
                        // can reach 100%.
                        let priorOtherTotal = max(0, 1.0 - current)
                        if priorOtherTotal > 0.0001 {
                            let remainingBudget = max(0, 1.0 - newWeight)
                            let scale = remainingBudget / priorOtherTotal
                            for key in influenceMap.keys where key != boneID {
                                influenceMap[key] = max(0, (influenceMap[key] ?? 0) * scale)
                            }
                        }
                    }
                case .subtract:
                    influenceMap[boneID] = max(0, current - factor)
                case .replace:
                    for key in influenceMap.keys {
                        influenceMap[key] = (key == boneID)
                            ? (current * (1 - factor) + target * factor)
                            : (influenceMap[key, default: 0] * (1 - factor))
                    }
                    if influenceMap[boneID] == nil {
                        influenceMap[boneID] = target * factor
                    }
                case .smooth, .blur:
                    guard neighbors.indices.contains(index) else { break }
                    let neighborWeights = neighbors[index].compactMap { neighbor -> Float? in
                        weights[neighbor].first(where: { $0.boneID == boneID })?.weight
                    }
                    if !neighborWeights.isEmpty {
                        let average = neighborWeights.reduce(0, +) / Float(neighborWeights.count)
                        influenceMap[boneID] = max(0, current + (average - current) * factor)
                    }
                }

                weights[index] = normalized(influenceMap.map { VertexBoneWeight(boneID: $0.key, weight: $0.value) })
            }
        }
    }

    /// Everything a stroke needs, worked out once.
    private func prepareWeightBrush(
        imageIndex: Int,
        boneID: UUID,
        assetSize: SIMD2<Float>,
        mode: MeshWeightPaintMode?,
        radius: Float?,
        strength: Float?,
        falloff: Float?
    ) -> MeshWeightBrush? {
        guard skeleton.bones[boneID] != nil else { return nil }

        let paintMode = mode ?? meshWeightPaintMode
        let maxInfluences = max(1, meshWeightMaxInfluencesPerVertex)
        let image = images[imageIndex]

        var mesh = image.mesh.sanitizedSkinningData(maxInfluences: maxInfluences)
        if mesh.bindVertices.count != mesh.vertices.count {
            mesh.bindVertices = mesh.vertices
        }
        if mesh.vertexBoneWeights.count != mesh.vertices.count {
            mesh.vertexBoneWeights = Array(repeating: [], count: mesh.vertices.count)
        }
        if mesh.boneInverseBindMatrices[boneID] == nil,
           let world = skeleton.worldMatrix(for: boneID) {
            mesh.boneInverseBindMatrices[boneID] = SavedMatrix4x4(simd_inverse(world))
        }
        if mesh.bindImagePose == nil {
            mesh.bindImagePose = meshPose(for: image)
        }

        // Only smooth and blur read a neighbour. Building this for add,
        // subtract or replace allocated a Set per vertex to answer a question
        // nobody asked.
        var neighbors: [[Int]] = []
        if paintMode == .smooth || paintMode == .blur {
            var sets = Array(repeating: Set<Int>(), count: mesh.vertices.count)
            for i in stride(from: 0, to: mesh.indices.count, by: 3) {
                guard i + 2 < mesh.indices.count else { break }
                let a = Int(mesh.indices[i])
                let b = Int(mesh.indices[i + 1])
                let c = Int(mesh.indices[i + 2])
                guard sets.indices.contains(a), sets.indices.contains(b), sets.indices.contains(c) else { continue }
                sets[a].formUnion([b, c])
                sets[b].formUnion([a, c])
                sets[c].formUnion([a, b])
            }
            neighbors = sets.map { Array($0) }
        }

        // Where the artist SEES each vertex, worked out once for the stroke.
        //
        // The same call the overlay makes, lifted into world space: measuring
        // against anything else is measuring against a mesh that is not on
        // screen. `showDeformed` is the overlay's own flag, so the brush and
        // the markers agree about which mesh is being shown.
        let localVertices = skinnedLocalVertices(
            for: image,
            assetSize: assetSize,
            showDeformed: isMeshOverlayDeformed,
            mesh: mesh
        )
        let worldPositions = ToolUtilities.transformedVertices(
            for: image, localVertices: localVertices)

        return MeshWeightBrush(
            mesh: mesh,
            weights: mesh.vertexBoneWeights,
            worldPositions: worldPositions,
            restrictedTo: selectedMeshVertexIndices.isEmpty
                ? nil : selectedMeshVertexIndices,
            neighbors: neighbors,
            boneID: boneID,
            mode: paintMode,
            radius: max(radius ?? meshWeightBrushRadius, 0.0001),
            strength: max(0, min(strength ?? meshWeightBrushStrength, 1)),
            falloff: max(0.1, falloff ?? meshWeightBrushFalloff),
            influence: meshWeightBrushInfluence,
            maxInfluences: maxInfluences
        )
    }

    /// Writes a finished stroke back.
    private func commitWeightBrush(_ brush: MeshWeightBrush, imageIndex: Int) {
        var mesh = brush.mesh
        mesh.vertexBoneWeights = brush.weights
        images[imageIndex].mesh = mesh.sanitizedSkinningData(maxInfluences: brush.maxInfluences)
    }

    func paintMeshWeights(
        imageID: UUID,
        boneID: UUID,
        assetSize: SIMD2<Float>,
        worldPoint: SIMD2<Float>,
        mode: MeshWeightPaintMode? = nil,
        radius: Float? = nil,
        strength: Float? = nil,
        falloff: Float? = nil
    ) {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }),
              var brush = prepareWeightBrush(imageIndex: imageIndex, boneID: boneID,
                                             assetSize: assetSize,
                                             mode: mode, radius: radius,
                                             strength: strength, falloff: falloff)
        else { return }

        brush.apply(atWorld: worldPoint)
        commitWeightBrush(brush, imageIndex: imageIndex)
    }

    /// Something the artist needs to be told about the last mesh edit.
    ///
    /// Started life as a refusal message. Auto Bind needs the other tone too:
    /// it can succeed and still have deliberately left a bone out, and a bone
    /// left out on purpose looks exactly like a bone the detection missed
    /// unless somebody says which it was.
    struct MeshEditNotice: Equatable {
        var text: String
        /// A refused edit, versus the outcome of one that went through.
        var isWarning: Bool

        static func warning(_ text: String) -> MeshEditNotice {
            MeshEditNotice(text: text, isWarning: true)
        }

        static func info(_ text: String) -> MeshEditNotice {
            MeshEditNotice(text: text, isWarning: false)
        }
    }

    /// The notice to surface, or `nil` when there is nothing to say.
    @Published var meshEditNotice: MeshEditNotice?

    func deleteSelectedMeshVertices() {
        guard let imageID = selectedImageID,
              let imageIndex = images.firstIndex(where: { $0.id == imageID }),
              !selectedMeshVertexIndices.isEmpty else { return }

        guard let change = images[imageIndex].mesh.removingVertices(selectedMeshVertexIndices) else {
            // Deleting a boundary point joins its two neighbours with a straight
            // segment, and on a concave silhouette that segment can cross
            // another part of the outline. The mesh is left exactly as it was —
            // but say so, because silently doing nothing is what made this
            // feel broken.
            meshEditNotice = .warning(
                "Those points can't be removed: the outline would cross itself.")
            return
        }

        // beginInteraction, not pushUndoState. MeshTool.onMouseDown already
        // calls beginInteraction, and pushing again here stored a SECOND
        // snapshot of the same pre-delete state — so the first Cmd-Z restored
        // a state identical to the current one and appeared to do nothing.
        // beginInteraction is idempotent within a gesture and still pushes once
        // when the delete comes from the keyboard instead.
        beginInteraction()
        applyTopologyChange(change, imageIndex: imageIndex, imageID: imageID)
        selectedMeshVertexIndices = []
        selectedMeshInternalEdgeIndex = nil
        meshEditNotice = nil
    }

    /// Apply a mesh topology change and carry every per-vertex array with it.
    ///
    /// The mesh itself owns vertices, UVs, weights and bind pose, so those
    /// travel automatically. `meshAnimationDeform` and the `.meshDeform`
    /// keyframes do not: they live on `SceneImage` as plain per-vertex arrays
    /// addressed by index. Leaving them alone after a topology change left every
    /// deform key the wrong length and pointing at the wrong vertices, and the
    /// exporter drops any key whose count does not match the mesh
    /// (`UMJSONExportBuilder`) — so deleting a single vertex quietly destroyed
    /// that sprite's whole deform animation, and nothing showed it until the
    /// work was already gone.
    private func applyTopologyChange(
        _ change: Mesh.TopologyChange, imageIndex: Int, imageID: UUID
    ) {
        let newCount = change.mesh.vertices.count
        images[imageIndex].mesh = change.mesh

        if let deform = images[imageIndex].meshAnimationDeform {
            images[imageIndex].meshAnimationDeform =
                change.remapped(deform, fallback: change.mesh.vertices)
        }

        var clip = images[imageIndex].animationClip
        var rewrote = false
        for t in clip.tracks.indices
        where clip.tracks[t].targetID == imageID && clip.tracks[t].property == .meshDeform {
            for k in clip.tracks[t].keyframes.indices {
                guard case let .meshDeform(verts) = clip.tracks[t].keyframes[k].value else { continue }
                // Start from the new bind positions so any vertex the old key
                // did not cover still has a value: the array is always exactly
                // `newCount` long, which is what the exporter checks before it
                // decides whether to keep the key at all.
                var rebuilt = change.mesh.vertices
                for (old, new) in change.remap
                where verts.indices.contains(old) && new < newCount {
                    rebuilt[new] = verts[old]
                }
                clip.tracks[t].keyframes[k].value = .meshDeform(rebuilt)
                rewrote = true
            }
        }
        if rewrote { images[imageIndex].animationClip = clip }
    }

    /// Grow every per-vertex deform array to cover a newly inserted vertex.
    ///
    /// The mirror image of `applyTopologyChange`. Inserts append, so existing
    /// indices stay valid and only the new slot has to be filled — but filling
    /// it with the rest position would make the sprite snap on every frame that
    /// has a deform key, because the new vertex would sit at its bind position
    /// while its neighbours are displaced.
    ///
    /// Instead the new value is the same barycentric blend of the deformed
    /// corners of whichever triangle of the *previous* mesh contained it. Adding
    /// a point then leaves the deformed silhouette exactly as it was, which is
    /// what an artist expects from subdividing.
    private func extendDeformArrays(
        imageIndex: Int, imageID: UUID, previousMesh: Mesh, insertedIndex: Int
    ) {
        let newMesh = images[imageIndex].mesh
        let restPosition = newMesh.vertices.indices.contains(insertedIndex)
            ? newMesh.vertices[insertedIndex]
            : .zero
        let blend = previousMesh.barycentricSample(at: restPosition)

        func grown(_ old: [SIMD2<Float>]) -> [SIMD2<Float>] {
            var next = newMesh.vertices
            for i in 0..<min(old.count, next.count) where i != insertedIndex {
                next[i] = old[i]
            }
            if next.indices.contains(insertedIndex), let blend {
                let a = old.indices.contains(blend.a) ? old[blend.a] : restPosition
                let b = old.indices.contains(blend.b) ? old[blend.b] : restPosition
                let c = old.indices.contains(blend.c) ? old[blend.c] : restPosition
                next[insertedIndex] = a * blend.wa + b * blend.wb + c * blend.wc
            }
            return next
        }

        if let deform = images[imageIndex].meshAnimationDeform {
            images[imageIndex].meshAnimationDeform = grown(deform)
        }

        var clip = images[imageIndex].animationClip
        var rewrote = false
        for t in clip.tracks.indices
        where clip.tracks[t].targetID == imageID && clip.tracks[t].property == .meshDeform {
            for k in clip.tracks[t].keyframes.indices {
                guard case let .meshDeform(verts) = clip.tracks[t].keyframes[k].value else { continue }
                clip.tracks[t].keyframes[k].value = .meshDeform(grown(verts))
                rewrote = true
            }
        }
        if rewrote { images[imageIndex].animationClip = clip }
    }

    func updateVisibility(itemID: UUID, isHidden: Bool) {
        if let index = hierarchyItems.firstIndex(where: { $0.id == itemID }) {
            hierarchyItems[index].isHidden = isHidden
        }
        if let index = images.firstIndex(where: { $0.id == itemID }) {
            images[index].isHidden = isHidden
        }
    }

    /// Rename a hierarchy row, and the image or bone it names, together.
    ///
    /// A name is stored three times — `HierarchyItem.name`, `SceneImage.name`
    /// and `Bone.name` — and the row used to write only the first, through a
    /// `$hierarchyItems[index]` binding. Everything reading the other two kept
    /// the old name permanently: the Inspector header, the Draw Order panel,
    /// the "<image> Mesh" child row (built from `image.name`), the saved
    /// project, the JSON export, and `BinaryExporter`, so the .umesh handed to
    /// Unity carried a stale name. On bones it also broke
    /// `mirroredBoneName(for:)`, silently unpairing the left/right mirror.
    ///
    /// Addressed by id rather than by array index, because the commit lands
    /// after the edit — after a blur, a Return, a drag reorder, a delete — and
    /// an index captured when the row was last drawn no longer means the same
    /// row. A reorder renamed a different row; a delete trapped on the
    /// subscript.
    ///
    /// - Returns: whether anything actually changed. `commitEditing` runs on
    ///   every blur, so a box opened and closed again must not push an undo
    ///   entry or mark the project dirty.
    @discardableResult
    func renameHierarchyItem(itemID: UUID, to proposed: String) -> Bool {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = hierarchyItems.firstIndex(where: { $0.id == itemID })
        else { return false }

        // Re-committing the row's own name is not a rename, and must not be
        // read as a collision either — a project that already holds two rows
        // called "Bone" would otherwise renumber one just for opening the box.
        guard trimmed != hierarchyItems[index].name else { return false }

        let resolved = uniqueHierarchyName(trimmed, excluding: itemID)
        guard resolved != hierarchyItems[index].name else { return false }

        pushUndoState()
        hierarchyItems[index].name = resolved
        if let imageIndex = images.firstIndex(where: { $0.id == itemID }) {
            images[imageIndex].name = resolved
        }
        if skeleton.bones[itemID] != nil {
            skeleton.bones[itemID]?.name = resolved
        }
        return true
    }

    /// The reserved set is built by IDENTITY, not by matching name.
    ///
    /// The view's version filtered with `$0 != item.name.lowercased()`, which
    /// excludes every row that happens to SHARE the current name instead of the
    /// one being renamed — so with two rows called "Bone" the check stopped
    /// seeing either of them and produced a third duplicate.
    private func uniqueHierarchyName(_ proposed: String, excluding itemID: UUID) -> String {
        let reserved = Set(
            hierarchyItems
                .filter { $0.id != itemID }
                .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        guard reserved.contains(proposed.lowercased()) else { return proposed }
        var suffix = 2
        var candidate = "\(proposed) \(suffix)"
        while reserved.contains(candidate.lowercased()) {
            suffix += 1
            candidate = "\(proposed) \(suffix)"
        }
        return candidate
    }

    func image(for id: UUID) -> SceneImage? {
        images.first { $0.id == id }
    }

    func displayHierarchyIDs() -> [UUID] {
        let itemsByID = Dictionary(uniqueKeysWithValues: hierarchyItems.map { ($0.id, $0) })
        let boundImages = Dictionary(grouping: images.compactMap { image -> (UUID, UUID)? in
            guard let boneID = image.boneBinding?.boneID else { return nil }
            return (boneID, image.id)
        }, by: \.0).mapValues { pairs in
            pairs.map(\.1)
        }
        let itemOrder = Dictionary(uniqueKeysWithValues: hierarchyItems.map { ($0.id, $0.order) })
        let childBones = Dictionary(grouping: skeleton.orderedBones.compactMap { bone -> (UUID, UUID)? in
            guard let parentID = bone.parentID else { return nil }
            return (parentID, bone.id)
        }, by: \.0).mapValues { pairs in
            pairs.map(\.1)
        }

        var orderedIDs: [UUID] = []
        var visited = Set<UUID>()

        func appendBone(_ boneID: UUID) {
            guard itemsByID[boneID] != nil, !visited.contains(boneID) else { return }
            visited.insert(boneID)
            orderedIDs.append(boneID)

            let imageIDs = (boundImages[boneID] ?? []).sorted {
                (itemOrder[$0] ?? .max) < (itemOrder[$1] ?? .max)
            }
            for imageID in imageIDs where itemsByID[imageID] != nil && !visited.contains(imageID) {
                visited.insert(imageID)
                orderedIDs.append(imageID)
            }

            let childIDs = (childBones[boneID] ?? []).sorted {
                (itemOrder[$0] ?? .max) < (itemOrder[$1] ?? .max)
            }
            for childID in childIDs {
                appendBone(childID)
            }
        }

        let rootBoneIDs = skeleton.rootIDs.sorted {
            (itemOrder[$0] ?? .max) < (itemOrder[$1] ?? .max)
        }
        for rootBoneID in rootBoneIDs {
            appendBone(rootBoneID)
        }

        for item in hierarchyItems.sorted(by: { $0.order < $1.order }) where !visited.contains(item.id) {
            visited.insert(item.id)
            orderedIDs.append(item.id)
        }

        return orderedIDs
    }

    func updateImage(id: UUID, update: (inout SceneImage) -> Void) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        update(&images[index])
    }

    func setImagePosition(id: UUID, position: SIMD2<Float>) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        images[index].position = position
        syncImageSetupPoseFromVisiblePose(imageIndex: index)
    }

    func setImageRotation(id: UUID, rotation: Float) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        images[index].rotation = rotation
        syncImageSetupPoseFromVisiblePose(imageIndex: index)
    }

    func setImageScale(id: UUID, scale: SIMD2<Float>) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        images[index].scale = scale
        syncImageSetupPoseFromVisiblePose(imageIndex: index)
    }

    func setImageSkew(id: UUID, skew: SIMD2<Float>) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        images[index].skew = skew
        syncImageSetupPoseFromVisiblePose(imageIndex: index)
    }

    func setImageRotation3D(id: UUID, rotation3D: SIMD3<Float>) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        images[index].rotation3D = rotation3D
        if !isAnimationEditingEnabled {
            images[index].baseRotation3D = rotation3D
        }
    }

    /// The sprite as it should be DRAWN this frame.
    ///
    /// A drag does not write `position` until the mouse comes up; until then
    /// the new place lives in `previewPositions`. Everything that draws the
    /// sprite has to apply that, and it was applied by hand in each of them —
    /// three did, the mesh overlay did not, so the mesh stayed where the sprite
    /// used to be for the whole drag and snapped into place on release.
    ///
    /// One function, so a fourth consumer cannot forget. Anything else the
    /// preview ever carries is added here and every caller gets it.
    func renderPose(for image: SceneImage) -> SceneImage {
        guard let preview = previewPositions[image.id] else { return image }
        var resolved = image
        resolved.position = preview
        return resolved
    }

    func setPreviewPosition(id: UUID, position: SIMD2<Float>) {
        previewPositions[id] = position
    }

    func clearPreviewPosition(id: UUID) {
        previewPositions.removeValue(forKey: id)
    }

    func restoreProject(
        images: [SceneImage],
        skeleton: Skeleton,
        hierarchyItems: [HierarchyItem],
        currentFrame: Int,
        playbackLoops: Bool,
        playbackStartFrame: Int,
        playbackEndFrame: Int,
        selectedImageID: UUID? = nil,
        selectedImageIDs: Set<UUID> = [],
        selectedKeyframe: SelectedKeyframe? = nil,
        selectedKeyframes: Set<SelectedKeyframe> = [],
        sceneAnimationClip: AnimationClip = AnimationClip(name: "Scene"),
        constraintSetupValues: [UUID: ConstraintSetupValues] = [:],
        projectFramesPerSecond: Double = 30,
        authoredDrawOrder: [UUID] = [],
        skins: [Skin] = [],
        activeSkinID: UUID? = nil,
        animationEvents: [AnimationEvent] = [],
        sceneCompositions: [SceneComposition] = [],
        selectedSceneCompositionID: UUID? = nil,
        sceneViewCamera: SceneViewCamera? = nil
    ) {
        pause()
        self.sceneCompositions = sceneCompositions
        self.selectedSceneCompositionID = selectedSceneCompositionID
        self.sceneViewCamera = sceneViewCamera ?? SceneViewCamera()
        self.authoredDrawOrder = authoredDrawOrder
        self.skins = skins
        self.activeSkinID = activeSkinID
        self.animationEvents = animationEvents
        self.recentlyFiredEvents = []
        self.projectFramesPerSecond = min(max(projectFramesPerSecond, 1), 240)
        self.images = images
        self.skeleton = skeleton
        self.sceneAnimationClip = sceneAnimationClip
        self.constraintSetupValues = constraintSetupValues
        self.animatedDrawOrder = nil
        self.hierarchyItems = hierarchyItems
        self.playbackLoops = playbackLoops
        self.selectedImageID = selectedImageID
        self.selectedImageIDs = selectedImageIDs
        self.selectedKeyframe = selectedKeyframe
        self.selectedKeyframes = selectedKeyframes
        self.selectedMeshVertexIndices = []
        self.selectedMeshInternalEdgeIndex = nil
        self.selectedBoneID = nil
        self.boneCreationPreviewStart = nil
        self.boneCreationPreviewEnd = nil
        self.copiedKeyframes = []
        self.previewPositions = [:]
        // Every sprite in the project is new; nothing remembered about the
        // last one can be reached again, and holding it only costs memory.
        renderMeshCache.removeAll()
        setPlaybackRange(start: playbackStartFrame, end: playbackEndFrame)
        pruneSkins()
        refreshSkinResolution()
        setCurrentFrame(currentFrame)
    }

    func setCurrentFrame(_ frame: Int) {
        let clamped = max(frame, 0)
        let previous = currentFrame
        currentFrame = clamped
        // Landing on a whole frame is what scrubbing, stepping and every menu
        // command mean, so the continuous time snaps to it. Playback overwrites
        // this a moment later with the fraction; everything else wants the
        // exact frame it asked for.
        animationTime = Double(clamped)
        if !isPlaying {
            playheadClock.frame = Double(clamped)
        }
        fireEventsCrossed(from: previous, to: clamped)
        applyAnimations()
    }

    /// Put the playhead at a FRACTIONAL frame.
    ///
    /// Scrubbing already carried a fractional position — the timeline computed
    /// it, moved its line with it, and then handed the model
    /// `Int(frame.rounded())`. So the line slid and the viewport snapped, which
    /// is the timeline and the viewport disagreeing: exactly the
    /// desynchronisation that gets reported. Now that the clip is sampled at a
    /// continuous time there is nothing left to round for.
    ///
    /// `currentFrame` still follows as a whole number, because that is what
    /// selects a keyframe and what a key is written on. Only the POSE is
    /// continuous.
    func setAnimationTime(_ time: Double) {
        let clamped = max(time, 0)
        let previous = currentFrame
        animationTime = clamped
        currentFrame = Int(clamped.rounded(.down))
        if !isPlaying {
            playheadClock.frame = clamped
        }
        fireEventsCrossed(from: previous, to: currentFrame)
        applyAnimations()
    }

    func setPlaybackRange(start: Int, end: Int) {
        let clampedStart = max(start, 0)
        let clampedEnd = max(end, clampedStart)
        playbackStartFrame = clampedStart
        playbackEndFrame = clampedEnd
        if currentFrame < clampedStart || currentFrame > clampedEnd {
            setCurrentFrame(min(max(currentFrame, clampedStart), clampedEnd))
        }
    }

    func stepFrames(_ delta: Int, lowerBound: Int? = nil, upperBound: Int? = nil) {
        let minFrame = playbackLowerBound(fallback: lowerBound)
        let maxFrame = playbackUpperBound(fallback: upperBound, minimum: minFrame)
        let nextFrame = min(max(currentFrame + delta, minFrame), maxFrame)
        setCurrentFrame(nextFrame)
    }

    func play(looping: Bool? = nil, lowerBound: Int? = nil, upperBound: Int? = nil, framesPerSecond: Double? = nil) {
        let framesPerSecond = framesPerSecond ?? projectFramesPerSecond
        if let looping {
            playbackLoops = looping
        }

        let minFrame = playbackLowerBound(fallback: lowerBound)
        let maxFrame = playbackUpperBound(fallback: upperBound, minimum: minFrame)
        guard maxFrame >= minFrame else {
            isPlaying = false
            return
        }

        playbackTask?.cancel()
        if currentFrame < minFrame || currentFrame > maxFrame {
            setCurrentFrame(minFrame)
        }
        isPlaying = true
        playheadClock.frame = Double(currentFrame)

        playbackSession = PlaybackSession(
            startFrame: currentFrame,
            // Media time, not absolute time. `CFAbsoluteTimeGetCurrent()` is
            // wall-clock seconds since 2001 and it can JUMP — an NTP
            // correction, a timezone change, the user setting the clock — which
            // would teleport the playhead mid-animation. `CACurrentMediaTime()`
            // is monotonic, and it is the timebase the display link reports in,
            // so the playhead and the presentation clock speak the same units.
            startTime: CACurrentMediaTime(),
            framesPerSecond: max(framesPerSecond, 1),
            minFrame: minFrame,
            maxFrame: maxFrame
        )

        // ONE CLOCK, AND NO POLLING.
        //
        // The display link is the driver: `MetalRenderer.draw(in:)` calls
        // `tickPlayback()` on every presented frame, so the pose evaluated and
        // the frame that shows it come from the same tick, on both platforms.
        // `CanvasActivity` keeps the canvas awake for as long as `isPlaying`,
        // so the link runs for the whole of playback.
        //
        // There used to be a second driver here: a `Task` waking 60 times a
        // second forever, hopping to the main actor and re-evaluating the same
        // instant the link had just evaluated. Sixty wakeups a second is a
        // timer the SoC cannot idle through, and it was doing the work twice.
        // It is gone.
        //
        // Nothing needs to poll, because playback state is
        // (startTime, startFrame, fps, bounds) and the playhead is a pure
        // function of wall-clock time. If nothing draws for a while — a sheet
        // over the editor — the playhead is simply not SAMPLED; when drawing
        // resumes it lands exactly where the clock says, with no drift to
        // correct.
        //
        // The one thing that is not display is the end of a clip that does not
        // loop: the transport has to stop even if nobody is watching. That
        // gets ONE wake, at the moment it happens.
        playbackTask = nil
        if !playbackLoops {
            // Deliberately a frame LATE, not early. `tickPlayback` stops the
            // transport when the playhead passes `maxFrame`; a wake that
            // arrives before that finds nothing to do and there is no second
            // one, so the clip would run past its end forever. Arriving a
            // frame late costs a frame and always works.
            let secondsRemaining =
                Double(maxFrame + 1 - currentFrame) / max(framesPerSecond, 1)
            let nanoseconds = UInt64(max(secondsRemaining, 0) * 1_000_000_000)
            playbackTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled, let self else { return }
                await MainActor.run {
                    self.tickPlayback()
                }
            }
        }
    }

    /// Advances the playhead for the current playback session and re-applies
    /// animation to the model. Must be called on the main thread. Idempotent
    /// per instant: the playhead is derived from absolute time, never from
    /// incremental deltas, so any number of drivers may call this.
    /// - Parameter presentationTime: the instant this frame will be SEEN, in
    ///   `CACurrentMediaTime()`'s timebase, from `DisplayClock`. Not the moment
    ///   the CPU woke up: the display presents on an exact grid and the main
    ///   thread wakes near it, so sampling at the wake time computes each pose
    ///   for an instant a millisecond or so off the one it is shown at. That
    ///   error changes sign every frame, and it is what makes constant-velocity
    ///   motion shimmer even when no frame is dropped.
    func tickPlayback(presentationTime: CFTimeInterval? = nil) {
        guard isPlaying, let session = playbackSession else { return }

        let now = presentationTime ?? CACurrentMediaTime()
        let elapsed = now - session.startTime
        var fractional = Double(session.startFrame) + elapsed * session.framesPerSecond
        let span = Double(session.maxFrame - session.minFrame + 1)

        if fractional > Double(session.maxFrame) {
            if playbackLoops, span > 0 {
                let overshoot = fractional - Double(session.minFrame)
                fractional = Double(session.minFrame) + overshoot.truncatingRemainder(dividingBy: span)
            } else {
                playheadClock.frame = Double(session.maxFrame)
                setCurrentFrame(session.maxFrame)
                pause()
                return
            }
        }

        playheadClock.frame = fractional
        animationTime = fractional

        // `currentFrame` stays a whole number — it is what the timeline
        // selects and what a keyframe sits on — and only announces when it
        // actually changes, which is once per clip frame, not once per tick.
        let targetFrame = Int(fractional.rounded(.down))
        if targetFrame != currentFrame {
            currentFrame = targetFrame
        }

        // EVERY tick, not only when the whole frame number changes. The clip is
        // sampled at `animationTime`, so this is what turns 24 held poses a
        // second into 120 distinct ones. The render loop was already skinning
        // and drawing at display rate on a pose that had not moved; this is the
        // work already being paid for finally producing motion.
        applyAnimations()
    }

    func pause() {
        isPlaying = false
        flushPanelAnnounce()
        playbackSession = nil
        playbackTask?.cancel()
        playbackTask = nil
    }

    func togglePlayback(looping: Bool? = nil, lowerBound: Int? = nil, upperBound: Int? = nil) {
        if isPlaying {
            pause()
        } else {
            play(looping: looping, lowerBound: lowerBound, upperBound: upperBound)
        }
    }

    /// True when a track belongs to `sceneAnimationClip` rather than to a bone
    /// or a sprite: every constraint property and the draw order timeline.
    func isSceneOwnedTrack(_ property: AnimationTrackProperty) -> Bool {
        property.domain != .node
    }

    func keyframes(for imageID: UUID, property: AnimationTrackProperty) -> [Keyframe] {
        if isSceneOwnedTrack(property) {
            return sceneAnimationClip.keyframes(for: imageID, property: property)
        }
        if let index = images.firstIndex(where: { $0.id == imageID }) {
            ensureImageAnimationSpaceConsistency(imageIndex: index)
            return images[index].animationClip.keyframes(for: imageID, property: property)
        }
        if let bone = skeleton.bones[imageID] {
            return bone.animationClip.keyframes(for: imageID, property: property)
        }
        return []
    }

    /// The value a transform key would capture right now, read off live state.
    ///
    /// One place, because both writers need it: the per-property commit the
    /// drag tools call when a gesture ends, and the key button, which captures
    /// all four channels at once. Two copies of this would drift the moment a
    /// channel changed how it resolves.
    func resolvedKeyframeValue(for targetID: UUID, property: AnimationTrackProperty) -> KeyframeValue? {
        if let index = images.firstIndex(where: { $0.id == targetID }) {
            switch property {
            case .translate:
                return .translate(resolvedAnimatedTranslate(for: images[index]))
            case .rotate:
                return .rotate(resolvedAnimatedRotation(for: images[index]))
            case .scale:
                return .scale(images[index].scale)
            case .shear:
                return .shear(images[index].skew)
            default:
                // Deform keys are written by the mesh tools, and constraint /
                // draw order keys are owned by the scene clip, not by a sprite.
                return nil
            }
        }

        guard let bone = skeleton.bones[targetID] else { return nil }
        switch property {
        case .translate:
            return .translate(SIMD2<Float>(bone.localTransform.position.x, bone.localTransform.position.y))
        case .rotate:
            return .rotate(bone.localTransform.rotation.z)
        case .scale:
            return .scale(SIMD2<Float>(bone.localTransform.scale.x, bone.localTransform.scale.y))
        case .shear:
            return .shear(bone.localTransform.skew)
        default:
            // Bones own transform tracks only.
            return nil
        }
    }

    func commitKeyframe(for imageID: UUID, property: AnimationTrackProperty, value: KeyframeValue? = nil) {
        guard isAnimationEditingEnabled else { return }
        if let index = images.firstIndex(where: { $0.id == imageID }) {
            guard let resolvedValue = value ?? resolvedKeyframeValue(for: imageID, property: property) else {
                return
            }

            images[index].animationClip.upsertKeyframe(
                targetID: imageID,
                property: property,
                frame: currentFrame,
                value: resolvedValue
            )
            if let keyframe = images[index].animationClip.keyframes(for: imageID, property: property).first(where: { $0.frame == currentFrame }) {
                let selection = SelectedKeyframe(imageID: imageID, property: property, keyframeID: keyframe.id)
                selectedKeyframes = [selection]
                selectedKeyframe = selection
            }
            applyAnimations()
            return
        }

        guard var bone = skeleton.bones[imageID] else { return }
        guard let resolvedValue = value ?? resolvedKeyframeValue(for: imageID, property: property) else {
            return
        }

        bone.animationClip.upsertKeyframe(
            targetID: imageID,
            property: property,
            frame: currentFrame,
            value: resolvedValue
        )
        skeleton.bones[imageID] = bone
        if let keyframe = bone.animationClip.keyframes(for: imageID, property: property).first(where: { $0.frame == currentFrame }) {
            let selection = SelectedKeyframe(imageID: imageID, property: property, keyframeID: keyframe.id)
            selectedKeyframes = [selection]
            selectedKeyframe = selection
        }
        applyAnimations()
    }

    // MARK: – The key button

    /// What the key button is looking at, at the playhead.
    ///
    /// Three states, not two. A frame is often PARTLY keyed — a rotate drag
    /// wrote `.rotate` here and nothing else — and that is the case the button
    /// has to get right: pressing there must complete the key, never clear it.
    enum TransformKeyState {
        case none
        case partial
        case full
    }

    /// The whole transform, declared once — the fallback, and the thing the
    /// narrowing below is a subset of.
    static let transformKeyProperties: [AnimationTrackProperty] = [.translate, .rotate, .scale, .shear]

    /// What the key writes with a given tool in hand.
    ///
    /// Rotate keys the rotation, Translate keys the position. Keying all four
    /// from the rotate tool would drop three keys the artist never asked for,
    /// and those three then pin the pose against the next key.
    ///
    /// A tool that is not a transform tool has no channel of its own, so the
    /// key covers the whole transform. Refusing there would leave the button
    /// dead in Select, which is the mode people pick things in.
    static func transformKeyProperties(for tool: ActiveTool) -> [AnimationTrackProperty] {
        switch tool {
        case .move:   return [.translate]
        case .rotate: return [.rotate]
        case .scale:  return [.scale]
        case .skew:   return [.shear]
        case .select, .bone, .mesh, .physicsPreview:
            return transformKeyProperties
        }
    }

    /// The channels this press would write, right now.
    var activeTransformKeyProperties: [AnimationTrackProperty] {
        Self.transformKeyProperties(for: activeCanvasTool)
    }

    /// Everything one press would write to: the selected sprites and bones, in
    /// document order.
    ///
    /// Ordered on purpose — `Set` iteration is not stable between runs, and the
    /// keyframe this leaves selected afterwards would otherwise change from one
    /// launch to the next.
    var transformKeyTargets: [UUID] {
        var targets: [UUID] = []

        if !selectedImageIDs.isEmpty {
            for image in images where selectedImageIDs.contains(image.id) {
                targets.append(image.id)
            }
        } else if let primary = selectedImageID, images.contains(where: { $0.id == primary }) {
            targets.append(primary)
        }

        var boneIDs = selectedBoneIDs
        if let primary = selectedBoneID {
            boneIDs.insert(primary)
        }
        if boneIDs.count == 1, let only = boneIDs.first, skeleton.bones[only] != nil {
            targets.append(only)
        } else if !boneIDs.isEmpty {
            for entry in IKBuilderRules.hierarchicalOrder(skeleton: skeleton)
            where boneIDs.contains(entry.bone.id) {
                targets.append(entry.bone.id)
            }
        }

        return targets
    }

    /// The clip that owns a target's transform tracks — a sprite's own clip, or
    /// its bone's.
    private func transformKeyframes(for targetID: UUID, property: AnimationTrackProperty) -> [Keyframe] {
        if let index = images.firstIndex(where: { $0.id == targetID }) {
            return images[index].animationClip.keyframes(for: targetID, property: property)
        }
        return skeleton.bones[targetID]?.animationClip.keyframes(for: targetID, property: property) ?? []
    }

    /// Scoped to the ACTIVE channels on purpose: with the rotate tool in hand a
    /// frame holding only a translate key is clean as far as this button is
    /// concerned, so pressing writes the rotation instead of reading the
    /// translate as "already keyed" and clearing it.
    private func keyedTransformCount(for targetID: UUID, atFrame frame: Int) -> Int {
        activeTransformKeyProperties.reduce(0) { total, property in
            let keyed = transformKeyframes(for: targetID, property: property).contains { $0.frame == frame }
            return total + (keyed ? 1 : 0)
        }
    }

    /// `.full` only when EVERY selected target is complete. A mixed selection —
    /// one bone fully keyed, its neighbour half keyed — reads as `.partial`, so
    /// pressing completes both instead of clearing the one that was done.
    func transformKeyState() -> TransformKeyState {
        let targets = transformKeyTargets
        guard !targets.isEmpty else { return .none }

        var allFull = true
        var allEmpty = true
        for target in targets {
            let count = keyedTransformCount(for: target, atFrame: currentFrame)
            if count < activeTransformKeyProperties.count { allFull = false }
            if count > 0 { allEmpty = false }
        }

        if allFull { return .full }
        if allEmpty { return .none }
        return .partial
    }

    /// The key button: capture the pose of everything selected, here, now.
    ///
    /// Keyframes could previously only appear as a side effect of dragging, so
    /// a pose that was already correct could not be keyed without nudging
    /// something first, and a pose reached with several tools could not be
    /// keyed as one thing.
    /// Returns whether it actually keyed anything, so a caller can confirm the
    /// press — animate, tap the haptic — only when something happened. The
    /// button is disabled in the refusing cases, but "disabled" is a render
    /// ago; this is the answer from the write itself.
    @discardableResult
    func toggleTransformKey() -> Bool {
        guard isAnimationEditingEnabled else { return false }
        let targets = transformKeyTargets
        guard !targets.isEmpty else { return false }

        let state = transformKeyState()
        pushUndoState()

        switch state {
        case .full:
            for target in targets {
                removeTransformKey(for: target, atFrame: currentFrame)
            }
            selectedKeyframes = []
            selectedKeyframe = nil
        case .none, .partial:
            for target in targets {
                writeTransformKey(for: target, atFrame: currentFrame)
            }
            var written: Set<SelectedKeyframe> = []
            for target in targets {
                for property in activeTransformKeyProperties {
                    guard let keyframe = transformKeyframes(for: target, property: property)
                        .first(where: { $0.frame == currentFrame }) else { continue }
                    written.insert(SelectedKeyframe(imageID: target,
                                                    property: property,
                                                    keyframeID: keyframe.id))
                }
            }
            selectedKeyframes = written
            selectedKeyframe = written.first
        }

        applyAnimations()
        return true
    }

    private func writeTransformKey(for targetID: UUID, atFrame frame: Int) {
        let properties = activeTransformKeyProperties
        if let index = images.firstIndex(where: { $0.id == targetID }) {
            for property in properties {
                guard let value = resolvedKeyframeValue(for: targetID, property: property) else { continue }
                images[index].animationClip.upsertKeyframe(
                    targetID: targetID,
                    property: property,
                    frame: frame,
                    value: value
                )
            }
            return
        }

        guard var bone = skeleton.bones[targetID] else { return }
        for property in properties {
            guard let value = resolvedKeyframeValue(for: targetID, property: property) else { continue }
            bone.animationClip.upsertKeyframe(
                targetID: targetID,
                property: property,
                frame: frame,
                value: value
            )
        }
        skeleton.bones[targetID] = bone
    }

    private func removeTransformKey(for targetID: UUID, atFrame frame: Int) {
        let properties = activeTransformKeyProperties
        if let index = images.firstIndex(where: { $0.id == targetID }) {
            for property in properties {
                let doomed = Set(images[index].animationClip
                    .keyframes(for: targetID, property: property)
                    .filter { $0.frame == frame }
                    .map { $0.id })
                guard !doomed.isEmpty else { continue }
                images[index].animationClip.deleteKeyframes(
                    targetID: targetID,
                    property: property,
                    keyframeIDs: doomed
                )
            }
            return
        }

        guard var bone = skeleton.bones[targetID] else { return }
        for property in properties {
            let doomed = Set(bone.animationClip
                .keyframes(for: targetID, property: property)
                .filter { $0.frame == frame }
                .map { $0.id })
            guard !doomed.isEmpty else { continue }
            bone.animationClip.deleteKeyframes(
                targetID: targetID,
                property: property,
                keyframeIDs: doomed
            )
        }
        skeleton.bones[targetID] = bone
    }

    func selectKeyframe(imageID: UUID, property: AnimationTrackProperty, keyframeID: UUID, additive: Bool) {
        let selection = SelectedKeyframe(imageID: imageID, property: property, keyframeID: keyframeID)
        if additive {
            if selectedKeyframes.contains(selection) {
                selectedKeyframes.remove(selection)
            } else {
                selectedKeyframes.insert(selection)
            }
        } else {
            selectedKeyframes = [selection]
        }
        selectedKeyframe = selectedKeyframes.first
        if images.contains(where: { $0.id == imageID }) {
            setSelection(ids: [imageID], primary: imageID, additive: false)
        } else if skeleton.bones[imageID] != nil {
            selectBone(imageID)
        }
    }

    func moveKeyframe(imageID: UUID, property: AnimationTrackProperty, keyframeID: UUID, toFrame frame: Int) {
        if isSceneOwnedTrack(property) {
            sceneAnimationClip.moveKeyframe(
                targetID: imageID,
                property: property,
                keyframeID: keyframeID,
                toFrame: frame
            )
            let selection = SelectedKeyframe(imageID: imageID, property: property, keyframeID: keyframeID)
            selectedKeyframes.insert(selection)
            selectedKeyframe = selection
            applyAnimations()
            return
        }
        if let index = images.firstIndex(where: { $0.id == imageID }) {
            images[index].animationClip.moveKeyframe(
                targetID: imageID,
                property: property,
                keyframeID: keyframeID,
                toFrame: frame
            )
        } else if var bone = skeleton.bones[imageID] {
            bone.animationClip.moveKeyframe(
                targetID: imageID,
                property: property,
                keyframeID: keyframeID,
                toFrame: frame
            )
            skeleton.bones[imageID] = bone
        } else {
            return
        }
        let selection = SelectedKeyframe(imageID: imageID, property: property, keyframeID: keyframeID)
        selectedKeyframes.insert(selection)
        selectedKeyframe = selection
        applyAnimations()
    }

    func updateKeyframeValue(imageID: UUID, property: AnimationTrackProperty, keyframeID: UUID, value: KeyframeValue) {
        if isSceneOwnedTrack(property) {
            sceneAnimationClip.updateKeyframeValue(
                targetID: imageID,
                property: property,
                keyframeID: keyframeID,
                value: value
            )
            applyAnimations()
            return
        }
        if let index = images.firstIndex(where: { $0.id == imageID }) {
            images[index].animationClip.updateKeyframeValue(
                targetID: imageID,
                property: property,
                keyframeID: keyframeID,
                value: value
            )
        } else if var bone = skeleton.bones[imageID] {
            bone.animationClip.updateKeyframeValue(
                targetID: imageID,
                property: property,
                keyframeID: keyframeID,
                value: value
            )
            skeleton.bones[imageID] = bone
        } else {
            return
        }
        applyAnimations()
    }

    func updateKeyframeTangents(
        imageID: UUID,
        property: AnimationTrackProperty,
        keyframeID: UUID,
        inTangent: SIMD2<Float>?,
        outTangent: SIMD2<Float>?,
        secondaryInTangent: SIMD2<Float>? = nil,
        secondaryOutTangent: SIMD2<Float>? = nil
    ) {
        if isSceneOwnedTrack(property) {
            sceneAnimationClip.updateKeyframeTangents(
                targetID: imageID,
                property: property,
                keyframeID: keyframeID,
                inTangent: inTangent,
                outTangent: outTangent,
                secondaryInTangent: secondaryInTangent,
                secondaryOutTangent: secondaryOutTangent
            )
            applyAnimations()
            return
        }
        if let index = images.firstIndex(where: { $0.id == imageID }) {
            images[index].animationClip.updateKeyframeTangents(
                targetID: imageID,
                property: property,
                keyframeID: keyframeID,
                inTangent: inTangent,
                outTangent: outTangent,
                secondaryInTangent: secondaryInTangent,
                secondaryOutTangent: secondaryOutTangent
            )
        } else if var bone = skeleton.bones[imageID] {
            bone.animationClip.updateKeyframeTangents(
                targetID: imageID,
                property: property,
                keyframeID: keyframeID,
                inTangent: inTangent,
                outTangent: outTangent,
                secondaryInTangent: secondaryInTangent,
                secondaryOutTangent: secondaryOutTangent
            )
            skeleton.bones[imageID] = bone
        } else {
            return
        }
        applyAnimations()
    }

    func moveSelectedKeyframes(anchor: SelectedKeyframe, deltaFrames: Int, startFrames: [SelectedKeyframe: Int]) {
        let selected = selectedKeyframes.isEmpty ? [anchor] : Array(selectedKeyframes)

        for selection in selected {
            guard let startFrame = startFrames[selection] else { continue }
            if isSceneOwnedTrack(selection.property) {
                sceneAnimationClip.moveKeyframe(
                    targetID: selection.imageID,
                    property: selection.property,
                    keyframeID: selection.keyframeID,
                    toFrame: startFrame + deltaFrames
                )
                continue
            }
            if var bone = skeleton.bones[selection.imageID] {
                bone.animationClip.moveKeyframe(
                    targetID: selection.imageID,
                    property: selection.property,
                    keyframeID: selection.keyframeID,
                    toFrame: startFrame + deltaFrames
                )
                skeleton.bones[selection.imageID] = bone
                continue
            }
            guard let imageIndex = images.firstIndex(where: { $0.id == selection.imageID }) else { continue }
            images[imageIndex].animationClip.moveKeyframe(
                targetID: selection.imageID,
                property: selection.property,
                keyframeID: selection.keyframeID,
                toFrame: startFrame + deltaFrames
            )
        }

        selectedKeyframe = anchor
        applyAnimations()
    }

    func selectedKeyframeInterpolation() -> KeyframeInterpolation? {
        guard !selectedKeyframes.isEmpty else { return nil }

        let interpolations = Set(
            selectedKeyframes.compactMap { selection in
                if let image = image(for: selection.imageID) {
                    return image.animationClip
                        .keyframe(for: selection.imageID, property: selection.property, keyframeID: selection.keyframeID)?
                        .interpolation
                }
                if isSceneOwnedTrack(selection.property) {
                    return sceneAnimationClip
                        .keyframe(for: selection.imageID, property: selection.property, keyframeID: selection.keyframeID)?
                        .interpolation
                }
                return skeleton.bones[selection.imageID]?
                    .animationClip
                    .keyframe(for: selection.imageID, property: selection.property, keyframeID: selection.keyframeID)?
                    .interpolation
            }
        )

        guard interpolations.count == 1 else { return nil }
        return interpolations.first
    }

    func setInterpolationForSelectedKeyframes(_ interpolation: KeyframeInterpolation) {
        guard !selectedKeyframes.isEmpty else { return }

        let grouped = Dictionary(grouping: selectedKeyframes) {
            KeyframeSelectionGroup(imageID: $0.imageID, property: $0.property)
        }

        for (group, selections) in grouped {
            if let imageIndex = images.firstIndex(where: { $0.id == group.imageID }) {
                images[imageIndex].animationClip.setInterpolation(
                    targetID: group.imageID,
                    property: group.property,
                    keyframeIDs: Set(selections.map(\.keyframeID)),
                    interpolation: interpolation
                )
            } else if isSceneOwnedTrack(group.property) {
                sceneAnimationClip.setInterpolation(
                    targetID: group.imageID,
                    property: group.property,
                    keyframeIDs: Set(selections.map(\.keyframeID)),
                    interpolation: interpolation
                )
            } else if var bone = skeleton.bones[group.imageID] {
                bone.animationClip.setInterpolation(
                    targetID: group.imageID,
                    property: group.property,
                    keyframeIDs: Set(selections.map(\.keyframeID)),
                    interpolation: interpolation
                )
                skeleton.bones[group.imageID] = bone
            }
        }

        applyAnimations()
    }

    func applyAutoTangentsToSelectedKeyframes() {
        guard !selectedKeyframes.isEmpty else { return }

        let grouped = Dictionary(grouping: selectedKeyframes) {
            KeyframeSelectionGroup(imageID: $0.imageID, property: $0.property)
        }

        for (group, selections) in grouped {
            if let imageIndex = images.firstIndex(where: { $0.id == group.imageID }) {
                images[imageIndex].animationClip.applyAutoTangents(
                    targetID: group.imageID,
                    property: group.property,
                    keyframeIDs: Set(selections.map(\.keyframeID))
                )
            } else if isSceneOwnedTrack(group.property) {
                sceneAnimationClip.applyAutoTangents(
                    targetID: group.imageID,
                    property: group.property,
                    keyframeIDs: Set(selections.map(\.keyframeID))
                )
            } else if var bone = skeleton.bones[group.imageID] {
                bone.animationClip.applyAutoTangents(
                    targetID: group.imageID,
                    property: group.property,
                    keyframeIDs: Set(selections.map(\.keyframeID))
                )
                skeleton.bones[group.imageID] = bone
            }
        }

        applyAnimations()
    }

    func deleteSelectedKeyframes() {
        guard !selectedKeyframes.isEmpty else { return }

        let grouped = Dictionary(grouping: selectedKeyframes) {
            KeyframeSelectionGroup(imageID: $0.imageID, property: $0.property)
        }
        for (group, selections) in grouped {
            if let imageIndex = images.firstIndex(where: { $0.id == group.imageID }) {
                images[imageIndex].animationClip.deleteKeyframes(
                    targetID: group.imageID,
                    property: group.property,
                    keyframeIDs: Set(selections.map { $0.keyframeID })
                )
            } else if isSceneOwnedTrack(group.property) {
                sceneAnimationClip.deleteKeyframes(
                    targetID: group.imageID,
                    property: group.property,
                    keyframeIDs: Set(selections.map { $0.keyframeID })
                )
                // Deleting the last key of a constraint property must put the
                // authored value back, otherwise the constraint would keep the
                // value the removed key happened to hold.
                if group.property.domain == .constraint,
                   !isConstraintPropertyAnimated(group.imageID, group.property) {
                    restoreConstraintSetupValue(group.imageID, group.property)
                }
            } else if var bone = skeleton.bones[group.imageID] {
                bone.animationClip.deleteKeyframes(
                    targetID: group.imageID,
                    property: group.property,
                    keyframeIDs: Set(selections.map { $0.keyframeID })
                )
                skeleton.bones[group.imageID] = bone
            }
        }

        selectedKeyframes.removeAll()
        selectedKeyframe = nil
        applyAnimations()
    }

    func isKeyframeSelected(_ selection: SelectedKeyframe) -> Bool {
        selectedKeyframes.contains(selection)
    }

    func setSelectedKeyframes(_ selections: Set<SelectedKeyframe>, additive: Bool) {
        if additive {
            selectedKeyframes.formUnion(selections)
        } else {
            selectedKeyframes = selections
        }

        selectedKeyframe = selectedKeyframes.first
        let imageIDs = Array(Set(selectedKeyframes.map(\.imageID)))
        if let primaryImageID = imageIDs.first, images.contains(where: { $0.id == primaryImageID }) {
            setSelection(ids: imageIDs, primary: primaryImageID, additive: false)
        } else if let primaryBoneID = imageIDs.first, skeleton.bones[primaryBoneID] != nil {
            selectBone(primaryBoneID)
        } else {
            selectedKeyframe = nil
        }
    }

    func copySelectedKeyframes() -> [NSItemProvider] {
        guard !selectedKeyframes.isEmpty else { return [] }

        let resolved: [(SelectedKeyframe, Keyframe)] = selectedKeyframes.compactMap { selection in
            if let image = image(for: selection.imageID),
               let keyframe = image.animationClip.keyframe(
                for: selection.imageID,
                property: selection.property,
                keyframeID: selection.keyframeID
               ) {
                return (selection, keyframe)
            }
            if let bone = skeleton.bones[selection.imageID],
               let keyframe = bone.animationClip.keyframe(
                for: selection.imageID,
                property: selection.property,
                keyframeID: selection.keyframeID
               ) {
                return (selection, keyframe)
            }
            if isSceneOwnedTrack(selection.property),
               let keyframe = sceneAnimationClip.keyframe(
                for: selection.imageID,
                property: selection.property,
                keyframeID: selection.keyframeID
               ) {
                return (selection, keyframe)
            }
            return nil
        }
        .sorted { lhs, rhs in
            if lhs.1.frame == rhs.1.frame {
                return lhs.0.property.rawValue < rhs.0.property.rawValue
            }
            return lhs.1.frame < rhs.1.frame
        }

        guard let firstFrame = resolved.first?.1.frame else { return [] }

        copiedKeyframes = resolved.map { selection, keyframe in
            CopiedKeyframePayload(
                imageID: selection.imageID,
                property: selection.property,
                relativeFrame: keyframe.frame - firstFrame,
                value: keyframe.value,
                interpolation: keyframe.interpolation,
                inTangent: keyframe.inTangent,
                outTangent: keyframe.outTangent,
                secondaryInTangent: keyframe.secondaryInTangent,
                secondaryOutTangent: keyframe.secondaryOutTangent
            )
        }

        let summary = "UltraMeshKeyframes:\(copiedKeyframes.count)"
        return [NSItemProvider(object: summary as NSString)]
    }

    func pasteCopiedKeyframes() {
        guard !copiedKeyframes.isEmpty else { return }

        var newSelections = Set<SelectedKeyframe>()
        for payload in copiedKeyframes {
            let targetFrame = max(currentFrame + payload.relativeFrame, 0)
            if isSceneOwnedTrack(payload.property) {
                if payload.property.domain == .constraint {
                    ensureConstraintSetupCaptured(payload.imageID)
                }
                sceneAnimationClip.upsertKeyframe(
                    targetID: payload.imageID,
                    property: payload.property,
                    frame: targetFrame,
                    value: payload.value,
                    interpolation: payload.interpolation
                )
                if let keyframe = sceneAnimationClip.keyframes(for: payload.imageID, property: payload.property)
                    .first(where: { $0.frame == targetFrame }) {
                    sceneAnimationClip.updateKeyframeTangents(
                        targetID: payload.imageID,
                        property: payload.property,
                        keyframeID: keyframe.id,
                        inTangent: payload.inTangent,
                        outTangent: payload.outTangent,
                        secondaryInTangent: payload.secondaryInTangent,
                        secondaryOutTangent: payload.secondaryOutTangent
                    )
                    newSelections.insert(
                        SelectedKeyframe(
                            imageID: payload.imageID,
                            property: payload.property,
                            keyframeID: keyframe.id
                        )
                    )
                }
                continue
            }
            if let index = images.firstIndex(where: { $0.id == payload.imageID }) {
                images[index].animationClip.upsertKeyframe(
                    targetID: payload.imageID,
                    property: payload.property,
                    frame: targetFrame,
                    value: payload.value,
                    interpolation: payload.interpolation
                )
                if let keyframe = images[index].animationClip.keyframes(for: payload.imageID, property: payload.property)
                    .first(where: { $0.frame == targetFrame }) {
                    images[index].animationClip.updateKeyframeTangents(
                        targetID: payload.imageID,
                        property: payload.property,
                        keyframeID: keyframe.id,
                        inTangent: payload.inTangent,
                        outTangent: payload.outTangent,
                        secondaryInTangent: payload.secondaryInTangent,
                        secondaryOutTangent: payload.secondaryOutTangent
                    )
                }
            } else if var bone = skeleton.bones[payload.imageID] {
                bone.animationClip.upsertKeyframe(
                    targetID: payload.imageID,
                    property: payload.property,
                    frame: targetFrame,
                    value: payload.value,
                    interpolation: payload.interpolation
                )
                if let keyframe = bone.animationClip.keyframes(for: payload.imageID, property: payload.property)
                    .first(where: { $0.frame == targetFrame }) {
                    bone.animationClip.updateKeyframeTangents(
                        targetID: payload.imageID,
                        property: payload.property,
                        keyframeID: keyframe.id,
                        inTangent: payload.inTangent,
                        outTangent: payload.outTangent,
                        secondaryInTangent: payload.secondaryInTangent,
                        secondaryOutTangent: payload.secondaryOutTangent
                    )
                }
                skeleton.bones[payload.imageID] = bone
            } else {
                continue
            }

            if let keyframe = keyframes(for: payload.imageID, property: payload.property)
                .first(where: { $0.frame == targetFrame }) {
                newSelections.insert(
                    SelectedKeyframe(
                        imageID: payload.imageID,
                        property: payload.property,
                        keyframeID: keyframe.id
                    )
                )
            }
        }

        setSelectedKeyframes(newSelections, additive: false)
        applyAnimations()
    }

    func duplicateSelectedKeyframes() {
        guard !selectedKeyframes.isEmpty else { return }

        let resolved: [(SelectedKeyframe, Keyframe)] = selectedKeyframes.compactMap { selection in
            if let image = image(for: selection.imageID),
               let keyframe = image.animationClip.keyframe(
                for: selection.imageID,
                property: selection.property,
                keyframeID: selection.keyframeID
               ) {
                return (selection, keyframe)
            }
            if let bone = skeleton.bones[selection.imageID],
               let keyframe = bone.animationClip.keyframe(
                for: selection.imageID,
                property: selection.property,
                keyframeID: selection.keyframeID
               ) {
                return (selection, keyframe)
            }
            if isSceneOwnedTrack(selection.property),
               let keyframe = sceneAnimationClip.keyframe(
                for: selection.imageID,
                property: selection.property,
                keyframeID: selection.keyframeID
               ) {
                return (selection, keyframe)
            }
            return nil
        }

        guard let minFrame = resolved.map(\.1.frame).min(),
              let maxFrame = resolved.map(\.1.frame).max() else {
            return
        }

        let duplicateOffset = max((maxFrame - minFrame) + 1, 1)
        copiedKeyframes = resolved.map { selection, keyframe in
            CopiedKeyframePayload(
                imageID: selection.imageID,
                property: selection.property,
                relativeFrame: (keyframe.frame - minFrame) + duplicateOffset,
                value: keyframe.value,
                interpolation: keyframe.interpolation,
                inTangent: keyframe.inTangent,
                outTangent: keyframe.outTangent,
                secondaryInTangent: keyframe.secondaryInTangent,
                secondaryOutTangent: keyframe.secondaryOutTangent
            )
        }

        currentFrame = minFrame
        pasteCopiedKeyframes()
    }

    private func normalizeOrder() {
        for index in hierarchyItems.indices {
            hierarchyItems[index].order = index
        }
    }

    private func syncImagesToHierarchy() {
        // Rank built ONCE, and every sprite given one.
        //
        // This used to call `firstIndex(of:)` on the tree inside the
        // comparator, which is O(n squared log n) — and, far worse, returned
        // `false` when either sprite was missing from the tree. A comparator
        // that answers `false` both ways for a pair is not a strict weak
        // ordering, and Swift's `sort` on an inconsistent predicate may return
        // ANY permutation: one sprite the tree does not name was enough to
        // scramble every other. Mirrored, the same set came back in fifteen
        // different orders across forty shuffles.
        //
        // A sprite the tree does not name now keeps its place at the back
        // instead of poisoning the comparison, and ties break on the sprite's
        // existing position, so the sort is stable.
        let orderedIDs = displayHierarchyIDs()
        var rank: [UUID: Int] = [:]
        rank.reserveCapacity(orderedIDs.count)
        for (index, id) in orderedIDs.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        let unranked = orderedIDs.count
        images = images.enumerated()
            .sorted { left, right in
                let leftRank = rank[left.element.id] ?? unranked
                let rightRank = rank[right.element.id] ?? unranked
                if leftRank != rightRank { return leftRank < rightRank }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    private func playbackLowerBound(fallback: Int?) -> Int {
        max(fallback ?? playbackStartFrame, 0)
    }

    private func playbackUpperBound(fallback: Int?, minimum: Int? = nil) -> Int {
        max(fallback ?? playbackEndFrame, minimum ?? playbackStartFrame, 0)
    }

    /// Puts the rig back on the pose Editor works from.
    ///
    /// The SETUP pose, written straight from the base values — not the clip
    /// sampled at frame zero, because frame zero is a keyframe like any other
    /// and a rig keyframed there would come back animated.
    ///
    /// Leaving Animator needs this on top of pausing. A paused rig is still an
    /// animated rig: stop at frame 37 and Editor is showing frame 37, and
    /// every edit made there is made against a pose that belongs to an
    /// animation. This is what a 2D skeletal editor does on leaving Animate mode, and it is
    /// what "Editor is not affected by Animator" has to mean.
    func restoreSetupPose() {
        applySetupPose()
    }

    /// The setup pose, written straight from the base values.
    ///
    /// Shared by the mode switch and by `applyAnimations` in Setup mode,
    /// because those are the same question and a second copy is exactly how
    /// this went wrong: `restoreSetupPose` put the rig back and
    /// `applyAnimations` sampled the clips again on the next interaction.
    private func applySetupPose() {
        // Pose mode owns `localTransform` — the artist is hand-posing it, and
        // writing the base values over it every interaction is the same bug in
        // a different costume. Skipped entirely rather than filtered inside the
        // loop, so nothing is written and `skeleton` announces nothing.
        if !isPoseMode {
            var restoredBones = skeleton.bones
            for (boneID, existingBone) in skeleton.bones {
                var bone = existingBone
                bone.localTransform.position.x = bone.baseTransform.position.x
                bone.localTransform.position.y = bone.baseTransform.position.y
                bone.localTransform.scale.x = bone.baseTransform.scale.x
                bone.localTransform.scale.y = bone.baseTransform.scale.y
                bone.localTransform.rotation.z = bone.baseTransform.rotation.z
                bone.localTransform.skew = bone.baseTransform.skew
                restoredBones[boneID] = bone
            }
            skeleton.bones = restoredBones
        }

        // One assignment, as everywhere else that touches `images` in bulk:
        // it is @Published, and six writes per sprite is six notifications.
        var restoredImages = images
        for index in restoredImages.indices {
            let base = restoredImages[index].boneBinding?.localPose
                ?? restoredImages[index].basePose
            restoredImages[index].position = base.position
            restoredImages[index].scale = base.scale
            restoredImages[index].rotation = base.rotation
            restoredImages[index].rotation3D = restoredImages[index].baseRotation3D
            restoredImages[index].skew = base.skew
            restoredImages[index].meshAnimationDeform = nil
        }
        applyBoneBindings(to: &restoredImages, time: Float(animationTime),
                          sampleClips: false)
        images = restoredImages
    }

    /// Re-pose the rig at the playhead, from outside the model.
    ///
    /// Entering Animator needs it: leaving restored the setup pose, and
    /// without this the timeline would open onto that instead of onto the
    /// frame the playhead is still sitting on.
    func reapplyAnimationsAtPlayhead() {
        applyAnimations()
    }

    private func applyAnimations() {
        // ONE time for the whole frame. Every sampler below reads this, so a
        // sprite, its bones and its constraints are never evaluated a fraction
        // apart from each other.
        let time = Float(animationTime)

        // Constraint properties must settle before any world matrix is built,
        // because the solver reads mix/softness/etc. straight off the structs.
        // Each of these three decides the mode for itself and clears its own
        // animated state in Setup, so they run either way.
        applyConstraintAnimations(time: time)
        applyDrawOrderAnimation(time: time)
        applyAttachmentAnimations(time: time)

        // ONE RULE, DECIDED HERE: Animator samples the clips, Editor writes the
        // setup pose.
        //
        // It used to be decided four times further down, differently each
        // time. Constraints had both branches, draw order had a guard, the
        // mesh deform had a condition — and the BONE pass was gated only on
        // pose mode while the SPRITE pass had no gate at all. So Editor
        // re-sampled every clip on every interaction, and `restoreSetupPose()`
        // — which the mode switch calls, and whose whole purpose is this —
        // lasted until the artist next moved the playhead, a bone, a sprite,
        // or pressed undo.
        //
        // The symptom reads as arbitrary because only KEYED properties leak:
        // an unkeyed one falls through to its base value and looks right, so
        // one bone is wrong and the one beside it is fine.
        //
        // The Setup branch samples no curve and evaluates no deform, so this
        // makes Editor cheaper as well as correct. The Animator path below is
        // unchanged.
        guard isAnimationEditingEnabled else {
            for index in images.indices {
                ensureImageAnimationSpaceConsistency(imageIndex: index)
            }
            applySetupPose()
            return
        }

        // In pose mode the artist is hand-posing localTransforms directly;
        // re-evaluating clips here would silently revert the pose every frame.
        // The mode decision above is about Setup vs Animate; this one is about
        // who owns `localTransform`, and they are different questions.
        if !isPoseMode {
            applyBoneAnimations(time: time)
        }
        // Runs first and against the published array, because it can convert a
        // sprite's animation space (a structural change, not a pose one). It
        // early-returns in the normal case, so this costs a comparison.
        for index in images.indices {
            ensureImageAnimationSpaceConsistency(imageIndex: index)
        }

        // Same reasoning as applyBoneAnimations: `images` is @Published, and
        // each of these six assignments per sprite announced its own change.
        // A 25-sprite rig sent 150 notifications per frame; now it sends one.
        var updatedImages = images
        for index in updatedImages.indices {
            let basePose = updatedImages[index].boneBinding?.localPose ?? updatedImages[index].basePose
            let pose = updatedImages[index].animationClip.pose(
                for: updatedImages[index].id,
                basePose: basePose,
                time: time
            )
            updatedImages[index].position = pose.position
            updatedImages[index].scale = pose.scale
            updatedImages[index].rotation = pose.rotation
            updatedImages[index].rotation3D = updatedImages[index].baseRotation3D
            updatedImages[index].skew = pose.skew

            // ONLY WHILE ANIMATING. `isAnimationEditingEnabled.didSet` clears
            // every deform on the way back to Editor, and this line put them
            // straight back: `setCurrentFrame` calls `applyAnimations`, and the
            // playhead moves in Editor too.
            //
            // A live deform in Editor is not a cosmetic problem. The mesh
            // overlay, the vertex hit test and the drag all read
            // `meshAnimationDeform ?? mesh.vertices`, while `updateMeshVertex`
            // in Editor writes `mesh.vertices` — so the array being drawn was
            // not the array being edited. The node stood still, the uv moved
            // with the drag, and the artwork slid through triangles that never
            // moved. That is the reported bug, and it is why bones already do
            // exactly this: Editor shows the setup pose.
            let deformed = updatedImages[index].animationClip.evaluatedMeshDeform(
                for: updatedImages[index].id,
                time: time,
                fallback: []
            )
            updatedImages[index].meshAnimationDeform =
                (isAnimationEditingEnabled && !deformed.isEmpty) ? deformed : nil
        }
        // Same array, same pass: the bindings read the pose that was just
        // written into it, and the whole frame is one copy and one assignment.
        applyBoneBindings(to: &updatedImages, time: time, sampleClips: true)
        images = updatedImages
    }

    private func applyBoneAnimations(time: Float) {
        // Build the whole updated bone table, then publish it once.
        //
        // `skeleton` is @Published, so the previous form — assigning
        // `skeleton.bones[boneID]` inside the loop — announced a change to
        // SwiftUI once PER BONE. During playback that meant a 40-bone rig sent
        // 40 change notifications per frame, and every view observing the
        // scene (timeline, hierarchy, inspector, draw order) was invalidated
        // by each one.
        // Iterating the published dictionary while writing into a local copy:
        // reads never notify, so only the single assignment at the end does.
        skeleton.bones = Self.clipSampledBones(skeleton.bones, atTime: time)
    }

    /// Every bone's local transform sampled from its clip at a frame.
    ///
    /// Shared by the live path above and by `rigPose(atFrame:)`, so a Scene
    /// instance poses its bones through exactly the code the canvas uses.
    static func clipSampledBones(_ bones: [UUID: Bone], atFrame frame: Int) -> [UUID: Bone] {
        clipSampledBones(bones, atTime: Float(frame))
    }

    static func clipSampledBones(_ bones: [UUID: Bone], atTime time: Float) -> [UUID: Bone] {
        var updatedBones = bones
        for (boneID, existingBone) in bones {
            var bone = existingBone
            let basePose = SceneImageAnimationPose(
                position: SIMD2<Float>(bone.baseTransform.position.x, bone.baseTransform.position.y),
                scale: SIMD2<Float>(bone.baseTransform.scale.x, bone.baseTransform.scale.y),
                rotation: bone.baseTransform.rotation.z,
                skew: bone.baseTransform.skew
            )
            // Bone rotation is an ANGLE — `moveBoneTip` and `setBoneRotation`
            // write it through `atan2`, so it arrives wrapped into (-π, π].
            // Joined the long way round, a two-degree move across that
            // boundary plays as a 358-degree spin.
            let pose = bone.animationClip.pose(
                for: boneID,
                basePose: basePose,
                time: time,
                cyclicRotation: true
            )
            bone.localTransform.position.x = pose.position.x
            bone.localTransform.position.y = pose.position.y
            bone.localTransform.scale.x = pose.scale.x
            bone.localTransform.scale.y = pose.scale.y
            bone.localTransform.rotation.z = pose.rotation
            bone.localTransform.skew = pose.skew
            updatedBones[boneID] = bone
        }
        return updatedBones
    }

    // MARK: - Pure pose sampling (Scene instances)

    /// The whole rig resolved at one frame, with nothing mutated.
    struct RigPose {
        struct ImagePose {
            var position: SIMD2<Float>
            var scale: SIMD2<Float>
            var rotation: Float
            var skew: SIMD2<Float>
            var meshDeform: [SIMD2<Float>]?
        }
        var imagePoses: [UUID: ImagePose]
        var worldMatrices: [UUID: simd_float4x4]
        /// Sprite order at this frame, nil when the draw order is not animated.
        var drawOrder: [UUID]?
    }

    /// Sample the rig at an arbitrary frame without touching the live scene.
    ///
    /// This is what lets a Scene place the same rig three times, each instance
    /// at a different point in its clip: `applyAnimations()` can only answer
    /// "what does frame N look like" by BECOMING frame N — it writes `images`
    /// and `skeleton`, both @Published, so asking it three times a frame would
    /// invalidate every observing view three times and leave the editor sitting
    /// at whichever frame was asked last.
    ///
    /// The rules, enforced by `verify_scene_instances.py` reading this source:
    /// nothing published is assigned; every sampling step goes through the same
    /// functions the live path uses (`constraintSampledSkeleton`,
    /// `clipSampledBones`, `boundImagePose`); and world matrices are taken with
    /// `steppingPhysics: false` — physics integrates over time, so instances
    /// OBSERVE the one shared simulation and never advance it.
    ///
    /// The rotation unwrap in `applyBoneBindings` is deliberately absent: it
    /// exists to keep the visible angle continuous from one live frame to the
    /// next, a static sample has no previous frame, and an angle off by 2π
    /// draws identically.
    func rigPose(atFrame frame: Int) -> RigPose {
        let key = RigPoseKey(frame: frame, token: rigStateToken)
        if let cached = rigPoseCache[key] { return cached }
        let sample = solveRigPose(atFrame: frame)
        // Small on purpose. A Scene asks for a handful of frames at a time —
        // one per instance — and the whole cache is dropped by the next edit
        // anyway, since the token is part of the key. Holding more would be
        // holding poses of a rig that has already changed.
        if rigPoseCache.count >= Self.rigPoseCacheLimit { rigPoseCache.removeAll(keepingCapacity: true) }
        rigPoseCache[key] = sample
        return sample
    }

    private struct RigPoseKey: Hashable {
        let frame: Int
        let token: UInt64
    }

    private var rigPoseCache: [RigPoseKey: RigPose] = [:]
    private static let rigPoseCacheLimit = 24

    private func solveRigPose(atFrame frame: Int) -> RigPose {
        var working = constraintSampledSkeleton(from: skeleton, atFrame: frame).skeleton
        working.bones = Self.clipSampledBones(working.bones, atFrame: frame)
        let matrices = working.worldMatrices(steppingPhysics: false)

        var poses: [UUID: RigPose.ImagePose] = [:]
        poses.reserveCapacity(images.count)
        for image in images {
            let basePose = image.boneBinding?.localPose ?? image.basePose
            var local = image.animationClip.pose(
                for: image.id,
                basePose: basePose,
                frame: frame
            )
            if let binding = image.boneBinding, let worldMatrix = matrices[binding.boneID] {
                local = Self.boundImagePose(localPose: local, worldMatrix: worldMatrix)
            }

            let deform = image.animationClip.evaluatedMeshDeform(
                for: image.id,
                frame: frame,
                fallback: []
            )
            poses[image.id] = RigPose.ImagePose(
                position: local.position,
                scale: local.scale,
                rotation: local.rotation,
                skew: local.skew,
                meshDeform: deform.isEmpty ? nil : deform
            )
        }

        return RigPose(
            imagePoses: poses,
            worldMatrices: matrices,
            drawOrder: sceneAnimationClip.evaluatedDrawOrder(frame: frame)
        )
    }

    private func resolvedAnimatedTranslate(for image: SceneImage) -> SIMD2<Float> {
        guard let boneID = image.boneBinding?.boneID else {
            return image.position
        }
        return skeleton.localPoint(image.position, relativeTo: boneID)
    }

    private func resolvedAnimatedRotation(for image: SceneImage) -> Float {
        guard let boneID = image.boneBinding?.boneID else {
            return image.rotation
        }
        return image.rotation - (skeleton.worldRotation(for: boneID) ?? 0)
    }

    private func convertImageAnimationSpace(imageIndex: Int, from sourceBoneID: UUID?, to targetBoneID: UUID?) {
        images[imageIndex].basePosition = convertPosition(images[imageIndex].basePosition, from: sourceBoneID, to: targetBoneID)
        images[imageIndex].baseRotation = convertRotation(images[imageIndex].baseRotation, from: sourceBoneID, to: targetBoneID)

        let imageID = images[imageIndex].id
        for trackIndex in images[imageIndex].animationClip.tracks.indices {
            guard images[imageIndex].animationClip.tracks[trackIndex].targetID == imageID else { continue }
            switch images[imageIndex].animationClip.tracks[trackIndex].property {
            case .translate:
                for keyframeIndex in images[imageIndex].animationClip.tracks[trackIndex].keyframes.indices {
                    guard case let .translate(position) = images[imageIndex].animationClip.tracks[trackIndex].keyframes[keyframeIndex].value else {
                        continue
                    }
                    images[imageIndex].animationClip.tracks[trackIndex].keyframes[keyframeIndex].value = .translate(
                        convertPosition(position, from: sourceBoneID, to: targetBoneID)
                    )
                }
            case .rotate:
                for keyframeIndex in images[imageIndex].animationClip.tracks[trackIndex].keyframes.indices {
                    guard case let .rotate(rotation) = images[imageIndex].animationClip.tracks[trackIndex].keyframes[keyframeIndex].value else {
                        continue
                    }
                    images[imageIndex].animationClip.tracks[trackIndex].keyframes[keyframeIndex].value = .rotate(
                        convertRotation(rotation, from: sourceBoneID, to: targetBoneID)
                    )
                }
            default:
                // Scale, shear and deform are space-invariant; constraint and
                // draw order tracks are not owned by a sprite at all.
                continue
            }
        }
    }

    /// Converts a sprite's current visible (world) pose into the local space
    /// of a bone, as the exact inverse of `applyBoneBindings`: the position is
    /// mapped through the inverse world matrix and the basis axes are mapped
    /// through the inverse 2×2 linear part, then decomposed back into
    /// rotation / scale / skew. Binding a sprite therefore never changes what
    /// is on screen, even under scaled, flipped, or sheared bones.
    private func localSpritePose(
        for image: SceneImage,
        relativeTo boneID: UUID?
    ) -> SceneImageAnimationPose {
        guard let boneID,
              let worldMatrix = skeleton.worldMatrix(for: boneID) else {
            return SceneImageAnimationPose(
                position: image.position,
                scale: image.scale,
                rotation: image.rotation,
                skew: image.skew
            )
        }
        let inverse = simd_inverse(worldMatrix)
        let local3 = MatrixUtilities.transformPoint(
            SIMD3<Float>(image.position.x, image.position.y, 0),
            with: inverse
        )
        let worldAxes = MatrixUtilities.shearedAxes(
            rotationDegrees: image.rotation * 180 / .pi,
            shear: image.skew,
            scale: image.scale
        )
        let invX = SIMD2<Float>(inverse.columns.0.x, inverse.columns.0.y)
        let invY = SIMD2<Float>(inverse.columns.1.x, inverse.columns.1.y)
        let localX = invX * worldAxes.x.x + invY * worldAxes.x.y
        let localY = invX * worldAxes.y.x + invY * worldAxes.y.y

        guard let decomposed = MatrixUtilities.decomposeTransform(
            xAxis: localX,
            yAxis: localY,
            preservedSkewYDegrees: image.skew.y
        ) else {
            // Degenerate bone matrix — fall back to angle-only conversion.
            return SceneImageAnimationPose(
                position: SIMD2<Float>(local3.x, local3.y),
                scale: image.scale,
                rotation: image.rotation - (skeleton.worldRotation(for: boneID) ?? 0),
                skew: image.skew
            )
        }
        return SceneImageAnimationPose(
            position: SIMD2<Float>(local3.x, local3.y),
            scale: decomposed.scale,
            rotation: decomposed.rotationRadians,
            skew: decomposed.skewDegrees
        )
    }

    private func syncImageBasePoseToVisiblePose(imageIndex: Int, relativeTo boneID: UUID?) {
        let localPose = localSpritePose(for: images[imageIndex], relativeTo: boneID)
        images[imageIndex].basePosition = localPose.position
        images[imageIndex].baseScale = localPose.scale
        images[imageIndex].baseRotation = localPose.rotation
        images[imageIndex].baseSkew = localPose.skew
    }

    private func syncImageSetupPoseFromVisiblePose(imageIndex: Int) {
        guard !isAnimationEditingEnabled else { return }
        let boneID = images[imageIndex].boneBinding?.boneID
        if boneID == nil {
            syncImageBasePoseToVisiblePose(imageIndex: imageIndex, relativeTo: nil)
            return
        }

        let localPose = localSpritePose(for: images[imageIndex], relativeTo: boneID)
        images[imageIndex].boneBinding?.localPosition = localPose.position
        images[imageIndex].boneBinding?.localScale = localPose.scale
        images[imageIndex].boneBinding?.localRotation = localPose.rotation
        images[imageIndex].boneBinding?.localSkew = localPose.skew
    }

    private func ensureImageAnimationSpaceConsistency(imageIndex: Int) {
        let expectedSpace: TransformAnimationSpace
        if let boneID = images[imageIndex].boneBinding?.boneID {
            expectedSpace = .boneLocal(boneID)
        } else {
            expectedSpace = .world
        }

        guard images[imageIndex].animationTransformSpace != expectedSpace else { return }
        convertImageAnimationSpace(
            imageIndex: imageIndex,
            from: images[imageIndex].animationTransformSpace.boneID,
            to: expectedSpace.boneID
        )
        images[imageIndex].animationTransformSpace = expectedSpace
    }

    private func convertPosition(_ position: SIMD2<Float>, from sourceBoneID: UUID?, to targetBoneID: UUID?) -> SIMD2<Float> {
        let worldPosition: SIMD2<Float>
        if let sourceBoneID,
           let worldMatrix = skeleton.worldMatrix(for: sourceBoneID) {
            let worldPoint = MatrixUtilities.transformPoint(SIMD3<Float>(position.x, position.y, 0), with: worldMatrix)
            worldPosition = SIMD2<Float>(worldPoint.x, worldPoint.y)
        } else {
            worldPosition = position
        }
        return skeleton.localPoint(worldPosition, relativeTo: targetBoneID)
    }

    private func convertRotation(_ rotation: Float, from sourceBoneID: UUID?, to targetBoneID: UUID?) -> Float {
        let worldRotation = rotation + (sourceBoneID.flatMap { skeleton.worldRotation(for: $0) } ?? 0)
        return worldRotation - (targetBoneID.flatMap { skeleton.worldRotation(for: $0) } ?? 0)
    }

    /// Applies bone → sprite bindings by composing the sprite's local affine
    /// with the bone's world affine and decomposing the result *exactly* back
    /// into position / rotation / scale / skew (the parametrization the render
    /// path consumes). The sprite inherits the
    /// bone's full transform — rotation, scale, flip, and shear — with no
    /// sliding, drifting, or scale loss. When the bone is rigid (scale 1, no
    /// shear) the result is identical to plain `localRotation + boneRotation`.
    /// Last world rotation emitted per bound image — transient editor state
    /// used only to unwrap atan2 results so the visible angle stays
    /// continuous while a bone sweeps across ±180°. Never persisted.
    private var lastBoundImageRotation: [UUID: Float] = [:]

    /// Places every bound sprite on its bone, IN THE ARRAY THE POSE PASS IS
    /// ALREADY HOLDING.
    ///
    /// It used to take its own copy of `images` and assign it back, so a
    /// playback frame copied the whole sprite array twice and announced it
    /// twice. The bindings need the pose, so they were always going to be the
    /// same walk over the same array; being a separate function is no reason to
    /// be a separate pass.
    /// - Parameter sampleClips: whether a bound sprite's own clip is
    ///   sampled for its bone-local pose. False in Setup mode, where the
    ///   binding's stored local pose IS the answer.
    ///
    ///   This is the same leak as the one `applyAnimations` decides at the
    ///   top, one level down: placing a bound sprite on its bone is structure
    ///   and belongs in both modes, but the pose it is placed AT was being
    ///   read from the clip whatever the mode. A bound sprite with keys showed
    ///   its animated offset in Editor while an unbound one beside it did not.
    private func applyBoneBindings(to bound: inout [SceneImage], time: Float,
                                   sampleClips: Bool) {
        let hasBindings = bound.contains { $0.boneBinding != nil }
        guard hasBindings else {
            if !lastBoundImageRotation.isEmpty { lastBoundImageRotation.removeAll() }
            return
        }
        // One matrix pass per frame instead of two full skeleton evaluations
        // per bound image.
        //
        // OBSERVING the physics simulation, never advancing it. The render loop
        // steps it once per presented frame (`MetalRenderer.draw(in:)` ->
        // `skeleton.worldMatrices()`), and this pass runs in the same frame; a
        // second step would run the simulation's clock twice per frame. It is
        // the same rule the Scene evaluator already follows, and it is written
        // on `worldMatrices(steppingPhysics:)`.
        //
        // It matters more now than it did: this used to run once per CLIP
        // frame and now runs once per DISPLAY frame, so a double step would
        // have gone from occasional to constant.
        //
        // The frame's ONE solve. The renderer asks for the same thing a moment
        // later for its own use; between the two, nothing writes the skeleton,
        // so the second ask is a dictionary read.
        let worldMatrices = frameWorldMatrices()

        for index in bound.indices {
            guard let binding = bound[index].boneBinding,
                  let worldMatrix = worldMatrices[binding.boneID] else {
                continue
            }
            let localPose = sampleClips
                ? bound[index].animationClip.pose(
                    for: bound[index].id,
                    basePose: binding.localPose,
                    time: time)
                : binding.localPose

            let world = Self.boundImagePose(localPose: localPose, worldMatrix: worldMatrix)
            bound[index].position = world.position
            bound[index].scale = world.scale
            bound[index].skew = world.skew

            var rotation = world.rotation
            // Unwrap toward the previous frame's emitted rotation so the
            // visible angle never jumps by 2π while a bone sweeps across
            // the ±180° boundary. Live-canvas continuity only: a static sample
            // (the Scene evaluator) has no previous frame to unwrap toward, and
            // an angle off by 2π draws identically.
            if let previous = lastBoundImageRotation[bound[index].id] {
                let twoPi = Float.pi * 2
                rotation += (twoPi * ((previous - rotation) / twoPi).rounded())
            }
            lastBoundImageRotation[bound[index].id] = rotation
            bound[index].rotation = rotation
        }
    }

    /// A bound sprite's world pose: the bone's world matrix applied to the
    /// sprite's local pose, decomposed back into the sprite transform convention.
    ///
    /// Extracted from `applyBoneBindings` so the Scene evaluator samples through
    /// the SAME math as the live canvas — two transcriptions of a decompose is
    /// how the three world-to-screen copies came to disagree.
    static func boundImagePose(
        localPose: SceneImageAnimationPose,
        worldMatrix: simd_float4x4
    ) -> SceneImageAnimationPose {
        // Sprite position: bone world matrix applied to the local anchor.
        let localPoint = SIMD3<Float>(localPose.position.x, localPose.position.y, 0)
        let worldPoint = MatrixUtilities.transformPoint(localPoint, with: worldMatrix)
        let position = SIMD2<Float>(worldPoint.x, worldPoint.y)

        // Sprite basis: bone 2×2 linear part × local sprite axes.
        let boneX = SIMD2<Float>(worldMatrix.columns.0.x, worldMatrix.columns.0.y)
        let boneY = SIMD2<Float>(worldMatrix.columns.1.x, worldMatrix.columns.1.y)
        let localAxes = MatrixUtilities.shearedAxes(
            rotationDegrees: localPose.rotation * 180 / .pi,
            shear: localPose.skew,
            scale: localPose.scale
        )
        let worldX = boneX * localAxes.x.x + boneY * localAxes.x.y
        let worldY = boneX * localAxes.y.x + boneY * localAxes.y.y

        guard let decomposed = MatrixUtilities.decomposeTransform(
            xAxis: worldX,
            yAxis: worldY,
            preservedSkewYDegrees: localPose.skew.y
        ) else {
            // Degenerate bone scale — keep the local pose rather than
            // producing NaNs.
            return SceneImageAnimationPose(
                position: position,
                scale: localPose.scale,
                rotation: localPose.rotation,
                skew: localPose.skew
            )
        }

        return SceneImageAnimationPose(
            position: position,
            scale: decomposed.scale,
            rotation: decomposed.rotationRadians,
            skew: decomposed.skewDegrees
        )
    }
}

// MARK: - Constraint & draw order animation
//
// Constraint properties and draw order are animated through `sceneAnimationClip`,
// a single clip whose tracks are keyed by target ID: a constraint's UUID for
// constraint properties, and `SceneAnimationTarget.drawOrder` for draw order.
//
// The authored values stay on the constraint structs themselves. `constraintSetupValues`
// only records the authored value of properties that have become animated, so
// leaving Animate mode (or deleting a track) restores exactly what the artist set
// up — and so that manual edits made outside this API are never clobbered.
extension SceneManager {

    // MARK: Evaluation

    /// Push the current frame's constraint values onto the live constraint
    /// structs. In Setup mode the authored values are restored instead, which is
    /// what makes the Setup/Animate toggle non-destructive.
    func applyConstraintAnimations(time: Float) {
        let animatedIDs = sceneAnimationClip.animatedTargetIDs
        guard !animatedIDs.isEmpty else { return }

        if isAnimationEditingEnabled {
            let sampled = constraintSampledSkeleton(from: skeleton, atTime: time)
            if sampled.didChange { skeleton = sampled.skeleton }
            return
        }

        // Setup mode: show the authored value on every animated property, so
        // the Setup/Animate toggle behaves the way this class of editor's does.
        var working = skeleton
        var didWrite = false
        for constraintID in animatedIDs where constraintID != SceneAnimationTarget.drawOrder {
            guard working.constraintKind(for: constraintID) != nil else { continue }
            guard let setup = constraintSetupValues[constraintID] else { continue }

            for property in working.animatableProperties(forConstraint: constraintID) {
                guard sceneAnimationClip.hasTrack(for: constraintID, property: property) else { continue }
                didWrite = true
                switch property.valueKind {
                case .scalar:
                    if let value = setup.scalar(property) {
                        working.setConstraintScalar(constraintID, property, value)
                    }
                case .flag:
                    if let value = setup.flag(property) {
                        working.setConstraintFlag(constraintID, property, value)
                    }
                case .vector2:
                    if let value = setup.vector(property) {
                        working.setConstraintVector(constraintID, property, value)
                    }
                case .deform, .drawOrder, .event, .attachment:
                    break
                }
            }
        }
        if didWrite { skeleton = working }
    }

    /// Constraint tracks sampled at a frame, onto a copy.
    ///
    /// The playback half of `applyConstraintAnimations`, split out so the Scene
    /// evaluator and the live path sample through the same code. Reads
    /// `sceneAnimationClip` and `constraintSetupValues`; mutates nothing.
    func constraintSampledSkeleton(
        from base: Skeleton,
        atFrame frame: Int
    ) -> (skeleton: Skeleton, didChange: Bool) {
        constraintSampledSkeleton(from: base, atTime: Float(frame))
    }

    func constraintSampledSkeleton(
        from base: Skeleton,
        atTime time: Float
    ) -> (skeleton: Skeleton, didChange: Bool) {
        var working = base
        var didWrite = false
        let animatedIDs = sceneAnimationClip.animatedTargetIDs

        for constraintID in animatedIDs where constraintID != SceneAnimationTarget.drawOrder {
            guard working.constraintKind(for: constraintID) != nil else { continue }
            let setup = constraintSetupValues[constraintID]

            for property in working.animatableProperties(forConstraint: constraintID) {
                guard sceneAnimationClip.hasTrack(for: constraintID, property: property) else { continue }
                didWrite = true

                switch property.valueKind {
                case .scalar:
                    let fallback = setup?.scalar(property)
                        ?? working.constraintScalar(constraintID, property)
                        ?? property.neutralValue
                    let sampled = sceneAnimationClip.evaluatedScalar(
                        for: constraintID,
                        property: property,
                        time: time,
                        fallback: fallback
                    )
                    working.setConstraintScalar(constraintID, property, property.clamped(sampled))
                case .flag:
                    let fallback = setup?.flag(property)
                        ?? working.constraintFlag(constraintID, property)
                        ?? false
                    let sampled = sceneAnimationClip.evaluatedFlag(
                        for: constraintID,
                        property: property,
                        time: time,
                        fallback: fallback
                    )
                    working.setConstraintFlag(constraintID, property, sampled)
                case .vector2:
                    let fallback = setup?.vector(property)
                        ?? working.constraintVector(constraintID, property)
                        ?? .zero
                    let sampled = sceneAnimationClip.evaluatedVector2(
                        for: constraintID,
                        property: property,
                        time: time,
                        fallback: fallback
                    )
                    working.setConstraintVector(constraintID, property, sampled)
                case .deform, .drawOrder, .event, .attachment:
                    break
                }
            }
        }
        return (working, didWrite)
    }

    /// Resolve the draw order for the current frame. Stepped by definition: the
    /// order is whatever the most recent key at or before the playhead says.
    func applyDrawOrderAnimation(time: Float) {
        guard isAnimationEditingEnabled,
              sceneAnimationClip.hasTrack(for: SceneAnimationTarget.drawOrder, property: .drawOrder),
              let order = sceneAnimationClip.evaluatedDrawOrder(time: time) else {
            if animatedDrawOrder != nil { animatedDrawOrder = nil }
            return
        }
        if animatedDrawOrder != order { animatedDrawOrder = order }
    }

    /// Which attachment each keyed slot shows at the playhead.
    ///
    /// Stepped, and not by convention: `AnimationTrackProperty.attachment`
    /// declares `forcesSteppedInterpolation`, and `Keyframe.init` holds any
    /// attachment payload, so there is no path by which a half-swapped PNG can
    /// be asked for.
    func applyAttachmentAnimations(time: Float) {
        // The only one of these that had no mode guard whatsoever, so an
        // attachment key hid and showed sprites in Editor. Cleared rather than
        // skipped: skipping would leave the last animated swap standing.
        guard isAnimationEditingEnabled else {
            if !animatedAttachments.isEmpty { animatedAttachments = [:] }
            return
        }
        var resolved: [String: UUID?] = [:]
        for slotName in slotNames {
            let target = SlotAnimationTarget.id(forSlotNamed: slotName)
            guard sceneAnimationClip.hasTrack(for: target, property: .attachment) else {
                continue
            }
            // Binary search, not filter-then-sort. The list is already sorted
            // by frame, and this runs per slot on every displayed frame: the
            // old form allocated two arrays per slot per frame to find one
            // element that a bisection finds without touching the heap.
            let keys = sceneAnimationClip.keyframes(for: target, property: .attachment)
            let span = AnimationClip.keyframeSpan(keys, time: time)
            guard let index = span.exact ?? span.previous,
                  case let .attachment(id) = keys[index].value else {
                continue
            }
            resolved[slotName] = id
        }
        if animatedAttachments != resolved { animatedAttachments = resolved }
    }

    /// Every slot name in the rig, in first-appearance order.
    ///
    /// A list, not a Set: iterating a Swift dictionary is not stable between
    /// launches, and a slot's row in the timeline must not move on its own.
    var slotNames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for image in images {
            let name = image.effectiveSlotName
            if seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    /// The sprites that share a slot — its attachments.
    func attachments(inSlot slotName: String) -> [SceneImage] {
        images.filter { $0.effectiveSlotName == slotName }
    }

    /// Sprites hidden this frame because another attachment holds their slot.
    ///
    /// Merged into the same set the skins use, so there is ONE answer to "is
    /// this sprite drawn". A second hidden-set is a second way for two
    /// attachments to end up on screen at once, which is the whole failure
    /// this feature exists to prevent.
    var attachmentHiddenImageIDs: Set<UUID> {
        guard !animatedAttachments.isEmpty else { return [] }
        var hidden: Set<UUID> = []
        for (slotName, shown) in animatedAttachments {
            for image in images where image.effectiveSlotName == slotName {
                if image.id != shown { hidden.insert(image.id) }
            }
        }
        return hidden
    }

    /// Drop tracks whose owner no longer exists, so deleting a constraint or a
    /// sprite cannot leave orphan rows in the timeline or stale keys in a save.
    func pruneSceneAnimationTracks() {
        let liveImageIDs = Set(images.map(\.id))
        var clip = sceneAnimationClip
        var didChange = false

        clip.tracks.removeAll { track in
            if track.property.domain == .scene { return false }
            let alive = skeleton.constraintKind(for: track.targetID) != nil
            if !alive { didChange = true }
            return !alive
        }

        // A draw order key that references sprites which no longer exist is
        // rewritten rather than dropped, so the rest of the ordering survives.
        for trackIndex in clip.tracks.indices where clip.tracks[trackIndex].property == .drawOrder {
            for keyIndex in clip.tracks[trackIndex].keyframes.indices {
                guard let order = clip.tracks[trackIndex].keyframes[keyIndex].value.drawOrderValue else { continue }
                let filtered = order.filter { liveImageIDs.contains($0) }
                if filtered.count != order.count {
                    clip.tracks[trackIndex].keyframes[keyIndex].value = .drawOrder(filtered)
                    didChange = true
                }
            }
        }

        let liveConstraintIDs = Set(skeleton.constraintDirectory.map(\.id))
        let staleSetup = constraintSetupValues.keys.filter { !liveConstraintIDs.contains($0) }
        if !staleSetup.isEmpty {
            for id in staleSetup { constraintSetupValues.removeValue(forKey: id) }
        }

        if didChange { sceneAnimationClip = clip }
    }

    // MARK: Setup capture

    /// Record a constraint's authored values the first time one of its
    /// properties is keyed. Idempotent: an existing record is never overwritten,
    /// otherwise an animated value would be mistaken for the setup pose.
    func ensureConstraintSetupCaptured(_ constraintID: UUID) {
        guard constraintSetupValues[constraintID] == nil,
              skeleton.constraintKind(for: constraintID) != nil else { return }
        constraintSetupValues[constraintID] = skeleton.captureConstraintSetupValues(constraintID)
    }

    /// Refresh the authored value of one property. Called when the artist edits
    /// a constraint in Setup mode while the property is already animated.
    func updateConstraintSetupValue(_ constraintID: UUID, _ property: AnimationTrackProperty) {
        guard skeleton.constraintKind(for: constraintID) != nil else { return }
        var record = constraintSetupValues[constraintID] ?? ConstraintSetupValues()
        switch property.valueKind {
        case .scalar:
            if let value = skeleton.constraintScalar(constraintID, property) { record.set(property, scalar: value) }
        case .flag:
            if let value = skeleton.constraintFlag(constraintID, property) { record.set(property, flag: value) }
        case .vector2:
            if let value = skeleton.constraintVector(constraintID, property) { record.set(property, vector: value) }
        case .deform, .drawOrder, .event, .attachment:
            return
        }
        constraintSetupValues[constraintID] = record
    }

    // MARK: Queries used by the inspector and the timeline

    func isConstraintPropertyAnimated(_ constraintID: UUID, _ property: AnimationTrackProperty) -> Bool {
        sceneAnimationClip.hasTrack(for: constraintID, property: property)
    }

    /// True when a key sits exactly on the playhead, so the inspector can draw a
    /// filled key icon instead of a hollow one.
    func constraintPropertyHasKeyAtPlayhead(_ constraintID: UUID, _ property: AnimationTrackProperty) -> Bool {
        sceneAnimationClip
            .keyframes(for: constraintID, property: property)
            .contains { $0.frame == currentFrame }
    }

    /// Put every constraint back to its authored values. Used when switching
    /// named animations, where the outgoing animation may have driven properties
    /// the incoming one never touches.
    func restoreAllConstraintSetupValues() {
        guard !constraintSetupValues.isEmpty else { return }
        var working = skeleton
        for (constraintID, record) in constraintSetupValues {
            guard working.constraintKind(for: constraintID) != nil else { continue }
            working.applyConstraintSetupValues(constraintID, record)
        }
        skeleton = working
    }

    /// Install a different set of scene-wide timelines wholesale. Used by the
    /// animation library when the artist switches animations.
    func replaceSceneAnimation(clip: AnimationClip, constraintSetupValues values: [UUID: ConstraintSetupValues]) {
        sceneAnimationClip = clip
        constraintSetupValues = values
        animatedDrawOrder = nil
        pruneSceneAnimationTracks()
        applyAnimations()
    }

    /// Any animated property at all on this constraint.
    func hasAnyConstraintTrack(_ constraintID: UUID) -> Bool {
        skeleton.animatableProperties(forConstraint: constraintID)
            .contains { sceneAnimationClip.hasTrack(for: constraintID, property: $0) }
    }

    /// Delete every timeline belonging to a constraint and restore its authored
    /// values. Used by the inspector's "clear animation" affordance and when a
    /// constraint is deleted.
    func removeAllConstraintTracks(_ constraintID: UUID) {
        guard hasAnyConstraintTrack(constraintID) else { return }
        pushUndoState()
        for property in skeleton.animatableProperties(forConstraint: constraintID) {
            let keys = sceneAnimationClip.keyframes(for: constraintID, property: property)
            guard !keys.isEmpty else { continue }
            sceneAnimationClip.deleteKeyframes(
                targetID: constraintID,
                property: property,
                keyframeIDs: Set(keys.map(\.id))
            )
            restoreConstraintSetupValue(constraintID, property)
        }
        applyAnimations()
        objectWillChange.send()
    }

    func hasDrawOrderTrack() -> Bool {
        sceneAnimationClip.hasTrack(for: SceneAnimationTarget.drawOrder, property: .drawOrder)
    }

    func drawOrderHasKeyAtPlayhead() -> Bool {
        sceneAnimationClip
            .keyframes(for: SceneAnimationTarget.drawOrder, property: .drawOrder)
            .contains { $0.frame == currentFrame }
    }

    func constraintScalarValue(_ constraintID: UUID, _ property: AnimationTrackProperty) -> Float {
        skeleton.constraintScalar(constraintID, property) ?? property.neutralValue
    }

    func constraintFlagValue(_ constraintID: UUID, _ property: AnimationTrackProperty) -> Bool {
        skeleton.constraintFlag(constraintID, property) ?? false
    }

    func constraintVectorValue(_ constraintID: UUID, _ property: AnimationTrackProperty) -> SIMD2<Float> {
        skeleton.constraintVector(constraintID, property) ?? .zero
    }

    // MARK: Editing

    /// Single entry point for every constraint scalar edit in the editor.
    ///
    /// In Animate mode the change is keyed on the playhead (auto-key).
    /// In Setup mode it rewrites the authored value, and also the setup record
    /// when the property is already animated, so returning to Animate mode does
    /// not resurrect the old authored value.
    func setConstraintScalar(
        _ constraintID: UUID,
        _ property: AnimationTrackProperty,
        _ value: Float,
        pushUndo: Bool = true
    ) {
        guard skeleton.constraintKind(for: constraintID) != nil,
              property.valueKind == .scalar else { return }
        if pushUndo { pushUndoState() }

        let clamped = property.clamped(value)
        skeleton.setConstraintScalar(constraintID, property, clamped)

        if isAnimationEditingEnabled {
            ensureConstraintSetupCaptured(constraintID)
            sceneAnimationClip.upsertKeyframe(
                targetID: constraintID,
                property: property,
                frame: currentFrame,
                value: .scalar(clamped)
            )
            selectKeyframe(constraintID, property, atFrame: currentFrame)
        } else if isConstraintPropertyAnimated(constraintID, property) {
            updateConstraintSetupValue(constraintID, property)
        }

        applyAnimations()
        objectWillChange.send()
    }

    func setConstraintFlag(
        _ constraintID: UUID,
        _ property: AnimationTrackProperty,
        _ value: Bool,
        pushUndo: Bool = true
    ) {
        guard skeleton.constraintKind(for: constraintID) != nil,
              property.valueKind == .flag else { return }
        if pushUndo { pushUndoState() }

        skeleton.setConstraintFlag(constraintID, property, value)

        if isAnimationEditingEnabled {
            ensureConstraintSetupCaptured(constraintID)
            sceneAnimationClip.upsertKeyframe(
                targetID: constraintID,
                property: property,
                frame: currentFrame,
                value: .flag(value)
            )
            selectKeyframe(constraintID, property, atFrame: currentFrame)
        } else if isConstraintPropertyAnimated(constraintID, property) {
            updateConstraintSetupValue(constraintID, property)
        }

        applyAnimations()
        objectWillChange.send()
    }

    func setConstraintVector(
        _ constraintID: UUID,
        _ property: AnimationTrackProperty,
        _ value: SIMD2<Float>,
        pushUndo: Bool = true
    ) {
        guard skeleton.constraintKind(for: constraintID) != nil,
              property.valueKind == .vector2 else { return }
        if pushUndo { pushUndoState() }

        skeleton.setConstraintVector(constraintID, property, value)

        if isAnimationEditingEnabled {
            ensureConstraintSetupCaptured(constraintID)
            sceneAnimationClip.upsertKeyframe(
                targetID: constraintID,
                property: property,
                frame: currentFrame,
                value: .vector2(value)
            )
            selectKeyframe(constraintID, property, atFrame: currentFrame)
        } else if isConstraintPropertyAnimated(constraintID, property) {
            updateConstraintSetupValue(constraintID, property)
        }

        applyAnimations()
        objectWillChange.send()
    }

    /// Explicit key button: writes a key at the playhead carrying the value the
    /// constraint currently holds, without changing that value.
    func keyConstraintProperty(_ constraintID: UUID, _ property: AnimationTrackProperty) {
        guard skeleton.constraintKind(for: constraintID) != nil else { return }
        pushUndoState()
        ensureConstraintSetupCaptured(constraintID)

        let value: KeyframeValue
        switch property.valueKind {
        case .scalar:
            value = .scalar(property.clamped(constraintScalarValue(constraintID, property)))
        case .flag:
            value = .flag(constraintFlagValue(constraintID, property))
        case .vector2:
            value = .vector2(constraintVectorValue(constraintID, property))
        case .deform, .drawOrder, .event, .attachment:
            return
        }

        sceneAnimationClip.upsertKeyframe(
            targetID: constraintID,
            property: property,
            frame: currentFrame,
            value: value
        )
        selectKeyframe(constraintID, property, atFrame: currentFrame)
        applyAnimations()
        objectWillChange.send()
    }

    /// Remove just the key sitting on the playhead. When it was the last key of
    /// the track, the property reverts to its authored value.
    func removeConstraintKeyAtPlayhead(_ constraintID: UUID, _ property: AnimationTrackProperty) {
        let keys = sceneAnimationClip.keyframes(for: constraintID, property: property)
        guard let key = keys.first(where: { $0.frame == currentFrame }) else { return }
        pushUndoState()
        sceneAnimationClip.deleteKeyframes(
            targetID: constraintID,
            property: property,
            keyframeIDs: [key.id]
        )
        if !isConstraintPropertyAnimated(constraintID, property) {
            restoreConstraintSetupValue(constraintID, property)
        }
        applyAnimations()
        objectWillChange.send()
    }

    /// Delete a constraint property's whole timeline and put the authored value
    /// back on the constraint.
    func removeConstraintPropertyTrack(_ constraintID: UUID, _ property: AnimationTrackProperty) {
        let keys = sceneAnimationClip.keyframes(for: constraintID, property: property)
        guard !keys.isEmpty else { return }
        pushUndoState()
        sceneAnimationClip.deleteKeyframes(
            targetID: constraintID,
            property: property,
            keyframeIDs: Set(keys.map(\.id))
        )
        restoreConstraintSetupValue(constraintID, property)
        applyAnimations()
        objectWillChange.send()
    }

    func restoreConstraintSetupValue(_ constraintID: UUID, _ property: AnimationTrackProperty) {
        guard let record = constraintSetupValues[constraintID] else { return }
        switch property.valueKind {
        case .scalar:
            if let value = record.scalar(property) { skeleton.setConstraintScalar(constraintID, property, value) }
        case .flag:
            if let value = record.flag(property) { skeleton.setConstraintFlag(constraintID, property, value) }
        case .vector2:
            if let value = record.vector(property) { skeleton.setConstraintVector(constraintID, property, value) }
        case .deform, .drawOrder, .event, .attachment:
            break
        }
    }

    // MARK: Draw order keys

    /// Key the current authored order of `images` at the playhead. This is the
    /// draw order equivalent of pressing the key icon on a transform property.
    func keyDrawOrder() {
        guard !images.isEmpty else { return }
        pushUndoState()
        sceneAnimationClip.upsertKeyframe(
            targetID: SceneAnimationTarget.drawOrder,
            property: .drawOrder,
            frame: currentFrame,
            value: .drawOrder(images.map(\.id))
        )
        selectKeyframe(SceneAnimationTarget.drawOrder, .drawOrder, atFrame: currentFrame)
        applyAnimations()
        objectWillChange.send()
    }

    /// Key an explicit order, used when the artist reorders sprites while the
    /// playhead sits on an existing draw order key.
    func keyDrawOrder(_ order: [UUID]) {
        pushUndoState()
        sceneAnimationClip.upsertKeyframe(
            targetID: SceneAnimationTarget.drawOrder,
            property: .drawOrder,
            frame: currentFrame,
            value: .drawOrder(order)
        )
        selectKeyframe(SceneAnimationTarget.drawOrder, .drawOrder, atFrame: currentFrame)
        applyAnimations()
        objectWillChange.send()
    }

    func removeDrawOrderKeyAtPlayhead() {
        let keys = sceneAnimationClip.keyframes(for: SceneAnimationTarget.drawOrder, property: .drawOrder)
        guard let key = keys.first(where: { $0.frame == currentFrame }) else { return }
        pushUndoState()
        sceneAnimationClip.deleteKeyframes(
            targetID: SceneAnimationTarget.drawOrder,
            property: .drawOrder,
            keyframeIDs: [key.id]
        )
        applyAnimations()
        objectWillChange.send()
    }

    func removeDrawOrderTrack() {
        let keys = sceneAnimationClip.keyframes(for: SceneAnimationTarget.drawOrder, property: .drawOrder)
        guard !keys.isEmpty else { return }
        pushUndoState()
        sceneAnimationClip.deleteKeyframes(
            targetID: SceneAnimationTarget.drawOrder,
            property: .drawOrder,
            keyframeIDs: Set(keys.map(\.id))
        )
        animatedDrawOrder = nil
        applyAnimations()
        objectWillChange.send()
    }

    // MARK: Shared helpers

    private func selectKeyframe(_ targetID: UUID, _ property: AnimationTrackProperty, atFrame frame: Int) {
        guard let keyframe = sceneAnimationClip
            .keyframes(for: targetID, property: property)
            .first(where: { $0.frame == frame }) else { return }
        let selection = SelectedKeyframe(imageID: targetID, property: property, keyframeID: keyframe.id)
        selectedKeyframes = [selection]
        selectedKeyframe = selection
    }
}

// MARK: - Skins
//
// Slots are derived from the sprites themselves: every sprite carries a slot
// name, and sprites sharing one are variants of the same attachment point. A
// skin then records which variant each slot shows. Slots are not a separate
// entity to create and manage, so a plain rig needs no setup at all — it simply
// has one sprite per slot and no skin has anything to override.
extension SceneManager {

    /// Slot name → every sprite that can occupy it, in authored draw order.
    var slotMembers: [String: [UUID]] {
        var out: [String: [UUID]] = [:]
        for image in images {
            out[image.effectiveSlotName, default: []].append(image.id)
        }
        return out
    }

    /// Slots that hold more than one sprite, i.e. the real variant points. These
    /// are the only slots worth showing in the skin editor.
    var variantSlotNames: [String] {
        slotMembers.filter { $0.value.count > 1 }.keys.sorted()
    }

    /// Every slot name in the project, sorted.
    var allSlotNames: [String] {
        slotMembers.keys.sorted()
    }

    /// What each slot shows when no skin is active: the first sprite the artist
    /// has not hidden, falling back to the first member so a slot whose sprites
    /// are all hidden still resolves to something stable.
    private var setupAttachments: [String: UUID?] {
        var out: [String: UUID?] = [:]
        for (slot, members) in slotMembers {
            let visible = members.first { id in
                images.first(where: { $0.id == id })?.isHidden == false
            }
            out.updateValue(visible ?? members.first, forKey: slot)
        }
        return out
    }

    var activeSkin: Skin? {
        guard let activeSkinID else { return nil }
        return skins.first(where: { $0.id == activeSkinID })
    }

    /// Recompute which sprites the active skin displaces. Cheap, but only worth
    /// running when skins, slots or the sprite list actually change.
    func refreshSkinResolution() {
        let resolved = SkinResolver.resolve(
            activeSkinID: activeSkinID,
            skins: skins,
            slotMembers: slotMembers,
            setupAttachments: setupAttachments
        )
        if resolved != skinResolution {
            skinResolution = resolved
        }
    }

    /// True when the active skin displaces this sprite. Distinct from the
    /// artist's own hide toggle, which stays in `SceneImage.isHidden`.
    func isHiddenByActiveSkin(_ imageID: UUID) -> Bool {
        skinResolution.hiddenImageIDs.contains(imageID)
    }

    // MARK: Slot editing

    /// Move a sprite into a slot. Passing an empty name detaches it, so it
    /// stands alone under its own name again.
    func setSlotName(_ slotName: String, for imageID: UUID) {
        guard let index = images.firstIndex(where: { $0.id == imageID }) else { return }
        let trimmed = slotName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard images[index].slotName != trimmed else { return }
        pushUndoState()
        images[index].slotName = trimmed
        refreshSkinResolution()
    }

    /// Group several sprites into one slot in a single undoable step, which is
    /// how a variant point is normally created.
    func assignSlot(_ slotName: String, to imageIDs: [UUID]) {
        let trimmed = slotName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !imageIDs.isEmpty else { return }
        pushUndoState()
        for imageID in imageIDs {
            guard let index = images.firstIndex(where: { $0.id == imageID }) else { continue }
            images[index].slotName = trimmed
        }
        refreshSkinResolution()
    }

    /// Rename a slot everywhere it appears, keeping every skin pointing at it.
    func renameSlot(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        pushUndoState()
        for index in images.indices where images[index].effectiveSlotName == oldName {
            images[index].slotName = trimmed
        }
        for skinIndex in skins.indices {
            if let value = skins[skinIndex].attachments.removeValue(forKey: oldName) {
                // `value` is `UUID?` and may legitimately be nil (empty slot);
                // updateValue preserves that instead of dropping the entry.
                skins[skinIndex].attachments.updateValue(value, forKey: trimmed)
            }
        }
        refreshSkinResolution()
    }

    // MARK: Skin CRUD

    @discardableResult
    func createSkin(named requestedName: String? = nil, activate: Bool = true) -> UUID {
        pushUndoState()
        let name = uniqueSkinName(requestedName ?? "Skin")
        let skin = Skin(name: name)
        skins.append(skin)
        if activate { activeSkinID = skin.id } else { refreshSkinResolution() }
        return skin.id
    }

    /// Duplicate a skin including its attachment choices and inclusions.
    @discardableResult
    func duplicateSkin(_ id: UUID) -> UUID? {
        guard let index = skins.firstIndex(where: { $0.id == id }) else { return nil }
        pushUndoState()
        let source = skins[index]
        let copy = Skin(
            name: uniqueSkinName("\(source.name) copy"),
            attachments: source.attachments,
            includedSkinIDs: source.includedSkinIDs
        )
        skins.insert(copy, at: index + 1)
        activeSkinID = copy.id
        return copy.id
    }

    func renameSkin(_ id: UUID, to newName: String) {
        guard let index = skins.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != skins[index].name else { return }
        pushUndoState()
        skins[index].name = uniqueSkinName(trimmed, excluding: id)
    }

    func deleteSkin(_ id: UUID) {
        guard skins.contains(where: { $0.id == id }) else { return }
        pushUndoState()
        skins.removeAll { $0.id == id }
        // Any skin that included the deleted one must forget it, otherwise the
        // resolver would keep walking a dangling reference.
        for index in skins.indices {
            skins[index].includedSkinIDs.removeAll { $0 == id }
        }
        if activeSkinID == id {
            activeSkinID = nil
        } else {
            refreshSkinResolution()
        }
    }

    func setActiveSkin(_ id: UUID?) {
        guard activeSkinID != id else { return }
        activeSkinID = id
    }

    private func uniqueSkinName(_ requested: String, excluding: UUID? = nil) -> String {
        let taken = Set(skins.filter { $0.id != excluding }.map(\.name))
        guard taken.contains(requested) else { return requested }
        var suffix = 2
        while taken.contains("\(requested) \(suffix)") { suffix += 1 }
        return "\(requested) \(suffix)"
    }

    // MARK: Attachment editing

    /// Point a slot at a sprite in the given skin. `nil` empties the slot,
    /// which is different from clearing the entry entirely.
    /// Show an attachment in a slot — the one verb the artist uses.
    ///
    /// What it MEANS depends on the mode:
    ///
    /// * In Editor it edits the active skin, because that is what a skin is:
    ///   the setup-time choice of which sprite occupies a slot.
    /// * In Animator it keys the attachment timeline at the playhead, because
    ///   an animation is a sequence of those choices over time.
    ///
    /// One verb with two meanings is better than two verbs the artist has to
    /// choose between, and it is the difference between a feature and a
    /// workflow.
    func showAttachment(slot slotName: String, imageID: UUID?) {
        guard !slotName.isEmpty else { return }
        if isAnimationEditingEnabled {
            keyAttachment(slot: slotName, imageID: imageID)
            return
        }
        guard let skinID = activeSkinID else { return }
        setSkinAttachment(skinID: skinID, slot: slotName, imageID: imageID)
    }

    /// Key which attachment a slot shows, at the playhead.
    func keyAttachment(slot slotName: String, imageID: UUID?) {
        guard !slotName.isEmpty else { return }
        pushUndoState()
        sceneAnimationClip.upsertKeyframe(
            targetID: SlotAnimationTarget.id(forSlotNamed: slotName),
            property: .attachment,
            frame: currentFrame,
            value: .attachment(imageID),
            interpolation: .hold
        )
        applyAnimations()
    }

    /// Whether this slot is keyed at the playhead, for the key button's state.
    func attachmentHasKeyAtPlayhead(slot slotName: String) -> Bool {
        sceneAnimationClip
            .keyframes(for: SlotAnimationTarget.id(forSlotNamed: slotName),
                       property: .attachment)
            .contains { $0.frame == currentFrame }
    }

    /// Remove this slot's key at the playhead, leaving the previous one — or
    /// the skin, if it was the only one — in charge again.
    func removeAttachmentKeyAtPlayhead(slot slotName: String) {
        let target = SlotAnimationTarget.id(forSlotNamed: slotName)
        let keys = sceneAnimationClip.keyframes(for: target, property: .attachment)
        guard let key = keys.first(where: { $0.frame == currentFrame }) else { return }
        pushUndoState()
        sceneAnimationClip.deleteKeyframes(targetID: target, property: .attachment,
                                           keyframeIDs: [key.id])
        applyAnimations()
    }

    /// Which sprite the slot shows right now, whatever decided it.
    func shownAttachment(inSlot slotName: String) -> UUID? {
        if let keyed = animatedAttachments[slotName] { return keyed }
        if let fromSkin = skinResolution.slots[slotName] { return fromSkin }
        return attachments(inSlot: slotName).first?.id
    }

    func setSkinAttachment(skinID: UUID, slot: String, imageID: UUID?) {
        guard let index = skins.firstIndex(where: { $0.id == skinID }) else { return }
        pushUndoState()
        skins[index].setAttachment(imageID, for: slot)
        refreshSkinResolution()
    }

    /// Remove the skin's opinion about a slot, letting it fall through to the
    /// skins it includes and finally to the setup arrangement.
    func clearSkinAttachment(skinID: UUID, slot: String) {
        guard let index = skins.firstIndex(where: { $0.id == skinID }),
              skins[index].attachments[slot] != nil else { return }
        pushUndoState()
        skins[index].clearAttachment(for: slot)
        refreshSkinResolution()
    }

    /// Record the arrangement currently on screen into a skin, so an artist can
    /// pose the variants by eye and then capture them in one step.
    func captureCurrentArrangement(into skinID: UUID) {
        guard let index = skins.firstIndex(where: { $0.id == skinID }) else { return }
        pushUndoState()
        for (slot, members) in slotMembers where members.count > 1 {
            let shown = members.first { id in
                images.first(where: { $0.id == id })?.isHidden == false
                    && !isHiddenByActiveSkin(id)
            }
            skins[index].setAttachment(shown, for: slot)
        }
        refreshSkinResolution()
    }

    // MARK: Inclusion

    /// Make `skinID` build on `includedID`.
    ///
    /// Refuses to create a cycle: a skin may not include something that already
    /// leads back to it, which would make resolution order meaningless.
    @discardableResult
    func addSkinInclusion(skinID: UUID, includedID: UUID) -> Bool {
        guard skinID != includedID,
              let index = skins.firstIndex(where: { $0.id == skinID }),
              skins.contains(where: { $0.id == includedID }),
              !skins[index].includedSkinIDs.contains(includedID),
              !skinChainContains(start: includedID, target: skinID) else { return false }
        pushUndoState()
        skins[index].includedSkinIDs.append(includedID)
        refreshSkinResolution()
        return true
    }

    func removeSkinInclusion(skinID: UUID, includedID: UUID) {
        guard let index = skins.firstIndex(where: { $0.id == skinID }),
              skins[index].includedSkinIDs.contains(includedID) else { return }
        pushUndoState()
        skins[index].includedSkinIDs.removeAll { $0 == includedID }
        refreshSkinResolution()
    }

    /// True when walking inclusions from `start` reaches `target`.
    private func skinChainContains(start: UUID, target: UUID) -> Bool {
        var visited = Set<UUID>()
        var stack = [start]
        while let current = stack.popLast() {
            if current == target { return true }
            guard visited.insert(current).inserted,
                  let skin = skins.first(where: { $0.id == current }) else { continue }
            stack.append(contentsOf: skin.includedSkinIDs)
        }
        return false
    }

    /// Drop references to sprites that no longer exist. Called after deletions
    /// so a skin cannot point at a missing sprite.
    func pruneSkins() {
        let liveIDs = Set(images.map(\.id))
        var didChange = false
        for skinIndex in skins.indices {
            for (slot, imageID) in skins[skinIndex].attachments {
                guard let imageID, !liveIDs.contains(imageID) else { continue }
                skins[skinIndex].attachments.updateValue(nil, forKey: slot)
                didChange = true
            }
        }
        if didChange { refreshSkinResolution() }
    }
}

// MARK: - Mirroring
//
// Rigs are usually symmetrical, and the tedious half of weighting a character is
// redoing the work on the other side. These operations move weights and poses
// across the X axis, pairing bones by the naming convention every rig already
// uses (a trailing or embedded L/R, or "left"/"right").
extension SceneManager {

    /// Find the bone that mirrors `bone` by name.
    ///
    /// Recognises the conventions rigs actually use: `arm_L` ↔ `arm_R`,
    /// `L_arm` ↔ `R_arm`, `left arm` ↔ `right arm`. Case is preserved so a
    /// mirrored name matches the project's existing style. Returns nil when the
    /// bone has no side marker, which correctly leaves spine and head bones
    /// mapping to themselves.
    func mirroredBoneName(for name: String) -> String? {
        // Ordered longest-first so "left" is tried before a bare "l".
        let pairs: [(String, String)] = [
            ("left", "right"), ("Left", "Right"), ("LEFT", "RIGHT"),
            ("_l", "_r"), ("_L", "_R"),
            ("-l", "-r"), ("-L", "-R"),
            (".l", ".r"), (".L", ".R")
        ]
        for (a, b) in pairs {
            if name.contains(a) { return name.replacingOccurrences(of: a, with: b) }
            if name.contains(b) { return name.replacingOccurrences(of: b, with: a) }
        }
        return nil
    }

    /// Resolve the mirror partner of a bone, or nil when it sits on the axis.
    func mirroredBone(of boneID: UUID) -> UUID? {
        guard let bone = skeleton.bones[boneID],
              let partnerName = mirroredBoneName(for: bone.name),
              partnerName != bone.name else { return nil }
        return skeleton.orderedBones.first(where: { $0.name == partnerName })?.id
    }

    /// Mirror a mesh's vertex weights across a vertical axis.
    ///
    /// For each vertex, the weights of the vertex nearest its mirror position
    /// are copied over, with every bone swapped for its side partner. Vertices
    /// with no partner within `tolerance` are left untouched rather than being
    /// given a wrong neighbour's weights — silently pulling in the closest
    /// vertex regardless of distance is how mirrored weights end up subtly
    /// wrong in ways that are hard to spot later.
    ///
    /// - Parameters:
    ///   - axisX: mesh-space X the mirror reflects about.
    ///   - tolerance: how far a candidate may sit from the exact mirror point.
    /// - Returns: number of vertices actually mirrored.
    @discardableResult
    func mirrorMeshWeights(
        imageID: UUID,
        axisX: Float? = nil,
        tolerance: Float = 1.5
    ) -> Int {
        guard let imageIndex = images.firstIndex(where: { $0.id == imageID }) else { return 0 }
        let mesh = images[imageIndex].mesh
        let vertices = mesh.vertices
        guard !vertices.isEmpty, mesh.vertexBoneWeights.count == vertices.count else { return 0 }

        // Default axis is the mesh's own horizontal centre.
        let axis: Float
        if let axisX {
            axis = axisX
        } else {
            let xs = vertices.map(\.x)
            guard let lo = xs.min(), let hi = xs.max() else { return 0 }
            axis = (lo + hi) * 0.5
        }

        // Cache the bone partner lookup: it is name-based and would otherwise be
        // repeated once per influence per vertex.
        var partnerCache: [UUID: UUID?] = [:]
        func partner(_ boneID: UUID) -> UUID {
            if let cached = partnerCache[boneID] { return cached ?? boneID }
            let resolved = mirroredBone(of: boneID)
            partnerCache[boneID] = resolved
            return resolved ?? boneID
        }

        var updated = mesh.vertexBoneWeights
        var mirroredCount = 0

        for index in vertices.indices {
            let source = vertices[index]
            let mirrorPoint = SIMD2<Float>(2 * axis - source.x, source.y)

            var bestIndex: Int?
            var bestDistance = Float.greatestFiniteMagnitude
            for candidate in vertices.indices {
                let d = simd_distance(vertices[candidate], mirrorPoint)
                if d < bestDistance {
                    bestDistance = d
                    bestIndex = candidate
                }
            }

            guard let bestIndex, bestDistance <= tolerance else { continue }

            let sourceWeights = mesh.vertexBoneWeights[bestIndex]
            guard !sourceWeights.isEmpty else { continue }

            updated[index] = sourceWeights.map {
                VertexBoneWeight(boneID: partner($0.boneID), weight: $0.weight)
            }
            mirroredCount += 1
        }

        guard mirroredCount > 0 else { return 0 }

        pushUndoState()
        images[imageIndex].mesh.vertexBoneWeights = updated
        images[imageIndex].mesh = images[imageIndex].mesh.sanitizedSkinningData()
        applyAnimations()
        objectWillChange.send()
        return mirroredCount
    }

    /// Mirror the current pose of a bone onto its side partner: X position and
    /// rotation are reflected, Y and scale copied. Bones without a partner are
    /// skipped.
    ///
    /// - Returns: number of bones whose pose was written.
    @discardableResult
    func mirrorBonePose(_ boneIDs: [UUID]) -> Int {
        var written = 0
        var working = skeleton

        for boneID in boneIDs {
            guard let source = working.bones[boneID],
                  let partnerID = mirroredBone(of: boneID),
                  var target = working.bones[partnerID] else { continue }

            var pose = source.localTransform
            pose.position.x = -pose.position.x
            // Only the Z rotation is meaningful for a 2D mirror; X and Y stay as
            // authored so a 3D-tilted bone keeps its tilt.
            pose.rotation.z = -pose.rotation.z
            pose.skew.x = -pose.skew.x
            target.localTransform = pose
            working.bones[partnerID] = target
            written += 1
        }

        guard written > 0 else { return 0 }
        pushUndoState()
        skeleton = working
        applyAnimations()
        objectWillChange.send()
        return written
    }

    /// Flip a bone's pose in place, reflecting it about its own parent axis.
    /// Used for the single-bone "flip" that does not need a partner.
    func flipBonePose(_ boneID: UUID) {
        guard var bone = skeleton.bones[boneID] else { return }
        pushUndoState()
        bone.localTransform.position.x = -bone.localTransform.position.x
        bone.localTransform.rotation.z = -bone.localTransform.rotation.z
        bone.localTransform.skew.x = -bone.localTransform.skew.x
        skeleton.bones[boneID] = bone
        applyAnimations()
        objectWillChange.send()
    }
}

// MARK: - IK / Path / Physics constraint management
//
// Transform Constraints already had a full management API; the other three only
// had "create from selection", which is why their inspectors could show a
// constraint but never edit one. These bring them to parity: rename, duplicate,
// delete, reorder, retarget, and edit the bone lists.
extension SceneManager {

    // MARK: IK

    func renameIKConstraint(_ id: UUID, to newName: String) {
        guard let index = skeleton.ikConstraints.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != skeleton.ikConstraints[index].name else { return }
        pushUndoState()
        skeleton.ikConstraints[index].name = trimmed
    }

    func deleteIKConstraint(_ id: UUID) {
        guard skeleton.ikConstraints.contains(where: { $0.id == id }) else { return }
        pushUndoState()
        removeAllConstraintTracks(id)
        skeleton.ikConstraints.removeAll { $0.id == id }
        if selectedConstraintID == id { selectedConstraintID = nil }
        constraintSetupValues.removeValue(forKey: id)
        pruneSceneAnimationTracks()
    }

    @discardableResult
    func duplicateIKConstraint(_ id: UUID) -> UUID? {
        guard let index = skeleton.ikConstraints.firstIndex(where: { $0.id == id }) else { return nil }
        pushUndoState()
        let source = skeleton.ikConstraints[index]
        let copy = IKConstraint(
            id: UUID(),
            name: "\(source.name) Copy",
            enabled: source.enabled,
            order: source.order + 1,
            mix: source.mix,
            boneChain: source.boneChain,
            targetBoneID: source.targetBoneID,
            bendPositive: source.bendPositive,
            stretch: source.stretch,
            compress: source.compress,
            uniformScale: source.uniformScale,
            softness: source.softness
        )
        skeleton.ikConstraints.insert(copy, at: index + 1)
        renormalizeIKOrder()
        selectedConstraintID = copy.id
        return copy.id
    }

    func moveIKConstraint(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty,
              source.allSatisfy({ skeleton.ikConstraints.indices.contains($0) }) else { return }
        pushUndoState()
        skeleton.ikConstraints.move(fromOffsets: source, toOffset: destination)
        renormalizeIKOrder()
    }

    /// IK occupies the low end of the evaluation pipeline so Transform and
    /// Physics constraints can post-process its results.
    private func renormalizeIKOrder() {
        for index in skeleton.ikConstraints.indices {
            skeleton.ikConstraints[index].order = index
        }
    }

    func setIKTarget(_ constraintID: UUID, target boneID: UUID) {
        guard let index = skeleton.ikConstraints.firstIndex(where: { $0.id == constraintID }),
              skeleton.ikConstraints[index].targetBoneID != boneID else { return }
        pushUndoState()
        skeleton.ikConstraints[index].targetBoneID = boneID
        // A bone cannot both drive the chain and be driven by it.
        skeleton.ikConstraints[index].boneChain.removeAll { $0 == boneID }
    }

    /// Append a bone to the IK chain. Order matters: the chain runs root → tip,
    /// so the bone is added at the end.
    func addBoneToIKChain(_ boneID: UUID, constraintID: UUID) {
        guard let index = skeleton.ikConstraints.firstIndex(where: { $0.id == constraintID }) else { return }
        let c = skeleton.ikConstraints[index]
        guard boneID != c.targetBoneID, !c.boneChain.contains(boneID) else { return }
        pushUndoState()
        skeleton.ikConstraints[index].boneChain.append(boneID)
    }

    func removeBoneFromIKChain(_ boneID: UUID, constraintID: UUID) {
        guard let index = skeleton.ikConstraints.firstIndex(where: { $0.id == constraintID }),
              skeleton.ikConstraints[index].boneChain.contains(boneID) else { return }
        pushUndoState()
        skeleton.ikConstraints[index].boneChain.removeAll { $0 == boneID }
    }

    /// Replace the whole chain with the current bone selection, root → tip.
    /// Faster than adding bones one at a time when reworking a rig.
    func setIKChainFromSelection(_ constraintID: UUID) {
        guard let index = skeleton.ikConstraints.firstIndex(where: { $0.id == constraintID }) else { return }
        let ordered = selectedBonesInChainOrder.map(\.id)
            .filter { $0 != skeleton.ikConstraints[index].targetBoneID }
        guard !ordered.isEmpty else { return }
        pushUndoState()
        skeleton.ikConstraints[index].boneChain = ordered
    }

    func updateIKConstraint(_ id: UUID, _ mutate: (inout IKConstraint) -> Void) {
        guard let index = skeleton.ikConstraints.firstIndex(where: { $0.id == id }) else { return }
        pushUndoState()
        mutate(&skeleton.ikConstraints[index])
        applyAnimations()
    }

    // MARK: Path

    func renamePathConstraint(_ id: UUID, to newName: String) {
        guard let index = skeleton.pathConstraints.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != skeleton.pathConstraints[index].name else { return }
        pushUndoState()
        skeleton.pathConstraints[index].name = trimmed
    }

    func deletePathConstraint(_ id: UUID) {
        guard skeleton.pathConstraints.contains(where: { $0.id == id }) else { return }
        pushUndoState()
        removeAllConstraintTracks(id)
        skeleton.pathConstraints.removeAll { $0.id == id }
        if selectedConstraintID == id { selectedConstraintID = nil }
        constraintSetupValues.removeValue(forKey: id)
        pruneSceneAnimationTracks()
    }

    @discardableResult
    func duplicatePathConstraint(_ id: UUID) -> UUID? {
        guard let index = skeleton.pathConstraints.firstIndex(where: { $0.id == id }) else { return nil }
        pushUndoState()
        var copy = skeleton.pathConstraints[index]
        copy = PathConstraint(
            id: UUID(),
            name: "\(copy.name) Copy",
            enabled: copy.enabled,
            order: copy.order + 1,
            mix: copy.mix,
            pathBones: copy.pathBones,
            bones: copy.bones,
            position: copy.position,
            spacing: copy.spacing,
            spacingMode: copy.spacingMode,
            positionMix: copy.positionMix,
            rotateMix: copy.rotateMix,
            offsetRotation: copy.offsetRotation,
            closed: copy.closed,
            reversed: copy.reversed,
            rotateMode: copy.rotateMode
        )
        skeleton.pathConstraints.insert(copy, at: index + 1)
        selectedConstraintID = copy.id
        return copy.id
    }

    func addFollowerToPath(_ boneID: UUID, constraintID: UUID) {
        guard let index = skeleton.pathConstraints.firstIndex(where: { $0.id == constraintID }) else { return }
        let c = skeleton.pathConstraints[index]
        guard !c.bones.contains(boneID), !c.pathBones.contains(boneID) else { return }
        pushUndoState()
        skeleton.pathConstraints[index].bones.append(boneID)
    }

    func removeFollowerFromPath(_ boneID: UUID, constraintID: UUID) {
        guard let index = skeleton.pathConstraints.firstIndex(where: { $0.id == constraintID }),
              skeleton.pathConstraints[index].bones.contains(boneID) else { return }
        pushUndoState()
        skeleton.pathConstraints[index].bones.removeAll { $0 == boneID }
    }

    /// Rebuild the path's control points from the current selection, root → leaf.
    func setPathControlBonesFromSelection(_ constraintID: UUID) {
        guard let index = skeleton.pathConstraints.firstIndex(where: { $0.id == constraintID }) else { return }
        let ordered = selectedBonesInChainOrder.map(\.id)
            .filter { !skeleton.pathConstraints[index].bones.contains($0) }
        guard ordered.count >= 2 else { return }
        pushUndoState()
        skeleton.pathConstraints[index].pathBones = ordered
    }

    // MARK: Physics

    func renamePhysicsConstraint(_ id: UUID, to newName: String) {
        guard let index = skeleton.physicsConstraints.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != skeleton.physicsConstraints[index].name else { return }
        pushUndoState()
        skeleton.physicsConstraints[index].name = trimmed
    }

    func deletePhysicsConstraint(_ id: UUID) {
        guard skeleton.physicsConstraints.contains(where: { $0.id == id }) else { return }
        pushUndoState()
        removeAllConstraintTracks(id)
        skeleton.physicsConstraints.removeAll { $0.id == id }
        if selectedConstraintID == id { selectedConstraintID = nil }
        constraintSetupValues.removeValue(forKey: id)
        pruneSceneAnimationTracks()
    }

    @discardableResult
    func duplicatePhysicsConstraint(_ id: UUID) -> UUID? {
        guard let index = skeleton.physicsConstraints.firstIndex(where: { $0.id == id }) else { return nil }
        pushUndoState()
        let source = skeleton.physicsConstraints[index]
        let copy = PhysicsConstraint(
            id: UUID(),
            name: "\(source.name) Copy",
            enabled: source.enabled,
            order: source.order + 1,
            mix: source.mix,
            physicsType: source.physicsType,
            affectedBones: source.affectedBones,
            settings: source.settings
        )
        skeleton.physicsConstraints.insert(copy, at: index + 1)
        selectedConstraintID = copy.id
        return copy.id
    }

    func setPhysicsChainFromSelection(_ constraintID: UUID) {
        guard let index = skeleton.physicsConstraints.firstIndex(where: { $0.id == constraintID }) else { return }
        let ordered = selectedBonesInChainOrder.map(\.id)
        guard !ordered.isEmpty else { return }
        pushUndoState()
        skeleton.physicsConstraints[index].affectedBones = ordered
    }

    // MARK: Shared

    /// Toggle any constraint on or off by id, whatever its type.
    func setConstraintEnabled(_ id: UUID, _ enabled: Bool) {
        pushUndoState()
        if let i = skeleton.ikConstraints.firstIndex(where: { $0.id == id }) {
            skeleton.ikConstraints[i].enabled = enabled
        } else if let i = skeleton.transformConstraints.firstIndex(where: { $0.id == id }) {
            skeleton.transformConstraints[i].enabled = enabled
        } else if let i = skeleton.pathConstraints.firstIndex(where: { $0.id == id }) {
            skeleton.pathConstraints[i].enabled = enabled
        } else if let i = skeleton.physicsConstraints.firstIndex(where: { $0.id == id }) {
            skeleton.physicsConstraints[i].enabled = enabled
        }
        applyAnimations()
    }

    /// Delete any constraint by id, routing to the right store.
    func deleteConstraint(_ id: UUID) {
        switch skeleton.constraintKind(for: id) {
        case .ik:        deleteIKConstraint(id)
        case .transform: deleteTransformConstraint(id)
        case .path:      deletePathConstraint(id)
        case .physics:   deletePhysicsConstraint(id)
        case .none:      break
        }
    }

    /// Duplicate any constraint by id.
    @discardableResult
    func duplicateConstraint(_ id: UUID) -> UUID? {
        switch skeleton.constraintKind(for: id) {
        case .ik:        return duplicateIKConstraint(id)
        case .transform: return duplicateTransformConstraint(id)
        case .path:      return duplicatePathConstraint(id)
        case .physics:   return duplicatePhysicsConstraint(id)
        case .none:      return nil
        }
    }

    /// Rename any constraint by id.
    func renameConstraint(_ id: UUID, to newName: String) {
        switch skeleton.constraintKind(for: id) {
        case .ik:        renameIKConstraint(id, to: newName)
        case .transform: renameTransformConstraint(id, to: newName)
        case .path:      renamePathConstraint(id, to: newName)
        case .physics:   renamePhysicsConstraint(id, to: newName)
        case .none:      break
        }
    }

    /// Bones the artist may pick as a target: everything except the ones this
    /// constraint already drives, so a constraint cannot be made to drive itself.
    func targetCandidates(excluding driven: [UUID]) -> [Bone] {
        skeleton.orderedBones.filter { !driven.contains($0.id) }
    }
}

// MARK: - Animation events
//
// Events live on the scene clip as one track per event definition, so they
// inherit the whole keyframe toolchain — moving, copying, deleting, selecting —
// without any special-casing. Their keyframes are stepped by construction: an
// event either fires on a frame or it does not.
extension SceneManager {

    func animationEvent(for id: UUID) -> AnimationEvent? {
        animationEvents.first(where: { $0.id == id })
    }

    /// Event definitions that have at least one key, in the order the timeline
    /// should list them.
    var keyedEventIDs: [UUID] {
        animationEvents
            .filter { sceneAnimationClip.hasTrack(for: $0.id, property: .event) }
            .map(\.id)
    }

    // MARK: Definitions

    @discardableResult
    func createAnimationEvent(named requestedName: String? = nil) -> UUID {
        pushUndoState()
        let event = AnimationEvent(name: uniqueEventName(requestedName ?? "event"))
        animationEvents.append(event)
        objectWillChange.send()
        return event.id
    }

    func renameAnimationEvent(_ id: UUID, to newName: String) {
        guard let index = animationEvents.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != animationEvents[index].name else { return }
        pushUndoState()
        animationEvents[index].name = uniqueEventName(trimmed, excluding: id)
        objectWillChange.send()
    }

    func updateAnimationEvent(_ id: UUID, _ mutate: (inout AnimationEvent) -> Void) {
        guard let index = animationEvents.firstIndex(where: { $0.id == id }) else { return }
        pushUndoState()
        mutate(&animationEvents[index])
        objectWillChange.send()
    }

    /// Delete an event definition and every key that raised it. Leaving the keys
    /// behind would produce firings with no name attached.
    func deleteAnimationEvent(_ id: UUID) {
        guard animationEvents.contains(where: { $0.id == id }) else { return }
        pushUndoState()
        animationEvents.removeAll { $0.id == id }
        let keys = sceneAnimationClip.keyframes(for: id, property: .event)
        if !keys.isEmpty {
            sceneAnimationClip.deleteKeyframes(
                targetID: id,
                property: .event,
                keyframeIDs: Set(keys.map(\.id))
            )
        }
        objectWillChange.send()
    }

    private func uniqueEventName(_ requested: String, excluding: UUID? = nil) -> String {
        let taken = Set(animationEvents.filter { $0.id != excluding }.map(\.name))
        guard taken.contains(requested) else { return requested }
        var suffix = 2
        while taken.contains("\(requested) \(suffix)") { suffix += 1 }
        return "\(requested) \(suffix)"
    }

    // MARK: Keys

    func keyEvent(_ eventID: UUID, payload: AnimationEventPayload = .inheritingDefaults) {
        guard animationEvent(for: eventID) != nil else { return }
        pushUndoState()
        sceneAnimationClip.upsertKeyframe(
            targetID: eventID,
            property: .event,
            frame: currentFrame,
            value: .event(payload)
        )
        objectWillChange.send()
    }

    func eventHasKeyAtPlayhead(_ eventID: UUID) -> Bool {
        sceneAnimationClip
            .keyframes(for: eventID, property: .event)
            .contains { $0.frame == currentFrame }
    }

    func removeEventKeyAtPlayhead(_ eventID: UUID) {
        let keys = sceneAnimationClip.keyframes(for: eventID, property: .event)
        guard let key = keys.first(where: { $0.frame == currentFrame }) else { return }
        pushUndoState()
        sceneAnimationClip.deleteKeyframes(
            targetID: eventID,
            property: .event,
            keyframeIDs: [key.id]
        )
        objectWillChange.send()
    }

    /// Payload of the key sitting on the playhead, for the inspector to edit.
    func eventPayloadAtPlayhead(_ eventID: UUID) -> AnimationEventPayload? {
        sceneAnimationClip
            .keyframes(for: eventID, property: .event)
            .first(where: { $0.frame == currentFrame })?
            .value.eventPayload
    }

    func setEventPayloadAtPlayhead(_ eventID: UUID, _ payload: AnimationEventPayload) {
        guard eventHasKeyAtPlayhead(eventID) else { return }
        pushUndoState()
        sceneAnimationClip.upsertKeyframe(
            targetID: eventID,
            property: .event,
            frame: currentFrame,
            value: .event(payload)
        )
        objectWillChange.send()
    }

    // MARK: Firing

    /// Report every event key strictly between the previous playhead position
    /// and the new one, inclusive of the destination.
    ///
    /// Scrubbing backwards does not fire: replaying an event because the artist
    /// dragged the playhead left would be noise.
    /// A loop wrap (`to` < `from` while playing) is treated as two forward
    /// spans so events near the loop point are not silently skipped.
    func fireEventsCrossed(from: Int, to: Int) {
        guard !animationEvents.isEmpty else {
            lastEventScanFrame = to
            return
        }
        defer { lastEventScanFrame = to }

        guard from != to else { return }

        var fired: [FiredAnimationEvent] = []

        if to > from {
            collectEvents(in: (from + 1)...to, into: &fired)
        } else if isPlaying {
            // Wrapped around the loop: finish the old span, then the new one.
            let upper = max(playbackEndFrame, from)
            if upper > from {
                collectEvents(in: (from + 1)...upper, into: &fired)
            }
            let lower = playbackStartFrame
            if to >= lower {
                collectEvents(in: lower...to, into: &fired)
            }
        }

        guard !fired.isEmpty else { return }
        fired.sort { $0.frame < $1.frame }
        // Keep the tail bounded: this is a live readout, not a log.
        recentlyFiredEvents = Array((recentlyFiredEvents + fired).suffix(32))
    }

    private func collectEvents(in range: ClosedRange<Int>, into fired: inout [FiredAnimationEvent]) {
        for definition in animationEvents {
            for keyframe in sceneAnimationClip.keyframes(for: definition.id, property: .event)
            where range.contains(keyframe.frame) {
                let payload = keyframe.value.eventPayload ?? .inheritingDefaults
                let resolved = payload.resolved(against: definition)
                fired.append(
                    FiredAnimationEvent(
                        eventID: definition.id,
                        name: definition.name,
                        frame: keyframe.frame,
                        intValue: resolved.int,
                        floatValue: resolved.float,
                        stringValue: resolved.string
                    )
                )
            }
        }
    }

    func clearFiredEvents() {
        guard !recentlyFiredEvents.isEmpty else { return }
        recentlyFiredEvents = []
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct KeyframeSelectionGroup: Hashable {
    let imageID: UUID
    let property: AnimationTrackProperty
}
