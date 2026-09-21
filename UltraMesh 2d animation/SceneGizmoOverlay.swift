import SwiftUI
import simd

/// Which handles the Scene canvas is showing.
///
/// Four, and the same four the rig's toolbar offers, so the gesture an artist
/// learns on a sprite is the gesture that moves a card.
enum SceneGizmoTool: String, CaseIterable, Identifiable {
    case translate, rotate, scale, shear

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .translate: return "arrow.up.and.down.and.arrow.left.and.right"
        case .rotate:    return "arrow.triangle.2.circlepath"
        case .scale:     return "arrow.up.left.and.arrow.down.right"
        case .shear:     return "italic"
        }
    }

    var title: String { rawValue.capitalized }
}

/// What the handles are attached to.
enum SceneGizmoTarget: Equatable {
    case layer(UUID)
    /// A light. Same handles, same drag maths, same undo — a light is a Scene
    /// object, so it gets the gizmo Scene objects get rather than one of its
    /// own. What it adds is the handles a light HAS and a card does not:
    /// radius, cone angles, a direction to aim.
    case light(UUID)
    /// The shot camera. Only while flying: in the front view you are looking
    /// THROUGH it, so there is nothing on screen to put a handle on.
    case camera
}

/// The handles over the Scene canvas.
///
/// SwiftUI on top of the rendered image, not drawn into it. Three reasons, and
/// the first is the one that matters: the frame is cached on its inputs now, so
/// a gizmo drawn into the raster would re-rasterise the whole set every time
/// the pointer moved over a handle. The second is that hit-testing wants view
/// coordinates. The third is that a handle is editor chrome and must never
/// reach a file, which is a promise a separate layer keeps by construction.
struct SceneGizmoOverlay: View {

    let composition: SceneComposition
    let frame: Int
    let isFlying: Bool
    /// The rendered image's own pixel size, and where it sits in the view.
    /// Handles are measured in image pixels and drawn in view points, so the
    /// two have to be related explicitly.
    let pixelSize: SIMD2<Float>
    let fitted: CGRect
    let tool: SceneGizmoTool
    let target: SceneGizmoTarget

    let renderer: SceneFrameRenderer
    let sceneManager: SceneManager

    /// The handle under the pointer, or the one a drag is locked to.
    ///
    /// Passed in rather than held here: the overlay is rebuilt on every change
    /// to the composition, so state kept inside it would be state that
    /// sometimes survives and sometimes does not. The viewport owns it, sets it
    /// from `handle(at:)` as the pointer moves, and PINS it to the dragged
    /// handle for the length of a drag — which is what stops the highlight
    /// wandering to a neighbour mid-gesture while the drag itself stays locked.
    var highlighted: HandleID? = nil

    /// A lit handle is drawn thicker rather than in another colour, so the axis
    /// still says which axis it is. Two points over the resting two: enough to
    /// read at a glance, not enough to move the line under the pointer.
    static let litWidth: CGFloat = 4

    /// Handle length on screen. Constant, the way every 3D editor's is: a gizmo
    /// that shrank into the distance would be one you cannot grab exactly when
    /// the thing is hardest to reach.
    static let handlePixels: CGFloat = 78
    /// Below this an axis has no direction worth trusting — the card is turned
    /// edge-on — so its handle is not drawn and refuses the drag rather than
    /// dividing a pointer delta by almost nothing and throwing the card off the
    /// set.
    /// An axis drawn shorter than this is not drawn at all.
    ///
    /// It was 6, and the arrowhead is 12 long: between the two the head was
    /// longer than the shaft it caps, which is what "the arrowheads look
    /// deformed from some angles" is. An arrow needs to be an arrow, so the
    /// floor is the head plus a shaft worth seeing. Below it the axis is
    /// pointing at the eye, and the drag is refused rather than answered by
    /// dividing by almost nothing.
    static let minAxisPixels: CGFloat = 26
    /// How near the pointer has to be to grab one.
    static let grabPixels: CGFloat = 22

    // MARK: Light chrome
    //
    // VISUAL SIZE AND HIT SIZE ARE DIFFERENT NUMBERS, and they are named
    // separately here for the reason the rest of this editor already names
    // them separately: a dot big enough to hit comfortably with a finger is a
    // dot too big to sit politely on top of artwork. The drawn dot is small and
    // the hitbox around it is not.

    /// The drawn radius of a light's own handle dots.
    static let lightHandleVisualPx: CGFloat = 4.5
    /// How near the pointer has to be to take one.
    ///
    /// SMALLER than `grabPixels`, not larger. A light's handles sit close
    /// together — the two cone arcs meet the rim within a few pixels of each
    /// other at a narrow cone — and a generous radius on each is what makes a
    /// neighbouring handle steal the drag. The nearest handle wins inside this
    /// radius, so the number is the point at which "near enough" starts, not a
    /// claim on territory.
    static let lightGrabPx: CGFloat = 16
    /// And the same again for touch, where the pointer is a fingertip rather
    /// than a point. iPadOS only.
    static let lightGrabTouchPx: CGFloat = 24

    static var lightGrabRadius: CGFloat {
        #if os(iOS)
        return lightGrabTouchPx
        #else
        return lightGrabPx
        #endif
    }

    /// The influence ring, the cone and the beam are drawn at this width.
    /// One point, not two: this is a diagram over somebody's artwork, and it
    /// has to be readable without competing with it.
    static let lightChromeWidth: CGFloat = 1.4
    /// The order handles are tested in. Fixed, so a tie is broken the same way
    /// twice — see `beginDrag`.
    static let axisOrder: [HandleID] = [.axisX, .axisY, .axisZ]
    /// Drawn and tested BEFORE the axes, and in a fixed order for the same
    /// reason: a dictionary's order is seeded per process, and a gizmo that
    /// grabs a different handle on Tuesday is one nobody trusts.
    static let planeOrder: [HandleID] = [.planeXY, .planeXZ, .planeYZ]

    /// The two axes a plane handle is spanned by, and the normal it drags in.
    static func planeAxes(_ id: HandleID, basis: Basis) -> (SIMD3<Float>, SIMD3<Float>) {
        switch id {
        case .planeXY: return (basis.x, basis.y)
        case .planeXZ: return (basis.x, basis.z)
        default:       return (basis.y, basis.z)
        }
    }

    static func planeNormal(_ id: HandleID, basis: Basis) -> SIMD3<Float>? {
        switch id {
        case .planeXY: return basis.z
        case .planeXZ: return basis.y
        case .planeYZ: return basis.x
        default: return nil
        }
    }

    /// Where the plane quad sits along its two axes, as a fraction of the
    /// gizmo's scale, and how big it is. Off the origin so it never covers the
    /// free-move handle, and short so it never reaches the arrowheads.
    static let planeOffset: Float = 0.30
    static let planeSize: Float = 0.26
    /// How square-on a plane must be seen before its handle is offered. The
    /// cosine between the view direction and the plane's normal: below this the
    /// quad is a sliver to aim at AND the ray-plane intersection behind it is
    /// ill-conditioned, so it is withdrawn on the same fact that makes it
    /// useless rather than drawn and then failing under the finger.
    static let minPlaneFacing: Float = 0.25

    /// Input from outside, when something else owns the touches.
    ///
    /// On iPad only the UIKit surface can tell a finger from a Pencil, so it
    /// Which end of a touch this is. The surface speaks in these; the handles
    /// are moved directly, not through a value that waits for a redraw.
    enum ExternalPhase { case began, changed, ended }

    /// The drag in flight, owned by whoever the input arrives at.
    ///
    /// A BINDING, not this view's own state, and that is the fix for the lag.
    /// Input used to park in a `@State` value here: the touch surface wrote it,
    /// SwiftUI redrew — with the element still where it had been — and only
    /// then did an `onChange` fire and move it. Every frame drew the handles one
    /// step behind the thing they were attached to.
    ///
    /// Now the surface calls `beginDrag` and `applyDrag` itself, so the element
    /// moves inside the same callback that delivered the touch, before anything
    /// is drawn from it. macOS's own gesture writes the same binding.
    @Binding var drag: DragState?

    // MARK: - Axes

    /// One handle, as DRAWN: where it starts and ends in view points, and
    /// which way it runs on screen.
    ///
    /// Screen only, and nothing else. It used to carry `pixelsPerUnit` and
    /// `localLength` as well, which is how a screen measurement ended up
    /// answering a world question — every drag divided by that ratio, and the
    /// ratio is constant only under an affine projection. The drags read the
    /// world through `SceneProjection` now, so the presentation geometry and
    /// the interaction mathematics are separate things that no longer share a
    /// number.
    struct Axis {
        var origin: CGPoint
        var tip: CGPoint
        var direction: CGVector
    }

    struct DragState {
        var handle: HandleID
        var start: CGPoint
        var startLayer: SceneLayer?
        /// The light AS IT WAS when the drag began.
        ///
        /// Every drag is answered from the START state plus the total pointer
        /// movement, never from the last frame's result. Accumulating deltas
        /// drifts, and on a value with a clamp — a radius at zero, a cone at
        /// its limit — it also ratchets: push past the end and the value cannot
        /// come back, because the delta that would return it was already lost
        /// to the clamp.
        var startLight: SceneLight?
        var startCamera: SceneCamera?
        var axis: Axis?
    }

