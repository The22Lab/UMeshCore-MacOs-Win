// EditorScene -- mesh editing, weights and binding: the SceneManager half
// of Mesh mode that needs no texture. The geometry itself is `Mesh`'s (see
// src/Mesh/MeshEditing.cpp); this file is the editing surface over it --
// selection, undo, notices, and carrying per-vertex deform data across
// topology changes.
//
// Ported from `Data/SceneManager.swift`, `selectMeshVertices` through
// `deleteSelectedMeshVertices` / `extendDeformArrays`, including Auto Bind
// and the weight brush. Not here: `traceSelectedMesh`, which reads the
// sprite's alpha (next slice).
//
// Notes on the port:
//  - Swift passes `alphaSampler` / `assetSize` to `insertMeshVertex` and
//    `updateMeshUV` and discards both (`_ = alphaSampler`); they are not
//    carried over.
//  - Swift iterates a `[UUID: [UUID: BoneFit]]` dictionary when looking for
//    the sprite that holds most of a bone, and takes the first on a tie --
//    so which sprite a contested bone was "left to" could change between
//    launches. Here the rivals are visited in `images` order.
//  - `Set` / `Dictionary` orders in the brush and in `boundBoneIDs` become
//    first-seen / hierarchy orders. Same values, deterministic order.

#include "umeshcore/Editor/EditorScene.h"

#include <algorithm>
#include <cmath>
#include <set>

#include "umeshcore/Editor/ToolUtilities.h"

namespace umeshcore {

namespace {

// A vertex's influences as an insertion-ordered map (Swift builds a
// `Dictionary(uniqueKeysWithValues:)` from sanitized weights, whose keys
// are unique).
struct InfluenceMap {
    std::vector<std::pair<Uuid, float>> entries;

    float get(Uuid id) const {
        for (const auto& [k, v] : entries) {
            if (k == id) return v;
        }
        return 0.0f;
    }
    bool has(Uuid id) const {
        return std::any_of(entries.begin(), entries.end(), [&](const auto& e) { return e.first == id; });
    }
    void set(Uuid id, float value) {
        for (auto& [k, v] : entries) {
            if (k == id) {
                v = value;
                return;
            }
        }
        entries.emplace_back(id, value);
    }
    void erase(Uuid id) {
        entries.erase(std::remove_if(entries.begin(), entries.end(), [&](const auto& e) { return e.first == id; }),
                      entries.end());
    }
    std::vector<VertexBoneWeight> weights() const {
        std::vector<VertexBoneWeight> out;
        for (const auto& [k, v] : entries) out.push_back(VertexBoneWeight{k, v});
        return out;
    }
};

InfluenceMap mapOf(const std::vector<VertexBoneWeight>& weights) {
    InfluenceMap m;
    for (const VertexBoneWeight& w : weights) m.set(w.boneID, w.weight);
    return m;
}

// The brush's own normalisation: merge, drop non-positive, keep the
// strongest `maxInfluences`, sum to one.
std::vector<VertexBoneWeight> normalizedInfluences(const std::vector<VertexBoneWeight>& influences, int maxInfluences) {
    InfluenceMap merged;
    for (const VertexBoneWeight& w : influences) {
        if (std::isfinite(w.weight) && w.weight > 0) merged.set(w.boneID, merged.get(w.boneID) + w.weight);
    }
    std::vector<VertexBoneWeight> result;
    for (const auto& [k, v] : merged.entries) result.push_back(VertexBoneWeight{k, std::max(0.0f, v)});
    std::stable_sort(result.begin(), result.end(), [](const auto& a, const auto& b) { return a.weight > b.weight; });
    if (static_cast<int>(result.size()) > maxInfluences) result.resize(static_cast<std::size_t>(maxInfluences));
    float total = 0.0f;
    for (const auto& w : result) total += w.weight;
    if (!(total > 0.000001f)) return {};
    for (auto& w : result) w.weight /= total;
    return result;
}

// A brush prepared once per stroke: the mesh, the parameters, the drawn
// world positions, and the adjacency when the mode reads neighbours.
struct WeightBrush {
    Mesh mesh;
    std::vector<std::vector<VertexBoneWeight>> weights;
    std::vector<Vec2> worldPositions;
    std::optional<std::unordered_set<int>> restrictedTo;
    std::vector<std::vector<int>> neighbors;
    Uuid boneID;
    EditorScene::MeshWeightPaintMode mode = EditorScene::MeshWeightPaintMode::Add;
    float radius = 1.0f;
    float strength = 0.0f;
    float falloff = 1.0f;
    float influence = 1.0f;
    int maxInfluences = 4;

