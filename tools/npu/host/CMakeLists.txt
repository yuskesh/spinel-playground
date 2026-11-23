# tools/npu/host/CMakeLists.txt -- the Zephyr image around a hosted Spinel
# program. tools/npu/spinel-npu compiles the program, the runtime and the
# tensor shim, and hands the objects over through SP_NPU_OUT.
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(spinel_npu)
target_sources(app PRIVATE src/host.c ${SP_NPU_OUT}/npu_glue.c ${SP_NPU_OUT}/npu_model.c)
target_compile_definitions(app PRIVATE IREE_PLATFORM_GENERIC=1 IREE_FILE_IO_ENABLE=0
  IREE_DEVICE_SIZE_T=uint32_t PRIdsz=PRIu32 IREE_STATUS_MODE=0
  IREE_ALLOCATOR_SYSTEM_CTL=iree_allocator_libc_ctl)
target_compile_options(app PRIVATE -include ${CMAKE_CURRENT_SOURCE_DIR}/tiny.h)
target_include_directories(app PRIVATE ${SP_NPU_OUT}
  ${ZEPHYR_HAL_NXP_MODULE_DIR}/mcux/middleware/neutron/include
  $ENV{IREE_SRC}/runtime/src $ENV{IREE_SRC} $ENV{IREE_M33_BUILD}/runtime/src)
file(GLOB SP_RT ${SP_NPU_OUT}/rt/*.o)
file(GLOB SP_IREE $ENV{IREE_M33_BUILD}/runtime/src/iree/*.a $ENV{IREE_M33_BUILD}/runtime/src/iree/*/*.a
  $ENV{IREE_M33_BUILD}/runtime/src/iree/*/*/*.a $ENV{IREE_M33_BUILD}/runtime/src/iree/*/*/*/*.a
  $ENV{IREE_M33_BUILD}/runtime/src/iree/*/*/*/*/*.a $ENV{IREE_M33_BUILD}/build_tools/third_party/*/*.a)
target_link_libraries(app PRIVATE ${SP_NPU_OUT}/app.o ${SP_NPU_OUT}/shim.o ${SP_NPU_OUT}/npu_k.o
  ${SP_RT} -Wl,--start-group ${SP_IREE} -Wl,--end-group)