    /// The three axes serve twice: as arrows for translate, scale and shear,
    /// and as the RINGS that turn about them for rotate. One vocabulary, so a
    /// red handle means the x axis whatever tool is showing.
    enum HandleID: Hashable {
        case axisX, axisY, axisZ, free, uniform
        /// A light's own handle. Wrapped rather than flattened into cases here,
        /// so the light's geometry can grow a handle without this enum, the
        /// drawing and the hit test each needing a new case.
        case light(SceneLightGizmo.Handle)
        /// The three plane handles: a small quad in the corner between two
        /// axes, which drags within that plane. One ray-plane intersection is
        /// exact, where running the two axes side by side is two approximations
        /// added together.
        case planeXY, planeXZ, planeYZ
        /// Rotation about the axis you are looking along — the one turn no
        /// world axis matches, so the one handle that is honestly screen-space.
        case viewRing
    }

    var body: some View {
        ZStack {
            // THE LIGHT'S DIAGRAM ONLY. The manipulator itself — axes, rings,
            // planes — used to be drawn here too, by `Canvas`, and that is the
            // whole of why it lagged the picture during a trackpad gesture:
            // `Canvas` redraws on SwiftUI's own cadence, which the very same
            // gesture handling stalls (see `CanvasActivity.
            // drawIfDisplayLinkStalled()`), while the Metal picture underneath
            // gets force-redrawn by hand. `SceneMetalRenderer.encodeGizmoPass`
            // now draws the manipulator INSIDE that same forced draw call, from
            // `gizmoLayout()` below — built from the exact same
            // `handleSet()`-adjacent state, so it cannot disagree with the
            // hit-testing/drag code that stays here.
            //
            // A light's own diagram stays SwiftUI: it is chrome describing
            // what the light DOES, not a manipulator being actively dragged,
            // and the cost of it trailing one frame during a stalled gesture
            // reads very differently from a handle trailing the pointer.
            if let handles = handleSet(), let light = handles.light {
                Canvas { context, _ in drawLight(light, in: &context) }
                    .allowsHitTesting(false)
            }
        }
        // THE HANDLES, NOT THE VIEWPORT. This was `Rectangle()`, so the overlay
        // claimed every drag over the whole canvas — and on macOS that is the
        // drag that orbits the set. Zoom still worked, because magnification is
        // attached below; orbit and pan were swallowed before they ever reached
        // the viewport, which is exactly what "no permite voltear" describes.
        //
        // The shape is the handles themselves, fattened to the grab radius, so
        // a drag that starts on one is the gizmo's and a drag that starts
        // anywhere else falls through to navigation.
        .contentShape(grabShape())
        // Only where nothing else owns the touches. On iPad the surface does,
        // and two gesture systems on one view is how a handle and a camera end
        // up fighting over the same finger.
        .gesture(dragGesture, including: Self.usesOwnGesture ? .all : .subviews)
    }

    /// A Mac's pointer has no touch type to sort, so the overlay keeps its own
    /// gesture there. On iPad `SceneInputSurface` owns every touch and calls
    /// `beginDrag`/`applyDrag` directly — two gesture systems on one view is how
    /// a handle and a camera end up fighting over the same finger.
    static var usesOwnGesture: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// The area the handles actually occupy, fattened by the grab radius.
    ///
    /// Everything outside it belongs to whatever is underneath — which is the
    /// canvas, and the canvas is what orbits.
    private func grabShape() -> Path {
        var path = Path()
        guard let set = handleSet() else { return path }
        let r = Self.grabPixels
        switch tool {
        case .translate, .scale, .shear:
            for id in Self.axisOrder {
                guard let axis = set.axes[id] else { continue }
                var line = Path()
                line.move(to: axis.origin)
                line.addLine(to: axis.tip)
                path.addPath(line.strokedPath(.init(lineWidth: r * 2, lineCap: .round)))
            }
            path.addEllipse(in: CGRect(x: set.origin.x - r, y: set.origin.y - r,
                                       width: 2 * r, height: 2 * r))
            if tool == .translate {
                for id in Self.planeOrder {
                    guard let quad = set.planes[id], quad.count == 4 else { continue }
                    var q = Path()
                    q.move(to: quad[0])
                    for p in quad.dropFirst() { q.addLine(to: p) }
                    q.closeSubpath()
                    path.addPath(q)
                }
            }
        case .rotate:
            for id in Self.axisOrder {
                for arc in set.rings[id] ?? [] where arc.count >= 2 {
                    var ring = Path()
                    ring.move(to: arc[0])
                    for point in arc.dropFirst() { ring.addLine(to: point) }
                    path.addPath(ring.strokedPath(.init(lineWidth: r * 2, lineCap: .round)))
                }
            }
            var view = Path()
            let outer = set.ringRadius * Self.viewRingScale
            view.addEllipse(in: CGRect(x: set.origin.x - outer, y: set.origin.y - outer,
                                       width: 2 * outer, height: 2 * outer))
            path.addPath(view.strokedPath(.init(lineWidth: r * 2)))
        }
        return path
    }

    /// Whether a handle is grabbable at this point — what the touch surface
    /// asks before deciding a one-finger drag is navigation.
    func handle(at point: CGPoint) -> HandleID? {
        beginDragTarget(at: point)?.0
    }

    // MARK: - Geometry

    private var viewpoint: SceneFrameRenderer.Viewpoint {
        isFlying
            ? .fly(sceneManager.sceneViewCamera)
            : .shot(sceneManager.sceneCamera(for: composition, atFrame: frame))
    }

    private var activeLayer: SceneLayer? {
        guard case let .layer(id) = target else { return nil }
        return composition.layers.first { $0.id == id }
    }

    /// The light AS THE SHOT SEES IT at this frame — sampled, not authored.
    ///
    /// So the handles sit on the light the canvas is drawing. Reading the
    /// authored light instead would leave the gizmo behind whenever a light
    /// track moved it, which is the "gizmo separating from its object"
    /// complaint in its exact form.
    private var activeLight: SceneLight? {
        guard case let .light(id) = target else { return nil }
        return sceneManager.sceneLights(for: composition, atFrame: frame)
            .first { $0.id == id }
    }

    /// A light's three axes.
    ///
    /// Point lights get the WORLD axes: a point light has no orientation, and
    /// handles along an invented one would turn with nothing.
    ///
    /// Spots and directionals get a frame built on their BEAM: z is where they
    /// point, x and y across it. So translating a spot along z walks it up its
    /// own beam, and the rotate rings about x and y aim it — which is what an
    /// artist reaches for. There is no roll ring that does anything, and that is
    /// correct rather than missing: a cone is round, and a light stores where it
    /// points, not a full orientation.
    private func basis(for light: SceneLight) -> Basis {
        guard light.kind != .point else {
            return Basis(origin: light.world,
                         x: SIMD3<Float>(1, 0, 0),
                         y: SIMD3<Float>(0, 1, 0),
                         z: SIMD3<Float>(0, 0, 1))
        }
        let forward = light.direction
        let frame = Self.ringFrame(normal: forward)
        return Basis(origin: light.world, x: frame.u, y: frame.v, z: forward)
    }

    /// View points back to image pixels — the inverse of `toView`.
    ///
    /// Every world-space answer below starts from a pointer position, and the
    /// projection speaks the RENDERED IMAGE's pixels while the gesture speaks
    /// the view's points. Converting in one named place is what stops the two
    /// being mixed; doing it inline is how a drag ends up right on a Mac and
    /// wrong on a Retina iPad.
    private func toPixels(_ p: CGPoint) -> SIMD2<Float> {
        let sx = CGFloat(max(pixelSize.x, 1)) / max(fitted.width, 0.0001)
        let sy = CGFloat(max(pixelSize.y, 1)) / max(fitted.height, 0.0001)
        return SIMD2<Float>(Float((p.x - fitted.minX) * sx),
                            Float((p.y - fitted.minY) * sy))
    }

    /// The camera these handles are being drawn through.
    ///
    /// THE REAL ONE, and every drag reads it — `worldUnits`, `worldDelta`,
    /// `worldAngle` all take `self.projection` on their own, straight from
    /// here. `gizmoProjection(origin:real:viewSize:)` below builds a SECOND,
    /// stabilised projection purely for where axes/rings/planes fall on
    /// screen; it never reaches the drag math, so precision here is untouched.
    private var projection: SceneProjection {
        renderer.projection(viewpoint: viewpoint, pixelSize: pixelSize)
    }

    /// How wide the gizmo's OWN camera sees. Small — a few degrees, close to
    /// orthographic — because the whole point is that it barely matters where
    /// on screen the gizmo sits; every direction inside this cone looks nearly
    /// the same regardless of camera position.
    static let gizmoHalfFieldOfView: Float = 3 * .pi / 180

