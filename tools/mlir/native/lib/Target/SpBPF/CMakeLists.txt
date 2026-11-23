# Canonical schema uses LLVMSupport JSON only, not MLIR: the contract precedes dialect IR.
add_library(SpinelMLIRSpBPFSchema STATIC
  Schema.cpp)
target_link_libraries(SpinelMLIRSpBPFSchema PUBLIC LLVMSupport)

# BPF ELF/BTF emission directly uses the BPF backend and MLIR-to-LLVM translation. Watch for
# Darwin-only direct-link header propagation failures.
add_library(SpinelMLIRSpBPFObject STATIC
  ObjectEmitter.cpp)
target_link_libraries(SpinelMLIRSpBPFObject PUBLIC
  SpinelMLIRSpBPFSchema
  MLIRTargetLLVMIRExport
  MLIRToLLVMIRTranslationRegistration
  LLVMBPFCodeGen
  LLVMBPFDesc
  LLVMBPFInfo
  LLVMCodeGen
  LLVMTarget
  LLVMCore
  LLVMMC)
