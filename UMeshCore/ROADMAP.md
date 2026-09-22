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
   *Status: in progress.* `clipSampledBones` (every bone's local transform
   sampled from its own `AnimationClip` at a time, the piece
   `applyBoneAnimations` and `solveRigPose` both call into) is ported and
   tested, including the `cyclicRotation: true` angle-unwrap this pass uses.
   `applyBoneBindings`/`boundImagePose` (places a bound sprite on its bone:
   bone world matrix composed with the sprite's local affine, decomposed
   back into position/rotation/scale/skew, with the same-frame rotation
   unwrap so a bone sweeping across ±180° doesn't visibly jump) and
   `ensureImageAnimationSpaceConsistency`/`convertImageAnimationSpace`/
   `convertPosition`/`convertRotation` (keeps a sprite's animation tracks —
   base pose and every translate/rotate keyframe — expressed in world space
   or in whichever bone it's bound to, converting on bind/unbind so the
   sprite never moves on screen) are also ported and tested. Deliberate
   divergence, documented in `SceneAnimator.h`'s file header: the Swift
   source reads bone world matrices from `SceneManager.frameWorldMatrices()`,
   a once-per-rendered-frame memoization cache that exists purely to avoid
   re-stepping physics more than once per real frame; `applyBoneBindings`
   here instead takes the world matrices as a parameter, matching the
   existing decision that physics stepping is the caller's concern (see
   `Skeleton::worldMatrices()`), so this file has no per-frame cache/token
   state of its own — behavior is unchanged, only where that memoization
   would live has moved to whatever eventually plays SceneManager's role.
   `Data/ConstraintAnimation.swift` (the authored-vs-animated constraint
   value bookkeeping `applyConstraintAnimations` needed) is now ported too,
   as `Constraints/ConstraintAnimation.h/.cpp`: `ConstraintKind`,
   `ConstraintSetupValues`, and generic (kind-agnostic) scalar/flag/vector
   get/set access to any of the four constraint stores by
   `AnimationTrackProperty` (`constraintScalar`/`setConstraintScalar`, etc.,
   `captureConstraintSetupValues`/`applyConstraintSetupValues`). Modeled as
   free functions taking `Skeleton&` rather than as `Skeleton` methods (the
   Swift source's `extension Skeleton` is effectively the same API surface),
   matching this port's existing pattern of keeping cross-subsystem
   orchestration out of the core data types. One deliberate representation
   change, documented in the header: `ConstraintSetupValues`'s three maps
   are keyed directly by the `AnimationTrackProperty` enum instead of by its
   Swift `rawValue` string — `std::unordered_map` hashes a scoped enum out
   of the box, and going through a string would mean hand-maintaining a
   rawValue table that exists nowhere else in this port, for a dictionary
   key spelling nothing here serializes or otherwise depends on.
   `SceneAnimator` now also has `constraintSampledSkeleton`/
   `applyConstraintAnimations` built on top of it (samples the scene-wide
   animation clip's constraint-property tracks onto a skeleton copy while
   animating; in Setup mode, restores each animated property's authored
   value from `constraintSetupValues` instead, so leaving Animate mode is
   non-destructive).
   `applyDrawOrderAnimation`/`applyAttachmentAnimations`/`slotNames` (the
   scene-wide, stepped-interpolation tracks) and `applySetupPose` are also
   ported and tested now. Two deliberate representation changes, documented
   in the header: (1) `applyDrawOrderAnimation`/`applyAttachmentAnimations`
   return their answer directly instead of writing it into a `SceneManager`
   field only when it differs from the previous value — that comparison is
   an `@Published`-change-notification optimization in Swift, and change-
   detection on the returned value, if a caller wants it, is the caller's to
   do, per the same reasoning as `Skeleton::worldMatrices()`'s own
   physics-stepping decision; (2) `applyAttachmentAnimations`'s per-slot
   result reuses `Skin::SlotAttachments`'s existing "key present vs. value
   optional" double-optional shape (`unordered_map<string,
   optional<Uuid>>`) for the same reason Swift's `[String: UUID?]` needs it:
   a slot absent from the map has no attachment track at all, while a slot
   present but mapped to `nullopt` means its track explicitly resolves to
   "show nothing" this frame — two different facts, not one.
   `resolvedKeyframeValue`/`resolvedAnimatedTranslate`/
   `resolvedAnimatedRotation` (what a bone/sprite's current value is, in
   keyframe shape — what the "key" button reads), `commitKeyframe`/
   `commitMeshDeformKeyframe` (write that as a keyframe at the current frame
   and re-run the pipeline), and `applyAnimations` itself (the whole-scene
   per-frame orchestrator tying every piece above together, in the same
   order the Swift source runs them) are now ported and tested too —
   **`SceneAnimator` is complete.** `commitKeyframe`/`commitMeshDeformKeyframe`
   return the keyframe that ended up selected (`SelectedKeyframe`, ported
   from `Data/Keyframe.swift`) rather than writing into a persistent
   "what's selected" field, the same representation choice as
   `applyDrawOrderAnimation`'s. `applyAnimations` solves
   `skeleton.worldMatrices()` itself, once, internally, right before placing
   bound sprites — after this same call's constraint/bone-animation passes
   have already updated the skeleton, so the matrices reflect this frame's
   pose; it never steps physics (the caller's concern throughout this port),
   documented alongside `applyBoneBindings`'s identical decision. Only
   `solveRigPose`/`rigPose(atFrame:)` (point-sampling a rig at an arbitrary
   frame for a Scene-compositing instance without touching the live scene)
   remain unported from the animation-evaluation side — Phase 5 scope.
   `SceneAnimator` also gained `localSpritePose` (converts a sprite's
   current visible/world pose into a bone's local space — the exact inverse
   of `boundImagePose`, and round-trip-tested against it), needed by the
   `Editor/EditorScene.h` work below.

   *`EditorScene`: started.* Rather than attempt a full `SceneManager` port
   in one pass (see Risk #1), built the minimal Scene aggregate the plan
   called for: `Editor/EditorScene.h`, a single header-only class carrying
   exactly what `ToolManager`/the 8 tools need — the sprite list, skeleton,
   scene-wide clip/constraint-setup bookkeeping, animation transport state,
   the full selection state machine (`setSelection`/`clearSelection`/
   `selectBone`/`toggleBoneSelection`/`setBoneSelection`/`selectMeshLayer`/
   `selectMeshVertices`, `selectedBonesInChainOrder`/`InDepthOrder`), drag
   preview (`setPreviewPosition`/`clearPreviewPosition`/`renderPose`),
   sprite/bone transform mutators (`setImagePosition`/`Rotation`/`Scale`/
   `Skew`/`Rotation3D`, `moveBoneRoot`/`moveBoneTip`/`setBoneRotation`/
   `setBoneLength`), undo/redo (`beginInteraction`/`endInteraction`/
   `undo`/`redo`, one-push-per-gesture), and thin wrappers over
   `SceneAnimator`'s `commitKeyframe`/`commitMeshDeformKeyframe`/
   `applyAnimations`. All ported 1:1 from the corresponding
   `SceneManager.swift` methods and tested (13 tests covering selection,
   drag preview, sprite/bone mutators in both Editor and Animate mode, and
   undo/redo including the one-push-per-gesture guard).

   Deliberately not yet in `EditorScene`, documented in its file header,
   because nothing in this port sets or reads them yet: timeline
   multi-selection (`selectedKeyframes`/`selectedKeyframe`), the IK-chain
   builder's draft state, and Bind Mode/weight paint/mesh-edit mode
   (`meshWeightPaintEnabled`/`isMeshEditEnabled`/`isBindingBonesMode`/
   `pendingCanvasMode`/`meshEditNotice`) — each is its own subsystem to
   port when the tool that needs it (`MeshTool`, `BoneTool`) is reached, not
   corner-cut now. One consequence, also documented: Swift's
   `boneSelectionBecameNonEmpty()` calls `leaveSpriteModes()`, which reads
   exactly those deferred flags; since none of this port's code can yet set
   any of them true, that call is provably a no-op today, so it's omitted
   rather than stubbed.

   `updateMeshVertex` (needs `Mesh::clampedPositionInsideHullIfNeeded`,
   itself needing `hullVertexIndices`/`pointInsideHull`/
   `pointOnHullBoundary` — not ported) is a newly-identified, `MeshTool`-
   scoped gap, deferred alongside that tool.

   **Status: Phase 2's tool layer is now complete, except two tools with
   real, documented, further-reaching blockers (`MeshTool`,
   `PhysicsPreviewTool` — see below).**

   The plan for unblocking `ToolManager`'s *dispatch logic* without
   `CanvasPicking.imageHit` (still needs Phase 4/5's asset pipeline) is
   built and proven: `Editor/CanvasPicking.h/.cpp` ports `CanvasPicking`'s
   arbitration rule in full (`target()`: a hit ON something beats a hit
   NEAR something, whatever kind it is; bone wins ties) with the image
   hit-test itself injected as an `ImageHitTestFn` callback — a platform
   with no texture pipeline yet passes one that always returns nullopt,
   which makes `target()` degrade to correct bone-only picking, not a stub
   of a stub. `Editor/Tool.h` ports the `Tool` protocol (`EditorScene&` +
   `ImageHitTestFn` in place of `scene: SceneManager`/`assets: AssetManager`,
   plus `hitScale`/`touchOptimized` as explicit parameters, threaded the
   rest of the way from `ToolUtilities.h`'s existing externalization of
   them).

   Six of the eight tools are ported and tested against this design:
   - `SelectTool` — image/bone click, Shift/Cmd multi-select, click-to-clear
     (except a Cmd-drag from empty canvas, which adds a marquee instead).
   - `MoveTool` — sprite drag (live preview, committed on release) and
     bone/bone-group drag, both with the move-X/move-Y gizmo axis
     constraint and Shift-snap. Its mesh-vertex-drag branch is deferred,
     needing the same two things `updateMeshVertex` needs everywhere else
     in this port (see `MeshTool` below).
   - `ScaleTool` — corner-handle scaling (uniform or single-axis), Shift
     snap, bone scale (Animate) vs. bone length (Setup), group scaling
     preserving proportions, and the post-release "settle" ease
     (`Tool::update`'s first real use). Needed one new `EditorScene`
     mutator, `setBoneScale`.
   - `SkewTool` — per-axis shear from a skew-edge handle, angle-delta
     driven, +-180 clamped, Shift rounds to whole degrees. Needed one new
     `EditorScene` mutator, `setBoneSkew`.
   - `RotateTool` — angle-delta rotation for a sprite or a rigid bone
     group, Shift-snaps to 15 degree steps, zeroes a grabbed sprite's 3D
     tilt, and the same settle-on-release pattern as `ScaleTool`. Verified
     against the real Swift source that `RotationGizmoState`/`ArcHitTest`
     (a separate 3D-tilt gizmo/tool) are NOT a dependency despite the name
     similarity — a suspected blocker that turned out to be false.
   - `BoneTool` — posing existing bones (root/tip drag) and authoring new
     ones (drag from empty canvas, or chain a new bone from an existing
     tip). Needed two new `EditorScene` additions: `addBone` and bone-
     creation preview state. **Found and documented a real Swift dead-code
     discrepancy** (not silently "fixed"): `onMouseDown` checks
     Shift/Cmd and toggles multi-selection *before* ever calling
     `interactionForHit`, so that function's own "Shift resizes the tip"
     branch — with a multi-line comment explaining that exact design — is
     unreachable in the app as it stands today. Ported the real, reachable
     behavior (Shift-click a tip toggles selection, same as anywhere else
     on a bone; it does not resize); flagged for confirmation against the
     Swift binary once Xcode access exists, the same standing already given
     the `MeshKernelTests` `RingFoldsBack`/`RingSelfIntersecting` finding
     from Phase 1.

   `ToolManager` itself (`Editor/ToolManager.h/.cpp`) is also ported: the
   full click/drag/release dispatch (gizmo-grab detection via
   `ToolUtilities::hitTestGizmo`, the image-vs-bone selection-click policy —
   including the click-count/touch-vs-desktop "when does a click change the
   selection" rule — and per-tool default-handle arming), `handlePointerExit`,
   `update`, `setTool`, and the bone marquee in Pose mode (via the already-
   ported `ToolUtilities::bonesIntersecting`). Missing tools are looked up
   the same way Swift's own `tools[currentTool]?.onMouseDown(...)` already
   handles one: silently does nothing, a real and safe no-op, not a crash
   waiting to happen. Three things are deliberately NOT ported, each
   documented in `ToolManager.h`'s file header with why:
   - The IK-builder-picking and Bind-Mode intercepts (`handleMouseMove`/
     `handleMouseDown`'s first two blocks) — neither subsystem is modeled
     in `EditorScene`.
   - The sprite marquee (`updateSelectionRect`, Select tool, not Pose
     mode) — needs `ToolUtilities::hitTestRect`, blocked on the same
     asset/alpha pipeline as `hitTestScreen`/`hitTestSelectionTarget`. The
     bone marquee has no such dependency and IS ported.
   - `updateRotationHover`/`handleRotationMouseDown`/
     `handleRotationMouseDrag`/`syncRotationState` — verified by grepping
     the whole Swift source tree that these four private methods have ZERO
     call sites anywhere, including within `ToolManager` itself. Provably
     dead code, not merely unlikely to run (contrast with the `BoneTool`
     finding above, which is reachable in principle, just not from the
     current caller) — not ported.

   The two tools NOT ported, and precisely why (both confirmed by direct
   research against the Swift source and this port's current surface, not
   assumed):
   - **`MeshTool`** (~672 lines, the largest tool) — every one of its
     sub-modes (Bind Mode, Weight Paint, hull creation, vertex
     select/drag, edge insert/delete) routes through at least one of: the
     asset/alpha pipeline (Phase 4/5), or a family of mesh-editing
     mutators (`updateMeshVertex`, `insertMeshVertex`,
     `deleteSelectedMeshVertices`, `constrainMeshInteriorVertices`, ...)
     that don't exist on `EditorScene` yet and themselves need
     `Mesh::clampedPositionInsideHullIfNeeded` (needing
     `hullVertexIndices`/`pointInsideHull`/`pointOnHullBoundary`, not
     ported). No sub-mode sidesteps both gaps; deferred as a whole unit
     rather than attempting a partial port with nowhere for most clicks to
     route.
   - **`PhysicsPreviewTool`** — its own mouse-handling logic is small and
     self-contained (hit-test a bone, store/clear a world-space pose
     override while dragging), and would be easy to port mechanically.
     But the override has no consumer: `EditorScene` doesn't own a live
     `PhysicsConstraintSystem` instance (deliberately — see Risk #2), and
     nothing in `SceneAnimator`'s pose evaluation reads a preview-override
     map. Porting the mouse handlers without that integration would
     compile and run but visibly do nothing — worse than not having it.
     Deferred until `EditorScene` (or whatever eventually plays a live-
     rig-instance role) owns a physics sim state, naturally alongside
     Phase 5's physics secondary motion work.

   All of the above is tested: 22 test binaries, 117 checks, 100% passing.
3. **Serialization** — binary UMSH chunked format (byte-exact; the
   `.meshDeform` empty-payload gap in the current Swift writer needs an
   explicit decision before the reader is written, not a silent port-as-is —
   see Risks), the native `.umesh` project package (JSON + SHA-256-deduped
   PNG assets, ~35 `Saved*` structs with documented optional/fallback
   semantics preserved field-by-field), UMJSON engine-agnostic interchange.
   *Status: started.* `Serialization/UMeshBinaryFormat.h` ports
   `Export/UMeshBinaryFormat.swift` in full: the file header layout
   constants (`magic`/`version`/`HeaderFlag`), `ChunkID` (FourCC values
   verified against the Swift source's literal hex), per-chunk
   `ChunkVersion`, and every compact wire-code enum (`InterpCode`,
   `TrackPropertyCode`, `KeyframeValueCode`, `AnimationSpaceCode`) plus the
   `KeyframeFlags`/`ImageFlags` bitmasks (Swift `OptionSet` -> a small
   `rawValue` struct with `contains`/`insert`, this port's existing pattern
   for bitmask types). One finding worth flagging for future chunk-encoder
   work: `TrackPropertyCode`'s numeric values are a separate, frozen,
   append-only numbering (assigned in shipping order) and do NOT match
   `AnimationTrackProperty`'s C++ enum declaration order (which mirrors
   `Data/Keyframe.swift`'s declaration order instead) — documented at length
   in the header so nobody ever `static_cast`s the enum directly into the
   wire format; conversion always goes through `toWireCode`/`fromWireCode`,
   mirroring the Swift source's own `init(_:)`/`.trackProperty` indirection
   rather than `.rawValue`.

   `Serialization/BinaryWriter.h` ports `Export/BinaryWriter.swift`'s
   append-only little-endian primitive writer 1:1 (fixed-width ints/float/
   bool, length-prefixed string, Vec2/Vec3/Vec4/Mat4, length-prefixed
   arrays, chunk framing via `openChunk`/`closeChunk`, header patching via
   `patchU32`), with two documented, deliberate divergences: (1) array
   writes go through the same scalar primitives element-by-element instead
   of Swift's `withUnsafeBufferPointer` bulk memory copy — a pure
   performance optimization in the Swift source with no behavioral
   difference on any little-endian target this port runs on, avoided here
   to not depend on pointer-reinterpretation UB; (2) `writeUuid` writes this
   port's `Uuid` as `hi` then `lo` (two little-endian `UInt64` words)
   instead of copying Swift `UUID.uuid`'s raw 16-byte RFC-4122 tuple —
   `Uuid`'s own header already establishes that it needn't bit-match
   Swift's UUID generator, and since the Swift app's binary exporter has no
   reader to interoperate with (see below), there is no cross-language byte
   layout to preserve here, only round-trip self-consistency.

   **Newly identified**, confirmed by grepping the whole Swift source tree:
   `.umesh`'s binary format is *export-only* in the Swift app today — there
   is no `BinaryReader.swift`/decoder anywhere, only `BinaryExporter.swift`
   writing one-way. This sharpens Risk #4's framing: the reader isn't a
   port with a Swift reference to diff against, it's new code from the
   start. `Serialization/BinaryReader.h` is added on that basis: the exact
   byte-level inverse of `BinaryWriter` (same primitive set, plus
   `readFileHeader`/`readChunkHeader` for framing, bounds-checked
   throughout since file input is untrusted — throws `std::out_of_range` on
   truncation, `std::runtime_error` on a bad magic). It only covers the
   primitive layer for now; the `.meshDeform`-empty-payload decision Risk #4
   calls for is deferred to when the ANIM chunk's actual encoder/decoder are
   written (the chunk-level `BinaryExporter`/scene-shaped work below), since
   that's the first point a real choice (replicate vs. fix-with-version-bump)
   has anything to act on.

   Tested: `tests/BinarySerializationTests.cpp` (12 tests) — FourCC/magic,
   every `ChunkID` value against the Swift source's literal hex, spot
   checks plus a full round-trip of every `AnimationTrackProperty` through
   `toWireCode`/`fromWireCode`, `InterpCode` round-trips, both bitmask
   types, `BinaryWriter`/`BinaryReader` round-trips for every scalar and
   composite primitive, chunk-framing size-patching, a full file-header
   round-trip, and the two error paths (bad magic, truncated read).

   **Chunk-level encoders: done for 6 of 7 chunks.** `Serialization/
   BinaryExporter.h/.cpp` ports `Export/BinaryExporter.swift`'s
   `writeMetaChunk`/`writeAssetsChunk`/`writeSkeletonChunk`/
   `writeImagesChunk`/`writeMeshesChunk`/`writeAnimationsChunk` 1:1,
   field-by-field, verified against 3 parallel research passes (chunk byte
   layout, C++ surface cross-reference, asset/scene-camera blocker check)
   before writing code, the same "inject what's needed" scoping `EditorScene`
   used in Phase 2 rather than porting `SceneManager`/`AssetManager`
   themselves. `writeScenesChunk` (the 7th chunk) is deliberately NOT
   ported: it serializes `scene.sceneCompositions`
   (`SceneComposition`/`SceneLayer`/`SceneCamera`/`SceneLight`/
   `SceneAmbient`/`SceneFill`, all in `Data/Scene/`), none of which are
   ported and which ROADMAP already scopes to Phase 5. This is a safe,
   self-describing omission, not a silent gap: the Swift source itself only
   writes SCENES `if !scene.sceneCompositions.isEmpty`, so a project that
   never used Scene mode already produces an identical file whether or not
   that chunk exists, and `EditorScene` has no `sceneCompositions` field at
   all, so this port's equivalent of that condition is unconditionally
   false today.

   Two new small types support this: `Serialization/AssetRecord.h` (a
   minimal `{id, name, filePath, size}` stand-in for Swift's `AssetManager`/
   `TextureAsset` -- confirmed by research that the ASSETS chunk only ever
   needs those four fields, never the GPU texture handle or atlas state
   those Swift types also carry, so this is NOT blocked on an image-decode
   pipeline the way `CanvasPicking.imageHit` was in Phase 2) and
   `Serialization/BinaryExportOptions.h` (port of `BinaryExportOptions`,
   omitting Swift's `includeBaseAnimations` field since grepping the whole
   of `BinaryExporter.swift` shows it's never read there). `EditorScene`
   gained `playbackStartFrame`/`playbackEndFrame` (real scene state the
   META chunk needs, mirroring `SceneManager.swift:276-277`).

   Two documented, deliberate divergences from the Swift writer, both
   version-bumped in `UMeshBinaryFormat.h`'s `ChunkVersion`:
   - **ASSETS (v2)**: Swift's "asset not found" record and a *found* asset's
     reference-mode record are byte-ambiguous (both end in the same
     `u32(0)` with nothing telling a reader whether a string follows).
     Added an explicit `u8 found` flag instead of replicating the ambiguity
     -- there is no real Swift reader to preserve byte-parity with (see the
     `BinaryReader.h` note above).
   - **ANIMATIONS (v2), the Risk #4 decision**: confirmed the Swift bug in
     full -- `writeKeyframe`'s `.meshDeform` case is exactly `case
     .meshDeform: break`, writing zero bytes (no discriminant, no payload)
     while every other case writes at least a `KeyframeValueCode` byte,
     silently desyncing the rest of the stream for any file with a
     meshDeform keyframe. Put to the user explicitly (Risk #4 calls for
     this): fix it in the C++ writer, since nothing in the Swift app has
     ever read this format back, so there is no real interop to break.
     `.meshDeform` now writes `KeyframeValueCode::MeshDeform` (code 8,
     already reserved) followed by a length-prefixed `Vec2` array like
     every other value kind.

   One implementation bug caught by the new tests before commit: the first
   version of `writeAnimationsChunk` iterated `scene.skeleton.orderedBones()`
   (which returns `std::vector<Bone>` by value) directly in a range-for and
   stored `const AnimationClip*` pointers into its elements for use *after*
   the loop -- the temporary vector is destroyed at the end of its own
   range-for, so those pointers dangled, corrupting the keyframe `value`
   variant and crashing with `std::bad_variant_access` on the very first
   test run. Fixed by binding `orderedBones()`'s result to a named local
   that outlives the whole function.

   Tested: `tests/BinaryExporterTests.cpp` (8 tests) — builds a non-trivial
   scene (2 bones with parent/child hierarchy, 2 sprites one bound to a
   bone with a full animation clip, tracks covering every `KeyframeValue`
   case including `.meshDeform` and `.event`, one asset present + one
   missing) and round-trips it through `BinaryExporter` -> `BinaryReader`,
   asserting exact field values chunk by chunk, plus dedicated coverage for
   the found/missing-asset flag, embed-mode byte inlining, and the
   meshDeform fix specifically. All 24 test binaries pass.

   Still not started from the binary side: `writeScenesChunk`, deferred to
   Phase 5 alongside `SceneComposition` (see above).

   **JSON foundation: started.** The native `.umesh` *project* package
   (`Data/ProjectPersistence.swift`, 1,905 lines, ~35 `Saved*` structs --
   distinct from the binary export format above) and UMJSON interchange
   (`Export/JSON/*.swift`, ~1,450 lines combined) are both plain JSON, so
   before porting either, a research pass (3 parallel investigations, same
   approach as the BinaryExporter scoping) nailed down their actual shape:
   - The native project format is a **package directory** (`.umesh` as a
     macOS `FileWrapper` bundle: `project.json` manifest + a sibling
     `Assets/` folder of SHA-256-deduplicated PNGs), not a single file or a
     zip -- `ProjectPersistence.swift` also reads a legacy flat-JSON
     fallback for pre-package saves. Most of its ~35 `Saved*` types are
     synthesized `Codable` with no custom logic; a few (`SavedBone`,
     `SavedMesh`, `SavedScale2`) hand-roll `init(from:)` purely for
     backward-compatible defaulting (`decodeIfPresent(...) ?? default`) so
     older save files keep opening. Every UUID-keyed relationship is stored
     as a sorted array of `{id, value}` records, never a JSON object keyed
     by UUID string -- documented in the Swift source itself as a
     diffability choice.
   - UMJSON is a single flat, self-contained-or-referencing JSON file
     (`UMJSONDocument`), a fully separate model from `Saved*` (different
     conventions throughout: string IDs instead of `UUID`, flat `[Float]`
     arrays instead of `SavedSIMD2`/`3`, some unit differences called out in
     Swift's own comments). Confirmed export-only by grep, same situation
     as the binary format: no `UMJSONDocument` decode call or importer type
     exists anywhere in the Swift tree.
   - Both formats independently avoid UUID-keyed JSON objects and need
     nothing beyond primitives/strings/arrays/objects (UMJSON's optional
     embedded-texture bytes are just base64 text, an ordinary JSON string)
     -- one shared JSON module serves both; only the native format's
     package/directory/PNG-dedup layer sits on top of it and doesn't apply
     to UMJSON.

   Built on that finding: `Serialization/Json.h/.cpp`, a minimal
   `JsonValue` (Null/Bool/Number/String/Array/Object) + writer (`dump`,
   pretty-printed and always sorted-key since `Object` is a `std::map`,
   matching the spirit of Swift's `[.sortedKeys, .prettyPrinted]` without
   the "no external dependencies" cost of a real library -- see the file
   header) + a hand-written recursive-descent parser (`parse`, full escape
   handling including UTF-16 surrogate-pair combining, bounds-checked and
   throws `std::runtime_error` with a position on malformed input, same
   posture as `BinaryReader`). New code, not a port -- `Codable`/
   `JSONEncoder`/`JSONDecoder` have no C++ equivalent. Explicitly NOT
   trying for Swift byte-parity (documented at length in the header,
   parallel to `BinaryReader.h`'s reasoning): for the native project
   format, Swift's own app is the only reader that format has ever had, and
   this increment isn't trying to satisfy it yet, only to round-trip
   correctly against this module's own parser. A `valueOr(key, fallback)`
   helper mirrors the `decodeIfPresent(...) ?? default` pattern
   `ProjectPersistence.swift` uses throughout, ready for the `Saved*`-
   equivalent encoders that come next.

   Tested: `tests/JsonTests.cpp` (14 tests) -- every value kind round-trips
   through `dump`/`parse` (both pretty and compact), string escaping
   including a UTF-16 surrogate pair, sorted-key ordering, nested
   object/array round-trips, `valueOr`'s three cases (present / present-
   but-null / absent), wrong-type-access and malformed-input error paths.
   All 25 test binaries pass.

   **`Saved*` structs: started (the rig slice).** A dedicated research pass
   (field-by-field, against the real Swift source, not assumed) inventoried
   all 44 `Saved*`/`SavedProjectDocument` types across `ProjectPersistence.swift`
   and `Data/Scene/ScenePersistence.swift`, confirmed exact fallback logic
   for every custom `init(from:)`, and confirmed the top-level save/load/
   apply entry points (`AppState.currentProjectDocument()` /
   `ProjectPersistence.save/load` / `AppState.restore(document:)`, the last
   of which mutates `SceneManager` in place via `restoreProject(...)` --
   there is no "construct a fresh SceneManager" load path). Three buckets
   emerged: (1) direct 1:1 with already-ported UMeshCore types (Bone,
   Skeleton, SceneImage, Mesh, AnimationClip/Track/Keyframe, Skin,
   AnimationEvent, and -- newly confirmed -- all four constraint types,
   `IKConstraint`/`PathConstraint`/`TransformConstraint`/`PhysicsConstraint`,
   whose C++ fields already match Swift's `Saved*Constraint` shapes
   exactly); (2) plain-old-data Swift types with an obvious C++ shape but
   no UMeshCore port yet (`TextureAsset`, `HierarchyItem`, `NamedAnimation`,
   `CameraState`); (3) the entire Scene-compositing namespace
   (`SceneComposition`/`SceneLayer`/`SceneCamera`/`SceneLight`/
   `SceneAmbient`/`SceneMaterial`/`SceneFill`/`SceneViewCamera`), which has
   no UMeshCore analog at all and is Phase 5 scope, same as
   `writeScenesChunk` above.

   `Serialization/SavedGeometry.h/.cpp` covers the shared primitives every
   other `Saved*` type is built from: `Vec2`/`Vec3`/`Vec4` (`{x,y[,z[,w]]}`
   objects), `Uuid` (a JSON string, Swift's own canonical `UUID` `Codable`
   form), `Mat4` (a flat 16-element column-major array -- more compact than
   Swift's 16-named-field `SavedMatrix4x4`, not attempting byte-parity, see
   `Json.h`'s reasoning), and `scale2FromJson`, which alone preserves a
   real Swift-specific read-side quirk: `SavedScale2`'s custom decoder
   accepts either a bare number (old files' uniform-scale shorthand) or an
   `{x,y}` object.

   `Serialization/SavedSkeleton.h/.cpp` covers the rig slice this bucket-1
   set supports today: `Bone` (with `SavedBone`'s exact base-pose fallback
   -- `basePosition/baseRotation/baseScale/baseSkew` default to the local
   pose when absent, matching old files that predate a separate rest pose)
   and all four constraint types + `PhysicsSettings`, with their enum
   fields (`PathSpacingMode`, `PathRotateMode`, `PhysicsType`) round-tripped
   through string names matching Swift's actual `rawValue` spellings
   (confirmed by reading the enum declarations directly, e.g.
   `PathRotateMode.chainScale`, not guessed), each falling back to the same
   default Swift's own `?? .default` does on an unrecognized/absent string.
   `Skeleton` itself ties these together, with its four constraint arrays
   treated as `?? []` on read (backward compatible with pre-constraint save
   files) exactly like `SavedSkeleton`'s own optionals.

   `Serialization/SavedAnimation.h/.cpp` then closed the animation half:
   `SavedAnimationClip`/`Track`/`Keyframe`/`KeyframeValue`,
   `SavedAnimationEvent`, and `SavedConstraintSetupValues`, with every
   decode fallback read off the real Swift implementations
   (`restoredValue()`/`restoredKeyframe()`/`restoredAnimationTrack()`), not
   inferred. `SavedKeyframeValue` is Swift's hand-rolled tagged union (a
   `kind` string plus a bag of mutually-exclusive optional payloads), and
   three of its cases carry real semantics this port reproduces rather than
   "cleans up": `.scale` decodes `vector2 ?? SIMD2(repeating: scalar ?? 1)`
   (old files wrote uniform scale as one number, and a *missing* scale is
   neutral at 1, not 0); `.attachment` is a 0-or-1-element id ARRAY, never
   an optional id, because "slot deliberately empty" and "no attachment key
   at all" are different statements a JSON `null` cannot distinguish; and
   `.event`'s three payload fields each stay independently optional end to
   end, since absent means "inherit the event definition's default" and must
   not decode as 0/"". An unrecognized `kind` falls back to
   `.translate(zero)`, matching Swift's `default:` arm. Reading a keyframe
   goes through `Keyframe`'s own constructor, so its stepped-interpolation
   rule (flag/drawOrder/event/attachment payloads are always Hold) applies
   on load exactly as it does everywhere else -- a file claiming otherwise
   cannot smuggle a Bezier flag keyframe in.

   This is also the first place in the port to need Swift's
   `AnimationTrackProperty.rawValue` strings (`trackPropertyName`/
   `trackPropertyFromName`, all 42 verified against the Swift enum
   declaration). That does not reopen the earlier decision to key
   `ConstraintSetupValues` by the enum rather than by a string (see
   `Constraints/ConstraintAnimation.h`): the table lives at the
   serialization boundary, which is exactly where a wire spelling belongs,
   and it is a separate vocabulary from `UMeshBinaryFormat`'s numeric
   `TrackPropertyCode` -- two formats, two encodings of the same enum,
   neither derived from the other.

   With that in place, the bone `animationClip` deferral noted in the
   previous increment is closed: it round-trips, staying optional on the
   wire exactly as in Swift (a bone with nothing keyed writes no clip;
   a bone read without one gets `AnimationClip(name: bone.name)`).

   One more dangling-reference bug caught by the new tests, same class as
   `BinaryExporter.cpp`'s `orderedBones()` bug from the previous increment:
   `skeletonFromJson` originally chained `j.valueOr(key, fallback).asArray()`
   directly into a range-for. `valueOr` returns a `JsonValue` by value, and
   `.asArray()` returns a reference into that temporary's internals --
   range-for's lifetime extension only applies to a reference bound
   *directly* to the temporary, not to a reference obtained by calling a
   member function on it, so the temporary was destroyed before the loop
   body ran. Fixed the same way: bind each `valueOr(...)` result to a named
   local first. Flagged in both files' comments now so the pattern is
   recognizable next time.

   Tested: `tests/SavedSkeletonTests.cpp` (10 tests) -- every primitive
   round-trips, `SavedScale2`'s bare-number-or-object quirk on real parsed
   JSON text, a full `Bone` round trip preserving base != local pose, a
   hand-written old-file-shaped JSON blob confirming the base-pose fallback
   really fires, all four constraint types + `PhysicsSettings`, an unknown
   enum string falling back correctly, a full `Skeleton` round trip
   including all four constraint arrays, and an old-shaped skeleton (no
   constraint arrays at all) defaulting to empty. Plus
   `tests/SavedAnimationTests.cpp` (14 tests) -- all 42 property names
   round-trip (with spot checks against Swift's literal case spellings),
   every one of the 11 `KeyframeValue` kinds round-trips, the empty-slot
   attachment stays an empty array, an event payload keeps its fields
   independently optional, `.scale`'s two-level fallback fires on real
   parsed JSON, an unknown kind falls back to translate-zero, keyframes
   with and without tangents, a stepped payload staying Hold even when the
   file says Bezier, clip/track/event round trips, constraint setup values
   keyed by Swift's rawValue spellings, and the bone-carries-its-clip case
   that closed the previous increment's deferral. All 28 test binaries pass.

   `Serialization/SavedSceneImage.h/.cpp` finishes bucket 1: `SavedMesh`
   (+ `SavedMeshBindPose`/`SavedVertexBoneWeight`/
   `SavedBoneInverseBindMatrix`), `SavedSceneImage`
   (+ `SavedBoneImageBinding`/`SavedTransformAnimationSpace`) and
   `SavedSkin`. Three behaviors worth recording:
   - `meshFromJson` reproduces the LOAD-TIME REPAIR PASS, not just field
     mapping: Swift runs `restoredMeshRaw().repairedIfInvalid().mesh` with
     the raw build ending in `.sanitizedSkinningData()`, and the Swift
     comment says why -- a project written before the mesh kernel existed
     can carry a triangle list covering only part of its silhouette, that
     bad list was persisted, and reopening the file brought the holes back.
     Both methods already existed on this port's `Mesh`, so the same two
     steps run here in the same order. A visible consequence, asserted in
     the tests rather than left implicit: an old skinning-free mesh does
     NOT come back with empty `bindVertices`/`vertexBoneWeights` -- the
     sanitize pass normalizes both to one entry per vertex, in both
     implementations.
   - A sprite's `animationTransformSpace` restores through Swift's
     three-tier fallback: the explicitly saved space, else inferred from
     the bone binding, else world (older files had no explicit field).
   - `SavedSkin.attachments` is a slot-sorted ARRAY of `{slot, imageID?}`
     records, not an object keyed by slot, for exactly the double-optional
     reason this port's own `SlotAttachments` already documents: "key
     present, value null" (slot deliberately empty) and "key absent" (slot
     not described) are different statements that a JSON object collapses
     into one. This port sorts on write too, since the live map is
     unordered and output should stay diff-stable.

   Tested: `tests/SavedSceneImageTests.cpp` (8 tests) -- full mesh and
   sprite round trips, an old-file mesh with every optional array absent
   (including the sanitize-pass consequence above), a sprite falling back
   on all four of its optional fields with its animation space inferred
   from its binding, a sprite with neither binding nor space landing in
   world, `SavedScale2`'s bare-number shorthand reaching sprite scale, a
   malformed 2-component tint falling back to white entirely rather than
   partially applying, and a skin proving described-but-empty and
   not-described slots stay distinguishable across the round trip.

   **The manifest itself: done.** `Serialization/ProjectDocument.h/.cpp`
   ports `SavedProjectDocument`, the root object written to `project.json`.
   It is shaped as the FILE's model rather than `EditorScene`'s, so it
   carries fields the scene aggregate does not model (`playbackLoops`,
   `projectFramesPerSecond`, `authoredDrawOrder`) instead of dropping them,
   and `projectDocumentFrom(scene, assets)` / `applyProjectDocument(doc,
   scene)` convert at the edges -- the latter mutating the scene in place,
   matching Swift, where loading calls `SceneManager.restoreProject(...)`
   on the existing instance rather than constructing a fresh one (and
   clearing selection, drag previews and undo history, since nothing
   pointing into the replaced scene survives). `AssetRecord` gained a
   `role` (`SavedTextureAsset.role`, optional, absent meaning albedo) and
   a note that its `size` is deliberately NOT persisted here: Swift's
   `TextureAsset.size` comes from the decoded texture, so it is recovered
   by loading the file rather than read back from the manifest.

   One deliberate addition with no Swift counterpart, and why it exists:
   `ProjectDocument::unrecognized` keeps every top-level key this port
   does not model yet -- `hierarchyItems`, `editorState`, `camera`
   (`SavedCameraState`), `animations` (the `NamedAnimation` library),
   `sceneCompositions`/`selectedSceneCompositionID`/`sceneViewCamera`
   (Phase 5) -- verbatim on read, and writes them back unchanged. Swift
   needs no such mechanism because its `Codable` models every field; this
   port models a growing subset, and without it a load/save cycle through
   UMeshCore would silently destroy a real project's Scene mode and
   animation library. Tested explicitly, including that a modelled key
   never leaks into it.

   Tested: `tests/ProjectDocumentTests.cpp` (8 tests) --
   `SavedProjectDocument.empty`'s "new project" defaults, a full document
   round trip through real serialized text, albedo's role being omitted
   from the file, five unmodelled sections surviving a read/write cycle
   intact, `applyProjectDocument` restoring a scene while clearing
   selection/preview/undo, the missing-scene-clip fallback, and a minimal
   old-shaped file decoding with every optional section empty. All 29 test
   binaries pass.

   **The package layer: done -- the native project format now round-trips
   through a real directory on disk.** `Serialization/ProjectPackage.h/.cpp`
   ports `save`/`load`/`makeProjectFileWrapper`/`makeBundledAssets`/
   `resolvingAssetPaths`, producing Swift's exact on-disk shape: a
   `MyProject.umesh/` DIRECTORY (not an archive) holding `project.json`
   plus an `Assets/` folder of `N-Name.ext` files. Swift builds it with
   `FileWrapper`; this port uses `std::filesystem`, and both write
   atomically -- the package is assembled beside the destination and moved
   into place, so a failure partway through cannot leave the previous
   project half-overwritten.
   - **Content deduplication** matches Swift's reasoning, not just its
     mechanics: identical source bytes are written once and every asset
     sharing them points at that one file. The Swift comment explains why
     it exists even though importing already dedupes -- a project made
     BEFORE that dedupe does carry duplicates, and re-saving it should not
     carry them forward.
   - **Three things share the `.umesh` extension**, so the reader sniffs
     before parsing: a package (directory with a manifest), a legacy flat
     manifest file with its images as siblings (still supported, as in
     Swift), and a Unity RUNTIME EXPORT -- the chunked binary format from
     the first half of this phase, whose first four bytes are `UMSH`.
     Swift added that check because letting an export reach the JSON
     decoder produced "the data couldn't be read because it isn't in the
     correct format": true, useless, and indistinguishable from a corrupt
     project. This port reports it by name for the same reason.
   - One small correctness improvement over the Swift original, documented
     in place: Swift decides "is this path absolute" with
     `path.hasPrefix("/")`, which is POSIX-only. This port asks
     `std::filesystem` instead, so a Windows `C:\...` path in a manifest is
     also left alone rather than being appended to the project root.

   `Serialization/Sha256.h/.cpp` is the hash that dedup needs, implemented
   here for the same "no external dependencies" reason as the math library,
   test harness and JSON module -- Swift reaches for `CryptoKit.SHA256`,
   which has no portable equivalent. Nothing here is security-sensitive
   (it is content addressing, not a credential check), but it is the real
   FIPS 180-4 algorithm, so digests agree with Swift's for the same bytes.

   Tested: `tests/ProjectPackageTests.cpp` (12 tests, the first in this
   port to touch the filesystem -- each works under a unique temp directory
   and cleans up after itself). SHA-256 is checked against the published
   NIST vectors (including the million-'a' case and the 55/56/64-byte
   padding boundaries) rather than against this port's own output. The
   package tests cover the written directory layout, dedup collapsing two
   identical files into one, filename sanitization, a full save/load cycle
   through disk resolving relative asset paths back to real existing files,
   save-over-existing replacing rather than merging (and leaving no staging
   directory behind), the legacy flat-file shape resolving against the
   file's parent, absolute paths being left alone, a runtime export being
   rejected by name, a missing path being reported rather than crashing,
   and -- end to end this time -- an unmodelled section surviving a real
   save/load cycle. All 30 test binaries pass.

   **Bucket 2: closed.** The types the manifest needed that had no
   UMeshCore counterpart are ported, so they no longer live in
   `ProjectDocument::unrecognized` as opaque JSON:
   - `Model/HierarchyItem.h` -- the outliner tree (`HierarchyModels.swift`).
     Authored data, not a rendering of the skeleton, which is why it belongs
     in the core; the panel that DRAWS it stays per-platform.
   - `Animation/AnimationLibrary.h/.cpp` -- `NamedAnimation` plus the
     library itself (`Data/AnimationLibrary.swift`), which ROADMAP listed as
     an outstanding Phase 1 item. Reached here because the manifest
     persists it, and a manifest that could not round-trip the library
     would lose an artist's other animations on save. Takes an
     `EditorScene&` where Swift takes `SceneManager`. Two non-obvious rules
     the Swift comments call out are kept and tested directly: `restore`
     deliberately does NOT snapshot the live clips first (the project was
     just loaded, so those clips ARE the active animation's, and
     snapshotting would overwrite the file's contents with a copy of one of
     its own entries), and `switchTo` saves the outgoing animation even
     when the target is already active, then returns without reloading, so
     live clips are never overwritten with a stale snapshot.
   - `CameraState` already existed; it just needed its JSON.

   `Serialization/SavedEditorState.h/.cpp` carries the hierarchy and camera
   conversions. Swift's `SavedEditorState` itself is deliberately NOT
   ported, and the header says why rather than leaving it to inference: it
   is a flat bag of `AppState` UI scalars (timeline zoom, snap and onion-
   skin toggles, which track filter is selected, soft-selection sliders),
   which is platform-shell state under this port's standing rule. It still
   survives a save, because `unrecognized` carries the whole `editorState`
   object through untouched.

   `ProjectDocument` gained `hierarchyItems`, `camera`, `animations` and
   `activeAnimationID` as real fields. They are left for the caller to fill
   rather than read off `EditorScene`, because they live OUTSIDE the scene
   here exactly as they do in Swift (the camera and the animation library
   belong to `AppState`, not `SceneManager`) -- and Swift's own
   `AppState.restore` has the same shape: restore the scene, then the
   library, the camera and the rest separately. What is left in
   `unrecognized` today is just `editorState` and the Phase 5
   Scene-compositing sections.

   Tested: `tests/AnimationLibraryTests.cpp` (10 tests) -- snapshot
   capturing every clip and the longest duration across bone/sprite/scene,
   switching saving the outgoing edits and loading the target, switching to
   the ALREADY-ACTIVE animation saving without reloading, `restore` not
   snapshotting over what it was given, a dangling `activeID` selecting
   nothing, rename/remove, and JSON round trips for `NamedAnimation`,
   `HierarchyItem` (including nesting and an unknown type falling back to
   image) and `CameraState`. `ProjectDocumentTests` gained a case asserting
   these four sections now round-trip as real values with `unrecognized`
   empty. All 31 test binaries pass.

   **UMJSON: done -- Phase 3's last piece.**
   `Serialization/UMJsonModel.h` ports `Export/JSON/UMJSONModel.swift` (the
   ~25 document structs) and `Serialization/UMJsonBuilder.h/.cpp` ports
   `UMJSONExportBuilder.swift`. This is a FULLY separate model from
   `Saved*`, deliberately, and the differences are the point rather than
   inconsistency: IDs are strings (the consumer is not Swift or C++ and
   should not need a UUID type to read a rig), vectors are flat `[Float]`
   arrays, interpolation is spelled "stepped" rather than "hold", and units
   are preserved per-field rather than normalized -- a BONE's rotation and
   shear are radians while a SPRITE's rotation is radians but its shear is
   DEGREES, which is the editor's own internal asymmetry
   (`Transform3D2D` vs `MatrixUtilities::shearedAxes`) and is kept so a
   runtime reproduces the rig with zero conversion drift.

   Like the binary export format, UMJSON is WRITE-ONLY in Swift (confirmed
   by grep: no decoder or importer type exists anywhere), so this port
   provides a builder and a writer, not a reader.

   Determinism is structural, not incidental: bones go out in DFS order
   from the declared roots with children sorted by id (plus any orphan,
   also sorted), every map-derived collection is sorted by a stable key,
   and float rounding goes through one choke point. Exporting an unchanged
   project twice yields identical text -- the sole exception being
   `exportDate`, a timestamp by definition, same as the binary META
   chunk's.

   Both options carry real behavior and are ported with it:
   - `nonessentialData` (default true): when FALSE, values only the editor
     needs are stripped -- bone colors, the setup draw order, atlas region
     names, the 3D `depth` block, the project name.
   - `animationCleanUp` (default false): removes keys that provably cannot
     change what is rendered, and only those. Rule 1 drops a constant,
     curve-free track ONLY when its value equals the SETUP value; when the
     constant differs the track is KEPT, because dropping it would silently
     re-pose the rig (a bone held at 45 degrees would export flat at 0) --
     visible corruption, not cleanup. Rule 2 drops the interior keys of an
     equal-value run, keeping the endpoints so the hold's timing survives
     exactly. Keys carrying Bezier tangents are never dropped, since their
     handles shape the curve into and out of neighbours even when values
     match.

   Two smaller faithful details worth recording: a mesh-deform key never
   claims "bezier" even when the source keyframe is Bezier, because the
   editor's deform sampler never consults tangents and claiming otherwise
   would be a lie the runtime could act on; and a deform key whose vertex
   count disagrees with the mesh is dropped, because the editor ignores
   such keys at playback, so exporting them would hand the runtime data the
   editor itself would never show.

   One documented gap: `embedTextures` does not base64-embed. The asset
   record carries a path, not bytes, and embedding needs a base64 encoder
   plus file reads that belong with the caller. The option is honored by
   leaving `embedded` false and writing the path reference rather than
   silently pretending it embedded.

   The three constraint enum name tables (`PathSpacingMode`,
   `PathRotateMode`, `PhysicsType`) moved out of `SavedSkeleton.cpp`'s
   anonymous namespace into its header, since UMJSON writes the same
   `rawValue` spellings -- one vocabulary, two formats, rather than two
   copies that can drift.

   Tested: `tests/UMJsonTests.cpp` (18 tests) -- header/metadata,
   nonessential stripping in both directions, deterministic bone order with
   the root flagged, the depth block appearing only for real depth, neutral
   tint and normal blend being omitted, bound attachments reporting
   boneLocal space, mesh flattening with skinning omitted when unweighted
   and sorted when weighted, skin slots keeping "deliberately empty"
   distinguishable from "not described" (an explicit null in the text),
   "stepped" not "hold", deform keys being absolute and never Bezier,
   mismatched deform keys dropped, both cleanup rules including the
   keep-when-off-setup guard and the never-drop-a-Bezier-key guard,
   constraint/event/drawOrder timelines in their own sections with unset
   event overrides staying absent, rendered text parsing and being
   byte-stable across two renders, and float precision rounding. All 32
   test binaries pass.

   **Phase 3 is complete** for everything not blocked by a later phase.
   What remains deferred, each documented above: the binary `writeScenesChunk`
   and the manifest's Scene-compositing sections (Phase 5's
   `SceneComposition` model), `SavedEditorState`'s UI scalars (platform
   shell, preserved verbatim rather than modelled), and UMJSON's base64
   texture embedding.
4. **Shared render geometry layer** — platform-agnostic geometry building/
   batching/culling/projection/lighting math, exposed as POD vertex/uniform
   buffers consumed by thin Metal and DirectX 11/12 backends. Target the
   GPU-path Scene renderer design (`SceneMetalRenderer.swift`), not the CPU
   CoreGraphics rasterizer it's superseding (no Windows equivalent exists or
   should be built). Shader math (checkerboard LOD blend, sprite transform
   decomposition) authored once in C++ as reference, hand-transcribed to
   MSL and HLSL with a numeric cross-check harness.
   *Status: started.* `Render/SceneProjection.h/.cpp` ports
   `Render/SceneProjection.swift` -- the ONE way a scene turns world
   coordinates into pixels (view matrix, perspective projection, divide by
   w). Chosen as Phase 4's first piece because the whole phase hangs on it,
   and because the Swift source's own header records why it must be shared:
   the rig side already had THREE copies of world-to-screen
   (`MetalRenderer.project3DToScreen`, `ToolUtilities.project3DToScreen`,
   and an inline expression in the exporter) and they already DISAGREED --
   the exporter had no `rotation3D` term, so a sprite rotated in 3D
   exported differently from how it looked on the canvas. A Metal backend
   and a DirectX backend each re-deriving this would reproduce exactly that
   class of bug, which is what ROADMAP's Phase 2 note already committed
   against ("picking and rendering must share one skinning/projection
   implementation, never two").

   Ported whole, including the parts that exist because of specific
   reported bugs, each documented in place:
   - `clipAndProject` cuts a polygon to the near AND far planes rather than
     rejecting it. The all-or-nothing rule it replaces asked `project` per
     corner and dropped the whole primitive when one came back nil --
     false, because a quad with one corner behind the eye is PARTLY visible
     and the visible part is a polygon. Since the nearest corner crosses
     long before the centre does, and the gizmo projects the centre, the
     card vanished while its handles stayed. The cut happens in CLIP space,
     before the divide, so a cut vertex has `clip.z == 0` (near) or
     `clip.z == clip.w` (far) BY CONSTRUCTION and cannot land a hair on the
     wrong side of the guard it was made to satisfy.
   - The far plane clips too, and is not decoration: `farZ` went into the
     projection matrix and then nothing read it back, so the culler
     discarded cards the renderer would happily have drawn.
   - `projectiveQuad` deliberately KEEPS corners behind the eye. Such a
     corner divides by a negative w and lands at the antipode, which is its
     correct projective image, not an error to guard away -- that is what
     lets the visible part be drawn with real perspective rather than
     approximated.
   - `rayThrough`/`hitPlane`/`axisParameter` answer gizmo drags in WORLD
     space. The screen-delta-over-pixels-per-unit approach they replace is
     only right when the projection is affine; the Swift harness measured
     the handle sliding up to 313 px out from under the pointer.
   - `worldLengthForPixels` is ONE scale for all three axes, because the
     projection is uniform -- measuring per axis is what gave one gizmo
     three different arrows.

   Takes camera parameters directly rather than a `SceneCamera`, which
   belongs to Phase 5 and is not ported; `fromFrame` covers what the
   fly-camera initializer needs, so both Swift convenience initializers
   become one-liners once those types exist. Same "inject what's needed"
   scoping used throughout this port.

   Tested: `tests/SceneProjectionTests.cpp` (20 tests), asserting the
   PROPERTIES the Swift file documents rather than re-deriving matrix
   entries (which would only restate the implementation): the +Z look
   convention and y-down screen space, project/unproject being exact
   inverses at three depths and under a yawed+pitched camera, perspective
   convergence, a tilted card having a near edge wider than its far edge
   (the first failure the Swift header names), a partly-visible quad
   yielding a polygon where the all-or-nothing rule would draw nothing, a
   wholly-visible quad passing through unchanged with attributes intact,
   far-plane clipping, `projectiveQuad` answering for corners `project`
   refuses, a gizmo scale spanning the same pixels along X and Y, axis
   tracking in world units with the end-on case refused, and the
   angle-built and frame-built cameras projecting identically. All 33 test
   binaries pass.

   `Render/SceneCulling.h/.cpp` ports `Render/SceneCulling.swift` --
   `SceneFrustum` (the six world-space planes a frame decides with) and
   `FrameRegion` (the whole-pixel rectangle a layer is allowed to touch).
   Second because it is the first consumer of `SceneProjection`, and it
   consumes it in the one way that matters: the planes are pulled out of
   `viewProjection()` (Gribb & Hartmann), THE SAME matrix the drawing
   divides by, never rebuilt from the camera's field of view and near/far.
   The Swift header is explicit that rebuilding them reads more clearly and
   is wrong: the two agree only until somebody changes one, and the symptom
   when they drift is an object popping out at the edge of the screen while
   still visibly on it. That warning is sharper in this port than it was in
   Swift, because the entire point of a shared core is that a Metal backend
   and a DirectX backend do NOT each re-derive it -- the same
   three-copies-of-world-to-screen failure `SceneProjection` exists to
   prevent.

   The one structural thing to know about a culler, and the thing this
   file's tests are built around: its error is allowed in ONE direction. It
   may KEEP something invisible (wasted work -- the Swift harness measured
   1.3 % of 20 000 random cameras) and may never DISCARD something visible
   (an object vanishing). So `culls` is the conservative test -- a hull is
   culled only when it lies entirely outside ONE plane, and a hull
   straddling two is kept even when it really is outside, because deciding
   otherwise needs a separating-axis test and the cost of being wrong is
   not symmetric.

   Near and far are both extracted and both honoured, which is a pairing
   rather than a coincidence. In Swift the far plane predated
   `clipAndProject`'s far cut and for a while discarded cards the renderer
   would have drawn -- 51 layers out of 20 000, every one of them putting
   pixels on the canvas -- because `farZ` went into the projection matrix
   and nothing read it back. The C++ port has had the far cut since
   `SceneProjection` landed, so the two agree by construction; breaking
   either side of that still breaks the other.

   Two details that are easy to "clean up" into bugs, documented in place:
   NEAR is row 2 ALONE, not `w + z`, because clip z runs `0...w` in the
   Metal/Direct3D convention this projection writes out explicitly (the
   OpenGL form would put the near plane half a frustum too far back); and a
   row has to be gathered ACROSS the stored columns, since reading
   `columns[0]` as a row is the classic way to get a transposed frustum
   that culls everything in front of the camera. A degenerate (zero-normal)
   plane is left unscaled rather than divided by ~0, because a NaN plane
   compares false everywhere and would cull the whole scene -- the one
   direction this file may not fail in.

   **Two documented divergences, both in `FrameRegion::bounding`:**
   - The clamp to the frame happens in float, BEFORE the conversion to
     `int`, where Swift converts first and clamps after. Swift's order
     traps on a coordinate too large for `Int`; the same conversion is
     undefined in C++. Behaviour-preserving: every in-range value gives the
     identical region, and out-of-range ones are empty or whole-frame
     either way.
   - "Non-finite" is tested on every point rather than on the reduced box.
     Swift reduces first with `simd_min`/`simd_max`, which are fmin-based
     and return the OTHER operand for a NaN -- so a NaN corner among finite
     ones is quietly dropped there, and only an all-NaN set (or an
     infinity, which does propagate) reaches the guard. Dropping a corner
     shrinks the region, and a region too small clips pixels off a layer
     that IS on screen. The guard's evident intent is the whole frame, so
     that is what a NaN gets here.

   Tested: `tests/SceneCullingTests.cpp` (19 tests). The central one is a
   sweep of 20 000 random cameras and points that asks `SceneProjection`
   whether a point lands strictly inside the viewport between near and far,
   and asserts `culls` never discards one that does -- the asymmetric rule
   itself, checked against the same matrix the frustum comes from rather
   than against re-derived plane coefficients. Its counterpart builds the
   documented straddling case (a segment passing outside the frustum's
   top-left corner), proves INDEPENDENTLY through the projection that all
   21 sampled points on it are off screen, then asserts the culler keeps it
   anyway -- so the conservatism is pinned as behaviour, not left as a
   comment. The rest: plane normalisation making `margin` a world distance,
   inward-facing planes (the transposed-frustum check), the near plane's
   signed distance being a real world distance, behind-the-eye and
   beyond-far both culled, an empty hull culled, a margin in world units,
   a singular matrix producing finite planes, outward rounding in both
   directions, y-down with no flip, clipping to the frame, an off-screen
   region reading as empty, no-points vs non-finite giving opposite
   answers, and a projected quad's region containing every corner it came
   from. All 34 test binaries pass.

   **Not yet started**: the fly-camera orbit (`SceneViewProjection.swift`,
   of which `cameraBasis` is already inside `SceneProjection`), the POD
   vertex/uniform structs (`SceneGPU/SceneGPUTypes.swift`), the skin
   palette, gizmo layout and mesh building, arc/sphere geometry, lighting
   math, the frame budget, the reference shader math, and the
   Metal/DirectX backends themselves. `CLAUDE.md` carries the ordered list.
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
