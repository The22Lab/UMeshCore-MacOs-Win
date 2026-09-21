# UMeshCore Port Roadmap

Context: `../UltraMesh 2d animation/` is a fully-functional, polished
Swift/SwiftUI/Metal 2D skeletal-mesh-animation editor (~69,000 lines). The
goal is a shared C++ core (`UMeshCore`) so macOS and a new Windows app get
identical rig/mesh/animation/editor/gizmo behavior, while each platform
keeps its own native UI and renderer. Per explicit user decision: the Mac
app's existing SwiftUI UI (panels, inspectors, icons, dark/light theme) is
migrated to *read from* UMeshCore progressively, but is never rewritten;
the Windows WinUI 3 UI is scaffolded early, in parallel with core work, not
deferred to the end.

## Repository layout & build

- CMake (C++20), one target (`umeshcore`) buildable identically by Mac
  (Xcode "Run Script"/external-build-system target invoking `cmake --build`)
  and Windows (WinUI3 project pre-build step invoking the same). This avoids
  hand-maintained duplicate file lists across two IDEs, which is the most
  likely source of platform drift for a port this size.
- `include/umeshcore/<Module>/*.h`, `src/<Module>/*.cpp`, 1:1 with the
  Swift source's own folder structure so any file's C++ counterpart is
  findable by name.
- No external dependencies. Math is a small custom header-only library
  (`Math/Vec.h`, `Math/Mat4.h`) that mirrors Swift `simd`'s exact
  conventions (column-major, same operator semantics) function-for-function,
  rather than adopting GLM — the Swift call sites are idiosyncratic enough
  (`.columns.0/1/2/3`, `matrix_float4x4(diagonal:)`, etc.) that translating
  to a different library's idiom at ~30 call sites per file would itself be
  a source of transcription bugs. Same reasoning for a dependency-free test
  harness (`tests/TestHarness.h`) instead of GoogleTest/Catch2, at least
  until network-dependent fetches are known to be reliable in every build
  environment this project targets.

## Swift/C++ interop (Mac)

