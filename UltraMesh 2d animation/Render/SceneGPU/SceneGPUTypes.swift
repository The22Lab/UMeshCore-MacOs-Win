import Foundation
import simd

// ── The structs the shader reads ────────────────────────────────────────
//
// Hand-written on both sides, as the rest of this project already does, and
// kept in step by `Editor/verify_scene_gpu_transcription.py` rather than by a
// bridging header. The harness compares these declarations with the ones in
// `SceneShaders.metal` field by field and checks every size is a multiple of
// 16, which is the drift that produces a picture where one light is right and
// the next is reading a neighbour's radius.
//
// A shared header would be better and is a change to the Xcode project rather
// than to code, so it is left for the Mac. The harness is what makes leaving
// it safe.
//
// WHY THE PADDING IS SPELLED OUT. Metal aligns float3 to 16 bytes and so does
// `SIMD3<Float>`, so a float3 and a float written as two fields occupy 32
// bytes, not 16. Packing them into a float4 by hand is the only way the two
// sides can be read off against each other without counting.

struct SceneFrameUniforms {
    var viewProjection: simd_float4x4
    /// xyz eye, w nearZ.
    var eyeAndNear: SIMD4<Float>
    /// rgb ambient, w unused.
    var ambient: SIMD4<Float>
    var lightCount: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

/// One thing that can stand between a light and a surface.
///
/// ## A parallelogram, not a rectangle
///
/// A Scene card can be sheared, and a sheared card's two axes are not
/// perpendicular. Testing "inside" by projecting onto each axis separately is
/// right for a rectangle and wrong for every sheared one -- the shadow comes
/// out the shape the card would have had without its slant. So the shader
/// solves the 2x2 system instead, which is exact for a parallelogram and costs
/// about ten instructions.
///
/// ## Flat, and that is not a simplification
///
/// Every Scene layer is flat by the model's founding rule, so an occluder IS a
/// plane segment. A ray crosses it exactly once. That is why the alpha
/// silhouette costs ONE texture read per occluder per light rather than a march
/// along the ray, and it is the whole reason the expensive-looking option is
/// affordable.
struct SceneOccluder {
    /// xyz the quad's centre in world space, w unused.
    var origin: SIMD4<Float>
    /// xyz half-extent along the artwork's +x, w unused.
    var axisU: SIMD4<Float>
    /// xyz half-extent along the artwork's +y (image UP), w unused.
    var axisV: SIMD4<Float>
    /// xyz the plane's unit normal, w `dot(normal, origin)`.
    ///
    /// The offset is carried rather than recomputed because the shader needs it
    /// once per occluder per fragment and the CPU needs it once per frame.
    var normalAndOffset: SIMD4<Float>
    /// Where this occluder's alpha tile sits in the shadow atlas.
    var uvRect: SIMD4<Float>
    /// Which light channels this occluder casts on.
    var castMask: UInt32
    /// 1 when the alpha tile is real, 0 when the quad is the whole silhouette.
    ///
    /// A fill has no artwork to cut a hole in, and an asset whose alpha could
    /// not be read must cast its rectangle rather than nothing -- a missing
    /// file should not silently stop a character casting a shadow.
    var useAlpha: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

struct SceneLightUniform {
    /// xyz world origin, w radius.
    var originAndRadius: SIMD4<Float>
    /// xyz unit direction, w inner radius.
    var directionAndInner: SIMD4<Float>
    /// rgb colour * intensity, w fade band width.
    var tintAndBand: SIMD4<Float>
    /// x cosInner, y cosOuter, z depthInfluence, w normalInfluence.
    var cones: SIMD4<Float>
    var kind: UInt32
    var blend: UInt32
    var mask: UInt32
    var falloffRow: UInt32
    /// This light's slice of the occluder buffer, culled on the CPU.
    ///
    /// PER LIGHT AND NOT GLOBAL. Shadowing is O(lights x occluders) per
    /// fragment, and most occluders are nowhere near most lights -- so the CPU
    /// drops the ones outside the radius and outside the cast mask once per
    /// frame, instead of the GPU rejecting them once per pixel.
    var occluderStart: UInt32 = 0
    var occluderCount: UInt32 = 0
    /// 0 unless the artist asked this light for shadows. Off by default, so
    /// every project that predates them pays nothing at all.
    var castsShadows: UInt32 = 0
    var pad0: UInt32 = 0

