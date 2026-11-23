#!/bin/sh
#
# tests/core-boundary/intrinsics.sh — decision 0022 §1's word intrinsics, and
# decision 0042 stage 4's preludes for them.
#
#   [KERNEL=...] [SPINEL_TYPEDUMP=...] [LLVM_PREFIX=...] sh tests/core-boundary/intrinsics.sh
#
# Eleven parts:
#
#   1. execution: every 64-bit case of fixtures/intrinsics/cases.tsv, its
#      entry built by the kernel as an int64 body and run here, the status and
#      the value read back. A failed case must leave the result word
#      untouched. The values are hand-computed from the decision, not from any
#      implementation. A 32-bit body needs a 32-bit target (decision 0019), so
#      the 32-bit cases run on the board (tests/core-boundary/intrinsics-board.sh);
#      this part counts them and says so.
#   2. refusals: each fixture under fixtures/intrinsics/refuse is refused, by
#      its own category: a definition of an intrinsic's name in the source
#      (conflicting-intrinsic), a receiver (self. and a constant), a wrong
#      arity, a block, a keyword, a splat and a Boolean operand. `send` and
#      `alias` are refused as any `send` call and any top-level alias are.
#   3. the CRuby route's prelude (tools/core/intrinsics.rb): the same table,
#      the same answers, with an out-of-range operand raising. This runs our
#      own prelude against the hand-computed values; it compares with no other
#      implementation.
#   4. lowering, on thumbv8m.main at 32 bits: core_fixed_mul is a long multiply
#      and shifts with no call; the w32 operations and the comparisons call
#      nothing either.
#   5. the prelude is not a unit: packed with a source that calls one of its
#      names, the build is refused (conflicting-intrinsic).
#   6. the CRuby prelude gives every row of tests/core-bitwise/words.tsv, the
#      hand-computed table of decision 0042 stage 4, a `fail` row as
#      CoreIntrinsics::Arithmetic.
#   7. the hosted prelude (tools/core/hosted-prelude.rb), compiled by the
#      pinned Spinel with a caller as a plain hosted program, gives every
#      64-bit row, and each `fail` row raises RangeError with the text
#      written by hand below.
#   8. the failure texts of the core object's shim (spinel-core-emit
#      --shim-out) are the texts the hosted prelude raises, but
#      `core_u32: the value is outside 0..4294967295`: CORE refuses a
#      `core_u32` argument that is not a literal in 0..4294967295 at compile
#      time (unsupported-intrinsic-call; tests/core-bitwise and
#      tests/native-core/arith.sh check that refusal), so no core object
#      fails there at run time.
#   9. both preludes define exactly the names of the table in
#      spinel-mlir/Core/Intrinsics.h.
#  10. `spinel-core-emit --print-prelude` prints tools/core/hosted-prelude.rb.
#  11. a source that names no intrinsic gets no prelude: `--print-prelude
#      --for` prints nothing for it, and the checker's input ledger names the
#      source itself.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX=$ROOT/tests/core-boundary/fixtures/intrinsics
KERNEL=${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}
READER=${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}
EMIT=${EMIT:-$ROOT/tools/mlir/native/build/bin/spinel-core-emit}
CHECK=${CHECK:-$ROOT/tools/mlir/native/build/bin/spinel-core-check}
SPINEL=${SPINEL_SEAM:-$ROOT/vendor/spinel}/bin/spinel
WORDS=$ROOT/tests/core-bitwise/words.tsv
HOSTED=$ROOT/tools/core/hosted-prelude.rb
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp kernel "$EMIT"
source_stamp kernel "$CHECK"
source_stamp reader "$READER"
LLVM=${LLVM_PREFIX:-/opt/llvm-23.1.1}
CC_BIN=${CLANG:-$LLVM/bin/clang}
RUBY=${RUBY:-ruby}
die() { echo "intrinsics: $*" >&2; exit 2; }
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL"
[ -x "$READER" ] || die "no contract reader at $READER"
[ -x "$CC_BIN" ] || die "no clang at $CC_BIN"
[ -x "$EMIT" ] || die "no spinel-core-emit at $EMIT"
[ -x "$CHECK" ] || die "no spinel-core-check at $CHECK"
[ -x "$SPINEL" ] || die "no pinned spinel at $SPINEL (build vendor/spinel)"
W=$(mktemp -d "${TMPDIR:-/tmp}/core-intrinsics.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
T0=$(date +%s)

# the parameter names of a method of words.rb
params_of() { "$RUBY" -e 'm = File.read(ARGV[0])[/^def #{ARGV[1]}\(([^)]*)\)/, 1] or abort; puts m.split(/,\s*/)' "$FIX/src/words.rb" "$1"; }

# ENTRY's contract at WIDTH: an int64 body has an i64 boundary, a 32-bit body
# an i32 one (decision 0019)
contract() { # width entry out
  t=i64; [ "$1" = 32 ] && t=i32
  { echo "core-contract 1"; echo "root src/words.rb"; echo "entry $2"; echo "result $t"
    for p in $(params_of "$2"); do echo "param $p scalar $t"; done; } > "$3"
}

# build ENTRY at WIDTH into $W/WIDTH/ENTRY, with a harness that prints "status value"
build() { # width entry
  d=$W/$1/$2; mkdir -p "$d"
  contract "$1" "$2" "$d/k.contract"
  "$KERNEL" "$d/k.contract" --root "$FIX" --typedump "$READER" -o "$d/k.o" --header "$d/k.h" \
    --int-width="$1" --clang "$CC_BIN" > "$d/build.out" 2>&1 || return 1
  n=$(params_of "$2" | wc -l | tr -d ' ')
  call=""; i=1
  while [ "$i" -le "$n" ]; do call="${call}strtoll(argv[$i], 0, 10), "; i=$((i + 1)); done
  cat > "$d/h.c" <<EOF
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "k.h"
int main(int argc, char **argv) {
  if (argc != $((n + 1))) return 99;
  const int64_t sentinel = -1234567890123;
  int64_t r = sentinel;
  int32_t st = spinel_core_$2(${call}&r);
  if (st != 0) { printf("%d %s\n", (int)st, r == sentinel ? "untouched" : "TOUCHED"); return 0; }
  printf("0 %lld\n", (long long)r);
  return 0;
}
EOF
  "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$d" "$d/h.c" "$d/k.o" -o "$d/h" 2> "$d/h.log"
}

echo "intrinsics: 1. execution, on this host"
all=$(grep -v '^#' "$FIX/cases.tsv")
rows=$(printf '%s\n' "$all" | awk -F'\t' '$2 == 64')
echo "  $(printf '%s\n' "$all" | awk -F'\t' '$2 == 32' | grep -c .) case(s) of a 32-bit body run on the board (intrinsics-board.sh), not here"
for we in $(printf '%s\n' "$rows" | awk -F'\t' '{ print $2 "/" $3 }' | sort -u); do
  build "${we%/*}" "${we#*/}" || { echo "  FAIL ${we#*/} at ${we%/*} bits did not build:"; tail -3 "$W/$we/build.out" | sed 's/^/      /'; fail=$((fail + 1)); }
done
n_cases=0
printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r id width entry args status value; do
  h=$W/$width/$entry/h
  [ -x "$h" ] || { echo "  FAIL $id: no harness"; continue; }
  # shellcheck disable=SC2046
  got=$("$h" $(echo "$args" | tr ',' ' '))
  case $status in
    ok) want="0 $value" ;;
    arithmetic) want="2 untouched" ;;
  esac
  ok "$id: $entry($args) at $width bits" "$got" "$want"
