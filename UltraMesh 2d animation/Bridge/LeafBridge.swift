import CxxStdlib
import Foundation
import simd
import UMeshCore

// Phase 6a, stage B: the leaf conversions every other bridge file is built
// from -- identifiers, vectors, matrices, strings, and enums.
//
// THE RULE FOR THIS FOLDER. `Bridge/` converts; it never decides. Each
// function copies one shape of a value into the other shape of the SAME
// value, and `BridgeRoundTripTests` checks that out-and-back is the
// identity. Anything that would need a rule (clamping, defaulting,
// validating) belongs in UMeshCore, where it is tested, and not here.
//
// THE RULE FOR INTEROP. This environment had no Swift compiler when this was
// written, so it leans on the smallest set of interop features and lets
// UMeshCore's `Interop/SwiftModelBridge.h` do the rest in plain C++:
//
//   - C++ structs and their fields, read and assigned;
//   - `std::vector` iterated (`for x in v`, `map`) and built (`push_back`)
//     through the named aliases (`umeshcore.Vec2List`...);
//   - `std::string` <-> `String` (CxxStdlib);
//   - optionals, maps and enums ONLY through the helper functions, never by
//     touching `std::optional` / `std::unordered_map` / the C++ enum cases.

// MARK: - Identifiers

extension UUID {
    /// The same 128 bits. UMeshCore packs the first eight bytes big-endian
    /// into `hi` and the last eight into `lo`, which is the order both
    /// `Uuid::parse` and `Uuid::toString` read -- so `uuidString` and the C++
    /// string agree character for character (a test checks exactly that).
    init(core: umeshcore.Uuid) {
        let hi: UInt64 = core.hi
        let lo: UInt64 = core.lo
        let bytes: uuid_t = (
            UInt8(truncatingIfNeeded: hi >> 56), UInt8(truncatingIfNeeded: hi >> 48),
            UInt8(truncatingIfNeeded: hi >> 40), UInt8(truncatingIfNeeded: hi >> 32),
            UInt8(truncatingIfNeeded: hi >> 24), UInt8(truncatingIfNeeded: hi >> 16),
            UInt8(truncatingIfNeeded: hi >> 8), UInt8(truncatingIfNeeded: hi),
            UInt8(truncatingIfNeeded: lo >> 56), UInt8(truncatingIfNeeded: lo >> 48),
            UInt8(truncatingIfNeeded: lo >> 40), UInt8(truncatingIfNeeded: lo >> 32),
            UInt8(truncatingIfNeeded: lo >> 24), UInt8(truncatingIfNeeded: lo >> 16),
            UInt8(truncatingIfNeeded: lo >> 8), UInt8(truncatingIfNeeded: lo)
        )
        self.init(uuid: bytes)
    }

    var core: umeshcore.Uuid {
        let b = uuid
        // Built in two halves of four statements: one sixteen-term expression
        // is the kind the type checker gives up on.
        var hi: UInt64 = UInt64(b.0) << 56 | UInt64(b.1) << 48
        hi |= UInt64(b.2) << 40 | UInt64(b.3) << 32
        hi |= UInt64(b.4) << 24 | UInt64(b.5) << 16
        hi |= UInt64(b.6) << 8 | UInt64(b.7)
        var lo: UInt64 = UInt64(b.8) << 56 | UInt64(b.9) << 48
        lo |= UInt64(b.10) << 40 | UInt64(b.11) << 32
        lo |= UInt64(b.12) << 24 | UInt64(b.13) << 16
        lo |= UInt64(b.14) << 8 | UInt64(b.15)
        return umeshcore.Uuid(hi, lo)
    }
}

enum CoreUUID {
    /// The all-zero id: what an absent optional carries as its ignored
    /// payload (`makeOptionalUuid(false, _)` never reads it).
    static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// `UUID(core:)` under a name no other initializer competes with.
    ///
    /// From the test target, `UUID(core:)` did not resolve: the compiler
    /// offered only `UUID()` ("argument passed to call that takes no
    /// arguments") while `SIMD2<Float>(core:)` and `id.core` resolved
    /// fine in the same file. A static function on a type this module owns
    /// has one candidate and nothing to lose it to.
    static func uuid(_ core: umeshcore.Uuid) -> UUID { UUID(core: core) }

