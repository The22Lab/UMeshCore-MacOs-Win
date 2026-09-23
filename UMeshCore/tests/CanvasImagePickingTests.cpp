// Tests for alpha picking (Phase 6a A6d: `CanvasPicking.imageHit` and
// `AssetManager`'s alpha lookups, over an `AssetAlphaStore`). Every sprite
// is 100 x 100 at the origin and the camera is absent, so screen = world +
// half the 400 x 400 view: local (x, y) is screen (200 + x, 200 + y), and
// uv (u, v) is local (100u - 50, 50 - 100v).

#include "umeshcore/Editor/CanvasImagePicking.h"
#include "umeshcore/Editor/EditorScene.h"

#include "TestHarness.h"

using namespace umeshcore;
using namespace umeshcore::CanvasImagePicking;

namespace {

const Vec2 kView(400, 400);
const Vec2 kSize(100, 100);

// A 10 x 10 mask, opaque where `opaque(x, y)`.
template <typename F>
AlphaMask maskWhere(F opaque) {
    AlphaMask m(10, 10);
    for (int y = 0; y < 10; ++y)
        for (int x = 0; x < 10; ++x) m.set(x, y, opaque(x, y) ? 1.0f : 0.0f);
    return m;
}

// Distinct names: sprites sharing a name are one slot's variants, and the
// skin shows only one of them.
Uuid spriteWithMask(EditorScene& scene, AssetAlphaStore& store, AlphaMask mask) {
    static int serial = 0;
    const Uuid asset = Uuid::generate();
    store.set(asset, kSize, std::move(mask));
    return scene.addImage(asset, "s" + std::to_string(++serial), kSize, Vec2(0, 0), std::nullopt);
}

Vec2 screenOfLocal(float x, float y) { return Vec2(200 + x, 200 + y); }

} // namespace

static void testTheMaskAnswersAsAssetManagerDoes() {
    const AlphaMask empty;
    UM_CHECK(empty.alphaAtUV(0.3f, 0.3f) == 1.0f); // unloaded art reads opaque, as Swift
    const AlphaMask m = maskWhere([](int x, int y) { return x >= 2 && x <= 4 && y >= 3 && y <= 5; });
    UM_CHECK(m.alphaAtUV(0.35f, 0.45f) == 1.0f); // texel (3, 4)
    UM_CHECK(m.alphaAtUV(0.95f, 0.95f) == 0.0f);
    // Opaque texels x 2..4, y 3..5, with half a texel of margin.
    const auto b = m.opaqueBoundsUV();
    UM_CHECK(b.has_value());
    UM_CHECK_NEAR((*b)[0], 0.15, 1e-6);
    UM_CHECK_NEAR((*b)[1], 0.25, 1e-6);
    UM_CHECK_NEAR((*b)[2], 0.55, 1e-6); // (4 + 1.5) / 10
    UM_CHECK_NEAR((*b)[3], 0.65, 1e-6); // (5 + 1.5) / 10
    UM_CHECK(!maskWhere([](int, int) { return false; }).opaqueBoundsUV().has_value());
    // The byte cutoff: 12/255 is not opaque, 13/255 is -- the same texels the
    // 0.05 picking threshold accepts.
    AlphaMask edge(1, 1);
    edge.set(0, 0, 12.0f / 255.0f);
    UM_CHECK(!edge.opaqueBoundsUV().has_value());
    edge.set(0, 0, 13.0f / 255.0f);
    UM_CHECK(edge.opaqueBoundsUV().has_value());
}

// Only the left half is art: a click there is a direct hit, a click on the
// right half goes straight through.
static void testAClickOnATransparentTexelGoesThrough() {
    EditorScene scene;
    AssetAlphaStore store;
    const Uuid id = spriteWithMask(scene, store, maskWhere([](int x, int) { return x < 5; }));
    const auto left = imageHit(screenOfLocal(-30, 0), kView, scene, store, nullptr, 1.0f);
    UM_CHECK(left.has_value() && left->id == id && left->isDirect && left->distance == 0.0f);
    UM_CHECK(!imageHit(screenOfLocal(30, 0), kView, scene, store, nullptr, 1.0f).has_value());
}

