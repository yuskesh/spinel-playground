#!/bin/sh
# tests/doom-core/harness/build-artifacts.sh — the three artifacts, built once.
#
#   sh tests/doom-core/harness/build-artifacts.sh DIR
#
# The compiled, session and adapter cases load two shared objects and a
# generated session layout. harness/artifacts.sh knows how each is made, and
# tick.sh sources it; but tick.sh also supplies the names those recipes read and
# runs the audit step one of them depends on, so until this file existed nobody
# could build the three except by running the whole suite. The case runner
# builds nothing, so without this its compiled, session and adapter cases can
# only skip.
#
# It prints the assignments the runner and the screens check need, so a caller can do:
#
#   out=$(sh tests/doom-core/harness/build-artifacts.sh "$HARNESS_RUN") || exit 1
#   eval "$out"
#   REQUIRE_ALL=1 ruby tests/doom-core/harness/run.rb --tier commit
#
# THE STATUS MUST BE CAUGHT SEPARATELY. `eval "$(...)"` answers for the eval,
# not for the build: a failed build would leave the three names unset, the
# eval would succeed, and the runner would then SKIP every compiled, session
# and adapter case -- a run reporting green having tested four cases out of
# twenty-eight. REQUIRE_ALL=1 turns that skip into a failure, which is the
# second guard against the same mistake.
#
# IT IS A SEPARATE FILE, not a subcommand of artifacts.sh, on purpose. That file
# is sourced, and sourcing in POSIX sh inherits the caller's positional
# parameters: a `build` subcommand there would fire if the sourcing script ever
# happened to be run with that word as its first argument. A file that only ever
# defines functions cannot do that.
#
# THE TOOLS COME FROM THE ENVIRONMENT, under the names tick.sh already uses:
# KERNEL, ADAPTER, SPINEL_TYPEDUMP, CLANG or LLVM_PREFIX, WAD and RUBY. Nothing
# here names a path outside the checkout.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
W=${1:-}
[ -n "$W" ] || { echo "usage: build-artifacts.sh DIR" >&2; exit 2; }

# A build directory inside the checkout would leave the objects, the copied
# units and the generated layout as untracked work in the tree they came from.
# Compared by realpath, so a symlink either way does not walk through it.
dc_real() { (cd -- "$1" 2>/dev/null && pwd -P); }
dc_parent=$W
while [ ! -d "$dc_parent" ] && [ "$dc_parent" != "/" ] && [ "$dc_parent" != "." ]; do
  dc_parent=$(dirname -- "$dc_parent")
