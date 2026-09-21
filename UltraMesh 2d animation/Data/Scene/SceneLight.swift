import Foundation
import simd

/// What a light is shaped like.
///
/// Three, and deliberately only three at this level: everything an artist
/// listed — lamps, fire, magic, torches, spots, a sun — is one of these with
/// different numbers, and a fourth case would be a fourth attenuation formula
/// to keep in step with the other three. Area lights and cookies, when they
/// come, are a POINT light with something extra sampled, not a new kind.
enum SceneLightKind: String, CaseIterable, Equatable, Identifiable {
    /// Radiates from a place. Lamps, fire, explosions, magic.
    case point
    /// A cone from a place, along a direction. Torches, stage lights.
    case spot
    /// Everywhere at once, from a direction. The sun, the sky, the ambient key.
    case directional

    var id: String { rawValue }

    var title: String {
        switch self {
        case .point:       return "Point"
        case .spot:        return "Spot"
        case .directional: return "Global"
        }
    }

    var systemImage: String {
        switch self {
        case .point:       return "lightbulb"
        case .spot:        return "flashlight.on.fill"
        case .directional: return "sun.max"
        }
    }

    /// Whether the light has a place at all. A directional light does not: it
    /// is a direction and nothing else, so moving it would be a control that
    /// changes nothing — which is worse than not having it.
    var isPositional: Bool { self != .directional }
}

/// How a light joins what is already there.
///
/// `normal` and the three others are not variations of one operation. A normal
/// light adds to the factor that MULTIPLIES the artwork, so it illuminates:
/// a black sprite stays black however much you point at it, which is what
/// light does. An additive light is added AFTER that multiply, so it emits: it
/// survives a black sprite, which is what fire and magic need and what every
/// artist reaches for first.
enum SceneLightBlend: String, CaseIterable, Equatable, Identifiable {
    /// Illumination. Adds into the multiplicative factor.
    case normal
    /// Emission. Added after the multiply, so it cannot be cancelled by a dark
    /// sprite.
    case additive
    /// A gel: it can only take light away, and only where it reaches.
    case multiply
    /// Screen composite onto the accumulated lighting — brightens without ever
    /// passing 1, so it lifts shadows without blowing highlights.
    case screen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal:   return "Normal"
        case .additive: return "Additive"
        case .multiply: return "Multiply"
        case .screen:   return "Screen"
        }
    }
}

/// Which lights touch which layers.
///
/// The cheapest thing in the whole system: a light that cannot reach a layer is
/// never evaluated for it, so masking is the performance control as much as it
/// is an artistic one — a set with twelve lights and four masked groups costs
/// what three lights cost. Eight channels, which is what fits in a byte and
/// more than any 2D set has ever needed.
struct SceneLightMask: OptionSet, Equatable, Hashable {
    let rawValue: UInt8

    init(rawValue: UInt8) { self.rawValue = rawValue }

    static let layer1 = SceneLightMask(rawValue: 1 << 0)
    static let layer2 = SceneLightMask(rawValue: 1 << 1)
    static let layer3 = SceneLightMask(rawValue: 1 << 2)
    static let layer4 = SceneLightMask(rawValue: 1 << 3)
    static let layer5 = SceneLightMask(rawValue: 1 << 4)
    static let layer6 = SceneLightMask(rawValue: 1 << 5)
    static let layer7 = SceneLightMask(rawValue: 1 << 6)
    static let layer8 = SceneLightMask(rawValue: 1 << 7)

    static let all = SceneLightMask(rawValue: 0xFF)
    // No `none` constant: a static member spelled `none` on a type that is
    // ever written as an Optional makes `.none` ambiguous at the call site, and
    // the compiler resolves it to `Optional.none` without complaining.
    // `SceneLightMask([])` says the same thing and cannot be misread.

    static let channels: [SceneLightMask] = [
        .layer1, .layer2, .layer3, .layer4, .layer5, .layer6, .layer7, .layer8
    ]

