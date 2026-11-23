#!/usr/bin/env bash
# E063 build -- the wasm32 profile (one YAML file, no generator change), ported
# from spinel-llvm 463d49dd docs/experiments/results/E063/build.sh.
#
#   E040's kernel, unchanged --> the wasm32-worker profile --> .o
#   --> wasm-ld: bare, with names, as a wasip1 reactor, one boundary, and
#       strictly without the builtins archive (which must be REFUSED)
#
# Not on the runnable path: "E040 regression", which byte-compared the two MCU
# undef tables with E040's RECORDED ones -- a comparison with recorded output,
# an oracle. The MCU objects themselves are built and gated by the e040 lane.
#
#   bash build.sh && bash run_gates.sh [&& bash run_worker.sh]
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
need_wasm
: "${WASI_SYSROOT:?set WASI_SYSROOT to a wasi-libc sysroot (for the wasip1 reactor link)}"
E040=$HERE/../e040
PROFILE=$FSDIR/profiles/wasm32-worker.yaml

fs_fresh_workdir "$OUT"
mkdir -p "$OUT/gen" "$OUT/spinel" "$RES"
cp "$FSDIR/spinel/freestanding.rb" "$OUT/spinel/"
cp "$E040/e040_kern.rb" "$OUT/kern.rb"
# The E040 kernel, byte for byte: the claim is that the PROFILE is the only change.
cmp "$OUT/kern.rb" "$E040/e040_kern.rb"

echo "== toolchain =="
{
  "$CLANG" --version | head -1
  "$WASM_LD" --version
  "$NODE" --version | sed 's/^/node /'
  (cd "$REPO/vendor/spinel" && git rev-parse --short HEAD | sed 's/^/vendor\/spinel /')
  echo "wasi-sysroot  $WASI_SYSROOT"
  echo "wasi-builtins $WASI_BUILTINS"
} 2>&1 | tee "$RES/toolchain.txt"

echo "== spinel-fs-emit --freestanding --profile wasm32-worker =="
(cd "$OUT" && "$MLIRGEN" kern.rb --freestanding --profile "$PROFILE" \
    -o gen/kern.o --emit-header gen/spinel_freestanding.h \
    --emit-undef-tsv gen/undef.tsv 2>&1 | tail -1)
[ -f "$OUT/gen/kern.o" ] || { echo "no wasm32 object" >&2; exit 1; }
for f in mlir ll; do
  (cd "$OUT" && "$MLIRGEN" kern.rb --freestanding --profile "$PROFILE" \
      -o "gen/kern.$f" >/dev/null 2>&1)
done
cp "$OUT/gen/spinel_freestanding.h" "$RES/spinel_freestanding.h"
cp "$OUT/gen/undef.tsv" "$RES/undef_wasm32.tsv"
echo "-- the undefined-symbol gate's verdicts --"; cat "$RES/undef_wasm32.tsv"

(cd "$OUT" && "$MLIRGEN" kern.rb --freestanding --profile "$PROFILE" \
    -o gen/rerun.mlir >/dev/null 2>&1)
cmp "$OUT/gen/kern.mlir" "$OUT/gen/rerun.mlir"
echo "determinism: the .mlir is byte-identical across runs"

EXPORTS=()
while read -r sym; do EXPORTS+=("--export=$sym"); done < <(
  "$NM" --defined-only --extern-only "$OUT/gen/kern.o" | awk '{print $3}' | sort)
echo "== wasm-ld: ${#EXPORTS[@]} exports =="
"$WASM_LD" --no-entry --allow-undefined --strip-all "${EXPORTS[@]}" \
    "$OUT/gen/kern.o" "$WASI_BUILTINS" -o "$OUT/gen/kern.bare.wasm"
"$WASM_LD" --no-entry --allow-undefined "${EXPORTS[@]}" \
    "$OUT/gen/kern.o" "$WASI_BUILTINS" -o "$OUT/gen/kern.names.wasm"
"$WASM_LD" --no-entry --allow-undefined --strip-all "${EXPORTS[@]}" \
    --export=_initialize \
    "$WASI_SYSROOT/lib/wasm32-wasip1/crt1-reactor.o" "$OUT/gen/kern.o" \
    "$WASI_BUILTINS" -L"$WASI_SYSROOT/lib/wasm32-wasip1" -lc \
    -o "$OUT/gen/kern.reactor.wasm"
# Without the builtins archive, a strict link must be REFUSED: the kernel's i64
# multiply needs __multi3, and nothing but the archive supplies it.
if "$WASM_LD" --no-entry --strip-all "${EXPORTS[@]}" \
       "$OUT/gen/kern.o" -o "$OUT/gen/kern.nobuiltins.wasm" 2>"$OUT/gen/nobuiltins.err"; then
  echo "nobuiltins (strict): LINKED (unexpected)" >&2; exit 1
else
  echo "nobuiltins (strict): refused -- $(sort -u "$OUT/gen/nobuiltins.err" | \
      grep -o 'undefined symbol: .*' | sort -u | tr '\n' ' ')"
fi
"$WASM_LD" --no-entry --allow-undefined --strip-all "${EXPORTS[@]}" \
    "$OUT/gen/kern.o" -o "$OUT/gen/kern.nobuiltins.wasm"
(cd "$OUT" && "$MLIRGEN" kern.rb --freestanding --profile "$PROFILE" -m add \
    -o gen/one.o >/dev/null 2>&1)
"$WASM_LD" --no-entry --allow-undefined --strip-all --export=spinel_add \
    "$OUT/gen/one.o" "$WASI_BUILTINS" -o "$OUT/gen/kern.one.wasm"
cp "$OUT/gen/kern.bare.wasm" "$OUT/gen/kern.wasm"
mkdir -p "$OUT/probe"
cp "$HERE/probe/index.mjs" "$HERE/probe/wrangler.toml" "$OUT/probe/"
cp "$OUT/gen/kern.bare.wasm" "$OUT/probe/kern.wasm"
ruby "$HERE/mksig.rb" "$OUT/gen/spinel_freestanding.h" "$OUT/probe/sig.json"
"$NODE" "$HERE/wasm_shape.mjs" "$OUT/gen/kern.bare.wasm" "$OUT/gen/kern.reactor.wasm" \
    "$OUT/gen/kern.nobuiltins.wasm" > "$RES/shape.tsv"
echo "-- import/export shape --"; cat "$RES/shape.tsv"

{
  printf 'kind\tname\traw_bytes\n'
  for v in one bare names reactor nobuiltins; do
    printf 'module\t%s\t%s\n' "$v" "$(wc -c < "$OUT/gen/kern.$v.wasm" | tr -d ' ')"
  done
} > "$RES/size.tsv"
cat "$RES/size.tsv"
echo "build: done"
