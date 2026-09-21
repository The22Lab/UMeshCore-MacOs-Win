import Foundation
import simd

/// A scene: some layers at some depths, seen through a camera.
///
/// A project can hold several — a walk cycle staged three ways, or three shots
/// of one film — so they are a list with a selection, not a single slot bolted
/// onto the document. Retrofitting that later would mean touching persistence
/// twice.
struct SceneComposition: Identifiable, Equatable {
    let id: UUID
    var name: String
    /// The scene's cards. The ORDER OF THIS ARRAY IS NOT THE DRAW ORDER.
    ///
    /// It was, and it is worth recording the change of side rather than
    /// deleting the old rule. The list used to decide who covers whom, on the
    /// grounds that a list is what a compositor shuffles. The author overruled
    /// it: stacking is now a NUMBER on each layer, set in the inspector —
    /// `SceneLayer.sortingOrder` — because naming a layer's place is something
    /// you do once, while dragging rows is something you redo every time the
    /// set grows.
    ///
    /// What did NOT change is the part that rule was really protecting: DEPTH
    /// STILL DOES NOT REORDER ANYTHING. Pushing a card back in Z changes how big
    /// it draws and how fast it slides, and nothing about who covers whom.
    ///
    /// The array keeps one job: it breaks ties. Two cards on the same layer are
    /// drawn in the order they appear here, which is stable, is the order the
    /// artist created them in, and is something a Set could never provide.
    var layers: [SceneLayer]
    var camera: SceneCamera
    /// The set's lights, in the order they are applied.
    ///
    /// An ARRAY, and the order is the artist's. `multiply` and `screen` lights
    /// do not commute with the others, so "which light first" is a real
    /// question with a visible answer, and a Set would answer it differently on
    /// each launch — Swift seeds hashing per process.
    var lights: [SceneLight]
    /// The light that is there when nothing is pointed at something.
    ///
    /// Defaults to full white at strength 1, which multiplies by exactly one.
    /// A scene composed before lighting existed therefore renders through the
    /// same code and comes out identical — not nearly, identically, because
    /// `SceneLighting.isIdentity` skips the arithmetic entirely.
    var ambient: SceneAmbient
    /// Rendered behind every layer, so a scene is never composited onto nothing.
    var background: SceneFill
    var durationInFrames: Int
    var fps: Int
    /// Output size. Independent of the window: the shot is a fixed frame, and
    /// what the artist sees while flying around must not change what renders.
    var renderSize: SIMD2<Float>

    init(
        id: UUID = UUID(),
        name: String = "Scene",
        layers: [SceneLayer] = [],
        camera: SceneCamera = SceneCamera(),
        lights: [SceneLight] = [],
        ambient: SceneAmbient = .neutral,
        background: SceneFill = .neutral,
        durationInFrames: Int = 90,
        fps: Int = 30,
        renderSize: SIMD2<Float> = SIMD2<Float>(1920, 1080)
    ) {
        self.id = id
        self.name = name
        self.layers = layers
        self.camera = camera
        self.lights = lights
        self.ambient = ambient
        self.background = background
        self.durationInFrames = durationInFrames
        self.fps = fps
        self.renderSize = renderSize
    }

    func layer(_ id: UUID) -> SceneLayer? {
        layers.first { $0.id == id }
    }

    /// Every layer in DRAW ORDER: back first, front last.
    ///
    /// Sorted by `sortingOrder` ascending, ties broken by the array's own order.
    /// The tie-break is the whole reason this is a stable sort written out
    /// rather than `sorted(by:)` on the number alone — Swift's sort is not
    /// guaranteed stable, so two cards on one layer could swap between launches
    /// and an artist would see their set restack itself for no reason.
    var drawOrderedLayers: [SceneLayer] {
        layers.enumerated()
            .sorted {
                $0.element.sortingOrder != $1.element.sortingOrder
                    ? $0.element.sortingOrder < $1.element.sortingOrder
                    : $0.offset < $1.offset
            }
            .map(\.element)
    }

    /// The same order reversed: front-most first.
    ///
    /// What the hierarchy lists, because that is the convention the Editor's
    /// own hierarchy already uses — "top row = front-most" — and the two
    /// disagreeing about which end is the front is a bug this project has
    /// already shipped once.
    var frontToBackLayers: [SceneLayer] { drawOrderedLayers.reversed() }

    /// Layers in draw order, hidden ones dropped.
    var visibleLayers: [SceneLayer] {
        drawOrderedLayers.filter { !$0.isHidden && $0.opacity > 0.001 }
    }

    /// The number a new layer should take to land in front of everything.
    var frontSortingOrder: Int { (layers.map(\.sortingOrder).max() ?? -1) + 1 }

    func light(_ id: UUID) -> SceneLight? {
        lights.first { $0.id == id }
    }

