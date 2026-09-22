#pragma once

// A minimal, dependency-free JSON value type + writer + parser, shared
// foundation for the two JSON-based formats Phase 3 still needs to port:
// the native `.umesh` project package (`Data/ProjectPersistence.swift`)
// and the UMJSON interchange format (`Export/JSON/*.swift`). Confirmed by
// direct research before writing this: both are plain JSON trees of
// objects/arrays/primitives, neither uses UUID-keyed JSON objects (both
// independently avoid that -- JSON object keys must be strings, so a
// `[UUID: T]` dictionary would need a hand-rolled string key anyway; the
// Swift source instead always uses arrays of `{id, value}`-shaped records,
// sorted for determinism, a pattern this port's future `Saved*`-equivalent
// encoders will mirror on top of this module), and neither needs a custom
// transport encoding beyond optional base64 text (UMJSON's embedded
// textures) -- which is just an ordinary JSON string to this module.
//
// Written fresh, not ported: Swift's JSON handling for both formats goes
// through `JSONEncoder`/`JSONDecoder` + `Codable`, which has no portable
// C++ equivalent, and this project's own "no external dependencies"
// principle (ROADMAP.md's Repository layout section) rules out adopting a
// third-party JSON library the same way it already ruled out GLM and
// GoogleTest/Catch2.
//
// Byte-parity with Swift's own `JSONEncoder([.sortedKeys, .prettyPrinted])`
// output is explicitly NOT a goal (same reasoning as `BinaryReader.h`'s
// file header): for the native project format, Swift's own app is the
// only thing that has ever read those files back, and this port isn't
// trying to make its own writer's bytes satisfy that Swift reader in this
// increment -- only to round-trip correctly against its OWN parser. UMJSON
// is write-only in Swift today (confirmed by grep -- no decoder anywhere),
// same situation the binary export format was in. Sorted keys and
// pretty-printing are kept as the default anyway (free, and matches the
// spirit of the Swift source's deterministic/diffable design goal), just
// not byte-identical to Swift's specific formatting choices (e.g. Swift
// pads `"key" : value`; this module writes `"key": value`).

#include <cstdint>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace umeshcore {

class JsonValue {
public:
    enum class Type { Null, Bool, Number, String, Array, Object };

    using Array = std::vector<JsonValue>;
    // std::map keeps keys in sorted order automatically -- the C++
    // equivalent of Swift's `JSONEncoder.OutputFormatting.sortedKeys`.
    using Object = std::map<std::string, JsonValue>;

    JsonValue() = default;

    static JsonValue makeNull() { return JsonValue(); }
    static JsonValue makeBool(bool v);
    static JsonValue makeNumber(double v);
    static JsonValue makeString(std::string v);
    static JsonValue makeArray(Array v = {});
    static JsonValue makeObject(Object v = {});

    Type type() const { return type_; }
    bool isNull() const { return type_ == Type::Null; }
    bool isBool() const { return type_ == Type::Bool; }
    bool isNumber() const { return type_ == Type::Number; }
    bool isString() const { return type_ == Type::String; }
    bool isArray() const { return type_ == Type::Array; }
    bool isObject() const { return type_ == Type::Object; }

    bool asBool() const;
    double asDouble() const;
    float asFloat() const { return static_cast<float>(asDouble()); }
    int asInt() const { return static_cast<int>(asDouble()); }
    std::int64_t asInt64() const { return static_cast<std::int64_t>(asDouble()); }
    std::uint16_t asUint16() const { return static_cast<std::uint16_t>(asDouble()); }
    std::uint32_t asUint32() const { return static_cast<std::uint32_t>(asDouble()); }
    const std::string& asString() const;
    const Array& asArray() const;
    Array& asArray();
    const Object& asObject() const;
    Object& asObject();

    // --- Object convenience ---

    void set(const std::string& key, JsonValue value);
    // nullptr if the key is absent.
    const JsonValue* find(const std::string& key) const;
    // Mirrors the `decodeIfPresent(...) ?? fallback` pattern
    // `ProjectPersistence.swift` uses throughout for backward compatibility
    // with older save files: returns `fallback` when the key is missing OR
    // present but JSON `null`, the value otherwise.
    JsonValue valueOr(const std::string& key, JsonValue fallback) const;

    // --- Array convenience ---

    void push_back(JsonValue value);

    // Serializes to text. `prettyPrinted` adds newlines and 2-space
    // indentation; object keys are always emitted in sorted order (see
    // `Object`'s type alias above).
    std::string dump(bool prettyPrinted = true) const;

    // Parses `text`. Throws std::runtime_error with a position-annotated
    // message on malformed input -- file/network input is untrusted, the
    // same posture `BinaryReader` takes with binary input.
    static JsonValue parse(const std::string& text);

private:
    void requireType(Type expected, const char* what) const;

    Type type_ = Type::Null;
    bool bool_ = false;
    double number_ = 0.0;
    std::string string_;
    Array array_;
    Object object_;
};

} // namespace umeshcore