done
dc_here=$(dc_real "$ROOT")
dc_there=$(dc_real "$dc_parent")
case "$dc_there" in
  "$dc_here" | "$dc_here"/*)
    echo "build-artifacts.sh: $W is inside the checkout at $dc_here; the objects, the copied" >&2
    echo "  units and the generated layout belong outside every worktree" >&2
    exit 1 ;;
esac

RUBY="${RUBY:-ruby}"
AUDIT="${AUDIT:-$ROOT/tools/doom/audit-core.rb}"
PACK="${PACK:-$ROOT/tools/doom/pack-core.rb}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
ADAPTER_BIN="${ADAPTER:-$ROOT/tools/mlir/native/build/bin/spinel-core-adapter}"
WADFILE="${WAD:-$ROOT/build/doom-wad/doom1.wad}"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else CC_BIN=""; fi
SRCFIX="$ROOT/tests/doom-core/fixtures/source"
# The entries the lane compiles. One contract each, under SRCFIX, and THE LIST
# AND THE CONTRACTS ON DISK ARE THE SAME SET, which tests/doom-core/source-pack.sh
# now compares in both directions -- because this list drifted one way and
# nothing noticed: on 2026-09-18 it held 40 names against 42 tracked .contract
# files, with `inputall` and `renderall` on disk and unbuilt while 46 rows of
# tools/doom/core-migrated.tsv said definitions were "compiled through
# dc_sp_renderall". Both compile and both pass the link rule below.
#
# ONE LINE, and source-pack.sh reads it with a `sed` that expects exactly that:
# if this assignment is ever split across lines, split the check with it.
SENTRIES="col span mjob none tex mask flat zone zalloc jreset exec pwall pspan pmask ph1 ph3 cdis cspan cmask call dplanes cplanes sbdraw hudraw pangle pdist sgscale lindex absang clipv segside fplane chplane ssclear crunch chkbbox vssort addspr segloop stepall inputall renderall"
export ROOT RUBY PACK READER KERNEL ADAPTER_BIN CC_BIN SRCFIX SENTRIES

for pair in "KERNEL:$KERNEL" "ADAPTER:$ADAPTER_BIN" "SPINEL_TYPEDUMP:$READER"; do
  name=${pair%%:*}; path=${pair#*:}
  [ -x "$path" ] || { echo "build-artifacts.sh: no runnable $name at $path" >&2; exit 1; }
done
[ -f "$WADFILE" ] || { echo "build-artifacts.sh: no IWAD at $WADFILE" >&2; exit 1; }

[ -n "$CC_BIN" ] && [ -x "$CC_BIN" ] || {
  echo "build-artifacts.sh: no C compiler; set CLANG or LLVM_PREFIX" >&2; exit 1; }

. "$ROOT/tests/doom-core/harness/artifacts.sh"
dc_artifacts_ready

mkdir -p "$W"

# THE SESSION LAYOUT IS DERIVED FROM THE AUDIT, so the audit runs here too. It
# is the same call tick.sh makes, and its output is the same directory shape.
echo "build-artifacts.sh: the audit" >&2
mkdir -p "$W/audit"
"$RUBY" "$AUDIT" --reader "$READER" --tables "$ROOT/tools/doom" --output "$W/audit" > "$W/audit.err" 2>&1 || true
[ -s "$W/audit/closure.tsv" ] || {
  echo "build-artifacts.sh: the audit produced no closure; see $W/audit.err" >&2; exit 1; }

echo "build-artifacts.sh: the entries and libsource.so" >&2
dc_entry_units "$W/sk"
dc_entries "$W/sk" "$W/sk/unit" || {
  echo "build-artifacts.sh: an entry did not build; read $W/sk/pack.err and $W/sk/<entry>.err" >&2
  exit 1; }
# EVERY OBJECT REFERS ONLY TO ITSELF, checked here and not only in tick.sh,
# because everything built from here -- the screens check, the harness -- would
# otherwise run on an object the link rule refuses. The kernel accepting a
# definition does not settle it: the compiler chooses the relocations. The rule
# is by target (object-relocs.rb): a branch, an address pair or an x86-64 PC32
# to this object's own symbols or sections is admitted -- the jump and lookup
# tables clang makes of switches among them -- and a reference anything else
# must resolve is refused.
if ! "$RUBY" "$ROOT/tests/doom-core/object-relocs.rb" "$(dirname -- "$CC_BIN")" \
     $(for e in $SENTRIES; do printf '%s ' "$W/sk/$e.o"; done) > "$W/sk/relocs.out" 2>&1; then
  echo "build-artifacts.sh: an entry object holds more than branches into its own code:" >&2
  grep -v -e '^targets ' -e ' ok$' "$W/sk/relocs.out" >&2
  exit 1
fi
dc_source_lib "$W/sk" "$W/libsource.so"

# THE ONE CLOSURE: every entry above in a single kernel closure, as the cutover's
# one native entry will need them, built each time so that how far it scales is a
# series. It is RECORDED, not required, here -- the other artifacts do not depend
# on it -- and screens.sh asserts what was recorded. The dense-dispatch copy adds
# a jump table over every entry, which the relocation check admits as the
# object's own. Both kernels run at once.
echo "build-artifacts.sh: the one closure" >&2
for dc_k in none dense; do
  dc_o=$W/one/$dc_k
  mkdir -p "$dc_o"
  ( dc_rc=0
    "$RUBY" "$ROOT/tests/doom-core/one-closure.rb" --fixtures "$SRCFIX" --packed "$W/sk/stage/src/packed.rb" \
      --output "$dc_o" --dispatch "$dc_k" > "$dc_o/gen.err" 2>&1 || dc_rc=$?
    dc_t0=$(date +%s)
    [ "$dc_rc" != 0 ] || "$KERNEL" "$dc_o/stage/one.contract" --root "$dc_o/stage" --typedump "$READER" --int64-allow "$ROOT/tools/core/int64-allow.tsv" \
      -o "$dc_o/one.o" --header "$dc_o/one.h" --clang "$CC_BIN" > "$dc_o/kernel.err" 2>&1 || dc_rc=$?
    echo "kernel	$dc_rc	$(( $(date +%s) - dc_t0 ))" >> "$dc_o/shape.tsv"
    if [ -f "$dc_o/one.o" ]; then
      echo "bytes	$(wc -c < "$dc_o/one.o" | tr -d ' ')" >> "$dc_o/shape.tsv"
      "$RUBY" "$ROOT/tests/doom-core/object-relocs.rb" "$(dirname -- "$CC_BIN")" "$dc_o/one.o" > "$dc_o/relocs.out" 2>&1 || true
      echo "relocs	$(sed -n 's/^one \([a-z]*\).*/\1/p' "$dc_o/relocs.out" | head -1)" >> "$dc_o/shape.tsv"
    fi ) &
