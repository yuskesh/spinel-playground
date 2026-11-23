# Native compiler foundation. build.sh is the canonical configure command.
cmake_minimum_required(VERSION 3.20)
project(spinel-mlir-native LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(MLIR REQUIRED CONFIG)
message(STATUS "MLIRConfig.cmake: ${MLIR_DIR}")
message(STATUS "LLVMConfig.cmake: ${LLVM_DIR}")
message(STATUS "LLVM version:     ${LLVM_PACKAGE_VERSION}")

# Set out-of-tree executable output explicitly to match lit's <build>/bin.
set(LLVM_RUNTIME_OUTPUT_INTDIR ${CMAKE_BINARY_DIR}/bin)
set(LLVM_LIBRARY_OUTPUT_INTDIR ${CMAKE_BINARY_DIR}/lib)

list(APPEND CMAKE_MODULE_PATH "${MLIR_CMAKE_DIR}")
list(APPEND CMAKE_MODULE_PATH "${LLVM_CMAKE_DIR}")
include(TableGen)
include(AddLLVM)
include(AddMLIR)

# Spinel Extended: the imported slice is built against the official LLVM release,
# which is configured with LLVM_ENABLE_RTTI=OFF. The libraries below are declared
# with plain add_library(), so they do not inherit the -fno-rtti that AddLLVM
# gives add_llvm_library targets, and linking RTTI-enabled objects against an
# RTTI-free MLIR fails with "undefined reference to typeinfo for mlir::Dialect".
# Match whatever the MLIR being linked was built with; on an RTTI-enabled
# toolchain this block does nothing.
if(DEFINED LLVM_ENABLE_RTTI AND NOT LLVM_ENABLE_RTTI)
  add_compile_options($<$<COMPILE_LANGUAGE:CXX>:-fno-rtti>)
endif()

# Keep exactly one LLVM instance in each process. When a toolchain supplies
# shared libLLVM, exported MLIR targets may still reference static LLVMCore
# and other components. On macOS, tools linked both the dylib and ten static
# archives. Enzyme used the dylib, splitting AnalysisManager and cl::opt
# registries from the tool's static copy; spinel-fs-grad crashed in
# AnalysisManager::getResultImpl. On Linux, static components also made LSan
# detect duplicate TensorSpec construction. Redirect component locations to
# the dylib and cut their transitive interfaces, including for non-plugin tools.
if(LLVM_LINK_LLVM_DYLIB AND TARGET LLVM)
# Locations are exported per configuration (Homebrew RELEASE, Debian
# RELWITHDEBINFO). Checking only two fixed names silently skipped this on
# Debian, leaving thirty static LLVM references. Inspect all imported
# configurations and warn on failure so another toolchain cannot hide it.
  get_target_property(_spinel_llvm_dylib LLVM IMPORTED_LOCATION)
  if(NOT _spinel_llvm_dylib)
    get_target_property(_spinel_llvm_cfgs LLVM IMPORTED_CONFIGURATIONS)
    foreach(_cfg IN LISTS _spinel_llvm_cfgs)
      get_target_property(_spinel_llvm_dylib LLVM IMPORTED_LOCATION_${_cfg})
      if(_spinel_llvm_dylib)
        break()
      endif()
    endforeach()
  endif()
  if(NOT _spinel_llvm_dylib)
    message(WARNING "spinel-mlir: LLVM_LINK_LLVM_DYLIB is ON but the LLVM dylib location could not be resolved (IMPORTED_CONFIGURATIONS=${_spinel_llvm_cfgs}); static LLVM components stay linked — a pass plugin loaded in-process may crash")
  endif()
  if(_spinel_llvm_dylib)
    foreach(_c IN LISTS LLVM_AVAILABLE_LIBS)
      if(_c MATCHES "^LLVM[A-Za-z0-9]+$" AND NOT _c STREQUAL "LLVM" AND TARGET ${_c})
        get_target_property(_kind ${_c} TYPE)
        if(_kind STREQUAL "STATIC_LIBRARY")
          set_target_properties(${_c} PROPERTIES
            IMPORTED_LOCATION "${_spinel_llvm_dylib}"
            IMPORTED_LOCATION_RELEASE "${_spinel_llvm_dylib}"
            IMPORTED_LOCATION_DEBUG "${_spinel_llvm_dylib}"
            IMPORTED_LOCATION_RELWITHDEBINFO "${_spinel_llvm_dylib}"
            IMPORTED_LOCATION_MINSIZEREL "${_spinel_llvm_dylib}"
            INTERFACE_LINK_LIBRARIES "LLVM")
        endif()
      endif()
    endforeach()
    message(STATUS "spinel-mlir: LLVM components resolve to ${_spinel_llvm_dylib} (single LLVM per process)")
  endif()
endif()
include(HandleLLVMOptions)

# Embed the canonical tools/realtime/alloc_vocabulary.tsv at configure time.
# Native rtcheck and the undefined-symbol gate use the same allocation set.
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/GenAllocVocabulary.cmake)
spinel_generate_alloc_vocabulary(
  ${CMAKE_CURRENT_SOURCE_DIR}/../../realtime/alloc_vocabulary.tsv
  ${CMAKE_BINARY_DIR}/include/spinel-mlir/Realtime/AllocVocabulary.inc)

