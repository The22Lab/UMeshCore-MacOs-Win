#pragma once

// The Swift-facing edge of UMeshCore -- the part of the surface written FOR
// the Mac shell, so that everything else can stay written for C++.
//
// Phase 6a disconnects the Swift core entirely: the app's `SceneManager`
// becomes an adapter that holds a `umeshcore::EditorScene` and converts at
// the boundary. That boundary has one hard constraint this header exists
// for: Swift's C++ interop does not import `std::variant`, and a function
// whose signature mentions a type Swift cannot import is not imported
// either. So a variant may appear in NO signature Swift calls -- not as a
// parameter, not as a return type.
//
// The answer here is a FLAT struct per variant: a case tag plus every
// case's payload side by side, and a pair of functions that go between the
// flat form and the MODEL type that owns the variant (`Keyframe`,
// `SceneLayer`). The variant stays the C++ representation -- every
// `std::visit` in the core keeps its exhaustiveness -- and the flat form is
// a transport shape, never stored.
//
// This supersedes the audit's first idea in `bindings/swift/README.md`
// (discriminant + `optional<T>` accessors taking the variant): those
// accessors would take the variant as a parameter, which is exactly what
// cannot be imported. Recorded there too.
//
// WHY FLAT RATHER THAN ONE FUNCTION PER CASE. Swift mirrors these as
// enums with associated values; converting a case is then one switch on
// each side over one struct, and adding a case to the C++ variant breaks
// `fromFlat`'s switch at compile time here -- the one side of the boundary
// this repository can compile.
//
// Payload fields of the cases NOT named by `kind` are left at their
// defaults and ignored on the way back. A test pins that `toFlat` then
// `fromFlat` is the identity for every case, which is the only property
// the pair promises.

#include <string>
#include <vector>

#include "umeshcore/Animation/AnimationEvent.h"
#include "umeshcore/Animation/Keyframe.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Editor/GizmoHandle.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Model/Bone.h"
#include "umeshcore/Model/SceneImage.h"
#include "umeshcore/Scene/SceneLayer.h"

namespace umeshcore {

// ---- Named instantiations -------------------------------------------------
//
// Swift cannot instantiate a C++ template itself; it can only use a
// specialization that C++ has named. Every container Swift has to BUILD
// (to pass one in) is named here. Containers Swift only READS need no
// name -- a returned `std::vector` is iterable as it is.

using UuidList = std::vector<Uuid>;
using Vec2List = std::vector<Vec2>;
using FloatList = std::vector<float>;
using IntList = std::vector<int>;
using BoneList = std::vector<Bone>;
using SceneImageList = std::vector<SceneImage>;
using KeyframeList = std::vector<Keyframe>;

// ---- KeyframeValue --------------------------------------------------------

enum class KeyframeValueCase {
    Translate,
    Rotate,
    Scale,
    Shear,
    MeshDeform,
    Scalar,
    Flag,
    Vector2,
    DrawOrder,
    Event,
    Attachment
};

struct FlatKeyframeValue {
    KeyframeValueCase kind = KeyframeValueCase::Scalar;
    Vec2 vec2;                         // Translate, Scale, Shear, Vector2
    float scalar = 0.0f;               // Rotate, Scalar
    bool flag = false;                 // Flag
    std::vector<Vec2> meshDeform;      // MeshDeform
    std::vector<Uuid> drawOrder;       // DrawOrder
    AnimationEventPayload event;       // Event
    // Attachment. An empty slot is a real value here ("show nothing"), not
    // the absence of a key, so it gets its own flag rather than a nil Uuid.
    bool hasAttachment = false;
    Uuid attachment;
};

FlatKeyframeValue flatKeyframeValue(const Keyframe& keyframe);
// Replaces the keyframe's value. Keeps Swift's rule that a stepped kind
// (flag, draw order, event, attachment) is always Hold, since the
// interpolation of a key that cannot tween is not the caller's to choose.
void setFlatKeyframeValue(Keyframe& keyframe, const FlatKeyframeValue& value);

// A keyframe built entirely from Swift-importable parts.
Keyframe makeKeyframe(
    const Uuid& id, int frame, const FlatKeyframeValue& value,
    KeyframeInterpolation interpolation);

// The variant itself, for C++ callers and the tests. Swift never sees it.
FlatKeyframeValue toFlat(const KeyframeValue& value);
KeyframeValue fromFlat(const FlatKeyframeValue& flat);

// ---- SceneLayerContent ----------------------------------------------------

enum class SceneLayerContentCase { Rig, Plate, Fill };

struct FlatSceneLayerContent {
    SceneLayerContentCase kind = SceneLayerContentCase::Fill;
    SceneRigContent rig;        // Rig
    Uuid plateAssetId;          // Plate
    SceneFill fill;             // Fill
};

FlatSceneLayerContent flatLayerContent(const SceneLayer& layer);
void setFlatLayerContent(SceneLayer& layer, const FlatSceneLayerContent& content);

FlatSceneLayerContent toFlat(const SceneLayerContent& content);
SceneLayerContent fromFlat(const FlatSceneLayerContent& flat);

// ---- GizmoHandle ----------------------------------------------------------

enum class GizmoHandleCase {
    MoveCenter,
    MoveX,
    MoveY,
    Bone,
    MeshVertex,
    MeshInternalEdge,
    RotateRing,
    ScaleCorner,
    SkewEdge
};

struct FlatGizmoHandle {
    GizmoHandleCase kind = GizmoHandleCase::MoveCenter;
    Uuid boneID;   // Bone
    int index = 0; // MeshVertex, MeshInternalEdge, ScaleCorner, SkewEdge
};

FlatGizmoHandle toFlat(const GizmoHandle& handle);
GizmoHandle fromFlat(const FlatGizmoHandle& flat);

// ---- Strings --------------------------------------------------------------
//
// `std::string` crosses (Swift has `String(cxxString)` and
// `std.string(swiftString)` once `CxxStdlib` is imported), so nothing is
// needed for it. Noted here so nobody adds a `const char*` shim "to be
// safe" -- that would be a second, lifetime-unsafe way to do the same thing.

} // namespace umeshcore
