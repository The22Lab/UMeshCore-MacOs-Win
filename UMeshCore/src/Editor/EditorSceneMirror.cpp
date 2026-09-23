// EditorScene -- mirroring: finding a bone's side partner by name, and
// moving poses and mesh weights across the X axis.
//
// Ported from `Data/SceneManager.swift`, `// MARK: - Mirroring`. Three
// differences, each a fix of something the Swift source says it does and
// does not:
//
//  1. THE POSE STICKS. Swift's `mirrorBonePose` and `flipBonePose` write
//     only `localTransform` and then call `applyAnimations()` -- which, in
//     Editor mode, puts every bone back on its `baseTransform` (the setup
//     pass), and in Animator re-samples the clip over it. Outside Pose mode
//     both buttons did nothing visible. Here they follow the rule every
//     other bone setter follows (`setBoneRotation`, `moveBoneRoot`, ...):
//     in Editor the setup pose takes the new values; in Animator the
//     changed channels are keyed at the playhead; in Pose mode only the
//     local pose is written, as Swift.
//
//  2. A NAME WITH A MARKER-LIKE WORD STILL FINDS ITS PARTNER. Swift takes
//     the FIRST marker the name contains and gives up if that rename names
//     no bone -- so `arm_lower_L` is read as containing "_l" (from
//     "_lower"), becomes `arm_rower_L`, and has no mirror, although
//     `arm_lower_R` exists. Here every marker is tried in Swift's order and
//     the first rename that names a bone wins. Wherever Swift found a
//     partner this finds the same one (Swift's answer is the first
//     candidate); it only finds partners where Swift found none.
//
//  3. `L_arm` / `R_arm`. Swift's doc comment lists that convention as
//     recognised; its marker table has no prefix form, so it was not. The
//     prefix forms are tried LAST, anchored to the start of the name, so
//     they cannot change any answer Swift gave.
//
// `mirroredBoneName` itself stays Swift's (first marker, no lookup): it is
// a string function and says nothing about which bones exist.
//
// Kept as Swift: with both sides selected, `mirrorBonePose` reads each
// source from the pose it is building, so [arm_L, arm_R] copies L onto R
// and then R (now L's mirror) back onto L -- both end up L's pose, not
// swapped. The shell only ever passes one bone.

#include "umeshcore/Editor/EditorScene.h"

#include <cfloat>
#include <cmath>