    /// Do these two share a channel? The whole of masking.
    func reaches(_ other: SceneLightMask) -> Bool { !intersection(other).isEmpty }

    /// 1-based channel numbers, ascending — for a label, and in a fixed order
    /// because a label that reshuffles between launches is a bug report.
    var channelNumbers: [Int] {
        Self.channels.indices.compactMap { contains(Self.channels[$0]) ? $0 + 1 : nil }
    }
}

/// One stop of a falloff curve: a position across the fade band, the value
/// there, and the two Bézier handles.
///
/// The same shape a `Keyframe` has, minus the frame — because it IS a keyframe,
/// evaluated by the editor's own `AnimationCurve` on a normalised axis instead
/// of on frames. That is the point: intensity, radius and falloff are all eased
/// by one curve engine, so a falloff can be dragged in the Graph editor beside
/// a translate track and behaves identically.
struct LightFalloffStop: Equatable {
    var position: Float
    var value: Float
    var inTangent: SIMD2<Float>?
    var outTangent: SIMD2<Float>?

    init(position: Float, value: Float,
         inTangent: SIMD2<Float>? = nil, outTangent: SIMD2<Float>? = nil) {
        self.position = position
        self.value = value
        self.inTangent = inTangent
        self.outTangent = outTangent
    }
}

/// How a light fades across its band.
///
/// PINNED AT BOTH ENDS: the first stop is (0, 1) and the last is (1, 0), always,
/// enforced on construction rather than clamped on read. Those two are what make
/// the light continuous where the band meets full brightness and where it meets
/// darkness — a curve that ended at 0.2 would draw a hard circle around every
/// lamp in the set, and an artist would report it as "the light has an edge"
/// without ever suspecting the curve.
struct LightFalloffCurve: Equatable {
    private(set) var stops: [LightFalloffStop]

    init(_ stops: [LightFalloffStop]) {
        var pinned = stops.count >= 2 ? stops : LightFalloffCurve.smooth.stops
        pinned.sort { $0.position < $1.position }
        pinned[0].position = 0
        pinned[0].value = 1
        pinned[pinned.count - 1].position = 1
        pinned[pinned.count - 1].value = 0
        self.stops = pinned
    }

    /// A straight fade: both control points on the chord.
    static let linear = LightFalloffCurve([
        LightFalloffStop(position: 0, value: 1, outTangent: SIMD2<Float>(1.0 / 3, -1.0 / 3)),
        LightFalloffStop(position: 1, value: 0, inTangent: SIMD2<Float>(-1.0 / 3, 1.0 / 3)),
    ])

    /// The default. FLAT tangents at both ends, which is exactly smoothstep.
    ///
    /// Written out rather than left to the auto tangent, and that is not a
    /// stylistic choice. With two stops and no neighbours `AnimationCurve`'s
    /// auto slope is the slope of the CHORD, so a two-stop "auto" curve is a
    /// straight line — the default would have been linear while being called
    /// smooth. Flat ends give 1 - 3u² + 2u³, the fade with no corner at either
    /// end.
    static let smooth = LightFalloffCurve([
        LightFalloffStop(position: 0, value: 1, outTangent: SIMD2<Float>(1.0 / 3, 0)),
        LightFalloffStop(position: 1, value: 0, inTangent: SIMD2<Float>(-1.0 / 3, 0)),
    ])

    /// The physical fall, sampled as stops so it stays ONE curve type rather
    /// than a special case in the evaluator.
    ///
    /// Renormalised to reach 0 at the rim. An unrenormalised inverse square
    /// never reaches zero, so the pinning above would drag its last stop down
    /// anyway and put a kink there; renormalising says so out loud instead.
    static let inverseSquare: LightFalloffCurve = {
        let k: Float = 8
        let raw = (0...8).map { 1 / pow(1 + k * (Float($0) / 8), 2) }
        let lo = raw[raw.count - 1]
        return LightFalloffCurve(raw.indices.map {
            LightFalloffStop(position: Float($0) / 8, value: (raw[$0] - lo) / (1 - lo))
        })
    }()

