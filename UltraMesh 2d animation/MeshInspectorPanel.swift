import SwiftUI

/// The Mesh panel, built to the approved mock.
///
/// Sized by `InspectorMetrics`, the same measurements the Weights panel is drawn
/// to. The two drawings are the same render at the same size, so the two panels
/// have to come out the same size on screen — and they did not, because each
/// carried its own copy of the numbers over a different content width.
///
/// Colours come from `UM`, and from the SHARED half of it: this drawing and the
/// Weights one are the same family — the same card, segmented control, slider
/// ramp and tick — so those tones are named `inspector*` and both panels read
/// them. Only Auto-Mesh's lavender is this panel's alone.
struct MeshInspectorPanel: View {
    @ObservedObject var sceneManager: SceneManager
    @ObservedObject var toolManager: ToolManager
    let image: SceneImage
    let assetSize: SIMD2<Float>?
    let assetURL: URL?
    /// Supplied by the inspector, which owns the alpha decoding.
    let alphaSampler: () -> ((Int, Int) -> Float)?

    /// The width the panel was actually given, read back from its own layout.
    ///
    /// Measured in a background rather than by wrapping the card in a
    /// GeometryReader: a GeometryReader has no intrinsic height, so wrapping
    /// would force the panel to state its own height and feed that back into
    /// its layout. This lays out naturally and reads the resulting width.
    /// The inspector column is 220-320pt, so the first pass at the default is
    /// close and settles in one step.
    @State private var panelWidth: CGFloat = InspectorMetrics.defaultWidth

    /// An edge is half drawn on the canvas.
    ///
    /// While it is, this panel stands down: its buttons are the ones that
    /// would change the mode, the tool or the mesh out from under a stroke the
    /// artist is in the middle of, and a half-drawn edge has no home to go back
    /// to once its mode has changed. The canvas prompt is the only control that
    /// answers — Finish keeps it, Cancel drops it — which is the point of
    /// putting the way out in the same place as the mode.
    ///
    /// Read from the PREVIEW the renderer draws, which is set and cleared in
    /// the same breath as the tool's own state, so the two cannot disagree.
    private var isDrawingEdge: Bool {
        sceneManager.isMeshEditEnabled
            && sceneManager.meshEditToolMode == .create
            && sceneManager.meshCreateEdgePreviewStart != nil
    }

