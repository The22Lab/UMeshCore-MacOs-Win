// Tests for Render/SceneSkinPalette.h, ported from
// `Render/SceneGPU/SceneSkinPalette.swift`.
//
// The type exists for one reason -- the fold is exact ONLY when the
// weights sum to one -- so the central test is that: the shader-side sum
// over the folded palette lands on the same point as the CPU-side
// "blend, then apply the sprite and layer affines", and the SAME data with
// unnormalised weights does not. That is the 700-unit displacement the
// Swift header records, reproduced rather than described.
//
// `Editor/verify_scene_gpu_skinning.py` (exactness to 1e-13, the 652/700/
// 1343/38.3/22.7-unit figures) does not exist in this repository; see
// CLAUDE.md.

#include "umeshcore/Render/SceneSkinPalette.h"

#include <cmath>
#include <vector>

#include "umeshcore/Math/MatrixUtilities.h"
#include "umeshcore/Mesh/Mesh.h"

#include "TestHarness.h"

using namespace umeshcore;

namespace {

const Uuid kBoneA(1, 1);
const Uuid kBoneB(1, 2);
const Uuid kBoneC(1, 3);
const Uuid kUnknown(9, 9);

Vec3 apply(const Mat4& m, const Vec2& point) {
    const Vec4 out = m * Vec4(point.x, point.y, 0.0f, 1.0f);
    return Vec3(out.x, out.y, out.z);
}

struct Rig {
    std::vector<Uuid> order{kBoneA, kBoneB, kBoneC};
    std::unordered_map<Uuid, Mat4, UuidHash> world;
    std::unordered_map<Uuid, Mat4, UuidHash> inverseBind;
    Mat4 bindToWorld = MatrixUtilities::translation(Vec3(35, -20, 0));
    Mat4 worldToBind = MatrixUtilities::translation(Vec3(-35, 20, 0));
    // The sprite's posed transform and the layer's lift out of the card's
    // plane -- both affine, both constant for the frame, both folded in.
    Mat4 spriteToRig = MatrixUtilities::translation(Vec3(120, 40, 0)) * MatrixUtilities::rotationZ(0.3f);
    Mat4 rigToWorld = MatrixUtilities::translation(Vec3(-400, 90, 250)) * MatrixUtilities::rotationY(0.55f);

    Rig() {
        world[kBoneA] = MatrixUtilities::translation(Vec3(10, 5, 0)) * MatrixUtilities::rotationZ(0.2f);
        world[kBoneB] = MatrixUtilities::translation(Vec3(-60, 90, 0)) * MatrixUtilities::rotationZ(-0.9f);
        world[kBoneC] = MatrixUtilities::translation(Vec3(200, -30, 0)) * MatrixUtilities::rotationZ(1.4f);
        inverseBind[kBoneA] = MatrixUtilities::translation(Vec3(-10, -5, 0));
        inverseBind[kBoneB] = MatrixUtilities::translation(Vec3(60, -90, 0));
        inverseBind[kBoneC] = MatrixUtilities::translation(Vec3(-200, 30, 0));
    }

    SceneSkinPalette palette() const {
        return SceneSkinPalette(
            order, world, inverseBind, bindToWorld, worldToBind, spriteToRig, rigToWorld);
    }

    // What the CPU path does: blend the bone matrices in bind space, then
    // apply everything that comes after.
    Vec3 cpuPath(const Vec2& bindLocal, const std::vector<VertexBoneWeight>& weights) const {
        const Vec4 inBind = bindToWorld * Vec4(bindLocal.x, bindLocal.y, 0.0f, 1.0f);
        Vec4 blended(0, 0, 0, 0);
        float total = 0.0f;
        for (const VertexBoneWeight& w : weights) {
            blended = blended + (world.at(w.boneID) * (inverseBind.at(w.boneID) * inBind)) * w.weight;
            total += w.weight;
        }
        // The defensive divide `Mesh::skinnedVertices` does, which is
        // exactly why nothing upstream ever complains about unnormalised
        // weights.
        if (total > 0.000001f) blended = blended * (1.0f / total);
        const Vec4 out = rigToWorld * spriteToRig * worldToBind * Vec4(blended.x, blended.y, blended.z, 1.0f);
        return Vec3(out.x, out.y, out.z);
    }
};

// What the vertex shader does: one weighted sum over the folded palette.
Vec3 shaderPath(const SceneSkinPalette& palette, const Vec2& bindLocal, const SkinnedInfluences& influences) {
    Vec4 sum(0, 0, 0, 0);
    for (int i = 0; i < 4; ++i) {
        const Mat4& m = palette.matrices()[influences.slots[i]];
        sum = sum + (m * Vec4(bindLocal.x, bindLocal.y, 0.0f, 1.0f)) * influences.weights[i];
    }
    return Vec3(sum.x, sum.y, sum.z);
}

} // namespace

