cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(e079_edge_calibration)

# Everything interesting is generated: the object (kernel + Enzyme adjoint in
# one .o, from spinel-gradfs), the two headers, and -- for the shipped build --
# the weights the edge computed.  Zephyr only links and runs (P003 principle 7).
if(NOT DEFINED SPINEL_OBJ)
  message(FATAL_ERROR "-DSPINEL_OBJ=<path to grad.<profile>.o> is required")
endif()
if(NOT DEFINED SPINEL_GEN_DIR)
  message(FATAL_ERROR "-DSPINEL_GEN_DIR=<dir with the generated headers> is required")
endif()
if(NOT DEFINED E079_DRV_DIR)
  message(FATAL_ERROR "-DE079_DRV_DIR=<dir with e079_drv.c> is required")
endif()

target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${SPINEL_GEN_DIR} ${E079_DRV_DIR})
if(DEFINED E079_SHIPPED)
  target_compile_definitions(app PRIVATE E079_SHIPPED=1)
endif()

zephyr_link_libraries(${SPINEL_OBJ})
