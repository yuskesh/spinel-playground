add_llvm_executable(spinel-core-emit main.cpp)
target_link_libraries(spinel-core-emit PRIVATE
  SpinelCoreEmit
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
mlir_check_all_link_libraries(spinel-core-emit)
