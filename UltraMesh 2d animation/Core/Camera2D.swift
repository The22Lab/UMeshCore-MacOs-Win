import Foundation
import Combine
import simd

final class Camera2D: ObservableObject {
    @Published var position: SIMD2<Float> = .zero
    @Published var zoom: Float = 1.0

    private var panVelocity = SIMD2<Float>(repeating: 0)
    private var targetZoom: Float = 1.0
    private var targetPosition: SIMD2<Float> = .zero
    private var lastViewSize: SIMD2<Float> = SIMD2<Float>(repeating: 1)

    private let minZoom: Float = 0.1
    private let maxZoom: Float = 10.0
    private let zoomLerp: Float = 0.22
    private let maxZoomStep: Float = 0.25
    private let panFriction: Float = 0.82

    func pan(screenDelta: SIMD2<Float>) {
        let worldDelta = SIMD2<Float>(screenDelta.x, -screenDelta.y) / max(0.0001, zoom)
        position -= worldDelta
        targetPosition = position
        panVelocity = worldDelta
    }

    func zoom(at screenPoint: SIMD2<Float>, viewSize: SIMD2<Float>, magnification: Float) {
        let proposed = zoom * (1 + magnification)
        targetZoom = max(minZoom, min(maxZoom, proposed))

        let worldBefore = screenToWorld(screenPoint: screenPoint, viewSize: viewSize)
        let clampedStep = max(-maxZoomStep, min(maxZoomStep, targetZoom - zoom))
        zoom = max(minZoom, min(maxZoom, zoom + clampedStep))
        let worldAfter = screenToWorld(screenPoint: screenPoint, viewSize: viewSize)
        position += worldBefore - worldAfter
        targetPosition = position
    }

    func update(deltaTime: Float, viewSize: SIMD2<Float>) {
        lastViewSize = viewSize

        if simd_length(panVelocity) > 0.0001 {
            position -= panVelocity
            panVelocity *= pow(panFriction, deltaTime * 60)
        }

        if abs(targetZoom - zoom) > 0.0001 {
            let step = (targetZoom - zoom) * zoomLerp
            zoom = max(minZoom, min(maxZoom, zoom + step))
        }

        let positionDelta = targetPosition - position
        if simd_length(positionDelta) > 0.001 {
            position += positionDelta * 0.18
        }
    }

    func screenToWorld(screenPoint: SIMD2<Float>, viewSize: SIMD2<Float>) -> SIMD2<Float> {
        let centered = screenPoint - viewSize * 0.5
        return centered / max(0.0001, zoom) + position
    }

    func worldToScreen(worldPoint: SIMD2<Float>, viewSize: SIMD2<Float>) -> SIMD2<Float> {
        return (worldPoint - position) * zoom + viewSize * 0.5
    }

    func frame(bounds: Bounds2D, viewSize: SIMD2<Float>? = nil, padding: Float = 40) {
        let size = SIMD2<Float>(max(bounds.size.x, 1), max(bounds.size.y, 1))
        let padded = size + SIMD2<Float>(repeating: padding * 2)
        let useSize = viewSize ?? lastViewSize
        let zoomX = useSize.x / padded.x
        let zoomY = useSize.y / padded.y
        let target = max(minZoom, min(maxZoom, min(zoomX, zoomY)))
        targetZoom = target
        targetPosition = bounds.center
    }
}
