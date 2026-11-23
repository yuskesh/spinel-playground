cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(edge_twin_device)

# The freestanding object and its generated header both come from
# spinel-mlirgen; Zephyr is only asked to link and run.  P003 design principle 7:
# the final link belongs to the platform, and the platform here is Zephyr's own
# build system with its own toolchain -- the object is just an object.
if(NOT DEFINED SPINEL_OBJ)
  message(FATAL_ERROR "-DSPINEL_OBJ=<path to kern.o> is required (see build.sh)")
endif()
if(NOT DEFINED SPINEL_GEN_DIR)
  message(FATAL_ERROR "-DSPINEL_GEN_DIR=<dir with spinel_freestanding.h> is required")
endif()

target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${SPINEL_GEN_DIR})
if(DEFINED EDGE_TWIN_TRAP_PROBE)
  target_compile_definitions(app PRIVATE EDGE_TWIN_TRAP_PROBE=1)
endif()

zephyr_link_libraries(${SPINEL_OBJ})
