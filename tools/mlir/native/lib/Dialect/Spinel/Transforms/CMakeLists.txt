# Canonical rewrite implementation.
add_library(MLIRSpinelTransforms STATIC
  CanonicalizeCheckedArithmetic.cpp)
add_dependencies(MLIRSpinelTransforms MLIRSpinelTransformsIncGen)
target_link_libraries(MLIRSpinelTransforms PUBLIC
  MLIRSpinelDialect
  MLIRArithDialect
  MLIRPass
  MLIRTransformUtils)
