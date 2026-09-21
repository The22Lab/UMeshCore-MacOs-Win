import Foundation

/// One way out, and it peels one layer at a time.
///
/// The iPad has no Escape key, and the request was a single control that gets
/// out of "cualquier modo — mesh, bones create, weight, piezas seleccionadas".
/// The tempting reading is "a button that clears everything". That button is
/// worse than no button: an artist three levels deep in a weight-paint session
/// taps it to drop a vertex selection and loses the mode, the tool and the
/// sprite as well, with no undo — selection is not undoable.
///
/// So it is a LADDER. Everything the artist can be inside is ordered from the
/// most transient to the most settled, and one press leaves exactly one rung.
/// Press it repeatedly and you walk out the way you came in. The control names
/// the rung it is about to leave, so the next press is never a surprise.
///
/// The order below is the whole design, and it is a total order on purpose:
/// two things at the same depth would make the button's behaviour depend on
/// which check ran first.
enum EditorScope: Int, CaseIterable, Comparable {
    /// The IK builder is waiting for a bone to be tapped.
    case ikBuilderPick
    /// The IK builder is open but not waiting on anything.
    case ikBuilderDraft
    /// Vertices are selected inside a mesh edit.
    case meshVertexSelection
    /// Weight paint is on, inside a mesh edit.
    case weightPaint
    /// A mesh is being edited.
    case meshEdit
    /// Bind mode is picking a bone for the selected sprite.
    case bindBones
    /// One or more bones are selected.
    case boneSelection
    /// One or more sprites, or a constraint, are selected.
    case imageSelection
    /// A tool other than Select is active — Bone, Mesh, Weight, Rotate.
    case activeTool

    static func < (lhs: EditorScope, rhs: EditorScope) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// What the control says it will do. Short, because it sits in a corner of
    /// the canvas.
    var exitTitle: String {
        switch self {
        case .ikBuilderPick:      return "Cancel Pick"
        case .ikBuilderDraft:     return "Close IK Builder"
        case .meshVertexSelection: return "Deselect Vertices"
        case .weightPaint:        return "Exit Weight Paint"
        case .meshEdit:           return "Exit Mesh Edit"
        case .bindBones:          return "Exit Bind Mode"
        case .boneSelection:      return "Deselect Bones"
        case .imageSelection:     return "Deselect"
        case .activeTool:         return "Back to Select"
        }
    }
}

/// The ladder, as a function of what is true right now.
///
/// Pure and snapshot-based so it can be checked exhaustively rather than
/// argued about: `Editor/verify_escape_ladder.py` walks every reachable
/// combination of the flags below and proves that pressing the control always
/// terminates, always strictly descends, and never leaves a rung behind.
enum EditorEscape {

    /// Everything the ladder reads, and nothing else.
    struct State: Equatable {
        var isPickingIKBone = false
        var hasIKDraft = false
        var selectedMeshVertexCount = 0
        var isWeightPainting = false
        var isMeshEditing = false
        var isBindingBones = false
        var selectedBoneCount = 0
        var selectedImageCount = 0
        var hasSelectedConstraint = false
        /// False when the active tool is Select.
        var hasNonDefaultTool = false
    }

    /// The innermost rung the artist is standing on, or nil when they are out.
    static func deepest(_ state: State) -> EditorScope? {
        if state.isPickingIKBone { return .ikBuilderPick }
        if state.hasIKDraft { return .ikBuilderDraft }
        // Only meaningful inside a mesh edit: vertices cannot be selected
        // outside one, and reading the count alone would strand the ladder on a
        // rung that no press can clear.
        if state.isMeshEditing, state.selectedMeshVertexCount > 0 {
            return .meshVertexSelection
        }
        if state.isWeightPainting { return .weightPaint }
        if state.isMeshEditing { return .meshEdit }
        if state.isBindingBones { return .bindBones }
        if state.selectedBoneCount > 0 { return .boneSelection }
        if state.selectedImageCount > 0 || state.hasSelectedConstraint {
            return .imageSelection
        }
        if state.hasNonDefaultTool { return .activeTool }
        return nil
    }

    /// The state after leaving one rung.
    ///
    /// Modelled here as well as applied for real, so the property that matters
    /// — that a press always descends and never climbs — is checkable without
    /// a running editor.
    static func leaving(_ scope: EditorScope, from state: State) -> State {
        var next = state
        switch scope {
        case .ikBuilderPick:
            next.isPickingIKBone = false
        case .ikBuilderDraft:
            next.hasIKDraft = false
        case .meshVertexSelection:
            next.selectedMeshVertexCount = 0
        case .weightPaint:
            next.isWeightPainting = false
        case .meshEdit:
            // Leaving the mesh takes what lives inside it. Otherwise the next
            // press would find a vertex selection belonging to an edit that is
            // over — a rung under a ladder that has been taken away.
            next.isMeshEditing = false
            next.selectedMeshVertexCount = 0
            next.isWeightPainting = false
        case .bindBones:
            next.isBindingBones = false
        case .boneSelection:
            next.selectedBoneCount = 0
        case .imageSelection:
            next.selectedImageCount = 0
            next.hasSelectedConstraint = false
        case .activeTool:
            next.hasNonDefaultTool = false
        }
        return next
    }
}
