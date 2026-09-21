import SwiftUI

/// The way out, in the corner of the canvas.
///
/// Absent when there is nothing to leave — a control that is always there and
/// usually does nothing teaches an artist to ignore it. It appears when the
/// artist is inside something and names the thing it will close, because a
/// bare X three rungs deep is a gamble: the whole point of the ladder is that
/// the next press is predictable, and it can only be predictable if it is
/// legible.
///
/// The label is shown on the Mac, where a pointer can hover and there is room;
/// on iPad the glyph carries it, with the title underneath at a size that
/// still reads at arm's length. Both get the same accessibility label, which
/// is the one place the name has to exist on every platform.
struct CanvasEscapeButton: View {
    let scope: EditorScope
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                Text(scope.exitTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(UM.textOnAccent)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(UM.accentStrong)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.28), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.22), radius: 6, y: 2)
            )
            // A comfortable target around a small capsule, the way every other
            // canvas control here is built: the chip is what you see, the
            // rectangle is what you hit.
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.94 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isPressed)
        // The title changes as the artist walks out, and it should read as one
        // control changing its mind rather than a row of buttons swapping.
        .animation(.easeOut(duration: 0.14), value: scope)
        .accessibilityLabel(Text(scope.exitTitle))
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isPressed { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
    }
}