    /// Everything `SceneLighting.PreparedLight` works out once, in the layout
    /// the shader reads. The arithmetic is not repeated here — this is a
    /// transcription of the prepared light, and `PreparedLight` stays the one
    /// place the numbers are derived.
    init(_ prepared: SceneLighting.PreparedLight, falloffRow: Int) {
        let light = prepared.light
        originAndRadius = SIMD4<Float>(prepared.origin, prepared.radius)
        directionAndInner = SIMD4<Float>(prepared.direction, prepared.innerRadius)
        tintAndBand = SIMD4<Float>(prepared.tint, prepared.band)
        cones = SIMD4<Float>(prepared.cosInner, prepared.cosOuter,
                             light.depthInfluence, light.normalInfluence)
        kind = Self.kindCode(light.kind)
        blend = Self.blendCode(light.blend)
        mask = UInt32(light.mask.rawValue)
        self.falloffRow = UInt32(falloffRow)
        castsShadows = light.castsShadows ? 1 : 0
    }

    /// Fills in this light's slice of the occluder buffer.
    ///
    /// Separate from `init` because the slice is decided once the whole frame's
    /// occluders are known, and the uniform is built before that.
    mutating func setOccluders(start: Int, count: Int) {
        occluderStart = UInt32(start)
        occluderCount = UInt32(count)
    }

    /// The codes the shader compares against, in one place each.
    ///
    /// A `switch` rather than a raw value on the enum: the enums are
    /// `String`-backed because that is what the file format stores, and giving
    /// them an Int raw value as well would make the WIRE format depend on the
    /// declaration order of a Swift enum. Reordering the cases would then
    /// silently change every saved scene.
    static func kindCode(_ kind: SceneLightKind) -> UInt32 {
        switch kind {
        case .point:       return 0
        case .spot:        return 1
        case .directional: return 2
        }
    }

