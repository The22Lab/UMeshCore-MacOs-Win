#include "umeshcore/Constraints/TransformConstraintSolver.h"

#include <cmath>

#include "umeshcore/Constraints/ConstraintPropagation.h"
#include "umeshcore/Math/Angle.h"
#include "umeshcore/Math/Transform3D2D.h"
#include "umeshcore/Model/Skeleton.h"

namespace umeshcore::TransformConstraintSolver {

namespace {
inline float clamp01(float x) { return x < 0.0f ? 0.0f : (x > 1.0f ? 1.0f : x); }
} // namespace

// World matrix composition is T*Rz*Sk*S -> upper-left 2x2 holds
// rotation*skew*scale; column 3 holds translation.
Decomposed2D decompose(const Mat4& m) {
    const float a = m.columns[0].x;
    const float b = m.columns[0].y;
    const float c = m.columns[1].x;
    const float d = m.columns[1].y;
    const float scaleX = std::sqrt(a * a + b * b);
    const float rotation = std::atan2(b, a);
    // Express the Y-axis in a frame rotated by -rotation. With no skew the
    // Y-axis there is (0, scaleY); with skew X it becomes (scaleY*tan(skewX), scaleY).
    const float cosR = std::cos(rotation);
    const float sinR = std::sin(rotation);
    const float yLocalX = cosR * c + sinR * d;
    const float yLocalY = -sinR * c + cosR * d;
    const float scaleY = std::sqrt(yLocalX * yLocalX + yLocalY * yLocalY);
    // atan2(yLocalX, yLocalY) is the angle by which Y has departed from +90
    // degrees relative to X -- i.e. shear X.
    const float skewX = std::atan2(yLocalX, yLocalY);
    Decomposed2D out;
    out.position = Vec2(m.columns[3].x, m.columns[3].y);
    out.rotation = rotation;
    out.scaleX = std::isfinite(scaleX) ? scaleX : 1.0f;
    out.scaleY = std::isfinite(scaleY) ? scaleY : 1.0f;
    out.skewX = std::isfinite(skewX) ? skewX : 0.0f;
    out.skewY = 0.0f;
    return out;
}

// Recompose using the project's standard composition order (T*Rz*Sk*S),
// delegating to Transform3D2D::matrix() for byte-identical behavior with
// the rest of the rig pipeline.
Mat4 compose(const Decomposed2D& d) {
    Transform3D2D xform(
        Vec3(d.position.x, d.position.y, 0), Vec3(0, 0, d.rotation), Vec3(d.scaleX, d.scaleY, 1),
        Vec2(d.skewX, d.skewY));
    return xform.matrix();
}

void solve(const TransformConstraint& constraint, const Skeleton& skeleton, WorldMatrices& worldMatrices) {
    const float masterMix = clamp01(constraint.mix_);
    if (!(masterMix > 0.0001f)) return;
    if (skeleton.bone(constraint.targetBoneID) == nullptr) return;
    auto targetIt = worldMatrices.find(constraint.targetBoneID);
    if (targetIt == worldMatrices.end()) return;

    const float pMix = constraint.copyPosition ? clamp01(constraint.positionMix) * masterMix : 0.0f;
    const float rMix = constraint.copyRotation ? clamp01(constraint.rotationMix) * masterMix : 0.0f;
    const float sMix = constraint.copyScale ? clamp01(constraint.scaleMix) * masterMix : 0.0f;
    const float kMix = constraint.copyShear ? clamp01(constraint.shearMix) * masterMix : 0.0f;
    if (!(pMix + rMix + sMix + kMix > 0.0001f)) return;

    const Decomposed2D target = decompose(targetIt->second);

    const auto& childrenByParent = skeleton.childrenIndexForPropagation();
    for (Uuid boneID : constraint.affectedBones) {
        if (skeleton.bone(boneID) == nullptr) continue;
        auto currentIt = worldMatrices.find(boneID);
        if (currentIt == worldMatrices.end()) continue;
        if (boneID == constraint.targetBoneID) continue; // don't let a bone constrain itself.

        Decomposed2D current = decompose(currentIt->second);

        if (pMix > 0.0f) {
            const float tx = target.position.x + constraint.offsetPositionX;
            const float ty = target.position.y + constraint.offsetPositionY;
            current.position.x += (tx - current.position.x) * pMix;
            current.position.y += (ty - current.position.y) * pMix;
        }

        if (rMix > 0.0f) {
            const float targetRot = target.rotation + constraint.offsetRotation;
            const float delta = shortestAngleDelta(current.rotation, targetRot);
            current.rotation += delta * rMix;
        }

        if (sMix > 0.0f) {
            const float tsx = target.scaleX + constraint.offsetScaleX;
            const float tsy = target.scaleY + constraint.offsetScaleY;
            current.scaleX += (tsx - current.scaleX) * sMix;
            current.scaleY += (tsy - current.scaleY) * sMix;
        }

        if (kMix > 0.0f) {
            const float targetSkew = target.skewX + constraint.offsetShear;
            current.skewX += (targetSkew - current.skewX) * kMix;
        }

        worldMatrices[boneID] = compose(current);
        ConstraintPropagation::cascade(boneID, std::nullopt, skeleton, childrenByParent, worldMatrices);
    }
}

} // namespace umeshcore::TransformConstraintSolver

namespace umeshcore {

void TransformConstraint::apply(const Skeleton& skeleton, WorldMatrices& worldMatrices) const {
    TransformConstraintSolver::solve(*this, skeleton, worldMatrices);
}

} // namespace umeshcore
