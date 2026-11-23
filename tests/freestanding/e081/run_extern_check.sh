#!/usr/bin/env bash
# E081: the declaration-vs-wrapper gate (extern-check), with its controls, and
# the DYNAMIC backing of the static scan (E062's discipline: a static checker's
# claim is held against a second, independent mechanism).
#
#   extern_check.tsv   one row per (scenario, symbol-of-interest):
#     x_*   the real wrappers: every declared extern must MATCH
#     b_*   deliberately broken wrappers: the named symbol must NOT match
#     w_*   the two-witness rows: clang compiling the wrapper WITH the
#           generated header #included accepts the good wrapper and refuses
#           the broken one -- the same agreement, enforced by a C compiler
#           instead of a regex.
set -uo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
mkdir -p "$RES"
PROF=$HERE/cortex-m33-zephyr-e081.yaml

pass=0; fail=0
T=$RES/extern_check.tsv
printf 'id\texpect\tgot\tverdict\tnote\n' > "$T"
emit() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$T"
         if [ "$4" = PASS ]; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

# -- the real wrapper TUs: all 7 must MATCH --------------------------------
for src in zephyr/src/spinel_zephyr.c goodwrapper_plain.c; do
  id=$(basename "$src" .c)
  out=$("$FSCHECK" --extern --profile "$PROF" "$HERE/$src" 2>/dev/null)
  rc=$?
  nmatch=$(printf '%s\n' "$out" | awk -F'\t' '$1=="MATCH"' | wc -l | tr -d ' ')
  if [ "$rc" = 0 ] && [ "$nmatch" = 7 ]; then
    emit "x_$id" "MATCH:7" "MATCH:$nmatch" PASS "every declared extern agrees with $src"
  else
    emit "x_$id" "MATCH:7" "MATCH:$nmatch rc=$rc" FAIL "$src"
  fi
done

# -- the broken wrappers: the named symbol must be refused -----------------
bad() {  # id, file, symbol, expected-verdict
  local id=$1 file=$2 sym=$3 expect=$4
  out=$("$FSCHECK" --extern --profile "$PROF" "$HERE/badwrappers/$file" 2>/dev/null)
  rc=$?
  got=$(printf '%s\n' "$out" | awk -F'\t' -v s="$sym" '$2==s {print $1}')
  if [ "$rc" != 0 ] && [ "$got" = "$expect" ]; then
    emit "$id" "$expect" "$got" PASS "$file / $sym"
  else
    emit "$id" "$expect" "$got rc=$rc" FAIL "$file / $sym"
  fi
}
bad b1_arity      b1_arity.c      spinel_zephyr_gpio_set     MISMATCH
bad b2_return     b2_return.c     spinel_zephyr_uptime_ms    MISMATCH
bad b3_paramtype  b3_paramtype.c  spinel_zephyr_checksum32   MISMATCH
bad b4_missing    b1_arity.c      spinel_zephyr_sleep_ms     MISSING
bad b5_static     b5_static.c     spinel_zephyr_gpio_get     MISMATCH
bad b6_proto_only b6_proto_only.c spinel_zephyr_print_i64    MISSING
bad b7_pointer    b7_pointer.c    spinel_zephyr_sense_scale  MISMATCH

# -- the two-witness rows: the generated header vs a C compiler ------------
# (host clang, -fsyntax-only: the agreement being checked is a C-level type
# agreement, not a target codegen question -- abi-check.py covers the latter.)
GEN=$OUT/gen
if [ -f "$GEN/spinel_freestanding.cortex-m33-zephyr.h" ]; then
  cp "$GEN/spinel_freestanding.cortex-m33-zephyr.h" "$GEN/spinel_freestanding.h"
  if "$CLANG" -fsyntax-only -DE081_WITH_HEADER -I"$GEN" "$HERE/goodwrapper_plain.c" 2>/dev/null; then
    emit w_good_compiles ACCEPT ACCEPT PASS \
      "clang accepts the good wrapper with the generated header included"
  else
    emit w_good_compiles ACCEPT REJECT FAIL "good wrapper refused"
  fi
  if "$CLANG" -fsyntax-only -DE081_WITH_HEADER -I"$GEN" "$HERE/badwrappers/b2_return.c" 2>/dev/null; then
    emit w_bad_refused REJECT ACCEPT FAIL \
      "clang ACCEPTED a wrapper whose return type contradicts the header"
  else
    emit w_bad_refused REJECT REJECT PASS \
      "conflicting types for spinel_zephyr_uptime_ms -- the C compiler is the second witness"
  fi
else
  emit w_header_present yes no FAIL "generated header missing (run build_all.sh first)"
fi

cat "$T"
echo "extern_check.tsv: pass=$pass fail=$fail"
[ "$fail" = 0 ] || exit 1
