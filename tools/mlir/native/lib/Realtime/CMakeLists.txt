# Allocation-proof library reads LLVM IR and links no MLIR/dialects.
add_library(SpinelMLIRRealtime STATIC MayAllocate.cpp WholeModule.cpp)
target_include_directories(SpinelMLIRRealtime PUBLIC
  ${CMAKE_SOURCE_DIR}/include
  # Generate AllocVocabulary.inc during configuration.
  ${CMAKE_BINARY_DIR}/include)
# Spinel Extended: the components are named. The predecessor linked one LLVM
# dylib, where LLVMSupport resolved everything; with the release's static
# components, reading IR, linking modules and walking archives need their own.
target_link_libraries(SpinelMLIRRealtime PUBLIC
  LLVMSupport LLVMCore LLVMIRReader LLVMBitReader LLVMLinker LLVMObject)
