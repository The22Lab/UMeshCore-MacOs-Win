import CoreGraphics
import CoreImage
import Metal
import QuartzCore
import Foundation
import simd

/// Draws a Scene — layers at depths, seen through a camera — into a CGImage.
///
/// ONE renderer, used by the Scene canvas and by every Scene export. The rig
/// side of the editor grew a Metal canvas and a separate CoreGraphics exporter,
/// and the two already disagree about 3D-rotated sprites; a Scene is composed
/// on one surface and delivered from another, so it does not get two
/// implementations to begin with. What the artist previews IS the render.
///
/// CPU CoreGraphics rather than Metal, deliberately: the PNG exporter already
/// proved the triangle-affine technique renders the full rig correctly, the
/// export path needs a CGImage anyway, and a Scene is a handful of flat cards —
/// the per-frame cost is the same one the PNG exporter already pays.
///
/// TWO PICTURES, ONE SET OF CARDS. `renderImage` is the SHOT — through
/// `SceneProjection`, the export's model, untouched. `renderEditorView` is the
/// set seen from wherever the artist is standing — through
/// `SceneViewProjection`, a real camera, never exported. Both draw the same
/// layers through the same triangle code; only the function that turns a
/// card's point into a pixel differs, and it is passed in rather than chosen
/// inside, so neither picture can grow a second copy of "how a card is drawn".
@MainActor
final class SceneFrameRenderer {

    /// A tilted card used to be cut into this many patches per side and each
    /// one filled affinely. It is not any more — `drawCard` applies a
    /// homography instead — and the constant is kept only because it is the
    /// number the seam measurements in `verify_scene_render.py` were taken
    /// against, and because deleting the reason a technique was abandoned is
    /// how it comes back.
    ///
    /// The measurements said 24×24 keeps the worst warp under 1 % of a card's
    /// span at 60°. What they did not say, and what was found later, is that a
    /// backdrop-sized card is already 77 px from affine at TEN degrees — so the
    /// grid was never a middle ground, only its own maximum, and the fly view
    /// paid 1 152 clipped draws per card to approximate something a GPU maps
    /// exactly in one.
    static let retiredTiltSubdivisions = 24

    /// A bitmap, and WHERE IN THE FRAME it is.
    ///
    /// ## The bug this type exists to make impossible
    ///
    /// Three drawing paths — `drawStraddlingCard`, `drawProjectiveCard` and the
    /// fill's fallback — used to work out "the canvas" as
    /// `CGRect(0, 0, ctx.width, ctx.height)` and intersect the card's projected
    /// box with it, to bound the Core Image render. That is correct exactly
    /// while the context IS the frame, because the card's corners come from the
    /// `CardMapper`, which speaks FRAME coordinates.
    ///
    /// Lighting broke it, and broke it invisibly. A lit layer is drawn into a
    /// scratch bitmap that is a WINDOW on the frame, positioned by the
    /// context's transform — so that rectangle was the window's size placed at
    /// the window's own origin, while the card's box was still in frame
    /// coordinates. For any layer not touching the frame's bottom-left corner
    /// the intersection came out EMPTY and the path returned without drawing.
    /// Switch on Receive Light and the sprite vanishes.
    ///
    /// The trigger was not the zoom it was reported with. A front-parallel card
    /// projects affinely at ANY distance or lateral offset — measured at
    /// 0.000 px of deviation — so it took `drawAffineCard`, which uses only the
    /// transform and was unaffected. Two degrees of camera pitch put the
    /// deviation at 15 px, past the half-pixel tolerance, and the card moved to
    /// the projective path and disappeared. In the fly view, where the artist
    /// is orbiting, that is the normal state; in the front view it took getting
    /// close enough to cut the near plane, which is the straddling path and has
    /// the same fault.
    ///
    /// So: a drawing path may not ask a context how big it is. It asks the
    /// TARGET where it is, and gets an answer in the one coordinate system
    /// every other number in this file is already expressed in.
    struct RenderTarget {
        let context: CGContext
        /// The frame's full pixel size — what "the canvas" means, whatever this
        /// particular bitmap happens to be.
        let frameWidth: Int
        let frameHeight: Int
        /// Where this bitmap sits in the frame, CG convention: y up from the
        /// bottom of the FRAME.
        let originX: Int
        let originY: Int

        /// The whole frame, in CG coordinates. What every draw clips to.
        ///
        /// The FRAME and not this bitmap's own rectangle, deliberately. A
        /// bitmap clips to itself anyway — it has no pixels outside — so
        /// clipping to it a second time buys nothing and costs the guarantee
        /// that matters: a lit layer and an unlit one are handed the same
        /// rectangle, so they cannot draw differently. Turning Receive Light on
        /// changes how a layer is shaded and nothing whatever about where it
        /// lands.
        var canvas: CGRect {
            CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        }

        /// The full frame as its own target.
        static func frame(_ context: CGContext) -> RenderTarget {
            RenderTarget(context: context,
                         frameWidth: context.width, frameHeight: context.height,
                         originX: 0, originY: 0)
        }
    }

    /// Layer-local point (x right, y up, centred on the layer) to a CG pixel
    /// (y up from the bottom), or nil when it cannot be seen. Everything that
    /// draws a card goes through one of these.
    typealias LayerMap = (SIMD2<Float>) -> CGPoint?

    /// Layer-local points, the world they land in, and the eye that sees them.
    ///
    /// This exists because a `LayerMap` alone cannot fix the near plane. It
    /// hands back a point that is already projected, so by the time a drawing
    /// path sees a nil the world position that produced it is gone — and
    /// without that, the only thing left to do with a card that straddles the
    /// near plane is throw it away, which is precisely the bug. Keeping the
    /// world map alongside the projection lets the polygon be CUT to the plane
    /// instead.
    ///
    /// The single-point `point(_:)` is unchanged for the callers that want one
    /// answer about one point — a gizmo origin, a density probe.
    struct CardMapper {
        /// Layer-local to world. `SceneViewProjection.cardPoint` for both eyes:
        /// the shot and the fly view differ in the camera, not in where the
        /// card is.
        let world: (SIMD2<Float>) -> SIMD3<Float>
        let projection: SceneProjection
        /// Context height, for the flip into CGContext's y-up space.
        let height: Int

        /// One point, y up for CGContext. Nil at or behind the near plane.
        func point(_ local: SIMD2<Float>) -> CGPoint? {
            guard let screen = projection.project(world(local)) else { return nil }
            return CGPoint(x: CGFloat(screen.x), y: CGFloat(Float(height) - screen.y))
        }

        var map: LayerMap { { self.point($0) } }

        /// The polygon these local points bound, cut to the near plane, in
        /// SCREEN pixels with y down — the projection's own convention.
        ///
        /// Empty only when none of it is in front of the eye, which is the one
        /// case where drawing nothing is the right answer.
        func clippedScreen(_ locals: [SIMD2<Float>]) -> [SceneProjection.ProjectedVertex] {
            projection.clipAndProject(locals.map {
                SceneProjection.AttributedVertex(world: world($0), attribute: $0)
            })
        }

        /// The same polygon in CGContext's space, y up from the bottom.
        func clipped(_ locals: [SIMD2<Float>]) -> [(point: CGPoint, local: SIMD2<Float>)] {
            clippedScreen(locals).map {
                (point: CGPoint(x: CGFloat($0.screen.x),
                                y: CGFloat(Float(height) - $0.screen.y)),
                 local: $0.attribute)
            }
        }

        /// Whether the cut would change anything. False is the ordinary case.
        func isWhollyVisible(_ locals: [SIMD2<Float>]) -> Bool {
            projection.isWhollyVisible(locals.map(world))
        }

        /// The card's four corners as the quad that carries its texture, even
        /// when some are behind the eye. Nil only for the genuine degeneracy.
        func quad(_ locals: [SIMD2<Float>]) -> [CGPoint]? {
            guard let screen = projection.projectiveQuad(locals.map(world)) else { return nil }
            return screen.map { CGPoint(x: CGFloat($0.x), y: CGFloat(Float(height) - $0.y)) }
        }
    }

    /// How exact a frame has to be.
    ///
    /// `.final` is the deliverable: every sprite of every rig instance drawn
    /// through its own triangles, straight into the frame, resampled once.
    /// `.interactive` is the canvas, where the artist is orbiting and each
    /// frame has to be ready before the next touch: a rig instance is baked
    /// once into a card and that card is drawn, so moving the camera stops
    /// costing the rig's whole triangle count.
    ///
    /// The bake resamples a second time. That is a real difference, and it is
    /// why the export never asks for it — the preview may approximate, the file
    /// may not.
    enum Quality {
        case interactive
        case final
    }

    /// Everything a rendered frame depends on.
    ///
    /// The canvas used to rasterise inside SwiftUI's `body`, and `SceneManager`
    /// publishes constantly — the playhead, a hover, a selection — so a Scene
    /// with content in it redrew every card on changes that could not alter a
    /// single pixel. A frame is now a function of this, and it is drawn when
    /// this changes.
    ///
    /// `rigStateToken` is in here because a rig instance's picture depends on
    /// the RIG, which is not part of the composition: keyed on the composition
    /// alone, moving a bone left the Scene showing the rig as it used to be.
    ///
    /// Equatable rather than Hashable: there is one live frame per kind, so the
    /// cache is a comparison against the last one and `SceneComposition` never
    /// has to learn to hash itself.
    private struct RenderKey: Equatable {
        var frame: Int
        var pixelSize: SIMD2<Float>
        var rigStateToken: UInt64
        var quality: Quality
        var composition: SceneComposition
        var shotCamera: SceneCamera?
        var viewCamera: SceneViewCamera?
        /// The lights AS SAMPLED at this frame.
        ///
        /// The sampled ones, not the composition's authored list — which the
        /// key already carries inside `composition` and which does not change
        /// when the playhead moves. The camera is here on the same footing, as
        /// `shotCamera`: a cache key has to hold what was drawn, and an
        /// animated light that the key could not see would serve the previous
        /// frame's picture for the whole of a move.
        var lights: [SceneLight]
    }

    private enum RenderKind: Hashable { case shot, editor, export }

    private var frameCache: [RenderKind: (key: RenderKey, image: CGImage)] = [:]

    private weak var scene: SceneManager?
    private weak var assets: AssetManager?
    private let store = CGAssetImageStore()

    init(scene: SceneManager, assets: AssetManager) {
        self.scene = scene
        self.assets = assets
    }

    // MARK: - The shot