    static func optional(_ core: umeshcore.OptionalUuid) -> UUID? {
        umeshcore.optionalHasUuid(core) ? UUID(core: umeshcore.optionalUuid(core)) : nil
    }

    static func optional(_ value: UUID?) -> umeshcore.OptionalUuid {
        umeshcore.makeOptionalUuid(value != nil, (value ?? zero).core)
    }

    static func list(_ core: umeshcore.UuidList) -> [UUID] {
        core.map { UUID(core: $0) }
    }

    static func list(_ values: [UUID]) -> umeshcore.UuidList {
        var out = umeshcore.UuidList()
        for value in values { out.push_back(value.core) }
        return out
    }
}

// MARK: - Vectors and matrices

extension SIMD2 where Scalar == Float {
    init(core: umeshcore.Vec2) { self.init(core.x, core.y) }
    var core: umeshcore.Vec2 { umeshcore.Vec2(x, y) }
}

extension SIMD3 where Scalar == Float {
    init(core: umeshcore.Vec3) { self.init(core.x, core.y, core.z) }
    var core: umeshcore.Vec3 { umeshcore.Vec3(x, y, z) }
}

extension SIMD4 where Scalar == Float {
    init(core: umeshcore.Vec4) { self.init(core.x, core.y, core.z, core.w) }
    var core: umeshcore.Vec4 { umeshcore.Vec4(x, y, z, w) }
}

extension simd_float4x4 {
    /// Column for column: both sides are column-major, and
    /// `umeshcore::Mat4::columns[i]` is `columns.i` here.
    init(core: umeshcore.Mat4) {
        self.init(columns: (
            SIMD4<Float>(core: umeshcore.mat4Column(core, 0)),
            SIMD4<Float>(core: umeshcore.mat4Column(core, 1)),
            SIMD4<Float>(core: umeshcore.mat4Column(core, 2)),
            SIMD4<Float>(core: umeshcore.mat4Column(core, 3))
        ))
    }

    var core: umeshcore.Mat4 {
        umeshcore.Mat4(columns.0.core, columns.1.core, columns.2.core, columns.3.core)
    }
}

enum CoreVec2 {
    static func list(_ core: umeshcore.Vec2List) -> [SIMD2<Float>] {
        core.map { SIMD2<Float>(core: $0) }
    }

    static func list(_ values: [SIMD2<Float>]) -> umeshcore.Vec2List {
        var out = umeshcore.Vec2List()
        for value in values { out.push_back(value.core) }
        return out
    }

    static func optional(_ core: umeshcore.OptionalVec2) -> SIMD2<Float>? {
        umeshcore.optionalHasVec2(core) ? SIMD2<Float>(core: umeshcore.optionalVec2(core)) : nil
    }

    static func optional(_ value: SIMD2<Float>?) -> umeshcore.OptionalVec2 {
        umeshcore.makeOptionalVec2(value != nil, (value ?? .zero).core)
    }

    static func optionalList(_ core: umeshcore.OptionalVec2List) -> [SIMD2<Float>]? {
        umeshcore.optionalHasVec2List(core) ? list(umeshcore.optionalVec2List(core)) : nil
    }

    static func optionalList(_ values: [SIMD2<Float>]?) -> umeshcore.OptionalVec2List {
        umeshcore.makeOptionalVec2List(values != nil, list(values ?? []))
    }
}

enum CoreVec4 {
    static func optional(_ core: umeshcore.OptionalVec4) -> SIMD4<Float>? {
        umeshcore.optionalHasVec4(core) ? SIMD4<Float>(core: umeshcore.optionalVec4(core)) : nil
    }

