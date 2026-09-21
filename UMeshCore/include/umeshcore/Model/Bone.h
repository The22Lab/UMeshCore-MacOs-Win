#pragma once

// 1:1 port of `Data/Bone.swift`.

#include <algorithm>
#include <cmath>
#include <optional>
#include <string>
#include <vector>

#include "umeshcore/Animation/AnimationClip.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/MatrixUtilities.h"
#include "umeshcore/Math/Transform3D2D.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

struct Bone {
    Uuid id = Uuid::generate();
    std::string name;
    std::optional<Uuid> parentID;
    Transform3D2D baseTransform;
    Transform3D2D localTransform;
    float length = 96.0f;
    AnimationClip animationClip;
    // The colour weight paint gives this bone, or nullopt when nothing is
    // bound to it. Belongs to the BINDING, not the bone -- see
    // `bindingColor` below for why it's assigned on bind, not on creation.
    std::optional<Vec4> color;

    Bone() : animationClip("") {}

    Bone(std::string name_, std::optional<Uuid> parentID_, std::optional<Transform3D2D> baseTransform_,
         Transform3D2D localTransform_, float length_, std::optional<AnimationClip> animationClip_,
         std::optional<Vec4> color_)
        : name(std::move(name_)),
          parentID(parentID_),
          baseTransform(baseTransform_.value_or(localTransform_)),
          localTransform(localTransform_),
          length(length_),
          animationClip(animationClip_.has_value() ? std::move(*animationClip_) : AnimationClip(name)),
          color(color_) {}

    Mat4 worldMatrix(std::optional<Mat4> parentMatrix) const {
        const Mat4 local = localTransform.matrix();
        return (parentMatrix ? *parentMatrix : MatrixUtilities::identity()) * local;
    }

    Vec2 localStart() const { return Vec2(localTransform.position.x, localTransform.position.y); }

    Vec2 localEnd() const {
        const Vec2 direction(std::cos(localTransform.rotation.z), std::sin(localTransform.rotation.z));
        return localStart() + direction * length;
    }

    static Bone makeRoot(const std::string& name, Vec2 start, Vec2 end) {
        return make(name, start, end, std::nullopt, std::nullopt);
    }

    static Bone make(
        const std::string& name, Vec2 start, Vec2 end, std::optional<Uuid> parentID,
        std::optional<Mat4> parentMatrix) {
        Vec2 localStartPoint = start;
        Vec2 localEndPoint = end;
        if (parentMatrix.has_value()) {
            const Mat4 parentInverse = inverse(*parentMatrix);
            const Vec3 s = MatrixUtilities::transformPoint(Vec3(start.x, start.y, 0), parentInverse);
            const Vec3 e = MatrixUtilities::transformPoint(Vec3(end.x, end.y, 0), parentInverse);
            localStartPoint = Vec2(s.x, s.y);
            localEndPoint = Vec2(e.x, e.y);
        }
        const Vec2 delta = localEndPoint - localStartPoint;
        // Qualified: this class has its own `length` field, which would
        // otherwise shadow the free vector-length function of the same name.
        const float boneLength = std::max(umeshcore::length(delta), 12.0f);
        const float rotation = std::atan2(delta.y, delta.x);
        return Bone(
            name, parentID,
            Transform3D2D(
                Vec3(localStartPoint.x, localStartPoint.y, 0), Vec3(0, 0, rotation), Vec3::one(),
                Vec2::zero()),
            Transform3D2D(
                Vec3(localStartPoint.x, localStartPoint.y, 0), Vec3(0, 0, rotation), Vec3::one(),
                Vec2::zero()),
            boneLength, AnimationClip(name), std::nullopt);
    }

    // --- Distinct binding colours (ported for editor/hierarchy parity) ---

    // The alpha the weight overlay draws a bone colour at.
    static constexpr float kOverlayAlpha = 0.60f;

    static Vec4 distinctColor(int index);
    static Vec3 asDrawn(const Vec4& colour, const Vec3& background = Vec3::one());
    static Vec3 oklab(const Vec3& rgb);
    static Vec4 bindingColor(Uuid boneID, const std::vector<Vec4>& used);

private:
    static Vec3 hsvToRgb(float h, float s, float v);
};

} // namespace umeshcore
