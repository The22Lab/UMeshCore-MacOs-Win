// Tests for Mesh.h, ported from `Data/Mesh.swift`'s core struct,
// sanitization, and linear-blend-skinning pipeline. Expected values are
// hand-derived from the skinning formula documented in Mesh.h
// (world = sum_i w_i * BoneNow_i * inverse(BoneBind_i) * bindPose(local)),
// not from this implementation's own output.

#include <cmath>

#include "umeshcore/Mesh/Mesh.h"
#include "umeshcore/Model/Skeleton.h"
#include "TestHarness.h"

using namespace umeshcore;

static Bone makeBone(std::optional<Uuid> parent, Vec2 localPos, float rotationZ, float length) {
    Bone b;
    b.id = Uuid::generate();
    b.name = "bone";
    b.parentID = parent;
    b.localTransform.position = Vec3(localPos.x, localPos.y, 0);
    b.localTransform.rotation = Vec3(0, 0, rotationZ);
    b.baseTransform = b.localTransform;
    b.length = length;
    b.animationClip = AnimationClip("bone");
    return b;
}

static void testMakeQuad() {
    const Mesh q = Mesh::makeQuad("sprite", Vec2(100, 50));
    UM_CHECK(q.vertices.size() == 4);
    UM_CHECK(q.uvs.size() == 4);
    UM_CHECK(q.indices.size() == 6);
    UM_CHECK(q.hullVertexIndices.size() == 4);
    UM_CHECK(q.isQuadCompatible());
    UM_CHECK_NEAR(q.vertices[0].x, -50.0, 1e-4);
    UM_CHECK_NEAR(q.vertices[0].y, 25.0, 1e-4);
}

static void testSanitizedForRenderEmptyFallsBackToQuad() {
    Mesh empty("empty");
    const Mesh sanitized = empty.sanitizedForRender(Vec2(64, 64));
    UM_CHECK(sanitized.isQuadCompatible());
}

static void testSanitizedSkinningDataNormalizesAndMergesWeights() {
    Mesh m("m");
    m.vertices = {Vec2(0, 0)};
    m.bindVertices = {Vec2(0, 0)};
    const Uuid boneA = Uuid::generate();
    const Uuid boneB = Uuid::generate();
    m.boneInverseBindMatrices[boneA] = Mat4::identity();
    m.boneInverseBindMatrices[boneB] = Mat4::identity();
    // Duplicate entries for boneA (2.0 + 1.0 = 3.0 after merge) and one for boneB (1.0).
    m.vertexBoneWeights = {{{boneA, 2.0f}, {boneA, 1.0f}, {boneB, 1.0f}}};

    const Mesh sanitized = m.sanitizedSkinningData();
    UM_CHECK(sanitized.vertexBoneWeights.size() == 1);
    const auto& influences = sanitized.vertexBoneWeights[0];
    UM_CHECK(influences.size() == 2);
    // Sorted descending by weight: boneA (merged to 3.0, normalized 0.75) first.
    UM_CHECK(influences[0].boneID == boneA);
    UM_CHECK_NEAR(influences[0].weight, 0.75, 1e-5);
    UM_CHECK(influences[1].boneID == boneB);
    UM_CHECK_NEAR(influences[1].weight, 0.25, 1e-5);
    float sum = 0.0f;
    for (const auto& inf : influences) sum += inf.weight;
    UM_CHECK_NEAR(sum, 1.0, 1e-5);
}

static void testSanitizedSkinningDataDropsUnboundBoneReferences() {
    Mesh m("m");
    m.vertices = {Vec2(0, 0)};
    m.bindVertices = {Vec2(0, 0)};
    const Uuid unknownBone = Uuid::generate();
    // No entry in boneInverseBindMatrices for unknownBone -> must be dropped.
    m.vertexBoneWeights = {{{unknownBone, 1.0f}}};

    const Mesh sanitized = m.sanitizedSkinningData();
    UM_CHECK(sanitized.vertexBoneWeights[0].empty());
}

