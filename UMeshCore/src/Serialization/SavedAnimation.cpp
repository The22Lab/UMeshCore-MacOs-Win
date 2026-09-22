#include "umeshcore/Serialization/SavedAnimation.h"

#include <array>
#include <unordered_map>
#include <variant>

#include "umeshcore/Serialization/SavedGeometry.h"

namespace umeshcore {

namespace {

// Swift's `AnimationTrackProperty` case names, in this enum's declaration
// order so the table can be indexed directly. Verified case-by-case against
// the Swift enum declaration (Data/Keyframe.swift) -- a String-raw-valued
// enum with no explicit raw values, so rawValue == case name.
constexpr std::array<const char*, kAnimationTrackPropertyCount> kTrackPropertyNames{
    "translate",
    "rotate",
    "scale",
    "shear",
    "meshDeform",
    "constraintMix",
    "ikSoftness",
    "ikBendPositive",
    "ikStretch",
    "ikCompress",
    "transformRotateMix",
    "transformTranslateMix",
    "transformScaleMix",
    "transformShearMix",
    "pathPosition",
    "pathSpacing",
    "pathPositionMix",
    "pathRotateMix",
    "physicsMass",
    "physicsDamping",
    "physicsStiffness",
    "physicsGravity",
    "physicsDrag",
    "physicsWind",
    "cameraTranslate",
    "cameraTranslateZ",
    "cameraRotate3D",
    "cameraRoll",
    "cameraFOV",
    "lightTranslate",
    "lightTranslateZ",
    "lightIntensity",
    "lightRadius",
    "lightSoftness",
    "lightDirection",
    "lightAngles",
    "lightColorR",
    "lightColorG",
    "lightColorB",
    "drawOrder",
    "attachment",
    "event",
};

JsonValue vec2ArrayToJson(const std::vector<Vec2>& values) {
    JsonValue::Array arr;
    arr.reserve(values.size());
    for (const Vec2& v : values) arr.push_back(toJson(v));
    return JsonValue::makeArray(std::move(arr));
}

JsonValue uuidArrayToJson(const std::vector<Uuid>& ids) {
    JsonValue::Array arr;
    arr.reserve(ids.size());
    for (const Uuid& id : ids) arr.push_back(toJson(id));
    return JsonValue::makeArray(std::move(arr));
}

} // namespace

const char* trackPropertyName(AnimationTrackProperty property) {
    const int index = static_cast<int>(property);
    if (index < 0 || index >= kAnimationTrackPropertyCount) return "translate";
    return kTrackPropertyNames[static_cast<std::size_t>(index)];
}

AnimationTrackProperty trackPropertyFromName(const std::string& name) {
    static const std::unordered_map<std::string, AnimationTrackProperty> lookup = [] {
        std::unordered_map<std::string, AnimationTrackProperty> map;
        for (int i = 0; i < kAnimationTrackPropertyCount; ++i) {
            map.emplace(kTrackPropertyNames[static_cast<std::size_t>(i)], static_cast<AnimationTrackProperty>(i));
        }
        return map;
    }();
    const auto it = lookup.find(name);
    return it == lookup.end() ? AnimationTrackProperty::Translate : it->second;
}

const char* interpolationName(KeyframeInterpolation interpolation) {
    switch (interpolation) {
        case KeyframeInterpolation::Hold: return "hold";
        case KeyframeInterpolation::Linear: return "linear";
        case KeyframeInterpolation::Bezier: return "bezier";
    }
    return "linear";
}

KeyframeInterpolation interpolationFromName(const std::string& name) {
    if (name == "hold") return KeyframeInterpolation::Hold;
    if (name == "bezier") return KeyframeInterpolation::Bezier;
    return KeyframeInterpolation::Linear; // matches Swift's `?? .linear`.
}

JsonValue toJson(const KeyframeValue& value) {
    JsonValue j = JsonValue::makeObject();
    struct Visitor {
        JsonValue& out;
        void operator()(const TranslateValue& v) const {
            out.set("kind", JsonValue::makeString("translate"));
            out.set("vector2", toJson(v.value));
        }
        void operator()(const RotateValue& v) const {
            out.set("kind", JsonValue::makeString("rotate"));
            out.set("scalar", JsonValue::makeNumber(v.value));
        }
        void operator()(const ScaleValue& v) const {
            out.set("kind", JsonValue::makeString("scale"));
            out.set("vector2", toJson(v.value));
        }
        void operator()(const ShearValue& v) const {
            out.set("kind", JsonValue::makeString("shear"));
            out.set("vector2", toJson(v.value));
        }
        void operator()(const MeshDeformValue& v) const {
            out.set("kind", JsonValue::makeString("meshDeform"));
            out.set("vectorArray", vec2ArrayToJson(v.value));
        }
        void operator()(const ScalarValue& v) const {
            out.set("kind", JsonValue::makeString("scalar"));
            out.set("scalar", JsonValue::makeNumber(v.value));
        }
        void operator()(const FlagValue& v) const {
            out.set("kind", JsonValue::makeString("flag"));
            out.set("flag", JsonValue::makeBool(v.value));
        }
        void operator()(const Vector2Value& v) const {
            out.set("kind", JsonValue::makeString("vector2"));
            out.set("vector2", toJson(v.value));
        }
        void operator()(const DrawOrderValue& v) const {
            out.set("kind", JsonValue::makeString("drawOrder"));
            out.set("idArray", uuidArrayToJson(v.value));
        }
        void operator()(const AttachmentValue& v) const {
            // 0-or-1-element array, never an optional id -- see the header.
            out.set("kind", JsonValue::makeString("attachment"));
            JsonValue::Array ids;
            if (v.value.has_value()) ids.push_back(toJson(*v.value));
            out.set("idArray", JsonValue::makeArray(std::move(ids)));
        }
        void operator()(const EventValue& v) const {
            // Each field is written only when set: absent means "inherit the
            // event definition's default", which is NOT the same as 0/"".
            out.set("kind", JsonValue::makeString("event"));
            if (v.value.intValue.has_value()) out.set("eventInt", JsonValue::makeNumber(*v.value.intValue));
            if (v.value.floatValue.has_value()) out.set("eventFloat", JsonValue::makeNumber(*v.value.floatValue));
            if (v.value.stringValue.has_value()) out.set("eventString", JsonValue::makeString(*v.value.stringValue));
        }
    };
    std::visit(Visitor{j}, value);
    return j;
}

KeyframeValue keyframeValueFromJson(const JsonValue& j) {
    const JsonValue* kindValue = j.find("kind");
    const std::string kind = kindValue != nullptr ? kindValue->asString() : std::string();
    const JsonValue* vector2 = j.find("vector2");
    const JsonValue* scalar = j.find("scalar");

    if (kind == "translate") {
        return TranslateValue{vector2 != nullptr ? vec2FromJson(*vector2) : Vec2::zero()};
    }
    if (kind == "rotate") {
        return RotateValue{scalar != nullptr ? scalar->asFloat() : 0.0f};
    }
    if (kind == "scale") {
        // `vector2 ?? SIMD2(repeating: scalar ?? 1)` -- see the header.
        if (vector2 != nullptr) return ScaleValue{vec2FromJson(*vector2)};
        const float uniform = scalar != nullptr ? scalar->asFloat() : 1.0f;
        return ScaleValue{Vec2(uniform, uniform)};
    }
    if (kind == "shear") {
        return ShearValue{vector2 != nullptr ? vec2FromJson(*vector2) : Vec2::zero()};
    }
    if (kind == "meshDeform") {
        std::vector<Vec2> offsets;
        const JsonValue* vectorArray = j.find("vectorArray");
        if (vectorArray != nullptr) {
            for (const JsonValue& v : vectorArray->asArray()) offsets.push_back(vec2FromJson(v));
        }
        return MeshDeformValue{std::move(offsets)};
    }
    if (kind == "scalar") {
        return ScalarValue{scalar != nullptr ? scalar->asFloat() : 0.0f};
    }
    if (kind == "flag") {
        const JsonValue* flag = j.find("flag");
        return FlagValue{flag != nullptr && flag->asBool()};
    }
    if (kind == "vector2") {
        return Vector2Value{vector2 != nullptr ? vec2FromJson(*vector2) : Vec2::zero()};
    }
    if (kind == "drawOrder" || kind == "attachment") {
        std::vector<Uuid> ids;
        const JsonValue* idArray = j.find("idArray");
        if (idArray != nullptr) {
            for (const JsonValue& v : idArray->asArray()) ids.push_back(uuidFromJson(v));
        }
        if (kind == "drawOrder") return DrawOrderValue{std::move(ids)};
        // attachment: the array's first element, or "slot deliberately empty".
        AttachmentValue attachment;
        if (!ids.empty()) attachment.value = ids.front();
        return attachment;
    }
    if (kind == "event") {
        AnimationEventPayload payload;
        const JsonValue* eventInt = j.find("eventInt");
        if (eventInt != nullptr && !eventInt->isNull()) payload.intValue = eventInt->asInt();
        const JsonValue* eventFloat = j.find("eventFloat");
        if (eventFloat != nullptr && !eventFloat->isNull()) payload.floatValue = eventFloat->asFloat();
        const JsonValue* eventString = j.find("eventString");
        if (eventString != nullptr && !eventString->isNull()) payload.stringValue = eventString->asString();
        return EventValue{payload};
    }
    // Unknown kind -- matches Swift's `default: return .translate(.zero)`.
    return TranslateValue{Vec2::zero()};
}

JsonValue toJson(const Keyframe& keyframe) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(keyframe.id));
    j.set("frame", JsonValue::makeNumber(keyframe.frame));
    j.set("value", toJson(keyframe.value));
    j.set("interpolation", JsonValue::makeString(interpolationName(keyframe.interpolation)));
    if (keyframe.inTangent.has_value()) j.set("inTangent", toJson(*keyframe.inTangent));
    if (keyframe.outTangent.has_value()) j.set("outTangent", toJson(*keyframe.outTangent));
    if (keyframe.secondaryInTangent.has_value()) j.set("secondaryInTangent", toJson(*keyframe.secondaryInTangent));
    if (keyframe.secondaryOutTangent.has_value()) j.set("secondaryOutTangent", toJson(*keyframe.secondaryOutTangent));
    return j;
}

