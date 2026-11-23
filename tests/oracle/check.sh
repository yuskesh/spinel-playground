#!/bin/sh
# tests/oracle/check.sh -- tests/ORACLES.tsv against the tree it describes.
#
#   sh tests/oracle/check.sh [ROOT]
#
# ROOT defaults to this checkout. Its files are `git ls-files` when ROOT is a
# work tree, every file under tests/ and tools/ otherwise (tests/oracle/run.sh
# points it at planted copies). What is held:
#
#   1. the list is well formed: four columns, a known class, a section for a
#      gated row and `-` for any other, one row per path and section, and the
#      path exists;
#   2. every gate call -- `tools/oracle/gate <path> <section>` in a script,
#      `OracleGate.allow?("<path>", "<section>")` in Ruby -- names its own file
#      and a gated row, and every gated row has a call in its file;
#   3. every file the oracle patterns find has a row. The patterns are what
#      the oracles here were found by: the words CRuby, oracle, replay,
#      reference Ruby, REF_RUBY, BASELINE_KERNEL, doomgeneric and SPINEL_ORACLE
#      on a line that is not a comment, a fixture loaded with `require_relative
#      ARGV` or `load ARGV`, and a file under an oracle/ directory or with
#      oracle in its name;
#   4. a program row is mentioned, outside comments, only by files whose rows
#      are gated or are programs themselves.
#
# WHAT THIS DOES NOT CATCH. A pattern finds a file, not a line: a second CRuby
# run added to a file that already has a row passes here. Fixtures
# (*/fixtures/*) are not scanned; their callers are. A comparison spelled with
# none of the words is invisible to it. tests/oracle/run.sh says what ran.
set -u
ROOT=${1:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}
LIST="$ROOT/tests/ORACLES.tsv"
[ -f "$LIST" ] || { echo "check: no list at $LIST"; exit 1; }
W=$(mktemp -d "${TMPDIR:-/tmp}/oracle-check.XXXXXX") || exit 2
trap 'rm -rf "$W"' EXIT INT TERM
TAB=$(printf '\t')
bad=0
complain() { echo "  FAIL $*"; bad=$((bad + 1)); }

# The files: scripts, Ruby and Python, under tests/ and tools/.
if git -C "$ROOT" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  (cd "$ROOT" && git ls-files tests tools)
else
  (cd "$ROOT" && find tests tools -type f | LC_ALL=C sort)
