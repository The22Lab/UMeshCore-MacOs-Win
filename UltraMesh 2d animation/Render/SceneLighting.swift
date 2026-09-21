import CoreGraphics
import Foundation
import simd

/// The one place a Scene decides how much light reaches a point.
///
/// ## Where lighting is resolved, and why it is not where you would guess
///
/// Per LAYER, in SCREEN space, against the layer's own plane.
///
/// The obvious place is the card's texture: multiply a sprite by a light map
/// and draw it. That is what most 2D engines do, and here it would be wrong in
/// a way that shows. A Scene layer can be a rig instance whose sprites are
/// mesh-deformed, so a texel's position in the texture says very little about
/// where it ends up in the world; light it in texture space and a deformed arm
/// carries the lighting of where the arm was drawn flat.
///
/// A Scene layer, on the other hand, is FLAT — that is the model's founding
/// invariant, the one that made parallax free — so every pixel a layer draws
/// lies in one known plane. Intersect the ray through a pixel with that plane
/// and you have the exact world point, whatever the layer contains and however
/// it is tilted or deformed. No approximation is involved at all.
///
/// So: draw the layer, intersect, shade, composite. One lattice per layer
/// rather than one per sprite, and a rig instance with forty deformed sprites
/// costs the same as a plate.
///
/// ## What is interpolated, and how the density was chosen
///
/// Shading every pixel exactly would mean a bracketed Newton solve per light
/// per pixel. Instead the field is evaluated on a lattice and interpolated
/// bilinearly, and the lattice spacing is chosen from the light's FADE BAND —
/// not from its radius, and not from the card. The band is where the curvature
/// is; everywhere else the field is flat or zero and interpolation is exact.
///
/// `Editor/verify_scene_lighting.py` measures the error against per-pixel
/// evaluation over four band widths and five densities. It comes out as
/// `error ≈ 0.9 / (cells per band)²`, so:
///
///   * 16 cells per band → ≤ 1/255, under a quantisation step. `.final`.
///   * 8 cells per band → ≤ 4/255. `.interactive`, where the artist is orbiting.
///
/// Those two numbers are the constants below. They are measurements, not
/// guesses, and the harness fails if the code stops honouring them.
struct SceneLighting {

    /// A light with everything that does not change per pixel worked out once.
    struct PreparedLight {
        var light: SceneLight
        /// The falloff, tabulated. See `LightFalloffCurve.table`.
        var table: [Float]
        var origin: SIMD3<Float>
        var direction: SIMD3<Float>
        var radius: Float
        var innerRadius: Float
        var band: Float
        var cosInner: Float
        var cosOuter: Float
        var tint: SIMD3<Float>

        init(_ light: SceneLight) {
            self.light = light
            self.table = light.falloff.table()
            self.origin = light.world
            self.direction = light.direction
            self.radius = max(light.radius, 0.000001)
            self.innerRadius = light.innerRadius
            self.band = light.bandWidth
            // Cones compared as COSINES, never as angles: acos is at its least
            // accurate exactly on the axis, which is the middle of the cone,
            // and a dot product IS the cosine — converting it to an angle only
            // to convert back is arithmetic that can only lose.
            let outer = min(max(light.outerAngle, 0), .pi)
            let inner = min(max(light.innerAngle, 0), outer)
            self.cosOuter = cos(outer)
            self.cosInner = cos(inner)
            self.tint = light.color * light.intensity
        }

        /// The falloff at a normalised band position, through the table.
        func falloff(_ u: Float) -> Float {
            let n = table.count
            guard n >= 2 else { return 0 }
            let x = min(max(u, 0), 1) * Float(n - 1)
            let i = min(Int(x), n - 2)
            let f = x - Float(i)
            return table[i] * (1 - f) + table[i + 1] * f
        }

