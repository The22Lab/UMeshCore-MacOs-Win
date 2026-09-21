import SwiftUI
import UniformTypeIdentifiers

/// Layer Order Mode — the draw-order panel.
///
/// Shows every image, mesh, and attachment as a flat list in draw order
/// (top row = front-most layer). Rows can be dragged to reorder; the move is
/// applied live while dragging (same interaction model as the hierarchy
/// tree), so the canvas updates in real time. Works with mouse on macOS and
/// touch / Apple Pencil on iPadOS through standard SwiftUI drag & drop.
struct DrawOrderView: View {
    @ObservedObject var sceneManager: SceneManager
    let onFrameItem: (UUID) -> Void

    @State private var draggingID: UUID?
    /// The row the drop would land on, and which edge of it.
    ///
    /// The list does NOT move while a drag is in flight. It used to: the drop
    /// delegate performed the move on `dropEntered`, so passing over a row
    /// reshuffled the list under the cursor, the row beneath the pointer
    /// became a different sprite, and aiming at anything was guesswork. The
    /// line shows where it will go; the move happens once, on release.
    @State private var dropTargetID: UUID?
    @State private var dropsBelowTarget = false

    private let imageAccent = Color(red: 0.31, green: 0.84, blue: 0.95)
    private let boneAccent  = Color(red: 0.94, green: 0.29, blue: 0.78)
    private let meshAccent  = Color.orange

    var body: some View {
        ScrollView {
            if sceneManager.imagesInDrawOrder.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .padding(.top, 14)
            } else {
                LazyVStack(spacing: 0) {
                    drawOrderKeyBar
                    sortByBoneDepthButton
                    frontLabel
                    ForEach(Array(sceneManager.imagesInDrawOrder.enumerated()), id: \.element.id) { index, image in
                        row(for: image, drawIndex: index)
                            .overlay(alignment: dropsBelowTarget ? .bottom : .top) {
                                // Where the drop will land, drawn between the
                                // rows rather than by moving them.
                                if dropTargetID == image.id, draggingID != nil {
                                    Capsule()
                                        .fill(UM.accentStrong)
                                        .frame(height: 2.5)
                                        .padding(.horizontal, 6)
                                        .offset(y: dropsBelowTarget ? 1.5 : -1.5)
                                }
                            }
                            .onDrop(
                                of: [UTType.text],
                                delegate: DrawOrderDropDelegate(
                                    targetImageID: image.id,
                                    sceneManager: sceneManager,
                                    draggingID: $draggingID,
                                    dropTargetID: $dropTargetID,
                                    dropsBelowTarget: $dropsBelowTarget
                                )
                            )
                    }
                    backLabel
                }
                .padding(.vertical, 4)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: sceneManager.images.map(\.id))
    }

