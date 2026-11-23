# tests/grad/env.sh -- sourced by every case script (tests/grad/eNNN/<case>/run.sh)
# after it sets HERE to its own directory. The cases ran in spinel-llvm beside
# their sources with Homebrew defaults; here they write under $GRAD_WORK and take
# every tool this repository does not build from the caller.
#
#   LLVM_PREFIX  the official LLVM 23.1.1 (docs/building.md); required
#   ENZYME       the Enzyme plugin built against it, LLVMEnzyme-23.so (.dylib on
#                macOS); required. tools/grad/README.md says how it is built.
#   GRAD_WORK    where the cases write (default: $TMPDIR/spinel-grad)
#
# Built here first: vendor/spinel, tools/contract/build.sh (spinel-typedump),
# tools/mlir/native/build.sh (spinel-rtcheck), tools/llvm/build_rt_bc.sh (the
# runtime bitcode rtcheck links) and tools/llvm/passes (libSpinelGCRoots.so).
ROOT=$(cd -- "$HERE/../../../.." && pwd)
: "${LLVM_PREFIX:?set LLVM_PREFIX to the official LLVM 23.1.1 (docs/building.md)}"
: "${ENZYME:?set ENZYME to the Enzyme plugin built against LLVM 23.1.1 (tools/grad/README.md)}"
export LLVM_PREFIX ENZYME
SPINEL=${SPINEL:-$ROOT/vendor/spinel/bin/spinel}
GRADGEN=$ROOT/tools/grad/spinel-gradgen
CASE=$(basename -- "$(dirname -- "$HERE")")-$(basename -- "$HERE")
OUT=${GRAD_WORK:-${TMPDIR:-/tmp}/spinel-grad}/$CASE
for t in "$SPINEL" "$ROOT/tools/contract/build/spinel-typedump" \
         "$ROOT/tools/mlir/native/build/bin/spinel-rtcheck" \
         "$ROOT/tools/llvm/build/libspinel_rt_lto.a" \
         "$ROOT/tools/llvm/passes/build/libSpinelGCRoots.so" "$ENZYME"; do
  [ -e "$t" ] || { echo "$CASE: missing $t" >&2; exit 2; }
done
# Start from a clean directory holding the case's sources and the surface.
fresh() {
  rm -rf "$OUT"
  mkdir -p "$OUT/spinel"
  cp "$ROOT/tools/grad/spinel/grad.rb" "$ROOT/tools/grad/spinel/grad_rules.rb" "$OUT/spinel/"
  cp "$HERE"/*.rb "$OUT/" 2>/dev/null || true
}
# result NAME OK DETAIL -- one row of $OUT/result.tsv; OK is 0 for a pass.
result() {
  if [ "$2" = 0 ]; then _verdict=PASS; else _verdict=FAIL; fi
  printf '%s\t%s\t%s\n' "$1" "$_verdict" "$3" >> "$OUT/result.tsv"
}
