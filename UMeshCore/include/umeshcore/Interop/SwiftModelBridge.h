#pragma once

// The model half of the Swift edge: what `Bridge/` on the Mac needs to copy
// a `Bone`, a `SceneImage`, a `Skeleton`... from C++ into the Swift structs
// the views hold, and back.
//
// `SwiftBridge.h` covers the three `std::variant`s. This header covers the
// other things Swift's C++ interop does not do, or does in a way this port
// will not lean on without a compiler to prove it:
//
//   OPTIONALS. `std::optional<T>` imports, but BUILDING one from Swift goes
//   through a templated constructor, and Swift does not import templated
//   constructors. So each optional the model uses gets `makeOptionalX`,
//   `optionalHasX` and `optionalX` -- three plain functions, nothing to
//   instantiate on the Swift side.
//
//   MAPS AND SETS. `unordered_map`/`unordered_set` with a custom hasher
//   (`UuidHash`) are exactly the kind of template Swift can read only
//   awkwardly and cannot build. Each one the model stores is exposed as a
//   LIST of entries, sorted, with a getter and a setter. Sorted so the list
//   is a function of the map's contents and not of its bucket layout --
//   two equal maps give equal lists, which is what the round-trip tests
//   compare.
//
//   ENUMS. Every enum crosses BY NAME, never by position: `xCaseCount()` /
//   `xCase(i)` / `xCaseIndex(x)` enumerate the C++ cases, and the Swift side
//   pairs each with its own case through the name function the serializers
//   already use (`trackPropertyName`, `interpolationName`...). Those names
//   are the file-format spelling, pinned by the serialization tests against
//   Swift's raw values, so a pairing made through them cannot silently
//   swap two cases the way a cast would if either enum were reordered. The
//   Swift side builds its table once; converting a value afterwards is an
//   array lookup.
//
//   ACCESSORS BY REFERENCE. A method returning `const T&` is imported by
//   Swift under a mangled "unsafe" name, and nothing about its lifetime is
//   checked. `AnimationClip::tracks()` and `Skeleton::bones()` are the two
//   the bridge needs; both get a by-value free function here.
//
// None of this is logic. Every function is a copy between two shapes of the
// same data, and the tests pin exactly that: out and back is the identity.

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "umeshcore/Animation/AnimationClip.h"
#include "umeshcore/Animation/AnimationEvent.h"
#include "umeshcore/Animation/AnimationTrackProperty.h"
#include "umeshcore/Animation/Keyframe.h"
#include "umeshcore/Constraints/IKConstraint.h"
#include "umeshcore/Constraints/PathConstraint.h"
#include "umeshcore/Constraints/PhysicsConstraint.h"
#include "umeshcore/Constraints/TransformConstraint.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Interop/SwiftBridge.h"
#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Mesh/Mesh.h"
#include "umeshcore/Mesh/MeshTypes.h"
#include "umeshcore/Model/Bone.h"
#include "umeshcore/Model/HierarchyItem.h"
#include "umeshcore/Model/SceneImage.h"
#include "umeshcore/Model/Skeleton.h"
#include "umeshcore/Model/Skin.h"

