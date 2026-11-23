# Spinel dialect implementation depends on three ODS-generated targets.
add_library(MLIRSpinelDialect STATIC
  IR/SpinelDialect.cpp)
add_dependencies(MLIRSpinelDialect
  MLIRSpinelOpsIncGen
  MLIRSpinelOpsEnumsIncGen
  MLIRSpinelOpsAttributesIncGen)
target_link_libraries(MLIRSpinelDialect PUBLIC MLIRIR MLIRSupport)
add_subdirectory(Transforms)