        /// How much of this light reaches a world point, in 0...1.
        func attenuation(at point: SIMD3<Float>) -> Float {
            if light.kind == .directional { return 1 }
            var delta = point - origin
            // THE WHOLE OF 2.5D. Scaling the depth difference is the only place
            // in the model that mentions Z: 0 gives a light that lies flat
            // across every layer, 1 gives a real point in space.
            delta.z *= light.depthInfluence
            let distance = simd_length(delta)
            guard distance < radius else { return 0 }
            let radial: Float
            if distance <= innerRadius {
                radial = 1
            } else if band > 0.000001 {
                radial = falloff((distance - innerRadius) / band)
            } else {
                radial = 0
            }
            guard light.kind == .spot, distance > 0.000001 else { return radial }
            let cosine = simd_dot(delta / distance, direction)
            if cosine <= cosOuter { return 0 }
            if cosine >= cosInner { return radial }
            let t = (cosine - cosOuter) / max(cosInner - cosOuter, 0.000001)
            return radial * (t * t * (3 - 2 * t))
        }

        /// N·L, shaped by the surface, then faded in by `normalInfluence`.
        ///
        /// THE ORDER IS THE DESIGN. `smoothness` and `contrast` belong to the
        /// SURFACE and act on the directional response; `normalInfluence`
        /// belongs to the LIGHT and decides how much of that response is used
        /// at all. Keeping the influence as the outermost step means a light
        /// the artist deliberately set to flat 2D cannot be resurrected by a
        /// sprite's material — which is the one thing an artist would never
        /// forgive, because it would make a lighting decision unmakeable.
        ///
        /// Both parameters default to the neutral value, so the CPU fallback
        /// path calls this exactly as it always did and renders exactly what
        /// it always rendered.
        func lambert(at point: SIMD3<Float>, normal: SIMD3<Float>,
                     smoothness: Float = 0, contrast: Float = 0) -> Float {
            let influence = light.normalInfluence
            guard influence > 0 else { return 1 }
            let toLight: SIMD3<Float>
            if light.kind == .directional {
                toLight = -direction
            } else {
                var delta = origin - point
                delta.z *= light.depthInfluence
                let length = simd_length(delta)
                guard length > 0.000001 else { return 1 }
                toLight = delta / length
            }
            let ndotl = SceneLighting.shapedLambert(simd_dot(normal, toLight),
                                                     smoothness: smoothness,
                                                     contrast: contrast)
            return 1 - influence + influence * ndotl
        }

        /// The RGB arriving at a point, before the blend routes it.
        func emission(at point: SIMD3<Float>, normal: SIMD3<Float>) -> SIMD3<Float> {
            let a = attenuation(at: point)
            guard a > 0 else { return .zero }
            return tint * (a * lambert(at: point, normal: normal))
        }
    }

    /// In the artist's list order.
    ///
    /// Order matters, because `multiply` and `screen` do not commute with the
    /// rest, and it is the LIST's order rather than a Set's for the reason
    /// `CLAUDE.md` gives: Swift seeds a Set's hashing per process, so a render
    /// taken from one would differ between launches of the same project.
    let lights: [PreparedLight]
    let ambient: SceneAmbient

    init(lights: [SceneLight], ambient: SceneAmbient) {
        self.lights = lights.filter(\.isEnabled).map(PreparedLight.init)
        self.ambient = ambient
    }

    /// Nothing to do: no lights, and an ambient that multiplies by exactly one.
    ///
    /// The load-bearing default. A Scene composed before lighting existed has
    /// no lights and a neutral ambient, so this is true, the whole lighting
    /// path is skipped, and the frame is the one the renderer produced before —
    /// not approximately, identically, because no arithmetic runs on it at all.
    var isIdentity: Bool {
        lights.isEmpty && ambient.rgb == SIMD3<Float>(1, 1, 1)
    }

