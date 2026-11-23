# Freestanding gradient generator uses in-process Enzyme, not Python. Kept separate from fs-emit to
# preserve product/probe/admit behavior. Grad has no default routing surface; missing plugins fail
# visibly with rc 1.
add_llvm_executable(spinel-fs-grad main.cpp)
llvm_update_compile_flags(spinel-fs-grad)
target_link_libraries(spinel-fs-grad PRIVATE
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
  MLIRPass
  # Spinel Extended: spinel-llvm linked one LLVM dylib, which also supplied
  # the symbols the Enzyme plugin resolves from its host. The LLVM here is
  # static components: the pipeline names its own, and the executable exports
  # its symbols to the plugin the way opt does.
  LLVMPasses
  LLVMipo
  LLVMLinker
  LLVMPlugins)
export_executable_symbols_for_plugins(spinel-fs-grad)
mlir_check_all_link_libraries(spinel-fs-grad)
