add_llvm_executable(spinel-core-check main.cpp)
llvm_update_compile_flags(spinel-core-check)
target_link_libraries(spinel-core-check PRIVATE SpinelCoreEligibility)
