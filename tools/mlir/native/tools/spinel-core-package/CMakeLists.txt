add_llvm_executable(spinel-core-package main.cpp)
llvm_update_compile_flags(spinel-core-package)
target_link_libraries(spinel-core-package
  PRIVATE SpinelCoreBoundary SpinelCoreEligibility)
