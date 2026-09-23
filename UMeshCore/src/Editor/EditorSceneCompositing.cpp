// EditorScene -- Scene mode: the project's compositions, their layers and
// lights, the Scene selection, light and camera keys, the shot and lights
// sampled at a Scene frame, and the three view/shot alignments.
//
// Ported from `Data/SceneManager.swift`, `// MARK: - Scene mode state` and
// `// MARK: - Lights` up to `alignSceneViewToCamera`. The model types and
// their math (`SceneComposition`, `SceneLayer`, `SceneLight`,
// `SceneViewCamera`, `cameraBasis`) were ported in Phases 4-5; this file is
// only the editing surface over them, and calls them rather than
// re-deriving anything.
//
// One addition: `pruneSceneSelection` is CALLED (from `applySnapshot`).
// Swift declares it with the comment "called where a scene is replaced
// wholesale -- opening a project, undo" and never calls it: grep finds its
// declaration as its only mention. So undoing "add light" left the vanished
// light selected. Swift's views guard the lookup, so the visible symptom
// was an inspector/gizmo pointing at nothing rather than a crash; the fix
// is the one the comment describes.

#include "umeshcore/Editor/EditorScene.h"

#include <algorithm>
#include <cmath>
#include <set>

namespace umeshcore {

namespace {


// Swift's `lightColourChannels`: each colour channel's track, and which
// component of `color` it drives.
struct ColourChannel {
    AnimationTrackProperty property;
    float Vec3::*axis;
};
constexpr ColourChannel kLightColourChannels[] = {
    {AnimationTrackProperty::LightColorR, &Vec3::x},
    {AnimationTrackProperty::LightColorG, &Vec3::y},
    {AnimationTrackProperty::LightColorB, &Vec3::z},
};

// Swift's `Double.rounded()`: to nearest, halves away from zero.
int roundedFps(double fps) { return static_cast<int>(std::lround(fps)); }

} // namespace

SceneComposition* EditorScene::composition(Uuid id) {
    for (SceneComposition& c : sceneCompositions) {
        if (c.id == id) return &c;
    }
    return nullptr;
}

std::optional<SceneComposition> EditorScene::selectedSceneComposition() const {
    if (selectedSceneCompositionID.has_value()) {
        for (const SceneComposition& c : sceneCompositions) {
            if (c.id == *selectedSceneCompositionID) return c;
        }
    }
    if (sceneCompositions.empty()) return std::nullopt;
    return sceneCompositions.front();
}

std::optional<SceneLight> EditorScene::selectedSceneLight() const {
    const std::optional<Uuid> id = sceneSelection.lightID();
    if (!id.has_value()) return std::nullopt;
    const std::optional<SceneComposition> c = selectedSceneComposition();
    if (!c.has_value()) return std::nullopt;
    if (const SceneLight* light = c->light(*id)) return *light;
    return std::nullopt;
}

// The rig is what a Scene is FOR, so the first one opens with the rig on
// the set, on the focal plane where it shows at exactly its Editor size.
// Only when there is a rig: an empty project gets an empty Scene.
void EditorScene::ensureSceneCompositionExists() {
    if (!sceneCompositions.empty()) return;
    SceneComposition composition;
    composition.id = Uuid::generate();
    composition.name = "Scene 1";
    composition.durationInFrames = std::max(playbackEndFrame - playbackStartFrame + 1, 1);
    composition.fps = roundedFps(projectFramesPerSecond);
    if (!images.empty()) {
        SceneLayer rig;
        rig.id = Uuid::generate();
        rig.name = "Rig 1";
        rig.positionZ = composition.camera.positionZ + composition.camera.focalLength(composition.renderSize.y);
        rig.content = SceneRigContent{Uuid::generate(), 1.0f, 0, true};
        composition.layers.push_back(rig);
    }
    sceneCompositions = {composition};
    selectedSceneCompositionID = composition.id;
}

void EditorScene::replaceSceneComposition(const SceneComposition& updated, bool undoable) {
    SceneComposition* existing = composition(updated.id);
    if (existing == nullptr) return;
    if (undoable) pushUndoState();
    // `pushUndoState` copies the vector; the pointer is re-taken rather
    // than trusted across it.
    *composition(updated.id) = updated;
}

float EditorScene::defaultLayerZ(const SceneComposition& composition) {
    return composition.camera.positionZ + composition.camera.focalLength(composition.renderSize.y);
}

// Imported PNGs as plates and nothing else -- no hierarchy row, no mesh.
// A relief map is attached but its parallax stays OFF: an import must
// never silently change what a scene costs or looks like.
std::vector<Uuid> EditorScene::addScenePlates(const std::vector<ScenePlateAsset>& assets, Uuid compositionID) {
    const SceneComposition* found = composition(compositionID);
    if (found == nullptr || assets.empty()) return {};
    const float z = defaultLayerZ(*found);
    int order = found->frontSortingOrder();
    std::vector<Uuid> added;
    for (const ScenePlateAsset& asset : assets) {
        if (!asset.isPlaceable) continue;
        SceneLayer layer;
        layer.id = Uuid::generate();
        layer.name = asset.name;
        layer.positionZ = z;
        layer.sortingOrder = order;
        layer.material = sceneMaterialFlat();
        layer.material.normalMapAssetId = asset.normalMapAssetID;
        layer.material.heightMapAssetId = asset.heightMapAssetID;
        layer.content = ScenePlateContent{asset.assetID};
        order += 1;
        added.push_back(layer.id);
        // One undo entry PER PLATE, as Swift (each goes through
        // `addSceneLayer`).
        addSceneLayer(layer, compositionID);
    }
    return added;
}

void EditorScene::addSceneLayer(const SceneLayer& layer, Uuid compositionID) {
    SceneComposition* c = composition(compositionID);
    if (c == nullptr) return;
    SceneComposition updated = *c;
    updated.layers.push_back(layer);
    replaceSceneComposition(updated, true);
}

void EditorScene::removeSceneLayer(Uuid layerID, Uuid compositionID) {
    SceneComposition* c = composition(compositionID);
    if (c == nullptr) return;
    SceneComposition updated = *c;
    updated.layers.erase(std::remove_if(updated.layers.begin(), updated.layers.end(),
                                        [&](const SceneLayer& l) { return l.id == layerID; }),
                         updated.layers.end());
    replaceSceneComposition(updated, true);
}

// A layer that is not in the composition still costs the undo entry, as
// the Swift closure (a guard inside `updateSceneComposition`) does.
void EditorScene::replaceSceneLayer(const SceneLayer& layer, Uuid compositionID, bool undoable) {
    SceneComposition* c = composition(compositionID);
    if (c == nullptr) return;
    SceneComposition updated = *c;
    for (SceneLayer& l : updated.layers) {
        if (l.id == layer.id) {
            l = layer;
            break;
        }
    }
    replaceSceneComposition(updated, undoable);
}

// Not one step in the ARRAY (only the tie-break now, so a swap there would
// do nothing whenever the two numbers differ): the two layers' NUMBERS
// swap, keeping any grouping the artist built (10/20/30 does not become
// 0/1/2). Sharing a number, the tie itself moves.
void EditorScene::moveSceneLayer(Uuid layerID, Uuid compositionID, bool forward) {
    SceneComposition* c = composition(compositionID);
    if (c == nullptr) return;
    SceneComposition updated = *c;
    const std::vector<SceneLayer> ordered = updated.drawOrderedLayers();
    auto here = std::find_if(ordered.begin(), ordered.end(), [&](const SceneLayer& l) { return l.id == layerID; });
    if (here != ordered.end()) {
        const long target = (here - ordered.begin()) + (forward ? 1 : -1);
        if (target >= 0 && target < static_cast<long>(ordered.size())) {
            const Uuid otherID = ordered[static_cast<std::size_t>(target)].id;
            auto indexOf = [&](Uuid id) {
                return std::find_if(updated.layers.begin(), updated.layers.end(),
                                    [&](const SceneLayer& l) { return l.id == id; });
            };
            auto a = indexOf(layerID), b = indexOf(otherID);
            if (a->sortingOrder == b->sortingOrder) {
                std::iter_swap(a, b);
            } else {
                std::swap(a->sortingOrder, b->sortingOrder);
            }
        }
    }
    // The undo entry is pushed even when the move is refused at an end, as
    // the Swift closure's guards run after `updateSceneComposition` pushed.
    replaceSceneComposition(updated, true);
}

void EditorScene::selectSceneLight(std::optional<Uuid> id) {
    sceneSelection = id.has_value() ? SceneSelection::light(*id) : SceneSelection::none();
}

void EditorScene::selectSceneLayer(std::optional<Uuid> id) {
    sceneSelection = id.has_value() ? SceneSelection::layer(*id) : SceneSelection::none();
}

void EditorScene::pruneSceneSelection() {
    const std::optional<SceneComposition> c = selectedSceneComposition();
    if (!c.has_value()) {
        sceneSelection = SceneSelection::none();
        return;
    }
    if (const auto id = sceneSelection.layerID(); id.has_value() && c->layer(*id) == nullptr) {
        sceneSelection = SceneSelection::none();
    }
    if (const auto id = sceneSelection.lightID(); id.has_value() && c->light(*id) == nullptr) {
        sceneSelection = SceneSelection::none();
    }
}

// Placed where it will be SEEN: two thirds of the way from the camera to
// the focal plane (in front of a layer at the default depth), with a
// radius of three quarters of the frame's diagonal -- a light at the origin
// with a default radius is how a lighting feature reads as broken.
std::optional<Uuid> EditorScene::addSceneLight(SceneLightKind kind, Uuid compositionID) {
    const SceneComposition* c = composition(compositionID);
    if (c == nullptr) return std::nullopt;
    const float focal = c->camera.focalLength(c->renderSize.y);
    SceneLight light;
    light.id = Uuid::generate();
    light.name = std::string(sceneLightKindTitle(kind)) + " " + std::to_string(c->lights.size() + 1);
    light.kind = kind;
    light.position = c->camera.position;
    light.positionZ = c->camera.positionZ + focal * 0.66f;
    light.radius = length(c->renderSize) * 0.75f;
    if (kind == SceneLightKind::kSpot) {
        // Pointing into the set: the only useful way for a spot created at
        // the camera to point.
        light.azimuth = 0.0f;
        light.elevation = kPi / 2.0f;
    }
    SceneComposition updated = *c;
    updated.lights.push_back(light);
    replaceSceneComposition(updated, true);
    sceneSelection = SceneSelection::light(light.id);
    return light.id;
}

void EditorScene::replaceSceneLight(const SceneLight& light, Uuid compositionID, bool undoable) {
    SceneComposition* c = composition(compositionID);
    if (c == nullptr) return;
    SceneComposition updated = *c;
    for (SceneLight& l : updated.lights) {
        if (l.id == light.id) {
            l = light;
            break;
        }
    }
    replaceSceneComposition(updated, undoable);
}

void EditorScene::removeSceneLight(Uuid lightID, Uuid compositionID) {
    SceneComposition* c = composition(compositionID);
    if (c != nullptr) {
        SceneComposition updated = *c;
        updated.lights.erase(std::remove_if(updated.lights.begin(), updated.lights.end(),
                                            [&](const SceneLight& l) { return l.id == lightID; }),
                             updated.lights.end());
        replaceSceneComposition(updated, true);
    }
    if (sceneSelection == SceneSelection::light(lightID)) sceneSelection = SceneSelection::none();
}

void EditorScene::moveSceneLight(Uuid lightID, Uuid compositionID, bool forward) {
    SceneComposition* c = composition(compositionID);
    if (c == nullptr) return;
    SceneComposition updated = *c;
    auto here = std::find_if(updated.lights.begin(), updated.lights.end(),
                             [&](const SceneLight& l) { return l.id == lightID; });
    if (here != updated.lights.end()) {
        const long target = (here - updated.lights.begin()) + (forward ? 1 : -1);
        if (target >= 0 && target < static_cast<long>(updated.lights.size())) {
            std::iter_swap(here, updated.lights.begin() + target);
        }
    }
    replaceSceneComposition(updated, true);
}

// ---- Sampling ---------------------------------------------------------------

// Every property falls back to the AUTHORED camera: with a neutral fallback,
// keying the FOV alone would "animate" the untracked position to the
// origin. Sampled on the SCENE's frame axis.
SceneCamera EditorScene::sceneCamera(const SceneComposition& composition, int frame) const {
    SceneCamera camera = composition.camera;
    const Uuid target = SceneAnimationTarget::camera();
    const AnimationClip& clip = sceneAnimationClip;
    if (!clip.animatedTargetIDs().contains(target)) return camera;

    if (clip.hasTrack(target, AnimationTrackProperty::CameraTranslate)) {
        camera.position = clip.evaluatedVector2(target, AnimationTrackProperty::CameraTranslate, frame, camera.position);
    }
    if (clip.hasTrack(target, AnimationTrackProperty::CameraTranslateZ)) {
        camera.positionZ =
            clip.evaluatedScalar(target, AnimationTrackProperty::CameraTranslateZ, frame, camera.positionZ);
    }
    if (clip.hasTrack(target, AnimationTrackProperty::CameraRotate3D)) {
        const Vec2 xy = clip.evaluatedVector2(target, AnimationTrackProperty::CameraRotate3D, frame,
                                              Vec2(camera.rotation3D.x, camera.rotation3D.y));
        camera.rotation3D.x = xy.x;
        camera.rotation3D.y = xy.y;
    }
    if (clip.hasTrack(target, AnimationTrackProperty::CameraRoll)) {
        camera.rotation3D.z =
            clip.evaluatedScalar(target, AnimationTrackProperty::CameraRoll, frame, camera.rotation3D.z);
    }
    if (clip.hasTrack(target, AnimationTrackProperty::CameraFOV)) {
        const float sampled =
            clip.evaluatedScalar(target, AnimationTrackProperty::CameraFOV, frame, camera.fieldOfView);
        // Clamped where SAMPLED: an eased curve overshooting toward zero
        // would divide by tan(0) for a frame.
        camera.fieldOfView = std::min(std::max(sampled, 1.0f), 170.0f);
    }
    return camera;
}

std::vector<SceneLight> EditorScene::sceneLights(const SceneComposition& composition, int frame) const {
    if (composition.lights.empty()) return {};
    const auto animated = sceneAnimationClip.animatedTargetIDs();
    if (animated.empty()) return composition.lights;
    std::vector<SceneLight> out;
    out.reserve(composition.lights.size());
    for (const SceneLight& light : composition.lights) {
        out.push_back(animated.contains(light.id) ? sampledSceneLight(light, frame) : light);
    }
    return out;
}

SceneLight EditorScene::sampledSceneLight(const SceneLight& light, int frame) const {
    SceneLight result = light;
    const AnimationClip& clip = sceneAnimationClip;
    const Uuid target = light.id;
    auto scalar = [&](AnimationTrackProperty p, float fallback) -> std::optional<float> {
        if (!clip.hasTrack(target, p)) return std::nullopt;
        return clip.evaluatedScalar(target, p, frame, fallback);
    };
    auto vector = [&](AnimationTrackProperty p, Vec2 fallback) -> std::optional<Vec2> {
        if (!clip.hasTrack(target, p)) return std::nullopt;
        return clip.evaluatedVector2(target, p, frame, fallback);
    };

    if (auto p = vector(AnimationTrackProperty::LightTranslate, light.position)) result.position = *p;
    if (auto z = scalar(AnimationTrackProperty::LightTranslateZ, light.positionZ)) result.positionZ = *z;
    // Clamped where SAMPLED: overshooting tangents between intensity keys
    // 0 and 1 dip below zero, and a negative light subtracts.
    if (auto i = scalar(AnimationTrackProperty::LightIntensity, light.intensity)) result.intensity = std::max(*i, 0.0f);
    if (auto r = scalar(AnimationTrackProperty::LightRadius, light.radius)) result.radius = std::max(*r, 0.0f);
    if (auto s = scalar(AnimationTrackProperty::LightSoftness, light.softness)) {
        result.softness = std::min(std::max(*s, 0.0f), 1.0f);
    }
    if (auto d = vector(AnimationTrackProperty::LightDirection, Vec2(light.azimuth, light.elevation))) {
        result.azimuth = d->x;
        result.elevation = d->y;
    }
    if (auto a = vector(AnimationTrackProperty::LightAngles, Vec2(light.innerAngle, light.outerAngle))) {
        // As a PAIR, outer first: the inner angle is clamped against the
        // angle the shot is arriving at, not the one it is leaving.
        result.outerAngle = std::min(std::max(a->y, 0.0f), kPi);
        result.innerAngle = std::min(std::max(a->x, 0.0f), result.outerAngle);
    }
    for (const ColourChannel& channel : kLightColourChannels) {
        const auto value = scalar(channel.property, light.color.*channel.axis);
        if (!value.has_value()) continue;
        result.color.*channel.axis = std::min(std::max(*value, 0.0f), 1.0f);
    }
    return result;
}

// ---- Keys -------------------------------------------------------------------

// Every property of a light at once: keying only what changed leaves the
// other channels free to drift on the next key.
void EditorScene::keySceneLight(const SceneLight& light, int frame) {
    pushUndoState();
    AnimationClip& clip = sceneAnimationClip;
    const Uuid t = light.id;
    clip.upsertKeyframe(t, AnimationTrackProperty::LightTranslate, frame, Vector2Value{light.position});
    clip.upsertKeyframe(t, AnimationTrackProperty::LightTranslateZ, frame, ScalarValue{light.positionZ});
    clip.upsertKeyframe(t, AnimationTrackProperty::LightIntensity, frame, ScalarValue{light.intensity});
    clip.upsertKeyframe(t, AnimationTrackProperty::LightRadius, frame, ScalarValue{light.radius});
    clip.upsertKeyframe(t, AnimationTrackProperty::LightSoftness, frame, ScalarValue{light.softness});
    clip.upsertKeyframe(t, AnimationTrackProperty::LightDirection, frame,
                        Vector2Value{Vec2(light.azimuth, light.elevation)});
    clip.upsertKeyframe(t, AnimationTrackProperty::LightAngles, frame,
                        Vector2Value{Vec2(light.innerAngle, light.outerAngle)});
    for (const ColourChannel& channel : kLightColourChannels) {
        clip.upsertKeyframe(t, channel.property, frame, ScalarValue{light.color.*channel.axis});
    }
}

namespace {

bool hasKeyAt(const AnimationClip& clip, Uuid target, int frame) {
    for (const AnimationTrack& track : clip.tracks()) {
        if (track.targetID != target) continue;
        for (const Keyframe& k : track.keyframes) {
            if (k.frame == frame) return true;
        }
    }
    return false;
}

template <std::size_t N>
void deleteKeysAt(AnimationClip& clip, Uuid target, int frame, const std::array<AnimationTrackProperty, N>& props) {
    for (AnimationTrackProperty property : props) {
        std::unordered_set<Uuid, UuidHash> ids;
        for (const Keyframe& k : clip.keyframesFor(target, property)) {
            if (k.frame == frame) ids.insert(k.id);
        }
        if (!ids.empty()) clip.deleteKeyframes(target, property, ids);
    }
}

} // namespace

void EditorScene::removeSceneLightKey(Uuid lightID, int frame) {
    if (!hasKeyAt(sceneAnimationClip, lightID, frame)) return;
    pushUndoState();
    deleteKeysAt(sceneAnimationClip, lightID, frame, lightProperties());
}

std::vector<int> EditorScene::keyFramesFor(Uuid targetID) const {
    std::set<int> frames;
    for (const AnimationTrack& track : sceneAnimationClip.tracks()) {
        if (track.targetID != targetID) continue;
        for (const Keyframe& k : track.keyframes) frames.insert(k.frame);
    }
    return std::vector<int>(frames.begin(), frames.end());
}

std::vector<int> EditorScene::sceneLightKeyFrames(Uuid lightID) const { return keyFramesFor(lightID); }

// The whole shot at once, like the rig's transform key.
void EditorScene::keySceneCamera(const SceneComposition& composition, int frame) {
    pushUndoState();
    const SceneCamera& camera = composition.camera;
    const Uuid t = SceneAnimationTarget::camera();
    AnimationClip& clip = sceneAnimationClip;
    clip.upsertKeyframe(t, AnimationTrackProperty::CameraTranslate, frame, Vector2Value{camera.position});
    clip.upsertKeyframe(t, AnimationTrackProperty::CameraTranslateZ, frame, ScalarValue{camera.positionZ});
    clip.upsertKeyframe(t, AnimationTrackProperty::CameraRotate3D, frame,
                        Vector2Value{Vec2(camera.rotation3D.x, camera.rotation3D.y)});
    clip.upsertKeyframe(t, AnimationTrackProperty::CameraRoll, frame, ScalarValue{camera.rotation3D.z});
    clip.upsertKeyframe(t, AnimationTrackProperty::CameraFOV, frame, ScalarValue{camera.fieldOfView});
}

void EditorScene::removeSceneCameraKey(int frame) {
    const Uuid t = SceneAnimationTarget::camera();
    if (!hasKeyAt(sceneAnimationClip, t, frame)) return;
    pushUndoState();
    deleteKeysAt(sceneAnimationClip, t, frame, cameraProperties());
}

std::vector<int> EditorScene::sceneCameraKeyFrames() const { return keyFramesFor(SceneAnimationTarget::camera()); }

// ---- View and shot ------------------------------------------------------------

void EditorScene::alignSceneCameraToView(Uuid compositionID) {
    SceneComposition* c = composition(compositionID);
    if (c == nullptr) return;
    const Vec3 eye = sceneViewCamera.eye();
    SceneComposition updated = *c;
    updated.camera.position = Vec2(eye.x, eye.y);
    updated.camera.positionZ = eye.z;
    updated.camera.rotation3D = Vec3(sceneViewCamera.pitch, sceneViewCamera.yaw, 0.0f);
    updated.camera.fieldOfView = sceneViewCamera.fieldOfView;
    replaceSceneComposition(updated, true);
}

// Pivot on the selected card, or on the shot's frame, at a distance that
// fits it. The fit is against the render frame at that depth, not the
// card's pixels (the core holds no asset store either): a small prop gets
// room around it, which is the right way to be wrong.
void EditorScene::frameSceneView(Uuid compositionID, std::optional<Uuid> layerID) {
    const SceneComposition* c = composition(compositionID);
    if (c == nullptr) return;
    const SceneCamera& shot = c->camera;
    const float focal = shot.focalLength(c->renderSize.y);
    SceneViewCamera view = sceneViewCamera;

    Vec3 target;
    float extent = 0.0f;
    const SceneLayer* layer = layerID.has_value() ? c->layer(*layerID) : nullptr;
    if (layer != nullptr) {
        target = Vec3(layer->position.x, layer->position.y, layer->positionZ);
        const float depth = std::max(layer->positionZ - shot.positionZ, 1.0f);
        extent = std::max(c->renderSize.x, c->renderSize.y) * (depth / std::max(focal, 0.000001f)) *
                 std::max({layer->scale.x, layer->scale.y, 0.01f});
    } else {
        const CameraBasis basis = cameraBasis(shot.rotation3D.x, shot.rotation3D.y, shot.rotation3D.z);
        target = Vec3(shot.position.x, shot.position.y, shot.positionZ) + basis.forward * focal;
        extent = std::max(c->renderSize.x, c->renderSize.y);
    }
    view.pivot = target;
    const float half = view.fieldOfView * kPi / 180.0f * 0.5f;
    // 1.25: a margin, so the framed thing does not touch the edges.
    view.distance = std::min(std::max(extent * 0.5f * 1.25f / std::max(std::tan(half), 0.0001f),
                                      SceneViewCamera::kMinDistance),
                             SceneViewCamera::kMaxDistance);
    sceneViewCamera = view;
}

// Stand where the shot is: the pivot goes `distance` in front of the shot's
// eye, so `eye()` lands exactly on it. Swift spells "forward" out again
// here; the formula is `cameraBasis`'s to the letter, so this calls it --
// one transcription, which is what keeps the eye and the shot together.
void EditorScene::alignSceneViewToCamera(Uuid compositionID) {
    const SceneComposition* c = composition(compositionID);
    if (c == nullptr) return;
    const SceneCamera& shot = c->camera;
    SceneViewCamera view = sceneViewCamera;
    view.pitch = std::min(std::max(shot.rotation3D.x, -SceneViewCamera::kPitchLimit), SceneViewCamera::kPitchLimit);
    view.yaw = shot.rotation3D.y;
    view.fieldOfView = shot.fieldOfView;
    const Vec3 forward = cameraBasis(view.pitch, view.yaw, 0.0f).forward;
    view.pivot = Vec3(shot.position.x, shot.position.y, shot.positionZ) + forward * view.distance;
    sceneViewCamera = view;
}

} // namespace umeshcore
