import Foundation
import Metal
import simd

/// Scene, drawn by the GPU, into a texture that the canvas presents and the
/// exporter reads back.
///
/// ## Why this exists
///
/// The CPU compositor it replaces was a deliberate choice — one renderer, so
/// the canvas and the export could not disagree — and the choice was right.
/// What was never bounded was its cost. Measured: a frame is three fixed
/// passes over every pixel plus one per layer plus three more per LIT layer,
/// on one core, on the main thread, inside SwiftUI's `body`. At 2400×1350 the
/// ceiling is about four to seven lit layers, or four to six rig instances, at
/// 30fps — and the two share a thread, so they compete rather than add.
///
/// This keeps the property that mattered and drops the cost. There is still
/// ONE renderer: this one. The canvas presents the texture it draws; the
/// exporter reads the same texture back. Two consumers, one render pass, one
/// piece of arithmetic — which is a stronger guarantee than before, because
/// previously the two shared source code and now they share a result.
///
/// ## What the move deletes rather than ports
///
/// - `LightField` and the whole screen-space lattice. Lighting is evaluated
///   per pixel from an interpolated world position. The lattice's density
///   heuristics, cell-size caps and golden-ratio probes existed to bound an
///   error that no longer occurs; measured at 11.5 levels of 255 at the
///   shipped density, where a spot's cone crosses a cell.
/// - The near-plane clipper, on the draw path. Sutherland–Hodgman is there
///   because a CPU rasteriser must cut a triangle before dividing by w; the
///   hardware does it in fixed function. `SceneProjection.clip` stays for
///   hit-testing and bounds, which ask a different question.
/// - The per-triangle affine map. Hardware interpolation is perspective
///   correct and the affine is not — measured at 74.5 texels of 1024 on a
///   card tilted 60°, so this is an accuracy gain, not a trade.
///
/// Verified by `Editor/verify_scene_gpu_pipeline.py` (the arithmetic, against
/// `lighting_mirror.py` which stays normative) and
/// `Editor/verify_scene_gpu_transcription.py` (that the Swift and the Metal
/// agree on every struct).
///
/// ## Not yet wired
///
/// `SceneViewportView` still draws through `SceneFrameRenderer`, and both
/// exports still do too. This now draws everything a Scene contains — plates,
/// fills and rig instances, all lit — but nothing in the app calls it, so the
/// picture on screen is still the CPU compositor's. The switch is its own step,
/// because it is the one that can regress what the artist sees.
///
/// Until that step lands, every claim this file makes about being the ONE
/// renderer is a claim about what it is FOR, not about what runs.
final class SceneMetalRenderer {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let cardPipeline: MTLRenderPipelineState
    private let skinnedPipeline: MTLRenderPipelineState
    private let backgroundPipeline: MTLRenderPipelineState
    private let encodePipeline: MTLRenderPipelineState
    private let atlasSampler: MTLSamplerState
    private let curveSampler: MTLSamplerState

    /// How many frames the CPU may have in flight, and therefore how many
    /// copies of every buffer written per frame there are.
    ///
    /// ONE NUMBER, because it is one constraint: a buffer may be rewritten
    /// only once the GPU has finished reading it. The rig canvas gets this
    /// wrong today — its instance buffer is a ring of two and its mesh vertex
    /// buffer is a single buffer, with two frames in flight — and the result
    /// is a frame-late triangle under load, which reads as a rendering bug and
    /// is a data race. Nothing here may be written outside the ring.
    static let framesInFlight = 3

    /// Palette blocks are padded to this many matrices so every block's byte
    /// offset into the shared palette buffer stays aligned. 4 x 64 bytes is
    /// 256, the strictest `setVertexBuffer` offset alignment across the Macs
    /// this ships to; an unaligned offset is not a slow draw, it is a refused
    /// one.
    static let paletteAlignmentMatrices = 4
    private let inFlight = DispatchSemaphore(value: SceneMetalRenderer.framesInFlight)
    private var ringIndex = 0

    /// How long the GPU actually spent on the most recently COMPLETED frame,
    /// in milliseconds.
    ///
    /// The adaptive resolution ladder needs a cost per frame, and on the CPU
    /// that was a stopwatch around the draw. Here the draw call returns long
    /// before the work happens, so timing it measures how fast this thread can
    /// fill a command buffer -- a number that looks wonderful and would talk
    /// the ladder into a rung the GPU cannot hold. The only honest figure comes
    /// from the command buffer once the GPU is done with it.
    ///
    /// It therefore describes a frame that has ALREADY BEEN PRESENTED, which is
    /// what the ladder wants anyway: it climbs on evidence, not on prediction.
    ///
    /// Written on whatever thread Metal completes on and read on the main one,
    /// so it goes through a lock rather than trusting a `Double` to be atomic.
    var lastDrawMilliseconds: Double {
        costLock.lock()
        defer { costLock.unlock() }
        return recordedDrawMilliseconds
    }
    private let costLock = NSLock()
    private var recordedDrawMilliseconds: Double = 0

    private var cardVertexBuffers: [MTLBuffer?]
    private var cardVertexCapacity = 0
    private var skinnedVertexBuffers: [MTLBuffer?]
    private var skinnedVertexCapacity = 0
    private var paletteBuffers: [MTLBuffer?]
    private var paletteCapacity = 0
    private var lightBuffers: [MTLBuffer?]
    private var occluderBuffers: [MTLBuffer?]
    private var occluderCapacity = 0
    private var lightCapacity = 0

    /// The linear target the scene accumulates into, before the encode pass.
    ///
    /// `rgba16Float`, and that is not for precision at the end but for HEADROOM
    /// in the middle. The CPU compositor worked in eight bits, so a lamp bright
    /// enough to push a surface past white clipped AT THAT LAYER and every
    /// layer drawn over it composited against a flat white disc. Here the
    /// overflow survives until the encode pass, which is the only place
    /// anything is clamped.
    private var accumulation: MTLTexture?

    /// The 8-bit target an export renders into before reading it back.
    /// Kept between frames because an export renders hundreds at one size.
    private var readback: MTLTexture?

    /// Bound when the scene has no lights, so that `buffer(2)` and `texture(1)`
    /// are never left unset.
    ///
    /// METAL'S VALIDATION LAYER ABORTS THE PROCESS for a declared argument that
    /// was never bound, whether or not the shader goes on to read it — and it
    /// is on by default in a Debug build from Xcode. `sceneCardFragment`
    /// declares both, and both were bound only when there were lights to put in
    /// them, so a scene with no lights drew with two dangling bindings. That is
    /// EVERY freshly opened project and every freshly imported plate, which is
    /// exactly when this crashed.
    ///
    /// Binding a one-element buffer and a 1x1 texture costs nothing and removes
    /// the case. `lightCount` still says zero, so the shader never reads either.
    private var emptyLightBuffer: MTLBuffer?
    private var emptyCurveTexture: MTLTexture?
    private var emptyNormalTexture: MTLTexture?
    private var emptyHeightTexture: MTLTexture?
    private var emptyOccluderBuffer: MTLBuffer?

    // ── The shadow atlas ───────────────────────────────────────────────
    //
    // One R8 texture holding a small square of every shadow-casting asset's
    // alpha, so the fragment shader has ONE texture to bind however many
    // different sprites are casting. The alternative was an array of the
    // albedo atlas's pages, which a fragment shader cannot index freely and
    // which would have meant capping the number of pages a scene may have.
    //
    // It is also the better texture for the job. A shadow needs an outline,
    // not a resolution: 128 across gives a character's silhouette, the whole
    // atlas stays inside a megabyte, and every sample lands in cache -- which
    // matters when the loop is lights x occluders per fragment.
    private var shadowAtlas: MTLTexture?
    /// Which slot each asset's tile occupies, so a rebuild is only needed when
    /// a NEW caster appears rather than on every frame.
    private var shadowSlots: [UUID: Int] = [:]
    static let shadowTileSide = 128
    static let shadowAtlasTiles = 8
    /// The most casters one scene may have tiles for. Beyond it an occluder
    /// casts its rectangle rather than its outline -- degraded, never dropped,
    /// because a character that stops casting entirely reads as a bug and a
    /// slightly boxy shadow reads as a shadow.
    static var shadowSlotCount: Int { shadowAtlasTiles * shadowAtlasTiles }

    /// Falloff curves as rows of a 2D texture, one row per distinct curve.
    private var curveTexture: MTLTexture?
    private var curveRows: [LightFalloffCurve] = []
    /// The width of a curve row. `LightFalloffCurve.table()` already makes
    /// exactly this many entries, and it is the one place the number lives.
    static let curveEntries = 256

    /// A 1×2 texture per distinct fill, so a two-stop vertical ramp is a
    /// linear-filtered sample rather than a special case in the shader.
    private var fillTextures: [FillKey: MTLTexture] = [:]

    struct FillKey: Hashable {
        let top: SIMD4<Float>
        let bottom: SIMD4<Float>
        init(_ fill: SceneFill) { top = fill.topColor; bottom = fill.bottomColor }
    }

    // MARK: - Setup

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let cardVertex = library.makeFunction(name: "sceneCardVertex"),
              let skinnedVertex = library.makeFunction(name: "sceneSkinnedVertex"),
              let cardFragment = library.makeFunction(name: "sceneCardFragment"),
              let backgroundFragment = library.makeFunction(name: "sceneBackgroundFragment"),
              let encodeVertex = library.makeFunction(name: "sceneEncodeVertex"),
              let encodeFragment = library.makeFunction(name: "sceneEncodeFragment")
        else { return nil }

        self.device = device
        self.commandQueue = queue

