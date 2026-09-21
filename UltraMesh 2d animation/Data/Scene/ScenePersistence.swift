import Foundation
import simd

// MARK: - Saved forms of the Scene model
//
// Same conventions as the rest of ProjectPersistence.swift: plain Codable
// structs mirroring the live types field by field, and everything reachable
// from SavedProjectDocument is OPTIONAL there, so projects saved before Scene
// existed decode untouched. The other direction is covered per-field here —
// unknown layer kinds decode to nil and are dropped on restore rather than
// failing the whole document, so a future layer type does not brick an old
// editor.

struct SavedSceneFill: Codable {
    var topColor: [Float]
    var bottomColor: [Float]

    init(_ fill: SceneFill) {
        topColor = [fill.topColor.x, fill.topColor.y, fill.topColor.z, fill.topColor.w]
        bottomColor = [fill.bottomColor.x, fill.bottomColor.y, fill.bottomColor.z, fill.bottomColor.w]
    }

    func restored() -> SceneFill {
        SceneFill(
            topColor: Self.color(topColor),
            bottomColor: Self.color(bottomColor)
        )
    }

    private static func color(_ components: [Float]) -> SIMD4<Float> {
        guard components.count == 4 else { return SIMD4<Float>(0, 0, 0, 1) }
        return SIMD4<Float>(components[0], components[1], components[2], components[3])
    }
}

struct SavedSceneShotCamera: Codable {
    var position: SavedSIMD2
    var positionZ: Float
    var rotation3D: SavedSIMD3
    var fieldOfView: Float
    var nearZ: Float
    var farZ: Float

    init(_ camera: SceneCamera) {
        position = SavedSIMD2(camera.position)
        positionZ = camera.positionZ
        rotation3D = SavedSIMD3(camera.rotation3D)
        fieldOfView = camera.fieldOfView
        nearZ = camera.nearZ
        farZ = camera.farZ
    }

    func restored() -> SceneCamera {
        SceneCamera(
            position: position.simdValue,
            positionZ: positionZ,
            rotation3D: rotation3D.simdValue,
            // Clamped on the way in, not just in the UI: a hand-edited or
            // corrupt file must not produce a camera that divides by tan(0)
            // or draws nothing forever.
            fieldOfView: min(max(fieldOfView, 1), 170),
            nearZ: max(nearZ, 0.01),
            farZ: max(farZ, max(nearZ, 0.01) + 1)
        )
    }
}

// MARK: - Lights

struct SavedLightFalloffStop: Codable {
    var position: Float
    var value: Float
    var inTangent: SavedSIMD2?
    var outTangent: SavedSIMD2?

    init(_ stop: LightFalloffStop) {
        position = stop.position
        value = stop.value
        inTangent = stop.inTangent.map(SavedSIMD2.init)
        outTangent = stop.outTangent.map(SavedSIMD2.init)
    }

    func restored() -> LightFalloffStop {
        LightFalloffStop(position: position, value: value,
                         inTangent: inTangent?.simdValue,
                         outTangent: outTangent?.simdValue)
    }
}

struct SavedSceneLight: Codable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var kind: String
    var position: SavedSIMD2
    var positionZ: Float
    var azimuth: Float
    var elevation: Float
    var radius: Float
    var intensity: Float
    var color: SavedSIMD3
    var falloff: [SavedLightFalloffStop]
    var softness: Float
    var innerAngle: Float
    var outerAngle: Float
    var mask: UInt8
    var blend: String
    var depthInfluence: Float
    var normalInfluence: Float
    var castsShadows: Bool

    init(_ light: SceneLight) {
        id = light.id
        name = light.name
        isEnabled = light.isEnabled
        kind = light.kind.rawValue
        position = SavedSIMD2(light.position)
        positionZ = light.positionZ
        azimuth = light.azimuth
        elevation = light.elevation
        radius = light.radius
        intensity = light.intensity
        color = SavedSIMD3(light.color)
        falloff = light.falloff.stops.map(SavedLightFalloffStop.init)
        softness = light.softness
        innerAngle = light.innerAngle
        outerAngle = light.outerAngle
        mask = light.mask.rawValue
        blend = light.blend.rawValue
        depthInfluence = light.depthInfluence
        normalInfluence = light.normalInfluence
        castsShadows = light.castsShadows
    }

    /// A light restored with every range enforced on the way IN.
    ///
    /// Not only in the inspector. A hand-edited or truncated file must not be
    /// able to produce a light that divides by a zero band, inverts its cone,
    /// or reaches every layer because its mask decoded as nothing — and a
    /// cone whose inner angle exceeds its outer would make the smoothstep
    /// between them run backwards, which reads as a spot lit inside out.
    func restored() -> SceneLight {
        let outer = min(max(outerAngle, 0), Float.pi)
        return SceneLight(
            id: id,
            name: name,
            isEnabled: isEnabled,
            kind: SceneLightKind(rawValue: kind) ?? .point,
            position: position.simdValue,
            positionZ: positionZ,
            azimuth: azimuth,
            elevation: elevation,
            radius: max(radius, 0),
            intensity: max(intensity, 0),
            color: color.simdValue,
            falloff: LightFalloffCurve(falloff.map { $0.restored() }),
            softness: min(max(softness, 0), 1),
            innerAngle: min(max(innerAngle, 0), outer),
            outerAngle: outer,
            // An empty mask would be a light that lights nothing, which is
            // indistinguishable from the file being wrong. All channels.
            mask: mask == 0 ? .all : SceneLightMask(rawValue: mask),
            blend: SceneLightBlend(rawValue: blend) ?? .normal,
            depthInfluence: min(max(depthInfluence, 0), 1),
            normalInfluence: min(max(normalInfluence, 0), 1),
            castsShadows: castsShadows
        )
    }
}

