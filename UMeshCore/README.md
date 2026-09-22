# UMeshCore

Portable C++20 core extracted from the UltraMesh 2D Animation Swift/Metal
app (`../UltraMesh 2d animation/`), so macOS and Windows can share one
implementation of the rig/mesh/animation/editor engine — same tools, same
gizmos, same numeric behavior — while each platform keeps its own native UI
and GPU renderer (SwiftUI+Metal on macOS, WinUI 3 + DirectX on Windows).

This is a large, multi-phase port (the Swift source is ~69,000 lines). See
`ROADMAP.md` for the phase plan, dependency order, and named risks.

## Directory layout

```
UMeshCore/
  include/umeshcore/   public headers, mirrors the Swift Data/ + Core/ + Render/ layout
    Math/              Transform3D2D, MatrixUtilities, Vec/Mat4, Angle
    Core/              Uuid and other cross-cutting primitives
    Model/             Bone, Skeleton, Mesh, Skin (Phase 1, in progress)
    Constraints/        IK/Path/Transform/Physics solvers (Phase 1, pending)
    Animation/         AnimationCurve, Keyframe, AnimationClip, AnimationEvent (done)
    Serialization/      UMSH binary + project JSON + UMJSON (Phase 3, pending)
  src/                 .cpp implementation, mirrors include/
  tests/               dependency-free unit tests (see TestHarness.h) plus
                        a future tests/golden/ of JSON dumps from the Swift app
  bindings/
    swift/             Swift/C++ interop audit + module map notes (Phase 6a)
    win/                WinUI3/C++ consumption notes (Phase 6b)
  include/module.modulemap   the Clang module that makes `import UMeshCore` work
  tools/golden_dump/    (planned) Swift CLI that dumps deterministic
                        reference outputs for C++ parity tests
```

## Build

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j
ctest --test-dir build --output-on-failure
```

To consume it from another project (either shell):

```sh
cmake --install build --prefix <prefix>
```

then `find_package(UMeshCore)` and link `UMeshCore::umeshcore`. The
installed tree carries `include/module.modulemap` beside the headers, so a
Swift target with `<prefix>/include` on its search path and
`-cxx-interoperability-mode=default` can `import UMeshCore`. See
`bindings/swift/README.md` for what does and does not cross into Swift
unchanged.

Requires a C++20 compiler (GCC 13+/Clang/MSVC all fine) and CMake >= 3.20.
No external dependencies by design (see ROADMAP.md's math-library rationale).

## Testing philosophy

Every ported function is tested two ways where possible:

1. **Hand-derived golden values**, computed from the Swift source's own
   documented formulas (not the C++ port itself), so a transcription bug is
   actually caught rather than tautologically confirmed.
2. **Independent cross-checks** (e.g. `SlotAnimationTarget::id`'s FNV-1a
   hash is verified against a from-scratch Python re-implementation of the
   documented algorithm in `tests/AnimationTests.cpp`), used when a golden
   value can't practically be hand-computed.

True Swift-vs-C++ parity (byte-identical output from the real Swift app)
requires a `tools/golden_dump` Swift harness run on a Mac toolchain, which
this Linux development environment cannot do — that step is called out
explicitly in `ROADMAP.md` §2 as follow-up work for whoever has Xcode access.

## Status

**See `../CLAUDE.md`** — the map: where each phase stands, what is still
pending and why, the Swift reference for every remaining piece, and the
four conventions this port holds to.

`ROADMAP.md` is the detailed running record: it grows with every increment
and explains each decision and divergence at length. `CLAUDE.md` is the
map; `ROADMAP.md` is the territory.

In short, at the time of writing: Phases 0-3 are complete except for work
that a later phase unblocks, Phase 4 (shared render geometry) is in
progress, and Phases 5-6 have not started.
