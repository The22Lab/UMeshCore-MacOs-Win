import SwiftUI
import simd
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Export dialog.
///
/// Layout: a grouped format list on the left (Data / Image),
/// a titled options panel on the right whose controls each map to a real knob
/// in the pipeline,
/// and a bottom bar with Save / Load presets, "Open after export", Export and
/// Cancel. Every control is wired to real behavior in the export pipeline —
/// nothing here is decorative.
struct ExportDialog: View {
    @ObservedObject var appState: AppState
    let cameraOrigin: SIMD2<Float>
    let cameraZoom: Float
    let onClose: () -> Void

    @State private var settings = ExportSettings()
    @State private var status: ExportStatus = .idle
    @State private var validation: ValidationSummary?
    @State private var isValidating = false
    @State private var isPickingFolder = false
    @State private var isPickingPreset = false
    @State private var lastOutputURL: URL?

    // Settings persist between sessions: the last setup is remembered.
    @AppStorage("umExport.lastSettings") private var storedSettingsJSON = ""

    enum ExportStatus: Equatable {
        case idle, running
        case success(String)
        case failure(String)
    }

    struct ValidationSummary: Equatable {
        var errors: [String]
        var warnings: [String]
        var byteEstimate: Int
        var isValid: Bool { errors.isEmpty }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            HStack(alignment: .top, spacing: 0) {
                formatList
                Divider()
                optionsPanel
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear(perform: load)
        .onDisappear(perform: persist)
#if !os(macOS)
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { settings.outputPath = url.path }
        }
        .fileImporter(isPresented: $isPickingPreset, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { loadPreset(from: url) }
        }
#endif
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack {
            Text("Export").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("UltraMesh \(UltraMeshJSONExporter.formatVersion)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Format list (Data / Image groups)

    private var formatList: some View {
        VStack(alignment: .leading, spacing: 2) {
            groupHeader("Data")
            formatRadio(.json)
            formatRadio(.binary)
            groupHeader("Image").padding(.top, 10)
            formatRadio(.png)
            Spacer()
        }
        .padding(.vertical, 12)
        .frame(width: 150)
        .background(sidebarBackground)
    }

    private func groupHeader(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14).padding(.bottom, 2)
    }

    private func formatRadio(_ kind: ExportKind) -> some View {
        Button {
            settings.kind = kind
            settings.fileExtension = kind.defaultExtension
            status = .idle
            if kind == .json { runValidation() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: settings.kind == kind ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(settings.kind == kind ? Color.accentColor : .secondary)
                Text(kind.title).font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Options panel

    private var optionsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(settings.kind == .png ? "Export PNG" : "Export \(settings.kind.title)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.bottom, 6)
                Divider().padding(.bottom, 12)

                if settings.kind == .png { pngPanel } else { dataPanel }

                if case .idle = status {} else {
                    Divider().padding(.vertical, 12)
                    statusBanner
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Data panel (JSON / Binary) — the JSON export panel

    private var dataPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Output folder:") {
                pathField(text: $settings.outputPath) { chooseFolder() }
            }
            field("File name:") {
                HStack(spacing: 4) {
                    TextField("", text: $settings.fileName)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                    Text(settings.fileExtension).foregroundStyle(.secondary).font(.system(size: 11))
                }
            }
            field("Extension:") {
                TextField("", text: $settings.fileExtension)
                    .textFieldStyle(.roundedBorder).frame(width: 110)
            }
            field("Format:") {
                HStack(spacing: 10) {
                    Text(settings.kind == .json ? "JSON" : "Binary")
                        .font(.system(size: 11))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
                    if settings.kind == .json {
                        check("Pretty print", $settings.prettyPrint)
                    }
                }
            }
            field("Version:") {
                Text(settings.formatVersion)
                    .font(.system(size: 11))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
            }
            field("Output:") {
                HStack(spacing: 16) {
                    check("Nonessential data", $settings.nonessentialData)
                    check("Animation clean up", $settings.animationCleanUp)
                }
            }
            field("") {
                HStack(spacing: 16) {
                    check("Warnings", $settings.warnings)
                    check("Export all", $settings.exportAll)
                }
            }
            field("Textures:") {
                HStack(spacing: 16) {
                    check("Embed", $settings.embedTextures)
                    check("Reproducible", $settings.reproducible)
                }
            }
            field("Precision:") {
                Stepper(value: $settings.floatPrecision, in: 2...9) {
                    Text("\(settings.floatPrecision) decimals")
                        .font(.system(size: 11)).monospacedDigit()
                }
                .frame(width: 180)
            }
            field("Texture atlas:") {
                check("Pack", $settings.packTextureAtlas)
            }
            if settings.packTextureAtlas {
                field("Page size:") {
                    HStack(spacing: 6) {
                        intField($settings.atlasMaxWidth).frame(width: 66)
                        Text("×").foregroundStyle(.secondary)
                        intField($settings.atlasMaxHeight).frame(width: 66)
                        Text("px").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                field("Atlas:") {
                    HStack(spacing: 14) {
                        check("Power of two", $settings.atlasPowerOfTwo)
                        check("Strip whitespace", $settings.atlasStripWhitespace)
                    }
                }
                field("Padding:") {
                    HStack(spacing: 8) {
                        slider($settings.atlasPadding, 0...16).frame(width: 150)
                        Text("\(settings.atlasPadding) px")
                            .font(.system(size: 11)).monospacedDigit()
                    }
                }
            }

            if settings.kind == .json && settings.warnings {
                Divider().padding(.vertical, 6)
                validationBlock
            }
        }
        .onChange(of: settings.nonessentialData) { _, _ in runValidation() }
        .onChange(of: settings.animationCleanUp) { _, _ in runValidation() }
        .onChange(of: settings.exportAll) { _, _ in runValidation() }
        .onChange(of: settings.floatPrecision) { _, _ in runValidation() }
    }

    // MARK: PNG panel — the PNG export panel

    private var pngPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                field("Export type:") {
                    Picker("", selection: $settings.pngExportType) {
                        ForEach(ExportSettings.PNGExportType.allCases) { t in
                            Text(t.title).tag(t)
                        }
                    }
                    .labelsHidden().frame(width: 160)
                }
                Spacer()
                Button { settings.restoreDefaults() } label: {
                    Label("Defaults", systemImage: "arrow.counterclockwise")
                }
                .font(.system(size: 11))
            }

            field("Output folder:") {
                pathField(text: $settings.outputPath) { chooseFolder() }
            }
            field("File prefix:") {
                TextField("", text: $settings.filenamePrefix)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }
            field("Warm up:") {
                HStack(spacing: 8) {
                    slider($settings.warmUp, 0...20).frame(width: 190)
                    Text("\(settings.warmUp)").font(.system(size: 11)).monospacedDigit().frame(width: 26)
                }
            }
            field("Render:") {
                HStack(spacing: 14) {
                    check("Bones", $settings.renderBones)
                    check("Images", $settings.renderImages)
                    check("Others", $settings.renderOthers)
                }
            }
            field("Smoothing:") {
                HStack(spacing: 8) {
                    slider($settings.smoothing, 0...10).frame(width: 190)
                    Text(smoothingLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            field("Viewport:") {
                HStack(spacing: 12) {
                    check("Crop", $settings.cropViewport)
                    if settings.cropViewport {
                        Text("padding").font(.system(size: 10)).foregroundStyle(.secondary)
                        intField($settings.cropPadding).frame(width: 46)
                        Text("px").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            field("Size:") {
                HStack(spacing: 8) {
                    Picker("", selection: $settings.sizeMode) {
                        ForEach(PNGSizeMode.allCases) { m in Text(m.title).tag(m) }
                    }
                    .labelsHidden().frame(width: 90)

                    if settings.sizeMode == .scale {
                        slider($settings.scalePercent, 10...400).frame(width: 150)
                        Text("\(settings.scalePercent)%").font(.system(size: 11)).monospacedDigit().frame(width: 46)
                    } else {
                        intField($settings.pixelWidth).frame(width: 66)
                        Text("×").foregroundStyle(.secondary)
                        intField($settings.pixelHeight).frame(width: 66)
                        Text("px").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            field("Frames:") {
                HStack(spacing: 8) {
                    check("Range", $settings.useFrameRange)
                    if settings.useFrameRange {
                        intField($settings.startFrame).frame(width: 56)
                        Text("→").foregroundStyle(.secondary)
                        intField($settings.endFrame).frame(width: 56)
                        Text("(\(max(settings.endFrame - settings.startFrame + 1, 0)))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            field("FPS:") { intField($settings.fps).frame(width: 56) }

            Divider().padding(.vertical, 4)

            field("Background:") { check("Transparent", $settings.transparentBackground) }
            field("Compression:") {
                HStack(spacing: 8) {
                    slider($settings.compression, 0...9).frame(width: 190)
                    Text(compressionLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            field("Optimization:") {
                HStack(spacing: 14) {
                    check("Reduce colors", $settings.reduceColors)
                }
            }
        }
    }

    private var smoothingLabel: String {
        settings.smoothing == 0 ? "Nearest (crisp)" : "Bilinear \(settings.smoothing * 10)%"
    }

    private var compressionLabel: String {
        switch settings.compression {
        case 0...2: return "Low (fast)"
        case 3...6: return "Medium (default)"
        default:    return "High (small)"
        }
    }

    // MARK: Validation block

    private var validationBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Validation").font(.system(size: 12, weight: .semibold))
                if isValidating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Re-check") { runValidation() }.font(.system(size: 11))
            }
            if let v = validation {
                HStack(spacing: 14) {
                    Label("\(v.errors.count) errors",
                          systemImage: v.errors.isEmpty ? "checkmark.circle" : "xmark.octagon")
                        .foregroundStyle(v.errors.isEmpty ? .green : .red)
                        .font(.system(size: 11, weight: .medium))
                    Label("\(v.warnings.count) warnings", systemImage: "exclamationmark.triangle")
                        // Both branches must name Color explicitly: `.secondary`
                        // alone resolves to HierarchicalShapeStyle, which has no
                        // `.orange`, and the ternary forces one shared type.
                        .foregroundStyle(v.warnings.isEmpty ? Color.secondary : Color.orange)
                        .font(.system(size: 11))
                    Text("~\(byteString(v.byteEstimate))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                ForEach(Array((v.errors + v.warnings).prefix(5).enumerated()), id: \.offset) { item in
                    Text("• \(item.element)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Not checked yet.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusBanner: some View {
        switch status {
        case .idle: EmptyView()
        case .running:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Exporting…").font(.system(size: 11)) }
        case .success(let m):
            Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 11))
        case .failure(let m):
            Label(m, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                .font(.system(size: 11)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { savePreset() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .disabled(settings.outputPath.isEmpty)
            Button { loadPresetPicker() } label: { Label("Load", systemImage: "square.and.arrow.up") }
            Spacer()
            check("Open after export", $settings.openAfterExport)
            Button { performExport() } label: {
                Label("Export", systemImage: "square.and.arrow.up.on.square")
                    .frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canExport)
            Button(role: .cancel) { onClose() } label: { Label("Cancel", systemImage: "xmark.circle") }
                .keyboardShortcut(.cancelAction)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var canExport: Bool {
        guard !settings.outputPath.isEmpty, status != .running else { return false }
        if settings.kind == .json, settings.warnings, let v = validation, !v.isValid { return false }
        return true
    }

    // MARK: - Reusable controls

    @ViewBuilder
    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private func check(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) { Text(title).font(.system(size: 11)) }
#if os(macOS)
            .toggleStyle(.checkbox)
#else
            // Compact switches keep the dense rows readable on iPad.
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()
#endif
    }

    private func intField(_ binding: Binding<Int>) -> some View {
        TextField("", value: binding, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder).font(.system(size: 11))
    }

    private func slider(_ binding: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        Slider(
            value: Binding(get: { Double(binding.wrappedValue) },
                           set: { binding.wrappedValue = Int($0.rounded()) }),
            in: Double(range.lowerBound)...Double(range.upperBound)
        )
    }

    private func pathField(text: Binding<String>, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 300)
            Button { choose() } label: { Image(systemName: "folder") }
                .help("Choose folder")
        }
    }

    private var sidebarBackground: Color {
#if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
#else
        Color(.secondarySystemBackground)
#endif
    }

    private func byteString(_ bytes: Int) -> String {
        if bytes > 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        if bytes > 1_000 { return String(format: "%.0f KB", Double(bytes) / 1_000) }
        return "\(bytes) B"
    }

    // MARK: - Load / persist dialog state

    private func load() {
        if !storedSettingsJSON.isEmpty,
           let data = storedSettingsJSON.data(using: .utf8),
           let restored = try? ExportSettings.decoded(from: data) {
            settings = restored
        }
        let base = appState.projectFileURL?.deletingPathExtension().lastPathComponent
            ?? appState.suggestedProjectName
        if settings.fileName.isEmpty { settings.fileName = base }
        if settings.filenamePrefix.isEmpty || settings.filenamePrefix == "frame" {
            settings.filenamePrefix = appState.animationLibrary.active?.name ?? base
        }
        settings.fps = Int(appState.sceneManager.projectFramesPerSecond.rounded())
        initializeFrameRange()
        if settings.kind == .json { runValidation() }
    }

    private func persist() {
        if let data = try? settings.encoded(), let s = String(data: data, encoding: .utf8) {
            storedSettingsJSON = s
        }
    }

    private func initializeFrameRange() {
        let s = appState.sceneManager
        let boneDur = s.skeleton.orderedBones.map { $0.animationClip.durationInFrames }.max() ?? 0
        let imgDur = s.images.map { $0.animationClip.durationInFrames }.max() ?? 0
        let sceneDur = s.sceneAnimationClip.durationInFrames
        settings.startFrame = max(0, s.playbackStartFrame)
        settings.endFrame = max(max(boneDur, imgDur, sceneDur, s.playbackEndFrame), s.currentFrame)
        if settings.endFrame < settings.startFrame { settings.endFrame = settings.startFrame }
    }

    // MARK: - Presets

    private func savePreset() {
#if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Save Export Settings"
        panel.prompt = "Save"
        panel.nameFieldStringValue = "\(settings.fileName)-export.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.encoded().write(to: url, options: .atomic)
            status = .success("Saved settings to \(url.lastPathComponent)")
        } catch {
            status = .failure("Could not save settings: \(error.localizedDescription)")
        }
#else
        // iOS: presets live in the app's documents folder.
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(settings.fileName)-export.json")
        do {
            try settings.encoded().write(to: url, options: .atomic)
            status = .success("Saved settings to Documents/\(url.lastPathComponent)")
        } catch {
            status = .failure("Could not save settings: \(error.localizedDescription)")
        }
#endif
    }

    private func loadPresetPicker() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Load Export Settings"
        panel.prompt = "Load"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadPreset(from: url)
#else
        isPickingPreset = true
#endif
    }

    private func loadPreset(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            settings = try ExportSettings.decoded(from: data)
            status = .success("Loaded settings from \(url.lastPathComponent)")
            if settings.kind == .json { runValidation() }
        } catch {
            status = .failure("Could not load settings: \(error.localizedDescription)")
        }
    }

    // MARK: - Output picking

    private func chooseFolder() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !settings.outputPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: settings.outputPath)
        }
        if panel.runModal() == .OK, let url = panel.url { settings.outputPath = url.path }
#else
        isPickingFolder = true
#endif
    }

    // MARK: - Validation

    private func runValidation() {
        guard settings.kind == .json else { validation = nil; return }
        isValidating = true
        let scene = appState.sceneManager
        let assets = appState.assetManager
        let library = appState.animationLibrary
        let opts = jsonOptions(embedTextures: false)
        let exportAll = settings.exportAll
        let reproducible = settings.reproducible

        Task { @MainActor in
            let animations = UMExportAnimationSource.gather(
                scene: scene, library: exportAll ? library : nil)
            let request = UltraMeshJSONExportRequest(
                options: opts, includeExportDate: !reproducible, strict: false)
            do {
                let (data, report) = try UltraMeshJSONExporter.export(
                    scene: scene, assets: assets, animations: animations, request: request)
                validation = ValidationSummary(
                    errors: report.errors.map { $0.message },
                    warnings: report.warnings.map { $0.message },
                    byteEstimate: data.count)
            } catch {
                validation = ValidationSummary(
                    errors: [error.localizedDescription], warnings: [], byteEstimate: 0)
            }
            isValidating = false
        }
    }

    private func jsonOptions(embedTextures: Bool) -> UMJSONExportOptions {
        UMJSONExportOptions(
            floatPrecision: settings.floatPrecision,
            embedTextures: embedTextures,
            nonessentialData: settings.nonessentialData,
            animationCleanUp: settings.animationCleanUp,
            prettyPrint: settings.prettyPrint
        )
    }

    // MARK: - Export

    private func performExport() {
        guard !settings.outputPath.isEmpty else { return }
        let folder = URL(fileURLWithPath: settings.outputPath, isDirectory: true)
        status = .running
        persist()

        let scene = appState.sceneManager
        let assets = appState.assetManager
        let library = appState.animationLibrary
        let manager = appState.exportManager
        let cfg = settings

        Task { @MainActor in
            do {
                switch cfg.kind {
                case .json:
                    let ext = cfg.fileExtension.hasPrefix(".")
                        ? String(cfg.fileExtension.dropFirst()) : cfg.fileExtension
                    let target = folder.appendingPathComponent(cfg.fileName)
                        .appendingPathExtension(ext.isEmpty ? "json" : ext)
                    let animations = UMExportAnimationSource.gather(
                        scene: scene, library: cfg.exportAll ? library : nil)
                    let report = try UltraMeshJSONExporter.write(
                        scene: scene, assets: assets, animations: animations, to: target,
                        request: UltraMeshJSONExportRequest(
                            options: jsonOptions(embedTextures: cfg.embedTextures),
                            includeExportDate: !cfg.reproducible,
                            strict: cfg.warnings))
                    lastOutputURL = target
                    let warn = report.warnings.isEmpty ? "" : " · \(report.warnings.count) warning(s)"
                    let atlas = packAtlasIfRequested(scene: scene, assets: assets,
                                                        directory: folder, config: cfg)
                    status = .success("Exported \(target.lastPathComponent)\(warn)\(atlas)")
                    reveal(target)

                case .binary:
                    let ext = cfg.fileExtension.hasPrefix(".")
                        ? String(cfg.fileExtension.dropFirst()) : cfg.fileExtension
                    let target = folder.appendingPathComponent(cfg.fileName)
                        .appendingPathExtension(ext.isEmpty ? "umesh" : ext)
                    try await manager.exportSkeleton(
                        scene: scene, assets: assets, to: target,
                        options: BinaryExportOptions(
                            textureEmbedMode: cfg.embedTextures ? .embed : .reference,
                            includeBaseAnimations: true,
                            prettyName: cfg.fileName))
                    lastOutputURL = target
                    let atlas = packAtlasIfRequested(scene: scene, assets: assets,
                                                        directory: folder, config: cfg)
                    status = .success("Exported \(target.lastPathComponent)\(atlas)")
                    reveal(target)

                case .png:
                    guard cfg.fps > 0 else { status = .failure("FPS must be positive."); return }
                    let (w, h) = cfg.resolvedPixelSize(viewportWidth: 1024, viewportHeight: 1024)
                    let range: ClosedRange<Int>?
                    if cfg.pngExportType == .currentPose {
                        range = scene.currentFrame...scene.currentFrame
                    } else if cfg.useFrameRange {
                        guard cfg.endFrame >= cfg.startFrame else {
                            status = .failure("End frame must be ≥ start frame."); return
                        }
                        range = cfg.startFrame...cfg.endFrame
                    } else {
                        range = nil
                    }
                    let bg = cfg.transparentBackground
                        ? SIMD4<Float>(0, 0, 0, 0) : SIMD4<Float>(0, 0, 0, 1)
                    let req = PNGExportRequest(
                        animationName: nil,
                        fps: Double(cfg.fps),
                        frameRange: range,
                        outputDirectory: folder,
                        filenamePrefix: cfg.filenamePrefix.isEmpty ? "frame" : cfg.filenamePrefix,
                        frameSpec: PNGFrameSpec(
                            width: w, height: h, clearColor: bg,
                            cameraOrigin: cameraOrigin,
                            cameraZoom: cameraZoom * cfg.zoomMultiplier,
                            smoothing: cfg.smoothing,
                            renderImages: cfg.renderImages),
                        compression: cfg.compression,
                        reduceColors: cfg.reduceColors,
                        warmUpFrames: cfg.warmUp,
                        cropToContent: cfg.cropViewport,
                        cropPadding: Float(max(0, cfg.cropPadding)))
                    let result = try await manager.exportPNGSequence(
                        scene: scene, request: req, assets: assets)
                    lastOutputURL = result.filesWritten.first
                    status = .success("Wrote \(result.filesWritten.count) frames in \(String(format: "%.1f", result.totalDurationSeconds))s")
                    if let first = result.filesWritten.first { reveal(first) }
                }
            } catch {
                status = .failure(error.localizedDescription)
                PlatformFeedback.errorBeep()
            }
        }
    }

    /// Runs the atlas packer when "Texture atlas: Pack" is on, writing the pages
    /// and `.atlas` descriptor alongside the exported data file. Returns a short
    /// suffix for the status line, or an empty string when packing is off.
    /// `@MainActor` because the packer touches `SceneManager`/`AssetManager`,
    /// both main-actor isolated; without this the synchronous call from a
    /// nonisolated view method does not compile.
    /// Packing failure must not be reported as export failure: the data file is
    /// already on disk at this point, so the atlas is downgraded to a warning in
    /// the status line rather than throwing away a successful export.
    @MainActor
    private func packAtlasIfRequested(scene: SceneManager,
                                      assets: AssetManager,
                                      directory: URL,
                                      config: ExportSettings) -> String {
        guard config.packTextureAtlas else { return "" }
        do {
            let result = try TextureAtlasPacker.pack(
                scene: scene, assets: assets, to: directory,
                options: AtlasPackOptions(
                    maxPageWidth: max(64, config.atlasMaxWidth),
                    maxPageHeight: max(64, config.atlasMaxHeight),
                    padding: max(0, config.atlasPadding),
                    powerOfTwo: config.atlasPowerOfTwo,
                    stripWhitespace: config.atlasStripWhitespace,
                    name: config.fileName.isEmpty ? "atlas" : config.fileName))
            let pages = result.pageURLs.count
            let fill = Int((result.occupancy * 100).rounded())
            return " · atlas: \(result.regionCount) regions, \(pages) page\(pages == 1 ? "" : "s") (\(fill)% full)"
        } catch {
            return " · atlas skipped: \(error.localizedDescription)"
        }
    }

    /// Honors "Open after export" — reveals the produced file in Finder.
    private func reveal(_ url: URL) {
#if os(macOS)
        guard settings.openAfterExport else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
#endif
    }
}
