# Reserve harness for tests/app/reserves.sh (decision 0014, Task 9).
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(spinel_reserve_harness)
target_sources(app PRIVATE src/main.c)
# reserves.h is generated beside the build by reserves.sh from reserves.tsv
if(DEFINED SPC_RESERVES_DIR)
  target_include_directories(app PRIVATE ${SPC_RESERVES_DIR})
endif()
