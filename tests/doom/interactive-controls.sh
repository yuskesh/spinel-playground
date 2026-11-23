#!/bin/sh
#
# tests/doom/interactive-controls.sh — the rules tests/doom/interactive.sh
# relies on actually reject.
#
#   tests/doom/interactive-controls.sh
#
# Two things are controlled here, both cheap and neither needing SDL, a WAD or a
# build: the frame-stream comparison, and build.sh's refusals about where it is
# asked to write.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CMP="$ROOT/tests/doom/compare-frame-streams.sh"
BUILD="$ROOT/examples/doom/build.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/doom-ictl.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
pass=0; fail=0

# A frame-hash stream of n tics, in the shape sim_demo and doom -frames write.
mkstream() { # $1 path  $2 n  [$3 tic to corrupt]  [$4 replacement hash]
  {
    printf '#gametic\tviewhash\tfullhash\n'
    i=0
    while [ "$i" -lt "$2" ]; do
      if [ "${3:-}" = "$i" ]; then
        printf '%d\t%s\t%s\n' "$i" "$4" "$4"
      else
        printf '%d\t%016x\t%016x\n' "$i" "$((i * 7 + 1))" "$((i * 13 + 2))"
      fi
      i=$((i + 1))
    done
  } > "$1"
}

check() { # $1 label  $2 want ("" = expect success)  $3 a  $4 b  $5 ntics
  label="$1"; want="$2"
  log="$WORK/$(echo "$label" | tr -c 'a-zA-Z0-9' '_').log"
  set +e
  "$CMP" "$3" "$4" "$5" > "$log" 2>&1
  rc=$?
  set -e
  if [ -z "$want" ]; then
    if [ "$rc" -eq 0 ]; then echo "pass $label (exit 0, as required)"; pass=$((pass + 1))
    else echo "FAIL $label: expected success, got exit $rc"; sed 's/^/    /' "$log" | tail -4; fail=$((fail + 1)); fi
    return
  fi
  if [ "$rc" -eq 0 ]; then echo "FAIL $label: exited 0; it must fail"; fail=$((fail + 1)); return; fi
  if ! grep -Eq "$want" "$log"; then
    echo "FAIL $label: exited $rc but never said /$want/"; sed 's/^/    /' "$log" | tail -4; fail=$((fail + 1)); return
  fi
  echo "pass $label (exit $rc, diagnosed: $(grep -Eoh "$want" "$log" | head -1))"
  pass=$((pass + 1))
}

N=50
mkstream "$WORK/a.tsv" "$N"
mkstream "$WORK/b.tsv" "$N"

# 1. the honest case
check "1 identical full streams" "" "$WORK/a.tsv" "$WORK/b.tsv" "$N"

# 2. BOTH truncated at the tail, identically.  This is the one that used to
#    pass: the files are equal, so a byte comparison is satisfied, and almost
#    nothing was compared.
mkstream "$WORK/t1.tsv" 10
mkstream "$WORK/t2.tsv" 10
check "2 both truncated at the tail" "10 rows, expected exactly 50" "$WORK/t1.tsv" "$WORK/t2.tsv" "$N"

# 3. BOTH truncated at the head, identically: the right number of rows, the
#    wrong tics.  A count check alone would let this through.
head -1 "$WORK/a.tsv" > "$WORK/h1.tsv"
awk -F'\t' '!/^#/ && $1 >= 5' "$WORK/a.tsv" >> "$WORK/h1.tsv"
i=$N; while [ "$i" -lt $((N + 5)) ]; do printf '%d\t%016x\t%016x\n' "$i" "$((i * 7 + 1))" "$((i * 13 + 2))" >> "$WORK/h1.tsv"; i=$((i + 1)); done
cp "$WORK/h1.tsv" "$WORK/h2.tsv"
check "3 both shifted off the start" "row 0 has gametic 5, expected 0" "$WORK/h1.tsv" "$WORK/h2.tsv" "$N"

# 4. one hash differs
mkstream "$WORK/d.tsv" "$N" 25 deadbeefdeadbeef
check "4 one frame differs" "the two streams differ" "$WORK/a.tsv" "$WORK/d.tsv" "$N"

# 5. a gap in the middle
grep -v '^25	' "$WORK/a.tsv" > "$WORK/g.tsv"
check "5 a missing tic" "49 rows, expected exactly 50" "$WORK/a.tsv" "$WORK/g.tsv" "$N"

# 6. an empty stream
head -1 "$WORK/a.tsv" > "$WORK/e.tsv"
check "6 no data rows" "0 rows, expected exactly 50" "$WORK/a.tsv" "$WORK/e.tsv" "$N"

# 7. build.sh must refuse to write its executable over a directory, and must do
#    so BEFORE consulting a compiler or SDL -- this is a question about the
#    arguments.  The control therefore passes no LLVM_PREFIX, no CC and no
#    SPINEL: if it needed them it would not be the self-contained control this
#    file claims to hold, which is what macOS measured when case 7 reached for a
#    Linux path that does not exist there.
mkdir -p "$WORK/outdir"
log="$WORK/7.log"
set +e
env -u CC -u LLVM_PREFIX -u SPINEL OUT="$WORK/outdir" BUILD_DIR="$WORK/bd" "$BUILD" > "$log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL 7 OUT is a directory: exited 0; it must fail"; fail=$((fail + 1))
elif ! grep -q "is a directory" "$log"; then
  echo "FAIL 7 OUT is a directory: exited $rc but never said so"; sed 's/^/    /' "$log" | tail -4; fail=$((fail + 1))
elif [ "$(head -1 "$log")" != "$(grep -m1 'is a directory' "$log")" ]; then
  echo "FAIL 7 OUT is a directory: the refusal was not the first thing said, so something was consulted first:"
  sed 's/^/    /' "$log" | head -4
  fail=$((fail + 1))
else
  echo "pass 7 OUT is a directory, refused before any dependency (exit $rc)"
  pass=$((pass + 1))
fi

echo "interactive-controls: $((pass + fail)) run, $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
