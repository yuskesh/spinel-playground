add_llvm_executable(spinel-core-kernel main.cpp)
llvm_update_compile_flags(spinel-core-kernel)
target_link_libraries(spinel-core-kernel PRIVATE
  SpinelCoreKernel
  SpinelCoreBoundary
  SpinelCoreEligibility
  SpinelMLIRContract
  SpinelMLIRScalar
  MLIRFuncDialect
  MLIRArithDialect
  MLIRControlFlowDialect
  MLIRLLVMDialect
  MLIRFuncToLLVM
  MLIRArithToLLVM
  MLIRControlFlowToLLVM
  MLIRReconcileUnrealizedCasts
  MLIRTargetLLVMIRExport
  MLIRLLVMToLLVMIRTranslation
  MLIRBuiltinToLLVMIRTranslation
  MLIRPass)
mlir_check_all_link_libraries(spinel-core-kernel)
