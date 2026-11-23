#!/bin/sh
# tests/raster/run.sh -- DOOM's 3D view drawn on the GPU, end to end.
#
#   sh tests/raster/run.sh
#
# The raster lane (tools/raster: the Job IR table, spinel-rastergen,
# spinel-jobcheck and the IREE seam) attached to this repository's DOOM
# (examples/doom, built with RASTER_GPU=1). Ported from spinel-llvm 463d49dd
# (P005; E061-E075). What it establishes, on this machine's GPU (Metal on macOS,
# CUDA where IREE_BUILD has the CUDA driver and a GPU is present):
#
#   1. the kernels: one frame's Job IR is exported (bin/dump_jobs.rb),
#      spinel-rastergen writes every gather kind into one module with its entry
#      table, and iree-compile builds it for that GPU -- at scales 1, 2, 3, 4 and 6
#      (320x200 to 1920x1200); the tracked sp_job_table.h is what spinel-jobtable
#      emits, and spinel-jobtable's and spinel-jobcheck's checks pass
#   2. the Ruby-to-C interface refuses its broken shapes: bin/gpu_reject.rb's
#      cases are all REJECT, none ESCAPED, and its positive controls pass
#   3. the -res spelling refuses what it must (E075's CLI table) and accepts a
#      valid resolution
#   4. THE CHECK: DEMO1, DEMO2 and DEMO3 play to their end with the 3D view on
#      the GPU, at 320x200, 640x400, 960x600, 1280x800 and 1920x1200 -- the
#      last three were blocked by the ANG180 read past finetangent until it was
#      fixed (tools/raster/README.md). "Their end" is each demo lump's own
#      length, read from the IWAD (13-byte header, 4 bytes per tic, 0x80
#      marker), and every frame must have been drawn by the GPU: gpu frames ==
#      tics, rejects == 0.
#   5. DEMO1 screenshots at tics 35, 399 and 1000 have at least 50%
#      non-black RGB pixels inside the 3D viewport, excluding the HUD/border.
#
# No oracle runs: frame comparisons against the CPU executor (bin/gpu_demo.rb,
# E073's sample.tsv) or doomgeneric stay as files.
#
# Takes about 8 minutes, most of it the 1920x1200 demos. Not here, because it
# is not the GPU path: the plain CPU renderer at 1280x800, which the fix also
# brought to the end of DEMO1 (tools/raster/README.md gives the command).
#
# Requires LLVM_PREFIX (or CC), IREE_SRC, IREE_BUILD, IREE_COMPILE, SDL2 (via
# pkg-config), and the IWAD: DOOM_IWAD, or tools/doom/fetch-iwad.sh fetches and
# verifies it. The GPU runs open an SDL window.
#
# Without either GPU only the screenshot controls run; the rest is skipped by
# name ("SKIP raster: no GPU runtime", exit 2), or fails with REQUIRE_ALL=1.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
W=${RASTER_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/raster-test.XXXXXX")}
mkdir -p "$W"
pass=0; fail=0; failed=""
ok() {  # name got want
  if [ "$2" = "$3" ]; then echo "ok   $1"; pass=$((pass + 1))
  else echo "FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); failed="$failed|$1"; fi
}
step() {  # name command...
  n=$1; shift
  if "$@" > "$W/step.log" 2>&1; then echo "ok   $n"; pass=$((pass + 1)); return 0; fi
  echo "FAIL $n"; tail -5 "$W/step.log" | sed 's/^/     /'
  fail=$((fail + 1)); failed="$failed|$n"; return 1
}

# The GPU: Metal on macOS, CUDA where the IREE runtime was built with its driver
# and a GPU is present. Without one the screenshot controls, which need no GPU,
# run, and the rest of the lane is one named skip: exit 2, as
# tests/shader/run.sh, or a failure under REQUIRE_ALL=1.
GPU=
if [ "$(uname -s)" = Darwin ]; then GPU=metal
elif grep -q '^IREE_HAL_DRIVER_CUDA:BOOL=ON' "${IREE_BUILD:-/nonexistent}/CMakeCache.txt" 2>/dev/null &&
     nvidia-smi -L 2>/dev/null | grep -q GPU; then GPU=cuda; fi
if [ -z "$GPU" ]; then
  step "screenshot visibility controls" "${RUBY:-ruby}" "$HERE/visibility-controls.rb" || exit 1
  if [ "${REQUIRE_ALL:-0}" = 1 ]; then
    echo "FAIL raster: no GPU runtime (REQUIRE_ALL=1)"
    echo "raster: $pass passed, 1 failed"; exit 1
  fi
  echo "SKIP raster: no GPU runtime"
  echo "raster: $pass passed, 0 failed, 1 skipped"; exit 2
fi
: "${IREE_SRC:?set IREE_SRC}" "${IREE_BUILD:?set IREE_BUILD}" "${IREE_COMPILE:?set IREE_COMPILE}"
CC=${CC:-${LLVM_PREFIX:?set LLVM_PREFIX or CC}/bin/clang}
SPINEL=${SPINEL:-$REPO/vendor/spinel/bin/spinel}
RUBY=${RUBY:-ruby}
RD=$REPO/tools/raster
WAD=${DOOM_IWAD:-$REPO/build/doom-wad/doom1.wad}
[ -f "$WAD" ] || sh "$REPO/tools/doom/fetch-iwad.sh" "$(dirname "$WAD")" >/dev/null || { echo "raster: no IWAD" >&2; exit 2; }

step "screenshot visibility controls" "$RUBY" "$HERE/visibility-controls.rb" || exit 1

# ---- the programs -------------------------------------------------------------
mkdir -p "$W/bin"
step "DOOM builds with the GPU raster path (RASTER_GPU=1)" \
  env RASTER_GPU=1 OUT="$W/bin/doom" BUILD_DIR="$W/doombuild" sh "$REPO/examples/doom/build.sh" || exit 1
ok "the build records the GPU raster path" \
   "$(sed -n 's/^raster=\(GPU\).*/\1/p' "$W/doombuild/build-provenance.txt")" "GPU"
step "bin/dump_jobs.rb builds" "$SPINEL" "$REPO/examples/doom/bin/dump_jobs.rb" --cc="$CC" -o "$W/bin/dump_jobs"
# gpu_reject links the same seam doom does.
IREE_DEFS="-DIREE_ALLOCATOR_SYSTEM_CTL=iree_allocator_libc_ctl -DIREE_HAVE_HAL_LOCAL_SYNC_DRIVER_MODULE=1 \
-DIREE_HAVE_HAL_LOCAL_TASK_DRIVER_MODULE=1 -DIREE_HAVE_VMVX_MODULE"
if [ "$GPU" = metal ]; then
  IREE_DEFS="$IREE_DEFS -DIREE_HAVE_HAL_METAL_DRIVER_MODULE=1"
  IREE_PLATFORM="--link -framework --link Metal --link -framework --link Foundation --link -lc++"
  IREE_BACKEND="--iree-hal-target-backends=metal-spirv --iree-metal-compile-to-metallib=false"
else
  IREE_PLATFORM="--link -lstdc++ --link -ldl --link -lm --link -lpthread"
  IREE_BACKEND="--iree-hal-target-backends=cuda"
fi
for src in sp_raster_gpu sp_raster_shim; do
  # shellcheck disable=SC2086
  "$CC" -O2 $IREE_DEFS -I"$IREE_SRC/runtime/src" -I"$IREE_BUILD/runtime/src" -I"$RD" \
    -c "$RD/$src.c" -o "$W/$src.o" 2>> "$W/seam.log" || { echo "FAIL compiling $src.c"; exit 1; }
done
step "bin/gpu_reject.rb builds against the GPU seam" "$SPINEL" "$REPO/examples/doom/bin/gpu_reject.rb" --cc="$CC" \
  -o "$W/bin/gpu_reject" --link "$W/sp_raster_gpu.o" --link "$W/sp_raster_shim.o" \
  --link "$IREE_BUILD/runtime/src/iree/runtime/libiree_runtime_unified.a" \
  --link "$IREE_BUILD/build_tools/third_party/flatcc/libflatcc_parsing.a" \
  --link "$IREE_BUILD/build_tools/third_party/printf/libprintf_printf.a" \
  $IREE_PLATFORM

# ---- 1. the kernels, at scale 1 and 2 --------------------------------------------
kernels() {  # scale
  s=$1; jd=$W/jobs/s$s; mkdir -p "$jd" "$W/mlir"
  "$W/bin/dump_jobs" "$WAD" DEMO1 0 "$jd" - "$s" &&
  "$RD/spinel-rastergen" mlir --jobs "$jd" --table "$jd/table.tsv" --kind every \
      -o "$W/mlir/s$s.mlir" --entries-out "$W/mlir/s${s}_entries.tsv" &&
  # shellcheck disable=SC2086
  "$IREE_COMPILE" $IREE_BACKEND "$W/mlir/s$s.mlir" -o "$W/mlir/s$s.$GPU.vmfb"
}
for s in 1 2 3 4 6; do
  step "scale $s: Job IR, spinel-rastergen and iree-compile ($GPU) build the kernels" kernels $s
  ok "scale $s: the entry table has the 7 gather entries" \
     "$(grep -vc '^#' "$W/mlir/s${s}_entries.tsv")" "7"
done

# The table: the tracked C header is what spinel-jobtable emits from a dumped
# table (this tool's own output against this repository's own file), and the
# table's checks pass.
tools_emit() { "$RD/spinel-jobtable" emit "$W/jobs/s1/table.tsv" > "$W/jt.h" && cmp -s "$W/jt.h" "$RD/sp_job_table.h"; }
step "sp_job_table.h is exactly what spinel-jobtable emits" tools_emit
step "spinel-jobtable's table checks pass" "$RD/spinel-jobtable" check "$W/jobs/s1/table.tsv" --tsv "$W/jobtable.tsv"

# spinel-jobcheck #1-#15 on the scale-1 frame, spelled as E071 ran it: one module
# per gather kind. (#8's .vmfb export check needs iree-dump-module and #9 the C
# driver's TSV; E071 passed neither, and neither is passed here.)
jd=$W/jobs/s1; RG=$RD/spinel-rastergen
KS=$(awk -F'\t' '$1 == "span_max_kx" { print ($2 <= 4) ? 4 : 16 }' "$jd/meta.tsv")
"$RG" mlir --jobs "$jd" --table "$jd/table.tsv" --kind wall --K 16 -o "$W/mlir/w.mlir" >/dev/null &&
"$RG" mlir --jobs "$jd" --table "$jd/table.tsv" --kind span --K "$KS" -o "$W/mlir/s.mlir" >/dev/null &&
"$RG" mlir --jobs "$jd" --table "$jd/table.tsv" --kind masked --K 40 -o "$W/mlir/m.mlir" >/dev/null &&
"$RG" mlir --jobs "$jd" --table "$jd/table.tsv" --kind fuzz --K 1 -o "$W/mlir/f.mlir" >/dev/null
step "spinel-jobcheck passes on the scale-1 frame (per-kind modules, as E071)" \
  "$RD/spinel-jobcheck" --jobs "$jd" --table "$jd/table.tsv" --mlir "$W/mlir/w.mlir" \
  --span-mlir "$W/mlir/s.mlir" --Kspan "$KS" --masked-mlir "$W/mlir/m.mlir" --fuzz-mlir "$W/mlir/f.mlir" \
  --fuzzoff "$jd/fuzzoff.bin" --entries "$W/mlir/s1_entries.tsv" --tsv "$W/jobcheck.tsv"
[ -f "$W/jobcheck.tsv" ] && echo "     jobcheck: $(awk -F'\t' 'NR > 1 { n[$3]++ } END { for (k in n) printf "%s=%d ", k, n[k] }' "$W/jobcheck.tsv")"

# ---- 2. the Ruby-to-C interface's refusals ------------------------------------
sed 's/\(opaque_gather_[0-9a-f]\{15\}\)./\10/' "$W/mlir/s1_entries.tsv" > "$W/mlir/s1_entries_stale.tsv"
"$W/bin/gpu_reject" "$WAD" "$W/mlir/s1.$GPU.vmfb" "$W/mlir/s1_entries.tsv" "$GPU" \
  "$W/mlir/s1_entries_stale.tsv" "$W/reject.tsv" > "$W/reject.log" 2>&1
ok "gpu_reject ran" "$?" "0"
ok "gpu_reject: no broken shape ESCAPED" "$(grep -c 'ESCAPED' "$W/reject.tsv")" "0"
echo "     gpu_reject: $(awk -F'\t' 'NR > 1 && $1 !~ /^#/ { n[$2]++ } END { for (k in n) printf "%s=%d ", k, n[k] }' "$W/reject.tsv")"

# ---- 3. the -res spelling (E075's CLI table) ------------------------------------
D=$W/bin/doom
res_case() {  # expect(reject|accept) spec
  if "$D" -iwad "$WAD" -res "$2" -tics 1 -nopace -scale 1 > "$W/res.log" 2>&1; then got=accept; else got=reject; fi
  ok "-res $2 is ${1}ed" "$got" "$1"
}
res_case reject 1000x625
res_case reject 640x480
res_case reject 2880x1800
res_case reject 1920
res_case reject 0x0
res_case accept 1280x800

# ---- 4. THE CHECK: each demo to its end, on the GPU -------------------------------
demo_tics() {  # lump -> tics from the IWAD itself
  ruby -e 'w = File.binread(ARGV[0]); n, off = w[4, 8].unpack("l<l<")
    n.times { |i| pos, size, name = w[off + i * 16, 16].unpack("l<l<Z8")
      next unless name == ARGV[1]
      b = w[pos, size]; m = b.index("\x80".b, 13); puts((m - 13) / 4); exit }
    exit 1' "$WAD" "$1"
}
for spec in 1:320x200 2:640x400 3:960x600 4:1280x800 6:1920x1200; do
  s=${spec%%:*}; res=${spec##*:}
  for d in DEMO1 DEMO2 DEMO3; do
    want=$(demo_tics $d)
    log=$W/play_${res}_$d.log
    set --
    if [ "$d" = DEMO1 ]; then
      shots=$W/visibility_$res
      set -- -shot "$shots" -shottic 35,399,1000
    fi
    "$D" -iwad "$WAD" -playdemo $d -nopace -scale 1 -res $res -gpu -jobs \
      -gpuvmfb "$W/mlir/s$s.$GPU.vmfb" -gpuentries "$W/mlir/s${s}_entries.tsv" -gpudev "$GPU" "$@" > "$log" 2>&1
    rc=$?
    tics=$(sed -n 's/^doom: \([0-9]*\) tics on .*/\1/p' "$log")
    frames=$(sed -n 's/^doom: gpu frames=\([0-9]*\) .*/\1/p' "$log")
    rejects=$(sed -n 's/^doom: gpu frames=[0-9]* rejects=\([0-9]*\) .*/\1/p' "$log")
    ok "$d at $res: the GPU opened" "$(grep -c '^doom: GPU raster ready' "$log")" "1"
    ok "$d at $res: played to its end ($want tics, rc 0)" "$rc/$tics" "0/$want"
    ok "$d at $res: every frame drawn by the GPU, none rejected" "$frames/$rejects" "$want/0"
    if [ "$d" = DEMO1 ]; then
      # This runner constructs setblocks=10: a full-width 168*s-row view at
      # (0,0), above the status bar. Verify the reported geometry and inset by
      # one logical pixel so no edge/border contributes to visibility.
      width=${res%x*}; viewheight=$((168 * s))
      view=$(sed -n 's/^doom: GPU raster ready (\([0-9]*x[0-9]*\) view)$/\1/p' "$log")
      ok "$d at $res: screenshot viewport geometry" "$view" "${width}x${viewheight}"
      viewport="$s,$s,$((width - 2 * s)),$((viewheight - 2 * s))"
      for tic in 35 399 1000; do
        if step "$d at $res tic $tic: the 3D viewport is visible" \
          "$RUBY" "$HERE/visibility.rb" "${shots}_${tic}.bmp" --screen "$res" --viewport "$viewport"; then
          sed 's/^/     /' "$W/step.log"
        fi
        cp "$W/step.log" "${shots}_${tic}.visibility.log"
      done
    fi
  done
done

echo
echo "raster: $pass passed, $fail failed"
[ "$fail" = 0 ] || { echo "raster: failed:$failed" | tr '|' '\n'; exit 1; }
