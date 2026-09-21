import SwiftUI

/// Scene's timeline: a frozen names column, a frame ruler, one lane per track.
///
/// The Animator's shape, adapted. It measures itself with `TimelineMetrics` —
/// the SAME row height, header height, names width and grid origin — so the two
/// timelines line up when an artist looks from one to the other, and so that
/// changing a lane's height changes it in both rather than in one.
///
/// ## What Scene has tracks FOR
///
/// The camera, and each light. Not the cards: a card is placed and stays, which
/// is the rule Scene was built on — it assembles animation rather than
/// authoring it. So there is no row for a plate, and that is not an omission.
///
/// ## What is not here, said plainly
///
/// Curve editing. A Scene track's keyframes interpolate through the same
/// `AnimationCurve` as everything else, so the motion between them is already
/// eased the way the Animator eases; what is missing is the graph to DRAG those
/// tangents in. That gap is not new and is not specific to lights — the camera
/// has had it since it learned to key — and closing it means giving the
/// Animator's graph a second data source, which is its own piece of work.
struct SceneTimelineView: View {
    @EnvironmentObject private var appState: AppState

    let composition: SceneComposition
    @Binding var frame: Int
    /// The transport, owned by the workspace — which is what drives it, and
    /// what stops it when Scene goes off screen. Shared rather than duplicated
    /// so the button and the driver are looking at one session.
    @Binding var playback: ScenePlayback

    private var sceneManager: SceneManager { appState.sceneManager }

    /// A lane: what it is called, what it keys, and where its keys are.
    ///
    /// Built fresh each pass from the composition and the clip. Nothing is
    /// cached between frames, so a lane cannot show keys a light no longer has.
    private struct Lane: Identifiable {
        enum Subject: Equatable {
            case camera
            case light(UUID)
        }
        let id: String
        let title: String
        let subtitle: String
        let tint: Color
        let subject: Subject
        let frames: [Int]
    }

    private var lanes: [Lane] {
        var out: [Lane] = [
            Lane(id: "camera", title: "Camera", subtitle: "Shot",
                 tint: UM.brandMagenta, subject: .camera,
                 frames: sceneManager.sceneCameraKeyFrames)
        ]
        // The artist's own order, which is the order the lights are applied in.
        // A lane list that sorted itself would disagree with the inspector's
        // list about which light is which, and they are the same lights.
        for light in composition.lights {
            out.append(Lane(
                id: light.id.uuidString,
                title: light.name,
                subtitle: light.kind.title,
                tint: Color(red: Double(light.color.x), green: Double(light.color.y),
                            blue: Double(light.color.z)),
                subject: .light(light.id),
                frames: sceneManager.sceneLightKeyFrames(light.id)))
        }
        return out
    }

    private var lastFrame: Int { max(composition.durationInFrames - 1, 1) }

    var body: some View {
        GeometryReader { proxy in
            let gridWidth = max(proxy.size.width - TimelineMetrics.gridLeadingInset, 1)
            VStack(spacing: 0) {
                header(gridWidth: gridWidth)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(lanes) { lane in
                            row(lane, gridWidth: gridWidth)
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                // ONE playhead over everything, measured from
                // `gridLeadingInset` like every tick and every diamond. Drawn as
                // an overlay rather than inside the scroll view so it does not
                // scroll away from the ruler it belongs to.
                playhead(gridWidth: gridWidth, height: proxy.size.height)
            }
        }
        .background(UM.surface)
    }

    // MARK: - Header

    private func header(gridWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                transport
                HStack(spacing: 6) {
                    Text(String(format: "%03d", frame))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(UM.textPrimary)
                    Text("/ \(composition.durationInFrames) · \(composition.fps) fps")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(UM.textMuted)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: TimelineMetrics.labelsWidth, alignment: .leading)

            Rectangle()
                .fill(UM.textPrimary.opacity(0.08))
                .frame(width: TimelineMetrics.separatorWidth)

            ruler(gridWidth: gridWidth)
        }
        .frame(height: TimelineMetrics.headerHeight)
    }

