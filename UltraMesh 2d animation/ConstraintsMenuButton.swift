import SwiftUI

/// One entry point for every constraint type, including physics.
///
/// Physics used to be its own toolbar button, sitting beside Pose and Weights
/// as if it were a peer of them. It is not: it is one of four constraint kinds,
/// and the odd one out only because it also has a simulation you can run. As a
/// loose button it implied physics was a mode you enter, and it hid the fact
/// that IK, Transform and Path constraints existed at all unless you happened
/// to multi-select bones and find the menu in the inspector.
///
/// Everything a constraint can be is now in one place, with the requirement for
/// each spelled out rather than left as a greyed-out row with no explanation.
struct ConstraintsMenuButton: View {
    @ObservedObject var sceneManager: SceneManager
    @ObservedObject var toolManager: ToolManager

    private let accent = UM.animatorAccent

    private var selectedBoneCount: Int { sceneManager.selectedBoneIDs.count }
    private var isSimulating: Bool { sceneManager.isPhysicsPreviewActive }

    var body: some View {
        Menu {
            Section("Create") {
                Button {
                    // The builder, not a guess from the selection: inferring the
                    // target from hierarchy depth picks wrong for the standard
                    // setup where the target handle is an unparented bone.
                    sceneManager.beginIKBuilder()
                } label: { Label("IK Constraint…", systemImage: "link") }

                Button {
                    sceneManager.createTransformConstraintFromSelection()
                } label: { Label("Transform Constraint", systemImage: "move.3d") }
                    .disabled(selectedBoneCount < 2)

                Button {
                    sceneManager.createPathConstraintFromSelection()
                } label: {
                    Label("Path Constraint", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .disabled(selectedBoneCount < 3)

                Button {
                    sceneManager.createPhysicsConstraintFromSelection()
                } label: { Label("Physics Constraint", systemImage: "waveform.path") }
                    .disabled(selectedBoneCount < 2)
            }

            Section("Physics") {
                Button {
                    toggleSimulation()
                } label: {
                    Label(isSimulating ? "Stop Simulation" : "Simulate Physics",
                          systemImage: isSimulating ? "stop.fill" : "play.fill")
                }
            }

            Section {
                Text(requirementHint)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isSimulating ? "waveform.path.ecg" : "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text(isSimulating ? "Simulating" : "New Constraint")
                    .font(.system(size: 12, weight: .semibold))
                            Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(isSimulating ? UM.textOnAccent : UM.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: UM.controlRadius, style: .continuous)
                    .fill(isSimulating ? accent : UM.accentSoft)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    /// Says what the selection needs, instead of leaving rows greyed out with
    /// no reason given.
    private var requirementHint: String {
        switch selectedBoneCount {
        case 0: return "Select bones in the canvas to create a constraint."
        case 1: return "Transform and Physics need 2 bones; Path needs 3."
        case 2: return "Path constraints need 3 bones."
        default: return "Every constraint type is available for this selection."
        }
    }

    private func toggleSimulation() {
        sceneManager.meshWeightPaintEnabled = false
        sceneManager.isPoseMode = false
        if isSimulating {
            sceneManager.isPhysicsPreviewActive = false
            if toolManager.currentTool == .physicsPreview { toolManager.setTool(.select) }
        } else {
            sceneManager.isPhysicsPreviewActive = true
            toolManager.setTool(.physicsPreview)
            sceneManager.inspectorNavigationTarget = "physicsConstraints"
        }
    }
}