        let cardDescriptor = MTLRenderPipelineDescriptor()
        cardDescriptor.label = "Scene card"
        cardDescriptor.vertexFunction = cardVertex
        cardDescriptor.fragmentFunction = cardFragment
        cardDescriptor.colorAttachments[0].pixelFormat = Self.accumulationFormat
        // PREMULTIPLIED SOURCE-OVER, in fixed function. `dst = src + dst*(1-a)`
        // is the only blend the compositor uses, and the CPU path wrote it out
        // by hand because it had to. Here it is two enum values, and the
        // shader says nothing about blending at all.
        cardDescriptor.colorAttachments[0].isBlendingEnabled = true
        cardDescriptor.colorAttachments[0].rgbBlendOperation = .add
        cardDescriptor.colorAttachments[0].alphaBlendOperation = .add
        cardDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        cardDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        cardDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        cardDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let skinnedDescriptor = MTLRenderPipelineDescriptor()
        skinnedDescriptor.label = "Scene skinned"
        skinnedDescriptor.vertexFunction = skinnedVertex
        skinnedDescriptor.fragmentFunction = cardFragment
        skinnedDescriptor.colorAttachments[0].pixelFormat = Self.accumulationFormat
        skinnedDescriptor.colorAttachments[0].isBlendingEnabled = true
        skinnedDescriptor.colorAttachments[0].rgbBlendOperation = .add
        skinnedDescriptor.colorAttachments[0].alphaBlendOperation = .add
        skinnedDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        skinnedDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        skinnedDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        skinnedDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let backgroundDescriptor = MTLRenderPipelineDescriptor()
        backgroundDescriptor.label = "Scene background"
        backgroundDescriptor.vertexFunction = encodeVertex
        backgroundDescriptor.fragmentFunction = backgroundFragment
        backgroundDescriptor.colorAttachments[0].pixelFormat = Self.accumulationFormat
        // NO BLENDING. The background is the first thing in the pass and it is
        // what "behind everything" means, so it WRITES rather than composites.
        // Blended over a transparent clear it would be correct by accident and
        // wrong the moment the fill carries an alpha of its own.
        backgroundDescriptor.colorAttachments[0].isBlendingEnabled = false

        let encodeDescriptor = MTLRenderPipelineDescriptor()
        encodeDescriptor.label = "Scene encode"
        encodeDescriptor.vertexFunction = encodeVertex
        encodeDescriptor.fragmentFunction = encodeFragment
        encodeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let card = try? device.makeRenderPipelineState(descriptor: cardDescriptor),
              let skinned = try? device.makeRenderPipelineState(descriptor: skinnedDescriptor),
              let background = try? device.makeRenderPipelineState(descriptor: backgroundDescriptor),
              let encode = try? device.makeRenderPipelineState(descriptor: encodeDescriptor)
        else { return nil }
        self.cardPipeline = card
        self.skinnedPipeline = skinned
        self.backgroundPipeline = background
        self.encodePipeline = encode

        let atlasDescriptor = MTLSamplerDescriptor()
        atlasDescriptor.minFilter = .linear
        atlasDescriptor.magFilter = .linear
        // CLAMPED, because the atlas packs unrelated artwork side by side: a
        // repeating sampler at a card's edge reads the neighbour's pixels.
        atlasDescriptor.sAddressMode = .clampToEdge
        atlasDescriptor.tAddressMode = .clampToEdge

        let curveDescriptor = MTLSamplerDescriptor()
        curveDescriptor.minFilter = .linear
        curveDescriptor.magFilter = .linear
        // Clamp-to-edge is what makes the table's ends behave: a light is full
        // at its centre and out past its rim, and the sampler holds those
        // rather than wrapping the curve round.
        curveDescriptor.sAddressMode = .clampToEdge
        curveDescriptor.tAddressMode = .clampToEdge

        guard let atlasState = device.makeSamplerState(descriptor: atlasDescriptor),
              let curveState = device.makeSamplerState(descriptor: curveDescriptor)
        else { return nil }
        self.atlasSampler = atlasState
        self.curveSampler = curveState

        self.cardVertexBuffers = Array(repeating: nil, count: Self.framesInFlight)
        self.skinnedVertexBuffers = Array(repeating: nil, count: Self.framesInFlight)
        self.paletteBuffers = Array(repeating: nil, count: Self.framesInFlight)
        self.lightBuffers = Array(repeating: nil, count: Self.framesInFlight)
        self.occluderBuffers = Array(repeating: nil, count: Self.framesInFlight)
    }

    static let accumulationFormat: MTLPixelFormat = .rgba16Float
}

// MARK: - Drawing

extension SceneMetalRenderer {

    /// One draw in the scene's own order, and which pipeline it needs.
    ///
    /// A card and a skinned sprite read DIFFERENT VERTEX STRUCTS from different
    /// buffers, so they cannot share a draw call -- but they do share an order,
    /// and that order is the artist's. Keeping both in one list is what stops
    /// the renderer from quietly sorting rigs to the front.
    enum LayerDraw {
        enum Kind { case card, skinned }

        case card(range: Range<Int>, uniforms: SceneLayerUniforms,
                  texture: MTLTexture, normalMap: MTLTexture?,
                  heightMap: MTLTexture?)
        case skinned(range: Range<Int>, paletteOffset: Int,
                     uniforms: SceneLayerUniforms,
                     texture: MTLTexture, normalMap: MTLTexture?)

        var uniforms: SceneLayerUniforms {
            switch self {
            case let .card(_, uniforms, _, _, _): return uniforms
            case let .skinned(_, _, uniforms, _, _): return uniforms
            }
        }
    }

    /// Everything a frame needs that is not the composition itself.
    struct Frame {
        var projection: SceneProjection
        var lighting: SceneLighting
        var pixelSize: SIMD2<Int>
        /// The ground behind every layer, in SCREEN space.
        ///
        /// The two eyes disagree about it and only about it: the shot is
        /// composed against `SceneComposition.background`, and the fly view
        /// against the editor's void grey, so that flying out of the frame
        /// looks like leaving the set rather than like more sky. Passing it in
        /// rather than reading the composition is what lets one renderer serve
        /// both without learning which one it is drawing for.
        var background: SceneFill
    }

