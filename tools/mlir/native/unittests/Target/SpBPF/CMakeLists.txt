# No gtest: see SchemaTest.cpp. Use the existing small executable plus lit pattern.
add_llvm_executable(spinel-spbpf-schema-test SchemaTest.cpp)
llvm_update_compile_flags(spinel-spbpf-schema-test)
target_link_libraries(spinel-spbpf-schema-test PRIVATE SpinelMLIRSpBPFSchema)
