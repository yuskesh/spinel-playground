#!/bin/sh
#
# tests/gcviz/run.sh -- the collector's event record (decision 0036), end to
# end on tools/gcviz/example.rb.
#
#   sh tests/gcviz/run.sh
#
# CC (default cc), RUBY (default ruby) and LLVM_SYMBOLIZER (default: the one
# beside CC, else llvm-symbolizer) select the tools; the events
# runtime must be built (`make events-runtime` in vendor/spinel, see
# docs/building.md).
#
# 1. the regular build of the example ignores SPINEL_GC_EVENTS: it prints the
#    same answer and writes no file;
# 2. the events build prints the same answer, and its record at a 16 KB fixed
#    budget replays cleanly: nothing dropped, every sweep and survival names a
#    live slot, the census at exit names every slot the replay left live, and
#    there are collections, promotions and sweeps to see; every allocation
#    carries the stack that made it, which resolves to the line of
#    example.rb that allocated it (Particles on lines 26 and 28, and line
#    27's String, which since the 2026-11-14 upstream synchronisation is a
#    String handle object, not a string allocation), and each collection to
#    the line whose allocation started it;
# 3. controls: a record capped below its length (dropped records), and copies
#    with a planted orphan sweep, a missing census, a doubled allocation and
#    an allocation without its stack, each fail the replay check;
# 4. the same program with the slab off (SPINEL_GC_SLAB=0), then with aging
#    (SPINEL_GC_AGE=1): its blocks are malloc'd, reused from pools and swept
#    from lists, the record replays cleanly, the allocations resolve to the
#    same lines, only aging keeps survivors young, and copies with a planted
#    orphan list sweep or an unrecorded pool reuse fail the check.
#
# Exit 0 when everything passed, 1 on any failure. Nothing here runs another
# implementation.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SPINEL="$REPO/vendor/spinel/bin/spinel"
CC="${CC:-cc}"
RUBY="${RUBY:-ruby}"
EVENTS="$REPO/tools/gcviz/gcviz-events.rb"
export CC
if [ -z "${LLVM_SYMBOLIZER:-}" ]; then
  LLVM_SYMBOLIZER=llvm-symbolizer
  ccdir=$(dirname -- "$(command -v "$CC" 2>/dev/null || echo "$CC")")
  [ -x "$ccdir/llvm-symbolizer" ] && LLVM_SYMBOLIZER="$ccdir/llvm-symbolizer"
fi
export LLVM_SYMBOLIZER

