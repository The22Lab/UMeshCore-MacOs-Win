#pragma once

// A minimal, portable "Scene" aggregate for `ToolManager`/the 8 tools --
// what `Data/SceneManager.swift` (7,376 lines, 87 `@Published`
// properties mixing true model data with UI-only state) reduces to once
// every property a tool actually needs is separated from the ones that are
// pure Mac/Windows UI chrome (panel visibility, hover highlighting for
// SwiftUI views, timeline scroll position, etc.).
//
// Measured during Phase 6a, because the number used to be wrong here: of
// the 77 `@Published` declarations, 26 are model data with a counterpart
// in this port, 38 are unambiguously UI, and 5 are derived caches. This
// header (and CLAUDE.md) previously said "~400 `@Published`" and "~350 UI
// chrome"; both were guesses, and the inflated figure made the split look
// hopeless when it is roughly one third to two thirds.
//
// The two heaviest model properties are NOT `@Published` at all, which is
// the thing most likely to be broken by accident: `images` and `skeleton`
// are plain `var`s with `willSet { announceChange() }`, and
// `announceChange()` rate-limits to 12 Hz while the transport rolls.
// Publishing them would fire 60 notifications a second into a dozen
// observing views, since `applyAnimations()` alone has 49 call sites.
// See ROADMAP.md's named risk #1.
//
// PHASE 6a CHANGED WHAT THIS CLASS IS. It began as the minimal aggregate
// the tools need. The user's decision to disconnect the Swift core
// entirely means the Swift `SceneManager` becomes an adapter over THIS,
// so this class now grows into the real SceneManager: model state plus
// every operation the UI calls (264 distinct members, measured), the same
// implementation the Windows shell will use. What stays out is pure UI
// state (panel flags, hover highlights, notices) -- that is the adapter's.
// Plan and inventory: `bindings/swift/MIGRATION.md`.
//
// The inline methods below are the original tool-facing core; everything
// absorbed since is declared here and defined by area in
// `src/Editor/EditorScene*.cpp` (structure, skins, ...), so no single file
// has to hold 7 400 lines.
//
// Fields and methods here are 1:1 with their SceneManager counterparts
// (same names, same semantics) except where noted IN THE .cpp THAT
// DEFINES THEM. Not absorbed yet: the mesh-edit and weight-paint
// OPERATIONS (`MeshTool`, A6) and anything from `CanvasPicking` that needs
// a loaded texture's alpha. The mode FLAGS are here (A5), so
// `boneSelectionBecameNonEmpty` now calls `leaveSpriteModes()` as Swift
// does.

