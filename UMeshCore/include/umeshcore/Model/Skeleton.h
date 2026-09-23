#pragma once

// 1:1 port of `Data/Skeleton.swift`.

#include <algorithm>
#include <cmath>
#include <optional>
#include <unordered_map>
#include <vector>

#include "umeshcore/Constraints/Constraint.h"
#include "umeshcore/Constraints/IKConstraint.h"
#include "umeshcore/Constraints/PathConstraint.h"
#include "umeshcore/Constraints/PhysicsConstraint.h"
#include "umeshcore/Constraints/TransformConstraint.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Model/Bone.h"

namespace umeshcore {

class Skeleton {
public:
    std::vector<Uuid> rootIDs;

    // Concrete constraint stores, mirroring the Swift source's four typed
    // arrays (rather than one polymorphic array) -- `allConstraints()`
    // exposes them as a sorted, type-erased view for the solver pass.
    std::vector<IKConstraint> ikConstraints;
    std::vector<TransformConstraint> transformConstraints;
    std::vector<PathConstraint> pathConstraints;
    std::vector<PhysicsConstraint> physicsConstraints;

    Skeleton() { rebuildChildrenIndex(); }

    // --- Bones (the didSet-equivalent: children index invalidated only on
    // parent-link changes, see rebuildChildrenIndex / parentLinksDiffer) ---

    const std::unordered_map<Uuid, Bone, UuidHash>& bones() const { return bones_; }

    // Insert or replace a bone. Rebuilds the children index only if this
    // changes any bone's parent link (matching Skeleton.swift's
    // `parentLinksDiffer` check on the whole `didSet`).
    void setBone(const Bone& bone) {
        auto it = bones_.find(bone.id);
        const bool parentChanged = (it == bones_.end()) || (it->second.parentID != bone.parentID);
        bones_[bone.id] = bone;
        if (parentChanged) rebuildChildrenIndex();
    }

    void setBones(std::unordered_map<Uuid, Bone, UuidHash> newBones) {
        const bool changed = parentLinksDiffer(newBones, bones_);
        bones_ = std::move(newBones);
        if (changed) rebuildChildrenIndex();
    }

    const Bone* bone(Uuid id) const {
        auto it = bones_.find(id);
        return it == bones_.end() ? nullptr : &it->second;
    }

    // `skeleton.bones.removeValue(forKey:)`. Leaves `rootIDs` and any child
    // still naming this bone as its parent alone -- the caller decides what
    // happens to them, as `SceneManager.removeBones` does.
    void removeBone(Uuid id) {
        if (bones_.erase(id) > 0) rebuildChildrenIndex();
    }

    // Every constraint regardless of concrete type, ready for evaluation.
    std::vector<const BoneConstraint*> allConstraints() const {
        std::vector<const BoneConstraint*> out;
        out.reserve(
            ikConstraints.size() + transformConstraints.size() + pathConstraints.size() +
            physicsConstraints.size());
        for (const auto& c : ikConstraints) out.push_back(&c);
        for (const auto& c : transformConstraints) out.push_back(&c);
        for (const auto& c : pathConstraints) out.push_back(&c);
        for (const auto& c : physicsConstraints) out.push_back(&c);
        return out;
    }

    // World matrices with all enabled constraints applied in `order`
    // ascending. Unlike the Swift source, this overload never steps
    // physics -- physics is a stateful, per-rig-instance concern here (see
    // PhysicsConstraint.h), stepped explicitly by whatever owns both this
    // Skeleton and a PhysicsSimState, then blended in via
    // PhysicsConstraintSystem::applyConstraint. Non-physics constraints
    // (IK/Transform/Path) are applied exactly as in Swift.
    WorldMatrices worldMatrices() const {
        WorldMatrices result = baseWorldMatrices();
        std::vector<const BoneConstraint*> active;
        for (const auto* c : allConstraints()) {
            if (c->enabled() && c->mix() > 0.0001f) active.push_back(c);
        }
        std::stable_sort(active.begin(), active.end(), [](const BoneConstraint* a, const BoneConstraint* b) {
            return a->order() < b->order();
        });
        for (const auto* c : active) {
            c->apply(*this, result);
        }
        return result;
    }

    // World matrices BEFORE any constraint runs.
    WorldMatrices baseWorldMatrices() const {
        WorldMatrices result;
        result.reserve(bones_.size());
        for (Uuid root : rootIDs) {
            computeWorldMatrix(root, std::nullopt, result, cachedChildrenIndex_);
        }
        return result;
    }

    // Children of a bone, computed fresh each call (matches Swift's
    // `childrenOf`, which is documented as intentionally uncached -- only
    // `childrenIndexForPropagation()` below is the cached fast path).
    std::vector<Uuid> childrenOf(Uuid boneID) const {
        std::vector<Uuid> out;
        for (const auto& [id, bone] : bones_) {
            if (bone.parentID.has_value() && *bone.parentID == boneID) out.push_back(id);
        }
        return out;
    }

    // Parent -> children map, rebuilt only when parent links change. See
    // Bone.h-adjacent comment in Skeleton.swift: this exists because
    // walking with childrenOf() during constraint cascades was measured
    // quadratic in rig size.
    const std::unordered_map<Uuid, std::vector<Uuid>, UuidHash>& childrenIndexForPropagation() const {
        return cachedChildrenIndex_;
    }

    std::vector<Bone> orderedBones() const {
        std::vector<Bone> out;
        out.reserve(bones_.size());
        std::unordered_map<Uuid, bool, UuidHash> isRoot;
        for (Uuid id : rootIDs) {
            auto it = bones_.find(id);
            if (it != bones_.end()) {
                out.push_back(it->second);
                isRoot[id] = true;
            }
        }
        for (const auto& [id, bone] : bones_) {
            if (!isRoot.contains(id)) out.push_back(bone);
        }
        return out;
    }

