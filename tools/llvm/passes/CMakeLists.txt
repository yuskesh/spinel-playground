cmake_minimum_required(VERSION 3.20)
project(SpinelGCRoots LANGUAGES C CXX)

# The plugin is loaded into the LLVM 23.1.1 `opt` the gradient tools run
# (docs/building.md), so it is built only against that LLVM. LLVM_DIR comes
# from -DLLVM_DIR or from $LLVM_PREFIX/bin/llvm-config. There is no fallback:
# without either, CMake's own search silently picked a system LLVM (19.1.7 on
# Debian 13), and that plugin does not load into LLVM 23's opt.
set(SPINEL_LLVM_VERSION 23.1.1)
if(NOT DEFINED LLVM_DIR)
  if(NOT DEFINED ENV{LLVM_PREFIX} OR "$ENV{LLVM_PREFIX}" STREQUAL "")
    message(FATAL_ERROR
      "set LLVM_PREFIX to the official LLVM ${SPINEL_LLVM_VERSION} "
      "(docs/building.md), or pass -DLLVM_DIR=<its lib/cmake/llvm>")
  endif()
  execute_process(COMMAND $ENV{LLVM_PREFIX}/bin/llvm-config --cmakedir
                  OUTPUT_VARIABLE _cd OUTPUT_STRIP_TRAILING_WHITESPACE
                  RESULT_VARIABLE _rc ERROR_QUIET)
  if(NOT _rc EQUAL 0 OR NOT _cd)
    message(FATAL_ERROR
      "no llvm-config at LLVM_PREFIX=$ENV{LLVM_PREFIX}: set LLVM_PREFIX to the "
      "official LLVM ${SPINEL_LLVM_VERSION}, or pass -DLLVM_DIR")
  endif()
  set(LLVM_DIR "${_cd}")
endif()

# NO_DEFAULT_PATH: only LLVM_DIR is consulted, never a system LLVM.
find_package(LLVM REQUIRED CONFIG PATHS "${LLVM_DIR}" NO_DEFAULT_PATH)
if(NOT LLVM_PACKAGE_VERSION VERSION_EQUAL SPINEL_LLVM_VERSION)
  message(FATAL_ERROR
    "LLVM ${LLVM_PACKAGE_VERSION} from ${LLVM_DIR}; the plugin needs LLVM "
    "${SPINEL_LLVM_VERSION} (docs/building.md)")
endif()
message(STATUS "LLVM ${LLVM_PACKAGE_VERSION} from ${LLVM_DIR}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(SpinelGCRoots MODULE SpinelGCRoots.cpp)
target_include_directories(SpinelGCRoots PRIVATE ${LLVM_INCLUDE_DIRS})
target_compile_definitions(SpinelGCRoots PRIVATE ${LLVM_DEFINITIONS})
if(NOT LLVM_ENABLE_RTTI)
  target_compile_options(SpinelGCRoots PRIVATE -fno-rtti)
endif()

# out-of-tree plugins resolve LLVM symbols from the host (clang/opt)
if(APPLE)
  target_link_options(SpinelGCRoots PRIVATE -Wl,-undefined,dynamic_lookup)
endif()
