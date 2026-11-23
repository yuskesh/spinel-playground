# The settling probe (0014, Task 10's list: the 16 interrupt-stack bytes).
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(spinel_settle_probe)
target_sources(app PRIVATE src/main.c)
if(DEFINED SPC_FORCE_NESTING)
  target_compile_definitions(app PRIVATE SPC_FORCE_NESTING=${SPC_FORCE_NESTING})
endif()
