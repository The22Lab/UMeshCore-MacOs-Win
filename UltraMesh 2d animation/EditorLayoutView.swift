import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
#if os(macOS)
import AppKit
#endif

struct EditorLayoutView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var isPresentingSaveSheet = false
    @State private var saveProjectName = ""
    @State private var isConfirmingNewProject = false
    @State private var saveDirectoryURL: URL?
    @State private var isInspectorVisible = true
    @State private var isPresentingPNGExportSheet = false

    /// Where imported PNGs go. What the files BECOME differs; deciding it once
    /// here keeps the two platforms from drifting.
    private enum ImageImportDestination { case rig, scenePlate }
    @State private var imageImportDestination: ImageImportDestination = .rig

    // iOS: one unified file picker — multiple .fileImporter modifiers on the same
    // view only honour the last one on iOS, causing silent failures.
    // macOS: separate @State vars are fine (NSOpenPanel handles PNG/dir directly,
    // so only the project fileImporter ever fires and there is no conflict).
#if os(iOS)
    // No `.directory` case: the Save sheet owns its own folder picker,
    // because a picker has to be attached to the view that is on screen and
    // the sheet is what is on screen when Choose Folder is pressed.
    private enum FilePickerIntent { case project, images }
    @State private var filePickerIntent: FilePickerIntent? = nil
    // Captured at presentation time; NOT cleared by the binding's set — only by
    // the result callback's defer. Fixes a SwiftUI/iOS bug where the binding
    // set fires before onCompletion, leaving filePickerIntent nil in the callback.
    @State private var filePickerCapturedIntent: FilePickerIntent? = nil
    private var isImportingProject: Bool {
        get { filePickerIntent == .project }
        nonmutating set {
            filePickerIntent = newValue ? .project : nil
            if newValue { filePickerCapturedIntent = .project }
        }
    }
    private var isImportingPNG: Bool {
        get { filePickerIntent == .images }
        nonmutating set {
            filePickerIntent = newValue ? .images : nil
            if newValue { filePickerCapturedIntent = .images }
        }
    }
#else
    // macOS drives every file dialog through NSOpenPanel/NSSavePanel, so it
    // needs no picker state. The three @State flags that used to live here were
    // read by nothing on this platform — they only fed `.fileImporter`
    // modifiers that SwiftUI never installed.
