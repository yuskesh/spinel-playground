# Byte-helper probe for tests/app/channel.sh (decision 0014, Task 8): links
# the kernel's thumbv8m object of the `fill` entry, given as -DSPC_OBJ=<path>,
# and prints its bytes over the console under QEMU.
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(spinel_bytes_probe)
target_sources(app PRIVATE src/main.c)
if(NOT DEFINED SPC_OBJ)
  message(FATAL_ERROR "SPC_OBJ (the fill entry's object) is required")
endif()
target_link_libraries(app PRIVATE ${SPC_OBJ})
