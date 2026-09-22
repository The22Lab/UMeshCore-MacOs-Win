import XCTest
import UMeshCore

/// Slice 0 of the Phase 6a migration: does Swift/C++ interop actually work
/// in this project, at all?
///
/// Nothing here tests UMeshCore's behaviour — that is what the 53 C++ test
/// binaries are for (`cd UMeshCore && cmake --build build -j4 && ctest`).
/// This file answers a build question, and it is the ONLY thing that can
/// answer it, because the environment the migration was written in has no
/// Swift toolchain: `swift`, `swiftc` and `xcodebuild` are all absent
/// there, so every Swift file in this migration reaches you compiled zero
/// times.
///
/// If this target builds and these four tests pass, the following are all
/// proven at once and the rest of the migration rests on solid ground:
///
///   1. `SWIFT_OBJC_INTEROP_MODE = objcxx` took effect (otherwise
///      `import UMeshCore` fails outright, or buries you in parse errors
///      from inside `<variant>`).
///   2. `SWIFT_INCLUDE_PATHS` / `HEADER_SEARCH_PATHS` reach
///      `UMeshCore/include`, so Clang finds `module.modulemap` beside the
///      header tree.
///   3. The `UMeshCore/src` synchronized group really is compiling the
///      ~53 C++ translation units into the app — `versionString()` is
///      defined in `Version.cpp`, so a link error here means the group
///      did not take.
///   4. The C++ types arrive in Swift with usable shapes.
///
/// If it FAILS, the failure is in the project file, not in the core. The
/// four settings that make it work live in the two project-level
/// `buildSettings` blocks of `UltraMesh.xcodeproj/project.pbxproj`.
final class UMeshCoreInteropSmokeTests: XCTestCase {

    /// The cheapest possible question: does the module import and is the
    /// library actually linked?
    ///
    /// `kVersionMajor` is a `constexpr int` — a header-only constant, so it
    /// proves the HEADERS are visible. `versionString()` is defined in a
    /// `.cpp`, so it proves the SOURCES are compiled and linked. Both,
    /// deliberately: the first can pass while the second fails, and that
    /// exact combination means the synchronized group is missing.
    func testModuleImportsAndLibraryIsLinked() {
        XCTAssertEqual(umeshcore.kVersionMajor, 0)
        XCTAssertEqual(umeshcore.kVersionMinor, 1)

        let version = String(cString: umeshcore.versionString())
        XCTAssertFalse(version.isEmpty)
    }

    /// A plain value type crossing the boundary.
    ///
    /// `Vec2` is the shape every other value type in the core is built on,
    /// and it is the one that has to bridge cleanly for the Slice 1 bridge
    /// (`SIMD2<Float>` ↔ `Vec2`) to be possible at all.
    func testValueTypesCrossWithTheirFieldsIntact() {
        let v = umeshcore.Vec2(3, 4)
        XCTAssertEqual(v.x, 3)
        XCTAssertEqual(v.y, 4)

        // A free function in the namespace, on those values. Hand-derived:
        // 3*3 + 4*4 = 25, and the length is the 3-4-5 triangle.
        XCTAssertEqual(umeshcore.dot(v, v), 25)
        XCTAssertEqual(umeshcore.length(v), 5, accuracy: 1e-6)
    }

    /// A type with methods, constants and its own semantics — not just a
    /// bag of floats.
    ///
    /// `SceneLightMask` is `constexpr` throughout and has no `std::` types
    /// in its surface, which makes it the safest non-trivial thing to try
    /// first. The property asserted is the real one: a light reaches a
    /// surface when their masks SHARE a channel, which is an intersection
    /// test and not a containment one.
    func testATypeWithMethodsBehavesTheSameThroughInterop() {
        // Built from the raw value rather than with `operator|`: Swift's
        // C++ interop imports arithmetic and comparison operators, but
        // bitwise ones are not guaranteed, and a smoke test must not fail
        // for a reason that has nothing to do with what it is testing.
        // Channels 1 and 2 are bits 0 and 1.
        let light = umeshcore.SceneLightMask(0b0000_0011)
        let layer = umeshcore.SceneLightMask.layer2()

        XCTAssertTrue(light.reaches(layer))
        XCTAssertFalse(umeshcore.SceneLightMask.layer3().reaches(layer))
        XCTAssertEqual(umeshcore.SceneLightMask.all().rawValue, 0xFF)
    }

    /// A real algorithm, with a value derived by hand rather than from the
    /// port's own output — the convention every UMeshCore test follows.
    ///
    /// `ScenePlayback` is a good first choice because its clock is
    /// INJECTED (there is no portable `CACurrentMediaTime()`, so every
    /// entry point takes the instant), which makes it exactly reproducible
    /// from a test. At 24 fps, one second after the start the playhead is
    /// on frame 24 — and it FLOORS rather than rounds, so nine tenths of a
    /// frame in it is still on the frame before.
    func testARealAlgorithmAgreesWithTheCppSuite() {
        var session = umeshcore.ScenePlayback.Session()
        session.startTime = 0
        session.startFrame = 0
        session.framesPerSecond = 24
        session.lastFrame = 47
        session.loops = false

        XCTAssertEqual(umeshcore.ScenePlayback.playhead(1.0, session).frame, 24)
        XCTAssertEqual(umeshcore.ScenePlayback.playhead(0.9 / 24.0, session).frame, 0)

        // The shot ends when the playhead LEAVES the last frame, not when
        // it reaches it: frame 47 runs until 48/24 s.
        XCTAssertFalse(umeshcore.ScenePlayback.playhead(47.5 / 24.0, session).ended)
        XCTAssertTrue(umeshcore.ScenePlayback.playhead(48.0 / 24.0, session).ended)
    }
}
