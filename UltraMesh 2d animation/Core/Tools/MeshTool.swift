import Foundation
import ImageIO
import CoreGraphics
import simd

final class MeshTool: Tool {
    let type: ActiveTool = .mesh

    private var activeImageID: UUID?
    private var activeVertexIndices: [Int] = []
    private var dragStartLocalPosition = SIMD2<Float>(repeating: 0)
    private var dragStartVertexPositions: [Int: SIMD2<Float>] = [:]
    private var dragStartVertexUVs: [Int: SIMD2<Float>] = [:]
    private var dragInfluenceWeights: [Int: Float] = [:]
    private var pendingEmptyClick = false
    /// Where the brush last stamped, so a drag paints the segment since then
    /// rather than a dot at the new position. Cleared when the stroke ends, so
    /// the next stroke does not paint a line in from wherever the last one
    /// finished.
    private var lastPaintWorld: SIMD2<Float>?
    /// The weights as they were just before a brush stamp that landed on a
    /// bound bone, so a double click that arms that bone can take the stamp
    /// back.
    ///
    /// The first click of a double click is a stamp — there is no way to know
    /// at press time that a second one is coming — and it lands exactly where
    /// the bone being armed is. Left in place, every switch painted a blob of
    /// the OLD bone onto the NEW one. Cleared by a drag, which proves the click
    /// was a stroke rather than half a double click.
    private var weightsBeforePaintClick: (imageID: UUID, weights: [[VertexBoneWeight]])?
    private var createEdgeStartImageID: UUID?
    private var createEdgeStartVertexIndex: Int?
    private var createEdgeStartLocalPosition: SIMD2<Float>?
    private var createEdgeDidDrag = false

