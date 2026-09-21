import SwiftUI
import simd

/// Canvas overlay that visualizes the active Transform Constraint. Draws a dashed
/// line from the target bone's world position to each affected bone's world position,
/// with an arrowhead at the affected end so the data-flow direction is obvious.
///
/// Visible only while a Transform Constraint is the selected constraint and enabled.
/// Sits in the same SwiftUI overlay layer as other badges so it inherits hit-testing
/// transparency without disrupting tool input.
struct TransformConstraintGizmoView: View {
    @ObservedObject var sceneManager: SceneManager
    @ObservedObject var camera: CameraState
    let viewSize: CGSize

    private let tint = Color(red: 0.28, green: 0.68, blue: 1.00)

    var body: some View {
        Canvas { context, _ in
            guard let constraintID = sceneManager.selectedConstraintID,
                  let constraint = sceneManager.skeleton.transformConstraints.first(where: { $0.id == constraintID }),
                  constraint.enabled else {
                return
            }

            let worldMatrices = sceneManager.skeleton.worldMatrices()
            guard let targetMatrix = worldMatrices[constraint.targetBoneID] else { return }
            let targetWorld = SIMD2<Float>(targetMatrix.columns.3.x, targetMatrix.columns.3.y)
            let targetScreen = camera.worldToScreen(
                CGPoint(x: CGFloat(targetWorld.x), y: CGFloat(targetWorld.y)),
                viewSize: viewSize
            )

            // Target marker — slightly larger filled circle to read as the "source".
            let targetMarker = Path(ellipseIn: CGRect(
                x: targetScreen.x - 5, y: targetScreen.y - 5, width: 10, height: 10
            ))
            context.fill(targetMarker, with: .color(tint))
            context.stroke(
                targetMarker,
                with: .color(.white.opacity(0.9)),
                lineWidth: 1.5
            )

            for boneID in constraint.affectedBones {
                guard let m = worldMatrices[boneID] else { continue }
                let boneWorld = SIMD2<Float>(m.columns.3.x, m.columns.3.y)
                let boneScreen = camera.worldToScreen(
                    CGPoint(x: CGFloat(boneWorld.x), y: CGFloat(boneWorld.y)),
                    viewSize: viewSize
                )

                drawDashedArrow(from: targetScreen, to: boneScreen, in: &context)

                // Affected marker — hollow ring so it visually differs from the target.
                let ring = Path(ellipseIn: CGRect(
                    x: boneScreen.x - 4, y: boneScreen.y - 4, width: 8, height: 8
                ))
                context.stroke(ring, with: .color(tint), lineWidth: 2.0)
                let inner = Path(ellipseIn: CGRect(
                    x: boneScreen.x - 2, y: boneScreen.y - 2, width: 4, height: 4
                ))
                context.fill(inner, with: .color(.white.opacity(0.85)))
            }
        }
        .allowsHitTesting(false)
    }

    private func drawDashedArrow(from start: CGPoint, to end: CGPoint, in context: inout GraphicsContext) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0.5 else { return }

        // Pull endpoints in by the radius of each marker so the line doesn't visually
        // cross the circles. 6 px at target, 5 px at affected — matches the marker radii.
        let ux = dx / length
        let uy = dy / length
        let trimmedStart = CGPoint(x: start.x + ux * 6, y: start.y + uy * 6)
        let trimmedEnd   = CGPoint(x: end.x - ux * 7,   y: end.y - uy * 7)

        // Dashed line — communicates "constraint relationship" rather than rig bone.
        var line = Path()
        line.move(to: trimmedStart)
        line.addLine(to: trimmedEnd)
        let strokeStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4])
        context.stroke(line, with: .color(tint.opacity(0.85)), style: strokeStyle)

        // Arrowhead at the affected end — open chevron, matches inspector minimalism.
        let arrowLength: CGFloat = 9
        let arrowWidth: CGFloat = 5
        let leftAngle = atan2(uy, ux) + .pi * 0.85
        let rightAngle = atan2(uy, ux) - .pi * 0.85
        let leftPoint = CGPoint(
            x: trimmedEnd.x + cos(leftAngle) * arrowLength,
            y: trimmedEnd.y + sin(leftAngle) * arrowLength
        )
        let rightPoint = CGPoint(
            x: trimmedEnd.x + cos(rightAngle) * arrowLength,
            y: trimmedEnd.y + sin(rightAngle) * arrowLength
        )
        _ = arrowWidth // reserved for outlined arrowhead variant if needed later
        var head = Path()
        head.move(to: leftPoint)
        head.addLine(to: trimmedEnd)
        head.addLine(to: rightPoint)
        context.stroke(head, with: .color(tint), lineWidth: 1.8)
    }
}
