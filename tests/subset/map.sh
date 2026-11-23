#!/bin/sh
#
# tests/subset/map.sh -- tests/subset/coverage.tsv against the subset refusal
# tables (SubsetRefusals.cpp and SubsetTables.cpp), and the controls of
# tools/core/subset-coverage.rb. Needs no build.
#
#   sh tests/subset/map.sh DIR
#
# 0. this tree: every table entry has exactly one row, and each row's
#    evidence is a fixture that names its entry, or unverified-inherited with
#    a reason (exit 0).
#
# The controls run the check over a planted table (an owned node entry and
# call entry, an inherited node entry), a map and fixtures in DIR. The planted set passes as it is;
# each control changes one thing and requires exit 1 and its failure, by name:
#
#   1. a table entry with no row             no row
#   2. a row whose fixture is not a file     missing test
#   3. a row naming no table entry           unknown entry
#   4. two rows for one entry                duplicate row
#   5. a fixture that names another entry    fixture mismatch
#   6. unverified-inherited with no reason   no reason
#   7. evidence of neither form              bad evidence
#   9. an entry moved to the other file      wrong side
#  10. an entry in both files               in both files
#
# and 8: --expect prints a node's and a call's refusal text.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: map.sh DIR}
RUBY=${RUBY:-ruby}
CHECK=$ROOT/tools/core/subset-coverage.rb
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
mkdir -p "$DIR" || exit 2
T=$DIR/tree
[ -e "$T" ] && { echo "subset-map: $T exists; give a fresh DIR" >&2; exit 2; }

echo "subset-map: 0. this tree"
"$RUBY" "$CHECK" > "$DIR/self.txt" 2>&1
ok "every entry has one row, and every row its evidence" "$?|$(grep -c '^FAIL' "$DIR/self.txt")" "0|0"
head -1 "$DIR/self.txt" | sed 's/^/  /'

# The planted table, in the two files' forms.
mkdir -p "$T/fx"
refusals() {
  cat <<EOF
const std::map<std::string, NodeRefusal> &subsetRefusalNodes() {
  static const std::map<std::string, NodeRefusal> t = {
      {"StringNode",
       {HeapOperation, "a String literal"}},
$1  };
  return t;
}

const std::map<std::string, std::string> &subsetRefusalCalls() {
  static const std::map<std::string, std::string> t = {
      {"times",
       "\`times\` takes a block."},
  };
  return t;
}
EOF
}
inherited() {
  cat <<EOF
const std::map<std::string, std::string> &fsInheritedNodes() {
  static const std::map<std::string, std::string> t = {
$1  };
  return t;
}
EOF
}
NIL='      {"NilNode",
       "`nil` "
       "(no boxed nil)"},
'
refusals '' > "$T/refusals.cpp"
inherited "$NIL" > "$T/inherited.cpp"
printf '# subset-entry: node StringNode\n' > "$T/fx/s.rb"
printf '# subset-entry: call times\n' > "$T/fx/t.rb"
base() {
  printf 'node\tStringNode\tfixture fx/s.rb\n'
  printf 'node\tNilNode\tunverified-inherited\tthe planted reason\n'
  printf 'call\ttimes\tfixture fx/t.rb\n'
}
# check MAP [REFUSALS INHERITED]
check() { "$RUBY" "$CHECK" --root "$T" --refusals "${2:-$T/refusals.cpp}" --inherited "${3:-$T/inherited.cpp}" \
            --map "$1" > "$DIR/out.txt" 2>&1; echo $?; }
has() { grep -c "^FAIL $1: $2" "$DIR/out.txt"; }

echo "subset-map: the planted set as it is"
base > "$DIR/map.tsv"
ok "passes, with no failure" "$(check "$DIR/map.tsv")|$(grep -c '^FAIL' "$DIR/out.txt")" "0|0"

echo "subset-map: 1. an entry with no row"
base | grep -v '^node	NilNode' > "$DIR/map1.tsv"
ok "fails, naming the entry" "$(check "$DIR/map1.tsv")|$(has 'no row' 'node NilNode$')" "1|1"

echo "subset-map: 2. a fixture that is not a file"
base | sed 's|fx/t.rb|fx/gone.rb|' > "$DIR/map2.tsv"
ok "fails, naming the row and the path" "$(check "$DIR/map2.tsv")|$(has 'missing test' 'map2.tsv:3: call times: no file fx/gone.rb$')" "1|1"

echo "subset-map: 3. a row naming no entry"
{ base; printf 'call\teach\tfixture fx/t.rb\n'; } > "$DIR/map3.tsv"
ok "fails, naming the row" "$(check "$DIR/map3.tsv")|$(has 'unknown entry' 'map3.tsv:4: call each$')" "1|1"

echo "subset-map: 4. two rows for one entry"
{ base; printf 'node\tStringNode\tunverified-inherited\tagain\n'; } > "$DIR/map4.tsv"
ok "fails, naming both rows" "$(check "$DIR/map4.tsv")|$(has 'duplicate row' 'node StringNode: map4.tsv:1, map4.tsv:4$')" "1|1"

echo "subset-map: 5. a fixture naming another entry"
base | sed 's|^call	times	fixture fx/t.rb|call	times	fixture fx/s.rb|' > "$DIR/map5.tsv"
ok "fails, naming what the fixture says" \
   "$(check "$DIR/map5.tsv")|$(has 'fixture mismatch' 'map5.tsv:3: call times: fx/s.rb begins "# subset-entry: node StringNode"$')" "1|1"

echo "subset-map: 6. unverified-inherited with no reason"
base | sed 's|	the planted reason$||' > "$DIR/map6.tsv"
ok "fails, naming the entry" "$(check "$DIR/map6.tsv")|$(has 'no reason' 'map6.tsv:2: node NilNode$')" "1|1"

echo "subset-map: 7. evidence of neither form"
base | sed 's|fixture fx/s.rb|tests/freestanding/e040/run_reject.sh|' > "$DIR/map7.tsv"
ok "fails, naming the evidence" "$(check "$DIR/map7.tsv")|$(has 'bad evidence' 'map7.tsv:1: node StringNode: ')" "1|1"

echo "subset-map: 8. --expect"
ok "a node's text, from adjacent literals" \
   "$("$RUBY" "$CHECK" --refusals "$T/refusals.cpp" --inherited "$T/inherited.cpp" --expect node NilNode)" "f: NilNode is not in the freestanding subset -- \`nil\` (no boxed nil)."
ok "a call's text" "$("$RUBY" "$CHECK" --refusals "$T/refusals.cpp" --inherited "$T/inherited.cpp" --expect call times)" "f: \`times\` takes a block."

echo "subset-map: 9. an entry moved to the other file"
refusals "$NIL" > "$T/refusals9.cpp"; inherited '' > "$T/inherited9.cpp"
ok "fails, naming the row and the file it belongs in" \
   "$(check "$DIR/map.tsv" "$T/refusals9.cpp" "$T/inherited9.cpp")|$(has 'wrong side' 'map.tsv:2: node NilNode is unverified-inherited, so it belongs in inherited9.cpp$')|$(grep -c '^FAIL' "$DIR/out.txt")" "1|1|1"

echo "subset-map: 10. an entry in both files"
refusals "$NIL" > "$T/refusals10.cpp"
ok "fails, naming the entry" \
   "$(check "$DIR/map.tsv" "$T/refusals10.cpp")|$(has 'in both files' 'node NilNode$')" "1|1"

echo "subset-map: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" = 0 ]
