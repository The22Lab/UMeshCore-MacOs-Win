import Foundation

/// Top-level orchestrator for UltraMesh export. One instance is sufficient for
/// the lifetime of the app. Both methods are isolated to the main actor so they
/// can safely mutate `SceneManager` (which lives on the main actor).
@MainActor
final class ExportManager {

    /// Optional frame source for PNG export. Wire your Metal offscreen renderer
    /// here at app startup — without it, PNG export throws `.rendererUnavailable`.
    var pngFrameSource: PNGFrameSource?

    init(pngFrameSource: PNGFrameSource? = nil) {
        self.pngFrameSource = pngFrameSource
    }

    // MARK: - Skeleton Export (.umesh)

    /// Exports the current scene as a single `.umesh` file at `url`.
    /// Performs the work on a background `Task` so the UI stays responsive
    /// even on enormous projects.
    func exportSkeleton(
        scene: SceneManager,
        assets: AssetManager,
        to url: URL,
        options: BinaryExportOptions = BinaryExportOptions()
    ) async throws {
        // A project package and a Unity export share the .umesh extension by
        // design, so the destination has to be checked rather than trusted.
        // Writing a flat binary over a project package destroys it, and the
        // save panel's "replace?" prompt looks perfectly reasonable to whoever
        // is clicking it. Guarding here rather than at the call site means the
        // unified Export dialog and every future caller are covered too.
        if ProjectPersistence.isProjectPackage(url) {
            throw ProjectPersistence.ProjectFileError.wouldOverwriteProject(url)
        }

        // Serialization is fast (memcpy-bound) and the scene data lives on
        // the main actor; doing it here keeps everything ergonomic and
        // avoids Sendable gymnastics with @MainActor-isolated models.
        let exporter = BinaryExporter(options: options)
        try exporter.write(scene: scene, assets: assets, to: url)
    }

    /// In-memory variant — returns the blob for callers that want to send it
    /// to a service or compress it further.
    func exportSkeletonData(
        scene: SceneManager,
        assets: AssetManager,
        options: BinaryExportOptions = BinaryExportOptions()
    ) async throws -> Data {
        let exporter = BinaryExporter(options: options)
        return try exporter.export(scene: scene, assets: assets)
    }

    // MARK: - Scene Video Export

    /// Render a Scene to an H.264 movie.
    ///
    /// THROUGH THE SAME RENDERER THE CANVAS PRESENTS, and now through the same
    /// TEXTURE: the exporter reads back what the GPU drew rather than asking a
    /// second rasteriser for its own account of the same scene. The rig's canvas
    /// and its PNG exporter are two implementations that already disagree about
    /// a 3D-rotated sprite; a Scene does not repeat that, and sharing a result
    /// is a stronger guarantee than sharing source code.
    func exportSceneVideo(
        renderer: SceneFrameRenderer,
        metal: SceneMetalRenderer?,
        scene: SceneManager,
        assets: AssetManager,
        request: VideoExporter.Request,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws {
        let exporter = VideoExporter(renderer: renderer, metal: metal,
                                     scene: scene, assets: assets)
        try await exporter.export(request, progress: progress)
    }

    // MARK: - PNG Sequence Export

    /// Renders one animation clip to a sequence of PNG files. Throws
    /// `.rendererUnavailable` if `pngFrameSource` was not wired up at startup.
    func exportPNGSequence(
        scene: SceneManager,
        request: PNGExportRequest,
        assets: AssetManager? = nil,
        progressObserver: ExportProgressObserver? = nil
    ) async throws -> PNGExportResult {
        guard let frameSource = pngFrameSource else {
            throw ExportError.rendererUnavailable
        }
        // `assets` is only needed to measure content bounds for Crop; passing
        // nil simply leaves cropping inactive.
        let exporter = PNGSequenceExporter(frameSource: frameSource, assets: assets)
        exporter.progressObserver = progressObserver
        return try await exporter.export(scene: scene, request: request)
    }

    /// Batch variant: renders multiple animations to per-clip subdirectories
    /// under `parentDirectory`. Each clip's output goes to
    /// `parentDirectory/{clipName}/`.
    ///
    /// Uses a sequential outer loop (each animation's renderer is serial),
    /// but each animation internally fans out PNG encoding to a worker pool.
    func exportPNGSequencesBatch(
        scene: SceneManager,
        animations: [String],
        parentDirectory: URL,
        fps: Double,
        frameSpec: PNGFrameSpec,
        progressObserver: ExportProgressObserver? = nil
    ) async throws -> [String: PNGExportResult] {
        guard let frameSource = pngFrameSource else {
            throw ExportError.rendererUnavailable
        }

        var results: [String: PNGExportResult] = [:]
        let exporter = PNGSequenceExporter(frameSource: frameSource)
        exporter.progressObserver = progressObserver

        for clipName in animations {
            try Task.checkCancellation()
            let outDir = parentDirectory.appendingPathComponent(clipName, isDirectory: true)
            let request = PNGExportRequest(
                animationName: clipName,
                fps: fps,
                outputDirectory: outDir,
                filenamePrefix: clipName,
                frameSpec: frameSpec
            )
            results[clipName] = try await exporter.export(scene: scene, request: request)
        }
        return results
    }
}