done
wait

echo "build-artifacts.sh: the session layout" >&2
dc_session_catalog "$W/e5" "$WADFILE"
dc_session_schema "$W/e5" "$W/audit"
dc_session_layout "$W/e5"
[ -f "$W/e5/gen/buffers.tsv" ] || {
  echo "build-artifacts.sh: no session layout; see $W/e5/gen.err" >&2; exit 1; }
# ONE LAYOUT PER DEMO. A layout is a map's: its level counts are the catalog's.
# DEMO1's is e5 above, which the harness names; the screens check runs every
# demo over the session and the adapter, so each gets its own, under sessions/.
mkdir -p "$W/sessions"
ln -sfn ../e5 "$W/sessions/DEMO1"
for dc_demo in DEMO2 DEMO3; do
  dc_session_catalog "$W/sessions/$dc_demo" "$WADFILE" "$dc_demo"
  dc_session_schema "$W/sessions/$dc_demo" "$W/audit"
  dc_session_layout "$W/sessions/$dc_demo"
  [ -f "$W/sessions/$dc_demo/gen/buffers.tsv" ] || {
    echo "build-artifacts.sh: no $dc_demo session layout; see $W/sessions/$dc_demo/gen.err" >&2; exit 1; }
done

echo "build-artifacts.sh: the adapter and libadapter.so" >&2
dc_adapter_generate "$W/sk" "$W/ad" || {
  echo "build-artifacts.sh: an adapter did not generate; read $W/ad/<entry>.gen" >&2; exit 1; }
dc_adapter_link "$W/sk" "$W/ad" "$W/libadapter.so" || {
  echo "build-artifacts.sh: the adapter did not link; read $W/ad/cc.err" >&2; exit 1; }

# What the runner reads. Printed on stdout alone, so `eval "$(...)"` works and
# the progress above does not reach it.
echo "HARNESS_SOURCE_LIB='$W/libsource.so'; export HARNESS_SOURCE_LIB"
echo "HARNESS_ADAPTER_LIB='$W/libadapter.so'; export HARNESS_ADAPTER_LIB"
echo "HARNESS_SESSION_DIR='$W/e5/gen'; export HARNESS_SESSION_DIR"
echo "HARNESS_SESSION_ROOT='$W/sessions'; export HARNESS_SESSION_ROOT"
echo "HARNESS_ONE_CLOSURE='$W/one'; export HARNESS_ONE_CLOSURE"