    func onMouseDown(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        scene.beginInteraction()
        if scene.isBindingBonesMode {
            guard let imageID = scene.selectedImageID,
                  let image = scene.image(for: imageID),
                  let asset = assets.asset(for: image.assetID) else { return }
            if let boneID = ToolUtilities.hitTestBone(
                screenPoint: input.screenPosition,
                viewSize: input.viewSize,
                scene: scene,
                camera: input.camera
            ) {
                let boundIDs = scene.boundBoneIDs(imageID: imageID)
                if boundIDs.contains(boneID) {
                    scene.unbindBoneFromImage(imageID: imageID, boneID: boneID, maxInfluences: scene.meshWeightMaxInfluencesPerVertex)
                    if scene.activeWeightPaintBoneID == boneID { scene.activeWeightPaintBoneID = nil }
                } else {
                    scene.bindBoneToImage(imageID: imageID, boneID: boneID, assetSize: asset.size, maxInfluences: scene.meshWeightMaxInfluencesPerVertex)
                }
            }
            return
        }

        // Weight painting is NOT mesh editing. It used to sit behind this same
        // guard, so turning Mesh Edit off stopped the brush from doing anything
        // — the artist was in Weights mode, clicking, and nothing happened.
        // Painting weights needs a mesh to paint onto, not permission to move
        // its vertices.
        guard scene.isMeshEditEnabled
                || scene.meshWeightPaintEnabled
                || scene.isAnimationEditingEnabled else { return }

        // Not while painting. `hitTestScreen` returns the topmost image covering
        // the point with no regard for what is selected, so a brush stroke that
        // strayed over a neighbouring sprite — or merely passed under one drawn
        // in front — re-selected it and carried on painting the wrong mesh. The
        // artist picks the sprite; the brush never does.
        //
        // And not on a single click at all, once something is selected. A click
        // in Mesh mode is an edit; the node it places lands on whatever sprite
        // is drawn where the node belongs, which is often a sprite in FRONT of
        // the one being meshed. Double-click switches; single click meshes.
        // `ToolUtilities.meshModeMayChangeSelection` is the rule, shared with
        // ToolManager's selection block.
        let selectedBeforeThisTool = scene.selectedImageID
        if !scene.isWeightPaintStroke,
           let hit = ToolUtilities.hitTestScreen(
            screenPoint: input.screenPosition,
            viewSize: input.viewSize,
            scene: scene,
            assets: assets,
            camera: input.camera
           ),
           ToolUtilities.meshModeMayChangeSelection(
            to: hit, selectedID: scene.selectedImageID, clickCount: input.clickCount
           ) {
            scene.selectMeshLayer(for: hit)
        }

        // A CLICK THAT CHOOSES THE SPRITE IS SPENT ON CHOOSING IT.
        //
        // Whether `ToolManager` switched the selection (`didChangeSelection`) or
        // the block just above did, this click was the artist saying WHICH png
        // to mesh — and it must not also mesh it. With Add active it did: tap a
        // sprite to select it and a node appeared exactly where the tap landed,
        // on every sprite, every time, including the very first one. Nothing
        // below runs; the next click is the first edit.
        if input.didChangeSelection || scene.selectedImageID != selectedBeforeThisTool {
            pendingEmptyClick = false
            resetDragState(scene: scene)
            return
        }

        guard let selectedID = scene.selectedImageID,
              let image = scene.image(for: selectedID),
              let asset = assets.asset(for: image.assetID) else {
            pendingEmptyClick = false
            scene.selectMeshVertices([])
            resetDragState(scene: scene)
            return
        }

        if scene.isMeshCreatingHull && !scene.isAnimationEditingEnabled {
            pendingEmptyClick = false
            let localPosition = ToolUtilities.localCoordinates(for: input.position, image: image)
            if let firstIndex = image.mesh.hullVertexIndices.first.map(Int.init),
               image.mesh.vertices.indices.contains(firstIndex) {
                let firstVertex = image.mesh.vertices[firstIndex]
                if simd_distance(localPosition, firstVertex) <= 12 / max(image.scale.x, 0.001),
                   image.mesh.hullVertexIndices.count >= 3 {
                    scene.finishNewMesh()
                    resetDragState(scene: scene)
                    return
                }
            }
            _ = scene.appendMeshHullVertex(imageID: selectedID, localPosition: localPosition, assetSize: asset.size)
            return
        }

        // WEIGHTS OWNS THE CLICK, WITH OR WITHOUT A COLOUR.
        //
        // The test used to be `meshWeightPaintEnabled && activeWeightPaintBoneID
        // != nil`, and every branch inside it that asked "what if no bone is
        // armed?" was therefore unreachable — the pointer fallback below could
        // not run, and a click with the Weights panel open fell through to the
        // mesh sub-modes instead. With Create left active from the Mesh tab
        // that meant a click in Weights QUIETLY ADDED A NODE. Whether the brush
        // owns the click is a question about the MODE; whether it paints is a
        // question about the colour, and they are asked separately now.
        if scene.meshWeightPaintEnabled {
            pendingEmptyClick = false

            // THE CANVAS IS A COLOUR PICKER TOO. Reaching the bound-bones list
            // for every switch is the slow way round, and the list does not say
            // WHERE on the sprite a bone is. Clicking the bone does both.
            let boundIDs = scene.boundBoneIDs(imageID: selectedID)
            let boneHit = ToolUtilities.hitTestBone(
                screenPoint: input.screenPosition,
                viewSize: input.viewSize,
                scene: scene,
                camera: input.camera
            )
            // `weightPaintMayChangeBone` is the rule — double click once armed,
            // single click when nothing is, and never a bone this sprite is not
            // bound to.
            if let boneHit,
               ToolUtilities.weightPaintMayChangeBone(
                to: boneHit,
                armedBoneID: scene.activeWeightPaintBoneID,
                boundBoneIDs: boundIDs,
                clickCount: input.clickCount
               ) {
                if let taken = weightsBeforePaintClick, taken.imageID == selectedID {
                    scene.restoreMeshWeights(imageID: taken.imageID, weights: taken.weights)
                }
                weightsBeforePaintClick = nil
                scene.activeWeightPaintBoneID = boneHit
                lastPaintWorld = nil
                resetDragState(scene: scene)
                return
            }

            // WITH NO COLOUR CHOSEN THE BRUSH IS A POINTER. There is no bone to
            // paint into, so a click picks a node instead — and the one picked
            // is then the only one the brush touches, until the artist picks
            // another or clears the selection.
            guard scene.activeWeightPaintBoneID != nil else {
                weightsBeforePaintClick = nil
                if let hit = ToolUtilities.hitTestMeshVertex(
                    screenPoint: input.screenPosition,
                    viewSize: input.viewSize,
                    scene: scene,
                    assets: assets,
                    camera: input.camera
                ) {
                    scene.selectMeshVertices([hit])
                } else {
                    scene.selectMeshVertices([])
                }
                resetDragState(scene: scene)
                return
            }

            // Kept only when the stamp lands on a bone a second click could
            // arm. Everywhere else there is nothing to take back, and copying
            // the weight array on every stamp of a stroke would be a cost paid
            // for nothing.
            if let boneHit, boundIDs.contains(boneHit) {
                weightsBeforePaintClick = (selectedID, image.mesh.vertexBoneWeights)
            } else {
                weightsBeforePaintClick = nil
            }
            lastPaintWorld = input.position
            scene.paintSelectedMeshWeights(worldPoint: input.position,
                                           assetSize: asset.size)
            return
        }

        let hitVertexIndex = ToolUtilities.hitTestMeshVertex(
            screenPoint: input.screenPosition,
            viewSize: input.viewSize,
            scene: scene,
            assets: assets,
            camera: input.camera
        )
        switch scene.meshEditToolMode {
        case .delete:
            guard !scene.isAnimationEditingEnabled else { break }
            pendingEmptyClick = false
            if let vertexIndex = hitVertexIndex {
                scene.selectMeshVertices([vertexIndex])
                scene.deleteSelectedMeshVertices()
                resetDragState(scene: scene)
                return
            }
            return
        case .create:
            guard !scene.isAnimationEditingEnabled else { break }
            pendingEmptyClick = false
            let localPosition = ToolUtilities.localCoordinates(for: input.position, image: image)
            let clampedStartLocal = clampedToMeshInterior(localPosition, image: image, assetSize: asset.size)
            // The clamp is a convenience for a click just OUTSIDE the hull, so a
            // node lands on the edge without pixel aim. It is not for a click on
            // the other side of the canvas: the FIRST click of a double-click on
            // another png lands far from this sprite, and the clamp dragged it
            // onto the nearest hull edge as a node nobody asked for. Past the
            // reach, the click belongs to nothing.
            if let camera = input.camera {
                let clampedScreen = camera.worldToScreen(
                    localToWorld(clampedStartLocal, image: image), viewSize: input.viewSize)
                if simd_distance(clampedScreen, input.screenPosition) > Self.createClampReachPx {
                    resetDragState(scene: scene)
                    return
                }
            }
            scene.selectMeshInternalEdge(nil)
            createEdgeStartImageID = selectedID
            createEdgeStartVertexIndex = hitVertexIndex
            createEdgeStartLocalPosition = clampedStartLocal
            createEdgeDidDrag = false
            let previewStartWorld = localToWorld(clampedStartLocal, image: image)
            scene.meshCreateEdgePreviewStart = previewStartWorld
            scene.meshCreateEdgePreviewEnd = previewStartWorld
            if let vertexIndex = hitVertexIndex {
                scene.selectMeshVertices([vertexIndex])
            }
            return
        case .modify:
            break
        }

        if let vertexIndex = hitVertexIndex {
            pendingEmptyClick = false
            if input.isShiftPressed {
                if scene.selectedMeshVertexIndices.contains(vertexIndex) {
                    scene.removeMeshVertexFromSelection(vertexIndex)
                } else {
                    scene.addMeshVertexToSelection(vertexIndex)
                }
            } else {
                scene.selectMeshVertices([vertexIndex])
            }

            let selectedVertices = scene.selectedMeshVertexIndices.isEmpty ? [vertexIndex] : Array(scene.selectedMeshVertexIndices).sorted()
            beginVertexDrag(
                image: image,
                selectedID: selectedID,
                selectedVertices: selectedVertices,
                localPosition: ToolUtilities.localCoordinates(for: input.position, image: image),
                scene: scene,
                assetSize: asset.size
            )
            return
        }

        pendingEmptyClick = true
        resetDragState(scene: scene)
    }

