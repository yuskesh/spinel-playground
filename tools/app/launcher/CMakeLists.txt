# tools/app/launcher -- the FRDM-IMXRT1186's M33 image of decision 0023: it
# boots from the NOR (the boot header and the XMCD that has the ROM set up
# the HyperRAM), opens the TRDC to the Cortex-M7 and releases it to run its
# code in place from m7_code_partition. It does nothing after that.
#
# With SPC_GEN_DIR (the build of an application with a udp: channel, decision
# 0024's amendment) it is also the network firmware: it initialises the OCRAM
# ring before the M7 is released, takes its address by DHCP, publishes the
# boot id and sends every message the M7 puts into the ring, verbatim, as one
# UDP datagram (net/README.md). SPC_GEN_DIR holds the build's generated
# spc_net.h and spc_ring_geometry.h; it is read as a sysbuild image variable
# (launcher_SPC_GEN_DIR) or a plain one. The caller also gives the image
# net/net.conf as EXTRA_CONF_FILE and net/net.overlay as
# EXTRA_DTC_OVERLAY_FILE (spinel-core-app build passes them as launcher_...).
cmake_minimum_required(VERSION 3.20.0)
set(DTC_OVERLAY_FILE "${CMAKE_CURRENT_LIST_DIR}/app.overlay;${CMAKE_CURRENT_LIST_DIR}/../zephyr/v4.4.2/boards/frdm_imxrt1186_nor.overlay")
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(spinel_m7_launcher)
target_sources(app PRIVATE src/main.c)
zephyr_get(SPC_GEN_DIR SYSBUILD LOCAL)
if(SPC_GEN_DIR)
  if(NOT CONFIG_NETWORKING)
    message(FATAL_ERROR "SPC_GEN_DIR is given without net/net.conf: pass it as EXTRA_CONF_FILE")
  endif()
  target_sources(app PRIVATE net/ring_init.c net/forward.c)
  target_include_directories(app PRIVATE ${SPC_GEN_DIR} ${CMAKE_CURRENT_LIST_DIR}/..)
  target_compile_definitions(app PRIVATE SPC_NET_FIRMWARE=1)
  # the network code runs from the M33's ITCM: in place from the NOR a
  # datagram's send took 471 us (median), from the ITCM 173 us
  # (tools/doom/net-probe/README.md)
  foreach(lib subsys__net__ip subsys__net subsys__net__l2__ethernet subsys__net__l2__ethernet__dsa drivers__ethernet)
    zephyr_code_relocate(LIBRARY ${lib} LOCATION ITCM_TEXT NOKEEP)
  endforeach()
endif()