    /// A second, stabilised projection for the gizmo's SHAPE only: same eye as
    /// `real`, but pointed straight at `origin` with a narrow, fixed field of
    /// view, instead of inheriting the scene's own — often wide — one.
    ///
    /// WHY THE SHAPE NEEDS ITS OWN CAMERA. `orientation()` never reads
    /// position, so a ring's world direction cannot change when a layer moves
    /// — that part was never the bug. What DOES change is how oblique a wide
    /// perspective projection makes an off-centre object's local axes look:
    /// centred, a ring facing the camera reads as a near-circle; pushed to the
    /// edge of a wide FOV, the same ring can read as a thin, sharply tilted
    /// ellipse, which an artist reasonably reads as "the ring changed which
    /// axis it turns about" even though the maths never moved it. Recentring
    /// the projection on the gizmo's own origin removes that skew at its
    /// source — every axis is seen close to its own on-axis angle, the way it
    /// would be if the object sat at the middle of the frame — and the result
    /// is then slid back onto the object's true screen position as a rigid 2D
    /// offset that touches nothing about depth or foreshortening.
    ///
    /// The camera's OWN roll/horizon is preserved by re-orthogonalising its
    /// right/up against the new forward (Gram-Schmidt) rather than inventing a
    /// fresh pair — so recentring never visibly spins the gizmo, it only
    /// changes which way it is "squarely facing".
    private func gizmoProjection(origin: SIMD3<Float>, real: SceneProjection,
                                 viewSize: SIMD2<Float>) -> SceneProjection {
        var forward = origin - real.eye
        let length = simd_length(forward)
        // The eye sitting exactly on the origin has no direction to look
        // along — falls back to the real camera rather than dividing by zero.
        guard length > 1e-4 else { return real }
        forward /= length

        // The real camera's own right/up, read off its view matrix's rows —
        // a view matrix IS a basis in its rows by construction (see
        // `SceneProjection`'s orthonormal-frame initialiser).
        let view = real.viewMatrix
        var right = SIMD3<Float>(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        right -= forward * simd_dot(right, forward)
        if simd_length(right) < 1e-4 {
            // Looking almost straight along the real camera's own up (or
            // down): its right vector has nothing left once projected out of
            // `forward`. A world axis stands in — which one only matters in
            // that it be consistent, not which.
            right = abs(forward.y) < 0.9 ? simd_cross(SIMD3<Float>(0, 1, 0), forward)
                                          : simd_cross(SIMD3<Float>(1, 0, 0), forward)
        }
        right = simd_normalize(right)
        let up = simd_cross(forward, right)

        return SceneProjection(eye: real.eye, right: right, up: up, forward: forward,
                               focalLength: (viewSize.y * 0.5) / tan(Self.gizmoHalfFieldOfView),
                               nearZ: real.nearZ, farZ: 1_000_000, viewSize: viewSize)
    }

    /// Image pixels to view points.
    private func toView(_ p: SIMD2<Float>) -> CGPoint {
        let sx = fitted.width / CGFloat(max(pixelSize.x, 1))
        let sy = fitted.height / CGFloat(max(pixelSize.y, 1))
        return CGPoint(x: fitted.minX + CGFloat(p.x) * sx,
                       y: fitted.minY + CGFloat(p.y) * sy)
    }

    /// The target's three axes, as directions in WORLD space.
    ///
    /// This is what makes the handles turn with the camera the way Unity's do:
    /// every arrow, every ring and every plane handle is built from these and
    /// then projected, so orbiting foreshortens them, leans them, and turns the
    /// rings into ellipses — all of it for free, because it is what a real
    /// projection does to a real direction.
    ///
    /// A card's X and Y are its own plane axes, so a rotated or sheared card's
    /// handles lie along the card. Its Z is the card's normal. The camera's are
    /// the world's, because a camera has no card to lie in.
    struct Basis {
        var origin: SIMD3<Float>
        var x: SIMD3<Float>
        var y: SIMD3<Float>
        var z: SIMD3<Float>

        func direction(_ id: HandleID) -> SIMD3<Float>? {
            switch id {
            case .axisX: return x
            case .axisY: return y
            case .axisZ: return z
            default: return nil
            }
        }
    }

    private func basis(for layer: SceneLayer) -> Basis {
        // THE ELEMENT'S ROTATION, AND NOTHING ELSE. This used to difference the
        // card's own transform — `cardPoint(1,0) - cardPoint(0,0)` and the same
        // for y — which runs a point through `planePoint`: scale first, then
        // SHEAR, then roll. Normalising the results fixed their lengths and
        // could do nothing about the angle between them, so a sheared card
        // handed the gizmo a frame that was not a rotation, and a frame like
        // that shears every arrow it multiplies. That was the deformation.
        let axes = layer.orientation()
        return Basis(origin: layer.worldOrigin, x: axes.x, y: axes.y, z: axes.z)
    }

    /// The layer's MOVE axes, fixed to the world rather than to its own
    /// rotation.
    ///
    /// Rotate, scale and shear all want `basis(for:)` — that is the whole
    /// point of it, and the user confirms rotate reads correctly today. But
    /// it means the translate arrows visibly spin with the card's own Z roll
    /// and tilt, which is not what an artist reaching for "move" expects: the
    /// handle that answers "where is X" should not change answer because the
    /// card turned. So translate alone gets literal world axes, with the
    /// card's origin as the only thing carried over.
    private func worldBasis(for layer: SceneLayer) -> Basis {
        Basis(origin: layer.worldOrigin,
              x: SIMD3<Float>(1, 0, 0), y: SIMD3<Float>(0, 1, 0), z: SIMD3<Float>(0, 0, 1))
    }

    /// The one place "which basis does this tool draw and drag from" is
    /// decided for a layer. Both `handleSet()` (drawing/hit-testing) and
    /// `mutate(_:from:drag:point:)` (applying the drag) call this rather than
    /// each making the choice themselves, so the arrows on screen and the
    /// axes a drag moves along can never disagree.
    private func translateBasis(for layer: SceneLayer) -> Basis {
        tool == .translate ? worldBasis(for: layer) : basis(for: layer)
    }

    private func cameraBasis(_ camera: SceneCamera) -> Basis {
        Basis(origin: SIMD3<Float>(camera.position.x, camera.position.y, camera.positionZ),
              x: SIMD3<Float>(1, 0, 0), y: SIMD3<Float>(0, 1, 0), z: SIMD3<Float>(0, 0, 1))
    }

    /// The world length every axis of the gizmo is drawn at.
    ///
    /// ONE number, taken from the pivot's depth, so the whole manipulator is a
    /// constant size on screen and the arrow mesh is scaled UNIFORMLY. Each axis
    /// used to measure itself against the screen and take its own length, which
    /// gave one gizmo three differently sized arrows — and the more foreshortened
    /// an axis was, the longer its world length became, so its head grew as it
    /// turned away. Foreshortening is the projection's job; it is not the mesh's.
    private func gizmoScale(pivot: SIMD3<Float>,
                            projection: SceneProjection) -> Float? {
        let depth = projection.depth(of: pivot)
        return projection.worldLength(forPixels: Float(Self.handlePixels), atDepth: depth)
    }

    /// One axis of the gizmo: its local unit direction taken through the world
    /// transform and then the camera.
    ///
    /// The direction is the element's, the length is the gizmo's own uniform
    /// scale, and the projection is what shortens it when it points away. No
    /// part of the element's scale or shear is anywhere in this chain.
    private func worldAxis(_ direction: SIMD3<Float>, from origin: SIMD3<Float>,
                           scale: Float,
                           map: (SIMD3<Float>) -> SIMD2<Float>?) -> Axis? {
        guard let originPx = map(origin), let tipPx = map(origin + direction * scale)
        else { return nil }
        let o = toView(originPx)
        let tip = toView(tipPx)
        let span = hypot(tip.x - o.x, tip.y - o.y)
        guard span >= Self.minAxisPixels else { return nil }
        return Axis(origin: o, tip: tip,
                    direction: CGVector(dx: (tip.x - o.x) / span, dy: (tip.y - o.y) / span))
    }

    /// A circle in the plane whose normal is `normal`, projected — an ellipse
    /// once the camera is anywhere but square on to it, and a line when it is
    /// edge-on. That line is still where the artist grabs that axis, so it is
    /// drawn rather than hidden.
    /// The ring as ARCS, each cut where it crosses the near plane.
    ///
    /// It used to drop any sample that failed to project and join the survivors
    /// end to end, which closes the ring straight across the hole: one straight
    /// line drawn between two points 73 degrees apart on the circle, measured
    /// at an ordinary working distance in `verify_scene_gizmo_drag.py`. That is
    /// the malformed ring. It is the same fault the cards had, one dimension
    /// down — a primitive that straddles the plane patched over instead of cut
    /// to it.
    ///
    /// The huge step that remains where an arc ends is not a fault and is not
    /// smoothed away: a ring cut by the near plane really does sweep off the
    /// view, and drawing it as though it did not would be the lie.
    private func ringArcs(normal: SIMD3<Float>, origin: SIMD3<Float>, radius: Float,
                          projection: SceneProjection,
                          screenOffset: SIMD2<Float> = .zero) -> [[CGPoint]] {
        let frame = Self.ringFrame(normal: normal)
        func world(_ index: Int) -> SIMD3<Float> {
            let a = Float(index % Self.ringSamples) / Float(Self.ringSamples) * 2 * .pi
            return origin + (frame.u * cos(a) + frame.v * sin(a)) * radius
        }

        var arcs: [[CGPoint]] = []
        var current: [CGPoint] = []
        let near = projection.nearZ
        for i in 0..<Self.ringSamples {
            let w0 = world(i), w1 = world(i + 1)
            let d0 = projection.depth(of: w0), d1 = projection.depth(of: w1)
            if d0 >= near, let p = projection.project(w0) {
                current.append(toView(p + screenOffset))
            }
            guard (d0 >= near) != (d1 >= near) else { continue }
            // The crossing itself, nudged a hair towards the far side so the
            // projection's own `w > nearZ` guard — which is strict — still
            // answers for a point that is exactly on the plane.
            let t = (near - d0) / (d1 - d0)
            let cut = w0 + (w1 - w0) * t
            let toward = simd_normalize(cut - projection.eye)
            if let p = projection.project(cut + toward * Self.nearNudge) {
                current.append(toView(p + screenOffset))
            }
            if current.count >= 2 { arcs.append(current) }
            current = []
        }
        if current.count >= 2 { arcs.append(current) }

        // Wholly in front: one closed ring, which is the ordinary case and has
        // to stay closed.
        if arcs.count == 1 && arcs[0].count == Self.ringSamples {
            return arcs
        }
        return arcs
    }

    /// How far past the near plane a cut point is pushed so a strict `>` guard
    /// still answers for it. A hair, in world units scaled by nothing: the
    /// plane is at 1 unit and this is four orders below it.
    static let nearNudge: Float = 0.0001

    /// How solid an axis is drawn: the one coming toward the viewer is full
    /// strength, the one going away is held back. Unity's depth cue, and the
    /// reason a gizmo reads as an object in space rather than a decal.
    ///
    /// Dimmed, never hidden — an axis you cannot see is an axis you cannot use,
    /// and half the camera angles would lose one.
    private func depthAlpha(_ direction: SIMD3<Float>, from origin: SIMD3<Float>,
                            depthOf: (SIMD3<Float>) -> Float) -> Double {
        depthOf(origin + direction) <= depthOf(origin) ? 1.0 : Self.awayAlpha
    }

    static let awayAlpha: Double = 0.45
    static let ringSamples = 64

    struct HandleSet {
        var origin: CGPoint
        var axes: [HandleID: Axis]
        var ringRadius: CGFloat
        /// Each axis's ring, already projected — an ellipse, or a line when the
        /// camera is edge-on to it. ARCS, plural, because the near plane can
        /// cut a ring into pieces and they must not be joined back up.
        var rings: [HandleID: [[CGPoint]]]
        /// Each plane handle's quad, projected. Empty when the plane is turned
        /// too far edge-on to be worth offering.
        var planes: [HandleID: [CGPoint]]
        /// How solid each axis is drawn: the one coming toward the viewer is
        /// full strength.
        var alpha: [HandleID: Double]
        /// A light's own handles, and the shapes that show what it does.
        ///
        /// Empty for anything that is not a light, so every existing caller is
        /// untouched — the arrows, rings and planes above are the same set of
        /// numbers they always were.
        var light: LightHandles?
    }

    /// A light's visualisation and its grabbable points, already projected.
    ///
    /// EVERYTHING HERE IS EDITOR CHROME. It is built in this overlay, which is
    /// SwiftUI drawn on top of the rendered image; the renderer never sees it
    /// and an export cannot contain it. That is a promise kept by construction
    /// rather than by a flag somebody has to remember to check.
    struct LightHandles {
        /// The light itself, projected. Nil when it is behind the eye, where it
        /// has no honest position and nothing should be drawn at one.
        var centre: CGPoint?
        /// The outer edge of the light's influence.
        var influence: [CGPoint]
        /// Where the fade begins. Absent when softness is 1 and it would sit on
        /// the light itself.
        var inner: [CGPoint]
        /// The beam axis, from the light to the far end.
        var beam: (CGPoint, CGPoint)?
        /// The cone's two edges and the arcs across them.
        var outerEdges: [(CGPoint, CGPoint)]
        var innerEdges: [(CGPoint, CGPoint)]
        var outerArc: [CGPoint]
        var innerArc: [CGPoint]
        /// Where each grabbable point landed.
        var points: [SceneLightGizmo.Handle: CGPoint]
        var kind: SceneLightKind
        var colour: Color
        var isEnabled: Bool
    }

    /// Everything the gizmo looks like THIS pass, before any drawing or hit
    /// testing happens: which basis is in play, the one uniform scale, the
    /// real projection, and the gizmo's own stabilised projection plus the
    /// screen offset that slides it back onto the object's true position.
    ///
    /// `handleSet()` (CPU: hit-testing, and the light diagram's own numbers)
    /// and `gizmoLayout()` (the GPU's input) both start from EXACTLY this and
    /// nowhere else — there is one place "what does the gizmo look like right
    /// now" gets answered, so the shape a drag is measured against and the
    /// shape the GPU draws cannot disagree.
    private struct GizmoState {
        var basis: Basis
        var scale: Float
        var realProjection: SceneProjection
        /// Stabilised: same eye, recentred on `basis.origin`, narrow FOV.
        /// Shape only — never read by drag math.
        var projection: SceneProjection
        var screenOffsetPx: SIMD2<Float>

        func map(_ world: SIMD3<Float>) -> SIMD2<Float>? {
            projection.project(world).map { $0 + screenOffsetPx }
        }
    }

    private func gizmoState() -> GizmoState? {
        let basis: Basis
        switch target {
        case .layer:
            guard let layer = activeLayer, !layer.isHidden else { return nil }
            basis = translateBasis(for: layer)
        case .light:
            // A DISABLED light still gets its handles. Switching one off is how
            // an artist compares two lightings, and a light you cannot move
            // while it is off is one you have to switch on to place — which
            // changes the very thing you were comparing.
            guard let light = activeLight else { return nil }
            basis = self.basis(for: light)
        case .camera:
            // Only while flying: handles for the eye you are looking through
            // point at nothing.
            guard isFlying else { return nil }
            basis = cameraBasis(sceneManager.sceneCamera(for: composition, atFrame: frame))
        }

        // THE CURRENT TRANSFORM, THIS PASS. Everything below is derived from
        // `basis` — which was just read off the element — and from the camera
        // as it is now. Nothing is carried over from the last frame, so the
        // handles cannot trail what they are attached to.
        let realProjection = renderer.projection(viewpoint: viewpoint, pixelSize: pixelSize)
        guard let realOriginPx = realProjection.project(basis.origin) else { return nil }

        // THE GIZMO'S OWN CAMERA, for shape only. Recentred on `basis.origin`
        // with a narrow fixed FOV, so the axes/rings/planes below are built
        // as though the object sat at the middle of a near-orthographic
        // frame — no wide-FOV skew — and then sit back down on the object's
        // true screen position by a rigid 2D offset. `eye` is identical to
        // `realProjection`'s, so anything reading `.eye` reads the same point
        // either way.
        let projection = gizmoProjection(origin: basis.origin, real: realProjection,
                                         viewSize: pixelSize)
        // Where `forward` (the gizmo camera's principal axis) always lands —
        // dead centre — versus where the object actually is on screen.
        let screenOffsetPx = realOriginPx - pixelSize * 0.5

        // ONE scale for the whole manipulator, from the REAL pivot depth —
        // the gizmo's own narrow FOV must not change the constant on-screen
        // size the artist relies on to grab a handle.
        guard let scale = gizmoScale(pivot: basis.origin, projection: realProjection),
              scale > 0 else { return nil }

        return GizmoState(basis: basis, scale: scale, realProjection: realProjection,
                          projection: projection, screenOffsetPx: screenOffsetPx)
    }

    private func handleSet() -> HandleSet? {
        guard let state = gizmoState() else { return nil }
        let basis = state.basis
        let realProjection = state.realProjection
        let projection = state.projection
        let screenOffsetPx = state.screenOffsetPx
        let scale = state.scale
        let map = state.map

        guard let originPx = map(basis.origin) else { return nil }
        let origin = toView(originPx)

        var axes: [HandleID: Axis] = [:]
        var rings: [HandleID: [[CGPoint]]] = [:]
        var planes: [HandleID: [CGPoint]] = [:]
        var alpha: [HandleID: Double] = [:]

        for id in Self.axisOrder {
            guard let direction = basis.direction(id) else { continue }
            if let a = worldAxis(direction, from: basis.origin, scale: scale, map: map) {
                axes[id] = a
            }
            // Depth ordering reads off the REAL camera — "which end is nearer
            // the eye" does not need the gizmo's stabilised one to answer.
            alpha[id] = depthAlpha(direction, from: basis.origin,
                                   depthOf: { realProjection.depth(of: $0) })
            // The ring for an axis turns ABOUT that axis, so the axis is the
            // circle's normal.
            let arcs = ringArcs(normal: direction, origin: basis.origin,
                                radius: scale, projection: projection,
                                screenOffset: screenOffsetPx)
            if !arcs.isEmpty { rings[id] = arcs }
        }

        // The plane quads, in the corner between each pair of axes.
        for id in Self.planeOrder {
            guard let normal = Self.planeNormal(id, basis: basis) else { continue }
            // Turned too far edge-on and the quad is a sliver: there is nothing
            // to aim at, and the ray-plane intersection behind it becomes
            // ill-conditioned in the same breath. Offered or refused on the
            // same fact, rather than drawn and then failing when grabbed.
            let facing = abs(simd_dot(simd_normalize(basis.origin - realProjection.eye), normal))
            guard facing > Self.minPlaneFacing else { continue }
            let (a, b) = Self.planeAxes(id, basis: basis)
            let lo = Self.planeOffset * scale
            let hi = (Self.planeOffset + Self.planeSize) * scale
            let corners = [
                basis.origin + a * lo + b * lo, basis.origin + a * hi + b * lo,
                basis.origin + a * hi + b * hi, basis.origin + a * lo + b * hi,
            ]
            let screen = corners.compactMap { map($0) }
            if screen.count == 4 { planes[id] = screen.map(toView) }
        }

        // A light's OWN diagram — influence sphere, cone, beam — stays on the
        // real projection: it is not part of this pass's stabilisation, only
        // the shared axis/ring/plane manipulator is.
        let realMap: (SIMD3<Float>) -> SIMD2<Float>? = { realProjection.project($0) }

        return HandleSet(origin: origin, axes: axes, ringRadius: Self.handlePixels,
                         rings: rings, planes: planes, alpha: alpha,
                         light: activeLight.flatMap {
                             lightHandles($0, projection: realProjection, map: realMap)
                         })
    }

    // MARK: - GPU layout

    /// The gizmo, as `SceneMetalRenderer.encodeGizmoPass` needs it: world-space
    /// directions, colors and highlight state, plus the stabilised
    /// `viewProjection`/screen-offset pair to place them on screen — no
    /// `CGPoint`, no `Canvas`.
    ///
    /// Built from `gizmoState()`, the exact same starting point `handleSet()`
    /// uses, so the manipulator the GPU draws and the manipulator the pointer
    /// is tested against are the same shape by construction, not by two
    /// people agreeing to keep two functions in step.
    ///
    /// No parameter: `pixelSize` is this overlay's own stored property, the
    /// same one `gizmoState()` already reads through it — a second copy
    /// passed in by the caller would be a second number that could disagree
    /// with the one the hit-test half of this same instance is using.
    func gizmoLayout() -> SceneGizmoLayout? {
        guard let state = gizmoState() else { return nil }
        let basis = state.basis

        var axes: [HandleID: SceneGizmoLayout.AxisGeometry] = [:]
        var rings: [HandleID: SceneGizmoLayout.RingGeometry] = [:]
        var planes: [HandleID: SceneGizmoLayout.PlaneGeometry] = [:]

        // Only the handles this TOOL actually shows — a rotate ring built
        // while the translate tool is active would be extra vertices for a
        // handle nobody can grab right now, since `handle(at:)` never offers
        // it either.
        switch tool {
        case .translate, .scale, .shear:
            if tool == .translate {
                for id in Self.planeOrder {
                    guard let normal = Self.planeNormal(id, basis: basis) else { continue }
                    let facing = abs(simd_dot(simd_normalize(basis.origin - state.realProjection.eye),
                                              normal))
                    guard facing > Self.minPlaneFacing else { continue }
                    let (a, b) = Self.planeAxes(id, basis: basis)
                    planes[id] = SceneGizmoLayout.PlaneGeometry(
                        a: a, b: b, color: Self.axisColor(id),
                        highlighted: id == highlighted)
                }
            }
            for id in Self.axisOrder {
                guard let direction = basis.direction(id) else { continue }
                // Refused on the same fact the screen-space arrow already is —
                // an axis pointing at the eye has no honest direction to grab.
                guard worldAxis(direction, from: basis.origin, scale: state.scale,
                                map: state.map) != nil else { continue }
                let away = depthAlpha(direction, from: basis.origin,
                                      depthOf: { state.realProjection.depth(of: $0) })
                axes[id] = SceneGizmoLayout.AxisGeometry(
                    direction: direction, color: Self.axisColor(id),
                    highlighted: id == highlighted, awayAlpha: Float(away),
                    head: tool == .translate ? .arrow : .cube)
            }
        case .rotate:
            for id in Self.axisOrder {
                guard let direction = basis.direction(id) else { continue }
                let away = depthAlpha(direction, from: basis.origin,
                                      depthOf: { state.realProjection.depth(of: $0) })
                rings[id] = SceneGizmoLayout.RingGeometry(
                    normal: direction, color: Self.axisColor(id),
                    highlighted: id == highlighted, awayAlpha: Float(away))
            }
        }

        // THE FREE-MOVE / UNIFORM-SCALE HANDLE, at the origin — the white
        // square `draw(_:in:)` used to fill for exactly these two tools.
        let centerHandle: SceneGizmoLayout.CenterHandle? = (tool == .translate || tool == .scale)
            ? SceneGizmoLayout.CenterHandle(
                color: SIMD4<Float>(1, 1, 1, 1),
                highlighted: highlighted == .free || highlighted == .uniform)
            : nil

        return SceneGizmoLayout(
            tool: tool,
            origin: basis.origin,
            scale: state.scale,
            axes: axes, rings: rings, planes: planes,
            showViewRing: tool == .rotate,
            viewRingColor: SIMD4<Float>(1, 1, 1, 0.75),
            centerHandle: centerHandle,
            eye: state.realProjection.eye,
            // Safe to normalise unconditionally: `gizmoState()` only reaches
            // here after `realProjection.project(basis.origin)` succeeded,
            // which requires the point to be meaningfully in front of the eye
            // (`w > nearZ > 0`) — so `basis.origin` and the eye cannot coincide.
            forward: simd_normalize(basis.origin - state.realProjection.eye),
            viewProjection: state.projection.viewProjection,
            screenOffsetNDC: SIMD2<Float>(
                2 * state.screenOffsetPx.x / pixelSize.x,
                -2 * state.screenOffsetPx.y / pixelSize.y))
    }

    /// A light's visualisation, projected through the camera the canvas used.
    ///
    /// Every point starts as a WORLD point from `SceneLightGizmo` and goes
    /// through the same `project` the cards went through, so the circle leans
    /// into an ellipse when the camera turns and the cone foreshortens, for
    /// free. Nothing here is drawn in screen space and then hoped to line up.
    private func lightHandles(_ light: SceneLight,
                              projection: SceneProjection,
                              map: (SIMD3<Float>) -> SIMD2<Float>?) -> LightHandles? {
        let centre = light.world
        let frame = SceneLightGizmo.facingFrame(projection)
        func view(_ world: SIMD3<Float>) -> CGPoint? { map(world).map(toView) }
        func polyline(_ worlds: [SIMD3<Float>]) -> [CGPoint] { worlds.compactMap(view) }

        // The beam is drawn a fixed number of PIXELS long for a directional
        // light, which has no radius to borrow, and to the rim for the others —
        // so a spot's aim handle sits where its light actually stops.
        let beamWorld: Float
        if light.kind == .directional {
            let depth = projection.depth(of: centre)
            beamWorld = projection.worldLength(forPixels: Float(Self.handlePixels),
                                               atDepth: depth) ?? 0
        } else {
            beamWorld = light.radius
        }

        var influence: [CGPoint] = []
        var inner: [CGPoint] = []
        if light.kind.isPositional, light.radius > 0 {
            influence = polyline(SceneLightGizmo.ring(centre: centre, radius: light.radius,
                                                      frame: frame, samples: Self.ringSamples))
            if light.innerRadius > light.radius * 0.02 {
                inner = polyline(SceneLightGizmo.ring(centre: centre, radius: light.innerRadius,
                                                      frame: frame, samples: Self.ringSamples))
            }
        }

        var beam: (CGPoint, CGPoint)?
        if light.kind != .point, beamWorld > 0,
           let a = view(centre), let b = view(centre + light.direction * beamWorld) {
            beam = (a, b)
        }

        var outerEdges: [(CGPoint, CGPoint)] = []
        var innerEdges: [(CGPoint, CGPoint)] = []
        var outerArc: [CGPoint] = []
        var innerArc: [CGPoint] = []
        if light.kind == .spot, light.radius > 0 {
            let across = SceneLightGizmo.conePlane(axis: light.direction, projection: projection)
            func edges(_ angle: Float) -> [(CGPoint, CGPoint)] {
                let rim = SceneLightGizmo.coneRim(centre: centre, axis: light.direction,
                                                  across: across, halfAngle: angle,
                                                  distance: light.radius)
                guard let o = view(centre) else { return [] }
                return [rim.0, rim.1].compactMap { view($0) }.map { (o, $0) }
            }
            outerEdges = edges(light.outerAngle)
            innerEdges = edges(light.innerAngle)
            outerArc = polyline(SceneLightGizmo.coneArc(
                centre: centre, axis: light.direction, across: across,
                halfAngle: light.outerAngle, distance: light.radius))
            innerArc = polyline(SceneLightGizmo.coneArc(
                centre: centre, axis: light.direction, across: across,
                halfAngle: light.innerAngle, distance: light.radius))
        }

        var points: [SceneLightGizmo.Handle: CGPoint] = [:]
        for handle in SceneLightGizmo.handles(for: light.kind) {
            guard let world = SceneLightGizmo.position(handle, light: light,
                                                       projection: projection,
                                                       directionLength: beamWorld),
                  let p = view(world) else { continue }
            points[handle] = p
        }

        return LightHandles(
            centre: view(centre),
            influence: influence, inner: inner, beam: beam,
            outerEdges: outerEdges, innerEdges: innerEdges,
            outerArc: outerArc, innerArc: innerArc,
            points: points, kind: light.kind,
            colour: Color(red: Double(light.color.x), green: Double(light.color.y),
                          blue: Double(light.color.z)),
            isEnabled: light.isEnabled)
    }

    // MARK: - Colour

    /// X red, Y green, Z blue — the convention every 3D editor shares, so the
    /// axis an artist already knows is the axis they get.
    ///
    /// RGBA FLOATS, NOT A SWIFTUI `Color`. The only consumer left is
    /// `gizmoLayout()`, which hands these straight to the GPU as
    /// vertex colour — going through `Color` and back would mean trusting a
    /// colour-space round trip neither side needs, for a set of constants
    /// that are already exactly the numbers the fragment shader wants.
    static func axisColor(_ id: HandleID) -> SIMD4<Float> {
        switch id {
        case .axisX: return SIMD4<Float>(0.94, 0.33, 0.35, 1)
        case .axisY: return SIMD4<Float>(0.44, 0.83, 0.36, 1)
        case .axisZ:         return SIMD4<Float>(0.35, 0.58, 0.98, 1)
        // A plane takes the colour of the axis it is NORMAL to, which is the
        // convention every 3D editor shares: the blue quad is the one that
        // keeps Z fixed.
        case .planeXY:       return SIMD4<Float>(0.35, 0.58, 0.98, 1)
        case .planeXZ:       return SIMD4<Float>(0.44, 0.83, 0.36, 1)
        case .planeYZ:       return SIMD4<Float>(0.94, 0.33, 0.35, 1)
        default:             return SIMD4<Float>(0.98, 0.82, 0.30, 1)
        }
    }

    /// The screen-facing ring sits outside the three world rings so the two
    /// kinds never overlap and a drag is never ambiguous.
    static let viewRingScale: CGFloat = 1.28

    // MARK: - The light's diagram

    /// What the light does, drawn over the canvas.
    ///
    /// TINTED WITH THE LIGHT'S OWN COLOUR, at low opacity. It is how you tell
    /// two lights apart at a glance without reading a label, and it is why the
    /// chrome does not use the gizmo's axis colours: those mean X, Y and Z, and
    /// a ring that borrowed one would be claiming to be an axis.
    ///
    /// A disabled light is drawn in grey. Present, placeable, visibly off.
    private func drawLight(_ light: LightHandles, in context: inout GraphicsContext) {
        let tint = light.isEnabled ? light.colour : Color.white
        let strong = tint.opacity(light.isEnabled ? 0.95 : 0.45)
        let soft = tint.opacity(light.isEnabled ? 0.45 : 0.2)
        let faint = tint.opacity(light.isEnabled ? 0.22 : 0.12)

        func stroke(_ points: [CGPoint], _ colour: Color, _ width: CGFloat,
                    dash: [CGFloat] = []) {
            guard points.count >= 2 else { return }
            var path = Path()
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
            context.stroke(path, with: .color(colour),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
        }

        // The band between the inner edge and the rim is where the light fades,
        // so the rim is drawn solid and the inner edge dashed: one is where the
        // light ends, the other is where it starts to go.
        stroke(light.influence, soft, Self.lightChromeWidth)
        stroke(light.inner, faint, Self.lightChromeWidth, dash: [4, 4])

        for edge in light.outerEdges { stroke([edge.0, edge.1], soft, Self.lightChromeWidth) }
        for edge in light.innerEdges {
            stroke([edge.0, edge.1], faint, Self.lightChromeWidth, dash: [4, 4])
        }
        stroke(light.outerArc, soft, Self.lightChromeWidth)
        stroke(light.innerArc, faint, Self.lightChromeWidth, dash: [4, 4])

        if let beam = light.beam {
            stroke([beam.0, beam.1], strong, Self.lightChromeWidth)
            // An arrowhead, so the beam reads as a direction rather than a
            // radius that happens to be drawn as a line.
            let dx = beam.1.x - beam.0.x, dy = beam.1.y - beam.0.y
            let length = hypot(dx, dy)
            if length > 1 {
                let ux = dx / length, uy = dy / length
                let back = CGPoint(x: beam.1.x - ux * 11, y: beam.1.y - uy * 11)
                var head = Path()
                head.move(to: beam.1)
                head.addLine(to: CGPoint(x: back.x - uy * 4.5, y: back.y + ux * 4.5))
                head.addLine(to: CGPoint(x: back.x + uy * 4.5, y: back.y - ux * 4.5))
                head.closeSubpath()
                context.fill(head, with: .color(strong))
            }
        }

        // The light itself: a small filled disc in its own colour inside a ring,
        // which is the shape every compositor uses for a light and which reads
        // on pale artwork and on dark. Drawn LAST of the chrome so the cone's
        // edges, which all meet here, pass behind it rather than through it.
        if let centre = light.centre {
            let outer: CGFloat = 7
            let halo = Path(ellipseIn: CGRect(x: centre.x - outer, y: centre.y - outer,
                                              width: 2 * outer, height: 2 * outer))
            context.stroke(halo, with: .color(strong), lineWidth: 1.6)
            let core: CGFloat = 3
            context.fill(Path(ellipseIn: CGRect(x: centre.x - core, y: centre.y - core,
                                                width: 2 * core, height: 2 * core)),
                         with: .color(strong))
            // Four short rays, so a light reads as a light and not as a
            // selection dot. Directional lights get none: they have a beam
            // arrow already saying which way they point, and rays would say
            // "radiates from here", which is the one thing they do not do.
            if light.kind != .directional {
                for step in 0..<4 {
                    let a = Double(step) * .pi / 2 + .pi / 4
                    let dx = CGFloat(cos(a)), dy = CGFloat(sin(a))
                    var ray = Path()
                    ray.move(to: CGPoint(x: centre.x + dx * 9.5, y: centre.y + dy * 9.5))
                    ray.addLine(to: CGPoint(x: centre.x + dx * 13, y: centre.y + dy * 13))
                    context.stroke(ray, with: .color(soft), lineWidth: 1.6)
                }
            }
        }

        for handle in SceneLightGizmo.handles(for: light.kind) {
            guard let p = light.points[handle] else { continue }
            let lit = highlighted == .light(handle)
            let r = Self.lightHandleVisualPx + (lit ? 1.5 : 0)
            let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            context.fill(dot, with: .color(lit ? strong : tint.opacity(0.85)))
            context.stroke(dot, with: .color(.black.opacity(0.55)), lineWidth: 1.2)
        }
    }

    // MARK: - Dragging

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil { drag = beginDrag(at: value.startLocation) }
                guard let drag else { return }
                applyDrag(drag, to: value.location)
            }
            .onEnded { _ in drag = nil }
    }