    /// Render `composition` at `frame`, seen through `camera`, at `pixelSize`.
    ///
    /// The camera is a parameter rather than read off the composition so the
    /// SAME function serves both viewpoints: the canvas passes the fly camera
    /// while the artist is walking the set, the export always passes the shot.
    /// `quality` defaults to `.final` so a caller that does not think about it
    /// gets the exact picture. The corner preview is the one caller that asks
    /// for `.interactive`: it is 320px of reassurance about the framing, and it
    /// re-renders on every frame of playback.
    func renderImage(
        composition: SceneComposition,
        atFrame frame: Int,
        through camera: SceneCamera,
        pixelSize: SIMD2<Float>? = nil,
        quality: Quality = .final
    ) -> CGImage? {
        let size = pixelSize ?? composition.renderSize
        let lights = scene?.sceneLights(for: composition, atFrame: frame) ?? []
        let key = RenderKey(frame: frame, pixelSize: size,
                            rigStateToken: scene?.rigStateToken ?? 0,
                            quality: quality, composition: composition,
                            shotCamera: camera, viewCamera: nil, lights: lights)
        // The camera PREVIEW in the corner of the fly view comes through here,
        // and the shot camera does not move when the fly camera does — so
        // without this the artist paid for a second full frame, identical to
        // the last one, on every step of an orbit.
        if let cached = frameCache[.export], cached.key == key { return cached.image }

        guard let ctx = makeContext(size) else { return nil }
        drawShot(composition, atFrame: frame, through: camera, into: ctx,
                 quality: quality,
                 lighting: SceneLighting(lights: lights, ambient: composition.ambient))
        guard let image = ctx.makeImage() else { return nil }
        frameCache[.export] = (key, image)
        return image
    }

    /// The shot, with the cards outlined and the selection marked — what the
    /// canvas shows front-on. A separate entry point so the export, which calls
    /// `renderImage`, can never pick up a handle.
    func renderShotView(
        composition: SceneComposition,
        atFrame frame: Int,
        through camera: SceneCamera,
        pixelSize: SIMD2<Float>
    ) -> CGImage? {
        let lights = scene?.sceneLights(for: composition, atFrame: frame) ?? []
        let key = RenderKey(frame: frame, pixelSize: pixelSize,
                            rigStateToken: scene?.rigStateToken ?? 0,
                            quality: .interactive, composition: composition,
                            shotCamera: camera, viewCamera: nil, lights: lights)
        if let cached = frameCache[.shot], cached.key == key { return cached.image }

        guard let ctx = makeContext(pixelSize) else { return nil }
        let began = CACurrentMediaTime()
        drawShot(composition, atFrame: frame, through: camera, into: ctx,
                 quality: .interactive,
                 lighting: SceneLighting(lights: lights, ambient: composition.ambient))
        lastDrawMilliseconds = (CACurrentMediaTime() - began) * 1000
        guard let image = ctx.makeImage() else { return nil }
        frameCache[.shot] = (key, image)
        return image
    }

    private func drawShot(
        _ composition: SceneComposition,
        atFrame frame: Int,
        through camera: SceneCamera,
        into ctx: CGContext,
        quality: Quality,
        lighting: SceneLighting
    ) {
        guard let scene, let assets else { return }
        let target = RenderTarget.frame(ctx)
        let viewSize = SIMD2<Float>(Float(target.frameWidth), Float(target.frameHeight))
        let projection = SceneProjection(camera: camera, viewSize: viewSize)
        let frustum = SceneFrustum(viewProjection: projection.viewProjection)

        fill(composition.background, in: target, opacity: 1)

        // `lighting` arrives already sampled at this frame, from the same call
        // that built the cache key. Sampling it again here would be a second
        // answer to "what are the lights doing", and the key would be pinning
        // the other one.
        for layer in composition.visibleLayers {
            // CULLED BEFORE ANYTHING ELSE, and from world geometry only. The
            // footprint knows nothing about lights, so switching Receive Light
            // on cannot change whether a layer is drawn — only how it is
            // shaded.
            guard let footprint = layerFootprint(
                layer, composition: composition, atFrame: frame,
                projection: projection, frustum: frustum, fillsFrame: true,
                frameWidth: target.frameWidth, frameHeight: target.frameHeight)
            else { continue }
            drawLayer(layer, composition: composition, atFrame: frame,
                      projection: projection, footprint: footprint, lighting: lighting,
                      fillsFrame: true, scene: scene, assets: assets,
                      target: target, quality: quality)
        }
    }

    // MARK: - One layer: is it visible, where is it, and is it lit

    /// Where a layer is, answered once per layer per frame.
    ///
    /// ONE answer, shared by everything that asks. Culling asks it, the
    /// lighting window asks it, picking and the selection outline ask it. Four
    /// callers with four ideas of where a layer is, is four chances for the
    /// handles to sit beside the card — which this file has already been
    /// through once.
    struct LayerFootprint {
        /// Its four corners in world space. A layer is flat, so these are the
        /// exact convex hull of everything it can draw, which is what makes the
        /// frustum test sound rather than approximate.
        let worldCorners: [SIMD3<Float>]
        /// Its outline on screen after the near and far cuts, y DOWN. Three to
        /// five points: a card the near plane cuts is a triangle or a pentagon.
        let screenPolygon: [SIMD2<Float>]
        /// The pixels of the frame it can touch.
        let region: FrameRegion
    }

    /// The camera, WHOLE, as something hashable.
    ///
    /// The whole view matrix rather than the eye and a forward vector. Two
    /// cameras at one place looking one way can still differ by roll, and a key
    /// that cannot tell them apart would hand the fly view the shot's
    /// footprints — the two do render in the same frame, at the same pixel
    /// size, for the same layers.
    private struct CameraKey: Hashable {
        let view0: SIMD4<Float>
        let view1: SIMD4<Float>
        let view2: SIMD4<Float>
        let view3: SIMD4<Float>
        let focal: Float
        let nearZ: Float
        let viewSize: SIMD2<Float>

        init(_ projection: SceneProjection) {
            view0 = projection.viewMatrix.columns.0
            view1 = projection.viewMatrix.columns.1
            view2 = projection.viewMatrix.columns.2
            view3 = projection.viewMatrix.columns.3
            focal = projection.focalLength
            nearZ = projection.nearZ
            viewSize = projection.viewSize
        }
    }

    private struct FootprintKey: Hashable {
        let layerID: UUID
        let frame: Int
        let rigStateToken: UInt64
        let fillsFrame: Bool
        let camera: CameraKey
    }

    /// Where each layer is, for this frame.
    ///
    /// Four things ask per layer per frame — the cull, the draw, the lighting
    /// window, and the quads picking and the outline are built from — and for a
    /// rig the answer now costs a pass over its skinned vertices. Computing it
    /// once is what keeps this change from being slower than what it replaces;
    /// the key is exact, so nothing here can go stale.
    private var footprintCache: [FootprintKey: LayerFootprint?] = [:]
    /// A frame asks for at most one entry per layer per eye, so this is several
    /// frames' worth. Dropped wholesale rather than aged: the entries a new
    /// camera position makes are all new, so an LRU would be bookkeeping for a
    /// set that turns over completely anyway.
    static let footprintCacheLimit = 512

    /// How far a resample can spill past the geometry it is reading.
    ///
    /// This covers RESAMPLING and nothing else. It is not a margin for an
    /// uncertain bound: every bound here is exact by construction — a layer is
    /// flat, so its four projected corners are the true hull of everything it
    /// draws, and a rig's box now follows the skinned, deformed vertices the
    /// drawing actually sends to its triangles.
    ///
    /// Why it can be small, and where the argument stops. A perspective
    /// transform reconstructs its source through a kernel a few TEXELS wide.
    /// Minified, that is sub-pixel in the destination. Magnified enough for it
    /// to matter, the card is already larger than the frame and the region is
    /// clamped to the frame, where the padding does nothing. So it only has to
    /// cover a kernel at roughly 1:1, which is a few pixels.
    ///
    /// The one number in this file that was not measured. Core Image does not
    /// exist in the container these harnesses run in, so the exact reach of
    /// `CIPerspectiveTransform`'s kernel is the thing to check on the Mac: if a
    /// lit card ever shows a hairline its unlit twin does not, this is the
    /// constant, and the fix is to raise it rather than to suspect the bounds.
    static let resamplePaddingPx: Float = 4

    func layerFootprint(
        _ layer: SceneLayer,
        composition: SceneComposition,
        atFrame frame: Int,
        projection: SceneProjection,
        frustum: SceneFrustum,
        fillsFrame: Bool,
        frameWidth: Int,
        frameHeight: Int
    ) -> LayerFootprint? {
        let key = FootprintKey(
            layerID: layer.id, frame: frame,
            rigStateToken: scene?.rigStateToken ?? 0,
            fillsFrame: fillsFrame,
            camera: CameraKey(projection))
        if let cached = footprintCache[key] { return cached }
        let computed = computeFootprint(layer, composition: composition, atFrame: frame,
                                        projection: projection, frustum: frustum,
                                        fillsFrame: fillsFrame,
                                        frameWidth: frameWidth, frameHeight: frameHeight)
        if footprintCache.count >= Self.footprintCacheLimit {
            footprintCache.removeAll(keepingCapacity: true)
        }
        footprintCache[key] = computed
        return computed
    }

    private func computeFootprint(
        _ layer: SceneLayer,
        composition: SceneComposition,
        atFrame frame: Int,
        projection: SceneProjection,
        frustum: SceneFrustum,
        fillsFrame: Bool,
        frameWidth: Int,
        frameHeight: Int
    ) -> LayerFootprint? {
        guard let rect = cardLocalRect(layer, composition: composition, frame: frame)
        else { return nil }
        let locals = Self.cardLocals(rect)
        let worlds = locals.map { SceneViewProjection.cardPoint(layer: layer, local: $0) }

        // CULLED FIRST, and on world geometry alone. Not on anything the
        // lighting knows, not on anything the screen projection produced —
        // so whether a layer is drawn cannot depend on whether it is lit.
        guard !frustum.culls(worlds) else { return nil }

        // A fill in the shot paints the whole frame at its own depth, so its
        // region is the frame however its card projects.
        if fillsFrame && layer.content.isFill {
            return LayerFootprint(worldCorners: worlds, screenPolygon: [],
                                  region: .whole(width: frameWidth, height: frameHeight))
        }

        let mapper = CardMapper(
            world: { SceneViewProjection.cardPoint(layer: layer, local: $0) },
            projection: projection, height: 0)
        let screen = mapper.clippedScreen(locals).map(\.screen)
        // Three or more, not exactly four: a card the near plane cuts is a
        // triangle or a pentagon on screen, and it is still there to be drawn,
        // picked and outlined.
        guard screen.count >= 3 else { return nil }
        let region = FrameRegion.bounding(screen, pad: Self.resamplePaddingPx,
                                          frameWidth: frameWidth, frameHeight: frameHeight)
        guard !region.isEmpty else { return nil }
        return LayerFootprint(worldCorners: worlds, screenPolygon: screen, region: region)
    }

