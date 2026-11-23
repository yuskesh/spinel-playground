add_llvm_executable(spinel-core-adapter main.cpp)
llvm_update_compile_flags(spinel-core-adapter)
target_link_libraries(spinel-core-adapter
  PRIVATE SpinelCoreAdapter SpinelCoreBoundary SpinelCoreEligibility)
