import Foundation
import simd

final class MoveTool: Tool {
    let type: ActiveTool = .move

    private var activeID: UUID?
    private var activeBoneID: UUID?
    /// Every selected bone, parents first — `moveBoneRoot` converts a world
    /// point into PARENT space, so a parent already moved is the frame the
    /// child has to be written in.
    private var boneDragOrder: [UUID] = []
    /// Where each of them started, so the drag translates the group rather than
    /// stacking every bone onto the active one's position.
    private var boneStartPositions: [UUID: SIMD2<Float>] = [:]
    private var isDraggingMeshVertices = false
    private var activeVertexIndices: [Int] = []
    private var startPosition = SIMD2<Float>(repeating: 0)
    private var dragPosition = SIMD2<Float>(repeating: 0)
    private var grabOffsetScreen = SIMD2<Float>(repeating: 0)
    private var dragStartLocalPosition = SIMD2<Float>(repeating: 0)
    private var dragStartVertexPositions: [Int: SIMD2<Float>] = [:]
    private var mouseDownPosition: SIMD2<Float>?
    private var didDrag = false

    private let gridSize: Float = 1
    private let dragThreshold: Float = 4

    private func ensureDragStarted(currentPosition: SIMD2<Float>) -> Bool {
        if didDrag { return true }
        guard let down = mouseDownPosition else { return false }
        if simd_distance(currentPosition, down) >= dragThreshold {
            didDrag = true
            return true
        }
        return false
    }

    func onMouseDown(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        scene.beginInteraction()
        mouseDownPosition = input.position
        didDrag = false
        if let selectedID = scene.selectedImageID,
           let image = scene.image(for: selectedID),
           let asset = assets.asset(for: image.assetID),
           scene.isMeshLayerSelected,
           let hitVertex = ToolUtilities.hitTestMeshVertex(
                screenPoint: input.screenPosition,
                viewSize: input.viewSize,
                scene: scene,
                assets: assets,
                camera: input.camera
           ) {
            if !scene.selectedMeshVertexIndices.contains(hitVertex) {
                scene.selectMeshVertices([hitVertex])
            }
            activeID = selectedID
            isDraggingMeshVertices = true
            activeVertexIndices = Array(scene.selectedMeshVertexIndices).sorted()
            dragStartLocalPosition = ToolUtilities.localCoordinates(for: input.position, image: image)
            let sourceVertices = image.meshAnimationDeform ?? image.mesh.vertices
            dragStartVertexPositions = Dictionary(uniqueKeysWithValues: activeVertexIndices.compactMap { index in
                guard sourceVertices.indices.contains(index) else { return nil }
                return (index, sourceVertices[index])
            })
            _ = asset
            return
        }

        if let boneID = scene.selectedBoneID,
           let segment = scene.skeleton.lineSegment(for: boneID) {
            activeBoneID = boneID
            startPosition = segment.start
            dragPosition = segment.start
            if let camera = input.camera {
                let boneScreen = camera.worldToScreen(segment.start, viewSize: input.viewSize)
                grabOffsetScreen = input.screenPosition - boneScreen
            } else {
                grabOffsetScreen = .zero
            }
            boneDragOrder = scene.selectedBonesInDepthOrder
            boneStartPositions = Dictionary(uniqueKeysWithValues: boneDragOrder.compactMap { id in
                scene.skeleton.lineSegment(for: id).map { (id, $0.start) }
            })
            return
        }

        let hit = ToolUtilities.hitTestScreen(
            screenPoint: input.screenPosition,
            viewSize: input.viewSize,
            scene: scene,
            assets: assets,
            camera: input.camera
        ) ?? scene.selectedImageID
        guard let id = hit, let image = scene.image(for: id) else { return }
        if scene.isMeshLayerSelected, scene.selectedImageID == id {
            scene.selectMeshLayer(for: id)
        } else {
            scene.setSelection(ids: [id], primary: id, additive: input.isShiftPressed)
        }
        activeID = id
        startPosition = image.position
        dragPosition = image.position
        if let camera = input.camera {
            let imageScreen = camera.worldToScreen(image.position, viewSize: input.viewSize)
            grabOffsetScreen = input.screenPosition - imageScreen
        } else {
            grabOffsetScreen = .zero
        }
    }

