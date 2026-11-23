#!/bin/sh
# tools/doom/net-probe/build.sh -- builds the M33-only UDP sender (README.md).
#
#   sh tools/doom/net-probe/build.sh NETFILE OUT [SECONDS [FPS]]
#
# NETFILE is the network file, outside the repository, in the form
# tools/app/lib/core_app/net.rb reads, with the address taken by DHCP:
#
#   interface swp0
#   address dhcp
#   channel frames 192.0.2.14 5029
#
# Only `interface` and the `channel frames` line are read here; the board's
# address comes from DHCP whatever the file says. OUT/build/zephyr/zephyr.bin is the
# NOR image (the boot header and the XMCD at its start, written at
# 0x14000000). SECONDS (default 12) and FPS (default 35) set the window.
# PROBE_ICACHE=1 builds the variant that enables the code bus cache;
# PROBE_RELOCATE=1 the one whose network code runs from the ITCM.
# Needs ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR and west on PATH (docs/building.md).
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ $# -ge 2 ] || { echo "usage: build.sh NETFILE OUT [SECONDS [FPS]]" >&2; exit 2; }
net=$1; out=$2; seconds=${3:-12}; fps=${4:-35}
[ -f "$net" ] || { echo "build.sh: no network file $net" >&2; exit 1; }
iface=$(awk '$1 == "interface" { print $2 }' "$net")
dest=$(awk '$1 == "channel" && $2 == "frames" { print $3 }' "$net")
port=$(awk '$1 == "channel" && $2 == "frames" { print $4 }' "$net")
case $iface in [a-z]*) ;; *) echo "build.sh: $net names no interface" >&2; exit 1 ;; esac
echo "$dest" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || { echo "build.sh: $net has no 'channel frames ADDR PORT' line with an IPv4 address" >&2; exit 1; }
echo "$port" | grep -Eq '^[0-9]+$' && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { echo "build.sh: the port '$port' is not 1..65535" >&2; exit 1; }
mkdir -p "$out"
cat > "$out/probe_net.h" <<H
/* written by tools/doom/net-probe/build.sh from $(basename "$net") */
#define PROBE_IFACE "$iface"
#define PROBE_DEST_ADDR "$dest"
#define PROBE_DEST_PORT ${port}u
#define PROBE_SRC_PORT ${port}u
#define PROBE_SECONDS ${seconds}u
#define PROBE_FPS ${fps}u
H
west build -p always -b frdm_imxrt1186/mimxrt1186/cm33 "$here" -d "$out/build" -- \
  -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON -DZEPHYR_SDK_INSTALL_DIR="$ZEPHYR_SDK_INSTALL_DIR" -DPROBE_NET_H="$out/probe_net.h" ${PROBE_ICACHE:+-DPROBE_ICACHE=1} ${PROBE_RELOCATE:+-DPROBE_RELOCATE=1 -DCONFIG_CODE_DATA_RELOCATION=y} > "$out/build.log" 2>&1 ||
  { tail -30 "$out/build.log"; exit 1; }
grep -A12 '^Memory region' "$out/build.log"
grep 'Found toolchain' "$out/build.log"
