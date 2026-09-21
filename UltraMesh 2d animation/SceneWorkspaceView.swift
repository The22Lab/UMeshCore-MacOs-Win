import QuartzCore
import SwiftUI

/// The Scene workspace: hierarchy, viewport, inspector, timeline.
///
/// Replaces the rig workspace entirely rather than sitting on top of it. Scene
/// stages finished animations — it never rigs and never keys the rig — so
/// leaving the rig canvas live underneath would mean a stray click editing a
/// mesh the artist is only trying to look at.
struct SceneWorkspaceView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var sceneManager: SceneManager { appState.sceneManager }

    @State private var frame: Int = 0
    /// The transport. Editor state, and it lives HERE rather than on the
    /// manager for the reason `PlayheadClock` exists: the playhead moves at the
    /// scene's frame rate, and a `@Published` value moving that often would
    /// invalidate every view observing `SceneManager` — the hierarchy, the
    /// inspector, the layer list — thirty times a second, to move a line.
    /// `@State` here invalidates this subtree, which is the part that has to
    /// redraw anyway.
    @State private var playback = ScenePlayback()
    // NO selection state here. It lives on the manager, as one `SceneSelection`,
    // because a light and a card cannot both be selected — and while this was a
    // `@State` beside the manager's own light id, they could be.
    /// Free movement. Modal: while it is on, a drag navigates and never picks.
    @State private var isFlying = false

    var body: some View {
        Group {
            if let composition = sceneManager.selectedSceneComposition {
                content(composition)
            } else {
                // Only reachable if the ground-state scene failed to appear.
                // Says so rather than showing an empty grey panel.
                VStack(spacing: 10) {
                    Text("No scene")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(UM.textPrimary)
                    Button("Create a Scene") { sceneManager.ensureSceneCompositionExists() }
                        .buttonStyle(.plain)
                        .foregroundStyle(UM.accentStrong)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(UM.appBackground)
            }
        }
    }

    /// One tick: where does the clock say the playhead is?
    ///
    /// Writes `frame` only when the WHOLE number changes. The schedule ticks at
    /// display rate — 120 times a second on an iPad — and a scene at 24 fps has
    /// a new frame to show on one tick in five. Writing every tick would
    /// re-render the whole set five times for each picture that differs.
    private func advancePlayback() {
        guard let session = playback.session else { return }
        let now = ScenePlayback.playhead(at: CACurrentMediaTime(), session: session)
        if now.frame != frame { frame = now.frame }
        if now.ended { playback.stop() }
    }

    @ViewBuilder
    private func content(_ composition: SceneComposition) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SceneHierarchyView(composition: composition)
                .frame(minWidth: horizontalSizeClass == .compact ? 190 : 230,
                       idealWidth: 260, maxWidth: 320)

                Divider()

                SceneViewportView(
                    composition: composition,
                    frame: frame,
                    isFlying: $isFlying,
                    isPlaying: playback.isPlaying
                )
                .frame(minWidth: horizontalSizeClass == .compact ? 320 : 480)

                Divider()

                SceneInspectorView(composition: composition)
                .frame(minWidth: horizontalSizeClass == .compact ? 200 : 240,
                       idealWidth: 280, maxWidth: 330)
            }
            .frame(maxHeight: .infinity)

            Divider()

            // A LANE PER TRACK, not a slider. The scrubber it replaces could
            // show the camera's keys and nothing else — there was one row and
            // no room for a second — so a light's keys existed and could not be
            // seen. Height enough for the header and four lanes before it
            // scrolls, measured with the Animator's own metrics.
            SceneTimelineView(composition: composition, frame: $frame,
                              playback: $playback)
                .frame(height: TimelineMetrics.headerHeight
                       + TimelineMetrics.rowHeight * 4)
        }
        .background(UM.appBackground)
        .overlay {
            // THE DRIVER, and it is not a timer.
            //
            // The rig's transport is ticked by the Metal display link; Scene
            // renders on the CPU into a SwiftUI image, so there is no link to
            // hang it off. A `Task` waking thirty times a second would work and
            // is exactly what the rig's transport had removed from it — a
            // wake-up that often is one the SoC cannot idle through.
            //
            // `SwiftUI.TimelineView(.animation)` is the display's own schedule:
            // it ticks while this view is on screen and stops when it is not,
            // and it costs nothing when the transport is idle because the body
            // below does nothing. Qualified with its module because this
            // project has a `TimelineView` of its own.
            SwiftUI.TimelineView(.animation(paused: !playback.isPlaying)) { context in
                Color.clear.onChange(of: context.date) { _, _ in advancePlayback() }
            }
            .allowsHitTesting(false)
        }
        .onChange(of: playback.isPlaying) { _, playing in
            // The moment the shot stops, the canvas has all the time in the
            // world again — so the ladder goes back to the top rather than
            // leaving the picture soft until something else happens to it.
            if !playing { appState.sceneFrameRenderer.settleQuality() }
        }
        .onDisappear {
            // Leaving Scene STOPS the shot rather than letting it run on unseen.
            // The playhead is a function of wall-clock time, so a transport
            // left running while the artist spent a minute in the Editor would
            // be eighteen hundred frames along when they came back — correct by
            // the clock, and not what anybody meant.
            playback.stop()
        }
        .onChange(of: composition.durationInFrames) { _, duration in
            if frame >= duration { frame = max(duration - 1, 0) }
            playback.reanchor(to: frame, fps: composition.fps,
                              lastFrame: max(duration - 1, 0),
                              loops: sceneManager.sceneLoopsPlayback)
        }
        .onChange(of: composition.fps) { _, fps in
            // A rate change re-anchors from where the playhead IS, so the shot
            // changes speed without jumping.
            playback.reanchor(to: frame, fps: fps,
                              lastFrame: max(composition.durationInFrames - 1, 0),
                              loops: sceneManager.sceneLoopsPlayback)
        }
    }
}
