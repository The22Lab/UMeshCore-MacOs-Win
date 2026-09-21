import SwiftUI

/// The circular selection mark on a hierarchy row.
///
/// It exists because of a line in `HierarchyView.select(entry:item:)`: "On
/// iPadOS a hardware keyboard reports the same flags; without one there is no
/// modifier to read, and the canvas marquee is the multi-select gesture there."
/// Which is to say an iPad artist without a keyboard could not build a
/// selection from the hierarchy at all — only from the canvas, only by
/// rubber-band, and only over what happens to be visible. This is Cmd-click
/// without the Cmd.
///
/// THREE STATES, not two. A header row that is partly selected must not claim
/// to be empty, or "Select All" becomes a way to lose a careful selection by
/// looking away for a second.
enum HierarchySelectionMark: Equatable {
    case empty
    case partial
    case full
}

struct HierarchySelectionToggle: View {
    let mark: HierarchySelectionMark
    /// Tinted to whatever the row is — a bone's own colour, a sprite's
    /// fuchsia — so the mark reads as belonging to the thing beside it rather
    /// than as chrome bolted on.
    let tint: Color
    let action: () -> Void

    /// Drawn small and quiet; hit generously. The same split the canvas gizmo
    /// and the graph editor make, for the same reason: an elegant target is
    /// still a target.
    static let visualDiameter: CGFloat = 15
#if os(iOS)
    static let grabDiameter: CGFloat = 34
#else
    static let grabDiameter: CGFloat = 24
#endif

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(borderColour, lineWidth: mark == .empty ? 1.3 : 0)
                    .background(Circle().fill(fillColour))
                    .frame(width: Self.visualDiameter, height: Self.visualDiameter)

                switch mark {
                case .empty:
                    EmptyView()
                case .partial:
                    // A bar, not a smaller tick: "some of these" is a different
                    // statement from "this one", and drawing it as a faint tick
                    // is how an artist reads partial as full and taps once more
                    // to clear what they meant to keep.
                    Capsule()
                        .fill(UM.textOnAccent)
                        .frame(width: 7, height: 2)
                case .full:
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(UM.textOnAccent)
                }
            }
            .frame(width: Self.grabDiameter, height: Self.grabDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: mark)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(mark == .full ? [.isSelected] : [])
    }

    private var fillColour: Color {
        switch mark {
        case .empty:   return Color.clear
        case .partial: return tint.opacity(0.55)
        case .full:    return tint
        }
    }

    private var borderColour: Color {
        mark == .empty ? UM.textPrimary.opacity(0.28) : .clear
    }

    private var accessibilityLabel: String {
        switch mark {
        case .empty:   return "Select"
        case .partial: return "Some selected"
        case .full:    return "Selected"
        }
    }
}
