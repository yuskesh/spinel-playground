#!/bin/sh
#
# tests/doom/gate-r007-controls.sh — prove that the G0 gate rejects.
#
#   RUBY=ruby tests/doom/gate-r007-controls.sh
#
# Needs nothing but this checkout: the golden stands in for a built reference,
# so the identity case is exact and every other case is one edit away from it.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RUBY="${RUBY:-ruby}"
GATE="$ROOT/tests/doom/gate-r007-golden.rb"
GOLDEN="$ROOT/tests/doom/fixtures/reference/demo1_hashes.tsv"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/doom-g0ctl.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
pass=0; fail=0

mk() { f="$WORK/$1.tsv"; cp "$GOLDEN" "$f"; echo "$f"; }

check() { # $1 label  $2 want ("" = expect success)  $3 built  $4 allowances
  label="$1"; want="$2"; b="$3"; allow="${4:-}"
  log="$WORK/$(echo "$label" | tr -c 'a-zA-Z0-9' '_').log"
  set +e
  if [ -n "$allow" ]; then
    "$RUBY" "$GATE" --built "$b" --allowances "$allow" > "$log" 2>&1
  else
    "$RUBY" "$GATE" --built "$b" > "$log" 2>&1
  fi
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

# 1. the golden against itself
check "1 identity" "" "$GOLDEN"

# 2. one hash changed
b=$(mk c2)
"$RUBY" -e '
  p = ARGV[0]
  l = File.binread(p).split("\n", -1)
  i = l.index { |x| !x.start_with?("#") && x.split("\t")[0] == "3000" }
  f = l[i].split("\t", -1); f[2] = "0000000000000000"; l[i] = f.join("\t")
  File.binwrite(p, l.join("\n"))
' "$b"
check "2 one frame hash changed" "frame 3000 .*fnv1a64" "$b"

# 3. a row deleted: the frame ids must show the gap
b=$(mk c3)
"$RUBY" -e '
  p = ARGV[0]
  l = File.binread(p).split("\n", -1)
  i = l.index { |x| !x.start_with?("#") && x.split("\t")[0] == "2000" }
  l.delete_at(i); File.binwrite(p, l.join("\n"))
' "$b"
check "3 row deleted" "frame ids jump from" "$b"

# 4. a row duplicated
b=$(mk c4)
"$RUBY" -e '
  p = ARGV[0]
  l = File.binread(p).split("\n", -1)
  i = l.index { |x| !x.start_with?("#") && x.split("\t")[0] == "2000" }
  l.insert(i + 1, l[i]); File.binwrite(p, l.join("\n"))
' "$b"
check "4 row duplicated" "frame id 2000 repeats" "$b"

# 5. the E052 five-column file fed to this gate.  Both files have a column
# called fnv1a64 at index 2 and they are DIFFERENT hash functions; the gate must
# refuse on the header rather than compare them.
b="$WORK/e052.tsv"
printf '#frame\tgametic\tfnv1a64\tviewhash\tsha256\n0\t2\tdeadbeefdeadbeef\tcafecafecafecafe\t-\n' > "$b"
check "5 E052 layout refused" "different hash function" "$b"

# 6. a pinned declaration is tolerated; 7. a stale one is not
b=$(mk c6)
"$RUBY" -e '
  p = ARGV[0]
  l = File.binread(p).split("\n", -1)
  i = l.index { |x| !x.start_with?("#") && x.split("\t")[0] == "4000" }
  f = l[i].split("\t", -1); $stderr.print f[2]; f[2] = "1111111111111111"; l[i] = f.join("\t")
  File.binwrite(p, l.join("\n"))
' "$b" 2> "$WORK/g6.orig"
printf '4000\tfnv1a64\t%s\t1111111111111111\tsynthetic control\n' "$(cat "$WORK/g6.orig")" > "$WORK/allow6.tsv"
check "6 pinned declaration tolerated" "" "$b" "$WORK/allow6.tsv"
check "7 stale declaration reported" "did not occur" "$GOLDEN" "$WORK/allow6.tsv"

# 8. the same declared frame, a different built value
b=$(mk c8)
"$RUBY" -e '
  p = ARGV[0]
  l = File.binread(p).split("\n", -1)
  i = l.index { |x| !x.start_with?("#") && x.split("\t")[0] == "4000" }
  f = l[i].split("\t", -1); f[2] = "2222222222222222"; l[i] = f.join("\t")
  File.binwrite(p, l.join("\n"))
' "$b"
check "8 different value at a declared frame" "frame 4000" "$b" "$WORK/allow6.tsv"

echo "gate-r007-controls: $((pass + fail)) run, $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