    func onMouseDrag(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        guard ensureDragStarted(currentPosition: input.position) else { return }
        if let boneID = activeBoneID {
            if let camera = input.camera {
                let startScreen = camera.worldToScreen(startPosition, viewSize: input.viewSize)
                var targetScreen = input.screenPosition - grabOffsetScreen

                if input.activeHandle == .moveX {
                    targetScreen.y = startScreen.y
                } else if input.activeHandle == .moveY {
                    targetScreen.x = startScreen.x
                }

                dragPosition = camera.screenToWorld(targetScreen, viewSize: input.viewSize)
            } else {
                var rawTarget = input.position
                if input.activeHandle == .moveX {
                    rawTarget.y = startPosition.y
                } else if input.activeHandle == .moveY {
                    rawTarget.x = startPosition.x
                }
                dragPosition = rawTarget
            }

            let targetPosition = input.isShiftPressed ? ToolUtilities.snap(dragPosition, grid: gridSize) : dragPosition
            // Measured on the ACTIVE bone after snapping, then applied to the
            // group. Snapping each bone to the grid on its own would shear the
            // selection apart every time one of them crossed a grid line.
            let appliedDelta = targetPosition - startPosition
            guard !boneDragOrder.isEmpty else {
                scene.moveBoneRoot(id: boneID, to: targetPosition)
                return
            }
            for id in boneDragOrder {
                guard let start = boneStartPositions[id] else { continue }
                scene.moveBoneRoot(id: id, to: start + appliedDelta)
            }
            return
        }
        guard let id = activeID else { return }
        if isDraggingMeshVertices,
           let image = scene.image(for: id) {
            let currentLocalPosition = ToolUtilities.localCoordinates(for: input.position, image: image)
            let delta = currentLocalPosition - dragStartLocalPosition
            let adjustedDelta = input.isShiftPressed ? ToolUtilities.snap(delta, grid: gridSize) : delta
            for vertexIndex in activeVertexIndices {
                guard let startVertex = dragStartVertexPositions[vertexIndex] else { continue }
                scene.updateMeshVertex(imageID: id, vertexIndex: vertexIndex, localPosition: startVertex + adjustedDelta)
            }
            return
        }
        if let camera = input.camera {
            let startScreen = camera.worldToScreen(startPosition, viewSize: input.viewSize)
            var targetScreen = input.screenPosition - grabOffsetScreen

            if input.activeHandle == .moveX {
                targetScreen.y = startScreen.y
            } else if input.activeHandle == .moveY {
                targetScreen.x = startScreen.x
            }

            dragPosition = camera.screenToWorld(targetScreen, viewSize: input.viewSize)
        } else {
            var rawTarget = input.position
            if input.activeHandle == .moveX {
                rawTarget.y = startPosition.y
            } else if input.activeHandle == .moveY {
                rawTarget.x = startPosition.x
            }
            dragPosition = rawTarget
        }

        let targetPosition = input.isShiftPressed ? ToolUtilities.snap(dragPosition, grid: gridSize) : dragPosition
        scene.setPreviewPosition(id: id, position: targetPosition)
    }

    func onMouseUp(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        scene.endInteraction()
        defer {
            activeID = nil
            activeBoneID = nil
            boneDragOrder = []
            boneStartPositions = [:]
            isDraggingMeshVertices = false
            activeVertexIndices = []
            dragPosition = SIMD2<Float>(repeating: 0)
            grabOffsetScreen = SIMD2<Float>(repeating: 0)
            dragStartLocalPosition = .zero
            dragStartVertexPositions = [:]
            mouseDownPosition = nil
            didDrag = false
        }

        if let boneID = activeBoneID {
            guard didDrag else { return }
            let target = input.isShiftPressed ? ToolUtilities.snap(dragPosition, grid: gridSize) : dragPosition
            let appliedDelta = target - startPosition
            let moved = boneDragOrder.isEmpty ? [boneID] : boneDragOrder
            for id in moved {
                let start = boneStartPositions[id]
                scene.moveBoneRoot(id: id, to: (start ?? startPosition) + appliedDelta)
                scene.commitKeyframe(for: id, property: .translate)
            }
            return
        }
        guard let id = activeID else { return }
        if isDraggingMeshVertices {
            if scene.isAnimationEditingEnabled, let imageID = activeID {
                scene.commitMeshDeformKeyframe(imageID: imageID)
            }
            return
        }
        guard didDrag, scene.image(for: id) != nil else {
            scene.clearPreviewPosition(id: id)
            return
        }
        let target = input.isShiftPressed ? ToolUtilities.snap(dragPosition, grid: gridSize) : dragPosition
        scene.clearPreviewPosition(id: id)
        scene.setImagePosition(id: id, position: target)
        scene.commitKeyframe(for: id, property: .translate)
    }

    func update(scene: SceneManager, assets: AssetManager) {
        _ = scene
        _ = assets
    }
}
