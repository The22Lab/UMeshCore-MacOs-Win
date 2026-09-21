#include "umeshcore/Constraints/PathSolver.h"

#include <algorithm>
#include <cmath>
#include <optional>
#include <vector>

#include "umeshcore/Constraints/ConstraintPropagation.h"
#include "umeshcore/Math/Angle.h"
#include "umeshcore/Model/Skeleton.h"

namespace umeshcore::PathSolver {

namespace {

inline float rotZ(const Mat4& m) { return std::atan2(m.columns[0].y, m.columns[0].x); }

Mat4 rotateAround(const Mat4& m, Vec3 pivot, float angle) {
    const Mat4 toO = MatrixUtilities::translation(-pivot);
    const Mat4 rot = MatrixUtilities::rotationZ(angle);
    const Mat4 frO = MatrixUtilities::translation(pivot);
    return frO * rot * toO * m;
}

// Fold an arc position into [0, total), handling negatives, so a closed
// path can be walked in either direction without bounds checks.
float wrapArc(float s, float total) {
    if (!(total > 0.0001f)) return 0.0f;
    const float r = std::fmod(s, total);
    return r < 0.0f ? r + total : r;
}

// Scale a world matrix along its own X axis about a pivot (Chain Scale:
// only the bone's length may change, not its thickness).
Mat4 scaleAlongLocalX(const Mat4& m, Vec3 pivot, float factor) {
    Mat4 out = m;
    out.columns[0] = out.columns[0] * factor;
    const Vec3 movedOrigin = MatrixUtilities::transformPoint(Vec3::zero(), out);
    const Mat4 correction =
        MatrixUtilities::translation(Vec3(pivot.x - movedOrigin.x, pivot.y - movedOrigin.y, 0));
    return correction * out;
}

struct ArcSample {
    float t;
    float s;
};

// Extend the control points so the Catmull-Rom spline passes through the
// first and last of them. Open paths get mirrored phantom endpoints;
// closed paths wrap so the final segment joins the start with continuous
// curvature rather than a visible corner.
std::vector<Vec2> addPhantoms(const std::vector<Vec2>& pts, bool closed) {
    if (pts.size() < 2) return pts;
    if (closed) {
        std::vector<Vec2> out;
        out.reserve(pts.size() + 3);
        out.push_back(pts.back());
        out.insert(out.end(), pts.begin(), pts.end());
        out.push_back(pts[0]);
        out.push_back(pts[1]);
        return out;
    }
    const Vec2 a = pts[0] + (pts[0] - pts[1]) * 0.5f;
    const Vec2 b = pts.back() + (pts.back() - pts[pts.size() - 2]) * 0.5f;
    std::vector<Vec2> out;
    out.reserve(pts.size() + 2);
    out.push_back(a);
    out.insert(out.end(), pts.begin(), pts.end());
    out.push_back(b);
    return out;
}

Vec2 cr(const Vec2& p0, const Vec2& p1, const Vec2& p2, const Vec2& p3, float t) {
    const float t2 = t * t;
    const float t3 = t2 * t;
    const Vec2 a = p1 * 2.0f;
    const Vec2 b = (p2 - p0) * t;
    const Vec2 c = (p0 * 2.0f - p1 * 5.0f + p2 * 4.0f - p3) * t2;
    const Vec2 d = (p3 - p0 + (p1 - p2) * 3.0f) * t3;
    return (a + b + c + d) * 0.5f;
}

Vec2 evalDirect(const std::vector<Vec2>& pts, float t) {
    const int n = static_cast<int>(pts.size()) - 3;
    if (n < 1) return pts.empty() ? Vec2::zero() : pts.front();
    const int seg = std::max(0, std::min(n - 1, static_cast<int>(t)));
    return cr(pts[seg], pts[seg + 1], pts[seg + 2], pts[seg + 3], t - static_cast<float>(seg));
}

std::pair<Vec2, Vec2> eval(const std::vector<Vec2>& cp, float t, bool closed) {
    const std::vector<Vec2> pts = addPhantoms(cp, closed);
    const Vec2 pos = evalDirect(pts, t);
    const float tMax = static_cast<float>(pts.size()) - 3.0f;
    constexpr float eps = 0.001f;
    const Vec2 p1 = evalDirect(pts, std::min(t + eps, tMax));
    const Vec2 p0 = evalDirect(pts, std::max(t - eps, 0.0f));
    const Vec2 diff = p1 - p0;
    const Vec2 tangent = lengthSquared(diff) > 1e-6f ? normalize(diff) : Vec2(1, 0);
    return {pos, tangent};
}

std::vector<ArcSample> buildArcTable(const std::vector<Vec2>& cp, int samples, bool closed) {
    const std::vector<Vec2> pts = addPhantoms(cp, closed);
    const int segN = static_cast<int>(pts.size()) - 3;
    if (segN < 1) return {};

    const float tMax = static_cast<float>(segN);
    const float step = tMax / static_cast<float>(samples);
    std::vector<ArcSample> tbl;
    tbl.reserve(static_cast<std::size_t>(samples) + 1);

    Vec2 prev = evalDirect(pts, 0.0f);
    float cum = 0.0f;
    tbl.push_back(ArcSample{0.0f, 0.0f});

    for (int i = 1; i <= samples; ++i) {
        const float t = std::min(static_cast<float>(i) * step, tMax);
        const Vec2 pos = evalDirect(pts, t);
        cum += length(pos - prev);
        tbl.push_back(ArcSample{t, cum});
        prev = pos;
    }
    return tbl;
}

float arcToT(float s, const std::vector<ArcSample>& table) {
    if (table.size() < 2) return 0.0f;
    const float total = table.back().s;
    if (!(total > 0.0001f)) return 0.0f;
    if (s <= 0.0f) return table.front().t;
    if (s >= total) return table.back().t;

    std::size_t lo = 0;
    std::size_t hi = table.size() - 1;
    while (lo + 1 < hi) {
        const std::size_t mid = (lo + hi) >> 1;
        if (table[mid].s < s) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    const float span = table[hi].s - table[lo].s;
    if (!(span > 0.0001f)) return table[lo].t;
    const float frac = (s - table[lo].s) / span;
    return table[lo].t + frac * (table[hi].t - table[lo].t);
}

struct FollowerTarget {
    Uuid boneID;
    Vec2 position;
    Vec2 oldOrigin;
    Vec2 tangent;
    Mat4 old;
};

} // namespace

void solve(const PathConstraint& constraint, const Skeleton& skeleton, WorldMatrices& worldMatrices) {
    if (!constraint.enabled_ || !(constraint.mix_ > 0.0001f)) return;
    if (constraint.bones.empty() || constraint.pathBones.size() < 2) return;

    std::vector<Vec2> cp;
    cp.reserve(constraint.pathBones.size());
    for (Uuid bid : constraint.pathBones) {
        auto it = worldMatrices.find(bid);
        if (it == worldMatrices.end()) return;
        const Vec3 o = MatrixUtilities::transformPoint(Vec3::zero(), it->second);
        cp.emplace_back(o.x, o.y);
    }
    if (constraint.reversed) std::reverse(cp.begin(), cp.end());

    const bool closed = constraint.closed && cp.size() >= 3;
    const std::vector<ArcSample> table = buildArcTable(cp, 256, closed);
    if (table.empty() || !(table.back().s > 0.1f)) return;
    const float totalLen = table.back().s;

    const float effMix = std::min(1.0f, std::max(0.0f, constraint.mix_));
    const float posMix = std::min(1.0f, std::max(0.0f, constraint.positionMix)) * effMix;
    const float rotMix = std::min(1.0f, std::max(0.0f, constraint.rotateMix)) * effMix;
    const float startArc = constraint.position * totalLen;

    float spacingArc;
    switch (constraint.spacingMode) {
        case PathSpacingMode::Length: spacingArc = std::max(0.0f, constraint.spacing); break;
        case PathSpacingMode::Percent: spacingArc = std::max(0.0f, constraint.spacing) * totalLen; break;
        case PathSpacingMode::Proportional: spacingArc = std::max(0.0f, constraint.spacing); break;
        case PathSpacingMode::Fixed: spacingArc = std::max(0.0f, constraint.spacing); break;
    }

    // Pass 1: where every follower lands. Chain rotate modes need the
    // *next* bone's position before they can orient the current one, so
    // positions are resolved for the whole chain first.
    std::vector<FollowerTarget> targets;
    targets.reserve(constraint.bones.size());

    for (std::size_t i = 0; i < constraint.bones.size(); ++i) {
        const Uuid boneID = constraint.bones[i];
        auto oldWIt = worldMatrices.find(boneID);
        if (oldWIt == worldMatrices.end()) continue;

        float rawArc;
        if (constraint.spacingMode == PathSpacingMode::Proportional) {
            const Bone* b = skeleton.bone(boneID);
            const float blen = b != nullptr ? b->length : spacingArc;
            rawArc = startArc + static_cast<float>(i) * blen;
        } else {
            rawArc = startArc + static_cast<float>(i) * spacingArc;
        }

        const float arc =
            closed ? wrapArc(rawArc, totalLen) : std::min(totalLen, std::max(0.0f, rawArc));

        const float t = arcToT(arc, table);
        const auto [pathPos, tangent] = eval(cp, t, closed);

        const Vec3 oldO3 = MatrixUtilities::transformPoint(Vec3::zero(), oldWIt->second);
        const Vec2 oldO(oldO3.x, oldO3.y);
        const Vec2 newO = oldO + (pathPos - oldO) * posMix;

        targets.push_back(FollowerTarget{boneID, newO, oldO, tangent, oldWIt->second});
    }

    // Pass 2: translate, orient, and optionally stretch.
    const auto& childrenByParent = skeleton.childrenIndexForPropagation();
    for (std::size_t index = 0; index < targets.size(); ++index) {
        const FollowerTarget& tgt = targets[index];
        const Vec2 delta = tgt.position - tgt.oldOrigin;
        Mat4 w = MatrixUtilities::translation(Vec3(delta.x, delta.y, 0)) * tgt.old;

        std::optional<Vec2> aim;
        switch (constraint.rotateMode) {
            case PathRotateMode::Tangent:
                aim = lengthSquared(tgt.tangent) > 0.0001f ? std::optional<Vec2>(tgt.tangent)
                                                            : std::nullopt;
                break;
            case PathRotateMode::Chain:
            case PathRotateMode::ChainScale: {
                if (index + 1 < targets.size()) {
                    const Vec2 toNext = targets[index + 1].position - tgt.position;
                    aim = lengthSquared(toNext) > 0.0001f ? std::optional<Vec2>(normalize(toNext))
                                                           : std::nullopt;
                }
                if (!aim.has_value() && lengthSquared(tgt.tangent) > 0.0001f) {
                    aim = tgt.tangent;
                }
                break;
            }
        }

        if (rotMix > 0.0001f && aim.has_value()) {
            const float want = std::atan2(aim->y, aim->x) + constraint.offsetRotation;
            const float cur = rotZ(w);
            const float rotDelta = shortestAngleDelta(cur, want) * rotMix;
            if (std::abs(rotDelta) > 0.0001f) {
                w = rotateAround(w, Vec3(tgt.position.x, tgt.position.y, 0), rotDelta);
            }
        }

        // Chain Scale additionally stretches the bone so it exactly spans
        // the gap to the next one.
        if (constraint.rotateMode == PathRotateMode::ChainScale && index + 1 < targets.size()) {
            const Bone* b = skeleton.bone(tgt.boneID);
            if (b != nullptr && b->length > 0.0001f) {
                const float span = length(targets[index + 1].position - tgt.position);
                const float factor = 1.0f + ((span / b->length) - 1.0f) * effMix;
                if (std::isfinite(factor) && factor > 0.0001f && std::abs(factor - 1.0f) > 0.0001f) {
                    w = scaleAlongLocalX(w, Vec3(tgt.position.x, tgt.position.y, 0), factor);
                }
            }
        }

        worldMatrices[tgt.boneID] = w;
        ConstraintPropagation::cascade(tgt.boneID, std::nullopt, skeleton, childrenByParent, worldMatrices);
    }
}

} // namespace umeshcore::PathSolver

namespace umeshcore {

void PathConstraint::apply(const Skeleton& skeleton, WorldMatrices& worldMatrices) const {
    PathSolver::solve(*this, skeleton, worldMatrices);
}

} // namespace umeshcore
