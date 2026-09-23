#pragma once

// Port of `Core/Tools/MeshTool.swift` -- the Mesh tool: every Mesh-mode
// gesture on the canvas. In order of precedence on a press:
//
//   Bind Mode    a click on a bone binds it to the selected sprite, or
//                unbinds it if it already was;
//   choosing     a click that CHANGED the selected sprite is spent on
//                choosing it (it used to also drop a node where it landed);
//   tracing      while an outline is being traced, a click adds its next
//                point, and clicking near the first point closes it;
//   Weights      the brush owns the click: a double click on a bound bone
//                arms it (taking back the stamp the first click laid down),
//                with no bone armed a click picks the node the brush will be
//                restricted to, otherwise it paints;
//   Delete       a click on a node deletes it;
//   Create       a press starts an edge; a release without a drag places a
//                node (on the hull edge it landed on, or inside), a drag
//                joins its two ends;
//   Modify       a press on a node grabs it (Shift extends), with soft
//                selection when enabled; a click on nothing clears.
//
// The texture side arrives through `assets` (an `AssetAlphaStore`), which
// `ToolManager` sets while it dispatches an event from its store-taking
// overloads. Without it the tool can learn no sprite's size, and it does
// what Swift does when `assets.asset(for:)` fails: nothing.
//
// Not ported: `makeAlphaSampler` -- Swift decodes the PNG on every Create
// release only to hand the sampler to two scene methods whose bodies discard
// it (`_ = alphaSampler`). Nothing reads it, so nothing is decoded.

#include <optional>
#include <unordered_map>
#include <vector>

#include "umeshcore/Editor/AssetAlphaStore.h"
#include "umeshcore/Editor/Tool.h"

namespace umeshcore {

class MeshTool final : public Tool {
public:
    ActiveTool type() const override { return ActiveTool::Mesh; }

    void onMouseDown(const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
                     bool touchOptimized) override;
    void onMouseDrag(const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
                     bool touchOptimized) override;
    void onMouseUp(const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
                   bool touchOptimized) override;

    // Abandon a half-drawn edge, keeping everything already made (the
    // canvas prompt's Cancel).
    void cancelPendingCreateEdge(EditorScene& scene);

    // Set by `ToolManager` for the duration of one dispatched event.
    const AssetAlphaStore* assets = nullptr;

    // How far outside the hull (screen points) a Create click may land and
    // still be pulled onto the edge; how far a Create press must travel to
    // be an EDGE rather than a node (a Pencil tap always wanders more than
    // one pixel, and read every tap as a two-node edge).
    static float createClampReachPx(float hitScale) { return 12.0f * hitScale; }
    static float createDragThresholdPx(float hitScale) { return 6.0f * hitScale; }

private:
    std::optional<Uuid> activeImageID_;
    std::vector<int> activeVertexIndices_;
    Vec2 dragStartLocalPosition_ = Vec2::zero();
    std::unordered_map<int, Vec2> dragStartVertexPositions_;
    std::unordered_map<int, Vec2> dragStartVertexUVs_;
    std::unordered_map<int, float> dragInfluenceWeights_;
    bool pendingEmptyClick_ = false;
    // Where the brush last stamped, so a drag paints the segment since then.
    std::optional<Vec2> lastPaintWorld_;
    // The weights just before a stamp that landed on a bound bone, so the
    // double click that arms that bone can take the stamp back.
    struct TakenWeights {
        Uuid imageID;
        std::vector<std::vector<VertexBoneWeight>> weights;
    };
    std::optional<TakenWeights> weightsBeforePaintClick_;
    std::optional<Uuid> createEdgeStartImageID_;
    std::optional<int> createEdgeStartVertexIndex_;
    std::optional<Vec2> createEdgeStartLocalPosition_;
    bool createEdgeDidDrag_ = false;

    void resetDragState(EditorScene& scene);
    void beginVertexDrag(const SceneImage& image, Uuid selectedID, const std::vector<int>& selectedVertices,
                         Vec2 localPosition, const EditorScene& scene, Vec2 assetSize);
    const AssetAlpha* assetFor(const SceneImage& image) const;
};

} // namespace umeshcore