fi | while IFS= read -r f; do
  case $f in
    tools/oracle/* | tests/oracle/* | tests/ORACLES.tsv) continue ;;
    *.sh | *.rb | *.py) echo "$f" ;;
    *.*) ;;
    *) head -c 64 "$ROOT/$f" 2>/dev/null | head -1 | grep -q '^#!' && echo "$f" ;;
  esac
done > "$W/files"

# 1. the list
awk -F"$TAB" -v tab="$TAB" '
  /^#/ || /^$/ { next }
  NF != 4 { print "line " NR ": " NF " column(s), not 4"; next }
  $3 !~ /^(owner|definition|confirm|program|exempt|ungated)$/ { print "line " NR ": unknown class " $3; next }
  $3 ~ /^(owner|definition|confirm)$/ && $2 == "-" { print "line " NR ": a gated row needs a section"; next }
  $3 !~ /^(owner|definition|confirm)$/ && $2 != "-" { print "line " NR ": a " $3 " row has no section (-)"; next }
  seen[$1 tab $2]++ { print "line " NR ": " $1 " " $2 " is listed twice" }
' "$LIST" > "$W/form"
while IFS= read -r l; do complain "tests/ORACLES.tsv $l"; done < "$W/form"
awk -F"$TAB" '!/^#/ && NF == 4 { print $1 }' "$LIST" | LC_ALL=C sort -u > "$W/listed"
while IFS= read -r p; do [ -f "$ROOT/$p" ] || complain "tests/ORACLES.tsv names $p, which is not there"; done < "$W/listed"
awk -F"$TAB" '!/^#/ && NF == 4 && $3 ~ /^(owner|definition|confirm)$/ { print $1 "\t" $2 }' "$LIST" | LC_ALL=C sort -u > "$W/gated"

# 2. the calls, as `file<TAB>path<TAB>section`
while IFS= read -r f; do
  awk -v f="$f" '
    /^[ \t]*#/ { next }
    {
      s = $0
      while (match(s, /oracle\/gate"?[ \t]+[^ \t;|)"]+[ \t]+[^ \t;|)"]+/)) {
        c = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        sub(/^oracle\/gate"?[ \t]+/, "", c); split(c, a, /[ \t]+/)
        print f "\t" a[1] "\t" a[2]
      }
      s = $0
      while (match(s, /OracleGate\.allow\?\("[^"]+", *"[^"]+"/)) {
        c = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        sub(/^OracleGate\.allow\?\("/, "", c); sub(/"$/, "", c); split(c, a, /", *"/)
        print f "\t" a[1] "\t" a[2]
      }
    }' "$ROOT/$f"
done < "$W/files" > "$W/calls"
while IFS="$TAB" read -r f p s; do
  [ "$f" = "$p" ] || complain "$f: its gate call names $p, not itself"
  grep -qxF "$p$TAB$s" "$W/gated" || complain "$f: its gate call names $p $s, which is not a gated row"
done < "$W/calls"
cut -f2,3 "$W/calls" | LC_ALL=C sort -u > "$W/called"
LC_ALL=C comm -23 "$W/gated" "$W/called" | while IFS="$TAB" read -r p s; do
  echo "$p $s"
done > "$W/uncalled"
while IFS= read -r l; do complain "tests/ORACLES.tsv gates $l, and the file has no such call"; done < "$W/uncalled"

# 3. what the patterns find. One pass over every file; the lines are read as
# bytes, so a fixture with invalid UTF-8 is read rather than skipped.
grep -v '/fixtures/' "$W/files" | (cd "$ROOT" && LC_ALL=C xargs awk '
  FNR == 1 { if (prev != "" && hit) print prev; prev = FILENAME; hit = (FILENAME ~ /\/oracle\/|oracle/) }
  /^[ \t]*#/ { next }
  /CRuby|cruby|REF_RUBY|require_relative ARGV|load\(? ?ARGV|reference [Rr]uby|[Oo]racle|replay|BASELINE_KERNEL|doomgeneric|SPINEL_ORACLE/ { hit = 1 }
  END { if (prev != "" && hit) print prev }') > "$W/found"
while IFS= read -r f; do
  grep -qxF "$f" "$W/listed" || complain "$f looks like an oracle (tests/oracle/check.sh's patterns) and tests/ORACLES.tsv has no row for it"
done < "$W/found"

# 4. who runs a program: every file that names one outside a comment, by its
# file name or as a Ruby require of its stem, in one pass. A file that names a
# program only to leave it out is allowed when the program's own row says so,
# as "<that file> excludes it" or "<that file> runs only its entry refusal".
awk -F"$TAB" '!/^#/ && NF == 4 && ($3 == "program") { print $1 }' "$LIST" > "$W/programs"
awk -F"$TAB" '!/^#/ && NF == 4 && $3 ~ /^(owner|definition|confirm|program)$/ { print $1 }' "$LIST" | LC_ALL=C sort -u > "$W/may-run"
(cd "$ROOT" && LC_ALL=C xargs awk -v progs="$W/programs" '
  BEGIN { while ((getline p < progs) > 0) { n++; path[n] = p; b = p; sub(/.*\//, "", b); base[n] = b; stem[n] = b; sub(/\.rb$/, "", stem[n]) } }
  /^[ \t]*#/ { next }
  # a name, not the end of a longer one: compare.rb is not gpu_compare.rb
  function names(l, s,   k) {
    while ((k = index(l, s)) > 0) { if (k == 1 || substr(l, k - 1, 1) !~ /[A-Za-z0-9_.-]/) return 1; l = substr(l, k + 1) }
    return 0
  }
  { for (i = 1; i <= n; i++) if (FILENAME != path[i] && (names($0, base[i]) || index($0, "/" stem[i] "\""))) seen[FILENAME "\t" path[i]] = 1 }
  END { for (k in seen) print k }' < "$W/files") | LC_ALL=C sort > "$W/mentions"
while IFS="$TAB" read -r f prog; do
  grep -qxF "$f" "$W/may-run" && continue
  awk -F"$TAB" -v p="$prog" -v x="$f excludes it" -v y="$f runs only its entry refusal" '!/^#/ && $1 == p && $3 == "program" && (index($4, x) || index($4, y)) { found = 1 } END { exit !found }' "$LIST" ||
    complain "$f mentions $prog, a comparison program, and is not gated"
done < "$W/mentions"

n_rows=$(awk -F"$TAB" '!/^#/ && NF == 4' "$LIST" | wc -l | tr -d ' ')
echo "check: $n_rows rows, $(wc -l < "$W/gated" | tr -d ' ') gated sections, $(wc -l < "$W/calls" | tr -d ' ') gate calls, $(wc -l < "$W/found" | tr -d ' ') files found by the patterns, $bad failure(s)"
[ "$bad" -eq 0 ]
