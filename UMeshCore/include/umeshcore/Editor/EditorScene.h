#pragma once

// A minimal, portable "Scene" aggregate for `ToolManager`/the 8 tools --
// what `Data/SceneManager.swift` (~7,400 lines, ~400 `@Published`
// properties mixing true model data with UI-only state) reduces to once
// every property a tool actually needs is separated from the ~350 that are
// pure Mac/Windows UI chrome (panel visibility, hover highlighting for
// SwiftUI views, timeline scroll position, etc.). See ROADMAP.md's named
// risk #1: this is deliberately NOT a full SceneManager port -- each later
// phase absorbs more of SceneManager's surface into this class or a sibling
// one as tools/subsystems that need it get ported, rather than attempting
// the whole 7,400-line class in one pass.
//
// Fields and methods here are 1:1 with their SceneManager counterparts
// (same names, same semantics) except where noted. Deliberately NOT
// included yet, because nothing in this port sets or reads them:
// `selectedKeyframes`/`selectedKeyframe` (timeline multi-selection --
// belongs with the timeline UI port), `ikBuilder` (the IK-chain-building
// wizard's draft state), `meshWeightPaintEnabled`/`isMeshEditEnabled`/
// `isBindingBonesMode`/`pendingCanvasMode`/`meshEditNotice` (Bind Mode /
// weight paint / mesh edit mode -- `MeshTool`/`BoneTool` scope, not yet
// ported), `activeWeightPaintBoneID`, and anything from `CanvasPicking`
// (needs Phase 4/5's asset/texture pipeline). Consequently,
// `boneSelectionBecameNonEmpty`'s Swift counterpart calls
// `leaveSpriteModes()`, which this port omits: with every flag it would
// touch permanently false today, that call is a no-op, not a behavior
// change -- porting it for real is deferred to when those modes land.

#include <algorithm>
#include <optional>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "umeshcore/Animation/AnimationEvent.h"
#include "umeshcore/Animation/SceneAnimator.h"
#include "umeshcore/Constraints/ConstraintAnimation.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Editor/UndoRedoManager.h"
#include "umeshcore/Model/SceneImage.h"
#include "umeshcore/Model/Skeleton.h"
#include "umeshcore/Model/Skin.h"

namespace umeshcore {

class EditorScene {
public:
    // --- Model data ---
    std::vector<SceneImage> images;
    Skeleton skeleton;
    AnimationClip sceneAnimationClip{"Scene"};
    std::vector<Skin> skins;
    std::optional<Uuid> activeSkinID;
    std::vector<AnimationEvent> animationEvents;
    std::unordered_map<Uuid, ConstraintSetupValues, UuidHash> constraintSetupValues;

    // --- Animation transport (owned by the timeline in Swift; a plain
    // field here, set by whatever plays that role) ---
    bool isAnimationEditingEnabled = false;
    bool isPoseMode = false;
    int currentFrame = 0;
    float animationTime = 0.0f;
    // Timeline playback range hints (`SceneManager.playbackStartFrame`/
    // `playbackEndFrame`, `SceneManager.swift:276-277`). Real scene state,
    // not UI-only -- used by the META chunk of the binary exporter (see
    // Serialization/BinaryExporter.h) and, eventually, the timeline itself.
    int playbackStartFrame = 0;
    int playbackEndFrame = 0;

    // --- Selection state ---
    std::optional<Uuid> selectedImageID;
    std::unordered_set<Uuid, UuidHash> selectedImageIDs;
    std::optional<Uuid> selectedBoneID;
    std::unordered_set<Uuid, UuidHash> selectedBoneIDs;
    // The one place order is authoritative -- see `applyBoneSelection`.
    std::vector<Uuid> boneSelectionOrder;
    bool isMeshLayerSelected = false;
    std::unordered_set<int> selectedMeshVertexIndices;
    std::optional<int> selectedMeshInternalEdgeIndex;
    std::optional<int> hoveredMeshVertexIndex;
    std::optional<Uuid> hoveredBindBoneID;
    std::optional<Uuid> hoveredImageID;
    std::optional<Uuid> selectedConstraintID;

