// EditorScene -- animation: the transport, the canvas modes a tool change
// leaves, the escape ladder, the key button, keyframe selection / editing /
// copy / paste, and animation events.
//
// Ported from `Data/SceneManager.swift`: the transport block after
// `restoreProject` (`setCurrentFrame` .. `togglePlayback`), the
// `projectFramesPerSecond` didSet, `canvasToolChanged`, `escapeState` /
// `exitDeepestScope`, `// MARK: – The key button`, the keyframe editing
// block up to `duplicateSelectedKeyframes`, and `// MARK: - Animation
// events`.
//
// Swift keeps the keyframe selection in a `Set` and reads `.first` of it in
// five places (the primary selected key, which sprite a key selection
// selects). `Set.first` is unspecified and changes between launches; here
// the selection is a vector kept free of duplicates, and "first" is the
// first one selected. Same membership, deterministic primary.

#include "umeshcore/Editor/EditorScene.h"

#include <algorithm>
#include <cctype>
#include <climits>
#include <cmath>

#include "umeshcore/Serialization/SavedAnimation.h"

namespace umeshcore {

namespace {

std::string trimmedName(const std::string& s) {
    std::size_t b = 0, e = s.size();
    while (b < e && std::isspace(static_cast<unsigned char>(s[b]))) ++b;
    while (e > b && std::isspace(static_cast<unsigned char>(s[e - 1]))) --e;
    return s.substr(b, e - b);
}

// `Int(x.rounded(.down))` for a playhead time already clamped to >= 0.
// Swift traps on NaN or on anything past `Int.max`; a C++ cast there is
// undefined behavior. NaN lands on 0 and the top saturates -- a playhead
// that stops at the end of the representable range instead of taking the
// process down.
int wholeFrame(double t) {
    if (!(t >= 0.0)) return 0;
    if (t >= static_cast<double>(INT_MAX)) return INT_MAX;
    return static_cast<int>(std::floor(t));
}

struct SelectionGroup {
    Uuid targetID;
    AnimationTrackProperty property;
    std::unordered_set<Uuid, UuidHash> keyframeIDs;
};

// `Dictionary(grouping:)` by (target, property). Swift's grouping order is
// a dictionary's; every caller treats the groups independently, so the
// first-seen order here changes nothing but determinism.
std::vector<SelectionGroup> groupSelections(const std::vector<SelectedKeyframe>& selections) {
    std::vector<SelectionGroup> groups;
    for (const SelectedKeyframe& s : selections) {
        auto it = std::find_if(groups.begin(), groups.end(), [&](const SelectionGroup& g) {
            return g.targetID == s.imageID && g.property == s.property;
        });
        if (it == groups.end()) {
            groups.push_back(SelectionGroup{s.imageID, s.property, {s.keyframeID}});
        } else {
            it->keyframeIDs.insert(s.keyframeID);
        }
    }
    return groups;
}

} // namespace

// ---- Transport ------------------------------------------------------------

int EditorScene::playbackLowerBound(std::optional<int> fallback) const {
    return std::max(fallback.value_or(playbackStartFrame), 0);
}

int EditorScene::playbackUpperBound(std::optional<int> fallback, std::optional<int> minimum) const {
    return std::max({fallback.value_or(playbackEndFrame), minimum.value_or(playbackStartFrame), 0});
}

// Landing on a whole frame is what scrubbing, stepping and every menu
// command mean, so the continuous time snaps to it.
void EditorScene::setCurrentFrame(int frame) {
    const int clamped = std::max(frame, 0);
    const int previous = currentFrame;
    currentFrame = clamped;
    animationTime = static_cast<float>(clamped);
    if (!isPlaying) playheadFrame = static_cast<double>(clamped);
    fireEventsCrossed(previous, clamped);
    applyAnimationsNow();
}

// A FRACTIONAL playhead: the pose is sampled at the fraction, and
// `currentFrame` follows as the whole frame a key would be written on.
void EditorScene::setAnimationTime(double time) {
    const double clamped = time > 0.0 ? time : 0.0;
    const int previous = currentFrame;
    animationTime = static_cast<float>(clamped);
    currentFrame = wholeFrame(clamped);
    if (!isPlaying) playheadFrame = clamped;
    fireEventsCrossed(previous, currentFrame);
    applyAnimationsNow();
}

void EditorScene::setPlaybackRange(int start, int end) {
    const int clampedStart = std::max(start, 0);
    const int clampedEnd = std::max(end, clampedStart);
    playbackStartFrame = clampedStart;
    playbackEndFrame = clampedEnd;
    if (currentFrame < clampedStart || currentFrame > clampedEnd) {
        setCurrentFrame(std::min(std::max(currentFrame, clampedStart), clampedEnd));
    }
}

void EditorScene::stepFrames(int delta, std::optional<int> lowerBound, std::optional<int> upperBound) {
    const int minFrame = playbackLowerBound(lowerBound);
    const int maxFrame = playbackUpperBound(upperBound, minFrame);
    setCurrentFrame(std::min(std::max(currentFrame + delta, minFrame), maxFrame));
}

std::optional<double> EditorScene::scheduledEndWake() const {
    if (!isPlaying || !playbackSession.has_value() || playbackLoops) return std::nullopt;
    const PlaybackRun& s = *playbackSession;
    // Deliberately a frame LATE, not early: `tickPlayback` stops the
    // transport once the playhead passes `maxFrame`, and a wake that arrives
    // before that finds nothing to do and gets no second chance.
    const double remaining = static_cast<double>(s.maxFrame + 1 - currentFrame) / s.framesPerSecond;
    return std::max(remaining, 0.0);
}

// The session is (startTime, startFrame, fps, bounds); nothing polls. The
// returned wake does not need cancelling on pause: `tickPlayback` is a pure
// function of time and a no-op while paused, so a stale wake is harmless.
std::optional<double> EditorScene::play(double now, std::optional<bool> looping, std::optional<int> lowerBound,
                                        std::optional<int> upperBound, std::optional<double> framesPerSecond) {
    const double fps = framesPerSecond.value_or(projectFramesPerSecond);
    if (looping.has_value()) playbackLoops = *looping;

    const int minFrame = playbackLowerBound(lowerBound);
    const int maxFrame = playbackUpperBound(upperBound, minFrame);
    if (maxFrame < minFrame) {
        isPlaying = false;
        return std::nullopt;
    }

    if (currentFrame < minFrame || currentFrame > maxFrame) setCurrentFrame(minFrame);
    isPlaying = true;
    playheadFrame = static_cast<double>(currentFrame);
    playbackSession = PlaybackRun{currentFrame, now, std::max(fps, 1.0), minFrame, maxFrame};
    return scheduledEndWake();
}

void EditorScene::tickPlayback(double now) {
    if (!isPlaying || !playbackSession.has_value()) return;
    const PlaybackRun session = *playbackSession;

    const double elapsed = now - session.startTime;
    double fractional = static_cast<double>(session.startFrame) + elapsed * session.framesPerSecond;
    const double span = static_cast<double>(session.maxFrame - session.minFrame + 1);

    if (fractional > static_cast<double>(session.maxFrame)) {
        if (playbackLoops && span > 0) {
            const double overshoot = fractional - static_cast<double>(session.minFrame);
            fractional = static_cast<double>(session.minFrame) + std::fmod(overshoot, span);
        } else {
            playheadFrame = static_cast<double>(session.maxFrame);
            setCurrentFrame(session.maxFrame);
            pause();
            return;
        }
    }

    playheadFrame = fractional;
    animationTime = static_cast<float>(fractional);

    // DIVERGENCE (a Swift bug, fixed): Swift writes `currentFrame` here
    // directly and never calls `fireEventsCrossed`, so events fire when
    // scrubbing and stepping and NEVER during playback -- which is the one
    // time a game-style event exists for. The loop-wrap branch of
    // `fireEventsCrossed` ("wrapped around the loop: finish the old span,
    // then the new one") is only reachable from here, and in Swift it is
    // dead code. Verified by grep: its two call sites are `setCurrentFrame`
    // and `setAnimationTime`, neither of which playback uses except for the
    // final frame of a clip that does not loop.
    const int targetFrame = wholeFrame(fractional);
    if (targetFrame != currentFrame) {
        const int previous = currentFrame;
        currentFrame = targetFrame;
        fireEventsCrossed(previous, targetFrame);
    }

    // EVERY tick, not only on a whole-frame change: the clip is sampled at
    // `animationTime`, which is what turns 24 held poses a second into
    // display-rate motion.
    applyAnimationsNow();
}

void EditorScene::pause() {
    isPlaying = false;
    playbackSession = std::nullopt;
}

std::optional<double> EditorScene::togglePlayback(double now, std::optional<bool> looping,
                                                  std::optional<int> lowerBound, std::optional<int> upperBound) {
    if (isPlaying) {
        pause();
        return std::nullopt;
    }
    return play(now, looping, lowerBound, upperBound, std::nullopt);
}

// `projectFramesPerSecond.didSet`, including two of its quirks, kept:
//  - An out-of-range value re-assigns the clamped one from inside the
//    didSet, which fires the didSet again with the OUT-OF-RANGE value as
//    `oldValue`; that inner firing sees a change and restarts playback even
//    when the effective rate did not move (240 -> 300 -> 240). Harmless: the
//    restart resumes on the current frame.
//  - The restart is a bare `play()`, so it runs over the project range
//    (`playbackStartFrame...playbackEndFrame`), not the bounds the running
//    session was started with.
// NaN is refused outright: Swift's `max(NaN, 1)` is NaN, `NaN != NaN`, and
// the didSet re-assigns itself until the stack runs out.
std::optional<double> EditorScene::setProjectFramesPerSecond(double fps, double now) {
    if (std::isnan(fps)) return std::nullopt;
    const double clamped = std::min(std::max(fps, 1.0), 240.0);
    const bool wasOutOfRange = clamped != fps;
    const double oldValue = projectFramesPerSecond;
    projectFramesPerSecond = clamped;
    if (!wasOutOfRange && clamped == oldValue) return std::nullopt;
    if (!isPlaying) return std::nullopt;
    pause();
    return play(now, std::nullopt, std::nullopt, std::nullopt, std::nullopt);
}

// ---- Canvas modes and the way out ----------------------------------------

void EditorScene::canvasToolChanged(ActiveTool tool) {
    activeCanvasTool = tool;
    // Pose is a canvas mode too, cleared BEFORE the mesh tool's early
    // return: the mesh tool is the exception to leaving mesh mode, not to
    // leaving pose.
    isPoseMode = false;
    pendingCanvasMode = std::nullopt;
    if (tool == ActiveTool::Mesh) return;
    isMeshEditEnabled = false;
    meshWeightPaintEnabled = false;
    setBindingBonesMode(false);
    activeWeightPaintBoneID = std::nullopt;
}

EditorEscape::State EditorScene::escapeState() const {
    EditorEscape::State state;
    state.isPickingIKBone = ikBuilder.has_value() && ikBuilder->pickingSlot.has_value();
    state.hasIKDraft = ikBuilder.has_value();
    state.selectedMeshVertexCount = static_cast<int>(selectedMeshVertexIndices.size());
    state.isWeightPainting = meshWeightPaintEnabled;
    state.isMeshEditing = isMeshEditEnabled;
    state.isBindingBones = isBindingBonesMode;
    state.selectedBoneCount = static_cast<int>(selectedBoneIDs.size());
    state.selectedImageCount = static_cast<int>(selectedImageIDs.size());
    state.hasSelectedConstraint = selectedConstraintID.has_value();
    state.hasNonDefaultTool = false;
    return state;
}

std::optional<EditorScope> EditorScene::exitDeepestScope(bool hasNonDefaultTool) {
    EditorEscape::State state = escapeState();
    state.hasNonDefaultTool = hasNonDefaultTool;
    const std::optional<EditorScope> scope = EditorEscape::deepest(state);
    if (!scope.has_value()) return std::nullopt;

    switch (*scope) {
        case EditorScope::IkBuilderPick:
            if (ikBuilder.has_value()) ikBuilder->pickingSlot = std::nullopt;
            ikBuilderHoveredBoneID = std::nullopt;
            break;
        case EditorScope::IkBuilderDraft:
            cancelIKBuilder();
            break;
        case EditorScope::MeshVertexSelection:
            selectedMeshVertexIndices.clear();
            selectedMeshInternalEdgeIndex = std::nullopt;
            hoveredMeshVertexIndex = std::nullopt;
            break;
        case EditorScope::WeightPaint:
            meshWeightPaintEnabled = false;
            activeWeightPaintBoneID = std::nullopt;
            break;
        case EditorScope::MeshEdit:
            // Everything inside the edit goes with it, as `EditorEscape::
            // leaving` models; otherwise the next press finds a vertex
            // selection belonging to an edit that is over.
            isMeshEditEnabled = false;
            meshWeightPaintEnabled = false;
            activeWeightPaintBoneID = std::nullopt;
            selectedMeshVertexIndices.clear();
            selectedMeshInternalEdgeIndex = std::nullopt;
            hoveredMeshVertexIndex = std::nullopt;
            isMeshLayerSelected = false;
            break;
        case EditorScope::BindBones:
            setBindingBonesMode(false);
            break;
        case EditorScope::BoneSelection:
            selectBone(std::nullopt);
            break;
        case EditorScope::ImageSelection:
            selectedImageID = std::nullopt;
            selectedImageIDs.clear();
            selectedConstraintID = std::nullopt;
            break;
        case EditorScope::ActiveTool:
            // The caller's: the tool is not this object's to set.
            break;
    }
    return scope;
}

// ---- Keyframes ------------------------------------------------------------

std::vector<Keyframe> EditorScene::keyframes(Uuid targetID, AnimationTrackProperty property) {
    if (isSceneOwnedTrack(property)) return sceneAnimationClip.keyframesFor(targetID, property);
    if (SceneImage* img = image(targetID)) {
        ensureImageAnimationSpaceConsistency(skeleton, *img);
        return img->animationClip.keyframesFor(targetID, property);
    }
    if (const Bone* bone = skeleton.bone(targetID)) return bone->animationClip.keyframesFor(targetID, property);
    return {};
}

// Rotate keys the rotation, Translate keys the position; a tool with no
// channel of its own keys the whole transform, so the button is not dead in
// Select.
std::vector<AnimationTrackProperty> EditorScene::transformKeyProperties(ActiveTool tool) {
    switch (tool) {
        case ActiveTool::Move: return {AnimationTrackProperty::Translate};
        case ActiveTool::Rotate: return {AnimationTrackProperty::Rotate};
        case ActiveTool::Scale: return {AnimationTrackProperty::Scale};
        case ActiveTool::Skew: return {AnimationTrackProperty::Shear};
        case ActiveTool::Select:
        case ActiveTool::Bone:
        case ActiveTool::Mesh:
        case ActiveTool::PhysicsPreview:
            break;
    }
    return {AnimationTrackProperty::Translate, AnimationTrackProperty::Rotate, AnimationTrackProperty::Scale,
            AnimationTrackProperty::Shear};
}

// The selected sprites, in document order, then the selected bones in
// hierarchy order: ordered so the key left selected afterwards is the same
// one every launch.
std::vector<Uuid> EditorScene::transformKeyTargets() const {
    std::vector<Uuid> targets;
    if (!selectedImageIDs.empty()) {
        for (const SceneImage& img : images) {
            if (selectedImageIDs.contains(img.id)) targets.push_back(img.id);
        }
    } else if (selectedImageID.has_value() && image(*selectedImageID) != nullptr) {
        targets.push_back(*selectedImageID);
    }

    std::unordered_set<Uuid, UuidHash> boneIDs = selectedBoneIDs;
    if (selectedBoneID.has_value()) boneIDs.insert(*selectedBoneID);
    if (boneIDs.size() == 1) {
        const Uuid only = *boneIDs.begin();
        if (skeleton.bone(only) != nullptr) targets.push_back(only);
    } else if (!boneIDs.empty()) {
        for (const IKBuilderOrderedBone& entry : IKBuilderRules::hierarchicalOrder(skeleton)) {
            if (boneIDs.contains(entry.bone.id)) targets.push_back(entry.bone.id);
        }
    }
    return targets;
}

std::vector<Keyframe> EditorScene::transformKeyframes(Uuid targetID, AnimationTrackProperty property) const {
    if (const SceneImage* img = image(targetID)) return img->animationClip.keyframesFor(targetID, property);
    if (const Bone* bone = skeleton.bone(targetID)) return bone->animationClip.keyframesFor(targetID, property);
    return {};
}

// Scoped to the ACTIVE channels: with the rotate tool in hand a frame
// holding only a translate key is clean as far as the button is concerned.
int EditorScene::keyedTransformCount(Uuid targetID, int frame) const {
    int total = 0;
    for (AnimationTrackProperty property : activeTransformKeyProperties()) {
        const std::vector<Keyframe> keys = transformKeyframes(targetID, property);
        if (std::any_of(keys.begin(), keys.end(), [&](const Keyframe& k) { return k.frame == frame; })) total += 1;
    }
    return total;
}

// `Full` only when EVERY target is complete: a mixed selection reads as
// `Partial`, so pressing completes both rather than clearing the done one.
EditorScene::TransformKeyState EditorScene::transformKeyState() const {
    const std::vector<Uuid> targets = transformKeyTargets();
    if (targets.empty()) return TransformKeyState::None;
    const int channels = static_cast<int>(activeTransformKeyProperties().size());
    bool allFull = true, allEmpty = true;
    for (Uuid target : targets) {
        const int count = keyedTransformCount(target, currentFrame);
        if (count < channels) allFull = false;
        if (count > 0) allEmpty = false;
    }
    if (allFull) return TransformKeyState::Full;
    if (allEmpty) return TransformKeyState::None;
    return TransformKeyState::Partial;
}

void EditorScene::writeTransformKey(Uuid targetID, int frame) {
    const std::vector<AnimationTrackProperty> properties = activeTransformKeyProperties();
    if (SceneImage* img = image(targetID)) {
        for (AnimationTrackProperty property : properties) {
            const std::optional<KeyframeValue> value = resolvedKeyframeValue(skeleton, images, targetID, property);
            if (!value.has_value()) continue;
            img->animationClip.upsertKeyframe(targetID, property, frame, *value);
        }
        return;
    }
    const Bone* existing = skeleton.bone(targetID);
    if (existing == nullptr) return;
    Bone bone = *existing;
    for (AnimationTrackProperty property : properties) {
        const std::optional<KeyframeValue> value = resolvedKeyframeValue(skeleton, images, targetID, property);
        if (!value.has_value()) continue;
        bone.animationClip.upsertKeyframe(targetID, property, frame, *value);
    }
    skeleton.setBone(bone);
}

void EditorScene::removeTransformKey(Uuid targetID, int frame) {
    const std::vector<AnimationTrackProperty> properties = activeTransformKeyProperties();
    auto doomedIn = [&](const AnimationClip& clip, AnimationTrackProperty property) {
        std::unordered_set<Uuid, UuidHash> doomed;
        for (const Keyframe& k : clip.keyframesFor(targetID, property)) {
            if (k.frame == frame) doomed.insert(k.id);
        }
        return doomed;
    };
    if (SceneImage* img = image(targetID)) {
        for (AnimationTrackProperty property : properties) {
            const auto doomed = doomedIn(img->animationClip, property);
            if (!doomed.empty()) img->animationClip.deleteKeyframes(targetID, property, doomed);
        }
        return;
    }
    const Bone* existing = skeleton.bone(targetID);
    if (existing == nullptr) return;
    Bone bone = *existing;
    for (AnimationTrackProperty property : properties) {
        const auto doomed = doomedIn(bone.animationClip, property);
        if (!doomed.empty()) bone.animationClip.deleteKeyframes(targetID, property, doomed);
    }
    skeleton.setBone(bone);
}

// The key button: capture the pose of everything selected, here, now.
// Returns whether anything was keyed, so the shell confirms a press only
// when the write happened.
bool EditorScene::toggleTransformKey() {
    if (!isAnimationEditingEnabled) return false;
    const std::vector<Uuid> targets = transformKeyTargets();
    if (targets.empty()) return false;

    const TransformKeyState state = transformKeyState();
    pushUndoState();

    if (state == TransformKeyState::Full) {
        for (Uuid target : targets) removeTransformKey(target, currentFrame);
        selectedKeyframes.clear();
        selectedKeyframe = std::nullopt;
    } else {
        for (Uuid target : targets) writeTransformKey(target, currentFrame);
        std::vector<SelectedKeyframe> written;
        for (Uuid target : targets) {
            for (AnimationTrackProperty property : activeTransformKeyProperties()) {
                for (const Keyframe& k : transformKeyframes(target, property)) {
                    if (k.frame != currentFrame) continue;
                    const SelectedKeyframe selection{target, property, k.id};
                    if (std::find(written.begin(), written.end(), selection) == written.end()) {
                        written.push_back(selection);
                    }
                    break;
                }
            }
        }
        selectedKeyframes = written;
        selectedKeyframe = written.empty() ? std::nullopt : std::optional<SelectedKeyframe>(written.front());
    }

    applyAnimationsNow();
    return true;
}

void EditorScene::insertSelectedKeyframe(const SelectedKeyframe& selection) {
    if (!isKeyframeSelected(selection)) selectedKeyframes.push_back(selection);
}

bool EditorScene::isKeyframeSelected(const SelectedKeyframe& selection) const {
    return std::find(selectedKeyframes.begin(), selectedKeyframes.end(), selection) != selectedKeyframes.end();
}

void EditorScene::selectKeyframe(Uuid targetID, AnimationTrackProperty property, Uuid keyframeID, bool additive) {
    const SelectedKeyframe selection{targetID, property, keyframeID};
    if (additive) {
        auto it = std::find(selectedKeyframes.begin(), selectedKeyframes.end(), selection);
        if (it != selectedKeyframes.end()) {
            selectedKeyframes.erase(it);
        } else {
            selectedKeyframes.push_back(selection);
        }
    } else {
        selectedKeyframes = {selection};
    }
    selectedKeyframe =
        selectedKeyframes.empty() ? std::nullopt : std::optional<SelectedKeyframe>(selectedKeyframes.front());
    if (image(targetID) != nullptr) {
        setSelection({targetID}, targetID, false);
    } else if (skeleton.bone(targetID) != nullptr) {
        selectBone(targetID);
    }
}

void EditorScene::moveKeyframe(Uuid targetID, AnimationTrackProperty property, Uuid keyframeID, int toFrame) {
    if (isSceneOwnedTrack(property)) {
        sceneAnimationClip.moveKeyframe(targetID, property, keyframeID, toFrame);
    } else if (SceneImage* img = image(targetID)) {
        img->animationClip.moveKeyframe(targetID, property, keyframeID, toFrame);
    } else if (const Bone* existing = skeleton.bone(targetID)) {
        Bone bone = *existing;
        bone.animationClip.moveKeyframe(targetID, property, keyframeID, toFrame);
        skeleton.setBone(bone);
    } else {
        return;
    }
    const SelectedKeyframe selection{targetID, property, keyframeID};
    insertSelectedKeyframe(selection);
    selectedKeyframe = selection;
    applyAnimationsNow();
}

void EditorScene::updateKeyframeValue(Uuid targetID, AnimationTrackProperty property, Uuid keyframeID,
                                      const KeyframeValue& value) {
    if (isSceneOwnedTrack(property)) {
        sceneAnimationClip.updateKeyframeValue(targetID, property, keyframeID, value);
    } else if (SceneImage* img = image(targetID)) {
        img->animationClip.updateKeyframeValue(targetID, property, keyframeID, value);
    } else if (const Bone* existing = skeleton.bone(targetID)) {
        Bone bone = *existing;
        bone.animationClip.updateKeyframeValue(targetID, property, keyframeID, value);
        skeleton.setBone(bone);
    } else {
        return;
    }
    applyAnimationsNow();
}

void EditorScene::updateKeyframeValue(Uuid targetID, AnimationTrackProperty property, Uuid keyframeID,
                                      const FlatKeyframeValue& value) {
    updateKeyframeValue(targetID, property, keyframeID, fromFlat(value));
}

void EditorScene::updateKeyframeTangents(Uuid targetID, AnimationTrackProperty property, Uuid keyframeID,
                                         std::optional<Vec2> inTangent, std::optional<Vec2> outTangent,
                                         std::optional<Vec2> secondaryInTangent,
                                         std::optional<Vec2> secondaryOutTangent) {
    if (isSceneOwnedTrack(property)) {
        sceneAnimationClip.updateKeyframeTangents(targetID, property, keyframeID, inTangent, outTangent,
                                                  secondaryInTangent, secondaryOutTangent);
    } else if (SceneImage* img = image(targetID)) {
        img->animationClip.updateKeyframeTangents(targetID, property, keyframeID, inTangent, outTangent,
                                                  secondaryInTangent, secondaryOutTangent);
    } else if (const Bone* existing = skeleton.bone(targetID)) {
        Bone bone = *existing;
        bone.animationClip.updateKeyframeTangents(targetID, property, keyframeID, inTangent, outTangent,
                                                  secondaryInTangent, secondaryOutTangent);
        skeleton.setBone(bone);
    } else {
        return;
    }
    applyAnimationsNow();
}

// `startFrames` is Swift's `[SelectedKeyframe: Int]`, as a list (a
// dictionary keyed by a struct does not cross to Swift).
void EditorScene::moveSelectedKeyframes(const SelectedKeyframe& anchor, int deltaFrames,
                                        const std::vector<KeyframeStart>& startFrames) {
    const std::vector<SelectedKeyframe> selected =
        selectedKeyframes.empty() ? std::vector<SelectedKeyframe>{anchor} : selectedKeyframes;

    for (const SelectedKeyframe& selection : selected) {
        auto start = std::find_if(startFrames.begin(), startFrames.end(),
                                  [&](const KeyframeStart& s) { return s.key == selection; });
        if (start == startFrames.end()) continue;
        const int destination = start->frame + deltaFrames;
        if (isSceneOwnedTrack(selection.property)) {
            sceneAnimationClip.moveKeyframe(selection.imageID, selection.property, selection.keyframeID, destination);
            continue;
        }
        if (const Bone* existing = skeleton.bone(selection.imageID)) {
            Bone bone = *existing;
            bone.animationClip.moveKeyframe(selection.imageID, selection.property, selection.keyframeID, destination);
            skeleton.setBone(bone);
            continue;
        }
        if (SceneImage* img = image(selection.imageID)) {
            img->animationClip.moveKeyframe(selection.imageID, selection.property, selection.keyframeID, destination);
        }
    }

    selectedKeyframe = anchor;
    applyAnimationsNow();
}

// Swift resolves a selected key in two different orders in this block, and
// both are kept: interpolation / tangents / delete look at the SPRITE, then
// the scene clip, then the bone; copy / duplicate look at the sprite, the
// bone, then the scene clip. They can only disagree for an id that is both
// a scene-track target and a sprite or bone, which the fixed scene-target
// ids and fresh UUIDs rule out.
std::optional<KeyframeInterpolation> EditorScene::selectedKeyframeInterpolation() const {
    if (selectedKeyframes.empty()) return std::nullopt;
    std::optional<KeyframeInterpolation> only;
    for (const SelectedKeyframe& s : selectedKeyframes) {
        const Keyframe* key = nullptr;
        if (const SceneImage* img = image(s.imageID)) {
            key = img->animationClip.keyframe(s.imageID, s.property, s.keyframeID);
        } else if (isSceneOwnedTrack(s.property)) {
            key = sceneAnimationClip.keyframe(s.imageID, s.property, s.keyframeID);
        } else if (const Bone* bone = skeleton.bone(s.imageID)) {
            key = bone->animationClip.keyframe(s.imageID, s.property, s.keyframeID);
        }
        if (key == nullptr) continue;
        if (!only.has_value()) {
            only = key->interpolation;
        } else if (*only != key->interpolation) {
            return std::nullopt;
        }
    }
    return only;
}

void EditorScene::setInterpolationForSelectedKeyframes(KeyframeInterpolation interpolation) {
    if (selectedKeyframes.empty()) return;
    for (const SelectionGroup& g : groupSelections(selectedKeyframes)) {
        if (SceneImage* img = image(g.targetID)) {
            img->animationClip.setInterpolation(g.targetID, g.property, g.keyframeIDs, interpolation);
        } else if (isSceneOwnedTrack(g.property)) {
            sceneAnimationClip.setInterpolation(g.targetID, g.property, g.keyframeIDs, interpolation);
        } else if (const Bone* existing = skeleton.bone(g.targetID)) {
            Bone bone = *existing;
            bone.animationClip.setInterpolation(g.targetID, g.property, g.keyframeIDs, interpolation);
            skeleton.setBone(bone);
        }
    }
    applyAnimationsNow();
}

void EditorScene::applyAutoTangentsToSelectedKeyframes() {
    if (selectedKeyframes.empty()) return;
    for (const SelectionGroup& g : groupSelections(selectedKeyframes)) {
        if (SceneImage* img = image(g.targetID)) {
            img->animationClip.applyAutoTangents(g.targetID, g.property, g.keyframeIDs);
        } else if (isSceneOwnedTrack(g.property)) {
            sceneAnimationClip.applyAutoTangents(g.targetID, g.property, g.keyframeIDs);
        } else if (const Bone* existing = skeleton.bone(g.targetID)) {
            Bone bone = *existing;
            bone.animationClip.applyAutoTangents(g.targetID, g.property, g.keyframeIDs);
            skeleton.setBone(bone);
        }
    }
    applyAnimationsNow();
}

void EditorScene::deleteSelectedKeyframes() {
    if (selectedKeyframes.empty()) return;
    for (const SelectionGroup& g : groupSelections(selectedKeyframes)) {
        if (SceneImage* img = image(g.targetID)) {
            img->animationClip.deleteKeyframes(g.targetID, g.property, g.keyframeIDs);
        } else if (isSceneOwnedTrack(g.property)) {
            sceneAnimationClip.deleteKeyframes(g.targetID, g.property, g.keyframeIDs);
            // Deleting the last key of a constraint property puts the
            // authored value back, or the constraint keeps whatever the
            // removed key happened to hold.
            if (domain(g.property) == AnimationTrackDomain::Constraint &&
                !isConstraintPropertyAnimated(g.targetID, g.property)) {
                restoreConstraintSetupValue(g.targetID, g.property);
            }
        } else if (const Bone* existing = skeleton.bone(g.targetID)) {
            Bone bone = *existing;
            bone.animationClip.deleteKeyframes(g.targetID, g.property, g.keyframeIDs);
            skeleton.setBone(bone);
        }
    }
    selectedKeyframes.clear();
    selectedKeyframe = std::nullopt;
    applyAnimationsNow();
}

void EditorScene::setSelectedKeyframes(const std::vector<SelectedKeyframe>& selections, bool additive) {
    if (!additive) selectedKeyframes.clear();
    for (const SelectedKeyframe& s : selections) insertSelectedKeyframe(s);

    selectedKeyframe =
        selectedKeyframes.empty() ? std::nullopt : std::optional<SelectedKeyframe>(selectedKeyframes.front());
    // The owners of the selected keys, first-seen first (Swift:
    // `Array(Set(...)).first`, which is any of them).
    std::vector<Uuid> ownerIDs;
    for (const SelectedKeyframe& s : selectedKeyframes) {
        if (std::find(ownerIDs.begin(), ownerIDs.end(), s.imageID) == ownerIDs.end()) ownerIDs.push_back(s.imageID);
    }
    if (!ownerIDs.empty() && image(ownerIDs.front()) != nullptr) {
        setSelection(ownerIDs, ownerIDs.front(), false);
    } else if (!ownerIDs.empty() && skeleton.bone(ownerIDs.front()) != nullptr) {
        selectBone(ownerIDs.front());
    } else {
        selectedKeyframe = std::nullopt;
    }
}

std::optional<Keyframe> EditorScene::resolveSelectedKeyframe(const SelectedKeyframe& s) const {
    if (const SceneImage* img = image(s.imageID)) {
        if (const Keyframe* k = img->animationClip.keyframe(s.imageID, s.property, s.keyframeID)) return *k;
    }
    if (const Bone* bone = skeleton.bone(s.imageID)) {
        if (const Keyframe* k = bone->animationClip.keyframe(s.imageID, s.property, s.keyframeID)) return *k;
    }
    if (isSceneOwnedTrack(s.property)) {
        if (const Keyframe* k = sceneAnimationClip.keyframe(s.imageID, s.property, s.keyframeID)) return *k;
    }
    return std::nullopt;
}

int EditorScene::copySelectedKeyframes() {
    if (selectedKeyframes.empty()) return 0;

    std::vector<std::pair<SelectedKeyframe, Keyframe>> resolved;
    for (const SelectedKeyframe& s : selectedKeyframes) {
        if (auto k = resolveSelectedKeyframe(s)) resolved.emplace_back(s, *k);
    }
    // By frame, then by the property's raw (file-format) name, as Swift.
    // Stable, so two keys that tie on both keep selection order where
    // Swift's unstable sort would leave it to chance.
    std::stable_sort(resolved.begin(), resolved.end(), [](const auto& lhs, const auto& rhs) {
        if (lhs.second.frame == rhs.second.frame) {
            return std::string(trackPropertyName(lhs.first.property)) <
                   std::string(trackPropertyName(rhs.first.property));
        }
        return lhs.second.frame < rhs.second.frame;
    });
    if (resolved.empty()) return 0;

    const int firstFrame = resolved.front().second.frame;
    copiedKeyframes.clear();
    for (const auto& [selection, key] : resolved) {
        copiedKeyframes.push_back(CopiedKeyframePayload{selection.imageID, selection.property, key.frame - firstFrame,
                                                        key.value, key.interpolation, key.inTangent, key.outTangent,
                                                        key.secondaryInTangent, key.secondaryOutTangent});
    }
    return static_cast<int>(copiedKeyframes.size());
}

void EditorScene::pasteCopiedKeyframes() {
    if (copiedKeyframes.empty()) return;

    std::vector<SelectedKeyframe> newSelections;
    auto addSelection = [&](const SelectedKeyframe& s) {
        if (std::find(newSelections.begin(), newSelections.end(), s) == newSelections.end()) {
            newSelections.push_back(s);
        }
    };
    auto keyAt = [](const std::vector<Keyframe>& keys, int frame) -> std::optional<Uuid> {
        for (const Keyframe& k : keys) {
            if (k.frame == frame) return k.id;
        }
        return std::nullopt;
    };

    for (const CopiedKeyframePayload& payload : copiedKeyframes) {
        const int targetFrame = std::max(currentFrame + payload.relativeFrame, 0);
        if (isSceneOwnedTrack(payload.property)) {
            if (domain(payload.property) == AnimationTrackDomain::Constraint) {
                ensureConstraintSetupCaptured(payload.imageID);
            }
            sceneAnimationClip.upsertKeyframe(payload.imageID, payload.property, targetFrame, payload.value,
                                              payload.interpolation);
            if (auto id = keyAt(sceneAnimationClip.keyframesFor(payload.imageID, payload.property), targetFrame)) {
                sceneAnimationClip.updateKeyframeTangents(payload.imageID, payload.property, *id, payload.inTangent,
                                                          payload.outTangent, payload.secondaryInTangent,
                                                          payload.secondaryOutTangent);
                addSelection(SelectedKeyframe{payload.imageID, payload.property, *id});
            }
            continue;
        }
        if (SceneImage* img = image(payload.imageID)) {
            img->animationClip.upsertKeyframe(payload.imageID, payload.property, targetFrame, payload.value,
                                              payload.interpolation);
            if (auto id = keyAt(img->animationClip.keyframesFor(payload.imageID, payload.property), targetFrame)) {
                img->animationClip.updateKeyframeTangents(payload.imageID, payload.property, *id, payload.inTangent,
                                                          payload.outTangent, payload.secondaryInTangent,
                                                          payload.secondaryOutTangent);
            }
        } else if (const Bone* existing = skeleton.bone(payload.imageID)) {
            Bone bone = *existing;
            bone.animationClip.upsertKeyframe(payload.imageID, payload.property, targetFrame, payload.value,
                                              payload.interpolation);
            if (auto id = keyAt(bone.animationClip.keyframesFor(payload.imageID, payload.property), targetFrame)) {
                bone.animationClip.updateKeyframeTangents(payload.imageID, payload.property, *id, payload.inTangent,
                                                          payload.outTangent, payload.secondaryInTangent,
                                                          payload.secondaryOutTangent);
            }
            skeleton.setBone(bone);
        } else {
            continue;
        }
        // Through `keyframes(...)`, which settles a sprite's animation space
        // first, as Swift's does.
        if (auto id = keyAt(keyframes(payload.imageID, payload.property), targetFrame)) {
            addSelection(SelectedKeyframe{payload.imageID, payload.property, *id});
        }
    }

    setSelectedKeyframes(newSelections, false);
    applyAnimationsNow();
}

void EditorScene::duplicateSelectedKeyframes() {
    if (selectedKeyframes.empty()) return;

    std::vector<std::pair<SelectedKeyframe, Keyframe>> resolved;
    for (const SelectedKeyframe& s : selectedKeyframes) {
        if (auto k = resolveSelectedKeyframe(s)) resolved.emplace_back(s, *k);
    }
    if (resolved.empty()) return;
    int minFrame = resolved.front().second.frame, maxFrame = minFrame;
    for (const auto& entry : resolved) {
        minFrame = std::min(minFrame, entry.second.frame);
        maxFrame = std::max(maxFrame, entry.second.frame);
    }

    const int duplicateOffset = std::max((maxFrame - minFrame) + 1, 1);
    copiedKeyframes.clear();
    for (const auto& [selection, key] : resolved) {
        copiedKeyframes.push_back(CopiedKeyframePayload{
            selection.imageID, selection.property, (key.frame - minFrame) + duplicateOffset, key.value,
            key.interpolation, key.inTangent, key.outTangent, key.secondaryInTangent, key.secondaryOutTangent});
    }

    // Kept as Swift writes it: `currentFrame = minFrame` directly, NOT
    // `setCurrentFrame`, so the paste lands relative to the selection while
    // `animationTime` (the sampled pose) and the playhead line stay where
    // they were until the next scrub. Whether the playhead was meant to
    // move is not recoverable from the source, and making it move would
    // change what the artist sees after every duplicate; recorded rather
    // than guessed.
    currentFrame = minFrame;
    pasteCopiedKeyframes();
}

// ---- Events ---------------------------------------------------------------
//
// Events live on the scene clip as one track per definition, so they
// inherit the whole keyframe toolchain.

std::optional<AnimationEvent> EditorScene::animationEvent(Uuid id) const {
    for (const AnimationEvent& e : animationEvents) {
        if (e.id == id) return e;
    }
    return std::nullopt;
}

std::vector<Uuid> EditorScene::keyedEventIDs() const {
    std::vector<Uuid> out;
    for (const AnimationEvent& e : animationEvents) {
        if (sceneAnimationClip.hasTrack(e.id, AnimationTrackProperty::Event)) out.push_back(e.id);
    }
    return out;
}

std::string EditorScene::uniqueEventName(const std::string& requested, std::optional<Uuid> excluding) const {
    std::unordered_set<std::string> taken;
    for (const AnimationEvent& e : animationEvents) {
        if (excluding.has_value() && e.id == *excluding) continue;
        taken.insert(e.name);
    }
    if (!taken.contains(requested)) return requested;
    int suffix = 2;
    while (taken.contains(requested + " " + std::to_string(suffix))) suffix += 1;
    return requested + " " + std::to_string(suffix);
}

Uuid EditorScene::createAnimationEvent(std::optional<std::string> requestedName) {
    pushUndoState();
    AnimationEvent event;
    event.name = uniqueEventName(requestedName.value_or("event"), std::nullopt);
    animationEvents.push_back(event);
    return event.id;
}

void EditorScene::renameAnimationEvent(Uuid id, const std::string& newName) {
    auto it = std::find_if(animationEvents.begin(), animationEvents.end(),
                           [&](const AnimationEvent& e) { return e.id == id; });
    if (it == animationEvents.end()) return;
    const std::string trimmed = trimmedName(newName);
    if (trimmed.empty() || trimmed == it->name) return;
    pushUndoState();
    const std::string unique = uniqueEventName(trimmed, id);
    it->name = unique;
}

void EditorScene::replaceAnimationEvent(const AnimationEvent& updated) {
    auto it = std::find_if(animationEvents.begin(), animationEvents.end(),
                           [&](const AnimationEvent& e) { return e.id == updated.id; });
    if (it == animationEvents.end()) return;
    pushUndoState();
    *it = updated;
}

// Deletes the definition AND every key that raised it: keys left behind
// would fire with no name attached.
void EditorScene::deleteAnimationEvent(Uuid id) {
    if (!animationEvent(id).has_value()) return;
    pushUndoState();
    animationEvents.erase(std::remove_if(animationEvents.begin(), animationEvents.end(),
                                         [&](const AnimationEvent& e) { return e.id == id; }),
                          animationEvents.end());
    std::unordered_set<Uuid, UuidHash> keys;
    for (const Keyframe& k : sceneAnimationClip.keyframesFor(id, AnimationTrackProperty::Event)) keys.insert(k.id);
    if (!keys.empty()) sceneAnimationClip.deleteKeyframes(id, AnimationTrackProperty::Event, keys);
}

void EditorScene::keyEvent(Uuid eventID, const AnimationEventPayload& payload) {
    if (!animationEvent(eventID).has_value()) return;
    pushUndoState();
    sceneAnimationClip.upsertKeyframe(eventID, AnimationTrackProperty::Event, currentFrame, EventValue{payload});
}

bool EditorScene::eventHasKeyAtPlayhead(Uuid eventID) const {
    const auto& keys = sceneAnimationClip.keyframesFor(eventID, AnimationTrackProperty::Event);
    return std::any_of(keys.begin(), keys.end(), [&](const Keyframe& k) { return k.frame == currentFrame; });
}

void EditorScene::removeEventKeyAtPlayhead(Uuid eventID) {
    for (const Keyframe& k : sceneAnimationClip.keyframesFor(eventID, AnimationTrackProperty::Event)) {
        if (k.frame != currentFrame) continue;
        const Uuid keyID = k.id;
        pushUndoState();
        sceneAnimationClip.deleteKeyframes(eventID, AnimationTrackProperty::Event, {keyID});
        return;
    }
}

std::optional<AnimationEventPayload> EditorScene::eventPayloadAtPlayhead(Uuid eventID) const {
    for (const Keyframe& k : sceneAnimationClip.keyframesFor(eventID, AnimationTrackProperty::Event)) {
        if (k.frame != currentFrame) continue;
        if (const AnimationEventPayload* p = eventPayload(k.value)) return *p;
        return std::nullopt;
    }
    return std::nullopt;
}

void EditorScene::setEventPayloadAtPlayhead(Uuid eventID, const AnimationEventPayload& payload) {
    if (!eventHasKeyAtPlayhead(eventID)) return;
    pushUndoState();
    sceneAnimationClip.upsertKeyframe(eventID, AnimationTrackProperty::Event, currentFrame, EventValue{payload});
}

// Every event key after `from`, up to and including `to`. Scrubbing
// backwards fires nothing (replaying because the artist dragged left would
// be noise); a backwards move WHILE PLAYING is a loop wrap, taken as two
// forward spans so keys near the loop point are not skipped.
//
// The wrap spans use the running session's bounds. Swift uses the project
// range (`playbackStartFrame`/`playbackEndFrame`) -- but in Swift this
// branch never runs (see `tickPlayback`), and a session started with its
// own bounds (the timeline's clip range) wraps over THOSE, so the project
// range would fire keys the loop never crossed. With no session, the
// project range, as Swift.
//
// And the two spans are ordered EACH by frame, then appended in the order
// they were crossed. Swift sorts the union by frame, which puts the start
// of the new lap (frame 1) before the end of the old one (frame 9) -- the
// readout's "most recent" would be the one that happened first. Harmless
// in Swift only because the branch never ran.
//
// Swift's `lastEventScanFrame` is written here and read nowhere (verified
// by grep: three mentions, the declaration and two writes). Not ported.
void EditorScene::fireEventsCrossed(int from, int to) {
    if (animationEvents.empty() || from == to) return;

    auto byFrame = [](const FiredAnimationEvent& a, const FiredAnimationEvent& b) { return a.frame < b.frame; };
    std::vector<FiredAnimationEvent> fired;
    if (to > from) {
        collectEvents(from + 1, to, fired);
        std::stable_sort(fired.begin(), fired.end(), byFrame);
    } else if (isPlaying) {
        const int loopEnd = playbackSession.has_value() ? playbackSession->maxFrame : playbackEndFrame;
        const int loopStart = playbackSession.has_value() ? playbackSession->minFrame : playbackStartFrame;
        const int upper = std::max(loopEnd, from);
        if (upper > from) collectEvents(from + 1, upper, fired);
        std::stable_sort(fired.begin(), fired.end(), byFrame);
        std::vector<FiredAnimationEvent> newLap;
        if (to >= loopStart) collectEvents(loopStart, to, newLap);
        std::stable_sort(newLap.begin(), newLap.end(), byFrame);
        fired.insert(fired.end(), newLap.begin(), newLap.end());
    }
    if (fired.empty()) return;

    // A live readout, not a log: the last 32.
    recentlyFiredEvents.insert(recentlyFiredEvents.end(), fired.begin(), fired.end());
    if (recentlyFiredEvents.size() > 32) {
        recentlyFiredEvents.erase(recentlyFiredEvents.begin(),
                                  recentlyFiredEvents.end() - 32);
    }
}

void EditorScene::collectEvents(int lower, int upper, std::vector<FiredAnimationEvent>& fired) const {
    for (const AnimationEvent& definition : animationEvents) {
        for (const Keyframe& k : sceneAnimationClip.keyframesFor(definition.id, AnimationTrackProperty::Event)) {
            if (k.frame < lower || k.frame > upper) continue;
            const AnimationEventPayload* stored = eventPayload(k.value);
            const AnimationEventPayload payload = stored != nullptr ? *stored : AnimationEventPayload{};
            const AnimationEventPayload::Resolved resolved = payload.resolved(definition);
            fired.push_back(FiredAnimationEvent{definition.id, definition.name, k.frame, resolved.intValue,
                                                resolved.floatValue, resolved.stringValue});
        }
    }
}

} // namespace umeshcore