    /// Start a drag at this point, or nil when no handle is there. Callable
    /// from the touch surface, which applies it in the same pass.
    func beginDrag(at point: CGPoint) -> DragState? {
        guard let (id, axis) = beginDragTarget(at: point) else { return nil }
        sceneManager.pushUndoState()
        return DragState(handle: id, start: point,
                         startLayer: activeLayer,
                         startLight: activeLight,
                         startCamera: target == .camera
                             ? sceneManager.sceneCamera(for: composition, atFrame: frame)
                             : nil,
                         axis: axis)
    }

    /// Which handle a point grabs, and the axis it belongs to. No side effects:
    /// the touch surface asks this to decide whether a finger is a tool or
    /// navigation, long before any undo state is pushed.
    private func beginDragTarget(at point: CGPoint) -> (HandleID, Axis?)? {
        guard let set = handleSet() else { return nil }

        func nearest() -> (HandleID, Axis?)? {
            var best: (HandleID, Axis?, CGFloat)?

            // A LIGHT'S OWN HANDLES FIRST, and by NEAREST rather than by first
            // match. They are dots, they sit close together — at a narrow cone
            // the two arc handles meet the rim within a few pixels of each
            // other — and taking the first one within range would mean the
            // order of the list decided which of two adjacent handles you got.
            //
            // They are also tested before the axes, so a dot sitting on top of
            // an arrow is the thing you grab. The arrow is 78 px long and easy
            // to find elsewhere; the dot is 4.5 px and is the only place that
            // value can be changed.
            if let light = set.light {
                var nearestLight: (SceneLightGizmo.Handle, CGFloat)?
                for handle in SceneLightGizmo.handles(for: light.kind) {
                    guard let p = light.points[handle] else { continue }
                    let d = hypot(point.x - p.x, point.y - p.y)
                    guard d <= Self.lightGrabRadius else { continue }
                    if nearestLight == nil || d < nearestLight!.1 {
                        nearestLight = (handle, d)
                    }
                }
                if let hit = nearestLight { return (.light(hit.0), nil) }
            }

            switch tool {
            case .translate, .scale, .shear:
                // Planes first and at a smaller radius than the axes: a quad is
                // an area, so being INSIDE it is the test, and a plane that
                // also happens to be near an arrow should not steal it.
                if tool == .translate {
                    for id in Self.planeOrder {
                        guard let quad = set.planes[id], quad.count == 4 else { continue }
                        if Self.contains(quad, point) { return (id, nil) }
                    }
                }
                // A FIXED order, not the dictionary's. Swift seeds hashing per
                // process, so two handles at exactly equal distance would be
                // resolved by the launch — and a gizmo that grabs a different
                // axis on Tuesday is a gizmo nobody trusts.
                for id in Self.axisOrder {
                    guard let axis = set.axes[id] else { continue }
                    let d = distance(point, toSegment: axis.origin, axis.tip)
                    if d <= Self.grabPixels, best == nil || d < best!.2 {
                        best = (id, axis, d)
                    }
                }
                if tool != .shear {
                    let d = hypot(point.x - set.origin.x, point.y - set.origin.y)
                    if d <= Self.grabPixels, best == nil || d < best!.2 {
                        best = (tool == .scale ? .uniform : .free, nil, d)
                    }
                }
            case .rotate:
                // Nearest ring wins, and a ring is a polyline now, so the test
                // is a distance to the nearest of its segments — an ellipse
                // seen edge-on is a line, and a radial test around a circle
                // would never find it.
                for id in Self.axisOrder {
                    var nearest = CGFloat.greatestFiniteMagnitude
                    for arc in set.rings[id] ?? [] where arc.count >= 2 {
                        for i in 0..<(arc.count - 1) {
                            nearest = min(nearest, distance(point, toSegment: arc[i], arc[i + 1]))
                        }
                    }
                    if nearest <= Self.grabPixels, best == nil || nearest < best!.2 {
                        best = (id, nil, nearest)
                    }
                }
                let outer = set.ringRadius * Self.viewRingScale
                let radial = abs(hypot(point.x - set.origin.x, point.y - set.origin.y) - outer)
                if radial <= Self.grabPixels, best == nil || radial < best!.2 {
                    best = (.viewRing, nil, radial)
                }
            }
            guard let best else { return nil }
            return (best.0, best.1)
        }

        return nearest()
    }