namespace umeshcore {

// ---- Named containers -----------------------------------------------------
//
// Every container the Swift side has to BUILD. (`SwiftBridge.h` names the
// first few: `UuidList`, `Vec2List`, `BoneList`, `SceneImageList`,
// `KeyframeList`...)

using U16List = std::vector<std::uint16_t>;
using MeshEdgeList = std::vector<MeshEdge>;
using MeshTriangleList = std::vector<MeshTriangle>;
using VertexWeightList = std::vector<VertexBoneWeight>;
using VertexWeightTable = std::vector<VertexWeightList>;
using AnimationTrackList = std::vector<AnimationTrack>;
using HierarchyItemList = std::vector<HierarchyItem>;
using SkinList = std::vector<Skin>;
using AnimationEventList = std::vector<AnimationEvent>;

// ---- Leaf values ----------------------------------------------------------

// `MeshEdge` has no default constructor (it normalizes its two ends), and
// Swift can call a constructor but reads more plainly through a function.
MeshEdge makeMeshEdge(std::uint16_t a, std::uint16_t b);
MeshTriangle makeMeshTriangle(std::uint16_t a, std::uint16_t b, std::uint16_t c);

// `Mat4::columns` is a C array; it imports as a tuple, which is fine to
// read but clumsy to index. Column `i` is what `simd_float4x4.columns.i` is.
Vec4 mat4Column(const Mat4& m, int index);

// ---- Optionals ------------------------------------------------------------

using OptionalUuid = std::optional<Uuid>;
using OptionalVec2 = std::optional<Vec2>;
using OptionalVec4 = std::optional<Vec4>;
using OptionalVec2List = std::optional<std::vector<Vec2>>;
using OptionalBoneImageBinding = std::optional<BoneImageBinding>;
using OptionalMeshBindPose = std::optional<MeshBindPose>;
using OptionalInt = std::optional<int>;
using OptionalFloat = std::optional<float>;
using OptionalString = std::optional<std::string>;

// `makeOptionalX(false, anything)` is nullopt; the value is then ignored.
// `optionalX(o)` of an empty optional is the type's default value -- read
// `optionalHasX` first when that default is a legal value.
OptionalUuid makeOptionalUuid(bool hasValue, Uuid value);
bool optionalHasUuid(const OptionalUuid& o);
Uuid optionalUuid(const OptionalUuid& o);

OptionalVec2 makeOptionalVec2(bool hasValue, Vec2 value);
bool optionalHasVec2(const OptionalVec2& o);
Vec2 optionalVec2(const OptionalVec2& o);

OptionalVec4 makeOptionalVec4(bool hasValue, Vec4 value);
bool optionalHasVec4(const OptionalVec4& o);
Vec4 optionalVec4(const OptionalVec4& o);

OptionalVec2List makeOptionalVec2List(bool hasValue, const Vec2List& value);
bool optionalHasVec2List(const OptionalVec2List& o);
Vec2List optionalVec2List(const OptionalVec2List& o);

OptionalBoneImageBinding makeOptionalBoneImageBinding(bool hasValue, const BoneImageBinding& value);
bool optionalHasBoneImageBinding(const OptionalBoneImageBinding& o);
BoneImageBinding optionalBoneImageBinding(const OptionalBoneImageBinding& o);

OptionalMeshBindPose makeOptionalMeshBindPose(bool hasValue, const MeshBindPose& value);
bool optionalHasMeshBindPose(const OptionalMeshBindPose& o);
MeshBindPose optionalMeshBindPose(const OptionalMeshBindPose& o);

OptionalInt makeOptionalInt(bool hasValue, int value);
bool optionalHasInt(const OptionalInt& o);
int optionalInt(const OptionalInt& o);

OptionalFloat makeOptionalFloat(bool hasValue, float value);
bool optionalHasFloat(const OptionalFloat& o);
float optionalFloat(const OptionalFloat& o);

OptionalString makeOptionalString(bool hasValue, const std::string& value);
bool optionalHasString(const OptionalString& o);
std::string optionalString(const OptionalString& o);

// ---- Maps as sorted lists -------------------------------------------------

// `Mesh::boneInverseBindMatrices`, sorted by bone id.
struct BoneInverseBind {
    Uuid boneID;
    Mat4 matrix;
};
using BoneInverseBindList = std::vector<BoneInverseBind>;
BoneInverseBindList meshInverseBinds(const Mesh& mesh);
// Replaces the whole map. A bone listed twice keeps its LAST matrix, the
// same rule a Swift dictionary literal built by assignment follows.
void setMeshInverseBinds(Mesh& mesh, const BoneInverseBindList& binds);

// `Skin::attachments`, sorted by slot name. `hasImage == false` is a slot
// the skin deliberately EMPTIES -- a real entry, distinct from a slot the
// skin does not mention (which is simply absent from the list).
struct SkinSlotEntry {
    std::string slot;
    bool hasImage = false;
    Uuid imageID;
};
using SkinSlotEntryList = std::vector<SkinSlotEntry>;
SkinSlotEntryList skinSlotEntries(const Skin& skin);
void setSkinSlotEntries(Skin& skin, const SkinSlotEntryList& entries);

// `Skeleton`'s bone table, sorted by id (the dictionary Swift keeps has no
// order either; the list's order is for comparing, not for meaning).
BoneList skeletonBones(const Skeleton& skeleton);
void setSkeletonBones(Skeleton& skeleton, const BoneList& bones);

// `AnimationClip::tracks()` by value, and its setter (which rebuilds the
// clip's track index, as assigning `tracks` does in Swift).
AnimationTrackList clipTracks(const AnimationClip& clip);
void setClipTracks(AnimationClip& clip, const AnimationTrackList& tracks);

// ---- Constraints as plain data --------------------------------------------
//
// The four constraint classes derive from `BoneConstraint`, which has
// virtual functions. How Swift imports a polymorphic C++ class as a value
// type has moved between compiler releases, and this port cannot compile
// Swift to find out; a plain struct with the same fields imports the same
// way on every release. So the bridge copies through these, and nothing on
// the Swift side ever names the classes.
//
// Fields are exactly the classes' stored fields, trailing underscore
// dropped. `order`/`mix`/`enabled` keep the classes' defaults so a
// default-constructed data struct makes a default-constructed constraint.

struct IKConstraintData {
    Uuid id;
    std::string name;
    bool enabled = true;
    int order = 0;
    float mix = 1.0f;
    std::vector<Uuid> boneChain;
    Uuid targetBoneID;
    bool bendPositive = true;
    bool stretch = false;
    bool compress = false;
    bool uniformScale = false;
    float softness = 0.0f;

