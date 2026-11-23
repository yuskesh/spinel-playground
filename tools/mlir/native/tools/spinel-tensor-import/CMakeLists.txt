add_llvm_executable(spinel-tensor-import main.cpp)
llvm_update_compile_flags(spinel-tensor-import)
target_include_directories(spinel-tensor-import PRIVATE
  ${CMAKE_SOURCE_DIR}/lib/Tensor)
target_link_libraries(spinel-tensor-import PRIVATE
  SpinelMLIRTensor SpinelMLIRContract
  MLIRIR MLIRFuncDialect MLIRLinalgDialect MLIRArithDialect)
mlir_check_all_link_libraries(spinel-tensor-import)
