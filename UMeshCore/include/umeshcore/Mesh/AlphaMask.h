#pragma once

// A sprite's alpha channel, as the edit tools read it.
//
// Swift hands the mesh code an `alphaSampler: (Int, Int) -> Float` closure
// over a decoded texture. This port takes the decoded VALUES instead: the
// shell (which owns image decoding -- PNG on the Mac, WIC on Windows) fills
// one of these once per sprite and passes it by reference. Three reasons
// over a callback: it crosses to Swift with no function pointer or `void*`
// (the interop audit's one open `std::function`), it makes every consumer
// testable with a hand-built mask, and the core never learns what a texture
// is. The sampler's contract is kept: pixel (x, y) with y DOWN from the top
// row, alpha in 0...1, and anything outside the image reads as transparent.

#include <algorithm>
#include <array>
#include <cstddef>
#include <optional>
#include <vector>

namespace umeshcore {

struct AlphaMask {
    int width = 0;
    int height = 0;
    // Row-major, `width * height` values, row 0 at the TOP.
    std::vector<float> alpha;

    AlphaMask() = default;
    AlphaMask(int w, int h) : width(w), height(h), alpha(static_cast<std::size_t>(w > 0 && h > 0 ? w * h : 0), 0.0f) {}

    float at(int x, int y) const {
        if (x < 0 || y < 0 || x >= width || y >= height) return 0.0f;
        const std::size_t i = static_cast<std::size_t>(y) * static_cast<std::size_t>(width) + static_cast<std::size_t>(x);
        return i < alpha.size() ? alpha[i] : 0.0f;
    }
    // `AssetManager.alphaAt(u:v:)`: the texel containing (u, v), clamped to
    // the image, v DOWN. A mask with no pixels reads as OPAQUE (1), which is
    // what Swift answers when the texture cannot be loaded: an art-less
    // sprite stays selectable by its geometry rather than vanishing.
    float alphaAtUV(float u, float v) const {
        if (width <= 0 || height <= 0) return 1.0f;
        const int px = std::min(std::max(static_cast<int>(u * static_cast<float>(width)), 0), width - 1);
        const int py = std::min(std::max(static_cast<int>(v * static_cast<float>(height)), 0), height - 1);
        return at(px, py);
    }

    // `AssetManager.opaqueBounds`: the opaque extent in UV as (minU, minV,
    // maxU, maxV), with half a texel of margin (the map may be downsampled,
    // so the true edge can sit just outside the texel that found it).
    // nullopt for art transparent everywhere; (0, 0, 1, 1) for an empty mask.
    //
    // "Opaque" is Swift's byte test `alpha > UInt8(0.05 * 255)`, i.e. above
    // 12/255 -- the SAME texels the picking threshold (0.05) accepts on
    // 8-bit data, which every decoded texture is.
    std::optional<std::array<float, 4>> opaqueBoundsUV() const {
        if (width <= 0 || height <= 0) return std::array<float, 4>{0, 0, 1, 1};
        const float cutoff = static_cast<float>(static_cast<int>(kOpaqueCutoff * 255.0f)) / 255.0f;
        int minX = width, minY = height, maxX = -1, maxY = -1;
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                if (!(at(x, y) > cutoff)) continue;
                minX = std::min(minX, x);
                maxX = std::max(maxX, x);
                minY = std::min(minY, y);
                maxY = std::max(maxY, y);
            }
        }
        if (maxX < minX || maxY < minY) return std::nullopt;
        const float w = static_cast<float>(width), h = static_cast<float>(height);
        return std::array<float, 4>{std::max(0.0f, (static_cast<float>(minX) - 0.5f) / w),
                                    std::max(0.0f, (static_cast<float>(minY) - 0.5f) / h),
                                    std::min(1.0f, (static_cast<float>(maxX) + 1.5f) / w),
                                    std::min(1.0f, (static_cast<float>(maxY) + 1.5f) / h)};
    }

    // Alpha at or below this is not the sprite (`AssetManager.
    // opaqueCutoffFraction`), shared by the bounds and by picking.
    static constexpr float kOpaqueCutoff = 0.05f;

    void set(int x, int y, float value) {
        if (x < 0 || y < 0 || x >= width || y >= height) return;
        alpha[static_cast<std::size_t>(y) * static_cast<std::size_t>(width) + static_cast<std::size_t>(x)] = value;
    }
};

} // namespace umeshcore
