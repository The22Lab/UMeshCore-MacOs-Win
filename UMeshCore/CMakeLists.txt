cmake_minimum_required(VERSION 3.20)
# The version is the PORT's phase numbering, not a release: 5.0 means
# Phases 0-5 have landed. `SameMajorVersion` compatibility in the
# installed config file says what that actually promises downstream.
project(UMeshCore VERSION 5.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(UMESHCORE_BUILD_TESTS "Build UMeshCore unit tests" ON)

# --- umeshcore library --------------------------------------------------
# Phase 1 starts as a header-only interface target (pure math). As
# MeshKernel/AnimationClip/etc. land with real .cpp translation units, this
# becomes a normal STATIC/SHARED target -- see src/CMakeLists.txt.
add_subdirectory(src)

if(UMESHCORE_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
