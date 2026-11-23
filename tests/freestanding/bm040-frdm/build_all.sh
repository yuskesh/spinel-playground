#!/usr/bin/env bash
# bm040-frdm: bm040 on the NXP FRDM-MCXN947 board -- E040's kernel
# (e040/e040_kern.rb, unchanged) on the bare secure Cortex-M33 (CPU0) of the
# MCX N947, with no RTOS and no vendor SDK. Written here, not ported.
#
# The image is what bm040's is, for this chip: kern.o from spinel-fs-emit with
# bm040's profile (../bm040/cortex-m33-baremetal.yaml), so the object is
# bm040's byte for byte; this lane's startup code, linker script and LPUART
# console (src/); bm040's setjmp/longjmp, header and image-check control
# (../bm040/src/); and compiler-rt's builtins (BAREMETAL_BUILTINS). The driver
# half of src/main.c must equal bm040's but for the BEGIN line's platform name,
# and the build stops if it does not.
#
# Two images, as ELF and as the raw .bin LinkServer writes: bm runs every case
# of e040/mkcases.rb's cases.inc; bm_panic runs only the case that traps, with
# a trap hook that stops. bm_control.elf is never run: it is the control for
# run_gates.sh's checks of what an image contains.
# Writes, in $OUT: gen/ (kern.o, its header and undef table, cases.inc), the
# objects, the images and their link maps; in $RES: toolchain.txt, undef.tsv.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
. "$REPO/tools/doom/sha256.sh"
# bm040's need_baremetal also wants QEMU, which this lane does not run.
if [ -z "${BAREMETAL_BUILTINS:-}" ]; then
  echo "$LANE: set BAREMETAL_BUILTINS to compiler-rt's libclang_rt.builtins-armv8m.main.a (docs/toolchains/compiler-rt-23.1.1)" >&2
  exit 2
fi
[ -f "$BAREMETAL_BUILTINS" ] || { echo "$LANE: no file at BAREMETAL_BUILTINS=$BAREMETAL_BUILTINS" >&2; exit 2; }
BM040=$HERE/../bm040
PROF=$BM040/cortex-m33-baremetal.yaml
E040=$HERE/../e040
OBJCOPY=$LLVM_PREFIX/bin/llvm-objcopy

fs_fresh_workdir "$OUT"
mkdir -p "$OUT/gen" "$OUT/spinel" "$RES"
cp "$FSDIR/spinel/freestanding.rb" "$OUT/spinel/"
cp "$E040/e040_kern.rb" "$OUT/"

echo "== the driver is bm040's =="
driver() {  # $1 = main.c -> its driver half, the BEGIN line's platform name masked
  sed -n '/^\/\* ---- the trap hook and the driver/,$p' "$1" |
    sed 's|^\(	bm_puts("E040\\tBEGIN\\t\)[^\\]*|\1PLATFORM|'
}
driver "$BM040/src/main.c" > "$OUT/driver.bm040.c"
driver "$HERE/src/main.c" > "$OUT/driver.frdm.c"
[ -s "$OUT/driver.frdm.c" ] && cmp "$OUT/driver.bm040.c" "$OUT/driver.frdm.c" || {
  diff "$OUT/driver.bm040.c" "$OUT/driver.frdm.c" >&2 || true
  echo "src/main.c's driver half differs from bm040's" >&2; exit 1; }
echo "identical but for the BEGIN line's platform name"

echo "== toolchain =="
{
  "$CLANG" --version | head -1
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
        -I "$OUT/gen" -I "$BM040/src")
"$CLANG" "${CFLAGS[@]}" -c "$HERE/src/start.c" -o "$OUT/start.o"
"$CLANG" "${CFLAGS[@]}" -c "$BM040/src/setjmp.S" -o "$OUT/setjmp.o"
"$CLANG" "${CFLAGS[@]}" -c "$HERE/src/main.c" -o "$OUT/main.o"
"$CLANG" "${CFLAGS[@]}" -DBM040_PANIC_TRAP=1 -c "$HERE/src/main.c" -o "$OUT/main_panic.o"
"$CLANG" "${CFLAGS[@]}" -c "$BM040/src/control.c" -o "$OUT/control.o"
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
for img in bm bm_panic; do
  "$OBJCOPY" -O binary "$OUT/$img.elf" "$OUT/$img.bin"
done
echo "build_all: done"