    func onMouseDrag(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        // If we already started a vertex drag on mouseDown, keep dragging that vertex
        // instead of switching to paint mid-stroke.
        if scene.meshWeightPaintEnabled {
            // No colour, no stroke: with no bone chosen a drag is a selection
            // gesture, not a paint one.
            guard scene.activeWeightPaintBoneID != nil,
                  let imageID = scene.selectedImageID,
                  let image = scene.image(for: imageID),
                  let asset = assets.asset(for: image.assetID) else { return }
            // A stroke, not half a double click: the stamp the press laid
            // down is part of it and stays.
            weightsBeforePaintClick = nil
            // From the last stamp, not from nothing: a stroke has to cover the
            // path between two pointer samples or it paints a row of dots.
            let start = lastPaintWorld ?? input.position
            scene.paintSelectedMeshWeights(from: start, to: input.position,
                                           assetSize: asset.size)
            lastPaintWorld = input.position
            return
        }

        if let startImageID = createEdgeStartImageID,
           let image = scene.image(for: startImageID),
           let asset = assets.asset(for: image.assetID) {
            let currentLocal = ToolUtilities.localCoordinates(for: input.position, image: image)
            let clampedLocal = clampedToMeshInterior(currentLocal, image: image, assetSize: asset.size)
            scene.meshCreateEdgePreviewEnd = localToWorld(clampedLocal, image: image)
            let dragDistance = simd_length(input.screenPosition - input.startScreenPosition)
            if dragDistance >= Self.createDragThresholdPx {
                createEdgeDidDrag = true
            }
            return
        }

        _ = assets
        guard let activeImageID,
              let image = scene.image(for: activeImageID),
              let asset = assets.asset(for: image.assetID) else { return }
        let currentLocalPosition = ToolUtilities.localCoordinates(for: input.position, image: image)
        let delta = currentLocalPosition - dragStartLocalPosition
        // ONE PATH. Dragging a node moves the NODE.
        //
        // There used to be two, chosen by `isMeshOverlayDeformed` — which is
        // Show Deform, a VIEW option. A view option decided what an edit did,
        // and the branch it chose when Show Deform was off never moved the
        // vertex at all: it wrote the UV alone. So the geometry stayed put
        // while the texture slid inside the fixed triangles, and since
        // `updateMeshUV` clamps to 0...1, dragging past the border pinned
        // neighbouring UVs to the same texel and smeared one column of pixels
        // across the strip between them. That is the doubled, mirrored look in
        // the report: not a rendering bug, a drag that moved the picture
        // instead of the point.
        //
        // What each mode means now, and it is the same gesture in both:
        //
        //   EDITOR  — vertex AND uv move together, so the node slides across
        //             stationary artwork. The mesh is being fitted to the png;
        //             the png does not warp.
        //   ANIMATOR — the vertex moves and the uv does not, so the artwork
        //             follows the node. That is a deform, and it is the only
        //             place one is authored.
        //
        // `updateMeshVertex` already routes to `meshAnimationDeform` while
        // animating and to `mesh.vertices` otherwise, so the split lives in one
        // place rather than being restated here.
        for vertexIndex in activeVertexIndices {
            let weight = dragInfluenceWeights[vertexIndex] ?? 1
            let weightedDelta = delta * weight
            guard let startPosition = dragStartVertexPositions[vertexIndex] else { continue }
            scene.updateMeshVertex(imageID: activeImageID, vertexIndex: vertexIndex,
                                   localPosition: startPosition + weightedDelta)
            if !scene.isAnimationEditingEnabled, let startUV = dragStartVertexUVs[vertexIndex] {
                let uvDelta = SIMD2<Float>(weightedDelta.x / asset.size.x,
                                           -weightedDelta.y / asset.size.y)
                scene.updateMeshUV(imageID: activeImageID, vertexIndex: vertexIndex,
                                   uv: startUV + uvDelta, assetSize: asset.size)
            }
        }
    }

