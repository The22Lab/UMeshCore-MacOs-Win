import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PlatformFeedback {
    static func errorBeep() {
        #if os(macOS)
        NSSound.beep()
        #else
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(.error)
        #endif
    }

    /// Subtle tick when the canvas selection changes. No-op on macOS, where
    /// the highlight change plus the pointer already provide the feedback.
    static func selectionChanged() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    /// Light tap confirming a discrete action (undo, snap, tool switch).
    static func lightImpact() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}
