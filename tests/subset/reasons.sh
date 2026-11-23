#!/bin/sh
#
# tests/subset/reasons.sh -- each fixture row of tests/subset/coverage.tsv,
# refused by spinel-fs-emit with its own entry's reason (decision 0026,
# step 2).
#
#   sh tests/subset/reasons.sh DIR
#
# For every row whose evidence is `fixture PATH`, spinel-fs-emit compiles the
# fixture for the Cortex-M33 profile and must exit non-zero with the line
# `spinel-mlirgen: unsupported: TEXT`, where TEXT is what
# tools/core/subset-coverage.rb --expect gives for that entry from the subset
# refusal tables: the entry's own reason text, not the subset's refusal in
# general. Rows marked unverified-inherited are counted and not run.
#
# Controls:
#   a. a method with none of the table's constructs compiles (exit 0), so a
#      refusal above is not the setup failing;
#   b. the StringNode fixture checked against ArrayNode's text does not
#      match, so the assertion tells entries apart.
#
# Needs the native build (SPINEL_CORE_BUILD, default tools/mlir/native/build)
# and the reader (SPINEL_TYPEDUMP, default tools/contract/build/spinel-typedump),
# each held to this tree by its source stamp.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: reasons.sh DIR}
RUBY=${RUBY:-ruby}
BIN=${SPINEL_CORE_BUILD:-$ROOT/tools/mlir/native/build}/bin
EMIT=$BIN/spinel-fs-emit
READER=${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}
PROFILE=$ROOT/tools/freestanding/profiles/cortex-m33-zephyr.yaml
CHECK=$ROOT/tools/core/subset-coverage.rb
MAP=$ROOT/tests/subset/coverage.tsv
[ -x "$EMIT" ] || { echo "subset-reasons: no spinel-fs-emit at $EMIT (tools/mlir/native/build.sh)" >&2; exit 2; }
[ -x "$READER" ] || { echo "subset-reasons: no reader at $READER (tools/contract/build.sh)" >&2; exit 2; }
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$EMIT"
source_stamp reader "$READER"
mkdir -p "$DIR" || exit 2
W=$DIR/work
[ -e "$W" ] && { echo "subset-reasons: $W exists; give a fresh DIR" >&2; exit 2; }
mkdir -p "$W/spinel" && cp "$ROOT/tools/freestanding/spinel/freestanding.rb" "$W/spinel/" || exit 2
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
# emit FIXTURE: compiles a copy in W; prints the exit status, stderr in W/err
emit() {
  cp "$ROOT/$1" "$W/k.rb" || return 2
  (cd "$W" && "$EMIT" k.rb --freestanding --profile "$PROFILE" --typedump "$READER" -o k.o) > "$W/err" 2>&1
  echo $?
}
# refused_with FIXTURE KIND ENTRY: exit status and whether the entry's text is there
refused_with() {
  want=$("$RUBY" "$CHECK" --expect "$2" "$3") || { echo "no-expect"; return; }
  rc=$(emit "$1")
  printf '%s|%s' "$([ "$rc" != 0 ] && echo refused || echo "exit $rc")" \
    "$(grep -cF "spinel-mlirgen: unsupported: $want" "$W/err")"
}

echo "subset-reasons: the fixture rows"
unverified=0
while IFS='	' read -r kind entry evidence note; do
  case $kind in ''|\#*) continue ;; esac
  case $evidence in
    "fixture "*)
      got=$(refused_with "${evidence#fixture }" "$kind" "$entry")
      ok "$kind $entry: refused with its own reason" "$got" "refused|1"
      [ "$got" = "refused|1" ] || grep -v 'pre-T5' "$W/err" | head -2 | sed 's/^/      /' ;;
    unverified-inherited) unverified=$((unverified + 1)) ;;
  esac
done < "$MAP"
echo "  ($unverified unverified-inherited rows, not run)"

echo "subset-reasons: controls"
cat > "$W/accept.rb" <<'EOF'
require_relative "spinel/freestanding"
freestanding_def :f, params: [:i32], returns: :i32
def f(x)
  y = x + 1
  y
end
EOF
(cd "$W" && "$EMIT" accept.rb --freestanding --profile "$PROFILE" --typedump "$READER" -o accept.o) > "$W/accept.err" 2>&1
ok "a. a method with none of the table's constructs compiles" "$?" 0
ok "b. the StringNode fixture does not carry ArrayNode's reason" \
   "$(refused_with tests/subset/fixtures/node-StringNode.rb node ArrayNode)" "refused|0"

echo "subset-reasons: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" = 0 ]