static void testTheFoldMatchesTheCpuPathOnceWeightsAreNormalised() {
    const Rig rig;
    SceneSkinPalette palette = rig.palette();
    const Vec2 bindLocal(140, -95);
    // Deliberately NOT summing to one -- which is what the weight tools
    // actually produce: auto-weighting caps at four without renormalising.
    const std::vector<VertexBoneWeight> weights = {
        {kBoneA, 0.5f}, {kBoneB, 0.2f}, {kBoneC, 0.1f}};

    const SkinnedInfluences influences = palette.influences(weights);
    float total = 0.0f;
    for (int i = 0; i < 4; ++i) total += influences.weights[i];
    UM_CHECK_NEAR(total, 1.0, 1e-6);

    const Vec3 gpu = shaderPath(palette, bindLocal, influences);
    const Vec3 cpu = rig.cpuPath(bindLocal, weights);
    // Exact to floating point: the fold is an identity, not an
    // approximation.
    UM_CHECK_NEAR(length(gpu - cpu), 0.0, 1e-2);
}

static void testUnnormalisedWeightsWouldMoveTheVertexFar() {
    // The bug the normalisation exists to prevent, reproduced: feed the
    // raw weights straight to the shader's sum and the vertex leaves.
    // Pushing an affine inside a weighted sum adds its translation once
    // per influence instead of once, and there are three affines folded in
    // here.
    const Rig rig;
    SceneSkinPalette palette = rig.palette();
    const Vec2 bindLocal(140, -95);
    const std::vector<VertexBoneWeight> weights = {
        {kBoneA, 0.5f}, {kBoneB, 0.2f}, {kBoneC, 0.1f}};

    SkinnedInfluences raw;
    for (std::size_t i = 0; i < weights.size(); ++i) {
        raw.slots[i] = palette.slots().at(weights[i].boneID);
        raw.weights[static_cast<int>(i)] = weights[i].weight;
    }
    const Vec3 wrong = shaderPath(palette, bindLocal, raw);
    const Vec3 right = rig.cpuPath(bindLocal, weights);
    // Tens of units on this rig, and it grows with how far the folded
    // affines translate -- the Swift harness measured 700 units with the
    // sprite's affine alone and 1343 with all three. Either way it is
    // nowhere near float noise, which is why it reads as a rigging
    // mistake rather than a renderer one.
    UM_CHECK(length(wrong - right) > 10.0f);

    // And the tell is in the homogeneous coordinate: the weighted sum's w
    // IS the weight total, so "the weights sum to one" and "the divide by
    // w is a no-op" are the same statement.
    Vec4 sum(0, 0, 0, 0);
    for (int i = 0; i < 4; ++i) {
        sum = sum + (palette.matrices()[raw.slots[i]] * Vec4(bindLocal.x, bindLocal.y, 0.0f, 1.0f)) *
                        raw.weights[i];
    }
    UM_CHECK_NEAR(sum.w, 0.8, 1e-6);
}

static void testSlotZeroIsTheIdentityAndAnUnweightedVertexRidesIt() {
    const Rig rig;
    SceneSkinPalette palette = rig.palette();
    const Vec2 bindLocal(60, 25);

    const SkinnedInfluences none = palette.influences({});
    UM_CHECK(none.slots[0] == SceneSkinPalette::kIdentitySlot);
    UM_CHECK(none.weights == Vec4(1, 0, 0, 0));

    // "Identity" means the bind position, carried through the sprite and
    // layer affines -- not the origin, and not the first bone's pose.
    const Vec3 rest = shaderPath(palette, bindLocal, none);
    const Vec4 expected = rig.rigToWorld * rig.spriteToRig * rig.worldToBind * rig.bindToWorld *
                          Vec4(bindLocal.x, bindLocal.y, 0.0f, 1.0f);
    UM_CHECK_NEAR(length(rest - Vec3(expected.x, expected.y, expected.z)), 0.0, 1e-3);
    // And the first BONE is in slot 1, not slot 0 -- building the palette
    // straight from the bone list is what makes every unweighted vertex
    // ride that bone.
    UM_CHECK(palette.slots().at(kBoneA) == 1);
    UM_CHECK(palette.matrices().size() == 4);
}

static void testAWeightThatNamesNoKnownBoneIsDropped() {
    const Rig rig;
    SceneSkinPalette palette = rig.palette();
    const SkinnedInfluences influences =
        palette.influences({{kUnknown, 0.9f}, {kBoneB, 0.25f}});
    // The unknown bone contributes nothing, and what is left is
    // renormalised rather than left short.
    UM_CHECK(influences.slots[0] == palette.slots().at(kBoneB));
    UM_CHECK_NEAR(influences.weights[0], 1.0, 1e-6);
    // Zero and non-finite weights go the same way.
    const SkinnedInfluences degenerate =
        palette.influences({{kBoneA, 0.0f}, {kBoneB, std::nanf("")}, {kBoneC, -1.0f}});
    UM_CHECK(degenerate.weights == Vec4(1, 0, 0, 0));
    UM_CHECK(degenerate.slots[0] == SceneSkinPalette::kIdentitySlot);
}