    /// Draw one layer, through the lighting if any of it reaches this layer.
    ///
    /// The two pictures — the shot and the fly view — share this, because the
    /// bug they would otherwise grow is the one this file already warns about
    /// twice: a layer lit on the canvas and unlit in the export, found after
    /// rendering.
    ///
    /// `fillsFrame` is the one place the two genuinely differ. In the shot a
    /// `.fill` layer is atmosphere and paints the whole frame; seen from
    /// outside it is a card at its own depth, because the artist has to be able
    /// to see where the sky actually sits.
    private func drawLayer(
        _ layer: SceneLayer,
        composition: SceneComposition,
        atFrame frame: Int,
        projection: SceneProjection,
        footprint: LayerFootprint,
        lighting: SceneLighting,
        fillsFrame: Bool,
        scene: SceneManager,
        assets: AssetManager,
        target: RenderTarget,
        quality: Quality
    ) {
        let mapper = CardMapper(
            world: { SceneViewProjection.cardPoint(layer: layer, local: $0) },
            projection: projection, height: target.frameHeight)

        // THE FAST PATH, and it is the one that runs for every scene composed
        // before lighting existed: no lights, a neutral ambient, or a layer
        // that has opted out. Straight into the frame, no scratch buffer, no
        // arithmetic over any pixel — so those scenes render byte for byte what
        // they rendered before.
        guard !lighting.isIdentity, layer.receivesLight,
              let field = layerLightField(layer, lighting: lighting, projection: projection,
                                          region: footprint.region, quality: quality),
              let scratch = makeBitmap(width: footprint.region.width,
                                       height: footprint.region.height)
        else {
            drawLayerContent(layer, composition: composition, atFrame: frame, mapper: mapper,
                             fillsFrame: fillsFrame, scene: scene, assets: assets,
                             target: target, quality: quality)
            return
        }

        // The scratch is a WINDOW on the frame, so the layer is drawn with the
        // SAME projection and the SAME mapper, and simply shifted — rather than
        // re-projected into a smaller viewport, which would be a second camera
        // to keep in step with the first. The shift is the context's transform
        // and nothing else; every number the drawing paths handle stays in
        // frame coordinates, which is what `RenderTarget` is for.
        let originY = target.frameHeight - footprint.region.maxY
        let scratchTarget = RenderTarget(context: scratch,
                                         frameWidth: target.frameWidth,
                                         frameHeight: target.frameHeight,
                                         originX: footprint.region.minX,
                                         originY: originY)
        scratch.translateBy(x: CGFloat(-footprint.region.minX), y: CGFloat(-originY))
        drawLayerContent(layer, composition: composition, atFrame: frame, mapper: mapper,
                         fillsFrame: fillsFrame, scene: scene, assets: assets,
                         target: scratchTarget, quality: quality)

        // ONE WALK: read the scratch, light it, and source-over it onto the
        // frame. It used to modulate the scratch, make a CGImage of it, and ask
        // CoreGraphics to draw that — four passes over the layer's pixels where
        // this is one, plus a CGImage allocated and thrown away per lit layer
        // per frame.
        field.composite(from: scratch, into: target.context,
                        originX: footprint.region.minX, originY: originY,
                        viewRect: (minX: Float(footprint.region.minX),
                                   minY: Float(footprint.region.minY),
                                   maxX: Float(footprint.region.maxX),
                                   maxY: Float(footprint.region.maxY)))
    }

    /// What a layer draws, with no lighting anywhere in it.
    private func drawLayerContent(
        _ layer: SceneLayer,
        composition: SceneComposition,
        atFrame frame: Int,
        mapper: CardMapper,
        fillsFrame: Bool,
        scene: SceneManager,
        assets: AssetManager,
        target: RenderTarget,
        quality: Quality
    ) {
        switch layer.content {
        case let .fill(fillValue):
            if fillsFrame {
                // Atmosphere: parallax on a flat colour is invisible, so it
                // paints the frame at its own opacity.
                fill(fillValue, in: target, opacity: layer.opacity)
            } else {
                guard let rect = cardLocalRect(layer, composition: composition, frame: frame)
                else { return }
                drawFillCard(fillValue, rect: rect, mapper: mapper,
                             opacity: layer.opacity, target: target)
            }
        case let .plate(assetID):
            guard let asset = assets.asset(for: assetID),
                  let image = try? store.cgImage(for: asset) else { return }
            let half = asset.size * 0.5
            drawCard(image: image, rect: (min: -half, max: half), mapper: mapper,
                     opacity: layer.opacity, target: target)
        case .rig:
            drawRigInstance(layer, frame: frame, mapper: mapper,
                            scene: scene, assets: assets, target: target, quality: quality)
        }
    }

    /// The lighting over a layer's region, or nil when nothing reaches it.
    private func layerLightField(
        _ layer: SceneLayer,
        lighting: SceneLighting,
        projection: SceneProjection,
        region: FrameRegion,
        quality: Quality
    ) -> LightField? {
        let plane = layer.lightingPlane
        // Pixels per world unit at the layer's own depth — the number that
        // turns a fade band in world units into a lattice spacing in pixels.
        // At or behind the near plane there is no such ratio, so the lattice
        // falls back to its coarsest cell rather than to a negative one.
        let depth = projection.depth(of: layer.worldOrigin)
        let perUnit = depth > projection.nearZ ? projection.focalLength / depth : 0
        return LightField.build(
            lighting: lighting,
            mask: layer.lightMask,
            normal: plane.normal,
            screenBounds: (minX: Float(region.minX), minY: Float(region.minY),
                           maxX: Float(region.maxX), maxY: Float(region.maxY)),
            cellsPerBand: quality == .final ? SceneLighting.cellsPerBandFinal
                                            : SceneLighting.cellsPerBandInteractive,
            pixelsPerWorldUnit: perUnit,
            worldAt: { x, y in
                projection.hit(screen: SIMD2<Float>(x, y),
                               plane: plane.point, normal: plane.normal)
            })
    }

    /// Which eye a point is being projected for.
    enum Viewpoint {
        /// Through the shot camera — the front view, and the export.
        case shot(SceneCamera)
        /// From wherever the artist is standing — the fly view.
        case fly(SceneViewCamera)
    }

    /// Layer-local point to VIEW pixels, y down — the same chain that drew the
    /// card, handed out so the gizmos can measure against it.
    ///
    /// The handles have to come from here rather than from their own idea of
    /// where a card is. A gizmo derived independently lands beside the card at
    /// any tilt, and "the handle is not on the thing" is the kind of wrongness
    /// an artist stops trusting the whole mode over.
    ///
    /// Y down, matching `shotLayerQuads`/`editorLayerQuads`, so picking and the
    /// gizmos speak one coordinate system.
    func layerPointMap(layer: SceneLayer,
                       viewpoint: Viewpoint,
                       pixelSize: SIMD2<Float>) -> (SIMD2<Float>) -> SIMD2<Float>? {
        switch viewpoint {
        case let .shot(camera):
            let projection = SceneProjection(camera: camera, viewSize: pixelSize)
            let height = Int(pixelSize.y.rounded())
            return { [self] local in
                guard let cg = cgPoint(layerPoint: local, layer: layer,
                                       projection: projection, height: height)
                else { return nil }
                return SIMD2<Float>(Float(cg.x), pixelSize.y - Float(cg.y))
            }
        case let .fly(view):
            let projection = SceneViewProjection(camera: view, viewSize: pixelSize)
            return { local in
                projection.project(SceneViewProjection.cardPoint(layer: layer, local: local))
            }
        }
    }

    /// The camera, as the matrices everything projects through.
    ///
    /// Handed out whole rather than as a closure, so a caller that needs the
    /// projection AND the depth AND the focal length gets one camera rather than
    /// three that could be built from different arguments.
    func projection(viewpoint: Viewpoint, pixelSize: SIMD2<Float>) -> SceneProjection {
        switch viewpoint {
        case let .fly(view): return SceneProjection(view: view, viewSize: pixelSize)
        case let .shot(camera): return SceneProjection(camera: camera, viewSize: pixelSize)
        }
    }

    /// Where each visible layer's card lands in the shot, in screen pixels
    /// (y down), front-most last. The same chain the drawing used.
    func shotLayerQuads(
        composition: SceneComposition,
        atFrame frame: Int,
        through camera: SceneCamera,
        pixelSize: SIMD2<Float>
    ) -> [LayerQuad] {
        // THE SAME FOOTPRINT the drawing used. Picking and the outline used to
        // recompute the card's screen polygon here, which meant two answers to
        // "where is that layer" — and the gizmo sitting beside the card is a
        // bug this file has already shipped once. It also means a layer the
        // frustum culled has no quad, so nothing can be selected where nothing
        // is drawn.
        quads(composition: composition, atFrame: frame,
              projection: SceneProjection(camera: camera, viewSize: pixelSize),
              pixelSize: pixelSize, fillsFrame: false)
    }

    /// One layer-quad builder, over a projection either eye can supply.
    private func quads(
        composition: SceneComposition,
        atFrame frame: Int,
        projection: SceneProjection,
        pixelSize: SIMD2<Float>,
        fillsFrame: Bool
    ) -> [LayerQuad] {
        let frustum = SceneFrustum(viewProjection: projection.viewProjection)
        let width = Int(pixelSize.x.rounded()), height = Int(pixelSize.y.rounded())
        var quads: [LayerQuad] = []
        for layer in composition.visibleLayers {
            guard let footprint = layerFootprint(
                layer, composition: composition, atFrame: frame,
                projection: projection, frustum: frustum, fillsFrame: fillsFrame,
                frameWidth: width, frameHeight: height),
                footprint.screenPolygon.count >= 3
            else { continue }
            quads.append(LayerQuad(id: layer.id, corners: footprint.screenPolygon))
        }
        return quads
    }

    /// Where each light lands on screen, in view pixels with y DOWN.
    ///
    /// ONE answer, like `shotLayerQuads` is one answer for cards: the markers
    /// are drawn from this and the picking tests it, so a light can never be
    /// clicked somewhere it is not drawn.
    ///
    /// The lights are SAMPLED at the frame, so a light on a track is marked
    /// where the canvas is lighting from — not where it was authored.
    struct LightMarker {
        let id: UUID
        let screen: SIMD2<Float>
        let kind: SceneLightKind
        let color: SIMD3<Float>
        let isEnabled: Bool
    }

    func lightMarkers(
        composition: SceneComposition,
        atFrame frame: Int,
        viewpoint: Viewpoint,
        pixelSize: SIMD2<Float>
    ) -> [LightMarker] {
        guard let scene else { return [] }
        let projection = self.projection(viewpoint: viewpoint, pixelSize: pixelSize)
        return scene.sceneLights(for: composition, atFrame: frame).compactMap { light in
            // A DIRECTIONAL light has no place in the world — it is a direction
            // and nothing else — so it has no marker to stand on the canvas.
            // Giving it one at the origin would be a handle for a property it
            // does not have.
            guard light.kind.isPositional,
                  let screen = projection.project(light.world) else { return nil }
            return LightMarker(id: light.id, screen: screen, kind: light.kind,
                               color: light.color, isEnabled: light.isEnabled)
        }
    }

