# Each Swift source file being ported gets one test executable here, named
# to match (MathTests <-> Transform3D2D.swift/MatrixUtilities.swift), so
# coverage gaps are visible by scanning this file against
# `UltraMesh 2d animation/`.

function(umeshcore_add_test name)
    add_executable(${name} ${ARGN})
    target_link_libraries(${name} PRIVATE umeshcore)
    target_include_directories(${name} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    add_test(NAME ${name} COMMAND ${name})
endfunction()

umeshcore_add_test(MathTests MathTests.cpp)
umeshcore_add_test(AnimationTests AnimationTests.cpp)
umeshcore_add_test(SceneAnimatorTests SceneAnimatorTests.cpp)
umeshcore_add_test(SkeletonTests SkeletonTests.cpp)
umeshcore_add_test(ConstraintsTests ConstraintsTests.cpp)
umeshcore_add_test(ConstraintAnimationTests ConstraintAnimationTests.cpp)
umeshcore_add_test(MeshPredicatesTests MeshPredicatesTests.cpp)
umeshcore_add_test(MeshKernelTests MeshKernelTests.cpp)
umeshcore_add_test(MeshTests MeshTests.cpp)
umeshcore_add_test(SkinTests SkinTests.cpp)
umeshcore_add_test(EditorFoundationTests EditorFoundationTests.cpp)
umeshcore_add_test(SceneModelTests SceneModelTests.cpp)
umeshcore_add_test(ToolUtilitiesTests ToolUtilitiesTests.cpp)
umeshcore_add_test(EditorSceneTests EditorSceneTests.cpp)
umeshcore_add_test(CanvasPickingTests CanvasPickingTests.cpp)
umeshcore_add_test(SelectToolTests SelectToolTests.cpp)
umeshcore_add_test(MoveToolTests MoveToolTests.cpp)
umeshcore_add_test(ScaleToolTests ScaleToolTests.cpp)
umeshcore_add_test(SkewToolTests SkewToolTests.cpp)
umeshcore_add_test(RotateToolTests RotateToolTests.cpp)
umeshcore_add_test(BoneToolTests BoneToolTests.cpp)
umeshcore_add_test(ToolManagerTests ToolManagerTests.cpp)
umeshcore_add_test(BinarySerializationTests BinarySerializationTests.cpp)
umeshcore_add_test(BinaryExporterTests BinaryExporterTests.cpp)
umeshcore_add_test(JsonTests JsonTests.cpp)
umeshcore_add_test(SavedSkeletonTests SavedSkeletonTests.cpp)
umeshcore_add_test(SavedAnimationTests SavedAnimationTests.cpp)
umeshcore_add_test(SavedSceneImageTests SavedSceneImageTests.cpp)
umeshcore_add_test(ProjectDocumentTests ProjectDocumentTests.cpp)
umeshcore_add_test(ProjectPackageTests ProjectPackageTests.cpp)
umeshcore_add_test(AnimationLibraryTests AnimationLibraryTests.cpp)
umeshcore_add_test(UMJsonTests UMJsonTests.cpp)
umeshcore_add_test(SceneProjectionTests SceneProjectionTests.cpp)
umeshcore_add_test(SceneCullingTests SceneCullingTests.cpp)
umeshcore_add_test(SceneViewCameraTests SceneViewCameraTests.cpp)
umeshcore_add_test(SceneGPUTypesTests SceneGPUTypesTests.cpp)
umeshcore_add_test(SceneSkinPaletteTests SceneSkinPaletteTests.cpp)
umeshcore_add_test(SceneGizmoMeshTests SceneGizmoMeshTests.cpp)
umeshcore_add_test(SceneLightingTests SceneLightingTests.cpp)
umeshcore_add_test(SceneRenderBudgetTests SceneRenderBudgetTests.cpp)
umeshcore_add_test(SceneShaderMathTests SceneShaderMathTests.cpp)
umeshcore_add_test(SceneLayerTests SceneLayerTests.cpp)
umeshcore_add_test(SceneCompositionTests SceneCompositionTests.cpp)
umeshcore_add_test(SavedSceneTests SavedSceneTests.cpp)
umeshcore_add_test(ScenePlaybackTests ScenePlaybackTests.cpp)
umeshcore_add_test(PhysicsPreviewToolTests PhysicsPreviewToolTests.cpp)
umeshcore_add_test(ExportSettingsTests ExportSettingsTests.cpp)

# --- Header self-containment -------------------------------------------
#
# Compiles EVERY public header as its own translation unit, alone, so a
# header that quietly depends on whatever its neighbours included before
# it cannot land. That property is what makes `src/*.cpp` able to include
# only what it uses, and what makes the umbrella header (`UMeshCore.h`)
# safe to reorder.
#
# All 97 headers pass today. This target exists so the first one that
# stops passing fails a build rather than a shell's, months later, on
# another platform's compiler.
#
# CONFIGURE_DEPENDS so a header added without re-running cmake is still
# picked up; the generated sources are one `#include` each, so the whole
# target costs about as much as one ordinary test.
file(GLOB_RECURSE UMESHCORE_PUBLIC_HEADERS CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_SOURCE_DIR}/../include/umeshcore/*.h")

set(UMESHCORE_SELFTEST_SOURCES "")
foreach(header ${UMESHCORE_PUBLIC_HEADERS})
    file(RELATIVE_PATH rel "${CMAKE_CURRENT_SOURCE_DIR}/../include" "${header}")
    string(REPLACE "/" "_" stem "${rel}")
    string(REPLACE "." "_" stem "${stem}")
    set(generated "${CMAKE_CURRENT_BINARY_DIR}/selftest/${stem}.cpp")
    file(GENERATE OUTPUT "${generated}" CONTENT "#include \"${rel}\"\n")
    list(APPEND UMESHCORE_SELFTEST_SOURCES "${generated}")
endforeach()

file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/selftest/main.cpp" CONTENT
"// Generated. Every other TU in this target includes exactly one public\n\
// header and nothing else; linking them together is the test.\n\
#include <cstdio>\n\
int main() { std::fprintf(stderr, \"all checks passed\\n\"); return 0; }\n")

add_executable(HeaderSelfContainmentTests
    "${CMAKE_CURRENT_BINARY_DIR}/selftest/main.cpp"
    ${UMESHCORE_SELFTEST_SOURCES})
target_link_libraries(HeaderSelfContainmentTests PRIVATE umeshcore)
add_test(NAME HeaderSelfContainmentTests COMMAND HeaderSelfContainmentTests)
umeshcore_add_test(SceneGizmoStateTests SceneGizmoStateTests.cpp)
umeshcore_add_test(SceneGizmoDragTests SceneGizmoDragTests.cpp)
umeshcore_add_test(SceneLightGizmoTests SceneLightGizmoTests.cpp)
umeshcore_add_test(GraphViewportTests GraphViewportTests.cpp)
umeshcore_add_test(TimelineGraphMathTests TimelineGraphMathTests.cpp)
umeshcore_add_test(HierarchyDisplayTests HierarchyDisplayTests.cpp)
umeshcore_add_test(SceneViewportTests SceneViewportTests.cpp)
umeshcore_add_test(SwiftBridgeTests SwiftBridgeTests.cpp)
umeshcore_add_test(EditorSceneStructureTests EditorSceneStructureTests.cpp)
umeshcore_add_test(EditorSceneConstraintsTests EditorSceneConstraintsTests.cpp)
