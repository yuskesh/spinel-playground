cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(e081_platform_extern)

# The freestanding object, its generated header and the generated case table
# come from spinel-mlirgen / mkcases.py; Zephyr links and runs (P003 design
# principle 7).  New in E081: a second app TU, spinel_zephyr.c -- the platform
# wrappers the kernel imports.  It #includes the generated header, so the
# profile's extern declarations are enforced on it by Zephyr's own compiler.
if(NOT DEFINED SPINEL_OBJ)
  message(FATAL_ERROR "-DSPINEL_OBJ=<path to kern.o> is required")
endif()
if(NOT DEFINED SPINEL_GEN_DIR)
  message(FATAL_ERROR "-DSPINEL_GEN_DIR=<dir with spinel_freestanding.h and cases.inc> is required")
endif()

target_sources(app PRIVATE src/main.c src/spinel_zephyr.c)
target_include_directories(app PRIVATE ${SPINEL_GEN_DIR})
if(DEFINED E081_PANIC_TRAP)
  target_compile_definitions(app PRIVATE E081_PANIC_TRAP=1)
endif()

zephyr_link_libraries(${SPINEL_OBJ})
