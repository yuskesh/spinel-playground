# Spinel Extended: reduced to the libraries that spinel-fs-emit and
# spinel-fs-check actually link. The predecessor file also declares
# SpinelMLIRSupport, SpinelMLIRPasses and SpinelMLIRCAPI and descends into
# Tensor and Target; none of those are reached by this slice, and the
# CAPI library needs the SpBPF schema that is not imported.
add_subdirectory(Contract)
add_subdirectory(Core)
add_subdirectory(Frontend)
# The tensor lane (E163): tensor_def / assign! / tensor_extern to linalg-on-tensors.
add_subdirectory(Tensor)
add_subdirectory(Freestanding)
# The allocation-freedom prover (E169): reads LLVM IR, links no MLIR dialect.
add_subdirectory(Realtime)
add_subdirectory(Conversion)
add_subdirectory(Dialect)
# The SpBPF lane: its schema reader and BPF object emitter, and the C API
# over them.
add_subdirectory(Target)
add_library(SpinelMLIRCAPI STATIC
  CAPI/Support.cpp
  CAPI/SpBPF.cpp)
target_include_directories(SpinelMLIRCAPI PUBLIC
  ${CMAKE_SOURCE_DIR}/include)
target_link_libraries(SpinelMLIRCAPI PUBLIC SpinelMLIRSpBPFSchema)