    // --- Drag preview: the sprite's DRAWN position while a drag is live,
    // before the mouse-up commit writes `SceneImage::position` for real ---
    std::unordered_map<Uuid, Vec2, UuidHash> previewPositions;

    // The live preview line `BoneTool` draws while a new bone is being
    // dragged out (from empty canvas, or chained off an existing bone's
    // tip) -- both nullopt when nothing is being created. Presentation-only
    // state, matching `SceneManager.setBoneCreationPreview`.
    std::optional<Vec2> boneCreationPreviewStart;
    std::optional<Vec2> boneCreationPreviewEnd;

    // Temporary world-position overrides written by `PhysicsPreviewTool`
    // while a bone is being dragged.
    //
    // NOTHING READS THIS, HERE OR IN SWIFT, and that is not a gap in the
    // port. `PhysicsPreviewTool`'s own doc comment claims
    // `baseWorldMatrices()` reads the overrides to feed rest targets into
    // the solver; it does not. Verified by grep over the whole Swift
    // source: `physicsPreviewOverrides` has exactly three mentions -- its
    // declaration and the two `SceneManager` methods that write it -- and
    // `baseWorldMatrices` never consults it. The feature is unfinished on
    // the Swift side, not lost in translation, so the field exists with
    // the same shape and the same (absent) effect rather than being
    // invented here. See `PhysicsPreviewTool.h`.
    std::unordered_map<Uuid, Vec2, UuidHash> physicsPreviewOverrides;
    void setBoneCreationPreview(std::optional<Vec2> start, std::optional<Vec2> end) {
        boneCreationPreviewStart = start;
        boneCreationPreviewEnd = end;
    }

    // --- Undo/redo ---
    UndoRedoManager undoRedo;

    // --- Cross-frame continuity state SceneAnimator needs (see
    // `applyBoneBindings`'s doc comment) ---
    std::unordered_map<Uuid, float, UuidHash> lastBoundImageRotation;

    // --- Lookup ---

    SceneImage* image(Uuid id) {
        for (SceneImage& img : images) {
            if (img.id == id) return &img;
        }
        return nullptr;
    }
    const SceneImage* image(Uuid id) const {
        for (const SceneImage& img : images) {
            if (img.id == id) return &img;
        }
        return nullptr;
    }

    // --- Selection ---

    void setSelection(const std::vector<Uuid>& ids, std::optional<Uuid> primary, bool additive) {
        if (additive) {
            for (Uuid id : ids) selectedImageIDs.insert(id);
        } else {
            selectedImageIDs = std::unordered_set<Uuid, UuidHash>(ids.begin(), ids.end());
        }
        selectedImageID =
            primary.has_value() ? primary
            : (selectedImageIDs.empty() ? std::nullopt : std::optional<Uuid>(*selectedImageIDs.begin()));
        isMeshLayerSelected = false;
        hoveredMeshVertexIndex = std::nullopt;
        selectedMeshVertexIndices.clear();
        selectedMeshInternalEdgeIndex = std::nullopt;
        // The whole bone selection, not just the primary -- see
        // `Data/SceneManager.swift`'s `setSelection` comment: clearing one
        // field of three left bones selected but invisible.
        applyBoneSelection({});
    }

    void clearSelection() {
        selectedImageID = std::nullopt;
        selectedImageIDs.clear();
        applyBoneSelection({});
        isMeshLayerSelected = false;
        hoveredMeshVertexIndex = std::nullopt;
        selectedMeshVertexIndices.clear();
        selectedMeshInternalEdgeIndex = std::nullopt;
    }

    void selectMeshLayer(Uuid imageID) {
        setSelection({imageID}, imageID, false);
        isMeshLayerSelected = true;
    }

