// Tests for EditorScene's Mesh-mode operations (Phase 6a A6b): outline
// tracing, vertex edits in Editor vs Animator, deform data carried across
// topology changes, the weight brush, binding colours and Auto Bind.

#include "umeshcore/Editor/EditorScene.h"

#include <algorithm>

#include "TestHarness.h"

using namespace umeshcore;

namespace {

Uuid sprite(EditorScene& scene, const std::string& name, Vec2 size, Vec2 position) {
    return scene.addImage(Uuid::generate(), name, size, position, std::nullopt);
}

Uuid namedBone(EditorScene& scene, const std::string& name, Vec2 start, Vec2 end) {
    const Uuid id = scene.addBone(start, end);
    Bone b = *scene.skeleton.bone(id);
    b.name = name;
    scene.skeleton.setBone(b);
    return id;
}

// A sprite whose mesh has a centre point, so it has an interior vertex.
Uuid meshedSprite(EditorScene& scene) {
    const Uuid id = sprite(scene, "S", Vec2(100, 100), Vec2(0, 0));
    scene.selectMeshLayer(id);
    scene.insertMeshInteriorVertex(id, Vec2(0, 0), Vec2(100, 100));
    scene.endInteraction();
    return id;
}

} // namespace

// ---- Outline tracing -------------------------------------------------------------

static void testATracedOutlineIsOpenUntilClosed() {
    EditorScene scene;
    const Uuid id = sprite(scene, "S", Vec2(100, 100), Vec2(0, 0));
    scene.selectMeshLayer(id);
    scene.beginNewMesh();
    UM_CHECK(scene.isMeshCreatingHull && scene.image(id)->mesh.vertices.empty());
    scene.appendMeshHullVertex(id, Vec2(-40, -40), Vec2(100, 100));
    scene.appendMeshHullVertex(id, Vec2(40, -40), Vec2(100, 100));
    // Two points are not a shape: closing refuses, and says so.
    scene.finishNewMesh();
    UM_CHECK(scene.meshEditNotice.has_value() && scene.meshEditNotice->isWarning);
    scene.meshEditNotice = std::nullopt;
    scene.isMeshCreatingHull = true;
    scene.appendMeshHullVertex(id, Vec2(0, 40), Vec2(100, 100));
    // Still open: a polyline being traced has no interior yet.
    UM_CHECK(scene.image(id)->mesh.indices.empty());
    scene.finishNewMesh();
    UM_CHECK(scene.image(id)->mesh.indices.size() == 3);
    UM_CHECK(!scene.meshEditNotice.has_value());
}

// ---- Vertex edits ----------------------------------------------------------------------

static void testAVertexDragMovesTheRestMeshInEditorAndTheDeformInAnimator() {
    EditorScene scene;
    const Uuid id = meshedSprite(scene);
    scene.updateMeshVertex(id, 4, Vec2(10, 5));
    UM_CHECK(scene.image(id)->mesh.vertices[4] == Vec2(10, 5));
    UM_CHECK(!scene.image(id)->meshAnimationDeform.has_value());
    // Pulled outside the outline, an interior vertex stops on it.
    scene.updateMeshVertex(id, 4, Vec2(90, 5));
    UM_CHECK(scene.image(id)->mesh.vertices[4] == Vec2(50, 5));

    scene.setAnimationEditingEnabled(true);
    scene.updateMeshVertex(id, 4, Vec2(-5, -5));
    UM_CHECK(scene.image(id)->mesh.vertices[4] == Vec2(50, 5)); // rest untouched
    UM_CHECK(scene.image(id)->meshAnimationDeform.has_value());
    UM_CHECK((*scene.image(id)->meshAnimationDeform)[4] == Vec2(-5, -5));
    // Keying it leaves the new key selected, as Swift.
    const auto key = scene.commitMeshDeformKeyframe(id);
    UM_CHECK(key.has_value() && scene.selectedKeyframe == key);
}