# Decision 0042 stage 4: tools/core/hosted-prelude.rb, the one copy of the
# prelude the reader's and the hosted compiler's copies of a source get.
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/GenHostedPrelude.cmake)
spinel_generate_hosted_prelude(
  ${CMAKE_CURRENT_SOURCE_DIR}/../../core/hosted-prelude.rb
  ${CMAKE_BINARY_DIR}/include/spinel-mlir/Core/HostedPrelude.inc)

include_directories(${LLVM_INCLUDE_DIRS} ${MLIR_INCLUDE_DIRS})
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)
# ODS-generated *.h.inc / *.cpp.inc files use matching build-relative paths.
include_directories(${CMAKE_CURRENT_BINARY_DIR}/include)
link_directories(${LLVM_BUILD_LIBRARY_DIR})

# LLVM_DEFINITIONS is one space-separated string. Split it: on Debian the
# leading -D_GLIBCXX_USE_CXX11_ABI=1 otherwise swallowed subsequent definitions.
separate_arguments(LLVM_DEFINITIONS_LIST NATIVE_COMMAND ${LLVM_DEFINITIONS})
add_definitions(${LLVM_DEFINITIONS_LIST})

# Directly linking the imported LLVMSupport target propagates ZLIB, zstd and
# LibEdit interfaces that add the macOS SDK usr/include as -isystem, breaking
# libc++ wrapper-header lookup (for example <cerrno>). MLIR targets avoid this
# through LINK_ONLY. We include none of those headers: remove their include
# requirements only, preserving the link dependencies.
if(APPLE)
  foreach(_t ZLIB::ZLIB LibEdit::LibEdit zstd::libzstd_shared zstd::libzstd_static)
    if(TARGET ${_t})
      set_target_properties(${_t} PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES ""
        INTERFACE_SYSTEM_INCLUDE_DIRECTORIES "")
    endif()
  endforeach()
endif()

# LLVM_DEFAULT_EXTERNAL_LIT points to a nonexistent path on both Debian and
# macOS, allowing configuration to succeed but tests to fail later. Resolve:
# explicit LLVM_EXTERNAL_LIT, <prefix>/bin/llvm-lit, then <prefix>/bin/lit.
# Refuse at configure time if none exists.
if(NOT DEFINED LLVM_EXTERNAL_LIT OR LLVM_EXTERNAL_LIT STREQUAL "")
  foreach(cand "${LLVM_TOOLS_BINARY_DIR}/llvm-lit" "${LLVM_TOOLS_BINARY_DIR}/lit")
    if(EXISTS "${cand}")
      set(LLVM_EXTERNAL_LIT "${cand}" CACHE FILEPATH "lit runner" FORCE)
      break()
    endif()
  endforeach()
endif()
# Spinel Extended: this slice does not import the predecessor lit suite, so a
# lit runner is not a build prerequisite here. The official LLVM release ships
# neither llvm-lit nor the FileCheck/count/not utilities that suite needs.
# Keep the search above, report what it found, and only fail when a caller has
# asked for the lit wiring by pointing LLVM_EXTERNAL_LIT at something missing.
if(DEFINED LLVM_EXTERNAL_LIT AND NOT LLVM_EXTERNAL_LIT STREQUAL ""
   AND NOT EXISTS "${LLVM_EXTERNAL_LIT}")
  message(FATAL_ERROR "LLVM_EXTERNAL_LIT was set to '${LLVM_EXTERNAL_LIT}', which does not exist")
endif()
if(DEFINED LLVM_EXTERNAL_LIT AND NOT LLVM_EXTERNAL_LIT STREQUAL "")
  message(STATUS "lit:              ${LLVM_EXTERNAL_LIT}")
else()
  message(STATUS "lit:              not configured (this slice needs none)")
endif()

# Generate ODS targets before the libraries that depend on them.
# SpBPF: the eBPF MLIR lane (spbpf-compile, spbpf-opt), imported with the Go
# example that consumes it. No other tool links it.
add_subdirectory(include/spinel-mlir/Dialect/SpBPF/IR)
add_subdirectory(include/spinel-mlir/Dialect/SpBPF/Transforms)
# Spinel dialect: three candidate checked-arithmetic operations.
add_subdirectory(include/spinel-mlir/Dialect/Spinel/IR)
# Canonical rewrite pass.
add_subdirectory(include/spinel-mlir/Dialect/Spinel/Transforms)
# Spinel-to-LLVM conversion.
add_subdirectory(include/spinel-mlir/Conversion)

add_subdirectory(lib)
add_subdirectory(tools)
# Spinel Extended: only the SpBPF schema test is imported (unittests/CMakeLists.txt).
add_subdirectory(unittests)
# Spinel Extended: dropped -- the predecessor lit suite is not imported; tests/ carries this slice's
# checks.
# add_subdirectory(test)
