// Tests for the Mesh tool (Phase 6a A6d), driven the way a shell drives it:
// through ToolManager's store-taking overloads. No camera, so screen =
// world + (200, 200) in the 400 x 400 view; sprites are 100 x 100 and
// fully opaque unless a test says otherwise.

#include "umeshcore/Editor/EditorScene.h"
#include "umeshcore/Editor/ToolManager.h"

#include "TestHarness.h"

using namespace umeshcore;

namespace {

const Vec2 kView(400, 400);
const Vec2 kSize(100, 100);

struct Rig {
    EditorScene scene;
    AssetAlphaStore store;
    ToolManager tools;
    Vec2 pressWorld;
};

Uuid opaqueSprite(Rig& r, const std::string& name, Vec2 position) {
    AlphaMask m(10, 10);
    for (float& a : m.alpha) a = 1.0f;
    const Uuid asset = Uuid::generate();
    r.store.set(asset, kSize, m);
    return r.scene.addImage(asset, name, kSize, position, std::nullopt);
}

ToolInput at(Vec2 world, Vec2 startWorld, int clicks, bool dragging) {
    ToolInput in;
    in.position = world;
    in.startPosition = startWorld;
    in.screenPosition = world + Vec2(200, 200);
    in.startScreenPosition = startWorld + Vec2(200, 200);
    in.previousScreenPosition = in.screenPosition;
    in.viewSize = kView;
    in.clickCount = clicks;
    in.isDragging = dragging;
    return in;
}

void press(Rig& r, Vec2 world, int clicks = 1) {
    r.pressWorld = world;
    r.tools.handleMouseDown(at(world, world, clicks, false), r.scene, r.store, 1.0f, false);
}
void dragTo(Rig& r, Vec2 world) {
    r.tools.handleMouseDrag(at(world, r.pressWorld, 1, true), r.scene, r.store, 1.0f, false);
}
void release(Rig& r, Vec2 world) {
    r.tools.handleMouseUp(at(world, r.pressWorld, 1, false), r.scene, r.store, 1.0f, false);
}
void click(Rig& r, Vec2 world, int clicks = 1) {
    press(r, world, clicks);
    release(r, world);
}

// A sprite in Mesh mode, selected as a mesh layer, with a centre node (4).
Uuid meshMode(Rig& r) {
    const Uuid id = opaqueSprite(r, "body", Vec2(0, 0));
    r.tools.setTool(r.scene, ActiveTool::Mesh);
    r.scene.isMeshEditEnabled = true;
    r.scene.selectMeshLayer(id);
    r.scene.insertMeshInteriorVertex(id, Vec2(0, 0), kSize);
    r.scene.endInteraction();
    r.scene.selectMeshVertices({});
    return id;
}

std::size_t vertexCount(Rig& r, Uuid id) { return r.scene.image(id)->mesh.vertices.size(); }

} // namespace

// Create: a click places ONE node where it lands; a Pencil tap that wanders
// two points is still a click (it used to make two nodes and an edge); a
// real drag makes both ends and joins them.
static void testCreatePlacesANodeAndADragDrawsAnEdge() {
    Rig r;
    const Uuid id = meshMode(r);
    r.scene.meshEditToolMode = EditorScene::MeshEditToolMode::Create;
    click(r, Vec2(20, 20));
    UM_CHECK(vertexCount(r, id) == 6);
    UM_CHECK(r.scene.image(id)->mesh.vertices[5] == Vec2(20, 20));
    UM_CHECK(!r.scene.meshCreateEdgePreviewStart.has_value()); // the preview is cleared

    press(r, Vec2(-20, 20));
    dragTo(r, Vec2(-18, 20)); // 2 points: under the 6-point threshold
    release(r, Vec2(-18, 20));
    UM_CHECK(vertexCount(r, id) == 7);
    UM_CHECK(r.scene.image(id)->mesh.internalEdges.empty());

    press(r, Vec2(-25, -25));
    dragTo(r, Vec2(25, -25));
    release(r, Vec2(25, -25));
    UM_CHECK(vertexCount(r, id) == 9);
    UM_CHECK(r.scene.image(id)->mesh.internalEdges.size() == 1);
}

