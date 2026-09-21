# UMeshCore library sources.
#
# Phase 1 (math + data model) files get appended here as they land. Grouped
# to mirror include/umeshcore/<Module>/ and the Swift source layout
# (Data/, Core/) so a reviewer can find the C++ file for any Swift file by
# name.

add_library(umeshcore STATIC
    Version.cpp
    Animation/AnimationClip.cpp
    Model/Bone.cpp
    Constraints/ConstraintPropagation.cpp
    Constraints/IKSolver.cpp
    Constraints/PathSolver.cpp
    Constraints/TransformConstraintSolver.cpp
    Constraints/PhysicsConstraintSystem.cpp
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
