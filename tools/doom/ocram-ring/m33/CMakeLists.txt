# tools/doom/ocram-ring/m33 -- the ring test's consumer and checker on the
# M33 (README.md): tools/app/launcher's image (the boot header, the XMCD, the
# M7 released to run in place from m7_code_partition) with the ring's
# initialisation and the checker added.
cmake_minimum_required(VERSION 3.20.0)
set(APPDIR ${CMAKE_CURRENT_LIST_DIR}/../../../app)
set(DTC_OVERLAY_FILE "${APPDIR}/launcher/app.overlay;${APPDIR}/zephyr/v4.4.2/boards/frdm_imxrt1186_nor.overlay")
set(CONF_FILE "${APPDIR}/launcher/prj.conf;${CMAKE_CURRENT_LIST_DIR}/prj.conf")
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(spinel_ring_m33)
target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_LIST_DIR}/.. ${CMAKE_CURRENT_LIST_DIR}/../../../app/ring)
