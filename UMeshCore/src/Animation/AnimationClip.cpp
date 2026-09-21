#include "umeshcore/Animation/AnimationClip.h"

#include <algorithm>

#include "umeshcore/Math/Angle.h"

namespace umeshcore {

namespace {

// x/y-axis neighbor lookup used by the Bezier evaluators below: `index`
// points at a keyframe in the (already time-sorted) keyframe list; returns
// nullopt if there's no such keyframe or its value isn't a Vec2 kind.
std::optional<AnimationCurve::FrameSample> vec2Neighbour(
    const std::vector<Keyframe>& keyframes, std::optional<std::size_t> index, bool useX) {
    if (!index.has_value()) return std::nullopt;
    auto v = simd2Value(keyframes[*index].value);
    if (!v.has_value()) return std::nullopt;
    return AnimationCurve::FrameSample{
        keyframes[*index].frame, useX ? v->x : v->y};
}

std::optional<AnimationCurve::FrameSample> floatNeighbour(
    const std::vector<Keyframe>& keyframes, std::optional<std::size_t> index) {
    if (!index.has_value()) return std::nullopt;
    auto v = floatValue(keyframes[*index].value);
    if (!v.has_value()) return std::nullopt;
    return AnimationCurve::FrameSample{keyframes[*index].frame, *v};
}

} // namespace

float AnimationClip::sampledBezierComponentValue(
    float frame, int lhsFrame, int rhsFrame, float lhsValue, float rhsValue,
    std::optional<Vec2> outTangent, std::optional<Vec2> inTangent,
    std::optional<AnimationCurve::FrameSample> beforeStart,
    std::optional<AnimationCurve::FrameSample> afterEnd) {
    const AnimationCurve::Segment segment = AnimationCurve::segment(
        AnimationCurve::FrameSample{lhsFrame, lhsValue},
        AnimationCurve::FrameSample{rhsFrame, rhsValue}, outTangent, inTangent, beforeStart,
        afterEnd);
    return AnimationCurve::valueAtTime(segment, frame);
}

std::pair<Vec2, Vec2> AnimationClip::autoTangents(
    int currentFrame, float currentValue, std::optional<AnimationCurve::FrameSample> previous,
    std::optional<AnimationCurve::FrameSample> next) {
    const float incomingSpan = std::max(
        static_cast<float>(
            currentFrame - (previous ? previous->frame : std::max(currentFrame - 1, 0))),
        1.0f);
    const float outgoingSpan = std::max(
        static_cast<float>((next ? next->frame : (currentFrame + 1)) - currentFrame), 1.0f);

    float slope;
    if (previous.has_value() && next.has_value()) {
        slope = AnimationCurve::autoSlope(
            AnimationCurve::FrameSample{previous->frame, previous->value},
            AnimationCurve::FrameSample{currentFrame, currentValue},
            AnimationCurve::FrameSample{next->frame, next->value});
    } else if (previous.has_value()) {
        slope = AnimationCurve::autoSlope(
            AnimationCurve::FrameSample{previous->frame, previous->value},
            AnimationCurve::FrameSample{currentFrame, currentValue}, std::nullopt);
    } else if (next.has_value()) {
        slope = AnimationCurve::autoSlope(
            std::nullopt, AnimationCurve::FrameSample{currentFrame, currentValue},
            AnimationCurve::FrameSample{next->frame, next->value});
    } else {
        slope = 0.0f;
    }

    const float inX = -incomingSpan / 3.0f;
    const float outX = outgoingSpan / 3.0f;
    return {Vec2(inX, slope * inX), Vec2(outX, slope * outX)};
}

Vec2 AnimationClip::sampledValueVec2(
    Uuid targetID, AnimationTrackProperty property, float time, Vec2 fallback) const {
    const auto& keyframes = keyframesFor(targetID, property);
    if (keyframes.empty()) return fallback;

    const KeyframeSpan span = keyframeSpan(keyframes, time);
    if (span.exact.has_value()) {
        if (auto v = simd2Value(keyframes[*span.exact].value)) return *v;
    }

    const Keyframe* lhs = span.previous ? &keyframes[*span.previous] : nullptr;
    const Keyframe* rhs = span.next ? &keyframes[*span.next] : nullptr;

    if (lhs != nullptr && rhs != nullptr) {
        const auto lhsValueOpt = simd2Value(lhs->value);
        const auto rhsValueOpt = simd2Value(rhs->value);
        if (!lhsValueOpt.has_value() || !rhsValueOpt.has_value()) return fallback;
        const Vec2 lhsValue = *lhsValueOpt;
        const Vec2 rhsValue = *rhsValueOpt;
        if (lhs->interpolation == KeyframeInterpolation::Hold) return lhsValue;
        if (lhs->interpolation == KeyframeInterpolation::Bezier) {
            // PER COMPONENT, and each with its own neighbours: x and y are
            // two independent curves through the same keys.
            const std::optional<std::size_t> beforeIndex =
                (span.previous.has_value() && *span.previous > 0)
                    ? std::optional<std::size_t>(*span.previous - 1)
                    : std::nullopt;
            const std::optional<std::size_t> afterIndex =
                (span.next.has_value() && *span.next + 1 < keyframes.size())
                    ? std::optional<std::size_t>(*span.next + 1)
                    : std::nullopt;
            const float x = sampledBezierComponentValue(
                time, lhs->frame, rhs->frame, lhsValue.x, rhsValue.x, lhs->outTangent,
                rhs->inTangent, vec2Neighbour(keyframes, beforeIndex, true),
                vec2Neighbour(keyframes, afterIndex, true));
            const float y = sampledBezierComponentValue(
                time, lhs->frame, rhs->frame, lhsValue.y, rhsValue.y, lhs->secondaryOutTangent,
                rhs->secondaryInTangent, vec2Neighbour(keyframes, beforeIndex, false),
                vec2Neighbour(keyframes, afterIndex, false));
            return Vec2(x, y);
        }
        const int delta = std::max(rhs->frame - lhs->frame, 1);
        const float progress = (time - static_cast<float>(lhs->frame)) / static_cast<float>(delta);
        return mix(lhsValue, rhsValue, progress);
    }
    if (lhs != nullptr) {
        const auto v = simd2Value(lhs->value);
        return v.value_or(fallback);
    }
    if (rhs != nullptr) {
        const auto v = simd2Value(rhs->value);
        return v.value_or(fallback);
    }
    return fallback;
}

float AnimationClip::sampledValueFloat(
    Uuid targetID, AnimationTrackProperty property, float time, float fallback, bool cyclic) const {
    const auto& keyframes = keyframesFor(targetID, property);
    if (keyframes.empty()) return fallback;

    const KeyframeSpan span = keyframeSpan(keyframes, time);
    if (span.exact.has_value()) {
        if (auto v = floatValue(keyframes[*span.exact].value)) return *v;
    }

    const Keyframe* lhs = span.previous ? &keyframes[*span.previous] : nullptr;
    const Keyframe* rhs = span.next ? &keyframes[*span.next] : nullptr;

    if (lhs != nullptr && rhs != nullptr) {
        const auto lhsValueOpt = floatValue(lhs->value);
        auto rhsValueOpt = floatValue(rhs->value);
        if (!lhsValueOpt.has_value() || !rhsValueOpt.has_value()) return fallback;
        const float lhsValue = *lhsValueOpt;
        float rhsValue = *rhsValueOpt;
        if (lhs->interpolation == KeyframeInterpolation::Hold) return lhsValue;
        if (cyclic) {
            rhsValue = lhsValue + shortestAngleDelta(lhsValue, rhsValue);
        }
        if (lhs->interpolation == KeyframeInterpolation::Bezier) {
            // THE NEIGHBOURS, so an auto tangent is the same slope on both
            // sides of a key and the motion does not corner there.
            const std::optional<std::size_t> beforeIndex =
                (span.previous.has_value() && *span.previous > 0)
                    ? std::optional<std::size_t>(*span.previous - 1)
                    : std::nullopt;
            const std::optional<std::size_t> afterIndex =
                (span.next.has_value() && *span.next + 1 < keyframes.size())
                    ? std::optional<std::size_t>(*span.next + 1)
                    : std::nullopt;
            return sampledBezierComponentValue(
                time, lhs->frame, rhs->frame, lhsValue, rhsValue, lhs->outTangent, rhs->inTangent,
                floatNeighbour(keyframes, beforeIndex), floatNeighbour(keyframes, afterIndex));
        }
        const int delta = std::max(rhs->frame - lhs->frame, 1);
        const float progress = (time - static_cast<float>(lhs->frame)) / static_cast<float>(delta);
        return lhsValue + (rhsValue - lhsValue) * progress;
    }
    if (lhs != nullptr) {
        const auto v = floatValue(lhs->value);
        return v.value_or(fallback);
    }
    if (rhs != nullptr) {
        const auto v = floatValue(rhs->value);
        return v.value_or(fallback);
    }
    return fallback;
}

bool AnimationClip::evaluatedFlagAtTime(
    Uuid targetID, AnimationTrackProperty property, float time, bool fallback) const {
    const auto& keyframes = keyframesFor(targetID, property);
    if (keyframes.empty()) return fallback;
    const KeyframeSpan span = keyframeSpan(keyframes, time);
    const std::optional<std::size_t> idx = span.exact.has_value() ? span.exact : span.previous;
    if (idx.has_value()) {
        return boolValue(keyframes[*idx].value).value_or(fallback);
    }
    // Before the first key the setup value would pop in; the convention is
    // to hold the first key backwards instead.
    return boolValue(keyframes.front().value).value_or(fallback);
}

std::optional<std::vector<Uuid>> AnimationClip::evaluatedDrawOrderAtTime(float time) const {
    const auto& keyframes = keyframesFor(SceneAnimationTarget::drawOrder(), AnimationTrackProperty::DrawOrder);
    if (keyframes.empty()) return std::nullopt;
    const KeyframeSpan span = keyframeSpan(keyframes, time);
    const std::optional<std::size_t> idx = span.exact.has_value() ? span.exact : span.previous;
    if (idx.has_value()) {
        if (auto* v = drawOrderValue(keyframes[*idx].value)) return *v;
        return std::nullopt;
    }
    if (auto* v = drawOrderValue(keyframes.front().value)) return *v;
    return std::nullopt;
}

std::vector<Vec2> AnimationClip::evaluatedMeshDeformAtTime(
    Uuid targetID, float time, const std::vector<Vec2>& fallback) const {
    const auto& keyframes = keyframesFor(targetID, AnimationTrackProperty::MeshDeform);
    if (keyframes.empty()) return fallback;

    const KeyframeSpan span = keyframeSpan(keyframes, time);
    if (span.exact.has_value()) {
        if (auto* verts = meshDeformValue(keyframes[*span.exact].value)) return *verts;
    }

    const Keyframe* lhs = span.previous ? &keyframes[*span.previous] : nullptr;
    const Keyframe* rhs = span.next ? &keyframes[*span.next] : nullptr;

    if (lhs != nullptr && rhs != nullptr) {
        const auto* lv = meshDeformValue(lhs->value);
        const auto* rv = meshDeformValue(rhs->value);
        if (lv == nullptr || rv == nullptr || lv->size() != rv->size()) {
            if (lv != nullptr) return *lv;
            return fallback;
        }
        if (lhs->interpolation == KeyframeInterpolation::Hold) return *lv;
        const float progress =
            (time - static_cast<float>(lhs->frame)) /
            static_cast<float>(std::max(rhs->frame - lhs->frame, 1));
        std::vector<Vec2> out(lv->size());
        for (std::size_t i = 0; i < lv->size(); ++i) out[i] = mix((*lv)[i], (*rv)[i], progress);
        return out;
    }
    if (lhs != nullptr) {
        if (auto* v = meshDeformValue(lhs->value)) return *v;
        return fallback;
    }
    if (rhs != nullptr) {
        if (auto* v = meshDeformValue(rhs->value)) return *v;
        return fallback;
    }
    return fallback;
}

SceneImageAnimationPose AnimationClip::poseAtTime(
    Uuid targetID, const SceneImageAnimationPose& basePose, float time, bool cyclicRotation) const {
    SceneImageAnimationPose out;
    out.position = sampledValueVec2(targetID, AnimationTrackProperty::Translate, time, basePose.position);
    out.scale = sampledValueVec2(targetID, AnimationTrackProperty::Scale, time, basePose.scale);
    out.rotation =
        sampledValueFloat(targetID, AnimationTrackProperty::Rotate, time, basePose.rotation, cyclicRotation);
    out.skew = sampledValueVec2(targetID, AnimationTrackProperty::Shear, time, basePose.skew);
    return out;
}

// --- Mutation -------------------------------------------------------------

void AnimationClip::upsertKeyframe(
    Uuid targetID, AnimationTrackProperty property, int frame, KeyframeValue value,
    KeyframeInterpolation interpolation) {
    durationInFrames = std::max(durationInFrames, frame);
    const KeyframeInterpolation resolved =
        forcesSteppedInterpolation(property) ? KeyframeInterpolation::Hold : interpolation;

    if (auto trackIdx = trackIndexFor(targetID, property)) {
        auto& keyframes = tracks_[*trackIdx].keyframes;
        auto it = std::find_if(
            keyframes.begin(), keyframes.end(), [frame](const Keyframe& k) { return k.frame == frame; });
        if (it != keyframes.end()) {
            it->value = std::move(value);
            it->interpolation = resolved;
        } else {
            keyframes.push_back(Keyframe(frame, std::move(value), resolved));
            std::sort(keyframes.begin(), keyframes.end(),
                      [](const Keyframe& a, const Keyframe& b) { return a.frame < b.frame; });
        }
    } else {
        std::vector<Keyframe> newKeyframes;
        newKeyframes.push_back(Keyframe(frame, std::move(value), resolved));
        tracks_.push_back(AnimationTrack(targetID, property, std::move(newKeyframes)));
    }
    didMutate();
    rebuildTrackIndex();
}

void AnimationClip::moveKeyframe(
    Uuid targetID, AnimationTrackProperty property, Uuid keyframeID, int destinationFrame) {
    auto trackIdx = trackIndexFor(targetID, property);
    if (!trackIdx.has_value()) return;
    auto& keyframes = tracks_[*trackIdx].keyframes;
    auto keyIt = std::find_if(
        keyframes.begin(), keyframes.end(), [&](const Keyframe& k) { return k.id == keyframeID; });
    if (keyIt == keyframes.end()) return;
    const std::size_t keyIndex = static_cast<std::size_t>(keyIt - keyframes.begin());

    const int clampedFrame = std::max(destinationFrame, 0);
    Keyframe movingKeyframe = keyframes[keyIndex];
    movingKeyframe.frame = clampedFrame;

    auto collisionIt = std::find_if(keyframes.begin(), keyframes.end(), [&](const Keyframe& k) {
        return k.frame == clampedFrame && k.id != keyframeID;
    });
    if (collisionIt != keyframes.end()) {
        const std::size_t collisionIndex = static_cast<std::size_t>(collisionIt - keyframes.begin());
        keyframes[collisionIndex] = movingKeyframe;
        // Transcribed verbatim from Data/AnimationClip.swift's moveKeyframe:
        // the ternary is the Swift source's own removal-index arithmetic,
        // preserved bit-for-bit rather than re-derived.
        const std::size_t removalIndex = (keyIndex > collisionIndex) ? keyIndex : keyIndex + 1;
        keyframes.erase(keyframes.begin() + static_cast<std::ptrdiff_t>(removalIndex));
    } else {
        keyframes[keyIndex] = movingKeyframe;
    }

    std::sort(keyframes.begin(), keyframes.end(),
              [](const Keyframe& a, const Keyframe& b) { return a.frame < b.frame; });
    durationInFrames = std::max(durationInFrames, clampedFrame);
    didMutate();
    rebuildTrackIndex();
}

void AnimationClip::setInterpolation(
    Uuid targetID, AnimationTrackProperty property,
    const std::unordered_set<Uuid, UuidHash>& keyframeIDs, KeyframeInterpolation interpolation) {
    if (forcesSteppedInterpolation(property)) return;
    auto trackIdx = trackIndexFor(targetID, property);
    if (!trackIdx.has_value()) return;
    for (auto& kf : tracks_[*trackIdx].keyframes) {
        if (keyframeIDs.contains(kf.id)) kf.interpolation = interpolation;
    }
    didMutate();
    rebuildTrackIndex();
}

void AnimationClip::updateKeyframeValue(
    Uuid targetID, AnimationTrackProperty property, Uuid keyframeID, KeyframeValue value) {
    auto trackIdx = trackIndexFor(targetID, property);
    if (!trackIdx.has_value()) return;
    auto& keyframes = tracks_[*trackIdx].keyframes;
    auto it = std::find_if(
        keyframes.begin(), keyframes.end(), [&](const Keyframe& k) { return k.id == keyframeID; });
    if (it == keyframes.end()) return;
    it->value = std::move(value);
    didMutate();
    rebuildTrackIndex();
}

void AnimationClip::updateKeyframeTangents(
    Uuid targetID, AnimationTrackProperty property, Uuid keyframeID, std::optional<Vec2> inTangent,
    std::optional<Vec2> outTangent, std::optional<Vec2> secondaryInTangent,
    std::optional<Vec2> secondaryOutTangent) {
    auto trackIdx = trackIndexFor(targetID, property);
    if (!trackIdx.has_value()) return;
    auto& keyframes = tracks_[*trackIdx].keyframes;
    auto it = std::find_if(
        keyframes.begin(), keyframes.end(), [&](const Keyframe& k) { return k.id == keyframeID; });
    if (it == keyframes.end()) return;
    it->inTangent = inTangent;
    it->outTangent = outTangent;
    it->secondaryInTangent = secondaryInTangent;
    it->secondaryOutTangent = secondaryOutTangent;
    didMutate();
    rebuildTrackIndex();
}

void AnimationClip::applyAutoTangents(
    Uuid targetID, AnimationTrackProperty property,
    const std::unordered_set<Uuid, UuidHash>& keyframeIDs) {
    auto trackIdx = trackIndexFor(targetID, property);
    if (!trackIdx.has_value()) return;
    auto& keyframes = tracks_[*trackIdx].keyframes;
    const std::vector<Keyframe> snapshot = keyframes;

    for (std::size_t keyIndex = 0; keyIndex < keyframes.size(); ++keyIndex) {
        const Keyframe keyframe = keyframes[keyIndex];
        if (!keyframeIDs.contains(keyframe.id)) continue;

        const Keyframe* previous = keyIndex > 0 ? &snapshot[keyIndex - 1] : nullptr;
        const Keyframe* next = keyIndex + 1 < snapshot.size() ? &snapshot[keyIndex + 1] : nullptr;

        auto floatSample = [](const Keyframe* kf) -> std::optional<AnimationCurve::FrameSample> {
            if (kf == nullptr) return std::nullopt;
            auto v = floatValue(kf->value);
            if (!v.has_value()) return std::nullopt;
            return AnimationCurve::FrameSample{kf->frame, *v};
        };
        auto vec2Sample = [](const Keyframe* kf, bool useX) -> std::optional<AnimationCurve::FrameSample> {
            if (kf == nullptr) return std::nullopt;
            auto v = simd2Value(kf->value);
            if (!v.has_value()) return std::nullopt;
            return AnimationCurve::FrameSample{kf->frame, useX ? v->x : v->y};
        };
        auto applySingleAxis = [&](float value) {
            auto [inT, outT] = autoTangents(
                keyframe.frame, value, floatSample(previous), floatSample(next));
            keyframes[keyIndex].inTangent = inT;
            keyframes[keyIndex].outTangent = outT;
        };
        auto applyDualAxis = [&](Vec2 value) {
            auto [inX, outX] = autoTangents(
                keyframe.frame, value.x, vec2Sample(previous, true), vec2Sample(next, true));
            auto [inY, outY] = autoTangents(
                keyframe.frame, value.y, vec2Sample(previous, false), vec2Sample(next, false));
            keyframes[keyIndex].inTangent = inX;
            keyframes[keyIndex].outTangent = outX;
            keyframes[keyIndex].secondaryInTangent = inY;
            keyframes[keyIndex].secondaryOutTangent = outY;
        };

        if (auto* v = std::get_if<RotateValue>(&keyframe.value)) {
            applySingleAxis(v->value);
        } else if (auto* v = std::get_if<ScalarValue>(&keyframe.value)) {
            applySingleAxis(v->value);
        } else if (auto* v = std::get_if<ScaleValue>(&keyframe.value)) {
            applyDualAxis(v->value);
        } else if (auto* v = std::get_if<TranslateValue>(&keyframe.value)) {
            applyDualAxis(v->value);
        } else if (auto* v = std::get_if<ShearValue>(&keyframe.value)) {
            applyDualAxis(v->value);
        } else if (auto* v = std::get_if<Vector2Value>(&keyframe.value)) {
            applyDualAxis(v->value);
        }
        // MeshDeform/Flag/DrawOrder/Event/Attachment: no-op, matching Swift.
    }
    didMutate();
    rebuildTrackIndex();
}

void AnimationClip::deleteKeyframes(
    Uuid targetID, AnimationTrackProperty property,
    const std::unordered_set<Uuid, UuidHash>& keyframeIDs) {
    auto trackIdx = trackIndexFor(targetID, property);
    if (!trackIdx.has_value()) return;
    auto& keyframes = tracks_[*trackIdx].keyframes;
    keyframes.erase(
        std::remove_if(
            keyframes.begin(), keyframes.end(),
            [&](const Keyframe& k) { return keyframeIDs.contains(k.id); }),
        keyframes.end());
    if (keyframes.empty()) {
        tracks_.erase(tracks_.begin() + static_cast<std::ptrdiff_t>(*trackIdx));
    }
    didMutate();
    rebuildTrackIndex();
}

AnimationClip AnimationClip::retargeted(
    Uuid sourceID, Uuid targetID, std::optional<std::string> renamedTo) const {
    AnimationClip clip = *this;
    if (renamedTo.has_value()) clip.name = *renamedTo;
    std::vector<AnimationTrack> retargetedTracks = tracks_;
    for (auto& track : retargetedTracks) {
        if (track.targetID == sourceID) track.targetID = targetID;
    }
    clip.setTracks(std::move(retargetedTracks));
    return clip;
}

} // namespace umeshcore
