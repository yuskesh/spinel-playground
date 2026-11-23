# Mutations are generated copies used only by test executables. Product source
# has no mutation flag, switch or alternate behavior.
function(e051_copy_mutant name source needle replacement)
  file(READ "${CMAKE_CURRENT_SOURCE_DIR}/${source}" original)
  string(FIND "${original}" "${needle}" first)
  if(first LESS 0)
    message(FATAL_ERROR "E051 mutation ${name}: missing source anchor")
  endif()
  string(LENGTH "${needle}" n)
  math(EXPR after "${first}+${n}")
  string(SUBSTRING "${original}" ${after} -1 suffix)
  string(FIND "${suffix}" "${needle}" second)
  if(NOT second LESS 0)
    message(FATAL_ERROR "E051 mutation ${name}: nonunique source anchor")
  endif()
  string(REPLACE "${needle}" "${replacement}" mutated "${original}")
  file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/e051-mutants")
  set(path "${CMAKE_CURRENT_BINARY_DIR}/e051-mutants/${name}.cpp")
  file(WRITE "${path}" "${mutated}")
  set(${name}_SOURCE "${path}" PARENT_SCOPE)
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/${source}")
endfunction()
e051_copy_mutant(unknown lib/Conversion/Consumer.cpp
  "unknown ? \"unknown\" : \"rejected\"" "unknown ? \"rejected\" : \"rejected\"")
add_executable(spinel-e051-unknown-mutation tests/consumer/UnknownDiagnosticTest.cpp "${unknown_SOURCE}")
target_link_libraries(spinel-e051-unknown-mutation PRIVATE SpinelBPFConversion MLIRParser)
e051_copy_mutant(origins lib/Conversion/GroupBLoops.cpp
  "model->post=keepOriginKeys(originPost);setRanges(model->post,result->post);"
  "model->post=pre;setRanges(model->post,result->post);")
e051_copy_mutant(precheck lib/Conversion/GroupBLoops.cpp
  "[&](const loops::Syntax &s){return allowed(s);}" "[](const loops::Syntax &){return success();}")
foreach(mode origins precheck)
  add_llvm_executable(spinel-e051-${mode}-mutation tools/spinel-mlir.cpp "${${mode}_SOURCE}")
  llvm_update_compile_flags(spinel-e051-${mode}-mutation)
  target_link_libraries(spinel-e051-${mode}-mutation PRIVATE SpinelBPFConversion MLIRParser MLIRIR MLIRSupport MLIRPass)
endforeach()
foreach(mode unknown origins precheck)
  add_test(NAME scalar-${mode}-mutation COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/CheckScalarMutation.rb ${mode}
    $<TARGET_FILE:spinel-e051-${mode}-mutation>
    ${CMAKE_CURRENT_SOURCE_DIR}/docs/experiments/results/E051/supply-01.tar.gz
    ${CMAKE_CURRENT_BINARY_DIR}/e051-${mode}-mutation
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/xdpcount.spinel.mlir)
  add_dependencies(check-spinel-mlir spinel-e051-${mode}-mutation)
  add_dependencies(check-spinel-math spinel-e051-${mode}-mutation)
endforeach()
