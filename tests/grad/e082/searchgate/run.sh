#!/bin/sh
# E082 searchgate -- spinel-searchgate over three searchers of the same
# objective, and over aggregate curves it must refuse. Ported from spinel-llvm
# 463d49dd docs/experiments/results/E082/searchgate/run.sh.
#
# Needs ../rules/run.sh to have run first: descent_demo minimises the real
# spg_*_lut_loss surface from that build.
#
# Checks: the gate passes the correct searcher and refuses the two defective
# ones (anchor, E078 s6's defect; bestsofar, min-so-far reporting), each against
# the control trace; and it refuses E080's two committed margin curves, which
# are population aggregates, as AGGREGATE-UNAUDITABLE instead of blessing them.
# The curves (e080/) are inputs copied from spinel-llvm
# docs/experiments/results/E080/tables/.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../env.sh"
RULES=${GRAD_WORK:-${TMPDIR:-/tmp}/spinel-grad}/e082-rules/out
[ -f "$RULES/rules_kernels_diff.ll" ] || { echo "$CASE: run ../rules/run.sh first" >&2; exit 2; }
SG=$ROOT/tools/grad/spinel-searchgate
fresh
cd "$OUT"
mkdir -p out
LIBS="-lm -L $ROOT/vendor/spinel/lib -lspinel_rt"
[ "$(uname -s)" = Darwin ] || LIBS="$LIBS -lcrypt"
"$LLVM_PREFIX/bin/clang" -O2 -Wno-everything "$HERE/descent_demo.c" "$RULES/rules_kernels_diff.ll" \
  "$RULES/rules_impl.o" -o out/descent_demo $LIBS
for m in correct anchor bestsofar control; do
  ./out/descent_demo "$m" > "out/trace_$m.tsv" 2> "out/log_$m.txt"
done
for m in correct:0 anchor:1 bestsofar:1; do
  s=${m%%:*}; want=${m#*:}
  if "$SG" "out/trace_$s.tsv" --control out/trace_control.tsv --out "out/gates_$s.tsv" > /dev/null 2>&1
  then got=0; else got=1; fi
  [ "$got" = "$want" ]; result "searcher_$s" $? "expected exit $want, got $got"
done
for c in margin_curve_eps255 margin_curve_eps8; do
  line=$("$SG" "$HERE/e080/$c.tsv" 2>/dev/null | sed -n 2p || true)
  case "$line" in *AGGREGATE-UNAUDITABLE*) ok=0 ;; *) ok=1 ;; esac
  result "e080_$c" $ok "$(printf '%s' "$line" | cut -f3,4)"
done
cat "$OUT/result.tsv"
! grep -q '	FAIL	' "$OUT/result.tsv"
