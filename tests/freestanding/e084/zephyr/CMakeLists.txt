cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(e084_kernel_newton)

# TWO generated objects, as in E083 -- but the adjoint object now defines TWO
# symbols: the reverse gradient AND the forward-over-reverse Hessian-vector
# product, both of which the kernel's Newton-CG loop imports as platform
# externs declared by the profile.  West links the pair the way E081 compiled
# a wrapper C file (P003 principle 7: the final link is the platform's job).
if(NOT DEFINED SPINEL_OBJ)
  message(FATAL_ERROR "-DSPINEL_OBJ=<path to kern.<profile>.o> is required")
endif()
if(NOT DEFINED SPINEL_GRAD_OBJ)
  message(FATAL_ERROR "-DSPINEL_GRAD_OBJ=<path to grad.<profile>.o> is required")
endif()
if(NOT DEFINED SPINEL_GEN_DIR)
  message(FATAL_ERROR "-DSPINEL_GEN_DIR=<dir with the generated headers> is required")
endif()
if(NOT DEFINED E084_DRV_DIR)
  message(FATAL_ERROR "-DE084_DRV_DIR=<dir with e084_drv.c> is required")
endif()

target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${SPINEL_GEN_DIR} ${E084_DRV_DIR})
if(DEFINED E084_TRAP)
  target_compile_definitions(app PRIVATE E084_TRAP=${E084_TRAP})
endif()

zephyr_link_libraries(${SPINEL_OBJ} ${SPINEL_GRAD_OBJ})