static void testSkinnedVerticesIdentityWhenBonesUnmoved() {
    Skeleton skeleton;
    Bone bone = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);

    Mesh m("m");
    m.vertices = {Vec2(10, 0)};
    m.bindVertices = {Vec2(10, 0)};
    // Bound at a moment when the bone's world matrix was identity.
    m.boneInverseBindMatrices[bone.id] = inverse(Mat4::identity());
    m.vertexBoneWeights = {{{bone.id, 1.0f}}};

    const auto skinned = m.skinnedVertices(skeleton, std::nullopt, nullptr, /*presanitized=*/false);
    UM_CHECK(skinned.size() == 1);
    UM_CHECK_NEAR(skinned[0].x, 10.0, 1e-3);
    UM_CHECK_NEAR(skinned[0].y, 0.0, 1e-3);
}

static void testSkinnedVerticesFollowsBoneTranslation() {
    // Bind-time bone world matrix is identity (captured before the bone moved).
    const Mat4 bindWorld = Mat4::identity();

    Skeleton skeleton;
    // Bone now sits translated by (5, 5) from where it was at bind time.
    Bone bone = makeBone(std::nullopt, Vec2(5, 5), 0.0f, 100.0f);
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);

    Mesh m("m");
    m.vertices = {Vec2(10, 0)};
    m.bindVertices = {Vec2(10, 0)};
    m.boneInverseBindMatrices[bone.id] = inverse(bindWorld);
    m.vertexBoneWeights = {{{bone.id, 1.0f}}};

    // No currentPose -> legacy local-space path: result = current * invBind * bindLocal.
    const auto skinned = m.skinnedVertices(skeleton, std::nullopt, nullptr, false);
    UM_CHECK(skinned.size() == 1);
    UM_CHECK_NEAR(skinned[0].x, 15.0, 1e-3); // 10 + 5
    UM_CHECK_NEAR(skinned[0].y, 5.0, 1e-3);  // 0 + 5
}

static void testAutoBindWeightsBindsToNearestBone() {
    Skeleton skeleton;
    Bone near = makeBone(std::nullopt, Vec2(0, 0), 0.0f, 10.0f);
    Bone far = makeBone(std::nullopt, Vec2(1000, 1000), 0.0f, 10.0f);
    skeleton.setBone(near);
    skeleton.rootIDs.push_back(near.id);
    skeleton.setBone(far);
    skeleton.rootIDs.push_back(far.id);

    Mesh m = Mesh::makeQuad("sprite", Vec2(20, 20));
    const Mesh bound = m.autoBindWeights(skeleton);

    UM_CHECK(bound.hasSkinningData());
    UM_CHECK(bound.vertexBoneWeights.size() == bound.vertices.size());
    for (const auto& influences : bound.vertexBoneWeights) {
        UM_CHECK(!influences.empty());
        // The near bone dominates every vertex (quad is centered near origin,
        // far bone is 1000+ units away).
        UM_CHECK(influences[0].boneID == near.id);
        float sum = 0.0f;
        for (const auto& inf : influences) sum += inf.weight;
        UM_CHECK_NEAR(sum, 1.0, 1e-4);
    }
}

static void testKernelTriangulatedIndicesProducesWatertightMesh() {
    Mesh m("square");
    m.vertices = {Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)};
    m.hullVertexIndices = {0, 1, 2, 3};
    m.indices = m.kernelTriangulatedIndices();

    const auto report = m.validationReport();
    UM_CHECK(report.isValid());
}

UM_TEST_MAIN_BEGIN()
    testMakeQuad();
    testSanitizedForRenderEmptyFallsBackToQuad();
    testSanitizedSkinningDataNormalizesAndMergesWeights();
    testSanitizedSkinningDataDropsUnboundBoneReferences();
    testSkinnedVerticesIdentityWhenBonesUnmoved();
    testSkinnedVerticesFollowsBoneTranslation();
    testAutoBindWeightsBindsToNearestBone();
    testKernelTriangulatedIndicesProducesWatertightMesh();
UM_TEST_MAIN_END()
