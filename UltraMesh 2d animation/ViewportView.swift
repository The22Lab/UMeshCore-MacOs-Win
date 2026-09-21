import SwiftUI
import MetalKit
import QuartzCore

struct ViewportView: View {
    let assetManager: AssetManager
    @ObservedObject var sceneManager: SceneManager
    @ObservedObject var toolManager: ToolManager
    let camera: CameraState
    @ObservedObject var skewGizmoState: SkewGizmoState
    @ObservedObject var rotationGizmoState: RotationGizmoState
    /// Passed in rather than read from AppState here: this view is deliberately
    /// free of the app-level environment object so it can be previewed and
    /// driven from tests with nothing but managers. Nil in previews, where
    /// there is no app state to switch.
    var editorMode: Binding<EditorMode>? = nil

    /// Shared by key with the button in `CanvasOverlayControls`: `@AppStorage`
    /// views on the same key stay in sync through `UserDefaults`, so neither
    /// side has to own the other. A device preference, not a project property —
    /// it describes the iPad and the Pencil, not the rig.
    @AppStorage("umFingerNavigationOnly") private var fingerNavigationOnly = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ViewportMetalView(
                    assetManager: assetManager,
                    sceneManager: sceneManager,
                    toolManager: toolManager,
                    camera: camera,
                    fingerNavigationOnly: fingerNavigationOnly
                )

                TransformConstraintGizmoView(
                    sceneManager: sceneManager,
                    camera: camera,
                    viewSize: proxy.size
                )

                if let badge = rotationGizmoState.angleBadge {
                    RotationAngleBadge(badge: badge)
                        .position(x: badge.position.x + 24, y: badge.position.y - 20)
                        .transition(.opacity.combined(with: .scale(0.88)))
                        .animation(.easeOut(duration: 0.08), value: badge.degrees)
                        .allowsHitTesting(false)
                }

                // Shear publishes an angle badge on every drag and nothing ever
                // drew it, so rotating told you the angle and shearing did not.
                // `SkewAngleBadge` positions itself from the badge, unlike the
                // rotation one, so it takes no `.position` here.
                if let badge = skewGizmoState.angleBadge {
                    SkewAngleBadge(badge: badge, viewSize: proxy.size)
                        .allowsHitTesting(false)
                }