// A double click on another sprite switches to it -- and that click is
// SPENT on choosing: no node on either sprite.
static void testTheClickThatChoosesASpriteDoesNotEditIt() {
    Rig r;
    const Uuid b = meshMode(r);
    const Uuid a = opaqueSprite(r, "arm", Vec2(-150, 0));
    r.scene.selectMeshLayer(b);
    r.scene.meshEditToolMode = EditorScene::MeshEditToolMode::Create;
    click(r, Vec2(-150, 10), 2);
    UM_CHECK(r.scene.selectedImageID == std::optional<Uuid>(a));
    UM_CHECK(r.scene.isMeshLayerSelected);
    UM_CHECK(vertexCount(r, a) == 4 && vertexCount(r, b) == 5);
}

// Modify: in Editor a node drag moves the vertex AND its uv (the mesh is
// fitted to the art); in Animator it moves the vertex only (the art
// follows) and the release keys the deform.
static void testANodeDragFitsTheMeshInEditorAndDeformsInAnimator() {
    Rig r;
    const Uuid id = meshMode(r);
    press(r, Vec2(0, 0));
    dragTo(r, Vec2(10, 5));
    release(r, Vec2(10, 5));
    const Mesh& m = r.scene.image(id)->mesh;
    UM_CHECK(m.vertices[4] == Vec2(10, 5));
    UM_CHECK_NEAR(m.uvs[4].x, 0.6, 1e-6);  // 0.5 + 10 / 100
    UM_CHECK_NEAR(m.uvs[4].y, 0.45, 1e-6); // 0.5 - 5 / 100 (v runs down)

    r.scene.setAnimationEditingEnabled(true);
    r.scene.setCurrentFrame(8);
    press(r, Vec2(10, 5));
    dragTo(r, Vec2(-10, 5));
    release(r, Vec2(-10, 5));
    const SceneImage& img = *r.scene.image(id);
    UM_CHECK(img.mesh.vertices[4] == Vec2(10, 5)); // rest untouched
    UM_CHECK_NEAR(img.mesh.uvs[4].x, 0.6, 1e-6);   // uv untouched
    const auto& keys = img.animationClip.keyframesFor(id, AnimationTrackProperty::MeshDeform);
    UM_CHECK(keys.size() == 1 && keys[0].frame == 8);
    const auto* deform = std::get_if<MeshDeformValue>(&keys[0].value);
    UM_CHECK(deform != nullptr && deform->value[4] == Vec2(-10, 5));
}

static void testDeleteRemovesTheNodeUnderTheClick() {
    Rig r;
    const Uuid id = meshMode(r);
    r.scene.meshEditToolMode = EditorScene::MeshEditToolMode::Delete;
    click(r, Vec2(30, 30)); // no node there
    UM_CHECK(vertexCount(r, id) == 5);
    click(r, Vec2(1, 1));
    UM_CHECK(vertexCount(r, id) == 4);
}

