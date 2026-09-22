// Tests for Editor/Tools/PhysicsPreviewTool.h, ported from
// `Core/Tools/PhysicsPreviewTool.swift`.
//
// The thing to know before reading these: the override this tool writes
// has NO CONSUMER, in this port or in Swift. `PhysicsPreviewTool.h`
// carries the grep evidence. So these tests assert the tool's actual
// observable contract -- which bone it grabs, and that the override map
// ends up holding exactly what Swift's would -- rather than any effect on
// a pose, because there is none to assert on either side.
//
// The hit-test rule is this tool's own and differs from `BoneTool`'s on
// purpose, so it gets the attention:
//   - Both ENDS of a bone are candidates; the segment between them is not
//     hittable at all.
//   - Nearest end wins, across all bones.
//   - The radius is a flat 14 points and is NOT scaled for touch, unlike
//     `BoneTool`'s.

#include "umeshcore/Editor/Tools/PhysicsPreviewTool.h"

#include <cmath>

#include "umeshcore/Editor/ToolManager.h"

#include "TestHarness.h"

using namespace umeshcore;

namespace {

Bone makeBone(const Uuid& id, std::optional<Uuid> parent, const Vec2& localPos, float length) {
    Bone b;
    b.id = id;
    b.name = "bone";
    b.parentID = parent;
    b.localTransform.position = Vec3(localPos.x, localPos.y, 0.0f);
    b.baseTransform = b.localTransform;
    b.length = length;
    return b;
}

// Two bones in a chain: root at the origin running +x for 100, child
// carrying on from its tip for another 100. Joints therefore sit at world
// x = 0, 100 and 200.
struct Fixture {
    EditorScene scene;
    CameraState camera;
    Uuid rootID = Uuid(1, 1);
    Uuid childID = Uuid(2, 2);
};

Fixture makeFixture() {
    Fixture f;
    Skeleton skeleton;
    skeleton = skeleton.addingBone(makeBone(f.rootID, std::nullopt, Vec2(0, 0), 100.0f));
    skeleton = skeleton.addingBone(makeBone(f.childID, f.rootID, Vec2(100, 0), 100.0f));
    f.scene.skeleton = skeleton;
    return f;
}

// An input whose screen position is the camera's own projection of a world
// point, so the test states where it is clicking in WORLD terms and lets
// the camera decide the pixels -- the same path the tool takes.
ToolInput inputAtWorld(Fixture& f, const Vec2& world, const Vec2& nudgeScreen = Vec2::zero()) {
    ToolInput input;
    input.viewSize = Vec2(1000, 800);
    input.camera = &f.camera;
    input.position = world;
    input.screenPosition = f.camera.worldToScreen(world, input.viewSize) + nudgeScreen;
    return input;
}

// This tool never image-hit-tests, so the callback only has to exist.
const ImageHitTestFn kNoImages = [](const Vec2&, const Vec2&, CameraState*) {
    return std::optional<ImageHit>();
};

} // namespace

static void testGrabsTheNearestBoneEnd() {
    Fixture f = makeFixture();
    PhysicsPreviewTool tool;
    // Right on the child's tip at world x = 200.
    ToolInput input = inputAtWorld(f, Vec2(200, 0));
    tool.onMouseDown(input, f.scene, kNoImages, 1.0f, false);

    UM_CHECK(tool.draggingBoneID().has_value());
    if (tool.draggingBoneID()) UM_CHECK(*tool.draggingBoneID() == f.childID);
    UM_CHECK(f.scene.physicsPreviewOverrides.size() == 1);
    UM_CHECK(f.scene.physicsPreviewOverrides.count(f.childID) == 1);
}

static void testTheSharedJointGoesToWhicheverEndIsNearestNotToAParentRule() {
    // World x = 100 is the root's tip AND the child's root. Both are at
    // distance zero, so the winner is whichever the scan reaches first
    // with a strictly smaller distance -- which, because the comparison is
    // strict, is the FIRST bone in skeleton order. BoneTool's joint-beats-
    // segment priority has no equivalent here; this tool only knows ends.
    Fixture f = makeFixture();
    PhysicsPreviewTool tool;
    ToolInput input = inputAtWorld(f, Vec2(100, 0));
    tool.onMouseDown(input, f.scene, kNoImages, 1.0f, false);
    UM_CHECK(tool.draggingBoneID().has_value());
    if (tool.draggingBoneID()) UM_CHECK(*tool.draggingBoneID() == f.rootID);
}

