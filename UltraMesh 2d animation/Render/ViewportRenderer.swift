import Foundation
import simd

final class ViewportRenderer {
    typealias WorldToNDC = (SIMD2<Float>, CGSize) -> SIMD2<Float>

    /// The canvas guides: the two black lines through the origin, and nothing
    /// else. There used to be a faint 8-unit and 64-unit line grid behind them
    /// as well; with the checkerboard now living in world space it was a third
    /// pattern saying the same thing, so it is gone rather than switched off.
    struct GuideVertices {
        var axes: [GizmoVertex]
    }

    private struct GuideCacheKey: Equatable {
        var viewWidth: Float
        var viewHeight: Float
        var originX: Float
        var originY: Float
        var zoom: Float
    }

    private let worldToNDC: WorldToNDC
    private var cachedGuideKey: GuideCacheKey?
    private var cachedGuideVertices = GuideVertices(axes: [])

    init(worldToNDC: @escaping WorldToNDC) {
        self.worldToNDC = worldToNDC
    }

    func guideVertices(viewSize: CGSize, camera: CameraState) -> GuideVertices {
        let key = GuideCacheKey(
            viewWidth: Float(viewSize.width),
            viewHeight: Float(viewSize.height),
            originX: Float(camera.origin.x),
            originY: Float(camera.origin.y),
            zoom: Float(camera.zoom)
        )

        if cachedGuideKey == key {
            return cachedGuideVertices
        }

        let vertices = GuideVertices(
            axes: axisVertices(viewSize: viewSize, camera: camera)
        )
        cachedGuideKey = key
        cachedGuideVertices = vertices
        return vertices
    }

    func axisVertices(viewSize: CGSize, camera: CameraState) -> [GizmoVertex] {
        let worldMin = camera.screenToWorld(CGPoint(x: 0, y: viewSize.height), viewSize: viewSize)
        let worldMax = camera.screenToWorld(CGPoint(x: viewSize.width, y: 0), viewSize: viewSize)

        let axisColor = SIMD4<Float>(0.11, 0.11, 0.11, 0.82)
        let axisShadow = SIMD4<Float>(0.0, 0.0, 0.0, 0.18)

        let xStart = SIMD2<Float>(Float(worldMin.x), 0)
        let xEnd = SIMD2<Float>(Float(worldMax.x), 0)
        let yStart = SIMD2<Float>(0, Float(worldMin.y))
        let yEnd = SIMD2<Float>(0, Float(worldMax.y))

        return thickLine(
            from: xStart,
            to: xEnd,
            thickness: 2.0,
            color: axisShadow,
            viewSize: viewSize
        )
        + thickLine(
            from: yStart,
            to: yEnd,
            thickness: 2.0,
            color: axisShadow,
            viewSize: viewSize
        )
        + thickLine(
            from: xStart,
            to: xEnd,
            thickness: 1.0,
            color: axisColor,
            viewSize: viewSize
        )
        + thickLine(
            from: yStart,
            to: yEnd,
            thickness: 1.0,
            color: axisColor,
            viewSize: viewSize
        )
    }

    private func line(from start: SIMD2<Float>, to end: SIMD2<Float>, color: SIMD4<Float>, viewSize: CGSize) -> [GizmoVertex] {
        [
            GizmoVertex(position: worldToNDC(start, viewSize), color: color),
            GizmoVertex(position: worldToNDC(end, viewSize), color: color)
        ]
    }

    private func thickLine(from start: SIMD2<Float>,
                           to end: SIMD2<Float>,
                           thickness: Float,
                           color: SIMD4<Float>,
                           viewSize: CGSize) -> [GizmoVertex] {
        let ndcStart = worldToNDC(start, viewSize)
        let ndcEnd = worldToNDC(end, viewSize)
        let direction = ndcEnd - ndcStart
        let length = simd_length(direction)
        guard length > 0.0001 else { return [] }

        let pixelToNDCX = 2.0 / Float(max(viewSize.width, 1))
        let pixelToNDCY = 2.0 / Float(max(viewSize.height, 1))
        let normal = SIMD2<Float>(-direction.y / length, direction.x / length)
        let offset = SIMD2<Float>(
            normal.x * thickness * pixelToNDCX,
            normal.y * thickness * pixelToNDCY
        )

        let p0 = ndcStart + offset
        let p1 = ndcStart - offset
        let p2 = ndcEnd + offset
        let p3 = ndcEnd - offset

        return [
            GizmoVertex(position: p0, color: color),
            GizmoVertex(position: p1, color: color),
            GizmoVertex(position: p2, color: color),
            GizmoVertex(position: p2, color: color),
            GizmoVertex(position: p1, color: color),
            GizmoVertex(position: p3, color: color)
        ]
    }

    private func worldToNDC(_ world: SIMD2<Float>, _ viewSize: CGSize) -> SIMD2<Float> {
        worldToNDC(world, viewSize)
    }
}
