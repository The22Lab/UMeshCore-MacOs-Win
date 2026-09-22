#include "umeshcore/Render/SceneSkinPalette.h"

#include <algorithm>
#include <cmath>

#include "umeshcore/Mesh/Mesh.h" // VertexBoneWeight

namespace umeshcore {

SceneSkinPalette::SceneSkinPalette(
    const std::vector<Uuid>& boneOrder, const std::unordered_map<Uuid, Mat4, UuidHash>& worldMatrices,
    const std::unordered_map<Uuid, Mat4, UuidHash>& boneInverseBindMatrices, const Mat4& bindToWorld,
    const Mat4& worldToBind, const Mat4& spriteToRig, const Mat4& rigToWorld) {
    // Everything that happens AFTER the weighted sum, in one matrix. It is
    // pushed inside the sum, which is what makes normalised weights a
    // requirement rather than a nicety: each of these carries a
    // translation, and inside the sum each is counted once per influence.
    const Mat4 after = rigToWorld * spriteToRig * worldToBind;

    matrices_.reserve(boneOrder.size() + 1);
    // A * I * B, which is the identity when the two are inverses -- and is
    // written as the product rather than as the literal identity so that a
    // sprite whose bind pose is not exactly invertible degrades the same
    // way its bound vertices do, instead of snapping to the origin.
    matrices_.push_back(after * bindToWorld);

    for (const Uuid& boneID : boneOrder) {
        const auto world = worldMatrices.find(boneID);
        if (world == worldMatrices.end()) continue;
        const auto inverseBind = boneInverseBindMatrices.find(boneID);
        if (inverseBind == boneInverseBindMatrices.end()) continue;
        slots_[boneID] = static_cast<std::uint16_t>(matrices_.size());
        matrices_.push_back(after * (world->second * inverseBind->second) * bindToWorld);
    }
}

SkinnedInfluences SceneSkinPalette::influences(const std::vector<VertexBoneWeight>& weights) {
    struct Picked {
        std::uint16_t slot;
        float weight;
    };
    std::vector<Picked> picked;
    picked.reserve(kMaximumInfluences);
    for (const VertexBoneWeight& influence : weights) {
        if (!(influence.weight > 0.0f) || !std::isfinite(influence.weight)) continue;
        const auto slot = slots_.find(influence.boneID);
        if (slot == slots_.end()) continue;
        picked.push_back(Picked{slot->second, influence.weight});
    }

    if (static_cast<int>(picked.size()) > kMaximumInfluences) {
        ++truncatedVertices_;
        // Largest first, and ties broken by SLOT rather than left to the
        // sort. The weights arrive from an unordered walk upstream and
        // `std::sort` is not stable, so equal weights could otherwise pick
        // different bones between runs of the same project.
        std::sort(picked.begin(), picked.end(), [](const Picked& a, const Picked& b) {
            return a.weight == b.weight ? a.slot < b.slot : a.weight > b.weight;
        });
        picked.resize(kMaximumInfluences);
    }

    float total = 0.0f;
    for (const Picked& entry : picked) total += entry.weight;

    SkinnedInfluences out;
    if (!(total > 0.000001f)) {
        // No influences: one unit of weight on the identity slot, which is
        // the bind position -- the answer the CPU path's branch gives,
        // without the branch.
        out.weights = Vec4(1, 0, 0, 0);
        return out;
    }
    for (std::size_t index = 0; index < picked.size(); ++index) {
        out.slots[index] = picked[index].slot;
        out.weights[static_cast<int>(index)] = picked[index].weight / total;
    }
    return out;
}

} // namespace umeshcore
