# The machine-code step of the freestanding lane: LLVM IR and a profile in, an
# object out. spinel-fs-emit and spinel-fs-grad stop at LLVM IR and run this,
# so the five backends are linked here only. It links no MLIR.
add_llvm_executable(spinel-fs-codegen main.cpp)
llvm_update_compile_flags(spinel-fs-codegen)
target_link_libraries(spinel-fs-codegen PRIVATE
  SpinelMLIRFreestandingCodegen
  SpinelMLIRFreestanding
  LLVMIRReader
  LLVMAsmParser
  LLVMCore
  LLVMSupport)