    /// How a surface turns N·L into a lit fraction: the whole of Smoothness
    /// and Contrast, in one function that Metal transcribes verbatim.
    ///
    /// ## Smoothness is a WRAP, and specifically not a blur
    ///
    /// It moves the terminator from `N·L = 0` to `N·L = -s` and compresses the
    /// gradient, so light wraps around the relief and transitions soften
    /// monotonically; `s = 1` is full half-Lambert. Crucially it reads NO TEXEL
    /// but this fragment's own — that is the test for "is this secretly a
    /// blur?", and a mip-LOD bias on the normal-map sample fails it outright:
    /// it averages neighbours, it is literally a blur, and it would soften the
    /// ARTWORK's relief rather than the LIGHT's falloff across it. Those two
    /// look alike in a still and behave nothing alike once a light moves.
    ///
    /// ## Contrast goes HERE and not on the accumulated factor
    ///
    /// Where it is applied matters more than the formula. On the accumulated
    /// `factor` it would scale the ambient and act on a sprite with no lights
    /// reaching it at all — a brightness/contrast filter wearing a lighting
    /// control's name. On the attenuation it would reshape the light's radius
    /// and its cone, which belong to the light and not to the surface. On the
    /// shaped lambert it can only redistribute the DIRECTIONAL response, and
    /// the clamp holds it inside `[0, 1]` — the range Lambert already occupied
    /// — so no pixel can reach anywhere it could not reach before. The albedo
    /// is untouched by construction: contrast never multiplies a colour.
    ///
    /// ## Both neutral values take a branch, for two DIFFERENT reasons
    ///
    /// They look like one rule and they are not, and treating them as one is
    /// how the harness for this first got written wrong. Measured at the
    /// shader's precision in `verify_scene_material_response.py`:
    ///
    /// - `smoothness == 0` changes NO BIT either way. `(d + 0) / (1 + 0)` is
    ///   exactly `d` in IEEE 754 — adding zero is exact and dividing by one is
    ///   exact — over all 40 001 samples. This branch is here to skip the
    ///   work, on every fragment of every lit sprite that never asked for it.
    /// - `contrast == 0` is LOAD-BEARING. `0.5 + (x - 0.5) * 1.0` is not
    ///   exactly `x` in float32: 3 327 of 20 001 samples move, by up to
    ///   1.5e-08. Without the branch, every lit pixel of every existing
    ///   project would shift by an amount nobody could ever see or report.
    static func shapedLambert(_ ndotl: Float, smoothness: Float, contrast: Float) -> Float {
        var shaped = smoothness <= 0
            ? max(0, ndotl)
            : max(0, (ndotl + smoothness) / (1 + smoothness))
        if contrast > 0 {
            shaped = min(max(0.5 + (shaped - 0.5) * (1 + contrast), 0), 1)
        }
        return shaped
    }

    /// The lights that can reach a surface on these channels.
    func lights(reaching mask: SceneLightMask) -> [PreparedLight] {
        lights.filter { $0.light.mask.reaches(mask) }
    }

    /// The multiplicative factor and the additive term at one world point.
    static func shade(_ lights: [PreparedLight],
                      ambient: SceneAmbient,
                      at point: SIMD3<Float>,
                      normal: SIMD3<Float>) -> (factor: SIMD3<Float>, additive: SIMD3<Float>) {
        var factor = ambient.rgb
        var additive = SIMD3<Float>.zero
        for prepared in lights {
            switch prepared.light.blend {
            case .normal:
                factor += prepared.emission(at: point, normal: normal)
            case .additive:
                additive += prepared.emission(at: point, normal: normal)
            case .multiply:
                let a = prepared.attenuation(at: point)
                guard a > 0 else { continue }
                let reach = a * prepared.lambert(at: point, normal: normal)
                factor *= SIMD3<Float>(repeating: 1 - reach) + prepared.tint * reach
            case .screen:
                let e = prepared.emission(at: point, normal: normal)
                guard e != .zero else { continue }
                let one = SIMD3<Float>(1, 1, 1)
                factor = one - (one - factor) * (one - simd_clamp(e, .zero, one))
            }
        }
        return (factor, additive)
    }

    /// The smallest fade band among these lights, in world units. Nil when none
    /// of them has a gradient at all — a set of hard-edged discs, where a
    /// lattice has nothing to resolve and the density is bounded by the cap.
    static func narrowestBand(_ lights: [PreparedLight]) -> Float? {
        let bands = lights.compactMap { $0.band > 0.000001 ? $0.band : nil }
        return bands.min()
    }

    // MARK: - Density

    /// Lattice cells across the narrowest fade band.
    ///
    /// Both measured, both in `verify_scene_lighting.py`: 20 cells across the
    /// band holds the error to 0.79/255, under a quantisation step, and 10
    /// holds it to 3.09/255. `.interactive` takes the coarser one — it is the
    /// picture the artist is orbiting through, replaced sixty times a second.
    ///
    /// The measurement had to be taken OFF the lattice to mean anything. A
    /// uniform probe grid lands exactly on the lattice nodes whenever its
    /// spacing divides the cell, and reads an error of zero — which is how the
    /// first version of this constant came out four cells too coarse while its
    /// harness said it was exact.
    static let cellsPerBandFinal: Float = 20
    static let cellsPerBandInteractive: Float = 10

