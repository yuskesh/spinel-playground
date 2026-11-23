# tools/npu/stm32mp2/toolchain.cmake -- the toolchain file for IREE's runtime on
# the STM32MP257's Cortex-A35 (tools/npu/stm32mp2/build-iree.sh). The cross
# compiler and the sysroot come from the environment.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(P $ENV{STM32MP2_CROSS})
set(CMAKE_C_COMPILER ${P}gcc)
set(CMAKE_CXX_COMPILER ${P}g++)
set(CMAKE_ASM_COMPILER ${P}gcc)
set(CMAKE_AR ${P}ar)
set(CMAKE_RANLIB ${P}ranlib)
set(CMAKE_SYSROOT $ENV{STM32MP2_SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(F "-mcpu=cortex-a35 -O2 -ffunction-sections -fdata-sections")
set(CMAKE_C_FLAGS_INIT "${F}")
set(CMAKE_CXX_FLAGS_INIT "${F}")
set(CMAKE_ASM_FLAGS_INIT "${F}")
