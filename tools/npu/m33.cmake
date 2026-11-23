# tools/npu/m33.cmake -- the toolchain file for IREE's runtime on the Cortex-M33
# (tools/npu/build-iree-m33.sh). The host header and the Zephyr SDK come from
# the environment.
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(P $ENV{ZEPHYR_SDK_INSTALL_DIR}/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi)
set(CMAKE_C_COMPILER ${P}-gcc)
set(CMAKE_CXX_COMPILER ${P}-g++)
set(CMAKE_ASM_COMPILER ${P}-gcc)
set(CMAKE_AR ${P}-ar)
set(CMAKE_RANLIB ${P}-ranlib)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
get_filename_component(TINY ${CMAKE_CURRENT_LIST_DIR}/host/tiny.h ABSOLUTE)
set(F "-mcpu=cortex-m33 -mthumb -mfloat-abi=hard -mfpu=fpv5-sp-d16 -Os -ffunction-sections -fdata-sections -DIREE_PLATFORM_GENERIC=1 -DIREE_FILE_IO_ENABLE=0 -include ${TINY} -DIREE_WAIT_UNTIL_FN=tiny_wait_until -DIREE_TIME_NOW_FN=\"{ return 0; }\" -DIREE_DEVICE_SIZE_T=uint32_t -DPRIdsz=PRIu32 -DIREE_STATUS_MODE=0")
set(CMAKE_C_FLAGS_INIT "${F}")
set(CMAKE_CXX_FLAGS_INIT "${F}")
set(CMAKE_ASM_FLAGS_INIT "${F}")
