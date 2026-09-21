import Foundation
import simd

struct Bounds2D {
    var min: SIMD2<Float>
    var max: SIMD2<Float>

    var size: SIMD2<Float> { max - min }
    var center: SIMD2<Float> { (min + max) * 0.5 }

    static func empty() -> Bounds2D {
        Bounds2D(min: SIMD2<Float>(repeating: .infinity), max: SIMD2<Float>(repeating: -.infinity))
    }

    mutating func include(_ point: SIMD2<Float>) {
        min = SIMD2<Float>(Swift.min(min.x, point.x), Swift.min(min.y, point.y))
        max = SIMD2<Float>(Swift.max(max.x, point.x), Swift.max(max.y, point.y))
    }

    var isValid: Bool { min.x <= max.x && min.y <= max.y }
}
