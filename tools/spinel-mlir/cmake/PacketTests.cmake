# E015's named offset-check mutation; never linked into the production tool.
add_llvm_executable(spinel-mlir-offset-mutation
    tools/spinel-mlir.cpp lib/Conversion/Packet.cpp)
target_compile_definitions(spinel-mlir-offset-mutation PRIVATE
    SPINEL_E015_TEST_NO_OFFSET_RANGE=1)
target_link_libraries(spinel-mlir-offset-mutation PRIVATE
    SpinelBPFConversion MLIRParser MLIRIR MLIRSupport MLIRPass)
