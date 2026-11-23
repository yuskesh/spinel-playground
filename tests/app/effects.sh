#!/bin/sh
#
# tests/app/effects.sh -- decision 0014, Task 4: effects, call counts,
# evidence and the version 2 report.
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/app/effects.sh
#
# Every report here is an admission-only report of a version 2 entry: the
# kernel with --admit-only --report, bound to a configuration by
# --config-binding. Its `application` object is what the checks read.
#
#   1. The write set: a buffer written directly, one written through a helper's
#      parameter, one written through an `inout` extern argument, and one only
#      read, say written / written / written / not written.
#   2. Call counts: two sequential calls 2; loops of 2 and 3 in sequence 5; a
#      call in a loop of 3 inside a helper called twice 6; a call in each arm of
#      a conditional 2.
#   3. Evidence: bound evidence of 24 bytes is an attestation of 24 bytes, and
#      on the stack tool a declared callee with 24 attested bytes adds exactly
#      24 to the path; evidence that is missing, for another target, bound to
#      another configuration, or naming another symbol makes extern_effects
#      `unknown` with a named reason, and the stack tool refuses a declared
#      callee with no attested bytes.
#   4. Reports: every v2 report validates against the v2 schema, the v1 schema
#      refuses it, and a damaged copy is refused; a version 1 report is still
#      version 1 (tests/core-report/run.sh keeps its goldens).
#
# KERNEL, STACK_TOOL, SPINEL_TYPEDUMP, CLANG (or LLVM_PREFIX) and RUBY select
# the tools.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/app/fixtures/effects"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
STACK_TOOL="${STACK_TOOL:-$ROOT/tools/mlir/native/build/bin/spinel-core-stack}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
SCHEMA2="$ROOT/tools/mlir/native/schema/core-report-v2.schema.json"
SCHEMA1="$ROOT/tools/mlir/native/schema/core-report-v1.schema.json"
CHECK="$ROOT/tests/core-report/check.rb"
RUBY="${RUBY:-ruby}"
die() { echo "effects: $*" >&2; exit 1; }
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL"
[ -x "$STACK_TOOL" ] || die "no spinel-core-stack at $STACK_TOOL"
[ -x "$READER" ] || die "no contract reader at $READER (set SPINEL_TYPEDUMP)"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"

