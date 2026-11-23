#!/bin/sh
#
# tests/core-boundary/failure-sites.sh — the kernel's failure sites, a debugging aid.
#
#   [KERNEL=...] [ADAPTER=...] [SPINEL_TYPEDUMP=...] [LLVM_PREFIX=...] sh tests/core-boundary/failure-sites.sh
#
# `spinel-core-kernel --failure-sites FILE` makes each place a failure starts
# store its site's id in spinel_core_<entry>_failure_site before the status
# returns, and writes the sites to FILE. Four parts, on fixtures/failure-sites:
#
#   1. the table: each site of the planted fixture, its file, line, status and
#      operation (the lines are the fixture's, read by eye);
#   2. the sites, run here: a planted overflow of the entry's own `+`, one of
#      a helper's `*` that the entry passes up (the innermost site is kept),
#      and a core_fail(:capacity), each naming its line through the table; a
#      success leaves 0, and the wrapper clears a site on the next call. The
#      expected statuses and results are worked by hand, and the object built
#      without the option gives the same ones: the status ABI is unchanged;
#   3. off by default: the object built without the option has no site symbol
#      and its MLIR no site store, and the MLIR of the two builds, with value
#      names normalised, differs only by the site stores and the global;
#   4. the adapter's pair: spinel-core-adapter --failure-sites prints the site
#      of a failed call, and without the flag its source has no such line.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX=$ROOT/tests/core-boundary/fixtures/failure-sites
KERNEL=${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}
ADAPTER_BIN=${ADAPTER:-$ROOT/tools/mlir/native/build/bin/spinel-core-adapter}
READER=${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
LLVM=${LLVM_PREFIX:-/opt/llvm-23.1.1}
CC_BIN=${CLANG:-$LLVM/bin/clang}
RUBY=${RUBY:-ruby}
die() { echo "failure-sites: $*" >&2; exit 2; }
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL"
[ -x "$ADAPTER_BIN" ] || die "no spinel-core-adapter at $ADAPTER_BIN"
[ -x "$READER" ] || die "no contract reader at $READER"
[ -x "$CC_BIN" ] || die "no clang at $CC_BIN"
W=$(mktemp -d "${TMPDIR:-/tmp}/core-failure-sites.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
T0=$(date +%s)
SRC=$FIX/src/sites.rb
printf 'core-contract 1\nroot src/sites.rb\nentry fs_entry\nresult i64\nparam a scalar i64\nparam k scalar i64\n' > "$W/k.contract"
kern() { # out [kernel args]
  o=$1; shift
  "$KERNEL" "$W/k.contract" --root "$FIX" --typedump "$READER" --clang "$CC_BIN" -o "$W/$o.o" \
    --header "$W/k.h" --emit-mlir "$W/$o.mlir" "$@" > "$W/$o.log" 2>&1
}
kern on --failure-sites "$W/sites.tsv" || die "the build with --failure-sites failed; see $W/on.log"
kern off || die "the build without it failed; see $W/off.log"

echo "failure-sites: 1. the table"
row() { awk -F'\t' -v w="$1" '$6 == w { print $2 ":" $3 " " $5; exit }' "$W/sites.tsv"; }
ok "it names the entry's global" "$(sed -n 's/^# global\t//p' "$W/sites.tsv")" spinel_core_fs_entry_failure_site
ok "three sites, one per failing operation" "$(grep -c '^[0-9]' "$W/sites.tsv")" 3
ok "core_fail(:capacity): the fixture's line 13, CAPACITY" "$(row 'core_fail(:capacity)')" "$SRC:13 CAPACITY"
ok "the entry's +: line 15, ARITHMETIC" "$(row 'checked +')" "$SRC:15 ARITHMETIC"
ok "the helper's *: line 8, ARITHMETIC" "$(row 'checked *')" "$SRC:8 ARITHMETIC"

echo "failure-sites: 2. the sites, run"
"$CC_BIN" -O1 -DSITES -I"$W" "$FIX/harness.c" "$W/on.o" -o "$W/h-on" || die "the harness did not build against the object with sites"
"$CC_BIN" -O1 -I"$W" "$FIX/harness.c" "$W/off.o" -o "$W/h-off" || die "the harness did not build against the object without"
site_of() { awk -F'\t' -v w="$1" '$6 == w { print $1; exit }' "$W/sites.tsv"; }
PLUS=$(site_of 'checked +'); MUL=$(site_of 'checked *'); CAP=$(site_of 'core_fail(:capacity)')
call() { "$W/$1" "$2" "$3" | tr '\n' '|'; }
# 5 + 1 = 6, 6 * 2 = 12; 2**63 - 1 + 1 overflows the +; (2**62 + 1) * 4
# overflows the *; k < 0 is the capacity failure. A failure leaves 77.
ok "a success: 12, and no site" "$(call h-on 5 2)" "0 12 0|"
ok "the entry's own + overflows: ARITHMETIC, its site, and the next call clears it" \
   "$(call h-on 9223372036854775807 1)" "2 77 $PLUS|again 0 2 0|"
ok "the helper's * overflows: the innermost site, not the call's" \
   "$(call h-on 4611686018427387904 4)" "2 77 $MUL|again 0 2 0|"
ok "core_fail(:capacity): CAPACITY and its site" "$(call h-on 1 -1)" "4 77 $CAP|again 0 2 0|"
for args in "5 2" "9223372036854775807 1" "4611686018427387904 4" "1 -1"; do
  # shellcheck disable=SC2086
  ok "without the option, the same status and result for $args" \
     "$(call h-off $args | sed 's/ [-0-9]*|/|/g')" "$(call h-on $args | sed 's/ [-0-9]*|/|/g')"
done

echo "failure-sites: 3. off by default"
ok "the object without the option defines no site symbol" "$("$LLVM/bin/llvm-nm" "$W/off.o" | grep -c failure_site)" 0
ok "and its MLIR stores no site" "$(grep -c failure_site "$W/off.mlir")" 0
# ELF: B or D. Mach-O: the name has a leading _, and this zero-filled global is
# placed in __DATA,__common, which llvm-nm prints as S.
ok "the object with it defines the global" "$("$LLVM/bin/llvm-nm" "$W/on.o" | grep -cE ' ([BD] |[BDS] _)spinel_core_fs_entry_failure_site$')" 1
ok "the two MLIRs differ only by the site stores and the global (three sites and the wrapper's clear)" \
   "$("$RUBY" -e '
     norm = ->(f) { File.readlines(f).map { |l| l.gsub(/%[\w#]+/, "%_").gsub(/\^bb\d+/, "^bb").rstrip }.reject(&:empty?) }
     on, off = norm.(ARGV[0]), norm.(ARGV[1])
     left = Hash.new(0); off.each { |l| left[l] += 1 }
     extra = []; on.each { |l| left[l] > 0 ? left[l] -= 1 : extra << l.strip }
     missing = left.values.sum
     g = extra.grep(/\Allvm\.mlir\.global external @spinel_core_fs_entry_failure_site\(0 : i32\)/).size
     a = extra.grep(/\A%_ = llvm\.mlir\.addressof @spinel_core_fs_entry_failure_site : !llvm\.ptr\z/).size
     s = extra.grep(/\Allvm\.store %_, %_ : i32, !llvm\.ptr\z/).size
     c = extra.grep(/\A%_ = arith\.constant \d+ : i32\z/).size
     print "missing=#{missing} global=#{g} addressof=#{a} store=#{s} const=#{c} other=#{extra.size - g - a - s - c}"
   ' "$W/on.mlir" "$W/off.mlir")" "missing=0 global=1 addressof=4 store=4 const=4 other=0"

echo "failure-sites: 4. the adapter's pair"
"$ADAPTER_BIN" "$W/k.contract" --root "$FIX" --typedump "$READER" --outdir "$W/ad-on" --core-header k.h --failure-sites > "$W/ad-on.log" 2>&1 ||
  die "the adapter with --failure-sites failed; see $W/ad-on.log"
"$ADAPTER_BIN" "$W/k.contract" --root "$FIX" --typedump "$READER" --outdir "$W/ad-off" --core-header k.h > "$W/ad-off.log" 2>&1 ||
  die "the adapter failed; see $W/ad-off.log"
ok "with --failure-sites a failed call prints its site" \
   "$(grep -c 'spinel-core: fs_entry answered %d at failure site %d' "$W/ad-on/spinel_adapter_fs_entry.c")" 1
ok "and it compiles against the kernel's header" \
   "$(cp "$W/k.h" "$W/ad-on/" && "$CC_BIN" -std=c11 -fsyntax-only -I"$W/ad-on" "$W/ad-on/spinel_adapter_fs_entry.c" 2>&1 | grep -c error)" 0
ok "without it the adapter's source has no such line" "$(grep -c 'failure site\|failure_site' "$W/ad-off/spinel_adapter_fs_entry.c")" 0

echo "failure-sites: $((pass + fail)) checked, $pass pass, $fail fail; $(( $(date +%s) - T0 )) s"
[ "$fail" = 0 ]