    func onMouseUp(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        lastPaintWorld = nil
        scene.endInteraction()
        if scene.meshEditToolMode == .create,
           let startImageID = createEdgeStartImageID,
           let startLocalPosition = createEdgeStartLocalPosition,
           scene.selectedImageID == startImageID,
           let image = scene.image(for: startImageID),
           let asset = assets.asset(for: image.assetID) {
            let alphaSampler = makeAlphaSampler(for: asset.fileURL)
            let releaseLocalPosition = ToolUtilities.localCoordinates(for: input.position, image: image)
            let clampedReleaseLocal = clampedToMeshInterior(releaseLocalPosition, image: image, assetSize: asset.size)
            let releaseHitVertex = ToolUtilities.hitTestMeshVertex(
                screenPoint: input.screenPosition,
                viewSize: input.viewSize,
                scene: scene,
                assets: assets,
                camera: input.camera
            )

            if createEdgeDidDrag {
                let startVertexIndex = createEdgeStartVertexIndex
                    ?? scene.insertMeshInteriorVertex(
                        imageID: startImageID,
                        localPosition: startLocalPosition,
                        assetSize: asset.size,
                        alphaSampler: alphaSampler
                    )

                let endVertexIndex = releaseHitVertex ?? {
                    return scene.insertMeshInteriorVertex(
                        imageID: startImageID,
                        localPosition: clampedReleaseLocal,
                        assetSize: asset.size,
                        alphaSampler: alphaSampler
                    )
                }()

                if let startVertexIndex,
                   let endVertexIndex,
                   startVertexIndex != endVertexIndex {
                    scene.connectMeshVertices(startVertexIndex, endVertexIndex)
                }
            } else {
                if let hitVertex = releaseHitVertex {
                    scene.selectMeshVertices([hitVertex])
                } else if let edgeIndex = ToolUtilities.hitTestMeshHullEdge(
                    screenPoint: input.screenPosition,
                    viewSize: input.viewSize,
                    scene: scene,
                    assets: assets,
                    camera: input.camera
                ) {
                    _ = scene.insertMeshVertex(
                        imageID: startImageID,
                        localPosition: clampedReleaseLocal,
                        afterHullEdge: edgeIndex,
                        alphaSampler: alphaSampler,
                        assetSize: asset.size
                    )
                } else {
                    _ = scene.insertMeshInteriorVertex(
                        imageID: startImageID,
                        localPosition: clampedReleaseLocal,
                        assetSize: asset.size,
                        alphaSampler: alphaSampler
                    )
                }
            }

            scene.constrainMeshInteriorVertices(imageID: startImageID, assetSize: asset.size)
        }

        _ = assets
        if pendingEmptyClick {
            let dragDistance = simd_length(input.screenPosition - input.startScreenPosition)
            if dragDistance < 3 {
                scene.selectMeshVertices([])
                scene.selectMeshInternalEdge(nil)
            }
        }
        let pendingDeformImageID = activeImageID
        pendingEmptyClick = false
        resetDragState(scene: scene)
        if scene.isAnimationEditingEnabled, let imageID = pendingDeformImageID {
            scene.commitMeshDeformKeyframe(imageID: imageID)
        }
        if scene.selectedImageID == nil {
            scene.selectMeshVertices([])
        }
    }