    static func blendCode(_ blend: SceneLightBlend) -> UInt32 {
        switch blend {
        case .normal:   return 0
        case .additive: return 1
        case .multiply: return 2
        case .screen:   return 3
        }
    }
}

/// The surface a layer -- or one sprite of a rig -- presents to the lights.
///
/// ## Why the tangent frame is here and not derived in the shader
///
/// A normal map stores its normals in TANGENT space: +x is right across the
/// image, +y is up it, +z is out of it. Turning one into a world normal needs
/// the three world axes those directions correspond to, and there is exactly
/// one honest source for them: `SceneLayer.orientation()`, which is orthonormal
/// and carries NO scale and NO shear.
///
/// That is not fastidiousness. A sheared card's plane axes are not
/// perpendicular, so a normal rotated by them is no longer unit and no longer
/// perpendicular to anything -- the same fault `orientation()`'s own docstring
/// records having had with the gizmo, where a sheared card handed it a frame
/// that was not a rotation and every arrow came out skewed. An orthonormal
/// basis also has the convenience that its inverse transpose is itself, so
/// nothing anywhere in this feature needs one.
///
/// The honest cost: because the frame is scale-free, relief does not stretch
/// with a non-uniformly scaled card. A bump on a card scaled 3x wide still
/// lights round. For an emboss that is the reading an artist wants, and it is
/// the same approximation the flat normal already made.
struct SceneLayerUniforms {
    /// Atlas placement: x, y, width, height.
    var uvRect: SIMD4<Float>
    /// rgba, premultiplied on the way in.
    var tint: SIMD4<Float>
    var lightMask: UInt32
    var receivesLight: UInt32
    /// What this surface has, one bit each -- see `SceneMetalRenderer`'s
    /// `hasNormalMapFlag` and friends, which are the Swift half of the
    /// `kScene*` constants the shader compares against.
    ///
    /// Bit 0: a normal map is bound at texture(2) and the shader may sample it.
    ///
    /// A FLAG AND NOT A TEST ON `normalStrength`. The whole of this feature
    /// hangs off the promise that a sprite without a normal map renders exactly
    /// as it did before -- bit for bit, not nearly. The obvious alternative is
    /// a flat lavender texel, which decodes to +z and rotates back to the
    /// surface's own normal, and which is bit-identical ON A CARD FACING THE
    /// CAMERA. It is not on a tilted one: `orientation()` builds the normal
    /// from a cross product, and the cross product of two unit vectors is not
    /// reliably unit in float32. Measured over 4 000 random tilted cards in
    /// `verify_scene_normal_maps.py`, 826 come back from that round trip
    /// changed, by up to 1.2e-07.
    ///
    /// Nobody would ever report that. It would simply mean every project made
    /// before this feature renders fractionally differently after it -- and a
    /// test scene facing the camera, which is how this would have been
    /// checked, passes with the fault in.
    ///
    /// So the flag gates a BRANCH, and on the old path the shader never
    /// samples, never rotates and never normalises.
    var materialFlags: UInt32 = 0
    /// Which light channels' shadows may darken this surface. Zero receives
    /// none, which is what every project that predates shadows wants.
    var shadowedMask: UInt32 = 0
    /// xyz the layer's plane normal in world space, w the normal-map strength.
    ///
    /// Strength 0 is a flat surface and 1 is the map as painted; it is the
    /// AMPLITUDE knob, deliberately separate from smoothness, which reshapes
    /// the response rather than the relief.
    var normalAndStrength: SIMD4<Float>
    /// xyz the tangent -- image +x -- in world space, w the handedness.
    ///
    /// The handedness is `sign(scale.x * scale.y)` and the shader derives the
    /// bitangent as `handed * cross(N, T)`. A negative scale mirrors the card,
    /// and a mirrored basis that is not told it is mirrored lights the relief
    /// from the wrong side -- plausible in a still, wrong the moment a light
    /// moves across it.
    var tangentAndSign: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 1)
    /// x smoothness, y contrast, z parallax occlusion strength, w spare.
    var material: SIMD4<Float> = .zero
    /// x depth of the height volume in UV units, y minimum march steps,
    /// z maximum march steps, w steps of the self-shadow march.
    ///
    /// ZERO WHEN THERE IS NO MARCH, and that is not merely tidy: the shader
    /// reaches this field only inside the parallax branch, so a stale depth
    /// left here by a layer that turned the feature off would be read by
    /// nothing -- until the day a new flag opens a second door onto it. The
    /// cost of keeping it honest is one `.zero`.
    ///
    /// MIN AND MAX AS FLOATS, not as uints. They are interpolated against the
    /// view angle (`mix(max, min, |Vz|)`) before anything counts with them, so
    /// storing them as integers would only mean converting them back.
    var parallax: SIMD4<Float> = .zero
}

/// One vertex of a card or a skinned sprite, in WORLD space.
///
/// World and not screen, and that is the change that makes navigation free.
/// The rig canvas uploads screen-space vertices, so moving the camera one
/// pixel rebuilds and re-uploads every vertex of every mesh even though
/// nothing in the world moved. Here the camera is a uniform: panning and
/// zooming a still scene uploads nothing at all.
struct SceneVertexIn {
    var world: SIMD3<Float>
    var uv: SIMD2<Float>
}

/// One vertex of a skinned sprite.
///
/// The position is the vertex's BIND position, in sprite-local space, and it
/// never changes while the rig animates — the pose lives entirely in the
/// palette. So this buffer is uploaded once and reused every frame.
///
/// That is the whole of why playback stops costing what it costs. Today the
/// pose is baked into the vertices, so every cache keyed on it misses on every
/// frame of an animation and the full per-triangle cost comes back: measured at
/// 38.6 ms for two instances, over a 30fps budget before anything else in the
/// scene is drawn. With the pose in the palette, an animating rig re-uploads
/// thirty matrices and nothing else.
struct SceneSkinnedVertexIn {
    var bindLocal: SIMD2<Float>
    var uv: SIMD2<Float>
    /// Four slots into the palette. Slot 0 is the identity, so an unweighted
    /// vertex needs no branch in the shader.
    var slots: SIMD4<UInt16>
    /// Four weights that SUM TO ONE — normalised by `SceneSkinPalette`,
    /// because folding the sprite's bind affine into the palette is exact only
    /// when they do.
    var weights: SIMD4<Float>
}