    // MARK: - The editor view

    /// The set, seen from where the artist is standing.
    ///
    /// A real camera (`SceneViewProjection`), a void behind the cards instead of
    /// the shot's background, every card outlined with handles, and the shot
    /// camera drawn as a frustum so the artist can see what is in frame while
    /// standing outside it. Never exported.
    ///
    /// Cards are drawn in LIST order, as in the shot. From the side that can
    /// show a far card over a near one when the list says so; a depth sort
    /// would fix the picture and break the promise that Z never restacks a
    /// scene the artist has arranged. The outlines are what make the space
    /// legible either way.
    func renderEditorView(
        composition: SceneComposition,
        atFrame frame: Int,
        view: SceneViewCamera,
        pixelSize: SIMD2<Float>
    ) -> CGImage? {
        let lights = self.scene?.sceneLights(for: composition, atFrame: frame) ?? []
        let key = RenderKey(frame: frame, pixelSize: pixelSize,
                            rigStateToken: self.scene?.rigStateToken ?? 0,
                            quality: .interactive, composition: composition,
                            shotCamera: nil, viewCamera: view, lights: lights)
        if let cached = frameCache[.editor], cached.key == key { return cached.image }

        guard let scene, let assets, let ctx = makeContext(pixelSize) else { return nil }
        let target = RenderTarget.frame(ctx)
        let height = target.frameHeight
        let viewSize = SIMD2<Float>(Float(target.frameWidth), Float(height))
        let projection = SceneViewProjection(camera: view, viewSize: viewSize)
        let frustum = SceneFrustum(viewProjection: projection.matrices.viewProjection)
        fill(.solid(SIMD4<Float>(UM.sceneVoid.x, UM.sceneVoid.y, UM.sceneVoid.z, 1)),
             in: target, opacity: 1)

        // The SAME lighting, the same footprint, the same per-layer path as the
        // shot. Two eyes, one set of cards: the near-plane report was that a
        // layer left the canvas AND the camera preview, and one shared path is
        // what makes fixing it once fix both. Neither lighting nor culling gets
        // to relearn that.
        let lighting = SceneLighting(lights: lights, ambient: composition.ambient)
        let began = CACurrentMediaTime()
        defer { lastDrawMilliseconds = (CACurrentMediaTime() - began) * 1000 }
        for layer in composition.visibleLayers {
            guard let footprint = layerFootprint(
                layer, composition: composition, atFrame: frame,
                projection: projection.matrices, frustum: frustum, fillsFrame: false,
                frameWidth: target.frameWidth, frameHeight: height)
            else { continue }
            drawLayer(layer, composition: composition, atFrame: frame,
                      projection: projection.matrices, footprint: footprint,
                      lighting: lighting, fillsFrame: false, scene: scene, assets: assets,
                      target: target, quality: .interactive)
        }

        guard let image = ctx.makeImage() else { return nil }
        frameCache[.editor] = (key, image)
        return image
    }

    /// Where each visible layer's card lands in the editor view, in screen
    /// pixels (y down). Picking asks this; the overlay draws from it — one
    /// answer to "where is that card on screen".
    func editorLayerQuads(
        composition: SceneComposition,
        atFrame frame: Int,
        view: SceneViewCamera,
        pixelSize: SIMD2<Float>
    ) -> [LayerQuad] {
        quads(composition: composition, atFrame: frame,
              projection: SceneViewProjection(camera: view, viewSize: pixelSize).matrices,
              pixelSize: pixelSize, fillsFrame: false)
    }

    /// The render camera's frustum, as the points the fly view draws it from.
    ///
    /// GEOMETRY, NOT PIXELS. This used to be drawn straight into the raster by
    /// `drawFrustum`, which was fine while the picture was a CGContext and
    /// impossible once it is a Metal texture. Handing the points out instead
    /// puts the frustum on the same footing as the card outlines and the light
    /// markers: editor chrome, on its own layer, which an export cannot pick up
    /// even by accident.
    ///
    /// Screen pixels, y DOWN — the projection's own convention, the same one
    /// `LayerQuad` uses.
    struct FrustumGeometry {
        /// The shot's frame at its focal distance: the rectangle where one
        /// world unit is one rendered pixel.
        var frame: [SIMD2<Float>]
        /// The same rectangle pushed past the farthest layer, so the pyramid
        /// encloses the whole set. EMPTY when any corner falls behind the fly
        /// camera, because a partial box is worse than none.
        var far: [SIMD2<Float>]
        /// The camera itself. Nil when it is behind the fly camera's near
        /// plane, which is exactly when you have flown past it.
        var eye: SIMD2<Float>?
    }

    /// Where the shot's frustum lands in the fly view.
    ///
    /// Nil when the near frame does not project to four corners — the one case
    /// where there is nothing honest to draw.
    func frustumGeometry(
        composition: SceneComposition,
        atFrame frame: Int,
        view: SceneViewCamera,
        pixelSize: SIMD2<Float>
    ) -> FrustumGeometry? {
        guard let scene else { return nil }
        let shot = scene.sceneCamera(for: composition, atFrame: frame)
        let projection = SceneViewProjection(camera: view, viewSize: pixelSize)
        let focal = shot.focalLength(viewHeight: composition.renderSize.y)
        let near = SceneViewProjection.shotFrame(
            shot: shot, renderSize: composition.renderSize, atDistance: focal)
        // Far enough to pass every layer, so the pyramid always encloses the set.
        let farthest = composition.visibleLayers.map { $0.positionZ - shot.positionZ }.max() ?? focal
        let farDistance = min(max(farthest * 1.15, focal * 1.6), shot.farZ)
        let far = SceneViewProjection.shotFrame(
            shot: shot, renderSize: composition.renderSize, atDistance: farDistance)

        let frameScreen = near.compactMap { projection.project($0) }
        guard frameScreen.count == 4 else { return nil }
        let farScreen = far.compactMap { projection.project($0) }
        return FrustumGeometry(
            frame: frameScreen,
            far: farScreen.count == 4 ? farScreen : [],
            eye: projection.project(SIMD3<Float>(shot.position.x, shot.position.y,
                                                 shot.positionZ)))
    }

    struct LayerQuad {
        let id: UUID
        /// The card's outline in screen pixels, y down, wound in the card's own
        /// order: top-left, top-right, bottom-right, bottom-left.
        ///
        /// FOUR corners normally, and THREE TO FIVE when the near plane cuts
        /// the card — the cut replaces one corner with two, or removes one.
        /// Callers must not assume four. Assuming it is what made the selection
        /// box disappear along with the card it belongs to: `guard count == 4`
        /// threw away a card that was merely partly visible.
        let corners: [SIMD2<Float>]
    }