    /// Value at a normalised position across the band.
    ///
    /// Through `AnimationCurve` — the editor's one curve authority — on its
    /// continuous axis. Lighting has no Bézier code of its own, which is the
    /// whole reason `AnimationCurve.segment` grew a float overload.
    func value(at position: Float) -> Float {
        let u = min(max(position, 0), 1)
        if u <= 0 { return stops[0].value }
        if u >= 1 { return stops[stops.count - 1].value }
        var index = 0
        for i in 0..<(stops.count - 1) where stops[i].position <= u && u <= stops[i + 1].position {
            index = i
            break
        }
        let lhs = stops[index], rhs = stops[index + 1]
        let before = index > 0 ? stops[index - 1] : nil
        let after = index + 2 < stops.count ? stops[index + 2] : nil
        let segment = AnimationCurve.segment(
            start: (x: lhs.position, value: lhs.value),
            end: (x: rhs.position, value: rhs.value),
            outTangent: lhs.outTangent,
            inTangent: rhs.inTangent,
            beforeStart: before.map { (x: $0.position, value: $0.value) },
            afterEnd: after.map { (x: $0.position, value: $0.value) },
            minimumSpan: AnimationCurve.normalisedSpanFloor)
        return AnimationCurve.value(of: segment, atTime: u)
    }

    /// The curve as a table, for the inner loop.
    ///
    /// A falloff is evaluated once per lattice point per light per frame, and
    /// evaluating it exactly means a bracketed Newton solve each time — around
    /// a hundred operations to answer a question with one input in [0, 1].
    /// Tabulated once per light per frame instead. `Editor/verify_scene_lighting.py`
    /// measures the table against the exact curve across all three presets:
    /// worst 0.038/255 at this size, which is an eighth of a quantisation step.
    func table(entries: Int = LightFalloffCurve.tableEntries) -> [Float] {
        let n = max(entries, 2)
        return (0..<n).map { value(at: Float($0) / Float(n - 1)) }
    }

    static let tableEntries = 256
}