    void apply(Vec2 center) {
        using Mode = EditorScene::MeshWeightPaintMode;
        for (std::size_t index = 0; index < mesh.vertices.size(); ++index) {
            if (restrictedTo.has_value() && !restrictedTo->contains(static_cast<int>(index))) continue;
            if (index >= worldPositions.size()) continue;
            const float distance = length(worldPositions[index] - center);
            if (!(distance <= radius)) continue;
            const float t = std::max(0.0f, 1.0f - distance / radius);
            const float factor = std::pow(t, falloff) * strength;
            if (!(factor > 0.0001f)) continue;

            InfluenceMap map = mapOf(weights[index]);
            const float current = map.get(boneID);
            const float target = std::max(0.0f, std::min(1.0f, influence));

            switch (mode) {
                case Mode::Add: {
                    const float newWeight = std::min(1.0f, current + (target - current) * factor);
                    if (newWeight > current + 0.0001f) {
                        map.set(boneID, newWeight);
                        // The other bones give way proportionally, so the
                        // active one can reach 100%.
                        const float priorOtherTotal = std::max(0.0f, 1.0f - current);
                        if (priorOtherTotal > 0.0001f) {
                            const float scale = std::max(0.0f, 1.0f - newWeight) / priorOtherTotal;
                            for (auto& [k, v] : map.entries) {
                                if (k != boneID) v = std::max(0.0f, v * scale);
                            }
                        }
                    }
                    break;
                }
                case Mode::Subtract:
                    map.set(boneID, std::max(0.0f, current - factor));
                    break;
                case Mode::Replace:
                    for (auto& [k, v] : map.entries) {
                        v = k == boneID ? current * (1 - factor) + target * factor : v * (1 - factor);
                    }
                    if (!map.has(boneID)) map.set(boneID, target * factor);
                    break;
                case Mode::Smooth:
                case Mode::Blur: {
                    if (index >= neighbors.size()) break;
                    float sum = 0.0f;
                    int count = 0;
                    for (int n : neighbors[index]) {
                        for (const VertexBoneWeight& w : weights[static_cast<std::size_t>(n)]) {
                            if (w.boneID == boneID) {
                                sum += w.weight;
                                count += 1;
                                break;
                            }
                        }
                    }
                    if (count > 0) {
                        const float average = sum / static_cast<float>(count);
                        map.set(boneID, std::max(0.0f, current + (average - current) * factor));
                    }
                    break;
                }
            }
            weights[index] = normalizedInfluences(map.weights(), maxInfluences);
        }
    }
};

} // namespace

std::optional<std::size_t> EditorScene::imageIndex(Uuid id) const {
    for (std::size_t i = 0; i < images.size(); ++i) {
        if (images[i].id == id) return i;
    }
    return std::nullopt;
}

// ---- Selection and outline tracing ----------------------------------------------

void EditorScene::selectMeshInternalEdge(std::optional<int> index) {
    selectedMeshInternalEdgeIndex = index;
    if (index.has_value()) selectedMeshVertexIndices.clear();
}

void EditorScene::beginNewMesh() {
    isMeshCreatingHull = true;
    selectedMeshVertexIndices.clear();
    if (!selectedImageID.has_value()) return;
    const auto i = imageIndex(*selectedImageID);
    if (!i.has_value()) return;
    pushUndoState();
    Mesh& mesh = images[*i].mesh;
    mesh.vertices.clear();
    mesh.uvs.clear();
    mesh.indices.clear();
    mesh.hullVertexIndices.clear();
}

// Closing the traced outline is what gives it an interior: the only place
// it is triangulated.
void EditorScene::finishNewMesh() {
    isMeshCreatingHull = false;
    if (!selectedImageID.has_value()) return;
    const auto i = imageIndex(*selectedImageID);
    if (!i.has_value()) return;
    Mesh& mesh = images[*i].mesh;
    if (mesh.hullVertexIndices.size() < 3) {
        meshEditNotice = MeshEditNotice{
            "An outline needs at least three points. Trace one, or press New Edge again to start over.", true};
        return;
    }
    mesh.indices = mesh.triangulatedHullIndices();
}

// In Animator a vertex drag is a DEFORM (the live per-vertex array), in
// Editor it moves the rest mesh. Interior vertices are held inside the
// outline either way.
void EditorScene::updateMeshVertex(Uuid imageID, int vertexIndex, Vec2 localPosition) {
    const auto i = imageIndex(imageID);
    if (!i.has_value()) return;
    SceneImage& img = images[*i];
    if (vertexIndex < 0 || static_cast<std::size_t>(vertexIndex) >= img.mesh.vertices.size()) return;
    const Vec2 clamped = img.mesh.clampedPositionInsideHullIfNeeded(vertexIndex, localPosition);
    if (isAnimationEditingEnabled) {
        if (!img.meshAnimationDeform.has_value()) img.meshAnimationDeform = img.mesh.vertices;
        (*img.meshAnimationDeform)[static_cast<std::size_t>(vertexIndex)] = clamped;
    } else {
        img.mesh.vertices[static_cast<std::size_t>(vertexIndex)] = clamped;
    }
}

void EditorScene::updateMeshUV(Uuid imageID, int vertexIndex, Vec2 uv) {
    const auto i = imageIndex(imageID);
    if (!i.has_value()) return;
    Mesh& mesh = images[*i].mesh;
    if (vertexIndex < 0 || static_cast<std::size_t>(vertexIndex) >= mesh.uvs.size()) return;
    mesh.uvs[static_cast<std::size_t>(vertexIndex)] =
        Vec2(std::max(0.0f, std::min(1.0f, uv.x)), std::max(0.0f, std::min(1.0f, uv.y)));
}

// ---- Insertion, deletion, and the deform data that must follow ------------------

// Inserts append, so only the new slot needs a value -- and the rest
// position would make the sprite snap on every deformed frame. The new
// value is the barycentric blend of the DEFORMED corners of the old
// triangle that contained it, so subdividing leaves the silhouette alone.
void EditorScene::extendDeformArrays(std::size_t index, Uuid imageID, const Mesh& previousMesh, int insertedIndex) {
    const Mesh& newMesh = images[index].mesh;
    const Vec2 restPosition = insertedIndex >= 0 && static_cast<std::size_t>(insertedIndex) < newMesh.vertices.size()
                                  ? newMesh.vertices[static_cast<std::size_t>(insertedIndex)]
                                  : Vec2::zero();
    const std::optional<Mesh::BarycentricSample> blend = previousMesh.barycentricSample(restPosition);

    auto grown = [&](const std::vector<Vec2>& old) {
        std::vector<Vec2> next = newMesh.vertices;
        for (std::size_t i = 0; i < std::min(old.size(), next.size()); ++i) {
            if (static_cast<int>(i) != insertedIndex) next[i] = old[i];
        }
        if (insertedIndex >= 0 && static_cast<std::size_t>(insertedIndex) < next.size() && blend.has_value()) {
            auto corner = [&](int k) {
                return k >= 0 && static_cast<std::size_t>(k) < old.size() ? old[static_cast<std::size_t>(k)]
                                                                           : restPosition;
            };
            next[static_cast<std::size_t>(insertedIndex)] =
                corner(blend->a) * blend->wa + corner(blend->b) * blend->wb + corner(blend->c) * blend->wc;
        }
        return next;
    };

    SceneImage& img = images[index];
    if (img.meshAnimationDeform.has_value()) img.meshAnimationDeform = grown(*img.meshAnimationDeform);

    std::vector<AnimationTrack> tracks = img.animationClip.tracks();
    bool rewrote = false;
    for (AnimationTrack& track : tracks) {
        if (track.targetID != imageID || track.property != AnimationTrackProperty::MeshDeform) continue;
        for (Keyframe& key : track.keyframes) {
            if (const auto* deform = std::get_if<MeshDeformValue>(&key.value)) {
                key.value = MeshDeformValue{grown(deform->value)};
                rewrote = true;
            }
        }
    }
    if (rewrote) img.animationClip.setTracks(std::move(tracks));
}

std::optional<int> EditorScene::insertMeshVertex(Uuid imageID, Vec2 localPosition, int afterHullEdge) {
    const auto i = imageIndex(imageID);
    if (!i.has_value()) return std::nullopt;
    const auto result = images[*i].mesh.insertingHullVertex(localPosition, afterHullEdge);
    if (!result.has_value()) return std::nullopt;
    beginInteraction();
    // No opaque-area filtering here: in manual editing it removes coverage
    // and leaves transparent wedges.
    const Mesh previousMesh = images[*i].mesh;
    images[*i].mesh = result->mesh;
    extendDeformArrays(*i, imageID, previousMesh, result->insertedIndex);
    selectedMeshVertexIndices = {result->insertedIndex};
    selectedMeshInternalEdgeIndex = std::nullopt;
    return result->insertedIndex;
}

// An outline being traced is an OPEN polyline with no interior, so nothing
// is triangulated until `finishNewMesh` closes it.
std::optional<int> EditorScene::appendMeshHullVertex(Uuid imageID, Vec2 localPosition, Vec2 assetSize) {
    const auto i = imageIndex(imageID);
    if (!i.has_value()) return std::nullopt;
    beginInteraction();
    const Mesh previousMesh = images[*i].mesh;
    Mesh& mesh = images[*i].mesh;
    const int insertedIndex = static_cast<int>(mesh.vertices.size());
    mesh.vertices.push_back(localPosition);
    mesh.uvs.push_back(Mesh::uvFor(localPosition, assetSize));
    mesh.hullVertexIndices.push_back(static_cast<std::uint16_t>(insertedIndex));
    if (isMeshCreatingHull) {
        mesh.indices.clear();
    } else if (mesh.hullVertexIndices.size() >= 3) {
        mesh.indices = mesh.triangulatedHullIndices();
    } else {
        mesh.indices.clear();
    }
    extendDeformArrays(*i, imageID, previousMesh, insertedIndex);
    selectedMeshVertexIndices = {insertedIndex};
    selectedMeshInternalEdgeIndex = std::nullopt;
    return insertedIndex;
}

std::optional<int> EditorScene::insertMeshInteriorVertex(Uuid imageID, Vec2 localPosition, Vec2 assetSize) {
    const auto i = imageIndex(imageID);
    if (!i.has_value()) return std::nullopt;
    const auto result = images[*i].mesh.insertingInteriorVertex(localPosition, assetSize);
    if (!result.has_value()) {
        // Say why: if the stored outline is at fault, every insertion fails
        // and the mesh looks dead.
        meshEditNotice = images[*i].mesh.validationReport().isValid()
                             ? MeshEditNotice{"That point can't be added: it has to be inside the outline.", true}
                             : MeshEditNotice{"This mesh's outline is invalid, so no node can be added to it. "
                                              "Re-trace it from Mesh ▸ Auto Trace, or Reset to start over.",
                                              true};
        return std::nullopt;
    }
    beginInteraction();
    const Mesh previousMesh = images[*i].mesh;
    images[*i].mesh = result->mesh;
    extendDeformArrays(*i, imageID, previousMesh, result->insertedIndex);
    selectedMeshVertexIndices = {result->insertedIndex};
    selectedMeshInternalEdgeIndex = std::nullopt;
    return result->insertedIndex;
}

// The mesh carries vertices, UVs, weights and bind pose itself; the live
// deform and every `.meshDeform` key live on the sprite, addressed by index,
// and are rewritten through the remap -- always exactly the new length,
// which is what the exporter checks before keeping a key at all.
void EditorScene::applyTopologyChange(const MeshTopologyChange& change, std::size_t index, Uuid imageID) {
    SceneImage& img = images[index];
    img.mesh = change.mesh;
    if (img.meshAnimationDeform.has_value()) {
        img.meshAnimationDeform = change.remapped(*img.meshAnimationDeform, change.mesh.vertices);
    }
    std::vector<AnimationTrack> tracks = img.animationClip.tracks();
    bool rewrote = false;
    for (AnimationTrack& track : tracks) {
        if (track.targetID != imageID || track.property != AnimationTrackProperty::MeshDeform) continue;
        for (Keyframe& key : track.keyframes) {
            if (const auto* deform = std::get_if<MeshDeformValue>(&key.value)) {
                key.value = MeshDeformValue{change.remapped(deform->value, change.mesh.vertices)};
                rewrote = true;
            }
        }
    }
    if (rewrote) img.animationClip.setTracks(std::move(tracks));
}

void EditorScene::deleteSelectedMeshVertices() {
    if (!selectedImageID.has_value() || selectedMeshVertexIndices.empty()) return;
    const auto i = imageIndex(*selectedImageID);
    if (!i.has_value()) return;
    const auto change = images[*i].mesh.removingVertices(selectedMeshVertexIndices);
    if (!change.has_value()) {
        meshEditNotice = MeshEditNotice{"Those points can't be removed: the outline would cross itself.", true};
        return;
    }
    // beginInteraction, not pushUndoState: the mesh tool's mouse-down has
    // already begun the gesture, and a second push made the first Cmd-Z a
    // no-op.
    beginInteraction();
    applyTopologyChange(*change, *i, *selectedImageID);
    selectedMeshVertexIndices.clear();
    selectedMeshInternalEdgeIndex = std::nullopt;
    meshEditNotice = std::nullopt;
}

void EditorScene::resetSelectedMesh(Vec2 assetSize) {
    if (!selectedImageID.has_value()) return;
    const auto i = imageIndex(*selectedImageID);
    if (!i.has_value()) return;
    pushUndoState();
    images[*i].mesh = images[*i].mesh.resetToQuad(assetSize);
    selectedMeshVertexIndices.clear();
    isMeshCreatingHull = false;
}

void EditorScene::generateSelectedMesh(Vec2 assetSize) {
    if (!selectedImageID.has_value()) return;
    const auto i = imageIndex(*selectedImageID);
    if (!i.has_value()) return;
    pushUndoState();
    images[*i].mesh = images[*i].mesh.generated(assetSize, meshGenerateDensity);
    selectedMeshVertexIndices.clear();
    isMeshCreatingHull = false;
}

// ---- Edges and faces -------------------------------------------------------------

namespace {
std::vector<int> sortedIndices(const std::unordered_set<int>& s) {
    std::vector<int> v(s.begin(), s.end());
    std::sort(v.begin(), v.end());
    return v;
}
} // namespace

void EditorScene::connectMeshVertices(int first, int second) {
    if (!selectedImageID.has_value()) return;
    const auto i = imageIndex(*selectedImageID);
    if (!i.has_value()) return;
    pushUndoState();
    Mesh& mesh = images[*i].mesh;
    const std::size_t previousCount = mesh.internalEdges.size();
    mesh = mesh.connectingVertices(first, second);
    if (mesh.internalEdges.size() > previousCount) {
        selectedMeshInternalEdgeIndex = static_cast<int>(mesh.internalEdges.size()) - 1;
        selectedMeshVertexIndices = {first, second};
    }
}

void EditorScene::connectSelectedMeshVertices() {
    if (selectedMeshVertexIndices.size() != 2) return;
    const std::vector<int> sorted = sortedIndices(selectedMeshVertexIndices);
    connectMeshVertices(sorted[0], sorted[1]);
}

void EditorScene::clearSelectedMeshEdges() {
    if (!selectedImageID.has_value()) return;
    const auto i = imageIndex(*selectedImageID);
    if (!i.has_value()) return;
    pushUndoState();
    images[*i].mesh = images[*i].mesh.clearingInternalEdges();
    selectedMeshInternalEdgeIndex = std::nullopt;
}

void EditorScene::createSelectedMeshFace() {
    if (selectedMeshVertexIndices.size() != 3 || !selectedImageID.has_value()) return;
    const auto i = imageIndex(*selectedImageID);
    if (!i.has_value()) return;
    pushUndoState();
    const std::vector<int> sorted = sortedIndices(selectedMeshVertexIndices);
    images[*i].mesh = images[*i].mesh.creatingFace(sorted[0], sorted[1], sorted[2]);
    selectedMeshInternalEdgeIndex = std::nullopt;
}

void EditorScene::deleteSelectedMeshInternalEdge() {
    if (!selectedImageID.has_value() || !selectedMeshInternalEdgeIndex.has_value()) return;
    const auto i = imageIndex(*selectedImageID);
    if (!i.has_value()) return;
    Mesh& mesh = images[*i].mesh;
    const int edgeIndex = *selectedMeshInternalEdgeIndex;
    if (edgeIndex < 0 || static_cast<std::size_t>(edgeIndex) >= mesh.internalEdges.size()) return;
    pushUndoState();
    Mesh& m = images[*i].mesh;
    const MeshEdge removed = m.internalEdges[static_cast<std::size_t>(edgeIndex)];
    m.internalEdges.erase(m.internalEdges.begin() + edgeIndex);
    m.manualTriangles.erase(std::remove_if(m.manualTriangles.begin(), m.manualTriangles.end(),
                                           [&](const MeshTriangle& t) { return t.containsEdge(removed); }),
                            m.manualTriangles.end());
    m.indices = m.triangulatedIndicesWithInternalEdges();
    selectedMeshInternalEdgeIndex = std::nullopt;
}

void EditorScene::constrainMeshInteriorVertices(Uuid imageID, Vec2 assetSize) {
    const auto i = imageIndex(imageID);
    if (!i.has_value()) return;
    images[*i].mesh = images[*i].mesh.clampingInteriorVerticesInsideHull(assetSize);
}

// ---- Binding ---------------------------------------------------------------------

std::vector<Uuid> EditorScene::boundBoneIDs(Uuid imageID) const {
    const SceneImage* img = image(imageID);
    if (img == nullptr) return {};
    const auto bound = img->mesh.boundBoneIDs();
    std::vector<Uuid> out;
    for (const Bone& b : skeleton.orderedBones()) {
        if (bound.contains(b.id)) out.push_back(b.id);
    }
    // A stale id (a bone since deleted) still counts as bound, as in Swift;
    // it goes last, in a stable order.
    std::vector<Uuid> stale;
    for (Uuid id : bound) {
        if (skeleton.bone(id) == nullptr) stale.push_back(id);
    }
    std::sort(stale.begin(), stale.end(), [](Uuid a, Uuid b) { return a.hi != b.hi ? a.hi < b.hi : a.lo < b.lo; });
    out.insert(out.end(), stale.begin(), stale.end());
    return out;
}

// Records the bind; does not repaint (the artist's weights and their own
// "show deformed" choice are left alone).
void EditorScene::bindBoneToImage(Uuid imageID, Uuid boneID, Vec2 assetSize, int maxInfluences) {
    const auto i = imageIndex(imageID);
    const auto world = skeleton.worldMatrix(boneID);
    if (!i.has_value() || skeleton.bone(boneID) == nullptr || !world.has_value()) return;
    pushUndoState();
    Mesh& mesh = images[*i].mesh;
    if (mesh.isQuadCompatible()) mesh = mesh.generated(assetSize);
    mesh = mesh.addingBoneInfluence(boneID, *world, maxInfluences, meshPose(images[*i]));
    refreshBoneBindingColors();
}

void EditorScene::unbindBoneFromImage(Uuid imageID, Uuid boneID, int maxInfluences) {
    const auto i = imageIndex(imageID);
    if (!i.has_value()) return;
    pushUndoState();
    images[*i].mesh = images[*i].mesh.removingBoneInfluence(boneID, maxInfluences);
    refreshBoneBindingColors();
}

// Rebalances the bones ALREADY bound; binds nothing (the old version bound
// the whole rig to one sprite).
void EditorScene::autoWeightMesh(Uuid imageID, int maxInfluences) {
    const auto i = imageIndex(imageID);
    if (!i.has_value()) return;
    std::unordered_set<Uuid, UuidHash> bound;
    for (Uuid id : images[*i].mesh.boundBoneIDs()) {
        if (skeleton.bone(id) != nullptr) bound.insert(id);
    }
    if (bound.empty()) {
        meshEditNotice = MeshEditNotice{
            "Auto-Weight only rebalances the bones this image is already bound to. Bind at least one bone first, "
            "in Weights ▸ Binding ▸ Bind Bones.",
            true};
        return;
    }
    pushUndoState();
    images[*i].mesh = images[*i].mesh.autoWeights(skeleton, bound, maxInfluences, 4.0f, 0.35f, 0.0001f,
                                                  meshPose(images[*i]));
    meshEditNotice = std::nullopt;
    refreshBoneBindingColors();
}

void EditorScene::autoWeightSelectedMesh(int maxInfluences) {
    if (selectedImageID.has_value()) autoWeightMesh(*selectedImageID, maxInfluences);
}

bool EditorScene::skinImageToSkeleton(Uuid imageID, Vec2 assetSize, int maxInfluences) {
    const auto i = imageIndex(imageID);
    if (!i.has_value() || skeleton.bones().empty()) return false;
    pushUndoState();
    Mesh& mesh = images[*i].mesh;
    if (mesh.isQuadCompatible()) mesh = mesh.generated(assetSize);
    mesh = mesh.autoBindWeights(skeleton, maxInfluences, 4.0f, 0.35f, 0.0001f, meshPose(images[*i]));
    meshShowDeformed = true;
    return true;
}

void EditorScene::unskinImage(Uuid imageID) {
    const auto i = imageIndex(imageID);
    if (!i.has_value()) return;
    pushUndoState();
    Mesh& mesh = images[*i].mesh;
    mesh.vertexBoneWeights.assign(mesh.vertices.size(), {});
    mesh.boneInverseBindMatrices.clear();
    mesh.bindVertices.clear();
    mesh.bindImagePose = std::nullopt;
}

// A bone's colour is a statement about the meshes, so it is DERIVED from
// them: every bound bone gets one (in hierarchy order, so colours do not
// move between launches), every unbound bone gives its back.
void EditorScene::refreshBoneBindingColors() {
    std::unordered_set<Uuid, UuidHash> boundIDs;
    for (const SceneImage& img : images) {
        for (Uuid id : img.mesh.boundBoneIDs()) boundIDs.insert(id);
    }
    std::vector<Uuid> ordered;
    for (const IKBuilderOrderedBone& entry : IKBuilderRules::hierarchicalOrder(skeleton)) ordered.push_back(entry.bone.id);

    for (Uuid boneID : ordered) {
        const Bone* existing = skeleton.bone(boneID);
        if (existing == nullptr) continue;
        Bone bone = *existing;
        if (boundIDs.contains(boneID)) {
            if (bone.color.has_value()) continue;
            std::vector<Vec4> inUse;
            for (Uuid other : ordered) {
                if (const Bone* b = skeleton.bone(other); b != nullptr && b->color.has_value()) inUse.push_back(*b->color);
            }
            bone.color = Bone::bindingColor(boneID, inUse);
            skeleton.setBone(bone);
        } else if (bone.color.has_value()) {
            bone.color = std::nullopt;
            skeleton.setBone(bone);
        }
    }
}

EditorScene::InfluenceCount EditorScene::skinningInfluenceCount(Uuid imageID) const {
    const SceneImage* img = image(imageID);
    if (img == nullptr || img->mesh.vertexBoneWeights.empty()) return {};
    std::unordered_set<Uuid, UuidHash> bones;
    int vertices = 0;
    for (const auto& influences : img->mesh.vertexBoneWeights) {
        if (!influences.empty()) vertices += 1;
        for (const VertexBoneWeight& w : influences) bones.insert(w.boneID);
    }
    return InfluenceCount{static_cast<int>(bones.size()), vertices};
}

// ---- Weights ------------------------------------------------------------------------

void EditorScene::setVertexWeights(Uuid imageID, int vertexIndex, const std::vector<VertexBoneWeight>& influences,
                                   int maxInfluences) {
    const auto i = imageIndex(imageID);
    if (!i.has_value()) return;
    pushUndoState();
    Mesh mesh = images[*i].mesh.sanitizedSkinningData(maxInfluences);
    if (vertexIndex < 0 || static_cast<std::size_t>(vertexIndex) >= mesh.vertices.size()) return;
    std::vector<VertexBoneWeight> filtered;
    for (const VertexBoneWeight& w : influences) {
        if (std::isfinite(w.weight) && w.weight > 0) filtered.push_back(w);
    }
    std::stable_sort(filtered.begin(), filtered.end(), [](const auto& a, const auto& b) { return a.weight > b.weight; });
    if (static_cast<int>(filtered.size()) > maxInfluences) filtered.resize(static_cast<std::size_t>(maxInfluences));
    mesh.vertexBoneWeights[static_cast<std::size_t>(vertexIndex)] = filtered;
    images[*i].mesh = mesh.sanitizedSkinningData(maxInfluences);
    refreshBoneBindingColors();
}

// The bones stay BOUND (their inverse-bind matrices survive), so they keep
// their place in the bound list and their colours: only the paint goes.
void EditorScene::clearMeshWeights(Uuid imageID) {
    const auto i = imageIndex(imageID);
    if (!i.has_value()) return;
    pushUndoState();
    Mesh& mesh = images[*i].mesh;
    mesh.vertexBoneWeights.assign(mesh.vertices.size(), {});
    activeWeightPaintBoneID = std::nullopt;
    refreshBoneBindingColors();
}

void EditorScene::normalizeMeshWeights(Uuid imageID, int maxInfluences) {
    const auto i = imageIndex(imageID);
    if (!i.has_value()) return;
    pushUndoState();
    images[*i].mesh = images[*i].mesh.sanitizedSkinningData(maxInfluences);
}

std::vector<VertexBoneWeight> EditorScene::selectedVertexInfluences(Uuid imageID) const {
    const SceneImage* img = image(imageID);
    if (selectedMeshVertexIndices.empty() || img == nullptr) return {};
    const int vertexIndex = sortedIndices(selectedMeshVertexIndices).front();
    const Mesh mesh = img->mesh.sanitizedSkinningData(std::max(1, meshWeightMaxInfluencesPerVertex));
    if (static_cast<std::size_t>(vertexIndex) >= mesh.vertexBoneWeights.size()) return {};
    return mesh.vertexBoneWeights[static_cast<std::size_t>(vertexIndex)];
}

// No undo entry here -- Swift pushes none either.
void EditorScene::setSelectedVertexInfluence(Uuid imageID, Uuid boneID, float value) {
    const auto i = imageIndex(imageID);
    if (selectedMeshVertexIndices.empty() || !i.has_value()) return;
    const int vertexIndex = sortedIndices(selectedMeshVertexIndices).front();
    const int maxInfluences = std::max(1, meshWeightMaxInfluencesPerVertex);
    Mesh mesh = images[*i].mesh.sanitizedSkinningData(maxInfluences);
    if (static_cast<std::size_t>(vertexIndex) >= mesh.vertexBoneWeights.size()) return;
    InfluenceMap map = mapOf(mesh.vertexBoneWeights[static_cast<std::size_t>(vertexIndex)]);
    if (value <= 0.0001f) {
        map.erase(boneID);
    } else {
        map.set(boneID, std::max(0.0f, std::min(1.0f, value)));
        if (!mesh.boneInverseBindMatrices.contains(boneID)) {
            if (const auto world = skeleton.worldMatrix(boneID)) mesh.boneInverseBindMatrices[boneID] = inverse(*world);
        }
    }
    mesh.vertexBoneWeights[static_cast<std::size_t>(vertexIndex)] = map.weights();
    images[*i].mesh = mesh.sanitizedSkinningData(maxInfluences);
    refreshBoneBindingColors();
}

void EditorScene::restoreMeshWeights(Uuid imageID, const std::vector<std::vector<VertexBoneWeight>>& weights) {
    const auto i = imageIndex(imageID);
    if (!i.has_value() || images[*i].mesh.vertices.size() != weights.size()) return;
    images[*i].mesh.vertexBoneWeights = weights;
    refreshBoneBindingColors();
}

std::vector<Vec2> EditorScene::skinnedLocalVertices(const SceneImage& img, Vec2 assetSize, bool showDeformed,
                                                    const Mesh& mesh) const {
    return ToolUtilities::skinnedLocalVertices(img, assetSize, showDeformed, skeleton, mesh);
}

// ---- The weight brush ---------------------------------------------------------------

namespace {

// Everything a stroke needs, worked out once. Returns nullopt for a bone
// that does not exist.
std::optional<WeightBrush> prepareWeightBrush(const EditorScene& scene, const SceneImage& img, Uuid boneID,
                                              Vec2 assetSize, std::optional<EditorScene::MeshWeightPaintMode> mode,
                                              std::optional<float> radius, std::optional<float> strength,
                                              std::optional<float> falloff) {
    using Mode = EditorScene::MeshWeightPaintMode;
    if (scene.skeleton.bone(boneID) == nullptr) return std::nullopt;
    const Mode paintMode = mode.value_or(scene.meshWeightPaintMode);
    const int maxInfluences = std::max(1, scene.meshWeightMaxInfluencesPerVertex);

    Mesh mesh = img.mesh.sanitizedSkinningData(maxInfluences);
    if (mesh.bindVertices.size() != mesh.vertices.size()) mesh.bindVertices = mesh.vertices;
    if (mesh.vertexBoneWeights.size() != mesh.vertices.size()) mesh.vertexBoneWeights.assign(mesh.vertices.size(), {});
    if (!mesh.boneInverseBindMatrices.contains(boneID)) {
        if (const auto world = scene.skeleton.worldMatrix(boneID)) mesh.boneInverseBindMatrices[boneID] = inverse(*world);
    }
    if (!mesh.bindImagePose.has_value()) mesh.bindImagePose = meshPose(img);

    // Only smooth and blur read a neighbour.
    std::vector<std::vector<int>> neighbors;
    if (paintMode == Mode::Smooth || paintMode == Mode::Blur) {
        std::vector<std::set<int>> sets(mesh.vertices.size());
        for (std::size_t t = 0; t + 2 < mesh.indices.size(); t += 3) {
            const int a = mesh.indices[t], b = mesh.indices[t + 1], c = mesh.indices[t + 2];
            if (static_cast<std::size_t>(std::max({a, b, c})) >= sets.size()) continue;
            sets[static_cast<std::size_t>(a)].insert({b, c});
            sets[static_cast<std::size_t>(b)].insert({a, c});
            sets[static_cast<std::size_t>(c)].insert({a, b});
        }
        for (const auto& s : sets) neighbors.emplace_back(s.begin(), s.end());
    }

    // Where the artist SEES each vertex: the overlay's own call, lifted into
    // world space, so the ring, the markers and the brush agree.
    const std::vector<Vec2> local = scene.skinnedLocalVertices(img, assetSize, scene.isMeshOverlayDeformed(), mesh);
    WeightBrush brush;
    brush.worldPositions = ToolUtilities::transformedVertices(img, local);
    brush.weights = mesh.vertexBoneWeights;
    brush.mesh = std::move(mesh);
    if (!scene.selectedMeshVertexIndices.empty()) brush.restrictedTo = scene.selectedMeshVertexIndices;
    brush.neighbors = std::move(neighbors);
    brush.boneID = boneID;
    brush.mode = paintMode;
    brush.radius = std::max(radius.value_or(scene.meshWeightBrushRadius), 0.0001f);
    brush.strength = std::max(0.0f, std::min(strength.value_or(scene.meshWeightBrushStrength), 1.0f));
    brush.falloff = std::max(0.1f, falloff.value_or(scene.meshWeightBrushFalloff));
    brush.influence = scene.meshWeightBrushInfluence;
    brush.maxInfluences = maxInfluences;
    return brush;
}

} // namespace

void EditorScene::paintMeshWeights(Uuid imageID, Uuid boneID, Vec2 assetSize, Vec2 worldPoint,
                                   std::optional<MeshWeightPaintMode> mode, std::optional<float> radius,
                                   std::optional<float> strength, std::optional<float> falloff) {
    const auto i = imageIndex(imageID);
    if (!i.has_value()) return;
    auto brush = prepareWeightBrush(*this, images[*i], boneID, assetSize, mode, radius, strength, falloff);
    if (!brush.has_value()) return;
    brush->apply(worldPoint);
    Mesh mesh = brush->mesh;
    mesh.vertexBoneWeights = brush->weights;
    images[*i].mesh = mesh.sanitizedSkinningData(brush->maxInfluences);
}

void EditorScene::paintSelectedMeshWeights(Vec2 worldPoint, Vec2 assetSize) {
    if (!selectedImageID.has_value() || !activeWeightPaintBoneID.has_value()) return;
    paintMeshWeights(*selectedImageID, *activeWeightPaintBoneID, assetSize, worldPoint, std::nullopt, std::nullopt,
                     std::nullopt, std::nullopt);
}

// The whole segment between two pointer samples, stamped every quarter
// radius, so coverage depends on the path and not on how fast it was drawn.
void EditorScene::paintSelectedMeshWeights(Vec2 from, Vec2 to, Vec2 assetSize) {
    if (!selectedImageID.has_value() || !activeWeightPaintBoneID.has_value()) return;
    const auto i = imageIndex(*selectedImageID);
    if (!i.has_value()) return;
    auto brush = prepareWeightBrush(*this, images[*i], *activeWeightPaintBoneID, assetSize, std::nullopt,
                                    std::nullopt, std::nullopt, std::nullopt);
    if (!brush.has_value()) return;
    const float span = length(to - from);
    const float step = std::max(meshWeightBrushRadius * 0.25f, 0.0001f);
    // +1 so a stationary press still stamps once.
    const int stamps = std::min(static_cast<int>(std::ceil(static_cast<double>(span / step))) + 1, kMaxPaintStampsPerDrag);
    for (int k = 0; k < stamps; ++k) {
        const float t = stamps == 1 ? 1.0f : static_cast<float>(k) / static_cast<float>(stamps - 1);
        brush->apply(from + (to - from) * t);
    }
    Mesh mesh = brush->mesh;
    mesh.vertexBoneWeights = brush->weights;
    images[*i].mesh = mesh.sanitizedSkinningData(brush->maxInfluences);
}

// ---- Auto Bind ------------------------------------------------------------------------

namespace {

struct FitRow {
    Uuid imageID;
    std::unordered_map<Uuid, Mesh::BoneFit, UuidHash> fits;
};

// Every bone against every sprite outline, ONCE: whether a bone belongs
// here depends on how much of it lies elsewhere.
std::vector<FitRow> autoBindFitTable(const EditorScene& scene) {
    const WorldMatrices world = scene.skeleton.worldMatrices();
    struct Segment {
        Uuid id;
        Vec2 start, end;
    };
    std::vector<Segment> segments;
    for (const Bone& bone : scene.skeleton.orderedBones()) {
        auto it = world.find(bone.id);
        if (it == world.end()) continue;
        const Vec3 s = MatrixUtilities::transformPoint(Vec3::zero(), it->second);
        const Vec3 e = MatrixUtilities::transformPoint(Vec3(bone.length, 0, 0), it->second);
        segments.push_back(Segment{bone.id, Vec2(s.x, s.y), Vec2(e.x, e.y)});
    }
    std::vector<FitRow> table;
    for (const SceneImage& img : scene.images) {
        if (img.mesh.hullVertexIndices.size() < 3) continue;
        const MeshBindPose pose = meshPose(img);
        FitRow row{img.id, {}};
        for (const Segment& seg : segments) {
            const Mesh::BoneFit fit = img.mesh.fit(seg.start, seg.end, pose);
            if (fit.overlap > 0 || fit.originInside) row.fits[seg.id] = fit;
        }
        table.push_back(std::move(row));
    }
    return table;
}

// The bar for being a CANDIDATE -- any one of the three readings.
bool autoBindTouches(const Mesh::BoneFit& fit) {
    if (fit.originInside) return true;
    if (!(fit.overlap > 0)) return false;
    return fit.boneFraction >= EditorScene::kAutoBindMinBoneFraction ||
           fit.crossFraction >= EditorScene::kAutoBindMinCrossFraction;
}

} // namespace

// A bone is taken away from a sprite only when BOTH sides agree: another
// sprite holds at least twice as much of it, AND this sprite has a bone
// that fits it twice as well. (Deciding on the bone alone took the belt's
// only bone: the spine holds 190 units in the torso and 20 in the belt.)
// The best candidate is compared against itself, so a sprite is never
// emptied; a joint planted inside the sprite is exempt from both.
EditorScene::AutoBindDecision EditorScene::autoBindDecision(Uuid imageID) const {
    const std::vector<FitRow> table = autoBindFitTable(*this);
    auto here = std::find_if(table.begin(), table.end(), [&](const FitRow& r) { return r.imageID == imageID; });
    if (here == table.end()) return {};

    struct Candidate {
        Uuid id;
        Mesh::BoneFit fit;
    };
    std::vector<Candidate> candidates;
    for (const Bone& bone : skeleton.orderedBones()) {
        auto it = here->fits.find(bone.id);
        if (it != here->fits.end() && autoBindTouches(it->second)) candidates.push_back(Candidate{bone.id, it->second});
    }
    if (candidates.empty()) return {};

    float bestHere = 0.0f;
    for (const Candidate& c : candidates) bestHere = std::max(bestHere, c.fit.boneFraction);

    AutoBindDecision decision;
    std::vector<std::pair<Uuid, float>> scored;
    for (const Candidate& candidate : candidates) {
        if (candidate.fit.originInside) {
            scored.emplace_back(candidate.id, candidate.fit.boneFraction);
            continue;
        }
        std::optional<Uuid> rivalID;
        float rivalOverlap = 0.0f;
        for (const FitRow& row : table) {
            if (row.imageID == imageID) continue;
            auto it = row.fits.find(candidate.id);
            if (it == row.fits.end() || !(it->second.overlap > rivalOverlap)) continue;
            rivalOverlap = it->second.overlap;
            rivalID = row.imageID;
        }
        const bool dominated = candidate.fit.overlap < kAutoBindDominance * rivalOverlap;
        const bool outclassed = candidate.fit.boneFraction < kAutoBindRivalFloor * bestHere;
        if (dominated && outclassed && rivalID.has_value()) {
            decision.yielded.push_back(YieldedBone{candidate.id, *rivalID});
            continue;
        }
        scored.emplace_back(candidate.id, candidate.fit.boneFraction);
    }
    std::stable_sort(scored.begin(), scored.end(), [](const auto& a, const auto& b) { return a.second > b.second; });
    for (const auto& [id, fraction] : scored) decision.bound.push_back(id);
    return decision;
}

// The yielded bones are the part worth saying out loud: a bone given to an
// overlapping sprite looks, on the canvas, exactly like one the detection
// missed.
std::string EditorScene::autoBindSummary(const AutoBindDecision& decision) const {
    const std::size_t bound = decision.bound.size();
    std::string text = bound == 1 ? "Auto Bind: 1 bone bound" : "Auto Bind: " + std::to_string(bound) + " bones bound";
    if (decision.yielded.empty()) return text + ". Paint them with Auto-Weight, or by hand.";

    std::vector<std::string> names;
    for (const YieldedBone& y : decision.yielded) {
        if (const Bone* b = skeleton.bone(y.bone)) names.push_back(b->name);
    }
    std::set<std::string> owners;
    for (const YieldedBone& y : decision.yielded) {
        auto row = std::find_if(hierarchyItems.begin(), hierarchyItems.end(),
                                [&](const HierarchyItem& h) { return h.id == y.to; });
        if (row != hierarchyItems.end()) {
            owners.insert(row->name);
        } else if (const SceneImage* img = image(y.to)) {
            owners.insert(img->name);
        }
    }
    std::string boneList;
    if (names.empty()) {
        const std::size_t n = decision.yielded.size();
        boneList = std::to_string(n) + " bone" + (n == 1 ? "" : "s");
    } else {
        for (std::size_t k = 0; k < names.size(); ++k) boneList += (k ? ", " : "") + names[k];
    }
    // `sorted()` on Swift strings: code-point order, which std::set gives.
    std::string ownerList;
    for (const std::string& o : owners) ownerList += (ownerList.empty() ? "" : ", ") + o;
    text += ", and left " + boneList + " to ";
    text += ownerList.empty() ? "an overlapping image" : ownerList;
    return text + " — more of the bone lies there, and this image already has a closer one.";
}

// Replaces the bindings (a stale manual bind would survive as exactly the
// kind of foreign bone this removes), captures every inverse-bind matrix at
// the current pose, and does NOT paint: painting already done is kept,
// minus any bone no longer bound -- a weight naming a bone with no bind
// matrix would skin as the identity.
int EditorScene::autoBindImage(Uuid imageID, Vec2 assetSize, int maxInfluences) {
    (void)maxInfluences; // accepted, and unused in Swift too: no weights are computed.
    const auto i = imageIndex(imageID);
    if (!i.has_value()) return 0;
    const AutoBindDecision decision = autoBindDecision(imageID);
    if (decision.bound.empty()) {
        meshEditNotice = MeshEditNotice{
            "Auto Bind found no bone over this image. Move a bone onto it, or bind one by hand in Binding ▸ Bind "
            "Bones.",
            true};
        return 0;
    }
    pushUndoState();
    Mesh mesh = images[*i].mesh;
    if (mesh.isQuadCompatible()) mesh = mesh.generated(assetSize);
    const MeshBindPose pose = meshPose(images[*i]);
    const WorldMatrices world = skeleton.worldMatrices();
    mesh.bindVertices = mesh.vertices;
    mesh.bindImagePose = pose;
    mesh.boneInverseBindMatrices.clear();
    for (Uuid boneID : decision.bound) {
        auto it = world.find(boneID);
        if (it != world.end()) mesh.boneInverseBindMatrices[boneID] = inverse(it->second);
    }
    if (mesh.vertexBoneWeights.size() != mesh.vertices.size()) {
        mesh.vertexBoneWeights.assign(mesh.vertices.size(), {});
    } else {
        for (auto& influences : mesh.vertexBoneWeights) {
            influences.erase(std::remove_if(influences.begin(), influences.end(),
                                            [&](const VertexBoneWeight& w) {
                                                return !mesh.boneInverseBindMatrices.contains(w.boneID);
                                            }),
                             influences.end());
        }
    }
    images[*i].mesh = mesh;
    meshShowDeformed = true;
    meshEditNotice = MeshEditNotice{autoBindSummary(decision), false};
    refreshBoneBindingColors();
    return static_cast<int>(mesh.boneInverseBindMatrices.size());
}

void EditorScene::autoBindSelectedImage(Vec2 assetSize, int maxInfluences) {
    if (selectedImageID.has_value()) autoBindImage(*selectedImageID, assetSize, maxInfluences);
}

} // namespace umeshcore
