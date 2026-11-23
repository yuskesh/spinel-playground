#!/bin/sh
#
# tests/core-boundary/closure.sh — decision 0007 task 5's last bullet: what a
# WHOLE-DOOM closure would still need, measured rather than argued.
#
#   KERNEL=<spinel-core-kernel> tests/core-boundary/closure.sh
#
# The bullet asks for the remaining gaps to be recorded as stage-2 design
# input. A record of that kind rots quietly: the subset changes, the tree
# changes, and the document goes on saying what was true once. So the record in
# docs/core/doom-closure-gaps.md is written from two things this file measures,
# and this file requires the document to agree with them.
#
# Four lanes:
#
#   1. constructs. Each row of constructs.tsv is a probe the checker is asked
#      about, and it must answer what the row says -- `admitted`, or the
#      diagnostic category the row names. Rows exist for what IS admitted as
#      well as for what is not: a table of refusals alone would say nothing
#      about whether the checker still takes what it should.
#   2. the census. Every method in the Full tree, counted by which refused
#      constructs its body holds. The answer is pinned in census.expected.
#   3. the document. Every count the census found is required to be on its own
#      category's row of the record's table -- not merely somewhere in the
#      file, which a document full of numbers satisfies by accident. Every
#      probe is named, and every calibration method is recorded on the side the
#      census put it. A gap recorded with no probe behind it would be a claim;
#      a probe with no line in the record would be a measurement nobody reads.
#   4. nothing quietly dropped. The construct count is declared here, and the
#      census must have met no node kind it neither counts nor allows.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/core-boundary/fixtures/closure"
DOC="$ROOT/docs/core/doom-closure-gaps.md"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
CC_BIN="${CC:-${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/clang}"
RUBY="${RUBY:-ruby}"

die() { echo "closure: $*" >&2; exit 1; }
[ -f "$FIX/constructs.tsv" ] || die "no construct table at $FIX/constructs.tsv"
[ -f "$DOC" ] || die "no gap record at $DOC"
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL (build it first)"
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
# The census parses the Full tree with Prism, which ships with Ruby 3.3 and
# later and is a gem before that. Checked HERE rather than met halfway through
# the census, where a LoadError becomes three failures that look like a
# disagreement about the tree instead of a missing dependency. Measured on
# macOS, where the default ruby is 2.6 and the lane reported 30 of 33.
"$RUBY" -e 'require "prism"' >/dev/null 2>&1 || die \
  "the ruby at '$RUBY' ($("$RUBY" -e 'print RUBY_VERSION' 2>/dev/null)) cannot load prism, which the census needs.
       Prism ships with Ruby 3.3 and later; set RUBY=<such a ruby>, or install the prism gem."

