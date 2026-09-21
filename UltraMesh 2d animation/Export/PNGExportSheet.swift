import SwiftUI
import simd
import UniformTypeIdentifiers

/// Export configuration sheet. Lives in the Export module so the
/// UI surface and the format stay co-located.
struct PNGExportSheet: View {
    @ObservedObject var scene: SceneManager
    @ObservedObject var library: AnimationLibrary
    let cameraOrigin: SIMD2<Float>
    let cameraZoom: Float
    let onCancel: () -> Void
    let onExport: (PNGExportRequest) -> Void

    @State private var selectedAnimationID: UUID?

    @State private var width: Int = 1024
    @State private var height: Int = 1024
    @State private var fps: Int = 30
    @State private var transparent: Bool = true
    @State private var filenamePrefix: String = "frame"
    @State private var startFrame: Int = 0
    @State private var endFrame: Int = 0
    @State private var selectedFolderURL: URL?
    @State private var error: String?
    @State private var isPickingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export PNG Sequence")
                .font(.system(size: 14, weight: .semibold))

            Divider()

            Group {
                if !library.animations.isEmpty {
                    row("Animation") {
                        Picker("", selection: $selectedAnimationID) {
                            ForEach(library.animations) { anim in
                                Text(anim.name).tag(Optional(anim.id))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        .onChange(of: selectedAnimationID) { _, newID in
                            if let newID { library.switchTo(newID); initializeDefaults() }
                        }
                    }
                }
                row("Output Folder") {
                    HStack(spacing: 6) {
                        Text(selectedFolderURL?.lastPathComponent ?? "(none selected)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .leading)
                        Button("Choose…") { pickFolder() }
                    }
                }

                row("File Prefix") {
                    TextField("", text: $filenamePrefix)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }

                row("Size") {
                    HStack(spacing: 6) {
                        intField($width).frame(width: 70)
                        Text("×").foregroundStyle(.secondary)
                        intField($height).frame(width: 70)
                        Text("px").foregroundStyle(.secondary)
                    }
                }

                row("Frame Range") {
                    HStack(spacing: 6) {
                        intField($startFrame).frame(width: 60)
                        Text("→").foregroundStyle(.secondary)
                        intField($endFrame).frame(width: 60)
                        Text("(\(max(endFrame - startFrame + 1, 0)) frames)")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10))
                    }
                }

                row("FPS") {
                    intField($fps).frame(width: 60)
                }

                row("Background") {
                    Toggle("Transparent", isOn: $transparent)
#if os(macOS)
                        .toggleStyle(.checkbox)
#endif
                }
            }

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Export") { tryExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedFolderURL == nil)
            }
        }
        .padding(18)
#if os(macOS)
        .frame(width: 460)
#endif
        .onAppear { initializeDefaults() }
#if !os(macOS)
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { selectedFolderURL = url }
        }
#endif
    }

    // MARK: - UI helpers

    @ViewBuilder
    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            content()
            Spacer()
        }
    }

    private func intField(_ binding: Binding<Int>) -> some View {
        TextField("", value: binding, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
    }

    // MARK: - Defaults + actions

    private func initializeDefaults() {
        if selectedAnimationID == nil { selectedAnimationID = library.activeID }
        if let prefix = library.active?.name { filenamePrefix = prefix }
        // Default to the project's frame rate so an export plays back at the
        // same speed the artist previewed it at.
        fps = Int(scene.projectFramesPerSecond.rounded())
        // Auto-discover frame range from the scene
        let boneDur = scene.skeleton.orderedBones.map { $0.animationClip.durationInFrames }.max() ?? 0
        let imgDur = scene.images.map { $0.animationClip.durationInFrames }.max() ?? 0
        // Constraint and draw order timelines can outlast every bone and sprite
        // clip, so they take part in the discovered range too.
        let sceneDur = scene.sceneAnimationClip.durationInFrames
        let discovered = max(boneDur, imgDur, sceneDur, scene.playbackEndFrame)
        startFrame = max(0, scene.playbackStartFrame)
        endFrame = max(discovered, scene.currentFrame)
        if endFrame < startFrame { endFrame = startFrame }
    }

    private func pickFolder() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { selectedFolderURL = panel.url }
#else
        isPickingFolder = true
#endif
    }

    private func tryExport() {
        guard let folder = selectedFolderURL else { return }
        guard width > 0, height > 0, fps > 0 else {
            error = "Width, height and FPS must be positive."
            return
        }
        guard endFrame >= startFrame else {
            error = "End frame must be ≥ start frame."
            return
        }
        let bg = transparent ? SIMD4<Float>(0, 0, 0, 0) : SIMD4<Float>(0, 0, 0, 1)
        let request = PNGExportRequest(
            animationName: nil,
            fps: Double(fps),
            frameRange: startFrame...endFrame,
            outputDirectory: folder,
            filenamePrefix: filenamePrefix.isEmpty ? "frame" : filenamePrefix,
            frameSpec: PNGFrameSpec(
                width: width,
                height: height,
                clearColor: bg,
                cameraOrigin: cameraOrigin,
                cameraZoom: cameraZoom
            )
        )
        onExport(request)
    }
}