Keyframe keyframeFromJson(const JsonValue& j) {
    const JsonValue* inTangent = j.find("inTangent");
    const JsonValue* outTangent = j.find("outTangent");
    const JsonValue* secondaryIn = j.find("secondaryInTangent");
    const JsonValue* secondaryOut = j.find("secondaryOutTangent");

    // Goes through Keyframe's own constructor rather than assigning fields,
    // so its stepped-interpolation rule (flag/drawOrder/event/attachment
    // payloads are always Hold) applies here exactly as it does everywhere
    // else a keyframe is built.
    Keyframe keyframe(
        j.find("frame")->asInt(), keyframeValueFromJson(*j.find("value")),
        interpolationFromName(j.find("interpolation")->asString()),
        inTangent != nullptr ? std::optional<Vec2>(vec2FromJson(*inTangent)) : std::nullopt,
        outTangent != nullptr ? std::optional<Vec2>(vec2FromJson(*outTangent)) : std::nullopt,
        secondaryIn != nullptr ? std::optional<Vec2>(vec2FromJson(*secondaryIn)) : std::nullopt,
        secondaryOut != nullptr ? std::optional<Vec2>(vec2FromJson(*secondaryOut)) : std::nullopt);
    keyframe.id = uuidFromJson(*j.find("id"));
    return keyframe;
}