    /// Orders the sprites the way the rig implies: a forearm in front of the
    /// upper arm that drives it.
    ///
    /// A button rather than something that happens by itself. Recomputing this
    /// every frame would overwrite whatever ordering the artist set here, every
    /// time a bone moved. Pressed once it writes the authored order, so it is
    /// undoable and can be adjusted by hand afterwards.
    private var sortByBoneDepthButton: some View {
        Button {
            sceneManager.sortDrawOrderByBoneDepth()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text("Order by bone depth")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .foregroundStyle(UM.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sceneManager.skeleton.bones.isEmpty)
        .opacity(sceneManager.skeleton.bones.isEmpty ? 0.4 : 1)
        .help("Put each sprite in front of the ones driven by its bone's parents")
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for image: SceneImage, drawIndex: Int) -> some View {
        let isSelected = sceneManager.selectedImageID == image.id
            || sceneManager.selectedImageIDs.contains(image.id)
        let isDragging = draggingID == image.id
        let hasMesh = !image.mesh.isQuadCompatible || image.mesh.hasSkinningData()
        let boundBoneName = image.boneBinding
            .flatMap { sceneManager.skeleton.bones[$0.boneID]?.name }

        HStack(spacing: 7) {
            // EVERYTHING EXCEPT THE GRAB HANDLE, and the menu hangs off THIS.
            //
            // The menu used to be attached to the whole row, so holding the
            // grab handle — which is held on purpose, because holding is how a
            // drag starts — put Bring to Front / Send to Back on top of the row
            // the artist was trying to move. The handle is a sibling of this
            // group now rather than a child of it, which is the only thing that
            // separates the two cleanly: a competing gesture on the handle
            // would have swallowed its `.onDrag` along with the menu.
            rowContent(image: image, drawIndex: drawIndex, isSelected: isSelected,
                       boundBoneName: boundBoneName, hasMesh: hasMesh)
                .contentShape(Rectangle())
                .onTapGesture {
                    sceneManager.setSelection(ids: [image.id], primary: image.id, additive: false)
                }
                .contextMenu {
                    Button("Bring to Front") {
                        sceneManager.moveImageInDrawOrder(imageID: image.id, toDrawIndex: 0)
                    }
                    Button("Send to Back") {
                        sceneManager.moveImageInDrawOrder(
                            imageID: image.id,
                            toDrawIndex: max(sceneManager.imagesInDrawOrder.count - 1, 0)
                        )
                    }
                    Divider()
                    Button("Frame in Viewport") { onFrameItem(image.id) }
                }

            // THE DRAG SOURCE, and the only one.
            //
            // `.onDrag` used to sit on the whole row, which also carries a tap
            // gesture and three buttons — so a press near the eye or a nudge
            // chevron was a race between starting a drag and pressing the
            // control under it. The handle is a target of its own, and looks
            // like one.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UM.textPrimary.opacity(isDragging ? 0.75 : 0.38))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .onDrag {
                    draggingID = image.id
                    return NSItemProvider(object: image.id.uuidString as NSString)
                }
                .padding(.trailing, 4)
        }
        .padding(.leading, 6)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected
                        ? imageAccent.opacity(0.16)
                        : (isDragging ? UM.textPrimary.opacity(0.09) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isSelected ? imageAccent.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 0.5)
    }

