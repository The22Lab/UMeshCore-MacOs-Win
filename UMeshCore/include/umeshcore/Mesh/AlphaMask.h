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

#include <cstddef>
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
    void set(int x, int y, float value) {
        if (x < 0 || y < 0 || x >= width || y >= height) return;
        alpha[static_cast<std::size_t>(y) * static_cast<std::size_t>(width) + static_cast<std::size_t>(x)] = value;
    }
};

} // namespace umeshcore
