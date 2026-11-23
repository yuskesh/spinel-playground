# Hosted/freestanding lowering implementation.
add_library(MLIRSpinelToLLVM STATIC
  CheckedArithmetic.cpp)
add_dependencies(MLIRSpinelToLLVM MLIRSpinelConversionIncGen)
target_link_libraries(MLIRSpinelToLLVM PUBLIC
  MLIRSpinelDialect
  MLIRSpinelTransforms
  MLIRArithDialect
  MLIRControlFlowDialect
  MLIRLLVMDialect
  MLIRPass
  MLIRTransformUtils)