    static func optional(_ value: SIMD4<Float>?) -> umeshcore.OptionalVec4 {
        umeshcore.makeOptionalVec4(value != nil, (value ?? .zero).core)
    }
}

// MARK: - Scalars and strings

enum CoreScalar {
    /// C++ `int` is `Int32` here. Swift's `Int` is wider, so the way in
    /// clamps rather than traps: a frame number past two billion is not a
    /// reason to crash the editor.
    static func int32(_ value: Int) -> Int32 { Int32(clamping: value) }

    static func string(_ core: std.string) -> String { String(core) }
    static func string(_ value: String) -> std.string { std.string(value) }

    static func optionalInt(_ core: umeshcore.OptionalInt) -> Int? {
        umeshcore.optionalHasInt(core) ? Int(umeshcore.optionalInt(core)) : nil
    }

    static func optionalInt(_ value: Int?) -> umeshcore.OptionalInt {
        umeshcore.makeOptionalInt(value != nil, int32(value ?? 0))
    }

    static func optionalFloat(_ core: umeshcore.OptionalFloat) -> Float? {
        umeshcore.optionalHasFloat(core) ? umeshcore.optionalFloat(core) : nil
    }

    static func optionalFloat(_ value: Float?) -> umeshcore.OptionalFloat {
        umeshcore.makeOptionalFloat(value != nil, value ?? 0)
    }

    static func optionalString(_ core: umeshcore.OptionalString) -> String? {
        umeshcore.optionalHasString(core) ? String(umeshcore.optionalString(core)) : nil
    }

    static func optionalString(_ value: String?) -> umeshcore.OptionalString {
        umeshcore.makeOptionalString(value != nil, std.string(value ?? ""))
    }
}

// MARK: - Transform

extension Transform3D2D {
    init(core: umeshcore.Transform3D2D) {
        self.init(
            position: SIMD3<Float>(core: core.position),
            rotation: SIMD3<Float>(core: core.rotation),
            scale: SIMD3<Float>(core: core.scale),
            skew: SIMD2<Float>(core: core.skew)
        )
    }

    var core: umeshcore.Transform3D2D {
        umeshcore.Transform3D2D(position.core, rotation.core, scale.core, skew.core)
    }
}

// MARK: - Enums, paired by name

/// One Swift enum paired with one UMeshCore enum, case by case, through the
/// NAME both sides spell it with (the file-format raw value).
///
/// Built once: the C++ side lists its cases by index, each index's name is
/// looked up as a Swift raw value, and from then on converting is an array
/// or dictionary lookup. A C++ case with no Swift counterpart stops the app
/// at the first conversion, loudly, naming the case -- the alternative is a
/// value quietly read as some other case, which is the bug this avoids.
struct CoreEnumTable<Value: RawRepresentable & Hashable> where Value.RawValue == String {
    private let cases: [Value]
    private let indices: [Value: Int32]

    init(count: Int32, name: (Int32) -> String) {
        var cases: [Value] = []
        var indices: [Value: Int32] = [:]
        for index in 0..<count {
            let raw = name(index)
            guard let value = Value(rawValue: raw) else {
                preconditionFailure("UMeshCore case \"\(raw)\" has no counterpart in \(Value.self)")
            }
            cases.append(value)
            indices[value] = index
        }
        self.cases = cases
        self.indices = indices
    }

    /// The Swift case for the C++ case at `index`.
    func value(at index: Int32) -> Value { cases[Int(index)] }

    /// The C++ index of a Swift case.
    func index(of value: Value) -> Int32 {
        guard let index = indices[value] else {
            preconditionFailure("\(Value.self).\(value.rawValue) has no counterpart in UMeshCore")
        }
        return index
    }

    /// How many cases were paired -- for the test that every Swift case is.
    var count: Int { cases.count }
}

enum CoreEnums {
    static let trackProperty = CoreEnumTable<AnimationTrackProperty>(
        count: umeshcore.trackPropertyCaseCount()
    ) { String(cString: umeshcore.trackPropertyName(umeshcore.trackPropertyCase($0))) }