done > "$W/exec.out"
cat "$W/exec.out"
pass=$((pass + $(grep -c '^  pass' "$W/exec.out"))); fail=$((fail + $(grep -c '^  FAIL' "$W/exec.out")))
ok "every case of the table ran" "$(grep -c '^  \(pass\|FAIL\)' "$W/exec.out")" "$(printf '%s\n' "$rows" | grep -c .)"

echo "intrinsics: 2. refusals, each by its category"
for c in conflict:conflicting-intrinsic self_receiver:unsupported-intrinsic-call const_receiver:unsupported-intrinsic-call \
         arity:arity-mismatch block:unsupported-node keyword:unsupported-node splat:arity-mismatch \
         wrong_type:"type-evidence: operand 2 of core_w32_add" send:dangling-reference alias:binding-environment; do
  n=${c%%:*}; want=${c#*:}
  "$KERNEL" "$FIX/refuse/$n.contract" --root "$FIX" --typedump "$READER" -o "$W/$n.o" --clang "$CC_BIN" > /dev/null 2> "$W/$n.err"
  ok "$n is refused: $want" "$?|$(grep -c -- "$want" "$W/$n.err" | awk '{ print ($1 > 0) }')" "1|1"
done

echo "intrinsics: 3. the CRuby route's prelude, on the same table"
"$RUBY" -e '
  require ARGV[0]
  load ARGV[1]
  File.readlines(ARGV[2], chomp: true).each do |l|
    next if l.start_with?("#") || l.strip.empty?
    id, _width, entry, args, status, value = l.split("\t")
    # the plain `+` beside the intrinsic is the checked arithmetic of a
    # 32-bit CORE body, which CRuby has no counterpart for
    next if id == "same_body_plain_32"
    got = begin
            r = send(entry, *args.split(",").map { |x| Integer(x) })
            "ok #{r}"
          rescue CoreIntrinsics::Arithmetic
            "arithmetic -"
          end
    want = "#{status} #{value}"
    puts(got == want ? "  pass #{id}" : "  FAIL #{id} (got #{got.inspect}, want #{want.inspect})")
  end' "$ROOT/tools/core/intrinsics.rb" "$FIX/src/words.rb" "$FIX/cases.tsv" > "$W/prelude.out" 2>&1
cat "$W/prelude.out" | grep -v '^  pass' | head -20
p=$(grep -c '^  pass' "$W/prelude.out"); f=$(grep -c '^  FAIL' "$W/prelude.out")
ok "the prelude gives every case's answer ($p of them)" "$f|$p" "0|$(($(printf '%s\n' "$all" | grep -c .) - 1))"

echo "intrinsics: 4. lowering on thumbv8m.main, at 32 bits"
THUMB="--target=thumbv8m.main-none-eabi -mcpu=cortex-m33+nodsp -mfloat-abi=soft -mthumb -Os -ffreestanding"
dis() { # entry -> its body's disassembly in $W/thumb/ENTRY.dis
  d=$W/thumb/$1; mkdir -p "$d"
  contract 32 "$1" "$d/k.contract"
  # shellcheck disable=SC2086
  "$KERNEL" "$d/k.contract" --root "$FIX" --typedump "$READER" -o "$d/k.o" --header "$d/k.h" \
    --layout ptr32-i64-32long --int-width=32 --clang "$CC_BIN" -- $THUMB > "$d/build.out" 2>&1 || return 1
  "$LLVM/bin/llvm-objdump" -d --no-show-raw-insn "$d/k.o" > "$d/all.dis"
}
for e in f_mul w_add w_mul u_lt u_shr f_div; do
  dis "$e" || { echo "  FAIL $e did not build for thumbv8m.main"; fail=$((fail + 1)); }
done
ok "core_fixed_mul is a long multiply: smull in f_mul's object" "$(grep -cE '\ssmull\s' "$W/thumb/f_mul/all.dis" | awk '{ print ($1 > 0) }')" 1
for e in f_mul w_add w_mul u_lt u_shr; do
  ok "$e calls nothing (no bl or blx)" "$(grep -cE '\sblx?\s' "$W/thumb/$e/all.dis")" 0
done
helpers=$("$LLVM/bin/llvm-nm" -u "$W/thumb/f_div/k.o" | awk '{ print $NF }' | sort | tr '\n' ' ')
echo "  core_fixed_div's object calls: ${helpers:-nothing} (the 64-bit division helper is admitted, 0021's record)"
ok "core_fixed_div calls no more than the division helper" \
   "$(printf '%s\n' $helpers | grep -vcE '^__aeabi_l?divmod$|^$')" 0

echo "intrinsics: 5. the prelude is not a unit"
mkdir -p "$W/packed/src"
cat "$ROOT/tools/core/intrinsics.rb" "$FIX/src/words.rb" > "$W/packed/src/words.rb"
printf 'core-contract 1\nroot src/words.rb\nentry w_add\nresult i64\nparam a scalar i64\nparam b scalar i64\n' > "$W/packed/k.contract"
"$KERNEL" "$W/packed/k.contract" --root "$W/packed" --typedump "$READER" -o "$W/packed/k.o" --clang "$CC_BIN" > /dev/null 2> "$W/packed.err"
ok "the prelude packed with a caller is refused" "$?|$(grep -c 'conflicting-intrinsic' "$W/packed.err" | awk '{ print ($1 > 0) }')" "1|1"

echo "intrinsics: 6. the CRuby prelude, on words.tsv"
"$RUBY" -e '
  require ARGV[0]
  File.readlines(ARGV[1], chomp: true).each do |l|
    next if l.start_with?("#") || l.strip.empty?
    w, op, a, b, want = l.split("\t")
    a = Integer(a); b = Integer(b)
    got = begin
            r = case op
                when "u32lit" then core_u32(0xdeadbeef)
                when "w32_add_w" then core_w32_add(a, b)
                when /_neg\z/ then send("core_#{op}", a)
                else send("core_#{op}", a, b)
                end
            r == true ? "1" : r == false ? "0" : r.to_s
          rescue CoreIntrinsics::Arithmetic
            "fail"
          end
    puts(got == want ? "  pass" : "  FAIL #{w} #{op} #{a} #{b} (got #{got}, want #{want})")
  end' "$ROOT/tools/core/intrinsics.rb" "$WORDS" > "$W/words-cruby.out" 2>&1
grep -v '^  pass' "$W/words-cruby.out" | head -10
ok "the CRuby prelude gives every row of words.tsv ($(grep -c '^  pass' "$W/words-cruby.out") of them)" \
  "$(grep -vc '^  pass' "$W/words-cruby.out")|$(grep -c '^  pass' "$W/words-cruby.out")" \
  "0|$(grep -vc '^#' "$WORDS")"

echo "intrinsics: 7. the hosted prelude, compiled by the pinned Spinel"
# The failure texts, by hand, one per `fail` row at 64 bits.
cat > "$W/fail-texts" <<'EOF'
w32_add 2147483648 0|core_w32_add: an operand is outside the i32 range
w32_add 0 -2147483649|core_w32_add: an operand is outside the i32 range
w32_sub 2147483648 0|core_w32_sub: an operand is outside the i32 range
w32_mul 1 2147483648|core_w32_mul: an operand is outside the i32 range
w32_neg 2147483648 0|core_w32_neg: an operand is outside the i32 range
w32_shl 1 2147483648|core_w32_shl: an operand is outside the i32 range
w32_shl 2147483648 1|core_w32_shl: an operand is outside the i32 range
u32_lt 2147483648 0|core_u32_lt: an operand is outside the i32 range
u32_shr -1 32|core_u32_shr: the count is outside 0..31
u32_shr -1 -1|core_u32_shr: the count is outside 0..31
u32_shr 2147483648 1|core_u32_shr: an operand is outside the i32 range
fixed_mul 2147483648 1|core_fixed_mul: an operand is outside the i32 range
fixed_div 1 2147483648|core_fixed_div: an operand is outside the i32 range
w32_add_w 2147483648 0|core_w32_add: an operand is outside the i32 range
u64_shr -1 64|core_u64_shr: the count is outside 0..63
u64_shr -1 -1|core_u64_shr: the count is outside 0..63
EOF
# A plain hosted program: the prelude, then one rescued call per 64-bit row.
mkdir -p "$W/hosted"
"$RUBY" -e '
  puts File.read(ARGV[0])
  puts "def show(r)", "  r == true ? 1 : (r == false ? 0 : r)", "end"
  File.readlines(ARGV[1], chomp: true).each do |l|
    next if l.start_with?("#") || l.strip.empty?
    w, op, a, b, _ = l.split("\t")
    next unless w == "64"
    call = case op
           when "u32lit" then "core_u32(3735928559)"
           when "w32_add_w" then "core_w32_add(#{a}, #{b})"
           when /_neg\z/ then "core_#{op}(#{a})"
           else "core_#{op}(#{a}, #{b})"
           end
    puts "begin", "  puts \"#{op} #{a} #{b} \" + show(#{call}).to_s",
         "rescue RangeError => e", "  puts \"#{op} #{a} #{b} fail \" + e.message", "end"
  end' "$HOSTED" "$WORDS" > "$W/hosted/rows.rb"
awk -F'\t' -v texts="$W/fail-texts" '
  BEGIN { while ((getline l < texts) > 0) { split(l, p, "|"); t[p[1]] = p[2] } }
  !/^#/ && NF == 5 && $1 == 64 {
    k = $2 " " $3 " " $4
    print k " " ($5 == "fail" ? "fail " (k in t ? t[k] : "?") : $5)
  }' "$WORDS" > "$W/hosted/want"
