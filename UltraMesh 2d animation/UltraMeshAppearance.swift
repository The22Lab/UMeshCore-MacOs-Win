import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Which palette the interface draws in.
///
/// The light palette is the approved mockup and is not touched by any of this:
/// every colour below keeps its exact value as the LIGHT half of a pair, so
/// day mode is the same drawing it always was, byte for byte.
/// `Editor/verify_theme_night.py` holds that line by reading the palette as it
/// was in the last commit before night mode and asserting every light value
/// still equals it, alpha included.
enum UMAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Match System"
        case .light:  return "Day"
        case .dark:   return "Night"
        }
    }

    /// What the root view pins. `nil` lets the device decide.
    ///
    /// This has to be pinned rather than left alone, and the reason predates
    /// night mode: the system's own controls — sheets, alerts, pickers,
    /// toggles — follow the DEVICE unless told otherwise, so an iPad in dark
    /// mode drew white system labels over the editor's light panels while a Mac
    /// in light mode drew the same code correctly. Whatever the artist picks
    /// here, the system controls have to be told the same thing.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Where the choice is kept.
///
/// A single key read through `@AppStorage` in the root view. Nothing else
/// stores it, and nothing else needs to: the colours below resolve against the
/// APPEARANCE IN EFFECT rather than against a global, so no view has to observe
/// a theme object and no redraw has to be triggered by hand.
enum UMAppearanceStorage {
    static let key = "umInterfaceAppearance"
}

extension Color {

    /// One colour with two values, resolved by the appearance in effect.
    ///
    /// This is the whole mechanism, and it is deliberately not a switch on a
    /// stored theme. A dynamic platform colour is resolved by AppKit/UIKit at
    /// DRAW time against the appearance of the view drawing it, so:
    ///
    ///   * every existing `UM.something` call site keeps working, unchanged —
    ///     and there are hundreds of them;
    ///   * nothing has to observe a theme object, so switching appearance does
    ///     not invalidate every view in the editor through a published write;
    ///   * the light value is preserved by construction, because it is simply
    ///     the light branch.
    ///
    /// The alternative — `static var accent: Color { palette.accent }` over a
    /// mutable global — needs a way to tell SwiftUI the world changed, and
    /// static state has none. That is how a theme switch ends up needing a
    /// `@Published` object threaded through every view, or a full window
    /// rebuild.
    static func um(light: UInt32, dark: UInt32, opacity: Double = 1.0) -> Color {
#if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(srgbHex: isDark ? dark : light, alpha: opacity)
        })
#else
        return Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            return UIColor(srgbHex: isDark ? dark : light, alpha: opacity)
        })
#endif
    }
    /// The same, when the two sides need different alphas as well as
    /// different hues — a hairline that is ink at 8% on a light panel and
    /// light at 10% on a dark one is not one colour at one opacity.
    static func umPair(light: UInt32, lightOpacity: Double,
                       dark: UInt32, darkOpacity: Double) -> Color {
#if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(srgbHex: isDark ? dark : light,
                           alpha: isDark ? darkOpacity : lightOpacity)
        })
#else
        return Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            return UIColor(srgbHex: isDark ? dark : light,
                           alpha: isDark ? darkOpacity : lightOpacity)
        })
#endif
    }
}

#if os(macOS)
private extension NSColor {
    convenience init(srgbHex hex: UInt32, alpha: Double) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: CGFloat(alpha))
    }
}
#else
private extension UIColor {
    convenience init(srgbHex hex: UInt32, alpha: Double) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: CGFloat(alpha))
    }
}
#endif
