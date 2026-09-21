import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Renders an animation clip frame-by-frame and writes each frame as a PNG.
///
/// Pipeline:
///   1. Main actor: scrub `SceneManager.setCurrentFrame(frame)`.
///   2. Main actor: ask `PNGFrameSource.renderFrame(spec:)` for BGRA8 bytes
///      (must run on the renderer's queue — usually the main actor for Metal).
///   3. Background TaskGroup: PNG-encode the bytes and write to disk in parallel.
///
/// The renderer is serialized (Metal can't safely render to the same texture
/// from multiple threads). PNG encoding scales out to ProcessInfo cores via
/// the worker pool, which is where the speedup over a naive loop lives.
@MainActor
final class PNGSequenceExporter {

    weak var progressObserver: ExportProgressObserver?
    private let frameSource: PNGFrameSource
    /// Needed only to measure content bounds for Crop; nil disables cropping.
    private weak var assets: AssetManager?

    init(frameSource: PNGFrameSource, assets: AssetManager? = nil) {
        self.frameSource = frameSource
        self.assets = assets
    }

    // MARK: - Public API

    func export(scene: SceneManager,
                request: PNGExportRequest) async throws -> PNGExportResult {

        try Self.prepareOutputDirectory(request.outputDirectory)

        // Resolve frame range
        let (startFrame, endFrame) = try resolveFrameRange(scene: scene, request: request)
        guard startFrame <= endFrame else { throw ExportError.invalidFrameRange }
        let totalFrames = endFrame - startFrame + 1

        // Capture the artist's playhead BEFORE anything scrubs the scene. The
        // crop pass below scrubs the whole range, so hoisting this above it is
        // what guarantees the timeline is put back where the user left it.
        let savedFrame = scene.currentFrame
        defer { scene.setCurrentFrame(savedFrame) }   // restore after

        // Crop: measure the content across the whole range and reframe once.
        // Every PNG in a sequence must share dimensions, so the bounds are
        // unioned over all frames rather than cropped per frame.
        var request = request
        if request.cropToContent {
            if let framing = measureCropFraming(scene: scene, request: request,
                                                startFrame: startFrame, endFrame: endFrame) {
                request.frameSpec.width = framing.width
                request.frameSpec.height = framing.height
                request.frameSpec.cameraOrigin = framing.cameraOrigin
            }
            // No measurable content (empty scene) leaves the spec untouched,
            // so the export still produces valid, if empty, frames.
        }

        // Warm up: evaluate (and discard) frames leading into the range so
        // stateful systems — physics above all — have settled before the first
        // captured frame. Without this a spring rig exports its startup twitch.
        if request.warmUpFrames > 0 {
            for offset in stride(from: request.warmUpFrames, through: 1, by: -1) {
                try Task.checkCancellation()
                scene.setCurrentFrame(max(0, startFrame - offset))
                _ = try await frameSource.renderFrame(spec: request.frameSpec)
            }
        }

        let workerLimit = max(1, request.maxConcurrentEncoders
                              ?? max(2, ProcessInfo.processInfo.activeProcessorCount))
        let startedAt = Date()

        var completed = 0
        var written: [URL] = []
        written.reserveCapacity(totalFrames)

        // Producer (serial render) → consumer pool (parallel encode).
        // We bound in-flight encode tasks at `workerLimit` so memory stays flat
        // even on very long animations.
        try await withThrowingTaskGroup(of: URL.self) { group in
            var inFlight = 0
            var frame = startFrame

            while frame <= endFrame {
                try Task.checkCancellation()

                // Render serially on the main actor (Metal-safe)
                scene.setCurrentFrame(frame)
                let pixelData = try await frameSource.renderFrame(spec: request.frameSpec)
                let outputURL = Self.outputURL(prefix: request.filenamePrefix,
                                               frame: frame,
                                               directory: request.outputDirectory)
                let spec = request.frameSpec
                let compression = request.compression
                let reduceColors = request.reduceColors

                // Encode + write in parallel
                group.addTask(priority: .userInitiated) {
                    try await Self.encodeAndWritePNG(pixelData: pixelData,
                                                    width: spec.width,
                                                    height: spec.height,
                                                    to: outputURL,
                                                    compression: compression,
                                                    reduceColors: reduceColors)
                }
                inFlight += 1
                frame += 1

                if inFlight >= workerLimit {
                    if let url = try await group.next() {
                        written.append(url)
                        completed += 1
                        inFlight -= 1
                        notifyProgress(completed: completed, total: totalFrames)
                    }
                }
            }

            // Drain remaining encode workers
            for try await url in group {
                written.append(url)
                completed += 1
                notifyProgress(completed: completed, total: totalFrames)
            }
        }

        let duration = Date().timeIntervalSince(startedAt)
        return PNGExportResult(filesWritten: written, totalDurationSeconds: duration)
    }

    // MARK: - Helpers