if CC=$CC_BIN "$SPINEL" "$W/hosted/rows.rb" -o "$W/hosted/rows" > "$W/hosted/build.out" 2>&1; then
  "$W/hosted/rows" > "$W/hosted/got" 2>&1
  ok "the hosted prelude gives every 64-bit row, each failure with its text ($(grep -c . "$W/hosted/want") rows)" \
    "$(cmp -s "$W/hosted/want" "$W/hosted/got" && echo same || diff "$W/hosted/want" "$W/hosted/got" | sed -n 2p)" same
else
  echo "  FAIL the pinned Spinel does not compile the hosted prelude with its caller"
  sed 's/^/      /' "$W/hosted/build.out" | head -4
  fail=$((fail + 1))
fi

echo "intrinsics: 8. the shim's failure texts are the hosted prelude's"
mkdir -p "$W/shim"
printf 'def pick(a)\n  a + 1\nend\nputs pick(1)\n' > "$W/shim/s.rb"
"$SPINEL" "$W/shim/s.rb" --core pick --core-id=z --core-map="$W/shim/s.map" --no-line-map -S > /dev/null 2>&1
"$EMIT" --source "$W/shim/s.rb" --core-map "$W/shim/s.map" -o "$W/shim/s.o" --clang "$CC_BIN" \
  --typedump "$READER" --shim-out "$W/shim/shim.c" > "$W/shim/emit.out" 2>&1