static void testTheMiddleOfABoneIsNotHittable() {
    // The segment is not a candidate -- only its ends are. World x = 50 is
    // the middle of the root bone and 50 world units from either joint,
    // which is well outside 14 points at this camera's scale.
    Fixture f = makeFixture();
    PhysicsPreviewTool tool;
    ToolInput input = inputAtWorld(f, Vec2(50, 0));
    tool.onMouseDown(input, f.scene, kNoImages, 1.0f, false);
    UM_CHECK(!tool.draggingBoneID().has_value());
    UM_CHECK(f.scene.physicsPreviewOverrides.empty());
}

static void testAMissOutsideTheRadiusGrabsNothing() {
    Fixture f = makeFixture();
    PhysicsPreviewTool tool;
    // 40 screen points away from the root joint: outside 14.
    ToolInput input = inputAtWorld(f, Vec2(0, 0), Vec2(40.0f, 0.0f));
    tool.onMouseDown(input, f.scene, kNoImages, 1.0f, false);
    UM_CHECK(!tool.draggingBoneID().has_value());
    UM_CHECK(f.scene.physicsPreviewOverrides.empty());
}

static void testTheRadiusIsFourteenPointsAndIsNotScaledForTouch() {
    // Swift's `let jointR: Float = 14` is a plain constant, not one of the
    // `#if os(iOS)` pairs BoneTool uses -- so a touch build gets the same
    // radius. Asserted both sides of the boundary, and with touch on.
    Fixture f = makeFixture();
    PhysicsPreviewTool inside;
    ToolInput justInside = inputAtWorld(f, Vec2(0, 0), Vec2(13.0f, 0.0f));
    inside.onMouseDown(justInside, f.scene, kNoImages, 1.0f, true);
    UM_CHECK(inside.draggingBoneID().has_value());

    Fixture g = makeFixture();
    PhysicsPreviewTool outside;
    ToolInput justOutside = inputAtWorld(g, Vec2(0, 0), Vec2(15.0f, 0.0f));
    outside.onMouseDown(justOutside, g.scene, kNoImages, 4.0f, true);
    UM_CHECK(!outside.draggingBoneID().has_value());
}

static void testAMissClearsAPreviousDrag() {
    // Otherwise a missed click would leave the last bone still following
    // the pointer.
    Fixture f = makeFixture();
    PhysicsPreviewTool tool;
    ToolInput hit = inputAtWorld(f, Vec2(0, 0));
    tool.onMouseDown(hit, f.scene, kNoImages, 1.0f, false);
    UM_CHECK(tool.draggingBoneID().has_value());

    ToolInput miss = inputAtWorld(f, Vec2(0, 0), Vec2(500.0f, 500.0f));
    tool.onMouseDown(miss, f.scene, kNoImages, 1.0f, false);
    UM_CHECK(!tool.draggingBoneID().has_value());
}

static void testDragMovesTheOverrideAndMouseUpClearsIt() {
    Fixture f = makeFixture();
    PhysicsPreviewTool tool;
    ToolInput down = inputAtWorld(f, Vec2(0, 0));
    tool.onMouseDown(down, f.scene, kNoImages, 1.0f, false);

    ToolInput drag = inputAtWorld(f, Vec2(0, 0));
    drag.position = Vec2(37.0f, -19.0f);
    tool.onMouseDrag(drag, f.scene, kNoImages, 1.0f, false);
    UM_CHECK(f.scene.physicsPreviewOverrides.count(f.rootID) == 1);
    if (f.scene.physicsPreviewOverrides.count(f.rootID) == 1) {
        const Vec2 stored = f.scene.physicsPreviewOverrides.at(f.rootID);
        UM_CHECK_NEAR(stored.x, 37.0, 1e-6);
        UM_CHECK_NEAR(stored.y, -19.0, 1e-6);
    }

    tool.onMouseUp(drag, f.scene, kNoImages, 1.0f, false);
    UM_CHECK(f.scene.physicsPreviewOverrides.empty());
    UM_CHECK(!tool.draggingBoneID().has_value());
}

