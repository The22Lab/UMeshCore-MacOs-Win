import Foundation
import simd

// MARK: - Public Export Types

enum ExportError: LocalizedError {
    case noScene
    case noAnimations
    case animationNotFound(name: String)
    case ioFailure(URL, underlying: Error)
    case rendererUnavailable
    case textureReadFailed
    case invalidFrameRange
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noScene:                            return "Scene is empty — nothing to export."
        case .noAnimations:                       return "Scene contains no animation clips."
        case .animationNotFound(let name):        return "Animation '\(name)' not found."
        case .ioFailure(let url, let err):        return "I/O failure at \(url.lastPathComponent): \(err.localizedDescription)"
        case .rendererUnavailable:                return "Metal renderer is unavailable for offscreen export."
        case .textureReadFailed:                  return "Failed to read offscreen texture bytes."
        case .invalidFrameRange:                  return "Invalid frame range."
        case .cancelled:                          return "Export was cancelled."
        }
    }
}

/// Embedded vs. referenced texture mode for .umesh files.
enum TextureEmbedMode {
    /// Skip texture bytes; only store paths + asset IDs. Smallest file, requires
    /// the original PNGs to live alongside the exported file at load time.
    case reference
    /// Embed the raw PNG bytes inside the .umesh chunk. Self-contained.
    case embed
}

struct BinaryExportOptions {
    var textureEmbedMode: TextureEmbedMode
    var includeBaseAnimations: Bool
    var prettyName: String?

    init(textureEmbedMode: TextureEmbedMode = .reference,
         includeBaseAnimations: Bool = true,
         prettyName: String? = nil) {
        self.textureEmbedMode = textureEmbedMode
        self.includeBaseAnimations = includeBaseAnimations
        self.prettyName = prettyName
    }
}

/// PNG output dimensions and color settings.
struct PNGFrameSpec {
    /// Output width in pixels.
    var width: Int
    /// Output height in pixels.
    var height: Int
    /// Clear color (RGBA, premultiplied). Default fully transparent.
    var clearColor: SIMD4<Float>
    /// Camera origin override; nil = use the current scene camera.
    var cameraOrigin: SIMD2<Float>?
    /// Camera zoom override; nil = use the current scene camera.
    var cameraZoom: Float?
    /// Bilinear sampling strength, 0…10 (the "Smoothing" control). 0 = nearest
    /// neighbour, which is what pixel-art rigs want; higher values interpolate.
    var smoothing: Int
    /// Draw the image attachments. Off renders an empty (or bones-only) frame.
    var renderImages: Bool

    init(width: Int,
         height: Int,
         clearColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0),
         cameraOrigin: SIMD2<Float>? = nil,
         cameraZoom: Float? = nil,
         smoothing: Int = 8,
         renderImages: Bool = true) {
        self.width = width
        self.height = height
        self.clearColor = clearColor
        self.cameraOrigin = cameraOrigin
        self.cameraZoom = cameraZoom
        self.smoothing = smoothing
        self.renderImages = renderImages
    }
}

/// How the output resolution is derived (the "Size" control).
enum PNGSizeMode: String, Codable, CaseIterable, Identifiable {
    /// Scale the viewport by a percentage.
    case scale
    /// Explicit pixel dimensions.
    case fixed

    var id: String { rawValue }
    var title: String { self == .scale ? "Scale" : "Size" }
}

struct PNGExportRequest {
    /// Animation clip name to render (case-sensitive). Empty = current frame only.
    var animationName: String?
    /// Frames per second to sample. Defaults to 30.
    var fps: Double
    /// Inclusive frame range. Nil = full duration of the animation.
    var frameRange: ClosedRange<Int>?
    /// Output directory; one PNG per frame is written here.
    var outputDirectory: URL
    /// Filename prefix. Files are named `{prefix}_{frameNumber:06d}.png`.
    var filenamePrefix: String
    /// Image resolution and camera.
    var frameSpec: PNGFrameSpec
    /// Max parallel encode workers. Defaults to ProcessInfo.activeProcessorCount.
    var maxConcurrentEncoders: Int?

    /// PNG compression quality hint, 0…9 (the dialog's "Compression"). Maps to the
    /// ImageIO destination's lossy-compression knob: higher = smaller files.
    var compression: Int
    /// Quantize to a 256-colour palette before writing (the dialog's "Reduce colors").
    /// Smaller files for flat-colour art; skipped for photographic content.
    var reduceColors: Bool
    /// Frames evaluated (and discarded) before the range is captured, so
    /// physics and other stateful systems settle first — a warm-up pass.
    var warmUpFrames: Int
    /// Render only the tight bounding box of visible content (the dialog's "Crop").
    var cropToContent: Bool
    /// Extra world-space margin kept around cropped content, so strokes and
    /// antialiased edges are not shaved off at the boundary.
    var cropPadding: Float

    init(animationName: String?,
         fps: Double = 30,
         frameRange: ClosedRange<Int>? = nil,
         outputDirectory: URL,
         filenamePrefix: String,
         frameSpec: PNGFrameSpec,
         maxConcurrentEncoders: Int? = nil,
         compression: Int = 6,
         reduceColors: Bool = false,
         warmUpFrames: Int = 0,
         cropToContent: Bool = false,
         cropPadding: Float = 2) {
        self.animationName = animationName
        self.fps = fps
        self.frameRange = frameRange
        self.outputDirectory = outputDirectory
        self.filenamePrefix = filenamePrefix
        self.frameSpec = frameSpec
        self.maxConcurrentEncoders = maxConcurrentEncoders
        self.compression = compression
        self.reduceColors = reduceColors
        self.warmUpFrames = warmUpFrames
        self.cropToContent = cropToContent
        self.cropPadding = cropPadding
    }
}

struct PNGExportResult {
    var filesWritten: [URL]
    var totalDurationSeconds: Double
    var framesPerSecondActual: Double {
        guard totalDurationSeconds > 0 else { return 0 }
        return Double(filesWritten.count) / totalDurationSeconds
    }
}

// MARK: - Frame Sink (offscreen renderer abstraction)

/// Abstracts the offscreen renderer behind a single method so the exporter
/// can be tested with a stub and so any future Metal renderer can plug in
/// without recompiling the exporter. The pipeline is:
///   1. `scene.setCurrentFrame(frame)` is called by the exporter
///   2. `renderFrame(spec:)` returns BGRA8 premultiplied pixel bytes
///   3. The encoder turns the bytes into PNG on a worker
protocol PNGFrameSource: AnyObject {
    /// Render the currently-applied scene state into a width*height*4 BGRA8
    /// buffer (premultiplied alpha). Implementations are expected to be
    /// thread-isolated; the exporter calls this serially on its own actor.
    func renderFrame(spec: PNGFrameSpec) async throws -> Data
}

// MARK: - Progress

struct ExportProgress: Sendable {
    var completedFrames: Int
    var totalFrames: Int
    var fractionComplete: Double {
        totalFrames > 0 ? Double(completedFrames) / Double(totalFrames) : 0
    }
}

protocol ExportProgressObserver: AnyObject {
    func exportProgressDidChange(_ progress: ExportProgress)
}