grep -o 'sp_abort_uncaught("RangeError", "core_[^"]*")' "$W/shim/shim.c" |
  sed 's/^[^,]*, "//; s/")$//' | sort -u > "$W/shim/texts"
grep -o 'raise RangeError, "[^"]*"' "$HOSTED" | sed 's/^raise RangeError, "//; s/"$//' |
  grep -vxF 'core_u32: the value is outside 0..4294967295' | sort -u > "$W/shim/prelude-texts"
ok "the shim's texts are the prelude's but core_u32's compile-time one ($(grep -c . "$W/shim/texts") texts)" \
  "$(cmp -s "$W/shim/prelude-texts" "$W/shim/texts" && echo same || diff "$W/shim/prelude-texts" "$W/shim/texts" | sed -n 2p)" same

echo "intrinsics: 9. both preludes define exactly the table's names"
grep -o '{"core_[a-z0-9_]*",' "$ROOT/tools/mlir/native/include/spinel-mlir/Core/Intrinsics.h" |
  sed 's/^{"//; s/",$//' | sort > "$W/table-names"
names() { # PRELUDE: whether it defines exactly the table's names
  sed -n 's/^def \(core_[a-z0-9_]*\)(.*/\1/p' "$1" | sort > "$W/prelude-names"
  cmp -s "$W/table-names" "$W/prelude-names" && echo same || diff "$W/table-names" "$W/prelude-names" | sed -n 2p
}
ok "hosted-prelude.rb and intrinsics.rb define the table's $(grep -c . "$W/table-names") names" \
  "$(names "$HOSTED")|$(names "$ROOT/tools/core/intrinsics.rb")" "same|same"

