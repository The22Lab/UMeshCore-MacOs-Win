// Tests for CanvasPicking.h, ported from `Core/CanvasPicking.swift`'s
// `target()` arbitration. Expected values are hand-derived from that
// function's documented rule ("a hit ON something beats a hit NEAR
// something ... ties are broken by what is drawn in front" -> bone wins
// ties), not from this port's own output. The image hit-test itself is
// stubbed via a callback (see CanvasPicking.h's file header for why).

#include "umeshcore/Editor/CanvasPicking.h"
#include "TestHarness.h"

using namespace umeshcore;

static Bone makeBone(Vec2 start, Vec2 end) {
    return Bone::makeRoot("bone", start, end);
}

static ImageHitTestFn stubImageHit(std::optional<ImageHit> result) {
    return [result](const Vec2&, const Vec2&, CameraState*) { return result; };
}

static void testNeitherHitReturnsNullopt() {
    Skeleton skeleton;
    const auto result = target(
        Vec2(500, 500), Vec2(1000, 1000), skeleton, std::nullopt, nullptr, 1.0f, false, stubImageHit(std::nullopt));
    UM_CHECK(!result.has_value());
}

static void testBoneOnlyHitReturnsBone() {
    Skeleton skeleton;
    Bone bone = makeBone(Vec2(0, 0), Vec2(10, 0));
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);

    const Vec2 viewSize(1000, 1000);
    const Vec2 centerScreen = viewSize * 0.5f; // World (0,0) with no camera.
    const auto result =
        target(centerScreen, viewSize, skeleton, std::nullopt, nullptr, 1.0f, false, stubImageHit(std::nullopt));
    UM_CHECK(result.has_value());
    UM_CHECK(result->kind == SelectionTarget::Kind::Bone);
    UM_CHECK(result->id == bone.id);
}

static void testImageOnlyHitReturnsImage() {
    Skeleton skeleton; // No bones at all.
    const Uuid imageID = Uuid::generate();
    const auto result = target(
        Vec2(500, 500), Vec2(1000, 1000), skeleton, std::nullopt, nullptr, 1.0f, false,
        stubImageHit(ImageHit{imageID, /*isDirect=*/true, 0.0f}));
    UM_CHECK(result.has_value());
    UM_CHECK(result->kind == SelectionTarget::Kind::Image);
    UM_CHECK(result->id == imageID);
}

static void testBothHitBoneDirectBeatsImage() {
    Skeleton skeleton;
    Bone bone = makeBone(Vec2(0, 0), Vec2(10, 0));
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);
    const Vec2 viewSize(1000, 1000);
    const Vec2 centerScreen = viewSize * 0.5f;
    const Uuid imageID = Uuid::generate();

    const auto result = target(
        centerScreen, viewSize, skeleton, std::nullopt, nullptr, /*hitScale=*/1.0f, false,
        stubImageHit(ImageHit{imageID, /*isDirect=*/true, 0.0f}));
    UM_CHECK(result.has_value());
    UM_CHECK(result->kind == SelectionTarget::Kind::Bone);
}

static void testBothHitImageDirectBoneOnlyNearWinsToImage() {
    // A click ~20pt from the bone joint: within the bone's capture radius
    // (so hitTestBoneDetailed reports a hit) but well outside its
    // boneDirectRadius (6 * hitScale = 6pt), so this is a near miss on the
    // bone. A DIRECT image hit must win.
    Skeleton skeleton;
    Bone bone = makeBone(Vec2(0, 0), Vec2(10, 0));
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);
    const Vec2 viewSize(1000, 1000);
    const Vec2 centerScreen = viewSize * 0.5f;
    const Vec2 nearJoint = centerScreen + Vec2(20.0f, 0.0f);
    const Uuid imageID = Uuid::generate();

    const auto result = target(
        nearJoint, viewSize, skeleton, std::nullopt, nullptr, /*hitScale=*/1.0f, false,
        stubImageHit(ImageHit{imageID, /*isDirect=*/true, 0.0f}));
    UM_CHECK(result.has_value());
    UM_CHECK(result->kind == SelectionTarget::Kind::Image);
    UM_CHECK(result->id == imageID);
}

static void testBothHitNeitherDirectTieGoesToBone() {
    Skeleton skeleton;
    Bone bone = makeBone(Vec2(0, 0), Vec2(10, 0));
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);
    const Vec2 viewSize(1000, 1000);
    const Vec2 centerScreen = viewSize * 0.5f;
    const Vec2 nearJoint = centerScreen + Vec2(20.0f, 0.0f);
    const Uuid imageID = Uuid::generate();

    // Image hit exists but is NOT direct (a near-miss slop match).
    const auto result = target(
        nearJoint, viewSize, skeleton, std::nullopt, nullptr, 1.0f, false,
        stubImageHit(ImageHit{imageID, /*isDirect=*/false, 15.0f}));
    UM_CHECK(result.has_value());
    UM_CHECK(result->kind == SelectionTarget::Kind::Bone);
}

UM_TEST_MAIN_BEGIN()
    testNeitherHitReturnsNullopt();
    testBoneOnlyHitReturnsBone();
    testImageOnlyHitReturnsImage();
    testBothHitBoneDirectBeatsImage();
    testBothHitImageDirectBoneOnlyNearWinsToImage();
    testBothHitNeitherDirectTieGoesToBone();
UM_TEST_MAIN_END()
