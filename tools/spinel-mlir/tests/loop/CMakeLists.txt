cmake_minimum_required(VERSION 3.20)
project(SpinelBoundedLoopRangeTests LANGUAGES C CXX)
find_package(LLVM 23.1.1 REQUIRED CONFIG)
if(NOT GROUP_A_RANGE_ROOT)
  message(FATAL_ERROR "set GROUP_A_RANGE_ROOT to the pinned E011 source snapshot")
endif()
set(CMAKE_CXX_STANDARD 17)
add_compile_options(-fno-exceptions -fno-rtti)
add_library(SpinelBoundedLoopRange STATIC
  ../../lib/Analysis/BoundedLoopRange.cpp
  ${GROUP_A_RANGE_ROOT}/lib/Analysis/GroupARange.cpp)
target_include_directories(SpinelBoundedLoopRange PUBLIC
  ../../include ${GROUP_A_RANGE_ROOT}/include ${LLVM_INCLUDE_DIRS})
llvm_map_components_to_libnames(llvm_libs Support)
target_link_libraries(SpinelBoundedLoopRange PUBLIC ${llvm_libs})
add_executable(spinel-loop-range-test BoundedLoopRangeTest.cpp)
target_link_libraries(spinel-loop-range-test PRIVATE SpinelBoundedLoopRange)
enable_testing()
add_test(NAME bounded-loop-range COMMAND spinel-loop-range-test)
add_test(NAME bounded-loop-next-mutation COMMAND ${CMAKE_COMMAND}
  -DTEST_BINARY=$<TARGET_FILE:spinel-loop-range-test>
  -P ${CMAKE_CURRENT_SOURCE_DIR}/CheckMutation.cmake)
