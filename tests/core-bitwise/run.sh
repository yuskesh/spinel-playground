#!/bin/sh
#
# tests/core-bitwise/run.sh -- decision 0042: `&`, `|`, `^` and `~` (stage 1)
# on the freestanding route, `<<` and `>>` under S1 (stage 2), `abs` and `**`
# (stage 3), and the named wrapping and unsigned forms with decision 0022's
# intrinsics (stage 4), on the freestanding route and the status lane. (The
# native `--core` route's cases are in tests/native-core/arith.sh, beside the
# rest of its arithmetic.)
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/core-bitwise/run.sh
#
# 1. Freestanding, a 64-bit body. fs/k.rb is compiled by spinel-fs-emit for
#    the x86_64 Linux host profile. Linked with fs/drive.c it must print
#    fs/expect.txt; linked with fs/shifts.c, its `trap` shifts must give the
#    `checked` column of shifts.tsv and its `wrap` shifts the `wrap` column;
#    linked with fs/powers.c, its `abs` and `**` must do the same for
#    powers.tsv; linked with fs/words.c, its intrinsics must give the 64-bit
#    rows of words.tsv (`fail` is the trap hook with code 8), and its checksum
#    steps the published check values of FNV-1a 32 and 64 and CRC-32.
# 2. Freestanding, a 32-bit body: the same for fs32/k.rb on the wasm32
#    profile, linked with wasm-ld and run under node (fs32/run.mjs,
#    fs32/shifts.mjs, fs32/powers.mjs, fs32/words.mjs), without FNV-1a 64.
# 3. The status lane, a 64-bit body: status/src/shifts.rb's `shl` and `shr`
#    built by spinel-core-kernel for this host and run by status/drive.c,
#    which must give the `checked` column, and status/src/powers.rb's
#    kernels run by status/powers.c, which must give powers.tsv's. A failed
#    row is ARITHMETIC with the result word untouched; the status ABI has one
#    code for an overflow and a negative exponent alike. status/src/words.rb's
#    kernels, run by status/words.c, must give words.tsv's 64-bit rows (but
#    `w32_add_w`, a freestanding declaration) and the published checksums.
# 4. The status lane, a 32-bit body: the same kernels built for wasm32 at
#    `--int-width=32` and run under node by status/run.mjs,
#    status/powers.mjs and status/words.mjs.
# 5. Refusals, each with the words its row names: on freestanding, boolean
#    operands, a Float operand of `&` and of `>>`, `<<` and `**` on a buffer,
#    and a reopened Integer; on the status lane, `<<` on an Array local and a
#    reopened Integer#<< and Integer#**. Stage 4's: on freestanding, a `w64`
#    form on the wasm32 profile's 32-bit body, `core_u32` of a parameter and
#    of 4294967296, a receiver, a wrong arity, a block and an unused top-level
#    definition of an intrinsic's name; on the status lane, a `w64` form at
#    `--int-width=32` and `core_u32` of a parameter and of 4294967296.
# 6. The report: the status kernel of `a ** n`, built with `--report`, has
#    no loop (decision 0010's report counts loops, and `**` lowers without
#    one).
# 7. Controls, each with an input it plants: a changed expected line and a
#    changed row of each table (words.tsv too) are reported as differences,
#    and a refusal checked against another row's words fails.
# 8. A required file: req/main.rb names no intrinsic, and the helper it
#    requires (req/helper.rb) calls one; it compiles for the cortex-m33
#    profile (no link), since the prelude is picked from every file the
#    analysis reads.
# 9. Lines: the prelude goes before the program, after the source's leading
#    comment lines. lines/lines.rb, which has comment lines and calls an
#    intrinsic, is compiled with --emit-mlir, and the module's locations are
#    the file's own lines and columns, written by hand.
#
# The expected values were written by hand from Ruby's rules; no other
# implementation is run.
#
# Needs the native build (SPINEL_CORE_BUILD, default tools/mlir/native/build)
# and the reader (SPINEL_TYPEDUMP, default tools/contract/build/spinel-typedump),
# each held to this tree by its source stamp, and LLVM_PREFIX (or CLANG) for
# the official LLVM 23.1.1. Part 1 runs on x86_64 Linux only. Parts 2 and 4
# need wasm-ld (WASM_LD, default $LLVM_PREFIX/bin/wasm-ld) and node (NODE);
# where either cannot run, they are named skips. Part 6 reads the report
# with ruby.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE=$ROOT/tests/core-bitwise
BIN=${SPINEL_CORE_BUILD:-$ROOT/tools/mlir/native/build}/bin
EMIT=$BIN/spinel-fs-emit
KERNEL=$BIN/spinel-core-kernel
READER=${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}
PROFILES=$ROOT/tools/freestanding/profiles
TABLE=$HERE/shifts.tsv
POWERS=$HERE/powers.tsv
WORDS=$HERE/words.tsv