    static let interpolation = CoreEnumTable<KeyframeInterpolation>(
        count: umeshcore.interpolationCaseCount()
    ) { String(cString: umeshcore.interpolationName(umeshcore.interpolationCase($0))) }

    static let blendMode = CoreEnumTable<ImageBlendMode>(
        count: umeshcore.blendModeCaseCount()
    ) { String(cString: umeshcore.blendModeName(umeshcore.blendModeCase($0))) }

    static let hierarchyItemType = CoreEnumTable<HierarchyItem.ItemType>(
        count: umeshcore.hierarchyItemTypeCaseCount()
    ) { String(cString: umeshcore.hierarchyItemTypeName(umeshcore.hierarchyItemTypeCase($0))) }

    static let pathSpacingMode = CoreEnumTable<PathSpacingMode>(
        count: umeshcore.pathSpacingModeCaseCount()
    ) { String(cString: umeshcore.pathSpacingModeName(umeshcore.pathSpacingModeCase($0))) }

    static let pathRotateMode = CoreEnumTable<PathRotateMode>(
        count: umeshcore.pathRotateModeCaseCount()
    ) { String(cString: umeshcore.pathRotateModeName(umeshcore.pathRotateModeCase($0))) }

    static let physicsType = CoreEnumTable<PhysicsType>(
        count: umeshcore.physicsTypeCaseCount()
    ) { String(cString: umeshcore.physicsTypeName(umeshcore.physicsTypeCase($0))) }
}

extension AnimationTrackProperty {
    init(core: umeshcore.AnimationTrackProperty) {
        self = CoreEnums.trackProperty.value(at: umeshcore.trackPropertyCaseIndex(core))
    }

    var core: umeshcore.AnimationTrackProperty {
        umeshcore.trackPropertyCase(CoreEnums.trackProperty.index(of: self))
    }
}

extension KeyframeInterpolation {
    init(core: umeshcore.KeyframeInterpolation) {
        self = CoreEnums.interpolation.value(at: umeshcore.interpolationCaseIndex(core))
    }

    var core: umeshcore.KeyframeInterpolation {
        umeshcore.interpolationCase(CoreEnums.interpolation.index(of: self))
    }
}

extension ImageBlendMode {
    init(core: umeshcore.ImageBlendMode) {
        self = CoreEnums.blendMode.value(at: umeshcore.blendModeCaseIndex(core))
    }

    var core: umeshcore.ImageBlendMode {
        umeshcore.blendModeCase(CoreEnums.blendMode.index(of: self))
    }
}

extension HierarchyItem.ItemType {
    init(core: umeshcore.HierarchyItem.ItemType) {
        self = CoreEnums.hierarchyItemType.value(at: umeshcore.hierarchyItemTypeCaseIndex(core))
    }

    var core: umeshcore.HierarchyItem.ItemType {
        umeshcore.hierarchyItemTypeCase(CoreEnums.hierarchyItemType.index(of: self))
    }
}

extension PathSpacingMode {
    init(core: umeshcore.PathSpacingMode) {
        self = CoreEnums.pathSpacingMode.value(at: umeshcore.pathSpacingModeCaseIndex(core))
    }

    var core: umeshcore.PathSpacingMode {
        umeshcore.pathSpacingModeCase(CoreEnums.pathSpacingMode.index(of: self))
    }
}

extension PathRotateMode {
    init(core: umeshcore.PathRotateMode) {
        self = CoreEnums.pathRotateMode.value(at: umeshcore.pathRotateModeCaseIndex(core))
    }

    var core: umeshcore.PathRotateMode {
        umeshcore.pathRotateModeCase(CoreEnums.pathRotateMode.index(of: self))
    }
}

extension PhysicsType {
    init(core: umeshcore.PhysicsType) {
        self = CoreEnums.physicsType.value(at: umeshcore.physicsTypeCaseIndex(core))
    }

    var core: umeshcore.PhysicsType {
        umeshcore.physicsTypeCase(CoreEnums.physicsType.index(of: self))
    }
}
