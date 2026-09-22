#include "umeshcore/Serialization/SavedGeometry.h"

#include <stdexcept>

namespace umeshcore {

JsonValue toJson(const Uuid& id) { return JsonValue::makeString(id.toString()); }

Uuid uuidFromJson(const JsonValue& j) {
    const std::optional<Uuid> parsed = Uuid::parse(j.asString());
    if (!parsed.has_value()) throw std::runtime_error("uuidFromJson: malformed UUID string: " + j.asString());
    return *parsed;
}

JsonValue toJson(const Vec2& v) {
    JsonValue j = JsonValue::makeObject();
    j.set("x", JsonValue::makeNumber(v.x));
    j.set("y", JsonValue::makeNumber(v.y));
    return j;
}

Vec2 vec2FromJson(const JsonValue& j) {
    return Vec2(j.find("x")->asFloat(), j.find("y")->asFloat());
}

JsonValue toJson(const Vec3& v) {
    JsonValue j = JsonValue::makeObject();
    j.set("x", JsonValue::makeNumber(v.x));
    j.set("y", JsonValue::makeNumber(v.y));
    j.set("z", JsonValue::makeNumber(v.z));
    return j;
}

Vec3 vec3FromJson(const JsonValue& j) {
    return Vec3(j.find("x")->asFloat(), j.find("y")->asFloat(), j.find("z")->asFloat());
}

JsonValue toJson(const Vec4& v) {
    JsonValue j = JsonValue::makeObject();
    j.set("x", JsonValue::makeNumber(v.x));
    j.set("y", JsonValue::makeNumber(v.y));
    j.set("z", JsonValue::makeNumber(v.z));
    j.set("w", JsonValue::makeNumber(v.w));
    return j;
}

Vec4 vec4FromJson(const JsonValue& j) {
    return Vec4(j.find("x")->asFloat(), j.find("y")->asFloat(), j.find("z")->asFloat(), j.find("w")->asFloat());
}

JsonValue toJson(const Mat4& m) {
    JsonValue::Array arr;
    for (int c = 0; c < 4; ++c) {
        arr.push_back(JsonValue::makeNumber(m.columns[c].x));
        arr.push_back(JsonValue::makeNumber(m.columns[c].y));
        arr.push_back(JsonValue::makeNumber(m.columns[c].z));
        arr.push_back(JsonValue::makeNumber(m.columns[c].w));
    }
    return JsonValue::makeArray(std::move(arr));
}

Mat4 mat4FromJson(const JsonValue& j) {
    const JsonValue::Array& arr = j.asArray();
    Mat4 m;
    for (int c = 0; c < 4; ++c) {
        m.columns[c] = Vec4(
            arr[static_cast<std::size_t>(c * 4 + 0)].asFloat(), arr[static_cast<std::size_t>(c * 4 + 1)].asFloat(),
            arr[static_cast<std::size_t>(c * 4 + 2)].asFloat(), arr[static_cast<std::size_t>(c * 4 + 3)].asFloat());
    }
    return m;
}

Vec2 scale2FromJson(const JsonValue& j) {
    if (j.isNumber()) {
        const float scalar = j.asFloat();
        return Vec2(scalar, scalar);
    }
    return vec2FromJson(j);
}

} // namespace umeshcore
