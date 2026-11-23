# Freestanding object-generation driver, separate from admission-only fs-check to preserve its
# LLVMSupport/Contract dependency boundary. Reuse the scalar importer as an in-process library
# rather than spawning an executable wrapping the same library.
add_llvm_executable(spinel-fs-emit main.cpp)
llvm_update_compile_flags(spinel-fs-emit)
target_link_libraries(spinel-fs-emit PRIVATE
  SpinelMLIRFreestandingEmit
  SpinelMLIRFreestanding
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
mlir_check_all_link_libraries(spinel-fs-emit)
