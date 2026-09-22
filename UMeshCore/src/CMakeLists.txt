# UMeshCore library sources.
#
# Phase 1 (math + data model) files get appended here as they land. Grouped
# to mirror include/umeshcore/<Module>/ and the Swift source layout
# (Data/, Core/) so a reviewer can find the C++ file for any Swift file by
# name.

add_library(umeshcore STATIC
    Version.cpp
    Animation/AnimationClip.cpp
    Animation/AnimationLibrary.cpp
    Animation/SceneAnimator.cpp
    Model/Bone.cpp
    Constraints/ConstraintPropagation.cpp
    Constraints/IKSolver.cpp
    Constraints/PathSolver.cpp
    Constraints/TransformConstraintSolver.cpp
    Constraints/PhysicsConstraintSystem.cpp
    Constraints/ConstraintAnimation.cpp
    Render/SceneProjection.cpp
    Render/SceneCulling.cpp
    Render/SceneViewCamera.cpp
    Render/SceneSkinPalette.cpp
    Render/SceneGizmoMeshBuilder.cpp
    Mesh/MeshKernel.cpp
    Mesh/MeshValidator.cpp
    Mesh/Mesh.cpp
    Editor/ToolUtilities.cpp
    Editor/CanvasPicking.cpp
    Editor/Tools/SelectTool.cpp
    Editor/Tools/MoveTool.cpp
    Editor/Tools/ScaleTool.cpp
    Editor/Tools/SkewTool.cpp
    Editor/Tools/RotateTool.cpp
    Editor/Tools/BoneTool.cpp
    Editor/ToolManager.cpp
    Serialization/BinaryExporter.cpp
    Serialization/Json.cpp
    Serialization/ProjectDocument.cpp
    Serialization/ProjectPackage.cpp
    Serialization/Sha256.cpp
    Serialization/SavedAnimation.cpp
    Serialization/SavedEditorState.cpp
    Serialization/SavedGeometry.cpp
    Serialization/SavedSceneImage.cpp
    Serialization/SavedSkeleton.cpp
    Serialization/UMJsonBuilder.cpp
)

target_include_directories(umeshcore
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/../include>
        $<INSTALL_INTERFACE:include>
)

target_compile_features(umeshcore PUBLIC cxx_std_20)

if(MSVC)
    target_compile_options(umeshcore PRIVATE /W4)
else()
    target_compile_options(umeshcore PRIVATE -Wall -Wextra)
endif()
