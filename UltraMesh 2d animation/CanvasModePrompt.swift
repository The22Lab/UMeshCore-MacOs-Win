import SwiftUI

/// The bar at the bottom of the canvas that says what mode you are in, and how
/// to leave it.
///
/// Reported: it is hard to tell whether New Edge is on, and the same for Bind
/// Bones. Both are modes where the canvas behaves differently and nothing on
/// the canvas said so — the only sign was a highlighted segment in a panel on
/// the far side of the window, which is not where the artist is looking while
/// they draw.
///
/// So the canvas itself says it, in the one place the eye is already on, and
/// the way out is in the same sentence rather than somewhere else.
///
/// Bottom CENTRE, deliberately: the coordinate readout owns the bottom-left,
/// the escape control and the IK builder own the top-right, and the mode chips
/// own the top-left. The centre is the only edge of the canvas that is free,
/// and it is also where the eye goes when a mode changes what a tap does.
enum CanvasPromptMode: Equatable {
    /// Binding bones to the selected sprite. The art is dimmed so the bones
    /// read, and confirming ends the mode.
    case bindBones
    /// Drawing new mesh edges. The art is NOT dimmed — the whole point is to
    /// place vertices on it — and there is something in progress to abandon.
    case newEdge(hasPendingEdge: Bool)

    var title: String {
        switch self {
        case .bindBones: return "Bind Bones"
        case .newEdge:   return "New Edge"
        }
    }

    var detail: String {
        switch self {
        case .bindBones:
            return "Tap a bone to bind or unbind it"
        case let .newEdge(hasPending):
            return hasPending ? "Tap a second vertex to close the edge"
                              : "Tap two vertices to join them"
        }
    }

    /// What the primary button says. Named for what it DOES, not "OK".
    var confirmTitle: String {
        switch self {
        case .bindBones: return "Confirm"
        case .newEdge:   return "Finish"
        }
    }

    /// Whether a second, discarding button is offered.
    ///
    /// Only where there is genuinely something to discard. Bind mode applies
    /// each binding the moment it is tapped and has no session to roll back,
    /// so a Cancel there would be a Confirm wearing a different word — and a
    /// button that lies about being destructive is worse than no button.
    var offersCancel: Bool {
        switch self {
        case .bindBones: return false
        case let .newEdge(hasPending): return hasPending
        }
    }

    /// Whether the art behind the canvas is held back so the mode's own marks
    /// read over it.
    var dimsArtwork: Bool {
        switch self {
        case .bindBones: return true
        case .newEdge:   return false
        }
    }
}

struct CanvasModePrompt: View {
    let mode: CanvasPromptMode
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(mode.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(UM.textPrimary)
                Text(mode.detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(UM.textSecondary)
                    .lineLimit(1)
            }

            if mode.offersCancel {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UM.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Button(action: onConfirm) {
                Text(mode.confirmTitle)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(UM.textOnAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule(style: .continuous).fill(UM.accentStrong))
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(UM.surfaceRaised)
                .overlay(Capsule(style: .continuous).stroke(UM.hairline, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.20), radius: 10, y: 3)
        )
        .animation(.easeOut(duration: 0.14), value: mode)
    }
}