                // One stack, so the bone button sits directly above the
                // coordinate panel and the two travel together when the canvas
                // resizes.
                VStack(alignment: .leading, spacing: 8) {
                    CanvasModeButtonRow(
                        sceneManager: sceneManager,
                        toolManager: toolManager,
                        isSkeletonMode: editorMode?.wrappedValue == .skeleton
                    )

                    CoordinatePanel(
                    image: Binding(
                        get: {
                            guard let selectedID = sceneManager.selectedImageID else { return nil }
                            return sceneManager.image(for: selectedID)
                        },
                        set: { updatedImage in
                            guard let updatedImage else { return }
                            sceneManager.setImagePosition(id: updatedImage.id, position: updatedImage.position)
                            sceneManager.setImageScale(id: updatedImage.id, scale: updatedImage.scale)
                            sceneManager.setImageRotation(id: updatedImage.id, rotation: updatedImage.rotation)
                            sceneManager.setImageSkew(id: updatedImage.id, skew: updatedImage.skew)
                        }
                    ),
                    activeTool: toolManager.currentTool,
                    onSelectTool: { tool in
                        toolManager.setTool(tool)
                    }
                )

                    // The three automatic actions, right after the coordinate
                    // panel and in its own shell, so the stack reads as one
                    // thing that travels together.
                    CanvasAutoActionsRow(
                        assetManager: assetManager,
                        sceneManager: sceneManager,
                        alphaSampler: { url in makeAlphaSampler(for: url) }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 12)
                .padding(.bottom, 12)

                if let quickTool = toolManager.quickSwitchTool {
                    QuickToolSwitchOverlay(selectedTool: quickTool)
                        .position(quickSwitchOverlayPosition(in: proxy.size))
                        .allowsHitTesting(false)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.9)),
                            removal: .opacity
                        ))
                        .animation(.easeOut(duration: 0.1), value: quickTool)
                }

                // Top-leading: the bone visibility toggle, clear of the mode
                // row and the coordinate panel at the bottom. Making bones is
                // not here any more — it is one chip of CanvasModeButtonRow,
                // beside Pose, Mesh and Weights.
                if let editorMode {
                    CanvasOverlayControls(mode: editorMode, sceneManager: sceneManager)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 12)
                    .padding(.leading, 12)
                }

                if let notice = sceneManager.meshEditNotice {
                    MeshEditNoticeView(notice: notice) {
                        sceneManager.meshEditNotice = nil
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    // Long enough to read a two-line sentence, short enough not
                    // to sit over the canvas while the artist works around it.
                    .task(id: notice) {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        guard !Task.isCancelled else { return }
                        if sceneManager.meshEditNotice == notice {
                            sceneManager.meshEditNotice = nil
                        }
                    }
                }

                // Top-trailing so neither covers the coordinate panel at the
                // bottom-left, and both float over the canvas the artist is
                // clicking. ONE stack rather than two overlays: the escape
                // control and the IK panel are the two things that live in this
                // corner, and stacking them is what stops them landing on top
                // of each other when both are up.
                VStack(alignment: .trailing, spacing: 10) {
                    if let scope = escapeScope {
                        CanvasEscapeButton(scope: scope) {
                            // ONE RUNG. The tool is the only rung this object
                            // does not own, so it is handled here and the rest
                            // inside the scene manager — which is also where
                            // the ladder's order is NOT decided, so the two
                            // cannot disagree about it.
                            if sceneManager.exitDeepestScope(
                                hasNonDefaultTool: toolManager.currentTool != .select
                            ) == .activeTool {
                                toolManager.setTool(.select)
                            }
                        }
                        .transition(.opacity.combined(with: .scale(0.92, anchor: .topTrailing)))
                    }

                    if sceneManager.ikBuilder != nil {
                        IKBuilderPanelView(sceneManager: sceneManager)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 12)
                .padding(.trailing, 12)
                .animation(.easeOut(duration: 0.16), value: escapeScope)

                // BOTTOM CENTRE. The coordinate readout owns the bottom-left,
                // the escape control and the IK builder the top-right, the mode
                // chips the top-left. This is the one free edge, and it is
                // where the eye goes when a mode changes what a tap does.
                if let prompt = canvasPromptMode {
                    CanvasModePrompt(
                        mode: prompt,
                        onConfirm: {
                            switch prompt {
                            case .bindBones:
                                sceneManager.isBindingBonesMode = false
                            case .newEdge:
                                // Back to Modify, keeping every edge made. The
                                // mesh edit itself stays open — Finish ends the
                                // drawing, not the session.
                                toolManager.cancelPendingMeshEdge(scene: sceneManager)
                                sceneManager.meshEditToolMode = .modify
                            }
                        },
                        onCancel: {
                            // Only New Edge offers one, and only while an edge
                            // is half drawn: it drops that edge and stays in
                            // New Edge, because the artist cancelled a stroke
                            // and not a mode.
                            toolManager.cancelPendingMeshEdge(scene: sceneManager)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeOut(duration: 0.16), value: sceneManager.meshEditNotice)
            .animation(.easeOut(duration: 0.18), value: canvasPromptMode)
        }
    }

    /// The mode the canvas is in, or nil when it is in none that need saying.
    ///
    /// Bind mode needs a selected sprite to bind TO; without one it is waiting
    /// rather than active, and announcing it would be announcing nothing.
    var canvasPromptMode: CanvasPromptMode? {
        if sceneManager.isBindingBonesMode, sceneManager.selectedImageID != nil {
            return .bindBones
        }
        if sceneManager.isMeshEditEnabled,
           sceneManager.meshEditToolMode == .create,
           toolManager.currentTool == .mesh {
            // The half-drawn edge, read from the PREVIEW the renderer already
            // draws — the tool's own `createEdgeStartVertexIndex` is private to
            // it, and the preview is set and cleared in the same breath, so the
            // two cannot disagree about whether an edge is in progress.
            return .newEdge(hasPendingEdge: sceneManager.meshCreateEdgePreviewStart != nil)
        }
        return nil
    }

    /// The rung the escape control would leave, or nil when there is nothing
    /// to leave — which is when it is not shown at all.
    private var escapeScope: EditorScope? {
        var state = sceneManager.escapeState
        state.hasNonDefaultTool = toolManager.currentTool != .select
        return EditorEscape.deepest(state)
    }

    private func quickSwitchOverlayPosition(in size: CGSize) -> CGPoint {
        let fallback = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        guard let raw = toolManager.quickSwitchCursorPosition else { return fallback }
        let radius: CGFloat = 82
        let x = min(max(raw.x, radius), size.width - radius)
        let y = min(max(raw.y, radius), size.height - radius)
        return CGPoint(x: x, y: y)
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

private struct QuickToolSwitchOverlay: View {
    let selectedTool: ActiveTool

    private let ringStroke = Color.black.opacity(0.62)
    private let wheelSize: CGFloat = 156
    private let nodeDistance: CGFloat = 52
    private let nodeSize: CGFloat = 38
    private let labelOffsetY: CGFloat = 27

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.black.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                .frame(width: wheelSize - 74, height: wheelSize - 74)

            toolNode(.rotate, title: "Rotate", systemImage: "rotate.right", tint: UM.channelRotate)
                .offset(x: 0, y: -nodeDistance)
            toolNode(.skew, title: "Skew", systemImage: "rectangle.3.offgrid", tint: UM.channelShear)
                .offset(x: nodeDistance, y: 0)
            toolNode(.move, title: "Translate", systemImage: "arrow.up.and.down.and.arrow.left.and.right", tint: UM.channelTranslate)
                .offset(x: -nodeDistance, y: 0)
            toolNode(.scale, title: "Scale", systemImage: "arrow.up.left.and.down.right.magnifyingglass", tint: UM.channelScale)
                .offset(x: 0, y: nodeDistance)
        }
    }

    private func toolNode(_ tool: ActiveTool, title: String, systemImage: String, tint: Color) -> some View {
        let isSelected = selectedTool == tool
        return ZStack {
            ZStack {
                Circle()
                    .fill(Color.clear)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? tint.opacity(1.0) : Color.black.opacity(0.5), lineWidth: isSelected ? 2.1 : 1.1)
                    )
                    .frame(width: nodeSize, height: nodeSize)
                    .shadow(color: isSelected ? tint.opacity(0.35) : .clear, radius: 8, x: 0, y: 0)
                if tool == .skew {
                    SkewToolIcon()
                        .stroke(
                            Color.white.opacity(isSelected ? 0.96 : 0.65),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: 12, height: 12)
                } else if tool == .rotate {
                    Image("rotate_icon")
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 23, height: 23)
                        .opacity(isSelected ? 1.0 : 0.72)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(isSelected ? 0.96 : 0.65))
                }
            }

            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isSelected ? 0.78 : 0.54))
                .offset(y: labelOffsetY)
        }
        .frame(width: 72, height: 72, alignment: .center)
    }
}

