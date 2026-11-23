execute_process(COMMAND "${TEST_BINARY}" --drop-next
  RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)
if(NOT rc EQUAL 1 OR NOT out STREQUAL "" OR NOT err STREQUAL "next-env-join\n")
  message(FATAL_ERROR "wrong loop mutation observation: rc=${rc} out=${out} err=${err}")
endif()
message(STATUS "next-env-join mutation: named RED")
