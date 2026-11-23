#!/bin/sh
#
# tests/zephyr-full/run.sh -- full, the hosted runtime with its collector, on
# Zephyr's POSIX layer for the FRDM-MCXN947 (decision 0038): the build half.
#
#   sh tests/zephyr-full/run.sh
#
# Needs ZEPHYR_BASE (Zephyr v4.4.2), ZEPHYR_SDK_INSTALL_DIR (SDK 1.0.1), west
# on PATH and vendor/spinel built (docs/building.md). The board half is a
# manual run through tests/zephyr-full/check-log.rb (tools/zephyr-full/README.md);
# nothing here needs the board.
#
# 1. every program builds into a Zephyr image: basics, float, gc and oom
#    (oom with a 64 KB heap) from spinel-modular's tests/bare-full/programs (the submodule
#    vendor/spinel-modular), sleep, tcp and
#    marshal from programs/ here;
# 2. no image links Zephyr's own fdopen or fileno; a call to either reaches
#    picolibc's (renamed and reached through --wrap), and tcp's socket stream
#    does;
# 3. in each, src/host.c's constructor runs first, so the GC settings are in
#    the environment before the runtime's constructors read them;
# 4. each has picolibc's floating-point printf and is not a user-mode build,
#    and its image names neither this checkout nor the work directory;
# 5. basics also builds with --userspace, with the runtime's globals in
#    sp_partition (decision 0038 records that this build faults at run time);
# 6. check-log.rb accepts a capture made from an expected output, and
#    rejects one with a changed line, one with another exit status and one
#    with a fault report;
# 7. controls: the checks of 2, 3 and 4 must reject a planted input each
#    (an nm listing with Zephyr's fdopen, a map without the host constructor,
#    an image with this checkout's path appended).
#
# Exit 0 when everything passed, 1 on any failure, 2 when skipped. Nothing
# here runs another implementation.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$REPO/tests/zephyr-full"
BARE="$REPO/vendor/spinel-modular/tests/bare-full/programs"
DRIVER="$REPO/tools/zephyr-full/spinel-zephyr-full"
RUBY="${RUBY:-ruby}"
# a documentation address (RFC 5737): the build only carries it
PEER=192.0.2.1:7777

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS  $1"; }
ng() { fail=$((fail + 1)); echo "FAIL  $1"; }

for v in ZEPHYR_BASE ZEPHYR_SDK_INSTALL_DIR; do
  eval "val=\${$v:-}"
  if [ -z "$val" ]; then
    echo "SKIP  zephyr-full: $v is not set"
    exit 2
  fi
done
if ! command -v west >/dev/null 2>&1; then
  echo "SKIP  zephyr-full: west is not on PATH"
  exit 2
fi
if [ ! -x "$REPO/vendor/spinel/bin/spinel" ]; then
  echo "SKIP  zephyr-full: vendor/spinel is not built"
  exit 2
fi
NM="$ZEPHYR_SDK_INSTALL_DIR/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-nm"

T=$(mktemp -d "${TMPDIR:-/tmp}/zephyr-full-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

# wrap_ok NMLIST: no plain fdopen or fileno (Zephyr's) is linked, and each
# wrapper that is linked comes with picolibc's function behind it; a program
# that opens no stream links neither
wrap_ok() {
  ! grep -Eq ' [TtWw] (fdopen|fileno)$' "$1" || return 1
  for s in fdopen fileno; do
    if grep -Eq " [Tt] __wrap_$s\$" "$1"; then grep -Eq " [Tt] sp_picolibc_$s\$" "$1" || return 1; fi
  done
}
# uses_wrap NMLIST: the program's streams do go through picolibc's fdopen
uses_wrap() {
  grep -Eq ' [Tt] __wrap_fdopen$' "$1" && grep -Eq ' [Tt] sp_picolibc_fdopen$' "$1"
}
# ctor_ok MAP: the first constructor after __zephyr_init_array_start is host.c's
ctor_ok() {
  awk '/__zephyr_init_array_start = \./ { f = 1; next }
       f && /\.obj\)/ { print; exit }' "$1" | grep -q 'libapp\.a(host\.c\.obj)'
}
# clean_ok IMAGE: no path of this checkout or of the work directory
clean_ok() {
  ! grep -aqF "$REPO" "$1" && ! grep -aqF "$T" "$1"
}

# build NAME SOURCE [DRIVER OPTIONS...]: one image in $T/NAME
build() {
  n=$1; src=$2; shift 2
  "$RUBY" "$DRIVER" build "$@" "$src" "$T/$n" > "$T/$n.driver.log" 2>&1
}

