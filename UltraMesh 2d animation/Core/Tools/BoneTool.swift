import Foundation
import simd

final class BoneTool: Tool {
    let type: ActiveTool = .bone

    private enum Interaction {
        case create(parentID: UUID?, start: SIMD2<Float>)
        case moveRoot(UUID)
        case moveTip(UUID)
    }

    private enum HitPart {
        case start
        case end
        case segment
    }

    private var interaction: Interaction?
    private var currentPreview: SIMD2<Float>?
    private var mouseDownPosition: SIMD2<Float>?
    private var moveThresholdExceeded = false

    #if os(iOS)
    // iOS: larger targets for comfortable finger + Pencil use.
    // Drawable pixels; at 2× display scale: joint≈26pt, segment≈16pt.
    private let jointRadius: Float = 52
    private let lineRadius: Float  = 32
    private let clickDragThreshold: Float = 8
    #else
    private let jointRadius: Float = 12
    private let lineRadius: Float  = 9
    private let clickDragThreshold: Float = 4
    #endif

    func onMouseDown(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        scene.beginInteraction()
        _ = assets
        if let hit = hitTestBonePart(
            screenPoint: input.screenPosition,
            viewSize: input.viewSize,
            scene: scene,
            camera: input.camera
        ) {
            if input.isCommandPressed || input.isShiftPressed {
                // Cmd-click toggles the bone in the multi-selection without
                // starting a drag — matches macOS finder/list conventions.
                scene.toggleBoneSelection(hit.id)
                interaction = nil
                currentPreview = nil
                scene.setBoneCreationPreview(start: nil, end: nil)
                return
            }
            scene.selectBone(hit.id)
            currentPreview = nil
            interaction = interactionForHit(hit, input: input)
            mouseDownPosition = input.position
            moveThresholdExceeded = false
            if case let .create(_, start) = interaction {
                currentPreview = input.position
                scene.setBoneCreationPreview(start: start, end: input.position)
            } else {
                scene.setBoneCreationPreview(start: nil, end: nil)
            }
            return
        }

        let chainParentID = scene.selectedBoneID
        interaction = .create(parentID: chainParentID, start: input.position)
        currentPreview = input.position
        mouseDownPosition = input.position
        moveThresholdExceeded = true  // create mode always tracks drag from frame 0
        scene.setBoneCreationPreview(start: input.position, end: input.position)
    }

    func onMouseDrag(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        _ = assets
        guard let interaction else { return }
        switch interaction {
        case let .create(_, start):
            currentPreview = input.position
            scene.setBoneCreationPreview(start: start, end: input.position)
        case let .moveRoot(boneID):
            guard ensureDragStarted(currentPosition: input.position) else { return }
            scene.moveBoneRoot(id: boneID, to: input.position)
        case let .moveTip(boneID):
            guard ensureDragStarted(currentPosition: input.position) else { return }
            scene.moveBoneTip(id: boneID, to: input.position)
        }
    }

    // Returns true once the cursor has moved beyond the click/drag threshold
    // since mouseDown. Prevents micro-jitter on a click from being interpreted
    // as a drag that teleports a bone joint.
    private func ensureDragStarted(currentPosition: SIMD2<Float>) -> Bool {
        if moveThresholdExceeded { return true }
        guard let down = mouseDownPosition else { return false }
        if simd_distance(currentPosition, down) >= clickDragThreshold {
            moveThresholdExceeded = true
            return true
        }
        return false
    }

    func onMouseUp(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        scene.endInteraction()
        _ = assets
        defer {
            interaction = nil
            currentPreview = nil
            mouseDownPosition = nil
            moveThresholdExceeded = false
            scene.setBoneCreationPreview(start: nil, end: nil)
        }

        guard let interaction else { return }
        guard case let .create(parentID, start) = interaction else { return }
        let end = currentPreview ?? input.position
        guard simd_distance(start, end) >= 8 else {
            // A CLICK ON EMPTY CANVAS, which is a press and a release that
            // never travelled far enough to be a bone. It used to be nothing at
            // all: no bone made, and nothing cleared either, so the next drag
            // still chained off whatever was selected before it and there was
            // no way to start a second root without going to the hierarchy.
            //
            // It breaks the chain now. The SAME condition decides both, so
            // "too short to be a bone" and "a click that cancels" cannot drift
            // apart into two thresholds that disagree.
            scene.selectBone(nil)
            return
        }
        scene.addBone(start: start, end: end, parentID: parentID)
    }

    private func interactionForHit(_ hit: (id: UUID, part: HitPart), input: ToolInput) -> Interaction? {
        switch hit.part {
        case .start, .segment:
            return .moveRoot(hit.id)
        case .end:
            // A TIP MEANS "CARRY ON FROM HERE".
            //
            // It used to mean "resize this bone", with Shift for chaining —
            // which put the one gesture you want after making a bone behind a
            // modifier, and made the obvious gesture do something else. Building
            // a run of short bones meant moving away from the tip, clicking
            // empty space and coming back for every one of them. The two are
            // swapped: Shift resizes, a plain drag chains.
            if input.isShiftPressed {
                return .moveTip(hit.id)
            }
            return .create(parentID: hit.id, start: input.position)
        }
    }

    private func hitTestBonePart(
        screenPoint: SIMD2<Float>,
        viewSize: SIMD2<Float>,
        scene: SceneManager,
        camera: CameraState?
    ) -> (id: UUID, part: HitPart)? {
        let segments = scene.skeleton.worldLineSegments()
        guard !segments.isEmpty else { return nil }

        // Joints and segments are tracked separately so joints always win when
        // both overlap — a segment at 8px never beats a joint at 12px.
        var bestJointHit: (id: UUID, part: HitPart)?
        var bestJointDist = Float.greatestFiniteMagnitude
        var bestSegHit:   (id: UUID, part: HitPart)?
        var bestSegDist   = Float.greatestFiniteMagnitude

        for (bone, start, end) in segments {
            let startScreen = camera?.worldToScreen(start, viewSize: viewSize) ?? (start + viewSize * 0.5)
            let endScreen   = camera?.worldToScreen(end,   viewSize: viewSize) ?? (end   + viewSize * 0.5)

            let startDist = simd_distance(screenPoint, startScreen)
            if startDist <= jointRadius && startDist < bestJointDist {
                bestJointDist = startDist
                bestJointHit  = (bone.id, .start)
            }

            let endDist = simd_distance(screenPoint, endScreen)
            if endDist <= jointRadius && endDist < bestJointDist {
                bestJointDist = endDist
                bestJointHit  = (bone.id, .end)
            }

            let lineDist = distancePointToSegment(point: screenPoint, a: startScreen, b: endScreen)
            if lineDist <= lineRadius && lineDist < bestSegDist {
                bestSegDist = lineDist
                bestSegHit  = (bone.id, .segment)
            }
        }

        // Joints take absolute priority — a joint hit always beats a segment hit.
        return bestJointHit ?? bestSegHit
    }

    private func distancePointToSegment(point: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>) -> Float {
        let ab = b - a
        let t = max(0, min(1, simd_dot(point - a, ab) / max(0.0001, simd_dot(ab, ab))))
        let projection = a + ab * t
        return simd_distance(point, projection)
    }
}
