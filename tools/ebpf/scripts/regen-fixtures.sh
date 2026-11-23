#!/bin/sh
# Regenerate tests/fixtures/*.{ast,ir} from tests/fixtures/*.rb using the current
# spinel + the spinel-ebpf in-process codegen (ADR-011 Stage 2):
#   - .ast : bin/spinel --dump-ast --no-line-map  (upstream, byte-identical to
#            the legacy spinel_parse output the co-process expects)
#   - .ir  : the in-process binary's --ir mode (cc_build_ir_text over the analyzed
#            Compiler) — the replacement for the removed `--emit-ir` patch.
#
# Run INSIDE the build container with the project mounted at /work, after spinel
# is built (cd third_party/spinel && make deps && make). Works on any Linux host
# with a built spinel in $SPINEL_DIR.
#
# The committed fixtures are kept in this production (`--emit-ir`-equivalent)
# form (the corpus was migrated off the older legacy Ruby-analyzer dump in
# ADR-011 Stage 2). Re-running this should leave tests/fixtures/ unchanged; if a
# spinel update shifts the output, regenerate and re-run the unit suite — a few
# tests assert exact codegen/IR shape (return-type of attach/conditional handler
# inners, SN/ST scope locals, @needs_* program flags) and may need updating.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Spinel Extended: the compiler is this repository's vendor/spinel, as in
# bin/spinel-ebpf (the predecessor kept it at third_party/spinel).
SPINEL_DIR="${SPINEL_DIR:-$(cd "$ROOT/../.." && pwd)/vendor/spinel}"
FIX_DIR="$ROOT/tests/fixtures"
# upstream now builds bin/spinel (older checkouts used build/spinel); prefer bin/.
SPINEL="$SPINEL_DIR/bin/spinel"
[ -x "$SPINEL" ] || SPINEL="$SPINEL_DIR/build/spinel"
CC_BIN="$ROOT/build/codegen_c/spinel-ebpf-cc"

if [ ! -x "$SPINEL" ]; then
  echo "error: spinel binary not found (looked for bin/spinel and build/spinel in $SPINEL_DIR) — build first (cd $SPINEL_DIR && make)" >&2
  exit 1
fi

# Build the in-process codegen binary (upstream objects minus main.o + the
# codegen TU with -DSPNL_INPROCESS). Mirrors bin/spinel-ebpf's inproc_codegen_bin.
# Spinel Extended: including its declaration-manifest adapter TU (E154) and the
# regexp engine objects (build/regexp/*.o, which re_lit_check.o calls into).
OBJ=$(ls "$SPINEL_DIR"/build/csrc/*.o | grep -v '/main\.o$' | tr '\n' ' ')
RE_OBJ=$(ls "$SPINEL_DIR"/build/regexp/*.o 2>/dev/null | tr '\n' ' ')
mkdir -p "$ROOT/build/codegen_c"
# shellcheck disable=SC2086
cc -O2 -I "$SPINEL_DIR/src" "$ROOT/tools/spinel_ebpf_inproc.c" \
   "$ROOT/src/codegen_c/spbpf_schema_adapter.c" $OBJ $RE_OBJ \
   "$SPINEL_DIR/build/libprism.a" $( [ -f "$SPINEL_DIR/build/librbs.a" ] && echo "$SPINEL_DIR/build/librbs.a" ) -lm -o "$CC_BIN"

cd "$ROOT"
count=0
for rb in "$FIX_DIR"/*.rb; do
  base="$(basename "$rb" .rb)"
  # Relative path keeps spinel's SOURCE_FILE line portable across machines/dirs.
  rel_rb="${rb#"$ROOT"/}"
  SPINEL_NO_BUILTINS=1 "$SPINEL" --dump-ast --no-line-map "$rel_rb" > "$FIX_DIR/$base.ast"
  "$CC_BIN" "$rel_rb" "$base" --ir                > "$FIX_DIR/$base.ir"
  count=$((count + 1))
  echo "regenerated: $base.{ast,ir}"
done
echo "done: $count fixtures regenerated"