/// A light in a Scene.
///
/// Scene data, saved with the project, and animatable through the same tracks
/// the camera uses. It is NOT part of the rig: a light belongs to a staging of
/// a scene, not to the character, which is why it lives here beside
/// `SceneLayer` and never touches `SceneImage`.
struct SceneLight: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var kind: SceneLightKind

    // MARK: Place

    var position: SIMD2<Float>
    /// Depth, in the same axis as `SceneLayer.positionZ` and `SceneCamera`:
    /// higher is further from the camera.
    var positionZ: Float
    /// Which way a spot or a global light points, in the XY plane. Radians.
    var azimuth: Float
    /// Its tilt out of that plane, toward or away from the camera. Radians,
    /// positive going away — the same sign convention `positionZ` uses, so a
    /// light "pointing into the set" and a layer "pushed back" agree.
    var elevation: Float

    // MARK: Shape

    var radius: Float
    var intensity: Float
    var color: SIMD3<Float>
    var falloff: LightFalloffCurve
    /// Where the fade STARTS, as a fraction of the radius: the band is
    /// `radius * softness` wide and the light is at full strength inside it.
    ///
    /// One knob, not two that fight. It would have been easy to let softness
    /// feather the edge AND the curve shape the whole radius, and then no
    /// setting of either would mean anything on its own. Here the radius says
    /// where the light ends, softness says how much of it is fade, and the
    /// curve says what the fade looks like.
    var softness: Float
    /// Spot cone. Full strength inside the inner angle, nothing outside the
    /// outer one, smooth between. Radians, half-angles.
    var innerAngle: Float
    var outerAngle: Float

    // MARK: Behaviour

    var mask: SceneLightMask
    var blend: SceneLightBlend
    /// How much the depth difference counts toward the distance.
    ///
    /// 0 makes the light flat: every layer is lit as though it sat at the
    /// light's own depth, which is ordinary 2D lighting and what an artist
    /// staging a flat scene wants. 1 makes it a real point in space, so a
    /// backdrop twenty units behind the subject falls off like one. Nothing
    /// else in the model knows about Z — this single multiplier is the whole of
    /// 2.5D lighting, which is what keeps it from being a special case
    /// threaded through every formula.
    var depthInfluence: Float
    /// How much the surface's facing counts.
    ///
    /// 0 is flat 2D lighting: a card is lit the same however it is tilted. 1 is
    /// true Lambert. It exists now, before normal maps do, because a normal map
    /// changes only WHERE the normal comes from — so the day it lands, nothing
    /// in the shading needs rewriting.
    var normalInfluence: Float
    /// Reserved for shadow casting. Stored and persisted from the start so that
    /// turning shadows on later does not invalidate a saved scene.
    var castsShadows: Bool

    init(
        id: UUID = UUID(),
        name: String = "Light",
        isEnabled: Bool = true,
        kind: SceneLightKind = .point,
        position: SIMD2<Float> = .zero,
        positionZ: Float = -300,
        azimuth: Float = .pi / 2,
        elevation: Float = 0,
        radius: Float = 600,
        intensity: Float = 1,
        color: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
        falloff: LightFalloffCurve = .smooth,
        softness: Float = 1,
        innerAngle: Float = 20 * .pi / 180,
        outerAngle: Float = 35 * .pi / 180,
        mask: SceneLightMask = .all,
        blend: SceneLightBlend = .normal,
        depthInfluence: Float = 1,
        normalInfluence: Float = 0,
        castsShadows: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.kind = kind
        self.position = position
        self.positionZ = positionZ
        self.azimuth = azimuth
        self.elevation = elevation
        self.radius = radius
        self.intensity = intensity
        self.color = color
        self.falloff = falloff
        self.softness = softness
        self.innerAngle = innerAngle
        self.outerAngle = outerAngle
        self.mask = mask
        self.blend = blend
        self.depthInfluence = depthInfluence
        self.normalInfluence = normalInfluence
        self.castsShadows = castsShadows
    }

    var world: SIMD3<Float> { SIMD3<Float>(position.x, position.y, positionZ) }

    /// The unit vector the light points along.
    var direction: SIMD3<Float> {
        let ce = cos(elevation), se = sin(elevation)
        return SIMD3<Float>(cos(azimuth) * ce, sin(azimuth) * ce, se)
    }

    /// Where the fade begins, in world units.
    var innerRadius: Float { max(radius, 0) * (1 - min(max(softness, 0), 1)) }

    /// How wide the gradient is, in world units. The number the lattice density
    /// is chosen from, because the gradient is the only thing interpolation can
    /// get wrong.
    var bandWidth: Float { max(radius, 0) - innerRadius }
}

/// The light that is there when no light is pointed at something.
///
/// Without it an unlit corner is pure black, and a 2D scene with a black
/// background reads as broken rather than as dark. It multiplies, like every
/// `normal` light, so it tints as well as lifts.
struct SceneAmbient: Equatable {
    var color: SIMD3<Float>
    var intensity: Float

    init(color: SIMD3<Float> = SIMD3<Float>(1, 1, 1), intensity: Float = 1) {
        self.color = color
        self.intensity = intensity
    }

    var rgb: SIMD3<Float> { color * max(intensity, 0) }

    /// Full white at strength 1: a scene with no lights renders EXACTLY as it
    /// did before lighting existed. That is the whole of the default, and it is
    /// what lets this ship without changing a single scene anybody has already
    /// composed.
    static let neutral = SceneAmbient()
}
