#!/bin/sh
#
# tests/doom/compare-controls.sh — prove that tests/doom/compare.rb rejects.
#
#   RUBY=ruby tests/doom/compare-controls.sh <candidate-dir> <ntics>
#
# Decision 0006 task 3 asks for comparison failures to be proven with empty
# output, a deleted frame, a duplicated frame, a changed game-state row and a
# changed frame outside a recorded discrepancy, and for failure reasons to be
# asserted so that a missing tool cannot masquerade as a successful negative
# control.  All of that is here, plus the cases that keep an allowance list
# honest and the call-site check that the random stream depends on.
#
# The reference side is synthesised by tests/doom/oracle/make-fixture.rb from
# the candidate's own output.  That makes every control a test OF THE
# COMPARATOR and of nothing else -- see tests/doom/oracle/README.md.  It is how
# these can run on a host with no C reference implementation, which Debian is.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RUBY="${RUBY:-ruby}"
CAND="${1:?usage: compare-controls.sh <candidate-dir> <ntics>}"
NTICS="${2:?usage: compare-controls.sh <candidate-dir> <ntics>}"
CMP="$ROOT/tests/doom/compare.rb"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/doom-cmpctl.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

command -v "$RUBY" >/dev/null 2>&1 || { echo "compare-controls: no ruby '$RUBY'" >&2; exit 1; }
[ -d "$CAND" ] || { echo "compare-controls: no candidate directory at $CAND" >&2; exit 1; }

pass=0; fail=0

base="$WORK/ref-base"
"$RUBY" "$ROOT/tests/doom/oracle/make-fixture.rb" "$CAND" "$base" >/dev/null

mkref()  { r="$WORK/$1"; rm -rf "$r"; cp -r "$base" "$r"; echo "$r"; }
mkcand() { c="$WORK/$1"; rm -rf "$c"; cp -r "$CAND" "$c"; echo "$c"; }

# $1 label  $2 want-regex ("" = expect success)  $3 refdir  $4 allowances-or-empty
check() {
  label="$1"; want="$2"; ref="$3"; allow="${4:-}"; cnd="${CTL_CAND:-$CAND}"
  log="$WORK/$(echo "$label" | tr -c 'a-zA-Z0-9' '_').log"
  set +e
  if [ -n "$allow" ]; then
    "$RUBY" "$CMP" --reference "$ref" --candidate "$cnd" --ntics "$NTICS" --allowances "$allow" > "$log" 2>&1
  else
    "$RUBY" "$CMP" --reference "$ref" --candidate "$cnd" --ntics "$NTICS" > "$log" 2>&1
  fi
  rc=$?
  set -e
  if [ -z "$want" ]; then
    if [ "$rc" -eq 0 ]; then
      echo "pass $label (exit 0, as required)"; pass=$((pass + 1))
    else
      echo "FAIL $label: expected success, got exit $rc"; sed 's/^/    /' "$log" | tail -6; fail=$((fail + 1))
    fi
    return
  fi
  if [ "$rc" -eq 0 ]; then
    echo "FAIL $label: the comparator exited 0; it must fail"; fail=$((fail + 1)); return
  fi
  if ! grep -Eq "$want" "$log"; then
    echo "FAIL $label: exited $rc but never said /$want/ -- it failed for the wrong reason"
    sed 's/^/    /' "$log" | tail -6; fail=$((fail + 1)); return
  fi
  echo "pass $label (exit $rc, diagnosed: $(grep -Eoh "$want" "$log" | head -1))"
  pass=$((pass + 1))
}

# 0. the unmutated fixture must agree, or every control below is vacuous.  The
# fixture deliberately contains a mid-run gametic carrying two reference frames
# as well as the 41-frame wipe, so this is also the POSITIVE control for
# "several frames on one gametic is correct reference output".
check "0 unmutated fixture agrees" "" "$base"
base_log="$WORK/$(echo "0 unmutated fixture agrees" | tr -c 'a-zA-Z0-9' '_').log"
if grep -q "gametic(s) carry several reference frames" "$base_log"; then
  echo "pass 0b several frames on one gametic accepted ($(grep -o '[0-9]* gametic(s) carry several reference frames' "$base_log" | head -1))"
  pass=$((pass + 1))
else
  echo "FAIL 0b: the fixture did not exercise a multi-frame gametic, so control 11 proves nothing"
  fail=$((fail + 1))
fi

# 1. empty output
r=$(mkref c1); : > "$r/player.tsv"
check "1 empty stream file" "player/reference: .* is empty" "$r"