private struct CoordinatePanel: View {
    @Binding var image: SceneImage?
    let activeTool: ActiveTool
    let onSelectTool: (ActiveTool) -> Void
    // 1.0: the base width now carries the size, so the stored scale is a
    // preference on top of it rather than part of the design.
    @AppStorage("umCoordPanelScale") private var panelScale: Double = 1.0

    /// Every dimension is the approved panel's own measurement over its content
    /// width, so the composition holds at whatever width the panel is drawn at.
    /// The panel floats — nothing constrains it — so it names a base width and
    /// the stored scale is the only thing that changes it.
    struct Metrics {
        /// The drawing is 1185 x 662, with 56px of padding each side, so 1073
        /// of that width is content.
        static let mockContent: CGFloat = 1073
        static let baseWidth: CGFloat = 250

        let width: CGFloat
        var padding: CGFloat { width * 56 / 1185 }
        var verticalPadding: CGFloat { unit * 58 }
        var unit: CGFloat { max(width - 2 * padding, 1) / Self.mockContent }

        var corner: CGFloat { unit * 40 }
        var fieldCorner: CGFloat { unit * 24 }
        var fieldHeight: CGFloat { unit * 98 }
        var rowGap: CGFloat { unit * 51 }
        var labelColumn: CGFloat { unit * 320 }
        var columnGap: CGFloat { unit * 90 }
        var fieldGap: CGFloat { unit * 40 }
        var icon: CGFloat { unit * 48 }
        var iconGap: CGFloat { unit * 45 }
        var labelSize: CGFloat { unit * 46 }
        var letterSize: CGFloat { unit * 40 }
        var valueSize: CGFloat { unit * 44 }
    }