#endif

    @State private var isPickingFromPhotos = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showsImportSourceChoice = false
    @State private var pendingFilesImport = false
    @State private var pendingPhotosImport = false
    @State private var skeletonExportURL: URL?
    @State private var isSharingSkeleton = false
    @State private var isPresentingExportDialog = false
    @State private var exportAlertTitle = ""
    @State private var exportAlertMessage = ""
    @State private var showsExportResultAlert = false

    private let leftPanelWidth: CGFloat = 260
    private let rightPanelWidth: CGFloat = 280
    private let toolbarHeight: CGFloat = 52
    private let mainAreaMinHeight: CGFloat = 44
    private var showsTimeline: Bool { appState.editorMode == .animation }
    @State private var timelinePanelHeight: CGFloat = 280
    @State private var timelineDragStartHeight: CGFloat = 280

    @AppStorage("umInterfaceScale") private var storedScale: Double = 0.82
    @State private var showsInterfaceSettings = false
    @State private var importErrorMessage: String? = nil

    private var uiScale: CGFloat {
        #if os(iOS)
        return CGFloat(storedScale)
        #else
        return 1.0
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            // Registers the editor-wide key map with the responder chain on
            // both macOS and iPadOS. Zero-sized, so it does not affect layout.
            KeyboardShortcutHost(
                appState: appState,
                scene: appState.sceneManager,
                tools: appState.toolManager
            )

            ScaledContainer(scale: uiScale) {
                EditorToolbarView(
                    sceneManager: appState.sceneManager,
                    toolManager: appState.toolManager,
                    leftPanelWidth: leftPanelWidth,
                    rightPanelWidth: rightPanelWidth,
                    isInspectorVisible: isInspectorVisible,
                    onToggleInspector: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isInspectorVisible.toggle()
                        }
                    }
                )
            }
            .frame(height: toolbarHeight * uiScale)

            Group {
                if appState.editorMode == .scene {
                    // Scene replaces the whole rig workspace: its own panels,
                    // its own viewport, its own scrubber. Nothing of the rig
                    // canvas stays interactive underneath it.
                    SceneWorkspaceView()
                } else if showsTimeline {
                    VStack(spacing: 0) {
                        workspaceArea
                            .frame(maxHeight: .infinity)
                        timelinePanelResizeHandle
                        ScaledContainer(scale: uiScale) {
                            TimelineView(sceneManager: appState.sceneManager)
                        }
                        .frame(height: timelinePanelHeight)
                    }
                } else {
                    workspaceArea
                }
            }
            .frame(maxHeight: .infinity)
            .background(UM.appBackground)
        }
        .background(UM.appBackground)
        // ── Notifications (same on all platforms) ─────────────────────────
        .onReceive(NotificationCenter.default.publisher(for: .ultraMeshRequestSaveAs)) { _ in
            presentSaveSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ultraMeshRequestNewProject)) { _ in
            isConfirmingNewProject = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .ultraMeshRequestOpenProject)) { _ in
            openProjectPanel()
        }
        // ASKED, ALWAYS. Not only when something looks unsaved: the editor has
        // no reliable dirty flag — a mesh edit, a weight, a keyframe and a
        // camera move all change the project and none of them set one — so
        // guessing would mean sometimes discarding an afternoon without a word.
        // One dialog costs a tap and cannot be wrong.
        .confirmationDialog("Start a new project?",
                            isPresented: $isConfirmingNewProject,
                            titleVisibility: .visible) {
            Button("New Project", role: .destructive) {
                appState.newProject()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The rig, the animations and the scenes currently open will be "
                 + "cleared. Anything not saved is lost.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .ultraMeshRequestImportPNG)) { _ in
            openImportPanel(destination: .rig)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ultraMeshRequestImportScenePlate)) { _ in
            openImportPanel(destination: .scenePlate)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ultraMeshRequestExportSkeleton)) { _ in
            runSkeletonExportPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ultraMeshRequestExportPNGSequence)) { _ in
            runPNGSequenceExportPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ultraMeshRequestExportSceneVideo)) { _ in
            runSceneVideoExportPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ultraMeshRequestExportDialog)) { _ in
            isPresentingExportDialog = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .ultraMeshRequestSettings)) { _ in
            showsInterfaceSettings = true
        }
#if os(iOS)
        // ── Unified file picker (iOS) ──────────────────────────────────────
        // Single instance — avoids the iOS bug where only the last
        // .fileImporter modifier on a view responds to isPresented changes.
        .fileImporter(
            isPresented: Binding<Bool>(
                get: { filePickerIntent != nil },
                set: { if !$0 { filePickerIntent = nil } }
            ),
            allowedContentTypes: pickerAllowedContentTypes,
            allowsMultipleSelection: filePickerIntent == .images
        ) { result in handlePickerResult(result) }
#endif
        // macOS opens projects through NSOpenPanel in `openProjectPanel()`,
        // alongside every other panel on this platform. There used to be three
        // stacked `.fileImporter` modifiers here — the project one plus two the
        // comment itself called "never triggered" — and SwiftUI installs only
        // the LAST modifier of that kind on a view. The live one was the folder
        // picker, so setting `isImportingProject = true` did nothing at all and
        // both the Open Project button and Cmd-O were dead.
        //
        // The iOS half of this file already documents that exact behaviour and
        // works around it with a single unified picker; the assumption that
        // macOS was immune is what left it broken here.
        // ── Import source choice (iOS) ─────────────────────────────────────
#if os(iOS)
        .sheet(isPresented: $showsImportSourceChoice, onDismiss: { importSourceDismissed() }) {
            ImportSourceSheet(
                onPhotoLibrary: {
                    pendingPhotosImport = true
                    showsImportSourceChoice = false
                },
                onFiles: {
                    pendingFilesImport = true
                    showsImportSourceChoice = false
                }
            )
            .presentationDetents([.height(230)])
            .presentationDragIndicator(.visible)
        }
