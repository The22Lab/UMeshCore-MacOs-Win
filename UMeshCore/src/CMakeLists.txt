# UMeshCore library sources.
#
# Phase 1 (math + data model) files get appended here as they land. Grouped
# to mirror include/umeshcore/<Module>/ and the Swift source layout
# (Data/, Core/) so a reviewer can find the C++ file for any Swift file by
# name.

add_library(umeshcore STATIC
    Version.cpp
    Core/NaturalCompare.cpp
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
    Render/SceneLighting.cpp
    Render/SceneRenderBudget.cpp
    Render/SceneShaderMath.cpp
    Scene/SceneLayer.cpp
    Scene/SceneComposition.cpp
    Scene/ScenePlayback.cpp
    Export/ExportSettings.cpp
    Mesh/MeshKernel.cpp
    Mesh/MeshValidator.cpp
    Mesh/Mesh.cpp
    Mesh/MeshEditing.cpp
    Mesh/MeshTrace.cpp
    Editor/ToolUtilities.cpp
    Editor/CanvasPicking.cpp
    Editor/CanvasImagePicking.cpp
    Editor/Tools/SelectTool.cpp
    Editor/Tools/MoveTool.cpp
    Editor/Tools/ScaleTool.cpp
    Editor/Tools/SkewTool.cpp
    Editor/Tools/RotateTool.cpp
    Editor/Tools/BoneTool.cpp
    Editor/Tools/MeshTool.cpp
    Editor/Tools/PhysicsPreviewTool.cpp
    Editor/ToolManager.cpp
    Editor/SceneGizmoState.cpp
    Editor/SceneGizmoDrag.cpp
    Editor/SceneLightGizmo.cpp
    Editor/GraphViewport.cpp
    Editor/TimelineGraphMath.cpp
    Editor/HierarchyDisplay.cpp
    Editor/SceneViewport.cpp
    Editor/IKBuilder.cpp
    Editor/EditorSceneStructure.cpp
    Editor/EditorSceneSkins.cpp
    Editor/EditorSceneConstraints.cpp
    Editor/EditorSceneAnimation.cpp
    Editor/EditorSceneCompositing.cpp
    Editor/EditorSceneProject.cpp
    Editor/EditorSceneMirror.cpp
    Editor/EditorSceneMesh.cpp
    Interop/SwiftBridge.cpp
    Serialization/BinaryExporter.cpp
    Serialization/Json.cpp
    Serialization/ProjectDocument.cpp
    Serialization/ProjectPackage.cpp
    Serialization/Sha256.cpp
    Serialization/SavedAnimation.cpp
    Serialization/SavedEditorState.cpp
    Serialization/SavedGeometry.cpp
    Serialization/SavedScene.cpp
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

# --- Install / export ---------------------------------------------------
#
# What makes UMeshCore consumable from outside this tree, which is the
# whole of what Phase 6 needs before either shell can call anything.
#
# Two consumers, one export set:
#   - Xcode (Phase 6a). The Mac app puts the installed `include/` on its
#     header search path and links `libumeshcore.a`; `include/module.modulemap`
#     travels with the headers, so `import UMeshCore` resolves.
#   - CMake/MSVC (Phase 6b). `find_package(UMeshCore)` then link
#     `UMeshCore::umeshcore`.
#
# The `module.modulemap` is installed NEXT TO the header tree rather than
# inside it: Clang looks for it at the root of a header search path, so
# `include/module.modulemap` alongside `include/umeshcore/` is the layout
# that works. Installing it under `include/umeshcore/` would put it where
# nothing looks for it.
include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

install(TARGETS umeshcore
        EXPORT UMeshCoreTargets
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
        INCLUDES DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

install(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../include/umeshcore
        DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
        FILES_MATCHING PATTERN "*.h")

install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../include/module.modulemap
        DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

install(EXPORT UMeshCoreTargets
        FILE UMeshCoreTargets.cmake
        NAMESPACE UMeshCore::
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/UMeshCore)

write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/UMeshCoreConfigVersion.cmake"
    VERSION ${PROJECT_VERSION}
    # The port's own numbering is the PHASE, not a release, so nothing
    # downstream should pin a patch level it cannot check. SameMajorVersion
    # says what is actually promised: the surface does not break inside a
    # major.
    COMPATIBILITY SameMajorVersion)

configure_package_config_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/../cmake/UMeshCoreConfig.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/UMeshCoreConfig.cmake"
    INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/UMeshCore)

install(FILES
        "${CMAKE_CURRENT_BINARY_DIR}/UMeshCoreConfig.cmake"
        "${CMAKE_CURRENT_BINARY_DIR}/UMeshCoreConfigVersion.cmake"
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/UMeshCore)