    /// The row, minus the grab handle: index, glyph, name, bone pill, the
    /// nudge chevrons and the eye. Split out so the context menu can be
    /// attached to exactly this and not to the handle beside it.
    @ViewBuilder
    private func rowContent(image: SceneImage, drawIndex: Int, isSelected: Bool,
                            boundBoneName: String?, hasMesh: Bool) -> some View {
        HStack(spacing: 7) {
            // Draw-order index (0 = front)
            Text("\(drawIndex)")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(UM.textPrimary.opacity(0.42))
                .frame(width: 18, alignment: .trailing)

            // THE HIERARCHY'S OWN GLYPHS. These were `photo` and
            // `square.grid.3x3.topleft.filled` — two SF Symbols saying "image"
            // and "grid" in a different visual language from the tree three
            // panels away, where the same two things are a plate with a sun and
            // peaks, and a wireframe ball. One sprite should not be two
            // different marks depending on which list is looking at it.
            //
            // 13 points, the size the hierarchy draws them at: below about 11
            // the contour falls under a pixel and the glyph reads as a smudge.
            Group {
                if hasMesh {
                    MeshGlyph()
                } else {
                    ImageGlyph()
                }
            }
            .frame(width: 13, height: 13)
            .opacity(image.isHidden ? 0.4 : 0.88)

            Text(image.name)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(UM.textPrimary.opacity(image.isHidden ? 0.35 : 0.92))
                .lineLimit(1)

            if let boundBoneName {
                HStack(spacing: 2.5) {
                    // The bone pill wears the hierarchy's bone, for the same
                    // reason the sprite wears its plate: one mark per thing.
                    BoneGlyph()
                        .frame(width: 9, height: 9)
                    Text(boundBoneName)
                        .font(.system(size: 8, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(boneAccent.opacity(0.85))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(boneAccent.opacity(0.12)))
            }

            Spacer(minLength: 4)

            // One-step nudge controls: quick front/back moves without dragging.
            HStack(spacing: 1) {
                nudgeButton(systemName: "chevron.up", enabled: drawIndex > 0) {
                    sceneManager.nudgeImageInDrawOrder(imageID: image.id, forward: true)
                }
                nudgeButton(systemName: "chevron.down",
                            enabled: drawIndex < sceneManager.imagesInDrawOrder.count - 1) {
                    sceneManager.nudgeImageInDrawOrder(imageID: image.id, forward: false)
                }
            }

            Button {
                sceneManager.updateVisibility(itemID: image.id, isHidden: !image.isHidden)
            } label: {
                Image(systemName: image.isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(UM.textPrimary.opacity(image.isHidden ? 0.35 : 0.62))
                    .frame(width: 24, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func nudgeButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // 24 x 26. An 8pt chevron in a 17pt box is a target you have to
            // aim at, and this is the control that exists precisely so an
            // artist does not have to aim: one press, one place, no drag.
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(UM.textPrimary.opacity(enabled ? 0.62 : 0.18))
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Labels & Empty State

    /// Draw order keying. Only meaningful while animating: in Setup
    /// mode reordering edits the authored order and there is nothing to key.
    @ViewBuilder
    private var drawOrderKeyBar: some View {
        if sceneManager.isAnimationEditingEnabled {
            HStack(spacing: 8) {
                Button {
                    if sceneManager.drawOrderHasKeyAtPlayhead() {
                        sceneManager.removeDrawOrderKeyAtPlayhead()
                    } else {
                        sceneManager.keyDrawOrder()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: sceneManager.drawOrderHasKeyAtPlayhead() ? "diamond.fill" : "diamond")
                            .font(.system(size: 9, weight: .semibold))
                        Text(sceneManager.drawOrderHasKeyAtPlayhead() ? "Keyed" : "Key Draw Order")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(
                        sceneManager.drawOrderHasKeyAtPlayhead()
                            ? imageAccent
                            : UM.textPrimary.opacity(0.68)
                    )
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if sceneManager.hasDrawOrderTrack() {
                    Button("Clear") {
                        sceneManager.removeDrawOrderTrack()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.62))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(UM.textPrimary.opacity(0.045))
            )
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
    }

    private var frontLabel: some View {
        orderLabel(text: "FRONT", icon: "square.stack.3d.up.fill")
    }

    private var backLabel: some View {
        orderLabel(text: "BACK", icon: "square.stack.3d.down.forward.fill")
    }

    @ViewBuilder
    private func orderLabel(text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 7, weight: .semibold))
            Text(text)
                .font(.system(size: 7.5, weight: .bold, design: .rounded))
                .tracking(1.1)
        }
        .foregroundStyle(UM.textPrimary.opacity(0.26))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(UM.textPrimary.opacity(0.25))
            Text("No layers yet")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UM.textPrimary.opacity(0.55))
            Text("Import images to arrange their draw order.")
                .font(.system(size: 9.5))
                .foregroundStyle(UM.textPrimary.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
    }
}

/// Live-reorder drop delegate for Layer Order Mode. The move happens in
/// `dropEntered` (identical interaction model to the hierarchy tree) so the
/// list and canvas reorder in real time while the row is dragged.
/// Aim while dragging; move once on release.
///
/// The previous delegate performed the move in `dropEntered`, so the list
/// reshuffled as the pointer crossed each row: the sprite under the cursor
/// changed identity mid-drag, the row you were aiming at slid away, and a
/// drop of more than one place was a matter of luck. Nothing moves now until
/// the drop, and an insertion line says where it will land.
private struct DrawOrderDropDelegate: DropDelegate {
    let targetImageID: UUID
    let sceneManager: SceneManager
    @Binding var draggingID: UUID?
    @Binding var dropTargetID: UUID?
    @Binding var dropsBelowTarget: Bool

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != targetImageID else { return }
        dropTargetID = targetImageID
        dropsBelowTarget = isBelow(draggingID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let draggingID, draggingID != targetImageID {
            dropTargetID = targetImageID
            dropsBelowTarget = isBelow(draggingID)
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetImageID { dropTargetID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggingID = nil
            dropTargetID = nil
        }
        guard let draggingID, draggingID != targetImageID else { return true }
        let ordered = sceneManager.imagesInDrawOrder.map(\.id)
        guard let to = ordered.firstIndex(of: targetImageID) else { return true }
        sceneManager.moveImageInDrawOrder(imageID: draggingID, toDrawIndex: to)
        return true
    }

    /// Which side of the target the line goes on: a sprite travelling down
    /// lands after the row it was dropped on, one travelling up lands before
    /// it. Same rule the move itself uses, so the line does not promise one
    /// thing and the drop do another.
    private func isBelow(_ moved: UUID) -> Bool {
        let ordered = sceneManager.imagesInDrawOrder.map(\.id)
        guard let from = ordered.firstIndex(of: moved),
              let to = ordered.firstIndex(of: targetImageID) else { return false }
        return from < to
    }
}
