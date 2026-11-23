# Scalar frontend: MLIR-independent selection in Importer.cpp and native MLIR
# builders in MlirGen.cpp. Adding the latter first introduced MLIR linkage.
# LLVM became the fourth dialect for checked overflow intrinsics returning i1,
# noreturn/cold passthrough extern declarations and .rodata C-string globals:
# arith and func.func private cannot express those. Cold branches still use
# standard cf.cond_br weights. This library does not use spbpf. HostEmit.cpp
# owns the host --emit ll|obj back half: five-stage pipeline, translation and
# clang argv construction, never subprocess execution. The caller's RunToolFn
# launches clang; product-optin.test lane 14 checks that separation.
add_library(SpinelMLIRScalar STATIC
  HostEmit.cpp
  Importer.cpp
  MlirGen.cpp
  FreestandingSubset.cpp
  SubsetTables.cpp)
target_include_directories(SpinelMLIRScalar PUBLIC ${CMAKE_SOURCE_DIR}/include)
#
# E161 cp3C: the `--emit-checked-arithmetic` opt-in emits `spinel.checked_*`,
# so the builder links the Spinel dialect. The dialect is LOADED only under the
# opt-in (MlirGen.cpp, ModuleGen::run); linking it is unconditional because a
# library cannot be linked per call.
target_link_libraries(SpinelMLIRScalar PUBLIC
  SpinelMLIRContract
  SpinelCoreSubsetRefusals
  SpinelCoreBlockLoops
  MLIRIR
  MLIRSupport
  MLIRFuncDialect
  MLIRArithDialect
  MLIRControlFlowDialect
  MLIRLLVMDialect
  MLIRSpinelDialect
  # HostEmit.cpp five-stage pipeline and translateModuleToLLVMIR.
  MLIRSpinelToLLVM
  MLIRFuncToLLVM
  MLIRArithToLLVM
  MLIRControlFlowToLLVM
  MLIRReconcileUnrealizedCasts
  MLIRTargetLLVMIRExport
  MLIRLLVMToLLVMIRTranslation
  MLIRBuiltinToLLVMIRTranslation
  MLIRPass
  LLVMCore
  LLVMSupport)