    /// The stored scale goes into the WIDTH, not into a `scaleEffect`.
    ///
    /// That is what was covering the mode pill. `scaleEffect` is a drawing
    /// transform: the VStack above laid the panel out at its unscaled height
    /// and then it was drawn 20% larger about its bottom-left corner, so it
    /// grew upwards into the row it was supposed to sit under. Scaling the
    /// width instead means every dimension still derives from it, and the frame
    /// the layout reserves is the size the panel actually is.
    private var metrics: Metrics {
        Metrics(width: Metrics.baseWidth * max(CGFloat(panelScale), 0.5))
    }

    var body: some View {
        let m = metrics
        VStack(alignment: .leading, spacing: m.rowGap) {
            coordinateRow(
                title: "Translate",
                m: m,
                property: .translate,
                isActive: activeTool == .move,
                tool: .move,
                x: binding(
                    get: { Double($0.position.x) },
                    set: { $0.position.x = Float($1) }
                ),
                y: binding(
                    get: { Double($0.position.y) },
                    set: { $0.position.y = Float($1) }
                )
            )

            coordinateRow(
                title: "Scale",
                m: m,
                property: .scale,
                isActive: activeTool == .scale,
                tool: .scale,
                x: binding(
                    get: { Double($0.scale.x) },
                    set: { $0.scale.x = Float(max($1, 0.01)) }
                ),
                y: binding(
                    get: { Double($0.scale.y) },
                    set: { $0.scale.y = Float(max($1, 0.01)) }
                )
            )

            coordinateRow(
                title: "Rotate",
                m: m,
                property: .rotate,
                isActive: activeTool == .rotate,
                tool: .rotate,
                x: binding(
                    get: { Double($0.rotation * 180 / .pi) },
                    set: { $0.rotation = Float($1) * .pi / 180 }
                ),
                y: .constant(0),
                yLabel: "A",
                xLabel: "Z"
            )

            coordinateRow(
                title: "Shear",
                m: m,
                property: .shear,
                isActive: activeTool == .skew,
                tool: .skew,
                x: binding(
                    get: { Double($0.skew.x) },
                    set: { $0.skew.x = Float($1) }
                ),
                y: binding(
                    get: { Double($0.skew.y) },
                    set: { $0.skew.y = Float($1) }
                )
            )
        }
        .padding(.horizontal, m.padding)
        .padding(.vertical, m.verticalPadding)
        .frame(width: m.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: m.corner, style: .continuous)
                .fill(UM.coordPanelFill)
                .overlay(
                    RoundedRectangle(cornerRadius: m.corner, style: .continuous)
                        .stroke(UM.coordPanelBorder, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 6)
    }

    private func coordinateRow(
        title: String,
        m: Metrics,
        property: AnimationTrackProperty,
        isActive: Bool,
        tool: ActiveTool,
        x: Binding<Double>,
        y: Binding<Double>,
        yLabel: String = "Y",
        xLabel: String = "X"
    ) -> some View {
        // Icon and label share the row's ink: neutral while the tool is not in
        // hand, the channel's colour while it is. The icons used to be drawn in
        // their accent whatever the state, so all four rows looked lit and the
        // one that actually was looked no different.
        let ink = isActive ? UM.coordAccent(for: property) : UM.coordLabelInk

        return HStack(spacing: m.columnGap) {
            HStack(spacing: m.iconGap) {
                // One box for every glyph, so a wider icon cannot push its own
                // label right and leave that row out of line with the others.
                rowIcon(tool: tool, ink: ink, m: m)
                    .frame(width: m.icon, height: m.icon)

                Text(title)
                    .font(.system(size: m.labelSize, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 0)
            }
            .frame(width: m.labelColumn, alignment: .leading)

            HStack(spacing: m.fieldGap) {
                CoordinateValueField(label: xLabel, value: x, m: m)
                CoordinateValueField(label: yLabel, value: y, m: m)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectTool(tool)
        }
    }

    @ViewBuilder
    private func rowIcon(tool: ActiveTool, ink: Color, m: Metrics) -> some View {
        switch tool {
        case .skew:
            SkewToolIcon()
                .stroke(ink, style: StrokeStyle(lineWidth: max(m.unit * 7, 1),
                                                lineCap: .round, lineJoin: .round))
        case .rotate:
            // Template, not original: the drawing shows this glyph taking the
            // row's colour like the other three, and an `.original` bitmap
            // cannot be tinted, so it stayed amber on every row.
            Image("rotate_icon")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(ink)
        case .scale:
            Image(systemName: "arrow.down.left")
                .font(.system(size: m.icon * 0.82, weight: .bold))
                .foregroundStyle(ink)
        default:
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: m.icon * 0.78, weight: .bold))
                .foregroundStyle(ink)
        }
    }

    private func binding(
        get: @escaping (SceneImage) -> Double,
        set: @escaping (inout SceneImage, Double) -> Void
    ) -> Binding<Double> {
        Binding<Double>(
            get: { image.map(get) ?? 0 },
            set: { newValue in
                guard var current = image else { return }
                set(&current, newValue)
                image = current
            }
        )
    }
}

/// Shear, as a leaning square.
///
/// It used to be two corner brackets, which is the "crop" glyph — it says
/// nothing about slanting. A parallelogram is the shape the tool makes, and it
/// is what the approved panel draws. One shape, used by the row and by the
/// canvas gizmo, so the tool looks like itself in both places.
private struct SkewToolIcon: Shape {
    /// How far the top edge leans, as a fraction of the width.
    var lean: CGFloat = 0.26

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset = min(rect.width, rect.height) * 0.06
        let left = rect.minX + inset
        let right = rect.maxX - inset
        let top = rect.minY + inset
        let bottom = rect.maxY - inset
        let slant = (right - left) * lean

