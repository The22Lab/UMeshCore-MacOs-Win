#include "umeshcore/Serialization/SavedSkeleton.h"

#include "umeshcore/Serialization/SavedAnimation.h"
#include "umeshcore/Serialization/SavedGeometry.h"

namespace umeshcore {

namespace {

JsonValue uuidArrayToJson(const std::vector<Uuid>& ids) {
    JsonValue::Array arr;
    arr.reserve(ids.size());
    for (const Uuid& id : ids) arr.push_back(toJson(id));
    return JsonValue::makeArray(std::move(arr));
}

std::vector<Uuid> uuidArrayFromJson(const JsonValue& j) {
    std::vector<Uuid> out;
    for (const JsonValue& elem : j.asArray()) out.push_back(uuidFromJson(elem));
    return out;
}

} // namespace

JsonValue toJson(const Bone& bone) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(bone.id));
    j.set("name", JsonValue::makeString(bone.name));
    if (bone.parentID.has_value()) j.set("parentID", toJson(*bone.parentID));

    j.set("basePosition", toJson(bone.baseTransform.position));
    j.set("baseRotation", toJson(bone.baseTransform.rotation));
    j.set("baseScale", toJson(bone.baseTransform.scale));
    j.set("baseSkew", toJson(bone.baseTransform.skew));

    j.set("position", toJson(bone.localTransform.position));
    j.set("rotation", toJson(bone.localTransform.rotation));
    j.set("scale", toJson(bone.localTransform.scale));
    j.set("skew", toJson(bone.localTransform.skew));

    j.set("length", JsonValue::makeNumber(bone.length));
    if (bone.color.has_value()) j.set("color", toJson(*bone.color));
    // Optional on the wire, like Swift's own `SavedAnimationClip?`: a bone
    // with nothing keyed writes no clip at all.
    if (!bone.animationClip.tracks().empty()) j.set("animationClip", toJson(bone.animationClip));
    return j;
}

Bone boneFromJson(const JsonValue& j) {
    Bone bone;
    bone.id = uuidFromJson(*j.find("id"));
    bone.name = j.find("name")->asString();
    const JsonValue* parentID = j.find("parentID");
    if (parentID != nullptr) bone.parentID = uuidFromJson(*parentID);

    // position/rotation/scale/skew are required; base* falls back to the
    // local pose when absent, exactly matching SavedBone's custom
    // init(from:) fallback (old files authored no separate rest pose).
    bone.localTransform.position = vec3FromJson(*j.find("position"));
    bone.localTransform.rotation = vec3FromJson(*j.find("rotation"));
    bone.localTransform.scale = vec3FromJson(*j.find("scale"));
    bone.localTransform.skew = vec2FromJson(*j.find("skew"));

    const JsonValue* baseP = j.find("basePosition");
    bone.baseTransform.position = baseP != nullptr ? vec3FromJson(*baseP) : bone.localTransform.position;
    const JsonValue* baseR = j.find("baseRotation");
    bone.baseTransform.rotation = baseR != nullptr ? vec3FromJson(*baseR) : bone.localTransform.rotation;
    const JsonValue* baseS = j.find("baseScale");
    bone.baseTransform.scale = baseS != nullptr ? vec3FromJson(*baseS) : bone.localTransform.scale;
    const JsonValue* baseSk = j.find("baseSkew");
    bone.baseTransform.skew = baseSk != nullptr ? vec2FromJson(*baseSk) : bone.localTransform.skew;

    bone.length = j.find("length")->asFloat();
    const JsonValue* color = j.find("color");
    if (color != nullptr) bone.color = vec4FromJson(*color);
    const JsonValue* animationClip = j.find("animationClip");
    bone.animationClip = animationClip != nullptr ? animationClipFromJson(*animationClip) : AnimationClip(bone.name);
    return bone;
}