The Xcode project already targets a very recent toolchain
(`MACOSX_DEPLOYMENT_TARGET = 26.3`, `CLANG_CXX_LANGUAGE_STANDARD = gnu++20`),
so **Swift/C++ direct interop** (no hand-written C ABI shim) is the right
choice: near-zero boilerplate for the value-type-heavy shape of this code
(Transform3D2D, Bone, keyframe structs). Expose a narrow, curated
`bindings/swift/` header subset rather than all of `include/umeshcore/`, so
internal headers (e.g. `MeshPredicates`'s exact-arithmetic internals) aren't
accidentally exposed and don't constrain future refactors.

## Windows consumption

WinUI 3 apps are native C++/WinRT, so this is a normal static-lib
dependency with zero interop tax — `#include "umeshcore/*.h"` directly.
Since this is the "no adapting needed" consumer, `UMeshCore`'s public API
should stay idiomatic modern C++, not shaped defensively around Swift's
interop limitations.

## Testing / validation strategy

True behavior parity requires a **golden-dump harness**: a small Swift CLI
tool (`tools/golden_dump/`, not yet built — needs a Mac/Xcode toolchain this
Linux dev environment doesn't have) that serializes deterministic Swift
outputs (skeleton poses, IK solves, mesh triangulations, animation curve
samples, the slot-hash for known names) to JSON, checked into
`tests/golden/`. C++ unit tests then replay identical inputs and diff
against those files with per-subsystem tolerances (bit-exact for anything
specified as deterministic-by-construction, e.g. the slot hash or FABRIK's
fixed iteration count; tight float tolerance elsewhere).

Until that harness exists, tests in this repo use **hand-derived golden
values** computed independently from the Swift source's documented formulas
(not from the C++ port itself — see each test file's header comment) plus,
where a value can't practically be hand-computed (e.g. the FNV-1a+finalizer
slot hash), an independent from-scratch re-implementation in another
language as a transcription cross-check. This catches C++ bugs but is *not*
a substitute for the real Swift-vs-C++ golden diff — flagged explicitly so
nobody mistakes "tests pass" for "verified identical to the Swift app."

Special-case validation needs, carried over into each phase's own tests:
- **Mesh kernel**: run `MeshValidator`'s I1-I11 invariants as a
  first-class safety net on every triangulation produced during tests, not
  just golden-diffed.
- **Determinism**: anywhere the Swift code explicitly avoids `Dictionary`
  iteration order (Lawson flips' explicit edge array), add a dedicated test
  that runs the operation twice and asserts byte-identical output — a
  `std::unordered_map`'s iteration order is its own, separate
  non-determinism risk, independent of Swift-parity.
- **Physics**: golden-dump must capture the *sequence* of fixed-timestep
  states (not just a final frame), since the catch-up-steps/renderAlpha
  interpolation is a temporal contract.
- **Exact arithmetic**: `MeshPredicates::orient2d`'s exactness proof depends
  on vertex coordinates being `float` (not `double`) promoted losslessly
  into `double`'s 53-bit significand — enforce this at the type level, add
  an analytic exactness test independent of any Swift golden.

## Phase order

1. **Math + data model foundation** — Transform3D2D, MatrixUtilities,
   Bone/Skeleton (+children-index cache), constraint framework +
   ConstraintPropagation, IKSolver (1-bone/2-bone/FABRIK), PathSolver,
   TransformConstraint, PhysicsConstraintSystem (**deliberately
   restructured to per-rig-instance state**, not the Swift source's process
   singleton — see Risks), MeshPredicates (exact arithmetic), MeshKernel
   (triangulation), MeshValidator, Mesh (skinning), Skin/SkinResolver,
   AnimationCurve, Keyframe, AnimationClip, AnimationEvent, AnimationLibrary.
   *Status: AnimationCurve/Keyframe/AnimationClip/AnimationEvent, Bone/
   Skeleton, all four constraint solvers, MeshPredicates, MeshKernel,
   MeshValidator, and Mesh (skinning/sanitization/auto-bind) are done and
   tested (Animation moved ahead of Bone/Skeleton in implementation order
   since Bone directly owns an AnimationClip value and needs it as a
   complete type — the two have no dependency in the other direction).
   Deferred from Mesh.swift as editor-time (not per-frame-runtime)
   conveniences: `generated()`/`generatedGrid` (procedural interior-point
   mesh generation for a freshly-created sprite mesh), the manual-triangle-
   face workflow (`sanitizedManualTriangles`,
   `triangulatedIndicesWithInternalEdges`), and the Auto-Bind bone-fit
   scoring heuristic (which bones a sprite *suggests* binding to — distinct
   from `autoBindWeights`, which is ported and does the actual binding).
   Skin/SkinResolver and AnimationLibrary are next.*
2. **Editor logic** — `ToolInput` (the platform-neutral input boundary),
   `ToolManager` + all 8 tools (Select/Move/Rotate/Scale/Skew/Bone/Mesh/
   PhysicsPreview), gizmo hit-testing/metrics (every numeric constant —
   snap increments, drag thresholds, hit radii — ported as named constants,
   not inlined magic numbers), `CanvasPicking` (built to take projection as
   an injected function so Phase 4's renderer can slot in later without
   CanvasPicking changing — picking and rendering must share one skinning/
   projection implementation, never two), CameraState/Camera2D/Camera3D,
   EditorEscape, UndoRedoManager, CanvasActivity. Testable headless, with
   zero renderer.
   *Status: EditorEscape, CameraState, CanvasActivity, UndoRedoManager, the
   three gizmo-metrics files, GizmoHandle, ToolInput, Model/SceneImage
   (split out early as "the portable half of SceneManager's per-sprite
   state" ToolUtilities needs — see the SceneManager risk note), and the
   large majority of ToolUtilities.swift (snap*, point/segment/quad
   geometry, sprite local-frame/transform helpers, mesh resolution +
   skinnedLocalVertices + meshProjection + mesh vertex/edge hit-testing,
   bone hit-testing for both the mouse and touch-scored branches, the
   Liang-Barsky marquee test, soft-selection falloff weights, and the full
   `hitTestGizmo` dispatch for all 6 non-mesh-alpha tool cases) are done
   and tested. These were reformulated to take already-resolved values
   (a `const SceneImage&`, an asset size, a `const Skeleton&`, an explicit
   `hitScale`/`touchOptimized`) instead of `scene: SceneManager` /
   `assets: AssetManager` — documented in ToolUtilities.h's file header as
   a deliberate parameter-passing change with unmodified hit-test logic,
   extending the same "inject what's needed" pattern the Swift source
   already uses for CanvasPicking's projection closure.

   Deferred, and dependent on infrastructure that doesn't exist yet:
   `CanvasPicking.imageHit` and everything built on it (`hitTestScreen`,
   `hitTestRect`, `hitTestSelectionTarget`, `boundsForScene`/
   `boundsForImage`) need alpha-channel sampling against a LOADED texture,
   i.e. an asset/image-decode pipeline (stb_image or equivalent) that
   doesn't exist until Phase 4/5. `ToolManager` and the 8 concrete `Tool`
   implementations (Select/Move/Rotate/Scale/Skew/Bone/Mesh/PhysicsPreview)
   are not started — each mutates a live "Scene" (selection state, the
   skeleton, the sprite list, undo/redo integration) that needs its own
   design pass once the alpha-picking gap above is either filled or
   explicitly bridged with a stub, since `CanvasPicking.target` (bone vs.
   sprite arbitration) is on ToolManager's hot path for every click.

   *A second, newly-identified blocker for the same tools*: reading
   `ToolManager.swift` + the 8 `Core/Tools/*.swift` files end-to-end against
   `SceneManager.swift` found that almost every sprite/bone-editing mutator a
   tool calls (`moveBoneRoot`, `moveBoneTip`, `setBoneRotation`,
   `setImagePosition`, ...) branches on `isAnimationEditingEnabled`/
   `isPoseMode`: in Editor mode it writes the base pose directly and calls
   `applyAnimations()`; in Animator mode it calls `commitKeyframe(...)`
   instead and lets the next `applyAnimations()` re-sample the clip. Neither
   branch is meaningful without `applyAnimations()` itself — SceneManager's
   ~800-line whole-scene per-frame evaluator (`applyBoneAnimations`,
   `applyBoneBindings`, `applyConstraintAnimations`, `applyDrawOrderAnimation`,
   `applyAttachmentAnimations`, `ensureImageAnimationSpaceConsistency`,
   `applySetupPose`, plus `solveRigPose`/`rigPose(atFrame:)` for Scene-
   compositing instances, Phase 5) — which is a real, self-contained
   subsystem in its own right (`Animation/SceneAnimator.h/.cpp`, new this
   session), not previously called out as its own unit in this roadmap.
   *Status: started.* `clipSampledBones` (every bone's local transform
   sampled from its own `AnimationClip` at a time, the piece
   `applyBoneAnimations` and `solveRigPose` both call into) is ported and
   tested, including the `cyclicRotation: true` angle-unwrap this pass uses.
   The rest of the evaluator, `commitKeyframe`/`commitMeshDeformKeyframe`,
   and then `ToolManager` + the 8 tools on top of both, are the concrete next
   steps, in that order — each tool's manipulation math (drag deltas, snap,
   axis constraint) is independent of this and could in principle be ported
   sooner, but every tool's `onMouseDown`/`onMouseUp` writes through one of
   these two branches, so a tool ported without them would be untestable
   against real behavior, not just incomplete.
3. **Serialization** — binary UMSH chunked format (byte-exact; the
   `.meshDeform` empty-payload gap in the current Swift writer needs an
   explicit decision before the reader is written, not a silent port-as-is —
   see Risks), the native `.umesh` project package (JSON + SHA-256-deduped
   PNG assets, ~35 `Saved*` structs with documented optional/fallback
   semantics preserved field-by-field), UMJSON engine-agnostic interchange.
4. **Shared render geometry layer** — platform-agnostic geometry building/
   batching/culling/projection/lighting math, exposed as POD vertex/uniform
   buffers consumed by thin Metal and DirectX 11/12 backends. Target the
   GPU-path Scene renderer design (`SceneMetalRenderer.swift`), not the CPU
   CoreGraphics rasterizer it's superseding (no Windows equivalent exists or
   should be built). Shader math (checkerboard LOD blend, sprite transform
   decomposition) authored once in C++ as reference, hand-transcribed to
   MSL and HLSL with a numeric cross-check harness.
5. **Scene compositing / lighting / physics secondary motion / export** —
   mostly wiring Phase 1 (physics) + Phase 4 (lighting/geometry) together;
   own new scope is export orchestration (PNG sequence/video/texture atlas)
   with platform-swapped codec backends behind a common interface.
6. **Platform shells** — Mac: progressively rewire existing SwiftUI views'
   data sources to UMeshCore per landed phase, UI markup untouched. Windows:
   scaffold the full WinUI3 shell as soon as Phase 1 has any usable type
   (even a hardcoded test rig), so it's exercising real C++ code from day
   one instead of pure placeholder data; wire tool interaction after Phase
   2, file I/O after Phase 3, the DirectX renderer after Phase 4, export UI
   after Phase 5.

## Named risks

1. **`SceneManager.swift` god-object** (7,376 lines, ~400 `@Published`
   properties mixing true model data with UI-only state). Do not attempt to
   split it in one pass — let each landed phase mechanically absorb the
   properties it makes redundant; only audit "what's left" after Phase 5.
2. **Physics singleton → per-rig-instance**: the Swift source is a real
   `static let shared` process singleton. The C++ port must NOT mirror this
   — multiple simultaneous rig instances must not share one sim clock. This
   is a deliberate, documented divergence from the Swift source's current
   structure.
3. **Exact-arithmetic mesh predicates**: `orient2d`'s exactness proof
   requires `float` vertex coordinates promoted losslessly to `double`.
   Enforce at the type level; never "upgrade to double for safety."
4. **`.meshDeform` binary-format gap**: current Swift binary exporter
   writes no payload for `.meshDeform` keyframes. Needs an explicit decision
   (replicate the gap vs. fix in both languages with a schema version bump)
   before Phase 3's reader is written — surfaced to the user at that point.
5. **Metal/HLSL shader-math dual-authoring**: real math (not just
   boilerplate) lives in `.metal` shader source and needs an HLSL twin.
   Author once in C++, transcribe to both, verify with an automated numeric
   cross-check rather than visual inspection.
6. **Two SwiftUI-embedded math debts**: `SceneGizmoOverlay.swift` (1,732L)
   and `TimelineView.swift` (4,326L) contain real hit-testing/curve math
   inside SwiftUI view bodies. Extract into UMeshCore (Phase 2/4 scope)
   before Windows UI work needs equivalent logic — porting from a SwiftUI
   view body directly is much riskier than extract-on-Mac-first.

## Full architecture research

The complete exploration notes (per-file line counts, algorithm details,
tool/gizmo inventory, render architecture, binary format byte layout) that
this roadmap was derived from are preserved in the session that produced
it; the file-by-file dependency order and exact formulas are re-derived
from the actual Swift source at each implementation step, not from memory
of that research, per each module's header comments pointing at the source
file being ported.
