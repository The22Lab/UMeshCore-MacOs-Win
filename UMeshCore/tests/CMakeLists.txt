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