    /// Abandon the edge that is half drawn, keeping everything already made.
    ///
    /// The Cancel on the canvas prompt. It exists only while there IS a half
    /// drawn edge — an edge that has one end and no other — because with
    /// nothing pending, Cancel and Finish would do the same thing and one of
    /// them would be lying about being destructive.
    func cancelPendingCreateEdge(scene: SceneManager) {
        createEdgeStartImageID = nil
        createEdgeStartVertexIndex = nil
        scene.meshCreateEdgePreviewStart = nil
        scene.meshCreateEdgePreviewEnd = nil
    }

    /// `scene` is REQUIRED, not optional.
    ///
    /// It used to default to nil, and `onMouseUp` called it with nothing — so
    /// the two lines that clear the Create preview ran against a nil optional
    /// and did nothing. The green start dot is drawn from that preview, so it
    /// was painted on mouse-down and never removed: it sat at the last tap
    /// position for the rest of the session, including with the Pencil nowhere
    /// near the glass. A reset that silently does half its job is worse than
    /// one that does not compile.
    private func resetDragState(scene: SceneManager) {
        activeImageID = nil
        activeVertexIndices = []
        dragStartLocalPosition = .zero
        dragStartVertexPositions = [:]
        dragStartVertexUVs = [:]
        dragInfluenceWeights = [:]
        createEdgeStartImageID = nil
        createEdgeStartVertexIndex = nil
        createEdgeStartLocalPosition = nil
        createEdgeDidDrag = false
        scene.meshCreateEdgePreviewStart = nil
        scene.meshCreateEdgePreviewEnd = nil
    }