    /// A cell narrower than this buys nothing: it is already below what a
    /// gradient can show across a couple of pixels, and the lattice would
    /// approach the cost of shading every pixel exactly.
    ///
    /// It is also the limit of the guarantee above. A light whose gradient is
    /// only a few dozen pixels wide, spread over a full-frame layer, cannot get
    /// its 20 cells: the floor binds, and the harness measures what is left
    /// rather than claiming the bound still holds. The lever that would remove
    /// the caveat is to bound the lattice by the LIGHT's screen extent instead
    /// of the LAYER's — named here rather than left as a surprise, because a
    /// narrow bright light on a backdrop is the case it would fix.
    static let minimumCellPixels: Float = 2
    /// And wider than this, a lattice stops resolving anything at all, however
    /// broad the band — so a light with no gradient still gets a usable field.
    static let maximumCellPixels: Float = 96
    /// A hard ceiling on either side of the lattice, so a pathological light
    /// cannot make one frame cost a thousand.
    static let maximumLatticeSide = 384
}

/// A layer's lighting, sampled over the part of the screen it covers.
///
/// Screen space, because that is where the pixels being modulated are, and
/// because a layer's extent on screen is bounded by the frame however large its
/// artwork is — a 4096-pixel backdrop seen small costs what its screen size
/// costs, not what its texture does.
struct LightField {
    /// The rectangle of view pixels this field covers, y DOWN — the
    /// projection's own convention, so no flip lives in here.
    let originX: Float
    let originY: Float
    let width: Float
    let height: Float
    /// Lattice samples, row-major, `(columns + 1) * (rows + 1)` of them.
    let factors: [SIMD3<Float>]
    let additives: [SIMD3<Float>]
    let columns: Int
    let rows: Int

    /// Build the field for one layer.
    ///
    /// `worldAt` intersects the ray through a view pixel with the layer's own
    /// plane. It is a closure rather than a projection plus a plane because the
    /// caller already holds both and passing them separately is an invitation
    /// to build the plane twice.
    ///
    /// Nil when no light can reach this surface at all — the caller then draws
    /// the layer the way it always did, with no scratch buffer and no
    /// modulation.
    static func build(
        lighting: SceneLighting,
        mask: SceneLightMask,
        normal: SIMD3<Float>,
        screenBounds: (minX: Float, minY: Float, maxX: Float, maxY: Float),
        cellsPerBand: Float,
        pixelsPerWorldUnit: Float,
        worldAt: (Float, Float) -> SIMD3<Float>?
    ) -> LightField? {
        let reaching = lighting.lights(reaching: mask)
        if reaching.isEmpty && lighting.ambient.rgb == SIMD3<Float>(1, 1, 1) { return nil }

        let width = max(screenBounds.maxX - screenBounds.minX, 1)
        let height = max(screenBounds.maxY - screenBounds.minY, 1)

        // The cell comes from the narrowest BAND, converted to view pixels.
        // Radius would be the wrong variable: a wide light with a hair-thin
        // edge has a huge radius and a gradient a lattice chosen from it would
        // step straight over.
        let cellPixels: Float
        if let band = SceneLighting.narrowestBand(reaching), pixelsPerWorldUnit > 0.000001 {
            cellPixels = band * pixelsPerWorldUnit / max(cellsPerBand, 1)
        } else {
            cellPixels = SceneLighting.maximumCellPixels
        }
        let clamped = min(max(cellPixels, SceneLighting.minimumCellPixels),
                          SceneLighting.maximumCellPixels)
        let columns = min(max(Int((width / clamped).rounded(.up)), 1),
                          SceneLighting.maximumLatticeSide)
        let rows = min(max(Int((height / clamped).rounded(.up)), 1),
                       SceneLighting.maximumLatticeSide)

        var factors: [SIMD3<Float>] = []
        var additives: [SIMD3<Float>] = []
        factors.reserveCapacity((columns + 1) * (rows + 1))
        additives.reserveCapacity((columns + 1) * (rows + 1))
        let ambientOnly = (factor: lighting.ambient.rgb, additive: SIMD3<Float>.zero)
        for j in 0...rows {
            let y = screenBounds.minY + height * Float(j) / Float(rows)
            for i in 0...columns {
                let x = screenBounds.minX + width * Float(i) / Float(columns)
                // A lattice point whose ray misses the plane — it runs parallel
                // to a layer seen exactly edge-on, or meets it behind the eye —
                // gets the ambient and nothing else. Not a skip: the lattice is
                // a rectangle and a hole in it would interpolate garbage into
                // its neighbours.
                let shaded = worldAt(x, y).map {
                    SceneLighting.shade(reaching, ambient: lighting.ambient, at: $0, normal: normal)
                } ?? ambientOnly
                factors.append(LightField.finite(shaded.factor))
                additives.append(LightField.finite(shaded.additive))
            }
        }
        return LightField(originX: screenBounds.minX, originY: screenBounds.minY,
                          width: width, height: height,
                          factors: factors, additives: additives,
                          columns: columns, rows: rows)
    }

