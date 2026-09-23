#pragma once

// The alpha channel of every loaded texture, by asset id -- what picking
// needs from Swift's `AssetManager` and nothing more (convention #2: the
// store is passed in explicitly, as `AssetRecord` is to the exporter).
//
// The shell fills it when it decodes a texture and removes an entry when
// the asset goes. It may decode at a reduced size, as `AssetManager` does
// (it caps the long side to keep a 4096-pixel sprite under a megabyte):
// every reader samples by UV, so the mask's resolution is the shell's
// memory decision, not a correctness one.
//
// The opaque bounds are computed once, on `set`, as Swift caches them.

#include <array>
#include <optional>
#include <unordered_map>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Mesh/AlphaMask.h"

namespace umeshcore {

struct AssetAlpha {
    // The texture's size in pixels (`TextureAsset.size`), which is also the
    // sprite's local size.
    Vec2 size;
    AlphaMask mask;
    // (minU, minV, maxU, maxV); nullopt when nothing is opaque.
    std::optional<std::array<float, 4>> opaqueBounds;
};

class AssetAlphaStore {
public:
    void set(Uuid assetID, Vec2 size, AlphaMask mask) {
        AssetAlpha entry{size, std::move(mask), std::nullopt};
        entry.opaqueBounds = entry.mask.opaqueBoundsUV();
        entries_[assetID] = std::move(entry);
    }
    void remove(Uuid assetID) { entries_.erase(assetID); }
    void clear() { entries_.clear(); }
    const AssetAlpha* find(Uuid assetID) const {
        auto it = entries_.find(assetID);
        return it == entries_.end() ? nullptr : &it->second;
    }
    std::size_t count() const { return entries_.size(); }

private:
    std::unordered_map<Uuid, AssetAlpha, UuidHash> entries_;
};

} // namespace umeshcore