pass=0
fail=0
T=$(mktemp -d "${TMPDIR:-/tmp}/gcviz-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

ok() { pass=$((pass + 1)); echo "PASS  $1"; }
ng() { fail=$((fail + 1)); echo "FAIL  $1"; }

# each allocation resolves to the line that made it, each collection to the
# line whose allocation started it: check_lines LABEL JSON
check_lines() {
  "$RUBY" -rjson -e '
  j = JSON.parse(File.read(ARGV[0]))
  by = ->(kind, scan) { j["lives"].select { |l| l["kind"] == kind && (scan.nil? || l["scan"] == scan) }.map { |l| l["lines"].first }.tally.sort.map { |k, v| "#{k}:#{v}" }.join(",") }
  puts "source #{File.basename(j["source"].to_s)}"
  puts "unlined #{j["lives"].count { |l| l["lines"].empty? }}"
  puts "objects #{by.("alloc_obj", "none")}"
  puts "strings #{by.("alloc_str", nil)}"
  puts "cycles-unlined #{j["cycles"].count { |c| c["lines"].empty? }}"' "$2" >"$T/lines.txt" 2>&1
  # Re-pinned at the 2026-11-14 upstream synchronisation (f8ff01939): a String
  # local is a mutable handle there (SP_STR_HDL), so line 27's 80 Strings are
  # handle objects, allocated as objects with no scan like the Particles, and
  # nothing in example.rb allocates a string any more (baddd25a9 measured
  # "particles 26:2400,28:14" and "strings 27:80").
  for want in "source example.rb" "unlined 0" "objects 26:2400,27:80,28:14" "strings " "cycles-unlined 0"; do
    if grep -qx "$want" "$T/lines.txt"; then ok "$1 lines: $want"; else ng "$1 lines: expected '$want'"; sed 's/^/      /' "$T/lines.txt"; fi
  done
}

echo "== 1. the regular build"
if "$SPINEL" "$REPO/tools/gcviz/example.rb" -o "$T/plain" >"$T/plain.log" 2>&1; then
  out=$(cd "$T" && SPINEL_GC_EVENTS="$T/plain.bin" ./plain)
  [ "$out" = 6 ] && ok "regular build prints 6" || ng "regular build printed '$out', expected 6"
  [ ! -e "$T/plain.bin" ] && ok "regular build writes no events file" || ng "regular build wrote $T/plain.bin"
else
  ng "regular build of example.rb"; sed 's/^/      /' "$T/plain.log"
fi

echo "== 2. the events build"
if sh "$REPO/tools/gcviz/gcviz-build" "$REPO/tools/gcviz/example.rb" "$T/ev" >"$T/ev.log" 2>&1; then
  ok "gcviz-build example.rb"
  out=$(cd "$T" && SPINEL_GC_THRESHOLD_KB=16 SPINEL_GC_OBJ_BUDGET=fixed SPINEL_GC_EVENTS="$T/ev.bin" ./ev)
  [ "$out" = 6 ] && ok "events build prints 6" || ng "events build printed '$out', expected 6"
  if "$RUBY" "$EVENTS" check "$T/ev.bin" >"$T/check.log" 2>&1; then ok "replay check"; else ng "replay check"; sed 's/^/      /' "$T/check.log"; fi
  "$RUBY" "$EVENTS" summary "$T/ev.bin" >"$T/summary.txt" 2>&1
  for k in cycle swept survived0 survived1 census mark; do
    n=$(awk -v k="$k" '$2 == k { print $3 }' "$T/summary.txt")
    [ "${n:-0}" -gt 0 ] && ok "record has $k events ($n)" || ng "record has no $k events"
  done
  n=$(awk '$2 == "mark" { print $3 }' "$T/summary.txt")
  [ "$n" = 41 ] && ok "41 marks, one per round and one before" || ng "marks: '$n', expected 41"
  if "$RUBY" "$EVENTS" json "$T/ev.bin" "$T/ev" >"$T/ev.json" 2>"$T/json.log" &&
     "$RUBY" -rjson -e 'j = JSON.parse(File.read(ARGV[0])); exit(j["lives"].any? { |l| l["scan"] == "sp_PtrArray_gc_scan" } ? 0 : 1)' "$T/ev.json"; then
    ok "json names the batch arrays' class by its scan function"
    check_lines events "$T/ev.json"
  else
    ng "json names no sp_PtrArray_gc_scan object"; sed 's/^/      /' "$T/json.log"
  fi

  echo "== 3. controls"
  (cd "$T" && SPINEL_GC_THRESHOLD_KB=16 SPINEL_GC_OBJ_BUDGET=fixed SPINEL_GC_EVENTS_MAX=100 SPINEL_GC_EVENTS="$T/cap.bin" ./ev >/dev/null)
  if "$RUBY" "$EVENTS" check "$T/cap.bin" >"$T/cap.log" 2>&1; then ng "a capped record passed the check"
  elif grep -q 'records dropped' "$T/cap.log"; then ok "a capped record fails by its dropped count"
  else ng "a capped record failed for another reason"; sed 's/^/      /' "$T/cap.log"; fi
  for kind in orphan-sweep no-census double-alloc no-site; do
    "$RUBY" "$REPO/tests/gcviz/plant.rb" "$kind" "$T/ev.bin" "$T/$kind.bin"
    if "$RUBY" "$EVENTS" check "$T/$kind.bin" >"$T/$kind.log" 2>&1; then ng "planted $kind passed the check"
    else ok "planted $kind fails the check: $(head -1 "$T/$kind.log")"; fi
  done

  echo "== 4. the slab off, and with aging"
  for run in off age; do
    if [ "$run" = off ]; then vars=SPINEL_GC_SLAB=0; else vars="SPINEL_GC_SLAB=0 SPINEL_GC_AGE=1"; fi
    # shellcheck disable=SC2086
    out=$(cd "$T" && env $vars SPINEL_GC_THRESHOLD_KB=16 SPINEL_GC_OBJ_BUDGET=fixed SPINEL_GC_EVENTS="$T/$run.bin" ./ev)
    [ "$out" = 6 ] && ok "$run: prints 6" || ng "$run: printed '$out', expected 6"
    if "$RUBY" "$EVENTS" check "$T/$run.bin" >"$T/$run-check.log" 2>&1; then ok "$run: replay check"; else ng "$run: replay check"; sed 's/^/      /' "$T/$run-check.log"; fi
    "$RUBY" "$EVENTS" summary "$T/$run.bin" >"$T/$run-summary.txt" 2>&1
    # No malloc_str since the synchronisation: example.rb's Strings are handle
    # objects (see check_lines).
    for k in malloc_obj malloc_pool swept survived_list cycle; do
      n=$(awk -v k="$k" '$2 == k { print $3 }' "$T/$run-summary.txt")
      [ "${n:-0}" -gt 0 ] && ok "$run: record has $k events ($n)" || ng "$run: record has no $k events"
    done
    for k in alloc_obj census; do
      n=$(awk -v k="$k" '$2 == k { print $3 }' "$T/$run-summary.txt")
      [ -z "$n" ] && ok "$run: no $k events (nothing in the slab)" || ng "$run: $n $k events with the slab off"
    done
    # young survivors kept young by aging (what 32, aux 0) appear only with aging on
    kept=$("$RUBY" -e 'd = File.binread(ARGV[0]); n = d.unpack1("Q<", offset: 16)
      puts (0...n).count { |i| d.unpack("S<S<", offset: 32 + i * 32 + 28) == [32, 0] }' "$T/$run.bin")
    if [ "$run" = off ]; then
      [ "$kept" = 0 ] && ok "$run: no survivor kept young" || ng "$run: $kept survivors kept young without aging"
    else
      [ "$kept" -gt 0 ] && ok "$run: survivors kept young ($kept)" || ng "$run: no survivor kept young with aging"
    fi
    if "$RUBY" "$EVENTS" json "$T/$run.bin" "$T/ev" >"$T/$run.json" 2>"$T/$run-json.log"; then
      check_lines "$run" "$T/$run.json"
    else
      ng "$run: json"; sed 's/^/      /' "$T/$run-json.log"
    fi
  done
  for kind in orphan-sweep no-pool; do
    "$RUBY" "$REPO/tests/gcviz/plant.rb" "$kind" "$T/off.bin" "$T/off-$kind.bin"
    if "$RUBY" "$EVENTS" check "$T/off-$kind.bin" >"$T/off-$kind.log" 2>&1; then ng "off: planted $kind passed the check"
    else ok "off: planted $kind fails the check: $(head -1 "$T/off-$kind.log")"; fi
  done
else
  ng "gcviz-build example.rb"; sed 's/^/      /' "$T/ev.log"
fi

echo "gcviz: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