JsonValue toJson(const AnimationTrack& track) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(track.id));
    j.set("targetID", toJson(track.targetID));
    j.set("property", JsonValue::makeString(trackPropertyName(track.property)));
    JsonValue::Array keyframes;
    keyframes.reserve(track.keyframes.size());
    for (const Keyframe& kf : track.keyframes) keyframes.push_back(toJson(kf));
    j.set("keyframes", JsonValue::makeArray(std::move(keyframes)));
    return j;
}

AnimationTrack animationTrackFromJson(const JsonValue& j) {
    std::vector<Keyframe> keyframes;
    for (const JsonValue& kf : j.find("keyframes")->asArray()) keyframes.push_back(keyframeFromJson(kf));

    AnimationTrack track(
        uuidFromJson(*j.find("targetID")), trackPropertyFromName(j.find("property")->asString()),
        std::move(keyframes));
    track.id = uuidFromJson(*j.find("id"));
    return track;
}

JsonValue toJson(const AnimationClip& clip) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(clip.id));
    j.set("name", JsonValue::makeString(clip.name));
    j.set("durationInFrames", JsonValue::makeNumber(clip.durationInFrames));
    JsonValue::Array tracks;
    tracks.reserve(clip.tracks().size());
    for (const AnimationTrack& track : clip.tracks()) tracks.push_back(toJson(track));
    j.set("tracks", JsonValue::makeArray(std::move(tracks)));
    return j;
}