    bool operator==(const IKConstraintData&) const = default;
};

struct TransformConstraintData {
    Uuid id;
    std::string name;
    bool enabled = true;
    int order = 50;
    float mix = 1.0f;
    Uuid targetBoneID;
    std::vector<Uuid> affectedBones;
    bool copyPosition = false;
    bool copyRotation = true;
    bool copyScale = false;
    bool copyShear = false;
    float positionMix = 1.0f;
    float rotationMix = 1.0f;
    float scaleMix = 1.0f;
    float shearMix = 1.0f;
    float offsetPositionX = 0.0f;
    float offsetPositionY = 0.0f;
    float offsetRotation = 0.0f;
    float offsetScaleX = 0.0f;
    float offsetScaleY = 0.0f;
    float offsetShear = 0.0f;

    bool operator==(const TransformConstraintData&) const = default;
};

struct PathConstraintData {
    Uuid id;
    std::string name;
    bool enabled = true;
    int order = 0;
    float mix = 1.0f;
    std::vector<Uuid> pathBones;
    std::vector<Uuid> bones;
    float position = 0.0f;
    float spacing = 60.0f;
    PathSpacingMode spacingMode = PathSpacingMode::Length;
    float positionMix = 1.0f;
    float rotateMix = 1.0f;
    float offsetRotation = 0.0f;
    bool closed = false;
    bool reversed = false;
    PathRotateMode rotateMode = PathRotateMode::Tangent;

    bool operator==(const PathConstraintData&) const = default;
};

struct PhysicsConstraintData {
    Uuid id;
    std::string name;
    bool enabled = true;
    int order = 100;
    float mix = 1.0f;
    PhysicsType physicsType = PhysicsType::Spring;
    std::vector<Uuid> affectedBones;
    PhysicsSettings settings;

    bool operator==(const PhysicsConstraintData&) const = default;
};

using IKConstraintDataList = std::vector<IKConstraintData>;
using TransformConstraintDataList = std::vector<TransformConstraintData>;
using PathConstraintDataList = std::vector<PathConstraintData>;
using PhysicsConstraintDataList = std::vector<PhysicsConstraintData>;

IKConstraintData ikConstraintData(const IKConstraint& constraint);
IKConstraint makeIKConstraint(const IKConstraintData& data);
TransformConstraintData transformConstraintData(const TransformConstraint& constraint);
TransformConstraint makeTransformConstraint(const TransformConstraintData& data);
PathConstraintData pathConstraintData(const PathConstraint& constraint);
PathConstraint makePathConstraint(const PathConstraintData& data);
PhysicsConstraintData physicsConstraintData(const PhysicsConstraint& constraint);
PhysicsConstraint makePhysicsConstraint(const PhysicsConstraintData& data);

// A skeleton's four constraint stores, in their stored order (which is the
// artist's list order, not the solve order -- that comes from `order`).
IKConstraintDataList skeletonIKConstraints(const Skeleton& skeleton);
void setSkeletonIKConstraints(Skeleton& skeleton, const IKConstraintDataList& constraints);
TransformConstraintDataList skeletonTransformConstraints(const Skeleton& skeleton);
void setSkeletonTransformConstraints(Skeleton& skeleton, const TransformConstraintDataList& constraints);
PathConstraintDataList skeletonPathConstraints(const Skeleton& skeleton);
void setSkeletonPathConstraints(Skeleton& skeleton, const PathConstraintDataList& constraints);
PhysicsConstraintDataList skeletonPhysicsConstraints(const Skeleton& skeleton);
void setSkeletonPhysicsConstraints(Skeleton& skeleton, const PhysicsConstraintDataList& constraints);

// ---- Enums, by name -------------------------------------------------------
//
// For each: how many cases, the i-th case, and a case's index. Pair them
// with the name function next to each (declared in the Saved* headers).

int trackPropertyCaseCount();                          // trackPropertyName
AnimationTrackProperty trackPropertyCase(int index);
int trackPropertyCaseIndex(AnimationTrackProperty property);

int interpolationCaseCount();                          // interpolationName
KeyframeInterpolation interpolationCase(int index);
int interpolationCaseIndex(KeyframeInterpolation interpolation);

int blendModeCaseCount();                              // blendModeName
ImageBlendMode blendModeCase(int index);
int blendModeCaseIndex(ImageBlendMode mode);

int hierarchyItemTypeCaseCount();                      // hierarchyItemTypeName
HierarchyItem::ItemType hierarchyItemTypeCase(int index);
int hierarchyItemTypeCaseIndex(HierarchyItem::ItemType type);

int pathSpacingModeCaseCount();                        // pathSpacingModeName
PathSpacingMode pathSpacingModeCase(int index);
int pathSpacingModeCaseIndex(PathSpacingMode mode);

int pathRotateModeCaseCount();                         // pathRotateModeName
PathRotateMode pathRotateModeCase(int index);
int pathRotateModeCaseIndex(PathRotateMode mode);

int physicsTypeCaseCount();                            // physicsTypeName
PhysicsType physicsTypeCase(int index);
int physicsTypeCaseIndex(PhysicsType type);

} // namespace umeshcore