# 1-4: the seven programs
for row in "basics $BARE/basics.rb" "float $BARE/float.rb" "gc $BARE/gc.rb" \
           "oom $BARE/oom.rb --heap 65536" "sleep $HERE/programs/sleep.rb" \
           "tcp $HERE/programs/tcp.rb --peer $PEER" "marshal $HERE/programs/marshal.rb"; do
  set -- $row
  n=$1
  if ! build "$@"; then
    tail -5 "$T/$n.driver.log"
    ng "$n: builds a Zephyr image"
    continue
  fi
  ok "$n: builds a Zephyr image ($(grep -E '^ *FLASH:' "$T/$n/build.log" | awk '{print $2}') B flash)"
  b="$T/$n/build/zephyr"
  "$NM" "$b/zephyr.elf" > "$T/$n.nm"
  if wrap_ok "$T/$n.nm"; then ok "$n: Zephyr's fdopen and fileno are not linked"; else ng "$n: Zephyr's fdopen and fileno are not linked"; fi
  if [ "$n" = tcp ]; then
    if uses_wrap "$T/$n.nm"; then ok "tcp: the socket's stream comes from picolibc's fdopen"; else ng "tcp: the socket's stream comes from picolibc's fdopen"; fi
  fi
  if ctor_ok "$b/zephyr.map"; then ok "$n: the host constructor runs first"; else ng "$n: the host constructor runs first"; fi
  if grep -qx 'CONFIG_PICOLIBC_IO_FLOAT=y' "$b/.config" && grep -qx '# CONFIG_USERSPACE is not set' "$b/.config"; then
    ok "$n: floating-point printf, supervisor build"
  else
    ng "$n: floating-point printf, supervisor build"
  fi
  if clean_ok "$T/$n/zephyr.bin"; then ok "$n: the image names no local path"; else ng "$n: the image names no local path"; fi
done

# 5: the user-mode build
if build basics-us "$BARE/basics.rb" --userspace; then
  b="$T/basics-us/build/zephyr"
  "$NM" "$b/zephyr.elf" > "$T/basics-us.nm"
  if grep -qx 'CONFIG_USERSPACE=y' "$b/.config" && grep -q ' z_data_smem_sp_partition_part_start$' "$T/basics-us.nm" &&
     grep -q ' sp_gc_stat_collections$' "$T/basics-us.nm"; then
    sa=$(sed -n 's/^\([0-9a-f]*\) [A-Za-z] z_data_smem_sp_partition_part_start$/\1/p' "$T/basics-us.nm")
    se=$(sed -n 's/^\([0-9a-f]*\) [A-Za-z] z_data_smem_sp_partition_part_end$/\1/p' "$T/basics-us.nm")
    g=$(sed -n 's/^\([0-9a-f]*\) [A-Za-z] sp_gc_stat_collections$/\1/p' "$T/basics-us.nm")
    if [ -n "$sa" ] && [ -n "$se" ] && [ "$((0x$g >= 0x$sa && 0x$g < 0x$se))" = 1 ]; then
      ok "basics --userspace: builds, the runtime's globals in sp_partition"
    else
      ng "basics --userspace: builds, the runtime's globals in sp_partition"
    fi
  else
    ng "basics --userspace: builds, the runtime's globals in sp_partition"
  fi
else
  tail -5 "$T/basics-us.driver.log"
  ng "basics --userspace: builds, the runtime's globals in sp_partition"
fi

# 6: the board-log check, on captures written here
CL="$HERE/check-log.rb"
{ printf '*** Booting Zephyr OS build v4.4.2 ***\r\nZFULL\tBEGIN\r\nZFULL\tNET\tup\r\nZFULL\tMODE\tsupervisor\r\n'
  sed 's/$/\r/' "$HERE/programs/tcp.out"
  printf 'ZFULL\tGC\t0\r\nZFULL\tEXIT\t0\r\n'; } > "$T/good.log"
sed 's/^closed/opened/' "$T/good.log" > "$T/line.log"
sed 's/^ZFULL\tEXIT\t0/ZFULL\tEXIT\t1/' "$T/good.log" > "$T/status.log"
{ printf '*** Booting Zephyr OS build v4.4.2 ***\r\nZFULL\tBEGIN\r\nZFULL\tNET\tup\r\nZFULL\tMODE\tuser\t0\t3\r\n'
  printf '***** MPU FAULT *****\r\n'
  sed 's/$/\r/' "$HERE/programs/tcp.out"
  printf 'ZFULL\tGC\t0\r\nZFULL\tEXIT\t0\r\n'; } > "$T/fault.log"
if "$RUBY" "$CL" "$T/good.log" "$HERE/programs/tcp.out" >/dev/null; then ok "check-log: a capture of the expected output matches"; else ng "check-log: a capture of the expected output matches"; fi
for c in line status fault; do
  if "$RUBY" "$CL" "$T/$c.log" "$HERE/programs/tcp.out" >/dev/null; then
    ng "check-log: rejects a capture with a planted $c change"
  else
    ok "check-log: rejects a capture with a planted $c change"
  fi
done

# 7: controls for 2, 3 and 4, on inputs planted from the basics build
if [ -f "$T/basics.nm" ]; then
  { cat "$T/basics.nm"; echo "10000000 T fdopen"; } > "$T/planted.nm"
  if wrap_ok "$T/planted.nm"; then ng "control: the wrap check rejects Zephyr's fdopen"; else ok "control: the wrap check rejects Zephyr's fdopen"; fi
  grep -v 'libapp\.a(host\.c\.obj)' "$T/basics/build/zephyr/zephyr.map" > "$T/planted.map"
  if ctor_ok "$T/planted.map"; then ng "control: the constructor check rejects a map without host.c's"; else ok "control: the constructor check rejects a map without host.c's"; fi
  { cat "$T/basics/zephyr.bin"; printf '%s' "$REPO"; } > "$T/planted.bin"
  if clean_ok "$T/planted.bin"; then ng "control: the path check rejects this checkout's path"; else ok "control: the path check rejects this checkout's path"; fi
else
  ng "control: no basics build to plant from"
fi

echo "zephyr-full: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
