#pragma once

// 1:1 port of `Data/AnimationClip.swift`.

#include <algorithm>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "umeshcore/Animation/AnimationCurve.h"
#include "umeshcore/Animation/Keyframe.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

struct AnimationTrack {
    Uuid id = Uuid::generate();
    Uuid targetID;
    AnimationTrackProperty property = AnimationTrackProperty::Translate;
    std::vector<Keyframe> keyframes;

    AnimationTrack() = default;
    AnimationTrack(Uuid targetID_, AnimationTrackProperty property_,
                   std::vector<Keyframe> keyframes_ = {})
        : targetID(targetID_), property(property_), keyframes(std::move(keyframes_)) {
        std::sort(keyframes.begin(), keyframes.end(),
                  [](const Keyframe& a, const Keyframe& b) { return a.frame < b.frame; });
    }

    bool operator==(const AnimationTrack&) const = default;
};

struct SceneImageAnimationPose {
    Vec2 position;
    Vec2 scale;
    float rotation = 0.0f;
    Vec2 skew;

    bool operator==(const SceneImageAnimationPose&) const = default;
};

// Where a target's property lives, and whether a query landed exactly on a
// keyframe or between two.
struct KeyframeSpan {
    std::optional<std::size_t> exact;
    std::optional<std::size_t> previous;
    std::optional<std::size_t> next;
};

class AnimationClip {
public:
    Uuid id = Uuid::generate();
    std::string name;
    int durationInFrames = 0;

    AnimationClip() = default;
    explicit AnimationClip(std::string name_, int durationInFrames_ = 0,
                            std::vector<AnimationTrack> tracks_ = {})
        : name(std::move(name_)), durationInFrames(durationInFrames_) {
        setTracks(std::move(tracks_));
    }

    bool operator==(const AnimationClip& o) const {
        return id == o.id && name == o.name && durationInFrames == o.durationInFrames &&
               tracks_ == o.tracks_;
    }

    const std::vector<AnimationTrack>& tracks() const { return tracks_; }
    // Bulk replace, mirroring Swift's `tracks { didSet { rebuildTrackIndex() } }`.
    void setTracks(std::vector<AnimationTrack> tracks) {
        tracks_ = std::move(tracks);
        rebuildTrackIndex();
    }

    int revision() const { return revision_; }

    struct TrackKey {
        Uuid targetID;
        AnimationTrackProperty property;
        bool operator==(const TrackKey&) const = default;
    };
    struct TrackKeyHash {
        std::size_t operator()(const TrackKey& k) const {
            return UuidHash{}(k.targetID) ^
                   (static_cast<std::size_t>(k.property) * 0x9e3779b97f4a7c15ULL);
        }
    };

    // Where a target's property lives, or nullopt.
    std::optional<std::size_t> trackIndexFor(Uuid targetID, AnimationTrackProperty property) const {
        auto it = trackIndex_.find(TrackKey{targetID, property});
        if (it == trackIndex_.end()) return std::nullopt;
        return it->second;
    }

    const std::vector<Keyframe>& keyframesFor(Uuid targetID, AnimationTrackProperty property) const {
        static const std::vector<Keyframe> empty;
        auto idx = trackIndexFor(targetID, property);
        return idx ? tracks_[*idx].keyframes : empty;
    }

