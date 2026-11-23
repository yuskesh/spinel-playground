cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(e083_kernel_optimizer_loop)

# TWO generated objects, which is the experiment: spinel-mlirgen's kernel
# (whose `calibrate` IMPORTS spinel_grad_sq_hinge_loss as a platform extern
# declared by the profile) and spinel-gradfs's --grads-only object (which
# defines that one symbol).  "The platform supplies a declared extern" is,
# on Zephyr, exactly this second line of link input -- west links it the way
# E081 compiled a wrapper C file (P003 principle 7: the final link is the
# platform's job).
if(NOT DEFINED SPINEL_OBJ)
  message(FATAL_ERROR "-DSPINEL_OBJ=<path to kern.<profile>.o> is required")
endif()
if(NOT DEFINED SPINEL_GRAD_OBJ)
  message(FATAL_ERROR "-DSPINEL_GRAD_OBJ=<path to grad.<profile>.o> is required")
endif()
if(NOT DEFINED SPINEL_GEN_DIR)
  message(FATAL_ERROR "-DSPINEL_GEN_DIR=<dir with the generated headers> is required")
endif()
if(NOT DEFINED E083_DRV_DIR)
  message(FATAL_ERROR "-DE083_DRV_DIR=<dir with e083_drv.c> is required")
endif()

target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${SPINEL_GEN_DIR} ${E083_DRV_DIR})
if(DEFINED E083_TRAP)
  target_compile_definitions(app PRIVATE E083_TRAP=${E083_TRAP})
endif()

zephyr_link_libraries(${SPINEL_OBJ} ${SPINEL_GRAD_OBJ})
