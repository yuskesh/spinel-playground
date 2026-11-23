add_llvm_executable(spbpf-compile spbpf-compile.cpp)
llvm_update_compile_flags(spbpf-compile)
target_link_libraries(spbpf-compile PRIVATE
  MLIRSpBPFDialect
  MLIRSpBPFTransforms
  SpinelMLIRSpBPFObject
  MLIRParser
  MLIRPass
  MLIRArithToLLVM
  MLIRReconcileUnrealizedCasts
  MLIRFuncDialect
  MLIRSCFDialect
  MLIRControlFlowDialect
  MLIRLLVMDialect)
mlir_check_all_link_libraries(spbpf-compile)