    /// Draw one frame into `destination`, an 8-bit texture the canvas presents
    /// or the exporter reads.
    ///
    /// ONE ENTRY POINT, and that is the whole architecture. The canvas passes a
    /// drawable's texture; the exporter passes a texture it will read back.
    /// Nothing else differs — not the projection, not the lighting, not the
    /// order. Before this, the canvas and the export shared SOURCE CODE and
    /// could still drift apart through anything that read the context's own
    /// size; now they share a result.
    func render(composition: SceneComposition,
                atFrame frameIndex: Int,
                frame: Frame,
                scene: SceneManager,
                assets: AssetManager,
                into destination: MTLTexture,
                presenting drawable: (any MTLDrawable)? = nil) {

        inFlight.wait()
        ringIndex = (ringIndex + 1) % Self.framesInFlight

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { [weak self] finished in
            semaphore.signal()
            guard let self else { return }
            // `gpuEndTime` and `gpuStartTime` are zero until the buffer has
            // actually run, and a scheduling hiccup can order them oddly; a
            // negative or zero span is not a free frame, it is a missing
            // measurement, and feeding one to the ladder is how it climbs.
            let span = finished.gpuEndTime - finished.gpuStartTime
            guard span > 0 else { return }
            self.costLock.lock()
            self.recordedDrawMilliseconds = span * 1000
            self.costLock.unlock()
        }

        guard let target = accumulationTexture(width: frame.pixelSize.x,
                                               height: frame.pixelSize.y) else {
            if let drawable { commandBuffer.present(drawable) }
            commandBuffer.commit()
            return
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        // Clear to TRANSPARENT, not to a background colour. A fill layer that
        // covers the frame is a layer like any other and is drawn in its place
        // in the order; painting a background first would put it under layers
        // the artist sent behind it.
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            if let drawable { commandBuffer.present(drawable) }
            commandBuffer.commit()
            return
        }
        encoder.label = "Scene layers"
        encoder.setFragmentSamplerState(atlasSampler, index: 0)
        encoder.setFragmentSamplerState(curveSampler, index: 1)

        // THE GROUND, FIRST AND UNLIT. The CPU compositor fills this before any
        // layer and never lights it, because it is not a surface in the scene --
        // it is what the shot is composed against. Dropping it does not leave a
        // black frame, which would at least be obvious; it leaves the window's
        // own grey showing through wherever no layer covers, so the artist's
        // chosen ground silently becomes chrome.
        if let ramp = fillTexture(frame.background) {
            encoder.setRenderPipelineState(backgroundPipeline)
            encoder.setFragmentTexture(ramp, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        let lights = frame.lighting.lights
        let curves = prepareCurves(for: lights)
        var uniforms = SceneFrameUniforms(
            viewProjection: frame.projection.viewProjection,
            eyeAndNear: SIMD4<Float>(frame.projection.eye, frame.projection.nearZ),
            ambient: SIMD4<Float>(frame.lighting.ambient.rgb, 0),
            lightCount: UInt32(lights.count)
        )
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SceneFrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneFrameUniforms>.stride, index: 0)
        encoder.setFragmentTexture(curves ?? placeholderCurveTexture(), index: 1)

        // OCCLUDERS BEFORE LIGHTS, because each light's uniform carries its own
        // slice of the occluder buffer and the slices are only known once the
        // whole frame's casters have been culled against every light.
        //
        // And the WHOLE scene's casters, gathered before the first draw: a card
        // occludes surfaces drawn before it as well as after, so this cannot be
        // folded into the per-layer pass that follows.
        // NOTHING AT ALL WHEN NO LIGHT CASTS, which is every project that
        // predates shadows and most that do not. Gathering occluders samples
        // each rig's pose and builds a quad per sprite -- real work, every
        // frame, for a result nobody would read.
        let casting = lights.contains { $0.light.castsShadows }
        let occluders = casting
            ? occluderGeometry(composition: composition, atFrame: frameIndex,
                               scene: scene, assets: assets)
            : []
        let culled = cullOccluders(occluders, for: lights)
        uploadOccluders(culled.flat, into: encoder)
        // THE ATLAS IS NOT ALLOCATED UNTIL A TILE IS WANTED. `shadowAtlasTexture`
        // makes a megabyte the first time it is called, and calling it here
        // unconditionally would have charged that to every scene in the app on
        // its first frame, shadows or not. `shadowAtlas` is non-nil only once
        // `shadowTileRect` has actually needed it.
        encoder.setFragmentTexture(shadowAtlas ?? placeholderCurveTexture(), index: 3)
        uploadLights(lights, occluderRanges: culled.ranges, into: encoder)

        // BACK TO FRONT, through the composition's own order. `drawOrderedLayers`
        // is the one authority on what covers what — the exporter, the hierarchy
        // column and the move buttons all read it — and depth does not reorder
        // anything: Z affects projection, the artist's layer number affects
        // order. That separation is the plan's, and keeping it means a card
        // pushed far away does not jump behind its neighbours.
        // ONE ORDERED LIST, not one pass of cards and then one of rigs.
        // Splitting by kind is the obvious way to avoid switching pipelines and
        // it silently reorders the scene: every rig would land in front of every
        // plate, whatever the artist put where. The pipeline is switched when
        // the KIND changes instead, which for a normal scene is a handful of
        // times, and the order is the one `drawOrderedLayers` states.
        var cardVertices: [SceneVertexIn] = []
        var skinnedVertices: [SceneSkinnedVertexIn] = []
        var palettes: [simd_float4x4] = []
        var draws: [LayerDraw] = []

        for layer in composition.drawOrderedLayers where !layer.isHidden {
            if let built = cardGeometry(layer, composition: composition,
                                        atFrame: frameIndex,
                                        scene: scene, assets: assets) {
                let start = cardVertices.count
                cardVertices.append(contentsOf: built.vertices)
                draws.append(.card(range: start..<cardVertices.count,
                                   uniforms: built.uniforms, texture: built.texture,
                                   normalMap: built.normalMap,
                                   heightMap: built.heightMap))
                continue
            }
            // A rig is a SET of sprites, each with its own palette and possibly
            // its own atlas page, so it is several draws that happen to share a
            // layer -- and they stay in the layer's place in the order.
            for sprite in rigGeometry(layer, atFrame: frameIndex,
                                      scene: scene, assets: assets) {
                let start = skinnedVertices.count
                skinnedVertices.append(contentsOf: sprite.vertices)
                let paletteStart = palettes.count
                palettes.append(contentsOf: sprite.palette)
                // PADDED so the next block's byte offset stays aligned. A
                // palette is bound at an offset into one buffer, and
                // `setVertexBuffer` will not take an arbitrary one on every Mac
                // this ships to; 4 matrices is 256 bytes, the strictest of them.
                while palettes.count % Self.paletteAlignmentMatrices != 0 {
                    palettes.append(matrix_identity_float4x4)
                }
                draws.append(.skinned(
                    range: start..<skinnedVertices.count,
                    paletteOffset: paletteStart * MemoryLayout<simd_float4x4>.stride,
                    uniforms: sprite.uniforms, texture: sprite.texture,
                    normalMap: sprite.normalMap))
            }
        }

        let cardBuffer = cardVertices.isEmpty ? nil : cardVertexBuffer(for: cardVertices.count)
        if let cardBuffer {
            cardVertices.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                cardBuffer.contents().copyMemory(from: base, byteCount: raw.count)
            }
        }
        let skinnedBuffer = skinnedVertices.isEmpty ? nil : skinnedVertexBuffer(for: skinnedVertices.count)
        if let skinnedBuffer {
            skinnedVertices.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                skinnedBuffer.contents().copyMemory(from: base, byteCount: raw.count)
            }
        }
        let paletteStore = palettes.isEmpty ? nil : paletteBuffer(for: palettes.count)
        if let paletteStore {
            palettes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                paletteStore.contents().copyMemory(from: base, byteCount: raw.count)
            }
        }

        var boundKind: LayerDraw.Kind?
        for draw in draws {
            var layerUniforms = draw.uniforms
            switch draw {
            case let .card(range, _, texture, normalMap, heightMap):
                guard let cardBuffer else { continue }
                if boundKind != .card {
                    encoder.setRenderPipelineState(cardPipeline)
                    encoder.setVertexBuffer(cardBuffer, offset: 0, index: 0)
                    boundKind = .card
                }
                // THE SAME BYTES TO BOTH STAGES. The vertex shader needs the
                // tangent frame and the fragment shader needs the rest, and
                // splitting them into two structs would be two places for a
                // layer's surface to be described -- which is the drift this
                // file's transcription harness exists to catch. Bound on EVERY
                // draw, because a declared argument that is only sometimes
                // bound is what aborted Metal validation on a scene with no
                // lights.
                encoder.setVertexBytes(&layerUniforms,
                                       length: MemoryLayout<SceneLayerUniforms>.stride,
                                       index: 3)
                encoder.setFragmentBytes(&layerUniforms,
                                         length: MemoryLayout<SceneLayerUniforms>.stride,
                                         index: 1)
                encoder.setFragmentTexture(texture, index: 0)
                // BOUND EVEN WHEN THERE IS NO MAP. Metal's validation layer
                // aborts the process when a draw leaves an argument the
                // function declares unbound, whether or not the shader goes on
                // to read it -- which is exactly how a freshly imported scene
                // used to crash, with `lights` and `curves` declared and bound
                // only when there were lights. The flag in the uniform decides
                // whether it is SAMPLED; this decides whether it is BOUND, and
                // they are not the same question.
                encoder.setFragmentTexture(normalMap ?? placeholderNormalTexture(),
                                           index: 2)
                // THE SAME RULE, ONE SLOT ALONG. The flag decides whether the
                // height field is SAMPLED; this decides whether it is BOUND,
                // and leaving a declared argument unbound is what aborts
                // Metal's validation layer whether or not the shader reads it.
                encoder.setFragmentTexture(heightMap ?? placeholderHeightTexture(),
                                           index: 4)
                encoder.drawPrimitives(type: .triangle,
                                       vertexStart: range.lowerBound,
                                       vertexCount: range.count)

            case let .skinned(range, paletteOffset, _, texture, normalMap):
                guard let skinnedBuffer, let paletteStore else { continue }
                if boundKind != .skinned {
                    encoder.setRenderPipelineState(skinnedPipeline)
                    encoder.setVertexBuffer(skinnedBuffer, offset: 0, index: 0)
                    boundKind = .skinned
                }
                encoder.setVertexBuffer(paletteStore, offset: paletteOffset, index: 2)
                encoder.setVertexBytes(&layerUniforms,
                                       length: MemoryLayout<SceneLayerUniforms>.stride,
                                       index: 3)
                encoder.setFragmentBytes(&layerUniforms,
                                         length: MemoryLayout<SceneLayerUniforms>.stride,
                                         index: 1)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentTexture(normalMap ?? placeholderNormalTexture(),
                                           index: 2)
                // ALWAYS THE PLACEHOLDER. Parallax is a LAYER's material and a
                // rig is many sprites on one layer, so a rig instance never
                // sets the parallax bits -- but the fragment shader is shared,
                // it declares texture(4), and an unbound declared argument
                // aborts validation regardless of which branch runs.
                encoder.setFragmentTexture(placeholderHeightTexture(), index: 4)
                encoder.drawPrimitives(type: .triangle,
                                       vertexStart: range.lowerBound,
                                       vertexCount: range.count)
            }
        }
        encoder.endEncoding()

        encodePass(from: target, into: destination, commandBuffer: commandBuffer)
        // PRESENTED BY THE COMMAND BUFFER, not by the caller afterwards. This
        // function owns the buffer and commits it, so a caller has nowhere to
        // put a `present` that still lands before the commit; presenting from
        // outside would mean `drawable.present()` on the CPU, which shows the
        // frame when this thread gets round to it rather than when the GPU is
        // done with it. Nil for the exporter, which has a texture and no screen.
        if let drawable { commandBuffer.present(drawable) }
        commandBuffer.commit()
    }

    /// One frame, rendered and copied out as premultiplied BGRA8.
    ///
    /// THE SAME `render` THE CANVAS CALLS, into a texture instead of a drawable.
    /// That is the whole point of the move: the canvas and the film no longer
    /// share source code that could drift, they share a result. Before this the
    /// export went through `SceneFrameRenderer.renderImage` — a second
    /// rasteriser, on the CPU, whose agreement with the canvas was a promise
    /// rather than a fact.
    ///
    /// SYNCHRONOUS, which is right here and would be wrong anywhere else: an
    /// export is a batch job that must not hand a half-drawn frame to the
    /// encoder, and it has no display to keep up with.
    ///
    /// `bytesPerRow` IS THE CALLER'S. A `CVPixelBuffer` from a pool is padded to
    /// a stride of its own choosing, which is not `width * 4`, and writing rows
    /// at the wrong pitch shears the picture diagonally — a failure that looks
    /// like a corrupt codec rather than like a stride bug.
    ///
    /// Returns false when there is nothing to copy; the caller drops the frame
    /// rather than encoding whatever the pooled buffer last held.
    func renderForReadback(composition: SceneComposition,
                           atFrame frameIndex: Int,
                           frame: Frame,
                           scene: SceneManager,
                           assets: AssetManager,
                           into destination: UnsafeMutableRawPointer,
                           bytesPerRow: Int) -> Bool {
        let width = frame.pixelSize.x
        let height = frame.pixelSize.y
        guard width > 0, height > 0, bytesPerRow >= width * 4,
              let texture = readbackTexture(width: width, height: height)
        else { return false }

        render(composition: composition, atFrame: frameIndex, frame: frame,
               scene: scene, assets: assets, into: texture)

        guard let finish = commandQueue.makeCommandBuffer() else { return false }
#if os(macOS)
        // A MANAGED texture's CPU-side copy is stale until it is synchronised,
        // and `getBytes` does not do it for you. Without this an export reads
        // whatever the buffer held before — nothing on the first frame, and the
        // PREVIOUS frame on every one after, which reads as a film that is one
        // frame behind rather than as a missing blit.
        if let blit = finish.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
#endif
        // Committed AFTER the render and waited on, which is what makes the
        // read safe: command buffers on one queue execute in the order they
        // were committed, so this one finishing means that one has.
        finish.commit()
        finish.waitUntilCompleted()

        texture.getBytes(destination,
                         bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)
        return true
    }

    /// Linear float target to the 8 bits that leave the renderer.
    ///
    /// The ONLY place anything is clamped, and the only place the canvas and
    /// the export differ — in where the result is put, never in what it is.
    private func encodePass(from source: MTLTexture,
                            into destination: MTLTexture,
                            commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Scene encode"
        encoder.setRenderPipelineState(encodePipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(atlasSampler, index: 0)
        // Three vertices, not four: a full-screen triangle has no seam down
        // the diagonal where two triangles of a quad meet.
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}

// MARK: - Geometry

private extension SceneMetalRenderer {

    /// The standalone texture of a normal map asset, never an atlas page.
    ///
    /// `AssetManager` keeps a standalone `MTLTexture` for every asset beside
    /// its atlas entry, loaded `.SRGB: false` with `.origin: .topLeft` -- which
    /// is exactly what a normal map wants and what sampling it out of the
    /// atlas would have to work around. Sampled with raw `in.uv`, so no rect
    /// arithmetic can put the relief half a sprite to the left.
    func normalTexture(_ assetID: UUID?, assets: AssetManager) -> MTLTexture? {
        guard let assetID else { return nil }
        return assets.asset(for: assetID)?.texture
    }

    /// The standalone texture of the height field, never an atlas page.
    ///
    /// UNATLASED FOR A STRONGER REASON THAN THE NORMAL MAP'S. A normal map
    /// cannot be atlased because a linear sampler BLEEDS a neighbour in at the
    /// tile's edge; a height map cannot because the march deliberately reads
    /// texels far from the fragment's own, so a neighbour packed edge to edge
    /// would not be bled into -- it would be walked into and drawn.
    func heightTexture(_ assetID: UUID?, assets: AssetManager) -> MTLTexture? {
        guard let assetID else { return nil }
        return assets.asset(for: assetID)?.texture
    }

    struct BuiltCard {
        var vertices: [SceneVertexIn]
        var uniforms: SceneLayerUniforms
        var texture: MTLTexture
        /// The standalone texture of the paired normal map, never an atlas
        /// page. Nil when the surface has none, which is when the shader takes
        /// the branch that leaves the picture exactly as it was.
        var normalMap: MTLTexture?
        /// The height field the parallax march walks, if the layer names one
        /// that still resolves. Nil also means "use the normal map's alpha, if
        /// there is a normal map" -- that choice is made once, in
        /// `materialFields`, and shows up here only as a texture or no texture.
        var heightMap: MTLTexture?
    }

    /// A layer's card as two triangles in WORLD space, with the uniforms that
    /// light it.
    ///
    /// World space, and that is what makes navigating free: the camera is a
    /// uniform, so panning and zooming a still scene re-uploads nothing. The
    /// rig canvas uploads screen-space vertices and so rebuilds every mesh on
    /// every camera move, which is the same fault by a different name.
    func cardGeometry(_ layer: SceneLayer,
                      composition: SceneComposition,
                      atFrame frameIndex: Int,
                      scene: SceneManager,
                      assets: AssetManager) -> BuiltCard? {
        let texture: MTLTexture
        let uvRect: SIMD4<Float>
        let half: SIMD2<Float>

        switch layer.content {
        case let .plate(assetID):
            guard let asset = assets.asset(for: assetID),
                  let pageIndex = asset.atlasPageIndex,
                  let rect = asset.atlasUVRect,
                  let page = assets.atlasTexture(pageIndex: pageIndex) else { return nil }
            texture = page
            uvRect = rect
            half = asset.size * 0.5

        case let .fill(fill):
            guard let ramp = fillTexture(fill) else { return nil }
            texture = ramp
            uvRect = SIMD4<Float>(0, 0, 1, 1)
            // A fill has no intrinsic size, so it takes the render's. The CPU
            // path special-cased a frame-filling fill and painted it flat;
            // here it is a card like any other and the shader does not know
            // the difference.
            half = composition.renderSize * 0.5

        case .rig:
            // NOT A CARD, and deliberately not faked as one. A rig instance is a
            // set of skinned meshes with a bone palette each; `rigGeometry`
            // builds them and the caller falls through to it when this returns
            // nil. Returning a card here -- the rig baked to a bitmap, the way
            // the CPU compositor does it -- would put the whole point of the
            // move back on the CPU.
            return nil
        }

        // RESOLVED BEFORE THE CORNERS, because the shell below is sized from
        // the result. A plate's map is the LAYER's: a plate is one PNG, so the
        // layer and the artwork are the same surface; a rig is many, which is
        // why its map hangs off `SceneImage` instead.
        let normalMap = normalTexture(layer.material.normalMapAssetID, assets: assets)
        let heightMap = heightTexture(layer.material.heightMapAssetID, assets: assets)
        let fields = Self.materialFields(layer.material, normalMap: normalMap,
                                         heightMap: heightMap)

        // ── The silhouette shell ────────────────────────────────────────
        //
        // In `.silhouetteShell` the quad is grown by the depth of the height
        // volume and its UVs run past [0, 1] to match, so the parallax march
        // has somewhere to put relief that stands PROUD of where the card's
        // edge was. The shader discards whatever the march does not fill, so
        // the margin costs a band of rejected fragments and buys an outline
        // that is the artwork's rather than the rectangle's.
        //
        // THE EXPANSION LIVES ONLY IN THIS VERTEX BUFFER, and that boundary is
        // the whole of why the mode is safe. It does not reach
        // `SceneViewProjection.cardPoint`'s idea of the card, the picking
        // bounds, the framing, or the `SceneOccluder` this layer contributes to
        // the shadow pass. Growing any of those would let a layer be selected
        // from empty space and cast a shadow larger than itself -- the card IS
        // the size the artist set; the shell is only the volume it may paint in.
        //
        // A MARGIN IN UV, CONVERTED TO LOCAL. `parallaxDepth` is a fraction of
        // the artwork (the march has no other length it can express), so the
        // half-extents scale by it rather than adding a distance.
        //
        // TAKEN FROM `fields`, NOT FROM THE MATERIAL, and that is the bug this
        // line exists to not have. `materialFields` is where "is there really a
        // height field to march against" is decided -- a layer can be set to
        // the shell mode while its map is missing from disk, and asking the
        // material would then grow the quad for a march the shader is not going
        // to run and no clip flag is going to trim. The card would draw a
        // smeared border of clamped edge texels, which looks like a rendering
        // fault and is really a missing file. `fields.parallax.x` is zero
        // unless the march is genuinely on, so the shell follows it.
        // `fields.parallax.x` is zero unless the march is genuinely on, so
        // ANDing the mode with it gives both halves of the question at once:
        // only the shell grows the quad, and only when there is something to
        // march against.
        let margin = layer.material.parallaxMode.expandsCard ? fields.parallax.x : 0
        let outer = half * (1 + 2 * margin)

        // Layer-local corners, in the same winding `SceneViewProjection`
        // already uses so the two cannot disagree about which way a card faces.
        let locals = [
            SIMD2<Float>(-outer.x,  outer.y),
            SIMD2<Float>( outer.x,  outer.y),
            SIMD2<Float>( outer.x, -outer.y),
            SIMD2<Float>(-outer.x, -outer.y),
        ]
        let worlds = locals.map { SceneViewProjection.cardPoint(layer: layer, local: $0) }
        // UV.y = 0 is the image's TOP, which is the corner at local +y. Same
        // convention as the PNG exporter, and the one place a card silently
        // renders upside down if it is taken the other way.
        let lo = -margin
        let hi = 1 + margin
        let uvs: [SIMD2<Float>] = [
            SIMD2<Float>(lo, lo), SIMD2<Float>(hi, lo),
            SIMD2<Float>(hi, hi), SIMD2<Float>(lo, hi),
        ]

        var vertices: [SceneVertexIn] = []
        vertices.reserveCapacity(6)
        for index in [0, 1, 2, 0, 2, 3] {
            vertices.append(SceneVertexIn(world: worlds[index], uv: uvs[index]))
        }

        let plane = layer.lightingPlane
        let frame = layer.lightingTangent
        // PREMULTIPLIED ON THE WAY IN. The atlas holds premultiplied artwork
        // and the blend is premultiplied source-over, so the opacity has to
        // scale colour and alpha together. Scaling alpha alone is the classic
        // way a fading sprite goes bright before it disappears.
        let opacity = layer.opacity
        let uniforms = SceneLayerUniforms(
            uvRect: uvRect,
            tint: SIMD4<Float>(repeating: opacity),
            lightMask: UInt32(layer.lightMask.rawValue),
            receivesLight: layer.receivesLight ? 1 : 0,
            materialFlags: fields.flags,
            shadowedMask: fields.shadowedMask,
            normalAndStrength: SIMD4<Float>(plane.normal, fields.normalStrength),
            tangentAndSign: SIMD4<Float>(frame.tangent, frame.handed),
            material: fields.packed,
            parallax: fields.parallax
        )
        return BuiltCard(vertices: vertices, uniforms: uniforms, texture: texture,
                         normalMap: normalMap, heightMap: heightMap)
    }

    struct BuiltRig {
        var vertices: [SceneSkinnedVertexIn]
        var palette: [simd_float4x4]
        var uniforms: SceneLayerUniforms
        var texture: MTLTexture
        var normalMap: MTLTexture?
    }

    /// The layer's plane-to-world transform, as the one matrix the palette folds.
    ///
    /// SAMPLED FROM THE LAYER'S OWN FUNCTIONS, not restated as a product of
    /// scale, shear and rotation matrices. `planePoint` and `liftToWorld` are
    /// both LINEAR -- each sends (0,0) to the origin -- so the matrix's columns
    /// are exactly their images of the basis vectors, and sampling is exact.
    ///
    /// Restating them is the obvious port and it is wrong in ways a front-on
    /// test scene cannot see: `verify_scene_rig_geometry.py` measures five of
    /// them, and FOUR give an error of exactly zero on a layer at default scale
    /// with no shear, which is every layer until an artist drags one. Sampling
    /// cannot drift from `SceneViewProjection.cardPoint` because it comes from
    /// the same two functions `cardPoint` composes -- and `cardPoint` is what
    /// the canvas, the gizmos and the hit-testing already agree on.
    ///
    /// The z column is the layer's plane NORMAL, from `orientation()`. A card is
    /// flat, so a bind vertex's z is always zero and the column is never read on
    /// this path; taking the normal keeps the matrix a genuine basis and makes
    /// it the same normal the fragment shader lights with, rather than a second
    /// opinion about which way the card faces.
    static func rigToWorld(_ layer: SceneLayer) -> simd_float4x4 {
        let x = layer.liftToWorld(layer.planePoint(SIMD2<Float>(1, 0)))
        let y = layer.liftToWorld(layer.planePoint(SIMD2<Float>(0, 1)))
        let z = layer.orientation().z
        let o = layer.worldOrigin
        var m = MatrixUtilities.identity()
        m.columns.0 = SIMD4<Float>(x, 0)
        m.columns.1 = SIMD4<Float>(y, 0)
        m.columns.2 = SIMD4<Float>(z, 0)
        m.columns.3 = SIMD4<Float>(o, 1)
        return m
    }

    /// A rig instance's sprites, each as skinned triangles with its own palette.
    ///
    /// ONE DRAW PER SPRITE, not one per rig, and that is forced twice over: the
    /// palette folds `spriteToRig`, which differs per sprite, and sprites may
    /// sit on different atlas pages, which is a different texture binding.
    /// Sharing a palette across the rig poses every sprite but the first with
    /// the first one's transform -- 645 units in
    /// `verify_scene_rig_geometry.py`, with sprite zero itself untouched, so a
    /// one-sprite test scene says nothing about it.
    func rigGeometry(_ layer: SceneLayer,
                     atFrame frameIndex: Int,
                     scene: SceneManager,
                     assets: AssetManager) -> [BuiltRig] {
        guard case .rig = layer.content else { return [] }
        let clipDuration = max(scene.playbackEndFrame - scene.playbackStartFrame + 1, 1)
        guard let rigFrame = layer.rigFrame(sceneFrame: frameIndex,
                                            clipDuration: clipDuration) else { return [] }
        let sample = scene.rigPose(atFrame: scene.playbackStartFrame + rigFrame)
        let toWorld = Self.rigToWorld(layer)
        // The skeleton's own order, never a Dictionary's keys: `CLAUDE.md`
        // records that Swift seeds hashing per process, so a slot taken from
        // `worldMatrices.keys` would move between launches of the same project.
        let boneOrder = scene.skeleton.orderedBones.map { $0.id }

        var ordered = scene.renderOrderedImages
        if let order = sample.drawOrder {
            let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            ordered.sort { (position[$0.id] ?? .max) < (position[$1.id] ?? .max) }
        }

        let plane = layer.lightingPlane
        // The layer's frame is the FALLBACK here, not the answer: the skinned
        // vertex shader turns the tangent with the bones and reads its own
        // handedness off the pair the bones produced. This is what it falls
        // back to for a sprite the palette could not move.
        let frame = layer.lightingTangent
        var built: [BuiltRig] = []

        // REVERSED, like the Editor canvas and like `drawRigSprites`: index 0 is
        // the FRONT-most sprite, and a painter's algorithm lays the back down
        // first. Walked forwards, a Scene shows the exact reverse of what the
        // artist arranged in the Editor.
        for image in ordered.reversed() where !image.isHidden {
            guard let asset = assets.asset(for: image.assetID),
                  let pose = sample.imagePoses[image.id],
                  let pageIndex = asset.atlasPageIndex,
                  let uvRect = asset.atlasUVRect,
                  let page = assets.atlasTexture(pageIndex: pageIndex) else { continue }

            // A POSED COPY. `SceneImage` is a value type, so the sampled pose
            // rides the existing mesh pipeline without the scene ever learning
            // the frame was asked about.
            var posed = image
            posed.position = pose.position
            posed.scale = pose.scale
            posed.rotation = pose.rotation
            posed.skew = pose.skew
            posed.meshAnimationDeform = pose.meshDeform

            let mesh = ToolUtilities.resolvedMesh(for: posed, assetSize: asset.size)
            guard !mesh.indices.isEmpty else { continue }

            // The sprite's posed affine, and the bind pose's there-and-back.
            // SHEAR IS AN ANGLE IN DEGREES here, because these go through
            // `shearedAxes` -- `SceneLayer.shear`, folded into `toWorld` above,
            // is a raw slope through `planePoint`. Two fields spelled `shear`,
            // two different transforms.
            let spriteToRig = MatrixUtilities.shearedMatrix(
                position: posed.position,
                rotationDegrees: posed.rotation * 180 / .pi,
                shear: posed.skew, scale: posed.scale)
            // `Mesh.skinnedVertices` uses the stored bind pose, falling back to
            // the sprite's current one for meshes that predate it. Taken the
            // same way here so the two cannot answer differently.
            let bindPose = mesh.bindImagePose ?? scene.meshPose(for: posed)
            guard let worldToBind = MatrixUtilities.shearedMatrixInverse(
                    position: bindPose.position,
                    rotationDegrees: bindPose.rotation * 180 / .pi,
                    shear: bindPose.skew, scale: bindPose.scale) else { continue }
            let bindToWorld = MatrixUtilities.shearedMatrix(
                position: bindPose.position,
                rotationDegrees: bindPose.rotation * 180 / .pi,
                shear: bindPose.skew, scale: bindPose.scale)

            var palette = SceneSkinPalette(
                mesh: mesh, boneOrder: boneOrder,
                worldMatrices: sample.worldMatrices,
                bindToWorld: bindToWorld, worldToBind: worldToBind,
                spriteToRig: spriteToRig, rigToWorld: toWorld)

            // WHICH VERTICES THE SHADER IS FED depends on whether the mesh can
            // be skinned at all, because `skinnedVertices` bails on exactly the
            // same condition and hands back `vertices` -- the DEFORMED ones --
            // rather than bind positions. Feeding bind positions to a mesh it
            // refused to skin would move the sprite by the whole deform.
            //
            // Both cases come out right through slot zero, which is
            // `rigToWorld . spriteToRig . worldToBind . bindToWorld`, and the
            // two inverses cancel: an unweighted vertex lands at
            // `rigToWorld . spriteToRig . v`, which is what the CPU does to it.
            let skinnable = mesh.hasSkinningData()
                && mesh.bindVertices.count == mesh.vertices.count
                && mesh.vertexBoneWeights.count == mesh.vertices.count
            let source = skinnable ? mesh.bindVertices : mesh.vertices

            // Influences ONCE PER VERTEX, then expanded by the index list. A
            // triangle list repeats a shared vertex for every triangle that
            // touches it, so resolving influences per index would redo the same
            // capping and normalising six times over on an interior vertex.
            var perVertex: [SkinnedInfluences] = []
            perVertex.reserveCapacity(source.count)
            for index in source.indices {
                guard skinnable, index < mesh.vertexBoneWeights.count else {
                    perVertex.append(SkinnedInfluences(
                        slots: SIMD4<UInt16>(repeating: SceneSkinPalette.identitySlot),
                        weights: SIMD4<Float>(1, 0, 0, 0)))
                    continue
                }
                perVertex.append(palette.influences(for: mesh.vertexBoneWeights[index]))
            }

            var vertices: [SceneSkinnedVertexIn] = []
            vertices.reserveCapacity(mesh.indices.count)
            for index in mesh.indices {
                let slot = Int(index)
                guard slot < source.count, slot < mesh.uvs.count else { continue }
                let influence = perVertex[slot]
                vertices.append(SceneSkinnedVertexIn(
                    bindLocal: source[slot], uv: mesh.uvs[slot],
                    slots: influence.slots, weights: influence.weights))
            }
            guard !vertices.isEmpty else { continue }

            // The sprite's own tint and alpha, times the layer's opacity, and
            // PREMULTIPLIED -- the atlas holds premultiplied artwork and the
            // blend is premultiplied source-over, so opacity has to scale
            // colour and alpha together.
            let alpha = posed.tintColor.w * layer.opacity
            // THE SPRITE'S OWN MAP, the LAYER'S other material settings. How
            // far light wraps and how sharply it separates describe how this
            // card sits in this set; the relief describes what is painted on
            // one PNG. Giving the whole rig one map would light the face by
            // the arm's bumps.
            let normalMap = normalTexture(posed.normalMapAssetID, assets: assets)
            // PARALLAX IS FORCED OFF HERE, and it is forced rather than merely
            // left unset. The march is a LAYER's material and a rig instance is
            // many sprites sharing one layer, so the layer's height field --
            // which would be the whole rig's -- would displace the face by the
            // arm's relief, the same fault that keeps normal maps per sprite
            // two comments above. The inspector never offers the control for a
            // rig; this is what makes that a guarantee rather than a habit, for
            // a layer whose content changed or whose file was hand-edited.
            var material = layer.material
            material.parallaxMode = .off
            let fields = Self.materialFields(material, normalMap: normalMap,
                                             heightMap: nil)
            let uniforms = SceneLayerUniforms(
                uvRect: uvRect,
                tint: SIMD4<Float>(posed.tintColor.x * alpha,
                                   posed.tintColor.y * alpha,
                                   posed.tintColor.z * alpha,
                                   alpha),
                lightMask: UInt32(layer.lightMask.rawValue),
                receivesLight: layer.receivesLight ? 1 : 0,
                materialFlags: fields.flags,
                shadowedMask: fields.shadowedMask,
                normalAndStrength: SIMD4<Float>(plane.normal, fields.normalStrength),
                tangentAndSign: SIMD4<Float>(frame.tangent, frame.handed),
                material: fields.packed,
                parallax: fields.parallax)

            built.append(BuiltRig(vertices: vertices, palette: palette.matrices,
                                  uniforms: uniforms, texture: page,
                                  normalMap: normalMap))
        }
        return built
    }
}

// MARK: - Shadows

extension SceneMetalRenderer {

    /// Everything that can stand between a light and a surface, this frame.
    ///
    /// ## Why occluders are built separately from the draws
    ///
    /// A card is an occluder for EVERY light in the scene, including lights
    /// that reach other layers entirely; and it occludes surfaces that are
    /// drawn before it as well as after. So the list has to exist whole before
    /// the first draw is encoded, which is the one thing the per-layer geometry
    /// pass cannot give.
    ///
    /// ## What a rig contributes
    ///
    /// One occluder per posed SPRITE, not one for the instance. A character is
    /// a set of limbs at different depths, and a single quad around all of them
    /// casts a shadow shaped like a crate. The quad is the sprite's posed card,
    /// which is EXACT for a rigid sprite and approximate under mesh deform --
    /// the deform moves the artwork inside a rectangle that the pose still
    /// defines, so a heavily deformed sprite's shadow is its undeformed
    /// outline, correctly placed. That is stated rather than hidden because it
    /// is the one visible limit of this approach.
    func occluderGeometry(composition: SceneComposition,
                          atFrame frameIndex: Int,
                          scene: SceneManager,
                          assets: AssetManager) -> [SceneOccluder] {
        var occluders: [SceneOccluder] = []
        for layer in composition.drawOrderedLayers where !layer.isHidden {
            let castMask = layer.material.shadowCastMask
            // EMPTY CASTS NOTHING, which is the default on every layer. A set
            // where everything casts by default is a set that is slow before
            // the artist has asked for anything.
            guard !castMask.isEmpty else { continue }

            switch layer.content {
            case let .plate(assetID):
                guard let asset = assets.asset(for: assetID) else { continue }
                let half = asset.size * 0.5
                let origin = SceneViewProjection.cardPoint(layer: layer, local: .zero)
                let alongX = SceneViewProjection.cardPoint(
                    layer: layer, local: SIMD2<Float>(half.x, 0)) - origin
                let alongY = SceneViewProjection.cardPoint(
                    layer: layer, local: SIMD2<Float>(0, half.y)) - origin
                if let made = makeOccluder(origin: origin, axisU: alongX, axisV: alongY,
                                           normal: layer.lightingPlane.normal,
                                           assetID: assetID, castMask: castMask,
                                           assets: assets) {
                    occluders.append(made)
                }

            case .fill:
                // A FILL IS NOT IN THE SET. It is the sky behind it, painted
                // across the whole frame; casting a shadow from it would put
                // the entire scene in shade.
                continue

            case .rig:
                occluders.append(contentsOf: rigOccluders(layer, atFrame: frameIndex,
                                                          castMask: castMask,
                                                          scene: scene, assets: assets))
            }
        }
        return occluders
    }

    private func rigOccluders(_ layer: SceneLayer, atFrame frameIndex: Int,
                              castMask: SceneLightMask,
                              scene: SceneManager,
                              assets: AssetManager) -> [SceneOccluder] {
        let clipDuration = max(scene.playbackEndFrame - scene.playbackStartFrame + 1, 1)
        guard let rigFrame = layer.rigFrame(sceneFrame: frameIndex,
                                            clipDuration: clipDuration) else { return [] }
        let sample = scene.rigPose(atFrame: scene.playbackStartFrame + rigFrame)
        let toWorld = Self.rigToWorld(layer)
        let normal = layer.lightingPlane.normal

        var made: [SceneOccluder] = []
        for image in scene.renderOrderedImages where !image.isHidden {
            guard let asset = assets.asset(for: image.assetID),
                  let pose = sample.imagePoses[image.id] else { continue }
            // SHEAR IS AN ANGLE IN DEGREES here, because this goes through
            // `shearedMatrix` -- `SceneLayer.shear`, folded into `toWorld`, is
            // a raw slope through `planePoint`. Two fields spelled `shear`, two
            // different transforms; `rigGeometry` carries the same note.
            let spriteToRig = MatrixUtilities.shearedMatrix(
                position: pose.position,
                rotationDegrees: pose.rotation * 180 / .pi,
                shear: pose.skew, scale: pose.scale)
            let toScene = simd_mul(toWorld, spriteToRig)
            let half = asset.size * 0.5
            func placed(_ local: SIMD2<Float>) -> SIMD3<Float> {
                let v = toScene * SIMD4<Float>(local.x, local.y, 0, 1)
                let w = abs(v.w) < 1e-4 ? 1 : v.w
                return SIMD3<Float>(v.x, v.y, v.z) / w
            }
            let origin = placed(.zero)
            if let occluder = makeOccluder(
                origin: origin,
                axisU: placed(SIMD2<Float>(half.x, 0)) - origin,
                axisV: placed(SIMD2<Float>(0, half.y)) - origin,
                normal: normal, assetID: image.assetID,
                castMask: castMask, assets: assets) {
                made.append(occluder)
            }
        }
        return made
    }

    /// One occluder, with its alpha tile resolved.
    ///
    /// Returns nil only for a quad with no area, which cannot occlude anything
    /// and would divide by a zero determinant in the shader.
    private func makeOccluder(origin: SIMD3<Float>,
                              axisU: SIMD3<Float>, axisV: SIMD3<Float>,
                              normal: SIMD3<Float>, assetID: UUID,
                              castMask: SceneLightMask,
                              assets: AssetManager) -> SceneOccluder? {
        let uu = simd_dot(axisU, axisU)
        let vv = simd_dot(axisV, axisV)
        let uv = simd_dot(axisU, axisV)
        guard uu * vv - uv * uv > 1e-9 else { return nil }

        let rect = shadowTileRect(for: assetID, assets: assets)
        return SceneOccluder(
            origin: SIMD4<Float>(origin, 0),
            axisU: SIMD4<Float>(axisU, 0),
            axisV: SIMD4<Float>(axisV, 0),
            normalAndOffset: SIMD4<Float>(normal, simd_dot(normal, origin)),
            uvRect: rect ?? .zero,
            castMask: UInt32(castMask.rawValue),
            // NO TILE MEANS THE RECTANGLE CASTS, not that nothing does. A
            // character whose file has moved should cast a boxy shadow rather
            // than stop casting -- one reads as a limitation, the other reads
            // as the feature being broken.
            useAlpha: rect == nil ? 0 : 1)
    }

    /// Which lights see which occluders, culled once per frame on the CPU.
    ///
    /// SHADOWING IS O(lights x occluders) PER FRAGMENT, so this is where the
    /// cost is actually decided. Most occluders are nowhere near most lights,
    /// and rejecting one here costs a sphere test once instead of a plane
    /// intersection a million times.
    func cullOccluders(_ occluders: [SceneOccluder],
                       for lights: [SceneLighting.PreparedLight])
        -> (flat: [SceneOccluder], ranges: [(start: Int, count: Int)]) {
        var flat: [SceneOccluder] = []
        var ranges: [(start: Int, count: Int)] = []
        for prepared in lights {
            guard prepared.light.castsShadows else {
                ranges.append((0, 0))
                continue
            }
            let start = flat.count
            for occluder in occluders {
                guard prepared.light.mask.reaches(SceneLightMask(rawValue: UInt8(occluder.castMask)))
                else { continue }
                // A directional light has no position and therefore no radius
                // to be outside of.
                if prepared.light.kind != .directional {
                    // THE QUAD'S REACH, not its centre. A backdrop's centre can
                    // sit far outside a lamp while the corner it is meant to
                    // shade sits inside it.
                    let extent = simd_length(SIMD3<Float>(occluder.axisU.x,
                                                          occluder.axisU.y,
                                                          occluder.axisU.z))
                        + simd_length(SIMD3<Float>(occluder.axisV.x,
                                                   occluder.axisV.y,
                                                   occluder.axisV.z))
                    let centre = SIMD3<Float>(occluder.origin.x, occluder.origin.y,
                                              occluder.origin.z)
                    if simd_distance(centre, prepared.origin) > prepared.radius + extent {
                        continue
                    }
                }
                flat.append(occluder)
                // CAPPED PER LIGHT. Past the cap the nearest ones are kept,
                // because a shadow from the sprite in front of the lamp is the
                // one an artist would miss.
                if flat.count - start >= Self.maxOccludersPerLight { break }
            }
            ranges.append((start, flat.count - start))
        }
        return (flat, ranges)
    }

    static let maxOccludersPerLight = 16
}

// MARK: - Resources

private extension SceneMetalRenderer {

    /// The vertex buffer for this frame's slot, grown if it has to be.
    ///
    /// Grown for EVERY slot at once, not just this one: a ring whose members
    /// have different lengths is a ring with a slot that overflows on the
    /// frame it comes round to.
    func cardVertexBuffer(for count: Int) -> MTLBuffer? {
        let needed = MemoryLayout<SceneVertexIn>.stride * count
        if cardVertexCapacity < needed || cardVertexBuffers.contains(where: { $0 == nil }) {
            let aligned = ((needed + 4095) / 4096) * 4096
            cardVertexBuffers = cardVertexBuffers.map { _ in
                device.makeBuffer(length: aligned, options: .storageModeShared)
            }
            cardVertexCapacity = aligned
        }
        return cardVertexBuffers[ringIndex]
    }

    /// The skinned-vertex ring. Separate from the card ring because the two
    /// hold DIFFERENT STRUCTS -- `SceneSkinnedVertexIn` carries four slots and
    /// four weights that a card has no use for -- and packing both into one
    /// buffer would make the stride a lie for one of them.
    func skinnedVertexBuffer(for count: Int) -> MTLBuffer? {
        let needed = MemoryLayout<SceneSkinnedVertexIn>.stride * count
        if skinnedVertexCapacity < needed || skinnedVertexBuffers.contains(where: { $0 == nil }) {
            let aligned = ((needed + 4095) / 4096) * 4096
            skinnedVertexBuffers = skinnedVertexBuffers.map { _ in
                device.makeBuffer(length: aligned, options: .storageModeShared)
            }
            skinnedVertexCapacity = aligned
        }
        return skinnedVertexBuffers[ringIndex]
    }

    /// The bone-palette ring, read by `sceneSkinnedVertex` at buffer index 2.
    func paletteBuffer(for count: Int) -> MTLBuffer? {
        let needed = MemoryLayout<simd_float4x4>.stride * count
        if paletteCapacity < needed || paletteBuffers.contains(where: { $0 == nil }) {
            let aligned = ((needed + 4095) / 4096) * 4096
            paletteBuffers = paletteBuffers.map { _ in
                device.makeBuffer(length: aligned, options: .storageModeShared)
            }
            paletteCapacity = aligned
        }
        return paletteBuffers[ringIndex]
    }

    /// Where this asset's alpha tile lives in the shadow atlas, building it if
    /// this is the first time the asset has cast anything.
    ///
    /// Nil when there is no room left or the alpha could not be read; the
    /// caller then casts the rectangle, which is a worse shadow and not a
    /// missing one.
    func shadowTileRect(for assetID: UUID, assets: AssetManager) -> SIMD4<Float>? {
        let side = Self.shadowTileSide
        let across = Self.shadowAtlasTiles
        func rect(_ slot: Int) -> SIMD4<Float> {
            let column = Float(slot % across), row = Float(slot / across)
            let step = 1 / Float(across)
            // INSET BY HALF A TEXEL on each side. The atlas is sampled with
            // linear filtering, so a uv exactly on a tile's boundary averages
            // in the neighbouring sprite -- which puts a faint ghost of another
            // character's outline around every shadow.
            let inset = 0.5 / Float(across * side)
            return SIMD4<Float>(column * step + inset, row * step + inset,
                                step - 2 * inset, step - 2 * inset)
        }
        if let slot = shadowSlots[assetID] { return rect(slot) }
        guard shadowSlots.count < Self.shadowSlotCount,
              let tile = assets.alphaTile(assetID: assetID, side: side),
              let atlas = shadowAtlasTexture() else { return nil }
        let slot = shadowSlots.count
        let region = MTLRegionMake2D((slot % across) * side, (slot / across) * side,
                                     side, side)
        tile.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            atlas.replace(region: region, mipmapLevel: 0, withBytes: base,
                          bytesPerRow: side)
        }
        shadowSlots[assetID] = slot
        return rect(slot)
    }

    func shadowAtlasTexture() -> MTLTexture? {
        if let existing = shadowAtlas { return existing }
        let size = Self.shadowAtlasTiles * Self.shadowTileSide
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = .shaderRead
        // A FULL BLACK ATLAS, so an unwritten slot occludes NOTHING. Filled
        // with white it would cast an opaque square for any tile that failed to
        // upload, which is the most alarming possible failure mode.
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let blank = [UInt8](repeating: 0, count: size * size)
        blank.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                            withBytes: base, bytesPerRow: size)
        }
        shadowAtlas = texture
        return texture
    }

    /// Binds `occluders` at fragment buffer(3), always.
    func uploadOccluders(_ occluders: [SceneOccluder],
                         into encoder: MTLRenderCommandEncoder) {
        // NO EARLY RETURN, for the reason `uploadLights` gives: a declared
        // argument left unbound aborts Metal's validation whether or not the
        // shader reads it, and a scene with no shadows is the common case.
        guard !occluders.isEmpty else {
            if emptyOccluderBuffer == nil {
                emptyOccluderBuffer = device.makeBuffer(
                    length: MemoryLayout<SceneOccluder>.stride,
                    options: .storageModeShared)
            }
            if let placeholder = emptyOccluderBuffer {
                encoder.setFragmentBuffer(placeholder, offset: 0, index: 3)
            }
            return
        }
        let needed = MemoryLayout<SceneOccluder>.stride * occluders.count
        if occluderCapacity < needed || occluderBuffers.contains(where: { $0 == nil }) {
            let aligned = ((needed + 4095) / 4096) * 4096
            occluderBuffers = occluderBuffers.map { _ in
                device.makeBuffer(length: aligned, options: .storageModeShared)
            }
            occluderCapacity = aligned
        }
        guard let buffer = occluderBuffers[ringIndex] else { return }
        occluders.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: raw.count)
        }
        encoder.setFragmentBuffer(buffer, offset: 0, index: 3)
    }

    func uploadLights(_ lights: [SceneLighting.PreparedLight],
                      occluderRanges: [(start: Int, count: Int)],
                      into encoder: MTLRenderCommandEncoder) {
        // NO EARLY RETURN. `lights` is a declared argument of the fragment
        // function, and Metal validates that it was bound even on a draw whose
        // `lightCount` is zero and which therefore never reads it.
        guard !lights.isEmpty else {
            if emptyLightBuffer == nil {
                emptyLightBuffer = device.makeBuffer(
                    length: MemoryLayout<SceneLightUniform>.stride,
                    options: .storageModeShared)
            }
            if let placeholder = emptyLightBuffer {
                encoder.setFragmentBuffer(placeholder, offset: 0, index: 2)
            }
            return
        }
        var uniforms: [SceneLightUniform] = []
        uniforms.reserveCapacity(lights.count)
        for (index, prepared) in lights.enumerated() {
            var uniform = SceneLightUniform(prepared, falloffRow: curveRow(for: prepared))
            if index < occluderRanges.count {
                let range = occluderRanges[index]
                uniform.setOccluders(start: range.start, count: range.count)
            }
            uniforms.append(uniform)
        }
        let needed = MemoryLayout<SceneLightUniform>.stride * uniforms.count
        if lightCapacity < needed || lightBuffers.contains(where: { $0 == nil }) {
            let aligned = ((needed + 4095) / 4096) * 4096
            lightBuffers = lightBuffers.map { _ in
                device.makeBuffer(length: aligned, options: .storageModeShared)
            }
            lightCapacity = aligned
        }
        guard let buffer = lightBuffers[ringIndex] else { return }
        uniforms.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: raw.count)
        }
        encoder.setFragmentBuffer(buffer, offset: 0, index: 2)
    }

    func accumulationTexture(width: Int, height: Int) -> MTLTexture? {
        if let existing = accumulation, existing.width == width, existing.height == height {
            return existing
        }
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.accumulationFormat,
            width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        accumulation = device.makeTexture(descriptor: descriptor)
        return accumulation
    }

    /// The export's own 8-bit target, which the CPU is allowed to read.
    ///
    /// NOT `.private`, which is what every other texture here is. A private
    /// texture lives only on the GPU and `getBytes` cannot see it; the export
    /// is the one place the CPU has to read a result back, so this one is
    /// managed on macOS — where a discrete GPU keeps its own copy that has to
    /// be synchronised — and shared everywhere else.
    func readbackTexture(width: Int, height: Int) -> MTLTexture? {
        if let existing = readback, existing.width == width, existing.height == height {
            return existing
        }
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
#if os(macOS)
        descriptor.storageMode = .managed
#else
        descriptor.storageMode = .shared
#endif
        readback = device.makeTexture(descriptor: descriptor)
        return readback
    }

    /// A 1x1 stand-in for the curve texture, for a scene with no lights.
    ///
    /// Never sampled — `lightCount` is zero on those draws — but bound, because
    /// a declared texture argument that was never bound is a validation abort,
    /// not a silently ignored one.
    func placeholderCurveTexture() -> MTLTexture? {
        if let existing = emptyCurveTexture { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var one: Float = 1
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: &one, bytesPerRow: MemoryLayout<Float>.stride)
        emptyCurveTexture = texture
        return texture
    }

    /// A 1x1 flat normal, so `texture(2)` is bound on every single draw.
    ///
    /// LAVENDER AND NOT BLACK. It is never sampled -- the flag keeps the
    /// shader out of that branch entirely -- but a placeholder whose value is
    /// nonsense is a placeholder that turns a future missing-flag bug into a
    /// black sprite rather than a flat-lit one. (0.5, 0.5, 1) decodes to the
    /// surface's own normal, which is the honest stand-in for "no relief".
    func placeholderNormalTexture() -> MTLTexture? {
        if let existing = emptyNormalTexture { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var flat: [UInt8] = [128, 128, 255, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: &flat, bytesPerRow: 4)
        emptyNormalTexture = texture
        return texture
    }

    /// The stand-in bound at texture(4) when a surface has no height field.
    ///
    /// WHITE, AND NOT BLACK. A height of 1 puts the surface at the very TOP of
    /// the volume, so the march's first test passes at the fragment's own texel
    /// and the displacement is exactly zero. Black would put it at the floor,
    /// and a future missing-flag bug would then displace the whole card by its
    /// full depth -- a sprite visibly sliding off itself. The same reasoning
    /// that makes the normal placeholder lavender rather than black: a
    /// placeholder that is never read should still be the honest value, so that
    /// the day it IS read the fault looks like nothing instead of like chaos.
    func placeholderHeightTexture() -> MTLTexture? {
        if let existing = emptyHeightTexture { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var top: [UInt8] = [255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: &top, bytesPerRow: 1)
        emptyHeightTexture = texture
        return texture
    }

    /// Bit 0 of `SceneLayerUniforms.materialFlags`, spelled once.
    ///
    /// The Metal side calls it `kSceneHasNormalMap`; the transcription harness
    /// checks the two agree, the way it already checks every field of every
    /// struct these two languages describe twice.
    static let hasNormalMapFlag: UInt32 = 1
    /// Bits 1 to 5 of `materialFlags`, the Swift half of the `kScene*`
    /// constants in `SceneShaders.metal`. One name per bit on each side, so
    /// the two files can be read off against each other rather than counted.
    static let hasHeightMapFlag: UInt32 = 2
    static let heightFromNormalAlphaFlag: UInt32 = 4
    static let parallaxClipFlag: UInt32 = 8
    static let parallaxSelfShadowFlag: UInt32 = 16
    static let heightInvertedFlag: UInt32 = 32

    /// The loop bound the shader compiles against, spelled here so the uniform
    /// can never exceed it. `kSceneMaxParallaxSteps` is the same number.
    static let maxParallaxSteps: Float = 128
    static let maxParallaxShadowSteps: Float = 32

    /// What one Quality knob buys, in steps.
    ///
    /// TWO NUMBERS FROM ONE, because the march wants a floor and a ceiling and
    /// interpolates between them by view angle, while an artist wants to know
    /// whether this surface is worth the milliseconds. The floor is what a
    /// head-on fragment costs and the ceiling what a grazing one does, which is
    /// why the ceiling climbs so much further: the sweep across the artwork
    /// grows with the angle and the sample count has to follow it.
    static func parallaxSteps(quality: Float) -> (min: Float, max: Float) {
        let q = min(max(quality, 0), 1)
        return (min: 4 + 12 * q, max: 16 + (maxParallaxSteps - 16) * q)
    }

    /// The material half of a layer's uniforms, built in ONE place.
    ///
    /// Both `cardGeometry` and `rigGeometry` fill a `SceneLayerUniforms`, and
    /// the promise that a surface with no normal map renders bit for bit as it
    /// did rests entirely on the flag being clear. Deciding that twice is how
    /// one of the two paths ends up setting it on a sprite whose map failed to
    /// load -- the shader then samples a lavender 1x1, normalises, and moves
    /// every pixel of that sprite by a rounding error nobody can account for.
    ///
    /// THE FLAG FOLLOWS THE TEXTURE, NOT THE ASSET ID. An id that resolves to
    /// nothing is a surface with no map, which is exactly what a project whose
    /// normal map was deleted on disk should draw.
    /// THE SAME RULE GOVERNS THE PARALLAX BITS. A height map named by a layer
    /// whose file has since been deleted is a surface with no height field, so
    /// the bits stay clear and the card draws flat -- which is what a project
    /// whose map went missing should render, and is why the decision is made
    /// from the TEXTURE rather than from `parallaxMode` or an asset id.
    ///
    /// The alpha fallback is chosen here and nowhere else: with no height
    /// texture but a normal map bound, the height comes from that map's alpha.
    /// The two source bits are mutually exclusive by construction, which is
    /// what lets `sceneHeightAt` read one texture or the other with no third
    /// case for "both" that could only ever mean one of them.
    static func materialFields(_ material: SceneMaterial,
                               normalMap: MTLTexture?,
                               heightMap: MTLTexture?)
        -> (flags: UInt32, normalStrength: Float, shadowedMask: UInt32,
            packed: SIMD4<Float>, parallax: SIMD4<Float>) {
        let clean = material.sanitized
        var flags: UInt32 = normalMap == nil ? 0 : hasNormalMapFlag

        // A march needs somewhere to march: a dedicated map, or a normal map
        // whose alpha stands in for one.
        let heightSource: UInt32?
        if heightMap != nil {
            heightSource = hasHeightMapFlag
        } else if normalMap != nil {
            heightSource = heightFromNormalAlphaFlag
        } else {
            heightSource = nil
        }

        var parallax = SIMD4<Float>.zero
        var occlusionStrength: Float = 0
        if clean.parallaxMode != .off, let heightSource {
            flags |= heightSource
            if clean.heightInverted { flags |= heightInvertedFlag }
            if clean.parallaxMode.clips { flags |= parallaxClipFlag }
            let steps = parallaxSteps(quality: clean.parallaxQuality)
            if clean.parallaxSelfShadow { flags |= parallaxSelfShadowFlag }
            // A quarter of the view march, capped: the self-shadow answers yes
            // or no rather than where, so it does not need the resolution the
            // surface does, and it runs once PER LIGHT rather than once per
            // fragment. Spending the view march's budget again on every lamp
            // is how a two-light scene costs three times what it looks like.
            let shadowSteps = clean.parallaxSelfShadow
                ? min(max(steps.max * 0.25, 4), maxParallaxShadowSteps)
                : 0
            parallax = SIMD4<Float>(clean.parallaxDepth, steps.min, steps.max, shadowSteps)
            occlusionStrength = clean.parallaxOcclusionStrength
        }

        return (flags,
                normalMap == nil ? 0 : clean.normalStrength,
                UInt32(clean.shadowedMask.rawValue),
                SIMD4<Float>(clean.smoothness, clean.contrast, occlusionStrength, 0),
                parallax)
    }

    /// Which row of the curve texture holds this light's falloff.
    ///
    /// A pure lookup into the row list `prepareCurves` has already settled.
    /// It used to be able to append a row and invalidate the texture, which
    /// could not fire — the texture is built first — and would have cleared
    /// the texture out from under the frame if it ever had.
    func curveRow(for prepared: SceneLighting.PreparedLight) -> Int {
        curveRows.firstIndex(of: prepared.light.falloff) ?? 0
    }

    /// One row per distinct falloff, REBUILT ONLY WHEN THE SET CHANGES.
    ///
    /// It used to make a texture and upload every row on every frame. A curve
    /// does not change while the scene plays, so that was an allocation and
    /// 256 floats per light per frame to arrive at the bytes already there —
    /// the same per-frame allocation the CPU compositor had just been cured of.
    ///
    /// Walked in FIRST-APPEARANCE ORDER, never through a Set: `CLAUDE.md`
    /// records that Swift seeds a Set's hashing per process, so a row index
    /// taken from one would put a different curve under a light between
    /// launches of the same project.
    func prepareCurves(for lights: [SceneLighting.PreparedLight]) -> MTLTexture? {
        var rows: [LightFalloffCurve] = []
        for prepared in lights where !rows.contains(prepared.light.falloff) {
            rows.append(prepared.light.falloff)
        }
        guard !rows.isEmpty else { return nil }
        if rows == curveRows, let existing = curveTexture { return existing }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: Self.curveEntries, height: rows.count, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        for (row, curve) in rows.enumerated() {
            // `LightFalloffCurve.table` is the one place a curve is tabulated,
            // shared with the CPU path so the two cannot describe the same
            // curve differently.
            var values = curve.table(entries: Self.curveEntries)
            texture.replace(
                region: MTLRegionMake2D(0, row, Self.curveEntries, 1),
                mipmapLevel: 0,
                withBytes: &values,
                bytesPerRow: MemoryLayout<Float>.stride * Self.curveEntries)
        }
        curveRows = rows
        curveTexture = texture
        return texture
    }

    /// A two-stop vertical ramp as a 1×2 texture.
    ///
    /// Linear filtering over two texels IS a two-stop linear ramp, exactly —
    /// so the gradient needs no branch in the shader and no vertex colour, and
    /// a flat fill is the case where the two stops happen to match.
    func fillTexture(_ fill: SceneFill) -> MTLTexture? {
        let key = FillKey(fill)
        if let existing = fillTextures[key] { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 1, height: 2, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        // PREMULTIPLIED, because that is what the blend expects and what the
        // atlas holds. A ramp written straight would composite as if its
        // transparent stop were opaque.
        func premultiplied(_ c: SIMD4<Float>) -> [Float16] {
            [Float16(c.x * c.w), Float16(c.y * c.w), Float16(c.z * c.w), Float16(c.w)]
        }
        // Row 0 is the TOP of the card, matching UV.y = 0.
        var rows = premultiplied(fill.topColor) + premultiplied(fill.bottomColor)
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 2), mipmapLevel: 0,
                        withBytes: &rows, bytesPerRow: MemoryLayout<Float16>.stride * 4)
        fillTextures[key] = texture
        return texture
    }
}