    void selectMeshVertices(std::unordered_set<int> indices) { selectedMeshVertexIndices = std::move(indices); }

    // Replace or extend the bone selection. `ids` arrive in the order they
    // should hold; `primary`, when given and still present, moves to the
    // end so it stays the active bone.
    void setBoneSelection(const std::vector<Uuid>& ids, std::optional<Uuid> primary, bool additive) {
        std::vector<Uuid> order = additive ? boneSelectionOrder : std::vector<Uuid>{};
        for (Uuid id : ids) {
            if (std::find(order.begin(), order.end(), id) == order.end()) order.push_back(id);
        }
        if (primary.has_value()) {
            auto it = std::find(order.begin(), order.end(), *primary);
            if (it != order.end()) {
                order.erase(it);
                order.push_back(*primary);
            }
        }
        applyBoneSelection(order);
        if (!order.empty()) boneSelectionBecameNonEmpty();
    }

    void selectBone(std::optional<Uuid> id) {
        applyBoneSelection(id.has_value() ? std::vector<Uuid>{*id} : std::vector<Uuid>{});
        if (id.has_value()) boneSelectionBecameNonEmpty();
    }

    void toggleBoneSelection(Uuid id) {
        if (std::find(boneSelectionOrder.begin(), boneSelectionOrder.end(), id) != boneSelectionOrder.end()) {
            std::vector<Uuid> filtered;
            for (Uuid existing : boneSelectionOrder) {
                if (existing != id) filtered.push_back(existing);
            }
            applyBoneSelection(filtered);
        } else {
            setBoneSelection({id}, id, true);
        }
    }

    // Selected bones sorted root -> tip. Two callers need this order: IK
    // wants a chain well-defined regardless of click order, and the bone
    // transform setters take world values converted against the parent's
    // CURRENT world transform, so a child written before its parent turns
    // twice.
    std::vector<Bone> selectedBonesInChainOrder() const {
        struct Entry {
            int position;
            Bone bone;
        };
        std::vector<Entry> entries;
        for (std::size_t i = 0; i < boneSelectionOrder.size(); ++i) {
            if (const Bone* b = skeleton.bone(boneSelectionOrder[i])) {
                entries.push_back(Entry{static_cast<int>(i), *b});
            }
        }
        std::stable_sort(entries.begin(), entries.end(), [this](const Entry& a, const Entry& b) {
            const int da = depthOf(a.bone), db = depthOf(b.bone);
            return da != db ? da < db : a.position < b.position;
        });
        std::vector<Bone> out;
        out.reserve(entries.size());
        for (const Entry& e : entries) out.push_back(e.bone);
        return out;
    }

    std::vector<Uuid> selectedBonesInDepthOrder() const {
        std::vector<Uuid> out;
        for (const Bone& b : selectedBonesInChainOrder()) out.push_back(b.id);
        return out;
    }

    // --- Drag preview ---

    void setPreviewPosition(Uuid id, Vec2 position) { previewPositions[id] = position; }
    void clearPreviewPosition(Uuid id) { previewPositions.erase(id); }

    // The sprite as it should be DRAWN this frame: `position` overridden by
    // its live drag preview, if one exists.
    SceneImage renderPose(const SceneImage& img) const {
        auto it = previewPositions.find(img.id);
        if (it == previewPositions.end()) return img;
        SceneImage resolved = img;
        resolved.position = it->second;
        return resolved;
    }

    // --- Sprite transform mutators ---