AnimationClip animationClipFromJson(const JsonValue& j) {
    std::vector<AnimationTrack> tracks;
    for (const JsonValue& t : j.find("tracks")->asArray()) tracks.push_back(animationTrackFromJson(t));

    AnimationClip clip(j.find("name")->asString(), j.find("durationInFrames")->asInt(), std::move(tracks));
    clip.id = uuidFromJson(*j.find("id"));
    return clip;
}

JsonValue toJson(const AnimationEvent& event) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(event.id));
    j.set("name", JsonValue::makeString(event.name));
    j.set("defaultInt", JsonValue::makeNumber(event.defaultInt));
    j.set("defaultFloat", JsonValue::makeNumber(event.defaultFloat));
    j.set("defaultString", JsonValue::makeString(event.defaultString));
    j.set("audioPath", JsonValue::makeString(event.audioPath));
    j.set("volume", JsonValue::makeNumber(event.volume));
    j.set("balance", JsonValue::makeNumber(event.balance));
    return j;
}

AnimationEvent animationEventFromJson(const JsonValue& j) {
    AnimationEvent event;
    event.id = uuidFromJson(*j.find("id"));
    event.name = j.find("name")->asString();
    event.defaultInt = j.find("defaultInt")->asInt();
    event.defaultFloat = j.find("defaultFloat")->asFloat();
    event.defaultString = j.find("defaultString")->asString();
    event.audioPath = j.find("audioPath")->asString();
    event.volume = j.find("volume")->asFloat();
    event.balance = j.find("balance")->asFloat();
    return event;
}

JsonValue constraintSetupValuesToJson(const Uuid& constraintID, const ConstraintSetupValues& values) {
    JsonValue j = JsonValue::makeObject();
    j.set("constraintID", toJson(constraintID));

    JsonValue scalars = JsonValue::makeObject();
    for (const auto& [property, value] : values.scalars) {
        scalars.set(trackPropertyName(property), JsonValue::makeNumber(value));
    }
    j.set("scalars", scalars);

    JsonValue flags = JsonValue::makeObject();
    for (const auto& [property, value] : values.flags) {
        flags.set(trackPropertyName(property), JsonValue::makeBool(value));
    }
    j.set("flags", flags);

    JsonValue vectors = JsonValue::makeObject();
    for (const auto& [property, value] : values.vectors) {
        vectors.set(trackPropertyName(property), toJson(value));
    }
    j.set("vectors", vectors);

    return j;
}

Uuid constraintSetupValuesIDFromJson(const JsonValue& j) { return uuidFromJson(*j.find("constraintID")); }

ConstraintSetupValues constraintSetupValuesFromJson(const JsonValue& j) {
    ConstraintSetupValues values;
    const JsonValue* scalars = j.find("scalars");
    if (scalars != nullptr) {
        for (const auto& [name, value] : scalars->asObject()) {
            values.scalars[trackPropertyFromName(name)] = value.asFloat();
        }
    }
    const JsonValue* flags = j.find("flags");
    if (flags != nullptr) {
        for (const auto& [name, value] : flags->asObject()) {
            values.flags[trackPropertyFromName(name)] = value.asBool();
        }
    }
    const JsonValue* vectors = j.find("vectors");
    if (vectors != nullptr) {
        for (const auto& [name, value] : vectors->asObject()) {
            values.vectors[trackPropertyFromName(name)] = vec2FromJson(value);
        }
    }
    return values;
}

} // namespace umeshcore