die() { echo "core-bitwise: $*" >&2; exit 2; }
[ -x "$EMIT" ] || die "no spinel-fs-emit at $EMIT (tools/mlir/native/build.sh)"
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL (tools/mlir/native/build.sh)"
[ -x "$READER" ] || die "no reader at $READER (tools/contract/build.sh)"
[ -f "$TABLE" ] || die "no shift table at $TABLE"
[ -f "$POWERS" ] || die "no power table at $POWERS"
[ -f "$WORDS" ] || die "no word table at $WORDS"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
LLVM_BIN=$(dirname "$CC_BIN")
WASM_LD_BIN=${WASM_LD:-$LLVM_BIN/wasm-ld}
NM_BIN=${NM:-$LLVM_BIN/llvm-nm}
NODE_BIN=${NODE:-node}
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$EMIT"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"

T=$(mktemp -d "${TMPDIR:-/tmp}/core-bitwise.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0; skip=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
skipped() { echo "  SKIP $1"; skip=$((skip + 1)); }
# same EXPECTED GOT: `same` when the files are equal, else the first difference
same() { if cmp -s "$1" "$2"; then echo same; else diff "$1" "$2" | sed -n 2p; fi; }

# rows WIDTH [TABLE]: the rows at WIDTH as "op a n", of shifts.tsv by default
rows() { awk -F'\t' -v w="$1" '!/^#/ && NF == 6 && $1 == w { print $2, $3, $4 }' "${2:-$TABLE}"; }
# want WIDTH COLUMN TABLE: the answers "op a n r" at WIDTH, COLUMN 5 (checked)
# or 6 (wrap)
want() { awk -F'\t' -v w="$1" -v c="$2" '!/^#/ && NF == 6 && $1 == w { print $2, $3, $4, $c }' "$3"; }
# shift_check LABEL WIDTH COLUMN OUT: OUT against the table
shift_check() {
  want "$2" "$3" "$TABLE" > "$T/want-$2-$3"
  ok "$1 ($(grep -c . "$T/want-$2-$3") rows)" "$(same "$T/want-$2-$3" "$4")" same
}
# power_check LABEL WIDTH COLUMN OUT [status]: OUT against powers.tsv. With
# `status`, a `negative` answer is read as `fail`: the status ABI reports both
# as ARITHMETIC.
power_check() {
  want "$2" "$3" "$POWERS" |
    if [ "${5:-}" = status ]; then sed 's/ negative$/ fail/'; else cat; fi > "$T/pwant-$2-$3"
  ok "$1 ($(grep -c . "$T/pwant-$2-$3") rows)" "$(same "$T/pwant-$2-$3" "$4")" same
}
# The status kernels of status/src/powers.rb, one per method.
POWER_KERNELS="ab pw pk0 pk1 pk2 pk31 pk63"

# words.tsv's rows: wrows WIDTH [FILTER] prints "op a b", wwant WIDTH [FILTER]
# "op a b answer". FILTER `status` leaves out `w32_add_w`, which only a
# freestanding declaration has.
wrows() { awk -F'\t' -v w="$1" -v f="${2:-}" '!/^#/ && NF == 5 && $1 == w && !(f == "status" && $2 == "w32_add_w") { print $2, $3, $4 }' "$WORDS"; }
wwant() { awk -F'\t' -v w="$1" -v f="${2:-}" '!/^#/ && NF == 5 && $1 == w && !(f == "status" && $2 == "w32_add_w") { print $2, $3, $4, $5 }' "${3:-$WORDS}"; }
# word_check LABEL WIDTH OUT [FILTER]
word_check() {
  wwant "$2" "${4:-}" > "$T/wwant-$2-${4:-fs}"
  ok "$1 ($(grep -c . "$T/wwant-$2-${4:-fs}") rows)" "$(same "$T/wwant-$2-${4:-fs}" "$3")" same
}
# The published check values: FNV-1a 32 of "a" 0xe40c292c and of "foobar"
# 0xbf9cf968, FNV-1a 64 of "a" 0xaf63dc4c8601ec8c and of "foobar"
# 0x85944171f73967e8, and CRC-32 of "123456789" 0xcbf43926, each read as
# signed. FNV-1a 64 is at 64 bits only.
checksums_want() {
  echo "fnv32 a -468965076"
  [ "$1" = 64 ] && echo "fnv64 a -5808556873153909620"
  echo "fnv32 foobar -1080231576"
  [ "$1" = 64 ] && echo "fnv64 foobar -8821353812377114648"
  echo "crc32 123456789 -873187034"
}
# checksum_check LABEL WIDTH OUT
checksum_check() {
  checksums_want "$2" > "$T/cwant-$2"
  ok "$1" "$(same "$T/cwant-$2" "$3")" same
}
# The status kernels of status/src/words.rb, one per method.
WORD_KERNELS32="w_w32_add w_w32_sub w_w32_mul w_w32_neg w_w32_shl w_u32_lt w_u32_le w_u32_gt w_u32_ge w_u32_shr w_fixed_mul w_fixed_div w_u32lit fnv32_seed fnv32_step crc32_step"
WORD_KERNELS64="$WORD_KERNELS32 w_w64_add w_w64_sub w_w64_mul w_w64_neg w_w64_shl w_u64_lt w_u64_le w_u64_gt w_u64_ge w_u64_shr fnv64_step"

mkdir -p "$T/fs/spinel"
cp "$ROOT/tools/freestanding/spinel/freestanding.rb" "$T/fs/spinel/"
# emit FILE PROFILE: compiles a copy as $T/fs/k.rb; prints the exit status,
# stderr in $T/fs/err
emit() {
  cp "$1" "$T/fs/k.rb" || return 2
  (cd "$T/fs" && "$EMIT" k.rb --freestanding --profile "$PROFILES/$2.yaml" \
     --typedump "$READER" -o k.o --emit-header k.h) > "$T/fs/err" 2>&1
  echo $?
}
wasm_ready=0
if ! "$WASM_LD_BIN" --version > "$T/wasm-ld.err" 2>&1; then
  wasm_why="wasm-ld at $WASM_LD_BIN does not run ($(head -1 "$T/wasm-ld.err"))"
elif ! "$NODE_BIN" --version > /dev/null 2>&1; then
  wasm_why="no node ($NODE_BIN)"
else
  wasm_ready=1
fi

echo "== 1. freestanding, a 64-bit body (x86_64 host profile) =="
if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; then
  ok "fs/k.rb compiles" "$(emit "$HERE/fs/k.rb" x86_64-linux-host)" 0
  if "$CC_BIN" -I"$T/fs" "$HERE/fs/drive.c" "$T/fs/k.o" -o "$T/fs/drive" > "$T/fs/link.err" 2>&1 &&
     "$CC_BIN" -I"$T/fs" "$HERE/fs/shifts.c" "$T/fs/k.o" -o "$T/fs/shifts" >> "$T/fs/link.err" 2>&1 &&
     "$CC_BIN" -I"$T/fs" "$HERE/fs/powers.c" "$T/fs/k.o" -o "$T/fs/powers" >> "$T/fs/link.err" 2>&1 &&
     "$CC_BIN" -I"$T/fs" "$HERE/fs/words.c" "$T/fs/k.o" -o "$T/fs/words" >> "$T/fs/link.err" 2>&1; then
    "$T/fs/drive" > "$T/out64" 2>&1
    ok "the calls give fs/expect.txt" "$(same "$HERE/fs/expect.txt" "$T/out64")" same
    rows 64 | "$T/fs/shifts" trap > "$T/fs64-trap" 2>&1
    shift_check "trap shifts give the checked column" 64 5 "$T/fs64-trap"
    rows 64 | "$T/fs/shifts" wrap > "$T/fs64-wrap" 2>&1
    shift_check "wrap shifts give the wrap column" 64 6 "$T/fs64-wrap"
    rows 64 "$POWERS" | "$T/fs/powers" trap > "$T/fs64-ptrap" 2>&1
    power_check "trap abs and ** give the checked column" 64 5 "$T/fs64-ptrap"
    rows 64 "$POWERS" | "$T/fs/powers" wrap > "$T/fs64-pwrap" 2>&1
    power_check "wrap abs and ** give the wrap column" 64 6 "$T/fs64-pwrap"
    wrows 64 | "$T/fs/words" words > "$T/fs64-words" 2>&1
    word_check "the intrinsics give words.tsv" 64 "$T/fs64-words"
    "$T/fs/words" checksums > "$T/fs64-sums" 2>&1
    checksum_check "the checksum steps give the published values" 64 "$T/fs64-sums"
  else
    echo "  FAIL fs/k.rb does not link with fs/drive.c, fs/shifts.c, fs/powers.c and fs/words.c"
    sed 's/^/      /' "$T/fs/link.err" | head -4
    fail=$((fail + 1))
  fi
else
  skipped "the 64-bit freestanding values: the x86_64 Linux host profile does not run on $(uname -s) $(uname -m)"
fi

echo "== 2. freestanding, a 32-bit body (wasm32 profile, under node) =="
if [ "$wasm_ready" = 0 ]; then
  skipped "the 32-bit freestanding values: $wasm_why"
else
  ok "fs32/k.rb compiles" "$(emit "$HERE/fs32/k.rb" wasm32-worker)" 0
  exports=$("$NM_BIN" --defined-only --extern-only "$T/fs/k.o" 2>/dev/null |
            awk '{printf " --export=%s", $3}')
  # shellcheck disable=SC2086 # one word per export
  if [ -n "$exports" ] &&
     "$WASM_LD_BIN" --no-entry --allow-undefined $exports "$T/fs/k.o" \
       -o "$T/fs/k.wasm" > "$T/fs/link.err" 2>&1; then
    "$NODE_BIN" "$HERE/fs32/run.mjs" "$T/fs/k.wasm" > "$T/out32" 2>&1
    ok "the calls give fs32/expect.txt" "$(same "$HERE/fs32/expect.txt" "$T/out32")" same
    rows 32 | "$NODE_BIN" "$HERE/fs32/shifts.mjs" "$T/fs/k.wasm" trap > "$T/fs32-trap" 2>&1
    shift_check "trap shifts give the checked column" 32 5 "$T/fs32-trap"
    rows 32 | "$NODE_BIN" "$HERE/fs32/shifts.mjs" "$T/fs/k.wasm" wrap > "$T/fs32-wrap" 2>&1
    shift_check "wrap shifts give the wrap column" 32 6 "$T/fs32-wrap"
    rows 32 "$POWERS" | "$NODE_BIN" "$HERE/fs32/powers.mjs" "$T/fs/k.wasm" trap > "$T/fs32-ptrap" 2>&1
    power_check "trap abs and ** give the checked column" 32 5 "$T/fs32-ptrap"
    rows 32 "$POWERS" | "$NODE_BIN" "$HERE/fs32/powers.mjs" "$T/fs/k.wasm" wrap > "$T/fs32-pwrap" 2>&1
    power_check "wrap abs and ** give the wrap column" 32 6 "$T/fs32-pwrap"
    wrows 32 | "$NODE_BIN" "$HERE/fs32/words.mjs" "$T/fs/k.wasm" words > "$T/fs32-words" 2>&1
    word_check "the intrinsics give words.tsv" 32 "$T/fs32-words"
    "$NODE_BIN" "$HERE/fs32/words.mjs" "$T/fs/k.wasm" checksums > "$T/fs32-sums" 2>&1
    checksum_check "the checksum steps give the published values" 32 "$T/fs32-sums"
  else
    echo "  FAIL fs32/k.rb does not link with wasm-ld"; sed 's/^/      /' "$T/fs/link.err" | head -4
    fail=$((fail + 1))
  fi
fi

# kernel WIDTH SRC ENTRY DIR [CLANG ARGS...]: the status kernel of ENTRY in
# status/src/SRC.rb at WIDTH, as DIR/ENTRY.o and DIR/ENTRY.h; the tool's
# output in DIR/ENTRY.out. A 32-bit body has an i32 boundary (decision 0019).
kernel() {
  k_t=i64; [ "$1" = 32 ] && k_t=i32
  k_w=$1 k_src=$2 k_entry=$3 k_dir=$4; shift 4
  mkdir -p "$k_dir"
  printf 'core-contract 1\nroot src/%s.rb\nentry %s\nresult %s\nparam a scalar %s\nparam n scalar %s\n' \
    "$k_src" "$k_entry" "$k_t" "$k_t" "$k_t" > "$k_dir/$k_entry.contract"
  "$KERNEL" "$k_dir/$k_entry.contract" --root "$HERE/status" --typedump "$READER" \
    -o "$k_dir/$k_entry.o" --header "$k_dir/$k_entry.h" --int-width="$k_w" \
    --clang "$CC_BIN" "$@" > "$k_dir/$k_entry.out" 2>&1
}

echo "== 3. the status lane, a 64-bit body (this host) =="
if kernel 64 shifts shl "$T/st64" && kernel 64 shifts shr "$T/st64" &&
   "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$T/st64" "$HERE/status/drive.c" \
     "$T/st64/shl.o" "$T/st64/shr.o" -o "$T/st64/drive" > "$T/st64/link.err" 2>&1; then
  ok "the 64-bit status kernels build and link" yes yes
  rows 64 | "$T/st64/drive" > "$T/st64-out" 2>&1
  shift_check "status shifts give the checked column" 64 5 "$T/st64-out"
else
  echo "  FAIL the 64-bit status kernels did not build or link"
  cat "$T"/st64/*.out "$T/st64/link.err" 2>/dev/null | sed 's/^/      /' | head -6
  fail=$((fail + 1))
fi
built=yes
for e in $POWER_KERNELS; do kernel 64 powers "$e" "$T/sp64" || built=no; done
if [ "$built" = yes ] &&
   "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$T/sp64" "$HERE/status/powers.c" \
     $(for e in $POWER_KERNELS; do printf ' %s' "$T/sp64/$e.o"; done) \
     -o "$T/sp64/drive" > "$T/sp64/link.err" 2>&1; then
  ok "the 64-bit status power kernels build and link" yes yes
  rows 64 "$POWERS" | "$T/sp64/drive" > "$T/sp64-out" 2>&1
  power_check "status abs and ** give the checked column" 64 5 "$T/sp64-out" status
else
  echo "  FAIL the 64-bit status power kernels did not build or link"
  cat "$T"/sp64/*.out "$T/sp64/link.err" 2>/dev/null | sed 's/^/      /' | head -6
  fail=$((fail + 1))
fi
built=yes
for e in $WORD_KERNELS64; do kernel 64 words "$e" "$T/sw64" || built=no; done
if [ "$built" = yes ] &&
   "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$T/sw64" "$HERE/status/words.c" \
     $(for e in $WORD_KERNELS64; do printf ' %s' "$T/sw64/$e.o"; done) \
     -o "$T/sw64/drive" > "$T/sw64/link.err" 2>&1; then
  ok "the 64-bit status word kernels build and link" yes yes
  wrows 64 status | "$T/sw64/drive" words > "$T/sw64-out" 2>&1
  word_check "status intrinsics give words.tsv" 64 "$T/sw64-out" status
  "$T/sw64/drive" checksums > "$T/sw64-sums" 2>&1
  checksum_check "status checksum steps give the published values" 64 "$T/sw64-sums"
else
  echo "  FAIL the 64-bit status word kernels did not build or link"
  cat "$T"/sw64/*.out "$T/sw64/link.err" 2>/dev/null | sed 's/^/      /' | head -6
  fail=$((fail + 1))
fi

echo "== 4. the status lane, a 32-bit body (wasm32, under node) =="
if [ "$wasm_ready" = 0 ]; then
  skipped "the 32-bit status values: $wasm_why"
elif kernel 32 shifts shl "$T/st32" --layout ptr32-i64-32long -- --target=wasm32 -O2 -ffreestanding &&
     kernel 32 shifts shr "$T/st32" --layout ptr32-i64-32long -- --target=wasm32 -O2 -ffreestanding &&
     "$WASM_LD_BIN" --no-entry --export=spinel_core_shl --export=spinel_core_shr \
       --export=__heap_base --initial-memory=131072 \
       "$T/st32/shl.o" "$T/st32/shr.o" -o "$T/st32/k.wasm" > "$T/st32/link.err" 2>&1; then
  ok "the 32-bit status kernels build and link" yes yes
  rows 32 | "$NODE_BIN" "$HERE/status/run.mjs" "$T/st32/k.wasm" > "$T/st32-out" 2>&1
  shift_check "status shifts give the checked column" 32 5 "$T/st32-out"
else
  echo "  FAIL the 32-bit status kernels did not build or link"
  cat "$T"/st32/*.out "$T/st32/link.err" 2>/dev/null | sed 's/^/      /' | head -6
  fail=$((fail + 1))
fi
if [ "$wasm_ready" = 1 ]; then
  built=yes
  for e in $POWER_KERNELS; do
    kernel 32 powers "$e" "$T/sp32" --layout ptr32-i64-32long -- --target=wasm32 -O2 -ffreestanding ||
      built=no
  done
  # shellcheck disable=SC2046 # one word per object and per export
  if [ "$built" = yes ] &&
     "$WASM_LD_BIN" --no-entry $(for e in $POWER_KERNELS; do printf ' --export=spinel_core_%s' "$e"; done) \
       --export=__heap_base --initial-memory=131072 \
       $(for e in $POWER_KERNELS; do printf ' %s' "$T/sp32/$e.o"; done) \
       -o "$T/sp32/k.wasm" > "$T/sp32/link.err" 2>&1; then
    ok "the 32-bit status power kernels build and link" yes yes
    rows 32 "$POWERS" | "$NODE_BIN" "$HERE/status/powers.mjs" "$T/sp32/k.wasm" > "$T/sp32-out" 2>&1
    power_check "status abs and ** give the checked column" 32 5 "$T/sp32-out" status
  else
    echo "  FAIL the 32-bit status power kernels did not build or link"
    cat "$T"/sp32/*.out "$T/sp32/link.err" 2>/dev/null | sed 's/^/      /' | head -6
    fail=$((fail + 1))
  fi
else
  skipped "the 32-bit status power values: $wasm_why"
fi
if [ "$wasm_ready" = 1 ]; then
  built=yes
  for e in $WORD_KERNELS32; do
    kernel 32 words "$e" "$T/sw32" --layout ptr32-i64-32long -- --target=wasm32 -O2 -ffreestanding ||
      built=no
  done
  # shellcheck disable=SC2046 # one word per object and per export
  if [ "$built" = yes ] &&
     "$WASM_LD_BIN" --no-entry $(for e in $WORD_KERNELS32; do printf ' --export=spinel_core_%s' "$e"; done) \
       --export=__heap_base --initial-memory=131072 \
       $(for e in $WORD_KERNELS32; do printf ' %s' "$T/sw32/$e.o"; done) \
       -o "$T/sw32/k.wasm" > "$T/sw32/link.err" 2>&1; then
    ok "the 32-bit status word kernels build and link" yes yes
    wrows 32 status | "$NODE_BIN" "$HERE/status/words.mjs" "$T/sw32/k.wasm" words > "$T/sw32-out" 2>&1
    word_check "status intrinsics give words.tsv" 32 "$T/sw32-out" status
    "$NODE_BIN" "$HERE/status/words.mjs" "$T/sw32/k.wasm" checksums > "$T/sw32-sums" 2>&1
    checksum_check "status checksum steps give the published values" 32 "$T/sw32-sums"
  else
    echo "  FAIL the 32-bit status word kernels did not build or link"
    cat "$T"/sw32/*.out "$T/sw32/link.err" 2>/dev/null | sed 's/^/      /' | head -6
    fail=$((fail + 1))
  fi
else
  skipped "the 32-bit status word values: $wasm_why"
fi

echo "== 5. refusals =="
# fs_refused NAME WORDS [PROFILE]: the exit status, then whether the words are
# on a `spinel-mlirgen: unsupported:` line
fs_refused() {
  rc=$(emit "$HERE/refuse/$1.rb" "${3:-x86_64-linux-host}")
  printf '%s|%s' "$([ "$rc" != 0 ] && echo refused || echo "exit $rc")" \
    "$(grep -F "spinel-mlirgen: unsupported: " "$T/fs/err" | grep -cF "$2")"
}
while IFS='|' read -r name words; do
  case $name in ''|\#*) continue ;; esac
  ok "freestanding $name" "$(fs_refused "$name" "$words")" "refused|1"
done <<'EOF'
bool_and|left operand of & is a boolean; only Integer values are in the subset
float_and|whole-program inference says `float_and` returns `poly`
float_shr|whole-program inference says `float_shr` returns `poly`
buf_shl|`<<` on an Array or String appends to a heap object. Only `<<` on a receiver typed Integer is a shift
buf_pow|`**` is a power only on two Integers (decision 0042)
reopen_shl|`class Integer` changes the builtin class Integer at the top level.
u32_param|core_u32 takes an Integer literal in 0..4294967295
u32_wide|core_u32 takes an Integer literal in 0..4294967295
self_w64|`core_w64_add` is a CORE intrinsic and is called with no receiver
arity_w64|`core_w64_add` takes 2 argument(s), 1 given
block_w64|`core_w64_add` is a CORE intrinsic and takes no block
def_w64|`core_w64_add` is defined in this source and is also the CORE intrinsic
EOF
ok "freestanding w64_on32 (the wasm32 profile)" \
  "$(fs_refused w64_on32 '`core_w64_add` computes on 64-bit words and this body is 32 bits' wasm32-worker)" "refused|1"
# st_refused SRC CATEGORY [32]: the exit status, then whether the kernel names
# CATEGORY as a reason the entry is not eligible; with 32, the kernel is built
# for wasm32 at `--int-width=32`
st_refused() {
  if [ "${3:-64}" = 32 ]; then
    kernel 32 "$1" "$1" "$T/refuse" --layout ptr32-i64-32long -- --target=wasm32 -O2 -ffreestanding
  else
    kernel 64 "$1" "$1" "$T/refuse"
  fi
  rc=$?
  printf '%s|%s' "$([ "$rc" != 0 ] && echo refused || echo "exit $rc")" \
    "$(grep -cF "not-eligible: $2: " "$T/refuse/$1.out" | awk '{ print ($1 > 0) }')"
}
ok "status ary_shl (an Array local)" "$(st_refused ary_shl heap-operation)" "refused|1"
ok "status reopen_shl (a reopened Integer#<<)" "$(st_refused reopen_shl binding-environment)" "refused|1"
ok "status reopen_pow (a reopened Integer#**)" "$(st_refused reopen_pow binding-environment)" "refused|1"
ok "status st_w64_32 (a w64 form at 32 bits)" \
  "$(st_refused st_w64_32 unsupported-intrinsic-call 32)" "refused|1"
ok "status st_u32_param (core_u32 of a parameter)" \
  "$(st_refused st_u32_param unsupported-intrinsic-call)" "refused|1"
ok "status st_u32_wide (core_u32 of 4294967296)" \
  "$(st_refused st_u32_wide unsupported-intrinsic-call)" "refused|1"

echo "== 6. the report =="
# loop_bound's verdict, its loop count and its work bound, for `a ** n`.
if kernel 64 powers pw "$T/report" --report "$T/report/pw.json" --profile hosted-stage2; then
  ok "a ** n reports no loop" \
    "$(ruby -rjson -e 'l = JSON.parse(File.read(ARGV[0])).dig("properties", "loop_bound")
                       puts [l["verdict"], l["loops"].size, l.dig("work_bound", "expression")].join(" ")' \
       "$T/report/pw.json" 2>&1)" "pass 0 0"
else
  echo "  FAIL the report kernel did not build"
  sed 's/^/      /' "$T/report/pw.out" | head -4
  fail=$((fail + 1))
fi

echo "== 7. controls =="
# a. One expected line changed is reported, so section 1's comparison can fail.
if [ -f "$T/out64" ]; then
  sed 's/^bnot 5 -6$/bnot 5 -5/' "$HERE/fs/expect.txt" > "$T/planted.txt"
  ok "a changed expected line is a difference" \
    "$(same "$T/planted.txt" "$T/out64")" "< bnot 5 -5"
else
  skipped "control a needs section 1's output"
fi
# b. A table row changed is reported, so the shift comparisons can fail.
if [ -f "$T/st64-out" ]; then
  sed 's/^64	shl	1	63	fail	/64	shl	1	63	-9223372036854775808	/' "$TABLE" > "$T/planted.tsv"
  want 64 5 "$T/planted.tsv" > "$T/planted-want"
  ok "a changed table row is a difference" \
    "$(same "$T/planted-want" "$T/st64-out")" "< shl 1 63 -9223372036854775808"
else
  skipped "control b needs section 3's output"
fi
# c. A row of powers.tsv changed is reported, so the power comparisons can
#    fail: `(-2) ** 63` is MIN, and the planted row says it fails.
if [ -f "$T/sp64-out" ]; then
  sed 's/^64	pow	-2	63	-9223372036854775808	/64	pow	-2	63	fail	/' "$POWERS" > "$T/planted-p.tsv"
  want 64 5 "$T/planted-p.tsv" | sed 's/ negative$/ fail/' > "$T/planted-pwant"
  ok "a changed power row is a difference" \
    "$(same "$T/planted-pwant" "$T/sp64-out")" "< pow -2 63 fail"
else
  skipped "control c needs section 3's output"
fi
# e. A row of words.tsv changed is reported, so the word comparisons can
#    fail: the planted row says `core_u32(0xdeadbeef)` is 0xdeadbeef unsigned.
if [ -f "$T/sw64-out" ]; then
  sed 's/^64	u32lit	0	0	-559038737$/64	u32lit	0	0	3735928559/' "$WORDS" > "$T/planted-w.tsv"
  wwant 64 status "$T/planted-w.tsv" > "$T/planted-wwant"
  ok "a changed word row is a difference" \
    "$(same "$T/planted-wwant" "$T/sw64-out")" "< u32lit 0 0 3735928559"
else
  skipped "control e needs section 3's word output"
fi
# d. A refusal checked against another row's words does not pass.
ok "bool_and is not refused with buf_shl's words" \
  "$(fs_refused bool_and '`<<` on an Array or String appends to a heap object.')" "refused|0"

echo "== 8. an intrinsic in a required file =="
mkdir -p "$T/req/spinel"
cp "$ROOT/tools/freestanding/spinel/freestanding.rb" "$T/req/spinel/"
cp "$HERE/req/main.rb" "$HERE/req/helper.rb" "$T/req/"
(cd "$T/req" && "$EMIT" main.rb --freestanding --profile "$PROFILES/cortex-m33-zephyr.yaml" \
   --typedump "$READER" -o k.o) > "$T/req/err" 2>&1
ok "req/main.rb compiles, its helper's intrinsic typed by the prelude" \
  "$?|$(grep -c 'core_' "$HERE/req/main.rb")" "0|0"
grep -v 'pre-T5' "$T/req/err" | grep -v '^spinel-fs-emit: wrote' | sed 's/^/      /' | head -3

echo "== 9. the source's own lines =="
mkdir -p "$T/lines/spinel"
cp "$ROOT/tools/freestanding/spinel/freestanding.rb" "$T/lines/spinel/"
cp "$HERE/lines/lines.rb" "$T/lines/"
(cd "$T/lines" && "$EMIT" --profile "$PROFILES/x86_64-linux-host.yaml" --source lines.rb \
   -o k.o --emit-llvm k.ll --emit-header k.h --emit-mlir k.mlir --typedump "$READER") \
  > "$T/lines/err" 2>&1
ok "lines/lines.rb: the module's locations are the source's lines and columns" \
  "$?|$(grep -o 'lines\.rb":[0-9]*:[0-9]*' "$T/lines/k.mlir" 2>/dev/null | cut -d: -f2,3 | sort -u -t: -k1,1n -k2,2n | tr '\n' ' ')" \
  "0|7:0 8:2 8:6 8:22 9:2 9:6 "

echo "core-bitwise: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ]
