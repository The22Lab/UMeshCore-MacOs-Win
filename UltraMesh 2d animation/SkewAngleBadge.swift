import SwiftUI

struct SkewAngleBadge: View {

    let badge: AngleBadge
    let viewSize: CGSize

    var body: some View {
        Text(badge.text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(Color(badge.color))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.platformWindowBackground.opacity(0.88))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(badge.color).opacity(0.5), lineWidth: 0.5)
                    )
            )
            .position(
                x: badge.position.x + 28,
                y: badge.position.y - 22
            )
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .animation(.easeOut(duration: 0.1), value: badge.text)
    }
}
