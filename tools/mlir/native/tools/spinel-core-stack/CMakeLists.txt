add_llvm_executable(spinel-core-stack main.cpp)
llvm_update_compile_flags(spinel-core-stack)
target_link_libraries(spinel-core-stack PRIVATE SpinelCoreKernel)
mlir_check_all_link_libraries(spinel-core-stack)
