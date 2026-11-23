add_executable(spinel-declaration-continuation-test ContinuationTest.cpp)
target_link_libraries(spinel-declaration-continuation-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME declaration-continuation
  COMMAND ruby ${PROJECT_SOURCE_DIR}/tests/consumer/run.rb
    $<TARGET_FILE:spinel-declaration-continuation-test>
    ${PROJECT_SOURCE_DIR}/test/Inputs/declaration-unused-map.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/fixture)
add_dependencies(check-spinel-mlir spinel-declaration-continuation-test)
add_dependencies(check-spinel-math spinel-declaration-continuation-test)
add_executable(spinel-devmap-selection-test DevMapSelectionTest.cpp)
target_link_libraries(spinel-devmap-selection-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME declaration-devmap-selection
  COMMAND ruby ${PROJECT_SOURCE_DIR}/tests/consumer/run.rb
    $<TARGET_FILE:spinel-devmap-selection-test>
    ${PROJECT_SOURCE_DIR}/test/Inputs/declaration-devmap-invalid.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/devmap-fixture)
add_dependencies(check-spinel-mlir spinel-devmap-selection-test)
add_dependencies(check-spinel-math spinel-devmap-selection-test)
add_library(SpinelDeclarationStopMutation STATIC
  ${PROJECT_SOURCE_DIR}/lib/Conversion/Consumer.cpp)
target_compile_definitions(SpinelDeclarationStopMutation PRIVATE
  SPINEL_E034_TEST_STOP_AFTER_DECLARATION_ERROR=1)
target_link_libraries(SpinelDeclarationStopMutation PUBLIC SpinelBPFConversion)
add_executable(spinel-declaration-stop-mutation ContinuationTest.cpp)
target_link_libraries(spinel-declaration-stop-mutation PRIVATE
  SpinelDeclarationStopMutation MLIRParser)
add_test(NAME declaration-continuation-mutation
  COMMAND ruby ${CMAKE_CURRENT_SOURCE_DIR}/check-mutation.rb
    $<TARGET_FILE:spinel-declaration-stop-mutation>
    ${PROJECT_SOURCE_DIR}/test/Inputs/declaration-unused-map.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/mutation)
add_dependencies(check-spinel-mlir spinel-declaration-stop-mutation)
add_dependencies(check-spinel-math spinel-declaration-stop-mutation)
