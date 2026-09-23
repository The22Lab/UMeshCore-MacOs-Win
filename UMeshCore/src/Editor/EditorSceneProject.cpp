// EditorScene -- opening a project: `SceneManager.restoreProject`, the one
// body behind "open" and "new project".
//
// Three differences from the Swift body, each a fix of something the Swift
// source itself says should hold:
//
//  1. UNDO HISTORY IS CLEARED. Swift's `SceneManager` is a `let` on
//     `AppState` that lives for the whole app, and neither
//     `restoreProject` nor `AppState.restore` touches its
//     `undoRedoManager` (grep: its only uses are push/undo/redo). So after
//     opening project B, Undo substituted project A's sprites and bones
//     back in -- sprites whose textures are no longer in the asset store.
//     History belongs to the project it was recorded in.
//  2. `pruneSceneSelection` runs, which is where its own comment says it
//     runs ("opening a project, undo") and where Swift never calls it.
//  3. The bone selection is cleared through `applyBoneSelection`, the
//     "one place the three bone-selection fields are written". Swift
//     writes `selectedBoneID = nil` directly and leaves the old project's
//     ids in `selectedBoneIDs` and `boneSelectionOrder`.
//
// Kept as Swift: the final `setCurrentFrame` fires the new project's event
// keys between the OLD playhead and the restored one into the (just
// cleared) readout -- open a project saved on frame 40 from frame 0 and
// its events 1...40 are listed. Harmless, and the readout is the shell's
// to clear. Also kept: the IK builder draft, the physics simulation and the
// canvas modes are not reset here -- the shell resets the modes (Swift's
// `AppState.restore` re-selects the tool, which runs `canvasToolChanged`).

#include "umeshcore/Editor/EditorScene.h"

#include <algorithm>

namespace umeshcore {

void EditorScene::restoreProject(const RestoredProject& p) {
    pause();
    sceneCompositions = p.sceneCompositions;
    selectedSceneCompositionID = p.selectedSceneCompositionID;
    sceneViewCamera = p.sceneViewCamera.value_or(SceneViewCamera{});
    authoredDrawOrder = p.authoredDrawOrder;
    skins = p.skins;
    activeSkinID = p.activeSkinID;
    animationEvents = p.animationEvents;
    recentlyFiredEvents.clear();
    // Paused just above, so the rate's didSet has no session to restart.
    projectFramesPerSecond = std::min(std::max(p.projectFramesPerSecond, 1.0), 240.0);
    images = p.images;
    skeleton = p.skeleton;
    sceneAnimationClip = p.sceneAnimationClip;
    constraintSetupValues = p.constraintSetupValues;
    animatedDrawOrder = std::nullopt;
    hierarchyItems = p.hierarchyItems;
    playbackLoops = p.playbackLoops;
    selectedImageID = p.selectedImageID;
    selectedImageIDs = std::unordered_set<Uuid, UuidHash>(p.selectedImageIDs.begin(), p.selectedImageIDs.end());
    selectedKeyframe = p.selectedKeyframe;
    selectedKeyframes.clear();
    for (const SelectedKeyframe& k : p.selectedKeyframes) insertSelectedKeyframe(k);
    selectedMeshVertexIndices.clear();
    selectedMeshInternalEdgeIndex = std::nullopt;
    applyBoneSelection({});
    boneCreationPreviewStart = std::nullopt;
    boneCreationPreviewEnd = std::nullopt;
    copiedKeyframes.clear();
    previewPositions.clear();

    undoRedo = UndoRedoManager();
    interactionPushed_ = false;
    pruneSceneSelection();

    setPlaybackRange(p.playbackStartFrame, p.playbackEndFrame);
    pruneSkins();
    refreshSkinResolution();
    setCurrentFrame(p.currentFrame);
}

} // namespace umeshcore