JsonValue toJson(const IKConstraint& c) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(c.id_));
    j.set("name", JsonValue::makeString(c.name_));
    j.set("enabled", JsonValue::makeBool(c.enabled_));
    j.set("order", JsonValue::makeNumber(c.order_));
    j.set("mix", JsonValue::makeNumber(c.mix_));
    j.set("boneChain", uuidArrayToJson(c.boneChain));
    j.set("targetBoneID", toJson(c.targetBoneID));
    j.set("bendPositive", JsonValue::makeBool(c.bendPositive));
    j.set("stretch", JsonValue::makeBool(c.stretch));
    j.set("compress", JsonValue::makeBool(c.compress));
    j.set("uniformScale", JsonValue::makeBool(c.uniformScale));
    j.set("softness", JsonValue::makeNumber(c.softness));
    return j;
}

IKConstraint ikConstraintFromJson(const JsonValue& j) {
    IKConstraint c;
    c.id_ = uuidFromJson(*j.find("id"));
    c.name_ = j.find("name")->asString();
    c.enabled_ = j.find("enabled")->asBool();
    c.order_ = j.find("order")->asInt();
    c.mix_ = j.find("mix")->asFloat();
    c.boneChain = uuidArrayFromJson(*j.find("boneChain"));
    c.targetBoneID = uuidFromJson(*j.find("targetBoneID"));
    c.bendPositive = j.find("bendPositive")->asBool();
    c.stretch = j.find("stretch")->asBool();
    c.compress = j.find("compress")->asBool();
    c.uniformScale = j.find("uniformScale")->asBool();
    c.softness = j.find("softness")->asFloat();
    return c;
}

namespace {
const char* pathSpacingModeName(PathSpacingMode m) {
    switch (m) {
        case PathSpacingMode::Length: return "length";
        case PathSpacingMode::Percent: return "percent";
        case PathSpacingMode::Proportional: return "proportional";
        case PathSpacingMode::Fixed: return "fixed";
    }
    return "length";
}
// Matches Swift's PathSpacingMode rawValues exactly (PathConstraint.swift).
PathSpacingMode pathSpacingModeFromName(const std::string& name) {
    if (name == "percent") return PathSpacingMode::Percent;
    if (name == "proportional") return PathSpacingMode::Proportional;
    if (name == "fixed") return PathSpacingMode::Fixed;
    return PathSpacingMode::Length; // unknown/absent falls back like Swift's `?? .length`.
}

const char* pathRotateModeName(PathRotateMode m) {
    switch (m) {
        case PathRotateMode::Tangent: return "tangent";
        case PathRotateMode::Chain: return "chain";
        case PathRotateMode::ChainScale: return "chainScale";
    }
    return "tangent";
}
// Matches Swift's PathRotateMode rawValues exactly (PathConstraint.swift).
PathRotateMode pathRotateModeFromName(const std::string& name) {
    if (name == "chain") return PathRotateMode::Chain;
    if (name == "chainScale") return PathRotateMode::ChainScale;
    return PathRotateMode::Tangent; // unknown/absent falls back like Swift's `?? .tangent`.
}
} // namespace

JsonValue toJson(const PathConstraint& c) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(c.id_));
    j.set("name", JsonValue::makeString(c.name_));
    j.set("enabled", JsonValue::makeBool(c.enabled_));
    j.set("order", JsonValue::makeNumber(c.order_));
    j.set("mix", JsonValue::makeNumber(c.mix_));
    j.set("pathBones", uuidArrayToJson(c.pathBones));
    j.set("bones", uuidArrayToJson(c.bones));
    j.set("position", JsonValue::makeNumber(c.position));
    j.set("spacing", JsonValue::makeNumber(c.spacing));
    j.set("spacingMode", JsonValue::makeString(pathSpacingModeName(c.spacingMode)));
    j.set("positionMix", JsonValue::makeNumber(c.positionMix));
    j.set("rotateMix", JsonValue::makeNumber(c.rotateMix));
    j.set("offsetRotation", JsonValue::makeNumber(c.offsetRotation));
    j.set("closed", JsonValue::makeBool(c.closed));
    j.set("reversed", JsonValue::makeBool(c.reversed));
    j.set("rotateMode", JsonValue::makeString(pathRotateModeName(c.rotateMode)));
    return j;
}