#endif
        // ── Photos library picker ──────────────────────────────────────────
        .photosPicker(
            isPresented: $isPickingFromPhotos,
            selection: $selectedPhotos,
            maxSelectionCount: nil,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: selectedPhotos) { _, newPhotos in
            guard !newPhotos.isEmpty else { return }
            Task {
                var urls: [URL] = []
                for item in newPhotos {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString + ".png")
                        try? data.write(to: url)
                        urls.append(url)
                    }
                }
                selectedPhotos = []
                guard !urls.isEmpty else { return }
                do {
                    try applyImportedPNGs(urls)
                } catch { PlatformFeedback.errorBeep() }
            }
        }
        // ── Skeleton share sheet (iOS) ────────────────────────────────────
#if os(iOS)
        .sheet(isPresented: $isSharingSkeleton) {
            if let url = skeletonExportURL {
                ShareSheetView(items: [url])
            }
        }
#endif
        // ── Interface / panel settings ─────────────────────────────────────
        .sheet(isPresented: $showsInterfaceSettings) {
            InterfaceScaleSettingsView(scale: $storedScale)
#if os(iOS)
                .presentationDetents([.height(400)])
                .presentationDragIndicator(.visible)
#else
                .frame(minWidth: 300)
#endif
        }
        // ── Save As sheet ─────────────────────────────────────────────────
        .sheet(isPresented: $isPresentingSaveSheet) {
            // Built twice rather than passing a conditional argument: Swift
            // has no `#if` between call arguments, and `onChooseDirectory`
            // cannot exist on iOS because the panel it runs is macOS-only.
#if os(macOS)
            SaveProjectSheet(
                projectName: $saveProjectName,
                directoryURL: $saveDirectoryURL,
                onChooseDirectory: { chooseProjectSaveDirectory() },
                onCancel: { isPresentingSaveSheet = false },
                onSave: { confirmProjectSave() }
            )
#else
            SaveProjectSheet(
                projectName: $saveProjectName,
                directoryURL: $saveDirectoryURL,
                onCancel: { isPresentingSaveSheet = false },
                onSave: { confirmProjectSave() }
            )
#endif
        }
        // ── Unified Export dialog (all formats) ──────────────
        .sheet(isPresented: $isPresentingExportDialog) {
            ExportDialog(
                appState: appState,
                cameraOrigin: SIMD2<Float>(Float(appState.camera.origin.x), Float(appState.camera.origin.y)),
                cameraZoom: Float(appState.camera.zoom),
                onClose: { isPresentingExportDialog = false }
            )
        }
        // ── PNG Export sheet ──────────────────────────────────────────────
        .sheet(isPresented: $isPresentingPNGExportSheet) {
            PNGExportSheet(
                scene: appState.sceneManager,
                library: appState.animationLibrary,
                cameraOrigin: SIMD2<Float>(Float(appState.camera.origin.x), Float(appState.camera.origin.y)),
                cameraZoom: Float(appState.camera.zoom),
                onCancel: { isPresentingPNGExportSheet = false },
                onExport: { request in
                    isPresentingPNGExportSheet = false
                    performPNGExport(request: request)
                }
            )
        }
        // ── Export result alert (iOS) ─────────────────────────────────────
        .alert(exportAlertTitle, isPresented: $showsExportResultAlert) {
            Button("OK") {}
        } message: {
            Text(exportAlertMessage)
        }
        // ── Import error alert ────────────────────────────────────────────
        .alert("Import Failed", isPresented: Binding<Bool>(
            get: { importErrorMessage != nil || appState.lastErrorMessage != nil },
            set: { (show: Bool) in
                if !show {
                    importErrorMessage = nil
                    appState.lastErrorMessage = nil
                }
            }
        )) {
            Button("OK") {
                importErrorMessage = nil
                appState.lastErrorMessage = nil
            }
        } message: {
            Text(importErrorMessage ?? appState.lastErrorMessage ?? "")
        }
    }

    // MARK: - Platform actions

    #if os(iOS)
    // Trigger pickers AFTER the sheet is fully dismissed to avoid presentation
    // conflicts (the root cause of Files not opening). Delay so the sheet dismiss
    // animation completes before the next modal presents.
    private func importSourceDismissed() {
        if pendingPhotosImport {
            pendingPhotosImport = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isPickingFromPhotos = true
            }
        } else if pendingFilesImport {
            pendingFilesImport = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isImportingPNG = true
            }
        }
    }

    private var pickerAllowedContentTypes: [UTType] {
        switch filePickerIntent {
        case .project: return [ProjectPersistence.projectContentType]
        case .images:  return [.png, .jpeg, .image]
        case nil:      return [.item]
        }
    }

    private func handlePickerResult(_ result: Result<[URL], Error>) {
        defer {
            filePickerIntent = nil
            filePickerCapturedIntent = nil
        }
        switch filePickerCapturedIntent {
        case .project:
            if case let .success(urls) = result, let url = urls.first {
                appState.openProject(from: url)
            } else if case let .failure(err) = result {
                importErrorMessage = err.localizedDescription
            }
        case .images:
            switch result {
            case let .success(urls):
                do {
                    try applyImportedPNGs(urls)
                } catch {
                    importErrorMessage = error.localizedDescription
                }
            case let .failure(err):
                let code = (err as NSError).code
                let cancelCode: Int = CocoaError.userCancelled.rawValue
                let isCancelled = code == NSUserCancelledError || code == cancelCode
                if !isCancelled {
                    importErrorMessage = err.localizedDescription
                }
            }
        case nil:
            if case let .success(urls) = result, !urls.isEmpty {
                importErrorMessage = "Import failed: could not determine file type (intent lost). Please try again."
            }
        }
    }
    #endif

    /// Opens a project. NSOpenPanel on macOS, the unified picker on iOS.
    private func openProjectPanel() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.message = "Open UltraMesh project"
        panel.prompt = "Open"
        panel.allowedContentTypes = [ProjectPersistence.projectContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        // A project is a package, i.e. a directory on disk. The panel has to
        // hand it back as a single file instead of descending into it.
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = appState.projectFileURL?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            appState.openProject(from: url)
        }
        #else
        isImportingProject = true
        #endif
    }

    /// Import PNGs and put them where the destination says.
    ///
    /// The rig's import makes each file a sprite; a Scene plate is an asset and
    /// a card and nothing else — no hierarchy row, no mesh, no bones. That
    /// difference is the whole of "importar PNG sin necesidad de provenir de
    /// animator o rigs", and it lives here so neither platform's picker can
    /// implement half of it.
    private func applyImportedPNGs(_ urls: [URL]) throws {
        let assets = try appState.assetManager.importPNGs(urls: urls)
        switch imageImportDestination {
        case .rig:
            let spawn = appState.camera.origin
            let position = SIMD2<Float>(Float(spawn.x), Float(spawn.y))
            // PAIRED HERE, where both managers are in hand. Importing
            // `hero.png` and `hero_n.png` together places one sprite with its
            // relief already attached -- the map is not placeable itself, so
            // `importPNGs` returned it and nothing tried to make a sprite of
            // it. Resolved AFTER the whole import, so the order the files
            // arrived in does not decide whether the pair is found.
            let placeable = assets.filter(\.isPlaceable)
            placeable.forEach { asset in
                appState.sceneManager.addImage(
                    asset: asset, position: position,
                    normalMapAssetID: appState.assetManager
                        .pairedNormalMapID(forArtworkNamed: asset.name))
            }
        case .scenePlate:
            appState.sceneManager.ensureSceneCompositionExists()
            guard let composition = appState.sceneManager.selectedSceneComposition else { return }
            let maps = Dictionary(uniqueKeysWithValues: assets.compactMap { asset in
                appState.assetManager.pairedNormalMapID(forArtworkNamed: asset.name)
                    .map { (asset.id, $0) }
            })
            // The same pairing, one role along: `hero.png` + `hero_h.png`
            // lands with its height field already attached. Resolved AFTER the
            // whole import, like the normal maps, so the order the files
            // arrived in does not decide whether the pair is found.
            let heights = Dictionary(uniqueKeysWithValues: assets.compactMap { asset in
                appState.assetManager.pairedHeightMapID(forArtworkNamed: asset.name)
                    .map { (asset.id, $0) }
            })
            appState.sceneManager.addScenePlates(assets: assets, to: composition.id,
                                                 normalMaps: maps, heightMaps: heights)
        }
    }

    private func openImportPanel(destination: ImageImportDestination = .rig) {
        imageImportDestination = destination
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.png]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            do {
                try applyImportedPNGs(panel.urls)
            } catch {
                PlatformFeedback.errorBeep()
            }
        }
        #else
        showsImportSourceChoice = true
        #endif
    }

    /// Where a project goes when the artist has not chosen a folder.
    ///
    /// "No folder selected" meant Save beeped and threw a folder picker at you
    /// before it would do anything — on iPad, where there was no Save button to
    /// begin with, that was the very first thing you would have met. The app's
    /// own Documents directory is the obvious default, and with
    /// UIFileSharingEnabled set it is the folder that appears in Files under
    /// On My iPad ▸ UltraMesh, so the project can be found again afterwards.
    private var defaultSaveDirectory: URL? {
        try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private func presentSaveSheet() {
        saveProjectName = appState.projectFileURL?.deletingPathExtension().lastPathComponent ?? appState.suggestedProjectName
        // The folder the artist picked last time comes back first: on iOS
        // that is the only one the app still has permission to write to, and
        // offering Documents instead of it silently changes where the project
        // lands.
#if os(iOS)
        let remembered = ProjectFolderAccess.remembered()
#else
        let remembered: URL? = nil
#endif
        saveDirectoryURL = appState.projectFileURL?.deletingLastPathComponent()
            ?? saveDirectoryURL
            ?? remembered
            ?? defaultSaveDirectory
        isPresentingSaveSheet = true
    }

    /// macOS only. On iOS the Save sheet presents its own `.fileImporter`;
    /// see `SaveProjectSheet`. Driving a document picker from here — the
    /// editor's root view, which is already presenting the sheet — is what
    /// made Choose Folder do nothing at all on iPad.
    #if os(macOS)
    private func chooseProjectSaveDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Project Folder"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveDirectoryURL
        if panel.runModal() == .OK { saveDirectoryURL = panel.url }
    }
    #endif

    /// Render the open Scene to a movie.
    ///
    /// Refuses with a reason rather than producing a zero-byte file when there
    /// is no Scene to render — the mode has to have been opened at least once.
    private func runSceneVideoExportPanel() {
        guard let composition = appState.sceneManager.selectedSceneComposition else {
            exportAlertTitle = "No scene to export"
            exportAlertMessage = "Open Scene mode and stage at least one layer first."
            showsExportResultAlert = true
            return
        }

        let suggested = composition.name.replacingOccurrences(of: "/", with: "-") + ".mov"
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Export Scene Video"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runSceneVideoExport(composition: composition, to: url)
        #else
        // iPadOS has no save panel: write into the app's Documents folder,
        // which UIFileSharingEnabled makes visible in Files, then say where it
        // went. Silently dropping a render somewhere unreachable is the same
        // failure the project save had.
        guard let directory = defaultSaveDirectory else {
            exportAlertTitle = "Export failed"
            exportAlertMessage = "Could not reach the Documents folder."
            showsExportResultAlert = true
            return
        }
        runSceneVideoExport(composition: composition,
                            to: directory.appendingPathComponent(suggested))
        #endif
    }

    private func runSceneVideoExport(composition: SceneComposition, to url: URL) {
        Task { @MainActor in
            do {
                try await appState.exportManager.exportSceneVideo(
                    renderer: appState.sceneFrameRenderer,
                    metal: appState.sceneMetalRenderer,
                    scene: appState.sceneManager,
                    assets: appState.assetManager,
                    request: VideoExporter.Request(
                        composition: composition,
                        destination: url,
                        pixelSize: nil,
                        bitrate: nil
                    )
                )
                exportAlertTitle = "Scene exported"
                exportAlertMessage = "Saved to \(url.path(percentEncoded: false))"
            } catch {
                exportAlertTitle = "Export failed"
                exportAlertMessage = error.localizedDescription
            }
            showsExportResultAlert = true
        }
    }

    private func runSkeletonExportPanel() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Export Skeleton"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (appState.projectFileURL?
            .deletingPathExtension().lastPathComponent
            ?? appState.suggestedProjectName) + ".umesh"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The name field above proposes the project's own filename plus
        // ".umesh" — which is exactly what the project package is called. The
        // save panel then offers to replace it and the artist says yes, because
        // it is their rig. ExportManager refuses that write; the catch below
        // reports why.
        Task {
            do {
                try await appState.exportManager.exportSkeleton(
                    scene: appState.sceneManager,
                    assets: appState.assetManager,
                    to: url
                )
            } catch {
                PlatformFeedback.errorBeep()
                print("UltraMesh skeleton export failed:", error.localizedDescription)
                appState.lastErrorMessage =
                    "Could not export the skeleton.\n\n\(error.localizedDescription)"
            }
        }
        #else
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(appState.suggestedProjectName)
            .appendingPathExtension("umesh")
        Task {
            do {
                try await appState.exportManager.exportSkeleton(
                    scene: appState.sceneManager,
                    assets: appState.assetManager,
                    to: tmpURL
                )
                skeletonExportURL = tmpURL
                isSharingSkeleton = true
            } catch {
                PlatformFeedback.errorBeep()
                print("UltraMesh skeleton export failed:", error.localizedDescription)
            }
        }
        #endif
    }

    private func runPNGSequenceExportPanel() {
        isPresentingPNGExportSheet = true
    }

    private func performPNGExport(request: PNGExportRequest) {
        Task {
            do {
                let result = try await appState.exportManager.exportPNGSequence(
                    scene: appState.sceneManager,
                    request: request
                )
                #if os(macOS)
                let alert = NSAlert()
                alert.messageText = "Export complete"
                alert.informativeText = "Wrote \(result.filesWritten.count) frames in \(String(format: "%.1f", result.totalDurationSeconds))s."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Reveal in Finder")
                alert.addButton(withTitle: "OK")
                if alert.runModal() == .alertFirstButtonReturn,
                   let first = result.filesWritten.first {
                    NSWorkspace.shared.activateFileViewerSelecting([first])
                }
                #else
                exportAlertTitle = "Export complete"
                exportAlertMessage = "Wrote \(result.filesWritten.count) frames in \(String(format: "%.1f", result.totalDurationSeconds))s."
                showsExportResultAlert = true
                #endif
            } catch {
                #if os(macOS)
                let alert = NSAlert()
                alert.messageText = "Export failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
                #else
                exportAlertTitle = "Export failed"
                exportAlertMessage = error.localizedDescription
                showsExportResultAlert = true
                #endif
            }
        }
    }

    private func confirmProjectSave() {
        let trimmedName = saveProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            PlatformFeedback.errorBeep()
            return
        }
        guard let destinationDirectory = saveDirectoryURL ?? defaultSaveDirectory else {
            // No second picker from here: on iOS the sheet is on screen and
            // would swallow it, and the sheet already refuses to call this
            // without a folder. Say why instead of beeping into the void.
            PlatformFeedback.errorBeep()
            appState.lastErrorMessage =
                "Choose a folder to save into before saving the project."
            return
        }
        let destinationURL = destinationDirectory
            .appendingPathComponent(trimmedName)
            .appendingPathExtension(ProjectPersistence.projectFileExtension)
        // Dismiss first, save after. `saveProject(to:)` reports a failure
        // through `lastErrorMessage`, which the root view shows as an alert —
        // and the root view cannot present an alert while this sheet is still
        // up. Saving in the same breath as the dismissal is how that message
        // would be lost, which is the failure this whole change is about.
        // Same shape as the import pickers above.
        isPresentingSaveSheet = false
        DispatchQueue.main.async {
            appState.saveProject(to: destinationURL)
        }
    }

    // MARK: - Layout

    private var timelinePanelResizeHandle: some View {
        Rectangle()
            .fill(UM.surfaceInset)
            .frame(height: 5)
#if os(iOS)
            // The 5 pt divider stays visually thin, but a finger gets a
            // ~29 pt grab band above and below it.
            .contentShape(Rectangle().inset(by: -12))
#else
            .contentShape(Rectangle())
#endif
            .onHover { inside in
                #if os(macOS)
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                #endif
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    timelinePanelHeight = max(52, timelineDragStartHeight - value.translation.height)
                }
                .onEnded { value in
                    let h = max(52, timelineDragStartHeight - value.translation.height)
                    timelinePanelHeight = h
                    timelineDragStartHeight = h
                }
            )
    }

    private var workspaceArea: some View {
        HStack(spacing: 0) {
            // On compact iPad (portrait), panels are still shown but narrower.
            ScaledContainer(scale: uiScale) {
                HierarchyPanelView(
                    assetManager: appState.assetManager,
                    sceneManager: appState.sceneManager,
                    animationLibrary: appState.animationLibrary,
                    camera: appState.camera
                )
            }
            .frame(minWidth: (horizontalSizeClass == .compact ? 180 : 220) * uiScale,
                   idealWidth: leftPanelWidth * uiScale,
                   maxWidth: (horizontalSizeClass == .compact ? 220 : 320) * uiScale)
            .clipped()

            Divider()

            ViewportView(
                assetManager: appState.assetManager,
                sceneManager: appState.sceneManager,
                toolManager: appState.toolManager,
                camera: appState.camera,
                skewGizmoState: appState.skewGizmoState,
                rotationGizmoState: appState.rotationGizmoState,
                editorMode: $appState.editorMode
            )
            .frame(minWidth: horizontalSizeClass == .compact ? 320 : 480)

            if isInspectorVisible {
                Divider()
                    .transition(.opacity)

                ScaledContainer(scale: uiScale) {
                    InspectorPanelView(
                        onToggleVisibility: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isInspectorVisible = false
                            }
                        }
                    )
                }
                .frame(minWidth: (horizontalSizeClass == .compact ? 180 : 220) * uiScale,
                       idealWidth: rightPanelWidth * uiScale,
                       maxWidth: (horizontalSizeClass == .compact ? 240 : 320) * uiScale)
                .clipped()
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minHeight: mainAreaMinHeight)
    }
}

