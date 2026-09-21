// Tests for Bone.h / Skeleton.h, ported from `Data/Bone.swift` /
// `Data/Skeleton.swift`. Expected values are hand-derived from the world
// matrix composition rule (world = parent.world * local.matrix()), not
// from the C++ implementation.

#include <cmath>

#include "umeshcore/Math/MatrixUtilities.h"
#include "umeshcore/Model/Skeleton.h"
#include "TestHarness.h"

using namespace umeshcore;

static Bone makeBone(const char* name, std::optional<Uuid> parent, Vec2 localPos, float rotationZ, float length) {
    Bone b;
    b.id = Uuid::generate();
    b.name = name;
    b.parentID = parent;
    b.localTransform.position = Vec3(localPos.x, localPos.y, 0);
    b.localTransform.rotation = Vec3(0, 0, rotationZ);
    b.baseTransform = b.localTransform;
    b.length = length;
    b.animationClip = AnimationClip(name);
    return b;
}

static void testTwoBoneChainStraight() {
    Skeleton skeleton;
    Bone root = makeBone("root", std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    Bone child = makeBone("child", root.id, Vec2(100, 0), 0.0f, 50.0f);
    skeleton.setBone(root);
    skeleton.rootIDs.push_back(root.id);
    skeleton.setBone(child);

    auto seg = skeleton.lineSegment(child.id);
    UM_CHECK(seg.has_value());
    UM_CHECK_NEAR(seg->start.x, 100.0, 1e-4);
    UM_CHECK_NEAR(seg->start.y, 0.0, 1e-4);
    UM_CHECK_NEAR(seg->end.x, 150.0, 1e-4);
    UM_CHECK_NEAR(seg->end.y, 0.0, 1e-4);
}

static void testTwoLevelRotationPropagation() {
    // Root rotated 90deg: its tip (and the child bone attached there)
    // should land at world (0, 100), and the child (itself unrotated
    // relative to its parent) should extend to (0, 150) -- see the test
    // file's header derivation.
    Skeleton skeleton;
    Bone root = makeBone("root", std::nullopt, Vec2(0, 0), kPi / 2.0f, 100.0f);
    Bone child = makeBone("child", root.id, Vec2(100, 0), 0.0f, 50.0f);
    skeleton.setBone(root);
    skeleton.rootIDs.push_back(root.id);
    skeleton.setBone(child);

    auto rootSeg = skeleton.lineSegment(root.id);
    UM_CHECK(rootSeg.has_value());
    UM_CHECK_NEAR(rootSeg->end.x, 0.0, 1e-3);
    UM_CHECK_NEAR(rootSeg->end.y, 100.0, 1e-3);

    auto childSeg = skeleton.lineSegment(child.id);
    UM_CHECK(childSeg.has_value());
    UM_CHECK_NEAR(childSeg->start.x, 0.0, 1e-3);
    UM_CHECK_NEAR(childSeg->start.y, 100.0, 1e-3);
    UM_CHECK_NEAR(childSeg->end.x, 0.0, 1e-3);
    UM_CHECK_NEAR(childSeg->end.y, 150.0, 1e-3);
}

static void testChildrenIndexInvalidatedOnReparentOnly() {
    Skeleton skeleton;
    Bone root = makeBone("root", std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    Bone child = makeBone("child", root.id, Vec2(100, 0), 0.0f, 50.0f);
    skeleton.setBone(root);
    skeleton.rootIDs.push_back(root.id);
    skeleton.setBone(child);

    UM_CHECK(skeleton.childrenIndexForPropagation().at(root.id).size() == 1);
    UM_CHECK(skeleton.childrenIndexForPropagation().at(root.id)[0] == child.id);

    // Mutating the child's pose (not its parent link) must not need a
    // rebuild to stay correct -- verify the index is still right afterward.
    Bone movedChild = child;
    movedChild.localTransform.position = Vec3(200, 0, 0);
    skeleton.setBone(movedChild);
    UM_CHECK(skeleton.childrenIndexForPropagation().at(root.id).size() == 1);

    // Reparenting to root (removing the parent link) must update the index.
    Bone detachedChild = movedChild;
    detachedChild.parentID = std::nullopt;
    skeleton.setBone(detachedChild);
    UM_CHECK(!skeleton.childrenIndexForPropagation().contains(root.id));
}

static void testCanParentRejectsCycles() {
    Skeleton skeleton;
    Bone root = makeBone("root", std::nullopt, Vec2(0, 0), 0.0f, 100.0f);
    Bone child = makeBone("child", root.id, Vec2(100, 0), 0.0f, 50.0f);
    skeleton.setBone(root);
    skeleton.rootIDs.push_back(root.id);
    skeleton.setBone(child);

    // root cannot become a child of its own descendant.
    UM_CHECK(!skeleton.canParent(root.id, child.id));
    // child can be reparented to a bone that isn't its own descendant (root itself).
    UM_CHECK(skeleton.canParent(child.id, root.id));
    // A bone can't be its own parent.
    UM_CHECK(!skeleton.canParent(root.id, root.id));
}

UM_TEST_MAIN_BEGIN()
    testTwoBoneChainStraight();
    testTwoLevelRotationPropagation();
    testChildrenIndexInvalidatedOnReparentOnly();
    testCanParentRejectsCycles();
UM_TEST_MAIN_END()
