add_executable(spinel-percpu-record-probe-test ProbeTest.cpp)
target_link_libraries(spinel-percpu-record-probe-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME percpu-record-probe COMMAND ruby
  ${PROJECT_SOURCE_DIR}/tests/consumer/run.rb
  $<TARGET_FILE:spinel-percpu-record-probe-test>
  ${CMAKE_CURRENT_SOURCE_DIR}/width-wrap.mlir.gz
  ${CMAKE_CURRENT_BINARY_DIR}/probe)
add_executable(spinel-percpu-record-mutation
  ${PROJECT_SOURCE_DIR}/tools/spinel-mlir.cpp
  ${PROJECT_SOURCE_DIR}/lib/Conversion/RecordMembers.cpp)
target_compile_definitions(spinel-percpu-record-mutation PRIVATE SPINEL_E041_TEST_ADD_AS_SUB=1)
target_link_libraries(spinel-percpu-record-mutation PRIVATE SpinelBPFConversion MLIRParser)
add_dependencies(check-spinel-mlir spinel-percpu-record-probe-test spinel-percpu-record-mutation)
add_dependencies(check-spinel-math spinel-percpu-record-probe-test spinel-percpu-record-mutation)