struct SavedSceneAmbient: Codable {
    var color: SavedSIMD3
    var intensity: Float

    init(_ ambient: SceneAmbient) {
        color = SavedSIMD3(ambient.color)
        intensity = ambient.intensity
    }

    func restored() -> SceneAmbient {
        SceneAmbient(color: color.simdValue, intensity: max(intensity, 0))
    }
}

/// A layer's surface, written only when it is not the default.
///
/// OPTIONAL ALL THE WAY DOWN, and each field optional inside it. That is the
/// rule the rest of this file already follows and it earns its keep twice
/// here: a project saved before materials existed decodes with `material` nil
/// and restores `SceneMaterial.flat`, which is the surface Scene has always
/// drawn; and a project saved by a later build that adds a field decodes in
/// THIS build with that field nil rather than failing the whole document.
struct SavedSceneMaterial: Codable {
    var normalMapAssetID: UUID?
    var normalStrength: Float?
    var smoothness: Float?
    var contrast: Float?
    var shadowCastMask: UInt8?
    var shadowedMask: UInt8?

    init(_ material: SceneMaterial) {
        normalMapAssetID = material.normalMapAssetID
        normalStrength = material.normalStrength
        smoothness = material.smoothness
        contrast = material.contrast
        shadowCastMask = material.shadowCastMask.rawValue
        shadowedMask = material.shadowedMask.rawValue
    }

    /// Sanitised on the way in, not merely on the way to the GPU.
    ///
    /// The shader's branches are `smoothness <= 0` and `contrast <= 0`, so a
    /// negative value out of a hand-edited or truncated file takes the slow
    /// path and computes a wrap with a negative width -- which pushes the
    /// terminator the wrong way and reads as an inverted light, not as a bad
    /// number.
    func restored() -> SceneMaterial {
        SceneMaterial(
            normalMapAssetID: normalMapAssetID,
            normalStrength: normalStrength ?? 1,
            smoothness: smoothness ?? 0,
            contrast: contrast ?? 0,
            shadowCastMask: SceneLightMask(rawValue: shadowCastMask ?? 0),
            shadowedMask: SceneLightMask(rawValue: shadowedMask ?? 0)
        ).sanitized
    }
}

struct SavedSceneLayer: Codable {
    /// Which case of `SceneLayerContent` this row is. String, not an int, so a
    /// file inspected by hand reads as what it is.
    enum Kind: String, Codable { case rig, plate, fill }

    var id: UUID
    var name: String
    var isHidden: Bool
    var opacity: Float
    var position: SavedSIMD2
    var positionZ: Float
    var rotation: Float
    var rotation3D: SavedSIMD3
    var scale: SavedSIMD2
    /// Optional so a project written before Scene layers could shear still
    /// opens; a missing slant is no slant.
    var shear: SavedSIMD2?
    /// Optional for the same reason, and the defaults matter: a project saved
    /// before lighting existed restores on channel 1 and receiving, which is
    /// what makes a light added to it later actually reach anything.
    var lightMask: UInt8?
    var receivesLight: Bool?
    /// Optional, and the default is what makes an old scene render IDENTICALLY.
    ///
    /// A project saved before layers had numbers had its stacking in the array
    /// ORDER, so restoring each layer's index as its number reproduces exactly
    /// the draw order it was saved with. Defaulting to zero would have put
    /// every card on one layer and left the tie-break to sort them — which is
    /// the same order, by luck, and would stop being so the moment anybody
    /// touched one number.
    var sortingOrder: Int?

    var kind: Kind
    // Per-kind payloads, only the relevant ones written.
    var clipID: UUID?
    var speed: Float?
    var startFrame: Int?
    var loops: Bool?
    var assetID: UUID?
    var fill: SavedSceneFill?
    /// Optional, and nil restores `SceneMaterial.flat` -- the surface every
    /// project that predates this one was drawn with.
    var material: SavedSceneMaterial?

