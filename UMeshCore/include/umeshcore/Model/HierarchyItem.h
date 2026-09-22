#pragma once

// 1:1 port of `HierarchyModels.swift`'s `HierarchyItem` -- the outliner's
// tree: what the artist sees in the hierarchy panel, in the order and
// nesting they arranged it. Persisted in the project manifest
// (`SavedHierarchyItem`), which is why it belongs here in the core rather
// than in a platform shell: the tree is authored data, not a rendering of
// the skeleton. The panel that DRAWS it is UI and stays per-platform.

#include <string>
#include <vector>

#include "umeshcore/Core/Uuid.h"

namespace umeshcore {

struct HierarchyItem {
    enum class ItemType { Image, Bone, Mesh };

    Uuid id = Uuid::generate();
    std::string name;
    ItemType type = ItemType::Image;
    bool isHidden = false;
    std::vector<HierarchyItem> children;
    int order = 0;

    bool operator==(const HierarchyItem&) const = default;
};

} // namespace umeshcore
