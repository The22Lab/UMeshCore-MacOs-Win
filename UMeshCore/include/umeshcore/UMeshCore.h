#pragma once

// The umbrella header: the whole of UMeshCore's public surface, in one
// include.
//
// This exists for the PLATFORM SHELLS, and it is the first thing Phase 6
// needs. A Swift target imports a C++ library as a MODULE, and a module
// needs one header to stand for it -- `include/module.modulemap` names
// this file. The Windows side does not strictly need it, but a WinUI 3
// project that includes this gets the same surface the Mac does, spelled
// the same way, which is the point of the library existing at all.
//
// It is NOT a convenience for code inside UMeshCore. A `.cpp` in `src/`
// includes exactly the headers it uses, so that a change to one module
// does not rebuild the world and so that a missing include is caught
// where it happens. `HeaderSelfContainmentTests` compiles every header
// below on its own, one translation unit each, to keep that true: every
// one of these 102 headers stands alone today, and the test is what stops
// the first one that does not from landing quietly.
//
// WHAT DOES NOT CROSS INTO SWIFT UNCHANGED is documented in
// `bindings/swift/README.md`, with the shape each one should take. The
// short version: everything here is importable, but four constructs
// (`std::variant`, `std::function` typedefs, pure-virtual bases, and
// reference-returning accessors) are awkward or unusable from Swift and
// want a facade. They are a small and bounded set -- three variants,
// one function typedef, three virtual bases -- which is why the answer is
// a facade rather than a rewrite.

// ---- Math ----
// The numeric foundation. Hand-written to match Swift `simd` call
// site for call site -- see CLAUDE.md convention #1.
#include "umeshcore/Math/Angle.h"
#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/MatrixUtilities.h"
#include "umeshcore/Math/Transform3D2D.h"
#include "umeshcore/Math/Vec.h"

// ---- Core ----
// Cross-cutting primitives.
#include "umeshcore/Core/Uuid.h"

// ---- Model ----
// The rig: bones, skeleton, sprites, skins.
#include "umeshcore/Model/Bone.h"
#include "umeshcore/Model/HierarchyItem.h"
#include "umeshcore/Model/SceneImage.h"
#include "umeshcore/Model/Skeleton.h"
#include "umeshcore/Model/Skin.h"

// ---- Mesh ----
// Mesh geometry, exact predicates and triangulation.
#include "umeshcore/Mesh/Mesh.h"
#include "umeshcore/Mesh/MeshKernel.h"
#include "umeshcore/Mesh/MeshPredicates.h"
#include "umeshcore/Mesh/MeshTypes.h"
#include "umeshcore/Mesh/MeshValidator.h"

// ---- Constraints ----
// The four solvers and their propagation.
#include "umeshcore/Constraints/Constraint.h"
#include "umeshcore/Constraints/ConstraintAnimation.h"
#include "umeshcore/Constraints/ConstraintPropagation.h"
#include "umeshcore/Constraints/IKConstraint.h"
#include "umeshcore/Constraints/IKSolver.h"
#include "umeshcore/Constraints/PathConstraint.h"
#include "umeshcore/Constraints/PathSolver.h"
#include "umeshcore/Constraints/PhysicsConstraint.h"
#include "umeshcore/Constraints/PhysicsConstraintSystem.h"
#include "umeshcore/Constraints/TransformConstraint.h"
#include "umeshcore/Constraints/TransformConstraintSolver.h"

// ---- Animation ----
// Curves, keyframes, clips, and the per-frame evaluator.
#include "umeshcore/Animation/AnimationClip.h"
#include "umeshcore/Animation/AnimationCurve.h"
#include "umeshcore/Animation/AnimationEvent.h"
#include "umeshcore/Animation/AnimationLibrary.h"
#include "umeshcore/Animation/AnimationTrackProperty.h"
#include "umeshcore/Animation/Keyframe.h"
#include "umeshcore/Animation/SceneAnimator.h"