    init(_ layer: SceneLayer) {
        id = layer.id
        name = layer.name
        isHidden = layer.isHidden
        opacity = layer.opacity
        position = SavedSIMD2(layer.position)
        positionZ = layer.positionZ
        rotation = layer.rotation
        rotation3D = SavedSIMD3(layer.rotation3D)
        scale = SavedSIMD2(layer.scale)
        shear = SavedSIMD2(layer.shear)
        lightMask = layer.lightMask.rawValue
        receivesLight = layer.receivesLight
        sortingOrder = layer.sortingOrder
        material = SavedSceneMaterial(layer.material)

        switch layer.content {
        case let .rig(clipID, speed, startFrame, loops):
            kind = .rig
            self.clipID = clipID
            self.speed = speed
            self.startFrame = startFrame
            self.loops = loops
        case let .plate(assetID):
            kind = .plate
            self.assetID = assetID
        case let .fill(fillValue):
            kind = .fill
            fill = SavedSceneFill(fillValue)
        }
    }

    /// Nil when the payload its kind needs is missing — the layer is dropped
    /// rather than restored as something it never was.
    ///
    /// `fallbackOrder` is this layer's index in the file, used as its layer
    /// number when the file predates them.
    func restored(fallbackOrder: Int = 0) -> SceneLayer? {
        let content: SceneLayerContent
        switch kind {
        case .rig:
            guard let clipID else { return nil }
            content = .rig(
                clipID: clipID,
                speed: speed ?? 1,
                startFrame: startFrame ?? 0,
                loops: loops ?? true
            )
        case .plate:
            guard let assetID else { return nil }
            content = .plate(assetID: assetID)
        case .fill:
            guard let fill else { return nil }
            content = .fill(fill.restored())
        }

        return SceneLayer(
            id: id,
            name: name,
            isHidden: isHidden,
            opacity: min(max(opacity, 0), 1),
            position: position.simdValue,
            positionZ: positionZ,
            rotation: rotation,
            rotation3D: rotation3D.simdValue,
            scale: scale.simdValue,
            shear: shear?.simdValue ?? .zero,
            sortingOrder: sortingOrder ?? fallbackOrder,
            lightMask: lightMask.map { $0 == 0 ? .layer1 : SceneLightMask(rawValue: $0) } ?? .layer1,
            receivesLight: receivesLight ?? true,
            material: material?.restored() ?? .flat,
            content: content
        )
    }
}

struct SavedSceneComposition: Codable {
    var id: UUID
    var name: String
    var layers: [SavedSceneLayer]
    var camera: SavedSceneShotCamera
    /// Optional: a scene saved before lighting existed has none, and restores
    /// with none, which is the identity case the renderer skips outright.
    var lights: [SavedSceneLight]?
    var ambient: SavedSceneAmbient?
    var background: SavedSceneFill
    var durationInFrames: Int
    var fps: Int
    var renderSize: SavedSIMD2

    init(_ composition: SceneComposition) {
        id = composition.id
        name = composition.name
        layers = composition.layers.map(SavedSceneLayer.init)
        camera = SavedSceneShotCamera(composition.camera)
        lights = composition.lights.map(SavedSceneLight.init)
        ambient = SavedSceneAmbient(composition.ambient)
        background = SavedSceneFill(composition.background)
        durationInFrames = composition.durationInFrames
        fps = composition.fps
        renderSize = SavedSIMD2(composition.renderSize)
    }

    func restored() -> SceneComposition {
        SceneComposition(
            id: id,
            name: name,
            // Enumerated, so a layer written before layer numbers existed takes
            // its position in the file as its number and the scene restores in
            // exactly the order it was saved in.
            layers: layers.enumerated().compactMap { $0.element.restored(fallbackOrder: $0.offset) },
            camera: camera.restored(),
            lights: lights?.map { $0.restored() } ?? [],
            ambient: ambient?.restored() ?? .neutral,
            background: background.restored(),
            durationInFrames: max(durationInFrames, 1),
            fps: min(max(fps, 1), 240),
            renderSize: SIMD2<Float>(
                max(renderSize.simdValue.x, 16),
                max(renderSize.simdValue.y, 16)
            )
        )
    }
}

/// Where the artist was standing, saved the way a window position is.
///
/// Editor convenience, never scene data: it is not keyframed, not exported, and
/// dropping this struct from a file loses nothing but a viewpoint.
struct SavedSceneViewCamera: Codable {
    var pivot: SavedSIMD3
    var distance: Float
    var pitch: Float
    var yaw: Float
    var fieldOfView: Float

    init(_ camera: SceneViewCamera) {
        pivot = SavedSIMD3(camera.pivot)
        distance = camera.distance
        pitch = camera.pitch
        yaw = camera.yaw
        fieldOfView = camera.fieldOfView
    }

    func restored() -> SceneViewCamera {
        SceneViewCamera(
            pivot: pivot.simdValue,
            distance: min(max(distance, SceneViewCamera.minDistance),
                          SceneViewCamera.maxDistance),
            // The same clamps the live camera enforces, applied on the way in:
            // a file must not be able to put the view somewhere the controls
            // cannot reach or leave.
            pitch: min(max(pitch, -SceneViewCamera.pitchLimit),
                       SceneViewCamera.pitchLimit),
            yaw: yaw,
            fieldOfView: min(max(fieldOfView, 1), 170)
        )
    }
}