#include <algorithm>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "umeshcore/Animation/AnimationEvent.h"
#include "umeshcore/Animation/SceneAnimator.h"
#include "umeshcore/Constraints/ConstraintAnimation.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Constraints/PhysicsConstraintSystem.h"
#include "umeshcore/Editor/EditorEscape.h"
#include "umeshcore/Editor/IKBuilder.h"
#include "umeshcore/Editor/ToolType.h"
#include "umeshcore/Editor/UndoRedoManager.h"
#include "umeshcore/Model/HierarchyItem.h"
#include "umeshcore/Interop/SwiftBridge.h"
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

    // --- Structure (Phase 6a: absorbed from SceneManager) ---

    // The outliner's rows. Their `order` is kept dense (0..n-1) by
    // `normalizeOrder` after every structural edit.
    std::vector<HierarchyItem> hierarchyItems;

    // The AUTHORED draw order: sprite ids, front to back. Its own list on
    // purpose -- the tree answers "what is parented to what", draw order
    // answers "what is in front of what", and deriving the second from the
    // first threw away any order written across a bone boundary. Empty
    // means "not authored yet", and the array order of `images` applies.
    // Written only through `setAuthoredDrawOrder`. NOT part of the undo
    // snapshot, which matches Swift.
    std::vector<Uuid> authoredDrawOrder;

    // What the last animation pass decided, stored the way Swift stores
    // them (`@Published private(set)`): the keyed draw order, if a draw
    // order key is in effect, and which attachment each keyed slot shows.
    // A slot ABSENT from the map is left to the skin; present with nullopt
    // is deliberately empty.
    std::optional<std::vector<Uuid>> animatedDrawOrder;
    std::unordered_map<std::string, std::optional<Uuid>> animatedAttachments;

    // Cached resolution of the active skin. Recomputed when skins, slots or
    // the sprite list change, never per draw.
    SkinResolution skinResolution;

    // The timeline's keyframe selection.
    std::vector<SelectedKeyframe> selectedKeyframes;
    std::optional<SelectedKeyframe> selectedKeyframe;

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
    // 90, as Swift declares it (the port had 0; the document default was
    // already 90, so a fresh scene and a fresh file now agree).
    int playbackEndFrame = 90;

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
        // Keyframes stay selected only on the sprites still selected.
        std::vector<SelectedKeyframe> kept;
        for (const SelectedKeyframe& k : selectedKeyframes) {
            if (selectedImageIDs.contains(k.imageID)) kept.push_back(k);
        }
        selectedKeyframes = std::move(kept);
        selectedKeyframe = selectedKeyframes.empty() ? std::nullopt
                                                     : std::optional<SelectedKeyframe>(selectedKeyframes.front());
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

    // A vertex selection and an internal-edge selection are exclusive:
    // selecting vertices drops the edge (Swift does this; the earlier port
    // did not, so a stale edge stayed "selected" under a vertex drag).
    void selectMeshVertices(std::unordered_set<int> indices) {
        selectedMeshVertexIndices = std::move(indices);
        if (!selectedMeshVertexIndices.empty()) selectedMeshInternalEdgeIndex = std::nullopt;
    }

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
    // parented to `parentID`, gives it its outliner row, selects it, and
    // returns its id. 1:1 port of `SceneManager.addBone`. (The row used to
    // be left out as "panel state"; since Phase 6a `hierarchyItems` is
    // model state here, and a bone with no row drops its whole subtree out
    // of `displayHierarchyIDs`.)
    Uuid addBone(Vec2 start, Vec2 end, std::optional<Uuid> parentID = std::nullopt);

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

    // Writes a key at the playhead and, like Swift, leaves it the selected
    // key (the port used to return the selection without storing it).
    std::optional<SelectedKeyframe> commitKeyframe(
        Uuid targetID, AnimationTrackProperty property, std::optional<KeyframeValue> value = std::nullopt) {
        const std::optional<SelectedKeyframe> selection = umeshcore::commitKeyframe(
            skeleton, images, sceneAnimationClip, constraintSetupValues, isAnimationEditingEnabled, isPoseMode,
            animationTime, currentFrame, targetID, property, value, lastBoundImageRotation);
        if (selection.has_value()) {
            selectedKeyframes = {*selection};
            selectedKeyframe = selection;
        }
        return selection;
    }
    std::optional<SelectedKeyframe> commitMeshDeformKeyframe(Uuid imageID) {
        return umeshcore::commitMeshDeformKeyframe(
            skeleton, images, sceneAnimationClip, constraintSetupValues, isAnimationEditingEnabled, isPoseMode,
            animationTime, currentFrame, imageID, lastBoundImageRotation);
    }
    // `SceneManager.applyAnimations`: runs the whole per-frame pass and
    // STORES the keyed draw order and attachments it decided, which is what
    // the render order and the hidden set read.
    AnimationFrameResult applyAnimationsNow() {
        AnimationFrameResult result = umeshcore::applyAnimations(
            skeleton, images, sceneAnimationClip, constraintSetupValues, isAnimationEditingEnabled, isPoseMode,
            animationTime, lastBoundImageRotation);
        animatedDrawOrder = result.animatedDrawOrder;
        animatedAttachments = result.animatedAttachments;
        return result;
    }

    // `isAnimationEditingEnabled.didSet`: leaving Animator drops every live
    // mesh deform, so Editor edits the array it draws.
    void setAnimationEditingEnabled(bool enabled);

    // ---- Structure: hierarchy, draw order, deletion (EditorSceneStructure.cpp)

    // A sprite from an asset, as `SceneManager.addImage` makes one. The
    // asset arrives as the three facts this needs (Swift passes a whole
    // `TextureAsset`; convention #2). Returns the new sprite's id.
    Uuid addImage(Uuid assetID, const std::string& assetName, Vec2 assetSize, Vec2 position,
                  std::optional<Uuid> normalMapAssetID);

    std::vector<Uuid> displayHierarchyIDs() const;
    void moveHierarchyItem(Uuid id, int toDisplayIndex);

    // Every current sprite exactly once: the authored order, then sprites
    // imported since, in the order they arrived. Resolved on read so nothing
    // has to keep it in step with imports and deletions.
    std::vector<Uuid> resolvedDrawOrder() const;
    void setAuthoredDrawOrder(std::vector<Uuid> order);
    // Sprites in the order to draw THIS frame, minus what the skin or an
    // attachment key hides.
    std::vector<SceneImage> renderOrderedImages() const;
    // What the Draw Order panel lists: the same as the render order, so the
    // panel agrees with the viewport while animating.
    std::vector<SceneImage> imagesInDrawOrder() const { return renderOrderedImages(); }
    void moveImageInDrawOrder(Uuid imageID, int toDrawIndex);
    void nudgeImageInDrawOrder(Uuid imageID, bool forward);
    void sortDrawOrderByBoneDepth();

    // Move `moved` to where `target` is now, by IDENTITY (an index measured
    // before the removal landed a downward drag one row too far).
    static std::optional<std::vector<Uuid>> movingID(Uuid moved, Uuid before, const std::vector<Uuid>& order);
    static std::optional<std::vector<Uuid>> movingIDToRow(Uuid moved, int row, const std::vector<Uuid>& order);
    static std::optional<Uuid> idAtRow(int row, const std::vector<Uuid>& order);

    void deleteHierarchy(Uuid itemID);
    void deleteHierarchyAt(const std::vector<int>& offsets);
    void duplicateSelected();
    void duplicateItem(Uuid id);
    void reparentBone(Uuid id, std::optional<Uuid> parentID);
    void bindImage(Uuid imageID, std::optional<Uuid> boneID);
    void updateVisibility(Uuid itemID, bool isHidden);
    // Renames the row AND the sprite or bone it names. False when nothing
    // changed, so a blur with no edit pushes no undo.
    bool renameHierarchyItem(Uuid itemID, const std::string& proposed);

    // ---- Draw order keys (EditorSceneStructure.cpp)
    void keyDrawOrder();
    void keyDrawOrder(const std::vector<Uuid>& order);
    void removeDrawOrderKeyAtPlayhead();
    void removeDrawOrderTrack();
    bool hasDrawOrderTrack() const;
    bool drawOrderHasKeyAtPlayhead() const;
    // Drops tracks whose owner is gone and rewrites draw order keys that
    // name deleted sprites, rather than dropping them.
    void pruneSceneAnimationTracks();

    // ---- Skins, slots, attachments (EditorSceneSkins.cpp)
    std::unordered_map<std::string, std::vector<Uuid>> slotMembers() const;
    std::vector<std::string> variantSlotNames() const;
    std::vector<std::string> allSlotNames() const;
    const Skin* activeSkin() const;
    void refreshSkinResolution();
    bool isHiddenByActiveSkin(Uuid imageID) const;
    std::unordered_set<Uuid, UuidHash> attachmentHiddenImageIDs() const;
    std::vector<SceneImage> attachments(const std::string& slotName) const;
    std::optional<Uuid> shownAttachment(const std::string& slotName) const;

    void setSlotName(const std::string& slotName, Uuid imageID);
    void assignSlot(const std::string& slotName, const std::vector<Uuid>& imageIDs);
    void renameSlot(const std::string& oldName, const std::string& newName);

    Uuid createSkin(std::optional<std::string> requestedName, bool activate);
    std::optional<Uuid> duplicateSkin(Uuid id);
    void renameSkin(Uuid id, const std::string& newName);
    void deleteSkin(Uuid id);
    // `activeSkinID.didSet`: the resolution follows the active skin.
    void setActiveSkin(std::optional<Uuid> id);

    void showAttachment(const std::string& slotName, std::optional<Uuid> imageID);
    void keyAttachment(const std::string& slotName, std::optional<Uuid> imageID);
    bool attachmentHasKeyAtPlayhead(const std::string& slotName) const;
    void removeAttachmentKeyAtPlayhead(const std::string& slotName);
    void setSkinAttachment(Uuid skinID, const std::string& slot, std::optional<Uuid> imageID);
    void clearSkinAttachment(Uuid skinID, const std::string& slot);
    void captureCurrentArrangement(Uuid skinID);
    bool addSkinInclusion(Uuid skinID, Uuid includedID);
    void removeSkinInclusion(Uuid skinID, Uuid includedID);
    // Drop skin references to sprites that no longer exist.
    void pruneSkins();

    // ---- Constraints (EditorSceneConstraints.cpp)

    // The IK builder's live draft (nullopt = panel closed) and the bone the
    // pointer is over while it picks.
    std::optional<IKBuilderDraft> ikBuilder;
    std::optional<Uuid> ikBuilderHoveredBoneID;

    // The rig's own physics simulation -- per instance, never shared
    // (ROADMAP risk #2). `isPhysicsPreviewActive` gates stepping it.
    PhysicsConstraintSystem physics;
    bool isPhysicsPreviewActive() const { return physics.isActive; }
    // `isPhysicsPreviewActive.didSet`: switching it off resets the sim.
    void setPhysicsPreviewActive(bool active);
    void resetPhysicsSimulation();
    // A STUB in Swift too (an empty body with a TODO): ported with the same
    // effect, which is none. See EditorSceneConstraints.cpp.
    void bakePhysicsToKeys();

    void beginIKBuilder();
    void cancelIKBuilder();
    IKBuilderValidation ikBuilderValidation() const;
    // True when the click was consumed by the builder's pick mode.
    bool ikBuilderHandleBonePick(Uuid boneID);
    void ikBuilderSetPicking(std::optional<IKBuilderSlot> slot);
    void ikBuilderSetChain(const std::vector<Uuid>& chain);
    void ikBuilderSetTarget(std::optional<Uuid> boneID);
    void ikBuilderSetName(const std::string& name);
    void ikBuilderSetBendPositive(bool value);
    void ikBuilderSetMix(float value);
    std::optional<Uuid> commitIKBuilder();

    std::optional<Uuid> createPathConstraintFromSelection();
    std::optional<Uuid> createTransformConstraintFromSelection();
    std::optional<Uuid> createPhysicsConstraintFromSelection(PhysicsType type, PhysicsPreset preset);

    void renameIKConstraint(Uuid id, const std::string& newName);
    void deleteIKConstraint(Uuid id);
    std::optional<Uuid> duplicateIKConstraint(Uuid id);
    void moveIKConstraint(const std::vector<int>& fromOffsets, int toOffset);
    void setIKTarget(Uuid constraintID, Uuid boneID);
    void addBoneToIKChain(Uuid boneID, Uuid constraintID);
    void removeBoneFromIKChain(Uuid boneID, Uuid constraintID);
    void setIKChainFromSelection(Uuid constraintID);
    // `updateIKConstraint(id) { ... }`: a Swift closure cannot cross, so the
    // shell reads the constraint, edits its copy and hands it back. Same
    // effect: one undo step, then re-animate. Matched by id.
    void replaceIKConstraint(const IKConstraint& updated);

    void renameTransformConstraint(Uuid id, const std::string& newName);
    void deleteTransformConstraint(Uuid id);
    std::optional<Uuid> duplicateTransformConstraint(Uuid id);
    void moveTransformConstraint(const std::vector<int>& fromOffsets, int toOffset);
    void addAffectedBone(Uuid boneID, Uuid constraintID);
    void removeAffectedBone(Uuid boneID, Uuid constraintID);
    void setTransformConstraintTarget(Uuid constraintID, Uuid boneID);

    void renamePathConstraint(Uuid id, const std::string& newName);
    void deletePathConstraint(Uuid id);
    std::optional<Uuid> duplicatePathConstraint(Uuid id);
    void addFollowerToPath(Uuid boneID, Uuid constraintID);
    void removeFollowerFromPath(Uuid boneID, Uuid constraintID);
    void setPathControlBonesFromSelection(Uuid constraintID);

    void renamePhysicsConstraint(Uuid id, const std::string& newName);
    void deletePhysicsConstraint(Uuid id);
    std::optional<Uuid> duplicatePhysicsConstraint(Uuid id);
    void setPhysicsChainFromSelection(Uuid constraintID);

    void setConstraintEnabled(Uuid id, bool enabled);
    void deleteConstraint(Uuid id);
    std::optional<Uuid> duplicateConstraint(Uuid id);
    void renameConstraint(Uuid id, const std::string& newName);
    // Every bone except the ones this constraint already drives.
    std::vector<Bone> targetCandidates(const std::vector<Uuid>& excludingDriven) const;

    // ---- Constraint animation (EditorSceneConstraints.cpp)
    void ensureConstraintSetupCaptured(Uuid constraintID);
    void updateConstraintSetupValue(Uuid constraintID, AnimationTrackProperty property);
    bool isConstraintPropertyAnimated(Uuid constraintID, AnimationTrackProperty property) const;
    bool constraintPropertyHasKeyAtPlayhead(Uuid constraintID, AnimationTrackProperty property) const;
    void restoreAllConstraintSetupValues();
    void replaceSceneAnimation(const AnimationClip& clip,
                               const std::unordered_map<Uuid, ConstraintSetupValues, UuidHash>& values);
    bool hasAnyConstraintTrack(Uuid constraintID) const;
    void removeAllConstraintTracks(Uuid constraintID);
    float constraintScalarValue(Uuid constraintID, AnimationTrackProperty property) const;
    bool constraintFlagValue(Uuid constraintID, AnimationTrackProperty property) const;
    Vec2 constraintVectorValue(Uuid constraintID, AnimationTrackProperty property) const;
    // The single entry point for a constraint edit: auto-keys in Animator,
    // rewrites the authored value (and its setup record, if animated) in
    // Editor. `pushUndo` is Swift's default-true parameter, spelled out.
    void setConstraintScalar(Uuid constraintID, AnimationTrackProperty property, float value, bool pushUndo);
    void setConstraintFlag(Uuid constraintID, AnimationTrackProperty property, bool value, bool pushUndo);
    void setConstraintVector(Uuid constraintID, AnimationTrackProperty property, Vec2 value, bool pushUndo);
    void keyConstraintProperty(Uuid constraintID, AnimationTrackProperty property);
    void removeConstraintKeyAtPlayhead(Uuid constraintID, AnimationTrackProperty property);
    void removeConstraintPropertyTrack(Uuid constraintID, AnimationTrackProperty property);
    void restoreConstraintSetupValue(Uuid constraintID, AnimationTrackProperty property);

    // ---- Transport (EditorSceneAnimation.cpp)
    //
    // THE CLOCK IS INJECTED, as in `Scene/ScenePlayback.h`: every entry that
    // needs "now" takes it, in the shell's monotonic seconds (Swift:
    // `CACurrentMediaTime()`). The playhead is a pure function of that time,
    // so nothing accumulates and a dropped frame costs one sample, never a
    // step. The one thing Swift does with a timer -- stopping a clip that
    // does not loop even when nothing is drawing -- is returned instead:
    // `play` / `togglePlayback` / `setProjectFramesPerSecond` give the
    // seconds until that wake, and the shell calls `tickPlayback` then.

    bool isPlaying = false;
    bool playbackLoops = true;
    double projectFramesPerSecond = 30.0;
    // Where the playhead line is, to a fraction of a frame (Swift's
    // `PlayheadClock.frame`, its own object there so a tick redraws a line
    // and not the timeline). The shell mirrors it into that object.
    double playheadFrame = 0.0;

    struct PlaybackRun {
        int startFrame = 0;
        double startTime = 0.0;
        double framesPerSecond = 30.0;
        int minFrame = 0;
        int maxFrame = 0;
    };
    std::optional<PlaybackRun> playbackSession;

    void setCurrentFrame(int frame);
    void setAnimationTime(double time);
    void setPlaybackRange(int start, int end);
    void stepFrames(int delta, std::optional<int> lowerBound, std::optional<int> upperBound);
    std::optional<double> play(double now, std::optional<bool> looping, std::optional<int> lowerBound,
                               std::optional<int> upperBound, std::optional<double> framesPerSecond);
    void tickPlayback(double now);
    void pause();
    std::optional<double> togglePlayback(double now, std::optional<bool> looping, std::optional<int> lowerBound,
                                         std::optional<int> upperBound);
    // `projectFramesPerSecond.didSet`: clamped to 1..240, and a running
    // session restarts at the new rate.
    std::optional<double> setProjectFramesPerSecond(double fps, double now);
    double secondsPerFrame() const { return 1.0 / std::max(projectFramesPerSecond, 1.0); }
    double timecode(int frame) const { return static_cast<double>(frame) * secondsPerFrame(); }

    // ---- Canvas modes (EditorSceneAnimation.cpp)
    //
    // The tool in hand, mirrored from ToolManager so the key button knows
    // what to write, and the sprite modes a tool change leaves.
    ActiveTool activeCanvasTool = ActiveTool::Select;
    bool isMeshEditEnabled = false;
    bool meshWeightPaintEnabled = false;
    bool isBindingBonesMode = false;
    std::optional<Uuid> activeWeightPaintBoneID;
    // A canvas mode asked for before a sprite was selected (the raw value
    // of the shell's `CanvasMode`), entered when one is picked.
    std::optional<std::string> pendingCanvasMode;
    // `ToolManager.setTool` and the quick switch both land here.
    void canvasToolChanged(ActiveTool tool);

    // Mesh edit and weight paint differ in what they do to a mesh and agree
    // on needing one.
    bool isSpriteMeshMode() const { return isMeshEditEnabled || meshWeightPaintEnabled; }
    // Being in a mesh mode is what means "show me the mesh"; the layer flag
    // alone is cleared by every selection path the modes survive.
    bool isMeshOverlayVisible() const { return isMeshEditEnabled || isMeshLayerSelected || meshWeightPaintEnabled; }
    // `isBindingBonesMode.didSet`: leaving bind mode drops its hover.
    void setBindingBonesMode(bool enabled) {
        isBindingBonesMode = enabled;
        if (!enabled) hoveredBindBoneID = std::nullopt;
    }

    // What a mesh operation says about itself (Swift's `MeshEditNotice`).
    // Model-side because the operations that set it are ported here; the
    // shell only shows it and clears it.
    struct MeshEditNotice {
        std::string text;
        bool isWarning = false;
        bool operator==(const MeshEditNotice&) const = default;
    };
    std::optional<MeshEditNotice> meshEditNotice;

    // Swift's `leaveSpriteModes` ends with `toolManager?.setTool(.select)`
    // when the mesh tool is in hand. This object cannot reach a tool manager
    // (and must not: the dependency points the other way), so it RAISES the
    // request and the shell -- which owns the ToolManager -- performs it and
    // clears this. Same effect, one hop later.
    std::optional<ActiveTool> requestedToolChange;

    // ---- The way out (EditorSceneAnimation.cpp)
    //
    // The facts the escape ladder reads; the ORDER lives in `EditorEscape`.
    EditorEscape::State escapeState() const;
    // Leave one rung and return it. `hasNonDefaultTool` is the one fact this
    // object does not hold, and the `ActiveTool` rung is the caller's to
    // apply.
    std::optional<EditorScope> exitDeepestScope(bool hasNonDefaultTool);

    // ---- Keyframes (EditorSceneAnimation.cpp)

    enum class TransformKeyState { None, Partial, Full };
    struct KeyframeStart {
        SelectedKeyframe key;
        int frame = 0;
    };

    std::vector<CopiedKeyframePayload> copiedKeyframes;

    // Every track except a bone's or a sprite's own lives on the scene clip.
    static bool isSceneOwnedTrack(AnimationTrackProperty property) {
        return domain(property) != AnimationTrackDomain::Node;
    }
    // Non-const: reading a sprite's keys first settles its animation space,
    // as Swift's does.
    std::vector<Keyframe> keyframes(Uuid targetID, AnimationTrackProperty property);

    static std::vector<AnimationTrackProperty> transformKeyProperties(ActiveTool tool);
    std::vector<AnimationTrackProperty> activeTransformKeyProperties() const {
        return transformKeyProperties(activeCanvasTool);
    }
    std::vector<Uuid> transformKeyTargets() const;
    TransformKeyState transformKeyState() const;
    bool toggleTransformKey();

    void selectKeyframe(Uuid targetID, AnimationTrackProperty property, Uuid keyframeID, bool additive);
    void moveKeyframe(Uuid targetID, AnimationTrackProperty property, Uuid keyframeID, int toFrame);
    void updateKeyframeValue(Uuid targetID, AnimationTrackProperty property, Uuid keyframeID,
                             const KeyframeValue& value);
    // The same, in the form Swift can pass (no variant in the signature).
    void updateKeyframeValue(Uuid targetID, AnimationTrackProperty property, Uuid keyframeID,
                             const FlatKeyframeValue& value);
    void updateKeyframeTangents(Uuid targetID, AnimationTrackProperty property, Uuid keyframeID,
                                std::optional<Vec2> inTangent, std::optional<Vec2> outTangent,
                                std::optional<Vec2> secondaryInTangent, std::optional<Vec2> secondaryOutTangent);
    void moveSelectedKeyframes(const SelectedKeyframe& anchor, int deltaFrames,
                               const std::vector<KeyframeStart>& startFrames);
    std::optional<KeyframeInterpolation> selectedKeyframeInterpolation() const;
    void setInterpolationForSelectedKeyframes(KeyframeInterpolation interpolation);
    void applyAutoTangentsToSelectedKeyframes();
    void deleteSelectedKeyframes();
    bool isKeyframeSelected(const SelectedKeyframe& selection) const;
    void setSelectedKeyframes(const std::vector<SelectedKeyframe>& selections, bool additive);
    // Fills `copiedKeyframes` and returns how many were copied. Swift also
    // wraps a summary in an `NSItemProvider`; that is the shell's to build
    // (the text is "UltraMeshKeyframes:<count>").
    int copySelectedKeyframes();
    void pasteCopiedKeyframes();
    void duplicateSelectedKeyframes();

    // ---- Events (EditorSceneAnimation.cpp)
    std::vector<FiredAnimationEvent> recentlyFiredEvents;

    std::optional<AnimationEvent> animationEvent(Uuid id) const;
    std::vector<Uuid> keyedEventIDs() const;
    Uuid createAnimationEvent(std::optional<std::string> requestedName);
    void renameAnimationEvent(Uuid id, const std::string& newName);
    // `updateAnimationEvent(id) { ... }` -- see `replaceIKConstraint`.
    void replaceAnimationEvent(const AnimationEvent& updated);
    void deleteAnimationEvent(Uuid id);
    void keyEvent(Uuid eventID, const AnimationEventPayload& payload);
    bool eventHasKeyAtPlayhead(Uuid eventID) const;
    void removeEventKeyAtPlayhead(Uuid eventID);
    std::optional<AnimationEventPayload> eventPayloadAtPlayhead(Uuid eventID) const;
    void setEventPayloadAtPlayhead(Uuid eventID, const AnimationEventPayload& payload);
    void fireEventsCrossed(int from, int to);
    void clearFiredEvents() { recentlyFiredEvents.clear(); }