    /// Non-finite out, zero in.
    ///
    /// Sanitised ONCE PER LATTICE POINT rather than once per pixel, which is
    /// where it costs nothing. It is not paranoia: the bytes a pixel is written
    /// back as come from `UInt8(_:)`, which TRAPS on a NaN, so a single
    /// infinity surviving out of a corrupt project file would not produce a
    /// wrong colour — it would take the editor down while rendering a frame.
    static func finite(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(value.x.isFinite ? value.x : 0,
                     value.y.isFinite ? value.y : 0,
                     value.z.isFinite ? value.z : 0)
    }

    /// Bilinear sample at a view pixel.
    func sample(x: Float, y: Float) -> (factor: SIMD3<Float>, additive: SIMD3<Float>) {
        let u = min(max((x - originX) / width, 0), 1) * Float(columns)
        let v = min(max((y - originY) / height, 0), 1) * Float(rows)
        // The lower cell corner, one short of the last lattice index so that
        // the upper corner is always in range. A sample landing exactly on the
        // far edge takes the last cell with fx = 1, which is that edge.
        let i0 = min(Int(u), max(columns - 1, 0))
        let j0 = min(Int(v), max(rows - 1, 0))
        let i1 = min(i0 + 1, columns)
        let j1 = min(j0 + 1, rows)
        let fx = u - Float(i0)
        let fy = v - Float(j0)
        let stride = columns + 1
        func lerp2(_ values: [SIMD3<Float>]) -> SIMD3<Float> {
            let a = values[j0 * stride + i0]
            let b = values[j0 * stride + i1]
            let c = values[j1 * stride + i0]
            let d = values[j1 * stride + i1]
            return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
        }
        return (lerp2(factors), lerp2(additives))
    }
}

extension LightField {

