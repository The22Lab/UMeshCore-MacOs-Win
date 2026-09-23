#include "umeshcore/Interop/SwiftModelBridge.h"

#include <algorithm>
#include <array>
#include <unordered_map>
#include <utility>

namespace umeshcore {

namespace {

// Each enum's cases, listed. The index is a position in THIS list -- the
// Swift side never reads it as meaning anything, only as a handle to pair
// with the case's name.
template <typename E, std::size_t N>
E caseAt(const std::array<E, N>& cases, int index) {
    if (index < 0 || static_cast<std::size_t>(index) >= N) return cases[0];
    return cases[static_cast<std::size_t>(index)];
}

template <typename E, std::size_t N>
int indexOf(const std::array<E, N>& cases, E value) {
    for (std::size_t i = 0; i < N; ++i) {
        if (cases[i] == value) return static_cast<int>(i);
    }
    return 0;
}

constexpr std::array<KeyframeInterpolation, 3> kInterpolations{
    KeyframeInterpolation::Hold, KeyframeInterpolation::Linear, KeyframeInterpolation::Bezier};

constexpr std::array<ImageBlendMode, 4> kBlendModes{
    ImageBlendMode::Normal, ImageBlendMode::Additive, ImageBlendMode::Multiply, ImageBlendMode::Screen};

constexpr std::array<HierarchyItem::ItemType, 3> kHierarchyItemTypes{
    HierarchyItem::ItemType::Image, HierarchyItem::ItemType::Bone, HierarchyItem::ItemType::Mesh};

constexpr std::array<PathSpacingMode, 4> kPathSpacingModes{
    PathSpacingMode::Length, PathSpacingMode::Percent, PathSpacingMode::Proportional, PathSpacingMode::Fixed};

constexpr std::array<PathRotateMode, 3> kPathRotateModes{
    PathRotateMode::Tangent, PathRotateMode::Chain, PathRotateMode::ChainScale};

constexpr std::array<PhysicsType, 5> kPhysicsTypes{
    PhysicsType::Spring, PhysicsType::Jiggle, PhysicsType::Rope, PhysicsType::Pendulum, PhysicsType::Cloth};

} // namespace

// ---- Leaf values ----------------------------------------------------------

MeshEdge makeMeshEdge(std::uint16_t a, std::uint16_t b) { return MeshEdge(a, b); }

MeshTriangle makeMeshTriangle(std::uint16_t a, std::uint16_t b, std::uint16_t c) {
    return MeshTriangle(a, b, c);
}

Vec4 mat4Column(const Mat4& m, int index) {
    if (index < 0 || index > 3) return Vec4(0, 0, 0, 0);
    return m.columns[index];
}

// ---- Optionals ------------------------------------------------------------

OptionalUuid makeOptionalUuid(bool hasValue, Uuid value) {
    return hasValue ? OptionalUuid(value) : std::nullopt;
}
bool optionalHasUuid(const OptionalUuid& o) { return o.has_value(); }
Uuid optionalUuid(const OptionalUuid& o) { return o.value_or(Uuid()); }

OptionalVec2 makeOptionalVec2(bool hasValue, Vec2 value) {
    return hasValue ? OptionalVec2(value) : std::nullopt;
}
bool optionalHasVec2(const OptionalVec2& o) { return o.has_value(); }
Vec2 optionalVec2(const OptionalVec2& o) { return o.value_or(Vec2()); }

OptionalVec4 makeOptionalVec4(bool hasValue, Vec4 value) {
    return hasValue ? OptionalVec4(value) : std::nullopt;
}
bool optionalHasVec4(const OptionalVec4& o) { return o.has_value(); }
Vec4 optionalVec4(const OptionalVec4& o) { return o.value_or(Vec4(0, 0, 0, 0)); }

OptionalVec2List makeOptionalVec2List(bool hasValue, const Vec2List& value) {
    return hasValue ? OptionalVec2List(value) : std::nullopt;
}
bool optionalHasVec2List(const OptionalVec2List& o) { return o.has_value(); }
Vec2List optionalVec2List(const OptionalVec2List& o) { return o.value_or(Vec2List{}); }

OptionalBoneImageBinding makeOptionalBoneImageBinding(bool hasValue, const BoneImageBinding& value) {
    return hasValue ? OptionalBoneImageBinding(value) : std::nullopt;
}
bool optionalHasBoneImageBinding(const OptionalBoneImageBinding& o) { return o.has_value(); }
BoneImageBinding optionalBoneImageBinding(const OptionalBoneImageBinding& o) {
    return o.value_or(BoneImageBinding{});
}

OptionalMeshBindPose makeOptionalMeshBindPose(bool hasValue, const MeshBindPose& value) {
    return hasValue ? OptionalMeshBindPose(value) : std::nullopt;
}
bool optionalHasMeshBindPose(const OptionalMeshBindPose& o) { return o.has_value(); }
MeshBindPose optionalMeshBindPose(const OptionalMeshBindPose& o) { return o.value_or(MeshBindPose{}); }

OptionalInt makeOptionalInt(bool hasValue, int value) { return hasValue ? OptionalInt(value) : std::nullopt; }
bool optionalHasInt(const OptionalInt& o) { return o.has_value(); }
int optionalInt(const OptionalInt& o) { return o.value_or(0); }

OptionalFloat makeOptionalFloat(bool hasValue, float value) {
    return hasValue ? OptionalFloat(value) : std::nullopt;
}
bool optionalHasFloat(const OptionalFloat& o) { return o.has_value(); }
float optionalFloat(const OptionalFloat& o) { return o.value_or(0.0f); }

OptionalString makeOptionalString(bool hasValue, const std::string& value) {
    return hasValue ? OptionalString(value) : std::nullopt;
}
bool optionalHasString(const OptionalString& o) { return o.has_value(); }
std::string optionalString(const OptionalString& o) { return o.value_or(std::string()); }

// ---- Maps as sorted lists -------------------------------------------------

BoneInverseBindList meshInverseBinds(const Mesh& mesh) {
    BoneInverseBindList out;
    out.reserve(mesh.boneInverseBindMatrices.size());
    for (const auto& [boneID, matrix] : mesh.boneInverseBindMatrices) out.push_back({boneID, matrix});
    std::sort(out.begin(), out.end(),
              [](const BoneInverseBind& a, const BoneInverseBind& b) { return a.boneID < b.boneID; });
    return out;
}

void setMeshInverseBinds(Mesh& mesh, const BoneInverseBindList& binds) {
    mesh.boneInverseBindMatrices.clear();
    for (const BoneInverseBind& bind : binds) mesh.boneInverseBindMatrices[bind.boneID] = bind.matrix;
}

SkinSlotEntryList skinSlotEntries(const Skin& skin) {
    SkinSlotEntryList out;
    out.reserve(skin.attachments.size());
    for (const auto& [slot, attachment] : skin.attachments) {
        SkinSlotEntry entry;
        entry.slot = slot;
        entry.hasImage = attachment.has_value();
        entry.imageID = attachment.value_or(Uuid());
        out.push_back(std::move(entry));
    }
    std::sort(out.begin(), out.end(), [](const SkinSlotEntry& a, const SkinSlotEntry& b) { return a.slot < b.slot; });
    return out;
}

void setSkinSlotEntries(Skin& skin, const SkinSlotEntryList& entries) {
    skin.attachments.clear();
    for (const SkinSlotEntry& entry : entries) {
        skin.attachments[entry.slot] = entry.hasImage ? SlotAttachment(entry.imageID) : SlotAttachment();
    }
}

BoneList skeletonBones(const Skeleton& skeleton) {
    BoneList out;
    out.reserve(skeleton.bones().size());
    for (const auto& [id, bone] : skeleton.bones()) out.push_back(bone);
    std::sort(out.begin(), out.end(), [](const Bone& a, const Bone& b) { return a.id < b.id; });
    return out;
}

void setSkeletonBones(Skeleton& skeleton, const BoneList& bones) {
    std::unordered_map<Uuid, Bone, UuidHash> table;
    table.reserve(bones.size());
    for (const Bone& bone : bones) table[bone.id] = bone;
    skeleton.setBones(std::move(table));
}

AnimationTrackList clipTracks(const AnimationClip& clip) { return clip.tracks(); }

void setClipTracks(AnimationClip& clip, const AnimationTrackList& tracks) { clip.setTracks(tracks); }

// ---- Constraints as plain data --------------------------------------------

IKConstraintData ikConstraintData(const IKConstraint& c) {
    IKConstraintData d;
    d.id = c.id_;
    d.name = c.name_;
    d.enabled = c.enabled_;
    d.order = c.order_;
    d.mix = c.mix_;
    d.boneChain = c.boneChain;
    d.targetBoneID = c.targetBoneID;
    d.bendPositive = c.bendPositive;
    d.stretch = c.stretch;
    d.compress = c.compress;
    d.uniformScale = c.uniformScale;
    d.softness = c.softness;
    return d;
}

IKConstraint makeIKConstraint(const IKConstraintData& d) {
    IKConstraint c;
    c.id_ = d.id;
    c.name_ = d.name;
    c.enabled_ = d.enabled;
    c.order_ = d.order;
    c.mix_ = d.mix;
    c.boneChain = d.boneChain;
    c.targetBoneID = d.targetBoneID;
    c.bendPositive = d.bendPositive;
    c.stretch = d.stretch;
    c.compress = d.compress;
    c.uniformScale = d.uniformScale;
    c.softness = d.softness;
    return c;
}

TransformConstraintData transformConstraintData(const TransformConstraint& c) {
    TransformConstraintData d;
    d.id = c.id_;
    d.name = c.name_;
    d.enabled = c.enabled_;
    d.order = c.order_;
    d.mix = c.mix_;
    d.targetBoneID = c.targetBoneID;
    d.affectedBones = c.affectedBones;
    d.copyPosition = c.copyPosition;
    d.copyRotation = c.copyRotation;
    d.copyScale = c.copyScale;
    d.copyShear = c.copyShear;
    d.positionMix = c.positionMix;
    d.rotationMix = c.rotationMix;
    d.scaleMix = c.scaleMix;
    d.shearMix = c.shearMix;
    d.offsetPositionX = c.offsetPositionX;
    d.offsetPositionY = c.offsetPositionY;
    d.offsetRotation = c.offsetRotation;
    d.offsetScaleX = c.offsetScaleX;
    d.offsetScaleY = c.offsetScaleY;
    d.offsetShear = c.offsetShear;
    return d;
}

TransformConstraint makeTransformConstraint(const TransformConstraintData& d) {
    TransformConstraint c;
    c.id_ = d.id;
    c.name_ = d.name;
    c.enabled_ = d.enabled;
    c.order_ = d.order;
    c.mix_ = d.mix;
    c.targetBoneID = d.targetBoneID;
    c.affectedBones = d.affectedBones;
    c.copyPosition = d.copyPosition;
    c.copyRotation = d.copyRotation;
    c.copyScale = d.copyScale;
    c.copyShear = d.copyShear;
    c.positionMix = d.positionMix;
    c.rotationMix = d.rotationMix;
    c.scaleMix = d.scaleMix;
    c.shearMix = d.shearMix;
    c.offsetPositionX = d.offsetPositionX;
    c.offsetPositionY = d.offsetPositionY;
    c.offsetRotation = d.offsetRotation;
    c.offsetScaleX = d.offsetScaleX;
    c.offsetScaleY = d.offsetScaleY;
    c.offsetShear = d.offsetShear;
    return c;
}

PathConstraintData pathConstraintData(const PathConstraint& c) {
    PathConstraintData d;
    d.id = c.id_;
    d.name = c.name_;
    d.enabled = c.enabled_;
    d.order = c.order_;
    d.mix = c.mix_;
    d.pathBones = c.pathBones;
    d.bones = c.bones;
    d.position = c.position;
    d.spacing = c.spacing;
    d.spacingMode = c.spacingMode;
    d.positionMix = c.positionMix;
    d.rotateMix = c.rotateMix;
    d.offsetRotation = c.offsetRotation;
    d.closed = c.closed;
    d.reversed = c.reversed;
    d.rotateMode = c.rotateMode;
    return d;
}

PathConstraint makePathConstraint(const PathConstraintData& d) {
    PathConstraint c;
    c.id_ = d.id;
    c.name_ = d.name;
    c.enabled_ = d.enabled;
    c.order_ = d.order;
    c.mix_ = d.mix;
    c.pathBones = d.pathBones;
    c.bones = d.bones;
    c.position = d.position;
    c.spacing = d.spacing;
    c.spacingMode = d.spacingMode;
    c.positionMix = d.positionMix;
    c.rotateMix = d.rotateMix;
    c.offsetRotation = d.offsetRotation;
    c.closed = d.closed;
    c.reversed = d.reversed;
    c.rotateMode = d.rotateMode;
    return c;
}

PhysicsConstraintData physicsConstraintData(const PhysicsConstraint& c) {
    PhysicsConstraintData d;
    d.id = c.id_;
    d.name = c.name_;
    d.enabled = c.enabled_;
    d.order = c.order_;
    d.mix = c.mix_;
    d.physicsType = c.physicsType;
    d.affectedBones = c.affectedBones;
    d.settings = c.settings;
    return d;
}

PhysicsConstraint makePhysicsConstraint(const PhysicsConstraintData& d) {
    PhysicsConstraint c;
    c.id_ = d.id;
    c.name_ = d.name;
    c.enabled_ = d.enabled;
    c.order_ = d.order;
    c.mix_ = d.mix;
    c.physicsType = d.physicsType;
    c.affectedBones = d.affectedBones;
    c.settings = d.settings;
    return c;
}

IKConstraintDataList skeletonIKConstraints(const Skeleton& skeleton) {
    IKConstraintDataList out;
    out.reserve(skeleton.ikConstraints.size());
    for (const IKConstraint& c : skeleton.ikConstraints) out.push_back(ikConstraintData(c));
    return out;
}
void setSkeletonIKConstraints(Skeleton& skeleton, const IKConstraintDataList& constraints) {
    skeleton.ikConstraints.clear();
    for (const IKConstraintData& d : constraints) skeleton.ikConstraints.push_back(makeIKConstraint(d));
}

TransformConstraintDataList skeletonTransformConstraints(const Skeleton& skeleton) {
    TransformConstraintDataList out;
    out.reserve(skeleton.transformConstraints.size());
    for (const TransformConstraint& c : skeleton.transformConstraints) out.push_back(transformConstraintData(c));
    return out;
}
void setSkeletonTransformConstraints(Skeleton& skeleton, const TransformConstraintDataList& constraints) {
    skeleton.transformConstraints.clear();
    for (const TransformConstraintData& d : constraints) {
        skeleton.transformConstraints.push_back(makeTransformConstraint(d));
    }
}

PathConstraintDataList skeletonPathConstraints(const Skeleton& skeleton) {
    PathConstraintDataList out;
    out.reserve(skeleton.pathConstraints.size());
    for (const PathConstraint& c : skeleton.pathConstraints) out.push_back(pathConstraintData(c));
    return out;
}
void setSkeletonPathConstraints(Skeleton& skeleton, const PathConstraintDataList& constraints) {
    skeleton.pathConstraints.clear();
    for (const PathConstraintData& d : constraints) skeleton.pathConstraints.push_back(makePathConstraint(d));
}

PhysicsConstraintDataList skeletonPhysicsConstraints(const Skeleton& skeleton) {
    PhysicsConstraintDataList out;
    out.reserve(skeleton.physicsConstraints.size());
    for (const PhysicsConstraint& c : skeleton.physicsConstraints) out.push_back(physicsConstraintData(c));
    return out;
}
void setSkeletonPhysicsConstraints(Skeleton& skeleton, const PhysicsConstraintDataList& constraints) {
    skeleton.physicsConstraints.clear();
    for (const PhysicsConstraintData& d : constraints) {
        skeleton.physicsConstraints.push_back(makePhysicsConstraint(d));
    }
}

// ---- Enums, by name -------------------------------------------------------

int trackPropertyCaseCount() { return kAnimationTrackPropertyCount; }
AnimationTrackProperty trackPropertyCase(int index) {
    return caseAt(allAnimationTrackProperties(), index);
}
int trackPropertyCaseIndex(AnimationTrackProperty property) {
    return indexOf(allAnimationTrackProperties(), property);
}

int interpolationCaseCount() { return static_cast<int>(kInterpolations.size()); }
KeyframeInterpolation interpolationCase(int index) { return caseAt(kInterpolations, index); }
int interpolationCaseIndex(KeyframeInterpolation interpolation) { return indexOf(kInterpolations, interpolation); }

int blendModeCaseCount() { return static_cast<int>(kBlendModes.size()); }
ImageBlendMode blendModeCase(int index) { return caseAt(kBlendModes, index); }
int blendModeCaseIndex(ImageBlendMode mode) { return indexOf(kBlendModes, mode); }

int hierarchyItemTypeCaseCount() { return static_cast<int>(kHierarchyItemTypes.size()); }
HierarchyItem::ItemType hierarchyItemTypeCase(int index) { return caseAt(kHierarchyItemTypes, index); }
int hierarchyItemTypeCaseIndex(HierarchyItem::ItemType type) { return indexOf(kHierarchyItemTypes, type); }

int pathSpacingModeCaseCount() { return static_cast<int>(kPathSpacingModes.size()); }
PathSpacingMode pathSpacingModeCase(int index) { return caseAt(kPathSpacingModes, index); }
int pathSpacingModeCaseIndex(PathSpacingMode mode) { return indexOf(kPathSpacingModes, mode); }

int pathRotateModeCaseCount() { return static_cast<int>(kPathRotateModes.size()); }
PathRotateMode pathRotateModeCase(int index) { return caseAt(kPathRotateModes, index); }
int pathRotateModeCaseIndex(PathRotateMode mode) { return indexOf(kPathRotateModes, mode); }

int physicsTypeCaseCount() { return static_cast<int>(kPhysicsTypes.size()); }
PhysicsType physicsTypeCase(int index) { return caseAt(kPhysicsTypes, index); }
int physicsTypeCaseIndex(PhysicsType type) { return indexOf(kPhysicsTypes, type); }

} // namespace umeshcore
