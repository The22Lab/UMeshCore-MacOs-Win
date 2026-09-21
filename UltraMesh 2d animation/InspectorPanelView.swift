import Foundation
import SwiftUI

/// The three things the inspector edits, split apart so each one is reachable
/// without scrolling past the other two.
/// What the inspector shows when no canvas mode is open.
///
/// Mesh and Weights were tabs here AND canvas modes, and keeping those two in
/// step is what broke twice: a tab that showed the panel with its mode off, and
/// a mode left lit under another one. They are not tabs any more — the canvas
/// button opens the mode, and the mode brings its panel with it.
enum InspectorTab: String, CaseIterable {
    case properties, constraints

    var title: String {
        switch self {
        case .properties:  return "Properties"
        case .constraints: return "Constraints"
        }
    }
}

struct InspectorPanelView: View {
    /// Outcome of the last weight mirror, shown inline so the artist knows
    /// whether anything actually matched.

    @EnvironmentObject private var appState: AppState
    var onToggleVisibility: (() -> Void)? = nil

    private var sceneManager: SceneManager { appState.sceneManager }
    private var assetManager: AssetManager { appState.assetManager }
    private var toolManager: ToolManager { appState.toolManager }
    private var orderedBones: [Bone] { sceneManager.skeleton.orderedBones }

    private let cardCorner: CGFloat = 14
    private let ultraPurple = Color(red: 0.90, green: 0.60, blue: 0.30)

    @State private var inspectorTab: InspectorTab = .properties

    /// Constraint currently being renamed inline, and its edit buffer.
    @State private var renamingConstraintID: UUID?
    @State private var constraintRenameText: String = ""

    /// Closes the undo group for the tint picker. `ColorPicker` streams values
    /// while its wheel is dragged and offers no "editing ended" callback, so a
    /// short idle stands in for one: without an end the interaction flag would
    /// stay raised and swallow the NEXT action's undo state.
    @State private var tintUndoCloseTask: Task<Void, Never>?
    private let ultraIndigo = Color(red: 0.73, green: 0.48, blue: 0.25)
    private let sectionFill         = UM.surface
    private let sectionFillElevated = UM.surface
    private let sectionStroke = UM.textPrimary.opacity(0.10)
    private let neutralButtonFill = UM.textPrimary.opacity(0.035)