# 2. a stream file that is not there at all
r=$(mkref c2); rm -f "$r/frames.tsv"
check "2 missing stream file" "frames/reference: no such file" "$r"

# 3. a gametic missing from the reference, with the frame ids RENUMBERED so the
# sequence stays contiguous.  Deleting a row on its own leaves an id gap, which
# control 19 covers; renumbering isolates the coverage rule from the id rule, so
# each is shown to fire on its own rather than one masking the other.
r=$(mkref c3)
"$RUBY" -e '
  p = ARGV[0]; g = ARGV[1]
  lines = File.binread(p).split("\n", -1)
  kept = lines.reject { |l| !l.start_with?("#") && l.split("\t")[1] == g }
  n = -1
  kept.map! do |l|
    next l if l.empty? || l.start_with?("#")
    f = l.split("\t", -1); f[0] = (n += 1).to_s; f.join("\t")
  end
  File.binwrite(p, kept.join("\n"))
' "$r/frames.tsv" 100
check "3 gametic missing from the reference" "frames: 1 gametic\(s\) missing from the reference" "$r"

# 4. a duplicated RECORD.  The record identity is the frame number, not the
# gametic: several frames legitimately share a gametic (control 0b), but the
# same frame number twice is a corrupt dump.  Copying the row verbatim is what
# makes this the duplicate-record case rather than the multi-frame case.
r=$(mkref c4)
"$RUBY" -e '
  p = ARGV[0]; g = ARGV[1]
  lines = File.binread(p).split("\n", -1)
  i = lines.index { |l| !l.start_with?("#") && l.split("\t")[1] == g }
  lines.insert(i + 1, lines[i])
  File.binwrite(p, lines.join("\n"))
' "$r/frames.tsv" 120
check "4 duplicated frame record" "frame id [0-9]+ appears twice" "$r"

# 5. a changed game-state row
r=$(mkref c5)
"$RUBY" -e '
  p = ARGV[0]
  lines = File.binread(p).split("\n", -1)
  i = lines.index { |l| !l.start_with?("#") && l.split("\t")[0] == "150" }
  f = lines[i].split("\t", -1); f[9] = (Integer(f[9], 10) + 1).to_s
  lines[i] = f.join("\t")
  File.binwrite(p, lines.join("\n"))
' "$r/player.tsv"
check "5 changed game-state row" "player: first mismatch at row .*gametic 150" "$r"

# 6. a changed frame, outside any declared discrepancy
r=$(mkref c6)
"$RUBY" -e '
  p = ARGV[0]; g = ARGV[1]
  lines = File.binread(p).split("\n", -1)
  i = lines.index { |l| !l.start_with?("#") && l.split("\t")[1] == g }
  f = lines[i].split("\t", -1); f[3] = "deadbeefdeadbeef"
  lines[i] = f.join("\t")
  File.binwrite(p, lines.join("\n"))
' "$r/frames.tsv" 200
check "6 changed frame" "frames: first mismatch at gametic 200" "$r"

# 7. keys out of order
r=$(mkref c7)
"$RUBY" -e '
  p = ARGV[0]
  lines = File.binread(p).split("\n", -1)
  i = lines.index { |l| !l.start_with?("#") && l.split("\t")[0] == "200" }
  lines[i], lines[i + 1] = lines[i + 1], lines[i]
  File.binwrite(p, lines.join("\n"))
' "$r/player.tsv"
check "7 keys out of order" "player/reference: keys are not increasing" "$r"

# 8. a real difference at a DECLARED gametic, with the declaration PINNING the
# reference value, the candidate value and the field.  Declaring only the tic
# would excuse whatever went wrong there; controls 8b and 8c are what prove it
# does not.
r=$(mkref c8)
"$RUBY" -e '
  p = ARGV[0]; g = ARGV[1]
  lines = File.binread(p).split("\n", -1)
  i = lines.index { |l| !l.start_with?("#") && l.split("\t")[1] == g }
  f = lines[i].split("\t", -1); f[3] = "1111111111111111"
  lines[i] = f.join("\t")
  File.binwrite(p, lines.join("\n"))
