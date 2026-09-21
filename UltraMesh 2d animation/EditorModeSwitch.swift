import SwiftUI

/// Where a mode strip is being drawn, which decides how much chrome it needs.
enum ModeStripVariant {
    /// In the top toolbar, on the light surface: a pill track.
    case toolbar
    /// Floating over the canvas, where the surrounding strip supplies the
    /// chrome — so the switch itself adds none, and the two do not stack two
    /// backgrounds on top of each other.
    case floating
}

extension View {
    /// Shared shell for the two mode strips, so they read as one family rather
    /// than two controls that happen to look similar.
    @ViewBuilder
    func modeStripChrome(_ variant: ModeStripVariant) -> some View {
        switch variant {
        case .toolbar:
            self
                .padding(3)
                .background(Capsule().fill(UM.surfaceRaised))
        case .floating:
            self
        }
    }
}

/// Editor, Animator, Scene — the three workspaces, in the top bar.
///
/// The underlying cases are still `skeleton` and `animation`: those raw values
/// are persisted in every saved project, so only the label changed.
///
/// Driven by `EditorMode.selectable`, not `allCases`, so a mode can be
/// withdrawn in one place and the switch cannot offer a button with no way
/// back. All three are offered today; Scene was parked while the other two
/// were finished and came back once its canvas showed the set.
struct EditorModeSwitch: View {
    @Binding var mode: EditorMode
    var variant: ModeStripVariant = .floating

    var body: some View {
        HStack(spacing: 4) {
            ForEach(EditorMode.selectable, id: \.self) { candidate in
                EditorModeSegment(
                    title: candidate.title,
                    systemImage: candidate.systemImage,
                    isActive: mode == candidate,
                    variant: variant,
                    action: { mode = candidate }
                )
                .help({
                    switch candidate {
                    case .skeleton:  return "Editor — build the rig: bones, meshes, weights"
                    case .animation: return "Animator — pose and key over time"
                    case .scene:     return "Scene — stage finished animations with depth and a camera"
                    }
                }())
            }
        }
        .modeStripChrome(variant)
    }
}

private struct EditorModeSegment: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    var variant: ModeStripVariant = .floating
    let action: () -> Void

    /// The toolbar sits on the window's own surface and has room; the canvas
    /// strip floats over artwork and has none. Same control, two sizes.
    private var isToolbar: Bool { variant == .toolbar }

    private static let activeGradient = LinearGradient(
        colors: [Color(hex: 0x7379F5), UM.brandMagenta],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        Button(action: action) {
            HStack(spacing: isToolbar ? 7 : 5) {
                Image(systemName: systemImage)
                    .font(.system(size: isToolbar ? 12 : 10, weight: .semibold))
                Text(title)
                    .font(.system(size: isToolbar ? 13 : 11, weight: .semibold))
                    .fixedSize()
            }
            .foregroundStyle(
                isActive
                    ? (isToolbar ? Color.white : UM.textOnAccent)
                    : UM.textPrimary
            )
            .padding(.horizontal, isToolbar ? 16 : 10)
            .padding(.vertical, isToolbar ? 7 : 5)
            // Only the active segment gets a shape. The inactive toolbar
            // segments used to carry a dashed capsule of their own; it read as
            // a second, hollow selection sitting next to the real one, and the
            // pill track behind the strip already frames them.
            .background {
                if isActive {
                    Capsule().fill(isToolbar ? AnyShapeStyle(Self.activeGradient) : AnyShapeStyle(UM.accentStrong))
                }
            }
        }
        .buttonStyle(.plain)
        // No system focus ring. On iPadOS the focused segment was drawn with a
        // dashed capsule around it — a second outline hugging the pill, on the
        // button that is NOT the selected one, which reads as the selection
        // being in two places at once. The strip already says which mode is on
        // by filling that segment.
        //
        // The cost is that a keyboard or Full Keyboard Access user loses the
        // ring that told them where Tab landed. What is left for them is
        // Cmd-Shift-A, which toggles between the two modes without needing to
        // reach the buttons at all.
        .focusEffectDisabled()
    }
}

