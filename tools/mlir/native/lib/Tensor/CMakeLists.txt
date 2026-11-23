# Limited tensor importer does not depend on Scalar/Freestanding libraries: their ABI/ownership
# contracts differ.
add_library(SpinelMLIRTensor STATIC
  Body.cpp
  Declaration.cpp
  Emit.cpp
  Generate.cpp
  Extern.cpp
  Fuse.cpp)
target_include_directories(SpinelMLIRTensor PUBLIC ${CMAKE_SOURCE_DIR}/include)
target_link_libraries(SpinelMLIRTensor PUBLIC
  SpinelMLIRContract
  MLIRIR
  MLIRFuncDialect
  MLIRLinalgDialect
  MLIRArithDialect
  MLIRTensorDialect
  MLIRMathDialect)