    void setImagePosition(Uuid id, Vec2 position) {
        SceneImage* img = image(id);
        if (img == nullptr) return;
        img->position = position;
        syncImageSetupPoseFromVisiblePose(*img);
    }
    void setImageRotation(Uuid id, float rotation) {
        SceneImage* img = image(id);
        if (img == nullptr) return;
        img->rotation = rotation;
        syncImageSetupPoseFromVisiblePose(*img);
    }
    void setImageScale(Uuid id, Vec2 scale) {
        SceneImage* img = image(id);
        if (img == nullptr) return;
        img->scale = scale;
        syncImageSetupPoseFromVisiblePose(*img);
    }
    void setImageSkew(Uuid id, Vec2 skew) {
        SceneImage* img = image(id);
        if (img == nullptr) return;
        img->skew = skew;
        syncImageSetupPoseFromVisiblePose(*img);
    }
    void setImageRotation3D(Uuid id, Vec3 rotation3D) {
        SceneImage* img = image(id);
        if (img == nullptr) return;
        img->rotation3D = rotation3D;
        if (!isAnimationEditingEnabled) img->baseRotation3D = rotation3D;
    }

    // --- Bone transform mutators ---

    void moveBoneRoot(Uuid id, Vec2 worldStart) {
        const Bone* existing = skeleton.bone(id);
        if (existing == nullptr) return;
        Bone bone = *existing;
        const Vec2 local = skeleton.localPoint(worldStart, bone.parentID);
        bone.localTransform.position = Vec3(local.x, local.y, 0);
        if (!isAnimationEditingEnabled && !isPoseMode) bone.baseTransform.position = bone.localTransform.position;
        skeleton.setBone(bone);
        if (isAnimationEditingEnabled && !isPoseMode) {
            commitKeyframe(
                id, AnimationTrackProperty::Translate,
                TranslateValue{Vec2(bone.localTransform.position.x, bone.localTransform.position.y)});
        } else {
            applyAnimationsNow();
        }
    }

    void moveBoneTip(Uuid id, Vec2 worldTip) {
        const Bone* existing = skeleton.bone(id);
        if (existing == nullptr) return;
        Bone bone = *existing;
        const Vec2 worldStart = skeleton.lineSegment(id).has_value() ? skeleton.lineSegment(id)->start : worldTip;
        const Vec2 parentSpaceTip = skeleton.localPoint(worldTip, bone.parentID);
        const Vec2 parentSpaceStart(bone.localTransform.position.x, bone.localTransform.position.y);
        const Vec2 delta = parentSpaceTip - parentSpaceStart;
        const Vec2 fallbackDelta = worldTip - worldStart;
        const Vec2 resolvedDelta = lengthSquared(delta) > 0.0001f ? delta : fallbackDelta;
        bone.length = std::max(length(resolvedDelta), 12.0f);
        bone.localTransform.rotation.z = std::atan2(resolvedDelta.y, resolvedDelta.x);
        if (!isAnimationEditingEnabled && !isPoseMode) bone.baseTransform.rotation.z = bone.localTransform.rotation.z;
        skeleton.setBone(bone);
        if (isAnimationEditingEnabled && !isPoseMode) {
            commitKeyframe(id, AnimationTrackProperty::Rotate, RotateValue{bone.localTransform.rotation.z});
        } else {
            applyAnimationsNow();
        }
    }

    void setBoneRotation(Uuid id, float worldAngle) {
        const Bone* existing = skeleton.bone(id);
        if (existing == nullptr) return;
        Bone bone = *existing;
        const auto parentAngle = bone.parentID.has_value() ? skeleton.worldRotation(*bone.parentID) : std::nullopt;
        bone.localTransform.rotation.z = worldAngle - (parentAngle.has_value() ? *parentAngle : 0.0f);
        if (!isAnimationEditingEnabled && !isPoseMode) bone.baseTransform.rotation.z = bone.localTransform.rotation.z;
        skeleton.setBone(bone);
        if (isAnimationEditingEnabled && !isPoseMode) {
            commitKeyframe(id, AnimationTrackProperty::Rotate, RotateValue{bone.localTransform.rotation.z});
        } else {
            applyAnimationsNow();
        }
    }