        path.move(to: CGPoint(x: left + slant, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right - slant, y: bottom))
        path.addLine(to: CGPoint(x: left, y: bottom))
        path.closeSubpath()
        return path
    }
}

private struct CoordinateValueField: View {
    let label: String
    @Binding var value: Double
    let m: CoordinatePanel.Metrics

    var body: some View {
        HStack(spacing: m.unit * 22) {
            Text(label)
                .font(.system(size: m.letterSize, weight: .bold, design: .rounded))
                .foregroundStyle(UM.coordLetterInk)
                .lineLimit(1)

            TextField("", value: $value, formatter: Self.formatter)
                .textFieldStyle(.plain)
                .font(.system(size: m.valueSize, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(UM.coordValueInk)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, m.unit * 30)
        .frame(maxWidth: .infinity)
        .frame(height: m.fieldHeight)
        .background(
            RoundedRectangle(cornerRadius: m.fieldCorner, style: .continuous)
                .fill(UM.coordFieldTint)
                .overlay(
                    RoundedRectangle(cornerRadius: m.fieldCorner, style: .continuous)
                        .stroke(UM.coordFieldBorder, lineWidth: 1)
                )
        )
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.minimumIntegerDigits = 1
        formatter.generatesDecimalNumbers = false
        return formatter
    }()
}

struct ViewportMetalView {
    let assetManager: AssetManager
    let sceneManager: SceneManager
    let toolManager: ToolManager
    let camera: CameraState
    /// iPadOS only in effect: finger navigates, Pencil does everything else.
    /// Carried down as a property so the touch view has one source for it,
    /// rather than reading `UserDefaults` from inside the input layer.
    var fingerNavigationOnly = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: MetalRenderer?
        /// Owned here because `ViewportMetalView` is a struct SwiftUI rebuilds
        /// on every layout pass, and the canvas's idle state has to outlive that.
        let activity = CanvasActivity()
    }

    // MARK: - Shared bridge (identical on macOS and iPadOS)

    /// One MTKView configuration for every platform. Any change here is a
    /// change on both platforms by construction.
    private func configure(_ view: MTKView) {
        view.device = MetalDeviceProvider.device
        view.clearColor = MTLClearColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        // Starts free-running. `CanvasActivity` is the only thing that ever
        // pauses it, and the only thing that ever un-pauses it, so there is one
        // owner of this bit rather than a flag several places race to set.
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.presentsWithTransaction = false
            metalLayer.allowsNextDrawableTimeout = false

            // THREE DRAWABLES, TWO FRAMES IN FLIGHT.
            //
            // This was two, and that decision was right for the problem it was
            // taken against: the canvas was drawing extra frames by hand from
            // every input event, and deepening the pool would have hidden that
            // rather than fixed it. The hand calls are gone, the drawable is
            // acquired last instead of first, and the depth is now its own
            // question.
            //
            // With two, one drawable is being displayed and one is being drawn
            // into. A frame that overruns its interval even slightly has
            // nowhere to go: it waits a whole refresh, and the frame after it
            // waits for that one. 8.3, 8.3, 16.6, 8.3 — a full dropped refresh
            // out of a small overrun, and the average still reads near 120.
            //
            // The third drawable absorbs that overrun. Modelled in
            // `verify_display_rate.py` against the same frame times: 23 missed
            // refreshes in 400 frames become none, and the mean time from a
            // frame starting to it being on screen falls from 110 ms to 16.7 —
            // the two-deep pool was building a backlog, not saving latency.
            //
            // `maxFramesInFlight` stays at two, and the reason is narrower
            // than it looks: `draw(in:)` is called BY the display link, so the
            // CPU is paced by the display and cannot run ahead of it whatever
            // the semaphore says. Two is what the two-deep pool allowed
            // implicitly, so nothing about run-ahead changes here. The extra
            // drawable is slack for the compositor and only that.
            metalLayer.maximumDrawableCount = 3
        }
    }

