# cmux-sv-model: the trace model sidecar (see build.sh). Built on the host, from
# slang (MIT, https://github.com/MikePopoloski/slang) at a pinned release.
cmake_minimum_required(VERSION 3.20)
project(cmux_sv_model LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# An installed slang of the pinned version (its CMake package) is used when
# given (-DSV_MODEL_SLANG_DIR=<prefix>/lib/cmake/slang); otherwise slang is
# built from the source tree build.sh unpacked (-DSV_MODEL_SLANG_SOURCE=...).
set(SV_MODEL_SLANG_SOURCE "" CACHE PATH "slang source tree")
if(SV_MODEL_SLANG_SOURCE)
  set(SLANG_INCLUDE_TOOLS OFF CACHE BOOL "" FORCE)
  set(SLANG_INCLUDE_TESTS OFF CACHE BOOL "" FORCE)
  set(SLANG_INCLUDE_INSTALL OFF CACHE BOOL "" FORCE)
  set(SLANG_INCLUDE_DOCS OFF CACHE BOOL "" FORCE)
  set(SLANG_INCLUDE_PYLIB OFF CACHE BOOL "" FORCE)
  set(SLANG_USE_MIMALLOC OFF CACHE BOOL "" FORCE)
  add_subdirectory(${SV_MODEL_SLANG_SOURCE} slang EXCLUDE_FROM_ALL)
else()
  find_package(slang 12.1 REQUIRED CONFIG)
endif()

add_executable(cmux-sv-model sv_model.cpp)
target_link_libraries(cmux-sv-model PRIVATE slang::slang)
