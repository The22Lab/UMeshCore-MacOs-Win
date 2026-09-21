import SwiftUI

/// The Weights panel, built to the approved Inspector_Weights mock.
///
/// Binding at the top, then the brush: a green Add / Subtract / Replace
/// segment, four action pills, five sliders, the overlay toggle, and the list
/// of bones bound to this sprite.
///
/// Sized the way the Mesh panel is — every dimension is the mock's own
/// measurement over the mock's content width (244px), scaled by the width the
/// panel is actually given, with a floor so the 11px label never falls under
/// 9pt in the narrowest inspector.
///
/// Colours are all in `UM`, and they are the SECOND drawing's, tone for tone.
/// The first one needed five inks darkened to be readable; this one was redrawn
/// with that in mind, so nothing here is substituted. What the palette costs is
/// measured and printed by `verify_weights_inspector_look.py` on every run.
struct WeightsInspectorPanel: View {
    @ObservedObject var sceneManager: SceneManager
    let image: SceneImage
    let assetSize: SIMD2<Float>?

    @State private var panelWidth: CGFloat = InspectorMetrics.defaultWidth
    @State private var mirrorResult: String?

    var body: some View {
        card(InspectorMetrics(width: panelWidth))
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { panelWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in
                            panelWidth = width
                        }
                }
            )
    }

    // MARK: - Card

    private func card(_ m: InspectorMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("BINDING", m: m)
                .padding(.bottom, m.rowGap)
            bindingRow(m)

            divider.padding(.vertical, m.sectionGap)

            heading("WEIGHT PAINT", m: m)
                .padding(.bottom, m.rowGap)
            modeSegments(m)
            actionPills(m).padding(.top, m.gap)

            divider.padding(.vertical, m.sectionGap)

            sliders(m)

            divider.padding(.vertical, m.sectionGap)

            overlayToggle(m)

            selectedVertexWeights(m)

            boundBones(m)
        }
        .padding(m.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: m.corner, style: .continuous)
                .fill(UM.inspectorCard)
                .overlay(
                    RoundedRectangle(cornerRadius: m.corner, style: .continuous)
                        .stroke(UM.inspectorCardBorder, lineWidth: 1)
                )
        )
    }

    private func heading(_ title: String, m: InspectorMetrics) -> some View {
        HStack(spacing: m.unit * 8) {
            Text(title)
                .font(.system(size: m.headingSize, weight: .bold, design: .rounded))
                .tracking(m.headingSize * 0.14)
                .foregroundStyle(UM.inspectorHeadingInk)
                .lineLimit(1)
            Rectangle().fill(UM.inspectorRule).frame(height: 1)
        }
    }

    private var divider: some View {
        Rectangle().fill(UM.inspectorRule).frame(height: 1)
    }

    // MARK: - Binding

    private func bindingRow(_ m: InspectorMetrics) -> some View {
        HStack(spacing: m.gap) {
            solidPill("Auto-Bind", icon: "wand.and.stars", m: m,
                      fill: UM.weightsBindFill, ink: UM.weightsBindInk,
                      isLit: false) {
                guard let assetSize else { return }
                sceneManager.autoBindImage(imageID: image.id, assetSize: assetSize)
                sceneManager.isBindingBonesMode = false
            }

            solidPill("Bind Bones", icon: "point.topleft.down.to.point.bottomright.curvepath",
                      m: m, fill: UM.weightsBindBonesFill, ink: UM.weightsBindBonesInk,
                      isLit: sceneManager.isBindingBonesMode) {
                sceneManager.isBindingBonesMode.toggle()
            }
        }
    }

    // MARK: - Add / Subtract / Replace

    private func modeSegments(_ m: InspectorMetrics) -> some View {
        HStack(spacing: m.unit * 2) {
            segment("Add", mode: .add, m: m)
            segment("Subtract", mode: .subtract, m: m)
            segment("Replace", mode: .replace, m: m)
        }
        .padding(m.unit * 3)
        .background(
            Capsule(style: .continuous)
                .fill(UM.inspectorSegmentTrack)
        )
    }

    @ViewBuilder
    private func segment(_ title: String, mode: MeshWeightPaintMode, m: InspectorMetrics) -> some View {
        let isActive = sceneManager.meshWeightPaintMode == mode
        Button {
            sceneManager.meshWeightPaintMode = mode
        } label: {
            Text(title)
                .font(.system(size: m.segmentSize, weight: .bold, design: .rounded))
                .foregroundStyle(isActive ? UM.inspectorSegmentActiveInk : UM.inspectorSegmentInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: m.segmentHeight)
                .background(
                    Capsule(style: .continuous)
                        .fill(isActive ? UM.inspectorSegmentActive : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func actionPills(_ m: InspectorMetrics) -> some View {
        VStack(spacing: m.gap) {
            HStack(spacing: m.gap) {
                gradientPill("Auto-Weight", icon: nil, m: m,
                             start: UM.weightsAutoStart, end: UM.weightsAutoEnd,
                             ink: UM.weightsAutoInk) {
                    sceneManager.autoWeightSelectedMesh(
                        maxInfluences: sceneManager.meshWeightMaxInfluencesPerVertex)
                }
                solidPill("Smooth", icon: nil, m: m,
                          fill: UM.inspectorPillFill, ink: UM.weightsSmoothInk,
                          isLit: sceneManager.meshWeightPaintMode == .smooth) {
                    sceneManager.meshWeightPaintMode = .smooth
                }
            }
            HStack(spacing: m.gap) {
                solidPill("Normalize", icon: nil, m: m,
                          fill: UM.inspectorPillAltFill, ink: UM.inspectorPillInk,
                          isLit: false) {
                    sceneManager.normalizeMeshWeights(
                        imageID: image.id,
                        maxInfluences: sceneManager.meshWeightMaxInfluencesPerVertex)
                }
                solidPill("Reset", icon: nil, m: m,
                          fill: UM.inspectorPillFill, ink: UM.inspectorResetInk,
                          isLit: false) {
                    sceneManager.clearMeshWeights(imageID: image.id)
                }
            }
        }
    }

    private func gradientPill(_ title: String, icon: String?, m: InspectorMetrics,
                              start: Color, end: Color, ink: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            pillLabel(title, icon: icon, m: m, ink: ink)
                .background(
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [start, end],
                                             startPoint: .leading, endPoint: .trailing))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func solidPill(_ title: String, icon: String?, m: InspectorMetrics,
                           fill: Color, ink: Color, isLit: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            pillLabel(title, icon: icon, m: m, ink: ink)
                .background(
                    Capsule(style: .continuous)
                        .fill(fill)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(isLit ? ink.opacity(0.55) : Color.clear,
                                        lineWidth: isLit ? 1.5 : 0)
                        )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func pillLabel(_ title: String, icon: String?, m: InspectorMetrics, ink: Color) -> some View {
        HStack(spacing: m.unit * 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: m.buttonSize * 1.1, weight: .semibold))
            }
            Text(title)
                .font(.system(size: m.buttonSize, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity)
        .frame(height: m.pillHeight)
    }

    // MARK: - Sliders

    private func sliders(_ m: InspectorMetrics) -> some View {
        VStack(alignment: .leading, spacing: m.rowGap) {
            slider("Influence", m: m, text: String(format: "%.2f", sceneManager.meshWeightBrushInfluence),
                   value: Binding(get: { Double(sceneManager.meshWeightBrushInfluence) },
                                  set: { sceneManager.meshWeightBrushInfluence = Float($0) }),
                   range: 0...1)

            slider("Brush Radius", m: m, text: "\(Int(sceneManager.meshWeightBrushRadius.rounded()))",
                   value: Binding(get: { Double(sceneManager.meshWeightBrushRadius) },
                                  set: { sceneManager.meshWeightBrushRadius = Float($0) }),
                   range: 4...260)

            slider("Brush Strength", m: m, text: String(format: "%.2f", sceneManager.meshWeightBrushStrength),
                   value: Binding(get: { Double(sceneManager.meshWeightBrushStrength) },
                                  set: { sceneManager.meshWeightBrushStrength = Float($0) }),
                   range: 0.01...1)

            slider("Brush Falloff", m: m, text: String(format: "%.2f", sceneManager.meshWeightBrushFalloff),
                   value: Binding(get: { Double(sceneManager.meshWeightBrushFalloff) },
                                  set: { sceneManager.meshWeightBrushFalloff = Float($0) }),
                   range: 0.2...4)

            slider("Max Influences", m: m, note: "per vertex",
                   text: "\(sceneManager.meshWeightMaxInfluencesPerVertex)",
                   value: Binding(
                       get: { Double(sceneManager.meshWeightMaxInfluencesPerVertex) },
                       set: { sceneManager.meshWeightMaxInfluencesPerVertex = max(1, min(8, Int($0.rounded()))) }),
                   range: 1...8)
        }
    }

    @ViewBuilder
    private func slider(_ title: String, m: InspectorMetrics, note: String? = nil,
                        text: String, value: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: m.unit * 4) {
            HStack(spacing: m.unit * 6) {
                Text(title)
                    .font(.system(size: m.labelSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(UM.inspectorLabelInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let note {
                    Text("· \(note)")
                        .font(.system(size: m.buttonSize, weight: .medium, design: .rounded))
                        .foregroundStyle(UM.inspectorNoteInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: m.unit * 6)
                Text(text)
                    .font(.system(size: m.labelSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(UM.inspectorValueInk)
                    .lineLimit(1)
            }
            WeightsRampSlider(value: value, range: range, knob: m.knob, track: m.track)
        }
    }

    // MARK: - Overlay

    private func overlayToggle(_ m: InspectorMetrics) -> some View {
        // The mock lays this out on a two-column grid with a single occupant,
        // so the button is half the row wide and the other half is empty.
        HStack(spacing: m.gap) {
            overlayButton(m)
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
        }
    }

    private func overlayButton(_ m: InspectorMetrics) -> some View {
        Button {
            sceneManager.showWeightOverlay.toggle()
        } label: {
            HStack(spacing: m.unit * 8) {
                ZStack {
                    Circle()
                        .fill(UM.inspectorCheckFill)
                        .overlay(Circle().stroke(UM.inspectorCheckBorder, lineWidth: 1))
                    Image(systemName: "checkmark")
                        .font(.system(size: m.check * 0.62, weight: .heavy))
                        .foregroundStyle(UM.inspectorCheckMark)
                }
                .frame(width: m.check, height: m.check)
                .opacity(sceneManager.showWeightOverlay ? 1 : 0.28)

                Text("Overlay")
                    .font(.system(size: m.labelSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(UM.inspectorLabelInk)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            // No pill behind it: the drawing puts the ring and the word
            // straight on the card.
            .padding(.horizontal, m.unit * 9)
            .frame(maxWidth: .infinity)
            .frame(height: m.unit * 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - The selected node

    /// The influences on the node the artist has picked, as numbers.
    ///
    /// The brush is the fast way to say "more here, less there" and a poor way
    /// to say "this vertex is 30% forearm". Both belong in a rigging tool, and
    /// only one of them was here: the panel offered five ways to shape a stroke
    /// and no way to state a value. This is the other half — pick a node with
    /// no colour chosen and its weights are listed, each editable, each showing
    /// which bone it belongs to in that bone's own colour.
    ///
    /// Only ever ONE node. A multi-selection has no single set of weights to
    /// show, and picking one at random to stand for the rest is how an editor
    /// starts lying about what it is editing.
    @ViewBuilder
    private func selectedVertexWeights(_ m: InspectorMetrics) -> some View {
        let selected = sceneManager.selectedMeshVertexIndices
        if selected.count == 1, let vertexIndex = selected.first,
           image.mesh.vertexBoneWeights.indices.contains(vertexIndex) {
            let ordered = orderedInfluences(vertexIndex)
            VStack(alignment: .leading, spacing: m.rowGap) {
                divider.padding(.top, m.sectionGap)

                HStack {
                    Text("Node \(vertexIndex)")
                        .font(.system(size: m.buttonSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(UM.inspectorLabelInk)
                        .lineLimit(1)
                    Spacer()
                    Text(ordered.isEmpty ? "unpainted" : "\(ordered.count) bones")
                        .font(.system(size: m.buttonSize, weight: .medium, design: .rounded))
                        .foregroundStyle(UM.inspectorFooterInk)
                        .lineLimit(1)
                }

                if ordered.isEmpty {
                    Text("Nothing drives this node yet. Paint it, or Auto-Weight the sprite.")
                        .font(.system(size: m.buttonSize, weight: .medium, design: .rounded))
                        .foregroundStyle(UM.inspectorNoteInk)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(ordered, id: \.boneID) { influence in
                        vertexWeightRow(influence, vertexIndex: vertexIndex, m: m)
                    }
                }
            }
        }
    }

    /// One node's influences, in the RIG's order.
    ///
    /// Not the stored order. `sanitizedSkinningData` sorts
    /// `vertexBoneWeights` by descending weight on every write, so listing the
    /// array directly meant dragging one slider past another swapped the two
    /// rows under the cursor — and the rest of that drag went to the other
    /// bone. A row has to stay where the artist put their cursor.
    ///
    /// Hierarchical order, the same order the Bound bones list below uses, so
    /// a node's sliders and the sprite's bones read down the panel alike. It
    /// is built by walking the rig and picking, rather than by sorting on a
    /// rank: Swift's sort is not stable, and every bone missing from the rig
    /// would tie with every other.
    private func orderedInfluences(_ vertexIndex: Int) -> [VertexBoneWeight] {
        let stored = image.mesh.vertexBoneWeights[vertexIndex]
        guard stored.count > 1 else { return stored }
        var rows: [VertexBoneWeight] = []
        var placed: Set<UUID> = []
        for entry in IKBuilderRules.hierarchicalOrder(skeleton: sceneManager.skeleton) {
            if let found = stored.first(where: { $0.boneID == entry.bone.id }) {
                rows.append(found)
                placed.insert(found.boneID)
            }
        }
        // A weight on a bone the rig no longer has still gets a row: hiding it
        // is how a node ends up driven by something with no way to see it.
        rows.append(contentsOf: stored.filter { !placed.contains($0.boneID) })
        return rows
    }

    private func vertexWeightRow(_ influence: VertexBoneWeight,
                                 vertexIndex: Int,
                                 m: InspectorMetrics) -> some View {
        let bone = sceneManager.skeleton.bones[influence.boneID]
        let colour = bone?.color ?? UM.unboundBone
        return VStack(alignment: .leading, spacing: m.unit * 4) {
            HStack(spacing: m.unit * 8) {
                BoneGlyph(boneColor: bone?.color)
                    .frame(width: m.boneDot, height: m.boneDot)
                Text(bone?.name ?? "Missing bone")
                    .font(.system(size: m.labelSize, weight: .medium, design: .rounded))
                    .foregroundStyle(UM.inspectorLabelInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: m.unit * 6)
                Text("\(Int((influence.weight * 100).rounded()))%")
                    .font(.system(size: m.labelSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(UM.inspectorValueInk)
                    .lineLimit(1)
            }
            WeightsRampSlider(
                value: Binding(
                    get: { Double(influence.weight) },
                    set: { newValue in
                        setVertexWeight(vertexIndex: vertexIndex,
                                        boneID: influence.boneID,
                                        to: Float(newValue))
                    }
                ),
                range: 0...1,
                knob: m.knob,
                track: m.track,
                start: Color(red: Double(colour.x), green: Double(colour.y), blue: Double(colour.z)),
                end: Color(red: Double(colour.x), green: Double(colour.y), blue: Double(colour.z))
            )
        }
    }

    /// Writes one influence and lets the model renormalise the rest.
    ///
    /// The other bones on the node are NOT rescaled here. `setVertexWeights`
    /// ends in `sanitizedSkinningData`, which normalises the row — doing it in
    /// both places is how a value ends up applied twice and the slider stops
    /// agreeing with the number beside it.
    private func setVertexWeight(vertexIndex: Int, boneID: UUID, to weight: Float) {
        guard image.mesh.vertexBoneWeights.indices.contains(vertexIndex) else { return }
        var influences = image.mesh.vertexBoneWeights[vertexIndex]
        if let at = influences.firstIndex(where: { $0.boneID == boneID }) {
            influences[at] = VertexBoneWeight(boneID: boneID, weight: max(0, min(1, weight)))
        } else {
            influences.append(VertexBoneWeight(boneID: boneID, weight: max(0, min(1, weight))))
        }
        sceneManager.setVertexWeights(
            imageID: image.id,
            vertexIndex: vertexIndex,
            influences: influences,
            maxInfluences: sceneManager.meshWeightMaxInfluencesPerVertex)
    }

    // MARK: - Bound bones

    private func boundBones(_ m: InspectorMetrics) -> some View {
        let bound = sceneManager.boundBoneIDs(imageID: image.id)
        let bones = IKBuilderRules.hierarchicalOrder(skeleton: sceneManager.skeleton)
            .map(\.bone)
            .filter { bound.contains($0.id) }

        return VStack(alignment: .leading, spacing: m.rowGap) {
            divider.padding(.top, m.sectionGap)

            HStack {
                Text("Bound bones")
                    .font(.system(size: m.buttonSize, weight: .medium, design: .rounded))
                    .foregroundStyle(UM.inspectorFooterInk)
                    .lineLimit(1)
                Spacer()
                Text("\(bones.count)")
                    .font(.system(size: m.buttonSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(UM.inspectorValueInk)
            }

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: m.unit * 3) {
                        ForEach(bones, id: \.id) { bone in
                            boneRow(bone, m: m)
                        }
                    }
                    .padding(m.unit * 8)
                }

                HStack {
                    Button {
                        guard let boneID = sceneManager.activeWeightPaintBoneID else { return }
                        sceneManager.unbindBoneFromImage(
                            imageID: image.id, boneID: boneID,
                            maxInfluences: sceneManager.meshWeightMaxInfluencesPerVertex)
                        sceneManager.activeWeightPaintBoneID = nil
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: m.buttonSize, weight: .semibold))
                            .foregroundStyle(UM.weightsTrashInk)
                            .frame(width: m.unit * 35, height: m.unit * 30)
                            .background(
                                RoundedRectangle(cornerRadius: m.unit * 11, style: .continuous)
                                    .fill(UM.weightsTrashFill)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(sceneManager.activeWeightPaintBoneID == nil)
                    .opacity(sceneManager.activeWeightPaintBoneID == nil ? 0.45 : 1)
                    .help("Unbind the selected bone from this sprite")

                    // Mirror has no place of its own in the mock, and it was
                    // the only way to reach `mirrorMeshWeights` — dropping it
                    // with the old markup would have made a working operation
                    // unreachable. It goes in the strip the mock leaves empty
                    // beside the bin, so the composition is unchanged.
                    Button {
                        let mirrored = sceneManager.mirrorMeshWeights(imageID: image.id)
                        mirrorResult = mirrored > 0
                            ? "Mirrored \(mirrored)"
                            : "No match in range"
                    } label: {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: m.buttonSize, weight: .semibold))
                            .foregroundStyle(UM.weightsTrashInk)
                            .frame(width: m.unit * 35, height: m.unit * 30)
                            .background(
                                RoundedRectangle(cornerRadius: m.unit * 11, style: .continuous)
                                    .fill(UM.weightsTrashFill)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Mirror the painted weights across X")

                    if let mirrorResult {
                        Text(mirrorResult)
                            .font(.system(size: m.buttonSize * 0.9, weight: .medium, design: .rounded))
                            .foregroundStyle(UM.inspectorFooterInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }

                    Spacer(minLength: 0)
                }
                .padding(m.unit * 8)
            }
            .frame(height: m.listHeight)
            .background(
                RoundedRectangle(cornerRadius: m.corner, style: .continuous)
                    .fill(UM.weightsListFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: m.corner, style: .continuous)
                            .stroke(UM.inspectorCardBorder, lineWidth: 1)
                    )
            )
        }
    }

    private func boneRow(_ bone: Bone, m: InspectorMetrics) -> some View {
        let isActive = sceneManager.activeWeightPaintBoneID == bone.id
        return Button {
            sceneManager.activeWeightPaintBoneID = isActive ? nil : bone.id
        } label: {
            HStack(spacing: m.unit * 10) {
                // The hierarchy's bone, in the colour the binding gave it —
                // the same glyph in both places, so a bone is recognisable
                // across the two panels instead of being a dot in one of them.
                BoneGlyph(boneColor: bone.color)
                    .frame(width: m.boneDot, height: m.boneDot)
                Text(bone.name)
                    .font(.system(size: m.labelSize * 1.18, weight: .medium, design: .rounded))
                    .foregroundStyle(UM.weightsBoneInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, m.unit * 8)
            .frame(height: m.unit * 23)
            .background(
                RoundedRectangle(cornerRadius: m.unit * 8, style: .continuous)
                    .fill(isActive ? UM.weightsRowHighlight : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The drawing's slider: a periwinkle-to-slate fill on a light lavender track,
/// with a pale knob.
///
/// It no longer borrows the Mesh panel's ramp. The two panels were drawn with
/// different ones — Mesh runs violet to magenta, this one runs periwinkle to
/// slate and DARKENS to the right, so the knob always sits on the deep end
/// rather than the pale one. Sharing a constant between two drawings that
/// disagree is not consistency, it is one of them being wrong.
private struct WeightsRampSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let knob: CGFloat
    let track: CGFloat
    /// The brush sliders use the panel's ramp; a per-bone weight row uses that
    /// bone's own colour, so the number and the node on the canvas match.
    var start: Color = UM.inspectorRampStart
    var end: Color = UM.inspectorRampEnd

    var body: some View {
        GeometryReader { geometry in
            let span = max(range.upperBound - range.lowerBound, 0.000001)
            let fraction = min(max((value - range.lowerBound) / span, 0), 1)
            let travel = max(geometry.size.width - knob, 1)
            let x = travel * fraction

            ZStack(alignment: .leading) {
                Capsule().fill(UM.inspectorSliderTrack).frame(height: track)

                Capsule()
                    .fill(LinearGradient(colors: [start, end],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: x + knob / 2, height: track)

                Circle()
                    .fill(UM.inspectorKnobFill)
                    .overlay(Circle().stroke(UM.inspectorCardBorder, lineWidth: 1))
                    .shadow(color: UM.inspectorLabelInk.opacity(0.22), radius: 2, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: x)
            }
            .frame(height: knob)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let position = min(max(drag.location.x - knob / 2, 0), travel)
                        value = range.lowerBound + (position / travel) * span
                    }
            )
        }
        .frame(height: knob)
    }
}