/// Whether bones are drawn on the canvas.
///
/// This used to carry the Editor / Animator switch as well. That moved to the
/// top bar, where the coarsest choice in the app belongs, and what is left here
/// is the one toggle that changes what the canvas draws.
///
/// It used to be a dark charcoal card stacked two rows high, floating over a
/// light canvas — a different palette from everything around it, and large
/// enough to cover the artwork it sits on. One compact strip now, in the app's
/// own blue-greys.
///
/// `accentSoft` rather than a surface tone on purpose: the canvas checkerboard
/// is the same family of light blue-greys as the chrome, so `surface` reads
/// 1.21 against the light squares and 1.01 against the dark ones — it would
/// vanish over half the board. `accentSoft` clears both.
///
/// SHOW BONES LIVES HERE, IN BOTH MODES. It was gated to Editor, on the
/// reasoning that bones are a rigging concern. They are not: you pose them in
/// Animator, and being unable to hide them there is exactly when you most want
/// to — to see the artwork without the skeleton over it.
struct CanvasOverlayControls: View {
    @Binding var mode: EditorMode
    @ObservedObject var sceneManager: SceneManager

    /// Same key `ViewportView` reads to drive the touch view. Two `@AppStorage`
    /// views on one key stay in sync through `UserDefaults`, so the button and
    /// the input layer need no binding between them.
    @AppStorage("umFingerNavigationOnly") private var fingerNavigationOnly = false

    var body: some View {
        HStack(spacing: 2) {
            boneToggle
            // iPadOS only, and not because macOS could not show it: there is no
            // finger and no Pencil on a Mac, so the button would toggle a rule
            // that governs nothing. A control that does nothing is worse than
            // an absent one.
            #if os(iOS)
            fingerToggle
            #endif
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(UM.accentSoft)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(UM.textPrimary.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
        )
    }

    private var boneToggle: some View {
        Button {
            sceneManager.showBones.toggle()
        } label: {
            // The project's own bone, with an eye badged on it. This was
            // `eye.fill` / `eye.slash.fill` — a stock symbol, in a strip where
            // every other mark is a shape drawn here, and one that showed no
            // bone at all: the only thing saying what it hid was where it sat.
            BoneVisibilityGlyph(
                isOpen: sceneManager.showBones,
                tint: sceneManager.showBones ? UM.textOnAccent : UM.textPrimary.opacity(0.62),
                contour: sceneManager.showBones
                    ? UM.accentStrong.opacity(0.55)
                    : UM.surface.opacity(0.65)
            )
            .frame(width: 17, height: 17)
            .frame(width: 26, height: 22)
            .background(
                Capsule().fill(sceneManager.showBones ? UM.accentStrong : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(sceneManager.showBones ? "Hide bones in the canvas" : "Show bones in the canvas")
    }

    #if os(iOS)
    /// Finger navigates, Pencil does everything else.
    ///
    /// The wording of the help text is the feature: the finger is not turned
    /// OFF, it is narrowed to navigation. Saying "disable touch" would describe
    /// a different — and much less useful — thing, and is the reason the glyph
    /// grows arrows rather than a strike-through.
    private var fingerToggle: some View {
        Button {
            fingerNavigationOnly.toggle()
        } label: {
            FingerNavigationGlyph(
                isLocked: fingerNavigationOnly,
                tint: fingerNavigationOnly ? UM.textOnAccent : UM.textPrimary.opacity(0.62),
                contour: fingerNavigationOnly
                    ? UM.accentStrong.opacity(0.55)
                    : UM.surface.opacity(0.65)
            )
            .frame(width: 17, height: 17)
            .frame(width: 26, height: 22)
            .background(
                Capsule().fill(fingerNavigationOnly ? UM.accentStrong : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(fingerNavigationOnly
              ? "Finger pans and zooms only — Apple Pencil for tools"
              : "Finger uses tools; two fingers pan and zoom")
    }
    #endif
}