echo "intrinsics: 10. the core emitter embeds the hosted prelude"
"$EMIT" --print-prelude > "$W/embedded.rb" 2> "$W/embedded.err"
ok "spinel-core-emit --print-prelude is tools/core/hosted-prelude.rb" \
  "$(cmp -s "$HOSTED" "$W/embedded.rb" && echo same || echo differs)" same

echo "intrinsics: 11. a source that names no intrinsic gets no prelude"
mkdir -p "$W/plain"
printf 'def pick(a, b)\n  a < b ? a : b\nend\nputs pick(7, 3)\n' > "$W/plain/plain.rb"
picked=$("$EMIT" --print-prelude --for "$W/plain/plain.rb" | wc -c | tr -d ' ')
"$CHECK" "$W/plain/plain.rb" --method pick --typedump "$READER" --inputs-out "$W/plain/ledger" > "$W/plain/check.out" 2>&1
ledger=$(tr '\0' '\n' < "$W/plain/ledger" 2>/dev/null)
real=$(cd "$W/plain" && pwd -P)/plain.rb
ok "no definition is picked, and the checker's ledger names the source itself" \
  "$picked|$([ "$ledger" = "$real" ] && echo source || echo "'$ledger'")" "0|source"

echo "intrinsics: $((pass + fail)) checked, $pass pass, $fail fail; $(( $(date +%s) - T0 )) s"
[ "$fail" = 0 ]
