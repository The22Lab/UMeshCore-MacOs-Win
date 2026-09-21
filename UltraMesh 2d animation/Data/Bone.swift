import Foundation
import simd

struct Bone: Identifiable, Equatable {
    let id: UUID
    var name: String
    var parentID: UUID?
    var baseTransform: Transform3D2D
    var localTransform: Transform3D2D
    var length: Float
    var animationClip: AnimationClip
    /// The colour weight paint gives this bone, or nil when nothing is bound
    /// to it.
    ///
    /// It belongs to the BINDING, not to the bone. It used to be handed out at
    /// creation, by bone count, and never touched again — so an unbound bone
    /// kept the colour it had been painted in, looking bound in the overlay and
    /// in the hierarchy with nothing painted in it. And keying it to a count
    /// meant a bone created after a deletion reused a colour that was still
    /// live somewhere else.
    var color: SIMD4<Float>?

    init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        baseTransform: Transform3D2D? = nil,
        localTransform: Transform3D2D = Transform3D2D(),
        length: Float = 96,
        animationClip: AnimationClip? = nil,
        color: SIMD4<Float>? = nil
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.baseTransform = baseTransform ?? localTransform
        self.localTransform = localTransform
        self.length = length
        self.animationClip = animationClip ?? AnimationClip(name: name)
        self.color = color
    }

    /// Golden-ratio hue progression, with lightness and saturation walking
    /// beside it on coprime cycles.
    ///
    /// Pastel: modest saturation, light. These are drawn as translucent fills
    /// over a near-white canvas, and the vivid ramp this replaces fought the
    /// artwork underneath instead of tinting it. Light, though, is a range and
    /// not a point — see below.
    ///
    /// Readability does not come from the fill. It comes from the contour,
    /// which `UM.contourInk` derives by darkening this colour to a fixed
    /// luminance — so every hue lands at the same contrast against the canvas
    /// no matter how light the pastel is. A flat multiplier cannot do that: a
    /// pastel yellow at 65 % is still pale, while a pastel blue at 65 % is
    /// already dark.
    ///
    /// WHY THE CYCLES ARE COPRIME. The value index used to be
    /// `index / saturations.count`, so six consecutive bones shared one
    /// lightness and differed in hue and a little saturation and in nothing
    /// else. Six shades of the same weight is exactly what "no se logran
    /// diferenciar" describes. 5 saturations against 7 values move BOTH on
    /// every bone and do not repeat a pair for 35 of them.
    static func distinctColor(index: Int) -> SIMD4<Float> {
        let phi: Float = 0.618033988
        let hue = (Float(index) * phi).truncatingRemainder(dividingBy: 1.0)
        let saturations: [Float] = [0.60, 0.38, 0.46, 0.32, 0.54]
        let values: [Float]      = [0.99, 0.82, 0.93, 0.76, 0.97, 0.88, 0.86]
        return SIMD4<Float>(hsvToRgb(h: hue,
                                     s: saturations[index % saturations.count],
                                     v: values[index % values.count]), 1.0)
    }

    /// The alpha the weight overlay draws a bone colour at.
    ///
    /// Comparing raw swatches flatters them: alpha pulls every colour toward
    /// the canvas and shrinks the differences between them. Two bones are told
    /// apart AS DRAWN, so that is where the distance is measured.
    static let overlayAlpha: Float = 0.60

    /// A colour composited the way the overlay composites it.
    static func asDrawn(_ colour: SIMD4<Float>,
                        over background: SIMD3<Float> = SIMD3<Float>(repeating: 1)) -> SIMD3<Float> {
        SIMD3<Float>(colour.x, colour.y, colour.z) * overlayAlpha
            + background * (1 - overlayAlpha)
    }

    /// OKLab, for asking whether two colours LOOK different.
    ///
    /// Hue distance answered a different question. Two pastels a tenth of a
    /// turn apart, both light, are the same wash of colour once they are drawn
    /// over the artwork — and the old search happily reported a healthy hue gap
    /// while handing out pairs the eye could not separate. Measured on the rig
    /// this came from: eight bound bones, closest pair ΔE 0.03, where the
    /// just-noticeable difference is about 0.02.
    static func oklab(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        func linear(_ c: Float) -> Float {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(rgb.x), g = linear(rgb.y), b = linear(rgb.z)
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        func cubeRoot(_ v: Float) -> Float { v < 0 ? -pow(-v, 1.0 / 3.0) : pow(v, 1.0 / 3.0) }
        let l_ = cubeRoot(l), m_ = cubeRoot(m), s_ = cubeRoot(s)
        return SIMD3<Float>(
            0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    /// A colour for a bone that has just been bound: the one that sits furthest
    /// — perceptually, as drawn — from every colour already in use.
    ///
    /// Walked along the ramp from a per-bone offset, so the answer looks
    /// arbitrary while being decided by separation rather than by luck — and it
    /// is decided by the SET in use, not by a running count, so deleting a bone
    /// can never leave two survivors wearing the same colour.
    static func bindingColor(for boneID: UUID, avoiding used: [SIMD4<Float>]) -> SIMD4<Float> {
        let offset = Int(abs(boneID.hashValue) % 997)
        guard !used.isEmpty else { return distinctColor(index: offset) }

        let usedLab = used.map { oklab(asDrawn($0)) }
        var best = distinctColor(index: offset)
        var bestGap: Float = -1
        // Wider than the old 60: the ramp repeats a saturation/value pair only
        // every 35 steps, so a short walk can miss the lightness that would
        // have separated this bone from the ones in use.
        for step in 0..<96 {
            let candidate = distinctColor(index: offset + step)
            let candidateLab = oklab(asDrawn(candidate))
            var gap: Float = .greatestFiniteMagnitude
            for lab in usedLab {
                gap = min(gap, simd_distance(candidateLab, lab))
            }
            if gap > bestGap {
                bestGap = gap
                best = candidate
            }
        }
        return best
    }

    private static func hsvToRgb(h: Float, s: Float, v: Float) -> SIMD3<Float> {
        let i = floor(h * 6)
        let f = h * 6 - i
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        switch Int(i.truncatingRemainder(dividingBy: 6)) {
        case 0: return SIMD3<Float>(v, t, p)
        case 1: return SIMD3<Float>(q, v, p)
        case 2: return SIMD3<Float>(p, v, t)
        case 3: return SIMD3<Float>(p, q, v)
        case 4: return SIMD3<Float>(t, p, v)
        default: return SIMD3<Float>(v, p, q)
        }
    }

    func worldMatrix(parentMatrix: simd_float4x4?) -> simd_float4x4 {
        let local = localTransform.matrix()
        return (parentMatrix ?? MatrixUtilities.identity()) * local
    }

    var localStart: SIMD2<Float> {
        SIMD2<Float>(localTransform.position.x, localTransform.position.y)
    }

    var localEnd: SIMD2<Float> {
        let direction = SIMD2<Float>(cos(localTransform.rotation.z), sin(localTransform.rotation.z))
        return localStart + direction * length
    }

    static func makeRoot(name: String, start: SIMD2<Float>, end: SIMD2<Float>) -> Bone {
        make(name: name, start: start, end: end, parentID: nil, parentMatrix: nil)
    }

    static func make(
        name: String,
        start: SIMD2<Float>,
        end: SIMD2<Float>,
        parentID: UUID?,
        parentMatrix: simd_float4x4?
    ) -> Bone {
        let parentInverse = parentMatrix.map(simd_inverse)
        let localStart3 = parentInverse.map {
            MatrixUtilities.transformPoint(SIMD3<Float>(start.x, start.y, 0), with: $0)
        } ?? SIMD3<Float>(start.x, start.y, 0)
        let localEnd3 = parentInverse.map {
            MatrixUtilities.transformPoint(SIMD3<Float>(end.x, end.y, 0), with: $0)
        } ?? SIMD3<Float>(end.x, end.y, 0)
        let localStart = SIMD2<Float>(localStart3.x, localStart3.y)
        let localEnd = SIMD2<Float>(localEnd3.x, localEnd3.y)
        let delta = localEnd - localStart
        let length = max(simd_length(delta), 12)
        let rotation = atan2(delta.y, delta.x)
        return Bone(
            name: name,
            parentID: parentID,
            baseTransform: Transform3D2D(
                position: SIMD3<Float>(localStart.x, localStart.y, 0),
                rotation: SIMD3<Float>(0, 0, rotation)
            ),
            localTransform: Transform3D2D(
                position: SIMD3<Float>(localStart.x, localStart.y, 0),
                rotation: SIMD3<Float>(0, 0, rotation)
            ),
            length: length,
            animationClip: AnimationClip(name: name)
        )
    }
}
