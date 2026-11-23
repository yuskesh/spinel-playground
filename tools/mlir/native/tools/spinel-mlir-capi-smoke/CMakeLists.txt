add_llvm_executable(spinel-mlir-capi-smoke main.c)
target_link_libraries(spinel-mlir-capi-smoke PRIVATE SpinelMLIRCAPI)
