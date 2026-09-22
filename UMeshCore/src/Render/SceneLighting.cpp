#include "umeshcore/Render/SceneLighting.h"

#include <algorithm>
#include <cmath>

#include "umeshcore/Animation/AnimationCurve.h"

namespace umeshcore {

namespace {
constexpr float kEpsilon = 0.000001f;
}

// ---- LightFalloffCurve -------------------------------------------------

std::vector<LightFalloffStop> LightFalloffCurve::smoothStops() {
    return {
        LightFalloffStop{0.0f, 1.0f, std::nullopt, Vec2(1.0f / 3.0f, 0.0f)},
        LightFalloffStop{1.0f, 0.0f, Vec2(-1.0f / 3.0f, 0.0f), std::nullopt}};
}

LightFalloffCurve::LightFalloffCurve(std::vector<LightFalloffStop> stops) {
    stops_ = stops.size() >= 2 ? std::move(stops) : smoothStops();
    std::sort(stops_.begin(), stops_.end(), [](const LightFalloffStop& a, const LightFalloffStop& b) {
        return a.position < b.position;
    });
    // Pinned on construction rather than clamped on read -- see the header.
    stops_.front().position = 0.0f;
    stops_.front().value = 1.0f;
    stops_.back().position = 1.0f;
    stops_.back().value = 0.0f;
}

LightFalloffCurve LightFalloffCurve::linear() {
    return LightFalloffCurve({
        LightFalloffStop{0.0f, 1.0f, std::nullopt, Vec2(1.0f / 3.0f, -1.0f / 3.0f)},
        LightFalloffStop{1.0f, 0.0f, Vec2(-1.0f / 3.0f, 1.0f / 3.0f), std::nullopt}});
}

LightFalloffCurve LightFalloffCurve::smooth() { return LightFalloffCurve(smoothStops()); }

LightFalloffCurve LightFalloffCurve::inverseSquare() {
    constexpr float k = 8.0f;
    float raw[9];
    for (int i = 0; i <= 8; ++i) {
        const float x = 1.0f + k * (static_cast<float>(i) / 8.0f);
        raw[i] = 1.0f / (x * x);
    }
    const float lo = raw[8];
    std::vector<LightFalloffStop> stops;
    stops.reserve(9);
    for (int i = 0; i <= 8; ++i) {
        stops.push_back(LightFalloffStop{
            static_cast<float>(i) / 8.0f, (raw[i] - lo) / (1.0f - lo), std::nullopt, std::nullopt});
    }
    return LightFalloffCurve(std::move(stops));
}

float LightFalloffCurve::value(float position) const {
    const float u = std::min(std::max(position, 0.0f), 1.0f);
    if (u <= 0.0f) return stops_.front().value;
    if (u >= 1.0f) return stops_.back().value;

    std::size_t index = 0;
    for (std::size_t i = 0; i + 1 < stops_.size(); ++i) {
        if (stops_[i].position <= u && u <= stops_[i + 1].position) {
            index = i;
            break;
        }
    }
    const LightFalloffStop& lhs = stops_[index];
    const LightFalloffStop& rhs = stops_[index + 1];
    std::optional<AnimationCurve::Sample> before;
    if (index > 0) before = AnimationCurve::Sample{stops_[index - 1].position, stops_[index - 1].value};
    std::optional<AnimationCurve::Sample> after;
    if (index + 2 < stops_.size())
        after = AnimationCurve::Sample{stops_[index + 2].position, stops_[index + 2].value};

    // Through `AnimationCurve` -- the editor's one curve authority -- on
    // its continuous axis. Lighting has no Bezier code of its own.
    const AnimationCurve::Segment segment = AnimationCurve::segment(
        AnimationCurve::Sample{lhs.position, lhs.value},
        AnimationCurve::Sample{rhs.position, rhs.value}, lhs.outTangent, rhs.inTangent, before,
        after, AnimationCurve::kNormalisedSpanFloor);
    return AnimationCurve::valueAtTime(segment, u);
}

std::vector<float> LightFalloffCurve::table(int entries) const {
    const int n = std::max(entries, 2);
    std::vector<float> out;
    out.reserve(static_cast<std::size_t>(n));
    for (int i = 0; i < n; ++i) {
        out.push_back(value(static_cast<float>(i) / static_cast<float>(n - 1)));
    }
    return out;
}

// ---- Light parameters --------------------------------------------------

SceneLightKindCode lightKindCode(SceneLightKind kind) {
    switch (kind) {
        case SceneLightKind::kPoint: return SceneLightKindCode::kPoint;
        case SceneLightKind::kSpot: return SceneLightKindCode::kSpot;
        case SceneLightKind::kDirectional: return SceneLightKindCode::kDirectional;
    }
    return SceneLightKindCode::kPoint;
}

SceneLightBlendCode lightBlendCode(SceneLightBlend blend) {
    switch (blend) {
        case SceneLightBlend::kNormal: return SceneLightBlendCode::kNormal;
        case SceneLightBlend::kAdditive: return SceneLightBlendCode::kAdditive;
        case SceneLightBlend::kMultiply: return SceneLightBlendCode::kMultiply;
        case SceneLightBlend::kScreen: return SceneLightBlendCode::kScreen;
    }
    return SceneLightBlendCode::kNormal;
}

Vec3 lightDirection(float azimuth, float elevation) {
    const float ce = std::cos(elevation), se = std::sin(elevation);
    return Vec3(std::cos(azimuth) * ce, std::sin(azimuth) * ce, se);
}

float lightInnerRadius(const SceneLightParams& light) {
    return std::max(light.radius, 0.0f) * (1.0f - std::min(std::max(light.softness, 0.0f), 1.0f));
}

float lightBandWidth(const SceneLightParams& light) {
    return std::max(light.radius, 0.0f) - lightInnerRadius(light);
}

// ---- PreparedLight -----------------------------------------------------

PreparedLight::PreparedLight(const SceneLightParams& light_) {
    light = light_;
    table = light_.falloff.table();
    origin = light_.world;
    direction = lightDirection(light_.azimuth, light_.elevation);
    radius = std::max(light_.radius, kEpsilon);
    innerRadius = lightInnerRadius(light_);
    band = lightBandWidth(light_);
    const float outer = std::min(std::max(light_.outerAngle, 0.0f), 3.14159265358979323846f);
    const float inner = std::min(std::max(light_.innerAngle, 0.0f), outer);
    cosOuter = std::cos(outer);
    cosInner = std::cos(inner);
    tint = light_.color * light_.intensity;
}

float PreparedLight::falloff(float u) const {
    const int n = static_cast<int>(table.size());
    if (n < 2) return 0.0f;
    const float x = std::min(std::max(u, 0.0f), 1.0f) * static_cast<float>(n - 1);
    const int i = std::min(static_cast<int>(x), n - 2);
    const float f = x - static_cast<float>(i);
    return table[static_cast<std::size_t>(i)] * (1.0f - f) +
           table[static_cast<std::size_t>(i) + 1] * f;
}

float PreparedLight::attenuation(const Vec3& point) const {
    if (light.kind == SceneLightKind::kDirectional) return 1.0f;
    Vec3 delta = point - origin;
    // THE WHOLE OF 2.5D -- the only place in the model that mentions Z.
    delta.z *= light.depthInfluence;
    const float distance = length(delta);
    if (!(distance < radius)) return 0.0f;
    float radial;
    if (distance <= innerRadius) {
        radial = 1.0f;
    } else if (band > kEpsilon) {
        radial = falloff((distance - innerRadius) / band);
    } else {
        radial = 0.0f;
    }
    if (light.kind != SceneLightKind::kSpot || !(distance > kEpsilon)) return radial;
    const float cosine = dot(delta / distance, direction);
    if (cosine <= cosOuter) return 0.0f;
    if (cosine >= cosInner) return radial;
    const float t = (cosine - cosOuter) / std::max(cosInner - cosOuter, kEpsilon);
    return radial * (t * t * (3.0f - 2.0f * t));
}

float PreparedLight::lambert(
    const Vec3& point, const Vec3& normal, float smoothness, float contrast) const {
    const float influence = light.normalInfluence;
    if (!(influence > 0.0f)) return 1.0f;
    Vec3 toLight;
    if (light.kind == SceneLightKind::kDirectional) {
        toLight = -direction;
    } else {
        Vec3 delta = origin - point;
        delta.z *= light.depthInfluence;
        const float len = length(delta);
        if (!(len > kEpsilon)) return 1.0f;
        toLight = delta / len;
    }
    const float ndotl = SceneLighting::shapedLambert(dot(normal, toLight), smoothness, contrast);
    return 1.0f - influence + influence * ndotl;
}

Vec3 PreparedLight::emission(const Vec3& point, const Vec3& normal) const {
    const float a = attenuation(point);
    if (!(a > 0.0f)) return Vec3::zero();
    return tint * (a * lambert(point, normal));
}

// ---- SceneLighting -----------------------------------------------------

SceneLighting::SceneLighting(
    const std::vector<SceneLightParams>& lights_, const SceneAmbient& ambient_) {
    ambient = ambient_;
    lights.reserve(lights_.size());
    for (const SceneLightParams& light : lights_) {
        if (!light.isEnabled) continue;
        lights.push_back(PreparedLight(light));
    }
}

bool SceneLighting::isIdentity() const {
    return lights.empty() && ambient.rgb() == Vec3(1, 1, 1);
}

std::vector<PreparedLight> SceneLighting::lightsReaching(std::uint8_t mask) const {
    std::vector<PreparedLight> out;
    for (const PreparedLight& prepared : lights) {
        if (lightMaskReaches(prepared.light.mask, mask)) out.push_back(prepared);
    }
    return out;
}

float SceneLighting::shapedLambert(float ndotl, float smoothness, float contrast) {
    float shaped = smoothness <= 0.0f
                       ? std::max(0.0f, ndotl)
                       : std::max(0.0f, (ndotl + smoothness) / (1.0f + smoothness));
    if (contrast > 0.0f) {
        shaped = std::min(std::max(0.5f + (shaped - 0.5f) * (1.0f + contrast), 0.0f), 1.0f);
    }
    return shaped;
}

SceneLighting::Shaded SceneLighting::shade(
    const std::vector<PreparedLight>& lights, const SceneAmbient& ambient, const Vec3& point,
    const Vec3& normal) {
    Shaded out{ambient.rgb(), Vec3::zero()};
    for (const PreparedLight& prepared : lights) {
        switch (prepared.light.blend) {
            case SceneLightBlend::kNormal:
                out.factor += prepared.emission(point, normal);
                break;
            case SceneLightBlend::kAdditive:
                out.additive += prepared.emission(point, normal);
                break;
            case SceneLightBlend::kMultiply: {
                const float a = prepared.attenuation(point);
                if (!(a > 0.0f)) continue;
                const float reach = a * prepared.lambert(point, normal);
                const Vec3 gel = Vec3(1 - reach, 1 - reach, 1 - reach) + prepared.tint * reach;
                out.factor = out.factor * gel;
                break;
            }
            case SceneLightBlend::kScreen: {
                const Vec3 e = prepared.emission(point, normal);
                if (e == Vec3::zero()) continue;
                const Vec3 one(1, 1, 1);
                const Vec3 clamped(
                    std::min(std::max(e.x, 0.0f), 1.0f), std::min(std::max(e.y, 0.0f), 1.0f),
                    std::min(std::max(e.z, 0.0f), 1.0f));
                out.factor = one - (one - out.factor) * (one - clamped);
                break;
            }
        }
    }
    return out;
}

std::optional<float> SceneLighting::narrowestBand(const std::vector<PreparedLight>& lights) {
    std::optional<float> best;
    for (const PreparedLight& prepared : lights) {
        if (!(prepared.band > kEpsilon)) continue;
        if (!best.has_value() || prepared.band < *best) best = prepared.band;
    }
    return best;
}

// ---- LightField --------------------------------------------------------

Vec3 LightField::finite(const Vec3& value) {
    return Vec3(
        std::isfinite(value.x) ? value.x : 0.0f, std::isfinite(value.y) ? value.y : 0.0f,
        std::isfinite(value.z) ? value.z : 0.0f);
}

std::optional<LightField> LightField::build(
    const SceneLighting& lighting, std::uint8_t mask, const Vec3& normal,
    const ScreenBounds& screenBounds, float cellsPerBand, float pixelsPerWorldUnit,
    const std::function<std::optional<Vec3>(float, float)>& worldAt) {
    const std::vector<PreparedLight> reaching = lighting.lightsReaching(mask);
    if (reaching.empty() && lighting.ambient.rgb() == Vec3(1, 1, 1)) return std::nullopt;

    LightField field;
    field.width = std::max(screenBounds.maxX - screenBounds.minX, 1.0f);
    field.height = std::max(screenBounds.maxY - screenBounds.minY, 1.0f);
    field.originX = screenBounds.minX;
    field.originY = screenBounds.minY;

    // The cell comes from the narrowest BAND, converted to view pixels.
    // Radius would be the wrong variable: a wide light with a hair-thin
    // edge has a huge radius and a gradient a lattice chosen from it would
    // step straight over.
    float cellPixels;
    const std::optional<float> band = SceneLighting::narrowestBand(reaching);
    if (band.has_value() && pixelsPerWorldUnit > kEpsilon) {
        cellPixels = *band * pixelsPerWorldUnit / std::max(cellsPerBand, 1.0f);
    } else {
        cellPixels = SceneLighting::kMaximumCellPixels;
    }
    const float clamped = std::min(
        std::max(cellPixels, SceneLighting::kMinimumCellPixels), SceneLighting::kMaximumCellPixels);
    field.columns = std::min(
        std::max(static_cast<int>(std::ceil(field.width / clamped)), 1),
        SceneLighting::kMaximumLatticeSide);
    field.rows = std::min(
        std::max(static_cast<int>(std::ceil(field.height / clamped)), 1),
        SceneLighting::kMaximumLatticeSide);

    const std::size_t count =
        static_cast<std::size_t>(field.columns + 1) * static_cast<std::size_t>(field.rows + 1);
    field.factors.reserve(count);
    field.additives.reserve(count);
    const SceneLighting::Shaded ambientOnly{lighting.ambient.rgb(), Vec3::zero()};
    for (int j = 0; j <= field.rows; ++j) {
        const float y = screenBounds.minY +
                        field.height * static_cast<float>(j) / static_cast<float>(field.rows);
        for (int i = 0; i <= field.columns; ++i) {
            const float x = screenBounds.minX +
                            field.width * static_cast<float>(i) / static_cast<float>(field.columns);
            // A lattice point whose ray misses the plane -- it runs
            // parallel to a layer seen exactly edge-on, or meets it behind
            // the eye -- gets the ambient and nothing else. NOT a skip:
            // the lattice is a rectangle, and a hole in it would
            // interpolate garbage into its neighbours.
            const std::optional<Vec3> world = worldAt(x, y);
            const SceneLighting::Shaded shaded =
                world.has_value()
                    ? SceneLighting::shade(reaching, lighting.ambient, *world, normal)
                    : ambientOnly;
            field.factors.push_back(finite(shaded.factor));
            field.additives.push_back(finite(shaded.additive));
        }
    }
    return field;
}

SceneLighting::Shaded LightField::sample(float x, float y) const {
    const float u =
        std::min(std::max((x - originX) / width, 0.0f), 1.0f) * static_cast<float>(columns);
    const float v =
        std::min(std::max((y - originY) / height, 0.0f), 1.0f) * static_cast<float>(rows);
    // The lower cell corner, one short of the last lattice index so the
    // upper corner is always in range. A sample landing exactly on the far
    // edge takes the last cell with fx = 1, which is that edge.
    const int i0 = std::min(static_cast<int>(u), std::max(columns - 1, 0));
    const int j0 = std::min(static_cast<int>(v), std::max(rows - 1, 0));
    const int i1 = std::min(i0 + 1, columns);
    const int j1 = std::min(j0 + 1, rows);
    const float fx = u - static_cast<float>(i0);
    const float fy = v - static_cast<float>(j0);
    const int stride = columns + 1;
    const auto lerp2 = [&](const std::vector<Vec3>& values) {
        const Vec3& a = values[static_cast<std::size_t>(j0 * stride + i0)];
        const Vec3& b = values[static_cast<std::size_t>(j0 * stride + i1)];
        const Vec3& c = values[static_cast<std::size_t>(j1 * stride + i0)];
        const Vec3& d = values[static_cast<std::size_t>(j1 * stride + i1)];
        return (a * (1.0f - fx) + b * fx) * (1.0f - fy) + (c * (1.0f - fx) + d * fx) * fy;
    };
    return SceneLighting::Shaded{lerp2(factors), lerp2(additives)};
}

} // namespace umeshcore
