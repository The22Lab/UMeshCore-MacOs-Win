import SwiftUI

/// Global keyboard map for the editor.
///
/// Implemented as a set of hidden, zero-sized buttons rather than a macOS
/// `CommandMenu`, because `.keyboardShortcut` on a button is honoured on both
/// macOS and iPadOS with a hardware keyboard. One implementation therefore
/// covers both platforms, which is what keeps their behaviour identical.
///
/// The map follows the convention shared by most animation tools:
/// single letters switch tools, space toggles playback, arrows step the
/// playhead, and modifiers scale the step. Nothing here overrides an existing
/// system shortcut (Cmd-based combinations are left to the app's command menu).
struct KeyboardShortcutHost: View {
    @ObservedObject var appState: AppState
    /// Observed directly rather than through `appState`, because the frame and
    /// playback state this view reads are published by the scene, not the app.
    @ObservedObject var scene: SceneManager
    @ObservedObject var tools: ToolManager

    /// How far Home/End and the page keys jump when no explicit range is set.
    private var timelineUpperBound: Int {
        let boneDuration = scene.skeleton.orderedBones
            .map(\.animationClip.durationInFrames).max() ?? 0
        let imageDuration = scene.images
            .map(\.animationClip.durationInFrames).max() ?? 0
        return max(
            boneDuration,
            imageDuration,
            scene.sceneAnimationClip.durationInFrames,
            scene.playbackEndFrame
        )
    }

    var body: some View {
        ZStack {
            // MARK: Playback

            shortcut(.space, modifiers: []) {
                scene.togglePlayback()
            }

            // MARK: Playhead

            shortcut(.leftArrow, modifiers: []) { scene.stepFrames(-1) }
            shortcut(.rightArrow, modifiers: []) { scene.stepFrames(1) }
            shortcut(.leftArrow, modifiers: .shift) { scene.stepFrames(-10) }
            shortcut(.rightArrow, modifiers: .shift) { scene.stepFrames(10) }
            shortcut(.home, modifiers: []) { scene.setCurrentFrame(scene.playbackStartFrame) }
            shortcut(.end, modifiers: []) { scene.setCurrentFrame(timelineUpperBound) }

            // MARK: Tools
            //
            // Q/W/E/R/T runs left to right along the keyboard in the same order
            // the transform tools appear in the toolbar.

            shortcut("q", modifiers: []) { tools.setTool(.select) }
            shortcut("w", modifiers: []) { tools.setTool(.move) }
            shortcut("e", modifiers: []) { tools.setTool(.rotate) }
            shortcut("r", modifiers: []) { tools.setTool(.scale) }
            shortcut("t", modifiers: []) { tools.setTool(.skew) }
            shortcut("b", modifiers: []) { tools.setTool(.bone) }
            shortcut("m", modifiers: []) { tools.setTool(.mesh) }

            // MARK: Keyframes

            shortcut(.delete, modifiers: []) { scene.deleteSelectedKeyframes() }
            shortcut("d", modifiers: [.command, .shift]) { scene.duplicateSelectedKeyframes() }

            // MARK: Modes
            //
            // Setup / Animate is toggled through `editorMode` rather than the
            // scene flag directly: the app state owns the transition and does
            // extra bookkeeping when entering animation mode.
            shortcut("a", modifiers: [.command, .shift]) {
                appState.editorMode = appState.editorMode == .animation ? .skeleton : .animation
            }
            shortcut("l", modifiers: []) {
                scene.playbackLoops.toggle()
            }
        }
        // Zero-sized and non-interactive: the buttons exist purely to register
        // their key equivalents with the responder chain.
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func shortcut(
        _ key: KeyEquivalent,
        modifiers: EventModifiers,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(.plain)
            .keyboardShortcut(key, modifiers: modifiers)
    }
}