// MARK: - Share sheet (iOS)

#if os(iOS)
import UIKit

private struct ShareSheetView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - Save Project Sheet

private struct SaveProjectSheet: View {
    @Binding var projectName: String
    @Binding var directoryURL: URL?

#if os(macOS)
    /// macOS runs an NSOpenPanel from the owner; iOS presents its own picker
    /// below, because only the view actually on screen can present one.
    let onChooseDirectory: () -> Void
#endif
    let onCancel: () -> Void
    let onSave: () -> Void

#if os(iOS)
    /// The folder picker's own presentation, owned by this sheet.
    @State private var isChoosingFolder = false
    @State private var folderError: String?
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save UltraMesh Project")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Project Name")
                    .font(.caption)
                    .foregroundStyle(UM.textSecondary)
                TextField("Project Name", text: $projectName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Folder")
                    .font(.caption)
                    .foregroundStyle(UM.textSecondary)
                HStack(spacing: 10) {
                    Text(directoryURL?.path(percentEncoded: false) ?? "No folder selected")
                        .font(.system(size: 12))
                        .foregroundStyle(directoryURL == nil ? UM.textSecondary : UM.textPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose Folder…") {
#if os(iOS)
                        // FROM INSIDE THE SHEET. The unified `.fileImporter`
                        // lives on the editor's root view, and on iOS a view
                        // that is already presenting a sheet cannot present a
                        // document picker as well — the request is dropped and
                        // nothing opens, which is exactly what "no abre nada"
                        // was. A picker has to be attached to the view that is
                        // actually on screen.
                        isChoosingFolder = true
#else
                        onChooseDirectory()
#endif
                    }
                }
                .padding(10)
                // The theme's own inset surface, not the platform's. A well
                // that follows the device's appearance sits inside a panel
                // that does not, so on an iPad in dark mode it was a black
                // box in the middle of the light editor.
                .background(UM.surfaceInset)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

#if os(iOS)
                if let folderError {
                    // Said here rather than swallowed: a picker that appears to
                    // work and a save that fails minutes later is the worst
                    // version of this.
                    Text(folderError)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UM.brandMagenta)
                        .fixedSize(horizontal: false, vertical: true)
                }
