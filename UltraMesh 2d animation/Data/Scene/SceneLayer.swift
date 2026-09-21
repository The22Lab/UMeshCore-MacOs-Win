import Foundation
import simd

/// A flat fill — a sky, a fog bank, a colour card behind everything.
struct SceneFill: Equatable {
    var topColor: SIMD4<Float>
    var bottomColor: SIMD4<Float>

    /// True when both stops match, i.e. it is a plain colour rather than a ramp.
    var isFlat: Bool { topColor == bottomColor }

    /// A neutral grey ramp.
    ///
    /// It used to be a dark blue, and a blue ground is not neutral: every
    /// colour placed on the set was judged against a tint, and a warm plate
    /// read warmer than it is. Grey is the standard working ground for exactly
    /// that reason. Still a ramp rather than a flat fill, so an empty scene
    /// reads as a space with a floor rather than as a blank.
    static let neutral = SceneFill(
        topColor: SIMD4<Float>(0.34, 0.34, 0.34, 1),
        bottomColor: SIMD4<Float>(0.46, 0.46, 0.46, 1)
    )

    static func solid(_ color: SIMD4<Float>) -> SceneFill {
        SceneFill(topColor: color, bottomColor: color)
    }
}

/// What a Scene layer actually draws.
///
/// Deliberately closed. A Scene assembles work that already exists — it does not
/// author it — so there is no case here for "a mesh being edited" or "a bone
/// chain". Rigging stays in Editor and animation stays in Animator.
enum SceneLayerContent: Equatable {
    /// An instance of this project's rig, playing one of its clips.
    ///
    /// The same rig can appear more than once in a scene at different depths and
    /// different points in its clip — three birds from one bird rig. That is
    /// only possible because `AnimationClip.pose(for:basePose:frame:)` is a pure
    /// function of the frame, so a pose can be sampled without disturbing the
    /// scene the artist is editing.
    case rig(clipID: UUID, speed: Float, startFrame: Int, loops: Bool)

    /// A plain image: a backdrop, a foreground plate, a cloud bank.
    case plate(assetID: UUID)

    /// A colour or vertical ramp, for skies and fog without needing a PNG.
    case fill(SceneFill)

    /// Whether this is the atmosphere case, which the shot paints across the
    /// whole frame rather than as a card.
    var isFill: Bool {
        if case .fill = self { return true }
        return false
    }
}