// Deleting a vertex rewrites every deform key through the remap; the
// survivors keep THEIR values, and the array is exactly the new length.
static void testDeletingAVertexKeepsEveryDeformKeyOnItsVertices() {
    EditorScene scene;
    const Uuid id = meshedSprite(scene);
    SceneImage& img = *scene.image(id);
    std::vector<Vec2> deform = img.mesh.vertices;
    for (std::size_t k = 0; k < deform.size(); ++k) deform[k] = Vec2(static_cast<float>(k), 100.0f);
    img.animationClip.upsertKeyframe(id, AnimationTrackProperty::MeshDeform, 0, MeshDeformValue{deform});

    // The quad's corners are 0..3 and the centre is 4; delete the centre.
    scene.selectMeshVertices({4});
    scene.deleteSelectedMeshVertices();
    const auto& keys = scene.image(id)->animationClip.keyframesFor(id, AnimationTrackProperty::MeshDeform);
    const auto* value = std::get_if<MeshDeformValue>(&keys[0].value);
    UM_CHECK(value != nullptr && value->value.size() == 4);
    for (std::size_t k = 0; k < 4; ++k) UM_CHECK(value->value[k] == Vec2(static_cast<float>(k), 100.0f));
    UM_CHECK(scene.selectedMeshVertexIndices.empty());
    // One undo step puts the vertex back.
    scene.undo();
    UM_CHECK(scene.image(id)->mesh.vertices.size() == 5);
}

// Inserting into an animated mesh gives the new vertex the deform of the
// triangle it landed in: under a uniform shift, exactly the same shift.
static void testInsertingIntoAnAnimatedMeshKeepsTheSilhouette() {
    EditorScene scene;
    const Uuid id = meshedSprite(scene);
    SceneImage& img = *scene.image(id);
    std::vector<Vec2> shifted = img.mesh.vertices;
    for (Vec2& v : shifted) v = v + Vec2(10, -4);
    img.animationClip.upsertKeyframe(id, AnimationTrackProperty::MeshDeform, 0, MeshDeformValue{shifted});
    img.meshAnimationDeform = shifted;

    const std::optional<int> inserted = scene.insertMeshInteriorVertex(id, Vec2(20, 20), Vec2(100, 100));
    UM_CHECK(inserted == std::optional<int>(5));
    const SceneImage& after = *scene.image(id);
    UM_CHECK_NEAR((*after.meshAnimationDeform)[5].x, 30.0, 1e-4);
    UM_CHECK_NEAR((*after.meshAnimationDeform)[5].y, 16.0, 1e-4);
    const auto* key =
        std::get_if<MeshDeformValue>(&after.animationClip.keyframesFor(id, AnimationTrackProperty::MeshDeform)[0].value);
    UM_CHECK(key != nullptr && key->value.size() == 6);
    UM_CHECK_NEAR(key->value[5].x, 30.0, 1e-4);
    // Outside the outline: refused, with the reason.
    UM_CHECK(!scene.insertMeshInteriorVertex(id, Vec2(200, 0), Vec2(100, 100)).has_value());
    UM_CHECK(scene.meshEditNotice.has_value() && scene.meshEditNotice->isWarning);
}

// ---- Weights and colours --------------------------------------------------------------------

static void testTheBrushAddsTheBoneAndTheOthersGiveWay() {
    EditorScene scene;
    const Uuid a = namedBone(scene, "a", Vec2(0, 0), Vec2(10, 0));
    const Uuid b = namedBone(scene, "b", Vec2(0, 0), Vec2(0, 10));
    const Uuid id = meshedSprite(scene);
    scene.bindBoneToImage(id, a, Vec2(100, 100), 4);
    scene.bindBoneToImage(id, b, Vec2(100, 100), 4);
    std::vector<std::vector<VertexBoneWeight>> w(scene.image(id)->mesh.vertices.size(), {VertexBoneWeight{a, 1.0f}});
    scene.restoreMeshWeights(id, w);

    // One stamp on the centre vertex: distance 0, so factor = strength.
    // 0 + (1 - 0) * 0.5 = 0.5 for b; a scales by (1 - 0.5) / 1.
    scene.paintMeshWeights(id, b, Vec2(100, 100), Vec2(0, 0), EditorScene::MeshWeightPaintMode::Add, 5.0f, 0.5f,
                           1.0f);
    const auto& centre = scene.image(id)->mesh.vertexBoneWeights[4];
    UM_CHECK(centre.size() == 2);
    for (const VertexBoneWeight& vw : centre) UM_CHECK_NEAR(vw.weight, 0.5, 1e-6);
    // A corner, 70 units away, is outside the 5-unit brush.
    UM_CHECK(scene.image(id)->mesh.vertexBoneWeights[0].size() == 1);
}

