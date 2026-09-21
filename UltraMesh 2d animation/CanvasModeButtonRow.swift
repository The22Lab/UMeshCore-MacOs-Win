import SwiftUI

/// What a click on the canvas does — chosen on the canvas.
///
/// Pose, Mesh, Bones and Weights sat in the top toolbar, or in the Inspector's
/// tab strip, or both. They are all things you do by working ON the artwork, so
/// the choice belongs beside it: bottom left, above the coordinate readout.
///
/// Every button goes through `CanvasModeSelection`. The alternative — a button
/// that sets its own flags — is what this file's history is made of: the Pose
/// button once cleared the bone tool, the Weights button cleared it and also
/// reset pose, and the Bone button cleared both without touching mesh edit.
struct CanvasModeButtonRow: View {
    @ObservedObject var sceneManager: SceneManager
    @ObservedObject var toolManager: ToolManager
    /// Bones, meshes and weights are Editor work; posing previews in either.
    let isSkeletonMode: Bool

    /// Left to right. Pose reads first because it is the one you leave the
    /// others for.
    private static let order: [CanvasMode] = [.pose, .mesh, .bone, .weights]

    private var active: CanvasMode? {
        CanvasModeSelection.active(scene: sceneManager, tools: toolManager)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.order) { mode in
                let enabled = !mode.requiresSkeletonMode || isSkeletonMode
                CanvasModeChip(
                    mode: mode,
                    isActive: active == mode,
                    isEnabled: enabled,
                    action: {
                        CanvasModeSelection.select(mode, scene: sceneManager, tools: toolManager)
                        PlatformFeedback.lightImpact()
                    }
                )
                .help(helpText(for: mode, enabled: enabled))
            }
        }
        .padding(5)
        .background(
            Capsule(style: .continuous)
                .fill(UM.canvasPillFill)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(UM.textPrimary.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
        )
    }

    private func helpText(for mode: CanvasMode, enabled: Bool) -> String {
        guard enabled else { return "\(mode.title) is available in Editor mode" }
        switch mode {
        case .pose:    return active == mode ? "Stop posing" : "Pose the rig"
        case .mesh:    return active == mode ? "Close the mesh tools" : "Shape this sprite's mesh"
        case .bone:    return active == mode ? "Stop adding bones" : "Add bones — drag on the canvas"
        case .weights: return active == mode ? "Put the brush away" : "Paint weights onto this sprite"
        }
    }
}

/// One chip in the row.
///
/// The resting fill is `accentSoft` because the canvas checkerboard is the same
/// family of light blue-greys as the chrome: a surface tone reads 1.21 against
/// the light squares and 1.01 against the dark ones, and would vanish over half
/// the board.
private struct CanvasModeChip: View {
    let mode: CanvasMode
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    /// ONE box, for all four glyphs.
    ///
    /// They were drawn at three sizes: a 13pt font on the two symbols, 17 on
    /// the bone, and 26 on the mesh ball — half again as large as the bone
    /// beside it. A row of buttons that differ only in which one is lit is the
    /// whole point of a row of buttons, so the size is named once here and
    /// every chip takes it.
    static let glyphSize: CGFloat = 19

    var body: some View {
        Button(action: action) {
            glyph
                // Square, so the lit background is a circle rather than a
                // stadium — that is the shape the drawing marks the active
                // mode with.
                .frame(width: 30, height: 30)
                .background(
                    // One violet for whichever mode is lit, as drawn. The
                    // drawing marks the selection by which disc is filled, not
                    // by what colour it is.
                    Circle()
                        .fill(isActive ? UM.canvasPillActive : Color.clear)
                        .shadow(color: UM.canvasPillActive.opacity(isActive ? 0.32 : 0),
                                radius: isActive ? 7 : 0, x: 0, y: 2)
                )
                .contentShape(Circle())
                .scaleEffect(isActive ? 1.04 : 1.0)
                .animation(.spring(response: 0.26, dampingFraction: 0.72), value: isActive)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
    }

    /// The row's ink at rest, white when lit. One colour for all four: Mesh
    /// used to be the only violet among three greys, and Bones carried a white
    /// body with a grey contour, so three of the four read as different
    /// KINDS of mark rather than as four of one kind.
    private var ink: Color {
        isActive ? Color.white : UM.canvasPillInk
    }

    @ViewBuilder
    private var glyph: some View {
        if mode == .bone {
            // The hierarchy's own bone, so the button and the thing it creates
            // are recognisably the same object. Solid here: its outlined style
            // is for the tree, where the rows are smaller and the contour is
            // what separates it from the row behind. On a chip it made the
            // bone a two-tone mark among solid ones.
            //
            // The plus rides on the corner — at this size a second glyph
            // beside it reads as two buttons — and is the only mark that
            // inverts, because it sits on its own white disc.
            ZStack(alignment: .bottomTrailing) {
                BoneGlyph(style: .solid, tint: ink)
                    .frame(width: Self.glyphSize, height: Self.glyphSize)

                Image(systemName: "plus.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.glyphSize * 0.52, height: Self.glyphSize * 0.52)
                    .foregroundStyle(isActive ? UM.canvasPillActive : UM.canvasPillInk)
                    .background(
                        Circle()
                            .fill(Color.white)
                            .frame(width: Self.glyphSize * 0.47, height: Self.glyphSize * 0.47)
                    )
                    .offset(x: 4, y: 3)
            }
        } else if mode == .mesh {
            // The COARSE lattice at this size. The fine one was drawn at 26pt
            // for room, not for looks: sixty struts at 0.021 of the box are
            // under a point here and would grey out into a smudge, which is
            // exactly the "different size" this row was reported for. The bare
            // icosahedron holds together small — it is what the hierarchy row
            // uses at half this size.
            MeshGlyph(tint: ink, lattice: .coarse)
                .frame(width: Self.glyphSize, height: Self.glyphSize)
        } else {
            // Sized by the FRAME, not by a font. `.font(size:)` sets the mark
            // and leaves the frame as padding around it, which is how a 13pt
            // symbol and a 26pt ball lived in one row.
            Image(systemName: mode.systemImage)
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .frame(width: Self.glyphSize, height: Self.glyphSize)
                .foregroundStyle(ink)
        }
    }
}
