#include "umeshcore/Model/Bone.h"

#include <limits>

namespace umeshcore {

Vec3 Bone::hsvToRgb(float h, float s, float v) {
    const float i = std::floor(h * 6.0f);
    const float f = h * 6.0f - i;
    const float p = v * (1.0f - s);
    const float q = v * (1.0f - f * s);
    const float t = v * (1.0f - (1.0f - f) * s);
    switch (static_cast<int>(std::fmod(i, 6.0f))) {
        case 0: return Vec3(v, t, p);
        case 1: return Vec3(q, v, p);
        case 2: return Vec3(p, v, t);
        case 3: return Vec3(p, q, v);
        case 4: return Vec3(t, p, v);
        default: return Vec3(v, p, q);
    }
}

Vec4 Bone::distinctColor(int index) {
    constexpr float phi = 0.618033988f;
    const float hue = std::fmod(static_cast<float>(index) * phi, 1.0f);
    static const float saturations[5] = {0.60f, 0.38f, 0.46f, 0.32f, 0.54f};
    static const float values[7] = {0.99f, 0.82f, 0.93f, 0.76f, 0.97f, 0.88f, 0.86f};
    // Swift's `%` on non-negative Int matches C++'s `%` on non-negative int;
    // `index` here is always >= 0 (see bindingColor).
    const Vec3 rgb = hsvToRgb(hue, saturations[index % 5], values[index % 7]);
    return Vec4(rgb.x, rgb.y, rgb.z, 1.0f);
}

Vec3 Bone::asDrawn(const Vec4& colour, const Vec3& background) {
    return Vec3(colour.x, colour.y, colour.z) * kOverlayAlpha + background * (1.0f - kOverlayAlpha);
}

Vec3 Bone::oklab(const Vec3& rgb) {
    auto linear = [](float c) { return c <= 0.04045f ? c / 12.92f : std::pow((c + 0.055f) / 1.055f, 2.4f); };
    const float r = linear(rgb.x);
    const float g = linear(rgb.y);
    const float b = linear(rgb.z);
    const float l = 0.4122214708f * r + 0.5363325363f * g + 0.0514459929f * b;
    const float m = 0.2119034982f * r + 0.6806995451f * g + 0.1073969566f * b;
    const float s = 0.0883024619f * r + 0.2817188376f * g + 0.6299787005f * b;
    auto cubeRoot = [](float v) { return v < 0.0f ? -std::pow(-v, 1.0f / 3.0f) : std::pow(v, 1.0f / 3.0f); };
    const float l_ = cubeRoot(l);
    const float m_ = cubeRoot(m);
    const float s_ = cubeRoot(s);
    return Vec3(
        0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_,
        1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_,
        0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_);
}

Vec4 Bone::bindingColor(Uuid boneID, const std::vector<Vec4>& used) {
    // Not bit-identical to Swift's `boneID.hashValue` (which is itself
    // randomized per-process by design, so there is no golden value to
    // match here) -- any well-distributed hash serves the same purpose:
    // an arbitrary-looking starting offset for the perceptual-distance
    // search below, which is what actually decides the result.
    const int offset = static_cast<int>(UuidHash{}(boneID) % 997);
    if (used.empty()) return distinctColor(offset);

    std::vector<Vec3> usedLab;
    usedLab.reserve(used.size());
    for (const auto& u : used) usedLab.push_back(oklab(asDrawn(u)));

    Vec4 best = distinctColor(offset);
    float bestGap = -1.0f;
    for (int step = 0; step < 96; ++step) {
        const Vec4 candidate = distinctColor(offset + step);
        const Vec3 candidateLab = oklab(asDrawn(candidate));
        float gap = std::numeric_limits<float>::max();
        for (const auto& lab : usedLab) {
            gap = std::min(gap, umeshcore::length(candidateLab - lab));
        }
        if (gap > bestGap) {
            bestGap = gap;
            best = candidate;
        }
    }
    return best;
}

} // namespace umeshcore