    // NO `lighting` convenience here, deliberately. It existed for one commit
    // and it was a trap: it built a `SceneLighting` from the AUTHORED lights,
    // so any caller reaching for the obvious property would render a scene
    // whose light tracks did nothing. Lighting is asked for at a FRAME, from
    // `SceneManager.sceneLighting(for:atFrame:)`, and there is no shortcut
    // past the sampling.
}

/// Where the artist is looking from while building a scene.
///
/// Editor state, not scene data: it is saved with the project the way a window
/// position is, it is never keyframed, and it never reaches an export. The whole
/// point of free movement is to walk around the set — which is a different
/// question from where the shot is taken from, and the moment those two are the
/// same value the artist can no longer check their framing without destroying
/// it.
///
/// Stored as an orbit — a pivot, a distance and two angles — rather than as a
/// position and a look direction. Orbiting is the gesture that gets used most,
/// and deriving it from a free position each time accumulates drift; deriving a
/// position from an orbit does not.
/// Where the artist is looking in the FRONT view.
///
/// The front view had no navigation at all: the shot was scaled to fit and that
/// was that, so placing a card in a corner of the frame meant squinting at it.
/// This is a plain 2D pan and zoom over the rendered shot — it changes nothing
/// about the shot itself, which is why it lives here beside `SceneViewCamera`
/// as editor state and is never keyframed and never exported.
struct SceneFrontView: Equatable {
    /// View points, added to where the image would otherwise sit.
    var pan: SIMD2<Float> = .zero
    var zoom: Float = 1

    /// Far enough out to see a set laid wide, far enough in to place a card by
    /// its corner. Clamped because an unclamped zoom is a viewport nobody can
    /// get back to.
    static let minZoom: Float = 0.15
    static let maxZoom: Float = 12

    mutating func zoomBy(_ factor: Float) {
        zoom = min(max(zoom * factor, Self.minZoom), Self.maxZoom)
    }

    var isIdentity: Bool { pan == .zero && zoom == 1 }

    static let identity = SceneFrontView()
}

struct SceneViewCamera: Equatable {
    /// What the view turns around. `F` moves it to the selected layer.
    var pivot: SIMD3<Float>
    /// Distance from the pivot to the eye.
    var distance: Float
    /// Radians. Clamped away from straight up and straight down, because at
    /// exactly the pole the horizon spins on its own and there is no way back.
    var pitch: Float
    var yaw: Float
    var fieldOfView: Float

    static let pitchLimit: Float = 89 * .pi / 180
    static let minDistance: Float = 10
    static let maxDistance: Float = 500_000

    init(
        pivot: SIMD3<Float> = .zero,
        distance: Float = 1800,
        pitch: Float = 0,
        yaw: Float = 0,
        fieldOfView: Float = 45
    ) {
        self.pivot = pivot
        self.distance = distance
        self.pitch = pitch
        self.yaw = yaw
        self.fieldOfView = fieldOfView
    }

    /// Where the eye actually sits, derived from the orbit.
    var eye: SIMD3<Float> {
        let cp = cos(pitch), sp = sin(pitch)
        let cy = cos(yaw), sy = sin(yaw)
        // Looking along +Z, so backing away from the pivot means going -Z.
        let forward = SIMD3<Float>(sy * cp, -sp, cy * cp)
        return pivot - forward * distance
    }

    /// The camera this view is looking through, so the same projection can serve
    /// the fly view and the render camera without a second code path.
    func asSceneCamera(nearZ: Float, farZ: Float) -> SceneCamera {
        let e = eye
        return SceneCamera(
            position: SIMD2<Float>(e.x, e.y),
            positionZ: e.z,
            rotation3D: SIMD3<Float>(pitch, yaw, 0),
            fieldOfView: fieldOfView,
            nearZ: nearZ,
            farZ: farZ
        )
    }

    mutating func orbit(deltaYaw: Float, deltaPitch: Float) {
        yaw += deltaYaw
        pitch = min(max(pitch + deltaPitch, -Self.pitchLimit), Self.pitchLimit)
    }

    mutating func dolly(by factor: Float) {
        // Multiplicative, so the step shrinks as you approach and a scroll wheel
        // feels the same at every scale. Clamped so the eye can never cross the
        // pivot and turn the view inside out.
        distance = min(max(distance * factor, Self.minDistance), Self.maxDistance)
    }

    /// Move the pivot across the view plane, in world units per screen pixel.
    mutating func pan(screenDelta: SIMD2<Float>, viewHeight: Float) {
        let half = fieldOfView * .pi / 180 * 0.5
        let worldPerPixel = (2 * distance * tan(half)) / max(viewHeight, 1)
        let cy = cos(yaw), sy = sin(yaw)
        let right = SIMD3<Float>(cy, 0, -sy)
        let up = SIMD3<Float>(sy * sin(pitch), cos(pitch), cy * sin(pitch))
        pivot -= right * (screenDelta.x * worldPerPixel)
        pivot += up * (screenDelta.y * worldPerPixel)
    }
}
