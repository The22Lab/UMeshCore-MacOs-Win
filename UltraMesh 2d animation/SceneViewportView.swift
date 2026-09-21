import SwiftUI
import simd

/// The Scene canvas: what the artist looks at while staging a set.
///
/// Two pictures of the same cards, and the artist chooses which one with the
/// Free Movement button:
///
///  * **Front** — the SHOT. Rendered through `SceneProjection`, the export's
///    model, so what is on screen is what comes out. The cards are outlined and
///    the selection is marked, and a drag moves the selected card in its own
///    plane. Depth is a modifier drag on macOS and the inspector everywhere.
///  * **Flying** — the SET. A real 3D camera (`SceneViewProjection`) looking at
///    the cards from outside, over a pale void, with the shot camera drawn as a
///    yellow frustum so the artist can see what is in frame while standing
///    beside it. A drag orbits, a pinch dollies, a tap picks. Never exported.
///
/// Both draw through `SceneFrameRenderer`, the renderer the export uses — one
/// set of triangle code, two functions that turn a card point into a pixel.
/// The rig side of the editor has a Metal canvas and a CoreGraphics exporter
/// that already disagree; a Scene is composed here and delivered from there,
/// so it never gets two.
struct SceneViewportView: View {
    @EnvironmentObject private var appState: AppState

    let composition: SceneComposition
    let frame: Int
    /// Free movement. Modal on purpose: while it is on, a drag navigates and
    /// never moves a card — which is also what makes it work on iPad, where
    /// there is no second mouse button to hold.
    @Binding var isFlying: Bool
    /// Whether the shot is playing. Passed in rather than read from a shared
    /// object for the same reason the transport itself is view state: it
    /// changes with the transport, and the only thing this needs it for is to
    /// know that the picture is provisional.
    let isPlaying: Bool
    /// Read from the manager's one selection rather than held here. The gizmo,
    /// the inspector, the layer list and the canvas all have to agree about
    /// what is selected, and a copy in this view is a second answer.
    private var selection: SceneSelection { sceneManager.sceneSelection }
    private var selectedLayerID: UUID? { sceneManager.sceneSelection.layerID }

    private var sceneManager: SceneManager { appState.sceneManager }

    /// The fly camera at the start of an orbit or pan, so the drag is applied to
    /// where the view WAS rather than compounding on every event.
    @State private var dragAnchor: SceneViewCamera?
    /// The card being dragged in the front view, and where it started.
    @State private var layerDrag: LayerDrag?
    /// `SceneViewCamera.distance` when the pinch began.
    @State private var pinchAnchor: Float?
    /// Which handles the canvas is showing, and what they are attached to.
    @State private var gizmoTool: SceneGizmoTool = .translate
    /// The camera can be the gizmo's subject instead of a card. Only while
    /// flying — see `SceneGizmoOverlay`.
    @State private var isAimingCamera = false

    /// The button in the mode switch, read from the key it writes. Two
    /// `@AppStorage` views on one key stay in sync through `UserDefaults`, so
    /// Scene follows the same setting Editor and Animator do with no binding
    /// between them.
    @AppStorage("umFingerNavigationOnly") private var fingerNavigationOnly = false

    /// The screen's scale factor. The Scene canvas is a bitmap the view scales
    /// to fit, so this is the difference between rendering at the size it is
    /// SHOWN at and rendering at a quarter of it.
    @Environment(\.displayScale) private var displayScale

    /// The gizmo drag in flight. Owned HERE, where the touch surface delivers
    /// input, so a handle drag reaches the element inside the callback that
    /// carried it rather than a frame later through view state.
    @State private var gizmoDrag: SceneGizmoOverlay.DragState?
    /// The handle the pointer is over. Owned here rather than inside the
    /// overlay because the overlay is rebuilt on every composition change, so
    /// state kept there would sometimes survive a rebuild and sometimes not.
    @State private var gizmoHover: SceneGizmoOverlay.HandleID?
    /// A card drag driven by the surface rather than by a SwiftUI gesture.
    @State private var surfaceToolStart: CGPoint?
    /// The pointer gesture reports a cumulative translation; navigation wants
    /// the step since the last event, so the previous one is kept.
    @State private var lastPointerTranslation: CGSize = .zero
    /// Decided once, on the first event of a pointer drag: whether this drag is
    /// navigation. Re-asking every event would let a card slide under the
    /// cursor and change the answer halfway through.
    @State private var pointerNavigates: Bool?

    private struct LayerDrag {
        let layerID: UUID
        let startPosition: SIMD2<Float>
        let startZ: Float
        let startWorld: SIMD2<Float>?
        let pushedUndo: Bool
    }

    /// Longest side the editor view renders at. CoreGraphics on every orbit
    /// step is the cost this mode accepted; this is where it stops growing.
    /// SCREEN PIXELS, not points. This was points, and nothing in the chain
    /// mentioned the display's scale factor — so on any Retina screen the set
    /// was rendered at half the linear resolution it was shown at and upscaled,
    /// a quarter of the pixels.
    ///
    /// It bit unevenly, which is what made it look like an iPad advantage: an
    /// iPad's viewport is around 1 000 points wide, so the cap barely applied
    /// and the image was upscaled 2x. A Mac window is often 2 000 points wide,
    /// so the cap cut it down first and the result was upscaled nearly 3x on
    /// top of already being half resolution. Same code, worse result.
    ///
    /// Still a cap, and still one a readback can afford: the projective card
    /// path reads its result back from the GPU, and that cost is linear in
    /// pixels. An iPad lands inside this and is now pixel-for-pixel; a very
    /// large Mac window is still capped, at under 1.8x rather than 2.9x.
    static let maxEditorPixels: Float = 2400
    /// And while a gesture is actually in flight, smaller.
    ///
    /// Fill cost is the square of this, so 820 against 1400 is a third of the
    /// pixels — and nobody reads a set at full sharpness while swinging the
    /// camera round it. The moment the drag ends the state changes, the view
    /// re-evaluates, and the full picture comes back on its own; there is no
    /// timer to leak and no "restore" that can be forgotten.
    ///
    /// A ceiling, never a target: a viewport already smaller than this renders
    /// at its own size. Upscaling to hit a cap would be paying MORE to look
    /// worse.
    /// While a gesture is in flight. Raised with the rest when the caps moved
    /// into pixels, but not proportionally: fill cost and the projective card's
    /// readback are both linear in pixels, and a drag is the one moment where
    /// being ready beats being sharp.
    static let interactiveEditorPixels: Float = 1200
    /// The same, for the front view, whose size follows the shot's aspect.
    static let maxShotPixels: Float = 1800
    static let interactiveShotPixels: Float = 900

