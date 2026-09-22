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

   `Render/SceneCulling.h/.cpp` ports `Render/SceneCulling.swift`: the
   frustum as six world-space planes, plus `FrameRegion`, the integer
   rectangle a culled draw is confined to. Two things carried across
   deliberately. First, the planes are EXTRACTED from the combined
   view-projection matrix (Gribb & Hartmann), never rebuilt from the
   camera's field of view, aspect and near/far -- that is the whole reason
   a culler can be trusted, since the planes then come from the same matrix
   the drawing divides by and cannot drift from it. Second, the error is
   allowed in ONE direction only: `culls` may keep something invisible
   (wasted work) and may never discard something visible (an object
   vanishing), so a hull is culled only when it lies wholly outside a
   SINGLE plane -- a hull straddling two is kept even when it is in fact
   outside, because deciding otherwise needs a separating-axis test and the
   cost of being wrong is not symmetric. Clip z runs 0..w (Metal/Direct3D),
   which is what `SceneProjection`'s perspective matrix writes, so NEAR is
   row 2 alone; the OpenGL `w + z` form would put the near plane half a
   frustum too far back. `FrameRegion` rounds OUTWARD, never to nearest,
   because a rectangle rounded inward loses the anti-aliased edge of
   whatever it bounds. One divergence, documented in place: Swift's
   `Int(x.rounded(.down))` traps outside Int's range, so the C++ cast
   saturates first rather than invoking undefined behavior; the caller
   clamps into the frame either way.

   `Render/SceneViewCamera.h/.cpp` ports `SceneViewCamera` (from
   `Data/Scene/SceneComposition.swift`) plus the pure camera math of
   `Render/SceneViewProjection.swift` -- the fly camera for the Scene
   editor view. The two Swift files are joined here on purpose: the Swift
   header says `SceneViewProjection.basis` must produce the SAME vectors
   `SceneViewCamera.eye` and `.pan` already use, because "two
   transcriptions of 'forward' is how the pivot would end up somewhere
   other than the middle of the screen". In this port there is exactly one:
   `cameraBasis`, already in `SceneProjection.h`, which `eye()` reads too,
   and `projection()` is a plain `SceneProjection` rather than a second
   copy of the projection math. `shotFrame` takes the shot camera's fields
   explicitly ("inject what's needed") and keeps Swift's UNCLAMPED focal
   length -- `SceneCamera.focalLength(viewHeight:)` does not clamp the
   field of view while `SceneViewProjection.init` clamps to 1..170 -- since
   the frustum gizmo it draws has to land on the frame the export actually
   renders. `cardCorners`/`cardPoint` are NOT ported: they take a
   `SceneLayer` and call its `planePoint`/`liftToWorld`, which is Phase 5,
   and inventing a layer type now would mean re-transcribing that lift --
   the failure the file itself warns about.

   **Follow-up fix (same file, landed after Phase 4 closed).**
   `FrameRegion::bounding` tested for non-finite coordinates on the
   REDUCED box, which made the answer depend on where the NaN sat and got
   it wrong in the forbidden direction. `std::min(finite, NaN)` returns
   the finite operand, so a NaN point anywhere but first was swallowed by
   the reduction and never reached the guard. Measured: the points
   `{(10,10), (NaN,20)}` gave `(10,10)-(10,20)` -- an EMPTY region, i.e.
   the layer skipped altogether -- while the same two in the other order
   gave the whole frame. A non-finite `pad`, which lands on all four
   edges, was not guarded at all and reached the int conversion, coming
   back `INT_MIN`. The test is now per point and covers `pad`, so every
   unknown gets the one conservative answer the header promises. Swift is
   exposed to the identical thing through fmin-based `simd_min`; this is
   a documented divergence in the safe direction, not a transcription
   slip. Two regression tests pin it (12 tests in the file now).

   Tested: `tests/SceneCullingTests.cpp` (10 tests originally) and
   `tests/SceneViewCameraTests.cpp` (9 tests). The culling tests check the
   asymmetric rule against `SceneProjection` itself over 4000 random
   cameras and points -- anything the projection would actually draw is
   never culled -- plus the behind-the-eye case a transposed row extraction
   gets exactly backwards, the near plane sitting at nearZ rather than half
   a frustum back, the far plane agreeing with `clipAndProject` (the
   disagreement the Swift header measured at 51 layers out of 20 000, every
   one putting pixels on the canvas), normalised planes so a margin is in
   world units, and `FrameRegion`'s outward rounding, frame clipping and
   NaN fallback to the whole frame. The camera tests pin the pivot staying
   at the exact screen centre through sixteen orbits (the one property a
   second transcription of "forward" breaks), a pan of N pixels moving the
   picture by exactly N pixels (world-per-pixel and focal length being
   inverses of each other), the pitch clamp, the multiplicative dolly, and
   `shotFrame`'s corners projecting onto the render's corners at three
   distances under a rotated shot. All 35 test binaries pass.

   Caveat carried from the Swift sources: `Editor/verify_scene_culling.py`,
   cited for the 1.3 % over-keep rate and the 51-layer figure, does not
   exist in this repository (see CLAUDE.md). The properties those numbers
   measured are what the tests pin instead.

   `Render/SceneGPUTypes.h` ports `Render/SceneGPU/SceneGPUTypes.swift`:
   the POD structs the scene shader reads. These are a WIRE FORMAT, not
   ordinary data types -- the same bytes are declared in Swift, in MSL, and
   will be declared again in HLSL for the DirectX backend, and nothing but
   the layout keeps them in step. The Swift header states the failure
   exactly: drift "produces a picture where one light is right and the next
   is reading a neighbour's radius", which is not a crash and not obviously
   wrong on screen. The padding is spelled out because Metal aligns
   `float3` to 16 bytes and so does `SIMD3<Float>`; C++ is the odd one out,
   with a 12-byte 4-aligned `Vec3`, so every struct is `alignas(16)` and
   every hole is a named `pad` field.

   The harness the Swift files lean on
   (`Editor/verify_scene_gpu_transcription.py`, which compares the
   declarations field by field and checks every size is a multiple of 16)
   does not exist here, so the check moved INTO the code: `static_assert`s
   on size, alignment and the offset of every field, against numbers
   derived by hand from the MSL declarations. A compiler that would lay
   these out differently does not compile the library -- strictly stronger
   than a script nobody runs. The runtime tests cover what a `sizeof`
   cannot see: that a field written by name lands on the WORD the shader
   indexes.

   Not ported: `SceneLightUniform.init(_ prepared:falloffRow:)`, which
   transcribes a `SceneLighting.PreparedLight` (Phase 4 piece 7) off a
   `SceneLight` (Phase 5) and derives nothing itself. The `kind`/`blend`
   CODES are here as enums, because the values are the wire contract; what
   is deliberately absent is the mapping from the model's enums. Swift
   writes that as an explicit `switch` rather than giving those enums an
   Int raw value, because they are `String`-backed for the file format and
   a raw value would make the wire format depend on Swift declaration
   order -- reordering the cases would silently change every saved scene.
   The same rule binds the C++ model when Phase 5 lands it: map with a
   switch, never a cast.

   `Render/SceneSkinPalette.h/.cpp` ports
   `Render/SceneGPU/SceneSkinPalette.swift`: a rig instance's bones folded
   into `N = rigToWorld * spriteToRig * A * (world * inverseBind) * B`, one
   matrix per sprite per bone, so the shader is the textbook four-weight
   sum -- thirty matrices instead of 8320, with the per-vertex work moved
   to hardware built for it.

   The fold is exact ONLY if the weights sum to one, and that condition is
   the whole of the type: pushing an affine inside a weighted sum adds its
   translation once per influence instead of once. The data does not
   guarantee it (the weight brush normalises, auto-weighting caps at four
   without renormalising, and `skinnedVertices` divides by the total
   defensively, so nothing upstream complains), which is why `influences`
   normalises on the way to the GPU and nothing else may skip it. Slot zero
   is the identity `A * B`, written as the product rather than as a literal
   identity so a sprite whose bind pose is not exactly invertible degrades
   the way its bound vertices do; an unweighted vertex rides it as one
   influence of weight 1, which is how the CPU's per-vertex branch
   disappears without changing the answer. Influences are capped BEFORE
   normalising -- the surviving four are renormalised between themselves,
   where normalising first and dropping the tail would leave the vertex
   short of its weight and slump it towards its bind position -- and the
   truncation is counted and reported rather than swallowed. Scoping: the
   Swift initializer takes a whole `Mesh` and reads one field of it, so the
   C++ one takes that field and Render stays independent of Mesh.

   Tested: `tests/SceneGPUTypesTests.cpp` (8 tests) and
   `tests/SceneSkinPaletteTests.cpp` (7 tests). The GPU-types tests write a
   distinct value into every field and read each struct back as the flat
   run of words the GPU indexes, plus the material flags being distinct
   single bits and the wire codes asserted as literals (a test that read
   them off the enum would agree with any reordering). The palette tests
   put the shader-side sum over the folded palette against a CPU-side
   "blend, then apply the sprite and layer affines" and require them to
   agree once normalised -- and reproduce the displacement with the raw
   weights rather than describing it, with the tell in the homogeneous
   coordinate, since the weighted sum's w IS the weight total. Also: slot
   zero resolving to the bind position rather than the origin or the first
   bone, a fifth influence being capped, counted and renormalised
   afterwards, tied weights breaking by slot so two runs of the same
   project agree (the slots are baked into an uploaded buffer), and a bone
   missing its inverse-bind taking no slot rather than shifting every later
   one. All 37 test binaries pass.

   `Render/SceneGizmoTypes.h`, `Render/SceneGizmoLayout.h` and
   `Render/SceneGizmoMeshBuilder.h/.cpp` port the gizmo trio
   (`SceneGPU/SceneGizmoTypes.swift`, `SceneGizmoLayout.swift`,
   `SceneGizmoMeshBuilder.swift`): the CPU-only description of the
   manipulator's shape, and its conversion into triangles -- cones and
   cylinders for the move/scale/shear arrows, tube-shaded tori for the
   rotate rings, translucent double-sided quads for the plane handles, and
   a light's own diagram. Everything in WORLD space; the vertex shader does
   the recentre-then-slide itself.

   No near-plane cutting here, deliberately, and the contrast with
   `SceneProjection::clipAndProject` is the point. The overlay's `ringArcs`
   hand-rolls a cut because a SwiftUI `Canvas` stroke is a polyline with no
   notion of clip-space clipping; a triangle handed to the GPU has no such
   problem, because the rasteriser clips every primitive against the
   frustum exactly and for free. `clipAndProject` still cuts because it
   feeds CPU picking and the export path, where there is no rasteriser.

   This is also the FIRST BITE of Risk #6. `ringFrame`, the plane-quad
   placement (`planeOffset`/`planeSize`), the view ring's scale and the
   away-facing alpha come out of `SceneGizmoOverlay.swift` -- 1732 lines of
   real math inside SwiftUI view bodies -- and into the core, which is the
   order this repository committed to: extract on the Mac BEFORE the
   Windows UI needs an equivalent, rather than porting later straight out
   of a view body. What BUILDS a layout (`gizmoState`, `handleSet`,
   `gizmoScale`, the drag math) stays there for now: it needs the Phase 5
   model.

   Deferred with reasons: `SceneGizmoTarget` and the light handle's
   payload, both Phase 5 types the builder never reads -- a light's handles
   reach it as positions, and the handle id's only job is to ORDER the
   buffer, so `kLight` is one flat case. Where Swift keys these geometries
   in a `Dictionary` and sorts on the way out (its order is seeded per
   process), the C++ layout carries vectors and the builder sorts by the
   same fixed key: same guarantee, and two platforms emitting the same
   buffer is the stronger version of the argument.

   Tested: `tests/SceneGizmoMeshTests.cpp` (12 tests). A mesh builder is
   easy to test badly -- re-deriving a vertex position restates the loop
   that produced it -- so these assert the documented properties: an arrow
   is EXACTLY `scale` long (that length is what `worldLengthForPixels`
   sized to hold a constant pixel size, so a head that overshoots makes the
   gizmo grow as the camera turns), a highlighted handle reads thicker
   rather than merely brighter and without getting longer, an away-facing
   axis dims rather than disappearing, the emit order is fixed whatever
   order the layout was filled in, the layers come out in draw order as a
   PREFIX property (adding a layer never disturbs what is below), the plane
   quad is double-sided and sits between its offset and its size, the view
   ring is outside the world rings and billboarded to the camera's forward,
   every primitive is a whole number of triangles with unit normals, a
   torus's points lie in its own tube, and degenerate input emits nothing
   rather than NaN vertices. Two of those tests started as wrong
   expectations of mine and were corrected to what the Swift actually does:
   a zero-scale gizmo does NOT come out empty (the plane quad's corners are
   offsets, not radii, so it has no guard on either side of the port and
   collapses onto the origin), and a light's influence ring keeps the
   ARTIST'S radius, unscaled by the gizmo's screen-constant scale -- only
   its tube's girth comes from that. All 38 test binaries pass.

   **The auxiliary geometry builders are NOT being ported, and that is a
   finding rather than a deferral.** `ArcGeometryBuilder.swift` (152),
   `SphereGeometryBuilder.swift` (140), `ArcMath.swift` (86) and
   `ArcHitTest.swift` (97) are a 3D arc-sphere rotation gizmo that nothing
   reaches. Verified by grep, not by reading: the two builders have ZERO
   references anywhere outside their own files (across `.swift` and
   `.metal` both); `ArcMath` is used only by those two and by `ArcHitTest`;
   and `ArcHitTest`'s only call sites are `ToolManager.updateRotationHover`
   and `handleRotationMouseDown` -- two of the four rotation-hover methods
   this port had ALREADY established as dead when BoneTool landed. The same
   evidence arrived twice from opposite directions.

   What is live is a different gizmo: `GizmoRenderer.rotateGizmoVertices`
   and `skewGizmoVertices` (a 2D ring, dot track and needle), which
   `MetalRenderer` calls and whose hit testing goes through
   `ToolUtilities` -> `.rotateRing` / `.skewEdge`, ported in Phase 2.
   Porting the arcs would have added ~475 lines of a manipulator the app
   neither draws nor tests, and every future reader would have had to work
   out why two rotation gizmos existed.

   Two things worth recording in case that design is ever revived. First,
   `ArcMath` was the SINGLE shared copy behind both the drawing and the hit
   test -- the property this port chases everywhere else, and the reason
   these files are worth reviving rather than rewriting. Second, a trap:
   the arc index means different things in the two files. In the builders 0
   is the outer ring; in `ArcHitTest` 0 is "no hit" and the outer ring is 4
   (`RotationGizmoState.mouseDown` guards on `hitArc > 0`). A literal port
   of the `Int` would inherit that ambiguity; the right shape in C++ is an
   `std::optional`.

   `Render/SceneLighting.h/.cpp` ports `Render/SceneLighting.swift`, plus
   `LightFalloffCurve` out of `Data/Scene/SceneLight.swift` (that file is
   Phase 5's model, but the curve is math, and it is evaluated through
   `AnimationCurve` -- the editor's one curve authority -- so lighting has
   no Bezier code of its own on either side).

   Lighting resolves per LAYER, in SCREEN space, against the layer's own
   plane, and the Swift header explains why that is not where one would
   guess: in texture space a rig instance's mesh-deformed sprite would
   carry the lighting of where the arm was drawn flat, because a texel's
   position says little about where it lands in the world. A Scene layer is
   flat by the model's founding invariant, so the ray through a pixel meets
   its plane in one exact point -- one lattice per layer rather than one
   per sprite. The lattice spacing comes from the light's FADE BAND, never
   its radius: the band is where the curvature is, and everywhere else the
   field is flat or zero and interpolation is exact.

   **A cited-but-missing harness figure was reproduced here for the first
   time in this port.** The Swift header justifies the `contrast == 0`
   branch by measuring that `0.5 + (x - 0.5) * 1.0` moves 3327 of 20 001
   samples, by up to 1.5e-08. The C++ test recomputes that on the same grid
   and gets exactly 3327 and 1.49e-08. It holds because both sides are
   float32, which is this port's founding premise about its math library.
   The neighbouring `smoothness == 0` branch looks like the same rule and
   is not: `(d + 0) / (1 + 0)` is exactly `d` in IEEE 754, so that branch
   exists only to skip work. The Swift header records that treating the two
   as one rule is how its own harness first got written wrong.

   This also closes the `SceneLightUniform` initializer deferred in the GPU
   types: the math enums (`SceneLightKind`, `SceneLightBlend`) and the
   explicit switch that maps them onto the wire codes live here, so the
   rule "map with a switch, never a cast" now has an implementation rather
   than only a comment.

   Not ported: `LightField.composite(from:into:)`. It reads a CoreGraphics
   bitmap and writes another -- it IS the CPU rasterizer this phase
   deliberately does not carry across. Its arithmetic is not lost, because
   it is what the fragment shader does, and it is written into the header
   for Phase 4's last piece:
   `lit = clamp(src * factor + additive * srcAlpha, 0, srcAlpha)` then
   `dst = lit + dst * (1 - srcAlpha)`. The additive term is scaled by alpha
   because it is added to the SURFACE, which only exists where there is
   alpha; added flat, an additive light lights up the transparent margin of
   every sprite and surrounds its subject with a rectangle of glow.

   Tested: `tests/SceneLightingTests.cpp` (18 tests) -- the drift
   measurement above, smoothness wrapping the terminator rather than
   blurring, attenuation flat inside the inner radius and zero past the rim
   with a monotone band, `depthInfluence` being the only mention of Z (0
   lights a layer a thousand units back as though it sat at the light's own
   depth, 1 puts it out of reach), a spot compared as cosines and
   smoothstepped between its cones, a light set flat staying flat however a
   surface's material is set, each blend routing where the design says
   (`multiply` can only take light away, and only where it reaches;
   `screen` cannot overshoot), the falloff presets matching the closed
   forms their comments claim (flat tangents give exactly 1 - 3u^2 + 2u^3;
   chord tangents give exactly 1 - u), the lattice density coming from the
   band rather than the radius, a missed ray getting ambient rather than a
   hole, and bilinear sampling being exact on a linear field. All 39 test
   binaries pass.

   `Render/SceneRenderBudget.h/.cpp` ports
   `Render/SceneRenderBudget.swift`: the resolution ladder, where the pixel
   cap is MEASURED rather than chosen. A fixed cap has to be picked for the
   worst machine and the heaviest set, which makes it wrong for every other
   combination -- too low and a fast machine shows a soft picture it could
   have drawn sharp, too high and a slow one drops half its frames while
   the artist orbits.

   It is ported even though the Swift header justifies the ladder with
   "Scene composites on the CPU", a premise the GPU path this phase targets
   changes. The two failure modes the ladder exists to avoid are properties
   of the LADDER, not of the rasterizer: oscillation (fixed by PREDICTING
   the rung above -- cost goes as pixels, pixels as the square of the scale
   -- and by requiring the headroom to have lasted eight frames) and
   ratcheting (fixed by returning to the top the moment the reason for
   being down goes away). Two shells each inventing their own would give
   the same artist two different pulsing behaviours on two machines. The
   one number worth revisiting per backend is the target frame time, and it
   is a named constant rather than a hidden assumption.

   Tested: `tests/SceneRenderBudgetTests.cpp` (10 tests). The oscillation
   test is the Swift header's own worked example turned into a scenario: a
   machine measuring 15 ms at half size against a 33 ms budget, which a
   naive "climb when under 60% of target" reads as plenty of room -- it
   climbs, takes 34 ms, is dropped back, and repeats. Six hundred frames of
   that machine leave the rung where it started and never accumulate credit
   towards a climb that would be undone. The rest: stepping down one rung
   at a time however catastrophic the frame, a still canvas going straight
   back to the top, a transient dropping two rungs and the ladder walking
   back up in two eight-frame climbs, a machine settling on the highest
   rung that actually fits, a single expensive frame spending the streak,
   and `FrameCostMeter` taking the median rather than the mean (one 80 ms
   launch frame drags a six-frame mean most of the way to the target and
   would cost a rung). All 40 test binaries pass.

   `Render/SceneShaderMath.h/.cpp` ports `SceneGPU/SceneShaders.metal`
   (1022 L) and `SceneGizmoShaders.metal` (80 L) as a C++ REFERENCE: the
   shading authored once, so MSL and HLSL become transcriptions that are
   diffed numerically against it rather than read side by side. That is
   Risk #5's stated mitigation, and this is the artifact it needed.

   It also replaces something that was lost. The `.metal` banner says it is
   "mirrored by `Editor/gpu_mirror.py` and checked against
   `Editor/lighting_mirror.py`, which stays the normative reference for
   what a lit pixel is worth", because there was no Metal toolchain where
   it was written. Neither script is here -- there is no Python in this
   repository at all -- so the normative reference did not survive. This
   file is executable, tested, and diffable against a GPU capture on either
   platform.

   Texture sampling is MODELLED rather than approximated: bilinear,
   clamp-to-edge, on texel centres, which is what a Metal or Direct3D
   linear sampler does. That is what produced the finding below.

   **FINDING: the falloff sampler and the CPU table do not agree.** The
   shader's comment says the off-by-one the CPU spells out (`u * (n - 1)`,
   not `u * n`) "is the sampler's business, not ours". It is -- and the
   sampler's business is texel CENTRES, `u * n - 0.5` -- so the two read
   different entries of the same table. Measured over a 256-entry table:
   0.29/255 on the default `smooth` curve, 0.50/255 on `linear`, and
   **3.21/255 on `inverseSquare` at u = 0.025**. Three quantisation steps,
   in the steepest part of the steepest preset, means the GPU and the CPU
   compositor put visibly different numbers in the same pixel of the same
   frame. The fix is one line on whichever side is declared normative
   (tabulate at the sampler's positions, or address the table at texel
   centres); it is left to the shell that first ships both paths, because
   changing either side here would silently diverge from the Swift
   original. It is now a number in a test rather than a sentence nobody
   checked.

   Tested: `tests/SceneShaderMathTests.cpp` (19 tests), and the first four
   are the ones that matter, because they are CROSS-CHECKS against the
   already-ported CPU implementation of the same arithmetic:
   `shapedLambert` and `lightLambert` agree BIT FOR BIT (two transcriptions
   of one formula that differ at all have already drifted),
   `lightAttenuation` agrees to within the sampler gap above and nothing
   else, and a whole lit pixel agrees end to end with `SceneLighting::shade`
   composited the way the fragment composites it -- which is the comparison
   `lighting_mirror.py` existed to make. The rest pin the behaviours whose
   failure a still frame cannot show: the tangent frame staying a rotation
   and surviving a bone scaled to nothing, the skinned path keeping the
   layer's lift (the 652-unit bug), a normal map at rest changing nothing
   and strength only tilting, a flat height field marching nowhere (which
   is why offering the normal map's alpha as a height source is safe), the
   secant refinement landing off the step boundaries (the staircase foil),
   the grazing guard bounding the sweep at ten times the depth, a light
   below the surface casting no self-shadow, a blocker BEHIND the receiver
   casting nothing, a flat 2D light casting no shadow at all (which falls
   out of the arithmetic rather than a special case), the deepest shadow
   winning rather than accumulating, a sprite that asks for nothing
   rendering bit for bit as it did, the additive term scaled by alpha so no
   glow rectangle appears around a sprite's transparent margin, the
   silhouette discard, the full-screen triangle's orientation, and the
   gizmo's own key light never going black.

   **Phase 4 is complete.** Nine pieces planned: eight ported, one
   (`ArcGeometryBuilder`/`SphereGeometryBuilder`) established as dead code
   and deliberately not ported. All 41 test binaries pass.
5. **Scene compositing / lighting / physics secondary motion / export** —
   mostly wiring Phase 1 (physics) + Phase 4 (lighting/geometry) together;
   own new scope is export orchestration (PNG sequence/video/texture atlas)
   with platform-swapped codec backends behind a common interface.
   *Status: started.* `Scene/SceneLayer.h/.cpp` ports
   `Data/Scene/SceneLayer.swift` (`SceneFill`, `SceneLayerContent`,
   `SceneLayer`), `Scene/SceneMaterial.h` ports
   `Data/Scene/SceneMaterial.swift`, and `Scene/SceneLightMask.h` lifts
   `SceneLightMask` out of `SceneLight.swift` into a header of its own.

   The mask gets its own file because three different things need it and
   only one of them is a light: a layer's `lightMask` says which channels
   it sits on, a material's `shadowCastMask`/`shadowedMask` say which it
   casts into and catches from, and a light's `mask` says which it
   reaches. Leaving it in the light's header would make a layer include a
   light in order to describe itself, which is backwards -- the mask is
   the vocabulary the three share, not a property of any one of them.

   `SceneLayer` first because it is what the earlier phases were waiting
   on, and they were waiting on purpose. `SceneViewCamera`'s header names
   `cardCorners`/`cardPoint` as blocked on `planePoint`/`liftToWorld`/
   `worldOrigin`, and `SceneLayerUniforms` on `orientation()`; inventing a
   layer type inside Render would have meant re-transcribing this lift,
   which is the "two transcriptions of a rotation" failure
   `SceneProjection`'s header exists because of. There is now exactly one
   transcription.

   What the file is built around, and what the tests assert rather than
   restate:
   - **Every layer is FLAT** -- its Z is constant across the whole card.
     That is what collapses the perspective to a single scale factor, what
     makes parallax cost nothing, and, less obviously, what makes LIGHTING
     exact rather than approximate: `SceneLighting` intersects the ray
     through a pixel with `lightingPlane()` and gets the world point that
     is actually there, whatever the layer contains and however its meshes
     are deformed.
   - **`orientation()` is separate from `planePoint` because of a whole
     bug.** The gizmo used to take its frame by differencing the card's
     transform, which runs points through `planePoint` -- scale, then
     SHEAR, then roll. Normalising the two vectors that came back fixed
     their lengths and could do nothing about the ANGLE between them, so a
     sheared card handed the gizmo a frame that was not a rotation, and a
     matrix like that shears every arrow it multiplies. `orientation()` is
     roll then tilt, with no path for scale or shear to reach it. The test
     therefore checks orthogonality, not length: length alone is exactly
     what the broken version already had.
   - **`planePoint` is scale, then shear, then roll, and that order IS the
     definition.** Shear after the scale means it is expressed in the
     card's scaled units -- the same order `SceneImage` applies skew in --
     so a scaled card slants by the amount the number says rather than by
     that amount times its scale. The test uses a non-uniform scale,
     because a uniform one cannot tell the two orders apart.
   - **`lightingTangent` reads only the SIGN of the scale.** A mirrored
     card draws its artwork reversed, so image +x points the other way and
     the handedness is `sign(scale.x * scale.y)`; a card that is not told
     it is mirrored lights its relief from the wrong side, which is
     entirely plausible in a still and obvious the moment a light crosses
     it. The magnitude is deliberately left out, so relief does not
     stretch with a card scaled 3x wide.
   - **`sortingOrder` and `positionZ` count in opposite directions**, on
     purpose: Z is a distance and things further off have more of it,
     while a stacking order counts upward towards the viewer in every tool
     that has one. Depth still reorders nothing.

   One documented divergence, the same one `SceneCulling.cpp` already
   makes and for the same reason: `rigFrame` converts
   `round(sceneFrame * speed)` through a saturating cast. Swift traps on a
   value outside `Int`, and the conversion is undefined in C++; a NaN
   speed out of a hand-edited file is what reaches it. The clamp or wrap
   that follows puts any saturated value back inside the clip, so no
   in-range input is affected.

   `SceneMaterial`'s default is a hard requirement rather than a taste,
   and the test says so as an equality with a freshly defaulted material
   rather than field by field -- a field added later cannot escape the
   bit-for-bit promise by not being listed. `sanitized` replaces a
   non-finite value with the DEFAULT and only then clamps, which is worth
   stating because one test asserted the opposite first and the code was
   right: an infinite `parallaxDepth` comes back 0.05, not 0.5.

   Tested: `tests/SceneLayerTests.cpp` (31 tests).

   `Scene/SceneComposition.h/.cpp` then ports the `SceneComposition` half
   of `Data/Scene/SceneComposition.swift`, `Scene/SceneCamera.h` ports
   `Data/Scene/SceneCamera.swift`, and `Scene/SceneLight.h` ports the
   MODEL half of `Data/Scene/SceneLight.swift`.

   Three things this deliberately did NOT write:
   - The lighting math. It landed in Phase 4 as
     `Render/SceneLighting.h`'s `LightFalloffCurve`, `lightDirection`,
     `lightInnerRadius`, `lightBandWidth` and `SceneLightParams` -- which
     is precisely "everything the lighting math reads off a light". So
     `SceneLight::params()` fills one and `direction()`/`innerRadius()`/
     `bandWidth()` ask the existing functions. A second transcription of
     the band width would be a particularly bad one to have: it is what
     the lattice density is chosen from, so two versions would not look
     wrong, they would look slightly grainy.
   - `SceneAmbient`. Already ported, in the same Render header, because
     the lighting solve holds one directly. A model-side copy is how two
     structs that mean the same thing start to differ by a field.
   - A second pair of "model" enums. `SceneLightKind` and
     `SceneLightBlend` already exist; what actually has to be explicit is
     the mapping from a case to its STORED TOKEN, which is what
     `sceneLightKindName`/`FromName` are. Never a cast -- a cast would
     make the saved file depend on declaration order, the rule
     `SceneGPUTypes.h` states for the wire codes.

   `SceneCamera` closes `SceneProjection`'s first deferred convenience
   initializer, as `sceneProjection(camera, viewSize)`. It lives in the
   Scene header rather than on `SceneProjection` so the dependency points
   one way: Scene knows about Render, Render never learns about Scene.
   `SceneViewCamera::projection()` was already the other half.

   `drawOrderedLayers` sorts `(sortingOrder, index)` pairs explicitly
   rather than sorting layers by the number alone. Neither Swift's
   `sorted(by:)` nor `std::sort` is stable, and the array's order is the
   documented tie-break -- two cards on one layer swapping between runs
   would have an artist watching their set restack itself for no reason.
   The test uses twenty same-order cards, because a short run can pass on
   an unstable sort by luck (most implementations insertion-sort small
   ranges).

   **A bug found by a test, in this port's own new code.**
   `frontSortingOrder` used Swift's `-1` as the SEED of the running
   maximum rather than as the fallback for an empty scene. Every layer
   having a negative `sortingOrder` then gave 0 -- putting a new card
   BEHIND the cards it was supposed to lead, and only in a scene where the
   artist had numbered everything below zero. `max() ?? -1` means the max
   of the array, with -1 standing in only when there is no array.

   Two small additive changes in `Render/SceneLighting.h`, documented in
   place: `LightFalloffStop`, `LightFalloffCurve` and `SceneAmbient` gained
   equality, because the Phase 5 model types that hold them are
   `Equatable` in Swift. The curve compares by its STOPS and not by its
   table: the table is derived, so comparing it would restate the same
   information 256 times and would call two curves different over a
   rounding difference in the tabulation.

   Tested: `tests/SceneCompositionTests.cpp` (23 tests) -- draw order and
   its tie-break, depth reordering nothing, front-to-back being exactly
   the reverse (the two ends disagreeing is a bug this project has already
   shipped once), the visibility threshold, the shot camera not picking up
   the fly camera's numbers, a degenerate depth range still producing a
   divisible projection, and the light model's derived values agreeing
   with the Phase 4 math they are asked of. All 43 test binaries pass.
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