PathConstraint pathConstraintFromJson(const JsonValue& j) {
    PathConstraint c;
    c.id_ = uuidFromJson(*j.find("id"));
    c.name_ = j.find("name")->asString();
    c.enabled_ = j.find("enabled")->asBool();
    c.order_ = j.find("order")->asInt();
    c.mix_ = j.find("mix")->asFloat();
    c.pathBones = uuidArrayFromJson(*j.find("pathBones"));
    c.bones = uuidArrayFromJson(*j.find("bones"));
    c.position = j.find("position")->asFloat();
    c.spacing = j.find("spacing")->asFloat();
    const JsonValue* spacingMode = j.find("spacingMode");
    c.spacingMode = spacingMode != nullptr ? pathSpacingModeFromName(spacingMode->asString()) : PathSpacingMode::Length;
    c.positionMix = j.find("positionMix")->asFloat();
    c.rotateMix = j.find("rotateMix")->asFloat();
    c.offsetRotation = j.find("offsetRotation")->asFloat();
    const JsonValue* closed = j.find("closed");
    c.closed = closed != nullptr && closed->asBool();
    const JsonValue* reversed = j.find("reversed");
    c.reversed = reversed != nullptr && reversed->asBool();
    const JsonValue* rotateMode = j.find("rotateMode");
    c.rotateMode = rotateMode != nullptr ? pathRotateModeFromName(rotateMode->asString()) : PathRotateMode::Tangent;
    return c;
}

JsonValue toJson(const TransformConstraint& c) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(c.id_));
    j.set("name", JsonValue::makeString(c.name_));
    j.set("enabled", JsonValue::makeBool(c.enabled_));
    j.set("order", JsonValue::makeNumber(c.order_));
    j.set("mix", JsonValue::makeNumber(c.mix_));
    j.set("targetBoneID", toJson(c.targetBoneID));
    j.set("affectedBones", uuidArrayToJson(c.affectedBones));
    j.set("copyPosition", JsonValue::makeBool(c.copyPosition));
    j.set("copyRotation", JsonValue::makeBool(c.copyRotation));
    j.set("copyScale", JsonValue::makeBool(c.copyScale));
    j.set("copyShear", JsonValue::makeBool(c.copyShear));
    j.set("positionMix", JsonValue::makeNumber(c.positionMix));
    j.set("rotationMix", JsonValue::makeNumber(c.rotationMix));
    j.set("scaleMix", JsonValue::makeNumber(c.scaleMix));
    j.set("shearMix", JsonValue::makeNumber(c.shearMix));
    j.set("offsetPositionX", JsonValue::makeNumber(c.offsetPositionX));
    j.set("offsetPositionY", JsonValue::makeNumber(c.offsetPositionY));
    j.set("offsetRotation", JsonValue::makeNumber(c.offsetRotation));
    j.set("offsetScaleX", JsonValue::makeNumber(c.offsetScaleX));
    j.set("offsetScaleY", JsonValue::makeNumber(c.offsetScaleY));
    j.set("offsetShear", JsonValue::makeNumber(c.offsetShear));
    return j;
}