    /// World units this drag asks for along a world axis.
    ///
    /// The closest approach of the pointer's ray to the axis LINE, at the start
    /// of the drag and now; the answer is the difference. That is a world
    /// distance, measured where the question lives.
    ///
    /// This replaces a screen-space measurement — the pointer delta projected
    /// onto the axis's screen direction, divided by a pixels-per-unit taken at
    /// the pivot. That ratio is constant only if the projection is affine, and
    /// under perspective it changes along the axis and with depth, so the card
    /// lagged when dragged away from the camera and overshot when dragged
    /// towards it. `verify_scene_gizmo_drag.py` measures the grabbed point
    /// ending up 313 px from the pointer at the worst of nine camera angles;
    /// through the ray it is 0.0000 px at all of them.
    ///
    /// Nil when the axis points straight at the eye — there is no honest answer
    /// there, and refusing is what the old `minAxisPixels` guard was reaching
    /// for by a different route.
    private func worldUnits(from start: CGPoint, to now: CGPoint,
                            origin: SIMD3<Float>, direction: SIMD3<Float>) -> Float? {
        let projection = self.projection
        guard let t0 = projection.axisParameter(screen: toPixels(start),
                                                origin: origin, direction: direction),
              let t1 = projection.axisParameter(screen: toPixels(now),
                                                origin: origin, direction: direction)
        else { return nil }
        return t1 - t0
    }