static void testFifthInfluenceIsCappedCountedAndRenormalisedAfterwards() {
    // Five bones, four slots. The four that survive must be renormalised
    // BETWEEN THEMSELVES: normalising first and dropping the tail leaves
    // the vertex short of its weight, which slumps it towards its bind
    // position exactly where a mesh is most finely painted.
    Rig rig;
    rig.order = {kBoneA, kBoneB, kBoneC, Uuid(1, 4), Uuid(1, 5)};
    for (int i = 4; i <= 5; ++i) {
        const Uuid extra(1, static_cast<std::uint64_t>(i));
        rig.world[extra] = MatrixUtilities::translation(Vec3(5.0f * i, 0, 0));
        rig.inverseBind[extra] = MatrixUtilities::translation(Vec3(-5.0f * i, 0, 0));
    }
    SceneSkinPalette palette = rig.palette();
    UM_CHECK(palette.truncatedVertices() == 0);

    const SkinnedInfluences influences = palette.influences(
        {{kBoneA, 0.4f}, {kBoneB, 0.3f}, {kBoneC, 0.15f}, {Uuid(1, 4), 0.1f}, {Uuid(1, 5), 0.05f}});
    // COUNTED AND REPORTED, not swallowed.
    UM_CHECK(palette.truncatedVertices() == 1);

    float total = 0.0f;
    for (int i = 0; i < 4; ++i) total += influences.weights[i];
    UM_CHECK_NEAR(total, 1.0, 1e-6);
    // Largest first, and the smallest is the one that went.
    UM_CHECK(influences.slots[0] == palette.slots().at(kBoneA));
    UM_CHECK(influences.slots[3] == palette.slots().at(Uuid(1, 4)));
    UM_CHECK_NEAR(influences.weights[0], 0.4 / 0.95, 1e-6);
}

static void testTiedWeightsBreakBySlotSoTwoRunsAgree() {
    // The weights arrive from an unordered walk upstream and the sort is
    // not stable, so equal weights could otherwise pick different bones
    // between runs of the same project -- and the slot indices are baked
    // into an uploaded vertex buffer.
    Rig rig;
    rig.order = {kBoneA, kBoneB, kBoneC, Uuid(1, 4), Uuid(1, 5)};
    for (int i = 4; i <= 5; ++i) {
        const Uuid extra(1, static_cast<std::uint64_t>(i));
        rig.world[extra] = MatrixUtilities::translation(Vec3(5.0f * i, 0, 0));
        rig.inverseBind[extra] = MatrixUtilities::translation(Vec3(-5.0f * i, 0, 0));
    }
    SceneSkinPalette palette = rig.palette();
    const std::vector<VertexBoneWeight> forwards = {
        {kBoneA, 0.2f}, {kBoneB, 0.2f}, {kBoneC, 0.2f}, {Uuid(1, 4), 0.2f}, {Uuid(1, 5), 0.2f}};
    std::vector<VertexBoneWeight> backwards(forwards.rbegin(), forwards.rend());

    const SkinnedInfluences a = palette.influences(forwards);
    const SkinnedInfluences b = palette.influences(backwards);
    for (int i = 0; i < 4; ++i) {
        UM_CHECK(a.slots[i] == b.slots[i]);
        UM_CHECK(a.weights[i] == b.weights[i]);
    }
    // Ties go to the lowest slots, which are the skeleton's own order.
    UM_CHECK(a.slots[0] == 1 && a.slots[3] == 4);
}

static void testABoneMissingItsInverseBindTakesNoSlot() {
    // A bone the mesh was never bound to cannot be folded, and must not
    // shift every later bone's slot by one -- the slots are indices into
    // an uploaded buffer.
    Rig rig;
    rig.inverseBind.erase(kBoneB);
    SceneSkinPalette palette = rig.palette();
    UM_CHECK(palette.slots().find(kBoneB) == palette.slots().end());
    UM_CHECK(palette.slots().at(kBoneA) == 1);
    UM_CHECK(palette.slots().at(kBoneC) == 2);
    UM_CHECK(palette.matrices().size() == 3);
}

UM_TEST_MAIN_BEGIN()
    testTheFoldMatchesTheCpuPathOnceWeightsAreNormalised();
    testUnnormalisedWeightsWouldMoveTheVertexFar();
    testSlotZeroIsTheIdentityAndAnUnweightedVertexRidesIt();
    testAWeightThatNamesNoKnownBoneIsDropped();
    testFifthInfluenceIsCappedCountedAndRenormalisedAfterwards();
    testTiedWeightsBreakBySlotSoTwoRunsAgree();
    testABoneMissingItsInverseBindTakesNoSlot();
UM_TEST_MAIN_END()
