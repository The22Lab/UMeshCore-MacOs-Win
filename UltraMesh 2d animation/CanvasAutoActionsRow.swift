import SwiftUI

/// Auto-Mesh, Auto-Bind and Auto-Weight, on the canvas.
///
/// All three already exist, and all three are buried in a panel that belongs to
/// a mode: Auto-Mesh in the Mesh panel, which only opens in Mesh mode;
/// Auto-Bind and Auto-Weight in the Weights panel, which only opens under the
/// brush. Reaching them meant changing mode first, which is the reason for a
/// shortcut in the first place.
///
/// Each button ends in the SAME model call as the panel button it doubles, with
/// the same arguments — including the influence cap, which is read from the
/// model rather than written here. Two buttons that both say Auto-Bind and do
/// subtly different things are worse than one button in an awkward place, and
/// `verify_canvas_auto_actions.py` compares the two call sites.
///
/// Availability is ONE rule: enabled when a sprite with an asset is selected,
/// and nothing more. The three actions already refuse out loud when they cannot
/// do anything — no bone over the sprite, nothing bound to weight yet — and
/// `SceneManager` says why in `meshEditNotice`. Disabling on those conditions
/// as well would replace an explanation with a dead button, which is the
/// opposite of what those notices were added for.
struct CanvasAutoActionsRow: View {
    let assetManager: AssetManager
    @ObservedObject var sceneManager: SceneManager
    /// The panel next door names the width; this matches it so the two read as
    /// one floating stack rather than two things that happen to be adjacent.
    var width: CGFloat = 250
    /// Builds the alpha reader Auto-Mesh traces against. Passed in because the
    /// viewport already owns one, and a second implementation of "read this
    /// PNG's alpha" is a second thing to keep in step.
    let alphaSampler: (URL) -> ((Int, Int) -> Float)?

    private var selected: SceneImage? {
        guard let id = sceneManager.selectedImageID else { return nil }
        return sceneManager.image(for: id)
    }

    private var asset: TextureAsset? {
        guard let image = selected else { return nil }
        return assetManager.asset(for: image.assetID)
    }

    /// Nothing selected to act on. The only reason any of the three is off.
    private var hasNoSprite: Bool { selected == nil || asset == nil }

    var body: some View {
        HStack(spacing: 6) {
            pill("Auto-Mesh", fill: UM.meshAutoFill, ink: UM.inspectorPillInk,
                 help: "Trace this sprite's outline and mesh it") {
                guard let image = selected, let asset,
                      let sampler = alphaSampler(asset.fileURL) else { return }
                sceneManager.selectMeshLayer(for: image.id)
                sceneManager.traceSelectedMesh(assetSize: asset.size, alphaSampler: sampler)
            }
            pill("Auto-Bind", fill: UM.weightsBindFill, ink: UM.weightsBindInk,
                 help: "Bind the bones lying over this sprite") {
                guard let image = selected, let asset else { return }
                sceneManager.autoBindImage(imageID: image.id, assetSize: asset.size)
                sceneManager.isBindingBonesMode = false
            }
            pill("Auto-Weight", fill: UM.weightsAutoStart, ink: UM.weightsAutoInk,
                 help: "Rebalance the weights across the bones already bound") {
                sceneManager.autoWeightSelectedMesh(
                    maxInfluences: sceneManager.meshWeightMaxInfluencesPerVertex)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(UM.coordPanelFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(UM.coordPanelBorder, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 6)
    }

    private func pill(_ title: String,
                      fill: Color,
                      ink: Color,
                      help: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(Capsule(style: .continuous).fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(hasNoSprite)
        .opacity(hasNoSprite ? 0.45 : 1.0)
        .help(hasNoSprite ? "Select a sprite first" : help)
    }
}