    /// Where a drag has moved a point, within a world PLANE through the pivot.
    ///
    /// A ray-plane intersection at both ends of the drag. Exact, and it is what
    /// makes a plane handle keep the grabbed point under the pointer instead of
    /// running two axis measurements at once and inheriting both their errors.
    private func worldDelta(from start: CGPoint, to now: CGPoint,
                            planeAt pivot: SIMD3<Float>, normal: SIMD3<Float>) -> SIMD3<Float>? {
        let projection = self.projection
        guard let a = projection.hit(screen: toPixels(start), plane: pivot, normal: normal),
              let b = projection.hit(screen: toPixels(now), plane: pivot, normal: normal)
        else { return nil }
        return b - a
    }

    /// The turn a drag asks for about a world axis, read IN THE RING'S OWN PLANE.
    ///
    /// The pointer's ray is met with the plane the ring lies in, and the angle
    /// is measured there, about the pivot, in the same `(u, v)` frame
    /// `ringPoints` drew the ring in — a different frame would offset every
    /// angle by a constant, which is invisible in a delta and wrong the moment
    /// anything reads an absolute.
    ///
    /// This replaces the screen angle swept about the gizmo's PROJECTED centre.
    /// That is the right angle only for the ring facing the camera: square on
    /// it is accurate to a degree, at a slant it is 39 degrees out on turns of
    /// 8 to 50, and near edge-on 104 — measured, at nine camera angles, in
    /// `verify_scene_gizmo_drag.py`. In the ring's plane the error is zero at
    /// every one of them.
    private func worldAngle(from start: CGPoint, to now: CGPoint,
                            pivot: SIMD3<Float>, normal: SIMD3<Float>) -> Float? {
        let projection = self.projection
        let frame = Self.ringFrame(normal: normal)
        guard let a = projection.hit(screen: toPixels(start), plane: pivot, normal: normal),
              let b = projection.hit(screen: toPixels(now), plane: pivot, normal: normal)
        else { return nil }
        func angle(_ point: SIMD3<Float>) -> Float {
            let d = point - pivot
            return atan2(simd_dot(d, frame.v), simd_dot(d, frame.u))
        }
        var delta = angle(b) - angle(a)
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }

    /// Two orthonormal vectors spanning the plane with this normal.
    ///
    /// Named once and used by both the drawing and the drag, so the ring the
    /// artist sees and the angle the drag reads are in the same frame.
    static func ringFrame(normal: SIMD3<Float>) -> (u: SIMD3<Float>, v: SIMD3<Float>) {
        let helper = abs(normal.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        var u = simd_cross(normal, helper)
        let length = simd_length(u)
        guard length > 0.00001 else { return (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)) }
        u /= length
        return (u, simd_cross(normal, u))
    }

    /// Move the element to where this drag now points. Writes the model
    /// immediately — there is no frame in between.
    func applyDrag(_ drag: DragState, to point: CGPoint) {
        switch target {
        case let .layer(layerID):
            guard let start = drag.startLayer else { return }
            sceneManager.updateSceneLayer(layerID, in: composition.id, undoable: false) { layer in
                mutate(&layer, from: start, drag: drag, point: point)
            }
        case let .light(lightID):
            guard let start = drag.startLight else { return }
            sceneManager.updateSceneLight(lightID, in: composition.id, undoable: false) { light in
                mutateLight(&light, from: start, drag: drag, point: point)
            }
        case .camera:
            guard let start = drag.startCamera else { return }
            sceneManager.updateSceneComposition(composition.id, undoable: false) { edited in
                var camera = start
                mutateCamera(&camera, from: start, drag: drag, point: point)
                edited.camera = camera
            }
        }
    }

    private func mutate(_ layer: inout SceneLayer, from start: SceneLayer,
                        drag: DragState, point: CGPoint) {
        switch tool {
        case .translate:
            switch drag.handle {
            case .axisX, .axisY, .axisZ:
                // The axis as a WORLD direction — fixed, per `translateBasis`,
                // not the card's own rotated frame. So `amount` is already a
                // literal world-space distance along a pure axis, and it is
                // assigned straight to the one field that axis is: no further
                // transform, because there is no rotation left to undo.
                let basis = translateBasis(for: start)
                guard let direction = basis.direction(drag.handle),
                      let amount = worldUnits(from: drag.start, to: point,
                                              origin: basis.origin, direction: direction)
                else { return }
                switch drag.handle {
                case .axisX: layer.position.x = start.position.x + amount
                case .axisY: layer.position.y = start.position.y + amount
                default:     layer.positionZ = start.positionZ + amount   // .axisZ
                }
            case .planeXY, .planeXZ, .planeYZ:
                // A plane handle is a ray meeting that plane — one exact
                // answer, not two axis measurements run side by side.
                let basis = translateBasis(for: start)
                guard let normal = Self.planeNormal(drag.handle, basis: basis),
                      let delta = worldDelta(from: drag.start, to: point,
                                             planeAt: basis.origin, normal: normal)
                else { return }
                // `a`/`b` are pure world axes now, so `da`/`db` are already
                // world-space deltas along X/Y/Z — assigned directly, the same
                // way the axis case above is.
                let (a, b) = Self.planeAxes(drag.handle, basis: basis)
                let da = simd_dot(delta, a), db = simd_dot(delta, b)
                switch drag.handle {
                case .planeXY:
                    layer.position += SIMD2<Float>(da, db)
                case .planeXZ:
                    layer.position.x = start.position.x + da
                    layer.positionZ = start.positionZ + db
                default:
                    layer.position.y = start.position.y + da
                    layer.positionZ = start.positionZ + db
                }
            case .free:
                // Free move slides the card across the WORLD XY plane through
                // its origin — the plane the screen-space free-move square
                // always meant, now that the basis is world axes rather than
                // the card's own tilted plane.
                let basis = translateBasis(for: start)
                guard let delta = worldDelta(from: drag.start, to: point,
                                             planeAt: basis.origin, normal: basis.z)
                else { return }
                layer.position = start.position + SIMD2<Float>(delta.x, delta.y)
            default: break
            }

        case .scale:
            // A ratio of distances from the origin, so the handle stays under
            // the pointer without any unit conversion at all.
            guard let set = handleSet() else { return }
            let startDist = max(hypot(drag.start.x - set.origin.x,
                                      drag.start.y - set.origin.y), 1)
            let nowDist = hypot(point.x - set.origin.x, point.y - set.origin.y)
            let factor = max(Float(nowDist / startDist), 0.01)
            switch drag.handle {
            case .axisX: layer.scale.x = max(start.scale.x * factor, 0.01)
            case .axisY: layer.scale.y = max(start.scale.y * factor, 0.01)
            case .uniform:
                layer.scale = simd_max(start.scale * factor, SIMD2<Float>(0.01, 0.01))
            default: break
            }

        case .shear:
            // The handle slides ACROSS its axis, and the slant is that offset
            // over the card's own extent — so dragging the handle by the card's
            // height is a shear of 1, whatever size the card is.
            //
            // Measured IN THE CARD'S PLANE, like every other drag here. It used
            // to take the screen offset across the axis and divide by a
            // pixels-per-unit read at the pivot, which is the same perspective
            // error the axis translate had: the slant ran ahead of the pointer
            // on the near side of a tilted card and behind it on the far side.
            let basis = self.basis(for: start)
            guard let rect = renderer.cardLocalRect(start, composition: composition, frame: frame),
                  let delta = worldDelta(from: drag.start, to: point,
                                         planeAt: basis.origin, normal: basis.z)
            else { return }
            let half = (rect.max - rect.min) * 0.5
            switch drag.handle {
            case .axisX:
                layer.shear.y = start.shear.y + simd_dot(delta, basis.y) / max(half.x, 0.001)
            case .axisY:
                layer.shear.x = start.shear.x - simd_dot(delta, basis.x) / max(half.y, 0.001)
            case .axisZ:
                // THE THIRD SLANT. A flat card has only two in-plane shears, so
                // the z handle does the thing the artist was actually missing:
                // it tips the card out of its plane. Dragging along the handle
                // pitches it, across it yaws — the same two turns the rotate
                // rings give, reachable from the tool where the card is being
                // slanted rather than by switching tools to reach them.
                //
                // Still measured in pixels, and deliberately: this is not a
                // slant with a geometric size, it is a rate — "how much tip per
                // how much drag" — so there is no world quantity for a ray to
                // find. Saying so beats dressing it up as geometry.
                guard let axis = drag.axis else { return }
                let dx = point.x - drag.start.x, dy = point.y - drag.start.y
                let along = Float(dx * axis.direction.dx + dy * axis.direction.dy)
                let across = Float(-dx * axis.direction.dy + dy * axis.direction.dx)
                layer.rotation3D.x = start.rotation3D.x + along * Self.radiansPerPixel
                layer.rotation3D.y = start.rotation3D.y + across * Self.radiansPerPixel
            default: break
            }

        case .rotate:
            let basis = self.basis(for: start)
            switch drag.handle {
            case .axisX, .axisY, .axisZ:
                // Read in the RING'S OWN PLANE, not as a screen angle about the
                // gizmo's projected centre. A screen angle is right only for the
                // ring facing the camera; at a slant the same sweep means a
                // bigger turn, and near edge-on a very much bigger one.
                guard let normal = basis.direction(drag.handle),
                      let turn = worldAngle(from: drag.start, to: point,
                                            pivot: basis.origin, normal: normal)
                else { return }
                switch drag.handle {
                // The card's own normal: turning about it is the card's roll.
                case .axisZ: layer.rotation = start.rotation + turn
                case .axisX: layer.rotation3D.x = start.rotation3D.x + turn
                default:     layer.rotation3D.y = start.rotation3D.y + turn
                }
            case .viewRing:
                // About the axis you are looking along. THIS one is honestly a
                // screen-space handle — its plane is the screen — so a screen
                // angle is not an approximation here, it is the definition.
                // For a card that turn is its roll, and it is the ring that
                // always works: the three world rings each vanish edge-on at
                // some angle.
                guard let set = handleSet() else { return }
                layer.rotation = start.rotation
                    + Self.angleDelta(from: drag.start, to: point, around: set.origin)
            default: break
            }
        }
    }