    private func attachRenderer(_ view: MTKView, coordinator: Coordinator) {
        let renderer = MetalRenderer(view: view)
        renderer.assetManager = assetManager
        renderer.sceneManager = sceneManager
        renderer.toolManager = toolManager
        renderer.camera = camera
        renderer.activity = coordinator.activity
        toolManager.camera = camera
        view.delegate = renderer
        coordinator.renderer = renderer
        coordinator.activity.attach(to: view)
        bindActivity(coordinator)
    }

    private func updateRenderer(_ coordinator: Coordinator) {
        coordinator.renderer?.assetManager = assetManager
        coordinator.renderer?.sceneManager = sceneManager
        coordinator.renderer?.toolManager = toolManager
        coordinator.renderer?.camera = camera
        coordinator.renderer?.activity = coordinator.activity
        toolManager.camera = camera
        bindActivity(coordinator)
    }

    /// Doors 2, 3 and 4 into `CanvasActivity`: the camera wakes from inside its
    /// own mutators, the three managers wake on every published write, and the
    /// two clock-driven states are asked about once a frame rather than tracked.
    private func bindActivity(_ coordinator: Coordinator) {
        // Bound through locals rather than `[weak sceneManager]` on the stored
        // properties: a capture list needs a plain identifier, and these are
        // members of a struct reached through an implicit `self`.
        let activity = coordinator.activity
        let scene = sceneManager
        let cam = camera
        cam.activity = activity
        activity.observe(scene: scene, tools: toolManager, assets: assetManager)
        activity.probes.isPlaying = { [weak scene] in scene?.isPlaying ?? false }
        activity.probes.isCameraAnimating = { [weak cam] in cam?.isAnimating ?? false }
    }

