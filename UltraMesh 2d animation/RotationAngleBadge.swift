import SwiftUI

/// Angle badge for the rotation gizmo.
struct RotationAngleBadge: View {
    let badge: RotationBadge

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(badge.color))
                .frame(width: 6, height: 6)
            Text(String(format: "%@  %+.1f°", badge.axisLabel, badge.degrees))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Color(badge.color))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.platformWindowBackground.opacity(0.92))
                .overlay(
                    Capsule()
                        .stroke(Color(badge.color).opacity(0.45), lineWidth: 0.5)
                )
        )
    }
}

// ✓ COMPLETE — RotationAngleBadge.swift