#endif
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
#if os(iOS)
                    guard directoryURL != nil else {
                        folderError = "Choose a folder before saving."
                        isChoosingFolder = true
                        return
                    }
#endif
                    onSave()
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(maxWidth: 520)
#if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .fileImporter(isPresented: $isChoosingFolder,
                      allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url):
                // A folder handed over by the document picker is
                // SECURITY-SCOPED, and the bookmark is what lets the save
                // reach it after this sheet is gone. Without one, the picker
                // works, the path shows, and writing fails later with a
                // permission error nobody can connect to this moment.
                directoryURL = url
                folderError = ProjectFolderAccess.remember(url) ? nil
                    : "That folder could not be opened for writing."
            case let .failure(error):
                let code = (error as NSError).code
                if code != NSUserCancelledError && code != CocoaError.userCancelled.rawValue {
                    folderError = error.localizedDescription
                }
            }
        }
#else
        .frame(minWidth: 520)
#endif
    }
}

// MARK: - Scaled container

private struct ScaledContainer<Content: View>: View {
    let scale: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        if scale >= 0.99 {
            content()
        } else {
            GeometryReader { geo in
                content()
                    .frame(width: geo.size.width / scale,
                           height: geo.size.height / scale)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: geo.size.width,
                           height: geo.size.height,
                           alignment: .topLeading)
            }
            .clipped()
        }
    }
}