    var body: some View {
        card(InspectorMetrics(width: panelWidth))
            // Dimmed as well as disabled: a control that refuses a tap without
            // looking any different reads as a broken button rather than as
            // one that is standing down on purpose.
            .opacity(isDrawingEdge ? 0.45 : 1.0)
            .disabled(isDrawingEdge)
            .animation(.easeOut(duration: 0.14), value: isDrawingEdge)
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
        VStack(alignment: .leading, spacing: m.sectionGap) {
            heading(m)

            VStack(spacing: m.rowGap) {
                segmentedControl(m)
                actionPills(m)
            }

            hairline
            sliders(m)
            hairline
            checkboxes(m)

            // The drawing puts the vertex count at the BOTTOM of the card, with
            // the empty space above it. `.infinity` resolves to the ideal height
            // when the inspector proposes none, so the panel still hugs its
            // content in a scroll view and only stretches when given room.
            Spacer(minLength: m.footerGap)

            hairline
            footer(m)
        }
        .frame(maxHeight: .infinity, alignment: .top)
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

    private func heading(_ m: InspectorMetrics) -> some View {
        HStack(spacing: m.unit * 8) {
            Text("MESH")
                .font(.system(size: m.headingSize, weight: .bold, design: .rounded))
                .tracking(m.headingSize * 0.14)
                .foregroundStyle(UM.inspectorHeadingInk)
                .lineLimit(1)
            Rectangle()
                .fill(UM.inspectorRule)
                .frame(height: 1)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(UM.inspectorRule)
            .frame(height: 1)
    }

    // MARK: - Add / Modify / Eliminate

    private func segmentedControl(_ m: InspectorMetrics) -> some View {
        HStack(spacing: 0) {
            segment("Add", mode: .create, m: m)
            segment("Modify", mode: .modify, m: m)
            segment("Eliminate", mode: .delete, m: m)
        }
        .padding(m.unit * 5)
        .background(
            Capsule(style: .continuous)
                .fill(UM.inspectorSegmentTrack)
        )
    }

    @ViewBuilder
    private func segment(_ title: String, mode: MeshEditToolMode, m: InspectorMetrics) -> some View {
        let isActive = sceneManager.meshEditToolMode == mode
        Button {
            sceneManager.selectMeshLayer(for: image.id)
            toolManager.setTool(.mesh)
            sceneManager.meshEditToolMode = mode
        } label: {
            Text(title)
                .font(.system(size: m.segmentSize, weight: isActive ? .bold : .medium, design: .rounded))
                .foregroundStyle(isActive ? UM.inspectorSegmentActiveInk : UM.inspectorSegmentInk)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .frame(height: m.segmentHeight - m.unit * 10)
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
                pill("Auto-Mesh", m: m, fill: UM.meshAutoFill) {
                    guard let assetSize, let sampler = alphaSampler() else { return }
                    sceneManager.selectMeshLayer(for: image.id)
                    sceneManager.traceSelectedMesh(assetSize: assetSize, alphaSampler: sampler)
                }
                pill(sceneManager.isMeshCreatingHull ? "Finish" : "New Edge", m: m) {
                    sceneManager.selectMeshLayer(for: image.id)
                    toolManager.setTool(.mesh)
                    if sceneManager.isMeshCreatingHull {
                        sceneManager.finishNewMesh()
                    } else {
                        sceneManager.beginNewMesh()
                    }
                }
            }
            HStack(spacing: m.gap) {
                pill("Generate", m: m, fill: UM.inspectorPillAltFill) {
                    guard let assetSize else { return }
                    sceneManager.selectMeshLayer(for: image.id)
                    sceneManager.generateSelectedMesh(assetSize: assetSize)
                }
                pill("Reset", m: m, ink: UM.inspectorResetInk) {
                    guard let assetSize else { return }
                    sceneManager.selectMeshLayer(for: image.id)
                    sceneManager.resetSelectedMesh(assetSize: assetSize)
                }
            }
        }
    }

    private func pill(_ title: String,
                      m: InspectorMetrics,
                      fill: Color = UM.inspectorPillFill,
                      ink: Color = UM.inspectorPillInk,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: m.buttonSize, weight: .bold, design: .rounded))
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: m.pillHeight)
                .background(Capsule(style: .continuous).fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sliders

    private func sliders(_ m: InspectorMetrics) -> some View {
        VStack(alignment: .leading, spacing: m.rowGap) {
            ramp("Detail", m: m, value: Binding(
                get: { Double(sceneManager.meshAutoDetail) },
                set: { sceneManager.meshAutoDetail = Float($0) }
            ), range: 10...100, text: "\(Int(sceneManager.meshAutoDetail.rounded()))")

            ramp("Concavity", m: m, value: Binding(
                get: { Double(sceneManager.meshAutoConcavity) },
                set: { sceneManager.meshAutoConcavity = Float($0) }
            ), range: 0...100, text: "\(Int(sceneManager.meshAutoConcavity.rounded()))")

            ramp("Padding", m: m, value: Binding(
                get: { Double(sceneManager.meshAutoPadding) },
                set: { sceneManager.meshAutoPadding = Float($0) }
            ), range: 0...4, text: String(format: "%.1f", sceneManager.meshAutoPadding))

            // Set apart, and last: Detail, Concavity and Padding shape the
            // OUTLINE; this one fills what is inside it.
            ramp("Generate", m: m, value: Binding(
                get: { Double(sceneManager.meshGenerateDensity) },
                set: { sceneManager.meshGenerateDensity = Float($0) }
            ), range: 0...100,
               text: "\(Int(sceneManager.meshGenerateDensity.rounded()))",
               note: "Interior density")
            .padding(.top, m.unit * 14)
        }
    }

    @ViewBuilder
    private func ramp(_ title: String,
                      m: InspectorMetrics,
                      value: Binding<Double>,
                      range: ClosedRange<Double>,
                      text: String,
                      note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: m.unit * 4) {
            HStack(spacing: m.unit * 8) {
                Text(title)
                    .font(.system(size: m.labelSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(UM.inspectorLabelInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(.system(size: m.labelSize * 0.92, weight: .medium, design: .rounded))
                        .foregroundStyle(UM.inspectorNoteInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: m.unit * 8)
                Text(text)
                    .font(.system(size: m.labelSize, weight: .bold, design: .rounded))
                    .foregroundStyle(UM.inspectorValueInk)
                    .lineLimit(1)
            }
            MeshRampSlider(value: value, range: range, knob: m.knob, track: m.track)
        }
    }

    // MARK: - Checkboxes

    private func checkboxes(_ m: InspectorMetrics) -> some View {
        VStack(spacing: m.checkRowGap) {
            HStack(spacing: m.checkGap) {
                checkbox("Triangles", m: m, isOn: Binding(
                    get: { sceneManager.meshShowTriangles },
                    set: { sceneManager.meshShowTriangles = $0 }
                ))
                checkbox("Dim image", m: m, isOn: Binding(
                    get: { sceneManager.meshDimImage },
                    set: { sceneManager.meshDimImage = $0 }
                ))
            }
            HStack(spacing: m.checkGap) {
                checkbox("Isolate", m: m, isOn: Binding(
                    get: { sceneManager.meshIsolateSelection },
                    set: { sceneManager.meshIsolateSelection = $0 }
                ))
                checkbox("Show deformed", m: m, isOn: Binding(
                    get: { sceneManager.meshShowDeformed },
                    set: { sceneManager.meshShowDeformed = $0 }
                ))
            }
        }
    }

    private func checkbox(_ title: String, m: InspectorMetrics, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: m.checkGap) {
                // A ring in both states, as drawn — the tick appears inside
                // it rather than the ring changing into a filled disc.
                ZStack {
                    Circle()
                        .fill(isOn.wrappedValue ? UM.inspectorCheckFill : Color.clear)
                        .overlay(Circle().stroke(UM.inspectorCheckBorder, lineWidth: 1.5))
                    if isOn.wrappedValue {
                        Image(systemName: "checkmark")
                            .font(.system(size: m.check * 0.46, weight: .bold))
                            .foregroundStyle(UM.inspectorCheckMark)
                    }
                }
                .frame(width: m.check, height: m.check)

                // "Show deformed" is the longest of the four and was being
                // truncated to "Show defor...". It has to be READ, so it
                // shrinks as far as it needs to; `fixedSize` keeps it on one
                // line while it does.
                Text(title)
                    .font(.system(size: m.labelSize, weight: .medium, design: .rounded))
                    .foregroundStyle(UM.inspectorLabelInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private func footer(_ m: InspectorMetrics) -> some View {
        HStack {
            Text("Vertices")
                .font(.system(size: m.labelSize, weight: .medium, design: .rounded))
                .foregroundStyle(UM.inspectorFooterInk)
                .lineLimit(1)
            Spacer()
            Text("\(image.mesh.vertices.count)")
                .font(.system(size: m.labelSize, weight: .bold, design: .rounded))
                .foregroundStyle(UM.inspectorValueInk)
                .lineLimit(1)
        }
    }
}

/// The drawing's slider: a periwinkle-to-slate fill on a light lavender track.
///
/// The same one the Weights panel draws — the two drawings agree here, so they
/// read one ramp rather than two constants that can drift apart.
private struct MeshRampSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let knob: CGFloat
    let track: CGFloat

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let span = max(range.upperBound - range.lowerBound, 0.000001)
            let fraction = min(max((value - range.lowerBound) / span, 0), 1)
            let travel = max(geometry.size.width - knob, 1)
            let x = travel * fraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(UM.inspectorSliderTrack)
                    .frame(height: track)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [UM.inspectorRampStart, UM.inspectorRampEnd],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: x + knob / 2, height: track)

                Circle()
                    .fill(UM.inspectorKnobFill)
                    .overlay(Circle().stroke(UM.inspectorCardBorder, lineWidth: 1))
                    .shadow(color: UM.inspectorLabelInk.opacity(isDragging ? 0.30 : 0.18),
                            radius: 2, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: x)
            }
            .frame(height: knob)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let position = min(max(drag.location.x - knob / 2, 0), travel)
                        value = range.lowerBound + (position / travel) * span
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: knob)
    }
}
