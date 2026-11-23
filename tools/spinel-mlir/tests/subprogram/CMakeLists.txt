add_library(SpinelSubprogramGraph STATIC
    ${PROJECT_SOURCE_DIR}/lib/Analysis/SubprogramGraph.cpp
    ${PROJECT_SOURCE_DIR}/lib/Analysis/SubprogramFlow.cpp)
target_include_directories(SpinelSubprogramGraph PUBLIC ${PROJECT_SOURCE_DIR}/include)
add_executable(spinel-subprogram-graph-test GraphTest.cpp)
target_link_libraries(spinel-subprogram-graph-test PRIVATE SpinelSubprogramGraph)
add_test(NAME subprogram-graph COMMAND spinel-subprogram-graph-test)
add_dependencies(check-spinel-mlir spinel-subprogram-graph-test)
add_dependencies(check-spinel-math spinel-subprogram-graph-test)
add_executable(spinel-subprogram-flow-test FlowTest.cpp)
target_link_libraries(spinel-subprogram-flow-test PRIVATE SpinelSubprogramGraph)
add_test(NAME subprogram-flow COMMAND spinel-subprogram-flow-test)
add_dependencies(check-spinel-mlir spinel-subprogram-flow-test)
add_dependencies(check-spinel-math spinel-subprogram-flow-test)
add_executable(spinel-subprogram-prepare-test PrepareTest.cpp)
target_link_libraries(spinel-subprogram-prepare-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME subprogram-prepare COMMAND ruby
    ${PROJECT_SOURCE_DIR}/tests/consumer/run.rb
    $<TARGET_FILE:spinel-subprogram-prepare-test>
    ${PROJECT_SOURCE_DIR}/test/Inputs/e019-sub-int.mlir.gz
    ${PROJECT_BINARY_DIR}/subprogram-prepare)
add_dependencies(check-spinel-mlir spinel-subprogram-prepare-test)
add_dependencies(check-spinel-math spinel-subprogram-prepare-test)
add_test(NAME subprogram-enum-count-controls COMMAND ruby
    ${PROJECT_SOURCE_DIR}/tests/subprogram/enum-copy-controls.rb
    $<TARGET_FILE:spinel-mlir>
    ${PROJECT_SOURCE_DIR}/test/Inputs/e063-cachestat.mlir.gz
    ${PROJECT_BINARY_DIR}/enum-count-controls)
add_dependencies(check-spinel-mlir spinel-mlir)
add_dependencies(check-spinel-math spinel-mlir)
# Only the subprogram TU differs. Put its object directly in the executable;
# the archive's ordinary Subprograms.cpp object is then not pulled by the linker.
foreach(subprogram_mutation FULL_HULL NO_SUMMARY)
  string(TOLOWER ${subprogram_mutation} subprogram_name)
  string(REPLACE "_" "-" subprogram_name ${subprogram_name})
  add_library(SpinelSubprogram${subprogram_mutation} OBJECT
      ${PROJECT_SOURCE_DIR}/lib/Conversion/Subprograms.cpp)
  target_compile_definitions(SpinelSubprogram${subprogram_mutation} PRIVATE
      SPINEL_E019_TEST_${subprogram_mutation}=1)
  target_link_libraries(SpinelSubprogram${subprogram_mutation} PUBLIC SpinelBPFConversion)
  add_llvm_executable(spinel-mlir-subprogram-${subprogram_name}
      PARTIAL_SOURCES_INTENDED
      ${PROJECT_SOURCE_DIR}/tools/spinel-mlir.cpp
      $<TARGET_OBJECTS:SpinelSubprogram${subprogram_mutation}>)
  llvm_update_compile_flags(spinel-mlir-subprogram-${subprogram_name})
  target_link_libraries(spinel-mlir-subprogram-${subprogram_name} PRIVATE
      SpinelBPFConversion MLIRParser MLIRIR MLIRSupport MLIRPass)
  add_dependencies(check-spinel-mlir spinel-mlir-subprogram-${subprogram_name})
  add_dependencies(check-spinel-math spinel-mlir-subprogram-${subprogram_name})
endforeach()
