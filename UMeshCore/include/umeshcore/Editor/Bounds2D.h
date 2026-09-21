#pragma once

// 1:1 port of `Core/Framing.swift`.

#include <algorithm>
#include <limits>

#include "umeshcore/Math/Vec.h"

namespace umeshcore {

struct Bounds2D {
    Vec2 min;
    Vec2 max;

    Vec2 size() const { return max - min; }
    Vec2 center() const { return (min + max) * 0.5f; }
    bool isValid() const { return min.x <= max.x && min.y <= max.y; }

    static Bounds2D empty() {
        const float inf = std::numeric_limits<float>::infinity();
        return Bounds2D{Vec2(inf, inf), Vec2(-inf, -inf)};
    }

    void include(const Vec2& point) {
        min = Vec2(std::min(min.x, point.x), std::min(min.y, point.y));
        max = Vec2(std::max(max.x, point.x), std::max(max.y, point.y));
    }
};

} // namespace umeshcore
