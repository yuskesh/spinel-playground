cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(e077_freestanding_data_abi)

# The freestanding object, its generated header and the generated case table all
# come from spinel-mlirgen / mkcases.py; Zephyr is only asked to link and run.
# P003 design principle 7: the final link belongs to the platform.
if(NOT DEFINED SPINEL_OBJ)
  message(FATAL_ERROR "-DSPINEL_OBJ=<path to kern.o> is required")
endif()
if(NOT DEFINED SPINEL_GEN_DIR)
  message(FATAL_ERROR "-DSPINEL_GEN_DIR=<dir with spinel_freestanding.h and cases.inc> is required")
endif()

target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${SPINEL_GEN_DIR})
if(DEFINED E077_PANIC_TRAP)
  target_compile_definitions(app PRIVATE E077_PANIC_TRAP=1)
endif()

zephyr_link_libraries(${SPINEL_OBJ})
