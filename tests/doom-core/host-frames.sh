#!/bin/sh
#
# tests/doom-core/host-frames.sh — DOOM's built entries on this host, over DEMO1's first tics.
#
#   WAD=... LLVM_PREFIX=...|CLANG=... [CORE_BUILD=DIR] [TICS=500] [SPINEL=... SPINEL_LIB=... ADAPTER=... READER=...] \
#     sh tests/doom-core/host-frames.sh DIR
#
# The check a change to DOOM's CORE source runs before the board does
# (tools/test/affected.rb selects it with the board lane). The three entries
# are built by the kernel for this host (CORE_BUILD: a build in verify.sh's
# layout, reused; otherwise built here, about eight minutes), linked into
# tests/doom-core/native/bound.rb with this tree's adapter, and DEMO1 is
# played for TICS tics (500 unless set) over the storage the session
# allocated, as rt1186.sh's part 2 plays it. Every frame's two FNV-1a 64
# digests must be the recorded ones (tests/doom-core/fixtures/screens/DEMO1.tsv).
#
# NOT AN ORACLE, BY THE OWNER'S PRECEDENT: tests/doom-core/native.sh compares
# the same program's frames with the same recording, and the owner ruled
# native not a comparison (tests/ORACLES.tsv, exempt, 2026-10-18). Nothing
# here runs CRuby.
#
# WHAT IT CANNOT SEE. On this host the entries are built with a 64-bit body:
# ordinary arithmetic is 64-bit, so a value that leaves i32 between two
# operations, which the board's 32-bit body refuses as ARITHMETIC, passes
# here. What it does see: a frame that differs (a comparison or a shift that
# reads a signed angle as unsigned, say), a word intrinsic given an operand
# outside i32 (ARITHMETIC on every width), and a store outside a cell's
# element. Only the board lane runs the 32-bit body.
#
# CONTROL: the comparison is run once more on the frames with one digest
# planted wrong, and must fail.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: host-frames.sh DIR}
RUBY=${RUBY:-ruby}
WADFILE=${WAD:-$ROOT/build/doom-wad/doom1.wad}
SPINEL=${SPINEL:-$ROOT/vendor/spinel/bin/spinel}
SPINEL_LIB=${SPINEL_LIB:-$ROOT/vendor/spinel/lib}
KERNEL=${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}
ADAPTER_BIN=${ADAPTER:-$ROOT/tools/mlir/native/build/bin/spinel-core-adapter}
READER=${READER:-${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}}
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
FIX=$ROOT/tests/doom-core/fixtures/screens
PACK=$ROOT/tools/doom/pack-core.rb
TICS=${TICS:-500}
case $TICS in *[!0-9]*|0) echo "host-frames: TICS must be a positive number of tics, not '$TICS'" >&2; exit 2 ;; esac
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
T0=$(date +%s)
summary() {
  echo "host-frames: $((pass + fail)) checked, $pass pass, $fail fail; $(( $(date +%s) - T0 )) s"
  [ "$fail" -eq 0 ]
  exit $?
}
mkdir -p "$DIR" || exit 2
if [ ! -f "$WADFILE" ] || [ -z "${CLANG:-}${LLVM_PREFIX:-}" ] || [ ! -x "$SPINEL" ] || [ ! -x "$KERNEL" ] ||
   [ ! -x "$ADAPTER_BIN" ] || [ ! -x "$READER" ]; then
  echo "host-frames: it needs the IWAD (WAD), LLVM_PREFIX or CLANG, the pinned compiler, the kernel, the adapter and the reader" >&2
  exit 2
fi
CC_BIN=${CLANG:-$LLVM_PREFIX/bin/clang}
SHIM=$DIR/shim; mkdir -p "$SHIM"; ln -sf "$CC_BIN" "$SHIM/cc"
SRCFIX=$ROOT/tests/doom-core/fixtures/source
# shellcheck source=tests/doom-core/harness/artifacts.sh
. "$ROOT/tests/doom-core/harness/artifacts.sh"