// MARK: - Import source sheet (iOS)

#if os(iOS)
private struct ImportSourceSheet: View {
    let onPhotoLibrary: () -> Void
    let onFiles: () -> Void

    var body: some View {
        ZStack {
            UM.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                Text("Import Image")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.40))
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                VStack(spacing: 10) {
                    importRow(
                        title: "Photo Library",
                        subtitle: "Import from your photo library",
                        systemImage: "photo.on.rectangle.angled",
                        tint: Color(red: 0.30, green: 0.62, blue: 0.95),
                        action: onPhotoLibrary
                    )
                    importRow(
                        title: "Files",
                        subtitle: "Import a PNG from iCloud or Files",
                        systemImage: "folder.fill",
                        tint: Color(red: 0.25, green: 0.78, blue: 0.58),
                        action: onFiles
                    )
                }
                .padding(.horizontal, 16)

                Spacer(minLength: 16)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func importRow(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.opacity(0.18))
                        .frame(width: 46, height: 46)
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.42))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.20))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(UM.surfaceInset)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
#endif

// MARK: - Interface / panel settings

private struct InterfaceScaleSettingsView: View {
    @Binding var scale: Double
    @AppStorage("umCoordPanelScale") private var coordScale: Double = 1.2
    @AppStorage(UMAppearanceStorage.key) private var appearanceRaw = UMAppearance.light.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Interface Settings")
                .font(.headline)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(UM.textSecondary)
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(UMAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Night uses the same layout in greys and darks. Day is unchanged.")
                    .font(.system(size: 11))
                    .foregroundStyle(UM.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()

#if os(iOS)
            scaleSection(
                label: "Interface Size",
                value: $scale,
                in: 0.60...1.0,
                minLabel: "Compact", maxLabel: "Full Size",
                presets: [("S", 0.65), ("M", 0.80), ("L", 1.00)]
            )
            Divider()
#endif

            scaleSection(
                label: "Canvas Info Panel",
                value: $coordScale,
                in: 0.60...2.0,
                minLabel: "Small", maxLabel: "Large",
                presets: [("S", 0.80), ("M", 1.20), ("L", 1.60)]
            )
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func scaleSection(
        label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        minLabel: String,
        maxLabel: String,
        presets: [(String, Double)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.medium))
            Slider(value: value, in: range)
            HStack {
                Text(minLabel).font(.caption2).foregroundStyle(UM.textSecondary)
                Spacer()
                Text(maxLabel).font(.caption2).foregroundStyle(UM.textSecondary)
            }
            HStack(spacing: 12) {
                ForEach(presets, id: \.0) { item in
                    Button {
                        withAnimation(.spring(duration: 0.25)) { value.wrappedValue = item.1 }
                    } label: {
                        Text(item.0)
                            .font(.system(size: 14, weight: abs(value.wrappedValue - item.1) < 0.04 ? .bold : .regular))
                            .foregroundStyle(abs(value.wrappedValue - item.1) < 0.04 ? Color.primary : Color.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(abs(value.wrappedValue - item.1) < 0.04
                                          ? Color.white.opacity(0.12)
                                          : Color.white.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
