import Foundation
import Combine
import CoreGraphics
import simd

@MainActor
final class ToolManager: ObservableObject {
    @Published var currentTool: ActiveTool = .select
    @Published var quickSwitchTool: ActiveTool?
    @Published var quickSwitchCursorPosition: CGPoint?
    private(set) var lastInput: ToolInput?
    private(set) var hoveredHandle: GizmoHandle?
    private(set) var activeHandle: GizmoHandle?
    private(set) var selectionRect: CGRect?

    weak var camera: CameraState?
    /// So a tool change can leave the canvas modes that tool cannot serve.
    /// Weak, and set by `AppState`: the scene owns the tool manager's lifetime,
    /// not the other way round.
    weak var scene: SceneManager?
    let skewState: SkewGizmoState
    let rotationState: RotationGizmoState

    private let tools: [ActiveTool: Tool]
    private var quickSwitchClearTask: Task<Void, Never>?

    init(skewState: SkewGizmoState, rotationState: RotationGizmoState) {
        self.skewState = skewState
        self.rotationState = rotationState
        self.tools = [
            .select: SelectTool(),
            .bone: BoneTool(),
            .mesh: MeshTool(),
            .move: MoveTool(),
            .rotate: RotateTool(),
            .scale: ScaleTool(),
            .skew: SkewTool(skewState: skewState),
            .physicsPreview: PhysicsPreviewTool()
        ]
    }

    func setTool(_ tool: ActiveTool) {
        currentTool = tool
        scene?.canvasToolChanged(to: tool)
    }

    func activateQuickSwitchTool(_ tool: ActiveTool) {
        activateQuickSwitchTool(tool, at: nil)
    }