namespace umeshcore {

namespace {

// Ordered longest-first so "left" is tried before a bare "l".
const std::pair<const char*, const char*> kSideMarkers[] = {
    {"left", "right"}, {"Left", "Right"}, {"LEFT", "RIGHT"}, {"_l", "_r"}, {"_L", "_R"},
    {"-l", "-r"},      {"-L", "-R"},      {".l", ".r"},      {".L", ".R"},
};
// The documented `L_arm` convention, start-anchored (see the header).
const std::pair<const char*, const char*> kSidePrefixes[] = {
    {"L_", "R_"}, {"l_", "r_"}, {"L.", "R."}, {"l.", "r."}, {"L-", "R-"}, {"l-", "r-"},
};

std::string replacingAll(std::string s, const std::string& from, const std::string& to) {
    std::size_t pos = 0;
    while ((pos = s.find(from, pos)) != std::string::npos) {
        s.replace(pos, from.size(), to);
        pos += to.size();
    }
    return s;
}

bool startsWith(const std::string& s, const std::string& prefix) {
    return s.size() >= prefix.size() && s.compare(0, prefix.size(), prefix) == 0;
}

// Every rename the markers suggest, in the order they are tried.
std::vector<std::string> partnerNameCandidates(const std::string& name) {
    std::vector<std::string> out;
    for (const auto& [a, b] : kSideMarkers) {
        if (name.find(a) != std::string::npos) out.push_back(replacingAll(name, a, b));
        if (name.find(b) != std::string::npos) out.push_back(replacingAll(name, b, a));
    }
    for (const auto& [a, b] : kSidePrefixes) {
        if (startsWith(name, a)) out.push_back(b + name.substr(std::char_traits<char>::length(a)));
        if (startsWith(name, b)) out.push_back(a + name.substr(std::char_traits<char>::length(b)));
    }
    return out;
}

} // namespace

std::optional<std::string> EditorScene::mirroredBoneName(const std::string& name) {
    for (const auto& [a, b] : kSideMarkers) {
        if (name.find(a) != std::string::npos) return replacingAll(name, a, b);
        if (name.find(b) != std::string::npos) return replacingAll(name, b, a);
    }
    return std::nullopt;
}

std::optional<Uuid> EditorScene::mirroredBone(Uuid boneID) const {
    const Bone* bone = skeleton.bone(boneID);
    if (bone == nullptr) return std::nullopt;
    const std::vector<Bone> ordered = skeleton.orderedBones();
    for (const std::string& candidate : partnerNameCandidates(bone->name)) {
        if (candidate == bone->name) continue;
        for (const Bone& other : ordered) {
            if (other.name == candidate) return other.id;
        }
    }
    return std::nullopt;
}

// Refuses to guess: a vertex with no partner within `tolerance` keeps its
// weights, because silently pulling in the nearest vertex whatever its
// distance is how mirrored weights end up subtly wrong.
int EditorScene::mirrorMeshWeights(Uuid imageID, std::optional<float> axisX, float tolerance) {
    SceneImage* img = image(imageID);
    if (img == nullptr) return 0;
    const Mesh& mesh = img->mesh;
    const std::vector<Vec2>& vertices = mesh.vertices;
    if (vertices.empty() || mesh.vertexBoneWeights.size() != vertices.size()) return 0;

    float axis = 0.0f;
    if (axisX.has_value()) {
        axis = *axisX;
    } else {
        float lo = vertices.front().x, hi = lo;
        for (const Vec2& v : vertices) {
            lo = std::min(lo, v.x);
            hi = std::max(hi, v.x);
        }
        axis = (lo + hi) * 0.5f;
    }

    std::unordered_map<Uuid, std::optional<Uuid>, UuidHash> partnerCache;
    auto partner = [&](Uuid boneID) {
        auto it = partnerCache.find(boneID);
        if (it == partnerCache.end()) it = partnerCache.emplace(boneID, mirroredBone(boneID)).first;
        return it->second.value_or(boneID);
    };

    std::vector<std::vector<VertexBoneWeight>> updated = mesh.vertexBoneWeights;
    int mirroredCount = 0;
    for (std::size_t index = 0; index < vertices.size(); ++index) {
        const Vec2 mirrorPoint(2.0f * axis - vertices[index].x, vertices[index].y);
        std::optional<std::size_t> best;
        float bestDistance = FLT_MAX;
        for (std::size_t candidate = 0; candidate < vertices.size(); ++candidate) {
            const float d = length(vertices[candidate] - mirrorPoint);
            if (d < bestDistance) {
                bestDistance = d;
                best = candidate;
            }
        }
        if (!best.has_value() || !(bestDistance <= tolerance)) continue;
        const std::vector<VertexBoneWeight>& source = mesh.vertexBoneWeights[*best];
        if (source.empty()) continue;
        std::vector<VertexBoneWeight> swapped;
        swapped.reserve(source.size());
        for (const VertexBoneWeight& w : source) swapped.push_back(VertexBoneWeight{partner(w.boneID), w.weight});
        updated[index] = std::move(swapped);
        mirroredCount += 1;
    }
    if (mirroredCount == 0) return 0;

    pushUndoState();
    img = image(imageID);
    img->mesh.vertexBoneWeights = std::move(updated);
    img->mesh = img->mesh.sanitizedSkinningData();
    applyAnimationsNow();
    return mirroredCount;
}

// The rule every bone setter follows, applied to a whole reflected pose.
void EditorScene::writeMirroredPose(Uuid boneID, const Transform3D2D& pose, bool includesScale) {
    const Bone* existing = skeleton.bone(boneID);
    if (existing == nullptr) return;
    Bone bone = *existing;
    bone.localTransform = pose;
    if (!isAnimationEditingEnabled && !isPoseMode) {
        // The channels the setup pass restores are the ones that must be
        // written to the setup pose, or it restores them straight back.
        bone.baseTransform.position.x = pose.position.x;
        bone.baseTransform.position.y = pose.position.y;
        bone.baseTransform.rotation.z = pose.rotation.z;
        bone.baseTransform.scale.x = pose.scale.x;
        bone.baseTransform.scale.y = pose.scale.y;
        bone.baseTransform.skew = pose.skew;
    }
    skeleton.setBone(bone);
    if (isAnimationEditingEnabled && !isPoseMode) {
        // Values captured up front: each commit re-samples the rig, which
        // would put the not-yet-keyed channels back on the clip.
        commitKeyframe(boneID, AnimationTrackProperty::Translate, TranslateValue{Vec2(pose.position.x, pose.position.y)});
        commitKeyframe(boneID, AnimationTrackProperty::Rotate, RotateValue{pose.rotation.z});
        if (includesScale) {
            commitKeyframe(boneID, AnimationTrackProperty::Scale, ScaleValue{Vec2(pose.scale.x, pose.scale.y)});
        }
        commitKeyframe(boneID, AnimationTrackProperty::Shear, ShearValue{pose.skew});
    } else {
        applyAnimationsNow();
    }
}

// X position, Z rotation and X shear reflected; Y, scale and any 3D tilt
// copied (a tilted bone keeps its tilt).
int EditorScene::mirrorBonePose(const std::vector<Uuid>& boneIDs) {
    Skeleton working = skeleton;
    std::vector<std::pair<Uuid, Transform3D2D>> writes;
    for (Uuid boneID : boneIDs) {
        const Bone* source = working.bone(boneID);
        const std::optional<Uuid> partnerID = mirroredBone(boneID);
        if (source == nullptr || !partnerID.has_value() || working.bone(*partnerID) == nullptr) continue;
        Transform3D2D pose = source->localTransform;
        pose.position.x = -pose.position.x;
        pose.rotation.z = -pose.rotation.z;
        pose.skew.x = -pose.skew.x;
        Bone target = *working.bone(*partnerID);
        target.localTransform = pose;
        working.setBone(target);
        writes.emplace_back(*partnerID, pose);
    }
    if (writes.empty()) return 0;
    pushUndoState();
    for (const auto& [id, pose] : writes) writeMirroredPose(id, pose, /*includesScale=*/true);
    return static_cast<int>(writes.size());
}

void EditorScene::flipBonePose(Uuid boneID) {
    const Bone* bone = skeleton.bone(boneID);
    if (bone == nullptr) return;
    pushUndoState();
    Transform3D2D pose = bone->localTransform;
    pose.position.x = -pose.position.x;
    pose.rotation.z = -pose.rotation.z;
    pose.skew.x = -pose.skew.x;
    writeMirroredPose(boneID, pose, /*includesScale=*/false);
}

} // namespace umeshcore
