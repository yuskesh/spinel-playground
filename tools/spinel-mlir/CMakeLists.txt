cmake_minimum_required(VERSION 3.20)
project(spinel-mlir LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(MLIR REQUIRED CONFIG)
if(NOT LLVM_PACKAGE_VERSION VERSION_EQUAL "23.1.1")
  message(FATAL_ERROR "spinel-mlir requires LLVM/MLIR 23.1.1")
endif()
set(LLVM_RUNTIME_OUTPUT_INTDIR ${CMAKE_BINARY_DIR}/bin)
set(LLVM_LIBRARY_OUTPUT_INTDIR ${CMAKE_BINARY_DIR}/lib)
list(APPEND CMAKE_MODULE_PATH "${MLIR_CMAKE_DIR}" "${LLVM_CMAKE_DIR}")
include(TableGen)
include(AddLLVM)
include(AddMLIR)
include(cmake/SingleLLVM.cmake)
include(HandleLLVMOptions)
add_compile_options($<$<COMPILE_LANGUAGE:CXX>:-fno-rtti>
                    $<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions>)
separate_arguments(LLVM_DEFINITIONS_LIST NATIVE_COMMAND ${LLVM_DEFINITIONS})
add_definitions(${LLVM_DEFINITIONS_LIST})
include_directories(${LLVM_INCLUDE_DIRS} ${MLIR_INCLUDE_DIRS})
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include ${CMAKE_CURRENT_BINARY_DIR}/include)
# Spinel Extended: lit is Python and is not used; tests/spinel-mlir/run.sh reads
# test/*.test's RUN lines and runs ctest (lit.cfg.py and lit.site.cfg.py.in are
# not imported).
include(cmake/BpfMLIR.cmake)
# E075: immutable build provenance, not the caller's run-time checkout.
execute_process(COMMAND git rev-parse HEAD WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
  OUTPUT_VARIABLE SPINEL_CONSUMER_COMMIT OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND git status --porcelain --untracked-files=no WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
  OUTPUT_VARIABLE SPINEL_CONSUMER_CHANGES OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
if(SPINEL_CONSUMER_CHANGES STREQUAL "")
  set(SPINEL_CONSUMER_DIRTY false)
else()
  set(SPINEL_CONSUMER_DIRTY true)
endif()
# Spinel Extended: the bpf-mlir commit, from SOURCE_VERSION when there is one
# (a source release or a clone of a public release), else from git (decision
# 0047).
include(${CMAKE_CURRENT_SOURCE_DIR}/bpf-mlir-commit.cmake)
configure_file(cmake/BuildRevision.h.in include/spinel/Conversion/BuildRevision.h @ONLY)

add_llvm_executable(spinel-ir-normalize tools/spinel-ir-normalize.cpp)
llvm_update_compile_flags(spinel-ir-normalize)
target_link_libraries(spinel-ir-normalize PRIVATE
  PinnedEBPFDialect MLIRArithDialect MLIRParser MLIRIR MLIRSupport)
add_subdirectory(include/spinel/Dialect/SpinelFacts/IR)
add_library(SpinelFactsDialect STATIC lib/Dialect/SpinelFacts/SpinelFactsDialect.cpp)
add_dependencies(SpinelFactsDialect MLIRSpinelFactsOpsIncGen)
target_link_libraries(SpinelFactsDialect PUBLIC MLIRIR MLIRSupport)
add_library(SpinelFactsImport STATIC lib/Import/Import.cpp)
target_link_libraries(SpinelFactsImport PUBLIC SpinelFactsDialect)
set(SPINEL_CONSUMER_SOURCES lib/Conversion/LowerToEBPF.cpp
    lib/Conversion/Inspection.cpp lib/Conversion/ConsumerInspection.cpp
    lib/Conversion/SeamExport.cpp lib/Conversion/InspectionOutput.cpp
    lib/Conversion/Consumer.cpp lib/Conversion/ConsumerHooks.cpp
    lib/Conversion/ScalarDiagnostics.cpp
    lib/Conversion/TypingProbeComparison.cpp lib/Conversion/ConsumerTypingProbe.cpp
    lib/Conversion/ConsumerGroups.cpp lib/Conversion/GroupBLoops.cpp
    lib/Conversion/ConsumerUserSide.cpp
    lib/Conversion/SourceAudits.cpp
    lib/Conversion/Subprograms.cpp
    lib/Conversion/DeclarationRecovery.cpp
    lib/Conversion/LoopFacts.cpp
    lib/Analysis/BoundedLoopRange.cpp
    lib/Conversion/GroupE.cpp lib/Conversion/Packet.cpp
    lib/Conversion/GroupBEffects.cpp lib/Conversion/Helpers.cpp
    lib/Conversion/GroupGTracing.cpp lib/Conversion/GroupGProbe.cpp
    lib/Conversion/GroupGUprobe.cpp
    lib/Conversion/GroupGRuntime.cpp lib/Conversion/GroupGSocket.cpp
    lib/Conversion/GroupGKernel.cpp lib/Conversion/FmodRet.cpp lib/Analysis/KernelTypes.cpp
    lib/Conversion/Ring.cpp lib/Conversion/Argv.cpp
    lib/Conversion/RecordValue.cpp
    lib/Conversion/RecordDeclarations.cpp
    lib/Conversion/RecordMaps.cpp
    lib/Conversion/RefAtomic.cpp
    lib/Conversion/RecordMembers.cpp)
add_library(SpinelBPFConversion STATIC ${SPINEL_CONSUMER_SOURCES})
target_link_libraries(SpinelBPFConversion PUBLIC SpinelFactsImport PinnedEBPFDialect MLIRArithDialect MLIRPass)
add_llvm_executable(spinel-mlir tools/spinel-mlir.cpp)
llvm_update_compile_flags(spinel-mlir)
target_link_libraries(spinel-mlir PRIVATE SpinelBPFConversion MLIRParser MLIRIR MLIRSupport MLIRPass)
add_custom_target(check-spinel-mlir
  DEPENDS spinel-ir-normalize spinel-mlir)
enable_testing()
add_executable(spinel-argv-scope-test tests/consumer/ArgvScopeTest.cpp)
target_link_libraries(spinel-argv-scope-test PRIVATE SpinelBPFConversion)
add_test(NAME argv-scope COMMAND spinel-argv-scope-test)
add_dependencies(check-spinel-mlir spinel-argv-scope-test)
add_executable(spinel-argv-check-order-test tests/consumer/ArgvCheckOrderTest.cpp)
target_link_libraries(spinel-argv-check-order-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME argv-check-order COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/run.rb
    $<TARGET_FILE:spinel-argv-check-order-test>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/e071-argv.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/argv-check-order)
add_dependencies(check-spinel-mlir spinel-argv-check-order-test)
add_library(SpinelBPFConversionArgvIndex STATIC ${SPINEL_CONSUMER_SOURCES})
target_compile_definitions(SpinelBPFConversionArgvIndex PRIVATE SPINEL_E071_TEST_ARGV_INDEX_SHIFT=1)
target_link_libraries(SpinelBPFConversionArgvIndex PUBLIC $<TARGET_PROPERTY:SpinelBPFConversion,LINK_LIBRARIES>)
add_llvm_executable(spinel-mlir-argv-index-mutation tools/spinel-mlir.cpp)
llvm_update_compile_flags(spinel-mlir-argv-index-mutation)
target_link_libraries(spinel-mlir-argv-index-mutation PRIVATE SpinelBPFConversionArgvIndex MLIRParser MLIRIR MLIRSupport MLIRPass)
add_dependencies(check-spinel-mlir spinel-mlir-argv-index-mutation)
add_executable(spinel-fmod-terminal-test tests/consumer/FmodTerminalTest.cpp)
target_link_libraries(spinel-fmod-terminal-test PRIVATE SpinelBPFConversion)
add_test(NAME fmod-terminal COMMAND spinel-fmod-terminal-test)
add_dependencies(check-spinel-mlir spinel-fmod-terminal-test)
add_executable(spinel-fmod-explicit-return-test tests/consumer/FmodExplicitReturnTest.cpp)
target_link_libraries(spinel-fmod-explicit-return-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME fmod-explicit-return COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/run.rb
    $<TARGET_FILE:spinel-fmod-explicit-return-test>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/e065-fmod-ret.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/fmod-explicit-return)
add_dependencies(check-spinel-mlir spinel-fmod-explicit-return-test)
add_test(NAME source-pipeline COMMAND ruby ${CMAKE_CURRENT_SOURCE_DIR}/tests/source-pipeline.rb)
add_library(SpinelMathIntervalAnalysis STATIC lib/Analysis/MathIntervalAnalysis.cpp)
llvm_update_compile_flags(SpinelMathIntervalAnalysis)
target_link_libraries(SpinelMathIntervalAnalysis PUBLIC MLIRAnalysis MLIRIR MLIRSupport)
add_subdirectory(tests/interval)
add_subdirectory(tests/range)
add_dependencies(check-spinel-math spinel-argv-scope-test)
add_dependencies(check-spinel-math spinel-argv-check-order-test)
add_dependencies(check-spinel-math spinel-mlir-argv-index-mutation)
add_dependencies(check-spinel-math spinel-fmod-terminal-test)
add_dependencies(check-spinel-math spinel-fmod-explicit-return-test)
add_subdirectory(tests/subprogram)
target_link_libraries(SpinelBPFConversion PUBLIC SpinelSubprogramGraph)
add_library(SpinelRecordLayout STATIC lib/Analysis/RecordLayout.cpp)
target_include_directories(SpinelRecordLayout PUBLIC include)
add_executable(spinel-record-layout-test tests/record/RecordLayoutTest.cpp)
target_link_libraries(spinel-record-layout-test PRIVATE SpinelRecordLayout)
add_test(NAME record-layout COMMAND spinel-record-layout-test)
add_dependencies(check-spinel-mlir spinel-record-layout-test)
add_dependencies(check-spinel-math spinel-record-layout-test)
add_library(SpinelRecordExport STATIC lib/Conversion/RecordExport.cpp)
target_link_libraries(SpinelRecordExport PUBLIC SpinelRecordLayout MLIRIR MLIRSupport)
target_link_libraries(SpinelBPFConversion PUBLIC SpinelRecordExport)
add_executable(spinel-record-export-test tests/record/RecordExportTest.cpp)
target_link_libraries(spinel-record-export-test PRIVATE SpinelRecordExport)
add_test(NAME record-export COMMAND spinel-record-export-test)
add_dependencies(check-spinel-mlir spinel-record-export-test)
add_dependencies(check-spinel-math spinel-record-export-test)
add_executable(spinel-record-value-test tests/record/RecordValueTest.cpp)
target_link_libraries(spinel-record-value-test PRIVATE SpinelBPFConversion SpinelRecordLayout)
add_test(NAME record-value COMMAND spinel-record-value-test)
add_dependencies(check-spinel-mlir spinel-record-value-test)
add_dependencies(check-spinel-math spinel-record-value-test)
add_executable(spinel-record-declarations-test tests/record/RecordDeclarationsTest.cpp)
target_link_libraries(spinel-record-declarations-test PRIVATE SpinelBPFConversion MLIRParser)
foreach(kind basic mc)
  if(kind STREQUAL "basic")
    set(fixture e016-record-basic.mlir.gz)
  else()
    set(fixture e016-ring-mc.mlir.gz)
  endif()
  add_test(NAME record-declarations-${kind} COMMAND ruby
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/record/run-declarations.rb
      $<TARGET_FILE:spinel-record-declarations-test>
      ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/${fixture} ${kind}
      ${CMAKE_CURRENT_BINARY_DIR}/record-declarations-${kind})
endforeach()
add_dependencies(check-spinel-mlir spinel-record-declarations-test)
add_dependencies(check-spinel-math spinel-record-declarations-test)
# E029 (ring section — owned by E029): the ring test on saved ring_mc /
# t_ring facts against the Go oracle, and the two H6 mutation builds (test
# only), which reuse the common sources and the main library's link list.
add_executable(spinel-ring-test tests/consumer/RingTest.cpp)
add_executable(spinel-current-comm-callback-test tests/consumer/CurrentCommCallbackTest.cpp)
target_link_libraries(spinel-current-comm-callback-test PRIVATE SpinelBPFConversion)
add_test(NAME current-comm-callback COMMAND spinel-current-comm-callback-test)
add_dependencies(check-spinel-mlir spinel-current-comm-callback-test)
add_dependencies(check-spinel-math spinel-current-comm-callback-test)
target_compile_definitions(spinel-ring-test PRIVATE
    SPINEL_E029_ORACLE="${CMAKE_CURRENT_SOURCE_DIR}/docs/experiments/results/E003/capture/positive")
target_link_libraries(spinel-ring-test PRIVATE SpinelBPFConversion MLIRParser)
foreach(ring_case mc t-ring)
  add_test(NAME ring-${ring_case} COMMAND ruby
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/run.rb
      $<TARGET_FILE:spinel-ring-test>
      ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/ring-${ring_case}.mlir.gz
      ${CMAKE_CURRENT_BINARY_DIR}/ring-${ring_case})
endforeach()
foreach(ring_mutation swap polarity)
  string(TOUPPER ${ring_mutation} ring_flag)
  if(ring_mutation STREQUAL "swap")
    set(ring_flag FIELD_SWAP)
  endif()
  add_library(SpinelBPFConversionRing${ring_flag} STATIC ${SPINEL_CONSUMER_SOURCES})
  target_compile_definitions(SpinelBPFConversionRing${ring_flag} PRIVATE
      SPINEL_E029_TEST_RING_${ring_flag}=1)
  target_link_libraries(SpinelBPFConversionRing${ring_flag} PUBLIC
      $<TARGET_PROPERTY:SpinelBPFConversion,LINK_LIBRARIES>)
  add_llvm_executable(spinel-mlir-ring-${ring_mutation} tools/spinel-mlir.cpp)
  llvm_update_compile_flags(spinel-mlir-ring-${ring_mutation})
  target_link_libraries(spinel-mlir-ring-${ring_mutation} PRIVATE
      SpinelBPFConversionRing${ring_flag} MLIRParser MLIRIR MLIRSupport MLIRPass)
  add_dependencies(check-spinel-mlir spinel-mlir-ring-${ring_mutation})
  add_dependencies(check-spinel-math spinel-mlir-ring-${ring_mutation})
endforeach()
# Addendum D (A): the RingBuf declaration is selected and rejected under the
# production registry; a control arm drops the handler.
add_executable(spinel-ring-selection-test tests/consumer/RingSelectionTest.cpp)
target_compile_definitions(spinel-ring-selection-test PRIVATE
    SPINEL_E029_RG_NOT_RECORD_STDERR="${CMAKE_CURRENT_SOURCE_DIR}/docs/experiments/results/E003/capture/negative/internal_frontend_testdata_neg_rg_not_record/build.stderr")
target_link_libraries(spinel-ring-selection-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME ring-selection COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/run.rb
    $<TARGET_FILE:spinel-ring-selection-test>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/ring-rg-not-record.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/ring-selection)
add_dependencies(check-spinel-mlir spinel-ring-selection-test)
add_dependencies(check-spinel-math spinel-ring-selection-test)
# swap: t_ring's record.make operands; polarity: mc's present/absent yields.
add_test(NAME ring-mutation-swap COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/ring-mutation.rb
    $<TARGET_FILE:spinel-mlir> $<TARGET_FILE:spinel-mlir-ring-swap> swap
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/ring-t-ring.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/ring-mutation-swap
    $<TARGET_FILE:spinel-ring-test>)
add_test(NAME ring-mutation-polarity COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/ring-mutation.rb
    $<TARGET_FILE:spinel-mlir> $<TARGET_FILE:spinel-mlir-ring-polarity> polarity
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/ring-mc.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/ring-mutation-polarity)
# E039: `r = R.output_str(…)` and the user string, before E040, through a
# test-only uprobe root: greetwatch's IR against Go's and the output_str
# negatives' stderr against Go's (saved facts from the fixed producer).
add_executable(spinel-output-str-test tests/consumer/OutputStrTest.cpp)
target_link_libraries(spinel-output-str-test PRIVATE SpinelBPFConversion MLIRParser)
set(SPINEL_E039_ORACLE ${CMAKE_CURRENT_SOURCE_DIR}/docs/experiments/results/E003/capture)
# E082: the last argument is the dir file 0 is moved into — a tracked capture
# dir whose target/ holds the uprobe binary the fixture names (same bytes).
add_test(NAME output-str-greetwatch COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/output-str-run.rb
    $<TARGET_FILE:spinel-output-str-test> positive
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/output-str-greetwatch.mlir.gz
    ${SPINEL_E039_ORACLE}/positive/examples_greetwatch_greetwatch/greetwatch.mlir
    ${CMAKE_CURRENT_BINARY_DIR}/output-str-greetwatch
    ${SPINEL_E039_ORACLE}/positive/examples_greetwatch_greetwatch)
foreach(output_str_negative output_str_dropped output_str_no_if
        output_str_in_kprobe status_in_else status_nonzero status_not_i64
        field_not_u8_array no_status_member)
set(output_str_negative_oracle ${SPINEL_E039_ORACLE}/negative/internal_frontend_testdata_uprobe_neg_${output_str_negative}/build.stderr)
if(output_str_negative STREQUAL "output_str_in_kprobe")
  set(output_str_negative_oracle ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/output-str-output_str_in_kprobe-e070.stderr)
endif()
  add_test(NAME output-str-${output_str_negative} COMMAND ruby
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/output-str-run.rb
      $<TARGET_FILE:spinel-output-str-test> negative
      ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/output-str-${output_str_negative}.mlir.gz
      ${output_str_negative_oracle}
      ${CMAKE_CURRENT_BINARY_DIR}/output-str-${output_str_negative}
      ${SPINEL_E039_ORACLE}/negative/internal_frontend_testdata_uprobe_neg_${output_str_negative})
endforeach()
# E045: output_str_or_discard — up_discard (outside the fixed 609; Go oracle
# from E040's oracle-02, copied with hashes) and the four discard negatives.
set(SPINEL_E045_ORACLE ${CMAKE_CURRENT_SOURCE_DIR}/docs/experiments/results/E045/oracle/up_discard/up_discard.mlir)
# E082: a capture dir with the same target/cfix (the oracle schema's binary_sha256).
set(SPINEL_E045_SOURCE_DIR ${SPINEL_E039_ORACLE}/negative/internal_frontend_testdata_uprobe_neg_discard_dropped)
add_test(NAME output-str-up_discard COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/output-str-run.rb
    $<TARGET_FILE:spinel-output-str-test> positive
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/output-str-up_discard.mlir.gz
    ${SPINEL_E045_ORACLE}
    ${CMAKE_CURRENT_BINARY_DIR}/output-str-up_discard
    ${SPINEL_E045_SOURCE_DIR})
foreach(output_str_negative discard_dropped discard_in_kprobe discard_no_status
        sent_outside)
  set(output_str_negative_oracle ${SPINEL_E039_ORACLE}/negative/internal_frontend_testdata_uprobe_neg_${output_str_negative}/build.stderr)
  # E069: E145 changed this one SB025 wording; raw copy from E068 stop-b,
  # sha256 7ab44dd306464035713d322b7b4a29f10004711f882f364c47bd6050d4375a5e.
  if(output_str_negative STREQUAL "discard_dropped")
    set(output_str_negative_oracle ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/output-str-discard_dropped-e145.stderr)
  elseif(output_str_negative STREQUAL "discard_in_kprobe")
    set(output_str_negative_oracle ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/output-str-discard_in_kprobe-e070.stderr)
  endif()
  add_test(NAME output-str-${output_str_negative} COMMAND ruby
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/output-str-run.rb
      $<TARGET_FILE:spinel-output-str-test> negative
      ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/output-str-${output_str_negative}.mlir.gz
      ${output_str_negative_oracle}
      ${CMAKE_CURRENT_BINARY_DIR}/output-str-${output_str_negative}
      ${SPINEL_E039_ORACLE}/negative/internal_frontend_testdata_uprobe_neg_${output_str_negative})
endforeach()
# E045 H6 (test only): the discard decision flipped (slt -> sge) on up_discard.
add_library(SpinelBPFConversionOutputStrDISCARD_SGE STATIC ${SPINEL_CONSUMER_SOURCES})
target_compile_definitions(SpinelBPFConversionOutputStrDISCARD_SGE PRIVATE
    SPINEL_E045_TEST_DISCARD_SGE=1)
target_link_libraries(SpinelBPFConversionOutputStrDISCARD_SGE PUBLIC
    $<TARGET_PROPERTY:SpinelBPFConversion,LINK_LIBRARIES>)
add_executable(spinel-output-str-test-discard-sge tests/consumer/OutputStrTest.cpp)
target_link_libraries(spinel-output-str-test-discard-sge PRIVATE
    SpinelBPFConversionOutputStrDISCARD_SGE MLIRParser)
add_test(NAME output-str-mutation-discard-sge COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/output-str-mutation.rb
    $<TARGET_FILE:spinel-output-str-test-discard-sge>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/output-str-up_discard.mlir.gz
    ${SPINEL_E045_ORACLE}
    ${CMAKE_CURRENT_BINARY_DIR}/output-str-mutation-discard-sge
    ${SPINEL_E045_SOURCE_DIR})
add_dependencies(check-spinel-mlir spinel-output-str-test-discard-sge)
add_dependencies(check-spinel-math spinel-output-str-test-discard-sge)
# E054: map-kind atomic_add (SB002) and a dynamically dispatched operator
# (unknown SB004) — saved negative facts, stderr against Go's byte for byte.
foreach(e054_negative hash_atomic_add hash_record_add_or_init rc_map_atomic
        rec_poly_chain)
  add_test(NAME e054-${e054_negative} COMMAND ruby
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/negative-stderr.rb
      $<TARGET_FILE:spinel-mlir>
      ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/e054-${e054_negative}.mlir.gz
      ${SPINEL_E039_ORACLE}/negative/internal_frontend_testdata_neg_${e054_negative}/build.stderr
      ${CMAKE_CURRENT_BINARY_DIR}/e054-${e054_negative})
endforeach()
# E054 H3 (test only): the hash atomic_add check removed, and the E065 hint
# removed — each must change its case's stderr in the named way.
foreach(e054_flag NO_HASH_ATOMIC NO_E065_HINT)
  string(TOLOWER ${e054_flag} e054_mutation)
  string(REPLACE "_" "-" e054_mutation ${e054_mutation})
  add_library(SpinelBPFConversionE054${e054_flag} STATIC ${SPINEL_CONSUMER_SOURCES})
  target_compile_definitions(SpinelBPFConversionE054${e054_flag} PRIVATE
      SPINEL_E054_TEST_${e054_flag}=1)
  target_link_libraries(SpinelBPFConversionE054${e054_flag} PUBLIC
      $<TARGET_PROPERTY:SpinelBPFConversion,LINK_LIBRARIES>)
  add_llvm_executable(spinel-mlir-e054-${e054_mutation} tools/spinel-mlir.cpp)
  llvm_update_compile_flags(spinel-mlir-e054-${e054_mutation})
  target_link_libraries(spinel-mlir-e054-${e054_mutation} PRIVATE
      SpinelBPFConversionE054${e054_flag} MLIRParser MLIRIR MLIRSupport MLIRPass)
  add_dependencies(check-spinel-mlir spinel-mlir-e054-${e054_mutation})
  add_dependencies(check-spinel-math spinel-mlir-e054-${e054_mutation})
endforeach()
add_test(NAME e054-mutation-no-hash-atomic COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/negative-stderr.rb --mutant "SB001 (UnsupportedConstruct)"
    $<TARGET_FILE:spinel-mlir-e054-no-hash-atomic>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/e054-hash_atomic_add.mlir.gz
    ${SPINEL_E039_ORACLE}/negative/internal_frontend_testdata_neg_hash_atomic_add/build.stderr
    ${CMAKE_CURRENT_BINARY_DIR}/e054-mutation-no-hash-atomic)
add_test(NAME e054-mutation-no-e065-hint COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/negative-stderr.rb
    --mutant "needs a static call target [path: prog]"
    $<TARGET_FILE:spinel-mlir-e054-no-e065-hint>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/e054-rec_poly_chain.mlir.gz
    ${SPINEL_E039_ORACLE}/negative/internal_frontend_testdata_neg_rec_poly_chain/build.stderr
    ${CMAKE_CURRENT_BINARY_DIR}/e054-mutation-no-e065-hint)
# E045 H6 (test only): a record-valued hash status with its first two record
# members swapped, on pos_percpu_basic (PerPort.insert(53, Stats.new(…))).
add_library(SpinelBPFConversionStatusRecordSwap STATIC ${SPINEL_CONSUMER_SOURCES})
target_compile_definitions(SpinelBPFConversionStatusRecordSwap PRIVATE
    SPINEL_E045_TEST_STATUS_RECORD_SWAP=1)
target_link_libraries(SpinelBPFConversionStatusRecordSwap PUBLIC
    $<TARGET_PROPERTY:SpinelBPFConversion,LINK_LIBRARIES>)
add_llvm_executable(spinel-mlir-status-record-swap tools/spinel-mlir.cpp)
llvm_update_compile_flags(spinel-mlir-status-record-swap)
target_link_libraries(spinel-mlir-status-record-swap PRIVATE
    SpinelBPFConversionStatusRecordSwap MLIRParser MLIRIR MLIRSupport MLIRPass)
add_test(NAME status-record-mutation-swap COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/status-record-mutation.rb
    $<TARGET_FILE:spinel-mlir> $<TARGET_FILE:spinel-mlir-status-record-swap>
    $<TARGET_FILE:spinel-ir-normalize>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/status-record-percpu-basic.mlir.gz
    ${SPINEL_E039_ORACLE}/positive/internal_frontend_testdata_pos_percpu_basic/percpu_basic.mlir
    ${CMAKE_CURRENT_BINARY_DIR}/status-record-mutation-swap)
add_dependencies(check-spinel-mlir spinel-mlir-status-record-swap)
add_dependencies(check-spinel-math spinel-mlir-status-record-swap)
add_dependencies(check-spinel-mlir spinel-output-str-test)
add_dependencies(check-spinel-math spinel-output-str-test)
# H6 (test only): the read's status yielded as 0, and the user string taken
# inside the present region instead of before the reserve.
foreach(output_str_flag STATUS_ZERO STR_IN_PRESENT)
  string(TOLOWER ${output_str_flag} output_str_mutation)
  string(REPLACE "_" "-" output_str_mutation ${output_str_mutation})
  add_library(SpinelBPFConversionOutputStr${output_str_flag} STATIC ${SPINEL_CONSUMER_SOURCES})
  target_compile_definitions(SpinelBPFConversionOutputStr${output_str_flag} PRIVATE
      SPINEL_E039_TEST_${output_str_flag}=1)
  target_link_libraries(SpinelBPFConversionOutputStr${output_str_flag} PUBLIC
      $<TARGET_PROPERTY:SpinelBPFConversion,LINK_LIBRARIES>)
  add_executable(spinel-output-str-test-${output_str_mutation} tests/consumer/OutputStrTest.cpp)
  target_link_libraries(spinel-output-str-test-${output_str_mutation} PRIVATE
      SpinelBPFConversionOutputStr${output_str_flag} MLIRParser)
  add_test(NAME output-str-mutation-${output_str_mutation} COMMAND ruby
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/output-str-mutation.rb
      $<TARGET_FILE:spinel-output-str-test-${output_str_mutation}>
      ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/output-str-greetwatch.mlir.gz
      ${SPINEL_E039_ORACLE}/positive/examples_greetwatch_greetwatch/greetwatch.mlir
      ${CMAKE_CURRENT_BINARY_DIR}/output-str-mutation-${output_str_mutation}
      ${SPINEL_E039_ORACLE}/positive/examples_greetwatch_greetwatch)
  add_dependencies(check-spinel-mlir spinel-output-str-test-${output_str_mutation})
  add_dependencies(check-spinel-math spinel-output-str-test-${output_str_mutation})
endforeach()
add_executable(spinel-ring-hooks-test tests/consumer/RingHooksTest.cpp)
target_link_libraries(spinel-ring-hooks-test PRIVATE SpinelBPFConversion)
add_test(NAME ring-hooks COMMAND spinel-ring-hooks-test)
add_dependencies(check-spinel-mlir spinel-ring-hooks-test)
add_dependencies(check-spinel-math spinel-ring-hooks-test)
add_dependencies(check-spinel-mlir spinel-ring-test)
add_dependencies(check-spinel-math spinel-ring-test)
target_link_libraries(SpinelBPFConversion PUBLIC SpinelGroupARange)
add_library(SpinelBPFConversionRMWMutation STATIC ${SPINEL_CONSUMER_SOURCES})
target_compile_definitions(SpinelBPFConversionRMWMutation PRIVATE SPINEL_E010_TEST_RMW_AFTER_RANGE=1)
target_link_libraries(SpinelBPFConversionRMWMutation PUBLIC SpinelFactsImport PinnedEBPFDialect MLIRArithDialect MLIRPass SpinelGroupARange)
target_link_libraries(SpinelBPFConversionRMWMutation PUBLIC SpinelRecordExport)
target_link_libraries(SpinelBPFConversionRMWMutation PUBLIC SpinelSubprogramGraph)
add_executable(spinel-consumer-hooks-test tests/consumer/ConsumerHooksTest.cpp
    tests/consumer/SeparateHandler.cpp)
target_link_libraries(spinel-consumer-hooks-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME consumer-hooks COMMAND ruby ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/run.rb
    $<TARGET_FILE:spinel-consumer-hooks-test>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/group-a-ops-types.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/consumer-hooks
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/e016-narrow-basic.mlir.gz)
add_dependencies(check-spinel-mlir spinel-consumer-hooks-test)
add_dependencies(check-spinel-math spinel-consumer-hooks-test)
add_executable(spinel-rejected-program-test tests/consumer/RejectedProgramTest.cpp)
target_link_libraries(spinel-rejected-program-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME rejected-program COMMAND ruby ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/run.rb
    $<TARGET_FILE:spinel-rejected-program-test>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/e043-two-programs.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/rejected-program)
add_dependencies(check-spinel-mlir spinel-rejected-program-test)
add_dependencies(check-spinel-math spinel-rejected-program-test)
add_executable(spinel-rejected-program-mutation tests/consumer/RejectedProgramTest.cpp
    lib/Conversion/Consumer.cpp)
target_compile_definitions(spinel-rejected-program-mutation PRIVATE SPINEL_E043_TEST_IMMEDIATE_RETURN=1)
target_link_libraries(spinel-rejected-program-mutation PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME rejected-program-mutation COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/RejectedProgramMutation.rb
    $<TARGET_FILE:spinel-rejected-program-mutation>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/e043-two-programs.mlir.gz)
add_dependencies(check-spinel-mlir spinel-rejected-program-mutation)
add_dependencies(check-spinel-math spinel-rejected-program-mutation)
add_executable(spinel-rmw-domain-test tests/consumer/RmwDomainTest.cpp)
target_link_libraries(spinel-rmw-domain-test PRIVATE SpinelBPFConversion)
add_test(NAME rmw-domain COMMAND spinel-rmw-domain-test)
add_dependencies(check-spinel-mlir spinel-rmw-domain-test)
add_dependencies(check-spinel-math spinel-rmw-domain-test)
add_executable(spinel-consumer-finalizer-test tests/consumer/FinalizeBodyTest.cpp)
add_executable(spinel-unknown-diagnostic-test tests/consumer/UnknownDiagnosticTest.cpp)
target_link_libraries(spinel-unknown-diagnostic-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME unknown-diagnostic COMMAND spinel-unknown-diagnostic-test
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/xdpcount.spinel.mlir)
add_dependencies(check-spinel-mlir spinel-unknown-diagnostic-test)
add_dependencies(check-spinel-math spinel-unknown-diagnostic-test)
add_executable(spinel-source-audit-continuation-test tests/consumer/SourceAuditContinuationTest.cpp)
target_link_libraries(spinel-source-audit-continuation-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME source-audit-continuation COMMAND spinel-source-audit-continuation-test
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/xdpcount.spinel.mlir)
add_dependencies(check-spinel-mlir spinel-source-audit-continuation-test)
add_dependencies(check-spinel-math spinel-source-audit-continuation-test)
add_executable(spinel-source-audit-operator-test tests/consumer/SourceAuditOperatorTest.cpp)
target_link_libraries(spinel-source-audit-operator-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME source-audit-operator COMMAND ruby ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/run-source-operator.rb
  $<TARGET_FILE:spinel-source-audit-operator-test> ${CMAKE_CURRENT_SOURCE_DIR}/docs/experiments/results/E052/supply/raw.tar.gz)
add_dependencies(check-spinel-mlir spinel-source-audit-operator-test)
add_dependencies(check-spinel-math spinel-source-audit-operator-test)
add_llvm_executable(spinel-source-audit-diagnostic-mutation
  tools/spinel-mlir.cpp lib/Conversion/SourceAudits.cpp)
target_compile_definitions(spinel-source-audit-diagnostic-mutation PRIVATE SPINEL_E052_TEST_DIAGNOSTIC_BYTE)
target_link_libraries(spinel-source-audit-diagnostic-mutation PRIVATE SpinelBPFConversion MLIRParser MLIRIR MLIRSupport MLIRPass)
add_dependencies(check-spinel-mlir spinel-source-audit-diagnostic-mutation)
add_dependencies(check-spinel-math spinel-source-audit-diagnostic-mutation)
add_test(NAME scalar-typing-loop-diagnostics COMMAND ruby
  ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/check-scalar-typing-loop.rb
  $<TARGET_FILE:spinel-mlir> ${CMAKE_CURRENT_SOURCE_DIR}
  ${CMAKE_CURRENT_SOURCE_DIR}/docs/experiments/results/E051/inputs.json
  ${CMAKE_CURRENT_SOURCE_DIR}/docs/experiments/results/E051/supply-01.tar.gz
  ${CMAKE_CURRENT_BINARY_DIR}/scalar-typing-loop-diagnostics)
include(tests/consumer/ScalarMutations.cmake)
add_executable(spinel-group-g-runtime-test tests/tracing/RuntimeTest.cpp)
target_link_libraries(spinel-group-g-runtime-test PRIVATE SpinelBPFConversion MLIRParser)
target_link_libraries(spinel-consumer-finalizer-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME consumer-finalizer COMMAND spinel-consumer-finalizer-test
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/xdpcount.spinel.mlir)
add_dependencies(check-spinel-mlir spinel-consumer-finalizer-test)
add_dependencies(check-spinel-math spinel-consumer-finalizer-test)
add_executable(spinel-consumer-export-test tests/consumer/ExportTest.cpp)
target_link_libraries(spinel-consumer-export-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME consumer-export COMMAND ruby ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/run.rb
    $<TARGET_FILE:spinel-consumer-export-test>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/group-a-ops-types.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/consumer-export)
add_dependencies(check-spinel-mlir spinel-consumer-export-test)
add_dependencies(check-spinel-math spinel-consumer-export-test)
# E028: add_or_init against the Go oracle's hash/mc IR (ktime is E033's helper),
# probe-only status statements and the lowerToEBPF diagnostic gate.
add_executable(spinel-group-e-test tests/consumer/GroupETest.cpp)
target_compile_definitions(spinel-group-e-test PRIVATE
    SPINEL_E028_MC_ORACLE="${CMAKE_CURRENT_SOURCE_DIR}/docs/experiments/results/E003/capture/positive/cmd_spinelbpf_testdata_hash_mc/mc.mlir")
target_link_libraries(spinel-group-e-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME group-e-add-or-init-probe-gate COMMAND ruby ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/run.rb
    $<TARGET_FILE:spinel-group-e-test>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/hash-mc.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/group-e-test)
add_dependencies(check-spinel-mlir spinel-group-e-test)
add_dependencies(check-spinel-math spinel-group-e-test)
add_llvm_executable(spinel-mlir-rmw-mutation tools/spinel-mlir.cpp)
llvm_update_compile_flags(spinel-mlir-rmw-mutation)
target_link_libraries(spinel-mlir-rmw-mutation PRIVATE SpinelBPFConversionRMWMutation MLIRParser MLIRIR MLIRSupport MLIRPass)
add_dependencies(check-spinel-mlir spinel-mlir-rmw-mutation)
include(cmake/PacketTests.cmake)
add_executable(spinel-loop-facts-test tests/loop/LoopFactsTest.cpp
    )
target_link_libraries(spinel-loop-facts-test PRIVATE SpinelBPFConversion MLIRParser)
target_compile_options(spinel-loop-facts-test PRIVATE -fno-exceptions -fno-rtti)
add_dependencies(check-spinel-mlir spinel-loop-facts-test)
add_dependencies(check-spinel-math spinel-loop-facts-test)
add_test(NAME bounded-loop-facts COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/loop/loop-facts.rb
    $<TARGET_FILE:spinel-loop-facts-test>
    ${CMAKE_CURRENT_SOURCE_DIR}/docs/experiments/results/E008/capture/raw.tar.gz ${CMAKE_CURRENT_BINARY_DIR}/loop-facts)
add_library(SpinelBPFConversionLoopMutation STATIC ${SPINEL_CONSUMER_SOURCES})
target_compile_definitions(SpinelBPFConversionLoopMutation PRIVATE SPINEL_E012_TEST_COUNT=1)
target_link_libraries(SpinelBPFConversionLoopMutation PUBLIC SpinelFactsImport PinnedEBPFDialect MLIRArithDialect MLIRPass SpinelGroupARange)
target_link_libraries(SpinelBPFConversionLoopMutation PUBLIC SpinelRecordExport)
target_link_libraries(SpinelBPFConversionLoopMutation PUBLIC SpinelSubprogramGraph)
add_llvm_executable(spinel-mlir-loop-mutation tools/spinel-mlir.cpp)
llvm_update_compile_flags(spinel-mlir-loop-mutation)
target_link_libraries(spinel-mlir-loop-mutation PRIVATE SpinelBPFConversionLoopMutation MLIRParser MLIRIR MLIRSupport MLIRPass)
add_dependencies(check-spinel-mlir spinel-mlir-loop-mutation)
add_dependencies(check-spinel-math spinel-mlir-loop-mutation)
# E027 packet-only scope contract; both check targets own this executable.
add_executable(spinel-packet-loop-test tests/loop/PacketLoopTest.cpp)
target_link_libraries(spinel-packet-loop-test PRIVATE SpinelBPFConversion MLIRParser)
add_dependencies(check-spinel-mlir spinel-packet-loop-test)
add_dependencies(check-spinel-math spinel-packet-loop-test)
add_test(NAME packet-loop-scope COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/run.rb
    $<TARGET_FILE:spinel-packet-loop-test>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/packet-bounds.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/packet-loop-scope)
add_executable(spinel-packet-loop-rollback-test tests/loop/PacketLoopTest.cpp
    lib/Conversion/Packet.cpp)
target_compile_definitions(spinel-packet-loop-rollback-test PRIVATE
    SPINEL_E027_TEST_NO_PACKET_RESTORE=1)
target_link_libraries(spinel-packet-loop-rollback-test PRIVATE SpinelBPFConversion MLIRParser)
add_dependencies(check-spinel-mlir spinel-packet-loop-rollback-test)
add_dependencies(check-spinel-math spinel-packet-loop-rollback-test)
add_test(NAME packet-loop-rollback-mutation COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/loop/rollback.rb
    $<TARGET_FILE:spinel-packet-loop-rollback-test>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/packet-bounds.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/packet-loop-rollback)
add_llvm_executable(spinel-mlir-loop-map-mutation tools/spinel-mlir.cpp
    lib/Conversion/GroupBEffects.cpp)
target_compile_definitions(spinel-mlir-loop-map-mutation PRIVATE
    SPINEL_E027_TEST_DROP_MAP_EFFECT=1)
target_link_libraries(spinel-mlir-loop-map-mutation PRIVATE SpinelBPFConversion MLIRParser MLIRIR MLIRSupport MLIRPass)
add_dependencies(check-spinel-mlir spinel-mlir-loop-map-mutation)
add_dependencies(check-spinel-math spinel-mlir-loop-map-mutation)
add_subdirectory(tests/probe)
add_executable(spinel-sockmap-selection-test tests/tracing/SockMapSelectionTest.cpp)
add_executable(spinel-kernel-root-test tests/tracing/KernelRootTest.cpp)
add_executable(spinel-kernel-mutation-test tests/tracing/KernelMutationTest.cpp)
target_link_libraries(spinel-kernel-mutation-test PRIVATE SpinelBPFConversion MLIRParser)
add_dependencies(check-spinel-mlir spinel-kernel-mutation-test)
add_dependencies(check-spinel-math spinel-kernel-mutation-test)
add_test(NAME group-g-kernel-mutations COMMAND ruby
  ${CMAKE_CURRENT_SOURCE_DIR}/tests/tracing/check-kernel-mutations.rb
  $<TARGET_FILE:spinel-kernel-mutation-test>
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/group-g-mutation-field.mlir.gz
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/group-g-mutation-arg.mlir.gz
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/group-g-mutation-presence.mlir.gz
  ${CMAKE_CURRENT_BINARY_DIR}/group-g-kernel-mutations)
add_executable(spinel-rootless-declaration-test tests/tracing/RootlessDeclarationTest.cpp)
target_link_libraries(spinel-rootless-declaration-test PRIVATE SpinelBPFConversion MLIRParser)
add_dependencies(check-spinel-mlir spinel-rootless-declaration-test)
add_dependencies(check-spinel-math spinel-rootless-declaration-test)
add_test(NAME group-g-rootless-declarations COMMAND ruby
  ${CMAKE_CURRENT_SOURCE_DIR}/tests/tracing/check-rootless.rb
  $<TARGET_FILE:spinel-rootless-declaration-test>
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/group-g-rootless-declarations.mlir.gz
  ${CMAKE_CURRENT_BINARY_DIR}/group-g-rootless-declarations)
add_executable(spinel-invalid-lowering-test tests/tracing/InvalidLoweringTest.cpp)
target_link_libraries(spinel-invalid-lowering-test PRIVATE SpinelBPFConversion MLIRParser)
add_dependencies(check-spinel-mlir spinel-invalid-lowering-test)
add_dependencies(check-spinel-math spinel-invalid-lowering-test)
add_test(NAME group-g-invalid-lowering COMMAND ruby
  ${CMAKE_CURRENT_SOURCE_DIR}/tests/tracing/check-invalid-lowering.rb
  $<TARGET_FILE:spinel-invalid-lowering-test>
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/group-g-invalid-verdict.mlir.gz
  ${CMAKE_CURRENT_BINARY_DIR}/group-g-invalid-lowering)
target_link_libraries(spinel-kernel-root-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME group-g-kernel-root COMMAND ruby
  ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/run.rb
  $<TARGET_FILE:spinel-kernel-root-test>
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/group-g-trace-fexit.mlir.gz
  ${CMAKE_CURRENT_BINARY_DIR}/group-g-kernel-root)
add_dependencies(check-spinel-mlir spinel-kernel-root-test)
add_dependencies(check-spinel-math spinel-kernel-root-test)
add_test(NAME group-g-sockmap-policy COMMAND ruby
  ${CMAKE_CURRENT_SOURCE_DIR}/tests/tracing/check-sockmap-policy.rb
  $<TARGET_FILE:spinel-kernel-root-test>
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/group-g-sk-lookup.mlir.gz
  ${CMAKE_CURRENT_BINARY_DIR}/group-g-sockmap-policy)
target_link_libraries(spinel-sockmap-selection-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME group-g-sockmap-selection COMMAND ruby
  ${CMAKE_CURRENT_SOURCE_DIR}/tests/tracing/check-sockmap.rb
  $<TARGET_FILE:spinel-sockmap-selection-test>
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/group-g-sockmap-invalid.mlir.gz
  ${CMAKE_CURRENT_SOURCE_DIR}/docs/experiments/results/E035/capture/synthetic/sk_value_unused_custom_xdp/build.stderr
  ${CMAKE_CURRENT_BINARY_DIR}/group-g-sockmap-selection)
add_dependencies(check-spinel-mlir spinel-sockmap-selection-test)
add_dependencies(check-spinel-math spinel-sockmap-selection-test)
# E033: independent registry for shared scalar helpers.
add_executable(spinel-helper-test tests/consumer/HelperTest.cpp)
target_compile_definitions(spinel-helper-test PRIVATE
    SPINEL_E033_REC_ORACLE="${CMAKE_CURRENT_SOURCE_DIR}/docs/experiments/results/E003/capture/positive/internal_frontend_testdata_pos_rec_ktime/rec_ktime.mlir"
    SPINEL_E033_MC_ORACLE="${CMAKE_CURRENT_SOURCE_DIR}/docs/experiments/results/E003/capture/positive/cmd_spinelbpf_testdata_hash_mc/mc.mlir")
target_link_libraries(spinel-helper-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME scalar-helpers COMMAND ruby ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/helpers.rb
    $<TARGET_FILE:spinel-helper-test>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/rec-ktime.mlir.gz
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/hash-mc.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/helper-test)
add_dependencies(check-spinel-mlir spinel-helper-test)
add_dependencies(check-spinel-math spinel-helper-test)
add_executable(spinel-helper-loc-mutation tests/consumer/HelperTest.cpp lib/Conversion/Helpers.cpp)
get_target_property(E033_HELPER_DEFINITIONS spinel-helper-test COMPILE_DEFINITIONS)
target_compile_definitions(spinel-helper-loc-mutation PRIVATE ${E033_HELPER_DEFINITIONS}
    SPINEL_E033_TEST_UNKNOWN_LOC=1)
target_link_libraries(spinel-helper-loc-mutation PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME scalar-helper-loc-mutation COMMAND ${CMAKE_COMMAND} -E env E033_EXPECT_LOC_RED=1
    ruby ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/helpers.rb
    $<TARGET_FILE:spinel-helper-loc-mutation>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/rec-ktime.mlir.gz
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/hash-mc.mlir.gz
    ${CMAKE_CURRENT_BINARY_DIR}/helper-loc-mutation)
add_dependencies(check-spinel-mlir spinel-helper-loc-mutation)
add_dependencies(check-spinel-math spinel-helper-loc-mutation)
add_subdirectory(tests/declarations)
add_subdirectory(tests/percpu-record)
add_executable(spinel-uprobe-hooks-test tests/consumer/UprobeHooksTest.cpp)
target_link_libraries(spinel-uprobe-hooks-test PRIVATE SpinelBPFConversion)
add_test(NAME uprobe-hooks COMMAND spinel-uprobe-hooks-test)
add_dependencies(check-spinel-mlir spinel-uprobe-hooks-test)
add_dependencies(check-spinel-math spinel-uprobe-hooks-test)
add_llvm_executable(spinel-mlir-uprobe-mutation
    tools/spinel-mlir.cpp lib/Conversion/GroupGUprobe.cpp)
llvm_update_compile_flags(spinel-mlir-uprobe-mutation)
target_compile_definitions(spinel-mlir-uprobe-mutation PRIVATE SPINEL_E040_TEST_SIGNED_U32=1)
target_link_libraries(spinel-mlir-uprobe-mutation PRIVATE
    SpinelBPFConversion MLIRParser MLIRIR MLIRSupport MLIRPass)
add_dependencies(check-spinel-mlir spinel-mlir-uprobe-mutation)
add_dependencies(check-spinel-math spinel-mlir-uprobe-mutation)

add_llvm_executable(spinel-mlir-packet-diagnostic-mutation
  tools/spinel-mlir.cpp lib/Conversion/Packet.cpp)
llvm_update_compile_flags(spinel-mlir-packet-diagnostic-mutation)
target_compile_definitions(spinel-mlir-packet-diagnostic-mutation PRIVATE
  SPINEL_E046_TEST_DIAGNOSTIC_BYTE=1)
target_link_libraries(spinel-mlir-packet-diagnostic-mutation PRIVATE
  SpinelBPFConversion MLIRParser MLIRIR MLIRSupport)
add_dependencies(check-spinel-mlir spinel-mlir-packet-diagnostic-mutation)
add_dependencies(check-spinel-math spinel-mlir-packet-diagnostic-mutation)

# E075: domain-only writer and format tests.
add_executable(spinel-inspection-test tests/consumer/InspectionTest.cpp lib/Conversion/Inspection.cpp)
add_test(NAME inspection-writer COMMAND spinel-inspection-test)
add_dependencies(check-spinel-mlir spinel-inspection-test)
add_dependencies(check-spinel-math spinel-inspection-test)
add_test(NAME inspection-cli COMMAND ruby
  ${CMAKE_CURRENT_SOURCE_DIR}/tests/inspection/cli.rb
  $<TARGET_FILE:spinel-mlir>
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/xdpcount.spinel.mlir)
add_test(NAME inspection-source-writer COMMAND ruby
  ${CMAKE_CURRENT_SOURCE_DIR}/tests/inspection/source-report.rb)
add_executable(spinel-inspection-phase-test tests/consumer/InspectionPhaseTest.cpp)
target_link_libraries(spinel-inspection-phase-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME inspection-phase COMMAND spinel-inspection-phase-test
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/xdpcount.spinel.mlir)
add_dependencies(check-spinel-mlir spinel-inspection-phase-test)
add_dependencies(check-spinel-math spinel-inspection-phase-test)
add_executable(spinel-inspection-scope-test tests/consumer/InspectionScopeTest.cpp)
target_link_libraries(spinel-inspection-scope-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME inspection-scope COMMAND spinel-inspection-scope-test
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/xdpcount.spinel.mlir)
add_dependencies(check-spinel-mlir spinel-inspection-scope-test)
add_dependencies(check-spinel-math spinel-inspection-scope-test)

# E077: isolated root/checked-copy tests, shared by both check targets.
add_executable(spinel-tracepoint-copy-test tests/consumer/TracepointCopyTest.cpp)
target_link_libraries(spinel-tracepoint-copy-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME tracepoint-copy COMMAND ruby
  ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/tracepoint-copy-unit.rb
  $<TARGET_FILE:spinel-tracepoint-copy-test>
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/tracepoint-array-ring.mlir.gz
  ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/tracepoint-array-kprobe.mlir.gz)
add_dependencies(check-spinel-mlir spinel-tracepoint-copy-test)
add_dependencies(check-spinel-math spinel-tracepoint-copy-test)
add_test(NAME union-inspection-default COMMAND ruby
  ${CMAKE_CURRENT_SOURCE_DIR}/tests/inspection/union-default.rb
  ${CMAKE_CURRENT_SOURCE_DIR})
# E077 sensitivity: force just the altered Probe object into a test-only CLI;
# all other objects are the ordinary library. No production flag or option.
add_library(SpinelTracepointCopyDrop OBJECT lib/Conversion/GroupGProbe.cpp)
target_compile_definitions(SpinelTracepointCopyDrop PRIVATE SPINEL_E077_TEST_TP_COPY_DROP=1)
target_link_libraries(SpinelTracepointCopyDrop PRIVATE SpinelBPFConversion)
add_llvm_executable(spinel-mlir-tp-copy-drop tools/spinel-mlir.cpp
  $<TARGET_OBJECTS:SpinelTracepointCopyDrop>)
llvm_update_compile_flags(spinel-mlir-tp-copy-drop)
target_link_libraries(spinel-mlir-tp-copy-drop PRIVATE
  SpinelBPFConversion MLIRParser MLIRIR MLIRSupport MLIRPass)
add_dependencies(check-spinel-mlir spinel-mlir-tp-copy-drop)
add_dependencies(check-spinel-math spinel-mlir-tp-copy-drop)

# E079: owned observation comparison, with no Consumer::run in calibration.
add_executable(spinel-typing-probe-test tests/consumer/TypingProbeComparisonTest.cpp)
target_link_libraries(spinel-typing-probe-test PRIVATE SpinelBPFConversion)
add_test(NAME typing-probe-comparison COMMAND spinel-typing-probe-test)
add_executable(spinel-typing-probe-calibration tests/consumer/TypingProbeCalibration.cpp)
target_link_libraries(spinel-typing-probe-calibration PRIVATE SpinelBPFConversion)
add_dependencies(check-spinel-mlir spinel-typing-probe-test spinel-typing-probe-calibration)
add_dependencies(check-spinel-math spinel-typing-probe-test spinel-typing-probe-calibration)
add_executable(spinel-kernel-path-addr-test tests/consumer/KernelPathAddrTest.cpp)
target_link_libraries(spinel-kernel-path-addr-test PRIVATE SpinelBPFConversion MLIRParser)
add_dependencies(check-spinel-mlir spinel-kernel-path-addr-test)
add_dependencies(check-spinel-math spinel-kernel-path-addr-test)
foreach(kernel_mutation path-leaf-swap addr-zero)
  add_library(SpinelKernel-${kernel_mutation} OBJECT lib/Conversion/GroupGKernel.cpp)
  if(kernel_mutation STREQUAL "path-leaf-swap")
    target_compile_definitions(SpinelKernel-${kernel_mutation} PRIVATE SPINEL_E079_TEST_PATH_LEAF_SWAP=1)
  else()
    target_compile_definitions(SpinelKernel-${kernel_mutation} PRIVATE SPINEL_E079_TEST_ADDR_ZERO=1)
  endif()
  target_link_libraries(SpinelKernel-${kernel_mutation} PRIVATE SpinelBPFConversion)
  add_llvm_executable(spinel-mlir-${kernel_mutation} tools/spinel-mlir.cpp $<TARGET_OBJECTS:SpinelKernel-${kernel_mutation}>)
  llvm_update_compile_flags(spinel-mlir-${kernel_mutation})
  target_link_libraries(spinel-mlir-${kernel_mutation} PRIVATE SpinelBPFConversion MLIRParser MLIRIR MLIRSupport MLIRPass)
  add_dependencies(check-spinel-mlir spinel-mlir-${kernel_mutation})
  add_dependencies(check-spinel-math spinel-mlir-${kernel_mutation})
endforeach()
add_test(NAME capture-wrote-origin COMMAND ruby ${CMAKE_CURRENT_SOURCE_DIR}/tests/corpus/capture-wrote-origin.rb)

# E080: checked user buffers share only the existing reservation contract.
add_executable(spinel-uprobe-buffer-test tests/consumer/UprobeBufferTest.cpp)
target_link_libraries(spinel-uprobe-buffer-test PRIVATE SpinelBPFConversion MLIRParser)
add_test(NAME uprobe-buffer-contract COMMAND ruby
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/consumer/uprobe-buffer-run.rb
    $<TARGET_FILE:spinel-uprobe-buffer-test>
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/E080/up-buf.mlir.gz
    ${CMAKE_CURRENT_SOURCE_DIR}/test/Inputs/E080/up_buf.rb
    ${CMAKE_CURRENT_BINARY_DIR}/uprobe-buffer-unit)
add_dependencies(check-spinel-mlir spinel-uprobe-buffer-test)
add_dependencies(check-spinel-math spinel-uprobe-buffer-test)
add_llvm_executable(spinel-mlir-buffer-length-mutation tools/spinel-mlir.cpp lib/Conversion/Ring.cpp)
llvm_update_compile_flags(spinel-mlir-buffer-length-mutation)
target_compile_definitions(spinel-mlir-buffer-length-mutation PRIVATE SPINEL_E080_TEST_BUFFER_LEN_ZERO=1)
target_link_libraries(spinel-mlir-buffer-length-mutation PRIVATE SpinelBPFConversion MLIRParser MLIRIR MLIRSupport MLIRPass)
add_dependencies(check-spinel-mlir spinel-mlir-buffer-length-mutation)
add_dependencies(check-spinel-math spinel-mlir-buffer-length-mutation)
