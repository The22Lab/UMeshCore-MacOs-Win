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
