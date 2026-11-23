#!/bin/sh
#
# tests/doom-core/bound-resources.sh — the entries over resources the boundary did not allocate.
#
#   CORE_BUILD=... WAD=... LLVM_PREFIX=...|CLANG=... [SPINEL=... SPINEL_LIB=... ADAPTER=... READER=...] \
#     sh tests/doom-core/bound-resources.sh DIR
#
# tests/doom-core/verify.sh runs it after its kernel build, as CORE_BUILD.
#
# Decision 0021, "Resources at an address the boundary did not allocate", on
# the host. CORE_BUILD is a kernel build of the three entries in
# tests/doom-core/verify.sh's layout (doom_core_*.o and .h, stage/ with the
# packed contracts, manifest.tsv); building it takes about eight minutes, so
# this lane takes one rather than making its own. The adapter is generated
# here, by this tree's spinel-core-adapter.
#
# WHAT IT CHECKS
#   * the kernel build packed this tree's CORE units (its manifest is
#     examples/doom/core/entries/units.tsv's rows)
#   * tests/doom-core/native/bound.rb, built with the entries, opens DEMO1's
#     session, writes it at open and plays DEMO1 over the storage it allocated
#   * tools/doom/session-image.rb splits that session into the image, and
#     sha256sum -c accepts the image's digests; its resource part holds the
#     resources the entries are handed, and its derived index tables are the
#     ones the session built
#   * the same program maps the image's resource part read-only, binds every
#     resource field to it, and plays DEMO1 again: every frame is the
#     allocated run's, and both are the recorded frames
#     (tests/doom-core/fixtures/screens/DEMO1.tsv)
#   * a write to a bound resource is refused by the adapter, by its message
#   * four binds are refused, each by its own message: a field that is not a
#     resource, an address not aligned for the element, an address whose end
#     overflows, and a count other than the schema's
#   * CONTROL: an image whose colormap is inverted plays other frames,
#     so the bound run reads the image and not the storage it released
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: bound-resources.sh DIR}
RUBY=${RUBY:-ruby}
WADFILE=${WAD:-$ROOT/build/doom-wad/doom1.wad}
SPINEL=${SPINEL:-$ROOT/vendor/spinel/bin/spinel}
SPINEL_LIB=${SPINEL_LIB:-$ROOT/vendor/spinel/lib}
ADAPTER_BIN=${ADAPTER:-$ROOT/tools/mlir/native/build/bin/spinel-core-adapter}
READER=${READER:-${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}}
. "$ROOT/tools/test/source-stamp.sh"
source_stamp reader "$READER"
FIX=$ROOT/tests/doom-core/fixtures/screens
TICS=5026
CTL_TICS=35
pass=0; fail=0; skip=0; skips=""
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
skipped() { echo "  SKIP $1: $2 ($3)" >&2; skip=$((skip + 1)); skips="$skips
bound-resources: skipped $1: $2; enable with $3"; }
summary() {
  echo "bound-resources: $((pass + fail)) checked, $pass pass, $fail fail, $skip lane(s) skipped; $(( $(date +%s) - T0 )) s$skips"
  if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -ne 0 ]; then exit 1; fi
  [ "$fail" -eq 0 ]
  exit $?
}
T0=$(date +%s)
mkdir -p "$DIR" || exit 2
if [ -z "${CORE_BUILD:-}" ] || [ ! -f "${CORE_BUILD:-}/doom_core_render.o" ] || [ ! -f "$WADFILE" ] ||
   [ -z "${CLANG:-}${LLVM_PREFIX:-}" ] || [ ! -x "$SPINEL" ] || [ ! -x "$ADAPTER_BIN" ] || [ ! -x "$READER" ]; then
  skipped "the bound-resources lane" "it needs CORE_BUILD, the IWAD, LLVM_PREFIX or CLANG, the pinned compiler, the adapter and the reader" \
    "CORE_BUILD (a verify.sh build directory), WAD, LLVM_PREFIX or CLANG, SPINEL, ADAPTER and READER"
  summary
fi
CC_BIN=${CLANG:-$LLVM_PREFIX/bin/clang}
SHIM=$DIR/shim; mkdir -p "$SHIM"; ln -sf "$CC_BIN" "$SHIM/cc"
# shellcheck source=tests/doom-core/harness/artifacts.sh
. "$ROOT/tests/doom-core/harness/artifacts.sh"

