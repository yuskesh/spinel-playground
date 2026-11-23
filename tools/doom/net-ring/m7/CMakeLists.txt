# tools/doom/net-ring/m7 -- the network path's test producer on the M7
# (README.md), with the DOOM M7 application's board files (decision 0023).
cmake_minimum_required(VERSION 3.20.0)
set(BOARDS ${CMAKE_CURRENT_LIST_DIR}/../../../app/zephyr/v4.4.2/boards)
set(DTC_OVERLAY_FILE "${BOARDS}/frdm_imxrt1186_nor.overlay;${BOARDS}/frdm_imxrt1186_cm7.overlay")
set(CONF_FILE "${BOARDS}/frdm_imxrt1186_cm7.conf;${CMAKE_CURRENT_LIST_DIR}/prj.conf")
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(spinel_net_ring_m7)
target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_LIST_DIR}/../../../app)
