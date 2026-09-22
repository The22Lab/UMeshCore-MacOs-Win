#include "umeshcore/Scene/SceneComposition.h"

#include <algorithm>
#include <cstddef>
#include <utility>

namespace umeshcore {

const SceneLayer* SceneComposition::layer(const Uuid& id) const {
    for (const SceneLayer& candidate : layers) {
        if (candidate.id == id) return &candidate;
    }
    return nullptr;
}

const SceneLight* SceneComposition::light(const Uuid& id) const {
    for (const SceneLight& candidate : lights) {
        if (candidate.id == id) return &candidate;
    }
    return nullptr;
}

std::vector<SceneLayer> SceneComposition::drawOrderedLayers() const {
    // Sort (sortingOrder, index) pairs rather than the layers themselves,
    // so the index IS the tie-break and the result does not depend on
    // whether the library's sort happens to be stable. See the header.
    std::vector<std::pair<int, std::size_t>> keys;
    keys.reserve(layers.size());
    for (std::size_t i = 0; i < layers.size(); ++i) {
        keys.emplace_back(layers[i].sortingOrder, i);
    }
    std::sort(keys.begin(), keys.end(), [](const auto& a, const auto& b) {
        return a.first != b.first ? a.first < b.first : a.second < b.second;
    });

    std::vector<SceneLayer> out;
    out.reserve(layers.size());
    for (const auto& key : keys) out.push_back(layers[key.second]);
    return out;
}

std::vector<SceneLayer> SceneComposition::frontToBackLayers() const {
    std::vector<SceneLayer> out = drawOrderedLayers();
    std::reverse(out.begin(), out.end());
    return out;
}

std::vector<SceneLayer> SceneComposition::visibleLayers() const {
    // Bound to a named local rather than iterated directly. Range-for
    // does extend the range temporary's lifetime, but this port has been
    // bitten twice by the near-identical form where a member call on a
    // returned temporary hands back a reference that is NOT extended
    // (`BinaryExporter`'s `orderedBones()`, `SavedSkeleton`'s `valueOr`),
    // so the whole family is written out here.
    std::vector<SceneLayer> ordered = drawOrderedLayers();
    std::vector<SceneLayer> out;
    for (SceneLayer& candidate : ordered) {
        if (!candidate.isHidden && candidate.opacity > 0.001f) out.push_back(std::move(candidate));
    }
    return out;
}

int SceneComposition::frontSortingOrder() const {
    // Swift's `max() ?? -1` then `+ 1`, so an empty scene's first layer
    // lands on 0 rather than on 1.
    //
    // The `-1` is the EMPTY-CASE fallback, not a seed for the running
    // maximum. Seeding with it instead (which is what this was first
    // written as) gives 0 for a scene whose every layer has a negative
    // order -- putting the new card behind cards it is supposed to lead,
    // and only in a scene where the artist had numbered everything below
    // zero.
    if (layers.empty()) return 0;
    int highest = layers.front().sortingOrder;
    for (const SceneLayer& candidate : layers) {
        highest = std::max(highest, candidate.sortingOrder);
    }
    return highest + 1;
}

} // namespace umeshcore