// ---- Editor ----
// Tools, gizmo metrics, picking and undo -- the editor's logic,
// with no UI in it.
#include "umeshcore/Editor/Bounds2D.h"
#include "umeshcore/Editor/CameraState.h"
#include "umeshcore/Editor/CanvasActivity.h"
#include "umeshcore/Editor/CanvasPicking.h"
#include "umeshcore/Editor/EditorEscape.h"
#include "umeshcore/Editor/EditorScene.h"
#include "umeshcore/Editor/GizmoHandle.h"
#include "umeshcore/Editor/GraphViewport.h"
#include "umeshcore/Editor/HierarchyDisplay.h"
#include "umeshcore/Editor/MeshOverlayMetrics.h"
#include "umeshcore/Editor/MoveGizmoMetrics.h"
#include "umeshcore/Editor/RotateGizmoMetrics.h"
#include "umeshcore/Editor/SceneGizmoDrag.h"
#include "umeshcore/Editor/SceneGizmoState.h"
#include "umeshcore/Editor/SceneLightGizmo.h"
#include "umeshcore/Editor/SceneViewport.h"
#include "umeshcore/Editor/SkewGizmoMetrics.h"
#include "umeshcore/Editor/TimelineGraphMath.h"
#include "umeshcore/Editor/Tool.h"
#include "umeshcore/Editor/ToolInput.h"
#include "umeshcore/Editor/ToolManager.h"
#include "umeshcore/Editor/ToolType.h"
#include "umeshcore/Editor/ToolUtilities.h"
#include "umeshcore/Editor/UndoRedoManager.h"
#include "umeshcore/Editor/Tools/BoneTool.h"
#include "umeshcore/Editor/Tools/MoveTool.h"
#include "umeshcore/Editor/Tools/PhysicsPreviewTool.h"
#include "umeshcore/Editor/Tools/RotateTool.h"
#include "umeshcore/Editor/Tools/ScaleTool.h"
#include "umeshcore/Editor/Tools/SelectTool.h"
#include "umeshcore/Editor/Tools/SkewTool.h"

// ---- Render ----
// Platform-agnostic render geometry: projection, culling, the POD
// wire structs a backend uploads, lighting math and the reference
// shader math.
#include "umeshcore/Render/SceneCulling.h"
#include "umeshcore/Render/SceneGPUTypes.h"
#include "umeshcore/Render/SceneGizmoLayout.h"
#include "umeshcore/Render/SceneGizmoMeshBuilder.h"
#include "umeshcore/Render/SceneGizmoTypes.h"
#include "umeshcore/Render/SceneLighting.h"
#include "umeshcore/Render/SceneProjection.h"
#include "umeshcore/Render/SceneRenderBudget.h"
#include "umeshcore/Render/SceneShaderMath.h"
#include "umeshcore/Render/SceneSkinPalette.h"
#include "umeshcore/Render/SceneViewCamera.h"

// ---- Scene ----
// Scene compositing: layers, lights, cameras, transport.
#include "umeshcore/Scene/SceneCamera.h"
#include "umeshcore/Scene/SceneComposition.h"
#include "umeshcore/Scene/SceneLayer.h"
#include "umeshcore/Scene/SceneLight.h"
#include "umeshcore/Scene/SceneLightMask.h"
#include "umeshcore/Scene/SceneMaterial.h"
#include "umeshcore/Scene/ScenePlayback.h"
#include "umeshcore/Scene/SceneSelection.h"

// ---- Serialization ----
// The three formats -- UMSH binary, the `.umesh` project package,
// and UMJSON interchange.
#include "umeshcore/Serialization/AssetRecord.h"
#include "umeshcore/Serialization/BinaryExportOptions.h"
#include "umeshcore/Serialization/BinaryExporter.h"
#include "umeshcore/Serialization/BinaryReader.h"
#include "umeshcore/Serialization/BinaryWriter.h"
#include "umeshcore/Serialization/Json.h"
#include "umeshcore/Serialization/ProjectDocument.h"
#include "umeshcore/Serialization/ProjectPackage.h"
#include "umeshcore/Serialization/SavedAnimation.h"
#include "umeshcore/Serialization/SavedEditorState.h"
#include "umeshcore/Serialization/SavedGeometry.h"
#include "umeshcore/Serialization/SavedScene.h"
#include "umeshcore/Serialization/SavedSceneImage.h"
#include "umeshcore/Serialization/SavedSkeleton.h"
#include "umeshcore/Serialization/Sha256.h"
#include "umeshcore/Serialization/UMJsonBuilder.h"
#include "umeshcore/Serialization/UMJsonModel.h"
#include "umeshcore/Serialization/UMeshBinaryFormat.h"

// ---- Export ----
// Export configuration. The orchestration is shell; see
// `ExportSettings.h`.
#include "umeshcore/Export/ExportSettings.h"

// ---- Library identity ----
#include "umeshcore/Version.h"
