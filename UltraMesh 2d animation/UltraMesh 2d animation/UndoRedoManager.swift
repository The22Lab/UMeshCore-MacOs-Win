import Foundation
import Combine

/// Snapshot of mutable scene state — both are value types so copying is O(N) but safe.
struct SceneSnapshot {
    let images: [SceneImage]
    let skeleton: Skeleton
    /// Scene-wide animation tracks: constraint properties and draw order.
    /// Included so undo restores constraint keys and draw-order keys exactly
    /// like it restores bone and sprite keys.
    let sceneAnimationClip: AnimationClip
    /// Authored (setup pose) constraint values, restored alongside the clip so
    /// undoing a keyed change cannot leave a constraint at an evaluated value.
    let constraintSetupValues: [UUID: ConstraintSetupValues]
    /// Skins and the one being previewed. Slot membership itself lives on the
    /// sprites and therefore already travels in `images`.
    let skins: [Skin]
    let activeSkinID: UUID?
    /// Event definitions. The keys that raise them already travel in
    /// `sceneAnimationClip`.
    let animationEvents: [AnimationEvent]
    /// Scene compositions and which one is open. Included so undoing an Align
    /// Camera to View, a layer edit or a scene deletion restores the SHOT —
    /// without these, undo would roll the rig back and leave the camera where
    /// the mistake put it. The fly camera is deliberately absent: where the
    /// artist is standing is not an edit.
    let sceneCompositions: [SceneComposition]
    let selectedSceneCompositionID: UUID?

    init(
        images: [SceneImage],
        skeleton: Skeleton,
        sceneAnimationClip: AnimationClip = AnimationClip(name: "Scene"),
        constraintSetupValues: [UUID: ConstraintSetupValues] = [:],
        skins: [Skin] = [],
        activeSkinID: UUID? = nil,
        animationEvents: [AnimationEvent] = [],
        sceneCompositions: [SceneComposition] = [],
        selectedSceneCompositionID: UUID? = nil
    ) {
        self.images = images
        self.skeleton = skeleton
        self.sceneAnimationClip = sceneAnimationClip
        self.constraintSetupValues = constraintSetupValues
        self.skins = skins
        self.activeSkinID = activeSkinID
        self.animationEvents = animationEvents
        self.sceneCompositions = sceneCompositions
        self.selectedSceneCompositionID = selectedSceneCompositionID
    }
}

final class UndoRedoManager: ObservableObject {
    private let maxDepth = 80

    private var undoStack: [SceneSnapshot] = []
    private var redoStack: [SceneSnapshot] = []

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Push the current state before a mutation. Clears the redo stack.
    func push(_ snapshot: SceneSnapshot) {
        undoStack.append(snapshot)
        if undoStack.count > maxDepth { undoStack.removeFirst() }
        redoStack.removeAll()
        sync()
    }

    /// Returns the state to restore, saving `current` for redo.
    func undo(current: SceneSnapshot) -> SceneSnapshot? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        sync()
        return previous
    }

    /// Returns the state to restore, saving `current` for undo.
    func redo(current: SceneSnapshot) -> SceneSnapshot? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        sync()
        return next
    }

    private func sync() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}
