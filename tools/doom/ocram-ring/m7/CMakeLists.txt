# tools/doom/ocram-ring/m7 -- the ring test's producer on the M7 (README.md),
# with the DOOM M7 application's board files (decision 0023): its code in
# place from the NOR's m7_code_partition, its RAM the HyperRAM, its console
# LPUART1. Nothing of it is linked into the ring's OCRAM2 (build.sh), which
# the board's own MPU table makes Normal non-cacheable (ring_abi.h).
cmake_minimum_required(VERSION 3.20.0)
set(BOARDS ${CMAKE_CURRENT_LIST_DIR}/../../../app/zephyr/v4.4.2/boards)
set(DTC_OVERLAY_FILE "${BOARDS}/frdm_imxrt1186_nor.overlay;${BOARDS}/frdm_imxrt1186_cm7.overlay")
set(CONF_FILE "${BOARDS}/frdm_imxrt1186_cm7.conf;${CMAKE_CURRENT_LIST_DIR}/prj.conf")
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(spinel_ring_m7)
target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_LIST_DIR}/.. ${CMAKE_CURRENT_LIST_DIR}/../../../app/ring)
# the kept failing input (build.sh, PLANT=1)
if(SPC_RING_PLANT_EARLY_HEAD)
  target_compile_definitions(app PRIVATE SPC_RING_PLANT_EARLY_HEAD=1)
endif()
