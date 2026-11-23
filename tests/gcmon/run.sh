#!/bin/sh
#
# tests/gcmon/run.sh — the GC monitoring tools, end to end.
#
#   sh tests/gcmon/run.sh
#
# SPINEL (default vendor/spinel/bin/spinel), CC (default cc), RUBY (default
# ruby) and WAD (see tools/gcmon/run_gcmon_gate.sh) select the tools.
#
# 1. the section probe's properties (probe_properties.rb);
# 2. the probe does not disturb the counters (probe_noninvasive.rb, macOS);
# 3. spinel-gcmon on a small subject that allocates N strings:
#    ab with equal N passes --expect-zero, ab with different N fails it (the
#    control), a subject that is not a Spinel program fails it (no GC counter
#    output is MISSING, not zero), run/flame/stress answer, and --pause is
#    refused as NOT PORTED;
# 4. the DOOM gate: DEMO1 to tic 500 and to tic 5026, every count equal.
#
# Exit 0 when everything passed, 1 on any failure, 2 when nothing failed but
# something was skipped. Sections 2 and 4 need the macOS malloc counter, so on
# any other host they SKIP and the suite exits 2: not a pass.
#
# Nothing here runs another implementation. tools/gcmon/gcmon_stub.rb exists
# for a CRuby differential, which is an oracle; it is not run.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SPINEL="${SPINEL:-$REPO/vendor/spinel/bin/spinel}"
CC="${CC:-cc}"
RUBY="${RUBY:-ruby}"
GCMON="$REPO/tools/gcmon/spinel-gcmon"
export SPINEL CC

pass=0
fail=0
skip=0
W=$(mktemp -d "${TMPDIR:-/tmp}/gcmon-test.XXXXXX")
trap 'rm -rf "$W"' EXIT

# note <rc> <name> [expected rc]: records one check
note() {
  want="${3:-0}"
  if [ "$1" = "$want" ]; then pass=$((pass + 1)); echo "PASS  $2"
  elif [ "$1" = 2 ] && [ "$want" = 0 ]; then skip=$((skip + 1)); echo "SKIP  $2"
  else fail=$((fail + 1)); echo "FAIL  $2 (exit $1, expected $want)"; fi
}

# expect_text <file> <text> <name>
expect_text() {
  if grep -q -- "$2" "$1"; then pass=$((pass + 1)); echo "PASS  $3"
  else fail=$((fail + 1)); echo "FAIL  $3 (no \"$2\" in its output)"; sed 's/^/      /' "$1"; fi
}

echo "== 1. probe properties"
"$RUBY" "$REPO/tests/gcmon/probe_properties.rb"; note $? "probe_properties.rb"

echo "== 2. probe non-invasive"
"$RUBY" "$REPO/tests/gcmon/probe_noninvasive.rb"; note $? "probe_noninvasive.rb"

echo "== 3. spinel-gcmon"
cat > "$W/alloc.rb" <<'RB'
n = ARGV[0].to_i
a = []
i = 0
while i < n
  a << ("z" * 48)
  i += 1
end
puts a.length
RB
if "$SPINEL" "$W/alloc.rb" --cc="$CC" -o "$W/alloc" >"$W/build.log" 2>&1; then
  note 0 "the subject builds"

  "$RUBY" "$GCMON" ab --a "$W/alloc 300" --b "$W/alloc 300" --expect-zero >"$W/ab-same.txt" 2>&1
  note $? "ab: equal work passes --expect-zero"
  expect_text "$W/ab-same.txt" "gc_report" "ab: the GC counter's rows are present"
  expect_text "$W/ab-same.txt" "malloc_count	mallocs" "ab: the malloc counter's rows are present"

  "$RUBY" "$GCMON" ab --a "$W/alloc 300" --b "$W/alloc 600" --expect-zero >"$W/ab-diff.txt" 2>&1
  note $? "ab: 300 more allocations fail --expect-zero (the control)" 1
  expect_text "$W/ab-diff.txt" "^FAIL	gc_report" "ab: the failure names a GC counter row"

  # A C program built here, not a system binary: macOS strips
  # DYLD_INSERT_LIBRARIES from SIP-protected ones such as /usr/bin/true, which
  # would silence both counters. Here only the GC counter is silent.
  printf 'int main(void) { return 0; }\n' > "$W/plain.c"
  "$CC" -o "$W/plain" "$W/plain.c"
  "$RUBY" "$GCMON" ab --a "$W/plain" --b "$W/plain" --expect-zero >"$W/ab-none.txt" 2>&1
  note $? "ab: a non-Spinel subject fails --expect-zero (no GC output is MISSING)" 1
  expect_text "$W/ab-none.txt" "gc_report	(no output)	MISSING" "ab: the silent GC counter is written MISSING"

  "$RUBY" "$GCMON" run -- "$W/alloc" 100 >"$W/run.txt" 2>&1
  note $? "run: exits 0"
  expect_text "$W/run.txt" "malloc_count	mallocs" "run: reports the malloc counter"

  "$RUBY" "$GCMON" flame -- "$W/alloc" 100 -o "$W/out.folded" >"$W/flame.txt" 2>&1
  note $? "flame: exits 0"
  if grep -q '^alloc;.*;.* [0-9][0-9]*$' "$W/out.folded" 2>/dev/null; then
    note 0 "flame: writes per-site folded lines"
  else
    note 1 "flame: writes per-site folded lines"
  fi

  "$RUBY" "$GCMON" stress -- "$W/alloc" 2000 >"$W/stress.txt" 2>&1
  note $? "stress: the subject survives GC_STRESS + VERIFY_GEN"
else
  cat "$W/build.log"
  note 1 "the subject builds"
fi

"$RUBY" "$GCMON" ab --a x --b y --pause >"$W/pause.txt" 2>&1
note $? "ab --pause is refused" 2
expect_text "$W/pause.txt" "NOT PORTED" "the refusal names --pause as NOT PORTED"
"$RUBY" "$GCMON" run --pause -- /usr/bin/true >"$W/pause2.txt" 2>&1
note $? "run --pause is refused" 2

echo "== 4. DOOM gate"
sh "$REPO/tools/gcmon/run_gcmon_gate.sh"; note $? "run_gcmon_gate.sh"

echo "---- gcmon: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ] || exit 1
[ "$skip" = 0 ] || exit 2
