import AVFoundation
import CoreGraphics
import Foundation
import simd

/// Writes a Scene to an H.264 movie.
///
/// AVFoundation does the encoding; what is worth writing down is the handful of
/// things it will cheerfully get wrong on our behalf.
@MainActor
final class VideoExporter {

    struct Request {
        var composition: SceneComposition
        var destination: URL
        /// nil renders at the composition's own size.
        var pixelSize: SIMD2<Float>?
        /// Average bitrate. nil derives one from the frame area.
        var bitrate: Int?
    }

    private let renderer: SceneFrameRenderer
    /// The GPU renderer, when there is one. Nil falls back to the CPU
    /// compositor, exactly as the canvas does and for the same reason.
    private let metal: SceneMetalRenderer?
    private weak var scene: SceneManager?
    private weak var assets: AssetManager?

    init(renderer: SceneFrameRenderer,
         metal: SceneMetalRenderer?,
         scene: SceneManager,
         assets: AssetManager) {
        self.renderer = renderer
        self.metal = metal
        self.scene = scene
        self.assets = assets
    }

    /// H.264 encodes in macroblocks over 2x-subsampled chroma, so an odd
    /// dimension is rejected by some encoders and silently letterboxed by
    /// others. Rounded UP so nothing is cropped, and floored at 16 because a
    /// two-pixel movie is a file no player will open. Done once, here, rather
    /// than discovered in a player.
    static func encodableSize(_ size: SIMD2<Float>) -> (width: Int, height: Int) {
        var w = max(16, Int(size.x.rounded(.up)))
        var h = max(16, Int(size.y.rounded(.up)))
        if w % 2 != 0 { w += 1 }
        if h % 2 != 0 { h += 1 }
        return (w, h)
    }

    func export(
        _ request: Request,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws {
        guard let scene else { throw ExportError.rendererUnavailable }
        let composition = request.composition
        let frameCount = max(composition.durationInFrames, 1)
        let fps = max(composition.fps, 1)
        let (width, height) = Self.encodableSize(request.pixelSize ?? composition.renderSize)

        // A stale file at the destination makes AVAssetWriter fail to start
        // with an error that says nothing about the real cause.
        try? FileManager.default.removeItem(at: request.destination)

        let fileType: AVFileType = request.destination.pathExtension.lowercased() == "mp4"
            ? .mp4 : .mov
        let writer = try AVAssetWriter(outputURL: request.destination, fileType: fileType)

        let bitrate = request.bitrate ?? Self.defaultBitrate(width: width, height: height)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoMaxKeyFrameIntervalKey: fps * 2,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        guard writer.canAdd(input) else { throw ExportError.rendererUnavailable }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ExportError.rendererUnavailable
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            try Task.checkCancellation()

            // The SHOT, sampled at this frame — never the fly camera. Where the
            // artist was standing while placing a layer has nothing to do with
            // the delivered shot, and getting this backwards would silently
            // render the wrong film.
            let camera = scene.sceneCamera(for: composition, atFrame: frame)
            guard let pool = adaptor.pixelBufferPool else { continue }

            // THE SAME TEXTURE THE CANVAS PRESENTS, read back into the encoder's
            // own buffer. What the artist watched while composing IS the file,
            // not a second rasteriser's account of it.
            let buffer: CVPixelBuffer?
            if let metal, let assets {
                buffer = metalFrame(metal, composition: composition, atFrame: frame,
                                    through: camera, scene: scene, assets: assets,
                                    pool: pool, width: width, height: height)
            } else if let image = renderer.renderImage(
                composition: composition,
                atFrame: frame,
                through: camera,
                pixelSize: SIMD2<Float>(Float(width), Float(height))
            ) {
                buffer = Self.pixelBuffer(from: image, pool: pool,
                                          width: width, height: height)
            } else {
                buffer = nil
            }
            guard let buffer else { continue }

            // Built from the frame INDEX, not accumulated. Summing a Double
            // frame duration drifts — at 29.97 the error crosses a whole frame
            // inside a minute, and the symptom is a clip that runs short.
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            adaptor.append(buffer, withPresentationTime: time)

            if let progress {
                progress(Double(frame + 1) / Double(frameCount))
            }
        }

        input.markAsFinished()
        // The session ends one frame AFTER the last one, or the final frame has
        // zero duration and most players drop it.
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount),
                                               timescale: CMTimeScale(fps)))
        await writer.finishWriting()
        if writer.status == .failed {
            throw writer.error ?? ExportError.rendererUnavailable
        }
    }

    // MARK: - Bits

    /// ~0.1 bits per pixel per frame at 30 fps, clamped to a sane band. Enough
    /// for flat 2D art, which compresses far better than photography.
    private static func defaultBitrate(width: Int, height: Int) -> Int {
        let pixels = width * height
        return min(max(pixels * 3, 2_000_000), 40_000_000)
    }

    /// One frame, rendered on the GPU straight into a pooled pixel buffer.
    ///
    /// `CVPixelBufferGetBytesPerRow` AND NOT `width * 4`. A pooled buffer is
    /// padded to a stride of its own choosing, and writing rows at the wrong
    /// pitch shears the picture progressively down the frame — which looks like
    /// a broken codec and is a stride bug.
    ///
    /// No black fill first, unlike the CGImage path. The renderer's own
    /// background pass covers every pixel, and what it writes is
    /// premultiplied — so a transparent ground arrives as (0,0,0,0), which is
    /// the black H.264 would have been given anyway.
    private func metalFrame(
        _ metal: SceneMetalRenderer,
        composition: SceneComposition,
        atFrame frameIndex: Int,
        through camera: SceneCamera,
        scene: SceneManager,
        assets: AssetManager,
        pool: CVPixelBufferPool,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let pixelSize = SIMD2<Float>(Float(width), Float(height))
        let frame = SceneMetalRenderer.Frame(
            projection: SceneProjection(camera: camera, viewSize: pixelSize),
            lighting: SceneLighting(
                lights: scene.sceneLights(for: composition, atFrame: frameIndex),
                ambient: composition.ambient),
            pixelSize: SIMD2<Int>(width, height),
            // THE COMPOSITION'S OWN GROUND, never the editor's void grey. The
            // fly view's ground is chrome; this is the film.
            background: composition.background)

        guard metal.renderForReadback(
            composition: composition, atFrame: frameIndex, frame: frame,
            scene: scene, assets: assets, into: base,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)) else { return nil }
        return buffer
    }

    private static func pixelBuffer(
        from image: CGImage,
        pool: CVPixelBufferPool,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let info: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
                         | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info
        ) else { return nil }

        // H.264 has no alpha. Compositing onto black here means a transparent
        // background arrives as black rather than as whatever was left in the
        // pooled buffer from a previous frame.
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