    // MARK: - Dragging a light

    /// What a drag does to a light.
    ///
    /// ALWAYS FROM `start`, never from the light's current value. The handles
    /// that end in a clamp — a radius at zero, a cone at half a turn — would
    /// otherwise ratchet: push a value past its limit and the delta that would
    /// bring it back was already swallowed by the clamp, so the light never
    /// comes home.
    private func mutateLight(_ light: inout SceneLight, from start: SceneLight,
                             drag: DragState, point: CGPoint) {
        let projection = self.projection
        let centre = start.world

        /// Where the pointer is, on the world plane through the light that
        /// faces the camera. Every light handle is answered here, which is what
        /// keeps the grabbed point under the pointer at any camera angle.
        func facingHit() -> SIMD3<Float>? {
            projection.hit(screen: toPixels(point), plane: centre,
                           normal: SceneLightGizmo.viewAxis(projection))
        }

        if case let .light(handle) = drag.handle {
            switch handle {
            case .radius:
                guard let hit = facingHit() else { return }
                let radius = SceneLightGizmo.radius(forHit: hit, centre: centre)
                light.radius = radius
                // The BAND is what the artist was looking at, so it is what is
                // preserved. Softness is a fraction of the radius, so leaving
                // it alone would make the fade grow with the radius and the
                // light would change shape while being resized.
                if start.radius > 1e-5, radius > 1e-5 {
                    let band = start.radius * start.softness
                    light.softness = min(max(band / radius, 0), 1)
                }
            case .softness:
                guard let hit = facingHit() else { return }
                light.softness = SceneLightGizmo.softness(forHit: hit, centre: centre,
                                                          radius: start.radius)
            case .direction:
                guard let hit = facingHit() else { return }
                let aim = hit - centre
                guard simd_length(aim) > 1e-5 else { return }
                SceneLightGizmo.aim(&light, along: aim)
            case .innerAngle, .outerAngle:
                // In the CONE'S OWN PLANE, not the facing one: the angle being
                // read is the angle the arc was drawn at, and reading it
                // anywhere else would answer a different question.
                let across = SceneLightGizmo.conePlane(axis: start.direction,
                                                       projection: projection)
                let normal = simd_cross(start.direction, across)
                guard let hit = projection.hit(screen: toPixels(point),
                                               plane: centre, normal: normal),
                      let angle = SceneLightGizmo.halfAngle(forHit: hit, centre: centre,
                                                            axis: start.direction)
                else { return }
                if handle == .outerAngle {
                    light.outerAngle = min(max(angle, 0), .pi)
                    light.innerAngle = min(start.innerAngle, light.outerAngle)
                } else {
                    light.innerAngle = min(max(angle, 0), start.outerAngle)
                }
            }
            return
        }

        // The shared handles — the arrows and the rings — mean for a light what
        // they mean for a card, so they go through the same measurements.
        let basis = self.basis(for: start)
        switch tool {
        case .translate:
            switch drag.handle {
            case .axisX, .axisY, .axisZ:
                guard let direction = basis.direction(drag.handle),
                      let amount = worldUnits(from: drag.start, to: point,
                                              origin: basis.origin, direction: direction)
                else { return }
                let moved = centre + direction * amount
                light.position = SIMD2<Float>(moved.x, moved.y)
                light.positionZ = moved.z
            case .planeXY, .planeXZ, .planeYZ:
                guard let normal = Self.planeNormal(drag.handle, basis: basis),
                      let delta = worldDelta(from: drag.start, to: point,
                                             planeAt: basis.origin, normal: normal)
                else { return }
                let moved = centre + delta
                light.position = SIMD2<Float>(moved.x, moved.y)
                light.positionZ = moved.z
            case .free:
                // Across the plane the artist is looking at, which is the one
                // plane a pointer can specify a point in without a third number.
                guard let delta = worldDelta(from: drag.start, to: point,
                                             planeAt: basis.origin,
                                             normal: SceneLightGizmo.viewAxis(projection))
                else { return }
                let moved = centre + delta
                light.position = SIMD2<Float>(moved.x, moved.y)
                light.positionZ = moved.z
            default: break
            }
        case .rotate:
            // AIMING, not orienting. A light stores where it points, so a turn
            // is applied to its direction and re-expressed as azimuth and
            // elevation. A turn about the beam itself comes back as no change,
            // which is correct: a cone has nothing to roll.
            guard start.kind != .point else { return }
            switch drag.handle {
            case .axisX, .axisY, .axisZ:
                guard let axis = basis.direction(drag.handle),
                      let turn = worldAngle(from: drag.start, to: point,
                                            pivot: basis.origin, normal: axis)
                else { return }
                SceneLightGizmo.aim(&light, along: SceneLightGizmo.rotated(
                    start.direction, about: axis, by: turn))
            case .viewRing:
                guard let set = handleSet() else { return }
                let turn = Self.angleDelta(from: drag.start, to: point, around: set.origin)
                SceneLightGizmo.aim(&light, along: SceneLightGizmo.rotated(
                    start.direction, about: SceneLightGizmo.viewAxis(projection), by: turn))
            default: break
            }
        case .scale, .shear:
            // A light has no size to scale and no plane to slant. Its size IS
            // its radius and its cone, and those have handles of their own that
            // say what they change — which is why there is no scale here rather
            // than a factor nobody could state the meaning of.
            break
        }
    }

    private func mutateCamera(_ camera: inout SceneCamera, from start: SceneCamera,
                              drag: DragState, point: CGPoint) {
        switch tool {
        case .translate:
            // The camera's handles are the world's axes, and they go through
            // the same world-space measurement every other handle does.
            let basis = cameraBasis(start)
            guard let direction = basis.direction(drag.handle),
                  let amount = worldUnits(from: drag.start, to: point,
                                          origin: basis.origin, direction: direction)
            else { return }
            switch drag.handle {
            case .axisX: camera.position.x = start.position.x + amount
            case .axisY: camera.position.y = start.position.y + amount
            case .axisZ: camera.positionZ = start.positionZ + amount
            default: break
            }
        case .rotate:
            let basis = cameraBasis(start)
            switch drag.handle {
            case .axisX, .axisY, .axisZ:
                guard let normal = basis.direction(drag.handle),
                      let turn = worldAngle(from: drag.start, to: point,
                                            pivot: basis.origin, normal: normal)
                else { return }
                switch drag.handle {
                case .axisZ: camera.rotation3D.z = start.rotation3D.z + turn
                case .axisX: camera.rotation3D.x = start.rotation3D.x + turn
                default:     camera.rotation3D.y = start.rotation3D.y + turn
                }
            case .viewRing:
                guard let set = handleSet() else { return }
                camera.rotation3D.z = start.rotation3D.z
                    + Self.angleDelta(from: drag.start, to: point, around: set.origin)
            default: break
            }
        case .scale, .shear:
            // A camera has neither.
            break
        }
    }

    /// A quarter turn is a quarter turn, and crossing the -pi/pi seam is a small
    /// step rather than most of a turn the wrong way.
    static func angleDelta(from start: CGPoint, to now: CGPoint, around origin: CGPoint) -> Float {
        let a = atan2(start.y - origin.y, start.x - origin.x)
        let b = atan2(now.y - origin.y, now.x - origin.x)
        var d = Float(b - a)
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }

    static let radiansPerPixel: Float = 0.008

    /// Whether a point is inside a convex polygon — the test a plane handle
    /// wants, because a quad is an area and not a line to be near.
    static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var positive = 0, negative = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if cross > 0 { positive += 1 } else if cross < 0 { negative += 1 }
        }
        return positive == 0 || negative == 0
    }

    private func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let vx = b.x - a.x, vy = b.y - a.y
        let lengthSquared = vx * vx + vy * vy
        guard lengthSquared > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * vx + (p.y - a.y) * vy) / lengthSquared
        t = min(max(t, 0), 1)
        return hypot(p.x - (a.x + vx * t), p.y - (a.y + vy * t))
    }
}
