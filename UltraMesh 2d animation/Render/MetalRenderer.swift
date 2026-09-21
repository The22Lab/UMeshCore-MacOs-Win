import Foundation
import MetalKit
import QuartzCore
import simd
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class MetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let checkerPipelineState: MTLRenderPipelineState
    private let texturePipelineState: MTLRenderPipelineState
    /// The alpha-contour rim. Same vertices as the sprite, different fragment
    /// shader — which is the whole reason the rim follows deformation, bones
    /// and 3D rotation without a line of geometry code.
    private let outlinePipelineState: MTLRenderPipelineState
    private let textureInstancedPipelineState: MTLRenderPipelineState
    private let gizmoPipelineState: MTLRenderPipelineState

    /// One pipeline per blend mode, indexed by `ImageBlendMode.pipelineIndex`.
    /// Blending is fixed at pipeline creation in Metal, so a mode change means
    /// a different pipeline — the reason blend modes break batching here just
    /// as they do in the Unity runtime.
    private let texturePipelineStatesByBlend: [MTLRenderPipelineState]
    private let textureInstancedPipelineStatesByBlend: [MTLRenderPipelineState]
    private let quadVertexBuffer: MTLBuffer
    private lazy var gizmoRenderer = GizmoRenderer(worldToNDC: worldToNDC)
    private lazy var viewportRenderer = ViewportRenderer(worldToNDC: worldToNDC)
    private var textTextureCache: [String: MTLTexture] = [:]
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private let skewPerspectiveM34: Float = -1.0 / 500.0
    private let skewYawDegrees: Float = 30.0
    private let skewRollDegrees: Float = 10.0
    private let skewCameraZ: Float = 400.0

    weak var assetManager: AssetManager?
    weak var sceneManager: SceneManager?
    weak var toolManager: ToolManager?
    weak var camera: CameraState?
    /// Decides, at the end of each frame, whether there is any reason to draw
    /// another one. Held strongly: it is owned by the view's coordinator, which
    /// outlives this renderer, and a nil here would silently pin the canvas at
    /// 120Hz forever.
    var activity: CanvasActivity?

    /// Fill, outline and ring for a bind-mode state, from one pastel.
    ///
    /// The contour is derived rather than written out, so adding a state means
    /// choosing one colour and its readability is settled.
    private static func bindStateColours(
        _ colour: SIMD3<Float>, fillAlpha: Float
    ) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        let ink = UM.contourInk(for: colour)
        return (
            SIMD4<Float>(colour.x, colour.y, colour.z, fillAlpha),
            SIMD4<Float>(ink.x, ink.y, ink.z, 0.96),
            SIMD4<Float>(ink.x, ink.y, ink.z, 0.92)
        )
    }

    /// Must stay laid out exactly like `CheckerUniforms` in
    /// CheckerboardShaders.metal. The dead `vignetteStrength` is gone, and so
    /// is the `contentScale` that briefly replaced it: camera zoom is already
    /// in drawable pixels everywhere in this renderer.
    private struct CheckerUniforms {
        var viewportSize: SIMD2<Float>
        var checkerSize: SIMD2<Float>
        var darkColor: SIMD3<Float>
        var lightColor: SIMD3<Float>
        var zoom: Float
        var cameraPosition: SIMD2<Float>
    }

    /// Must stay laid out exactly like `VertexIn` in TextureShaders.metal.
    /// Opacity lives in `tint.w` rather than a separate float: one SIMD4 keeps
    /// both sides 16-byte aligned with no padding to get wrong.
    private struct TexturedVertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
        var tint: SIMD4<Float>
    }

    private struct QuadVertex {
        var local: SIMD2<Float>
        var uv: SIMD2<Float>
    }

    /// Must stay laid out exactly like `SpriteInstance` in TextureShaders.metal.
    private struct SpriteInstance {
        var positionScale: SIMD4<Float>
        var halfSizeSkew: SIMD4<Float>
        var rotationAndPad: SIMD4<Float>
        var uvRect: SIMD4<Float>
        var tint: SIMD4<Float>
    }

    private struct SpriteSceneUniforms {
        var viewportAndZoom: SIMD4<Float>
        var cameraOrigin: SIMD4<Float>
    }

    /// One draw call's worth of sprites, IN DRAW ORDER.
    ///
    /// This used to be two arrays of ranges — one for the instanced quads, one
    /// for the mesh triangles — each filled from a bucket keyed by
    /// `(atlasPage, blendMode)` and emitted page-major. That threw the draw
    /// order away twice over: a sprite on atlas page 1 composited after every
    /// sprite on page 0, and every quad composited before every mesh. Order
    /// survived only WITHIN a bucket, which is why a small rig on one page
    /// looked right and the newest layers of a growing one did not — they are
    /// the ones on the newest page, and the ones most likely to be meshed.
    ///
    /// Alpha compositing is order-dependent, so a batch may only merge draws
    /// that are ALREADY ADJACENT in the draw order. A run is exactly that: a
    /// maximal stretch of consecutive sprites sharing the state a draw call
    /// binds. A rig on one page with one blend mode still collapses to a
    /// single call; one that does not, draws correctly.
    ///
    /// See `Editor/verify_editor_draw_order.py`. Editor viewport only — the
    /// export path and the no-atlas fallback both walk the draw order and draw
    /// as they go, and never had this.
    private struct DrawRun {
        enum Kind { case instanced, mesh }
        var kind: Kind
        var pageIndex: Int
        var blendIndex: Int
        /// Instance index for `.instanced`, vertex index for `.mesh`.
        var start: Int
        /// Instance count for `.instanced`, vertex count for `.mesh`.
        var count: Int
    }

    /// The skeleton pose for the frame currently being drawn, solved once in
    /// `draw` and shared by every pass. Nil outside a draw.
    private var framePose: [UUID: simd_float4x4]?

    /// EVERY BUFFER WRITTEN PER FRAME IS A RING, for the same one reason: a
    /// buffer may only be rewritten once the GPU has finished reading it, and
    /// with two frames in flight the frame after next is still reading this
    /// one. These two were single buffers while the instance buffer beside them
    /// was already a ring of two — so under load the sprite batch was rewritten
    /// out from under a draw that had been encoded but not executed, which
    /// reads as a frame-late triangle and is a data race. It is the fault
    /// `SceneMetalRenderer` names in its own header as the thing not to repeat.
    private var spriteBatchBuffers: [MTLBuffer?] =
        Array(repeating: nil, count: MetalRenderer.maxFramesInFlight)
    private var spriteBatchBufferLength: Int = 0
    /// The rim gets its own ring. Writing the sprite batch buffer again after
    /// the sprite draws are encoded would corrupt them WITHIN one frame: the
    /// encoder has recorded the draw calls, but the GPU has not read the
    /// vertices yet. That is a separate problem from the ring, and both are
    /// real — one is about two passes in a frame, the other about two frames.
    private var outlineVertexBuffers: [MTLBuffer?] =
        Array(repeating: nil, count: MetalRenderer.maxFramesInFlight)
    private var outlineVertexBufferLength: Int = 0
    /// Reconstructs when each frame will be presented, so the animation is
    /// sampled on the display's grid rather than at whatever moment the main
    /// thread happened to wake. See `DisplayClock`.
    let displayClock = DisplayClock()

    /// How many frames the CPU may have in flight, and therefore how many
    /// sprite instance buffers there are. One number, because they are the
    /// same constraint: a buffer may be rewritten only once the GPU has
    /// finished reading it.
    ///
    /// TWO, and deliberately fewer than the swap chain is deep.
    ///
    /// Not because three would cost latency — it would not. `draw(in:)` is
    /// called by the display link, so the CPU is paced by the display and has
    /// no way to run ahead of it; the semaphore engages only when frames are
    /// already late. This is the guard that stops a sprite instance buffer
    /// being rewritten while the GPU is reading it, and two is what the old
    /// two-deep drawable pool allowed implicitly, so raising the pool to three
    /// changes nothing about how far ahead the CPU may be. See the note on
    /// `maximumDrawableCount` in ViewportView.
    /// How much of the artwork is left showing while bones are being bound.
    ///
    /// Low enough that a bone reads over any sprite, high enough that the rig
    /// is still recognisable — an artist binding a forearm needs to see WHICH
    /// forearm. Measured against the mesh edit's 0.34, which dims one sprite
    /// rather than all of them and so can afford to leave more.
    static let bindModeArtworkDim: Float = 0.16

    static let maxFramesInFlight = 2
    private let inFlightSemaphore = DispatchSemaphore(value: MetalRenderer.maxFramesInFlight)
    private var spriteInstanceBuffers: [MTLBuffer?] =
        Array(repeating: nil, count: MetalRenderer.maxFramesInFlight)
    private var spriteInstanceBufferLength: Int = 0
    /// ONE INDEX FOR EVERY RING. They are written once each per encoded
    /// frame and so advance together; a second counter is a second thing to
    /// keep in step, and the slot they disagreed about would be whichever
    /// was added last.
    private var ringIndex: Int = 0

    init(view: MTKView) {
        guard let device = view.device else {
            fatalError("Metal device unavailable")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Failed to create command queue")
        }
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Failed to create default Metal library")
        }
        guard let checkerVertex = library.makeFunction(name: "checkerVertex"),
              let checkerFragment = library.makeFunction(name: "checkerFragment") else {
            fatalError("Missing checkerboard shader functions")
        }
        guard let textureVertex = library.makeFunction(name: "textureVertex"),
              let textureInstancedVertex = library.makeFunction(name: "textureInstancedVertex"),
              let textureFragment = library.makeFunction(name: "textureFragment") else {
            fatalError("Missing texture shader functions")
        }
        guard let alphaOutlineFragment = library.makeFunction(name: "alphaOutlineFragment") else {
            fatalError("Missing alpha outline shader function")
        }
        guard let gizmoVertex = library.makeFunction(name: "gizmoVertex"),
              let gizmoFragment = library.makeFunction(name: "gizmoFragment") else {
            fatalError("Missing gizmo shader functions")
        }

        let checkerDescriptor = MTLRenderPipelineDescriptor()
        checkerDescriptor.label = "Checkerboard Pipeline"
        checkerDescriptor.vertexFunction = checkerVertex
        checkerDescriptor.fragmentFunction = checkerFragment
        checkerDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

        // The texture fragment shader emits PREMULTIPLIED colour, so "normal"
        // is (one, oneMinusSourceAlpha) rather than (sourceAlpha, …). The two
        // are algebraically identical for normal blending, and premultiplying
        // is what keeps additive and screen from over-brightening at partial
        // alpha — the same convention the Unity runtime's shader uses.
        func textureDescriptor(_ label: String,
                               _ vertexFunction: MTLFunction,
                               _ blend: ImageBlendMode) -> MTLRenderPipelineDescriptor {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "\(label) (\(blend.rawValue))"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = textureFragment
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            switch blend {
            case .normal:
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            case .additive:
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
            case .multiply:
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .destinationColor
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .zero
            case .screen:
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceColor
            }
            // Alpha accumulates the same way in every mode so the drawable's
            // coverage stays correct over the checkerboard.
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return descriptor
        }

        let textureDescriptors = ImageBlendMode.pipelineOrder.map {
            textureDescriptor("Texture Pipeline", textureVertex, $0)
        }
        let textureInstancedDescriptors = ImageBlendMode.pipelineOrder.map {
            textureDescriptor("Texture Instanced Pipeline", textureInstancedVertex, $0)
        }

        // Straight alpha over whatever is already there, like the gizmos —
        // the rim sits on top of the art rather than tinting it.
        let outlineDescriptor = MTLRenderPipelineDescriptor()
        outlineDescriptor.label = "Selection Outline Pipeline"
        outlineDescriptor.vertexFunction = textureVertex
        outlineDescriptor.fragmentFunction = alphaOutlineFragment
        outlineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        outlineDescriptor.colorAttachments[0].isBlendingEnabled = true
        outlineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        outlineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        outlineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        outlineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        outlineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        outlineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let gizmoDescriptor = MTLRenderPipelineDescriptor()
        gizmoDescriptor.label = "Gizmo Pipeline"
        gizmoDescriptor.vertexFunction = gizmoVertex
        gizmoDescriptor.fragmentFunction = gizmoFragment
        gizmoDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        gizmoDescriptor.colorAttachments[0].isBlendingEnabled = true
        gizmoDescriptor.colorAttachments[0].rgbBlendOperation = .add
        gizmoDescriptor.colorAttachments[0].alphaBlendOperation = .add
        gizmoDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        gizmoDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        gizmoDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        gizmoDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            checkerPipelineState = try device.makeRenderPipelineState(descriptor: checkerDescriptor)
            let textureStates = try textureDescriptors.map {
                try device.makeRenderPipelineState(descriptor: $0)
            }
            let textureInstancedStates = try textureInstancedDescriptors.map {
                try device.makeRenderPipelineState(descriptor: $0)
            }
            texturePipelineStatesByBlend = textureStates
            textureInstancedPipelineStatesByBlend = textureInstancedStates
            // The unqualified properties stay the plain-blending variants, which
            // is what gizmo badges and the no-atlas fallback path want.
            texturePipelineState = textureStates[ImageBlendMode.normal.pipelineIndex]
            textureInstancedPipelineState = textureInstancedStates[ImageBlendMode.normal.pipelineIndex]
            outlinePipelineState = try device.makeRenderPipelineState(descriptor: outlineDescriptor)
            gizmoPipelineState = try device.makeRenderPipelineState(descriptor: gizmoDescriptor)
        } catch {
            fatalError("Failed to create pipeline state: \(error)")
        }

        let quadVertices: [QuadVertex] = [
            QuadVertex(local: SIMD2<Float>(-1, 1), uv: SIMD2<Float>(0, 0)),
            QuadVertex(local: SIMD2<Float>(1, 1), uv: SIMD2<Float>(1, 0)),
            QuadVertex(local: SIMD2<Float>(-1, -1), uv: SIMD2<Float>(0, 1)),
            QuadVertex(local: SIMD2<Float>(1, -1), uv: SIMD2<Float>(1, 1))
        ]
        guard let quadVertexBuffer = device.makeBuffer(
            bytes: quadVertices,
            length: MemoryLayout<QuadVertex>.stride * quadVertices.count,
            options: .storageModeShared
        ) else {
            fatalError("Failed to create quad vertex buffer")
        }
        self.quadVertexBuffer = quadVertexBuffer

        self.device = device
        self.commandQueue = commandQueue
        super.init()
    }

    /// DOOR 5, and the one that is easy to miss because it comes from the VIEW
    /// rather than from the model or from input: a window resized, a split view
    /// dragged, an iPad rotated, the window moved to a display with a different
    /// scale. None of those publish anything, and a sleeping canvas would keep
    /// showing the old drawable stretched to the new size until something else
    /// happened to wake it.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        activity?.wake()
    }

    func draw(in view: MTKView) {
        let stats = FrameStatistics.shared
        stats.beginFrame(animationTime: sceneManager?.animationTime ?? 0)

        // The only place the canvas is ever put to sleep, and deliberately the
        // LAST thing in the frame: whatever it is about to stop drawing has, by
        // then, been drawn and presented at least once.
        //
        // `defer` rather than a call at the end, because the frame now has an
        // early exit — a drawable that never arrived. Two call sites would be
        // two things to keep in step, and forgetting one leaves a canvas
        // drawing forever because it was never asked to settle.
        defer { activity?.settleAfterFrame() }

        // ── CPU WORK FIRST, DRAWABLE LAST ────────────────────────────────
        //
        // `view.currentDrawable` BLOCKS the calling thread when every drawable
        // is still in use, and this method used to ask for it as its very
        // first act — before the clip was sampled, before the skeleton was
        // solved, before a single vertex was built. Two things followed:
        //
        //  1. the block landed at the START of the frame, so any hesitation in
        //     the compositor became a hesitation in the animation rather than
        //     something the CPU could work through; and
        //  2. the drawable was then HELD for the whole CPU frame, from here to
        //     `present`. A drawable held longer is a drawable not available to
        //     the next frame, which is how a renderer ends up alternating
        //     16.7 / 33.3 ms while its average still reads 60 fps.
        //
        // The order below is the one Metal is designed around: do everything
        // that does not need a drawable, take the drawable at the last
        // possible moment, encode, present.
        // WHEN this frame will be seen, not when the CPU got round to it.
        // Every clock in the frame — the playhead, the physics accumulator —
        // is told the same instant, so animation time and simulation time
        // cannot drift apart from each other or from the display.
        displayClock.setRefreshRate(view.preferredFramesPerSecond)
        let presentationTime = displayClock.presentationTime(cpuTime: CACurrentMediaTime())

        stats.begin(.animation)
        sceneManager?.beginFramePose(presentationTime: presentationTime)
        sceneManager?.tickPlayback(presentationTime: presentationTime)

        if let sceneManager, let assetManager, let toolManager {
            toolManager.update(scene: sceneManager, assets: assetManager)
        }
        stats.end(.animation)

        // Solve the skeleton ONCE for the whole frame. Every consumer below used
        // to reach for `worldMatrices()` (or `lineSegment`/`worldRotation`,
        // which each solve the entire skeleton to answer about one bone), so a
        // single frame ran the full constraint stack — IK, FABRIK, paths,
        // physics, cascades — about five times over.
        stats.begin(.solve)
        framePose = sceneManager?.frameWorldMatrices()
        stats.end(.solve)

        updateCamera(drawableSize: view.drawableSize)

        // Bound how far the CPU may run ahead of the GPU.
        //
        // The sprite instance buffer is triple-buffered, but nothing stopped
        // the CPU from lapping the GPU and overwriting a buffer still being
        // read — it worked only because `currentDrawable` happened to block
        // first, which is no longer true now that the drawable is taken last.
        // An explicit count is both the correctness fix and the pacing one: a
        // CPU allowed to sprint ahead and then stall produces exactly the
        // uneven intervals this whole change is about.
        //
        // Timed together with the drawable, because they are one question —
        // how long this frame had to wait before it was allowed to draw. With
        // the wait outside the measurement the report would show a drawable
        // that is always instantly available, which is true and useless.
        stats.begin(.drawable)
        inFlightSemaphore.wait()

        let acquiredDrawable = view.currentDrawable
        let acquiredDescriptor = view.currentRenderPassDescriptor
        stats.end(.drawable)

        guard let drawable = acquiredDrawable,
              let renderPassDescriptor = acquiredDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            // Every path past `wait()` has to signal, or the renderer
            // deadlocks after three dropped frames.
            inFlightSemaphore.signal()
            framePose = nil
            return
        }

        // Advanced HERE, not at the top: a frame that never encodes must not
        // consume a slot, or the ring drifts out of step with what is actually
        // in flight.
        ringIndex = (ringIndex + 1) % MetalRenderer.maxFramesInFlight

        stats.begin(.encode)

        let cameraPosition = camera?.origin ?? .zero
        let cameraZoom = camera?.zoom ?? 1.0
        let checkers = Self.checkerColours(for: view)

        let uniforms = CheckerUniforms(
            viewportSize: SIMD2(
                Float(view.drawableSize.width),
                Float(view.drawableSize.height)
            ),
            // World units now, not pixels: the board is part of the canvas.
            // 18 keeps the square exactly the size it drew at before, at zoom 1.
            checkerSize: SIMD2(18, 18),
            darkColor: checkers.dark,
            lightColor: checkers.light,
            zoom: Float(cameraZoom),
            cameraPosition: SIMD2<Float>(Float(cameraPosition.x), Float(cameraPosition.y))
        )

        encoder.setRenderPipelineState(checkerPipelineState)
        encoder.setFragmentBytes(
            [uniforms],
            length: MemoryLayout<CheckerUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        drawViewportGuides(encoder: encoder, drawableSize: view.drawableSize)
        drawSceneImages(encoder: encoder, drawableSize: view.drawableSize)
        drawBonesOverlay(encoder: encoder, drawableSize: view.drawableSize)
        drawMeshOverlay(encoder: encoder, drawableSize: view.drawableSize)
        drawGizmos(encoder: encoder, drawableSize: view.drawableSize, commandBuffer: commandBuffer)
        drawSelectionRect(encoder: encoder, drawableSize: view.drawableSize)
        drawAngleBadge(encoder: encoder, drawableSize: view.drawableSize)

        // Dropped rather than kept: holding it would pin a dictionary of every
        // bone matrix between frames for no benefit, and risk a stale pose being
        // read by anything that runs outside draw().
        framePose = nil

        encoder.endEncoding()
        stats.end(.encode)

        let slot = stats.endFrame()
        // The semaphore is captured directly, not through `self`: a renderer
        // that went away before its last frame completed would otherwise never
        // signal, and the count would leak.
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { buffer in
            FrameStatistics.shared.recordGPUTime(
                buffer.gpuEndTime - buffer.gpuStartTime, forSlot: slot)
            semaphore.signal()
        }
        // What the DISPLAY did, not what the app did. Everything else measured
        // here is a timestamp the app took; this one comes back from the
        // compositor once the drawable is genuinely on screen.
        if stats.isEnabled {
            drawable.addPresentedHandler { presented in
                FrameStatistics.shared.recordPresented(
                    at: presented.presentedTime, forSlot: slot)
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// The checkerboard for the appearance this view is drawing in.
    ///
    /// The palette's `Color`s resolve themselves — a dynamic platform colour is
    /// asked for its value at draw time, against the appearance of the view
    /// asking. These cannot: they are `SIMD3<Float>` on their way to a shader.
    /// So the renderer asks the view directly, which is the same question by a
    /// different route and needs no global and no notification.
    private static func checkerColours(for view: MTKView)
        -> (light: SIMD3<Float>, dark: SIMD3<Float>) {
#if os(macOS)
        let isDark = view.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
#else
        let isDark = view.traitCollection.userInterfaceStyle == .dark
#endif
        return isDark
            ? (UM.checkerLightNight, UM.checkerDarkNight)
            : (UM.checkerLight, UM.checkerDark)
    }

    private func drawSceneImages(encoder: MTLRenderCommandEncoder, drawableSize: CGSize) {
        guard let assetManager,
              let sceneManager else {
            return
        }
        guard !assetManager.atlasPages.isEmpty else {
            drawSceneImagesFallback(encoder: encoder, drawableSize: drawableSize)
            return
        }
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else { return }

        let pageCount = assetManager.atlasPageCount
        guard pageCount > 0 else { return }

        // Atlas page and blend mode each force a state change, so each has to
        // split a draw call — but splitting is all they may do. They must not
        // decide the ORDER, which is what bucketing by them did.
        let estimatedImageCount = max(sceneManager.images.count, 1)
        let estimatedVertexCount = max(estimatedImageCount * 6, 6)
        var combinedInstances: [SpriteInstance] = []
        combinedInstances.reserveCapacity(estimatedImageCount)
        var combinedVertices: [TexturedVertex] = []
        combinedVertices.reserveCapacity(estimatedVertexCount)
        var drawRuns: [DrawRun] = []
        drawRuns.reserveCapacity(8)

        // Editor-only diagnostic, off unless asked for. Records which sprite
        // each run was opened or extended for, so the sequence actually
        // submitted to Metal can be checked against the draw order rather than
        // assumed to match it. See `reportDrawOrder`.
        let auditingDrawOrder = DrawOrderAudit.isEnabled
        var auditedNames: [(run: Int, name: String)] = []

        /// Extend the run in progress, or start a new one. The only thing that
        /// starts a new one is a change of state — never a change of page
        /// order, never the kind of geometry coming first.
        func openRun(_ kind: DrawRun.Kind, page: Int, blend: Int, start: Int, count: Int,
                     name: @autoclosure () -> String) {
            if var last = drawRuns.last,
               last.kind == kind, last.pageIndex == page, last.blendIndex == blend {
                last.count += count
                drawRuns[drawRuns.count - 1] = last
            } else {
                drawRuns.append(DrawRun(kind: kind, pageIndex: page, blendIndex: blend,
                                        start: start, count: count))
            }
            if auditingDrawOrder {
                auditedNames.append((drawRuns.count - 1, name()))
            }
        }

        let isMeshEditing = sceneManager.isMeshEditEnabled
        let isolateSelection = isMeshEditing && sceneManager.meshIsolateSelection

        // The rim reuses the vertices the sprite pass has already skinned,
        // deformed and projected. Recomputing them would be a second
        // transcription of the same geometry, and the two would drift.
        var outlineDraws: [OutlineDraw] = []
        let selectedID = sceneManager.selectedImageID
        let hoveredID = sceneManager.hoveredImageID

        // Handed to picking, so a click tests the frame that was on screen when
        // it happened rather than a fresher one nobody saw — and so picking
        // does not repeat the skinning this loop is about to do.
        var drawnGeometry: [UUID: CanvasPicking.ScreenGeometry] = [:]
        drawnGeometry.reserveCapacity(estimatedImageCount)

        // Evaluate the skeleton once per frame; every skinned image reuses the
        // same matrices instead of re-walking the hierarchy (and constraints)
        // per image.
        let needsSkinning = sceneManager.images.contains { !$0.isHidden && $0.mesh.hasSkinningData() }
        let frameWorldMatrices: [UUID: simd_float4x4]? = needsSkinning ? framePose : nil

        for image in sceneManager.renderOrderedImages.reversed() where !image.isHidden {
            if isolateSelection, image.id != sceneManager.selectedImageID {
                continue
            }
            let renderImage = sceneManager.renderPose(for: image)

            guard let asset = assetManager.asset(for: renderImage.assetID) else { continue }
            guard let pageIndex = asset.atlasPageIndex else { continue }
            guard let uvRect = asset.atlasUVRect else { continue }
            guard pageIndex < pageCount else { continue }

            let has3DRotation = simd_length(renderImage.rotation3D) > 0.0001
            let isSelectedMeshEditImage = isMeshEditing && renderImage.id == sceneManager.selectedImageID
            // ToolUtilities.resolvedMesh, not a second private copy of it. The
            // copy returned the RAW mesh while `skinnedLocalVertices` below
            // resolves the SANITIZED one, so indices and UVs came from one mesh
            // and positions from another. Any sanitising that changed the vertex
            // list — which is exactly what happens to a mesh with a bad triangle
            // list — made the two disagree inside a single draw call.
            // Through the memo, not the sanitizer. `sanitizedForRender` walks
            // every triangle and every vertex and allocates as it goes; the
            // mesh it repairs does not change while the animation plays, so
            // doing it here made the frame cost grow with the size of the
            // artwork. Same function, same answer, computed on edit.
            let mesh = sceneManager.renderMeshCache.resolvedMesh(for: renderImage, assetSize: asset.size)
            let showDeformed = sceneManager.isMeshOverlayDeformed
            let localVertices = sceneManager.skinnedLocalVertices(for: renderImage, assetSize: asset.size, showDeformed: showDeformed, worldMatrices: frameWorldMatrices)
            let worldVertices = transformedVertices(for: renderImage, localVertices: localVertices)
            let screenVertices: [SIMD2<Float>] = worldVertices.map { world in
                if has3DRotation {
                    return project3DToScreen(
                        point: world,
                        center: renderImage.position,
                        rotationZ: renderImage.rotation,
                        rotation3D: renderImage.rotation3D,
                        viewSize: SIMD2<Float>(width, height),
                        camera: camera
                    )
                } else {
                    return worldToScreen(world, drawableSize: drawableSize)
                }
            }

            // When deformed positions may fall far outside the image's natural bounds
            // (e.g. LBS applied to local-space bindVertices moves them away from the image),
            // use bind-pose positions for culling so the image is never incorrectly skipped.
            let cullVertices: [SIMD2<Float>]
            if showDeformed {
                // The bind shape comes straight from the mesh resolved above.
                // Routing this back through `skinnedLocalVertices` re-resolved
                // and re-sanitized the same mesh a second time every frame, to
                // produce a shape that by definition involves no skinning.
                var bindLocal: [SIMD2<Float>] = []
                bindLocal.reserveCapacity(mesh.uvs.count)
                for uv in mesh.uvs {
                    bindLocal.append(Mesh.localPosition(for: uv, size: asset.size))
                }
                let bindWorld = transformedVertices(for: renderImage, localVertices: bindLocal)
                cullVertices = bindWorld.map { worldToScreen($0, drawableSize: drawableSize) }
            } else {
                cullVertices = screenVertices
            }
            if isQuadOutsideViewport(cullVertices, drawableSize: drawableSize, padding: 96) {
                continue
            }

            drawnGeometry[renderImage.id] = CanvasPicking.ScreenGeometry(
                mesh: mesh, screenVertices: screenVertices
            )

            // Selected wins over hovered: pointing at the sprite you already
            // have selected must not demote its rim to the quiet colour.
            if renderImage.id == selectedID || renderImage.id == hoveredID {
                var rimVertices: [TexturedVertex] = []
                appendMeshVertices(
                    mesh: mesh,
                    uvRect: uvRect,
                    screenVertices: screenVertices,
                    drawableSize: drawableSize,
                    destination: &rimVertices,
                    tint: SIMD4<Float>(1, 1, 1, 1)
                )
                if !rimVertices.isEmpty {
                    outlineDraws.append(OutlineDraw(
                        vertices: rimVertices,
                        pageIndex: pageIndex,
                        uvRect: uvRect,
                        colour: renderImage.id == selectedID ? UM.canvasSelect : UM.canvasPreselect
                    ))
                }
            }

            // The sprite's authored tint, held back where something else has to
            // be read over it.
            //
            // BIND MODE DIMS EVERY SPRITE, not only the one being bound. The
            // mode is about picking a BONE, and the art is what stands between
            // the artist and the skeleton — dimming just the selected sprite
            // would leave the rest of the rig covering the bones being aimed
            // at. Mesh edit dims only the sprite being edited, because there
            // the art is the thing being worked ON.
            let isBindingArtwork = sceneManager.isBindingBonesMode
                && sceneManager.selectedImageID != nil
            let dim: Float
            if isBindingArtwork {
                dim = Self.bindModeArtworkDim
            } else if isSelectedMeshEditImage && sceneManager.meshDimImage {
                dim = 0.34
            } else {
                dim = 1.0
            }
            var tint = renderImage.tintColor
            tint.w *= dim
            let blendIndex = renderImage.blendMode.pipelineIndex

            let shouldRenderAsMesh = has3DRotation || (!mesh.isQuadCompatible && (!isSelectedMeshEditImage || showDeformed))
            if shouldRenderAsMesh {
                let before = combinedVertices.count
                appendMeshVertices(
                    mesh: mesh,
                    uvRect: uvRect,
                    screenVertices: screenVertices,
                    drawableSize: drawableSize,
                    destination: &combinedVertices,
                    tint: tint
                )
                let added = combinedVertices.count - before
                if added > 0 {
                    openRun(.mesh, page: pageIndex, blend: blendIndex,
                            start: before, count: added, name: renderImage.name)
                }
                continue
            }

            openRun(.instanced, page: pageIndex, blend: blendIndex,
                    start: combinedInstances.count, count: 1, name: renderImage.name)
            combinedInstances.append(
                SpriteInstance(
                    positionScale: SIMD4<Float>(renderImage.position.x, renderImage.position.y, renderImage.scale.x, renderImage.scale.y),
                    halfSizeSkew: SIMD4<Float>(asset.size.x * 0.5, asset.size.y * 0.5, renderImage.skew.x, renderImage.skew.y),
                    rotationAndPad: SIMD4<Float>(renderImage.rotation * 180 / Float.pi, 0, 0, 0),
                    uvRect: uvRect,
                    tint: tint
                )
            )
        }

        // ── ONE EMISSION, IN DRAW ORDER ──────────────────────────────────
        //
        // Both buffers are uploaded once, then the runs are walked in the order
        // they were built — which is the order the sprites were visited, which
        // is the draw order. A run says which buffer it reads from and what
        // state it needs; nothing here may reorder anything.
        //
        // No early return for an empty run list: both uploads are guarded, the
        // loop over no runs does nothing, and a scene whose sprites are all
        // hidden still has a selection to rim and a geometry map to publish.
        if !combinedInstances.isEmpty {
            let byteLength = MemoryLayout<SpriteInstance>.stride * combinedInstances.count
            ensureSpriteInstanceBufferCapacity(requiredLength: byteLength)
            guard let instanceBuffer = spriteInstanceBuffers[ringIndex] else { return }
            memcpy(instanceBuffer.contents(), combinedInstances, byteLength)
        }
        if !combinedVertices.isEmpty {
            let byteLength = MemoryLayout<TexturedVertex>.stride * combinedVertices.count
            ensureSpriteBatchBufferCapacity(requiredLength: byteLength)
            guard let batchBuffer = spriteBatchBuffers[ringIndex] else { return }
            memcpy(batchBuffer.contents(), combinedVertices, byteLength)
        }

        let cameraOrigin = camera?.origin ?? .zero
        let cameraZoom = Float(camera?.zoom ?? 1.0)
        var sceneUniforms = SpriteSceneUniforms(
            viewportAndZoom: SIMD4<Float>(width, height, cameraZoom, 0),
            cameraOrigin: SIMD4<Float>(Float(cameraOrigin.x), Float(cameraOrigin.y), 0, 0)
        )
        encoder.setVertexBytes(&sceneUniforms,
                               length: MemoryLayout<SpriteSceneUniforms>.stride, index: 2)

        // The two kinds bind different things at buffer index 0 — the unit
        // quad for the instanced path, the built triangles for the mesh path —
        // so the binding is re-issued whenever the kind changes, and only then.
        var boundKind: DrawRun.Kind?
        var boundBlend = -1
        for run in drawRuns {
            guard let atlasTexture = assetManager.atlasTexture(pageIndex: run.pageIndex) else { continue }

            switch run.kind {
            case .instanced:
                guard let instanceBuffer = spriteInstanceBuffers[ringIndex] else { continue }
                if boundKind != .instanced {
                    encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
                    boundKind = .instanced
                    boundBlend = -1
                }
                if run.blendIndex != boundBlend {
                    encoder.setRenderPipelineState(textureInstancedPipelineStatesByBlend[run.blendIndex])
                    boundBlend = run.blendIndex
                }
                encoder.setVertexBuffer(instanceBuffer,
                                        offset: run.start * MemoryLayout<SpriteInstance>.stride,
                                        index: 1)
                encoder.setFragmentTexture(atlasTexture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: run.count)

            case .mesh:
                guard let batchBuffer = spriteBatchBuffers[ringIndex] else { continue }
                if boundKind != .mesh {
                    encoder.setVertexBuffer(batchBuffer, offset: 0, index: 0)
                    boundKind = .mesh
                    boundBlend = -1
                }
                if run.blendIndex != boundBlend {
                    encoder.setRenderPipelineState(texturePipelineStatesByBlend[run.blendIndex])
                    boundBlend = run.blendIndex
                }
                encoder.setFragmentTexture(atlasTexture, index: 0)
                encoder.drawPrimitives(type: .triangle,
                                       vertexStart: run.start, vertexCount: run.count)
            }
        }

        if auditingDrawOrder {
            DrawOrderAudit.report(runs: drawRuns.map {
                ($0.kind == .instanced ? "quad" : "mesh", $0.pageIndex, $0.blendIndex,
                 $0.start, $0.count)
            }, submitted: auditedNames,
               instanceCount: combinedInstances.count,
               vertexCount: combinedVertices.count)
        }

        drawSelectionOutlines(outlineDraws, encoder: encoder)

        // Published to picking only once the frame is fully described, so a
        // half-filled dictionary is never visible to a click.
        sceneManager.lastDrawnGeometry = drawnGeometry
    }

    // MARK: - Selection rim

    private struct OutlineDraw {
        let vertices: [TexturedVertex]
        let pageIndex: Int
        let uvRect: SIMD4<Float>
        let colour: SIMD3<Float>
    }

    /// Mirrors `OutlineUniforms` in TextureShaders.metal.
    private struct OutlineUniforms {
        var uvRect: SIMD4<Float>
        var color: SIMD4<Float>
        var thickness: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    /// Drawable pixels, like every other measurement in this renderer —
    /// `MeshOverlayMetrics` states the same convention and `CheckerUniforms`
    /// records why: camera zoom is already in drawable pixels here, so a second
    /// point-to-pixel conversion would double-count.
    ///
    /// Sized against the mesh contour, which is 3.5px and reads correctly: the
    /// selection rim is a little heavier, because it has to be findable at a
    /// glance across a whole canvas rather than followed along an edge.
    private static let outlineRimPx: Float = 3.6
    /// Drawn first and fatter, leaving about a pixel of dark on each side.
    private static let outlineContourPx: Float = 5.6

    /// Two passes, fat and dark then thin and coloured — the same contour trick
    /// the glyphs and the mesh markers use, and the only reason a pale grey
    /// pre-selection is legible at all. Without it the grey rim vanishes on
    /// pale artwork, which is most artwork.
    private func drawSelectionOutlines(_ draws: [OutlineDraw],
                                       encoder: MTLRenderCommandEncoder) {
        guard !draws.isEmpty, let assetManager else { return }

        var combined: [TexturedVertex] = []
        var starts: [Int] = []
        for draw in draws {
            starts.append(combined.count)
            combined.append(contentsOf: draw.vertices)
        }
        let byteLength = MemoryLayout<TexturedVertex>.stride * combined.count
        ensureOutlineBufferCapacity(requiredLength: byteLength)
        guard let outlineBuffer = outlineVertexBuffers[ringIndex] else { return }
        memcpy(outlineBuffer.contents(), combined, byteLength)

        encoder.setRenderPipelineState(outlinePipelineState)
        encoder.setVertexBuffer(outlineBuffer, offset: 0, index: 0)

        // Contour under every rim, then every rim: two loops rather than two
        // passes per sprite, so a rim is never buried under the NEXT sprite's
        // contour where two selected sprites overlap.
        for pass in 0..<2 {
            for (index, draw) in draws.enumerated() {
                guard let atlasTexture = assetManager.atlasTexture(pageIndex: draw.pageIndex) else { continue }
                let colour = pass == 0 ? UM.contourInk(for: draw.colour) : draw.colour
                let thickness = pass == 0 ? Self.outlineContourPx : Self.outlineRimPx
                var uniforms = OutlineUniforms(
                    uvRect: draw.uvRect,
                    color: SIMD4<Float>(colour.x, colour.y, colour.z, pass == 0 ? 0.85 : 1.0),
                    thickness: thickness
                )
                encoder.setFragmentTexture(atlasTexture, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OutlineUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle,
                                       vertexStart: starts[index],
                                       vertexCount: draw.vertices.count)
            }
        }
    }

    private func drawSceneImagesFallback(encoder: MTLRenderCommandEncoder, drawableSize: CGSize) {
        guard let assetManager,
              let sceneManager else {
            return
        }
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        guard width > 0, height > 0 else { return }

        for image in sceneManager.renderOrderedImages.reversed() where !image.isHidden {
            let renderImage = sceneManager.renderPose(for: image)

            guard let asset = assetManager.asset(for: renderImage.assetID) else { continue }
            let halfWidth = asset.size.x * 0.5
            let halfHeight = asset.size.y * 0.5

            let local = [
                SIMD2<Float>(-halfWidth, halfHeight),
                SIMD2<Float>(halfWidth, halfHeight),
                SIMD2<Float>(-halfWidth, -halfHeight),
                SIMD2<Float>(halfWidth, -halfHeight)
            ]
            let uvs = [
                SIMD2<Float>(0, 0),
                SIMD2<Float>(1, 0),
                SIMD2<Float>(0, 1),
                SIMD2<Float>(1, 1)
            ]

            let rotationDeg = renderImage.rotation * 180 / Float.pi
            let shearForRender: SIMD2<Float> = renderImage.skew
            let has3DRotation = simd_length(renderImage.rotation3D) > 0.0001
            let worldCorners = local.map { p in
                MatrixUtilities.shearedWorldTransform(
                    local: p,
                    position: renderImage.position,
                    rotation: rotationDeg,
                    shear: shearForRender,
                    scale: renderImage.scale
                )
            }
            let screenCorners: [SIMD2<Float>] = worldCorners.map { world in
                if has3DRotation {
                    return project3DToScreen(
                        point: world,
                        center: renderImage.position,
                        rotationZ: renderImage.rotation,
                        rotation3D: renderImage.rotation3D,
                        viewSize: SIMD2<Float>(width, height),
                        camera: camera
                    )
                } else {
                    return worldToScreen(world, drawableSize: drawableSize)
                }
            }

            if isQuadOutsideViewport(screenCorners, drawableSize: drawableSize, padding: 96) {
                continue
            }

            let tint = renderImage.tintColor
            let vertices: [TexturedVertex] = [
                TexturedVertex(position: screenToNDC(screenCorners[0], viewSize: drawableSize), uv: uvs[0], tint: tint),
                TexturedVertex(position: screenToNDC(screenCorners[1], viewSize: drawableSize), uv: uvs[1], tint: tint),
                TexturedVertex(position: screenToNDC(screenCorners[2], viewSize: drawableSize), uv: uvs[2], tint: tint),
                TexturedVertex(position: screenToNDC(screenCorners[3], viewSize: drawableSize), uv: uvs[3], tint: tint)
            ]

            // This path draws one sprite at a time in draw order, so it can
            // honour the blend mode exactly rather than bucketing for it.
            encoder.setRenderPipelineState(texturePipelineStatesByBlend[renderImage.blendMode.pipelineIndex])
            encoder.setVertexBytes(vertices, length: MemoryLayout<TexturedVertex>.stride * vertices.count, index: 0)
            encoder.setFragmentTexture(asset.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private func ensureOutlineBufferCapacity(requiredLength: Int) {
        guard requiredLength > 0 else { return }
        if outlineVertexBufferLength < requiredLength
            || outlineVertexBuffers.contains(where: { $0 == nil }) {
            // EVERY SLOT, not just this one: a ring whose members have
            // different lengths is a ring with a slot that overflows on the
            // frame it comes round to.
            let alignedLength = ((requiredLength + 4095) / 4096) * 4096
            outlineVertexBuffers = outlineVertexBuffers.map { _ in
                device.makeBuffer(length: alignedLength, options: .storageModeShared)
            }
            outlineVertexBufferLength = alignedLength
        }
    }

    private func ensureSpriteBatchBufferCapacity(requiredLength: Int) {
        guard requiredLength > 0 else { return }
        if spriteBatchBufferLength < requiredLength
            || spriteBatchBuffers.contains(where: { $0 == nil }) {
            let alignedLength = ((requiredLength + 4095) / 4096) * 4096
            spriteBatchBuffers = spriteBatchBuffers.map { _ in
                device.makeBuffer(length: alignedLength, options: .storageModeShared)
            }
            spriteBatchBufferLength = alignedLength
        }
    }

    private func ensureSpriteInstanceBufferCapacity(requiredLength: Int) {
        guard requiredLength > 0 else { return }
        if spriteInstanceBufferLength >= requiredLength,
           spriteInstanceBuffers.allSatisfy({ $0 != nil }) {
            return
        }
        let alignedLength = ((requiredLength + 4095) / 4096) * 4096
        spriteInstanceBuffers = spriteInstanceBuffers.map { _ in
            device.makeBuffer(length: alignedLength, options: .storageModeShared)
        }
        spriteInstanceBufferLength = alignedLength
    }

    private func drawGizmos(encoder: MTLRenderCommandEncoder, drawableSize: CGSize, commandBuffer: MTLCommandBuffer) {
        guard let assetManager,
              let sceneManager,
              let toolManager else {
            return
        }
        var vertices: [GizmoVertex] = []
        let active = toolManager.activeHandle
        let hovered = toolManager.hoveredHandle

        let zoom = camera?.zoom ?? 1.0
        gizmoRenderer.ndcTransform = nil

        if let boneID = sceneManager.selectedBoneID,
           let pose = framePose,
           let segment = sceneManager.skeleton.lineSegment(for: boneID, in: pose),
           sceneManager.selectedImageID == nil {
            let center = segment.start
            switch toolManager.currentTool {
            case .move, .select:
                let moveVertices = gizmoRenderer.moveGizmoVertices(center: center, zoom: zoom, active: active, hovered: hovered, viewSize: drawableSize)
                drawGizmoVertices(moveVertices, encoder: encoder, primitive: .triangle)
            case .rotate:
                let rotation = sceneManager.skeleton.worldRotation(for: boneID, in: pose) ?? 0
                let rotateVertices = gizmoRenderer.rotateGizmoVertices(center: center, rotation: rotation, zoom: zoom, active: active, hovered: hovered, viewSize: drawableSize)
                drawGizmoVertices(rotateVertices.fill, encoder: encoder, primitive: .triangle)
                drawGizmoVertices(rotateVertices.stroke, encoder: encoder, primitive: .triangle)
            case .scale:
                let scaleVertices = gizmoRenderer.scaleGizmoVertices(center: center, zoom: zoom, active: active, hovered: hovered, viewSize: drawableSize)
                drawGizmoVertices(scaleVertices, encoder: encoder, primitive: .triangle)
            case .bone, .mesh, .skew, .physicsPreview:
                break
            }
            gizmoRenderer.ndcTransform = nil
            return
        }

        guard let selectedID = sceneManager.selectedImageID,
              let image = sceneManager.image(for: selectedID) else {
            return
        }

        let renderImage = sceneManager.renderPose(for: image)

        guard let asset = assetManager.asset(for: renderImage.assetID) else {
            return
        }

        let size = SIMD2<Float>(Float(asset.texture.width),
                                Float(asset.texture.height))
        let shearForRender: SIMD2<Float> = renderImage.skew
        let corners = transformedCorners(
            for: renderImage,
            frame: ToolUtilities.localFrame(for: renderImage, assetSize: size),
            shearOverride: shearForRender
        )
        let center = renderImage.position

        switch toolManager.currentTool {
        case .move, .select:
            let moveVertices = gizmoRenderer.moveGizmoVertices(center: center, zoom: zoom, active: active, hovered: hovered, viewSize: drawableSize)
            drawGizmoVertices(moveVertices, encoder: encoder, primitive: .triangle)
        case .bone:
            break
        case .mesh:
            break
        case .rotate:
            let rotateVertices = gizmoRenderer.rotateGizmoVertices(center: center, rotation: renderImage.rotation, zoom: zoom, active: active, hovered: hovered, viewSize: drawableSize)
            drawGizmoVertices(rotateVertices.fill, encoder: encoder, primitive: .triangle)
            drawGizmoVertices(rotateVertices.stroke, encoder: encoder, primitive: .triangle)
        case .scale:
            let scaleVertices = gizmoRenderer.scaleGizmoVertices(center: center, zoom: zoom, active: active, hovered: hovered, viewSize: drawableSize)
            drawGizmoVertices(scaleVertices, encoder: encoder, primitive: .triangle)
        case .skew:
            // A FIXED radius, not one measured off the sprite. The old one
            // came from the sprite's transformed corners, so shearing moved
            // the corners, which moved the radius, which redrew the gizmo
            // bigger every frame of the drag.
            let skewVertices = gizmoRenderer.skewGizmoVertices(
                center: center,
                shearXDegrees: renderImage.skew.x,
                shearYDegrees: renderImage.skew.y,
                zoom: zoom,
                active: active,
                hovered: hovered,
                viewSize: drawableSize
            )
            drawGizmoVertices(skewVertices, encoder: encoder, primitive: .triangle)
        case .physicsPreview:
            break
        }

        // No rectangle around the sprite. A PNG on a checkerboard already shows
        // its own extent through its alpha, and every transform tool draws a
        // gizmo at the centre that says which sprite is selected — so the box
        // added nothing and crossed the artwork being worked on. `corners` is
        // still computed: it is what the skew gizmo is sized from, and what
        // picking and the rubber band test against elsewhere.
        if toolManager.currentTool != .move && toolManager.currentTool != .select && toolManager.currentTool != .bone && toolManager.currentTool != .mesh {
            vertices.append(contentsOf: gizmoRenderer.pivotVertices(at: center, zoom: zoom, viewSize: drawableSize))
        }
        gizmoRenderer.ndcTransform = nil

        drawGizmoVertices(vertices, encoder: encoder)
    }

    private func drawMeshOverlay(encoder: MTLRenderCommandEncoder, drawableSize: CGSize) {
        guard let assetManager,
              let sceneManager,
              let toolManager,
              let selectedID = sceneManager.selectedImageID,
              let image = sceneManager.image(for: selectedID),
              let asset = assetManager.asset(for: image.assetID) else {
            return
        }
        guard sceneManager.isMeshOverlayVisible else { return }

        // The pose the sprite is DRAWN at — the same one the sprite layer uses.
        // Reading `image` here is what left the mesh behind during a drag.
        let renderImage = sceneManager.renderPose(for: image)

        guard let mesh = ToolUtilities.overlayMesh(for: image, assetSize: asset.size) else { return }
        let localVertices = sceneManager.skinnedLocalVertices(
            for: image,
            assetSize: asset.size,
            showDeformed: sceneManager.isMeshOverlayDeformed,
            mesh: mesh
        )
        let worldVertices = transformedVertices(for: renderImage, localVertices: localVertices)
        guard !worldVertices.isEmpty else { return }

        let hullColor = SIMD4<Float>(UM.canvasMesh.x, UM.canvasMesh.y, UM.canvasMesh.z, 0.98)
        let lineColor = SIMD4<Float>(hullColor.x, hullColor.y, hullColor.z, 0.85)
        let vertexColor = SIMD4<Float>(hullColor.x, hullColor.y, hullColor.z, 1.0)
        let hoverColor = SIMD4<Float>(UM.canvasHover.x, UM.canvasHover.y, UM.canvasHover.z, 1.0)
        let selectedColor = SIMD4<Float>(1.00, 0.76, 0.16, 1.0)
        let createPreviewColor = SIMD4<Float>(UM.canvasPreview.x, UM.canvasPreview.y, UM.canvasPreview.z, 0.95)
        let internalEdgeColor = SIMD4<Float>(1.0, 0.85, 0.12, 0.98)
        let selectedInternalEdgeColor = SIMD4<Float>(1.0, 0.95, 0.42, 1.0)
        let zoom = camera?.zoom ?? 1.0
        // In weight paint mode use larger vertex markers so the influence
        // colors are easier to read and the bones controlling each vertex stand out.
        // Every size the overlay draws itself at, named in one place. They all
        // grew: the contour was thin enough to lose over busy artwork, the
        // triangle connections were nearly hairlines, and the nodes were small
        // enough that a rim would not have fitted inside them.
        let internalEdgeWidthPx = MeshOverlayMetrics.internalEdgeWidthPx
        let basePixelRadius = MeshOverlayMetrics.nodeRadiusPx(
            weightPainting: sceneManager.meshWeightPaintEnabled)
        let radius = Float(basePixelRadius / max(Float(zoom), 0.001))
        let contourWidthPx = MeshOverlayMetrics.contourWidthPx
        let connectionWidthPx = MeshOverlayMetrics.connectionWidthPx
        let dashLengthPx: Float = 7.0
        let dashGapPx: Float = 5.0

        var triangleEdges: [GizmoVertex] = []
        // Triangles answer "how is this sprite cut up", which is not a question
        // being asked while posing a rig, building bones or painting weights —
        // and over a face they are clutter. A selected mesh layer is enough to
        // raise the overlay, so the overlay being up is not the same as being
        // in Mesh mode; the mode is asked for directly, from the one place that
        // decides it. The Triangles toggle still applies within Mesh mode.
        if sceneManager.meshShowTriangles,
           CanvasModeSelection.active(scene: sceneManager, tools: toolManager) == .mesh {
            for triangle in stride(from: 0, to: mesh.indices.count, by: 3) {
                guard triangle + 2 < mesh.indices.count else { break }
                let i0 = Int(mesh.indices[triangle])
                let i1 = Int(mesh.indices[triangle + 1])
                let i2 = Int(mesh.indices[triangle + 2])
                guard worldVertices.indices.contains(i0),
                      worldVertices.indices.contains(i1),
                      worldVertices.indices.contains(i2) else {
                    continue
                }
                triangleEdges.append(contentsOf: meshDashedLine(
                    from: worldVertices[i0],
                    to: worldVertices[i1],
                    color: lineColor,
                    viewSize: drawableSize,
                    widthPx: connectionWidthPx,
                    dashLengthPx: dashLengthPx,
                    gapLengthPx: dashGapPx
                ))
                triangleEdges.append(contentsOf: meshDashedLine(
                    from: worldVertices[i1],
                    to: worldVertices[i2],
                    color: lineColor,
                    viewSize: drawableSize,
                    widthPx: connectionWidthPx,
                    dashLengthPx: dashLengthPx,
                    gapLengthPx: dashGapPx
                ))
                triangleEdges.append(contentsOf: meshDashedLine(
                    from: worldVertices[i2],
                    to: worldVertices[i0],
                    color: lineColor,
                    viewSize: drawableSize,
                    widthPx: connectionWidthPx,
                    dashLengthPx: dashLengthPx,
                    gapLengthPx: dashGapPx
                ))
            }
        }

        var hullEdges: [GizmoVertex] = []
        if mesh.hullVertexIndices.count > 1 {
            // An outline still being traced is open: n nodes give n-1 segments.
            // Wrapping with `% count` is right for a finished outline and wrong
            // for one in progress — it draws a line straight across the artwork
            // from the last node back to the first, which is what the artist is
            // trying to look at.
            let isOpen = sceneManager.isMeshCreatingHull
            let segmentCount = isOpen
                ? mesh.hullVertexIndices.count - 1
                : mesh.hullVertexIndices.count
            for index in 0..<segmentCount {
                let current = Int(mesh.hullVertexIndices[index])
                let next = Int(mesh.hullVertexIndices[(index + 1) % mesh.hullVertexIndices.count])
                guard worldVertices.indices.contains(current),
                      worldVertices.indices.contains(next) else {
                    continue
                }
                hullEdges.append(contentsOf: meshThickLine(
                    from: worldVertices[current],
                    to: worldVertices[next],
                    color: hullColor,
                    viewSize: drawableSize,
                    widthPx: contourWidthPx
                ))
            }
        }

        var internalEdges: [GizmoVertex] = []
        for (edgeIndex, edge) in mesh.internalEdges.enumerated() {
            let startIndex = Int(edge.a)
            let endIndex = Int(edge.b)
            guard worldVertices.indices.contains(startIndex),
                  worldVertices.indices.contains(endIndex) else {
                continue
            }
            let color = sceneManager.selectedMeshInternalEdgeIndex == edgeIndex ? selectedInternalEdgeColor : internalEdgeColor
            internalEdges.append(contentsOf: meshThickLine(
                from: worldVertices[startIndex],
                to: worldVertices[endIndex],
                color: color,
                viewSize: drawableSize,
                widthPx: internalEdgeWidthPx
            ))
        }

        var vertexMarkers: [GizmoVertex] = []
        /// Selection and hover rings, drawn after the pies so they sit on top.
        var weightPaintRings: [(center: SIMD2<Float>, color: SIMD4<Float>)] = []
        let weightPaintEnabled = sceneManager.meshWeightPaintEnabled
        // Only where the answer is used. `mesh` comes from `overlayMesh`,
        // which ends in `sanitizedForRender`, which ends in exactly this call
        // — so outside weight paint this was a second full pass over every
        // vertex, every frame, building a dictionary per vertex, for a result
        // nothing below reads.
        let safeWeights = weightPaintEnabled
            ? mesh.sanitizedSkinningData().vertexBoneWeights
            : []
        let showBlendedWeights = weightPaintEnabled && !safeWeights.isEmpty
        let boneColors: [UUID: SIMD4<Float>] = weightPaintEnabled
            ? Dictionary(uniqueKeysWithValues: sceneManager.skeleton.bones.compactMap { pair in
                pair.value.color.map { (pair.key, $0) }
            })
            : [:]
        // With a node selected in weight paint, the rest are DIMMED so the one
        // being worked on is unmistakable — it is the only one the brush will
        // touch, and a row of equally bright pies gives no sign of that.
        let hasWeightSelection = weightPaintEnabled
            && !sceneManager.selectedMeshVertexIndices.isEmpty
        let dimmed: Float = 0.28

        for (index, vertex) in worldVertices.enumerated() {
            let isSelected = sceneManager.selectedMeshVertexIndices.contains(index)
            let isHovered = sceneManager.hoveredMeshVertexIndex == index
            let fade: Float = (hasWeightSelection && !isSelected && !isHovered)
                ? dimmed : 1.0

            // In weight paint a selected or hovered vertex keeps its weights and
            // gets a RING. It used to be replaced by a flat disc and `continue`d
            // past the pie, so in the one mode whose job is showing weights,
            // every vertex you had selected showed none.
            if showBlendedWeights, isSelected || isHovered {
                weightPaintRings.append((vertex, isSelected ? selectedColor : hoverColor))
            } else if isSelected {
                vertexMarkers.append(contentsOf: gizmoRenderer.meshVertexMarker(center: vertex, radius: radius, color: selectedColor, viewSize: drawableSize))
                continue
            } else if isHovered {
                vertexMarkers.append(contentsOf: gizmoRenderer.meshVertexMarker(center: vertex, radius: radius, color: hoverColor, viewSize: drawableSize))
                continue
            }

            if showBlendedWeights, safeWeights.indices.contains(index), !safeWeights[index].isEmpty {
                let slices: [(weight: Float, color: SIMD4<Float>)] = safeWeights[index].compactMap { influence in
                    guard let boneColor = boneColors[influence.boneID] else { return nil }
                    return (influence.weight,
                            SIMD4<Float>(boneColor.x, boneColor.y, boneColor.z, 0.96 * fade))
                }
                if !slices.isEmpty {
                    vertexMarkers.append(contentsOf: gizmoRenderer.boneWeightPieMarker(
                        center: vertex,
                        radius: radius,
                        slices: slices,
                        viewSize: drawableSize
                    ))
                    continue
                }
            }

            let plain = SIMD4<Float>(vertexColor.x, vertexColor.y, vertexColor.z,
                                     vertexColor.w * fade)
            vertexMarkers.append(contentsOf: gizmoRenderer.meshVertexMarker(center: vertex, radius: radius, color: plain, viewSize: drawableSize))
        }

        var createPreviewMarker: [GizmoVertex] = []
        var createPreviewEdge: [GizmoVertex] = []
        if sceneManager.isMeshEditEnabled,
           sceneManager.meshEditToolMode == .create,
           toolManager.currentTool == .mesh,
           let input = toolManager.lastInput {
            createPreviewMarker.append(contentsOf: gizmoRenderer.meshVertexMarker(
                center: input.position,
                radius: radius * 1.05,
                color: createPreviewColor,
                viewSize: drawableSize
            ))
        }
        if sceneManager.isMeshEditEnabled,
           sceneManager.meshEditToolMode == .create,
           toolManager.currentTool == .mesh,
           let previewStart = sceneManager.meshCreateEdgePreviewStart,
           let previewEnd = sceneManager.meshCreateEdgePreviewEnd {
            createPreviewEdge.append(contentsOf: meshThickLine(
                from: previewStart,
                to: previewEnd,
                color: internalEdgeColor,
                viewSize: drawableSize,
                widthPx: internalEdgeWidthPx
            ))
        }

        // Brush cursor preview: two concentric rings drawn at the cursor
        // position when weight paint is active, sized to the brush radius and falloff.
        var brushCursor: [GizmoVertex] = []
        // NO COLOUR, NO BRUSH. With no bone chosen there is nothing to paint
        // into, so the rings would be a cursor promising an action that does
        // nothing. The pointer is what the artist gets, and a click selects a
        // node instead.
        if sceneManager.meshWeightPaintEnabled,
           toolManager.currentTool == .mesh,
           let activeBoneID = sceneManager.activeWeightPaintBoneID,
           let input = toolManager.lastInput {
            let activeBoneColor = sceneManager.skeleton.bones[activeBoneID]?.color
                ?? SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
            let outerColor = SIMD4<Float>(activeBoneColor.x, activeBoneColor.y, activeBoneColor.z, 0.95)
            let innerColor = SIMD4<Float>(activeBoneColor.x, activeBoneColor.y, activeBoneColor.z, 0.55)
            let brushWorld = sceneManager.meshWeightBrushRadius
            let outerWidth: Float = 1.6
            let innerWidth: Float = 1.0
            brushCursor.append(contentsOf: meshRing(
                center: input.position,
                radius: brushWorld,
                color: outerColor,
                viewSize: drawableSize,
                widthPx: outerWidth
            ))
            let falloffFactor = max(0.0, min(1.0, 1.0 / max(sceneManager.meshWeightBrushFalloff, 0.3)))
            let innerRadius = brushWorld * (0.35 + 0.4 * falloffFactor)
            brushCursor.append(contentsOf: meshRing(
                center: input.position,
                radius: innerRadius,
                color: innerColor,
                viewSize: drawableSize,
                widthPx: innerWidth
            ))
        }

        // Bone weight color overlay: fill each mesh triangle with per-vertex blended bone colors
        var overlayTriangles: [GizmoVertex] = []
        if sceneManager.showWeightOverlay && showBlendedWeights {
            func blendedColor(at index: Int) -> SIMD4<Float> {
                guard safeWeights.indices.contains(index), !safeWeights[index].isEmpty else {
                    return SIMD4<Float>(UM.weightUnassigned.x, UM.weightUnassigned.y, UM.weightUnassigned.z, 0.60)
                }
                var r: Float = 0; var g: Float = 0; var b: Float = 0
                for influence in safeWeights[index] {
                    guard let c = boneColors[influence.boneID] else { continue }
                    r += c.x * influence.weight
                    g += c.y * influence.weight
                    b += c.z * influence.weight
                }
                return SIMD4<Float>(r, g, b, 0.68)
            }
            for triangle in stride(from: 0, to: mesh.indices.count, by: 3) {
                guard triangle + 2 < mesh.indices.count else { break }
                let i0 = Int(mesh.indices[triangle])
                let i1 = Int(mesh.indices[triangle + 1])
                let i2 = Int(mesh.indices[triangle + 2])
                guard worldVertices.indices.contains(i0),
                      worldVertices.indices.contains(i1),
                      worldVertices.indices.contains(i2) else { continue }
                // worldVertices must be converted to NDC for GizmoVertex
                let p0 = worldToNDC(worldVertices[i0], drawableSize: drawableSize)
                let p1 = worldToNDC(worldVertices[i1], drawableSize: drawableSize)
                let p2 = worldToNDC(worldVertices[i2], drawableSize: drawableSize)
                overlayTriangles.append(GizmoVertex(position: p0, color: blendedColor(at: i0)))
                overlayTriangles.append(GizmoVertex(position: p1, color: blendedColor(at: i1)))
                overlayTriangles.append(GizmoVertex(position: p2, color: blendedColor(at: i2)))
            }
        }

        drawGizmoVertices(overlayTriangles, encoder: encoder, primitive: .triangle)
        drawGizmoVertices(triangleEdges, encoder: encoder, primitive: .triangle)
        drawGizmoVertices(hullEdges, encoder: encoder, primitive: .triangle)
        drawGizmoVertices(internalEdges, encoder: encoder, primitive: .triangle)
        drawGizmoVertices(createPreviewEdge, encoder: encoder, primitive: .triangle)
        drawGizmoVertices(brushCursor, encoder: encoder, primitive: .triangle)
        drawGizmoVertices(vertexMarkers, encoder: encoder, primitive: .triangle)

        // Rings last, so a selection reads on top of the weight colours it is
        // no longer covering.
        if !weightPaintRings.isEmpty {
            var ringVertices: [GizmoVertex] = []
            for ring in weightPaintRings {
                ringVertices.append(contentsOf: meshRing(
                    center: ring.center,
                    radius: radius * 1.45,
                    color: ring.color,
                    viewSize: drawableSize,
                    widthPx: 2.2
                ))
            }
            drawGizmoVertices(ringVertices, encoder: encoder, primitive: .triangle)
        }
        drawGizmoVertices(createPreviewMarker, encoder: encoder, primitive: .triangle)
    }

    private func drawBonesOverlay(encoder: MTLRenderCommandEncoder, drawableSize: CGSize) {
        guard let sceneManager else { return }
        guard sceneManager.showBones else { return }
        let segments = sceneManager.skeleton.worldLineSegments(in: framePose ?? sceneManager.skeleton.worldMatrices())
        guard !segments.isEmpty || (sceneManager.boneCreationPreviewStart != nil && sceneManager.boneCreationPreviewEnd != nil) else { return }

        let bodyFill = SIMD4<Float>(UM.boneFill.x, UM.boneFill.y, UM.boneFill.z, 0.55)
        let bodyOutline = SIMD4<Float>(UM.boneOutline.x, UM.boneOutline.y, UM.boneOutline.z, 0.80)
        let selectedBodyFill = SIMD4<Float>(1.0, 0.15, 0.15, 0.55)
        let selectedBodyOutline = SIMD4<Float>(1.0, 0.10, 0.10, 0.85)
        let previewBodyFill = SIMD4<Float>(UM.bonePreviewFill.x, UM.bonePreviewFill.y, UM.bonePreviewFill.z, 0.32)
        let previewBodyOutline = SIMD4<Float>(UM.bonePreviewLine.x, UM.bonePreviewLine.y, UM.bonePreviewLine.z, 0.70)
        let rootDot = SIMD4<Float>(UM.boneRootDot.x, UM.boneRootDot.y, UM.boneRootDot.z, 0.90)
        let rootRing = SIMD4<Float>(UM.boneRootRing.x, UM.boneRootRing.y, UM.boneRootRing.z, 0.80)
        let selectedRootRing = SIMD4<Float>(1.0, 0.10, 0.10, 0.90)
        let zoom = camera?.zoom ?? 1.0
        // Drawable pixels, so a bone keeps its weight on screen at any zoom.
        // Thicker than it was — 14px across rather than 10 — at the author's
        // request: a 10px bone over artwork this size read as a hairline. The
        // joint stays wider than the body it caps, or the chain looks like one
        // continuous stick with no articulation in it.
        let jointRadius = Float(7.6 / max(Float(zoom), 0.001))
        let halfWidth = Float(7.0 / max(Float(zoom), 0.001))

        let boneCount = segments.count
        var bodyVertices: [GizmoVertex] = []
        bodyVertices.reserveCapacity(boneCount * 180)
        var jointVertices: [GizmoVertex] = []
        jointVertices.reserveCapacity(boneCount * 200)
        var parentLinkVertices: [GizmoVertex] = []

        var boneTipByID: [UUID: SIMD2<Float>] = [:]
        boneTipByID.reserveCapacity(boneCount)
        for (bone, _, end) in segments {
            boneTipByID[bone.id] = end
        }

        // EVERY selected bone, not just the active one. This read
        // `selectedBoneID` alone, so a multi-selection put one bone in the
        // highlight colour and left the rest looking untouched — a selection
        // you cannot see is a selection you do not trust, and the transform
        // that then moved all of them looked like a bug.
        let selectedIDs = sceneManager.selectedBoneIDs
        let primaryID = sceneManager.selectedBoneID
        let weightPaintActive = sceneManager.meshWeightPaintEnabled
        // In weight paint the bone that matters is the one ARMED for the brush,
        // which is not `selectedBoneID` — that is whatever bone Editor mode was
        // last on. The canvas used to highlight the second while the panel
        // highlighted the first, so it pointed confidently at the wrong bone.
        let armedBoneID = weightPaintActive ? sceneManager.activeWeightPaintBoneID : nil
        let parentLinkColor = SIMD4<Float>(1.0, 1.0, 1.0, 0.9)
        let dashLengthPx: Float = 4.0
        let gapLengthPx: Float = 4.0

        // Bind Mode: visual state for each bone (bound/unbound/hovered)
        let isBindMode = sceneManager.isBindingBonesMode && sceneManager.selectedImageID != nil
        let boundBoneIDsForBind: Set<UUID> = sceneManager.selectedImageID.map {
            isBindMode ? sceneManager.boundBoneIDs(imageID: $0) : []
        } ?? []
        let hoveredBindBoneID = isBindMode ? sceneManager.hoveredBindBoneID : nil

        // IK builder: the canvas becomes the picker, so each bone has to read as
        // chain, target, or neither at a glance.
        let ikDraft = sceneManager.ikBuilder
        let isIKBuilding = ikDraft != nil
        let ikChainIDs: Set<UUID> = Set(ikDraft?.chain ?? [])
        let ikTargetID = ikDraft?.targetID
        let ikHoveredID = ikDraft?.pickingSlot != nil ? sceneManager.ikBuilderHoveredBoneID : nil

        for (bone, start, end) in segments {
            let isSelected = selectedIDs.contains(bone.id)
            // One of the selected bones is the ACTIVE one: the bone the
            // inspector edits and the bone a rotation is measured from. It has
            // to be pickable out of the group at a glance.
            let isPrimary = primaryID == bone.id
            let isArmed = armedBoneID == bone.id
            let isBoundInBindMode = isBindMode && boundBoneIDsForBind.contains(bone.id)
            let isHoveredInBindMode = isBindMode && hoveredBindBoneID == bone.id
            let fill: SIMD4<Float>
            let outline: SIMD4<Float>
            let ring: SIMD4<Float>
            if isIKBuilding {
                if bone.id == ikTargetID {
                    // Target — amber, the colour the IK card already uses.
                    fill    = SIMD4<Float>(1.00, 0.72, 0.24, 0.72)
                    outline = SIMD4<Float>(1.00, 0.66, 0.14, 0.98)
                    ring    = SIMD4<Float>(1.00, 0.62, 0.10, 0.94)
                } else if ikChainIDs.contains(bone.id) {
                    // Chain — violet.
                    fill    = SIMD4<Float>(0.68, 0.48, 1.00, 0.70)
                    outline = SIMD4<Float>(0.60, 0.38, 1.00, 0.98)
                    ring    = SIMD4<Float>(0.56, 0.34, 0.98, 0.94)
                } else if bone.id == ikHoveredID {
                    // Under the cursor and pickable — bright neutral.
                    fill    = SIMD4<Float>(1.00, 1.00, 1.00, 0.62)
                    outline = SIMD4<Float>(1.00, 1.00, 1.00, 0.95)
                    ring    = SIMD4<Float>(1.00, 1.00, 1.00, 0.90)
                } else {
                    // Everything else recedes so the two roles stand out.
                    fill    = SIMD4<Float>(0.46, 0.46, 0.50, 0.22)
                    outline = SIMD4<Float>(0.42, 0.42, 0.46, 0.34)
                    ring    = SIMD4<Float>(0.38, 0.38, 0.42, 0.34)
                }
            } else if isBindMode {
                if isHoveredInBindMode && isBoundInBindMode {
                    // Hovered bound — peach "ready to unbind"
                    (fill, outline, ring) = Self.bindStateColours(
                        UM.bindUnbindPeach, fillAlpha: 0.55)
                } else if isHoveredInBindMode {
                    // Hovered unbound — butter "ready to bind"
                    (fill, outline, ring) = Self.bindStateColours(
                        UM.bindReadyButter, fillAlpha: 0.55)
                } else if isBoundInBindMode {
                    // Bound — mint
                    (fill, outline, ring) = Self.bindStateColours(
                        UM.bindBoundMint, fillAlpha: 0.50)
                } else {
                    // Unbound in bind mode — dimmed, but still on a light
                    // canvas, so slate rather than mid grey.
                    fill    = SIMD4<Float>(UM.boneFill.x, UM.boneFill.y, UM.boneFill.z, 0.22)
                    outline = SIMD4<Float>(UM.boneOutline.x, UM.boneOutline.y, UM.boneOutline.z, 0.40)
                    ring    = SIMD4<Float>(UM.boneOutline.x, UM.boneOutline.y, UM.boneOutline.z, 0.40)
                }
            } else if weightPaintActive {
                // The fill is the bone's pastel; the contour is that same hue
                // taken down to a fixed luminance, so a pale yellow bone reads
                // exactly as well as a deep blue one. A flat multiplier gave
                // whatever contrast the hue happened to start with.
                let boneColour = bone.color ?? UM.unboundBone
                let bc = SIMD3<Float>(boneColour.x, boneColour.y, boneColour.z)
                let ink = UM.contourInk(for: bc)
                fill = SIMD4<Float>(bc.x, bc.y, bc.z, isArmed ? 0.80 : 0.30)
                outline = SIMD4<Float>(ink.x, ink.y, ink.z, isArmed ? 1.0 : 0.72)
                ring = SIMD4<Float>(ink.x, ink.y, ink.z, isArmed ? 1.0 : 0.72)
            } else if isSelected && !isPrimary {
                // In the selection but not the active one: the same highlight,
                // held back so the active bone still reads as the one being
                // measured from. Not a third colour — a member of a selection
                // that looks like a different STATE is how a group stops
                // reading as a group.
                fill = SIMD4<Float>(selectedBodyFill.x, selectedBodyFill.y,
                                    selectedBodyFill.z, selectedBodyFill.w * 0.62)
                outline = SIMD4<Float>(selectedBodyOutline.x, selectedBodyOutline.y,
                                       selectedBodyOutline.z, selectedBodyOutline.w * 0.72)
                ring = SIMD4<Float>(selectedRootRing.x, selectedRootRing.y,
                                    selectedRootRing.z, selectedRootRing.w * 0.72)
            } else {
                fill = isPrimary ? selectedBodyFill : bodyFill
                outline = isPrimary ? selectedBodyOutline : bodyOutline
                ring = isPrimary ? selectedRootRing : rootRing
            }
            // A pastel at 0.55 beside the same pastel at 0.38 is not a signal
            // — it is the same colour, slightly. The armed bone is drawn
            // THICKER, which reads across a canvas at any zoom and does not
            // depend on the hue it happened to be given.
            let bodyHalfWidth = isArmed ? halfWidth * 1.75 : halfWidth
            bodyVertices.append(contentsOf: gizmoRenderer.boneBodyVertices(
                start: start,
                end: end,
                halfWidth: bodyHalfWidth,
                fillColor: fill,
                outlineColor: outline,
                viewSize: drawableSize
            ))
            jointVertices.append(contentsOf: gizmoRenderer.boneJointVertices(
                center: start,
                radius: isArmed ? jointRadius * 1.45 : jointRadius,
                fillColor: rootDot,
                ringColor: ring,
                viewSize: drawableSize
            ))

            if let parentID = bone.parentID, let parentTip = boneTipByID[parentID] {
                parentLinkVertices.append(contentsOf: dashedLine(
                    from: parentTip,
                    to: start,
                    color: parentLinkColor,
                    viewSize: drawableSize,
                    dashPx: dashLengthPx,
                    gapPx: gapLengthPx
                ))
            }
        }

        if let previewStart = sceneManager.boneCreationPreviewStart,
           let previewEnd = sceneManager.boneCreationPreviewEnd {
            bodyVertices.append(contentsOf: gizmoRenderer.boneBodyVertices(
                start: previewStart,
                end: previewEnd,
                halfWidth: halfWidth,
                fillColor: previewBodyFill,
                outlineColor: previewBodyOutline,
                viewSize: drawableSize
            ))
            jointVertices.append(contentsOf: gizmoRenderer.boneJointVertices(
                center: previewStart,
                radius: jointRadius,
                fillColor: rootDot,
                ringColor: previewBodyOutline,
                viewSize: drawableSize
            ))
        }

        drawGizmoVertices(bodyVertices, encoder: encoder, primitive: .triangle)
        drawGizmoVertices(jointVertices, encoder: encoder, primitive: .triangle)
        drawGizmoVertices(parentLinkVertices, encoder: encoder, primitive: .line)
    }

    private func dashedLine(from start: SIMD2<Float>,
                            to end: SIMD2<Float>,
                            color: SIMD4<Float>,
                            viewSize: CGSize,
                            dashPx: Float,
                            gapPx: Float) -> [GizmoVertex] {
        let p0 = worldToScreen(start, drawableSize: viewSize)
        let p1 = worldToScreen(end, drawableSize: viewSize)
        let delta = p1 - p0
        let length = simd_length(delta)
        guard length > 0.5, dashPx > 0.01 else { return [] }
        let dir = delta / length
        let cycle = dashPx + max(gapPx, 0)
        var verts: [GizmoVertex] = []
        var traveled: Float = 0
        while traveled < length {
            let dashStart = p0 + dir * traveled
            let dashEnd = p0 + dir * min(traveled + dashPx, length)
            verts.append(GizmoVertex(position: screenToNDC(dashStart, viewSize: viewSize), color: color))
            verts.append(GizmoVertex(position: screenToNDC(dashEnd, viewSize: viewSize), color: color))
            traveled += cycle
        }
        return verts
    }

    private func rotationRadius(zoom: Float) -> Float {
        let base: Float = 64
        let scaled = base * sqrt(max(zoom, 0.01))
        return max(48, min(96, scaled))
    }

    private func drawViewportGuides(encoder: MTLRenderCommandEncoder, drawableSize: CGSize) {
        guard let camera else { return }
        let vertices = viewportRenderer.guideVertices(viewSize: drawableSize, camera: camera)
        drawGizmoVertices(vertices.axes, encoder: encoder, primitive: .triangle)
    }

    private func drawGizmoVertices(_ vertices: [GizmoVertex], encoder: MTLRenderCommandEncoder, primitive: MTLPrimitiveType = .line) {
        guard !vertices.isEmpty else { return }
        encoder.setRenderPipelineState(gizmoPipelineState)
        let byteCount = MemoryLayout<GizmoVertex>.stride * vertices.count
        guard let buffer = device.makeBuffer(
            bytes: vertices,
            length: byteCount,
            options: .storageModeShared
        ) else {
            return
        }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: primitive, vertexStart: 0, vertexCount: vertices.count)
    }

    private func isQuadOutsideViewport(_ quad: [SIMD2<Float>], drawableSize: CGSize, padding: Float) -> Bool {
        guard !quad.isEmpty else { return true }
        var minX = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude

        for point in quad {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        let paddedMinX: Float = -padding
        let paddedMinY: Float = -padding
        let paddedMaxX = Float(drawableSize.width) + padding
        let paddedMaxY = Float(drawableSize.height) + padding

        return maxX < paddedMinX || minX > paddedMaxX || maxY < paddedMinY || minY > paddedMaxY
    }


    private func drawSelectionRect(encoder: MTLRenderCommandEncoder, drawableSize: CGSize) {
        guard let toolManager, let rect = toolManager.selectionRect else { return }
        let color = SIMD4<Float>(0.8, 0.85, 0.95, 0.8)
        let fill = SIMD4<Float>(0.4, 0.6, 1.0, 0.08)
        let vertices = selectionRectVertices(rect: rect, viewSize: drawableSize, stroke: color, fill: fill)
        drawGizmoVertices(vertices.fill, encoder: encoder, primitive: .triangle)
        drawGizmoVertices(vertices.stroke, encoder: encoder, primitive: .line)
    }

    private func selectionRectVertices(rect: CGRect, viewSize: CGSize, stroke: SIMD4<Float>, fill: SIMD4<Float>) -> (fill: [GizmoVertex], stroke: [GizmoVertex]) {
        let p0 = screenToNDC(SIMD2<Float>(Float(rect.minX), Float(rect.minY)), viewSize: viewSize)
        let p1 = screenToNDC(SIMD2<Float>(Float(rect.maxX), Float(rect.minY)), viewSize: viewSize)
        let p2 = screenToNDC(SIMD2<Float>(Float(rect.maxX), Float(rect.maxY)), viewSize: viewSize)
        let p3 = screenToNDC(SIMD2<Float>(Float(rect.minX), Float(rect.maxY)), viewSize: viewSize)

        let fillVerts = [
            GizmoVertex(position: p0, color: fill),
            GizmoVertex(position: p1, color: fill),
            GizmoVertex(position: p2, color: fill),
            GizmoVertex(position: p0, color: fill),
            GizmoVertex(position: p2, color: fill),
            GizmoVertex(position: p3, color: fill)
        ]

        let strokeVerts = [
            GizmoVertex(position: p0, color: stroke),
            GizmoVertex(position: p1, color: stroke),
            GizmoVertex(position: p1, color: stroke),
            GizmoVertex(position: p2, color: stroke),
            GizmoVertex(position: p2, color: stroke),
            GizmoVertex(position: p3, color: stroke),
            GizmoVertex(position: p3, color: stroke),
            GizmoVertex(position: p0, color: stroke)
        ]

        return (fillVerts, strokeVerts)
    }

    private func drawAngleBadge(encoder: MTLRenderCommandEncoder, drawableSize: CGSize) {
        guard let toolManager, toolManager.currentTool == .rotate,
              let input = toolManager.lastInput, input.isDragging,
              let sceneManager else { return }
        let center: SIMD2<Float>
        if let selectedID = sceneManager.selectedImageID,
           let image = sceneManager.image(for: selectedID) {
            center = image.position
        } else if let boneID = sceneManager.selectedBoneID,
                  let pose = framePose,
                  let segment = sceneManager.skeleton.lineSegment(for: boneID, in: pose) {
            center = segment.start
        } else {
            return
        }
        let vector = input.position - center
        let angle = atan2(vector.y, vector.x) * 180 / Float.pi
        let text = String(format: "%.1f°", angle)
        guard let texture = textTexture(for: text) else { return }

        let badgeSize = CGSize(width: 68, height: 26)
        let screen = input.screenPosition + SIMD2<Float>(12, 12)
        drawTexturedQuad(encoder: encoder, texture: texture, screenPosition: screen, size: badgeSize, drawableSize: drawableSize)
    }

    private func drawTexturedQuad(encoder: MTLRenderCommandEncoder, texture: MTLTexture, screenPosition: SIMD2<Float>, size: CGSize, drawableSize: CGSize) {
        let x = screenPosition.x
        let y = screenPosition.y
        let w = Float(size.width)
        let h = Float(size.height)

        let p0 = screenToNDC(SIMD2<Float>(x, y), viewSize: drawableSize)
        let p1 = screenToNDC(SIMD2<Float>(x + w, y), viewSize: drawableSize)
        let p2 = screenToNDC(SIMD2<Float>(x, y + h), viewSize: drawableSize)
        let p3 = screenToNDC(SIMD2<Float>(x + w, y + h), viewSize: drawableSize)

        let vertices: [TexturedVertex] = [
            TexturedVertex(position: p0, uv: SIMD2<Float>(0, 0), tint: SIMD4<Float>(1, 1, 1, 1)),
            TexturedVertex(position: p1, uv: SIMD2<Float>(1, 0), tint: SIMD4<Float>(1, 1, 1, 1)),
            TexturedVertex(position: p2, uv: SIMD2<Float>(0, 1), tint: SIMD4<Float>(1, 1, 1, 1)),
            TexturedVertex(position: p3, uv: SIMD2<Float>(1, 1), tint: SIMD4<Float>(1, 1, 1, 1))
        ]

        encoder.setRenderPipelineState(texturePipelineState)
        encoder.setVertexBytes(vertices, length: MemoryLayout<TexturedVertex>.stride * vertices.count, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func textTexture(for text: String) -> MTLTexture? {
        if let cached = textTextureCache[text] { return cached }
        let size = CGSize(width: 68, height: 26)
        let rect = CGRect(origin: .zero, size: size)
        let style = NSMutableParagraphStyle()
        style.alignment = .center

#if os(macOS)
        let image = NSImage(size: size)
        image.lockFocus()
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor(white: 0.1, alpha: 0.85).setFill()
        path.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ]
        text.draw(in: rect.insetBy(dx: 4, dy: 5), withAttributes: attrs)
        image.unlockFocus()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
#else
        let uiImage = UIGraphicsImageRenderer(size: size).image { _ in
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
            UIColor(white: 0.1, alpha: 0.85).setFill()
            path.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: style
            ]
            text.draw(in: rect.insetBy(dx: 4, dy: 5), withAttributes: attrs)
        }
        guard let cgImage = uiImage.cgImage else { return nil }
#endif

        let loader = MTKTextureLoader(device: device)
        let texture = try? loader.newTexture(cgImage: cgImage, options: [
            MTKTextureLoader.Option.SRGB: false
        ])
        if let texture { textTextureCache[text] = texture }
        return texture
    }

    /// The renderer's own copy of this was deleted. It framed the sprite on the
    /// PNG's rectangle while `ToolUtilities` framed it on the mesh, so the frame
    /// drawn on canvas and the quad picking tested were different rectangles.
    private func transformedCorners(for image: SceneImage,
                                    frame: ToolUtilities.LocalFrame,
                                    shearOverride: SIMD2<Float>? = nil) -> [SIMD2<Float>] {
        ToolUtilities.transformedCorners(for: image, frame: frame, shearOverride: shearOverride)
    }

    private func transformedVertices(for image: SceneImage, localVertices: [SIMD2<Float>], shearOverride: SIMD2<Float>? = nil) -> [SIMD2<Float>] {
        ToolUtilities.transformedVertices(for: image, localVertices: localVertices, shearOverride: shearOverride)
    }

    private func meshLine(from start: SIMD2<Float>, to end: SIMD2<Float>, color: SIMD4<Float>, viewSize: CGSize) -> [GizmoVertex] {
        [
            GizmoVertex(position: worldToNDC(start, drawableSize: viewSize), color: color),
            GizmoVertex(position: worldToNDC(end, drawableSize: viewSize), color: color)
        ]
    }

    private func meshThickLine(
        from start: SIMD2<Float>,
        to end: SIMD2<Float>,
        color: SIMD4<Float>,
        viewSize: CGSize,
        widthPx: Float
    ) -> [GizmoVertex] {
        let p0 = worldToScreen(start, drawableSize: viewSize)
        let p1 = worldToScreen(end, drawableSize: viewSize)
        return meshThickLineScreen(fromScreen: p0, toScreen: p1, color: color, viewSize: viewSize, widthPx: widthPx)
    }

    private func meshThickLineScreen(
        fromScreen p0: SIMD2<Float>,
        toScreen p1: SIMD2<Float>,
        color: SIMD4<Float>,
        viewSize: CGSize,
        widthPx: Float
    ) -> [GizmoVertex] {
        let delta = p1 - p0
        let length = simd_length(delta)
        guard length > 0.001 else { return [] }
        let dir = delta / length
        let normal = SIMD2<Float>(-dir.y, dir.x)
        let half = normal * (widthPx * 0.5)

        let a = screenToNDC(p0 + half, viewSize: viewSize)
        let b = screenToNDC(p0 - half, viewSize: viewSize)
        let c = screenToNDC(p1 + half, viewSize: viewSize)
        let d = screenToNDC(p1 - half, viewSize: viewSize)

        return [
            GizmoVertex(position: a, color: color),
            GizmoVertex(position: b, color: color),
            GizmoVertex(position: c, color: color),
            GizmoVertex(position: c, color: color),
            GizmoVertex(position: b, color: color),
            GizmoVertex(position: d, color: color)
        ]
    }

    private func meshRing(
        center: SIMD2<Float>,
        radius: Float,
        color: SIMD4<Float>,
        viewSize: CGSize,
        widthPx: Float
    ) -> [GizmoVertex] {
        let screenCenter = worldToScreen(center, drawableSize: viewSize)
        let screenEdge = worldToScreen(center + SIMD2<Float>(radius, 0), drawableSize: viewSize)
        let screenRadius = simd_distance(screenCenter, screenEdge)
        guard screenRadius > 0.5 else { return [] }
        let segments = max(24, Int(screenRadius * 0.75))
        var vertices: [GizmoVertex] = []
        vertices.reserveCapacity(segments * 6)
        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * Float.pi * 2
            let a1 = Float(i + 1) / Float(segments) * Float.pi * 2
            let p0 = screenCenter + SIMD2<Float>(cos(a0), sin(a0)) * screenRadius
            let p1 = screenCenter + SIMD2<Float>(cos(a1), sin(a1)) * screenRadius
            vertices.append(contentsOf: meshThickLineScreen(
                fromScreen: p0,
                toScreen: p1,
                color: color,
                viewSize: viewSize,
                widthPx: widthPx
            ))
        }
        return vertices
    }

    private func meshDashedLine(
        from start: SIMD2<Float>,
        to end: SIMD2<Float>,
        color: SIMD4<Float>,
        viewSize: CGSize,
        widthPx: Float,
        dashLengthPx: Float,
        gapLengthPx: Float
    ) -> [GizmoVertex] {
        let p0 = worldToScreen(start, drawableSize: viewSize)
        let p1 = worldToScreen(end, drawableSize: viewSize)
        let delta = p1 - p0
        let length = simd_length(delta)
        guard length > 0.001 else { return [] }

        let dir = delta / length
        let unit = max(dashLengthPx + gapLengthPx, 1.0)
        var t: Float = 0
        var vertices: [GizmoVertex] = []
        while t < length {
            let segmentStart = p0 + dir * t
            let segmentEnd = p0 + dir * min(t + dashLengthPx, length)
            vertices.append(contentsOf: meshThickLineScreen(
                fromScreen: segmentStart,
                toScreen: segmentEnd,
                color: color,
                viewSize: viewSize,
                widthPx: widthPx
            ))
            t += unit
        }
        return vertices
    }

    private func appendMeshVertices(
        mesh: Mesh,
        uvRect: SIMD4<Float>,
        screenVertices: [SIMD2<Float>],
        drawableSize: CGSize,
        destination: inout [TexturedVertex],
        tint: SIMD4<Float>
    ) {
        guard mesh.uvs.count == screenVertices.count else { return }
        guard mesh.indices.count >= 3 else { return }

        destination.reserveCapacity(destination.count + mesh.indices.count)

        for start in stride(from: 0, to: mesh.indices.count, by: 3) {
            guard start + 2 < mesh.indices.count else { break }

            let i0 = Int(mesh.indices[start])
            let i1 = Int(mesh.indices[start + 1])
            let i2 = Int(mesh.indices[start + 2])

            guard screenVertices.indices.contains(i0),
                  screenVertices.indices.contains(i1),
                  screenVertices.indices.contains(i2),
                  mesh.uvs.indices.contains(i0),
                  mesh.uvs.indices.contains(i1),
                  mesh.uvs.indices.contains(i2) else {
                continue
            }

            let tri = [i0, i1, i2]
            for vertexIndex in tri {
                let baseUV = mesh.uvs[vertexIndex]
                let atlasUV = SIMD2<Float>(
                    uvRect.x + baseUV.x * uvRect.z,
                    uvRect.y + baseUV.y * uvRect.w
                )
                destination.append(
                    TexturedVertex(
                        position: screenToNDC(screenVertices[vertexIndex], viewSize: drawableSize),
                        uv: atlasUV,
                        tint: tint
                    )
                )
            }
        }
    }

    private func gizmoHandles(for tool: ActiveTool, corners: [SIMD2<Float>], center: SIMD2<Float>) -> [SIMD2<Float>] {
        switch tool {
        case .move, .select:
            return [center]
        case .bone:
            return [center]
        case .mesh:
            return corners
        case .rotate:
            return corners
        case .scale:
            return corners
        case .skew:
            let top = (corners[0] + corners[1]) * 0.5
            let bottom = (corners[2] + corners[3]) * 0.5
            let left = (corners[0] + corners[2]) * 0.5
            let right = (corners[1] + corners[3]) * 0.5
            return [top, bottom, left, right]
        case .physicsPreview:
            return [center]
        }
    }

    private func projectSkewToNDC(world: SIMD2<Float>, center: SIMD2<Float>, rotationZ: Float, rotation3D: SIMD3<Float>, drawableSize: CGSize) -> SIMD2<Float> {
        let viewSize = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        let screenPoint = camera?.worldToScreen(world, viewSize: viewSize) ?? (world + viewSize * 0.5)
        let centerScreen = camera?.worldToScreen(center, viewSize: viewSize) ?? (center + viewSize * 0.5)

        let pitch = rotation3D.x
        let yaw = rotation3D.y
        let rotation3DMatrix = MatrixUtilities.rotationY(yaw) * MatrixUtilities.rotationX(pitch)
        let perspective = MatrixUtilities.perspective(m34: skewPerspectiveM34)
        let matrix = perspective * rotation3DMatrix

        let local = SIMD3<Float>(screenPoint.x - centerScreen.x, screenPoint.y - centerScreen.y, 0)
        let projected = MatrixUtilities.transformPoint(local, with: matrix)
        let screen = SIMD2<Float>(centerScreen.x + projected.x, centerScreen.y + projected.y)

        let ndcX = (screen.x / (viewSize.x * 0.5)) - 1.0
        let ndcY = 1.0 - (screen.y / (viewSize.y * 0.5))
        return SIMD2<Float>(ndcX, ndcY)
    }

    private func project3DToScreen(point: SIMD2<Float>, center: SIMD2<Float>, rotationZ: Float, rotation3D: SIMD3<Float>, viewSize: SIMD2<Float>, camera: CameraState?) -> SIMD2<Float> {
        let screenPoint = camera?.worldToScreen(point, viewSize: viewSize) ?? (point + viewSize * 0.5)
        let centerScreen = camera?.worldToScreen(center, viewSize: viewSize) ?? (center + viewSize * 0.5)

        let pitch = rotation3D.x
        let yaw = rotation3D.y
        let rotation3DMatrix = MatrixUtilities.rotationY(yaw) * MatrixUtilities.rotationX(pitch)
        let perspective = MatrixUtilities.perspective(m34: -1.0 / 500.0)
        let matrix = perspective * rotation3DMatrix

        let local = SIMD3<Float>(screenPoint.x - centerScreen.x, screenPoint.y - centerScreen.y, 0)
        let projected = MatrixUtilities.transformPoint(local, with: matrix)
        return SIMD2<Float>(centerScreen.x + projected.x, centerScreen.y + projected.y)
    }

    private func worldToNDC(_ world: SIMD2<Float>, drawableSize: CGSize) -> SIMD2<Float> {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        let screen = worldToScreen(world, drawableSize: drawableSize)
        let ndcX = (screen.x / (width * 0.5)) - 1.0
        let ndcY = 1.0 - (screen.y / (height * 0.5))
        return SIMD2<Float>(ndcX, ndcY)
    }

    private func screenToNDC(_ screen: SIMD2<Float>, viewSize: CGSize) -> SIMD2<Float> {
        let width = Float(viewSize.width)
        let height = Float(viewSize.height)
        let ndcX = (screen.x / (width * 0.5)) - 1.0
        let ndcY = 1.0 - (screen.y / (height * 0.5))
        return SIMD2<Float>(ndcX, ndcY)
    }

    private func worldToScreen(_ world: SIMD2<Float>, drawableSize: CGSize) -> SIMD2<Float> {
        let viewSize = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        if let camera {
            return camera.worldToScreen(world, viewSize: viewSize)
        }
        return world + viewSize * 0.5
    }

    private func updateCamera(drawableSize: CGSize) {
        let now = CACurrentMediaTime()
        let delta = now - lastFrameTime
        lastFrameTime = now
        let viewSize = CGSize(width: drawableSize.width, height: drawableSize.height)
        camera?.update(deltaTime: max(0.0, min(0.05, delta)), viewSize: viewSize)
    }

}