echo "== the kernel build is this tree's =="
grep -v '^#' "$ROOT/examples/doom/core/entries/units.tsv" > "$DIR/units.want"
grep -v '^#' "$CORE_BUILD/manifest.tsv" > "$DIR/units.got"
ok "CORE_BUILD packed examples/doom/core/entries/units.tsv's units, digest for digest" \
   "$(cmp -s "$DIR/units.want" "$DIR/units.got" && echo same)" same

echo "== the program, with this tree's adapter =="
rm -rf "$DIR/adapter"
dc_route_adapter "$CORE_BUILD" "$DIR/adapter" > "$DIR/adapter.out" 2>&1
rc=$?
for c in "$DIR/adapter"/spinel_adapter_*.c; do
  "$CC_BIN" -std=c11 -O1 -I"$DIR/adapter" -c "$c" -o "$DIR/adapter/obj/$(basename "$c" .c).o" >> "$DIR/adapter.out" 2>&1 || rc=$?
done
ok "the adapter generates and compiles, and its registry binds" \
   "$rc|$(grep -c '^int32_t spinel_adapter_registry_bind(' "$DIR/adapter/spinel_adapter_registry.c")" "0|1"
"$CC_BIN" -std=c11 -O1 -c "$ROOT/tests/doom-core/native/bound_map.c" -o "$DIR/bound_map.o" > "$DIR/map.out" 2>&1
LINKS="--link $DIR/bound_map.o"
for o in "$CORE_BUILD"/doom_core_*.o "$DIR"/adapter/obj/*.o; do LINKS="$LINKS --link $o"; done
s=$(date +%s)
# shellcheck disable=SC2086
PATH=$SHIM:$PATH SPINEL_LIB="$SPINEL_LIB" "$SPINEL" "$ROOT/tests/doom-core/native/bound.rb" -o "$DIR/bound" \
  $LINKS --link -lpthread > "$DIR/bound.build" 2>&1
ok "tests/doom-core/native/bound.rb builds with the entries" "$?" 0
echo "  time build: $(( $(date +%s) - s )) s"
[ -x "$DIR/bound" ] || summary

echo "== DEMO1 over allocated storage, and the image of its session =="
mkdir -p "$DIR/alloc"
s=$(date +%s)
"$DIR/bound" "$WADFILE" DEMO1 "$TICS" "$DIR/alloc" alloc > "$DIR/alloc.out" 2>&1
ok "the allocated run plays $TICS tics" "$?|$(grep -c "^bound: alloc: $TICS tic(s)$" "$DIR/alloc.out")" "0|1"
echo "  time alloc: $(( $(date +%s) - s )) s"
grep -v '^#' "$FIX/DEMO1.tsv" | head -n "$TICS" > "$DIR/want.frames"
grep -v '^#' "$DIR/alloc/alloc.frames" > "$DIR/alloc.got" 2>/dev/null
ok "  every frame is the recorded one" "$(wc -l < "$DIR/alloc.got" | tr -d ' ')|$(cmp -s "$DIR/want.frames" "$DIR/alloc.got" && echo same)" \
   "$TICS|same"
"$RUBY" "$ROOT/tools/doom/session-image.rb" --catalog "$DIR/alloc/native-catalog.tsv" \
  --snapshot "$DIR/alloc/native-0.bin" --out "$DIR/image" > "$DIR/image.out" 2>&1
ok "session-image.rb writes the image" "$?" 0
sed 's/^/  /' "$DIR/image.out"
ok "  and sha256sum -c accepts its digests" \
   "$(cd "$DIR/image" && sha256sum -c image.sha256 2>&1 | grep -c ': OK$')" 3
nres=$(grep -v '^#' "$DIR/image/image.tsv" | awk -F'\t' '$5 == "resource"' | wc -l | tr -d ' ')
# The resources the entries are handed: entries/fields.tsv's fields whose
# schema role is resource.
nhanded=$(grep -v '^#' "$ROOT/examples/doom/core/entries/fields.tsv" | cut -f3 | sort -u |
  awk -F'\t' 'NR == FNR { if ($2 == "resource") r[$1] = 1; next } r[$1]' "$ROOT/examples/doom/core/state.tsv" - |
  wc -l | tr -d ' ')
ok "  every resource the entries are handed is in its resource part, and nothing else" "$nres" "$nhanded"
ok "  its derived index tables are the session's own" \
   "$("$RUBY" -e 'dir, want = ARGV; b = File.binread(File.join(dir, "resources.bin")); got = []
     File.foreach(File.join(dir, "image.tsv")) do |ln|
       next if ln.start_with?("#")
       f = ln.chomp.split("\t"); next unless f[4] == "derived"
       b.byteslice(Integer(f[5]), Integer(f[6])).unpack("q<*").each_with_index { |v, k| got << "#{f[0]}\t#{k}\t#{v}" }
     end
     w = File.readlines(want, chomp: true)
     puts "#{got.length}|#{got == w ? "same" : "differ"}"' "$DIR/image" "$DIR/alloc/derived.tsv")" \
   "$(wc -l < "$DIR/alloc/derived.tsv" | tr -d ' ')|same"

echo "== DEMO1 over the image's resources, mapped read-only and bound =="
mkdir -p "$DIR/boundrun"
s=$(date +%s)
"$DIR/bound" "$WADFILE" DEMO1 "$TICS" "$DIR/boundrun" bound "$DIR/image" > "$DIR/bound.out" 2>&1
ok "the bound run binds every resource and plays $TICS tics" \
   "$?|$(grep -c "^bound: bound $nres resource buffer(s) into the read-only image$" "$DIR/bound.out")|$(grep -c "^bound: bound: $TICS tic(s)$" "$DIR/bound.out")" \
   "0|1|1"
echo "  time bound: $(( $(date +%s) - s )) s"
grep -v '^#' "$DIR/boundrun/bound.frames" > "$DIR/bound.got" 2>/dev/null
ok "  every frame is the allocated run's" "$(wc -l < "$DIR/bound.got" | tr -d ' ')|$(cmp -s "$DIR/alloc.got" "$DIR/bound.got" && echo same)" \
   "$TICS|same"
ok "  a write to a bound resource is refused by the adapter" \
   "$(grep -c '^bound: write to [a-z_0-9]*: store [a-z_0-9]*\[0\] = 0 answered 1$' "$DIR/bound.out")" 1

echo "== binds that are refused, each by its message =="
"$DIR/bound" "$WADFILE" DEMO1 0 "$DIR/boundrun" refuse "$DIR/image" > "$DIR/refuse.out" 2>&1
ok "the refusal run completes" "$?" 0
ok "  a field that is not a resource" \
   "$(grep -c '^bound: role: [a-z_0-9]* is a persistent field, not a resource; only a resource is bound$' "$DIR/refuse.out")" 1
ok "  an address not aligned for the element" \
   "$(grep -c '^bound: alignment: the adapter would not bind [a-z_0-9]* at [0-9]* (element [2-7], count [0-9]*)$' "$DIR/refuse.out")" 1
ok "  an address whose end overflows" \
   "$(grep -c '^bound: overflow: the adapter would not bind [a-z_0-9]* at -2 (element 1, count [0-9]*)$' "$DIR/refuse.out")" 1
ok "  a count other than the schema's" \
   "$(grep -c '^bound: count: [a-z_0-9]* counts [0-9]*, the image says [0-9]*$' "$DIR/refuse.out")" 1

echo "== CONTROL: an image with other bytes plays other frames =="
rm -rf "$DIR/image-ctl"; cp -R "$DIR/image" "$DIR/image-ctl"
"$RUBY" -e 'dir = ARGV[0]; path = File.join(dir, "resources.bin"); b = File.binread(path)
  n = 0
  File.foreach(File.join(dir, "image.tsv")) do |ln|
    next if ln.start_with?("#")
    f = ln.chomp.split("\t")
    next unless f[0] == "renderer_colormap"
    off = Integer(f[5]); len = Integer(f[6])
    len.times { |i| b.setbyte(off + i, b.getbyte(off + i) ^ 0xff) }
    n += 1
  end
  File.binwrite(path, b); puts n' "$DIR/image-ctl" > "$DIR/ctl.patch" 2>&1
ok "the control inverts the colormap of its copy" "$(cat "$DIR/ctl.patch")" 1
mkdir -p "$DIR/ctlrun"
"$DIR/bound" "$WADFILE" DEMO1 "$CTL_TICS" "$DIR/ctlrun" bound "$DIR/image-ctl" > "$DIR/ctl.out" 2>&1
ctlrc=$?
head -n "$CTL_TICS" "$DIR/alloc.got" > "$DIR/ctl.want"
grep -v '^#' "$DIR/ctlrun/bound.frames" > "$DIR/ctl.got" 2>/dev/null
ok "  it plays $CTL_TICS tics, and its frames are not the allocated run's" \
   "$ctlrc|$(wc -l < "$DIR/ctl.got" | tr -d ' ')|$(cmp -s "$DIR/ctl.want" "$DIR/ctl.got" && echo same || echo differ)" \
   "0|$CTL_TICS|differ"
summary