WORK=$(mktemp -d "${TMPDIR:-/tmp}/core-closure.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
pass=0; fail=0
TAB=$(printf '\t')

echo "== the constructs answer what the record says they do =="
mkdir -p "$WORK/src"
n_row=0
while IFS="$TAB" read -r id shape verdict what; do
  case "$id" in \#*|"") continue ;; esac
  n_row=$((n_row + 1))
  case "$shape" in
    narrow)
      # The body between this row's marker and the next.
      awk -v want="--- $id" '
        $0 == want { on = 1; next }
        /^--- / { on = 0 }
        on { print }
      ' "$FIX/src/probes.rb" > "$WORK/src/$id.rb"
      if [ ! -s "$WORK/src/$id.rb" ]; then
        echo "  FAIL $id has no body in src/probes.rb"; fail=$((fail + 1)); continue
      fi
      { echo "core-contract 1"; echo "root src/$id.rb"; echo "entry probe"
        echo "result i64"; echo "param a scalar i64"; echo "param b scalar i64"
        echo "param buf buffer i32 inout count n_buf"; echo "param n_buf scalar u64"
      } > "$WORK/src/$id.contract"
      ;;
    generated)
      # The row whose point is its width: thirty declared buffers, which is the
      # shape the mobj state would need, one array per field.
      "$RUBY" -e '
        n = 30
        names = (0...n).flat_map { |i| ["a#{i}", "n_a#{i}"] }
        File.write(ARGV[0] + ".rb", "def probe(" + names.join(", ") + ")\n  a0[0] = a1[0]\n  0\nend\n")
        c = ["core-contract 1", "root src/" + File.basename(ARGV[0]) + ".rb", "entry probe", "result i64"]
        (0...n).each { |i| c << "param a#{i} buffer i32 inout count n_a#{i}"; c << "param n_a#{i} scalar u64" }
        File.write(ARGV[0] + ".contract", c.join("\n") + "\n")
      ' "$WORK/src/$id"
      ;;
    *) echo "  FAIL $id has shape $shape, which is not narrow or generated"
       fail=$((fail + 1)); continue ;;
  esac

  set +e
  out=$("$KERNEL" "$WORK/src/$id.contract" --root "$WORK" -o /dev/null --header /dev/null \
        --clang "$CC_BIN" 2>&1)
  rc=$?
  set -e
  if [ "$verdict" = admitted ]; then
    if [ "$rc" -eq 0 ]; then
      echo "  pass $id is admitted ($what)"; pass=$((pass + 1))
    else
      echo "  FAIL $id should be admitted ($what) but:"
      printf '%s\n' "$out" | sed 's/^/      /' | head -2; fail=$((fail + 1))
    fi
  elif [ "$rc" -eq 0 ]; then
    echo "  FAIL $id built; the record says it is refused as $verdict ($what)"
    fail=$((fail + 1))
  elif printf '%s' "$out" | grep -q ": $verdict: "; then
    echo "  pass $id is refused as $verdict ($what)"; pass=$((pass + 1))
  else
    echo "  FAIL $id is refused, but not as $verdict:"
    printf '%s\n' "$out" | sed 's/^/      /' | head -2; fail=$((fail + 1))
  fi
done < "$FIX/constructs.tsv"
[ "$n_row" -gt 0 ] || die "the construct table is empty"

# Every body has a row, not only every row a body.
for m in $(grep '^--- ' "$FIX/src/probes.rb" | sed 's/^--- //'); do
  if ! grep -q "^$m$TAB" "$FIX/constructs.tsv"; then
    echo "  FAIL $m has a body with no row in the table"; fail=$((fail + 1))
  fi
done
dup=$(awk -F"$TAB" '!/^#/ && NF { print $1 }' "$FIX/constructs.tsv" | sort | uniq -d)
[ -z "$dup" ] || { echo "  FAIL the construct table names these twice: $dup"; fail=$((fail + 1)); }

echo "== the census is what it was =="
if "$RUBY" "$FIX/census.rb" "$ROOT" > "$WORK/census.actual" 2>"$WORK/census.err"; then
  grep -v '^#' "$FIX/census.expected" > "$WORK/census.want"
  if cmp -s "$WORK/census.want" "$WORK/census.actual"; then
    echo "  pass $(awk -F"$TAB" '$1 == "defs" { print $2 }' "$WORK/census.actual") defs and $(awk -F"$TAB" '$1 == "attr_methods" { print $2 }' "$WORK/census.actual") accessors over $(awk -F"$TAB" '$1 == "files" { print $2 }' "$WORK/census.actual") files, counted as recorded"
    pass=$((pass + 1))
  else
    echo "  FAIL the census has moved:"
    diff "$WORK/census.want" "$WORK/census.actual" | sed 's/^/      /' | head -8
    fail=$((fail + 1))
  fi
else
  echo "  FAIL the census would not run:"; sed 's/^/      /' "$WORK/census.err" | head -4
  fail=$((fail + 1))
fi

