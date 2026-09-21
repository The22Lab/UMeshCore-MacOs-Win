import SwiftUI

/// The four things a click on the canvas can be doing: posing the rig, shaping
/// a mesh, building bones, or painting weights.
///
/// Weight paint joined the others rather than staying a flag of its own. It was
/// managed by four separate assignments that all had to agree, and they did not
/// — the brush stayed live under another mode more than once. Being a case here
/// makes it mutually exclusive by construction.
enum CanvasMode: String, CaseIterable, Identifiable {
    case pose, mesh, bone, weights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pose:    return "Pose"
        case .mesh:    return "Mesh"
        case .bone:    return "Bones"
        case .weights: return "Weights"
        }
    }

    var systemImage: String {
        switch self {
        // The drawing's own glyph for Pose: a figure with its arms out. Mesh
        // and Bones have shapes of their own, drawn by the button row, so they
        // name no symbol here.
        case .pose:    return "figure.arms.open"
        case .mesh:    return ""            // drawn with MeshGlyph
        case .bone:    return ""          // drawn with BoneGlyph
        case .weights: return "paintbrush.fill"
        }
    }

    /// Whether this mode takes the inspector over.
    ///
    /// Mesh mode IS the mesh panel and Weights IS the weights panel. The
    /// inspector used to work this out from the two flags directly, which is
    /// a second reading of "which mode is on" living outside this type — the
    /// exact shape of the drift that once left Mesh Edit lit under Pose.
    var ownsInspector: Bool { self == .mesh || self == .weights }

    /// Everything except posing is Editor work.
    var requiresSkeletonMode: Bool { self != .pose }

    /// Mesh and weights act on a sprite; there is nothing to do without one.
    var requiresImage: Bool { self == .mesh || self == .weights }
}

/// Turning one canvas mode on turns the others off.
///
/// One implementation, because of what happened the last time there was more
/// than one. Each button used to carry its own copy of this bookkeeping and
/// they had already drifted: the Pose button cleared the bone tool, the Weights
/// button cleared it too but also reset pose, and the Bone button cleared both
/// without touching the mesh-edit flag. It was gathered into
/// `CanvasModePanel.select(_:)`; now that the Bones button lives on the canvas
/// and the other two stay in the toolbar strip, it has to be reachable from
/// both, so it lives here rather than inside either of them.
///
/// Clicking the mode that is already lit returns to plain selection.
enum CanvasModeSelection {

    /// Which mode is lit, or nil when the artist is just selecting things.
    @MainActor
    static func active(scene: SceneManager, tools: ToolManager) -> CanvasMode? {
        if scene.isPoseMode { return .pose }
        if scene.meshWeightPaintEnabled { return .weights }
        if scene.isMeshEditEnabled { return .mesh }
        if tools.currentTool == .bone { return .bone }
        return nil
    }

    @MainActor
    static func select(_ mode: CanvasMode, scene: SceneManager, tools: ToolManager) {
        let alreadyActive = active(scene: scene, tools: tools) == mode

        // Clear all of them first, every time. Leaving a mode is not something
        // each button gets to remember on its own — that is how Mesh Edit
        // stayed lit under Pose.
        scene.meshWeightPaintEnabled = false
        scene.isPoseMode = false
        scene.isMeshEditEnabled = false
        scene.isBindingBonesMode = false
        scene.pendingCanvasMode = nil
        // EVERY tool, not the two that happen to be modes of their own.
        // Translate, Rotate, Scale and Shear are canvas states as much as
        // Bones and Mesh are: naming only those two meant choosing Pose with
        // Rotate held left the toolbar saying Rotate and the strip saying
        // Pose, and a canvas drag did whichever was asked first. The mode
        // being entered picks its own tool below.
        if tools.currentTool != .select {
            tools.setTool(.select)
        }

        guard !alreadyActive else { return }
        enter(mode, scene: scene, tools: tools)
    }

    /// Turns a mode ON, without the toggle.
    ///
    /// `select` is what a BUTTON does: clicking the mode that is already lit
    /// returns to plain selection. Picking a mesh in the hierarchy is not that
    /// — it is always a request to work on that mesh — so it needs the half of
    /// `select` that enters, without the half that leaves. Split out rather
    /// than reimplemented at the call site: the entering rules (which sprite,
    /// which tool, which inspector tab) belong here with everything else that
    /// decides a mode.
    ///
    /// The caller is expected to have cleared the previous mode, which `select`
    /// does above; entering from the hierarchy goes through `selectMeshLayer`
    /// and the tool change, which clear it the same way.
    @MainActor
    static func enter(_ mode: CanvasMode, scene: SceneManager, tools: ToolManager) {
        switch mode {
        case .bone:
            tools.setTool(.bone)

        case .mesh:
            // Mesh editing needs a sprite. It ASKS for one rather than
            // refusing: "Select an image first" is a dead end, and the artist
            // has to work out for themselves that the button will behave
            // differently after a click somewhere else.
            guard let imageID = scene.selectedImageID else {
                scene.pendingCanvasMode = mode.rawValue
                scene.meshEditNotice = .info(
                    "Pick a sprite to mesh — click one on the canvas or in the "
                    + "hierarchy, and Mesh mode opens on it.")
                return
            }
            scene.selectMeshLayer(for: imageID)
            tools.setTool(.mesh)
            scene.isMeshEditEnabled = true
            scene.inspectorNavigationTarget = "mesh"

        case .pose:
            scene.isPoseMode = true
            scene.inspectorNavigationTarget = "pose"

        case .weights:
            // Same requirement as mesh, and the same answer: it asks.
            guard let imageID = scene.selectedImageID else {
                scene.pendingCanvasMode = mode.rawValue
                scene.meshEditNotice = .info(
                    "Pick a sprite to paint — click one on the canvas or in the "
                    + "hierarchy, and the brush opens on it.")
                return
            }
            scene.selectMeshLayer(for: imageID)
            tools.setTool(.mesh)
            scene.meshWeightPaintEnabled = true
        }
    }
}
