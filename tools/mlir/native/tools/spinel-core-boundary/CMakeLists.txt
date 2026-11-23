add_llvm_executable(spinel-core-boundary main.cpp)
llvm_update_compile_flags(spinel-core-boundary)
# SpinelCoreEligibility carries Input.cpp, which is how a source becomes an
# analysed ContractModule -- the entry is resolved against that AST rather than
# against the file's text, so no Ruby parser is added here.
target_link_libraries(spinel-core-boundary
  PRIVATE SpinelCoreBoundary SpinelCoreEligibility)
