add_library(MLIRSpBPFTransforms STATIC
  VerifyOwnership.cpp
  VerifySchema.cpp
  LowerToLLVM.cpp)
add_dependencies(MLIRSpBPFTransforms MLIRSpBPFTransformsIncGen)
target_link_libraries(MLIRSpBPFTransforms PUBLIC
  SpinelMLIRSpBPFSchema
  MLIRSpBPFDialect
  MLIRPass
  MLIRTransforms
  MLIRLLVMDialect
  MLIRControlFlowDialect
  MLIRFuncDialect)