TransformConstraint transformConstraintFromJson(const JsonValue& j) {
    TransformConstraint c;
    c.id_ = uuidFromJson(*j.find("id"));
    c.name_ = j.find("name")->asString();
    c.enabled_ = j.find("enabled")->asBool();
    c.order_ = j.find("order")->asInt();
    c.mix_ = j.find("mix")->asFloat();
    c.targetBoneID = uuidFromJson(*j.find("targetBoneID"));
    c.affectedBones = uuidArrayFromJson(*j.find("affectedBones"));
    c.copyPosition = j.find("copyPosition")->asBool();
    c.copyRotation = j.find("copyRotation")->asBool();
    c.copyScale = j.find("copyScale")->asBool();
    c.copyShear = j.find("copyShear")->asBool();
    c.positionMix = j.find("positionMix")->asFloat();
    c.rotationMix = j.find("rotationMix")->asFloat();
    c.scaleMix = j.find("scaleMix")->asFloat();
    c.shearMix = j.find("shearMix")->asFloat();
    c.offsetPositionX = j.find("offsetPositionX")->asFloat();
    c.offsetPositionY = j.find("offsetPositionY")->asFloat();
    c.offsetRotation = j.find("offsetRotation")->asFloat();
    c.offsetScaleX = j.find("offsetScaleX")->asFloat();
    c.offsetScaleY = j.find("offsetScaleY")->asFloat();
    c.offsetShear = j.find("offsetShear")->asFloat();
    return c;
}

namespace {
const char* physicsTypeName(PhysicsType t) {
    switch (t) {
        case PhysicsType::Spring: return "spring";
        case PhysicsType::Jiggle: return "jiggle";
        case PhysicsType::Rope: return "rope";
        case PhysicsType::Pendulum: return "pendulum";
        case PhysicsType::Cloth: return "cloth";
    }
    return "spring";
}
// Matches Swift's PhysicsType rawValues exactly (PhysicsConstraint.swift).
PhysicsType physicsTypeFromName(const std::string& name) {
    if (name == "jiggle") return PhysicsType::Jiggle;
    if (name == "rope") return PhysicsType::Rope;
    if (name == "pendulum") return PhysicsType::Pendulum;
    if (name == "cloth") return PhysicsType::Cloth;
    return PhysicsType::Spring; // unknown/absent falls back like Swift's `?? .spring`.
}
} // namespace

JsonValue toJson(const PhysicsSettings& s) {
    JsonValue j = JsonValue::makeObject();
    j.set("mass", JsonValue::makeNumber(s.mass));
    j.set("damping", JsonValue::makeNumber(s.damping));
    j.set("stiffness", JsonValue::makeNumber(s.stiffness));
    j.set("gravity", JsonValue::makeNumber(s.gravity));
    j.set("drag", JsonValue::makeNumber(s.drag));
    j.set("wind", toJson(s.wind));
    j.set("stretchLimit", JsonValue::makeNumber(s.stretchLimit));
    j.set("angleLimitMin", JsonValue::makeNumber(s.angleLimitMin));
    j.set("angleLimitMax", JsonValue::makeNumber(s.angleLimitMax));
    return j;
}

PhysicsSettings physicsSettingsFromJson(const JsonValue& j) {
    PhysicsSettings s;
    s.mass = j.find("mass")->asFloat();
    s.damping = j.find("damping")->asFloat();
    s.stiffness = j.find("stiffness")->asFloat();
    s.gravity = j.find("gravity")->asFloat();
    s.drag = j.find("drag")->asFloat();
    s.wind = vec2FromJson(*j.find("wind"));
    s.stretchLimit = j.find("stretchLimit")->asFloat();
    s.angleLimitMin = j.find("angleLimitMin")->asFloat();
    s.angleLimitMax = j.find("angleLimitMax")->asFloat();
    return s;
}

JsonValue toJson(const PhysicsConstraint& c) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(c.id_));
    j.set("name", JsonValue::makeString(c.name_));
    j.set("enabled", JsonValue::makeBool(c.enabled_));
    j.set("order", JsonValue::makeNumber(c.order_));
    j.set("mix", JsonValue::makeNumber(c.mix_));
    j.set("physicsType", JsonValue::makeString(physicsTypeName(c.physicsType)));
    j.set("affectedBones", uuidArrayToJson(c.affectedBones));
    j.set("settings", toJson(c.settings));
    return j;
}

