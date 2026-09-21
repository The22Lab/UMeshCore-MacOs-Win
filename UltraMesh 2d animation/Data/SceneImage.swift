import Foundation
import simd

enum TransformAnimationSpace: Equatable {
    case world
    case boneLocal(UUID)

    var boneID: UUID? {
        switch self {
        case .world:
            return nil
        case let .boneLocal(boneID):
            return boneID
        }
    }
}

struct BoneImageBinding: Equatable {
    var boneID: UUID
    var localPosition: SIMD2<Float>
    var localScale: SIMD2<Float>
    var localRotation: Float
    var localSkew: SIMD2<Float>

    var localPose: SceneImageAnimationPose {
        SceneImageAnimationPose(
            position: localPosition,
            scale: localScale,
            rotation: localRotation,
            skew: localSkew
        )
    }
}

/// How a sprite composites against what is already drawn.
///
/// These are the standard 2D effect modes. They are a per-sprite property
/// rather than a material choice because the runtime carries the tint as vertex
/// colour and only breaks its draw-call batch when the *mode* changes.
enum ImageBlendMode: String, Codable, CaseIterable, Equatable {
    case normal
    case additive
    case multiply
    case screen

    var title: String {
        switch self {
        case .normal:   return "Normal"
        case .additive: return "Additive"
        case .multiply: return "Multiply"
        case .screen:   return "Screen"
        }
    }

    /// Fixed order used to index the renderer's per-mode pipeline states.
    /// Declared explicitly rather than reusing `allCases` so reordering the
    /// cases (or adding one for the UI) cannot silently repoint a pipeline.
    static let pipelineOrder: [ImageBlendMode] = [.normal, .additive, .multiply, .screen]

    var pipelineIndex: Int {
        switch self {
        case .normal:   return 0
        case .additive: return 1
        case .multiply: return 2
        case .screen:   return 3
        }
    }
}

struct SceneImage: Identifiable, Equatable {
    let id: UUID
    let assetID: UUID
    var name: String
    var basePosition: SIMD2<Float>
    var position: SIMD2<Float>
    var baseScale: SIMD2<Float>
    var scale: SIMD2<Float>
    var baseRotation: Float
    var rotation: Float
    var baseRotation3D: SIMD3<Float>
    var rotation3D: SIMD3<Float>
    var baseSkew: SIMD2<Float>
    var skew: SIMD2<Float>
    var mesh: Mesh
    var meshAnimationDeform: [SIMD2<Float>]? = nil
    var boneBinding: BoneImageBinding?
    var isHidden: Bool
    /// Slot this sprite can occupy. Sprites sharing a slot name are variants of
    /// the same attachment point and only one is shown at a time, chosen by the
    /// active skin. Empty means the sprite is its own slot, which is the state
    /// every rig starts in and keeps until the artist groups sprites.
    var slotName: String = ""
    /// The normal map paired with this sprite's artwork, if it has one.
    ///
    /// PER SPRITE AND NOT PER LAYER, because a normal map is the pair of ONE
    /// PNG. A rig is many PNGs with different relief on each, so a single map
    /// for the whole instance would light every sprite by the arm's bumps. The
    /// rest of the material -- how far light wraps, how sharply it separates,
    /// which shadows are cast and caught -- stays on `SceneLayer`, because
    /// those describe how the card sits in the set rather than what is drawn
    /// on it.
    ///
    /// Defaulted, so every existing construction site keeps compiling and
    /// every existing rig keeps rendering exactly as it did.
    var normalMapAssetID: UUID? = nil
    /// Tint multiplied into the sprite (RGBA). Opaque white leaves it untouched.
    /// Defaulted so every existing construction site keeps compiling.
    var tintColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    var blendMode: ImageBlendMode = .normal
    var animationClip: AnimationClip
    var animationTransformSpace: TransformAnimationSpace

    /// The slot this sprite actually belongs to. Sprites that were never
    /// assigned a slot stand alone under their own name.
    var effectiveSlotName: String {
        slotName.isEmpty ? name : slotName
    }

    var basePose: SceneImageAnimationPose {
        SceneImageAnimationPose(
            position: basePosition,
            scale: baseScale,
            rotation: baseRotation,
            skew: baseSkew
        )
    }
}