/// One card in a Scene, at its own depth.
///
/// Every layer is FLAT: its Z is constant across the whole card, which is what
/// makes the perspective collapse to a single scale factor and what makes
/// parallax cost nothing. It is the After Effects model, and it is what the
/// artist asked for.
struct SceneLayer: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isHidden: Bool
    var opacity: Float

    var position: SIMD2<Float>
    /// Depth. Higher is further from the camera.
    var positionZ: Float
    /// Roll, in radians — the card spinning in its own plane.
    var rotation: Float
    /// Pitch and yaw tilt the card out of its plane; the z component is unused
    /// because `rotation` already carries roll. Kept as a SIMD3 to match the
    /// convention `SceneImage.rotation3D` already established in the rig.
    var rotation3D: SIMD3<Float>
    var scale: SIMD2<Float>
    /// Slant, as a pair of tangents: x slides a point sideways by its height,
    /// y slides it vertically by its width. The same shape `SceneImage.skew`
    /// uses in the rig, so the number an artist learns in one place means the
    /// same in the other.
    var shear: SIMD2<Float>

    /// Which layer this card is drawn on. HIGHER IS NEARER THE FRONT.
    ///
    /// Assigned in the inspector, the way a compositor assigns one — so an
    /// artist says "the foreground is layer 30" once and every card they put
    /// there stacks correctly, instead of dragging rows into position.
    ///
    /// Nearer the front for higher numbers, which is the opposite of `positionZ`
    /// and deliberately so: Z is a distance, and things further away have more
    /// of it. A layer number is a stacking order, and every tool that has one —
    /// Photoshop, After Effects, Unity's Order in Layer — counts it upward
    /// towards the viewer. Matching Z here would have made the two numbers look
    /// interchangeable when they do the opposite.
    ///
    /// DEPTH STILL DOES NOT REORDER ANYTHING. Pushing a card back in Z changes
    /// how big it draws and how fast it slides, and nothing about who covers
    /// whom — that was the founding rule and it has not moved. What has changed
    /// is only HOW the artist states the stacking: a number they set, rather
    /// than a position in a list they shuffle.
    var sortingOrder: Int

    /// Which light channels this layer sits on.
    ///
    /// A light reaches the layer when their masks share a channel. This is the
    /// performance control as much as the artistic one: a light that cannot
    /// reach a layer is never evaluated over it, so masking a set into groups
    /// makes a twelve-light scene cost what three lights cost.
    var lightMask: SceneLightMask
    /// Off makes the layer immune to the whole system — it draws exactly as it
    /// would with no lights in the scene. For a UI plate, a title card, or
    /// anything that is a picture OF something rather than a thing in the set.
    var receivesLight: Bool

    /// The surface this layer presents to the lights: its relief, how far the
    /// light wraps around it, and which shadows it casts and catches.
    ///
    /// ON THE LAYER AND NOT ON THE CONTENT, so that a plate and a rig instance
    /// are the same kind of surface. A rig's NORMAL MAP is the exception and
    /// lives on `SceneImage`, because a map is the pair of one PNG and a rig is
    /// many PNGs; everything else here is a property of how this card sits in
    /// this set, which is a layer's business.
    var material: SceneMaterial

    var content: SceneLayerContent

    init(
        id: UUID = UUID(),
        name: String,
        isHidden: Bool = false,
        opacity: Float = 1,
        position: SIMD2<Float> = .zero,
        positionZ: Float = 0,
        rotation: Float = 0,
        rotation3D: SIMD3<Float> = .zero,
        scale: SIMD2<Float> = SIMD2<Float>(1, 1),
        shear: SIMD2<Float> = .zero,
        sortingOrder: Int = 0,
        lightMask: SceneLightMask = .layer1,
        receivesLight: Bool = true,
        material: SceneMaterial = .flat,
        content: SceneLayerContent
    ) {
        self.id = id
        self.name = name
        self.isHidden = isHidden
        self.opacity = opacity
        self.position = position
        self.positionZ = positionZ
        self.rotation = rotation
        self.rotation3D = rotation3D
        self.scale = scale
        self.shear = shear
        self.sortingOrder = sortingOrder
        self.lightMask = lightMask
        self.receivesLight = receivesLight
        self.material = material
        self.content = content
    }

    /// A card-local point in the card's OWN PLANE: scale, then shear, then roll.
    ///
    /// ONE function, called by both pictures. The shot's `cgPoint` and the fly
    /// view's `cardPoint` each used to inline this, and two copies of a
    /// transform is how one of them ends up missing a term — the rig side of
    /// this editor already has exactly that bug between its canvas and its
    /// exporter, where a 3D-rotated sprite exports differently from how it
    /// previews. Scene composes on one surface and delivers from another; it
    /// does not get to grow the same disagreement.
    ///
    /// THE ORDER IS THE DEFINITION. Shear is applied after the scale, so it is
    /// expressed in the card's scaled units — the same order `SceneImage`
    /// applies skew in — and a scaled card slants by the amount the number
    /// says rather than by that amount times its scale.
    func planePoint(_ local: SIMD2<Float>) -> SIMD2<Float> {
        let sx = local.x * scale.x
        let sy = local.y * scale.y
        let hx = sx + sy * shear.x
        let hy = sy + sx * shear.y
        let c = cos(rotation), s = sin(rotation)
        return SIMD2<Float>(hx * c - hy * s, hx * s + hy * c)
    }

    /// A point of the card's own plane, lifted into world space by the layer's
    /// tilt: pitch about its x axis, then yaw about its y.
    ///
    /// Linear and orthonormal — it takes a plane to a plane and preserves
    /// lengths and angles — which is why it can serve both the card's corners
    /// and the gizmo's frame without either one restating it.
    func liftToWorld(_ planePoint: SIMD2<Float>) -> SIMD3<Float> {
        let cp = cos(rotation3D.x), sp = sin(rotation3D.x)
        let cy = cos(rotation3D.y), sy = sin(rotation3D.y)
        let y1 = planePoint.y * cp
        let z1 = planePoint.y * sp
        return SIMD3<Float>(planePoint.x * cy + z1 * sy, y1, -planePoint.x * sy + z1 * cy)
    }

    /// Where the layer's origin sits in world space.
    var worldOrigin: SIMD3<Float> {
        SIMD3<Float>(position.x, position.y, positionZ)
    }

    /// The plane every pixel this layer draws lies in: a point on it and its
    /// normal.
    ///
    /// This is what makes lighting exact rather than approximate. A layer is
    /// FLAT — the invariant the whole Scene model is built on — so the ray
    /// through any pixel the layer covers meets this plane at the world point
    /// that is actually there, whatever the layer contains, however it is
    /// tilted, and however its meshes are deformed. Straight off
    /// `orientation()`, so no scale and no shear can reach the normal.
    var lightingPlane: (point: SIMD3<Float>, normal: SIMD3<Float>) {
        (worldOrigin, orientation().z)
    }

    /// The artwork's own axes in world space: where image +x points, and
    /// whether the card is mirrored.
    ///
    /// This is the other half of `lightingPlane`, and it exists for the same
    /// reason: a normal map stores its normals in TANGENT space -- +x across
    /// the image, +y up it, +z out of it -- and turning one into a world normal
    /// needs the world directions those three mean here.
    ///
    /// STRAIGHT OFF `orientation()`, so no scale and no shear can reach it,
    /// exactly as the normal cannot. The scale gets in only through its SIGN: a
    /// card with a negative scale draws its artwork reversed, so image +x
    /// points the other way, and the bitangent's handedness is
    /// `sign(scale.x * scale.y)`. A mirrored card whose basis is not told it is
    /// mirrored lights its relief from the wrong side -- entirely plausible in
    /// a still, and obvious the moment a light crosses it.
    ///
    /// The magnitude of the scale is deliberately left out. Relief therefore
    /// does not stretch with a card scaled 3x wide: a bump on it still lights
    /// round. That is the reading an emboss wants, and it is the same
    /// approximation the flat normal has always made.
    var lightingTangent: (tangent: SIMD3<Float>, handed: Float) {
        let axes = orientation()
        // `sign` of zero is zero, and a frame multiplied by zero is not a
        // frame. A degenerate axis keeps the unmirrored reading, which is what
        // the card looked like before it was flattened.
        let sx: Float = scale.x < 0 ? -1 : 1
        let sy: Float = scale.y < 0 ? -1 : 1
        return (axes.x * sx, sx * sy)
    }

    /// The layer's ROTATION, as three orthonormal world axes.
    ///
    /// This is what a manipulator hangs off, and the reason it exists separately
    /// from `planePoint` is the whole of a bug: the gizmo used to take its frame
    /// by differencing the card's own transform, which runs a point through
    /// `planePoint` — scale first, then SHEAR, then roll. Normalising the two
    /// vectors that came back fixed their lengths and could do nothing about the
    /// angle between them, so a sheared card handed the gizmo a frame that was
    /// not a rotation. A matrix like that shears every arrow it multiplies.
    ///
    /// Roll, then the tilt. No scale and no shear can reach it, which is what
    /// keeps the arrows square to each other however the card itself is squashed.
    func orientation() -> (x: SIMD3<Float>, y: SIMD3<Float>, z: SIMD3<Float>) {
        let c = cos(rotation), s = sin(rotation)
        let x = liftToWorld(SIMD2<Float>(c, s))
        let y = liftToWorld(SIMD2<Float>(-s, c))
        return (x, y, simd_cross(x, y))
    }

    /// Which frame of its clip this layer shows when the scene is at `frame`.
    ///
    /// Returns nil for anything that is not a rig. A speed of zero freezes the
    /// instance on its start frame rather than dividing the timeline by nothing.
    func rigFrame(sceneFrame: Int, clipDuration: Int) -> Int? {
        guard case let .rig(_, speed, startFrame, loops) = content else { return nil }
        guard clipDuration > 0 else { return startFrame }
        let advanced = startFrame + Int((Float(sceneFrame) * speed).rounded())
        guard loops else { return min(max(advanced, 0), clipDuration - 1) }
        // Swift's % keeps the sign of the dividend, so a negative start frame or
        // a negative speed would index backwards off the clip without this.
        let wrapped = advanced % clipDuration
        return wrapped < 0 ? wrapped + clipDuration : wrapped
    }
}
