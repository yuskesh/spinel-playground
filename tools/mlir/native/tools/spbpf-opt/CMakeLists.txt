add_llvm_executable(spbpf-opt main.cpp)
llvm_update_compile_flags(spbpf-opt)
target_link_libraries(spbpf-opt PRIVATE
  MLIRSpBPFDialect
  MLIRSpBPFTransforms
  MLIROptLib
  MLIRRegisterAllDialects
  MLIRRegisterAllPasses)
mlir_check_all_link_libraries(spbpf-opt)