    var body: some View {
        VStack(spacing: 0) {
            infoCard {
                VStack(alignment: .leading, spacing: 14) {
                    headerBar

                    // Properties | Constraints belong to what is SELECTED — an
                    // image's transform, a bone's parent, the constraints on
                    // it. A mode panel is not a selection: Mesh mode is the
                    // mesh tools and nothing else, and a tab strip over it
                    // offered two tabs neither of which changed anything on
                    // screen. It comes back the moment the mode is off.
                    if !isModePanelOpen {
                        inspectorTabBar
                    }

                    // Creating any constraint, and running the physics
                    // simulation, live under this tab. The simulation toggle
                    // was the one thing the old Physics toolbar button did that
                    // creating a constraint does not, so it travels with it
                    // rather than disappearing when the button did.
                    if !isModePanelOpen, inspectorTab == .constraints {
                        ConstraintsMenuButton(
                            sceneManager: sceneManager,
                            toolManager: toolManager
                        )
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if let selectedImage = selectedImage {
                                    imageInspector(selectedImage)
                                } else if sceneManager.selectedBoneIDs.count > 1 {
                                    multiBoneInspector(sceneManager.selectedBonesInChainOrder)
                                } else if let selectedBone = selectedBone {
                                    boneInspector(selectedBone)
                                } else {
                                    emptyStateCard
                                }
                            }
                            .padding(.trailing, 2)
                        }
                        .onChange(of: sceneManager.inspectorNavigationTarget) { target in
                            guard let target else { return }
                            // No tab to open any more: the canvas button turned
                            // the mode on, and the mode brings its panel with
                            // it. This only has to scroll to the section.
                            //
                            // It used to set `inspectorTab` directly, around the
                            // function that turns the mode on — which showed the
                            // Weights panel with the brush off, and no colours
                            // on the canvas.
                            if target == "pose" {
                                withAnimation(.easeInOut(duration: 0.14)) {
                                    selectInspectorTab(.properties)
                                }
                            }
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(target, anchor: .top)
                            }
                            sceneManager.inspectorNavigationTarget = nil
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(UM.appBackground)
    }

    private var selectedImage: SceneImage? {
        sceneManager.selectedImageID.flatMap { sceneManager.image(for: $0) }
    }

    private var selectedBone: Bone? {
        sceneManager.selectedBoneID.flatMap { sceneManager.skeleton.bone($0) }
    }

    /// Tint, opacity and blend mode for a sprite.
    ///
    /// Tint travels to the runtime as vertex colour, so recolouring never costs
    /// an extra draw call; changing the blend MODE does break the batch, which
    /// is why it is a deliberate choice rather than a per-frame effect.
    @ViewBuilder
    private func appearanceSection(_ image: SceneImage) -> some View {
        let imageID = image.id

        HStack(spacing: 10) {
            ColorPicker("", selection: Binding(
                get: {
                    let t = image.tintColor
                    return Color(.sRGB, red: Double(t.x), green: Double(t.y),
                                 blue: Double(t.z), opacity: 1.0)
                },
                set: { newValue in
                    let rgba = PlatformColors.rgbaComponents(newValue)
                    // One undo step per drag, not per streamed value.
                    sceneManager.beginInteraction()
                    sceneManager.updateImage(id: imageID) {
                        // Opacity is edited by its own slider, so the picker
                        // only carries the hue and leaves alpha alone.
                        $0.tintColor = SIMD4<Float>(rgba.0, rgba.1, rgba.2, $0.tintColor.w)
                    }
                    scheduleTintUndoClose()
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 44)

            Text("Tint")
                .font(.system(size: 11))
                .foregroundStyle(UM.textSecondary)

            Spacer()

            Button("Reset") {
                sceneManager.pushUndoState()
                sceneManager.updateImage(id: imageID) {
                    $0.tintColor = SIMD4<Float>(1, 1, 1, 1)
                    $0.blendMode = .normal
                }
            }
            .font(.system(size: 11))
        }

        HStack(spacing: 8) {
            Text("Opacity")
                .font(.system(size: 11))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 62, alignment: .leading)
            Slider(value: Binding(
                get: { Double(image.tintColor.w) },
                set: { newValue in
                    sceneManager.updateImage(id: imageID) {
                        $0.tintColor.w = Float(newValue)
                    }
                }
            ), in: 0...1, onEditingChanged: { isEditing in
                // The drag is one undo step, pushed before the first change.
                if isEditing { sceneManager.beginInteraction() }
                else { sceneManager.endInteraction() }
            })
            Text(String(format: "%.0f%%", image.tintColor.w * 100))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(UM.textSecondary)
                .frame(width: 40, alignment: .trailing)
        }

        HStack(spacing: 8) {
            Text("Blend")
                .font(.system(size: 11))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 62, alignment: .leading)
            Picker("", selection: Binding(
                get: { image.blendMode },
                set: { newValue in
                    guard newValue != image.blendMode else { return }
                    sceneManager.pushUndoState()
                    sceneManager.updateImage(id: imageID) { $0.blendMode = newValue }
                }
            )) {
                ForEach(ImageBlendMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
        }

        normalMapRow(image)
    }

    /// Which normal map pairs with this sprite's artwork.
    ///
    /// HERE AND NOT IN THE SCENE INSPECTOR, because a normal map is the pair of
    /// ONE PNG and this is the panel where the artist has that PNG in front of
    /// them. A rig is many sprites with different relief on each; offering one
    /// map for the whole instance over in Scene would light the face with the
    /// arm's bumps.
    ///
    /// Usually already filled in: importing `hero.png` and `hero_n.png`
    /// together pairs them by name at creation. This row is for the cases the
    /// convention does not cover, and for taking a pairing back.
    @ViewBuilder
    private func normalMapRow(_ image: SceneImage) -> some View {
        let imageID = image.id
        let maps = assetManager.normalMapAssets
        HStack(spacing: 8) {
            Text("Relief")
                .font(.system(size: 11))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 62, alignment: .leading)
            Menu {
                Button("None") {
                    sceneManager.pushUndoState()
                    sceneManager.updateImage(id: imageID) { $0.normalMapAssetID = nil }
                }
                if maps.isEmpty {
                    // NOT AN EMPTY MENU. A menu that opens onto nothing reads
                    // as broken; this says what to do about it.
                    Text("Import a file named …_n.png")
                } else {
                    Divider()
                    ForEach(maps) { asset in
                        Button(asset.name) {
                            sceneManager.pushUndoState()
                            sceneManager.updateImage(id: imageID) {
                                $0.normalMapAssetID = asset.id
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    normalMapThumbnail(image.normalMapAssetID)
                    Text(normalMapLabel(image))
                        .font(.system(size: 11))
                        .foregroundStyle(image.normalMapAssetID == nil
                                         ? UM.textMuted : UM.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .labelsHidden()
        }
    }

    /// A NAMED-BUT-MISSING MAP SAYS SO, rather than falling back to "None" and
    /// letting the artist set it again and watch nothing happen — the file is
    /// what moved, and only this row can tell them that.
    private func normalMapLabel(_ image: SceneImage) -> String {
        guard let id = image.normalMapAssetID else { return "None" }
        return assetManager.asset(for: id)?.name ?? "Missing file"
    }

    @ViewBuilder
    private func normalMapThumbnail(_ assetID: UUID?) -> some View {
        if let assetID, let preview = assetManager.thumbnail(assetID: assetID, maxPixel: 32) {
            Image(decorative: preview, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(UM.textPrimary.opacity(0.08))
                .frame(width: 16, height: 16)
        }
    }

    /// Ends the tint picker's undo group once the values stop arriving.
    private func scheduleTintUndoClose() {
        tintUndoCloseTask?.cancel()
        tintUndoCloseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            sceneManager.endInteraction()
            tintUndoCloseTask = nil
        }
    }

    @ViewBuilder
    private func imageInspector(_ image: SceneImage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            selectionHeader(title: image.name, kind: "IMAGE", accent: ultraPurple)

            // Mesh editing and skinning live under the Mesh tab; how the sprite
            // looks and what drives it stay under Properties. Nothing was
            // removed — the long scroll was split so each half is reachable
            // without paging past the other.
            // The panel draws its own card, so it is not wrapped in an
            // `inspectorSection` as well — that put a second border and 12pt of
            // padding around it that the drawing does not have, and made it a
            // visibly different shape from the Weights panel beside it, which
            // has never been wrapped.
            if sceneManager.isMeshEditEnabled {
                if appState.editorMode == .skeleton {
                    // Straight in, with no gate in front of it. There was a
                    // "Mesh Edit" toggle here that had to be lit before any of
                    // this appeared, and that stayed lit after the artist had
                    // moved on to Pose or another tool — so the canvas went on
                    // treating clicks as mesh edits. Mesh editing is now simply
                    // what Mesh mode means, and the mode owns it.
                    meshInspector(image)
                        .id("mesh")
                } else {
                    inspectorSection(spacing: 14) {
                        Text("Switch to Editor mode to edit this mesh.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(UM.textMuted)
                    }
                    .id("mesh")
                }
            }

            if !isModePanelOpen, inspectorTab == .properties {
            inspectorSection(spacing: 14) {
                // Above Appearance: WHICH sprite is showing comes before what
                // it looks like, and in Animator this is the row being keyed.
                // It draws nothing at all for a sprite that stands alone,
                // which is every sprite until the artist groups two into a
                // slot in the Skins panel.
                AttachmentsPanel(sceneManager: sceneManager, image: image)

                sectionTitle("Appearance")
                appearanceSection(image)
                Divider()
                    .overlay(UM.textPrimary.opacity(0.08))

                sectionTitle("Bone Bind")
                Picker("Bound Bone", selection: boundBoneBinding(for: image.id)) {
                    Text("None").tag(nil as UUID?)
                    ForEach(orderedBones) { bone in
                        Text(bone.name).tag(Optional(bone.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(orderedBones.isEmpty)

                if let binding = image.boneBinding,
                   let bone = sceneManager.skeleton.bone(binding.boneID) {
                    Text("Bound to \(bone.name)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UM.textPrimary.opacity(0.72))
                } else {
                    Text("Image moves independently")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UM.textPrimary.opacity(0.58))
                }
            }
            }

            // Weights is its own tab. It lived inside the Mesh tab and only
            // appeared while weight paint was on, so reaching it meant going
            // through mesh editing — which is the same coupling that made the
            // brush stop working when Mesh Edit was switched off.
            // The panel draws its own card, so it is not wrapped in an
            // `inspectorSection` as well: the mock has one card, and nesting a
            // second one puts a border and 12pt of padding around it that the
            // mock does not have.
            if sceneManager.meshWeightPaintEnabled && appState.editorMode == .skeleton {
                WeightsInspectorPanel(
                    sceneManager: sceneManager,
                    image: image,
                    assetSize: assetManager.asset(for: image.assetID)?.size
                )
                .id("weightPaint")
            }

            if !isModePanelOpen, inspectorTab == .constraints {
                inspectorSection(spacing: 10) {
                    sectionTitle("Constraints")
                    Text("Constraints are created from a bone selection. Select two or more bones in the canvas.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UM.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }



    @ViewBuilder
    /// The Mesh panel, built to the approved mock.
    ///
    /// The markup that used to be here — three icon mode buttons, a 2x2 grid of
    /// icon actions, four `sliderRow`s and a `LazyVGrid` of toggles — is gone
    /// rather than left beside it: two ways to draw the same panel is how the
    /// two halves end up disagreeing about what a control does.
    private func meshInspector(_ image: SceneImage) -> some View {
        MeshInspectorPanel(
            sceneManager: sceneManager,
            toolManager: toolManager,
            image: image,
            assetSize: assetManager.asset(for: image.assetID)?.size,
            assetURL: assetManager.asset(for: image.assetID)?.fileURL,
            alphaSampler: {
                guard let url = assetManager.asset(for: image.assetID)?.fileURL else { return nil }
                return makeAlphaSampler(for: url)
            }
        )
    }


    @ViewBuilder
    private func multiBoneInspector(_ bones: [Bone]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            selectionHeader(title: "\(bones.count) Bones Selected", kind: "MULTI", accent: ultraPurple)

            inspectorSection(spacing: 12) {
                sectionTitle("Selection")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(bones) { bone in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(swiftUIColor(bone.color ?? UM.unboundBone))
                                .frame(width: 7, height: 7)
                            Text(bone.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(UM.textPrimary.opacity(0.85))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            inspectorSection(spacing: 10) {
                sectionTitle("Create Constraint")

                // Every constraint type is built from the current selection, and
                // each needs a different minimum. Stating the requirement is far
                // clearer than a menu item that is simply greyed out with no
                // explanation of why.
                Text(constraintCreationHint(selectedBoneCount: bones.count))
                    .font(.system(size: 9))
                    .foregroundStyle(UM.textPrimary.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)

                Menu {
                    Button {
                        // Opens the builder rather than guessing from the
                        // selection. The old path inferred the target from
                        // hierarchy depth, which picks wrong for the standard
                        // setup where the target handle is an unparented bone.
                        sceneManager.beginIKBuilder()
                    } label: {
                        Label("IK Constraint…", systemImage: "link")
                    }

                    Divider()

                    Button {
                        sceneManager.createTransformConstraintFromSelection()
                    } label: { Label("Transform Constraint", systemImage: "move.3d") }
                        .disabled(bones.count < 2)
                    Button {
                        sceneManager.createPathConstraintFromSelection()
                    } label: { Label("Path Constraint", systemImage: "point.3.connected.trianglepath.dotted") }
                        .disabled(bones.count < 3)
                    Button {} label: { Label("Rotation Constraint", systemImage: "rotate.3d") }
                        .disabled(true)

                    Divider()

                    Button {
                        sceneManager.createPhysicsConstraintFromSelection()
                    } label: { Label("Physics Constraint", systemImage: "waveform.path") }
                        .disabled(bones.count < 2)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("New")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(ultraPurple.opacity(0.95))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(UM.textPrimary.opacity(0.18), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)

                if bones.count >= 3 {
                    Text("IK: \(bones.count - 1) bone chain → \"\(bones.last?.name ?? "")\" target.  Path: first \(bones.count - 1) bones define the curve, \"\(bones.last?.name ?? "")\" follows it.  Physics: full chain gets spring/rope dynamics.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(UM.textPrimary.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                } else if bones.count == 2 {
                    Text("IK will use \"\(bones.first?.name ?? "")\" as the chain and \"\(bones.last?.name ?? "")\" as the target. Physics Constraint works with 2+ bones. Select 3+ for Path.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(UM.textPrimary.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Select 2+ bones for IK or Physics, or 3+ bones for a Path Constraint.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(UM.textPrimary.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !sceneManager.skeleton.ikConstraints.isEmpty {
                inspectorSection(spacing: 8) {
                    sectionTitle("IK Constraints")
                    ForEach(sceneManager.skeleton.ikConstraints.indices, id: \.self) { idx in
                        ikConstraintCard(Binding(
                            get: { sceneManager.skeleton.ikConstraints[idx] },
                            set: { sceneManager.skeleton.ikConstraints[idx] = $0 }
                        ))
                    }
                }
            }

            if !sceneManager.skeleton.transformConstraints.isEmpty {
                inspectorSection(spacing: 10) {
                    sectionTitle("Transform Constraints")
                    ForEach(sceneManager.skeleton.transformConstraints.indices, id: \.self) { idx in
                        transformConstraintCard(Binding(
                            get: { sceneManager.skeleton.transformConstraints[idx] },
                            set: { sceneManager.skeleton.transformConstraints[idx] = $0 }
                        ))
                    }
                }
                .id("transformConstraints")
            }

            if !sceneManager.skeleton.pathConstraints.isEmpty {
                inspectorSection(spacing: 10) {
                    sectionTitle("Path Constraints")
                    ForEach(sceneManager.skeleton.pathConstraints.indices, id: \.self) { idx in
                        pathConstraintCard(Binding(
                            get: { sceneManager.skeleton.pathConstraints[idx] },
                            set: { sceneManager.skeleton.pathConstraints[idx] = $0 }
                        ))
                    }
                }
            }

            if !sceneManager.skeleton.physicsConstraints.isEmpty {
                inspectorSection(spacing: 10) {
                    sectionTitle("Physics Constraints")
                    ForEach(sceneManager.skeleton.physicsConstraints.indices, id: \.self) { idx in
                        physicsConstraintCard(Binding(
                            get: { sceneManager.skeleton.physicsConstraints[idx] },
                            set: { sceneManager.skeleton.physicsConstraints[idx] = $0 }
                        ))
                    }
                }
                .id("physicsConstraints")
            }
        }
    }

    /// Explain what the current selection can and cannot create.
    ///
    /// Constraints are built from the bone selection, ordered root → leaf, with
    /// the deepest bone acting as the target. Without this the artist has to
    /// guess why a menu entry is disabled.
    private func constraintCreationHint(selectedBoneCount count: Int) -> String {
        switch count {
        case 0:
            return "Select bones in the viewport or hierarchy. The deepest selected bone becomes the target."
        case 1:
            return "1 bone selected. IK, Transform and Physics need at least 2; Path needs 3."
        case 2:
            return "2 bones selected — IK, Transform and Physics available. Path needs 3 or more."
        default:
            return "\(count) bones selected. The deepest becomes the target; the rest are driven."
        }
    }

    // MARK: - IK Constraint Card

    /// Full IK inspector: every parameter the solver takes.
    ///
    /// Previously this was a read-only row showing only the name and a bone
    /// count, so a constraint could be created but never adjusted — the mix,
    /// target, bend direction, stretch, compress and softness all existed in the
    /// solver with no way to reach them.
    @ViewBuilder
    private func ikConstraintCard(_ binding: Binding<IKConstraint>) -> some View {
        let c = binding.wrappedValue
        let tint = ultraPurple
        let isSelected = sceneManager.selectedConstraintID == c.id
        let targetBone = sceneManager.skeleton.bones[c.targetBoneID]

        VStack(alignment: .leading, spacing: 0) {
            // Header: enable toggle, name, chain summary, actions.
            HStack(spacing: 7) {
                Button {
                    sceneManager.setConstraintEnabled(c.id, !c.enabled)
                } label: {
                    Image(systemName: c.enabled ? "checkmark.square.fill" : "square")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(c.enabled ? tint : UM.textPrimary.opacity(0.3))
                }
                .buttonStyle(.plain)

                // The same mark the tree shows, so a constraint looks like
                // itself in both places.
                IKConstraintGlyph(isEnabled: c.enabled)
                    .frame(width: 14, height: 14)

                if renamingConstraintID == c.id {
                    TextField("Name", text: $constraintRenameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .onSubmit {
                            sceneManager.renameIKConstraint(c.id, to: constraintRenameText)
                            renamingConstraintID = nil
                        }
                } else {
                    Text(c.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UM.textPrimary.opacity(c.enabled ? 0.92 : 0.45))
                }

                Spacer(minLength: 0)

                Text("\(c.boneChain.count) bone\(c.boneChain.count == 1 ? "" : "s")")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(UM.textPrimary.opacity(0.4))

                Menu {
                    Button("Rename") {
                        constraintRenameText = c.name
                        renamingConstraintID = c.id
                    }
                    Button("Duplicate") { sceneManager.duplicateIKConstraint(c.id) }
                    Button("Set Chain from Selection") {
                        sceneManager.setIKChainFromSelection(c.id)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        sceneManager.deleteIKConstraint(c.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(UM.textPrimary.opacity(0.45))
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { sceneManager.selectedConstraintID = c.id }

            if isSelected {
                VStack(alignment: .leading, spacing: 9) {
                    Divider().overlay(UM.textPrimary.opacity(0.06))

                    // Target — the bone the chain reaches toward.
                    HStack {
                        Text("Target")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(UM.textPrimary.opacity(0.68))
                        Spacer()
                        Menu {
                            ForEach(sceneManager.targetCandidates(excluding: c.boneChain)) { bone in
                                Button(bone.name) {
                                    sceneManager.setIKTarget(c.id, target: bone.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(targetBone?.name ?? "None")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(targetBone == nil ? Color.red.opacity(0.7) : UM.textPrimary.opacity(0.85))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7, weight: .semibold))
                                    .foregroundStyle(UM.textPrimary.opacity(0.35))
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(UM.textPrimary.opacity(0.06))
                            )
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }

                    // Chain — ordered root → tip, removable.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Chain")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(UM.textPrimary.opacity(0.45))
                                .textCase(.uppercase)
                            Spacer()
                            Button("Add Selected") {
                                for bone in sceneManager.selectedBonesInChainOrder {
                                    sceneManager.addBoneToIKChain(bone.id, constraintID: c.id)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(tint.opacity(0.85))
                        }

                        if c.boneChain.isEmpty {
                            Text("Empty chain — the constraint will not solve. Select bones root → tip and use Add Selected.")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.orange.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(Array(c.boneChain.enumerated()), id: \.element) { position, boneID in
                                        if let bone = sceneManager.skeleton.bones[boneID] {
                                            HStack(spacing: 3) {
                                                Text("\(position + 1)")
                                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                                    .foregroundStyle(UM.textPrimary.opacity(0.35))
                                                boneChip(bone, color: tint.opacity(0.8))
                                                Button {
                                                    sceneManager.removeBoneFromIKChain(boneID, constraintID: c.id)
                                                } label: {
                                                    Image(systemName: "xmark")
                                                        .font(.system(size: 7, weight: .bold))
                                                        .foregroundStyle(UM.textPrimary.opacity(0.4))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Divider().overlay(UM.textPrimary.opacity(0.06))

                    // Solver parameters.
                    pathSlider(
                        title: "Mix",
                        valueText: String(format: "%.2f", c.mix),
                        value: Binding(
                            get: { c.mix },
                            set: { sceneManager.setConstraintScalar(c.id, .constraintMix, $0, pushUndo: false) }
                        ),
                        range: 0...1,
                        tint: tint
                    )

                    pathSlider(
                        title: "Softness",
                        valueText: String(format: "%.1f", c.softness),
                        value: Binding(
                            get: { c.softness },
                            set: { sceneManager.setConstraintScalar(c.id, .ikSoftness, $0, pushUndo: false) }
                        ),
                        range: 0...200,
                        tint: tint
                    )

                    // Bend direction. Two bones can reach a target two ways; this
                    // picks which elbow the chain uses.
                    HStack {
                        Text("Bend")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(UM.textPrimary.opacity(0.68))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { c.bendPositive },
                            set: { sceneManager.setConstraintFlag(c.id, .ikBendPositive, $0) }
                        )) {
                            Text("Positive").tag(true)
                            Text("Negative").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }

                    // Reach behaviour.
                    VStack(alignment: .leading, spacing: 5) {
                        ikToggle("Stretch", isOn: c.stretch, tint: tint,
                                 help: "Lengthen the chain when the target is out of reach.") {
                            sceneManager.setConstraintFlag(c.id, .ikStretch, $0)
                        }
                        ikToggle("Compress", isOn: c.compress, tint: tint,
                                 help: "Shorten the chain when the target is closer than its rest length.") {
                            sceneManager.setConstraintFlag(c.id, .ikCompress, $0)
                        }
                        // Uniform Scale has no animation track, so it writes the
                        // constraint directly rather than going through a key.
                        ikToggle("Uniform Scale", isOn: c.uniformScale, tint: tint,
                                 help: "Scale both axes together while stretching, so the bone does not thin out.") { newValue in
                            sceneManager.updateIKConstraint(c.id) { $0.uniformScale = newValue }
                        }
                    }

                    constraintAnimationSection(c.id, tint: tint)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(UM.textPrimary.opacity(isSelected ? 0.07 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? tint.opacity(0.6) : UM.textPrimary.opacity(0.08), lineWidth: 1)
        )
    }

    /// Labelled switch with an explanatory caption, used by the IK reach options
    /// where the names alone do not convey what they do.
    @ViewBuilder
    private func ikToggle(
        _ title: String,
        isOn: Bool,
        tint: Color,
        help: String,
        action: @escaping (Bool) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(UM.textPrimary.opacity(0.72))
                Spacer()
                Toggle("", isOn: Binding(get: { isOn }, set: action))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .scaleEffect(0.72)
                    .frame(height: 16)
                    .tint(tint)
            }
            Text(help)
                .font(.system(size: 8.5))
                .foregroundStyle(UM.textPrimary.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Transform Constraint Card

    /// UltraMesh blue — used across every Transform Constraint UI affordance and the
    /// canvas gizmo, so the user can immediately associate the inspector card with
    /// the target → affected line drawn over the rig.
    private var transformBlue: Color { Color(red: 0.28, green: 0.68, blue: 1.00) }

    @ViewBuilder
    private func transformConstraintCard(_ binding: Binding<TransformConstraint>) -> some View {
        let tint = transformBlue
        let c = binding.wrappedValue
        let constraintID = c.id
        let isSelected = sceneManager.selectedConstraintID == constraintID
        let targetBone = sceneManager.skeleton.bone(c.targetBoneID)

        VStack(alignment: .leading, spacing: 0) {
            // Header — name, enabled toggle, overflow menu (rename / duplicate / delete).
            HStack(spacing: 8) {
                Image(systemName: "move.3d")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                TextField("", text: Binding(
                    get: { binding.wrappedValue.name },
                    set: { sceneManager.renameTransformConstraint(constraintID, to: $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UM.textPrimary.opacity(0.92))
                .lineLimit(1)
                Spacer(minLength: 0)
                Toggle("", isOn: binding.enabled)
                    .toggleStyle(.switch)
                    .scaleEffect(0.72)
                    .labelsHidden()
                    .tint(tint)
                Menu {
                    Button("Duplicate") { sceneManager.duplicateTransformConstraint(constraintID) }
                    Divider()
                    Button("Delete", role: .destructive) {
                        sceneManager.deleteTransformConstraint(constraintID)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UM.textPrimary.opacity(0.6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                sceneManager.selectedConstraintID = isSelected ? nil : constraintID
            }

            if c.enabled {
                Divider()
                    .overlay(UM.textPrimary.opacity(0.08))
                    .padding(.horizontal, 8)

                VStack(alignment: .leading, spacing: 10) {
                    transformConstraintTargetRow(binding: binding, targetBone: targetBone, tint: tint)

                    pathSlider(title: "Mix",
                               valueText: String(format: "%.2f", c.mix),
                               value: binding.mix, range: 0...1,
                               tint: tint)

                    Divider().overlay(UM.textPrimary.opacity(0.06))

                    // Channel grid — toggles, mix sliders, offset fields per channel.
                    transformChannelGroup(
                        title: "Position",
                        enabled: binding.copyPosition,
                        mix: binding.positionMix,
                        offsets: .twoAxis(
                            x: binding.offsetPositionX,
                            y: binding.offsetPositionY,
                            xLabel: "Offset X",
                            yLabel: "Offset Y",
                            range: -500...500,
                            format: "%.0f"
                        ),
                        tint: tint
                    )

                    transformChannelGroup(
                        title: "Rotation",
                        enabled: binding.copyRotation,
                        mix: binding.rotationMix,
                        offsets: .angleDegrees(binding: binding.offsetRotation),
                        tint: tint
                    )

                    transformChannelGroup(
                        title: "Scale",
                        enabled: binding.copyScale,
                        mix: binding.scaleMix,
                        offsets: .twoAxis(
                            x: binding.offsetScaleX,
                            y: binding.offsetScaleY,
                            xLabel: "Offset X",
                            yLabel: "Offset Y",
                            range: -2...2,
                            format: "%.2f"
                        ),
                        tint: tint
                    )

                    transformChannelGroup(
                        title: "Shear",
                        enabled: binding.copyShear,
                        mix: binding.shearMix,
                        offsets: .angleDegrees(binding: binding.offsetShear),
                        tint: tint
                    )

                    Divider().overlay(UM.textPrimary.opacity(0.06))

                    // Affected bones — chips with remove buttons + add-from-selection.
                    transformConstraintAffectedBonesRow(binding: binding, tint: tint)

                    constraintAnimationSection(binding.wrappedValue.id, tint: tint)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(UM.textPrimary.opacity(isSelected ? 0.07 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? tint.opacity(0.6) : UM.textPrimary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func transformConstraintTargetRow(
        binding: Binding<TransformConstraint>,
        targetBone: Bone?,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            Text("Target")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(UM.textPrimary.opacity(0.6))
            Spacer(minLength: 0)
            Menu {
                ForEach(orderedBones) { bone in
                    Button(bone.name) {
                        sceneManager.setTransformConstraintTarget(binding.wrappedValue.id, target: bone.id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if let targetBone {
                        Circle()
                            .fill(swiftUIColor(targetBone.color ?? UM.unboundBone))
                            .frame(width: 7, height: 7)
                        Text(targetBone.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(UM.textPrimary.opacity(0.9))
                    } else {
                        Text("None")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(UM.textPrimary.opacity(0.55))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(UM.textPrimary.opacity(0.55))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(tint.opacity(0.28), lineWidth: 1)
                        )
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// Per-channel control: enable checkbox + mix slider + offset fields.
    /// All offset variants share the same row layout so the inspector stays calm.
    @ViewBuilder
    private func transformChannelGroup(
        title: String,
        enabled: Binding<Bool>,
        mix: Binding<Float>,
        offsets: TransformChannelOffsets,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: enabled) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(UM.textPrimary.opacity(enabled.wrappedValue ? 0.9 : 0.45))
                }
#if os(macOS)
                .toggleStyle(.checkbox)
#endif
                .tint(tint)
                Spacer(minLength: 0)
                Text(String(format: "%.2f", mix.wrappedValue))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(UM.textPrimary.opacity(0.85))
            }

            CapsuleSlider(
                value: Binding(
                    get: { Double(mix.wrappedValue) },
                    set: { mix.wrappedValue = Float($0) }
                ),
                in: 0...1
            )
            .tint(tint)
            .frame(height: 18)
            .disabled(!enabled.wrappedValue)
            .opacity(enabled.wrappedValue ? 1.0 : 0.45)

            offsets.body(tint: tint, enabled: enabled.wrappedValue)
        }
    }

    @ViewBuilder
    private func transformConstraintAffectedBonesRow(
        binding: Binding<TransformConstraint>,
        tint: Color
    ) -> some View {
        let c = binding.wrappedValue
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Affected (\(c.affectedBones.count))")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(UM.textPrimary.opacity(0.5))
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                if let selectedBoneID = sceneManager.selectedBoneID,
                   selectedBoneID != c.targetBoneID,
                   !c.affectedBones.contains(selectedBoneID) {
                    Button {
                        sceneManager.addAffectedBone(selectedBoneID, to: c.id)
                    } label: {
                        Label("Add Selected", systemImage: "plus")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tint)
                }
            }

            if c.affectedBones.isEmpty {
                Text("Select a bone and tap “Add Selected”.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(UM.textPrimary.opacity(0.45))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(c.affectedBones, id: \.self) { boneID in
                            if let bone = sceneManager.skeleton.bone(boneID) {
                                HStack(spacing: 4) {
                                    boneChip(bone, color: tint)
                                    Button {
                                        sceneManager.removeAffectedBone(boneID, from: c.id)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(UM.textPrimary.opacity(0.5))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Path Constraint Card

    @ViewBuilder
    private func pathConstraintCard(_ binding: Binding<PathConstraint>) -> some View {
        let pathBlue = Color(red: 0.28, green: 0.68, blue: 1.00)
        let c = binding.wrappedValue
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(pathBlue)
                Text(c.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UM.textPrimary.opacity(0.92))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Toggle("", isOn: binding.enabled)
                    .toggleStyle(.switch)
                    .scaleEffect(0.72)
                    .labelsHidden()
                    .tint(pathBlue)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if c.enabled {
                Divider()
                    .overlay(UM.textPrimary.opacity(0.08))
                    .padding(.horizontal, 8)

                VStack(alignment: .leading, spacing: 8) {
                    // Position slider
                    pathSlider(title: "Position",
                               valueText: String(format: "%.0f%%", c.position * 100),
                               value: binding.position, range: 0...1,
                               tint: pathBlue)

                    // Spacing (range adapts to spacing mode)
                    let spacingRange: ClosedRange<Float> = c.spacingMode == .percent ? 0...1 : 0...500
                    let spacingText = c.spacingMode == .percent
                        ? String(format: "%.0f%%", c.spacing * 100)
                        : String(format: "%.0f", c.spacing)
                    pathSlider(title: "Spacing",
                               valueText: spacingText,
                               value: binding.spacing,
                               range: spacingRange,
                               tint: pathBlue)

                    // Mix sliders
                    pathSlider(title: "Position Mix",
                               valueText: String(format: "%.2f", c.positionMix),
                               value: binding.positionMix, range: 0...1,
                               tint: pathBlue)

                    pathSlider(title: "Rotate Mix",
                               valueText: String(format: "%.2f", c.rotateMix),
                               value: binding.rotateMix, range: 0...1,
                               tint: pathBlue)

                    // Offset rotation
                    pathSlider(title: "Offset Rotation",
                               valueText: String(format: "%.1f°", c.offsetRotation * 180 / .pi),
                               value: Binding(
                                   get: { binding.wrappedValue.offsetRotation / .pi },
                                   set: { binding.offsetRotation.wrappedValue = $0 * .pi }
                               ),
                               range: -1...1,
                               tint: pathBlue)

                    // Spacing mode picker
                    HStack(spacing: 6) {
                        Text("Spacing Mode")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(UM.textPrimary.opacity(0.6))
                        Spacer()
                        Picker("", selection: binding.spacingMode) {
                            Text("Length").tag(PathSpacingMode.length)
                            Text("%").tag(PathSpacingMode.percent)
                            Text("Bone").tag(PathSpacingMode.proportional)
                            Text("Fixed").tag(PathSpacingMode.fixed)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 168)
                    }

                    // Rotate mode — how followers orient along the curve.
                    HStack {
                        Text("Rotate Mode")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(UM.textPrimary.opacity(0.68))
                        Spacer()
                        Picker("", selection: binding.rotateMode) {
                            ForEach(PathRotateMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }

                    HStack(spacing: 14) {
                        Toggle(isOn: binding.closed) {
                            Text("Closed")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(UM.textPrimary.opacity(0.68))
                        }
                        .toggleStyle(.switch)
                        .scaleEffect(0.8)
                        .fixedSize()

                        Toggle(isOn: binding.reversed) {
                            Text("Reverse")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(UM.textPrimary.opacity(0.68))
                        }
                        .toggleStyle(.switch)
                        .scaleEffect(0.8)
                        .fixedSize()

                        Spacer(minLength: 0)
                    }

                    // Path bones chips
                    if !c.pathBones.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Path Bones")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(UM.textPrimary.opacity(0.45))
                                .textCase(.uppercase)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(c.pathBones, id: \.self) { boneID in
                                        if let bone = sceneManager.skeleton.bone(boneID) {
                                            boneChip(bone, color: pathBlue.opacity(0.8))
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Follower bones chips + add button
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Follower Bones")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(UM.textPrimary.opacity(0.45))
                                .textCase(.uppercase)
                            Spacer()
                            // Add selected bone as a follower
                            if let primary = sceneManager.selectedBoneID,
                               !c.bones.contains(primary) && !c.pathBones.contains(primary) {
                                Button {
                                    binding.bones.wrappedValue.append(primary)
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 9, weight: .bold))
                                        Text("Add Selected")
                                            .font(.system(size: 9, weight: .semibold))
                                    }
                                    .foregroundStyle(pathBlue)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if c.bones.isEmpty {
                            Text("No follower bones.")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(UM.textPrimary.opacity(0.38))
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(c.bones, id: \.self) { boneID in
                                        if let bone = sceneManager.skeleton.bone(boneID) {
                                            boneChip(bone, color: UM.textPrimary.opacity(0.55))
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Followers — the bones the path drives.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Followers")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(UM.textPrimary.opacity(0.45))
                                .textCase(.uppercase)
                            Spacer()
                            Button("Add Selected") {
                                for bone in sceneManager.selectedBonesInChainOrder {
                                    sceneManager.addFollowerToPath(bone.id, constraintID: c.id)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(pathBlue.opacity(0.85))
                        }

                        if c.bones.isEmpty {
                            Text("No followers — nothing will move along this path.")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.orange.opacity(0.7))
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(c.bones, id: \.self) { boneID in
                                        if let bone = sceneManager.skeleton.bones[boneID] {
                                            HStack(spacing: 3) {
                                                boneChip(bone, color: pathBlue.opacity(0.8))
                                                Button {
                                                    sceneManager.removeFollowerFromPath(boneID, constraintID: c.id)
                                                } label: {
                                                    Image(systemName: "xmark")
                                                        .font(.system(size: 7, weight: .bold))
                                                        .foregroundStyle(UM.textPrimary.opacity(0.4))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Button("Set Path Points from Selection") {
                            sceneManager.setPathControlBonesFromSelection(c.id)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(pathBlue.opacity(0.85))
                    }

                    constraintAnimationSection(c.id, tint: pathBlue)

                    HStack(spacing: 10) {
                        Button {
                            sceneManager.duplicatePathConstraint(c.id)
                        } label: {
                            Text("Duplicate")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(pathBlue.opacity(0.85))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            sceneManager.deletePathConstraint(c.id)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 10, weight: .medium))
                                Text("Remove Constraint")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(Color.red.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .padding(.top, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(UM.textPrimary.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(pathBlue.opacity(c.enabled ? 0.35 : 0.14), lineWidth: 1)
                )
        )
    }

    // MARK: - Physics Constraint Card

    @ViewBuilder
    private func physicsConstraintCard(_ binding: Binding<PhysicsConstraint>) -> some View {
        let physicsOrange = Color(red: 1.00, green: 0.55, blue: 0.15)
        let c = binding.wrappedValue
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: c.physicsType.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(physicsOrange)
                Text(c.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UM.textPrimary.opacity(0.92))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Toggle("", isOn: binding.enabled)
                    .toggleStyle(.switch)
                    .scaleEffect(0.72)
                    .labelsHidden()
                    .tint(physicsOrange)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if c.enabled {
                Divider()
                    .overlay(UM.textPrimary.opacity(0.08))
                    .padding(.horizontal, 8)

                VStack(alignment: .leading, spacing: 8) {
                    // Type picker
                    HStack(spacing: 6) {
                        Text("Type")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(UM.textPrimary.opacity(0.6))
                        Spacer()
                        Picker("", selection: binding.physicsType) {
                            ForEach(PhysicsType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 110)
                    }

                    // Preset menu
                    Menu {
                        ForEach(PhysicsPreset.allCases.filter { $0 != .custom }, id: \.self) { preset in
                            Button {
                                binding.physicsType.wrappedValue = preset.physicsType
                                binding.settings.wrappedValue = preset.settings()
                            } label: {
                                Text(preset.displayName)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Apply Preset")
                                .font(.system(size: 10, weight: .semibold))
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(UM.textPrimary.opacity(0.5))
                        }
                        .foregroundStyle(physicsOrange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(physicsOrange.opacity(0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(physicsOrange.opacity(0.28), lineWidth: 1)
                                )
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(UM.textPrimary.opacity(0.06))

                    // Mix
                    pathSlider(title: "Mix",
                               valueText: String(format: "%.2f", c.mix),
                               value: binding.mix, range: 0...1,
                               tint: physicsOrange)

                    // Mass
                    pathSlider(title: "Mass",
                               valueText: String(format: "%.2f", c.settings.mass),
                               value: Binding(
                                   get: { binding.wrappedValue.settings.mass },
                                   set: { binding.settings.wrappedValue.mass = $0 }
                               ),
                               range: 0.1...5.0,
                               tint: physicsOrange)

                    // Damping
                    pathSlider(title: "Damping",
                               valueText: String(format: "%.2f", c.settings.damping),
                               value: Binding(
                                   get: { binding.wrappedValue.settings.damping },
                                   set: { binding.settings.wrappedValue.damping = $0 }
                               ),
                               range: 0...0.99,
                               tint: physicsOrange)

                    // Stiffness
                    pathSlider(title: "Stiffness",
                               valueText: String(format: "%.0f", c.settings.stiffness),
                               value: Binding(
                                   get: { binding.wrappedValue.settings.stiffness },
                                   set: { binding.settings.wrappedValue.stiffness = $0 }
                               ),
                               range: 0...500,
                               tint: physicsOrange)

                    // Gravity
                    pathSlider(title: "Gravity",
                               valueText: String(format: "%.0f", c.settings.gravity),
                               value: Binding(
                                   get: { binding.wrappedValue.settings.gravity },
                                   set: { binding.settings.wrappedValue.gravity = $0 }
                               ),
                               range: 0...1200,
                               tint: physicsOrange)

                    // Drag
                    pathSlider(title: "Drag",
                               valueText: String(format: "%.3f", c.settings.drag),
                               value: Binding(
                                   get: { binding.wrappedValue.settings.drag },
                                   set: { binding.settings.wrappedValue.drag = $0 }
                               ),
                               range: 0...0.3,
                               tint: physicsOrange)

                    // Wind X / Y
                    pathSlider(title: "Wind X",
                               valueText: String(format: "%.0f", c.settings.wind.x),
                               value: Binding(
                                   get: { binding.wrappedValue.settings.wind.x },
                                   set: { binding.settings.wrappedValue.wind.x = $0 }
                               ),
                               range: -500...500,
                               tint: physicsOrange)

                    pathSlider(title: "Wind Y",
                               valueText: String(format: "%.0f", c.settings.wind.y),
                               value: Binding(
                                   get: { binding.wrappedValue.settings.wind.y },
                                   set: { binding.settings.wrappedValue.wind.y = $0 }
                               ),
                               range: -500...500,
                               tint: physicsOrange)

                    // Affected bones chips (index 0 = pinned root, rest = simulated)
                    if !c.affectedBones.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Bones (\(c.affectedBones.count))")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(UM.textPrimary.opacity(0.45))
                                .textCase(.uppercase)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(c.affectedBones.indices, id: \.self) { i in
                                        if let bone = sceneManager.skeleton.bone(c.affectedBones[i]) {
                                            boneChip(bone, color: i == 0 ? physicsOrange : UM.textPrimary.opacity(0.55))
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Quality picker
                    HStack(spacing: 6) {
                        Text("Quality")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(UM.textPrimary.opacity(0.6))
                        Spacer()
                        Picker("", selection: physicsQualityBinding()) {
                            Text("Low").tag(PhysicsQuality.low)
                            Text("Med").tag(PhysicsQuality.medium)
                            Text("High").tag(PhysicsQuality.high)
                            Text("Ultra").tag(PhysicsQuality.ultra)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }

                    // Simulation controls
                    HStack(spacing: 8) {
                        Button {
                            sceneManager.resetPhysicsSimulation()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("Reset")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(UM.textPrimary.opacity(0.7))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(UM.textPrimary.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(UM.textPrimary.opacity(0.12), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)

                        Button {
                            sceneManager.bakePhysicsToKeys()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("Bake To Keys")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(physicsOrange.opacity(0.9))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(physicsOrange.opacity(0.10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(physicsOrange.opacity(0.28), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }

                    // Simulated chain.
                    HStack {
                        Text("Chain")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(UM.textPrimary.opacity(0.45))
                            .textCase(.uppercase)
                        Spacer()
                        Text("\(c.affectedBones.count) bone\(c.affectedBones.count == 1 ? "" : "s")")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(UM.textPrimary.opacity(0.4))
                        Button("Set from Selection") {
                            sceneManager.setPhysicsChainFromSelection(c.id)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(physicsOrange.opacity(0.85))
                    }

                    constraintAnimationSection(c.id, tint: physicsOrange)

                    Button {
                        sceneManager.duplicatePhysicsConstraint(c.id)
                    } label: {
                        Text("Duplicate")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(physicsOrange.opacity(0.85))
                    }
                    .buttonStyle(.plain)

                    // Delete
                    Button {
                        sceneManager.deletePhysicsConstraint(c.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .medium))
                            Text("Remove Constraint")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Color.red.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .padding(.top, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(UM.textPrimary.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(physicsOrange.opacity(c.enabled ? 0.35 : 0.14), lineWidth: 1)
                )
        )
    }

    private func physicsQualityBinding() -> Binding<PhysicsQuality> {
        Binding(
            get: { PhysicsConstraintSystem.shared.quality },
            set: { PhysicsConstraintSystem.shared.quality = $0 }
        )
    }

    private func boneChip(_ bone: Bone, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(swiftUIColor(bone.color ?? UM.unboundBone))
                .frame(width: 6, height: 6)
            Text(bone.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(UM.textPrimary.opacity(0.06))
                .overlay(Capsule(style: .continuous).stroke(UM.textPrimary.opacity(0.12), lineWidth: 0.5))
        )
    }

    // MARK: - Constraint animation (key icons)

    /// Diamond key button for one animatable constraint property.
    ///
    /// Filled when a key sits exactly on the playhead, outlined when the
    /// property is animated but not keyed here, and dimmed when the property is
    /// not animated at all — three states, so "animated elsewhere" never looks
    /// the same as "not animated".
    @ViewBuilder
    private func constraintKeyButton(
        _ constraintID: UUID,
        _ property: AnimationTrackProperty,
        tint: Color
    ) -> some View {
        let isAnimated = sceneManager.isConstraintPropertyAnimated(constraintID, property)
        let hasKeyHere = sceneManager.constraintPropertyHasKeyAtPlayhead(constraintID, property)

        Button {
            if hasKeyHere {
                sceneManager.removeConstraintKeyAtPlayhead(constraintID, property)
            } else {
                sceneManager.keyConstraintProperty(constraintID, property)
            }
        } label: {
            Image(systemName: hasKeyHere ? "diamond.fill" : "diamond")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(
                    hasKeyHere ? tint
                        : (isAnimated ? tint.opacity(0.75) : UM.textPrimary.opacity(0.28))
                )
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hasKeyHere ? "Remove key at playhead" : "Key \(property.title) at playhead")
    }

    /// One editable, keyable constraint property. Scalars get a slider, booleans
    /// get a toggle, vectors get paired X/Y steppers.
    @ViewBuilder
    private func constraintAnimationRow(
        _ constraintID: UUID,
        _ property: AnimationTrackProperty,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(property.title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(UM.textPrimary.opacity(0.68))
                Spacer(minLength: 0)

                switch property.valueKind {
                case .scalar:
                    Text(String(format: "%.2f", sceneManager.constraintScalarValue(constraintID, property)))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(UM.textPrimary.opacity(0.85))
                case .flag:
                    Toggle("", isOn: Binding(
                        get: { sceneManager.constraintFlagValue(constraintID, property) },
                        set: { sceneManager.setConstraintFlag(constraintID, property, $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .scaleEffect(0.72)
                    .frame(height: 16)
                case .vector2:
                    let value = sceneManager.constraintVectorValue(constraintID, property)
                    Text(String(format: "%.0f, %.0f", value.x, value.y))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(UM.textPrimary.opacity(0.85))
                case .deform, .drawOrder, .event, .attachment:
                    EmptyView()
                }

                constraintKeyButton(constraintID, property, tint: tint)
            }

            if property.valueKind == .scalar {
                let range = property.valueRange ?? 0...1
                CapsuleSlider(
                    value: Binding(
                        get: { Double(sceneManager.constraintScalarValue(constraintID, property)) },
                        set: {
                            // The whole drag is one undo step: `beginInteraction`
                            // below already pushed it, so intermediate values must
                            // not push again.
                            sceneManager.setConstraintScalar(constraintID, property, Float($0), pushUndo: false)
                        }
                    ),
                    in: Double(range.lowerBound)...Double(min(range.upperBound, 1000)),
                    onEditingChanged: { isEditing in
                        if isEditing {
                            sceneManager.beginInteraction()
                        } else {
                            sceneManager.endInteraction()
                        }
                    }
                )
                .tint(tint)
            }

            if property.valueKind == .vector2 {
                HStack(spacing: 6) {
                    ForEach(0..<2, id: \.self) { axis in
                        TextField(
                            axis == 0 ? "X" : "Y",
                            value: Binding(
                                get: {
                                    let v = sceneManager.constraintVectorValue(constraintID, property)
                                    return Double(axis == 0 ? v.x : v.y)
                                },
                                set: { newValue in
                                    var v = sceneManager.constraintVectorValue(constraintID, property)
                                    if axis == 0 { v.x = Float(newValue) } else { v.y = Float(newValue) }
                                    sceneManager.setConstraintVector(constraintID, property, v)
                                }
                            ),
                            format: .number
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(UM.textPrimary.opacity(0.06))
                        )
                    }
                }
            }
        }
    }

    /// The full animatable-property block for a constraint. Shown in Animate
    /// mode, where keying is meaningful; Setup mode keeps the card uncluttered.
    @ViewBuilder
    private func constraintAnimationSection(_ constraintID: UUID, tint: Color) -> some View {
        if sceneManager.isAnimationEditingEnabled,
           let kind = sceneManager.skeleton.constraintKind(for: constraintID) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(tint.opacity(0.85))
                    Text("ANIMATION")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .kerning(0.6)
                        .foregroundStyle(UM.textPrimary.opacity(0.5))
                    Spacer(minLength: 0)
                    if sceneManager.hasAnyConstraintTrack(constraintID) {
                        Button("Clear") {
                            sceneManager.removeAllConstraintTracks(constraintID)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.62))
                    }
                }

                ForEach(kind.animatableProperties, id: \.self) { property in
                    constraintAnimationRow(constraintID, property, tint: tint)
                }
            }
            .padding(.top, 2)
        }
    }

    private func pathSlider(
        title: String,
        valueText: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(UM.textPrimary.opacity(0.68))
                Spacer()
                Text(valueText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(UM.textPrimary.opacity(0.85))
            }
            CapsuleSlider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Float($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .tint(tint)
        }
    }

    @ViewBuilder
    private func boneInspector(_ bone: Bone) -> some View {
        selectionHeader(title: bone.name, kind: "BONE", accent: ultraPurple)

        // Reachable with a single bone selected: the builder no longer needs a
        // multi-selection, and requiring one was the reason IK felt unreachable.
        if inspectorTab == .constraints {
        inspectorSection(spacing: 8) {
            sectionTitle("Constraints")

            // Constraints this bone takes part in, either as a link in the
            // chain or as the target. Without this the card was only reachable
            // from a multi-selection, so a constraint could be created and then
            // never found again.
            let related = sceneManager.skeleton.ikConstraints.indices.filter { index in
                let c = sceneManager.skeleton.ikConstraints[index]
                return c.boneChain.contains(bone.id) || c.targetBoneID == bone.id
            }
            ForEach(related, id: \.self) { index in
                ikConstraintCard(Binding(
                    get: { sceneManager.skeleton.ikConstraints[index] },
                    set: { sceneManager.skeleton.ikConstraints[index] = $0 }
                ))
            }

            Button {
                sceneManager.beginIKBuilder()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .bold))
                    Text("New IK Constraint…")
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(ultraPurple)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(neutralButtonFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(sectionStroke, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
        }

        if inspectorTab == .properties {
        inspectorSection(spacing: 8) {
            sectionTitle("Mirror")

            // Symmetrical rigs: the partner is found by name convention
            // (arm_L ↔ arm_R, left/right), so nothing has to be configured.
            let partnerName = sceneManager.mirroredBone(of: bone.id)
                .flatMap { sceneManager.skeleton.bones[$0]?.name }

            HStack(spacing: 6) {
                Button {
                    sceneManager.mirrorBonePose([bone.id])
                } label: {
                    Text("Pose → \(partnerName ?? "partner")")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(partnerName == nil ? UM.textPrimary.opacity(0.25) : ultraPurple)
                .disabled(partnerName == nil)

                Spacer(minLength: 0)

                Button {
                    sceneManager.flipBonePose(bone.id)
                } label: {
                    Text("Flip")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ultraPurple)
            }

            if partnerName == nil {
                Text("No mirror partner. Name bones with a side marker such as _L / _R to enable pose mirroring.")
                    .font(.system(size: 9))
                    .foregroundStyle(UM.textPrimary.opacity(0.38))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        inspectorSection {
            sectionTitle("Hierarchy")

            Picker("Parent", selection: parentBinding(for: bone.id)) {
                Text("Root").tag(nil as UUID?)
                ForEach(parentOptions(for: bone.id)) { candidate in
                    Text(candidate.name).tag(Optional(candidate.id))
                }
            }
            .pickerStyle(.menu)

            Text("Shift-drag from the tip to create a child bone.")
                .font(.system(size: 11))
                .foregroundStyle(UM.textPrimary.opacity(0.6))
        }
        }

        if sceneManager.isMeshEditEnabled {
            inspectorSection(spacing: 8) {
                sectionTitle("Mesh")
                Text("Select a sprite to edit its mesh. Bones have no mesh of their own.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UM.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func boundBoneBinding(for imageID: UUID) -> Binding<UUID?> {
        Binding(
            get: { sceneManager.image(for: imageID)?.boneBinding?.boneID },
            set: { newValue in sceneManager.bindImage(imageID, to: newValue) }
        )
    }

    private func swiftUIColor(_ value: SIMD4<Float>?) -> Color {
        guard let value else { return Color.gray }
        return Color(.sRGB,
                     red: Double(value.x),
                     green: Double(value.y),
                     blue: Double(value.z),
                     opacity: Double(value.w))
    }

    private func parentBinding(for boneID: UUID) -> Binding<UUID?> {
        Binding(
            get: { sceneManager.skeleton.bone(boneID)?.parentID },
            set: { newValue in sceneManager.reparentBone(id: boneID, to: newValue) }
        )
    }

    private func parentOptions(for boneID: UUID) -> [Bone] {
        orderedBones.filter { candidate in
            candidate.id != boneID && sceneManager.skeleton.canParent(boneID, to: candidate.id)
        }
    }

    private func meshBinding(get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: get, set: set)
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Inspector")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(UM.textPrimary)
            Spacer(minLength: 0)
            if let onToggleVisibility {
                Button(action: onToggleVisibility) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(UM.textPrimary.opacity(0.82))
                        .frame(width: 23, height: 23)
                        .background(
                            Circle()
                                .fill(sectionFillElevated.opacity(0.9))
                                .overlay(
                                    Circle()
                                        .stroke(UM.textPrimary.opacity(0.14), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .help("Hide Inspector")
            }
        }
    }

    private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [sectionFillElevated.opacity(0.94), sectionFill.opacity(0.98)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                            .stroke(UM.textPrimary.opacity(0.11), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 6)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(UM.textPrimary.opacity(0.68))
            .textCase(.uppercase)
    }

    private func selectionHeader(title: String, kind: String, accent: Color) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(kind)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(UM.textPrimary.opacity(0.56))
                    .textCase(.uppercase)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UM.textPrimary.opacity(0.96))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer()
        }
    }

    private func inspectorSection<Content: View>(spacing: CGFloat = 10, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [sectionFillElevated.opacity(0.82), sectionFill.opacity(0.95)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(sectionStroke, lineWidth: 1)
                )
        )
    }


    private func segmentedContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            content()
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(sectionFillElevated.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(UM.textPrimary.opacity(0.11), lineWidth: 1)
                )
        )
    }

    private var emptyStateCard: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(UM.accentSoft.opacity(0.55))
                    .frame(width: 84, height: 84)
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(UM.textPrimary.opacity(0.55))
            }
            Text("Select an image, mesh, or bone in the Hierarchy to edit it here.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(UM.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 190)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// Properties / Mesh / Constraints.
    ///
    /// The inspector was one long scroll where mesh tools, skinning and
    /// constraint editors all stacked up and the artist scrolled past whichever
    /// two they were not using. The mockup splits them, and the split is also
    /// what lets Constraints stop being a toolbar button.
    ///
    /// Spelled "Constraints" — the mockup reads "Constrains", which is a typo
    /// worth not shipping into the UI.
    /// Opening a tab is what turns its mode on.
    ///
    /// Weight paint used to be reached from the canvas mode strip and then
    /// displayed inside the Mesh tab, so painting weights meant being in mesh
    /// editing. Now the tab IS the mode: open Weights and the brush is live,
    /// leave it and it is not. Nothing is left switched on behind a panel the
    /// artist has navigated away from, which is the whole complaint about the
    /// button this replaces.
    /// Opening a tab is now only opening a tab.
    ///
    /// It used to turn canvas modes on and off as a side effect, because Mesh
    /// and Weights were tabs as well as modes. They are modes only; this is a
    /// tab strip again.
    private func selectInspectorTab(_ tab: InspectorTab) {
        inspectorTab = tab
    }

    /// True while a canvas mode owns the inspector.
    ///
    /// Mesh mode IS the mesh panel and weight paint IS the weights panel — one
    /// panel for the mode you are in, rather than its tools mixed into a strip
    /// alongside things that have nothing to do with what you are doing.
    private var isModePanelOpen: Bool {
        CanvasModeSelection.active(scene: sceneManager, tools: toolManager)?.ownsInspector == true
    }

    private var inspectorTabBar: some View {
        HStack(spacing: 3) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) { selectInspectorTab(tab) }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 11, weight: .semibold))
                        // Four tabs now, and "Constraints" is long. Let it
                        // shrink rather than truncate in a narrow Inspector.
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .foregroundStyle(inspectorTab == tab ? UM.textPrimary : UM.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(inspectorTab == tab ? UM.accent.opacity(0.85) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(UM.surfaceInset))
    }

    private func makeAlphaSampler(for fileURL: URL) -> ((Int, Int) -> Float)? {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return { x, y in
            guard x >= 0, x < width, y >= 0, y < height else { return 0 }
            let index = y * bytesPerRow + x * bytesPerPixel + 3
            return Float(pixels[index]) / 255.0
        }
    }
}

/// Lightweight descriptor for Transform Constraint per-channel offsets, used by the
/// inspector card to render either a single-angle field (rotation, shear) or a pair
/// of X/Y numeric fields (position, scale) with a unified row layout.
enum TransformChannelOffsets {
    case twoAxis(x: Binding<Float>, y: Binding<Float>, xLabel: String, yLabel: String, range: ClosedRange<Float>, format: String)
    case angleDegrees(binding: Binding<Float>)

    @ViewBuilder
    func body(tint: Color, enabled: Bool) -> some View {
        switch self {
        case let .twoAxis(x, y, xLabel, yLabel, range, format):
            HStack(spacing: 6) {
                TransformOffsetField(label: xLabel, value: x, range: range, format: format, tint: tint)
                TransformOffsetField(label: yLabel, value: y, range: range, format: format, tint: tint)
            }
            .opacity(enabled ? 1.0 : 0.45)
            .disabled(!enabled)
        case let .angleDegrees(binding):
            // Convert radians ↔ degrees at the binding edge so the field reads naturally
            // ("45°" instead of "0.785 rad") while storage remains canonical radians.
            let degreesBinding = Binding<Float>(
                get: { binding.wrappedValue * 180 / .pi },
                set: { binding.wrappedValue = $0 * .pi / 180 }
            )
            TransformOffsetField(label: "Offset", value: degreesBinding, range: -360...360, format: "%.0f°", tint: tint)
                .opacity(enabled ? 1.0 : 0.45)
                .disabled(!enabled)
        }
    }
}

/// Compact numeric field used for Transform Constraint offsets. Editable via direct
/// text entry; commits on submit / focus loss so transient typing doesn't churn the
/// undo stack.
private struct TransformOffsetField: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: String
    let tint: Color

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(UM.textPrimary.opacity(0.5))
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(UM.textPrimary.opacity(0.92))
                .focused($focused)
                .onAppear { draft = String(format: format, value) }
                .onChange(of: value) { _, newValue in
                    if !focused { draft = String(format: format, newValue) }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .onSubmit { commit() }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(UM.textPrimary.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(focused ? tint.opacity(0.55) : UM.textPrimary.opacity(0.10), lineWidth: 1)
                        )
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commit() {
        // Strip trailing units ("°") so users can leave them visible while editing.
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "°", with: "")
        if let parsed = Float(trimmed) {
            let clamped = min(max(parsed, range.lowerBound), range.upperBound)
            value = clamped
            draft = String(format: format, clamped)
        } else {
            draft = String(format: format, value)
        }
    }
}


#Preview {
    InspectorPanelView()
        .environmentObject(AppState())
}
