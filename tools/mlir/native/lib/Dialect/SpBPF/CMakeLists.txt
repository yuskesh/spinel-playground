# SpBPF dialect implementation depends on ODS-generated MLIRSpBPFOpsIncGen.
add_library(MLIRSpBPFDialect STATIC
  IR/SpBPFDialect.cpp)
add_dependencies(MLIRSpBPFDialect MLIRSpBPFOpsIncGen)
target_link_libraries(MLIRSpBPFDialect PUBLIC MLIRIR MLIRSupport)
add_subdirectory(Transforms)