    /// Scrubs the range measuring content bounds, then converts the union into a
    /// single framing shared by every exported frame.
    ///
    /// Scrubbing is required rather than measuring one frame: an animation moves
    /// the art, so a box measured at frame 0 would clip later frames. The scene's
    /// current frame is restored by the caller's `defer`.
    private func measureCropFraming(scene: SceneManager,
                                    request: PNGExportRequest,
                                    startFrame: Int,
                                    endFrame: Int) -> CropFraming? {
        guard let assets else { return nil }

        var union = ContentBounds.empty
        for frame in startFrame...endFrame {
            scene.setCurrentFrame(frame)
            union.formUnion(ContentBounds.measure(scene: scene, assets: assets))
        }
        guard !union.isEmpty else { return nil }

        let padded = union.inset(by: max(0, request.cropPadding))
        let zoom = request.frameSpec.cameraZoom ?? 1.0
        return CropFraming.from(bounds: padded, zoom: zoom)
    }

    private static func prepareOutputDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw ExportError.ioFailure(url, underlying: error)
            }
        }
    }

    private static func outputURL(prefix: String, frame: Int, directory: URL) -> URL {
        let name = String(format: "%@_%06d.png", prefix, frame)
        return directory.appendingPathComponent(name)
    }

    private func notifyProgress(completed: Int, total: Int) {
        progressObserver?.exportProgressDidChange(
            ExportProgress(completedFrames: completed, totalFrames: total)
        )
    }

    private func resolveFrameRange(scene: SceneManager,
                                   request: PNGExportRequest) throws -> (Int, Int) {
        if let explicit = request.frameRange {
            return (explicit.lowerBound, explicit.upperBound)
        }
        // Compute from named animation clip or scene playback bounds
        let duration = scene.skeleton.orderedBones
            .map { $0.animationClip.durationInFrames }
            .max() ?? 0
        let imagesDuration = scene.images
            .map { $0.animationClip.durationInFrames }
            .max() ?? 0
        let effective = max(duration, imagesDuration, scene.playbackEndFrame)
        guard effective > 0 else { throw ExportError.invalidFrameRange }
        return (max(0, scene.playbackStartFrame), effective)
    }

    // MARK: - PNG Encoding (concurrent-safe, runs on worker threads)

    /// Encodes a BGRA8 premultiplied byte buffer into a PNG file.
    /// Pure function — safe to call from any context.
    nonisolated static func encodeAndWritePNG(pixelData: Data,
                                              width: Int,
                                              height: Int,
                                              to url: URL,
                                              compression: Int = 6,
                                              reduceColors: Bool = false) async throws -> URL {
        return try await Task.detached(priority: .userInitiated) {
            try encodePNGSync(pixelData: pixelData, width: width, height: height,
                              to: url, compression: compression, reduceColors: reduceColors)
        }.value
    }

    /// Synchronous core of the PNG encoder. Called from a worker.
    nonisolated static func encodePNGSync(pixelData: Data,
                                          width: Int,
                                          height: Int,
                                          to url: URL,
                                          compression: Int = 6,
                                          reduceColors: Bool = false) throws -> URL {
        let bytesPerRow = width * 4
        guard pixelData.count >= bytesPerRow * height else {
            throw ExportError.textureReadFailed
        }
        var pixelData = pixelData
        if reduceColors {
            // Uniform 4-bits-per-channel quantization (4096-colour cube). Flat,
            // cel-shaded art loses nothing visible while PNG's filters compress
            // the reduced palette markedly better. Alpha is left untouched so
            // edge antialiasing survives.
            pixelData.withUnsafeMutableBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                let count = min(raw.count, bytesPerRow * height)
                var i = 0
                while i < count {
                    // BGRA byte order — quantize B, G, R and leave A at i+3.
                    let alpha = base[i + 3]
                    // The buffer is PREMULTIPLIED: a channel may never exceed
                    // alpha. Quantization rounds up, so clamp afterwards or
                    // semi-transparent edges develop bright halos.
                    base[i]     = Swift.min(base[i]     & 0xF0 | (base[i]     >> 4), alpha)
                    base[i + 1] = Swift.min(base[i + 1] & 0xF0 | (base[i + 1] >> 4), alpha)
                    base[i + 2] = Swift.min(base[i + 2] & 0xF0 | (base[i + 2] >> 4), alpha)
                    i += 4
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // BGRA8 with premultiplied first alpha is the Metal default — direct match.
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        let provider = pixelData.withUnsafeBytes { raw -> CGDataProvider in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: raw.count)
            buffer.initialize(from: raw.bindMemory(to: UInt8.self).baseAddress!,
                              count: raw.count)
            return CGDataProvider(
                dataInfo: buffer,
                data: buffer,
                size: raw.count,
                releaseData: { info, _, _ in
                    if let info { info.assumingMemoryBound(to: UInt8.self).deallocate() }
                }
            )!
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw ExportError.textureReadFailed
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ExportError.ioFailure(url, underlying: NSError(domain: "PNG", code: -1))
        }
        // The compression slider is 0…9; ImageIO takes 0…1 where *higher*
        // means more aggressive lossy compression, so the scale is mapped
        // directly. PNG stays lossless — this steers filter/effort selection.
        let clampedCompression = max(0, min(9, compression))
        let properties: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality: Double(clampedCompression) / 9.0
        ] as CFDictionary
        CGImageDestinationAddImage(dest, cgImage, properties)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.ioFailure(url, underlying: NSError(domain: "PNG", code: -2))
        }
        return url
    }
}