private:
    bool interactionPushed_ = false;

    SceneSnapshot currentSnapshot() const {
        SceneSnapshot s;
        s.images = images;
        s.skeleton = skeleton;
        s.sceneAnimationClip = sceneAnimationClip;
        s.constraintSetupValues = constraintSetupValues;
        s.skins = skins;
        s.activeSkinID = activeSkinID;
        s.animationEvents = animationEvents;
        return s;
    }
    void applySnapshot(const SceneSnapshot& s);

    void normalizeOrder();
    void syncImagesToHierarchy();
    void removeBones(const std::vector<Uuid>& ids);
    void rebuildHierarchyFromState();
    std::string uniqueHierarchyName(const std::string& proposed, Uuid excluding) const;
    std::string uniqueSkinName(const std::string& requested, std::optional<Uuid> excluding) const;
    bool skinChainContains(Uuid start, Uuid target) const;
    std::unordered_map<std::string, std::optional<Uuid>> setupAttachments() const;
    void selectKeyframeAt(Uuid targetID, AnimationTrackProperty property, int frame);

    int playbackLowerBound(std::optional<int> fallback) const;
    int playbackUpperBound(std::optional<int> fallback, std::optional<int> minimum) const;
    std::optional<double> scheduledEndWake() const;
    std::vector<Keyframe> transformKeyframes(Uuid targetID, AnimationTrackProperty property) const;
    int keyedTransformCount(Uuid targetID, int frame) const;
    void writeTransformKey(Uuid targetID, int frame);
    void removeTransformKey(Uuid targetID, int frame);
    void insertSelectedKeyframe(const SelectedKeyframe& selection);
    std::optional<Keyframe> resolveSelectedKeyframe(const SelectedKeyframe& selection) const;
    std::string uniqueEventName(const std::string& requested, std::optional<Uuid> excluding) const;
    void collectEvents(int lower, int upper, std::vector<FiredAnimationEvent>& fired) const;

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
    // the selection, and the modes that act on a sprite's mesh have nothing
    // left to act on.
    void boneSelectionBecameNonEmpty() {
        selectedImageID = std::nullopt;
        selectedImageIDs.clear();
        isMeshLayerSelected = false;
        hoveredMeshVertexIndex = std::nullopt;
        selectedMeshVertexIndices.clear();
        selectedMeshInternalEdgeIndex = std::nullopt;
        leaveSpriteModes();
    }

    // Ends the sprite modes because the sprite is gone. Changing WHICH sprite
    // is painted deliberately does not come through here.
    void leaveSpriteModes() {
        if (!(isSpriteMeshMode() || isBindingBonesMode || pendingCanvasMode.has_value())) return;
        meshWeightPaintEnabled = false;
        isMeshEditEnabled = false;
        setBindingBonesMode(false);
        activeWeightPaintBoneID = std::nullopt;
        pendingCanvasMode = std::nullopt;
        meshEditNotice = std::nullopt;
        if (activeCanvasTool == ActiveTool::Mesh) requestedToolChange = ActiveTool::Select;
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
