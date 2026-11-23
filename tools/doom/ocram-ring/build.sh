#!/bin/sh
# tools/doom/ocram-ring/build.sh -- builds the ring test's pair and its NOR image (README.md).
#
#   sh tools/doom/ocram-ring/build.sh OUT [PLANT]
#
# OUT/m33 and OUT/m7 are the two Zephyr builds, OUT/nor.bin the NOR image:
# the M33's zephyr.bin (with the boot header and the XMCD) at 0, the M7's at
# its CONFIG_FLASH_LOAD_OFFSET (m7_code_partition), every other byte 0xff.
# PLANT=1 builds the M7 as the kept failing input (head before the slot).
# Refused, naming the cause: an image with a section in OCRAM2 (either core's
# view, either security alias), and an M33 image that reaches the M7's code.
# Needs ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR and west on PATH (docs/building.md).
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ $# -ge 1 ] || { echo "usage: build.sh OUT [PLANT]" >&2; exit 2; }
out=$1; plant=${2:-0}
mkdir -p "$out"
OBJDUMP=$ZEPHYR_SDK_INSTALL_DIR/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-objdump
build() { # dir board [cmake args]
  d=$1; b=$2; shift 2
  west build -p always -b "$b" "$here/$d" -d "$out/$d" -- -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON \
    -DZEPHYR_SDK_INSTALL_DIR="$ZEPHYR_SDK_INSTALL_DIR" "$@" > "$out/$d.log" 2>&1 || { tail -30 "$out/$d.log"; exit 1; }
  grep -A12 '^Memory region' "$out/$d.log" | sed "s|^|$d: |"
}
build m33 frdm_imxrt1186/mimxrt1186/cm33
if [ "$plant" = 1 ]; then build m7 frdm_imxrt1186/mimxrt1186/cm7 -DSPC_RING_PLANT_EARLY_HEAD=1
else build m7 frdm_imxrt1186/mimxrt1186/cm7; fi
# no section of either image in OCRAM2: 0x2050_0000 and 0x3050_0000 (256 KB
# each), the M7's and the M33's views
for d in m33 m7; do
  "$OBJDUMP" -h "$out/$d/zephyr/zephyr.elf" | awk -v d="$d" '
    NR > 5 && $1 ~ /^[0-9]+$/ { vma = strtonum("0x" $4); size = strtonum("0x" $3)
      if (size > 0 && ((vma < 0x20540000 && vma + size > 0x20500000) || (vma < 0x30540000 && vma + size > 0x30500000))) {
        printf "build.sh: %s has section %s at 0x%08x in OCRAM2\n", d, $2, vma; bad = 1 } }
    END { exit bad }' || exit 1
done
echo "no section of either image in OCRAM2"
off=$(sed -n 's/^CONFIG_FLASH_LOAD_OFFSET=//p' "$out/m7/zephyr/.config")
m33=$(wc -c < "$out/m33/zephyr/zephyr.bin")
[ "$m33" -le $((off)) ] || { echo "build.sh: the M33 image ($m33 B) reaches the M7's code at $off" >&2; exit 1; }
m7=$(wc -c < "$out/m7/zephyr/zephyr.bin")
total=$((off + m7))
# 0xff everywhere, then each image at its offset
head -c "$total" /dev/zero | tr '\000' '\377' > "$out/nor.bin"
dd if="$out/m33/zephyr/zephyr.bin" of="$out/nor.bin" conv=notrunc status=none
dd if="$out/m7/zephyr/zephyr.bin" of="$out/nor.bin" bs=1 seek=$((off)) conv=notrunc status=none 2>/dev/null ||
  dd if="$out/m7/zephyr/zephyr.bin" of="$out/nor.bin" oflag=seek_bytes seek=$((off)) conv=notrunc status=none
echo "nor.bin: m33 $m33 B at 0, m7 $m7 B at $off, $(wc -c < "$out/nor.bin") B, sha256 $(sha256sum "$out/nor.bin" | cut -c1-16)"