static void testADragWithNothingGrabbedWritesNothing() {
    Fixture f = makeFixture();
    PhysicsPreviewTool tool;
    ToolInput drag = inputAtWorld(f, Vec2(500, 500));
    tool.onMouseDrag(drag, f.scene, kNoImages, 1.0f, false);
    UM_CHECK(f.scene.physicsPreviewOverrides.empty());
}

static void testAnEmptySkeletonIsAQuietNoOp() {
    Fixture f = makeFixture();
    f.scene.skeleton = Skeleton();
    PhysicsPreviewTool tool;
    ToolInput input = inputAtWorld(f, Vec2(0, 0));
    tool.onMouseDown(input, f.scene, kNoImages, 1.0f, false);
    UM_CHECK(!tool.draggingBoneID().has_value());
    UM_CHECK(f.scene.physicsPreviewOverrides.empty());
}

static void testTheOverrideStillHasNoConsumer() {
    // Pinning the documented state of the feature rather than a behaviour:
    // a bone under an override poses exactly as it does without one,
    // because nothing reads the map -- in this port or in Swift. If a
    // consumer is ever added, THIS test is the one that should fail and
    // send the reader to `PhysicsPreviewTool.h`.
    Fixture f = makeFixture();
    const WorldMatrices before = f.scene.skeleton.worldMatrices();

    PhysicsPreviewTool tool;
    ToolInput down = inputAtWorld(f, Vec2(0, 0));
    tool.onMouseDown(down, f.scene, kNoImages, 1.0f, false);
    ToolInput drag = down;
    drag.position = Vec2(1000.0f, 1000.0f);
    tool.onMouseDrag(drag, f.scene, kNoImages, 1.0f, false);

    const WorldMatrices after = f.scene.skeleton.worldMatrices();
    UM_CHECK(before.size() == after.size());
    for (const auto& [id, matrix] : before) {
        UM_CHECK(after.count(id) == 1);
        if (after.count(id) == 1) UM_CHECK(matrix == after.at(id));
    }
}

static void testToolManagerNowHasAToolForThePhysicsPreviewMode() {
    // The "y" key and the constraints menu both select this mode in the
    // Swift app, so a shell switching to it must find a tool rather than
    // nothing.
    Fixture f = makeFixture();
    ToolManager manager;
    // The manager overwrites `input.camera` with its own on the way to the
    // tool, so the test has to hand it the same one it projected with.
    manager.camera = &f.camera;
    manager.setTool(f.scene, ActiveTool::PhysicsPreview);
    UM_CHECK(manager.currentTool == ActiveTool::PhysicsPreview);

    // And the registered tool actually acts: a mouse-down on a joint
    // routed through the manager grabs the bone, which is the difference
    // between a registered tool and an absent one.
    ToolInput input = inputAtWorld(f, Vec2(0, 0));
    manager.handleMouseDown(input, f.scene, kNoImages, 1.0f, false);
    UM_CHECK(f.scene.physicsPreviewOverrides.size() == 1);
}

UM_TEST_MAIN_BEGIN()
testGrabsTheNearestBoneEnd();
testTheSharedJointGoesToWhicheverEndIsNearestNotToAParentRule();
testTheMiddleOfABoneIsNotHittable();
testAMissOutsideTheRadiusGrabsNothing();
testTheRadiusIsFourteenPointsAndIsNotScaledForTouch();
testAMissClearsAPreviousDrag();
testDragMovesTheOverrideAndMouseUpClearsIt();
testADragWithNothingGrabbedWritesNothing();
testAnEmptySkeletonIsAQuietNoOp();
testTheOverrideStillHasNoConsumer();
testToolManagerNowHasAToolForThePhysicsPreviewMode();
UM_TEST_MAIN_END()
