# tools/doom/net-probe -- the M33-only UDP sender of decision 0024's
# amendment, a measurement image (not the DOOM image): see README.md.
cmake_minimum_required(VERSION 3.20.0)
set(DTC_OVERLAY_FILE "${CMAKE_CURRENT_LIST_DIR}/app.overlay;${CMAKE_CURRENT_LIST_DIR}/../../app/zephyr/v4.4.2/boards/frdm_imxrt1186_nor.overlay")
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(spinel_net_probe)
target_sources(app PRIVATE src/main.c)
# the destination, from the network file outside the repository (build.sh)
if(NOT DEFINED PROBE_NET_H)
  message(FATAL_ERROR "PROBE_NET_H names the header build.sh writes from the network file")
endif()
target_compile_definitions(app PRIVATE PROBE_NET_H="${PROBE_NET_H}")
# the driver's busy-wait, timed from outside it: the HAL's send returns when
# the frame is queued, and the driver then spins on tx_done before it calls
# the reclaim; both are HAL functions in another object, so --wrap reaches
# them without touching Zephyr's source
zephyr_ld_options(-Wl,--wrap=EP_SendFrameCommon -Wl,--wrap=EP_SendFrame -Wl,--wrap=EP_ReclaimTxDescCommon)
# the variant that enables the code bus cache (build.sh, PROBE_ICACHE=1)
if(PROBE_ICACHE)
  target_compile_definitions(app PRIVATE PROBE_ICACHE=1)
endif()
# the variant whose network code runs from the M33's ITCM instead of in place
# from the NOR (build.sh, PROBE_RELOCATE=1), as Zephyr's samples/net/zperf
# relocates it for the i.MX RT1170
if(PROBE_RELOCATE)
  foreach(lib subsys__net__ip subsys__net subsys__net__l2__ethernet subsys__net__l2__ethernet__dsa drivers__ethernet)
    zephyr_code_relocate(LIBRARY ${lib} LOCATION ITCM_TEXT NOKEEP)
  endforeach()
endif()