echo "== the record says what was measured, on the line where it belongs =="
# Not "does this number appear somewhere in the document". A count has to be on
# its own category's row of the table, because a document is full of numbers
# and any of them will satisfy a search: measured, with the loose check, six of
# the eleven figures could be changed in the table and the lane stayed green,
# and two of them could be exchanged with each other.
row_has() { # category value
  awk -F'|' -v k="\`$1\`" -v v="$2" '
    { for (i = 1; i <= NF; i++) { gsub(/^ +| +$/, "", $i) }
      if ($2 == k) { for (i = 3; i <= NF; i++) if ($i == v) { found = 1 } } }
    END { exit !found }
  ' "$DOC"
}
bad=0
for line in $(awk -F"$TAB" '$1 == "blocked" { print $2 ":" $3 }' "$WORK/census.actual" | tr '\n' ' '); do
  key=${line%%:*}; val=${line#*:}
  if ! grep -qF "\`$key\`" "$DOC"; then
    echo "  FAIL the record does not name the blocked construct $key"; bad=$((bad + 1))
  elif ! row_has "$key" "$val"; then
    echo "  FAIL the record's row for $key does not carry its count, $val"; bad=$((bad + 1))
  fi
done
# The three totals, each required in a sentence that names what it counts.
want_defs=$(awk -F"$TAB" '$1 == "defs" { print $2 }' "$WORK/census.actual")
want_attr=$(awk -F"$TAB" '$1 == "attr_methods" { print $2 }' "$WORK/census.actual")
want_sites=$(awk -F"$TAB" '$1 == "attr_sites" { print $2 }' "$WORK/census.actual")
want_clean=$(awk -F"$TAB" '$1 == "clean" { print $2 }' "$WORK/census.actual")
grep -q "\*\*$want_defs \`def\`s over" "$DOC" || {
  echo "  FAIL the record does not state $want_defs defs where it counts them"; bad=$((bad + 1)); }
grep -q "\*\*$want_attr methods\*\*" "$DOC" || {
  echo "  FAIL the record does not state $want_attr accessor methods where it counts them"; bad=$((bad + 1)); }
# The call sites as well as the methods. This was the one figure on the page
# the lane did not hold, and it was counted by hand; the census counts it now,
# so the record has to agree with the count rather than with the hand.
grep -q "\*\*$want_sites call sites\*\*" "$DOC" || {
  echo "  FAIL the record does not state $want_sites accessor call sites where it counts them"; bad=$((bad + 1)); }
grep -q "$want_clean of them contain nothing" "$DOC" || {
  echo "  FAIL the record does not state $want_clean clean where it counts them"; bad=$((bad + 1)); }
# The calibration, by name: each method the census named has to be in the
# record on the side the census put it.
for line in $(awk -F"$TAB" '$1 == "calibrate" { print $2 "=" $3 }' "$WORK/census.actual" | tr '\n' ' '); do
  m=${line%%=*}; side=${line#*=}
  if ! grep -qF "\`$m\`" "$DOC"; then
    echo "  FAIL the record does not name the calibration method $m"; bad=$((bad + 1))
  elif ! grep -F "\`$m\`" "$DOC" | grep -q "\*\*$side"; then
    echo "  FAIL the record does not say $m is $side"; bad=$((bad + 1))
  fi
done
# And every probe, by id, in a section that agrees about what it showed. The
# record puts what is ADMITTED in its own section -- "What is NOT a gap" -- so
# an admitted probe cited among the gaps, or a refused one cited among the
# non-gaps, is a probe filed under the wrong conclusion.
notgap_from=$(grep -n '^### 10\.' "$DOC" | cut -d: -f1)
[ -n "$notgap_from" ] || { echo "  FAIL the record has no section 10"; bad=$((bad + 1)); notgap_from=0; }
while IFS="$TAB" read -r id shape verdict what; do
  case "$id" in \#*|"") continue ;; esac
  lines=$(grep -nF "\`$id\`" "$DOC" | cut -d: -f1)
  if [ -z "$lines" ]; then
    echo "  FAIL the record never mentions the probe \`$id\`"; bad=$((bad + 1)); continue
  fi
  # At least one mention on the right side. A probe may also be cited across
  # the line for contrast -- an admitted one named in a gap section to say what
  # the gap is not -- so this asks where it is CONCLUDED, not where it is
  # mentioned.
  ok=0
  for ln in $lines; do
    if [ "$verdict" = admitted ]; then
      [ "$ln" -ge "$notgap_from" ] && ok=1
    else
      [ "$ln" -lt "$notgap_from" ] && ok=1
    fi
  done
  if [ "$ok" -eq 0 ]; then
    if [ "$verdict" = admitted ]; then
      echo "  FAIL \`$id\` is admitted and the record concludes it nowhere among the non-gaps"
    else
      echo "  FAIL \`$id\` is refused and the record concludes it nowhere among the gaps"
    fi
    bad=$((bad + 1))
  fi
done < "$FIX/constructs.tsv"
# The share column is derived from the counts, so it rots the moment one moves.
while IFS="$TAB" read -r cat rest; do
  case "$cat" in \#*|"") continue ;; esac
done < /dev/null
for line in $(awk -F"$TAB" '$1 == "blocked" { print $2 ":" $3 }' "$WORK/census.actual" | tr '\n' ' '); do
  key=${line%%:*}; val=${line#*:}
  want=$(awk -v v="$val" -v d="$want_defs" 'BEGIN { printf "%d%%", (v * 100 + d / 2) / d }')
  if ! row_has "$key" "$want"; then
    echo "  FAIL the record's row for $key does not carry its share, $want"; bad=$((bad + 1))
  fi
done
if [ "$bad" -eq 0 ]; then
  echo "  pass every count is on its category's row, and every probe and calibration is named"
  pass=$((pass + 1))
else
  fail=$((fail + bad))
fi

# Section 9 rests on another lane's fixture rather than on a probe of its own,
# so the fixture has to be there and to carry what the section says it does.
# This is a DECLARATION check and nothing else: it reads rows of slots'
# trace.tsv and runs no kernel. What executes that declaration is elsewhere --
# slots.sh's `refuse` lane, and artifacts.sh, which breaks the declared counts
# and makes the direct harness name the cells it actually finds changed. The
# wording below says "rests on a fixture that does" for that reason.
if [ ! -f "$ROOT/tests/core-boundary/fixtures/slots/trace.tsv" ]; then
  echo "  FAIL the record cites a slots fixture that is not there"; fail=$((fail + 1))
elif [ "$(awk -F"$TAB" '$1 == "check" && $8 != "0" && $9 != "0" { n++ } END { print n + 0 }' \
          "$ROOT/tests/core-boundary/fixtures/slots/trace.tsv")" -eq 0 ]; then
  echo "  FAIL the record says refusals move cells, and the slots table declares none"
  fail=$((fail + 1))
else
  echo "  pass the section that has no probe of its own rests on a fixture that does"
  echo "       (declared here; slots.sh and artifacts.sh are what run it)"
  pass=$((pass + 1))
fi

echo "== nothing was quietly dropped =="
# The construct table and the record can both shrink without a number moving,
# so the sizes are declared here and compared. A reset of this kind is only
# safe when the declaration is in the file the change would have to touch.
EXPECT_CONSTRUCTS=28
if [ "$n_row" -ne "$EXPECT_CONSTRUCTS" ]; then
  echo "  FAIL $n_row construct(s) in the table, and this lane expects $EXPECT_CONSTRUCTS"
  fail=$((fail + 1))
else
  echo "  pass all $EXPECT_CONSTRUCTS constructs are still probed"
  pass=$((pass + 1))
fi
n_unclass=$(awk -F"$TAB" '$1 == "unclassified" { n++ } END { print n + 0 }' "$WORK/census.actual")
if [ "$n_unclass" -ne 0 ]; then
  echo "  FAIL the census met $n_unclass node kind(s) it neither counts nor allows:"
  awk -F"$TAB" '$1 == "unclassified" { print "      " $2 }' "$WORK/census.actual"
  fail=$((fail + 1))
else
  echo "  pass every node kind in the tree is one the census counts or allows"
  pass=$((pass + 1))
fi

echo "closure: $((pass + fail)) checked, $pass pass, $fail fail, $n_row construct(s) probed"
[ "$fail" -eq 0 ] || exit 1