W=$(mktemp -d "${TMPDIR:-/tmp}/app-effects.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
BINDING=$(cat "$FIX/binding.txt")
# The evidence fixtures name the host's triple, which differs per host; the
# files are staged with it filled in.
TARGET=$("$CC_BIN" -print-target-triple)
mkdir -p "$W/fix/e"
cp "$FIX"/*.rb "$FIX"/*.contract "$W/fix/"
for f in "$FIX"/e/*.json; do sed "s/HOSTTARGET/$TARGET/" "$f" > "$W/fix/e/$(basename "$f")"; done

# report ENTRY-CONTRACT: an admission-only report, path printed
report() {
  "$KERNEL" "$W/fix/$1.contract" --root "$W/fix" --admit-only --clang "$CC_BIN" --typedump "$READER" \
    --report "$W/$1.json" --profile realtime --config-binding "$BINDING" > "$W/$1.log" 2>&1 ||
    die "$1 did not report; see $W/$1.log"
  echo "$W/$1.json"
}
field() { # report ruby-expression over j
  "$RUBY" -rjson -e 'j = JSON.parse(File.read(ARGV[0])); puts(eval(ARGV[1]))' "$1" "$2"
}

echo "effects: 1. the write set"
R=$(report writes)
ok "direct, via helper, via inout extern, read-only" \
   "$(field "$R" 'j["application"]["buffers"].map { |b| "#{b["name"]}=#{b["written"]}" }.join(" ")')" \
   "direct=true viahelper=true viaextern=true ro=false"

echo "effects: 2. call counts"
for pair in c_seq:2 c_loops:5 c_helper:6 c_cond:2; do
  e=${pair%%:*}; want=${pair#*:}
  R=$(report "$e")
  ok "$e counts $want" "$(field "$R" 'e = j["application"]["externs"][0]; "#{e["calls"]}/#{e["calls_derived"]}"')" "$want/true"
done
ok "c_helper: two sites, both through the helper" \
   "$(field "$W/c_helper.json" 'j["application"]["work_bound"]["extern_terms"].map { |t| t["context"].join(">") }.join(" ")')" \
   "call:twice@34:2>loop:twice#0>extern:Adc.latest@7:13 call:twice@35:2>loop:twice#0>extern:Adc.latest@7:13"

echo "effects: 2b. an extern whose bound is unknown (decision 0021, owner 2026-10-20)"
# c_unknown is c_seq with the extern's bound `iterations unknown "<reason>"`:
# the entry's own work still derives, and its loop_bound is unknown, naming
# the extern and the reason. c_seq, with `iterations 1`, is the control.
R=$(report c_unknown)
ok "c_unknown: loop_bound is unknown, naming Adc.latest and its reason" \
   "$(field "$R" 'l = j["properties"]["loop_bound"]; "#{l["verdict"]}|#{l["work_bound"]["expression"].nil? ? "no-work" : "work"}|" + l["unknown_externs"].map { |u| "#{u["extern"]}: #{u["reason"]}" }.join(";")')" \
   "unknown|work|Adc.latest: a converter wait with no derived bound"
ok "and its extern carries the bound and the reason" \
   "$(field "$R" 'e = j["application"]["externs"][0]; "#{e["bound"]}|#{e["bound_reason"]}"')" \
   'iterations unknown "a converter wait with no derived bound"|a converter wait with no derived bound'
ok "control: c_seq, the same entry with a derived extern bound, passes loop_bound and names no unknown extern" \
   "$(field "$(report c_seq)" 'l = j["properties"]["loop_bound"]; "#{l["verdict"]}|#{l.key?("unknown_externs")}"')" "pass|false"

echo "effects: 3. evidence"
R=$(report c_seq)
ok "bound evidence of 24 bytes is an attestation of 24 bytes" \
   "$(field "$R" 's = j["application"]["externs"][0]["stack"]; "#{s["bytes"]}/#{s["evidence"]}"')" "24/attestation"
ok "and extern_effects passes" "$(field "$R" 'j["properties"]["extern_effects"]["verdict"]')" pass
for v in missing:"cannot be read" other-target:"another target|for target" other-config:"another configuration" wrong-symbol:"names symbol"; do
  name=${v%%:*}; pat=${v#*:}
  R=$(report "ev-$name")
  ok "evidence $name: unknown, with its reason" \
     "$(field "$R" 'p = j["properties"]["extern_effects"]; "#{p["verdict"]}/#{p["reasons"].size}"'):$(field "$R" 'j["properties"]["extern_effects"]["reasons"][0]' | grep -cE "$pat")" "unknown/1:1"
done
ok "the stack tool adds exactly 24 attested bytes to the path" \
   "$("$STACK_TOOL" "$FIX/attested.ll" --clang "$CC_BIN" --profile hosted-stage2 --attested spc_board_adc_latest=24 2>/dev/null | sed -n 's/^kernel_stack: //p')" \
   "$(( $("$STACK_TOOL" "$FIX/attested.ll" --clang "$CC_BIN" --profile hosted-stage2 --attested spc_board_adc_latest=0 2>/dev/null | sed -n 's/^kernel_stack: //p') + 24 ))"
ok "control: a declared callee with no attested bytes refuses the path" \
   "$("$STACK_TOOL" "$FIX/attested.ll" --clang "$CC_BIN" --profile hosted-stage2 2>/dev/null | grep -c 'only declared in this IR and has no bound stack evidence')" 1
ok "control: the report needs --config-binding" \
   "$("$KERNEL" "$W/fix/c_seq.contract" --root "$W/fix" --admit-only --clang "$CC_BIN" --typedump "$READER" --report "$W/nb.json" --profile realtime > "$W/nb.log" 2>&1 && echo accepted || grep -c 'needs --config-binding' "$W/nb.log")" 1

echo "effects: 4. the reports"
ok "every v2 report validates against the v2 schema" \
   "$("$RUBY" "$CHECK" --schema "$SCHEMA2" --validate "$W"/*.json 2>&1 | tail -1)" "check: $(ls "$W"/*.json | wc -l | tr -d ' ') passed, 0 failed"
ok "the v1 schema refuses a v2 report" "$("$RUBY" "$CHECK" --schema "$SCHEMA1" --validate "$W/c_seq.json" > /dev/null 2>&1 && echo accepted || echo refused)" refused
"$RUBY" -rjson -e 'j = JSON.parse(File.read(ARGV[0])); j["application"]["externs"][0]["calls"] = 2; File.write(ARGV[1], JSON.generate(j))' "$W/c_seq.json" "$W/damaged.json"
ok "control: a damaged v2 report is refused" "$("$RUBY" "$CHECK" --schema "$SCHEMA2" --validate "$W/damaged.json" > /dev/null 2>&1 && echo accepted || echo refused)" refused
ok "the report says version 2 and carries no object" "$(field "$W/c_seq.json" '"#{j["version"]}/#{j["object"].inspect}"')" "2/nil"

# DECISION 0014 D5: a board constant as an extern argument reaches const_args
# with its VALUE, exactly as a literal does -- the checks that decide device
# ownership and guard satisfaction read that value and nothing else.
R=$(report c_const)
ok "board constant arguments are reported as their values, one entry per site (Adc::CH0 then Adc::CH1)" \
   "$(field "$R" 'e = j["application"]["externs"][0]; "#{e["const_args"].inspect}/#{e["sites"]}"')" "[[0], [1]]/2"

echo
echo "effects: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" = 0 ] || exit 1