    std::optional<Mat4> worldMatrix(Uuid id) const {
        const auto matrices = worldMatrices();
        auto it = matrices.find(id);
        return it == matrices.end() ? std::nullopt : std::optional<Mat4>(it->second);
    }

    std::optional<Mat4> parentWorldMatrix(std::optional<Uuid> boneID) const {
        if (!boneID.has_value()) return std::nullopt;
        const Bone* b = bone(*boneID);
        if (b == nullptr || !b->parentID.has_value()) return std::nullopt;
        return worldMatrix(*b->parentID);
    }

    struct LineSegment {
        Vec2 start;
        Vec2 end;
    };

    std::optional<LineSegment> lineSegment(Uuid boneID) const {
        return lineSegment(boneID, worldMatrices());
    }

    std::optional<LineSegment> lineSegment(Uuid boneID, const WorldMatrices& pose) const {
        const Bone* b = bone(boneID);
        auto it = pose.find(boneID);
        if (b == nullptr || it == pose.end()) return std::nullopt;
        const Vec3 start3 = MatrixUtilities::transformPoint(Vec3::zero(), it->second);
        const Vec3 end3 = MatrixUtilities::transformPoint(Vec3(b->length, 0, 0), it->second);
        return LineSegment{Vec2(start3.x, start3.y), Vec2(end3.x, end3.y)};
    }

    std::optional<float> worldRotation(Uuid boneID) const {
        return worldRotation(boneID, worldMatrices());
    }

    std::optional<float> worldRotation(Uuid boneID, const WorldMatrices& pose) const {
        auto seg = lineSegment(boneID, pose);
        if (!seg.has_value()) return std::nullopt;
        const Vec2 delta = seg->end - seg->start;
        if (!(lengthSquared(delta) > 0.0001f)) return std::nullopt;
        return std::atan2(delta.y, delta.x);
    }

    bool canParent(Uuid boneID, std::optional<Uuid> candidateParentID) const {
        if (!candidateParentID.has_value()) return true;
        if (boneID == *candidateParentID) return false;
        Uuid current = *candidateParentID;
        while (const Bone* b = bone(current)) {
            if (b->parentID.has_value() && *b->parentID == boneID) return false;
            if (!b->parentID.has_value()) break;
            current = *b->parentID;
        }
        return true;
    }

    Vec2 localPoint(Vec2 worldPoint, std::optional<Uuid> boneID) const {
        if (!boneID.has_value()) return worldPoint;
        auto m = worldMatrix(*boneID);
        if (!m.has_value()) return worldPoint;
        const Vec3 local =
            MatrixUtilities::transformPoint(Vec3(worldPoint.x, worldPoint.y, 0), inverse(*m));
        return Vec2(local.x, local.y);
    }

    struct WorldLineSegment {
        Bone bone;
        Vec2 start;
        Vec2 end;
    };

    std::vector<WorldLineSegment> worldLineSegments() const {
        return worldLineSegments(worldMatrices());
    }

    std::vector<WorldLineSegment> worldLineSegments(const WorldMatrices& matrices) const {
        std::vector<WorldLineSegment> result;
        for (const auto& b : orderedBones()) {
            auto it = matrices.find(b.id);
            if (it == matrices.end()) continue;
            const Vec3 start3 = MatrixUtilities::transformPoint(Vec3::zero(), it->second);
            const Vec3 end3 = MatrixUtilities::transformPoint(Vec3(b.length, 0, 0), it->second);
            result.push_back(WorldLineSegment{b, Vec2(start3.x, start3.y), Vec2(end3.x, end3.y)});
        }
        return result;
    }

    Skeleton addingBone(const Bone& bone) const {
        Skeleton next = *this;
        next.setBone(bone);
        if (!bone.parentID.has_value()) {
            bool alreadyRoot = false;
            for (Uuid id : next.rootIDs) {
                if (id == bone.id) { alreadyRoot = true; break; }
            }
            if (!alreadyRoot) next.rootIDs.push_back(bone.id);
        }
        return next;
    }

private:
    std::unordered_map<Uuid, Bone, UuidHash> bones_;
    std::unordered_map<Uuid, std::vector<Uuid>, UuidHash> cachedChildrenIndex_;

    static bool parentLinksDiffer(
        const std::unordered_map<Uuid, Bone, UuidHash>& lhs,
        const std::unordered_map<Uuid, Bone, UuidHash>& rhs) {
        if (lhs.size() != rhs.size()) return true;
        for (const auto& [id, bone] : lhs) {
            auto it = rhs.find(id);
            if (it == rhs.end() || it->second.parentID != bone.parentID) return true;
        }
        return false;
    }

    void rebuildChildrenIndex() {
        std::unordered_map<Uuid, std::vector<Uuid>, UuidHash> index;
        index.reserve(bones_.size());
        for (const auto& [id, bone] : bones_) {
            if (!bone.parentID.has_value()) continue;
            index[*bone.parentID].push_back(id);
        }
        cachedChildrenIndex_ = std::move(index);
    }

    void computeWorldMatrix(
        Uuid id, std::optional<Mat4> parent, WorldMatrices& result,
        const std::unordered_map<Uuid, std::vector<Uuid>, UuidHash>& childrenByParent) const {
        const Bone* b = bone(id);
        if (b == nullptr) return;
        const Mat4 world = b->worldMatrix(parent);
        result[id] = world;
        auto it = childrenByParent.find(id);
        if (it == childrenByParent.end()) return;
        for (Uuid child : it->second) {
            computeWorldMatrix(child, world, result, childrenByParent);
        }
    }
};

} // namespace umeshcore