' "$r/frames.tsv" 250
CV=$("$RUBY" -e '
  p = ARGV[0]; t = ARGV[1]
  l = File.binread(p).split("\n", -1).find { |x| !x.start_with?("#") && x.split("\t")[0] == t }
  print l.split("\t", -1)[1]
' "$CAND/frames.tsv" 249)
printf 'frames\t250\tviewhash\t1111111111111111\t%s\tsynthetic control: a declared discrepancy\n' "$CV" > "$WORK/allow8.tsv"
check "8 declared discrepancy tolerated" "" "$r" "$WORK/allow8.tsv"

# 8b. the SAME declared gametic, but a different reference value than the one
# declared.  A new wrong value at a tolerated tic is a new defect.
r=$(mkref c8b)
"$RUBY" -e '
  p = ARGV[0]; g = ARGV[1]
  lines = File.binread(p).split("\n", -1)
  i = lines.index { |l| !l.start_with?("#") && l.split("\t")[1] == g }
  f = lines[i].split("\t", -1); f[3] = "2222222222222222"
  lines[i] = f.join("\t")
  File.binwrite(p, lines.join("\n"))
' "$r/frames.tsv" 250
check "8b different value at a declared tic" "which is not what happened" "$r" "$WORK/allow8.tsv"

# 8c. a declared row-stream discrepancy, and then a SECOND field of the same row
# also differing.  The observed difference set must equal the declared set, not
# merely contain it.
r=$(mkref c8c)
"$RUBY" -e '
  p = ARGV[0]
  lines = File.binread(p).split("\n", -1)
  hdr = lines.find { |l| l.start_with?("#") }[1..].split("\t", -1)
  i = lines.index { |l| !l.start_with?("#") && l.split("\t")[0] == "300" }
  f = lines[i].split("\t", -1)
  f[9]  = (Integer(f[9], 10) + 1).to_s
  f[10] = (Integer(f[10], 10) + 1).to_s
  lines[i] = f.join("\t")
  File.binwrite(p, lines.join("\n"))
  File.write(ARGV[1], [hdr[9], f[9], hdr[10], f[10]].join("\n"))
' "$r/player.tsv" "$WORK/c8c.info"
C9=$("$RUBY" -e '
  l = File.binread(ARGV[0]).split("\n", -1).find { |x| !x.start_with?("#") && x.split("\t")[0] == "300" }
  f = l.split("\t", -1); print [f[9], f[10]].join("\t")
' "$CAND/player.tsv")
H9=$(sed -n 1p "$WORK/c8c.info"); R9=$(sed -n 2p "$WORK/c8c.info")
{ printf 'player\t300\t%s\t%s\t%s\tsynthetic control: only one field is declared\n' \
    "$H9" "$R9" "$(printf '%s' "$C9" | cut -f1)"; } > "$WORK/allow8c.tsv"
check "8c undeclared second field at a declared tic" "is not it" "$r" "$WORK/allow8c.tsv"

# 9. a declared discrepancy that does NOT occur is itself reported
printf 'frames\t251\tviewhash\taaaaaaaaaaaaaaaa\tbbbbbbbbbbbbbbbb\tsynthetic control: should be stale\n' > "$WORK/allow9.tsv"
check "9 stale allowance reported" "did not occur" "$base" "$WORK/allow9.tsv"

# 10. the call-site check: same value and index, different call site
r=$(mkref c10)
"$RUBY" -e '
  p = ARGV[0]
  lines = File.binread(p).split("\n", -1)
  i = lines.index { |l| !l.start_with?("#") && l.split("\t")[7] == "p_mobj.c:532" }
  abort "control 10 found no mapped call site to move" if i.nil?
  f = lines[i].split("\t", -1); f[7] = "p_lights.c:99"
  lines[i] = f.join("\t")
  File.binwrite(p, lines.join("\n"))
' "$r/rand.tsv"
check "10 same value, different call site" "same value and index, different call site" "$r"

# 11. the reference's gametic column going backwards
r=$(mkref c11)
"$RUBY" -e '
  p = ARGV[0]
  lines = File.binread(p).split("\n", -1)
  i = lines.index { |l| !l.start_with?("#") && l.split("\t")[1] == "300" }
  f = lines[i].split("\t", -1); f[1] = "250"
  lines[i] = f.join("\t")
  File.binwrite(p, lines.join("\n"))
' "$r/frames.tsv"
check "11 reference gametic goes backwards" "gametic goes backwards" "$r"

# 12. a candidate tic missing in the middle.  This is the control for "do not
# pass by comparing fewer": dropping a tic must be caught as a coverage gap,
# not silently reduce the comparison to the tics that remain.
c=$(mkcand c12)
"$RUBY" -e '
  p = ARGV[0]; t = ARGV[1]
  lines = File.binread(p).split("\n", -1)
  lines.reject! { |l| !l.start_with?("#") && l.split("\t")[0] == t }
  File.binwrite(p, lines.join("\n"))
' "$c/frames.tsv" 200
CTL_CAND="$c" check "12 candidate tic dropped" "frames/candidate: 1 of [0-9]+ requested tic\(s\) missing \(middle\)" "$base"
unset CTL_CAND

# 13. the same, on a per-tic stream whose key validation is the strict one.
c=$(mkcand c13)
"$RUBY" -e '
  p = ARGV[0]; t = ARGV[1]
  lines = File.binread(p).split("\n", -1)
  lines.reject! { |l| !l.start_with?("#") && l.split("\t")[0] == t }
  File.binwrite(p, lines.join("\n"))
' "$c/player.tsv" 200
CTL_CAND="$c" check "13 candidate state row dropped" "player/candidate: .*(missing|rows)" "$base"
unset CTL_CAND

# 14. the wipe: many frames on one gametic is correct reference output, and the
# structural checks must run over those rows rather than skipping them.
wipe_rows=$(awk -F'\t' '!/^#/ && $2 == 2' "$base/frames.tsv" | wc -l | tr -d ' ')
if [ "$wipe_rows" -lt 2 ]; then
  echo "FAIL 14: the fixture has $wipe_rows frame(s) on the wipe gametic, so control 15 proves nothing"
  fail=$((fail + 1))
else
  echo "pass 14 wipe carries $wipe_rows frames on one gametic and is accepted"
  pass=$((pass + 1))
fi

# 15. a duplicated frame RECORD inside the wipe.  The wipe legitimises repeated
# gametics, not repeated frame numbers, and the validation must not stop at the
# comparison window: these rows are never compared and must still be checked.
r=$(mkref c15)
"$RUBY" -e '
  p = ARGV[0]
  lines = File.binread(p).split("\n", -1)
  i = lines.index { |l| !l.start_with?("#") && l.split("\t")[1] == "2" }
  lines.insert(i + 1, lines[i])
  File.binwrite(p, lines.join("\n"))
' "$r/frames.tsv"
check "15 duplicated frame record inside the wipe" "frame id [0-9]+ appears twice" "$r"

# 16-18. truncation.  Expected coverage is the REQUESTED range 0..ntics-1, not
# the observed one, so a candidate cut short at either end -- or both -- must
# fail.  Derived from the observed span these all pass: each is contiguous over
# what it holds, every tic present finds its reference frame, and the run
# compares fewer things and reports success.  That defect was real here, found
# by review at ntics=5 against a candidate holding tics 0..3.
trunc() { # $1 name  $2 ruby predicate keeping a tic
  c="$WORK/$1"; rm -rf "$c"; cp -r "$CAND" "$c"
  "$RUBY" -e '
    p = ARGV[0]; keep = ARGV[1]
    lines = File.binread(p).split("\n", -1)
    out = lines.select { |l| l.empty? || l.start_with?("#") || eval(keep.gsub("T", l.split("\t")[0])) }
    File.binwrite(p, out.join("\n"))
  ' "$c/frames.tsv" "$2"
  echo "$c"
}
c=$(trunc t16 'T >= 2');   CTL_CAND="$c" check "16 candidate truncated at the head" "requested tic\(s\) missing \(head\)" "$base"; unset CTL_CAND
c=$(trunc t17 'T < 398');  CTL_CAND="$c" check "17 candidate truncated at the tail" "requested tic\(s\) missing \(tail\)" "$base"; unset CTL_CAND
c=$(trunc t18 'T >= 2 && T < 398'); CTL_CAND="$c" check "18 candidate truncated at both ends" "requested tic\(s\) missing \(both ends\)" "$base"; unset CTL_CAND

# 19. a gap in the reference's frame id sequence.  s_frameno++ advances once per
# dump, so a jump means rows were lost between two writes -- a file that still
# looks ordered and still has unique ids.
r=$(mkref c19)
"$RUBY" -e '
  p = ARGV[0]
  lines = File.binread(p).split("\n", -1)
  i = lines.index { |l| !l.start_with?("#") && l.split("\t")[1] == "200" }
  lines.delete_at(i)
  File.binwrite(p, lines.join("\n"))
' "$r/frames.tsv"
check "19 frame id gap in the reference" "frame ids jump from" "$r"

echo "compare-controls: $((pass + fail)) run, $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