static void testABoundBoneHasAColourUntilItIsUnbound() {
    EditorScene scene;
    const Uuid a = namedBone(scene, "a", Vec2(0, 0), Vec2(10, 0));
    const Uuid id = meshedSprite(scene);
    UM_CHECK(!scene.skeleton.bone(a)->color.has_value());
    scene.bindBoneToImage(id, a, Vec2(100, 100), 4);
    UM_CHECK(scene.skeleton.bone(a)->color.has_value());
    UM_CHECK(scene.boundBoneIDs(id) == std::vector<Uuid>{a});
    // Clearing the paint keeps the bind, and so the colour.
    scene.clearMeshWeights(id);
    UM_CHECK(scene.skeleton.bone(a)->color.has_value());
    scene.unbindBoneFromImage(id, a, 4);
    UM_CHECK(!scene.skeleton.bone(a)->color.has_value());
    UM_CHECK(scene.boundBoneIDs(id).empty());
}

static void testAutoWeightRefusesAnUnboundSprite() {
    EditorScene scene;
    namedBone(scene, "a", Vec2(0, 0), Vec2(10, 0));
    const Uuid id = meshedSprite(scene);
    const bool couldUndo = scene.undoRedo.canUndo();
    scene.autoWeightMesh(id, 4);
    UM_CHECK(scene.meshEditNotice.has_value() && scene.meshEditNotice->isWarning);
    UM_CHECK(scene.undoRedo.canUndo() == couldUndo); // refused: nothing pushed
}

// ---- Auto Bind -------------------------------------------------------------------------------

// The Swift comment's own scene, built to its numbers: a spine 230 long
// runs through a torso (200 inside) and a belt (20 inside), and dips into
// an arm (20 inside) that already has its own bone.
//   belt: keeps the spine -- dominated by the torso, but it has nothing
//         better, so it is not OUTCLASSED;
//   arm:  yields the spine to the torso -- dominated AND outclassed by the
//         upper arm, which lies wholly inside it.
static void testAutoBindTakesABoneAwayOnlyWhenBothSidesAgree() {
    EditorScene scene;
    const Uuid torso = sprite(scene, "torso", Vec2(100, 200), Vec2(0, 100));
    const Uuid belt = sprite(scene, "belt", Vec2(100, 20), Vec2(0, -10));
    const Uuid arm = sprite(scene, "arm", Vec2(130, 20), Vec2(55, 160));
    const Uuid spine = namedBone(scene, "spine", Vec2(0, -30), Vec2(0, 200));
    const Uuid upperArm = namedBone(scene, "upperArm", Vec2(25, 160), Vec2(115, 160));

    const auto beltDecision = scene.autoBindDecision(belt);
    UM_CHECK(beltDecision.bound == std::vector<Uuid>{spine});
    UM_CHECK(beltDecision.yielded.empty());

    const auto armDecision = scene.autoBindDecision(arm);
    UM_CHECK(armDecision.bound == std::vector<Uuid>{upperArm});
    UM_CHECK(armDecision.yielded.size() == 1);
    UM_CHECK(armDecision.yielded[0].bone == spine && armDecision.yielded[0].to == torso);

    // Binding says what it left, and to whom.
    UM_CHECK(scene.autoBindImage(arm, Vec2(130, 20), 4) == 1);
    UM_CHECK(scene.meshEditNotice.has_value() && !scene.meshEditNotice->isWarning);
    UM_CHECK(scene.meshEditNotice->text.find("left spine to torso") != std::string::npos);
    UM_CHECK(scene.boundBoneIDs(arm) == std::vector<Uuid>{upperArm});
    UM_CHECK(scene.meshShowDeformed);

    // Nothing over a sprite: refused, nothing changed.
    const Uuid lonely = sprite(scene, "lonely", Vec2(10, 10), Vec2(900, 900));
    UM_CHECK(scene.autoBindImage(lonely, Vec2(10, 10), 4) == 0);
    UM_CHECK(scene.meshEditNotice->isWarning);
}

UM_TEST_MAIN_BEGIN()
    testATracedOutlineIsOpenUntilClosed();
    testAVertexDragMovesTheRestMeshInEditorAndTheDeformInAnimator();
    testDeletingAVertexKeepsEveryDeformKeyOnItsVertices();
    testInsertingIntoAnAnimatedMeshKeepsTheSilhouette();
    testTheBrushAddsTheBoneAndTheOthersGiveWay();
    testABoundBoneHasAColourUntilItIsUnbound();
    testAutoWeightRefusesAnUnboundSprite();
    testAutoBindTakesABoneAwayOnlyWhenBothSidesAgree();
UM_TEST_MAIN_END()