    func activateQuickSwitchTool(_ tool: ActiveTool, at cursorPosition: CGPoint?) {
        currentTool = tool
        scene?.canvasToolChanged(to: tool)
        quickSwitchTool = tool
        if let cursorPosition {
            quickSwitchCursorPosition = cursorPosition
        }
        quickSwitchClearTask?.cancel()
        quickSwitchClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.quickSwitchTool = nil
                self?.quickSwitchCursorPosition = nil
            }
        }
    }

    func endQuickSwitchOverlay() {
        quickSwitchClearTask?.cancel()
        quickSwitchClearTask = nil
        quickSwitchTool = nil
        quickSwitchCursorPosition = nil
    }

    /// The pointer is no longer over the canvas.
    ///
    /// An Apple Pencil lifted out of hover range, or a mouse moved off the
    /// view. Everything below was derived from a pointer being somewhere, and
    /// none of it has any meaning once there is no pointer — so it goes,
    /// rather than keeping its last value.
    ///
    /// `lastInput` is the one that was reported: the mesh Create preview draws
    /// its green dot at `lastInput.position`, and because nothing ever cleared
    /// it the dot stayed wherever the Pencil last hovered, for the rest of the
    /// session. The rest are the same bug in other colours — a sprite, a
    /// vertex, a bind bone, an IK bone and a gizmo handle, each left lit under
    /// nothing.
    func handlePointerExit(scene: SceneManager) {
        // Never mid-drag. On the Mac the pointer can leave the view WHILE a
        // drag is live — dragging a sprite off the canvas does exactly that —
        // and a drag owns its state until it ends.
        //
        // The iPad ordering is safe for a different reason, worth writing down
        // because it looks unsafe: putting the Pencil down ends the hover, and
        // `.ended` is not guaranteed to arrive after `touchesBegan`, so this
        // can run a moment before an interaction starts. It does not matter.
        // `handleMouseDown` recomputes `hoveredHandle` itself before reading
        // it, and everything else cleared here is a highlight. Nothing that a
        // press depends on survives only in these fields.
        guard activeHandle == nil, lastInput?.isDragging != true else { return }

        lastInput = nil
        hoveredHandle = nil
        if scene.hoveredImageID != nil { scene.hoveredImageID = nil }
        if scene.hoveredMeshVertexIndex != nil { scene.hoveredMeshVertexIndex = nil }
        if scene.hoveredBindBoneID != nil { scene.hoveredBindBoneID = nil }
        if scene.ikBuilderHoveredBoneID != nil { scene.ikBuilderHoveredBoneID = nil }
    }

    /// Drop the mesh edge that is half drawn, if there is one.
    ///
    /// Forwarded rather than reached into: the half-drawn edge is the mesh
    /// tool's own state, and the canvas prompt should not have to know which
    /// tool holds it.
    func cancelPendingMeshEdge(scene: SceneManager) {
        (tools[.mesh] as? MeshTool)?.cancelPendingCreateEdge(scene: scene)
    }

    func handleMouseMove(_ input: ToolInput, scene: SceneManager, assets: AssetManager) {
        lastInput = input

        // Bone under the cursor while the IK builder is picking, so the canvas
        // shows what a click would land on before it happens.
        if scene.ikBuilder?.pickingSlot != nil {
            let hovered = ToolUtilities.hitTestBone(
                screenPoint: input.screenPosition,
                viewSize: input.viewSize,
                scene: scene,
                camera: camera
            )
            if scene.ikBuilderHoveredBoneID != hovered {
                scene.ikBuilderHoveredBoneID = hovered
            }
        } else if scene.ikBuilderHoveredBoneID != nil {
            scene.ikBuilderHoveredBoneID = nil
        }

        // Track which bone the cursor is hovering in Bind Mode for visual
        // feedback. Written only when it CHANGES: `@Published` fires
        // `objectWillChange` on assignment, not on difference, so storing the
        // same bone again rebuilt the hierarchy, the inspector and the
        // timeline on every mouse-move event.
        if scene.isBindingBonesMode, scene.selectedImageID != nil {
            let hoveredBind = ToolUtilities.hitTestBone(
                screenPoint: input.screenPosition,
                viewSize: input.viewSize,
                scene: scene,
                camera: camera
            )
            if scene.hoveredBindBoneID != hoveredBind {
                scene.hoveredBindBoneID = hoveredBind
            }
            // Bind Mode is about bones, so no sprite pre-selection competes
            // with the bone the artist is aiming at.
            if scene.hoveredImageID != nil { scene.hoveredImageID = nil }
        } else if scene.hoveredBindBoneID != nil {
            scene.hoveredBindBoneID = nil
        }

        // PRE-SELECTION. Resolved through the same picker a click uses, and
        // stored as what the click would RETURN — so the grey outline is a
        // promise about the next click rather than a guess about the cursor.
        // Nil when a bone would win: a click there is not going to select a
        // sprite, and saying otherwise is a lie the artist learns from.
        if !scene.isBindingBonesMode {
            var hovered: UUID?
            if case .image(let id)? = ToolUtilities.hitTestSelectionTarget(
                screenPoint: input.screenPosition,
                worldPoint: input.position,
                viewSize: input.viewSize,
                scene: scene,
                assets: assets,
                camera: camera
            ) {
                hovered = id
            }
            // Written only when it CHANGES: `@Published` fires on assignment,
            // not on difference, and this runs on every mouse-move and every
            // Apple Pencil hover sample.
            if scene.hoveredImageID != hovered { scene.hoveredImageID = hovered }
        }

        hoveredHandle = ToolUtilities.hitTestGizmo(
            tool: currentTool,
            screenPoint: input.screenPosition,
            viewSize: input.viewSize,
            scene: scene,
            assets: assets,
            camera: camera
        )
        // A handle under the cursor means the click grabs the gizmo, not a
        // sprite, so the pre-selection has to agree with that.
        if hoveredHandle != nil, scene.hoveredImageID != nil {
            scene.hoveredImageID = nil
        }

        if currentTool == .skew {
            switch hoveredHandle {
            case .skewEdge(0): skewState.hoveredArc = 1
            case .skewEdge(1): skewState.hoveredArc = 2
            case .skewEdge(2): skewState.hoveredArc = 3
            default: skewState.hoveredArc = 0
            }
        } else {
            skewState.hoveredArc = 0
        }

        if scene.isMeshLayerSelected {
            // REUSE THE ANSWER ABOVE. With the mesh tool up, `hoveredHandle`
            // IS the hovered node: `hitTestGizmo` has just run the same test,
            // at the same radius, against the same projection. Asking again
            // resolved the mesh a second time and could not answer
            // differently. Any other tool asks nothing about the mesh in its
            // gizmo pass, so that case still has to do the work.
            let hoveredVertex: Int?
            if case .some(.meshVertex(let index)) = hoveredHandle {
                hoveredVertex = index
            } else if currentTool == .mesh {
                hoveredVertex = nil
            } else {
                hoveredVertex = ToolUtilities.hitTestMeshVertex(
                    screenPoint: input.screenPosition,
                    viewSize: input.viewSize,
                    scene: scene,
                    assets: assets,
                    camera: camera
                )
            }
            if scene.hoveredMeshVertexIndex != hoveredVertex {
                scene.hoveredMeshVertexIndex = hoveredVertex
            }
        } else if scene.hoveredMeshVertexIndex != nil {
            scene.hoveredMeshVertexIndex = nil
        }
    }

    func handleMouseDown(_ input: ToolInput, scene: SceneManager, assets: AssetManager) {
        // IK builder intercept: while a slot is armed, a click on a bone fills
        // that slot instead of selecting. Runs first so picking works with
        // whatever tool is active — an artist should not have to know that
        // bone picking lives in one particular tool.
        if scene.ikBuilder?.pickingSlot != nil {
            if let boneID = ToolUtilities.hitTestBone(
                screenPoint: input.screenPosition,
                viewSize: input.viewSize,
                scene: scene,
                camera: camera
            ) {
                scene.ikBuilderHandleBonePick(boneID)
            }
            // Clicking empty space is swallowed too: it would otherwise clear
            // the selection under a panel the artist is still working in.
            return
        }

        // Bind Mode intercept: clicks toggle bone binding on the selected mesh.
        // This runs before any normal selection logic so hitting a bone never
        // accidentally deselects the image or changes the active tool.
        if scene.isBindingBonesMode,
           let imageID = scene.selectedImageID,
           let image = scene.image(for: imageID),
           let asset = assets.asset(for: image.assetID) {
            if let boneID = ToolUtilities.hitTestBone(
                screenPoint: input.screenPosition,
                viewSize: input.viewSize,
                scene: scene,
                camera: camera
            ) {
                let boundIDs = scene.boundBoneIDs(imageID: imageID)
                if boundIDs.contains(boneID) {
                    scene.unbindBoneFromImage(
                        imageID: imageID,
                        boneID: boneID,
                        maxInfluences: scene.meshWeightMaxInfluencesPerVertex
                    )
                    if scene.activeWeightPaintBoneID == boneID {
                        scene.activeWeightPaintBoneID = nil
                    }
                } else {
                    scene.bindBoneToImage(
                        imageID: imageID,
                        boneID: boneID,
                        assetSize: asset.size,
                        maxInfluences: scene.meshWeightMaxInfluencesPerVertex
                    )
                }
            }
            // Never change selection state while in Bind Mode
            return
        }

        hoveredHandle = ToolUtilities.hitTestGizmo(
            tool: currentTool,
            screenPoint: input.screenPosition,
            viewSize: input.viewSize,
            scene: scene,
            assets: assets,
            camera: camera
        )
        activeHandle = hoveredHandle
        if currentTool == .skew {
            switch activeHandle {
            case .skewEdge(0): skewState.hoveredArc = 1
            case .skewEdge(1): skewState.hoveredArc = 2
            case .skewEdge(2): skewState.hoveredArc = 3
            default: skewState.hoveredArc = 0
            }
        }

        let currentSelectionID = scene.selectedBoneID ?? scene.selectedImageID
        let hasFocusedSelection = currentSelectionID != nil
        // For `didChangeSelection` below: which sprite was selected before this
        // click had its say.
        let imageSelectedBeforeClick = scene.selectedImageID

        // Weight paint holds its target, the same way Bind Mode does. The brush
        // paints `selectedImageID`, so letting a click re-select mid-stroke moves
        // the brush to another sprite. On iPadOS `allowSelectionChange` below is
        // unconditionally true, so a single tap was enough — which is where this
        // was reported from — and a tap that lands on a bone is worse still,
        // because `selectBone` clears `selectedImageID` and the stroke stops
        // painting anything at all.
        let holdsSelectionForPainting = currentTool == .mesh && scene.isWeightPaintStroke

        // And in Weights the bones on the canvas are a COLOUR PICKER, not a
        // selection: a click on one arms the brush with it (`MeshTool`, via
        // `weightPaintMayChangeBone`). `selectBone` clears `selectedImageID`,
        // so if it also ran, the click that armed a bone would take away the
        // sprite being painted in the same breath — and the arming, which runs
        // after this block, would then find nothing selected and do nothing.
        //
        // Wider than `holdsSelectionForPainting` on purpose: that one asks
        // whether a bone is ALREADY armed, and the case this protects is the
        // double click that arms the first one.
        let bonesArmTheBrush = currentTool == .mesh
            && scene.meshWeightPaintEnabled
            && scene.selectedImageID != nil
#if os(iOS)
        // Touch has no hover and no double-click convention: tapping a
        // different bone or image must switch the selection immediately,
        // with a single touch, regardless of the active tool — matching
        // Procreate layers and Affinity nodes. (Taps on the active gizmo
        // are still consumed by the gizmo above, so transforms in progress
        // are never interrupted.)
        //
        // Except in Mesh mode, where a tap is an edit that lands on whatever
        // sprite is under the node — see `meshModeMayChangeSelection`. There a
        // double tap switches and a single tap never does, on both platforms.
        let allowSelectionChange = currentTool != .mesh || input.clickCount >= 2
#else
        let allowSelectionChange = currentTool == .select || input.clickCount >= 2
#endif
        let hitTarget = ToolUtilities.hitTestSelectionTarget(
            screenPoint: input.screenPosition,
            worldPoint: input.position,
            viewSize: input.viewSize,
            scene: scene,
            assets: assets,
            camera: camera
        )

        if activeHandle == nil {
            if let hitTarget {
                switch hitTarget {
                case let .image(hitID):
                    let canSwitch = !holdsSelectionForPainting
                        && (!hasFocusedSelection || allowSelectionChange || currentSelectionID == hitID)
                    if canSwitch {
                        // In a sprite mode, changing sprite selects the new
                        // sprite's MESH. `setSelection` clears
                        // `isMeshLayerSelected`, which is what the brush and
                        // the vertex hit-test both key off, so going through
                        // it left weight paint running with nothing to paint.
                        if scene.isSpriteMeshMode
                            || (scene.isMeshLayerSelected && scene.selectedImageID == hitID) {
                            scene.selectMeshLayer(for: hitID)
                        } else if currentTool == .select || scene.selectedImageID == nil || currentSelectionID != hitID {
                            scene.setSelection(ids: [hitID], primary: hitID, additive: input.isShiftPressed)
                        }
                    }
                    if scene.selectedImageID == hitID {
                        if currentTool == .bone {
                            activeHandle = nil
                        } else if currentTool == .rotate {
                            activeHandle = .rotateRing
                        } else if currentTool == .mesh {
                            activeHandle = hoveredHandle
                        } else if currentTool == .scale {
                            activeHandle = .scaleCorner(2)
                        } else {
                            activeHandle = ToolUtilities.defaultHandle(for: currentTool)
                        }
                    }
                case let .bone(hitID):
                    let canSwitch = !holdsSelectionForPainting
                        && !bonesArmTheBrush
                        && (!hasFocusedSelection || allowSelectionChange || currentSelectionID == hitID)
                    if canSwitch {
                        scene.selectBone(hitID)
                    }
                }
            } else {
                if currentTool == .bone {
                    activeHandle = nil
                } else if currentTool == .rotate, scene.selectedImageID != nil || scene.selectedBoneID != nil {
                    activeHandle = .rotateRing
                } else if currentTool == .mesh {
                    activeHandle = nil
                } else if currentTool == .scale, scene.selectedImageID != nil || scene.selectedBoneID != nil {
                    activeHandle = .scaleCorner(2)
                } else if currentTool == .select {
                    scene.clearSelection()
                }
            }
        }

#if os(iOS)
        // Confirm selection changes with a subtle haptic so a tap on a bone
        // feels acknowledged even before the highlight is perceived.
        if (scene.selectedBoneID ?? scene.selectedImageID) != currentSelectionID {
            PlatformFeedback.selectionChanged()
        }
#endif

        if currentTool == .mesh, scene.meshWeightPaintEnabled {
            selectionRect = nil
        }

        let enriched = ToolInput(
            position: input.position,
            startPosition: input.startPosition,
            screenPosition: input.screenPosition,
            previousScreenPosition: input.previousScreenPosition,
            screenDelta: input.screenDelta,
            startScreenPosition: input.startScreenPosition,
            viewSize: input.viewSize,
            isDragging: input.isDragging,
            isShiftPressed: input.isShiftPressed,
            clickCount: input.clickCount,
            hoveredHandle: hoveredHandle,
            activeHandle: activeHandle,
            camera: camera,
            // Decided HERE, where the switch happened, rather than re-derived
            // inside the tool: by the time the tool runs, `selectedImageID` is
            // already the new sprite and the tool has nothing to compare against.
            didChangeSelection: scene.selectedImageID != imageSelectedBeforeClick
        )
        lastInput = enriched
        tools[currentTool]?.onMouseDown(input: enriched, scene: scene, assets: assets)
    }

    func handleMouseDrag(_ input: ToolInput, scene: SceneManager, assets: AssetManager) {
        if activeHandle == nil {
            if currentTool == .select {
                // Pose mode is about the skeleton, so the marquee there takes
                // BONES. Everywhere else it still takes sprites — the artwork
                // is what a plain Select drag is for, and Pose is the one mode
                // where dragging a box over a rig and getting the pngs behind
                // it was never what was meant.
                if scene.isPoseMode {
                    updateBoneSelectionRect(input: input, scene: scene)
                } else {
                    updateSelectionRect(input: input, scene: scene, assets: assets)
                }
            } else if currentTool == .mesh, scene.meshEditToolMode == .modify {
                if scene.meshWeightPaintEnabled {
                    selectionRect = nil
                } else {
                    updateMeshSelectionRect(input: input, scene: scene, assets: assets)
                }
            }
        }
        let enriched = ToolInput(
            position: input.position,
            startPosition: input.startPosition,
            screenPosition: input.screenPosition,
            previousScreenPosition: input.previousScreenPosition,
            screenDelta: input.screenDelta,
            startScreenPosition: input.startScreenPosition,
            viewSize: input.viewSize,
            isDragging: input.isDragging,
            isShiftPressed: input.isShiftPressed,
            clickCount: input.clickCount,
            hoveredHandle: hoveredHandle,
            activeHandle: activeHandle,
            camera: camera
        )
        lastInput = enriched
        tools[currentTool]?.onMouseDrag(input: enriched, scene: scene, assets: assets)
    }

    func handleMouseUp(_ input: ToolInput, scene: SceneManager, assets: AssetManager) {
        let enriched = ToolInput(
            position: input.position,
            startPosition: input.startPosition,
            screenPosition: input.screenPosition,
            previousScreenPosition: input.previousScreenPosition,
            screenDelta: input.screenDelta,
            startScreenPosition: input.startScreenPosition,
            viewSize: input.viewSize,
            isDragging: input.isDragging,
            isShiftPressed: input.isShiftPressed,
            clickCount: input.clickCount,
            hoveredHandle: hoveredHandle,
            activeHandle: activeHandle,
            camera: camera
        )
        lastInput = enriched
        tools[currentTool]?.onMouseUp(input: enriched, scene: scene, assets: assets)
        activeHandle = nil
        selectionRect = nil
        if currentTool == .skew {
            skewState.hoveredArc = 0
        }
    }

    func update(scene: SceneManager, assets: AssetManager) {
        tools[currentTool]?.update(scene: scene, assets: assets)
    }

    private func updateSelectionRect(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        guard let rect = marqueeRect(input: input) else {
            selectionRect = nil
            return
        }
        selectionRect = rect

        let ids = ToolUtilities.hitTestRect(
            rect: rect,
            viewSize: input.viewSize,
            scene: scene,
            assets: assets,
            camera: camera
        )
        scene.setSelection(ids: ids, primary: ids.first, additive: input.isShiftPressed)
    }

    private func updateBoneSelectionRect(input: ToolInput, scene: SceneManager) {
        guard let rect = marqueeRect(input: input) else {
            selectionRect = nil
            return
        }
        selectionRect = rect

        let ids = ToolUtilities.bonesIntersecting(
            rect: rect,
            viewSize: input.viewSize,
            scene: scene,
            camera: camera
        )
        // The bone being worked on survives a box that still contains it, so
        // re-dragging the marquee does not hand the inspector to a neighbour
        // halfway through posing.
        scene.setBoneSelection(ids,
                               primary: ids.contains(where: { $0 == scene.selectedBoneID })
                                   ? scene.selectedBoneID : ids.first,
                               additive: input.isShiftPressed || input.isCommandPressed)
    }

    /// The marquee, or nil while the drag is still small enough to be a click.
    ///
    /// Three copies of this arithmetic had drifted into three functions; the
    /// threshold is the part that matters and it belongs in one of them.
    private func marqueeRect(input: ToolInput) -> CGRect? {
        let dx = input.screenPosition.x - input.startScreenPosition.x
        let dy = input.screenPosition.y - input.startScreenPosition.y
        guard abs(dx) >= 3 || abs(dy) >= 3 else { return nil }
        let minX = min(input.startScreenPosition.x, input.screenPosition.x)
        let maxX = max(input.startScreenPosition.x, input.screenPosition.x)
        let minY = min(input.startScreenPosition.y, input.screenPosition.y)
        let maxY = max(input.startScreenPosition.y, input.screenPosition.y)
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }

    private func updateMeshSelectionRect(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        guard let rect = marqueeRect(input: input) else {
            selectionRect = nil
            return
        }
        selectionRect = rect

        let hits = ToolUtilities.hitTestMeshVertices(
            rect: rect,
            viewSize: input.viewSize,
            scene: scene,
            assets: assets,
            camera: camera
        )
        if input.isShiftPressed {
            scene.selectMeshVertices(scene.selectedMeshVertexIndices.union(hits))
        } else {
            scene.selectMeshVertices(hits)
        }
    }

    private func updateRotationHover(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        guard let selectedID = scene.selectedImageID,
              let image = scene.image(for: selectedID),
              let camera = camera else { return }
        let center = camera.worldToScreen(image.position, viewSize: input.viewSize)
        let radius = rotationRadius(zoom: Float(camera.zoom))
        let hit = ArcHitTest.test(
            screenPt: input.screenPosition,
            center: center,
            radius: radius,
            cameraYaw: rotationState.cameraYaw,
            cameraPitch: rotationState.cameraPitch,
            rotX: image.rotation3D.x,
            rotY: image.rotation3D.y,
            rotZ: image.rotation
        )
        rotationState.hoveredArc = hit.arcIndex
    }

    private func handleRotationMouseDown(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        guard let selectedID = scene.selectedImageID,
              let image = scene.image(for: selectedID),
              let camera = camera else { return }
        let center = camera.worldToScreen(image.position, viewSize: input.viewSize)
        let radius = rotationRadius(zoom: Float(camera.zoom))
        rotationState.updateRadius(radius)

        let hit = ArcHitTest.test(
            screenPt: input.screenPosition,
            center: center,
            radius: radius,
            cameraYaw: rotationState.cameraYaw,
            cameraPitch: rotationState.cameraPitch,
            rotX: image.rotation3D.x,
            rotY: image.rotation3D.y,
            rotZ: image.rotation
        )
        rotationState.mouseDown(
            screenPt: CGPoint(x: CGFloat(input.screenPosition.x), y: CGFloat(input.screenPosition.y)),
            hitArc: hit.arcIndex,
            arcTangent: hit.tangent
        )
    }

    private func handleRotationMouseDrag(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        guard let selectedID = scene.selectedImageID else { return }
        rotationState.mouseDragged(
            currentPt: CGPoint(x: CGFloat(input.screenPosition.x), y: CGFloat(input.screenPosition.y)),
            zoom: Float(camera?.zoom ?? 1.0),
            isShiftDown: input.isShiftPressed
        )
        let xRad = rotationState.rotationX * (.pi / 180)
        let yRad = rotationState.rotationY * (.pi / 180)
        let zRad = rotationState.rotationZ * (.pi / 180)
        let existingZ = scene.image(for: selectedID)?.rotation3D.z ?? 0
        scene.setImageRotation3D(id: selectedID, rotation3D: SIMD3<Float>(xRad, yRad, existingZ))
        scene.setImageRotation(id: selectedID, rotation: zRad)
    }

    private func syncRotationState(scene: SceneManager) {
        guard let selectedID = scene.selectedImageID,
              let image = scene.image(for: selectedID) else { return }
        if !rotationState.isDragging {
            rotationState.rotationX = image.rotation3D.x * 180 / Float.pi
            rotationState.rotationY = image.rotation3D.y * 180 / Float.pi
            rotationState.rotationZ = image.rotation * 180 / Float.pi
        }
    }

    private func rotationRadius(zoom: Float) -> Float {
        let base: Float = 64
        let scaled = base * sqrt(max(zoom, 0.01))
        return max(48, min(96, scaled))
    }
}