    void setBoneSkew(Uuid id, Vec2 skew) {
        const Bone* existing = skeleton.bone(id);
        if (existing == nullptr) return;
        Bone bone = *existing;
        bone.localTransform.skew = skew;
        if (!isAnimationEditingEnabled && !isPoseMode) bone.baseTransform.skew = skew;
        skeleton.setBone(bone);
        if (isAnimationEditingEnabled && !isPoseMode) {
            commitKeyframe(id, AnimationTrackProperty::Shear, ShearValue{bone.localTransform.skew});
        } else {
            applyAnimationsNow();
        }
    }

    void setBoneLength(Uuid id, float length_) {
        const Bone* existing = skeleton.bone(id);
        if (existing == nullptr) return;
        Bone bone = *existing;
        bone.length = std::max(length_, 12.0f);
        skeleton.setBone(bone);
        applyAnimationsNow();
    }

    void setBoneScale(Uuid id, Vec2 scale) {
        const Bone* existing = skeleton.bone(id);
        if (existing == nullptr) return;
        Bone bone = *existing;
        bone.localTransform.scale.x = std::max(scale.x, 0.001f);
        bone.localTransform.scale.y = std::max(scale.y, 0.001f);
        if (!isAnimationEditingEnabled && !isPoseMode) {
            bone.baseTransform.scale.x = bone.localTransform.scale.x;
            bone.baseTransform.scale.y = bone.localTransform.scale.y;
        }
        skeleton.setBone(bone);
        if (isAnimationEditingEnabled && !isPoseMode) {
            commitKeyframe(
                id, AnimationTrackProperty::Scale,
                ScaleValue{Vec2(bone.localTransform.scale.x, bone.localTransform.scale.y)});
        } else {
            applyAnimationsNow();
        }
    }

    // Creates a new bone from `start` to `end` (world space), optionally
    // parented to `parentID`, selects it, and returns its id. 1:1 port of
    // `SceneManager.addBone`, minus the hierarchy-panel bookkeeping
    // (`hierarchyItems`/`normalizeOrder`/`syncImagesToHierarchy`) that
    // Swift's version also does -- outliner/UI-panel state, outside
    // EditorScene's "what tools need" boundary (see this file's header).
    Uuid addBone(Vec2 start, Vec2 end, std::optional<Uuid> parentID = std::nullopt) {
        pushUndoState();
        const int boneIndex = static_cast<int>(skeleton.bones().size()) + 1;
        const std::optional<Mat4> parentMatrix = parentID.has_value() ? skeleton.worldMatrix(*parentID) : std::nullopt;
        const Bone bone = Bone::make("Bone " + std::to_string(boneIndex), start, end, parentID, parentMatrix);
        skeleton = skeleton.addingBone(bone);
        selectBone(bone.id);
        return bone.id;
    }

    // --- Undo/redo ---

    void pushUndoState() { undoRedo.push(currentSnapshot()); }

    // Call at drag/interaction start -- pushes state only once per
    // continuous gesture.
    void beginInteraction() {
        if (interactionPushed_) return;
        interactionPushed_ = true;
        pushUndoState();
    }
    void endInteraction() { interactionPushed_ = false; }

    void undo() {
        const SceneSnapshot current = currentSnapshot();
        if (auto previous = undoRedo.undo(current)) applySnapshot(*previous);
    }
    void redo() {
        const SceneSnapshot current = currentSnapshot();
        if (auto next = undoRedo.redo(current)) applySnapshot(*next);
    }

    // --- Animation ---