    private func beginVertexDrag(
        image: SceneImage,
        selectedID: UUID,
        selectedVertices: [Int],
        localPosition: SIMD2<Float>,
        scene: SceneManager,
        assetSize: SIMD2<Float>
    ) {
        // `ToolUtilities.softSelectionWeights` computes the falloff — inner
        // radius, feather, smoothstep, optional hull exclusion — and NOTHING
        // called it. Every selected vertex was given a flat 1, so the toggle,
        // the radius, the feather and the exclude-hull flag were all in the
        // inspector and in the saved project driving nothing. A setting that is
        // offered, persisted and ignored is worse than one that is absent.
        let influenceWeights: [Int: Float]
        if scene.meshSoftSelectionEnabled {
            let soft = ToolUtilities.softSelectionWeights(
                for: image,
                assetSize: assetSize,
                selectedIndices: Set(selectedVertices),
                showDeformed: scene.isMeshOverlayDeformed,
                radius: scene.meshSoftSelectionRadius,
                feather: scene.meshSoftSelectionFeather,
                excludeHull: scene.meshSoftSelectionExcludeHull
            )
            influenceWeights = soft.isEmpty
                ? Dictionary(uniqueKeysWithValues: selectedVertices.map { ($0, 1.0 as Float) })
                : soft
        } else {
            influenceWeights = Dictionary(uniqueKeysWithValues: selectedVertices.map { ($0, 1.0 as Float) })
        }
        activeImageID = selectedID
        dragInfluenceWeights = influenceWeights
        activeVertexIndices = Array(influenceWeights.keys).sorted()
        dragStartLocalPosition = localPosition
        // FROM WHERE THE NODE IS DRAWN. `editLocalVertices` is what the overlay
        // and the hit test both use, so the drag starts at the marker the artist
        // grabbed rather than at a second opinion about where it is. With Show
        // Deform off those two answers differ — the overlay places nodes from
        // the uvs — and reading `mesh.vertices` here would make the node jump
        // on the first pixel of the drag.
        let sourceVertices = ToolUtilities.editLocalVertices(
            for: image, assetSize: assetSize,
            showDeformed: scene.isMeshOverlayDeformed,
            mesh: ToolUtilities.resolvedMesh(for: image, assetSize: assetSize)
        )
        dragStartVertexPositions = Dictionary(uniqueKeysWithValues: activeVertexIndices.compactMap { index in
            guard sourceVertices.indices.contains(index) else { return nil }
            return (index, sourceVertices[index])
        })
        dragStartVertexUVs = Dictionary(uniqueKeysWithValues: activeVertexIndices.compactMap { index in
            guard image.mesh.uvs.indices.contains(index) else { return nil }
            return (index, image.mesh.uvs[index])
        })
    }