    // The keyframes around a `time` (in fractional frames), found via one
    // binary search: `exact` is the key ON `time`, `previous` the last one
    // strictly before it, `next` the first strictly after.
    static KeyframeSpan keyframeSpan(const std::vector<Keyframe>& keyframes, float time) {
        std::size_t low = 0;
        std::size_t high = keyframes.size();
        while (low < high) {
            const std::size_t mid = (low + high) / 2;
            if (static_cast<float>(keyframes[mid].frame) < time) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        KeyframeSpan span;
        span.exact = (low < keyframes.size() && static_cast<float>(keyframes[low].frame) == time)
                         ? std::optional<std::size_t>(low)
                         : std::nullopt;
        span.previous = low > 0 ? std::optional<std::size_t>(low - 1) : std::nullopt;
        const std::size_t afterIndex = span.exact.has_value() ? low + 1 : low;
        span.next = afterIndex < keyframes.size() ? std::optional<std::size_t>(afterIndex)
                                                   : std::nullopt;
        return span;
    }

    static KeyframeSpan keyframeSpanAtFrame(const std::vector<Keyframe>& keyframes, int frame) {
        return keyframeSpan(keyframes, static_cast<float>(frame));
    }

    std::vector<int> frameNumbers(Uuid targetID, AnimationTrackProperty property) const {
        std::vector<int> out;
        for (const auto& kf : keyframesFor(targetID, property)) out.push_back(kf.frame);
        return out;
    }

    const Keyframe* keyframe(Uuid targetID, AnimationTrackProperty property, Uuid keyframeID) const {
        for (const auto& kf : keyframesFor(targetID, property)) {
            if (kf.id == keyframeID) return &kf;
        }
        return nullptr;
    }

    // --- Mutation -----------------------------------------------------

    void upsertKeyframe(
        Uuid targetID, AnimationTrackProperty property, int frame, KeyframeValue value,
        KeyframeInterpolation interpolation = KeyframeInterpolation::Linear);
    void moveKeyframe(
        Uuid targetID, AnimationTrackProperty property, Uuid keyframeID, int destinationFrame);
    void setInterpolation(
        Uuid targetID, AnimationTrackProperty property,
        const std::unordered_set<Uuid, UuidHash>& keyframeIDs,
        KeyframeInterpolation interpolation);
    void updateKeyframeValue(
        Uuid targetID, AnimationTrackProperty property, Uuid keyframeID, KeyframeValue value);
    void updateKeyframeTangents(
        Uuid targetID, AnimationTrackProperty property, Uuid keyframeID,
        std::optional<Vec2> inTangent, std::optional<Vec2> outTangent,
        std::optional<Vec2> secondaryInTangent = std::nullopt,
        std::optional<Vec2> secondaryOutTangent = std::nullopt);
    void applyAutoTangents(
        Uuid targetID, AnimationTrackProperty property,
        const std::unordered_set<Uuid, UuidHash>& keyframeIDs);
    void deleteKeyframes(
        Uuid targetID, AnimationTrackProperty property,
        const std::unordered_set<Uuid, UuidHash>& keyframeIDs);
    AnimationClip retargeted(
        Uuid sourceID, Uuid targetID, std::optional<std::string> renamedTo = std::nullopt) const;

    // --- Evaluation -----------------------------------------------------

    std::vector<Vec2> evaluatedMeshDeform(
        Uuid targetID, int frame, const std::vector<Vec2>& fallback) const {
        return evaluatedMeshDeformAtTime(targetID, static_cast<float>(frame), fallback);
    }
    std::vector<Vec2> evaluatedMeshDeformAtTime(
        Uuid targetID, float time, const std::vector<Vec2>& fallback) const;

    bool hasTrack(Uuid targetID, AnimationTrackProperty property) const {
        for (const auto& t : tracks_) {
            if (t.targetID == targetID && t.property == property && !t.keyframes.empty())
                return true;
        }
        return false;
    }

    std::unordered_set<Uuid, UuidHash> animatedTargetIDs() const {
        std::unordered_set<Uuid, UuidHash> out;
        for (const auto& t : tracks_) {
            if (!t.keyframes.empty()) out.insert(t.targetID);
        }
        return out;
    }

    // Properties animated for a target, in AnimationTrackProperty
    // declaration order so timeline rows stay stable between rebuilds.
    std::vector<AnimationTrackProperty> animatedProperties(Uuid targetID) const {
        std::unordered_set<AnimationTrackProperty> present;
        for (const auto& t : tracks_) {
            if (t.targetID == targetID && !t.keyframes.empty()) present.insert(t.property);
        }
        std::vector<AnimationTrackProperty> out;
        for (auto p : allAnimationTrackProperties()) {
            if (present.contains(p)) out.push_back(p);
        }
        return out;
    }

    float evaluatedScalar(
        Uuid targetID, AnimationTrackProperty property, int frame, float fallback) const {
        return evaluatedScalarAtTime(targetID, property, static_cast<float>(frame), fallback);
    }
    float evaluatedScalarAtTime(
        Uuid targetID, AnimationTrackProperty property, float time, float fallback) const {
        return sampledValueFloat(targetID, property, time, fallback, /*cyclic=*/false);
    }

    Vec2 evaluatedVector2(
        Uuid targetID, AnimationTrackProperty property, int frame, Vec2 fallback) const {
        return evaluatedVector2AtTime(targetID, property, static_cast<float>(frame), fallback);
    }
    Vec2 evaluatedVector2AtTime(
        Uuid targetID, AnimationTrackProperty property, float time, Vec2 fallback) const {
        return sampledValueVec2(targetID, property, time, fallback);
    }

    bool evaluatedFlag(
        Uuid targetID, AnimationTrackProperty property, int frame, bool fallback) const {
        return evaluatedFlagAtTime(targetID, property, static_cast<float>(frame), fallback);
    }
    bool evaluatedFlagAtTime(
        Uuid targetID, AnimationTrackProperty property, float time, bool fallback) const;

    std::optional<std::vector<Uuid>> evaluatedDrawOrder(int frame) const {
        return evaluatedDrawOrderAtTime(static_cast<float>(frame));
    }
    std::optional<std::vector<Uuid>> evaluatedDrawOrderAtTime(float time) const;

    SceneImageAnimationPose pose(
        Uuid targetID, const SceneImageAnimationPose& basePose, int frame,
        bool cyclicRotation = false) const {
        return poseAtTime(targetID, basePose, static_cast<float>(frame), cyclicRotation);
    }
    SceneImageAnimationPose poseAtTime(
        Uuid targetID, const SceneImageAnimationPose& basePose, float time,
        bool cyclicRotation = false) const;

private:
    std::vector<AnimationTrack> tracks_;
    std::unordered_map<TrackKey, std::size_t, TrackKeyHash> trackIndex_;
    int revision_ = 0;

    void didMutate() { ++revision_; }

    void rebuildTrackIndex() {
        trackIndex_.clear();
        trackIndex_.reserve(tracks_.size());
        // Last one wins on a duplicate (targetID, property) pair, matching
        // the Swift source (a duplicate is malformed either way).
        for (std::size_t i = 0; i < tracks_.size(); ++i) {
            trackIndex_[TrackKey{tracks_[i].targetID, tracks_[i].property}] = i;
        }
    }

    Vec2 sampledValueVec2(
        Uuid targetID, AnimationTrackProperty property, float time, Vec2 fallback) const;
    float sampledValueFloat(
        Uuid targetID, AnimationTrackProperty property, float time, float fallback,
        bool cyclic) const;

    static float sampledBezierComponentValue(
        float frame, int lhsFrame, int rhsFrame, float lhsValue, float rhsValue,
        std::optional<Vec2> outTangent, std::optional<Vec2> inTangent,
        std::optional<AnimationCurve::FrameSample> beforeStart,
        std::optional<AnimationCurve::FrameSample> afterEnd);

    static std::pair<Vec2, Vec2> autoTangents(
        int currentFrame, float currentValue, std::optional<AnimationCurve::FrameSample> previous,
        std::optional<AnimationCurve::FrameSample> next);
};

} // namespace umeshcore
