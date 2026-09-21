import Foundation
import simd

struct Transform3D2D: Equatable {
    var position: SIMD3<Float>
    var rotation: SIMD3<Float>
    var scale: SIMD3<Float>
    var skew: SIMD2<Float>

    init(position: SIMD3<Float> = .zero,
         rotation: SIMD3<Float> = .zero,
         scale: SIMD3<Float> = SIMD3<Float>(repeating: 1),
         skew: SIMD2<Float> = .zero) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
        self.skew = skew
    }

    func matrix() -> simd_float4x4 {
        let t = MatrixUtilities.translation(position)
        let rz = MatrixUtilities.rotationZ(rotation.z)
        let ry = MatrixUtilities.rotationY(rotation.y)
        let rx = MatrixUtilities.rotationX(rotation.x)
        let sk = MatrixUtilities.skew(skew)
        let sc = MatrixUtilities.scale(scale)
        return t * rz * ry * rx * sk * sc
    }
}