    /// Light a drawn layer AND composite it onto the frame, in one walk.
    ///
    /// ## Why these are one operation and not three
    ///
    /// They were three: modulate the scratch, make a CGImage of it, draw that
    /// image onto the frame. Six passes over a layer's pixels in all — clear,
    /// draw, read, write, copy, composite — where drawing an UNLIT layer costs
    /// one. So lighting a set did not cost a little more than not lighting it;
    /// it cost six times as much, per lit layer, and that was three quarters of
    /// the whole frame. Measured in `verify_scene_frame_cost.py`.
    ///
    /// Reading the scratch once and writing the frame once collapses four of
    /// those passes into one, and deletes the per-layer `CGImage` — which was
    /// also the largest allocation in the frame, made and thrown away once per
    /// lit layer per frame.
    ///
    /// It is also one QUANTISATION less. The old form rounded the lit colour
    /// into eight bits and then composited that; this composites the unrounded
    /// value. Worst case measured at 0.98/255 — not a lot, and free.
    ///
    /// ## The arithmetic
    ///
    /// Both bitmaps are `premultipliedFirst` in a little-endian word, so the
    /// bytes are B, G, R, A and the colours are already multiplied by alpha.
    ///
    ///     lit = clamp(src * factor + additive * srcAlpha, 0, srcAlpha)
    ///     dst = lit + dst * (1 - srcAlpha)
    ///
    /// The additive term is scaled by alpha because it is a colour added to the
    /// SURFACE, and the surface only exists where there is alpha — added flat,
    /// an additive light would light up the transparent margin of every sprite
    /// and surround its subject with a rectangle of glow.
    ///
    /// - Parameters:
    ///   - source: the scratch the layer was drawn into.
    ///   - destination: the frame.
    ///   - origin: where the scratch's bottom-left sits in the frame, in the
    ///     frame's own pixels.
    ///   - viewRect: the scratch's rectangle in view pixels, y DOWN, which is
    ///     what this field is indexed in.
    func composite(from source: CGContext, into destination: CGContext,
                   originX: Int, originY: Int,
                   viewRect: (minX: Float, minY: Float, maxX: Float, maxY: Float)) {
        guard let sourceBase = source.data, let destinationBase = destination.data
        else { return }
        let width = source.width, height = source.height
        guard width > 0, height > 0 else { return }
        let sourceRow = source.bytesPerRow, destinationRow = destination.bytesPerRow
        let sourcePixels = sourceBase.bindMemory(to: UInt8.self,
                                                 capacity: sourceRow * height)
        let destinationPixels = destinationBase.bindMemory(
            to: UInt8.self, capacity: destinationRow * destination.height)
        let inverse: Float = 1.0 / 255.0

        for row in 0..<height {
            let destinationRowIndex = originY + row
            guard destinationRowIndex >= 0, destinationRowIndex < destination.height
            else { continue }
            // CGContext row 0 is the BOTTOM of the bitmap; the field speaks y
            // down. The +0.5 samples the centre of the pixel rather than its
            // corner, which is a half-cell shift over the whole layer if
            // dropped — small, and exactly the kind of small that shows as the
            // light sitting slightly off its lamp.
            let viewY = viewRect.maxY - (Float(height - 1 - row) + 0.5)
            let sourceLine = sourcePixels + row * sourceRow
            let destinationLine = destinationPixels + destinationRowIndex * destinationRow
            for column in 0..<width {
                let sourceOffset = column * 4
                let alpha = sourceLine[sourceOffset + 3]
                // NOTHING DRAWN HERE. The commonest case by far — a layer's
                // region is a rectangle and its artwork is not — and skipping
                // it leaves the frame's own pixel exactly as it was, which is
                // what compositing a transparent pixel means.
                guard alpha > 0 else { continue }
                let destinationColumn = originX + column
                guard destinationColumn >= 0, destinationColumn < destination.width
                else { continue }
                let destinationOffset = destinationColumn * 4

                let viewX = viewRect.minX + Float(column) + 0.5
                let shaded = sample(x: viewX, y: viewY)
                let alphaF = Float(alpha) * inverse
                var rgb = SIMD3<Float>(Float(sourceLine[sourceOffset + 2]),
                                       Float(sourceLine[sourceOffset + 1]),
                                       Float(sourceLine[sourceOffset])) * inverse
                rgb = rgb * shaded.factor + shaded.additive * alphaF
                // Premultiplied: no channel may exceed its own alpha, or the
                // un-multiplied colour would be over 1 and the composite would
                // brighten whatever is behind it.
                rgb = simd_clamp(rgb, .zero, SIMD3<Float>(repeating: alphaF))

                // Source-over, onto whatever the frame already holds.
                let keep = 1 - alphaF
                let under = SIMD3<Float>(Float(destinationLine[destinationOffset + 2]),
                                         Float(destinationLine[destinationOffset + 1]),
                                         Float(destinationLine[destinationOffset])) * inverse
                let out = rgb + under * keep
                let outAlpha = alphaF + Float(destinationLine[destinationOffset + 3])
                    * inverse * keep

                destinationLine[destinationOffset + 2] = UInt8((min(out.x, 1) * 255).rounded())
                destinationLine[destinationOffset + 1] = UInt8((min(out.y, 1) * 255).rounded())
                destinationLine[destinationOffset] = UInt8((min(out.z, 1) * 255).rounded())
                destinationLine[destinationOffset + 3] = UInt8((min(outAlpha, 1) * 255).rounded())
            }
        }
    }
}
