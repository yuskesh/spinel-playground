add_executable(spinel-group-g-probe-test GroupGProbeTest.cpp)
target_link_libraries(spinel-group-g-probe-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME group-g-probe COMMAND ruby
  ${PROJECT_SOURCE_DIR}/tests/consumer/run.rb
  $<TARGET_FILE:spinel-group-g-probe-test>
  ${PROJECT_SOURCE_DIR}/test/Inputs/group-g-trace-raw-tp.mlir.gz
  ${PROJECT_BINARY_DIR}/group-g-probe)
add_dependencies(check-spinel-mlir spinel-group-g-probe-test)
add_dependencies(check-spinel-math spinel-group-g-probe-test)
