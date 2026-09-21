import Foundation
import simd

enum CameraProjectionMode {
    case orthographic
    case perspective
}

struct Camera3D {
    var position: SIMD3<Float> = .zero
    var rotation: SIMD3<Float> = .zero
    var projection: CameraProjectionMode = .orthographic
    var orthoScale: Float = 1.0
    var fovDegrees: Float = 45.0
    var nearZ: Float = 0.1
    var farZ: Float = 500.0

    func viewMatrix() -> simd_float4x4 {
        let t = MatrixUtilities.translation(SIMD3<Float>(-position.x, -position.y, -position.z))
        let rz = MatrixUtilities.rotationZ(-rotation.z)
        let ry = MatrixUtilities.rotationY(-rotation.y)
        let rx = MatrixUtilities.rotationX(-rotation.x)
        return rz * ry * rx * t
    }

    func projectionMatrix(viewSize: SIMD2<Float>) -> simd_float4x4 {
        switch projection {
        case .orthographic:
            let w = max(1.0, viewSize.x) * orthoScale
            let h = max(1.0, viewSize.y) * orthoScale
            return ortho(left: -w * 0.5, right: w * 0.5, bottom: -h * 0.5, top: h * 0.5, near: nearZ, far: farZ)
        case .perspective:
            let aspect = max(0.001, viewSize.x / max(1.0, viewSize.y))
            let fov = fovDegrees * Float.pi / 180
            return perspective(fovY: fov, aspect: aspect, near: nearZ, far: farZ)
        }
    }

    private func ortho(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> simd_float4x4 {
        let rl = 1.0 / (right - left)
        let tb = 1.0 / (top - bottom)
        let fn = 1.0 / (far - near)
        return simd_float4x4(columns: (
            SIMD4<Float>(2 * rl, 0, 0, 0),
            SIMD4<Float>(0, 2 * tb, 0, 0),
            SIMD4<Float>(0, 0, -2 * fn, 0),
            SIMD4<Float>(-(right + left) * rl, -(top + bottom) * tb, -(far + near) * fn, 1)
        ))
    }

    private func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let f = 1.0 / tan(fovY * 0.5)
        let nf = 1.0 / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(f / aspect, 0, 0, 0),
            SIMD4<Float>(0, f, 0, 0),
            SIMD4<Float>(0, 0, (far + near) * nf, -1),
            SIMD4<Float>(0, 0, (2 * far * near) * nf, 0)
        ))
    }
}
