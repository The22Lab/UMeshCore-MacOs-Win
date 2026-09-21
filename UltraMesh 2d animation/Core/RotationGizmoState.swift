import Foundation
import Combine
import CoreGraphics
import simd

/// State for the 3D rotation gizmo.
@MainActor
final class RotationGizmoState: ObservableObject {

    @Published var rotationX: Float = 0
    @Published var rotationY: Float = 0
    @Published var rotationZ: Float = 0
    @Published var activeArc: Int = 0
    @Published var hoveredArc: Int = 0
    @Published var isDragging: Bool = false
    @Published var angleBadge: RotationBadge? = nil

    var cameraYaw: Float {
        didSet { UserDefaults.standard.set(cameraYaw, forKey: "RotationGizmo.CameraYaw") }
    }
    var cameraPitch: Float {
        didSet { UserDefaults.standard.set(cameraPitch, forKey: "RotationGizmo.CameraPitch") }
    }

    private var dragStartRotX: Float = 0
    private var dragStartRotY: Float = 0
    private var dragStartRotZ: Float = 0
    private var dragOriginScreen: SIMD2<Float> = .zero
    private var dragTangent: SIMD2<Float> = SIMD2<Float>(1, 0)
    private var dragRadius: Float = 64

    weak var undoManager: UndoManager?

    init() {
        let yaw = UserDefaults.standard.float(forKey: "RotationGizmo.CameraYaw")
        let pitch = UserDefaults.standard.float(forKey: "RotationGizmo.CameraPitch")
        self.cameraYaw = yaw == 0 ? 0.61 : yaw
        self.cameraPitch = pitch == 0 ? 0.35 : pitch
    }

    func updateRadius(_ radius: Float) {
        dragRadius = max(1, radius)
    }

    func mouseDown(screenPt: CGPoint, hitArc: Int, arcTangent: SIMD2<Float>) {
        guard hitArc > 0 else { return }
        undoManager?.beginUndoGrouping()
        let oldX = rotationX
        let oldY = rotationY
        let oldZ = rotationZ
        undoManager?.registerUndo(withTarget: self) { s in
            s.rotationX = oldX
            s.rotationY = oldY
            s.rotationZ = oldZ
        }
        activeArc = hitArc
        dragStartRotX = rotationX
        dragStartRotY = rotationY
        dragStartRotZ = rotationZ
        dragOriginScreen = SIMD2<Float>(Float(screenPt.x), Float(screenPt.y))
        dragTangent = arcTangent
        isDragging = true
    }

    func mouseDragged(currentPt: CGPoint, zoom: Float, isShiftDown: Bool) {
        guard isDragging, activeArc > 0 else { return }
        let current = SIMD2<Float>(Float(currentPt.x), Float(currentPt.y))
        let delta = current - dragOriginScreen
        let scalar = simd_dot(delta, dragTangent)
        let degrees = scalar * (180 / (Float.pi * max(dragRadius, 1))) / max(zoom, 0.01)

        switch activeArc {
        case 1:
            rotationX = (dragStartRotX + degrees).clamped(to: -360...360)
        case 2:
            rotationY = (dragStartRotY + degrees).clamped(to: -360...360)
        case 3:
            rotationZ = dragStartRotZ + degrees
        default:
            break
        }

        if isShiftDown {
            rotationX = (rotationX / 15).rounded() * 15
            rotationY = (rotationY / 15).rounded() * 15
            rotationZ = (rotationZ / 15).rounded() * 15
        }

        angleBadge = RotationBadge(
            axisLabel: activeArc == 1 ? "X" : activeArc == 2 ? "Y" : "Z",
            degrees: activeArc == 1 ? rotationX : activeArc == 2 ? rotationY : rotationZ,
            color: activeArc == 1
                ? CGColor(red: 0.30, green: 0.69, blue: 0.49, alpha: 1)
                : activeArc == 2
                    ? CGColor(red: 0.22, green: 0.54, blue: 0.85, alpha: 1)
                    : CGColor(red: 0.89, green: 0.30, blue: 0.29, alpha: 1),
            position: currentPt
        )
    }

    func mouseUp() {
        isDragging = false
        activeArc = 0
        angleBadge = nil
        undoManager?.endUndoGrouping()
    }

    func reset() {
        undoManager?.beginUndoGrouping()
        let oldX = rotationX
        let oldY = rotationY
        let oldZ = rotationZ
        undoManager?.registerUndo(withTarget: self) { s in
            s.rotationX = oldX
            s.rotationY = oldY
            s.rotationZ = oldZ
        }
        rotationX = 0
        rotationY = 0
        rotationZ = 0
        undoManager?.endUndoGrouping()
    }
}

/// Floating badge for the rotation gizmo.
struct RotationBadge {
    let axisLabel: String
    let degrees: Float
    let color: CGColor
    let position: CGPoint
}

// ✓ COMPLETE — RotationGizmoState.swift
