#pragma once

// 1:1 port of `Core/EditorEscape.swift`.
//
// One way out, peeling one layer at a time. Everything the artist can be
// inside is ordered from most transient to most settled; one call leaves
// exactly one rung. The order is a total order on purpose: two things at
// the same depth would make behavior depend on which check ran first.

#include <optional>

namespace umeshcore {

enum class EditorScope {
    IkBuilderPick,        // The IK builder is waiting for a bone to be tapped.
    IkBuilderDraft,        // The IK builder is open but not waiting on anything.
    MeshVertexSelection,    // Vertices are selected inside a mesh edit.
    WeightPaint,             // Weight paint is on, inside a mesh edit.
    MeshEdit,                 // A mesh is being edited.
    BindBones,                 // Bind mode is picking a bone for the selected sprite.
    BoneSelection,               // One or more bones are selected.
    ImageSelection,               // One or more sprites, or a constraint, are selected.
    ActiveTool,                    // A tool other than Select is active.
};

// Ordering matches declaration order (EditorScope's Swift rawValue order),
// used by nothing directly here but documented since it IS the design.
inline bool operator<(EditorScope a, EditorScope b) {
    return static_cast<int>(a) < static_cast<int>(b);
}

namespace EditorEscape {

// Everything the ladder reads, and nothing else.
struct State {
    bool isPickingIKBone = false;
    bool hasIKDraft = false;
    int selectedMeshVertexCount = 0;
    bool isWeightPainting = false;
    bool isMeshEditing = false;
    bool isBindingBones = false;
    int selectedBoneCount = 0;
    int selectedImageCount = 0;
    bool hasSelectedConstraint = false;
    // False when the active tool is Select.
    bool hasNonDefaultTool = false;

    bool operator==(const State&) const = default;
};

// The innermost rung the artist is standing on, or nullopt when out.
inline std::optional<EditorScope> deepest(const State& state) {
    if (state.isPickingIKBone) return EditorScope::IkBuilderPick;
    if (state.hasIKDraft) return EditorScope::IkBuilderDraft;
    // Only meaningful inside a mesh edit: vertices cannot be selected
    // outside one, and reading the count alone would strand the ladder on
    // a rung that no call can clear.
    if (state.isMeshEditing && state.selectedMeshVertexCount > 0) {
        return EditorScope::MeshVertexSelection;
    }
    if (state.isWeightPainting) return EditorScope::WeightPaint;
    if (state.isMeshEditing) return EditorScope::MeshEdit;
    if (state.isBindingBones) return EditorScope::BindBones;
    if (state.selectedBoneCount > 0) return EditorScope::BoneSelection;
    if (state.selectedImageCount > 0 || state.hasSelectedConstraint) return EditorScope::ImageSelection;
    if (state.hasNonDefaultTool) return EditorScope::ActiveTool;
    return std::nullopt;
}

// The state after leaving one rung. Modelled here as well as applied for
// real, so "a call always descends and never climbs" is checkable without
// a running editor.
inline State leaving(EditorScope scope, const State& state) {
    State next = state;
    switch (scope) {
        case EditorScope::IkBuilderPick:
            next.isPickingIKBone = false;
            break;
        case EditorScope::IkBuilderDraft:
            next.hasIKDraft = false;
            break;
        case EditorScope::MeshVertexSelection:
            next.selectedMeshVertexCount = 0;
            break;
        case EditorScope::WeightPaint:
            next.isWeightPainting = false;
            break;
        case EditorScope::MeshEdit:
            // Leaving the mesh takes what lives inside it, or the next
            // call would find a vertex selection belonging to an edit
            // that is over.
            next.isMeshEditing = false;
            next.selectedMeshVertexCount = 0;
            next.isWeightPainting = false;
            break;
        case EditorScope::BindBones:
            next.isBindingBones = false;
            break;
        case EditorScope::BoneSelection:
            next.selectedBoneCount = 0;
            break;
        case EditorScope::ImageSelection:
            next.selectedImageCount = 0;
            next.hasSelectedConstraint = false;
            break;
        case EditorScope::ActiveTool:
            next.hasNonDefaultTool = false;
            break;
    }
    return next;
}

} // namespace EditorEscape
} // namespace umeshcore
