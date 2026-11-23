#!/bin/sh
# tools/doom/net-ring/build.sh -- builds the network path's test pair and its NOR image (README.md).
#
#   sh tools/doom/net-ring/build.sh NETFILE OUT
#
# NETFILE is the network file (tools/app/lib/core_app/net.rb's form, outside
# the repository) with one `channel frames HOST PORT` line. OUT/m33 is
# tools/app/launcher built as the network firmware (its SPC_GEN_DIR, OUT/gen,
# holds spc_net.h and spc_ring_geometry.h for a channel of 1301 bytes and
# depth 64, as the DOOM board application declares it), OUT/m7 the test
# producer, OUT/nor.bin the NOR image (the M33's at 0, the M7's at its
# CONFIG_FLASH_LOAD_OFFSET, 0xff between). Refused: an image with a section
# in OCRAM2, an M33 image that reaches the M7's code.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../.." && pwd)
[ $# -eq 2 ] || { echo "usage: build.sh NETFILE OUT" >&2; exit 2; }
net=$1; out=$2
mkdir -p "$out/gen"
"${RUBY:-ruby}" -I"$root/tools/app/lib" -rcore_app/app_model -rcore_app/net -e '
  ch = CoreApp::Channel.new(name: "frames", direction: "out", size: 1301, depth: 64, uart: false, udp: true, line: 0)
  app = Struct.new(:path, :channels).new("tools/doom/net-ring (the board application'"'"'s frames channel)", [ch])
  begin
    cfg = CoreApp::Net.read(ARGV[0], app)
  rescue CoreApp::Net::Error => e
    abort "build.sh: #{e.message}"
  end
  File.write(File.join(ARGV[1], "spc_net.h"), CoreApp::Net.launcher_header(cfg, ch))
  File.write(File.join(ARGV[1], "spc_ring_geometry.h"),
    "/* written by tools/doom/net-ring/build.sh: the frames channel, 1301 bytes, depth 64 */\n" \
    "#define SPC_RING_DEPTH 64u\n#define SPC_RING_STRIDE 1312u\n#define SPC_RING_MAX_LEN 1301u\n#define SPC_RING_OFFSET 512u\n#define SPC_RING_INIT_INDEX 0u\n#define SPC_RING_IN_DEPTH 0u\n#define SPC_RING_IN_STRIDE 0u\n#define SPC_RING_IN_MAX_LEN 0u\n#define SPC_RING_IN_OFFSET 0u\n#define SPC_RING_IN_INIT_INDEX 0u\n")
' "$net" "$out/gen"
OBJDUMP=$ZEPHYR_SDK_INSTALL_DIR/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-objdump
build() { # dir source board [cmake args]
  d=$1; src=$2; b=$3; shift 3
  west build -p always -b "$b" "$src" -d "$out/$d" -- -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON \
    -DZEPHYR_SDK_INSTALL_DIR="$ZEPHYR_SDK_INSTALL_DIR" "$@" > "$out/$d.log" 2>&1 || { tail -30 "$out/$d.log"; exit 1; }
  grep -A12 '^Memory region' "$out/$d.log" | grep -E 'FLASH|RAM|ITCM' | sed "s|^|$d: |"
}
build m33 "$root/tools/app/launcher" frdm_imxrt1186/mimxrt1186/cm33 -DSPC_GEN_DIR="$out/gen" \
  -DEXTRA_CONF_FILE="$root/tools/app/launcher/net/net.conf" -DEXTRA_DTC_OVERLAY_FILE="$root/tools/app/launcher/net/net.overlay"
build m7 "$here/m7" frdm_imxrt1186/mimxrt1186/cm7
for d in m33 m7; do
  "$OBJDUMP" -h "$out/$d/zephyr/zephyr.elf" | awk -v d="$d" '
    NR > 5 && $1 ~ /^[0-9]+$/ { vma = strtonum("0x" $4); size = strtonum("0x" $3)
      if (size > 0 && ((vma < 0x20540000 && vma + size > 0x20500000) || (vma < 0x30540000 && vma + size > 0x30500000))) {
        printf "build.sh: %s has section %s at 0x%08x in OCRAM2\n", d, $2, vma; bad = 1 } }
    END { exit bad }' || exit 1
done
off=$(sed -n 's/^CONFIG_FLASH_LOAD_OFFSET=//p' "$out/m7/zephyr/.config")
m33=$(wc -c < "$out/m33/zephyr/zephyr.bin")
[ "$m33" -le $((off)) ] || { echo "build.sh: the M33 image ($m33 B) reaches the M7's code at $off" >&2; exit 1; }
m7=$(wc -c < "$out/m7/zephyr/zephyr.bin")
head -c $((off + m7)) /dev/zero | tr '\000' '\377' > "$out/nor.bin"
dd if="$out/m33/zephyr/zephyr.bin" of="$out/nor.bin" conv=notrunc status=none
dd if="$out/m7/zephyr/zephyr.bin" of="$out/nor.bin" oflag=seek_bytes seek=$((off)) conv=notrunc status=none
echo "nor.bin: m33 $m33 B at 0, m7 $m7 B at $off, sha256 $(sha256sum "$out/nor.bin" | cut -c1-16)"