    private func ruler(gridWidth: CGFloat) -> some View {
        Canvas { context, size in
            let step = Self.tickStep(lastFrame: lastFrame, width: gridWidth)
            var value = 0
            while value <= lastFrame {
                let x = Self.x(forFrame: value, lastFrame: lastFrame, width: gridWidth)
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - 8))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(tick, with: .color(UM.textPrimary.opacity(0.22)), lineWidth: 1)
                context.draw(
                    Text("\(value)")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(UM.textMuted),
                    at: CGPoint(x: x + 1, y: size.height - 15), anchor: .leading)
                value += step
            }
        }
        .frame(width: gridWidth)
        .contentShape(Rectangle())
        .gesture(scrub(gridWidth: gridWidth))
    }

    // MARK: - Transport

    /// Rewind, step, play, step, end — and the loop toggle.
    ///
    /// The order every transport has had since tape, because it is the one an
    /// artist's hand already knows. Play in the middle so it is the biggest
    /// target and the one the eye lands on.
    private var transport: some View {
        HStack(spacing: 2) {
            transportButton("backward.end.fill", "Go to the start") { goToStart() }
            transportButton("backward.frame.fill", "Step back one frame") { step(-1) }
            Button {
                togglePlay()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(playback.isPlaying ? UM.brandMagenta : UM.textPrimary)
                    .frame(width: 26, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(UM.surfaceInset))
            }
            .buttonStyle(.plain)
            #if os(macOS)
            // Space, which is what every transport in every tool answers to.
            // macOS only: an iPad has no space bar to press while the Pencil is
            // in the other hand, and a shortcut nobody can reach is a shortcut
            // that only confuses the help text.
            .keyboardShortcut(.space, modifiers: [])
            #endif
            .help(playback.isPlaying ? "Pause  (Space)" : "Play the shot  (Space)")
            transportButton("forward.frame.fill", "Step forward one frame") { step(1) }
            transportButton("forward.end.fill", "Go to the end") { goToEnd() }

            Button {
                sceneManager.sceneLoopsPlayback.toggle()
                // Re-anchor rather than restart: the artist toggled how the
                // shot ENDS, not where it is, and stopping the playhead to say
                // so would be the button answering a question nobody asked.
                playback.reanchor(to: frame, fps: composition.fps,
                                  lastFrame: lastFrame,
                                  loops: sceneManager.sceneLoopsPlayback)
            } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(sceneManager.sceneLoopsPlayback
                                     ? UM.accentStrong : UM.textMuted)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(sceneManager.sceneLoopsPlayback ? "Looping" : "Play once")

            Spacer(minLength: 0)
        }
    }

    private func transportButton(_ symbol: String, _ help: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(UM.textSecondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func togglePlay() {
        if playback.isPlaying {
            playback.stop()
        } else {
            playback.play(from: frame, fps: composition.fps, lastFrame: lastFrame,
                          loops: sceneManager.sceneLoopsPlayback)
        }
    }

    /// Move the playhead by hand.
    ///
    /// STOPS the transport. Stepping while playing would put the playhead one
    /// frame along and the very next tick would take it straight back, so the
    /// button would appear not to work — and a scrub, which re-anchors instead,
    /// is the gesture that means "keep playing from here".
    private func step(_ delta: Int) {
        playback.stop()
        frame = min(max(frame + delta, 0), lastFrame)
    }

    private func goToStart() {
        playback.stop()
        frame = 0
    }

    private func goToEnd() {
        playback.stop()
        frame = lastFrame
    }

    /// A tick every so many frames, so the labels never collide.
    ///
    /// Chosen from the width rather than fixed, because the panel is resizable
    /// and a fixed step either crowds at narrow widths or leaves a bare ruler at
    /// wide ones. Stepped through the round numbers an artist counts in.
    static func tickStep(lastFrame: Int, width: CGFloat) -> Int {
        let minimumSpacing: CGFloat = 34
        let affordable = max(Int((width / minimumSpacing).rounded(.down)), 1)
        let raw = max(Int((Double(lastFrame) / Double(affordable)).rounded(.up)), 1)
        for candidate in [1, 2, 5, 10, 15, 20, 25, 30, 50, 60, 100, 120, 250, 500] {
            if candidate >= raw { return candidate }
        }
        return raw
    }

    // MARK: - Lanes

    private func row(_ lane: Lane, gridWidth: CGFloat) -> some View {
        let isSelected: Bool = {
            if case let .light(id) = lane.subject {
                return sceneManager.sceneSelection == .light(id)
            }
            return false
        }()
        return HStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(lane.tint)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(lane.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UM.textPrimary)
                        .lineLimit(1)
                    Text(lane.subtitle)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(UM.textMuted)
                }
                Spacer(minLength: 4)
                keyButton(lane)
            }
            .padding(.horizontal, 10)
            .frame(width: TimelineMetrics.labelsWidth, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                // Selecting the lane selects the light, so the canvas, the
                // inspector and the gizmo follow — one selection, everywhere.
                if case let .light(id) = lane.subject { sceneManager.selectSceneLight(id) }
            }

            Rectangle()
                .fill(UM.textPrimary.opacity(0.08))
                .frame(width: TimelineMetrics.separatorWidth)

            keyLane(lane, gridWidth: gridWidth)
        }
        .frame(height: TimelineMetrics.rowHeight)
        .background(isSelected ? UM.accent.opacity(0.16) : Color.clear)
    }

    private func keyLane(_ lane: Lane, gridWidth: CGFloat) -> some View {
        Canvas { context, size in
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height / 2))
            base.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(base, with: .color(UM.textPrimary.opacity(0.07)), lineWidth: 1)

            for keyFrame in lane.frames {
                let x = Self.x(forFrame: keyFrame, lastFrame: lastFrame, width: gridWidth)
                let y = size.height / 2
                // A DIAMOND, which is what a keyframe is everywhere else in this
                // editor. A circle here would read as something else.
                var diamond = Path()
                let r: CGFloat = 4.5
                diamond.move(to: CGPoint(x: x, y: y - r))
                diamond.addLine(to: CGPoint(x: x + r, y: y))
                diamond.addLine(to: CGPoint(x: x, y: y + r))
                diamond.addLine(to: CGPoint(x: x - r, y: y))
                diamond.closeSubpath()
                context.fill(diamond, with: .color(lane.tint))
                context.stroke(diamond, with: .color(.black.opacity(0.5)), lineWidth: 1)
            }
        }
        .frame(width: gridWidth)
        .contentShape(Rectangle())
        .gesture(scrub(gridWidth: gridWidth))
    }

    @ViewBuilder
    private func keyButton(_ lane: Lane) -> some View {
        let keyed = lane.frames.contains(frame)
        Button {
            switch lane.subject {
            case .camera:
                if keyed {
                    sceneManager.removeSceneCameraKey(atFrame: frame)
                } else {
                    sceneManager.keySceneCamera(composition, atFrame: frame)
                }
            case let .light(id):
                guard let light = composition.light(id) else { return }
                if keyed {
                    sceneManager.removeSceneLightKey(id, atFrame: frame)
                } else {
                    sceneManager.keySceneLight(light, atFrame: frame)
                }
            }
        } label: {
            Image(systemName: keyed ? "diamond.fill" : "diamond")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(keyed ? lane.tint : UM.textSecondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(keyed ? "Remove the key here" : "Key here")
    }

    // MARK: - Playhead and time

    private func playhead(gridWidth: CGFloat, height: CGFloat) -> some View {
        let x = TimelineMetrics.gridLeadingInset
            + Self.x(forFrame: frame, lastFrame: lastFrame, width: gridWidth)
        return Rectangle()
            .fill(UM.brandMagenta)
            .frame(width: 1.5, height: height)
            .offset(x: x - 0.75)
            .allowsHitTesting(false)
    }

    /// Frame to a position across the grid.
    ///
    /// Half a lane is NOT subtracted: a Scene frame is a moment, and the
    /// playhead, the ruler tick and the keyframe diamond for frame 12 all have
    /// to be the same x or they read as three different twelves.
    static func x(forFrame value: Int, lastFrame: Int, width: CGFloat) -> CGFloat {
        let t = CGFloat(min(max(value, 0), lastFrame)) / CGFloat(max(lastFrame, 1))
        return t * width
    }

    /// And back again.
    static func frame(atX x: CGFloat, lastFrame: Int, width: CGFloat) -> Int {
        let t = min(max(x / max(width, 1), 0), 1)
        return Int((t * CGFloat(max(lastFrame, 1))).rounded())
    }

    private func scrub(gridWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                frame = Self.frame(atX: value.location.x, lastFrame: lastFrame,
                                   width: gridWidth)
                // Scrubbing while playing RE-ANCHORS rather than stopping: the
                // artist is saying "play from here", and a transport still
                // measuring from where play was pressed would drag the playhead
                // back on the next tick.
                playback.reanchor(to: frame, fps: composition.fps,
                                  lastFrame: lastFrame,
                                  loops: sceneManager.sceneLoopsPlayback)
            }
    }
}
