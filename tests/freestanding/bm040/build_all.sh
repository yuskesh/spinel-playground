#!/usr/bin/env bash
# bm040: E040's kernel (e040/e040_kern.rb, unchanged) on the bare Cortex-M33 of
# QEMU's mps2-an521, with no RTOS. Written here, not ported.
#
# The image is three things and nothing else: kern.o from spinel-fs-emit (its
# undef gate run against cortex-m33-baremetal.yaml), this lane's driver
# (src/: startup, linker script, UART console, setjmp/longjmp), and
# compiler-rt's builtins (BAREMETAL_BUILTINS). No libc, no Zephyr: the driver is
# compiled -ffreestanding and linked -nostdlib.
#
# Two images: bm.elf runs every case of e040/mkcases.rb's cases.inc;
# bm_panic.elf runs only the case that traps, with a trap hook that stops.
# bm_control.elf is never run: it is the control for run_gates.sh's checks of
# what an image contains (src/control.c).
# Writes, in $OUT: gen/ (kern.o, its header and undef table, cases.inc), the
# objects, both images and their link maps; in $RES: toolchain.txt, undef.tsv.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
. "$REPO/tools/doom/sha256.sh"
need_baremetal
PROF=$HERE/cortex-m33-baremetal.yaml
E040=$HERE/../e040

fs_fresh_workdir "$OUT"
mkdir -p "$OUT/gen" "$OUT/spinel" "$RES"
cp "$FSDIR/spinel/freestanding.rb" "$OUT/spinel/"
cp "$E040/e040_kern.rb" "$OUT/"
cmp "$OUT/e040_kern.rb" "$E040/e040_kern.rb"

echo "== toolchain =="
{
  "$CLANG" --version | head -1
  "$QEMU_ARM" --version | head -1
  echo "builtins $BAREMETAL_BUILTINS"
  echo "builtins sha256 $(sp_sha256 "$BAREMETAL_BUILTINS")"
} 2>&1 | tee "$RES/toolchain.txt"

echo "== mkcases =="
ruby "$E040/mkcases.rb" "$OUT/gen"

echo "== spinel-fs-emit --freestanding --profile cortex-m33-baremetal =="
(cd "$OUT" && "$MLIRGEN" e040_kern.rb --freestanding --profile "$PROF" \
    -o gen/kern.o --emit-header gen/spinel_freestanding.h \
    --emit-undef-tsv gen/undef.tsv 2>&1 | tail -2)
[ -f "$OUT/gen/kern.o" ] || { echo "no kernel object" >&2; exit 1; }
cp "$OUT/gen/undef.tsv" "$RES/undef.tsv"

echo "== driver and link =="
CFLAGS=(--target=thumbv8m.main-none-eabi -mcpu=cortex-m33+nodsp -mfloat-abi=soft
        -mthumb -ffreestanding -fno-builtin -nostdlib -Os -Wall -Wextra -Werror
        -I "$OUT/gen" -I "$HERE/src")
"$CLANG" "${CFLAGS[@]}" -c "$HERE/src/start.c" -o "$OUT/start.o"
"$CLANG" "${CFLAGS[@]}" -c "$HERE/src/setjmp.S" -o "$OUT/setjmp.o"
"$CLANG" "${CFLAGS[@]}" -c "$HERE/src/main.c" -o "$OUT/main.o"
"$CLANG" "${CFLAGS[@]}" -DBM040_PANIC_TRAP=1 -c "$HERE/src/main.c" -o "$OUT/main_panic.o"
"$CLANG" "${CFLAGS[@]}" -c "$HERE/src/control.c" -o "$OUT/control.o"
link() {  # $1 = image, $2 = driver object, $3... = extra link arguments
  local img=$1 drv=$2; shift 2
  "$CLANG" "${CFLAGS[@]}" -static -fuse-ld=lld -Wl,-T,"$HERE/src/link.ld" \
      -Wl,-Map,"$OUT/$img.map" -o "$OUT/$img.elf" \
      "$OUT/start.o" "$OUT/setjmp.o" "$OUT/$drv" "$OUT/gen/kern.o" "$@" "$BAREMETAL_BUILTINS"
  echo "linked $img.elf"
}
link bm main.o
link bm_panic main_panic.o
# The control for run_gates.sh's image checks; it is never run.
link bm_control main.o "$OUT/control.o" -Wl,--unresolved-symbols=ignore-all
echo "build_all: done"
