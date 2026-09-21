import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Colour helpers that need the platform's colour class rather than SwiftUI's
/// opaque `Color`.
enum PlatformColors {
    /// Extracts sRGB components from a SwiftUI `Color`.
    ///
    /// `Color` deliberately hides its components, so the only way back out is
    /// through the platform type. Converting to sRGB first matters: a colour
    /// picked in Display P3 would otherwise report components outside 0…1 and
    /// tint the sprite wrong.
    static func rgbaComponents(_ color: Color) -> (Float, Float, Float, Float) {
        #if os(macOS)
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.white
        return (Float(converted.redComponent),
                Float(converted.greenComponent),
                Float(converted.blueComponent),
                Float(converted.alphaComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Float(r), Float(g), Float(b), Float(a))
        #endif
    }
}

extension Color {
    /// Cross-platform equivalent of NSColor.windowBackgroundColor / UIColor.systemBackground.
    static var platformWindowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// Cross-platform equivalent of NSColor.controlBackgroundColor / UIColor.secondarySystemBackground.
    static var platformControlBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}
