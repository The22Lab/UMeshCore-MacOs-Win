#pragma once

// JSON conversions for the small value types `Data/ProjectPersistence.swift`
// calls `SavedSIMD2`/`SavedSIMD3`/`SavedSIMD4`/`SavedMatrix4x4`/
// `SavedScale2` -- the geometry primitives used inside nearly every other
// `Saved*` struct. Free functions rather than methods on `Vec2`/`Vec3`/
// `Vec4`/`Mat4` themselves, matching this port's existing convention of
// keeping serialization concerns out of the core math types (see
// `Serialization/BinaryExporter.h`'s equivalent free-function shape).
//
// `Mat4` is written as a flat 16-element JSON array (column-major, matching
// this type's own `columns[0..3]` storage) rather than Swift's
// `SavedMatrix4x4`'s 16 individually-named `m00`..`m33` fields -- more
// compact, still fully self-describing and round-trippable, and (per this
// module's whole file family) not trying for Swift byte-parity in this
// increment. `scale2FromJson` alone preserves a Swift-specific quirk on the
// READ side: `SavedScale2`'s custom decoder accepts either a bare number
// (old files' uniform-scale shorthand) or an `{x,y}` object, so a JSON blob
// carrying that shorthand still parses correctly if one ever needs reading;
// this module's own writer always emits the `{x,y}` object form since there
// is no reason for new output to use the shorthand.

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Serialization/Json.h"

namespace umeshcore {

// A UUID is a JSON string in every `Saved*` struct (Swift `UUID` is
// `Codable` as its canonical 8-4-4-4-12 hex string). Throws
// std::runtime_error via Uuid::parse's caller-side check if malformed --
// see uuidFromJson's definition.
JsonValue toJson(const Uuid& id);
Uuid uuidFromJson(const JsonValue& j);

JsonValue toJson(const Vec2& v);
Vec2 vec2FromJson(const JsonValue& j);

JsonValue toJson(const Vec3& v);
Vec3 vec3FromJson(const JsonValue& j);

JsonValue toJson(const Vec4& v);
Vec4 vec4FromJson(const JsonValue& j);

JsonValue toJson(const Mat4& m);
Mat4 mat4FromJson(const JsonValue& j);

// See file header: accepts a bare number (uniform scale) or an {x,y} object.
Vec2 scale2FromJson(const JsonValue& j);

} // namespace umeshcore