    std::optional<SelectedKeyframe> commitKeyframe(
        Uuid targetID, AnimationTrackProperty property, std::optional<KeyframeValue> value = std::nullopt) {
        return umeshcore::commitKeyframe(
            skeleton, images, sceneAnimationClip, constraintSetupValues, isAnimationEditingEnabled, isPoseMode,
            animationTime, currentFrame, targetID, property, value, lastBoundImageRotation);
    }
    std::optional<SelectedKeyframe> commitMeshDeformKeyframe(Uuid imageID) {
        return umeshcore::commitMeshDeformKeyframe(
            skeleton, images, sceneAnimationClip, constraintSetupValues, isAnimationEditingEnabled, isPoseMode,
            animationTime, currentFrame, imageID, lastBoundImageRotation);
    }
    AnimationFrameResult applyAnimationsNow() {
        return umeshcore::applyAnimations(
            skeleton, images, sceneAnimationClip, constraintSetupValues, isAnimationEditingEnabled, isPoseMode,
            animationTime, lastBoundImageRotation);
    }

private:
    bool interactionPushed_ = false;

    SceneSnapshot currentSnapshot() const {
        SceneSnapshot s;
        s.images = images;
        s.skeleton = skeleton;
        s.sceneAnimationClip = sceneAnimationClip;
        s.skins = skins;
        s.activeSkinID = activeSkinID;
        s.animationEvents = animationEvents;
        return s;
    }
    void applySnapshot(const SceneSnapshot& s) {
        images = s.images;
        skeleton = s.skeleton;
        sceneAnimationClip = s.sceneAnimationClip;
        skins = s.skins;
        activeSkinID = s.activeSkinID;
        animationEvents = s.animationEvents;
    }

    // The one place the three bone-selection fields are written. `order`
    // is authoritative: the set is its contents and the primary is its
    // last element.
    void applyBoneSelection(std::vector<Uuid> order) {
        std::unordered_set<Uuid, UuidHash> seen;
        std::vector<Uuid> deduped;
        for (Uuid id : order) {
            if (skeleton.bone(id) == nullptr) continue;
            if (!seen.insert(id).second) continue;
            deduped.push_back(id);
        }
        boneSelectionOrder = deduped;
        selectedBoneIDs = std::unordered_set<Uuid, UuidHash>(deduped.begin(), deduped.end());
        selectedBoneID = deduped.empty() ? std::nullopt : std::optional<Uuid>(deduped.back());
    }

    // What picking a bone always means: a sprite and a bone are never both
    // the selection. `leaveSpriteModes()` is deferred -- see this file's
    // header comment.
    void boneSelectionBecameNonEmpty() {
        selectedImageID = std::nullopt;
        selectedImageIDs.clear();
        isMeshLayerSelected = false;
        hoveredMeshVertexIndex = std::nullopt;
        selectedMeshVertexIndices.clear();
        selectedMeshInternalEdgeIndex = std::nullopt;
    }

    int depthOf(const Bone& bone) const {
        int depth = 0;
        std::optional<Uuid> current = bone.parentID;
        int safety = 0;
        while (current.has_value() && safety < 64) {
            depth += 1;
            const Bone* parent = skeleton.bone(*current);
            current = parent != nullptr ? parent->parentID : std::nullopt;
            safety += 1;
        }
        return depth;
    }

    void syncImageBasePoseToVisiblePose(SceneImage& img, std::optional<Uuid> boneID) {
        const SceneImageAnimationPose local = localSpritePose(skeleton, img, boneID);
        img.basePosition = local.position;
        img.baseScale = local.scale;
        img.baseRotation = local.rotation;
        img.baseSkew = local.skew;
    }

    void syncImageSetupPoseFromVisiblePose(SceneImage& img) {
        if (isAnimationEditingEnabled) return;
        if (!img.boneBinding.has_value()) {
            syncImageBasePoseToVisiblePose(img, std::nullopt);
            return;
        }
        const SceneImageAnimationPose local = localSpritePose(skeleton, img, img.boneBinding->boneID);
        img.boneBinding->localPosition = local.position;
        img.boneBinding->localScale = local.scale;
        img.boneBinding->localRotation = local.rotation;
        img.boneBinding->localSkew = local.skew;
    }
};

} // namespace umeshcore