    /// How far outside the hull, in screen pixels, a Create click may land and
    /// still be pulled onto the edge. The same reach picking gives a thin
    /// sprite, scaled for touch.
    static var createClampReachPx: Float { 12 * ToolUtilities.touchHitScale }

    /// How far the pointer must travel before Create treats the gesture as
    /// DRAWING AN EDGE rather than placing a node.
    ///
    /// It was 1.0 — one drawable pixel, which on a 2x iPad is half a point.
    /// A mouse click moves exactly zero, so it never tripped and the Mac placed
    /// one node. An Apple Pencil never moves zero: a tap always wanders further
    /// than half a point, so every tap was read as a drag, and the drag branch
    /// creates a vertex at the start AND a vertex at the release — two nodes
    /// per tap, joined by an edge nobody asked for. That is the whole of the
    /// reported bug, and it could only ever appear on the Pencil.
    ///
    /// Six points, scaled for touch like every other tolerance here, matching
    /// `TouchInputMTKView.fingerDownSlop` — the distance that view already
    /// treats as "the artist meant to move this".
    static var createDragThresholdPx: Float { 6 * ToolUtilities.touchHitScale }

    private func clampedToMeshInterior(_ localPoint: SIMD2<Float>, image: SceneImage, assetSize: SIMD2<Float>) -> SIMD2<Float> {
        let mesh = ToolUtilities.resolvedMesh(for: image, assetSize: assetSize)
        let hullIndices = mesh.hullVertexIndices.map(Int.init)
        guard hullIndices.count >= 3 else { return localPoint }

        var polygon: [SIMD2<Float>] = []
        polygon.reserveCapacity(hullIndices.count)
        for index in hullIndices where mesh.vertices.indices.contains(index) {
            polygon.append(mesh.vertices[index])
        }
        guard polygon.count >= 3 else { return localPoint }

        if pointInsidePolygon(localPoint, polygon: polygon) {
            return localPoint
        }

        var bestPoint = polygon[0]
        var bestDistance = Float.greatestFiniteMagnitude
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            let projected = closestPointOnSegment(point: localPoint, a: a, b: b)
            let distance = simd_distance(localPoint, projected)
            if distance < bestDistance {
                bestDistance = distance
                bestPoint = projected
            }
        }
        return bestPoint
    }

    private func pointInsidePolygon(_ point: SIMD2<Float>, polygon: [SIMD2<Float>]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var isInside = false
        var previous = polygon.last!
        for current in polygon {
            let intersects = ((current.y > point.y) != (previous.y > point.y))
                && (point.x < (previous.x - current.x) * (point.y - current.y) / ((previous.y - current.y) + 0.000001) + current.x)
            if intersects {
                isInside.toggle()
            }
            previous = current
        }
        return isInside
    }

    private func closestPointOnSegment(point: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>) -> SIMD2<Float> {
        let ab = b - a
        let lengthSquared = simd_dot(ab, ab)
        guard lengthSquared > 0.000001 else { return a }
        let t = max(0, min(1, simd_dot(point - a, ab) / lengthSquared))
        return a + ab * t
    }

    private func localToWorld(_ local: SIMD2<Float>, image: SceneImage) -> SIMD2<Float> {
        let rotationDeg = image.rotation * 180 / Float.pi
        return MatrixUtilities.shearedWorldTransform(
            local: local,
            position: image.position,
            rotation: rotationDeg,
            shear: image.skew,
            scale: image.scale
        )
    }

    private func makeAlphaSampler(for fileURL: URL) -> ((Int, Int) -> Float)? {
        guard let data = try? Data(contentsOf: fileURL),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let ctx = CGContext(data: &pixels,
                                  width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return { x, y in
            let cx = min(max(x, 0), width - 1)
            let cy = min(max(y, 0), height - 1)
            return Float(pixels[cy * bytesPerRow + cx * bytesPerPixel + 3]) / 255.0
        }
    }
}