PhysicsConstraint physicsConstraintFromJson(const JsonValue& j) {
    PhysicsConstraint c;
    c.id_ = uuidFromJson(*j.find("id"));
    c.name_ = j.find("name")->asString();
    c.enabled_ = j.find("enabled")->asBool();
    c.order_ = j.find("order")->asInt();
    c.mix_ = j.find("mix")->asFloat();
    const JsonValue* physicsType = j.find("physicsType");
    c.physicsType = physicsType != nullptr ? physicsTypeFromName(physicsType->asString()) : PhysicsType::Spring;
    c.affectedBones = uuidArrayFromJson(*j.find("affectedBones"));
    c.settings = physicsSettingsFromJson(*j.find("settings"));
    return c;
}

JsonValue toJson(const Skeleton& skeleton) {
    JsonValue j = JsonValue::makeObject();

    JsonValue::Array bones;
    for (const auto& [id, bone] : skeleton.bones()) {
        (void)id;
        bones.push_back(toJson(bone));
    }
    j.set("bones", JsonValue::makeArray(std::move(bones)));
    j.set("rootIDs", uuidArrayToJson(skeleton.rootIDs));

    JsonValue::Array ik;
    for (const IKConstraint& c : skeleton.ikConstraints) ik.push_back(toJson(c));
    j.set("ikConstraints", JsonValue::makeArray(std::move(ik)));

    JsonValue::Array path;
    for (const PathConstraint& c : skeleton.pathConstraints) path.push_back(toJson(c));
    j.set("pathConstraints", JsonValue::makeArray(std::move(path)));

    JsonValue::Array transform;
    for (const TransformConstraint& c : skeleton.transformConstraints) transform.push_back(toJson(c));
    j.set("transformConstraints", JsonValue::makeArray(std::move(transform)));

    JsonValue::Array physics;
    for (const PhysicsConstraint& c : skeleton.physicsConstraints) physics.push_back(toJson(c));
    j.set("physicsConstraints", JsonValue::makeArray(std::move(physics)));

    return j;
}

Skeleton skeletonFromJson(const JsonValue& j) {
    Skeleton skeleton;
    for (const JsonValue& b : j.find("bones")->asArray()) skeleton.setBone(boneFromJson(b));
    skeleton.rootIDs = uuidArrayFromJson(*j.find("rootIDs"));

    // Each constraint array is optional in the Swift source purely for
    // backward compatibility with pre-constraint save files -- see this
    // file's header. `valueOr` with an empty array covers both "absent"
    // and "present but empty" the same way Swift's `?? []` does.
    //
    // `valueOr(...)` returns a JsonValue BY VALUE; each result is bound to
    // a named local here (not chained directly into `.asArray()` in the
    // range-for) so it outlives the loop body -- `.asArray()` returns a
    // reference into the JsonValue it's called on, and a temporary bound
    // only via that reference does NOT get its lifetime extended by the
    // range-for (lifetime extension only applies to a reference bound
    // directly to the temporary itself), so it would otherwise be
    // destroyed before the loop body runs -- same dangling-reference
    // class of bug as BinaryExporter.cpp's `orderedBones()` fix.
    const JsonValue ikArray = j.valueOr("ikConstraints", JsonValue::makeArray());
    for (const JsonValue& c : ikArray.asArray()) skeleton.ikConstraints.push_back(ikConstraintFromJson(c));

    const JsonValue pathArray = j.valueOr("pathConstraints", JsonValue::makeArray());
    for (const JsonValue& c : pathArray.asArray()) skeleton.pathConstraints.push_back(pathConstraintFromJson(c));

    const JsonValue transformArray = j.valueOr("transformConstraints", JsonValue::makeArray());
    for (const JsonValue& c : transformArray.asArray()) {
        skeleton.transformConstraints.push_back(transformConstraintFromJson(c));
    }

    const JsonValue physicsArray = j.valueOr("physicsConstraints", JsonValue::makeArray());
    for (const JsonValue& c : physicsArray.asArray()) {
        skeleton.physicsConstraints.push_back(physicsConstraintFromJson(c));
    }
    return skeleton;
}

} // namespace umeshcore
