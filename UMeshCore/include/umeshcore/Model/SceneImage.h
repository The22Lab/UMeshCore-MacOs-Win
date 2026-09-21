#pragma once

// 1:1 port of `Data/SceneImage.swift` -- a sprite: its transform (authored
// "base" pose + live pose driven by tools/animation), its mesh, optional
// bone binding, and rendering attributes.

#include <optional>
#include <string>

#include "umeshcore/Animation/AnimationClip.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Mesh/Mesh.h"

namespace umeshcore {

// Which frame a sprite's animation tracks are expressed in: world space, or
// local to a bone (so the sprite's animated offset stays attached to the
// bone's own motion). nullopt boneID = world.
struct TransformAnimationSpace {
    std::optional<Uuid> boneID;

    static TransformAnimationSpace world() { return TransformAnimationSpace{}; }
    static TransformAnimationSpace boneLocal(Uuid id) { return TransformAnimationSpace{id}; }

    bool operator==(const TransformAnimationSpace&) const = default;
};

struct BoneImageBinding {
    Uuid boneID;
    Vec2 localPosition;
    Vec2 localScale = Vec2::one();
    float localRotation = 0.0f;
    Vec2 localSkew = Vec2::zero();

    SceneImageAnimationPose localPose() const {
        SceneImageAnimationPose pose;
        pose.position = localPosition;
        pose.scale = localScale;
        pose.rotation = localRotation;
        pose.skew = localSkew;
        return pose;
    }

    bool operator==(const BoneImageBinding&) const = default;
};

// How a sprite composites against what is already drawn. Per-sprite (not a
// material choice) because the runtime carries tint as vertex color and
// only breaks its draw-call batch when the MODE changes.
enum class ImageBlendMode { Normal, Additive, Multiply, Screen };

// Fixed order used to index the renderer's per-mode pipeline states,
// declared explicitly (not derived from enum order) so reordering the enum
// cannot silently repoint a pipeline.
inline int pipelineIndex(ImageBlendMode mode) {
    switch (mode) {
        case ImageBlendMode::Normal: return 0;
        case ImageBlendMode::Additive: return 1;
        case ImageBlendMode::Multiply: return 2;
        case ImageBlendMode::Screen: return 3;
    }
    return 0;
}

struct SceneImage {
    Uuid id = Uuid::generate();
    Uuid assetID;
    std::string name;
    Vec2 basePosition;
    Vec2 position;
    Vec2 baseScale = Vec2::one();
    Vec2 scale = Vec2::one();
    float baseRotation = 0.0f;
    float rotation = 0.0f;
    Vec3 baseRotation3D;
    Vec3 rotation3D;
    Vec2 baseSkew = Vec2::zero();
    Vec2 skew = Vec2::zero();
    Mesh mesh;
    std::optional<std::vector<Vec2>> meshAnimationDeform;
    std::optional<BoneImageBinding> boneBinding;
    bool isHidden = false;
    // Slot this sprite can occupy. Sprites sharing a slot name are variants
    // of the same attachment point; only one is shown at a time, chosen by
    // the active skin. Empty means the sprite is its own slot.
    std::string slotName;
    std::optional<Uuid> normalMapAssetID;
    Vec4 tintColor = Vec4(1, 1, 1, 1);
    ImageBlendMode blendMode = ImageBlendMode::Normal;
    AnimationClip animationClip;
    TransformAnimationSpace animationTransformSpace;

    SceneImage() : animationClip("") {}

    // The slot this sprite actually belongs to; sprites never assigned a
    // slot stand alone under their own name.
    std::string effectiveSlotName() const { return slotName.empty() ? name : slotName; }

    SceneImageAnimationPose basePose() const {
        SceneImageAnimationPose pose;
        pose.position = basePosition;
        pose.scale = baseScale;
        pose.rotation = baseRotation;
        pose.skew = baseSkew;
        return pose;
    }
};

// 1:1 port of `SceneManager.meshPose(for:)`: the sprite's CURRENT (not
// base/authored) pose, in the shape `Mesh::skinnedVertices` needs to fold
// bind-space points back through.
inline MeshBindPose meshPose(const SceneImage& image) {
    MeshBindPose pose;
    pose.position = image.position;
    pose.rotation = image.rotation;
    pose.scale = image.scale;
    pose.skew = image.skew;
    return pose;
}

} // namespace umeshcore