    /// Binds the shared input contract. Mouse on macOS and touch/Pencil on
    /// iPadOS both terminate in these exact same core editor commands.
    ///
    /// DOOR 1 INTO `CanvasActivity`, and the reason every closure below starts
    /// the same way. The canvas sleeps when nothing is happening, so every
    /// input has to say that something is. Most of these would be woken anyway
    /// by the published write they cause — but not all of them (`onZoom` and
    /// `onPan` move a camera nothing observes) and not reliably (a handler that
    /// changes nothing this time still means the user is here). Waking first
    /// and unconditionally makes that a property of the door rather than a fact
    /// about each command.
    ///
    /// `verify_canvas_idle.py` checks every assignment in this function and in
    /// `bindTouchExtras` for the wake, so a fourteenth callback cannot be added
    /// without one.
    private func bindShared<V: ViewportInputContract>(_ view: V, coordinator: Coordinator) {
        let activity = coordinator.activity
        view.camera = camera
        view.activity = activity
        activity.probes.isInteracting = { [weak view] in view?.isInteracting ?? false }

        view.onMouseDown = { [self] in activity.wake(); toolManager.handleMouseDown($0, scene: sceneManager, assets: assetManager) }
        view.onMouseDrag = { [self] input in
            activity.wake()
            if input.isDragging { toolManager.handleMouseDrag(input, scene: sceneManager, assets: assetManager) }
            else { toolManager.handleMouseMove(input, scene: sceneManager, assets: assetManager) }
        }
        view.onMouseUp    = { [self] in activity.wake(); toolManager.handleMouseUp($0, scene: sceneManager, assets: assetManager) }
        view.onPan        = { [self] in activity.wake(); camera.pan(screenDelta: $0) }
        view.onZoom       = { [self, weak view] delta, loc in
            activity.wake()
            camera.zoom(at: loc, viewSize: view?.bounds.size ?? .zero, scrollDelta: delta)
        }
        view.onFrameAll   = { [self] sz in
            activity.wake()
            if let sel = sceneManager.selectedImageID,
               let img = sceneManager.image(for: sel),
               let ast = assetManager.asset(for: img.assetID) {
                camera.frame(bounds: ToolUtilities.boundsForImage(img, asset: ast), viewSize: sz, padding: 80, duration: 0.25)
            } else if let b = ToolUtilities.boundsForScene(scene: sceneManager, assets: assetManager) {
                camera.frame(bounds: b, viewSize: sz, padding: 80, duration: 0.25)
            }
        }
        view.onDeselect        = { [self] in
            activity.wake()
            sceneManager.selectedImageID = nil
            // THE BONE TOO. Escape used to clear only the sprite selection, so
            // in the Bone tool it did nothing visible and — the reported part —
            // did not break the chain: the next bone still became a child of
            // whichever bone was still selected. Bone creation reads
            // `selectedBoneID` as its parent, so "cancel the chain" and "clear
            // the bone selection" are the same act, and Escape is where an
            // artist reaches for it.
            sceneManager.selectBone(nil)
        }
        view.onPointerExit     = { [self] in
            activity.wake()
            toolManager.handlePointerExit(scene: sceneManager)
        }
        view.onDelete          = { [self] in activity.wake(); if toolManager.currentTool == .mesh { sceneManager.deleteSelectedMeshVertices() } }
        view.onSelectTool      = { [self] in activity.wake(); toolManager.setTool($0) }
        view.onQuickSelectTool = { [self] in activity.wake(); toolManager.activateQuickSwitchTool($0, at: $1) }
        view.onQuickSelectEnd  = { [self] in activity.wake(); toolManager.endQuickSwitchOverlay() }
    }
}

#if os(macOS)
extension ViewportMetalView: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView {
        let view = ToolInputMTKView()
        configure(view)
        attachRenderer(view, coordinator: context.coordinator)
        bindShared(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        updateRenderer(context.coordinator)
        nsView.window?.acceptsMouseMovedEvents = true
        if let v = nsView as? ToolInputMTKView { bindShared(v, coordinator: context.coordinator) }
    }
}
#else
extension ViewportMetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = TouchInputMTKView()
        configure(view)
        attachRenderer(view, coordinator: context.coordinator)
        bindShared(view, coordinator: context.coordinator)
        bindTouchExtras(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        updateRenderer(context.coordinator)
        if let v = uiView as? TouchInputMTKView {
            bindShared(v, coordinator: context.coordinator)
            bindTouchExtras(v, coordinator: context.coordinator)
        }
    }

    /// Touch-only additions on top of the shared contract. These are pure
    /// input adapters: each one terminates in the same shared core command
    /// the Mac reaches through its own input (menu/keyboard undo, scroll
    /// zoom). No functional logic lives here.
    private func bindTouchExtras(_ view: TouchInputMTKView, coordinator: Coordinator) {
        let activity = coordinator.activity
        // Assigned every update pass; the view's `didSet` ignores a repeat and
        // closes out any finger gesture that the old rule had in flight.
        view.fingerNavigationOnly = fingerNavigationOnly
        // Pinch delivers the raw gesture scale + anchor in drawable pixels —
        // applied multiplicatively so the canvas tracks the fingers 1:1.
        view.onPinchZoom  = { [self, weak view] factor, loc in
            activity.wake()
            camera.zoomBy(scaleFactor: factor, at: loc, viewSize: view?.drawableSize ?? .zero)
        }
        view.onUndo       = { [self] in activity.wake(); sceneManager.undo() }
        view.onRedo       = { [self] in activity.wake(); sceneManager.redo() }
    }
}
#endif

#Preview {
    ViewportView(
        assetManager: AssetManager(device: MetalDeviceProvider.device),
        sceneManager: SceneManager(),
        toolManager: ToolManager(skewState: SkewGizmoState(), rotationState: RotationGizmoState()),
        camera: CameraState(),
        skewGizmoState: SkewGizmoState(),
        rotationGizmoState: RotationGizmoState()
    )
        .frame(width: 600, height: 400)
}
