import Combine
import CoreGraphics
import Foundation

@MainActor
final class SkewGizmoState: ObservableObject {

    @Published var shearX: Float = 0
    @Published var shearY: Float = 0
    @Published var activeAxis: ShearAxis? = nil
    @Published var hoveredArc: Int = 0
    @Published var angleBadge: AngleBadge? = nil
    @Published var isDragging: Bool = false

    weak var undoManager: UndoManager?
    private var dragStartX: Float = 0
    private var dragStartY: Float = 0

    func mouseDown(screenPt: CGPoint, hitArc: Int) {
        guard hitArc > 0 else { return }
        activeAxis = switch hitArc {
        case 1: .shearX
        case 2: .shearY
        default: .shearZ
        }
        isDragging = true
        dragStartX = shearX
        dragStartY = shearY
        let oldX = shearX
        let oldY = shearY
        undoManager?.registerUndo(withTarget: self) { s in
            s.shearX = oldX
            s.shearY = oldY
        }
    }

    func applyDrag(deltaDegrees: Float, axis: ShearAxis, isSnap: Bool, cursor: CGPoint) {
        guard isDragging else { return }
        var d = deltaDegrees
        if isSnap {
            d = (d / 1.0).rounded() * 1.0
        }
        switch axis {
        case .shearX:
            shearX = (dragStartX + d).clamped(to: -180...180)
        case .shearY:
            shearY = (dragStartY + d).clamped(to: -180...180)
        case .shearZ:
            shearX = (dragStartX + d).clamped(to: -180...180)
            shearY = (dragStartY - d).clamped(to: -180...180)
        }

        let val: Float
        let label: String
        let color: CGColor
        switch axis {
        case .shearX:
            val = shearX
            label = "ShX"
            color = CGColor(red: 0.92, green: 0.36, blue: 0.34, alpha: 1)
        case .shearY:
            val = shearY
            label = "ShY"
            color = CGColor(red: 0.42, green: 0.82, blue: 0.56, alpha: 1)
        case .shearZ:
            val = d
            label = "ShZ"
            color = CGColor(red: 0.38, green: 0.66, blue: 0.95, alpha: 1)
        }
        angleBadge = AngleBadge(
            text: String(format: "%@  %+.1f°", label, val),
            position: cursor,
            color: color
        )
    }

    func mouseUp() {
        isDragging = false
        activeAxis = nil
        angleBadge = nil
    }
}
