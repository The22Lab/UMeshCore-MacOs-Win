#include "umeshcore/Editor/Tools/MeshTool.h"

#include <algorithm>
#include <cfloat>

#include "umeshcore/Editor/CanvasImagePicking.h"
#include "umeshcore/Editor/ToolUtilities.h"
#include "umeshcore/Math/MatrixUtilities.h"

namespace umeshcore {

namespace {

constexpr float kPiF = 3.14159265358979323846f;

Vec2 localToWorld(const Vec2& local, const SceneImage& image) {
    return MatrixUtilities::shearedWorldTransform(local, image.position, image.rotation * 180.0f / kPiF, image.skew,
                                                  image.scale);
}

// MeshTool's own point-in-polygon: note the `+ 0.000001` in the
// denominator, which the mesh's own test does not have. Kept as Swift.
bool pointInsidePolygon(const Vec2& point, const std::vector<Vec2>& polygon) {
    if (polygon.size() < 3) return false;
    bool inside = false;
    Vec2 previous = polygon.back();
    for (const Vec2& current : polygon) {
        const bool intersects =
            ((current.y > point.y) != (previous.y > point.y)) &&
            (point.x < (previous.x - current.x) * (point.y - current.y) / ((previous.y - current.y) + 0.000001f) +
                           current.x);
        if (intersects) inside = !inside;
        previous = current;
    }
    return inside;
}

Vec2 closestPointOnSegment(const Vec2& point, const Vec2& a, const Vec2& b) {
    const Vec2 ab = b - a;
    const float lengthSquared = dot(ab, ab);
    if (!(lengthSquared > 0.000001f)) return a;
    const float t = std::max(0.0f, std::min(1.0f, dot(point - a, ab) / lengthSquared));
    return a + ab * t;
}

// A click just outside the hull lands on its edge, so a node can be placed
// on the boundary without pixel aim.
Vec2 clampedToMeshInterior(const Vec2& localPoint, const SceneImage& image, const Vec2& assetSize) {
    const Mesh mesh = ToolUtilities::resolvedMesh(image, assetSize);
    std::vector<Vec2> polygon;
    for (std::uint16_t index : mesh.hullVertexIndices) {
        if (index < mesh.vertices.size()) polygon.push_back(mesh.vertices[index]);
    }
    if (mesh.hullVertexIndices.size() < 3 || polygon.size() < 3) return localPoint;
    if (pointInsidePolygon(localPoint, polygon)) return localPoint;
    Vec2 best = polygon.front();
    float bestDistance = FLT_MAX;
    for (std::size_t i = 0; i < polygon.size(); ++i) {
        const Vec2 projected = closestPointOnSegment(localPoint, polygon[i], polygon[(i + 1) % polygon.size()]);
        const float d = length(localPoint - projected);
        if (d < bestDistance) {
            bestDistance = d;
            best = projected;
        }
    }
    return best;
}

std::unordered_set<Uuid, UuidHash> asSet(const std::vector<Uuid>& ids) {
    return std::unordered_set<Uuid, UuidHash>(ids.begin(), ids.end());
}

} // namespace

const AssetAlpha* MeshTool::assetFor(const SceneImage& image) const {
    return assets != nullptr ? assets->find(image.assetID) : nullptr;
}

void MeshTool::onMouseDown(const ToolInput& input, EditorScene& scene, const ImageHitTestFn&, float hitScale,
                           bool touchOptimized) {
    scene.beginInteraction();
    const auto boneUnderPointer = [&] {
        return ToolUtilities::hitTestBone(input.screenPosition, input.viewSize, scene.skeleton, scene.selectedBoneID,
                                          input.camera, touchOptimized);
    };

    if (scene.isBindingBonesMode) {
        if (!scene.selectedImageID.has_value()) return;
        const Uuid imageID = *scene.selectedImageID;
        const SceneImage* image = scene.image(imageID);
        const AssetAlpha* asset = image != nullptr ? assetFor(*image) : nullptr;
        if (asset == nullptr) return;
        if (const auto boneID = boneUnderPointer()) {
            if (asSet(scene.boundBoneIDs(imageID)).contains(*boneID)) {
                scene.unbindBoneFromImage(imageID, *boneID, scene.meshWeightMaxInfluencesPerVertex);
                if (scene.activeWeightPaintBoneID == boneID) scene.activeWeightPaintBoneID = std::nullopt;
            } else {
                scene.bindBoneToImage(imageID, *boneID, asset->size, scene.meshWeightMaxInfluencesPerVertex);
            }
        }
        return;
    }

    // Weight painting needs a mesh to paint, not permission to move it.
    if (!(scene.isMeshEditEnabled || scene.meshWeightPaintEnabled || scene.isAnimationEditingEnabled)) return;

    // Never while painting (the brush never picks the sprite), and a single
    // click never switches once something is selected: a click here is an
    // edit, whose node lands on whatever sprite is drawn where it belongs.
    const std::optional<Uuid> selectedBeforeThisTool = scene.selectedImageID;
    if (!scene.isWeightPaintStroke() && assets != nullptr) {
        if (const auto hit = CanvasImagePicking::hitTestScreen(input.screenPosition, input.viewSize, scene, *assets,
                                                               input.camera, hitScale);
            hit.has_value() &&
            ToolUtilities::meshModeMayChangeSelection(*hit, scene.selectedImageID, input.clickCount)) {
            scene.selectMeshLayer(*hit);
        }
    }

    // A CLICK THAT CHOOSES THE SPRITE IS SPENT ON CHOOSING IT.
    if (input.didChangeSelection || scene.selectedImageID != selectedBeforeThisTool) {
        pendingEmptyClick_ = false;
        resetDragState(scene);
        return;
    }

    const SceneImage* imagePtr = scene.selectedImageID.has_value() ? scene.image(*scene.selectedImageID) : nullptr;
    const AssetAlpha* asset = imagePtr != nullptr ? assetFor(*imagePtr) : nullptr;
    if (asset == nullptr) {
        pendingEmptyClick_ = false;
        scene.selectMeshVertices({});
        resetDragState(scene);
        return;
    }
    const Uuid selectedID = *scene.selectedImageID;
    const SceneImage image = *imagePtr; // a copy: the scene mutates below

    if (scene.isMeshCreatingHull && !scene.isAnimationEditingEnabled) {
        pendingEmptyClick_ = false;
        const Vec2 local = ToolUtilities::localCoordinates(input.position, image);
        if (!image.mesh.hullVertexIndices.empty()) {
            const std::size_t first = image.mesh.hullVertexIndices.front();
            if (first < image.mesh.vertices.size() &&
                length(local - image.mesh.vertices[first]) <= 12.0f / std::max(image.scale.x, 0.001f) &&
                image.mesh.hullVertexIndices.size() >= 3) {
                scene.finishNewMesh();
                resetDragState(scene);
                return;
            }
        }
        scene.appendMeshHullVertex(selectedID, local, asset->size);
        return;
    }

    const auto projection =
        CanvasImagePicking::selectedMeshProjection(scene, *assets, input.camera, input.viewSize, hitScale);
    const auto vertexUnderPointer = [&]() -> std::optional<int> {
        return projection.has_value() ? ToolUtilities::hitTestMeshVertex(input.screenPosition, *projection)
                                      : std::nullopt;
    };

    // WEIGHTS OWNS THE CLICK, WITH OR WITHOUT A COLOUR.
    if (scene.meshWeightPaintEnabled) {
        pendingEmptyClick_ = false;
        const auto boundIDs = asSet(scene.boundBoneIDs(selectedID));
        const auto boneHit = boneUnderPointer();
        // The canvas is a colour picker too: a bone this sprite is bound to,
        // double-clicked once one is armed, single-clicked when none is.
        if (boneHit.has_value() && ToolUtilities::weightPaintMayChangeBone(*boneHit, scene.activeWeightPaintBoneID,
                                                                           boundIDs, input.clickCount)) {
            if (weightsBeforePaintClick_.has_value() && weightsBeforePaintClick_->imageID == selectedID) {
                scene.restoreMeshWeights(weightsBeforePaintClick_->imageID, weightsBeforePaintClick_->weights);
            }
            weightsBeforePaintClick_ = std::nullopt;
            scene.activeWeightPaintBoneID = boneHit;
            lastPaintWorld_ = std::nullopt;
            resetDragState(scene);
            return;
        }
        // With no colour chosen the brush is a pointer: a click picks the
        // node the brush will then be restricted to.
        if (!scene.activeWeightPaintBoneID.has_value()) {
            weightsBeforePaintClick_ = std::nullopt;
            if (const auto hit = vertexUnderPointer()) {
                scene.selectMeshVertices({*hit});
            } else {
                scene.selectMeshVertices({});
            }
            resetDragState(scene);
            return;
        }
        // Kept only when the stamp lands on a bone a second click could arm.
        if (boneHit.has_value() && boundIDs.contains(*boneHit)) {
            weightsBeforePaintClick_ = TakenWeights{selectedID, image.mesh.vertexBoneWeights};
        } else {
            weightsBeforePaintClick_ = std::nullopt;
        }
        lastPaintWorld_ = input.position;
        scene.paintSelectedMeshWeights(input.position, asset->size);
        return;
    }

    const std::optional<int> hitVertexIndex = vertexUnderPointer();
    switch (scene.meshEditToolMode) {
        case EditorScene::MeshEditToolMode::Delete:
            if (scene.isAnimationEditingEnabled) break;
            pendingEmptyClick_ = false;
            if (hitVertexIndex.has_value()) {
                scene.selectMeshVertices({*hitVertexIndex});
                scene.deleteSelectedMeshVertices();
                resetDragState(scene);
            }
            return;
        case EditorScene::MeshEditToolMode::Create: {
            if (scene.isAnimationEditingEnabled) break;
            pendingEmptyClick_ = false;
            const Vec2 local = ToolUtilities::localCoordinates(input.position, image);
            const Vec2 clampedStart = clampedToMeshInterior(local, image, asset->size);
            // The clamp is for a click just OUTSIDE the hull, not for the
            // first click of a double click on another sprite far away.
            if (input.camera != nullptr) {
                const Vec2 clampedScreen =
                    input.camera->worldToScreen(localToWorld(clampedStart, image), input.viewSize);
                if (length(clampedScreen - input.screenPosition) > createClampReachPx(hitScale)) {
                    resetDragState(scene);
                    return;
                }
            }
            scene.selectMeshInternalEdge(std::nullopt);
            createEdgeStartImageID_ = selectedID;
            createEdgeStartVertexIndex_ = hitVertexIndex;
            createEdgeStartLocalPosition_ = clampedStart;
            createEdgeDidDrag_ = false;
            const Vec2 previewStart = localToWorld(clampedStart, image);
            scene.meshCreateEdgePreviewStart = previewStart;
            scene.meshCreateEdgePreviewEnd = previewStart;
            if (hitVertexIndex.has_value()) scene.selectMeshVertices({*hitVertexIndex});
            return;
        }
        case EditorScene::MeshEditToolMode::Modify:
            break;
    }

    if (hitVertexIndex.has_value()) {
        pendingEmptyClick_ = false;
        const int vertexIndex = *hitVertexIndex;
        if (input.isShiftPressed) {
            if (scene.selectedMeshVertexIndices.contains(vertexIndex)) {
                scene.removeMeshVertexFromSelection(vertexIndex);
            } else {
                scene.addMeshVertexToSelection(vertexIndex);
            }
        } else {
            scene.selectMeshVertices({vertexIndex});
        }
        std::vector<int> selected(scene.selectedMeshVertexIndices.begin(), scene.selectedMeshVertexIndices.end());
        std::sort(selected.begin(), selected.end());
        if (selected.empty()) selected = {vertexIndex};
        beginVertexDrag(image, selectedID, selected, ToolUtilities::localCoordinates(input.position, image), scene,
                        asset->size);
        return;
    }

    pendingEmptyClick_ = true;
    resetDragState(scene);
}

void MeshTool::onMouseDrag(const ToolInput& input, EditorScene& scene, const ImageHitTestFn&, float hitScale, bool) {
    if (scene.meshWeightPaintEnabled) {
        // No colour, no stroke.
        if (!scene.activeWeightPaintBoneID.has_value() || !scene.selectedImageID.has_value()) return;
        const SceneImage* image = scene.image(*scene.selectedImageID);
        const AssetAlpha* asset = image != nullptr ? assetFor(*image) : nullptr;
        if (asset == nullptr) return;
        // A stroke, not half a double click: the press's stamp stays.
        weightsBeforePaintClick_ = std::nullopt;
        // From the last stamp, or a fast stroke paints a row of dots.
        scene.paintSelectedMeshWeights(lastPaintWorld_.value_or(input.position), input.position, asset->size);
        lastPaintWorld_ = input.position;
        return;
    }

    if (createEdgeStartImageID_.has_value()) {
        const SceneImage* image = scene.image(*createEdgeStartImageID_);
        const AssetAlpha* asset = image != nullptr ? assetFor(*image) : nullptr;
        if (asset != nullptr) {
            const Vec2 local = ToolUtilities::localCoordinates(input.position, *image);
            scene.meshCreateEdgePreviewEnd = localToWorld(clampedToMeshInterior(local, *image, asset->size), *image);
            if (length(input.screenPosition - input.startScreenPosition) >= createDragThresholdPx(hitScale)) {
                createEdgeDidDrag_ = true;
            }
            return;
        }
    }

    if (!activeImageID_.has_value()) return;
    const SceneImage* imagePtr = scene.image(*activeImageID_);
    const AssetAlpha* asset = imagePtr != nullptr ? assetFor(*imagePtr) : nullptr;
    if (asset == nullptr) return;
    const SceneImage image = *imagePtr;
    const Vec2 delta = ToolUtilities::localCoordinates(input.position, image) - dragStartLocalPosition_;
    // ONE PATH: dragging a node moves the NODE. In Editor the uv moves with
    // it (the mesh is fitted to the art); in Animator it does not (the art
    // follows: a deform). `updateMeshVertex` routes to the deform itself.
    for (int vertexIndex : activeVertexIndices_) {
        const auto w = dragInfluenceWeights_.find(vertexIndex);
        const Vec2 weightedDelta = delta * (w != dragInfluenceWeights_.end() ? w->second : 1.0f);
        const auto start = dragStartVertexPositions_.find(vertexIndex);
        if (start == dragStartVertexPositions_.end()) continue;
        scene.updateMeshVertex(*activeImageID_, vertexIndex, start->second + weightedDelta);
        if (!scene.isAnimationEditingEnabled) {
            if (const auto uv = dragStartVertexUVs_.find(vertexIndex); uv != dragStartVertexUVs_.end()) {
                const Vec2 uvDelta(weightedDelta.x / asset->size.x, -weightedDelta.y / asset->size.y);
                scene.updateMeshUV(*activeImageID_, vertexIndex, uv->second + uvDelta);
            }
        }
    }
}

void MeshTool::onMouseUp(const ToolInput& input, EditorScene& scene, const ImageHitTestFn&, float hitScale, bool) {
    lastPaintWorld_ = std::nullopt;
    scene.endInteraction();

    if (scene.meshEditToolMode == EditorScene::MeshEditToolMode::Create && createEdgeStartImageID_.has_value() &&
        createEdgeStartLocalPosition_.has_value() && scene.selectedImageID == createEdgeStartImageID_) {
        const Uuid startImageID = *createEdgeStartImageID_;
        const SceneImage* imagePtr = scene.image(startImageID);
        const AssetAlpha* asset = imagePtr != nullptr ? assetFor(*imagePtr) : nullptr;
        if (asset != nullptr) {
            const SceneImage image = *imagePtr;
            const Vec2 releaseLocal =
                clampedToMeshInterior(ToolUtilities::localCoordinates(input.position, image), image, asset->size);
            const auto projection =
                CanvasImagePicking::selectedMeshProjection(scene, *assets, input.camera, input.viewSize, hitScale);
            const std::optional<int> releaseHitVertex =
                projection.has_value() ? ToolUtilities::hitTestMeshVertex(input.screenPosition, *projection)
                                       : std::nullopt;
            if (createEdgeDidDrag_) {
                const std::optional<int> startVertex =
                    createEdgeStartVertexIndex_.has_value()
                        ? createEdgeStartVertexIndex_
                        : scene.insertMeshInteriorVertex(startImageID, *createEdgeStartLocalPosition_, asset->size);
                const std::optional<int> endVertex =
                    releaseHitVertex.has_value() ? releaseHitVertex
                                                 : scene.insertMeshInteriorVertex(startImageID, releaseLocal, asset->size);
                if (startVertex.has_value() && endVertex.has_value() && *startVertex != *endVertex) {
                    scene.connectMeshVertices(*startVertex, *endVertex);
                }
            } else if (releaseHitVertex.has_value()) {
                scene.selectMeshVertices({*releaseHitVertex});
            } else if (const std::optional<int> edge =
                           projection.has_value()
                               ? ToolUtilities::hitTestMeshHullEdge(input.screenPosition, *projection, hitScale)
                               : std::nullopt) {
                scene.insertMeshVertex(startImageID, releaseLocal, *edge);
            } else {
                scene.insertMeshInteriorVertex(startImageID, releaseLocal, asset->size);
            }
            scene.constrainMeshInteriorVertices(startImageID, asset->size);
        }
    }

    if (pendingEmptyClick_ && length(input.screenPosition - input.startScreenPosition) < 3.0f) {
        scene.selectMeshVertices({});
        scene.selectMeshInternalEdge(std::nullopt);
    }
    const std::optional<Uuid> pendingDeformImageID = activeImageID_;
    pendingEmptyClick_ = false;
    resetDragState(scene);
    if (scene.isAnimationEditingEnabled && pendingDeformImageID.has_value()) {
        scene.commitMeshDeformKeyframe(*pendingDeformImageID);
    }
    if (!scene.selectedImageID.has_value()) scene.selectMeshVertices({});
}

void MeshTool::cancelPendingCreateEdge(EditorScene& scene) {
    createEdgeStartImageID_ = std::nullopt;
    createEdgeStartVertexIndex_ = std::nullopt;
    scene.meshCreateEdgePreviewStart = std::nullopt;
    scene.meshCreateEdgePreviewEnd = std::nullopt;
}

// Clears the Create preview too: a reset that skipped it left the green
// start dot on the canvas for the rest of the session.
void MeshTool::resetDragState(EditorScene& scene) {
    activeImageID_ = std::nullopt;
    activeVertexIndices_.clear();
    dragStartLocalPosition_ = Vec2::zero();
    dragStartVertexPositions_.clear();
    dragStartVertexUVs_.clear();
    dragInfluenceWeights_.clear();
    createEdgeStartImageID_ = std::nullopt;
    createEdgeStartVertexIndex_ = std::nullopt;
    createEdgeStartLocalPosition_ = std::nullopt;
    createEdgeDidDrag_ = false;
    scene.meshCreateEdgePreviewStart = std::nullopt;
    scene.meshCreateEdgePreviewEnd = std::nullopt;
}

// Soft selection when enabled (the falloff the inspector offers), and the
// drag starts from where each node is DRAWN, so it does not jump on the
// first pixel when the overlay places nodes from their uvs.
void MeshTool::beginVertexDrag(const SceneImage& image, Uuid selectedID, const std::vector<int>& selectedVertices,
                               Vec2 localPosition, const EditorScene& scene, Vec2 assetSize) {
    std::unordered_map<int, float> weights;
    if (scene.meshSoftSelectionEnabled) {
        weights = ToolUtilities::softSelectionWeights(
            image, assetSize, std::unordered_set<int>(selectedVertices.begin(), selectedVertices.end()),
            scene.isMeshOverlayDeformed(), scene.meshSoftSelectionRadius, scene.meshSoftSelectionFeather,
            scene.meshSoftSelectionExcludeHull);
    }
    if (weights.empty()) {
        for (int v : selectedVertices) weights[v] = 1.0f;
    }
    activeImageID_ = selectedID;
    dragInfluenceWeights_ = weights;
    activeVertexIndices_.clear();
    for (const auto& [index, w] : weights) activeVertexIndices_.push_back(index);
    std::sort(activeVertexIndices_.begin(), activeVertexIndices_.end());
    dragStartLocalPosition_ = localPosition;
    const std::vector<Vec2> source = ToolUtilities::editLocalVertices(image, assetSize, scene.isMeshOverlayDeformed(),
                                                                      ToolUtilities::resolvedMesh(image, assetSize));
    dragStartVertexPositions_.clear();
    dragStartVertexUVs_.clear();
    for (int index : activeVertexIndices_) {
        if (index >= 0 && static_cast<std::size_t>(index) < source.size()) {
            dragStartVertexPositions_[index] = source[static_cast<std::size_t>(index)];
        }
        if (index >= 0 && static_cast<std::size_t>(index) < image.mesh.uvs.size()) {
            dragStartVertexUVs_[index] = image.mesh.uvs[static_cast<std::size_t>(index)];
        }
    }
}

} // namespace umeshcore