    /// The card's own rectangle, in layer-local units before the layer's
    /// scale: a plate is its image, a fill is the frame at its depth, a rig
    /// instance is the box around its posed sprites. Nil when there is nothing
    /// to bound.
    func cardLocalRect(
        _ layer: SceneLayer,
        composition: SceneComposition,
        frame: Int
    ) -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        switch layer.content {
        case let .plate(assetID):
            guard let size = assets?.asset(for: assetID)?.size else { return nil }
            return (-size * 0.5, size * 0.5)
        case .fill:
            guard let scene else { return nil }
            let shot = scene.sceneCamera(for: composition, atFrame: frame)
            let distance = layer.positionZ - shot.positionZ
            guard distance > shot.nearZ else { return nil }
            let focal = shot.focalLength(viewHeight: composition.renderSize.y)
            let half = composition.renderSize * 0.5 * (distance / max(focal, 0.000001))
            // The layer's own scale is applied by the card mapping; undo it
            // here so a fill always covers the frame whatever its scale says.
            let unscaled = SIMD2<Float>(half.x / max(layer.scale.x, 0.0001),
                                        half.y / max(layer.scale.y, 0.0001))
            return (-unscaled, unscaled)
        case .rig:
            return rigInstanceBounds(layer, frame: frame)
        }
    }

    /// Bounds of the rig's posed sprites, in the rig's own space — which is the
    /// layer's local space.
    /// The box around a rig instance's posed sprites, in rig-world units.
    ///
    /// THE SKINNED, DEFORMED VERTICES — the very points `drawRigSprites` sends
    /// to the triangles — and not, as this did, the four corners of each
    /// sprite's rectangle.
    ///
    /// The rectangle is the wrong shape to ask. A vertex that skinning or a
    /// mesh deform has pushed outside its sprite's rect is drawn there, so a
    /// box built from rects is not a bound at all; it is a box that usually
    /// happens to contain the drawing. That was survivable while the number was
    /// only used for a selection outline — where it showed as an outline that
    /// cut through a bent arm — and it stops being survivable the moment
    /// anything CLIPS to it, because then the arm is not merely outside the box,
    /// it is gone.
    ///
    /// It is the same work the drawing does, so it is computed once per layer
    /// per frame and cached with the footprint rather than recomputed at each
    /// of the four places that ask where a layer is.
    private func rigInstanceBounds(_ layer: SceneLayer, frame: Int) -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        guard let scene, let assets else { return nil }
        let clipDuration = max(scene.playbackEndFrame - scene.playbackStartFrame + 1, 1)
        guard let rigFrame = layer.rigFrame(sceneFrame: frame, clipDuration: clipDuration) else { return nil }
        let sample = scene.rigPose(atFrame: scene.playbackStartFrame + rigFrame)
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        var any = false
        for image in scene.renderOrderedImages where !image.isHidden {
            guard let asset = assets.asset(for: image.assetID),
                  let pose = sample.imagePoses[image.id] else { continue }
            var posed = image
            posed.position = pose.position
            posed.scale = pose.scale
            posed.rotation = pose.rotation
            posed.skew = pose.skew
            posed.meshAnimationDeform = pose.meshDeform
            let mesh = ToolUtilities.resolvedMesh(for: posed, assetSize: asset.size)
            let localVerts = scene.skinnedLocalVertices(
                for: posed, assetSize: asset.size, showDeformed: true,
                worldMatrices: sample.worldMatrices, mesh: mesh
            )
            for c in ToolUtilities.transformedVertices(for: posed, localVertices: localVerts) {
                lo = simd_min(lo, c); hi = simd_max(hi, c); any = true
            }
        }
        return any ? (lo, hi) : nil
    }

    // MARK: - Overlay

    /// How much wider the contour pass draws than the ink: about a pixel of
    /// dark on each side.
    static let contourGrowPx: CGFloat = 2.2
    static let contourAlpha: CGFloat = 0.82
    /// The contour's luminance target. `contourInk`'s default of 0.26 is tuned
    /// for pale bone colours; the selection fuchsia is already darker than that,
    /// so at the default it would get itself back as its own contour and stand
    /// off nothing. Near-black keeps a shade of the ink's hue and separates from
    /// every ink used here by at least 2:1 — `verify_scene_view.py` reads this
    /// constant back and checks that.
    static let contourLuminance: Float = 0.06

    /// Handle squares, in pixels. They do not shrink with the card — a card
    /// seen edge-on is a line, and the handles are how it stays grabbable.
    static let handlePx: CGFloat = 5
    static let selectedHandlePx: CGFloat = 7

    // MARK: - Cards

    /// A rig instance: the project's sprites, posed at the instance's own clip
    /// frame, drawn through the layer's transform and the camera.
    private func drawRigInstance(
        _ layer: SceneLayer,
        frame: Int,
        mapper: CardMapper,
        scene: SceneManager,
        assets: AssetManager,
        target: RenderTarget,
        quality: Quality
    ) {
        // THE CARD, NOT THE RIG. Orbiting does not change the rig's pose — only
        // where it is seen from — yet every step redrew every triangle of every
        // sprite through a clip and an affine. Eight sprites of 120 triangles,
        // three instances, is 2 880 clipped image draws between one touch and
        // the next; that is the stutter, and it is the same picture each time.
        //
        // A rig instance in a Scene is a FLAT card, so it can be drawn once
        // into an image and that image drawn as the card. The pose decides when
        // it is redrawn, not the camera.
        if quality == .interactive,
           let baked = bakedRigCard(layer, frame: frame, mapper: mapper,
                                    scene: scene, assets: assets) {
            drawCard(image: baked.image, rect: baked.rect, mapper: mapper,
                     opacity: layer.opacity, target: target)
            return
        }

        guard let rigFrame = instanceRigFrame(layer, frame: frame, scene: scene) else { return }
        drawRigSprites(atRigFrame: rigFrame, map: mapper.map, mapper: mapper,
                       opacity: layer.opacity,
                       scene: scene, assets: assets, target: target)
    }

    /// The instance's own clip frame: the layer's speed/offset/loop over the
    /// range the Animator plays.
    ///
    /// (The stored clipID will pick a library animation once the library can be
    /// sampled purely; until then every instance plays the animation the rig
    /// currently has loaded — said here rather than discovered.)
    private func instanceRigFrame(_ layer: SceneLayer, frame: Int, scene: SceneManager) -> Int? {
        let clipDuration = max(scene.playbackEndFrame - scene.playbackStartFrame + 1, 1)
        guard let rigFrame = layer.rigFrame(sceneFrame: frame, clipDuration: clipDuration) else { return nil }
        return scene.playbackStartFrame + rigFrame
    }

    /// Every posed sprite of the rig, through `map`.
    ///
    /// One body, two callers: the exact path draws it straight into the frame
    /// with the camera's mapping, and the bake draws it into its own bitmap
    /// with a flat one. Two copies of "how a rig is drawn" is how the preview
    /// and the file would start to differ.
    private func drawRigSprites(
        atRigFrame rigFrame: Int,
        map: LayerMap,
        mapper: CardMapper?,
        opacity layerOpacity: Float,
        scene: SceneManager,
        assets: AssetManager,
        target: RenderTarget
    ) {
        let ctx = target.context
        // Rig-local vertices to whatever the caller can give the triangles.
        // With a camera they arrive as world points, so a triangle straddling
        // the near plane can be cut; without one — the bake, which draws flat
        // into its own bitmap — there is no near plane to straddle.
        func vertices(_ rigWorld: [SIMD2<Float>]) -> TriangleVertices {
            if let mapper { return .camera(locals: rigWorld, mapper: mapper) }
            return .flat(rigWorld.map { map($0) })
        }

        let sample = scene.rigPose(atFrame: rigFrame)

        // Draw order: the sampled permutation when the artist keyed one,
        // otherwise the structural order the canvas uses.
        var ordered = scene.renderOrderedImages
        if let order = sample.drawOrder {
            let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            ordered.sort { (position[$0.id] ?? .max) < (position[$1.id] ?? .max) }
        }

        // REVERSED, like the Editor canvas. Index 0 of this list is the
        // FRONT-most sprite — `DrawOrderView` says so ("top row = front-most
        // layer", "0 = front") and `CanvasPicking` says so — and a painter's
        // algorithm has to lay the back down first. Walked forwards, as this
        // was, the front-most sprite is painted first and then buried by every
        // sprite that is supposed to be behind it, so Scene showed the exact
        // reverse of what the artist arranged in the Editor.
        for image in ordered.reversed() where !image.isHidden {
            guard let asset = assets.asset(for: image.assetID),
                  let pose = sample.imagePoses[image.id] else { continue }

            // A POSED COPY. SceneImage is a value type, so the sampled pose can
            // ride the existing mesh/skinning pipeline without the scene ever
            // learning the frame was asked about.
            var posed = image
            posed.position = pose.position
            posed.scale = pose.scale
            posed.rotation = pose.rotation
            posed.skew = pose.skew
            posed.meshAnimationDeform = pose.meshDeform

            guard let cgImg = try? store.tinted(
                store.cgImage(for: asset), rgb: posed.tintColor, assetID: asset.id
            ) else { continue }

            let mesh = ToolUtilities.resolvedMesh(for: posed, assetSize: asset.size)
            let localVerts = scene.skinnedLocalVertices(
                for: posed, assetSize: asset.size, showDeformed: true,
                worldMatrices: sample.worldMatrices, mesh: mesh
            )
            let rigWorld = ToolUtilities.transformedVertices(for: posed, localVertices: localVerts)

            let imgW = CGFloat(asset.size.x)
            let imgH = CGFloat(asset.size.y)
            drawTriangles(
                indices: mesh.indices, uvs: mesh.uvs, vertices: vertices(rigWorld),
                image: cgImg, imageSize: CGSize(width: imgW, height: imgH),
                blendMode: posed.blendMode.cgBlendMode,
                opacity: CGFloat(posed.tintColor.w) * CGFloat(layerOpacity),
                ctx: ctx
            )
        }
    }

    /// A rig instance drawn once into its own bitmap, to be used as the card's
    /// texture — a pre-comp, the way a compositor treats a nested scene.
    ///
    /// Keyed on the instance's own clip frame and on `rigStateToken`, so it is
    /// redrawn when the POSE changes and never when only the camera does. That
    /// is the whole point: an orbit is a camera move.
    ///
    /// The bitmap is sized from how big the card actually lands on screen, in
    /// buckets, so a card the artist flies towards is re-baked in steps rather
    /// than on every pixel of approach — and never below the card's own texel
    /// density, which is what would make it look soft.
    ///
    /// REFUSED for a rig that uses anything but normal blending. An additive
    /// sprite composites against what is BEHIND it; baked, it would composite
    /// against the bake's own transparent ground and come out wrong. Those rigs
    /// take the exact path and pay for it, which is the honest trade.
    private func bakedRigCard(
        _ layer: SceneLayer,
        frame: Int,
        mapper: CardMapper,
        scene: SceneManager,
        assets: AssetManager
    ) -> (image: CGImage, rect: (min: SIMD2<Float>, max: SIMD2<Float>))? {
        guard let rigFrame = instanceRigFrame(layer, frame: frame, scene: scene),
              scene.images.allSatisfy({ $0.isHidden || $0.blendMode == .normal }),
              let rect = rigInstanceBounds(layer, frame: frame) else { return nil }

        let span = rect.max - rect.min
        guard span.x > 0.5, span.y > 0.5 else { return nil }

        // How many bitmap pixels per rig unit: what the card measures on screen
        // now, bucketed to powers of two so approaching it re-bakes a handful of
        // times instead of continuously. Never above 1 — the sprites' own
        // texels are the ceiling, and baking larger only costs.
        let density = screenDensity(of: rect, mapper: mapper, span: span)
        let bucket = densityBucket(density)
        let key = BakeKey(layerID: layer.id, rigFrame: rigFrame,
                          token: scene.rigStateToken, densityBucket: bucket)
        if let cached = rigBakeCache[key] { return (image: cached, rect: rect) }

        var scale = Float(bucket) / Float(Self.densityBucketSteps)
        // A hard ceiling on the bitmap. Density already keeps the bake at or
        // below what the card covers on screen, but a rig whose bounds are
        // thousands of units across can still ask for a bitmap measured in tens
        // of megabytes — and there are several of these held at once. On an
        // iPad that is the memory that matters.
        let longest = max(span.x, span.y) * scale
        if longest > Self.maxBakePixels { scale *= Self.maxBakePixels / longest }

        // EXACTLY this many pixels, with no floor.
        //
        // This used to go through `makeContext`, which floors a bitmap at
        // 16×16 — right for a frame, where a degenerate viewport must not
        // produce a degenerate context, and wrong here. The bake asked for,
        // say, 25×12 and got 25×16, and the map below scaled the rig by
        // `scale` while flipping against the CONTEXT's height. So the rig was
        // drawn into 12 of the bitmap's 16 rows and `drawCard` then stretched
        // all 16 rows across the card: the artwork squashed into three
        // quarters of its own card with the remaining quarter blank.
        //
        // It is the CAMERA PREVIEW's bug specifically, because it is a
        // function of density and the preview is 320 px wide. The harness
        // measures the same rigs at both sizes: on a 1920 canvas the bake
        // never lands under the floor, and in the preview it does — 75 % of
        // the card covered in one axis, 19 % in a thin one, and 0 % for a rig
        // small enough to round to no pixels at all.
        //
        // (The skinned bounds of the previous commit made this more likely,
        // not less: a truthful box is a bigger box, and density is screen
        // pixels over span.)
        let pixels = SIMD2<Int>(Int((span.x * scale).rounded()),
                                Int((span.y * scale).rounded()))
        // Below a pixel there is nothing to bake, and the triangle path draws
        // it directly — slower, and with no quantisation to lose it to.
        guard pixels.x >= 1, pixels.y >= 1,
              let bakeCtx = makeBitmap(width: pixels.x, height: pixels.y) else { return nil }

        // A flat map into the bitmap: rig-local to bake pixels, y up. No
        // camera, no perspective — the card carries all of that afterwards.
        //
        // Off the bitmap's ACTUAL extent rather than off `scale`, so the rig's
        // bounds land on the bitmap's four edges BY CONSTRUCTION — which is
        // exactly what `drawCard` assumes when it maps the whole image onto
        // `rect`. Deriving it from `scale` instead leaves the rounding of
        // `pixels` as a half-pixel of drift, and at a bake scale of 1/16 half a
        // bake pixel is eight rig units.
        let bakeSize = SIMD2<Float>(Float(bakeCtx.width), Float(bakeCtx.height))
        let bakeMap: LayerMap = { local in
            CGPoint(x: CGFloat((local.x - rect.min.x) / span.x * bakeSize.x),
                    y: CGFloat(bakeSize.y - (local.y - rect.min.y) / span.y * bakeSize.y))
        }
        // The bake draws into ITS OWN bitmap, so here the canvas really is the
        // context — which is what `RenderTarget.frame` says, out loud, rather
        // than being assumed by a path that reads `ctx.width`.
        drawRigSprites(atRigFrame: rigFrame, map: bakeMap, mapper: nil, opacity: 1,
                       scene: scene, assets: assets, target: .frame(bakeCtx))
        guard let image = bakeCtx.makeImage() else { return nil }

        // The rig's pose is what invalidates a bake, and the token is in the
        // key, so yesterday's poses are dead weight rather than history.
        holdBake(image, for: key)
        return (image: image, rect: rect)
    }

    /// Bitmap pixels per rig unit the card currently occupies on screen.
    private func screenDensity(of rect: (min: SIMD2<Float>, max: SIMD2<Float>),
                               mapper: CardMapper, span: SIMD2<Float>) -> Float {
        if let a = mapper.point(rect.min),
           let b = mapper.point(SIMD2<Float>(rect.max.x, rect.min.y)),
           let c = mapper.point(SIMD2<Float>(rect.min.x, rect.max.y)) {
            let widthPx = Float(hypot(b.x - a.x, b.y - a.y))
            let heightPx = Float(hypot(c.x - a.x, c.y - a.y))
            return max(widthPx / span.x, heightPx / span.y)
        }
        // A corner behind the eye. The card is being cut, not lost, so it still
        // has a size — measured over the part that survives the cut. Returning
        // 1 here, as this did, asked for a full-density bake of a card that is
        // mostly off screen: the memory ceiling caught it, but only after the
        // bitmap had been sized.
        let visible = mapper.clipped(Self.cardLocals(rect)).map(\.point)
        guard visible.count >= 3, span.x > 0, span.y > 0 else { return 1 }
        var lo = visible[0], hi = visible[0]
        for p in visible.dropFirst() {
            lo = CGPoint(x: min(lo.x, p.x), y: min(lo.y, p.y))
            hi = CGPoint(x: max(hi.x, p.x), y: max(hi.y, p.y))
        }
        return max(Float(hi.x - lo.x) / span.x, Float(hi.y - lo.y) / span.y)
    }

    /// The density, rounded UP to a power-of-two step and capped at 1.
    ///
    /// Up rather than to-nearest: a bake that is slightly too big is invisible,
    /// one that is slightly too small is soft, and softness is the failure the
    /// artist would report.
    private func densityBucket(_ density: Float) -> Int {
        let clamped = max(min(density, 1), Self.minBakeDensity)
        let steps = Float(Self.densityBucketSteps)
        let exponent = log2(clamped).rounded(.up)
        return max(1, Int((pow(2, exponent) * steps).rounded()))
    }

    /// Bake density is expressed as `bucket / densityBucketSteps`, so a bucket
    /// is an integer and can key a dictionary without a Float's equality.
    static let densityBucketSteps = 16
    /// A card smaller than this fraction of its texels still bakes — below it
    /// the bitmap would be a few pixels across and the card would shimmer.
    static let minBakeDensity: Float = 1.0 / 16
    /// Longest side of a baked bitmap. Above this the bake stops being cheaper
    /// than what it replaced.
    static let maxBakePixels: Float = 1600
    /// How much memory the baked rig cards may hold, in bytes.
    ///
    /// BYTES, not a count, and the count is what it replaced. Six entries was
    /// the working set for an artist ORBITING a still scene — the pose does not
    /// change, so one bake per instance is all there is to hold. Playback is a
    /// different access pattern entirely: the pose changes every frame, so a
    /// ninety-frame loop wants ninety bakes per instance, and six of them is
    /// six frames cached out of ninety.
    ///
    /// At the resolution playback actually runs at — the ladder has already
    /// dropped it — a bake is a few hundred kilobytes, so this holds a loop of
    /// a couple of hundred frames. The first pass through pays for them and
    /// every pass after it is free.
    static let bakeCacheBudget = 48 * 1024 * 1024

    private struct BakeKey: Hashable {
        let layerID: UUID
        let rigFrame: Int
        let token: UInt64
        let densityBucket: Int
    }

    private var rigBakeCache: [BakeKey: CGImage] = [:]
    private var rigBakeBytes = 0

    /// Hold a bake, if there is room for it.
    ///
    /// ## The eviction policy, and why it is not LRU
    ///
    /// Playback walks a LOOP, and a loop is the one access pattern LRU is
    /// pathological on: by the time frame 0 comes round again it is the least
    /// recently used thing in the cache, so it has just been evicted — to make
    /// room for the frame that will itself be evicted before its turn. Measured
    /// over a ninety-frame loop played four times, a cache holding sixty frames
    /// gets a ZERO per cent hit rate under FIFO and fifty per cent by simply
    /// keeping what it already has.
    ///
    /// So a full cache does not evict. It keeps the frames it managed to hold
    /// and those keep hitting, and the shot degrades in proportion to how much
    /// of it fits rather than collapsing to nothing.
    ///
    /// What IS dropped is anything whose token is stale — a bake of a pose the
    /// rig no longer has can never hit again, so it is not a cache entry, it is
    /// occupied memory.
    private func holdBake(_ image: CGImage, for key: BakeKey) {
        let cost = image.bytesPerRow * image.height
        if rigBakeBytes + cost > Self.bakeCacheBudget {
            let stale = rigBakeCache.keys.filter { $0.token != key.token }
            for victim in stale {
                if let held = rigBakeCache.removeValue(forKey: victim) {
                    rigBakeBytes -= held.bytesPerRow * held.height
                }
            }
        }
        guard rigBakeBytes + cost <= Self.bakeCacheBudget else { return }
        rigBakeCache[key] = image
        rigBakeBytes += cost
    }

    /// A plate: one textured card, subdivided when it is a perspective map.
    /// A card: one image, mapped onto the quad its corners land on.
    ///
    /// ONE OPERATION, NOT A GRID. CoreGraphics interpolates affinely and a flat
    /// card seen through a perspective camera is a projective map, so this used
    /// to cut the card into patches and approximate each one. That cannot be
    /// made cheap: run the real projection and a backdrop-sized card deviates
    /// 77 px from affine at TEN DEGREES of tilt, which no grid under 24x24
    /// brings inside a pixel — and the fly view is never front-on, so every
    /// card in it was 1 152 clipped image draws. It was measured, and it was
    /// four times worse than the fixed grid it replaced.
    ///
    /// A homography is what a flat card actually needs, and Core Image applies
    /// one on the GPU in a single pass. Front-on it is still one draw, through
    /// the affine path below, because there the two maps agree exactly and an
    /// affine draw needs no readback.
    private func drawCard(
        image: CGImage,
        rect: (min: SIMD2<Float>, max: SIMD2<Float>),
        mapper: CardMapper,
        opacity: Float,
        target: RenderTarget
    ) {
        // Corners in the order `ctx.draw` puts them in a y-up context.
        let locals = Self.cardLocals(rect)

        // A card that straddles the near plane used to end here, on a `guard`
        // whose comment read "a corner behind the eye: the card is not
        // drawable". It is drawable — it is PARTLY VISIBLE — and since the
        // nearest corner crosses long before the centre, and the gizmo projects
        // the centre, this is what made a layer vanish while its handles stayed
        // put. It is cut to the plane now instead.
        guard mapper.isWhollyVisible(locals) else {
            drawStraddlingCard(image: image, locals: locals, mapper: mapper,
                               opacity: opacity, target: target)
            return
        }
        guard let topLeft = mapper.point(locals[0]),
              let topRight = mapper.point(locals[1]),
              let bottomRight = mapper.point(locals[2]),
              let bottomLeft = mapper.point(locals[3])
        else { return }

        // Affine when the fourth corner lands where three of them predict.
        let predicted = CGPoint(x: topRight.x + bottomLeft.x - topLeft.x,
                                y: topRight.y + bottomLeft.y - topLeft.y)
        let deviation = hypot(bottomRight.x - predicted.x, bottomRight.y - predicted.y)
        if deviation <= Self.affineTolerancePx {
            drawAffineCard(image: image, topLeft: topLeft, topRight: topRight,
                           bottomLeft: bottomLeft, opacity: opacity, target: target)
        } else {
            drawProjectiveCard(image: image, topLeft: topLeft, topRight: topRight,
                               bottomRight: bottomRight, bottomLeft: bottomLeft,
                               opacity: opacity, target: target)
        }
    }

    /// The card's four local corners, top-left first — the order every path
    /// here speaks, named once so the four call sites cannot drift.
    static func cardLocals(_ rect: (min: SIMD2<Float>, max: SIMD2<Float>)) -> [SIMD2<Float>] {
        [SIMD2<Float>(rect.min.x, rect.max.y), SIMD2<Float>(rect.max.x, rect.max.y),
         SIMD2<Float>(rect.max.x, rect.min.y), SIMD2<Float>(rect.min.x, rect.min.y)]
    }

    /// A card the near plane cuts through: mapped whole, shown in part.
    ///
    /// The temptation is to fan the visible polygon into triangles and draw
    /// each under an affine, the way the rig meshes are drawn. It does not pay:
    /// near the plane the perspective across a card is severe enough that
    /// `verify_scene_near_clipping.py` measures forty thousand triangles for
    /// ONE card still landing 4.6 px out, against the 0.5 px this file calls
    /// "affine is right here" and against a draw budget it already calls a
    /// stutter at 2 880.
    ///
    /// So the card keeps its real perspective. It is a plane, so layer-local to
    /// screen is a homography, and a homography is fixed by four point
    /// correspondences — including a corner behind the eye, whose divide by a
    /// negative w lands it at the antipode. That antipode is the correct
    /// projective image of the corner, not an error to be guarded away, and the
    /// harness measures the resulting map against the true projection at 1.4e-08
    /// px with up to two corners behind.
    ///
    /// The near-plane cut then becomes a CLIP on the destination rather than a
    /// rejection of the primitive: the whole card is mapped, and only the part
    /// in front of the eye is let through.
    private func drawStraddlingCard(
        image: CGImage,
        locals: [SIMD2<Float>],
        mapper: CardMapper,
        opacity: Float,
        target: RenderTarget
    ) {
        let ctx = target.context
        let visible = mapper.clipped(locals).map(\.point)
        // Fewer than three points means none of the card is in front of the
        // eye, or it is exactly edge-on. Nothing to draw, and that is correct
        // rather than a fallback.
        guard visible.count >= 3, let quad = mapper.quad(locals) else { return }

        // The FRAME, from the target — not `ctx.width`/`ctx.height`, which is
        // this bitmap's size at this bitmap's origin and belongs to a different
        // coordinate system than `visible`.
        let canvas = target.canvas
        var box = CGRect(x: visible[0].x, y: visible[0].y, width: 0, height: 0)
        for point in visible.dropFirst() {
            box = box.union(CGRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        guard box.origin.x.isFinite, box.origin.y.isFinite,
              box.size.width.isFinite, box.size.height.isFinite else { return }
        let bounds = box.intersection(canvas).integral
        guard !bounds.isEmpty else { return }

        let source = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return }
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: quad[0]), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: quad[1]), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: quad[2]), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: quad[3]), forKey: "inputBottomLeft")
        guard let output = filter.outputImage else { return }

        // Cropped to the visible box BEFORE anything asks for its extent. A
        // quad with a corner behind the eye wraps through the line at infinity,
        // so the filter's own extent is unbounded — which is fine, because the
        // region wanted is known independently: it is where the cut polygon
        // lands. Reading the extent instead is what would turn this into a
        // beachball.
        guard let rendered = ciContext.createCGImage(output.cropped(to: bounds), from: bounds)
        else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(CGFloat(max(0, min(1, opacity))))
        ctx.beginPath()
        ctx.move(to: visible[0])
        for point in visible.dropFirst() { ctx.addLine(to: point) }
        ctx.closePath()
        ctx.clip()
        ctx.draw(rendered, in: bounds)
    }

    /// How far the fourth corner may miss before the map is treated as
    /// projective. Sub-pixel, so the cheap path is only taken when it is right.
    static let affineTolerancePx: CGFloat = 0.5

    /// The card as a parallelogram: one `ctx.draw` under an affine transform.
    ///
    /// `ctx.draw(image, in:)` puts the image right side up in a y-up context, so
    /// its own corners are (0, h) top-left, (w, h) top-right, (0, 0)
    /// bottom-left. Three corners determine the transform; the fourth is
    /// implied, which is precisely why this path is only taken when the fourth
    /// one agrees.
    private func drawAffineCard(image: CGImage,
                                topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint,
                                opacity: Float, target: RenderTarget) {
        // Takes the target although it never needs the canvas: a path that is
        // handed a bare context is a path that can quietly start measuring it
        // again, and this one sits two lines from the one that did.
        let ctx = target.context
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return }
        let transform = CGAffineTransform(
            a: (topRight.x - topLeft.x) / w, b: (topRight.y - topLeft.y) / w,
            c: (topLeft.x - bottomLeft.x) / h, d: (topLeft.y - bottomLeft.y) / h,
            tx: bottomLeft.x, ty: bottomLeft.y
        )
        ctx.saveGState()
        ctx.setAlpha(CGFloat(max(0, min(1, opacity))))
        ctx.concatenate(transform)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
    }

    /// The card as a quadrilateral: one GPU homography.
    ///
    /// Core Image's coordinate space is y up with the origin bottom-left, which
    /// is the space the layer maps already produce — so the corners go across
    /// untouched, and nothing has to be flipped twice and get it wrong once.
    ///
    /// The output is clipped to the canvas before it is read back, so a card
    /// mostly off screen costs almost nothing and a card entirely off screen
    /// costs a rectangle intersection.
    private func drawProjectiveCard(image: CGImage,
                                    topLeft: CGPoint, topRight: CGPoint,
                                    bottomRight: CGPoint, bottomLeft: CGPoint,
                                    opacity: Float, target: RenderTarget) {
        let ctx = target.context
        let source = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return }
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        guard let output = filter.outputImage else { return }

        let canvas = target.canvas
        let extent = output.extent
        // A degenerate quad — a card exactly edge-on — gives an infinite or
        // empty extent, and asking for a CGImage of that is how a preview turns
        // into a beachball.
        guard extent.origin.x.isFinite && extent.origin.y.isFinite
                && extent.size.width.isFinite && extent.size.height.isFinite,
              !extent.isEmpty else { return }
        let bounds = extent.intersection(canvas).integral
        guard !bounds.isEmpty, let rendered = ciContext.createCGImage(output, from: bounds)
        else { return }

        ctx.saveGState()
        ctx.setAlpha(CGFloat(max(0, min(1, opacity))))
        ctx.draw(rendered, in: bounds)
        ctx.restoreGState()
    }

    /// One context for the life of the renderer. Building a `CIContext` is
    /// expensive and building one per card per frame would cost more than the
    /// grid this replaces.
    private lazy var ciContext: CIContext = {
        // ON THE GPU, EXPLICITLY.
        //
        // `CIContext()` picks its own backing, and on a Mac with no window
        // attached or under memory pressure that can be the CPU renderer —
        // which turns every tilted card into a software perspective warp on the
        // main thread, at the moment the artist is orbiting and can least
        // afford it. Handed a device, it is Metal, and the warp is a GPU pass.
        //
        // `.cacheIntermediates: false` stays. The graph here is one filter deep
        // and never reused between frames, so a cache of intermediates is
        // memory held for a hit that cannot happen.
        //
        // WHAT THIS DOES NOT FIX, said plainly: `createCGImage` still reads the
        // result back to the CPU so CoreGraphics can composite it. That
        // readback is the next real lever, and closing it means compositing the
        // whole frame as a Core Image graph rather than card by card — a bigger
        // piece than this, and one worth doing on its own.
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .name: "UltraMeshScene",
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    /// A fill, as a card: its ramp clipped to the projected rectangle.
    private func drawFillCard(
        _ fillValue: SceneFill,
        rect: (min: SIMD2<Float>, max: SIMD2<Float>),
        mapper: CardMapper,
        opacity: Float,
        target: RenderTarget
    ) {
        let ctx = target.context
        // Cut, not rejected. A fill is a flat colour, so the clipped polygon is
        // all there is to it — no texture to keep in register, and the gradient
        // still runs between the midpoints of what remains.
        let screen = mapper.clipped(Self.cardLocals(rect)).map(\.point)
        guard screen.count >= 3 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(CGFloat(max(0, min(1, opacity))))
        ctx.beginPath()
        ctx.move(to: screen[0])
        for c in screen.dropFirst() { ctx.addLine(to: c) }
        ctx.closePath()
        ctx.clip()
        let top = fillValue.topColor, bottom = fillValue.bottomColor
        let topMid = CGPoint(x: (screen[0].x + screen[1].x) / 2, y: (screen[0].y + screen[1].y) / 2)
        let bottomMid = CGPoint(x: (screen[2].x + screen[3].x) / 2, y: (screen[2].y + screen[3].y) / 2)
        let colors = [
            CGColor(red: CGFloat(top.x), green: CGFloat(top.y), blue: CGFloat(top.z), alpha: CGFloat(top.w)),
            CGColor(red: CGFloat(bottom.x), green: CGFloat(bottom.y), blue: CGFloat(bottom.z), alpha: CGFloat(bottom.w)),
        ]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: topMid, end: bottomMid,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        } else {
            ctx.setFillColor(red: CGFloat(top.x), green: CGFloat(top.y), blue: CGFloat(top.z), alpha: CGFloat(top.w))
            // The CLIPPED PATH, which is what this card is. It used to fill
            // `0, 0, ctx.width, ctx.height` — harmless while the clip was in
            // place and the context was the frame, and wrong in a scratch,
            // where that rectangle is the window's size at the window's origin.
            // The clip already bounds it, so the card's own box is both correct
            // and the smallest thing that can be said here.
            ctx.fill(ctx.boundingBoxOfClipPath)
        }
    }

    // MARK: - The shot's chain

    /// Layer space -> world -> view matrix -> projection matrix -> CG pixels.
    ///
    /// Verified in `verify_scene_render.py` that each knob does what it says,
    /// and in `verify_scene_perspective.py` that the perspective is the divide
    /// by w rather than a scale chosen from the layer's depth.
    private func cgPoint(
        layerPoint c: SIMD2<Float>,
        layer: SceneLayer,
        projection: SceneProjection,
        height: Int
    ) -> CGPoint? {
        // A WORLD POINT, resolved before the camera sees it. Scale, shear and
        // roll come from `planePoint`, the tilt turns the card about its own
        // axes, and the layer's position places it — all of it in world space,
        // so every corner arrives at the projection with its own depth.
        //
        // The screen-space tilt that used to happen AFTER the projection is
        // gone. It only ever existed because the projection was a single scale
        // per layer and could not tilt anything; with a real matrix a tilted
        // card's near edge is wider than its far edge because that is what the
        // divide by w does to it.
        let world = SceneViewProjection.cardPoint(layer: layer, local: c)
        guard let screen = projection.project(world) else { return nil }
        // SceneProjection speaks screen coordinates (y down); CGContext draws
        // y up from the bottom-left.
        return CGPoint(x: CGFloat(screen.x), y: CGFloat(Float(height) - screen.y))
    }

    // MARK: - Drawing

    // MARK: - Bitmaps, kept rather than made

    /// Reusable bitmaps, one per size.
    ///
    /// A frame used to allocate its own: at the canvas cap that is thirteen
    /// megabytes malloc'd, zeroed by CoreGraphics, filled, read back and freed,
    /// twice per frame — once for the canvas, once for the camera preview. Per
    /// frame. At thirty frames a second that is eight hundred megabytes a
    /// second of allocation doing nothing but being allocated.
    ///
    /// Held by SIZE, because the sizes a Scene asks for are few and stable: the
    /// canvas at its cap, the canvas at its interactive cap, the preview, and
    /// one lighting scratch. A pool keyed on anything finer would never hit.
    ///
    /// Bounded in BYTES rather than in count. Counting entries would let four
    /// full-frame buffers sit in a pool that thinks it is holding four small
    /// ones, and on an iPad that is the memory that matters.
    private final class BitmapPool {
        private var contexts: [Key: CGContext] = [:]
        private var bytes = 0
        let budget: Int

        private struct Key: Hashable {
            let width: Int
            let height: Int
        }

        init(budget: Int) { self.budget = budget }

        /// A cleared context of this size, reused when one is already held.
        func context(width: Int, height: Int) -> CGContext? {
            guard width > 0, height > 0 else { return nil }
            let key = Key(width: width, height: height)
            if let held = contexts[key] {
                // CLEARED, not reset: a reused buffer still holds the last
                // frame, and a layer that draws fewer pixels this time would
                // otherwise composite over the ghost of the last one.
                held.clear(CGRect(x: 0, y: 0, width: width, height: height))
                return held
            }
            guard let made = Self.makeContext(width: width, height: height) else { return nil }
            let cost = width * height * 4
            // Evicted wholesale when the budget is passed. An LRU would be
            // bookkeeping for a set that turns over completely whenever the
            // viewport is resized, and keeps nothing useful otherwise.
            if bytes + cost > budget {
                contexts.removeAll(keepingCapacity: true)
                bytes = 0
            }
            contexts[key] = made
            bytes += cost
            return made
        }

        func evictAll() {
            contexts.removeAll(keepingCapacity: false)
            bytes = 0
        }

        static func makeContext(width: Int, height: Int) -> CGContext? {
            let info: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
                             | CGBitmapInfo.byteOrder32Little.rawValue
            guard let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info
            ) else { return nil }
            ctx.interpolationQuality = .medium
            return ctx
        }
    }

    /// Thirty-two megabytes: the canvas at its cap, its interactive cap, the
    /// preview and a scratch, with room for one resize in flight. Small enough
    /// that an iPad under pressure is not holding a second frame's worth of
    /// buffers it is not using.
    static let bitmapBudget = 32 * 1024 * 1024

    /// What the last few frames cost, and the ladder that reads it.
    ///
    /// On the RENDERER, not on the view. The view knows when the artist is
    /// moving; only the renderer knows what a frame actually took, and putting
    /// the two in one place is what lets the cap be measured rather than
    /// guessed. Not `@Published`: it changes every frame, and announcing that
    /// would invalidate every view observing this object sixty times a second —
    /// the mistake `PlayheadClock` exists to avoid.
    private(set) var frameCost = FrameCostMeter()
    private(set) var budget = SceneRenderBudget()

    /// What the last DRAW took, in milliseconds. Read by the view, which is the
    /// only thing that knows whether the frame was provisional.
    private(set) var lastDrawMilliseconds: Double = 0

    /// Report a rendered frame's cost and let the ladder move.
    func recordFrameCost(_ milliseconds: Double, isProvisional: Bool) {
        frameCost.record(milliseconds)
        budget.record(milliseconds: frameCost.milliseconds, isProvisional: isProvisional)
    }

    /// Back to full resolution. Called the moment the artist stops moving.
    func settleQuality() {
        budget.reset()
        frameCost.reset()
    }

    private lazy var framePool = BitmapPool(budget: Self.bitmapBudget)
    /// The lighting scratch. Its OWN pool, so a frame buffer and a scratch of
    /// the same size cannot be handed to both at once — which would have one
    /// compositing into the other while reading it.
    private lazy var scratchPool = BitmapPool(budget: Self.bitmapBudget)

    /// Drop everything held. Called when memory is short.
    func releaseCachedResources() {
        framePool.evictAll()
        scratchPool.evictAll()
        rigBakeCache.removeAll(keepingCapacity: false)
        rigBakeBytes = 0
        frameCache.removeAll(keepingCapacity: false)
        footprintCache.removeAll(keepingCapacity: false)
    }

    /// A bitmap of EXACTLY this many pixels.
    ///
    /// Separate from `makeContext` because that one floors at 16×16 — right for
    /// a FRAME, where a degenerate viewport must not produce a degenerate
    /// context, and wrong for anything whose size means something. Both callers
    /// here have had the same bug from inheriting that floor: a lighting window
    /// for a layer landing on twelve pixels would get a sixteen-pixel buffer
    /// and be squashed compositing back, and a rig bake of twelve rows got
    /// sixteen and left a quarter of its card blank.
    private func makeBitmap(width: Int, height: Int) -> CGContext? {
        scratchPool.context(width: width, height: height)
    }

    private func makeContext(_ size: SIMD2<Float>) -> CGContext? {
        // FROM THE POOL. The 16-pixel floor stays: it is the FRAME's, and a
        // degenerate viewport must not produce a degenerate context.
        framePool.context(width: max(Int(size.x.rounded()), 16),
                          height: max(Int(size.y.rounded()), 16))
    }

    /// Where a mesh's vertices reach the page from.
    enum TriangleVertices {
        /// Straight into a bitmap: no camera, so nothing can straddle a near
        /// plane and a vertex is either placed or it is not. The rig bake.
        case flat([CGPoint?])
        /// Through a camera. Triangles that straddle the near plane are CUT to
        /// it, carrying their UVs, rather than dropped — dropping is what made
        /// a rig instance erode from its near edge inwards as the camera came
        /// in, which `verify_scene_near_clipping.py` measures at half the mesh
        /// missing from the canvas at forty units out.
        case camera(locals: [SIMD2<Float>], mapper: CardMapper)

        var count: Int {
            switch self {
            case let .flat(points): return points.count
            case let .camera(locals, _): return locals.count
            }
        }
    }

    private func drawTriangles(
        indices: [UInt16],
        uvs: [SIMD2<Float>],
        vertices: TriangleVertices,
        image: CGImage,
        imageSize: CGSize,
        blendMode: CGBlendMode,
        opacity: CGFloat,
        ctx: CGContext
    ) {
        // UV -> UV-flipped image draw space, same convention as the PNG
        // exporter: in a Y-up context, UV.y = 0 (image top) sits at the rect's
        // maximum-y edge.
        func source(_ uv: SIMD2<Float>) -> CGPoint {
            CGPoint(x: CGFloat(uv.x) * imageSize.width,
                    y: (1 - CGFloat(uv.y)) * imageSize.height)
        }

        func emit(_ dst: (CGPoint, CGPoint, CGPoint), _ src: (CGPoint, CGPoint, CGPoint)) {
            guard let xform = TriangleAffine.transform(src: src, dst: dst) else { return }
            ctx.saveGState()
            ctx.setAlpha(opacity)
            ctx.setBlendMode(blendMode)
            ctx.beginPath()
            ctx.move(to: dst.0)
            ctx.addLine(to: dst.1)
            ctx.addLine(to: dst.2)
            ctx.closePath()
            ctx.clip()
            ctx.concatenate(xform)
            ctx.draw(image, in: CGRect(origin: .zero, size: imageSize))
            ctx.restoreGState()
        }

        // ONE CLIP AND ONE BLIT, when the pose turns out to be affine.
        //
        // Most sprites in most rigs are not deformed: a head bound rigidly to
        // one bone, a prop, a torso piece — every vertex moves by the same
        // matrix, so 120 triangles are 120 ways of drawing one image. Each of
        // those costs a path, a clip region, a matrix and a resampled blit, and
        // during playback the pose changes every frame so none of it caches.
        // Measured at 38.8 ms a frame for two instances, over a 30 fps budget
        // before anything else in the scene is drawn.
        //
        // The clip is still built from EVERY triangle, and that is not
        // laziness — it is what keeps the coverage identical. Drawing the
        // image's whole rectangle instead would show whatever lies outside the
        // mesh's hull, which is usually nothing and is occasionally artwork an
        // artist deliberately trimmed away. One path of 120 triangles costs
        // almost nothing; it is the clip SETUP and the blit, repeated, that
        // cost.
        //
        // Only for `.flat` — the rig bake. Through a camera a triangle can be
        // cut by the near plane into a quad, so the destination has more points
        // than the source and there is no affine to find.
        if case let .flat(points) = vertices,
           points.count == uvs.count,
           // EVERY vertex placed. One that is not means the bake's own map
           // refused it, and an affine solved through the rest would quietly
           // invent a position for it.
           !points.contains(where: { $0 == nil }) {
            let destination = points.compactMap { $0 }
            let sources = uvs.map(source)
            if let affine = MeshAffinity.affine(source: sources, destination: destination,
                                                tolerance: Self.affineTolerancePx) {
                ctx.saveGState()
                ctx.setAlpha(opacity)
                ctx.setBlendMode(blendMode)
                ctx.beginPath()
                var index = 0
                while index + 2 < indices.count {
                    let i0 = Int(indices[index]), i1 = Int(indices[index + 1])
                    let i2 = Int(indices[index + 2])
                    index += 3
                    guard i0 < destination.count, i1 < destination.count,
                          i2 < destination.count else { continue }
                    ctx.move(to: destination[i0])
                    ctx.addLine(to: destination[i1])
                    ctx.addLine(to: destination[i2])
                    ctx.closePath()
                }
                ctx.clip()
                ctx.concatenate(affine)
                ctx.draw(image, in: CGRect(origin: .zero, size: imageSize))
                ctx.restoreGState()
                return
            }
        }

        let vertexCount = vertices.count
        var i = 0
        while i + 2 < indices.count {
            let i0 = Int(indices[i]), i1 = Int(indices[i + 1]), i2 = Int(indices[i + 2])
            i += 3
            guard i0 < vertexCount, i1 < vertexCount, i2 < vertexCount,
                  i0 < uvs.count, i1 < uvs.count, i2 < uvs.count else { continue }

            switch vertices {
            case let .flat(points):
                guard let d0 = points[i0], let d1 = points[i1], let d2 = points[i2] else { continue }
                emit((d0, d1, d2), (source(uvs[i0]), source(uvs[i1]), source(uvs[i2])))

            case let .camera(locals, mapper):
                // The UV is the attribute that rides the cut, so a vertex
                // invented on the near plane samples the texture where the
                // triangle really crosses it.
                let polygon = [i0, i1, i2].map {
                    SceneProjection.AttributedVertex(world: mapper.world(locals[$0]),
                                                     attribute: uvs[$0])
                }
                let cut = mapper.projection.clipAndProject(polygon)
                guard cut.count >= 3 else { continue }
                // A clipped triangle is a triangle or a quad; a fan covers
                // either exactly, and the pieces are smaller than the triangle
                // they came from, so the affine each one gets is at least as
                // good as the one it replaces.
                let flip = Float(mapper.height)
                func page(_ v: SceneProjection.ProjectedVertex) -> CGPoint {
                    CGPoint(x: CGFloat(v.screen.x), y: CGFloat(flip - v.screen.y))
                }
                for k in 1..<(cut.count - 1) {
                    emit((page(cut[0]), page(cut[k]), page(cut[k + 1])),
                         (source(cut[0].attribute), source(cut[k].attribute),
                          source(cut[k + 1].attribute)))
                }
            }
        }
    }

    private func fill(
        _ fillValue: SceneFill,
        in target: RenderTarget,
        opacity: Float
    ) {
        // THE FRAME, from the target. Filling `0, 0, ctx.width, ctx.height`
        // would fill the scratch's own rectangle at the scratch's own origin,
        // which under the window's transform lands somewhere else entirely.
        let ctx = target.context
        let rect = target.canvas
        ctx.saveGState()
        ctx.setAlpha(CGFloat(max(0, min(1, opacity))))
        defer { ctx.restoreGState() }

        let top = fillValue.topColor
        if fillValue.isFlat {
            ctx.setFillColor(red: CGFloat(top.x), green: CGFloat(top.y),
                             blue: CGFloat(top.z), alpha: CGFloat(top.w))
            ctx.fill(rect)
            return
        }
        let bottom = fillValue.bottomColor
        let colors = [
            CGColor(red: CGFloat(top.x), green: CGFloat(top.y),
                    blue: CGFloat(top.z), alpha: CGFloat(top.w)),
            CGColor(red: CGFloat(bottom.x), green: CGFloat(bottom.y),
                    blue: CGFloat(bottom.z), alpha: CGFloat(bottom.w)),
        ]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray, locations: [0, 1]
        ) else {
            ctx.setFillColor(red: CGFloat(top.x), green: CGFloat(top.y),
                             blue: CGFloat(top.z), alpha: CGFloat(top.w))
            ctx.fill(rect)
            return
        }
        // Y-up context: the gradient's "top" colour starts at maximum y.
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: rect.maxY),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }
}