    /// Whether SwiftUI's pointer gestures drive this viewport.
    ///
    /// A Mac has one pointer and no touch types, so they do. An iPad has both,
    /// and only `SceneInputSurface` can tell them apart — two gesture systems
    /// on one view is how a handle and a camera end up fighting over the same
    /// finger.
    static var usesPointerGestures: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// The picture is PROVISIONAL: something is moving, so the next frame has
    /// to be ready before the next one rather than be perfect.
    ///
    /// PLAYBACK COUNTS, and it did not. A drag dropped the resolution and
    /// playing a shot did not, so pressing play asked for full-resolution
    /// frames thirty times a second — four times the pixels of the drag the
    /// artist had just been told was too heavy to draw sharp. The transport
    /// arrived after this rule and nothing connected them.
    private var isProvisional: Bool {
        dragAnchor != nil || pinchAnchor != nil || layerDrag != nil
            || gizmoDrag != nil || isPlaying
    }

    var body: some View {
        GeometryReader { proxy in
            let pixelSize = renderPixelSize(view: proxy.size)
            let fitted = fittedRect(pixelSize: pixelSize, in: proxy.size)
            ZStack {
                Rectangle().fill(isFlying ? Color(red: Double(UM.sceneVoid.x), green: Double(UM.sceneVoid.y),
                                                  blue: Double(UM.sceneVoid.z))
                                          : UM.surfaceInset)

                if let metal = appState.sceneMetalRenderer,
                   let metalFrame = metalFrame(pixelSize: pixelSize, renderer: metal) {
                    SceneMetalView(
                        renderer: metal,
                        scene: sceneManager, assets: appState.assetManager,
                        composition: composition, frameIndex: frame,
                        frame: metalFrame,
                        // TWO FINGERS PAN, exactly as they do on the iPad. The
                        // touch path calls the same `navigate` with the same
                        // finger count, so the two platforms cannot drift into
                        // different camera behaviour.
                        onPan: { delta in
                            navigate(delta: delta, fingers: 2,
                                     viewHeight: Float(proxy.size.height))
                        },
                        // A NOTCHED WHEEL, which is a mouse and not a trackpad.
                        onZoom: { deltaY, local in
                            pinch(scale: 1 + deltaY * Self.wheelZoomPerPoint,
                                  anchor: anchorInView(local, fitted: fitted),
                                  pixelSize: pixelSize, viewSize: proxy.size)
                        },
                        onPinch: { scale, local in
                            pinch(scale: scale,
                                  anchor: anchorInView(local, fitted: fitted),
                                  pixelSize: pixelSize, viewSize: proxy.size)
                        })
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        // HIT-TESTABLE, deliberately, and it was not.
                        //
                        // "The picture itself is never a hit target" sounded
                        // right and cost the whole feature: with hit-testing
                        // off the view receives no AppKit events at all, so
                        // `SceneInputMTKView`'s scroll and magnify handlers
                        // never fired. The two-finger trackpad gesture was
                        // written and unreachable.
                        //
                        // Letting it through takes nothing from anyone. Every
                        // layer that wants a click — the outlines, the light
                        // markers, the gizmo — sits ABOVE this in the stack and
                        // is offered the event first, and the drag and dolly
                        // gestures are attached to the enclosing stack rather
                        // than to this view, so they never depended on its
                        // hit-testing either.
                } else if let image = renderedImage(pixelSize: pixelSize) {
                    // At the display's scale, so a bitmap rendered in screen
                    // pixels is presented one for one instead of being blown up
                    // a second time on the way out.
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                }

                // ON TOP OF THE PICTURE, NOT IN IT — the same move the light
                // markers already made. These were drawn into the raster, from
                // the renderer's own copy of where each card landed; now they
                // come from `layerQuads`, which is also what picking uses, so
                // the box the artist sees and the box they can click are one
                // thing rather than two that agree.
                SceneCardOutlines(
                    quads: layerQuads(pixelSize: pixelSize),
                    selectedLayerID: selectedLayerID,
                    toView: { viewPoint($0, pixelSize: pixelSize, fitted: fitted) })

                // ONLY WHILE FLYING. Front-on, the frustum is edge-on to the
                // eye and collapses to a line across the middle of the shot it
                // is supposed to describe.
                if isFlying, let frustum = frustumGeometry(pixelSize: pixelSize) {
                    SceneFrustumOverlay(
                        geometry: frustum,
                        toView: { viewPoint($0, pixelSize: pixelSize, fitted: fitted) })
                }

                if composition.visibleLayers.isEmpty {
                    emptyHint
                }

                // Unmistakable while flying. Confusing the view for the shot is
                // how an afternoon goes into composing a frame that renders
                // from somewhere else.
                if isFlying {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(UM.accentStrong.opacity(0.9), lineWidth: 3)
                        .allowsHitTesting(false)
                }

                // ON TOP OF THE IMAGE, NOT IN IT. The frame is cached on its
                // inputs now; a handle drawn into the raster would redraw the
                // whole set every time the pointer crossed it. It is also
                // editor chrome that must never reach a file, which a separate
                // layer guarantees rather than promises.
                // EVERY light gets a mark, selected or not. A light draws no
                // pixels of its own, so without one there would be nothing on
                // the canvas to click — and the gizmo only exists for what is
                // already selected.
                SceneLightMarkers(
                    markers: lightMarkers(pixelSize: pixelSize),
                    selectedLightID: selection.lightID,
                    toView: { viewPoint($0, pixelSize: pixelSize, fitted: fitted) })

                if let gizmo = gizmoOverlay(pixelSize: pixelSize, fitted: fitted) {
                    gizmo
                }

#if os(macOS)
                // The hover pass. A separate, non-hit-testing layer over the
                // whole viewport: `onContinuousHover` on the overlay itself
                // would only report while the pointer is already ON a handle,
                // which is exactly when the highlight no longer needs to change.
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(point):
                            updateGizmoHover(at: point, pixelSize: pixelSize, fitted: fitted)
                        case .ended:
                            updateGizmoHover(at: nil, pixelSize: pixelSize, fitted: fitted)
                        }
                    }
#endif

#if os(iOS)
                // THE ONLY THING THAT KNOWS A FINGER FROM A PENCIL. It sits on
                // top and owns every touch, then hands them out: fingers to
                // navigation, the Pencil to the handles and the cards. SwiftUI
                // gestures cannot make that distinction, which is why Scene did
                // not follow the canvas's rule until now.
                SceneInputSurface(
                    fingerNavigationOnly: fingerNavigationOnly,
                    onNavigate: { delta, fingers, _ in
                        navigate(delta: delta, fingers: fingers,
                                 viewHeight: Float(proxy.size.height))
                    },
                    onPinch: { scale, anchor, _ in
                        pinch(scale: scale, anchor: anchor,
                              pixelSize: pixelSize, viewSize: proxy.size)
                    },
                    onToolDown: { surfaceTool(.began, at: $0, pixelSize: pixelSize, fitted: fitted) },
                    onToolDrag: { surfaceTool(.changed, at: $0, pixelSize: pixelSize, fitted: fitted) },
                    onToolUp: { surfaceTool(.ended, at: $0, pixelSize: pixelSize, fitted: fitted) },
                    claimsTouch: { toolClaims($0, pixelSize: pixelSize, fitted: fitted) }
                )
#endif

                VStack {
                    HStack(alignment: .top) {
                        navigationControls
                        Spacer(minLength: 0)
                        if isFlying { shotPreview }
                    }
                    Spacer(minLength: 0)
                    HStack {
                        gizmoToolStrip
                        Spacer(minLength: 0)
                    }
                }
                .padding(12)
            }
            .contentShape(Rectangle())
            // A mouse has no touch type to classify, so the pointer gestures
            // stay here. On iPad the surface above owns every touch, and these
            // are masked off rather than compiled out: `#if` between two links
            // of a modifier chain is a corner of the language this file has no
            // reason to stand in.
            .gesture(dragGesture(pixelSize: pixelSize, fitted: fitted,
                                 viewHeight: Float(proxy.size.height)),
                     including: Self.usesPointerGestures ? .all : .subviews)
            .simultaneousGesture(dollyGesture(pixelSize: pixelSize, viewSize: proxy.size),
                                 including: Self.usesPointerGestures ? .all : .subviews)
        }
    }

    /// What the handles act on, or nil when there is nothing to act on.
    ///
    /// Free movement is modal and navigation-only, so no handles while a
    /// navigation drag could be in flight — two things claiming the same drag
    /// is how a gizmo ends up fighting the camera.
    private var gizmoTarget: SceneGizmoTarget? {
        if isAimingCamera { return isFlying ? .camera : nil }
        switch selection {
        case .none:            return nil
        case let .layer(id):   return .layer(id)
        case let .light(id):   return .light(id)
        }
    }

    /// Translate / Rotate / Scale / Shear, and the camera toggle beside them.
    private var gizmoToolStrip: some View {
        HStack(spacing: 4) {
            ForEach(SceneGizmoTool.allCases) { tool in
                Button { gizmoTool = tool } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(gizmoTool == tool ? UM.textPrimary : UM.textSecondary)
                        .frame(width: 28, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(gizmoTool == tool ? UM.accentSoft : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(tool.title)
            }

            if isFlying {
                Divider().frame(height: 16)
                Button { isAimingCamera.toggle() } label: {
                    Image(systemName: "video")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isAimingCamera ? UM.textPrimary : UM.textSecondary)
                        .frame(width: 28, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isAimingCamera ? UM.accentSoft : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help("Aim the shot camera")
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(UM.surfaceRaised.opacity(0.92))
        )
        // The camera's handles only exist while flying, so leaving the fly view
        // has to put the strip back on the cards rather than leave it pointing
        // at something with no handles.
        .onChange(of: isFlying) { _, flying in
            if !flying { isAimingCamera = false }
        }
    }

    // MARK: - Navigation

    /// A pan gesture, in view points. `fingers` is what the canvas's law turns
    /// on: two fingers pan, one orbits (fly) or pans (front).
    ///
    /// One function for both platforms and both views, because "what does this
    /// drag mean" is exactly the question that grows a second, different answer
    /// if it is asked in two places.
    private func navigate(delta: CGPoint, fingers: Int, viewHeight: Float) {
        if isFlying {
            var camera = sceneManager.sceneViewCamera
            if fingers >= 2 {
                camera.pan(screenDelta: SIMD2<Float>(Float(delta.x), Float(delta.y)),
                           viewHeight: viewHeight)
            } else {
                camera.orbit(deltaYaw: Float(delta.x) * Self.radiansPerPoint,
                             deltaPitch: Float(delta.y) * Self.radiansPerPoint)
            }
            sceneManager.sceneViewCamera = camera
        } else {
            // The front view has no camera to orbit, so every finger pans it.
            sceneManager.sceneFrontView.pan += SIMD2<Float>(Float(delta.x), Float(delta.y))
        }
    }

    static let radiansPerPoint: Float = 0.006

    /// A pinch. Dollies the fly camera; zooms the front view TOWARD THE FINGERS,
    /// so what the artist is looking at stays where it is instead of sliding
    /// off while they zoom in on it.
    private func pinch(scale: CGFloat, anchor: CGPoint,
                       pixelSize: SIMD2<Float>, viewSize: CGSize) {
        guard scale > 0.01 else { return }
        if isFlying {
            var camera = sceneManager.sceneViewCamera
            camera.dolly(by: 1 / Float(scale))
            sceneManager.sceneViewCamera = camera
            return
        }
        let before = fittedRect(pixelSize: pixelSize, in: viewSize)
        guard before.width > 1, before.height > 1 else { return }
        let u = CGPoint(x: (anchor.x - before.minX) / before.width,
                        y: (anchor.y - before.minY) / before.height)
        sceneManager.sceneFrontView.zoomBy(Float(scale))
        let after = fittedRect(pixelSize: pixelSize, in: viewSize)
        let landed = CGPoint(x: after.minX + u.x * after.width,
                             y: after.minY + u.y * after.height)
        sceneManager.sceneFrontView.pan += SIMD2<Float>(Float(anchor.x - landed.x),
                                                        Float(anchor.y - landed.y))
    }

    /// Whether a one-finger touch here belongs to a tool rather than to
    /// navigation. Asked before any undo state is pushed.
    ///
    /// A handle first, then a card. Empty space belongs to navigation whatever
    /// the finger button says — the set must never be unreachable because the
    /// artist forgot which mode a button is in.
    private func toolClaims(_ point: CGPoint, pixelSize: SIMD2<Float>, fitted: CGRect) -> Bool {
        if let gizmo = gizmoOverlay(pixelSize: pixelSize, fitted: fitted),
           gizmo.handle(at: point) != nil {
            return true
        }
        return pickedLayer(at: imagePoint(point, pixelSize: pixelSize, fitted: fitted),
                           pixelSize: pixelSize) != nil
    }

    /// The handles, or nil when there is nothing to put them on. Built here
    /// rather than inline so the touch surface can ask the same instance what
    /// it would grab.
    private func gizmoOverlay(pixelSize: SIMD2<Float>, fitted: CGRect) -> SceneGizmoOverlay? {
        guard let target = gizmoTarget else { return nil }
        return SceneGizmoOverlay(
            composition: composition,
            frame: frame,
            isFlying: isFlying,
            pixelSize: pixelSize,
            fitted: fitted,
            tool: gizmoTool,
            target: target,
            renderer: appState.sceneFrameRenderer,
            sceneManager: sceneManager,
            // PINNED to the dragged handle while a drag is live. The pointer
            // wanders off the handle it grabbed — that is what dragging is —
            // and letting the highlight follow the pointer would have it hop to
            // a neighbour mid-gesture while the drag itself stayed locked,
            // which reads as the gizmo having changed its mind.
            highlighted: gizmoDrag?.handle ?? gizmoHover,
            drag: $gizmoDrag
        )
    }

    /// Follow the pointer so the handle under it lights up before it is
    /// grabbed. macOS only: a touch has no hover, and on iPad the highlight
    /// appears when the finger lands, which is the first moment there is
    /// anything to report.
    private func updateGizmoHover(at point: CGPoint?,
                                  pixelSize: SIMD2<Float>, fitted: CGRect) {
        guard gizmoDrag == nil else { return }
        let next = point.flatMap {
            gizmoOverlay(pixelSize: pixelSize, fitted: fitted)?.handle(at: $0)
        }
        if next != gizmoHover { gizmoHover = next }
    }

    /// A tool touch from the surface: the handles first, then a card drag.
    private func surfaceTool(_ phase: SceneGizmoOverlay.ExternalPhase,
                             at point: CGPoint,
                             pixelSize: SIMD2<Float>, fitted: CGRect) {
        // Built from the CURRENT transform, this call. The handle work then
        // happens here, synchronously, in the callback the touch arrived in.
        // It used to be handed to the overlay through a `@State` value, which
        // meant SwiftUI drew a frame with the element still in its old place
        // and only then let `onChange` move it — a small, constant lag between
        // the handles and the thing they are attached to.
        let gizmo = gizmoOverlay(pixelSize: pixelSize, fitted: fitted)
        switch phase {
        case .began:
            if let gizmo, let started = gizmo.beginDrag(at: point) {
                gizmoDrag = started
                surfaceToolStart = nil
                return
            }
            gizmoDrag = nil
            surfaceToolStart = point
            beginCardDrag(at: point, pixelSize: pixelSize, fitted: fitted)
        case .changed:
            if let drag = gizmoDrag {
                gizmo?.applyDrag(drag, to: point)
                return
            }
            updateCardDrag(to: point, pixelSize: pixelSize, fitted: fitted)
        case .ended:
            if gizmoDrag != nil {
                gizmoDrag = nil
                return
            }
            if let start = surfaceToolStart,
               hypot(point.x - start.x, point.y - start.y) < 4 {
                selectWhatever(isAt: point, pixelSize: pixelSize, fitted: fitted)
            }
            surfaceToolStart = nil
            layerDrag = nil
        }
    }

    // MARK: - Rendering

    /// Flying renders the whole viewport — the set has no aspect. Front renders
    /// the shot at the composition's aspect, scaled to fit, so resizing the
    /// window cannot change the framing.
    /// How much one point of scroll-wheel travel zooms.
    ///
    /// Only a NOTCHED wheel reaches this — a trackpad is told apart by its
    /// precise deltas and pans instead — so the number is tuned for a mouse's
    /// coarse steps rather than for fingers.
    static let wheelZoomPerPoint: CGFloat = 0.01

    /// A point in the Metal view's own space, in the GeometryReader's.
    ///
    /// The canvas is placed at `fitted` with `.position`, so its local origin
    /// is that rectangle's corner while `pinch` and `fittedRect` both speak the
    /// enclosing space. Zooming without this offset walks the anchor away from
    /// the pointer by however far the canvas is letterboxed.
    private func anchorInView(_ local: CGPoint, fitted: CGRect) -> CGPoint {
        CGPoint(x: local.x + fitted.minX, y: local.y + fitted.minY)
    }

    private func renderPixelSize(view: CGSize) -> SIMD2<Float> {
        guard view.width > 1, view.height > 1 else { return SIMD2<Float>(16, 16) }
        // Points to the pixels those points are actually shown at, then
        // capped. Doing it the other way round — capping in points — is what
        // made a big window look worse than a small one.
        let pixelScale = Float(displayScale)
        // THE LADDER, on top of the fixed cap. The cap says what this viewport
        // is worth drawing at; the ladder says what this MACHINE is managing
        // right now, measured from the frames it has just drawn. A fixed cap
        // alone has to be chosen for the worst machine and the heaviest set,
        // which makes it wrong for every other pair.
        let ladder = isProvisional
            ? appState.sceneFrameRenderer.budget.pixelCap(full: 1)
            : 1
        if isFlying {
            let base = isProvisional ? Self.interactiveEditorPixels : Self.maxEditorPixels
            let cap = base * ladder
            let longest = Float(max(view.width, view.height)) * pixelScale
            let scale = min(1, cap / max(longest, 1)) * pixelScale
            return SIMD2<Float>(Float(view.width) * scale, Float(view.height) * scale)
        }
        let aspect = composition.renderSize.x / max(composition.renderSize.y, 1)
        let base = isProvisional ? Self.interactiveShotPixels : Self.maxShotPixels
        let height = min(Float(view.height) * pixelScale, base * ladder)
        return SIMD2<Float>(height * aspect, height)
    }

    /// Where the rendered image sits in the view: scaled uniformly to fit and
    /// centred. Picking maps view points through this, so a click lands on the
    /// pixel the artist sees rather than the pixel the renderer wrote.
    private func fittedRect(pixelSize: SIMD2<Float>, in view: CGSize) -> CGRect {
        let scale = min(view.width / CGFloat(max(pixelSize.x, 1)),
                        view.height / CGFloat(max(pixelSize.y, 1)))
        let size = CGSize(width: CGFloat(pixelSize.x) * scale, height: CGFloat(pixelSize.y) * scale)
        let base = CGRect(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2,
                          width: size.width, height: size.height)
        // Flying already has a camera; the pan and zoom are the FRONT view's
        // way of getting close to a card, and applying them to both would be
        // two navigations fighting over one set of fingers.
        guard !isFlying else { return base }
        let front = sceneManager.sceneFrontView
        let zoomed = CGSize(width: base.width * CGFloat(front.zoom),
                            height: base.height * CGFloat(front.zoom))
        return CGRect(x: base.midX - zoomed.width / 2 + CGFloat(front.pan.x),
                      y: base.midY - zoomed.height / 2 + CGFloat(front.pan.y),
                      width: zoomed.width, height: zoomed.height)
    }

    /// Where each light is on screen, through whichever eye is showing.
    ///
    /// Asked of the renderer, so the mark is where the light actually is in the
    /// picture the canvas drew.
    private func lightMarkers(pixelSize: SIMD2<Float>) -> [SceneFrameRenderer.LightMarker] {
        appState.sceneFrameRenderer.lightMarkers(
            composition: composition, atFrame: frame,
            viewpoint: isFlying
                ? .fly(sceneManager.sceneViewCamera)
                : .shot(sceneManager.sceneCamera(for: composition, atFrame: frame)),
            pixelSize: pixelSize)
    }

    /// Image pixels to view points — the inverse of `imagePoint`.
    ///
    /// Named beside it rather than written out at each call, because the two
    /// have to stay each other's inverse: getting one of them wrong is a click
    /// that lands somewhere other than where the thing is drawn, and on a
    /// Retina iPad it is wrong by the scale factor.
    private func viewPoint(_ image: SIMD2<Float>, pixelSize: SIMD2<Float>,
                           fitted: CGRect) -> CGPoint {
        CGPoint(x: fitted.minX + CGFloat(image.x / max(pixelSize.x, 1)) * fitted.width,
                y: fitted.minY + CGFloat(image.y / max(pixelSize.y, 1)) * fitted.height)
    }

    /// The light under a view point, if any.
    ///
    /// Tried BEFORE the cards. A light's mark is small and sits on top of the
    /// artwork; a card is large and can be grabbed anywhere else on it, so the
    /// mark wins where they overlap.
    private func pickedLight(at point: CGPoint, pixelSize: SIMD2<Float>,
                             fitted: CGRect) -> UUID? {
        SceneLightMarkers.pick(lightMarkers(pixelSize: pixelSize), at: point,
                               toView: { viewPoint($0, pixelSize: pixelSize, fitted: fitted) })
    }

    private func imagePoint(_ viewPoint: CGPoint, pixelSize: SIMD2<Float>, fitted: CGRect) -> SIMD2<Float> {
        SIMD2<Float>(
            Float((viewPoint.x - fitted.minX) / max(fitted.width, 1)) * pixelSize.x,
            Float((viewPoint.y - fitted.minY) / max(fitted.height, 1)) * pixelSize.y
        )
    }

    /// Everything the GPU renderer needs that is not the composition.
    ///
    /// THE TWO EYES DIFFER HERE AND NOWHERE ELSE — in the projection and in the
    /// ground behind it. The fly view is composed against the editor's void
    /// grey so that leaving the frame looks like leaving the set; the shot is
    /// composed against the artist's own background, because that is what the
    /// file will contain. Everything downstream is told, not asked.
    /// A pixel size safe to turn into integers.
    ///
    /// `Int(_: Float)` TRAPS on NaN, on an infinity and on anything past
    /// `Int.max` — it does not clamp, it crashes the process. The CPU
    /// compositor never met that edge because `makeContext` took the same
    /// numbers through `max(Int(size.rounded()), 16)`, and its comment says
    /// why: "a degenerate viewport must not produce a degenerate context".
    /// Moving to Metal dropped that floor and replaced it with a raw
    /// conversion, which is a crash where there used to be a small picture.
    ///
    /// NaN gets in more easily than it looks. `renderPixelSize` computes the
    /// shot's aspect as `renderSize.x / max(renderSize.y, 1)`, and
    /// `max(NaN, 1)` is NaN — Swift's `max` returns the first argument when
    /// the comparison is false, and every comparison with NaN is false. So a
    /// composition carrying a NaN dimension propagates it straight through the
    /// guard that looks like it stops this.
    private static func integerPixels(_ size: SIMD2<Float>) -> SIMD2<Int>? {
        guard size.x.isFinite, size.y.isFinite,
              size.x >= 1, size.y >= 1,
              size.x < 65536, size.y < 65536 else { return nil }
        return SIMD2<Int>(Int(size.x), Int(size.y))
    }

    private func metalFrame(pixelSize: SIMD2<Float>,
                            renderer: SceneMetalRenderer) -> SceneMetalRenderer.Frame? {
        guard pixelSize.x > 1, pixelSize.y > 1 else { return nil }
        recordFrameCost(renderer.lastDrawMilliseconds)
        guard isFlying else { return shotMetalFrame(pixelSize: pixelSize) }
        guard let pixels = Self.integerPixels(pixelSize) else { return nil }
        return SceneMetalRenderer.Frame(
            projection: SceneViewProjection(camera: sceneManager.sceneViewCamera,
                                            viewSize: pixelSize).matrices,
            lighting: sceneLighting,
            pixelSize: pixels,
            background: .solid(SIMD4<Float>(UM.sceneVoid.x, UM.sceneVoid.y,
                                            UM.sceneVoid.z, 1)))
    }

    /// The SHOT's frame — what the film will contain.
    ///
    /// One construction, two callers: the canvas when it is front-on, and the
    /// camera preview in the corner, which exists precisely to say "this is
    /// what will be exported". Built separately they could disagree, and a
    /// preview that disagrees with the file is worse than no preview.
    private func shotMetalFrame(pixelSize: SIMD2<Float>) -> SceneMetalRenderer.Frame? {
        guard let pixels = Self.integerPixels(pixelSize) else { return nil }
        return SceneMetalRenderer.Frame(
            projection: SceneProjection(
                camera: sceneManager.sceneCamera(for: composition, atFrame: frame),
                viewSize: pixelSize),
            lighting: sceneLighting,
            pixelSize: pixels,
            background: composition.background)
    }

    private var sceneLighting: SceneLighting {
        SceneLighting(
            lights: sceneManager.sceneLights(for: composition, atFrame: frame),
            ambient: composition.ambient)
    }

    /// The camera preview's pixel size: a fixed width at the render's aspect.
    private var previewPixelSize: SIMD2<Float> {
        SIMD2<Float>(320, 320 * composition.renderSize.y
                     / max(composition.renderSize.x, 1))
    }

    /// Hand the ladder what the LAST frame actually cost.
    ///
    /// The GPU figure describes a frame that has already been presented, so it
    /// arrives one frame late — which is what the ladder wants anyway, since it
    /// climbs on evidence rather than on prediction. A cached CPU frame costs
    /// nothing and reports nothing, so a still canvas cannot feed it a run of
    /// free frames and talk it into a rung it has not earned.
    private func recordFrameCost(_ milliseconds: Double) {
        guard milliseconds > 0 else { return }
        appState.sceneFrameRenderer.recordFrameCost(milliseconds,
                                                    isProvisional: isProvisional)
    }

    private func renderedImage(pixelSize: SIMD2<Float>) -> CGImage? {
        guard pixelSize.x > 1, pixelSize.y > 1 else { return nil }
        guard let renderer = appState.sceneFrameRenderer else { return nil }
        let image: CGImage?
        if isFlying {
            image = renderer.renderEditorView(
                composition: composition, atFrame: frame,
                view: sceneManager.sceneViewCamera,
                pixelSize: pixelSize
            )
        } else {
            // The SHOT is the camera sampled at this frame — its keys are what
            // make a Scene a shot rather than a still.
            image = renderer.renderShotView(
                composition: composition, atFrame: frame,
                through: sceneManager.sceneCamera(for: composition, atFrame: frame),
                pixelSize: pixelSize
            )
        }
        // CLOSE THE LOOP, through the same helper the GPU path uses: only this
        // view knows whether the picture was provisional, and the ladder needs
        // that as well as the cost.
        recordFrameCost(renderer.lastDrawMilliseconds)
        return image
    }

    /// A scene with nothing on it says so ON THE CANVAS. The layer list already
    /// said it, in small grey type off to the side; the canvas is where the eye
    /// goes, and an empty canvas with no words reads as a broken one.
    private var emptyHint: some View {
        VStack(spacing: 6) {
            Text("Nothing on the set")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UM.textPrimary)
            Text("Add a rig instance, a plate or a fill with the + in the Layers panel.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(UM.textSecondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UM.surfaceRaised.opacity(0.92)))
        .allowsHitTesting(false)
    }

    /// What the SHOT sees, while the artist is somewhere else. Without it,
    /// flying means composing blind.
    private var shotPreview: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("CAMERA")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(UM.textMuted)
            Group {
                // THE SAME RENDERER AS THE CANVAS AND THE FILM. This panel's
                // whole job is to say "this is what will be exported", so it is
                // the one picture in the app that must not come from a second
                // implementation — the moment it did, it would be answering the
                // question it exists to answer with a guess.
                if let metal = appState.sceneMetalRenderer,
                   let previewFrame = shotMetalFrame(pixelSize: previewPixelSize) {
                    SceneMetalView(renderer: metal,
                                   scene: sceneManager, assets: appState.assetManager,
                                   composition: composition, frameIndex: frame,
                                   frame: previewFrame)
                        .aspectRatio(CGFloat(previewPixelSize.x
                                             / max(previewPixelSize.y, 1)),
                                     contentMode: .fit)
                } else if let image = appState.sceneFrameRenderer.renderImage(
                    composition: composition,
                    atFrame: frame,
                    through: sceneManager.sceneCamera(for: composition, atFrame: frame),
                    pixelSize: previewPixelSize,
                    quality: .interactive
                ) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    // THE SAME ASPECT as the image it stands in for. A bare
                    // `Rectangle` has no intrinsic ratio, so in a frame given a
                    // width and no height it collapses — and the preview
                    // vanishing entirely is the very complaint this panel
                    // exists to answer.
                    Rectangle()
                        .fill(UM.surfaceInset)
                        .aspectRatio(CGFloat(composition.renderSize.x
                                             / max(composition.renderSize.y, 1)),
                                     contentMode: .fit)
                }
            }
            .frame(width: 190)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(UM.textPrimary.opacity(0.25), lineWidth: 1)
            )
        }
    }

    // MARK: - Picking

    /// The card under a point, front-most first — the LAST drawn wins, which is
    /// the last in the list. Asked of the renderer so the answer is the quad it
    /// actually drew.
    /// Every card's outline in image pixels, from whichever eye is looking.
    ///
    /// ONE SOURCE for both uses: the outlines the artist sees and the picking
    /// that decides what they grabbed. These used to be separate — the overlay
    /// was drawn inside the raster from the renderer's own copy — and two ways
    /// of working out where a card landed is how a click starts missing the box
    /// it is aimed at.
    private func layerQuads(pixelSize: SIMD2<Float>) -> [SceneFrameRenderer.LayerQuad] {
        isFlying
            ? appState.sceneFrameRenderer.editorLayerQuads(
                composition: composition, atFrame: frame,
                view: sceneManager.sceneViewCamera, pixelSize: pixelSize)
            : appState.sceneFrameRenderer.shotLayerQuads(
                composition: composition, atFrame: frame,
                through: sceneManager.sceneCamera(for: composition, atFrame: frame),
                pixelSize: pixelSize)
    }

    /// Where the shot's frustum lands in the fly view, from the renderer that
    /// already knows how to project it.
    private func frustumGeometry(pixelSize: SIMD2<Float>) -> SceneFrameRenderer.FrustumGeometry? {
        appState.sceneFrameRenderer.frustumGeometry(
            composition: composition, atFrame: frame,
            view: sceneManager.sceneViewCamera, pixelSize: pixelSize)
    }

    private func pickedLayer(at image: SIMD2<Float>, pixelSize: SIMD2<Float>) -> UUID? {
        let quads = layerQuads(pixelSize: pixelSize)
        for quad in quads.reversed() where Self.contains(quad.corners, image) {
            return quad.id
        }
        return nil
    }

    /// Point in a convex quad, whichever way round its corners run. A card seen
    /// from behind runs the other way and must still be pickable.
    static func contains(_ quad: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        // Any convex polygon, not only a quad. A card the near plane cuts
        // through comes back as a triangle or a pentagon, and it is still a
        // card the artist can click; insisting on four made exactly the cards
        // that had gone invisible also unpickable.
        guard quad.count >= 3 else { return false }
        var positive = 0, negative = 0
        for i in 0..<quad.count {
            let a = quad[i], b = quad[(i + 1) % quad.count]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if cross > 0 { positive += 1 } else if cross < 0 { negative += 1 }
        }
        return positive == 0 || negative == 0
    }

    // MARK: - Navigation

    private var navigationControls: some View {
        HStack(spacing: 6) {
            Button {
                isFlying.toggle()
            } label: {
                Label(isFlying ? "Flying" : "Free Movement",
                      systemImage: isFlying ? "location.fill" : "location")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isFlying ? UM.textOnAccent : UM.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(isFlying ? UM.accentStrong : UM.surfaceRaised.opacity(0.9))
                    )
            }
            .buttonStyle(.plain)

            if !isFlying, !sceneManager.sceneFrontView.isIdentity {
                // A way back. A view that can be panned and zoomed needs one,
                // or a set can be left somewhere off screen with no clue how it
                // got there.
                control("Reset View", "arrow.counterclockwise") {
                    sceneManager.sceneFrontView = .identity
                }
            }

            if isFlying {
                // The way back to a flat, front-on view. Every 3D viewport
                // needs one, and in a 2D tool it is the most important control
                // on the panel.
                control("Front", "rectangle.portrait") {
                    var view = sceneManager.sceneViewCamera
                    view.pitch = 0
                    view.yaw = 0
                    sceneManager.sceneViewCamera = view
                }
                control("Frame Set", "arrow.up.left.and.arrow.down.right") {
                    sceneManager.frameSceneView(compositionID: composition.id,
                                                layerID: selectedLayerID)
                }
                control("Align Camera", "camera.badge.ellipsis") {
                    sceneManager.alignSceneCameraToView(compositionID: composition.id)
                }
                control("Look Through", "eye") {
                    sceneManager.alignSceneViewToCamera(compositionID: composition.id)
                }
            }
        }
    }

    private func control(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(UM.textPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Capsule().fill(UM.surfaceRaised.opacity(0.9)))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    /// One gesture, two meanings, decided by the mode rather than by the artist:
    ///
    ///  * Flying: a drag orbits (Shift-drag pans on macOS); a tap — a drag that
    ///    never moved — picks the card under it.
    ///  * Front: a drag on a card selects it and moves it in its own plane,
    ///    through `SceneProjection.worldPoint` so the card stays under the
    ///    cursor at any depth; Option-drag on macOS moves it in depth instead;
    ///    a drag on nothing clears the selection.
    ///
    /// Navigation never enters the undo stack. Moving a card is one entry,
    /// pushed once when the drag starts, not once per event.
    /// The card drag, extracted so the SwiftUI gesture and the iPad's touch
    /// surface run the SAME code. Two copies of "what a drag does to a card" is
    /// how one of them would keep picking on every event, or stop pushing undo.
    /// ONE decision about what a click selects.
    ///
    /// Lights first, then cards, then nothing. Written once because it is asked
    /// from three places — the trackpad click, the iPad touch surface, and the
    /// start of a card drag — and three copies of "what did you click" is how
    /// one of them ends up unable to select a light at all.
    private func selectWhatever(isAt point: CGPoint, pixelSize: SIMD2<Float>,
                                fitted: CGRect) {
        if let light = pickedLight(at: point, pixelSize: pixelSize, fitted: fitted) {
            sceneManager.selectSceneLight(light)
            return
        }
        sceneManager.selectSceneLayer(
            pickedLayer(at: imagePoint(point, pixelSize: pixelSize, fitted: fitted),
                        pixelSize: pixelSize))
    }

    private func beginCardDrag(at point: CGPoint, pixelSize: SIMD2<Float>, fitted: CGRect) {
        // A light's mark wins over the card under it: the mark is small and the
        // card can be grabbed anywhere else. Selecting it ends the gesture —
        // the light is then dragged by its gizmo, which is where its undo and
        // its axis constraints live.
        if let light = pickedLight(at: point, pixelSize: pixelSize, fitted: fitted) {
            sceneManager.selectSceneLight(light)
            layerDrag = nil
            return
        }
        let start = imagePoint(point, pixelSize: pixelSize, fitted: fitted)
        guard let hit = pickedLayer(at: start, pixelSize: pixelSize),
              let layer = composition.layer(hit) else {
            sceneManager.selectSceneLayer(nil)
            layerDrag = nil
            return
        }
        sceneManager.selectSceneLayer(hit)
        sceneManager.pushUndoState()
        let projection = SceneProjection(
            camera: sceneManager.sceneCamera(for: composition, atFrame: frame),
            viewSize: pixelSize)
        layerDrag = LayerDrag(
            layerID: hit, startPosition: layer.position, startZ: layer.positionZ,
            startWorld: projection.unproject(start, ontoPlaneZ: layer.positionZ),
            pushedUndo: true)
    }

    private func updateCardDrag(to point: CGPoint, pixelSize: SIMD2<Float>, fitted: CGRect) {
        guard let drag = layerDrag, drag.pushedUndo,
              let layer = composition.layer(drag.layerID) else { return }
        let projection = SceneProjection(
            camera: sceneManager.sceneCamera(for: composition, atFrame: frame),
            viewSize: pixelSize)
        let now = imagePoint(point, pixelSize: pixelSize, fitted: fitted)
        guard let startWorld = drag.startWorld,
              let nowWorld = projection.unproject(now, ontoPlaneZ: drag.startZ) else { return }
        let position = drag.startPosition + (nowWorld - startWorld)
        sceneManager.updateSceneLayer(layer.id, in: composition.id, undoable: false) {
            $0.position = position
        }
    }

    /// The pointer gesture: a mouse on macOS, and on iPad only when the touch
    /// surface is not there to classify it.
    ///
    /// Navigation here is the modifier conventions a mouse has and a finger does
    /// not: Option drags the set, Shift drags a card's depth. The finger rules
    /// live in `navigate` and are shared.
    private func dragGesture(pixelSize: SIMD2<Float>, fitted: CGRect, viewHeight: Float) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let delta = CGPoint(x: value.translation.width - lastPointerTranslation.width,
                                    y: value.translation.height - lastPointerTranslation.height)
                lastPointerTranslation = value.translation

                // Option is the mouse's "this drag is the view, not the thing"
                // — the convention every 3D editor shares. It navigates in both
                // views now, where before the front view had no navigation at
                // all and the fly view needed Shift to pan.
                if Self.isOptionDown {
                    navigate(delta: delta,
                             fingers: Self.isShiftDown ? 2 : 1,
                             viewHeight: viewHeight)
                    return
                }

                // THE SAME LAW THE GLASS FOLLOWS. On iPad a one-finger drag is
                // a tool where there is something to work on and navigation
                // everywhere else; a Mac has no touch types to sort, but the
                // rule is just as good there — and it is why Scene felt poorer
                // on the Mac. Empty canvas navigates, in both views.
                if pointerNavigates == nil {
                    pointerNavigates = !toolClaims(value.startLocation,
                                                   pixelSize: pixelSize, fitted: fitted)
                }
                if pointerNavigates == true {
                    navigate(delta: delta, fingers: 1, viewHeight: viewHeight)
                    return
                }

                if isFlying {
                    // Flying, on something: the handles took it, or there is
                    // nothing else a drag can mean up here.
                    navigate(delta: delta, fingers: 1, viewHeight: viewHeight)
                    return
                }

                if layerDrag == nil, surfaceToolStart == nil {
                    surfaceToolStart = value.startLocation
                    beginCardDrag(at: value.startLocation, pixelSize: pixelSize, fitted: fitted)
                    return
                }

                if Self.isShiftDown, let drag = layerDrag, drag.pushedUndo,
                   let layer = composition.layer(drag.layerID) {
                    // Depth: dragging up pushes the card away. Scaled to the
                    // card's distance so the gesture feels the same near and far.
                    let shot = sceneManager.sceneCamera(for: composition, atFrame: frame)
                    let distance = max(drag.startZ - shot.positionZ, 1)
                    let dz = -Float(value.translation.height) / max(viewHeight, 1) * distance * 2
                    let z = max(drag.startZ + dz, shot.positionZ + shot.nearZ + 1)
                    sceneManager.updateSceneLayer(layer.id, in: composition.id, undoable: false) {
                        $0.positionZ = z
                    }
                    return
                }

                updateCardDrag(to: value.location, pixelSize: pixelSize, fitted: fitted)
            }
            .onEnded { value in
                if isFlying || Self.isOptionDown {
                    let moved = hypot(value.translation.width, value.translation.height)
                    if moved < 4, !Self.isOptionDown {
                        // The gesture's location is already a VIEW point, and
                        // `selectWhatever` wants one. Converting to image pixels
                        // and straight back would be two roundings for nothing.
                        selectWhatever(isAt: value.location,
                                       pixelSize: pixelSize, fitted: fitted)
                    }
                }
                dragAnchor = nil
                layerDrag = nil
                surfaceToolStart = nil
                pointerNavigates = nil
                lastPointerTranslation = .zero
            }
    }

    /// Magnify on a trackpad. Dollies the set, zooms the front view — the same
    /// two answers `pinch` gives a pair of fingers, and through the same
    /// function, so a Mac and an iPad cannot end up with different zooms.
    ///
    /// `MagnificationGesture` reports a CUMULATIVE scale, and `pinch` takes a
    /// step: the previous value is kept and divided out. Feeding the cumulative
    /// value in would zoom by the whole gesture on every event.
    private func dollyGesture(pixelSize: SIMD2<Float>, viewSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let previous = pinchAnchor ?? 1
                pinchAnchor = Float(value)
                let step = Float(value) / max(previous, 0.01)
                pinch(scale: CGFloat(step),
                      anchor: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2),
                      pixelSize: pixelSize, viewSize: viewSize)
            }
            .onEnded { _ in pinchAnchor = nil }
    }

    private static var isShiftDown: Bool {
        #if os(macOS)
        return NSEvent.modifierFlags.contains(.shift)
        #else
        return false
        #endif
    }

    private static var isOptionDown: Bool {
        #if os(macOS)
        return NSEvent.modifierFlags.contains(.option)
        #else
        return false
        #endif
    }
}