echo "== the entries, built for this host =="
H=${CORE_BUILD:-$DIR/host}
if [ -z "${CORE_BUILD:-}" ]; then
  s=$(date +%s)
  rm -rf "$H"
  dc_core_entries "$H" > "$DIR/host.out" 2>&1
  ok "the kernel builds the three entries" "$?" 0
  echo "  time host entries: $(( $(date +%s) - s )) s"
fi
grep -v '^#' "$ROOT/examples/doom/core/entries/units.tsv" > "$DIR/units.want"
grep -v '^#' "$H/manifest.tsv" > "$DIR/units.got" 2>/dev/null
ok "the build packed this tree's units, digest for digest" "$(cmp -s "$DIR/units.want" "$DIR/units.got" && echo same)" same

echo "== the program, with this tree's adapter =="
rm -rf "$DIR/adapter"
dc_route_adapter "$H" "$DIR/adapter" > "$DIR/adapter.out" 2>&1
rc=$?
for c in "$DIR/adapter"/spinel_adapter_*.c; do
  "$CC_BIN" -std=c11 -O1 -I"$DIR/adapter" -c "$c" -o "$DIR/adapter/obj/$(basename "$c" .c).o" >> "$DIR/adapter.out" 2>&1 || rc=$?
done
"$CC_BIN" -std=c11 -O1 -c "$ROOT/tests/doom-core/native/bound_map.c" -o "$DIR/bound_map.o" >> "$DIR/adapter.out" 2>&1 || rc=$?
LINKS="--link $DIR/bound_map.o"
for o in "$H"/doom_core_*.o "$DIR"/adapter/obj/*.o; do LINKS="$LINKS --link $o"; done
# shellcheck disable=SC2086
PATH=$SHIM:$PATH SPINEL_LIB="$SPINEL_LIB" "$SPINEL" "$ROOT/tests/doom-core/native/bound.rb" -o "$DIR/bound" \
  $LINKS --link -lpthread > "$DIR/bound.build" 2>&1 || rc=$?
ok "tests/doom-core/native/bound.rb builds with the entries and the adapter" "$rc" 0
[ -x "$DIR/bound" ] || summary

echo "== DEMO1's first $TICS tics =="
s=$(date +%s)
rm -rf "$DIR/alloc"; mkdir -p "$DIR/alloc"
"$DIR/bound" "$WADFILE" DEMO1 "$TICS" "$DIR/alloc" alloc > "$DIR/alloc.out" 2>&1
ok "the program plays $TICS tics" "$?|$(grep -c "^bound: alloc: $TICS tic(s)$" "$DIR/alloc.out")" "0|1"
echo "  time play: $(( $(date +%s) - s )) s"
grep -v '^#' "$FIX/DEMO1.tsv" | head -n "$TICS" > "$DIR/want.frames"
grep -v '^#' "$DIR/alloc/alloc.frames" > "$DIR/got.frames" 2>/dev/null
# FRAMES -> "N|same", or the first frame that differs
judge() {
  "$RUBY" -e 'w = File.readlines(ARGV[0], chomp: true); g = File.readlines(ARGV[1], chomp: true)
    i = w.each_index.find { |k| g[k] != w[k] }
    puts(i ? "#{g.size}|tic #{i}: #{g[i].inspect}, recorded #{w[i].inspect}" : "#{g.size}|same")' "$DIR/want.frames" "$1"
}
ok "every frame is the recorded one" "$(judge "$DIR/got.frames")" "$TICS|same"
if [ "$fail" -ne 0 ]; then tail -5 "$DIR/alloc.out" | sed 's/^/    /'; fi
"$RUBY" -e 'l = File.readlines(ARGV[0]); k = l.size / 2; f = l[k].split("\t"); f[1] = "0" * 16; l[k] = f.join("\t"); File.write(ARGV[1], l.join)' \
  "$DIR/want.frames" "$DIR/planted.frames"
ok "control: a frame planted wrong is found" "$(judge "$DIR/planted.frames" | grep -c '|tic ')" 1
summary