// Weights: with no bone armed the brush is a pointer; with one armed, the
// first click of a double click on another bound bone paints -- and the
// second click, which arms that bone, TAKES THE STAMP BACK.
static void testArmingABoneByDoubleClickTakesBackTheFirstClicksStamp() {
    Rig r;
    const Uuid a = r.scene.addBone(Vec2(60, -40), Vec2(60, 40)); // off the sprite
    const Uuid b = r.scene.addBone(Vec2(-30, -30), Vec2(-30, 30));
    const Uuid id = meshMode(r);
    r.scene.bindBoneToImage(id, a, kSize, 4);
    r.scene.bindBoneToImage(id, b, kSize, 4);
    r.scene.meshWeightPaintEnabled = true;

    click(r, Vec2(0, 0)); // no colour: picks the node
    UM_CHECK(r.scene.selectedMeshVertexIndices == std::unordered_set<int>{4});
    r.scene.selectMeshVertices({});

    r.scene.activeWeightPaintBoneID = a;
    const auto before = r.scene.image(id)->mesh.vertexBoneWeights;
    click(r, Vec2(-30, 0), 1); // paints `a` around the click
    UM_CHECK(r.scene.image(id)->mesh.vertexBoneWeights != before);
    click(r, Vec2(-30, 0), 2); // arms `b`
    UM_CHECK(r.scene.activeWeightPaintBoneID == std::optional<Uuid>(b));
    UM_CHECK(r.scene.image(id)->mesh.vertexBoneWeights == before);
    UM_CHECK(r.scene.selectedImageID == std::optional<Uuid>(id)); // the sprite was never deselected
}

// Bind Mode: a click on a bone binds it, a second unbinds it, and neither
// touches the selection.
static void testBindModeTogglesTheBoneUnderTheClick() {
    Rig r;
    const Uuid bone = r.scene.addBone(Vec2(-30, -30), Vec2(-30, 30));
    const Uuid id = meshMode(r);
    r.scene.setBindingBonesMode(true);
    click(r, Vec2(-30, 0));
    UM_CHECK(r.scene.boundBoneIDs(id) == std::vector<Uuid>{bone});
    click(r, Vec2(-30, 0));
    UM_CHECK(r.scene.boundBoneIDs(id).empty());
    UM_CHECK(r.scene.selectedImageID == std::optional<Uuid>(id));
}

// Tracing: clicks add outline points; a click near the first closes it.
static void testTracingAnOutlineClosesOnTheFirstPoint() {
    Rig r;
    const Uuid id = meshMode(r);
    r.scene.beginNewMesh();
    for (Vec2 p : {Vec2(-40, -40), Vec2(40, -40), Vec2(0, 40)}) click(r, p);
    UM_CHECK(r.scene.isMeshCreatingHull);
    UM_CHECK(r.scene.image(id)->mesh.indices.empty());
    click(r, Vec2(-38, -38)); // within 12 of the first point
    UM_CHECK(!r.scene.isMeshCreatingHull);
    UM_CHECK(r.scene.image(id)->mesh.hullVertexIndices.size() == 3);
    UM_CHECK(r.scene.image(id)->mesh.indices.size() == 3);
}

// The sprite marquee: a band inside a sprite's art catches it (it holds no
// vertex); a band over empty canvas catches nothing.
static void testTheSpriteMarqueeCatchesArtNotEmptyCanvas() {
    Rig r;
    const Uuid a = opaqueSprite(r, "a", Vec2(-150, 0));
    opaqueSprite(r, "b", Vec2(0, 0));
    r.tools.setTool(r.scene, ActiveTool::Select);
    press(r, Vec2(-130, -10));
    dragTo(r, Vec2(-110, 10));
    UM_CHECK(r.scene.selectedImageIDs.size() == 1 && r.scene.selectedImageIDs.contains(a));
    release(r, Vec2(-110, 10));
    press(r, Vec2(-90, 60));
    dragTo(r, Vec2(-60, 90));
    UM_CHECK(r.scene.selectedImageIDs.empty());
}

UM_TEST_MAIN_BEGIN()
    testCreatePlacesANodeAndADragDrawsAnEdge();
    testTheClickThatChoosesASpriteDoesNotEditIt();
    testANodeDragFitsTheMeshInEditorAndDeformsInAnimator();
    testDeleteRemovesTheNodeUnderTheClick();
    testArmingABoneByDoubleClickTakesBackTheFirstClicksStamp();
    testBindModeTogglesTheBoneUnderTheClick();
    testTracingAnOutlineClosesOnTheFirstPoint();
    testTheSpriteMarqueeCatchesArtNotEmptyCanvas();
UM_TEST_MAIN_END()