// Through a transparent front sprite to the opaque one behind it.
static void testTheFrontMostOpaqueTexelWins() {
    EditorScene scene;
    AssetAlphaStore store;
    const Uuid back = spriteWithMask(scene, store, maskWhere([](int, int) { return true; }));
    const Uuid front = spriteWithMask(scene, store, maskWhere([](int x, int) { return x < 5; }));
    UM_CHECK(scene.renderOrderedImages().front().id == front); // newest is in front
    UM_CHECK(imageHit(screenOfLocal(-30, 0), kView, scene, store, nullptr, 1.0f)->id == front);
    UM_CHECK(imageHit(screenOfLocal(30, 0), kView, scene, store, nullptr, 1.0f)->id == back);
    // Hidden: not a candidate.
    scene.image(front)->isHidden = true;
    UM_CHECK(imageHit(screenOfLocal(-30, 0), kView, scene, store, nullptr, 1.0f)->id == back);
}

// Reach hugs the ART, not the sheet: 5 units off an opaque edge is caught
// (not direct), 5 units off the transparent half's edge is 55 from any art.
static void testReachIsMeasuredFromTheArtNotTheSheet() {
    EditorScene scene;
    AssetAlphaStore store;
    const Uuid id = spriteWithMask(scene, store, maskWhere([](int x, int) { return x < 5; }));
    const auto nearArt = imageHit(screenOfLocal(-55, 0), kView, scene, store, nullptr, 1.0f);
    UM_CHECK(nearArt.has_value() && nearArt->id == id && !nearArt->isDirect);
    UM_CHECK_NEAR(nearArt->distance, 5.0, 1e-3);
    UM_CHECK(!imageHit(screenOfLocal(55, 0), kView, scene, store, nullptr, 1.0f).has_value());
    // Touch scale widens the reach.
    UM_CHECK(imageHit(screenOfLocal(-70, 0), kView, scene, store, nullptr, 2.0f).has_value());
    UM_CHECK(!imageHit(screenOfLocal(-70, 0), kView, scene, store, nullptr, 1.0f).has_value());
}

static void testSpritesWithoutArtAreNotPickable() {
    EditorScene scene;
    AssetAlphaStore store;
    spriteWithMask(scene, store, maskWhere([](int, int) { return false; })); // transparent everywhere
    scene.addImage(Uuid::generate(), "unloaded", kSize, Vec2(0, 0), std::nullopt); // not in the store
    UM_CHECK(!imageHit(screenOfLocal(0, 0), kView, scene, store, nullptr, 1.0f).has_value());
}

// Through the arbitration: an opaque texel under the cursor beats a bone
// that is merely near; a bone ON the cursor beats the texel.
static void testAHitOnArtBeatsABoneNearIt() {
    EditorScene scene;
    AssetAlphaStore store;
    const Uuid id = spriteWithMask(scene, store, maskWhere([](int, int) { return true; }));
    const Uuid bone = scene.addBone(Vec2(0, 20), Vec2(40, 20));
    const ImageHitTestFn fn = makeImageHitTest(scene, store, 1.0f);
    // 10 units below the bone: near, not on it.
    const auto t = target(screenOfLocal(20, 10), kView, scene.skeleton, std::nullopt, nullptr, 1.0f, false, fn);
    UM_CHECK(t.has_value() && t->kind == SelectionTarget::Kind::Image && t->id == id);
    const auto onBone = target(screenOfLocal(20, 20), kView, scene.skeleton, std::nullopt, nullptr, 1.0f, false, fn);
    UM_CHECK(onBone.has_value() && onBone->kind == SelectionTarget::Kind::Bone && onBone->id == bone);
}

UM_TEST_MAIN_BEGIN()
    testTheMaskAnswersAsAssetManagerDoes();
    testAClickOnATransparentTexelGoesThrough();
    testTheFrontMostOpaqueTexelWins();
    testReachIsMeasuredFromTheArtNotTheSheet();
    testSpritesWithoutArtAreNotPickable();
    testAHitOnArtBeatsABoneNearIt();
UM_TEST_MAIN_END()
