#!/usr/bin/env bash
#
# tools/shader/run_shader_gate.sh — the shader lane's standing gate (the shader plan's first phase)
#
#   tools/shader/run_shader_gate.sh
#
# A gate with two exits. It checks the 2 artifacts that come **from one emission (func + arith)**,
# each in its own way:
#
#   spirv exit   draws with wgpu and Dawn: 0 bytes of difference (comparison contract, layer 1); the u8 stage has the contract's
#                3 requirements (differences ±1 / every difference explained by the tie distance / difference rate ≤ 0.1%)
#   llvm exit    drives ref.o and compares it bitwise with C(-ffp-contract=off).
#                As a **positive control** it also requires a difference from C(=fast)
#
# Three more:
#   - **emission check**: no hand-written spirv dialect outside the shell
#     (the lane's admission rests on (iii) alone, so if that breaks the basis for admission is gone)
#   - **frozen signature**: compares sig and the SPIR-V sha256 with the golden (comparison contract, layer 0)
#   - **6 refusals**: input outside the subset fails loudly (so the gate does not look only at green)
#
# Exit codes: PASS 0 / FAIL 1 / **SKIP 2**.
# When a prerequisite (wgpu/Dawn/naga/mlir-opt) is missing it returns SKIP, not PASS —
# this repository does not build checks where "nothing ran" turns green.
set -uo pipefail
# An oracle (tests/ORACLES.tsv): it runs only on the owner's instruction.
"$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)/tools/oracle/gate" tools/shader/run_shader_gate.sh whole || exit 0

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/spinel-shader-gate"
RES="${RES:-256}"
SUBJ="${SUBJ:-$HERE/test/flat.rb}"
GOLDEN="$HERE/golden/flat.tsv"
# --- OS branch (the Debian host's third GPU leg) ---
# The repair is **additive**: the macOS branch is unchanged to the byte. Only the Linux branch was added.
# The Metal lane section (below) skips by itself with `command -v xcrun`, so it is untouched.
case "$(uname -s)" in
  Darwin) OS_KIND=macos ;;
  *)      OS_KIND=linux ;;
esac

if [ "$OS_KIND" = macos ]; then
  LLVM_BIN="${LLVM_BIN:-/opt/homebrew/opt/llvm/bin}"
  DAWN_TAIL="macos-latest-Release"
else
  # Debian puts apt.llvm.org's LLVM 22 in /usr/lib/llvm-22 (the pinned version).
  LLVM_BIN="${LLVM_BIN:-/usr/lib/llvm-22/bin}"
  DAWN_TAIL="ubuntu-latest-Release"
fi
# The tools that consume .ll are pinned to the same version as mlir-translate (for the same reason as the generator)
# ★ Its position was fixed later: the added line had landed inside the Darwin branch,
#   so on Linux it was referenced while unset and failed with `CC_IR: unbound variable`
#   (set -u). It sits **after LLVM_BIN is set in both branches**. The default value is unchanged.
CC_IR="${CC_IR:-$LLVM_BIN/clang}"
# Make the child process (spinel-rb2spv) use the same LLVM.
export LLVM_BIN

# --- Keep the positive control's contraction independent of the ISA ---
# The x86-64 baseline has no FMA, so even `-ffp-contract=fast` does not contract,
# and the positive control **turns negative and FAILs falsely** (reporting a broken instrument).
# -mfma is added **to the control's build only** — the correct side (ref.o / c_off / raster_ref / R1) is
# not touched by a single byte. On arm64 FMA is in the baseline, so it does not take this branch.
# An explicit `-mfma`, not `-march=native` (no machine dependence brought in).
FAST_ISA=""
[ "$(uname -m)" = x86_64 ] && FAST_ISA="-mfma"

# --- Per-machine goldens are **per device** (revised) ---
# With a key of (OS, arch), two devices of the same machine (RTX 4090 / llvmpipe) fought over
# the same file, and **the u8 rate passed with a ×3 margin** (a miss in the lenient direction).
# Revision = the key gets the slug of **the adapter observed at run time**, combined with a
# **self-check** against the golden's device/adapter lines (not relying on the key's spelling alone).
#
# The slug rule exists **only here** (not carried into cmp/vcmp).
device_slug() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//' \
    | cut -c1-24 | sed 's/-$//'
}
# MKEY / MGOLDEN / MGARG_* are decided **once the first drawing shows the adapter**
# (the "== draw" section below). Empty here.
MKEY=""; MGOLDEN=""; MGARG_FLAT=""; MGARG_TRI=""; MGARG_TRI2=""; ADAPTER=""
V="$ROOT/docs/researches/r010_probes/vendor/wgpu-native"
D="$(ls -d "$ROOT"/docs/researches/r010_probes/vendor/dawn/Dawn-*-"$DAWN_TAIL" 2>/dev/null | head -1)"
# Dawn's Linux build goes in lib64/, not lib/ (measured).
DAWN_LIB="$D/lib/libwebgpu_dawn.a"
[ -f "$DAWN_LIB" ] || DAWN_LIB="$D/lib64/libwebgpu_dawn.a"

FREEZE=0
[ "${1:-}" = "--freeze" ] && FREEZE=1

skip() { echo "---- shader gate: SKIP ($1)"; echo "     * a prerequisite is missing, so this is SKIP, not PASS. Nothing passes silently (Z-7)"; exit 2; }

for t in "$LLVM_BIN/mlir-opt" "$LLVM_BIN/mlir-translate"; do
  [ -x "$t" ] || skip "$t is missing (needs Homebrew LLVM 22)"
done
command -v naga      >/dev/null 2>&1 || skip "naga is missing (docs/tools/naga.md)"
command -v spirv-val >/dev/null 2>&1 || skip "spirv-val is missing"
[ -x "$ROOT/vendor/spinel/bin/spinel" ] || skip "bin/spinel is missing"
[ -d "$V/include" ] || skip "wgpu-native is missing ($V — run r010_probes/run_probes.sh once)"
[ -n "$D" ] && [ -d "$D/include" ] && [ -f "$DAWN_LIB" ] || skip "Dawn is missing (run r010_probes/run_probes.sh once)"

mkdir -p "$WORK"
rc=0
fail() { echo "FAIL  $1"; rc=1; }

# --- harness (the wgpu and Dawn versions from the same source) ---
if [ "$OS_KIND" = macos ]; then
  FW="-framework Metal -framework Foundation -framework QuartzCore -framework IOKit -framework IOSurface"
  DAWN_EXTRA="-framework CoreGraphics -lc++"
  POSIX_DEF=""
else
  # draw.c is off-screen only and has no OS-dependent API (measured). Only the libraries to link differ.
  FW="-lm -ldl -lpthread"
  DAWN_EXTRA="-lstdc++"
  # With -std=c11 + glibc, clock_gettime/CLOCK_MONOTONIC are not visible from <time.h>
  # (the same family of issue as before). macOS headers declare them unconditionally, so that branch does not need this.
  POSIX_DEF="-D_POSIX_C_SOURCE=200809L"
fi
if [ ! -x "$WORK/draw" ] || [ "$HERE/draw.c" -nt "$WORK/draw" ]; then
  echo "== building draw harness (wgpu)"
  # shellcheck disable=SC2086
  cc -O2 -std=c11 $POSIX_DEF -I"$V/include" "$HERE/draw.c" -o "$WORK/draw" \
     "$V/lib/libwgpu_native.a" $FW || skip "the wgpu harness does not build"
fi
if [ ! -x "$WORK/draw_dawn" ] || [ "$HERE/draw.c" -nt "$WORK/draw_dawn" ]; then
  echo "== building draw harness (Dawn)"
  # shellcheck disable=SC2086
  cc -O2 -std=c11 $POSIX_DEF -DR011_DAWN -I"$D/include" -I"$D/include/dawn" "$HERE/draw.c" \
     -o "$WORK/draw_dawn" "$DAWN_LIB" $FW \
     $DAWN_EXTRA || skip "the Dawn harness does not build"
fi

# --- generation (2 exits + emission check + table + sig) ---
echo "== generate ($(basename "$SUBJ"))"
rm -rf "$WORK/out"
ruby "$HERE/spinel-rb2spv" "$SUBJ" --out "$WORK/out" --res "$RES" || {
  echo "---- shader gate: FAIL (the generator failed)"; exit 1; }
DIR="$WORK/out/flat"

# --- make 4 references (R1 f64 / R2 f32 / C off / C fast) ---
echo "== references"
cc -O2 -o "$WORK/ref_bin" "$DIR/ref_driver.c" "$DIR/ref.o" || fail "ref.o does not link"
"$WORK/ref_bin" "$DIR/ref.rgba" || fail "the R2 reference does not run"
cc -O2 -ffp-contract=off  -o "$WORK/c_off"  "$DIR/ref_c.c" && "$WORK/c_off"  "$DIR/refc_off.rgba"  || fail "cannot make C(off)"
# shellcheck disable=SC2086
cc -O2 -ffp-contract=fast $FAST_ISA -o "$WORK/c_fast" "$DIR/ref_c.c" && "$WORK/c_fast" "$DIR/refc_fast.rgba" || fail "cannot make C(fast)"
"$ROOT/vendor/spinel/bin/spinel" "$DIR/ref_native.rb" -o "$WORK/native" >/dev/null 2>&1 \
  && "$WORK/native" > "$DIR/native_f64.txt" || fail "cannot make R1 (Spinel native f64)"

# --- drawing (wgpu / Dawn / f32) ---
echo "== draw"
"$WORK/draw"      "$DIR/shader.wgsl" "$DIR/wgpu.ppm" --w "$RES" --h "$RES" > "$WORK/draw_wgpu.log" 2>&1 || fail "cannot draw with wgpu"
# --- only here is it known "which device it ran on" ---
ADAPTER="$(awk -F= '/^adapter\.device=/{print $2; exit}' "$WORK/draw_wgpu.log")"
[ -n "$ADAPTER" ] || fail "draw prints no adapter.device (the per-device golden cannot be chosen)"
echo "== device: $ADAPTER"
if [ "$OS_KIND" != macos ]; then
  MKEY="$(uname -s | tr 'A-Z' 'a-z')-$(uname -m)-$(device_slug "$ADAPTER")"
  MGOLDEN="$HERE/golden/flat.$MKEY.tsv"
  MGARG_FLAT="--mgolden $MGOLDEN --rate-key u8_rate_flat"
  MGARG_TRI="--mgolden $MGOLDEN --rate-key u8_rate_tri"
  MGARG_TRI2="--mgolden $MGOLDEN --rate-key u8_rate_tri2"
fi
# --- self-check: confirm that the golden **belongs to this device** ---
# Even when the key's spelling matches, red if the contents are another device's. Applied to darwin (shared golden) too
# — the M1 has one GPU, but an Intel Mac's dGPU/iGPU has the same hole.
SELF_SRC="$GOLDEN"
[ -n "$MGOLDEN" ] && SELF_SRC="$MGOLDEN"
if [ -f "$SELF_SRC" ]; then
  g_ad="$(awk -F'\t' '$1=="adapter"{print $2}' "$SELF_SRC")"
  [ -n "$g_ad" ] || g_ad="$(awk -F'\t' '$1=="device"{print $2}' "$SELF_SRC")"
  if [ -z "$g_ad" ]; then
    echo "SKIP  the golden has no adapter/device line ($SELF_SRC) — refreeze: run_shader_gate.sh --freeze"
  elif [ "$(device_slug "$g_ad")" = "$(device_slug "$ADAPTER")" ]; then
    echo "PASS  golden self-check: the golden belongs to this device ($g_ad)"
  else
    fail "golden self-check: the golden belongs to another device (golden \"$g_ad\" / at run time \"$ADAPTER\") — $SELF_SRC"
  fi
fi
"$WORK/draw_dawn" "$DIR/shader.wgsl" "$DIR/dawn.ppm" --w "$RES" --h "$RES" >/dev/null 2>&1 || fail "cannot draw with Dawn"
"$WORK/draw"      "$DIR/shader.wgsl" "$DIR/g32.ppm" --w "$RES" --h "$RES" --f32 >/dev/null 2>&1 \
  && mv "$DIR/g32.ppm.rgba" "$DIR/wgpu_f32.rgba" || fail "cannot get the f32 output"

# --- oracle (comparison contract) ---
echo "== oracle (GR-1)"
# shellcheck disable=SC2086
ruby "$HERE/spinel-shader-cmp" "$DIR" --res "$RES" --tsv "$DIR/gates.tsv" $MGARG_FLAT || rc=1

# --- R3 attribution ---
# R3 is **an attributor, not the gate's correct answer** (that is R2). What is checked here:
#   ① attribution is possible — if the GPU chose a form outside the candidate space, FAIL loudly
#     (that case needs the enumeration model extended, not a re-attribution, so it never passes quietly)
#   ② the attributed contraction positions are the same as the golden's — automates the rule "a golden update
#     goes together with re-attribution". Closes the path of replacing only the SPIR-V hash and forgetting the attribution
echo "== attribution (R3, E136)"
mkdir -p "$WORK/attrib"
if ruby "$HERE/spinel-shader-attrib" "$SUBJ" --gpu "$DIR/wgpu_f32.rgba" \
     --out "$WORK/attrib" --res "$RES" > "$WORK/attrib/summary.txt" 2>&1; then
  echo "PASS  attributable (every channel has a contraction placement with nd=0)"
else
  fail "cannot attribute — the GPU took a form outside the candidate space (details: $WORK/attrib/summary.txt)"
fi

# --- frozen signature (comparison contract, layer 0) ---
SIG="$(cat "$DIR/sig.txt")"
SPV="$(shasum -a 256 "$DIR/shader.spv" | cut -d' ' -f1)"
if [ -f "$GOLDEN" ]; then
  g_sig="$(awk -F'\t' '$1=="sig"{print $2}' "$GOLDEN")"
  g_spv="$(awk -F'\t' '$1=="spv_sha256"{print $2}' "$GOLDEN")"
  [ "$SIG" = "$g_sig" ] || fail "sig differs from the golden (now $SIG / golden $g_sig)"
  [ "$SPV" = "$g_spv" ] || fail "the SPIR-V sha256 differs from the golden (now $SPV / golden $g_spv)"
  [ "$SIG" = "$g_sig" ] && [ "$SPV" = "$g_spv" ] && echo "PASS  golden matches (sig + SPIR-V sha256)"
  # Matching the R3 attribution. Several matches in one channel are joined with '|' and compared.
  # **Attribution is an observation of the machine**, so other machines compare with their own golden
  # (measured: NVIDIA folds different positions from the M1 in r/b, and the Mac acceptance run also
  #  confirmed "the M1 does not factor out" = the attribution differs structurally by device).
  ATT_SRC="$GOLDEN"
  [ -n "$MGOLDEN" ] && ATT_SRC="$MGOLDEN"
  if [ -n "$MGOLDEN" ] && [ ! -f "$MGOLDEN" ]; then
    echo "SKIP  no per-machine golden ($MGOLDEN) — freeze: run_shader_gate.sh --freeze"
    echo "      * not turned into a silent PASS (Z-7)"
  elif grep -q '^attrib_r' "$ATT_SRC" 2>/dev/null; then
    att_ok=1
    for ch in r g b; do
      a_now="$(awk -F'\t' -v c="$ch" '$1==c{print $2}' "$WORK/attrib/attributed.tsv" | paste -sd'|' -)"
      a_gold="$(awk -F'\t' -v k="attrib_$ch" '$1==k{print $2}' "$ATT_SRC")"
      if [ "$a_now" != "$a_gold" ]; then
        fail "the attribution differs from the golden (channel $ch: now $a_now / golden $a_gold) — if this is a driver/naga update, re-attribute and --freeze"
        att_ok=0
      fi
    done
    [ "$att_ok" = 1 ] && echo "PASS  the attribution matches the golden (the contraction placement did not move)"
  else
    echo "SKIP  $ATT_SRC has no attrib_* (refreeze: run_shader_gate.sh --freeze)"
  fi
fi
if [ "$FREEZE" = 1 ] && [ ! -f "$WORK/attrib/attributed.tsv" ]; then
  fail "--freeze but there is no attribution result (attrib failed) — a golden that cannot be attributed is not frozen (E136)"
  FREEZE=0
fi
if [ "$FREEZE" = 1 ] && [ -n "$MGOLDEN" ]; then
  # --freeze on other machines **does not write the shared golden (flat.tsv)**.
  # The machine's own file is written at the end of the script (once the vpipe rates are all in).
  echo "FREEZE  the shared golden ($GOLDEN) is not written — this machine's file is $MGOLDEN"
elif [ "$FREEZE" = 1 ]; then
  # Comparison contract, layer 0: the golden records the device name / OS / naga version. A golden update
  # goes together with re-attributing the contractions (rerunning attrib) — never replace only the numbers.
  # Automated: the 3 lines attrib_r/g/b freeze the attribution; the comparison is in the attrib section above.
  mkdir -p "$(dirname "$GOLDEN")"
  {
    printf 'key\tvalue\n'
    printf 'sig\t%s\n' "$SIG"
    printf 'spv_sha256\t%s\n' "$SPV"
    printf 'spv_bytes\t%s\n' "$(wc -c < "$DIR/shader.spv" | tr -d ' ')"
    printf 'res\t%s\n' "$RES"
    printf 'device\t%s\n' "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
    printf 'os\t%s (%s)\n' "$(sw_vers -productVersion 2>/dev/null || echo unknown)" \
                            "$(sw_vers -buildVersion 2>/dev/null || echo unknown)"
    printf 'naga\t%s\n' "$(naga --version 2>/dev/null | head -1)"
    printf 'llvm\t%s\n' "$("$LLVM_BIN/mlir-opt" --version 2>/dev/null | awk '/LLVM version/{print $NF}' | head -1)"
    printf 'spinel_pin\t%s\n' "$(git -C "$ROOT/vendor/spinel" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    # R3 attribution. A golden update goes together with re-attribution — if attrib did not run, nothing is frozen
    for ch in r g b; do
      printf 'attrib_%s\t%s\n' "$ch" \
        "$(awk -F'\t' -v c="$ch" '$1==c{print $2}' "$WORK/attrib/attributed.tsv" | paste -sd'|' -)"
    done
  } > "$GOLDEN"
  echo "FREEZE  wrote the golden: $GOLDEN"
elif [ ! -f "$GOLDEN" ]; then
  echo "SKIP  no golden ($GOLDEN). To make it:"
  echo "      tools/shader/run_shader_gate.sh --freeze"
fi

# --- MSL lane (only when a subject declares lanes: [:msl]) ---
MSL_SUBJ="${MSL_SUBJ:-$HERE/test/flat_msl.rb}"
if [ -f "$MSL_SUBJ" ] && ! command -v xcrun >/dev/null 2>&1; then
  # Do not keep quiet about not running. Metal-direct is macOS-only, so it is N/A.
  echo "== msl lane"
  echo "SKIP  MSL lane: xcrun is missing (N/A-metal — the direct Metal leg is specific to macOS)"
fi
if [ -f "$MSL_SUBJ" ] && command -v xcrun >/dev/null 2>&1; then
  echo "== msl lane ($(basename "$MSL_SUBJ"))"
  if [ ! -x "$WORK/draw_metal" ] || [ "$HERE/draw_metal.m" -nt "$WORK/draw_metal" ]; then
    clang -O2 -fobjc-arc -framework Metal -framework Foundation \
      "$HERE/draw_metal.m" -o "$WORK/draw_metal" || fail "the Metal harness does not build"
  fi
  rm -rf "$WORK/mout"
  if ruby "$HERE/spinel-rb2spv" "$MSL_SUBJ" --out "$WORK/mout" --res "$RES" >/dev/null 2>&1; then
    M="$WORK/mout/flat"
    # ① adding a lane does not change the SPIR-V (canonical) — MSL is derived by naga
    m_spv="$(shasum -a 256 "$M/shader.spv" | cut -d' ' -f1)"
    if [ "$m_spv" = "$SPV" ]; then echo "PASS  adding the MSL lane leaves the SPIR-V identical (the canonical form does not move)"
    else fail "the MSL lane changed the SPIR-V ($m_spv)"; fi

    sed 's|^#pragma STDC FP_CONTRACT OFF.*$||' "$M/shader.metal" > "$M/nopragma.metal"
    cc -O2 -o "$WORK/m_r2" "$M/ref_driver.c" "$M/ref.o" 2>/dev/null && "$WORK/m_r2" "$M/ref.rgba"

    # ② comparison contract, layer 1: Metal-direct :fused has 0 bytes of difference from wgpu / Dawn (**under the same contraction regime** the layers across match)
    "$WORK/draw_metal" "$M/nopragma.metal" default u8 "$M/mf_u8.rgba" "$RES" "$RES" >/dev/null 2>&1
    if cmp -s "$M/mf_u8.rgba" "$DIR/wgpu.ppm.rgba"; then
      echo "PASS  layer 1 holds on 3 implementations (wgpu / Dawn / direct Metal :fused differ by 0 bytes)"
    else fail "direct Metal :fused does not match wgpu"; fi

    # ③ **only :separate is bitwise equal to R2** — the very reason this lane exists
    "$WORK/draw_metal" "$M/shader.metal"   default f32 "$M/ms_f32.rgba" "$RES" "$RES" >/dev/null 2>&1
    "$WORK/draw_metal" "$M/nopragma.metal" default f32 "$M/mf_f32.rgba" "$RES" "$RES" >/dev/null 2>&1
    if cmp -s "$M/ms_f32.rgba" "$M/ref.rgba"; then echo "PASS  :separate is bitwise equal to R2 (GR-2)"
    else fail ":separate is not bitwise equal to R2 (the reason this lane exists is broken)"; fi
    if cmp -s "$M/mf_f32.rgba" "$M/ref.rgba"; then fail ":fused is bitwise equal to R2 too = the instrument is not working"
    else echo "PASS  :fused does not match R2 (the positive control — contraction takes effect)"; fi

    # ③b R3 attribution: Metal-direct :fused must be attributed to **the same contraction positions as wgpu**.
    # It states the "why" of layer 1's 0-byte difference (②) in terms of contraction positions, independently of the hash comparison.
    mkdir -p "$WORK/mattrib"
    if ruby "$HERE/spinel-shader-attrib" "$MSL_SUBJ" --gpu "$M/mf_f32.rgba" \
         --out "$WORK/mattrib" --res "$RES" > "$WORK/mattrib/summary.txt" 2>&1; then
      if cmp -s "$WORK/mattrib/attributed.tsv" "$WORK/attrib/attributed.tsv"; then
        echo "PASS  direct Metal :fused is attributed to the same contraction placement as wgpu (R3, E136)"
      else fail "the attribution of direct Metal :fused differs from wgpu (diff $WORK/mattrib/attributed.tsv $WORK/attrib/attributed.tsv)"; fi
    else fail "direct Metal :fused cannot be attributed ($WORK/mattrib/summary.txt)"; fi

    # ④ AIR gate (same shape as the other AIR check). ★ What is counted is **the fast flag on arithmetic instructions**.
    # An earlier experiment wrote "fast=0", but that was because its subject was small and fully inlined;
    # fast flags on calls remain even under :separate (a later correction).
    xcrun -sdk macosx metal -fbracket-depth=2048 -S -emit-llvm "$M/shader.metal" \
      -o "$M/air_sep.ll" 2>/dev/null
    xcrun -sdk macosx metal -fbracket-depth=2048 -S -emit-llvm "$M/nopragma.metal" \
      -o "$M/air_fus.ll" 2>/dev/null
    if [ -f "$M/air_sep.ll" ] && [ -f "$M/air_fus.ll" ]; then
      a_sep=$(grep -cE '= *(tail +)?(fmul|fadd|fsub) +fast' "$M/air_sep.ll")
      a_fus=$(grep -cE '= *(tail +)?(fmul|fadd|fsub) +fast' "$M/air_fus.ll")
      m_sep=$(grep -c fmuladd "$M/air_sep.ll")
      if [ "$a_sep" = 0 ] && [ "$m_sep" = 0 ]; then
        echo "PASS  AIR gate: the arithmetic of :separate has 0 fast flags / 0 fmuladd (:fused has $a_fus)"
      else fail "AIR gate: the arithmetic of :separate has fast=$a_sep fmuladd=$m_sep"; fi
      [ "$a_fus" = 0 ] && fail "AIR gate: the arithmetic of :fused has no fast flags either = the control does not work"
    else
      echo "SKIP  cannot get the AIR dump (xcrun metal)"
    fi
  else
    fail "generating the MSL subject failed"
  fi
fi

# --- vertex pipeline (only when test/tri.rb exists) ---
VSUBJ="${VSUBJ:-$HERE/test/tri.rb}"
VSCENE="$HERE/test/tri.scene.txt"
VSCENE2="$HERE/test/tri.scene2.txt"
# The coverage control scene (left edge = pixel centre +1/1024 px). The shape where 160 pixels split
# is **promoted to the standing gate** — explained not by a count but by "every mismatch is within one grid step of an edge".
VSCENE_EDGE="${VSCENE_EDGE:-$ROOT/docs/experiments/results/E138/tri_edge.scene.txt}"
# The grid step is the per-machine golden's coverage_grid_bits (Vulkan is matched against what vulkaninfo reports).
GRID_BITS=""
if [ -n "$MGOLDEN" ] && [ -f "$MGOLDEN" ]; then
  GRID_BITS="$(awk -F'\t' '$1=="coverage_grid_bits"{print $2}' "$MGOLDEN")"
elif [ -z "$MGOLDEN" ] && [ -f "$GOLDEN" ]; then
  GRID_BITS="$(awk -F'\t' '$1=="coverage_grid_bits"{print $2}' "$GOLDEN")"
fi
GBARG=""
[ -n "$GRID_BITS" ] && GBARG="--grid-bits $GRID_BITS"
# The value Vulkan reports (the first physical device = the one wgpu picks by default). Metal has no counterpart.
VK_SPB=""
if command -v vulkaninfo >/dev/null 2>&1; then
  VK_SPB="$(vulkaninfo 2>/dev/null | awk '/subPixelPrecisionBits/{print $3; exit}')"
fi
if [ -n "$GRID_BITS" ] && [ -n "$VK_SPB" ]; then
  if [ "$GRID_BITS" = "$VK_SPB" ]; then
    echo "PASS  the coverage grid width matches what Vulkan reports (coverage_grid_bits=$GRID_BITS = subPixelPrecisionBits)"
  else
    fail "the coverage grid width differs from what is reported (golden $GRID_BITS / vulkaninfo $VK_SPB) — the frozen value or the machine changed"
  fi
fi
if [ -f "$VSUBJ" ] && [ -f "$VSCENE" ]; then
  echo "== vertex pipeline ($(basename "$VSUBJ"))"
  rm -rf "$WORK/vout"
  if ruby "$HERE/spinel-rb2spv" "$VSUBJ" --out "$WORK/vout" --res "$RES" >/dev/null 2>&1; then
    VD="$WORK/vout/tri"
    # ① lowering differential (sweep): ref.o == C(off) bitwise, differs from C(fast) (positive control)
    cc -O2 -o "$WORK/v_sweep_ref" "$VD/ref_driver.c" "$VD/ref.o" && "$WORK/v_sweep_ref" "$VD/sweep_ref.bin" || fail "vpipe: the sweep ref does not build"
    cc -O2 -ffp-contract=off  -o "$WORK/v_sweep_off"  "$VD/ref_c.c" && "$WORK/v_sweep_off"  "$VD/sweep_off.bin"
    # shellcheck disable=SC2086
    cc -O2 -ffp-contract=fast $FAST_ISA -o "$WORK/v_sweep_fast" "$VD/ref_c.c" && "$WORK/v_sweep_fast" "$VD/sweep_fast.bin"
    if cmp -s "$VD/sweep_ref.bin" "$VD/sweep_off.bin"; then echo "PASS  vpipe lowering differential (sweep): ref.o == C(off) bitwise (7 functions x 4096)"
    else fail "vpipe: ref.o != C(off) — the MLIR lowering changes the semantics"; fi
    if cmp -s "$VD/sweep_ref.bin" "$VD/sweep_fast.bin"; then fail "vpipe: matches C(fast) = the positive control does not work"
    else echo "PASS  vpipe sweep positive control: differs from C(fast)"; fi

    # ② R2 (CPU rasterizer) and R1 (Spinel native f64)
    # -lm: needed on glibc since the distance to an edge (sqrt/fabs) was added.
    cc -O2 -ffp-contract=off -o "$WORK/v_raster" "$VD/raster_ref.c" "$VD/ref.o" -lm || fail "vpipe: raster_ref does not build"
    "$WORK/v_raster" "$VSCENE" "$VD/raster_ref.rgba" "$VD/cover.bin" "$VD/dist.bin" || fail "vpipe: the R2 rasterizer does not run"
    "$ROOT/vendor/spinel/bin/spinel" "$VD/ref_native.rb" -o "$WORK/v_native" >/dev/null 2>&1 \
      && "$WORK/v_native" "$VSCENE" > "$VD/native_f64.txt" || fail "vpipe: cannot make R1 (Spinel f64)"

    # ③ drawing (scene → vertex buffer/uniform → wgpu/Dawn, u8 + f32)
    ruby -e 'toks = File.read(ARGV[0]).split; nv = toks[0].to_i
      File.binwrite(ARGV[1], toks[1, nv*4].map(&:to_f).pack("e*"))
      File.binwrite(ARGV[2], toks[1+nv*4, 1].map(&:to_f).pack("e*"))' "$VSCENE" "$VD/vb.bin" "$VD/ub.bin"
    NVTX=$(head -1 "$VSCENE" | tr -d ' ')
    VARGS="--w $RES --h $RES --nv $NVTX --vb $VD/vb.bin --stride 16 --attr 1,1,1,1 --ub $VD/ub.bin"
    # shellcheck disable=SC2086
    "$WORK/draw"      "$VD/shader.wgsl" "$VD/wgpu.ppm" $VARGS >/dev/null 2>&1 || fail "vpipe: cannot draw with wgpu"
    # shellcheck disable=SC2086
    "$WORK/draw_dawn" "$VD/shader.wgsl" "$VD/dawn.ppm" $VARGS >/dev/null 2>&1 || fail "vpipe: cannot draw with Dawn"
    # shellcheck disable=SC2086
    "$WORK/draw"      "$VD/shader.wgsl" "$VD/g32.ppm" $VARGS --f32 >/dev/null 2>&1 \
      && mv "$VD/g32.ppm.rgba" "$VD/wgpu_f32.rgba" || fail "vpipe: cannot get f32"
    # shellcheck disable=SC2086
    "$WORK/draw_dawn" "$VD/shader.wgsl" "$VD/d32.ppm" $VARGS --f32 >/dev/null 2>&1 \
      && mv "$VD/d32.ppm.rgba" "$VD/dawn_f32.rgba" || fail "vpipe: cannot get the Dawn f32"

    # --- coverage pass: run a separate pass with a vertex buffer that carries IDs ---
    # ID of vertex i = i/3 + 1 (triangle number + 1). Carried as f32 (draw.c's attr supports only the Float32 family).
    cov_draw() {   # $1 = scene, $2 = output prefix
      ruby -e 'toks = File.read(ARGV[0]).split; nv = toks[0].to_i
        a = toks[1, nv*4].map(&:to_f)
        out = []
        nv.times { |v| out.concat(a[v*4, 4]); out << (v / 3 + 1).to_f }
        File.binwrite(ARGV[1], out.pack("e*"))' "$1" "$VD/vb_cov.bin"
      n="$(head -1 "$1" | tr -d ' ')"
      ca="--w $RES --h $RES --nv $n --vb $VD/vb_cov.bin --stride 20 --attr 1,1,1,1,1 --ub $VD/ub.bin"
      # shellcheck disable=SC2086
      "$WORK/draw"      "$VD/shader_cov.wgsl" "$VD/${2}wgpu_cov.bin" $ca --r32u >/dev/null 2>&1 \
        || fail "vpipe: the coverage pass cannot draw with wgpu"
      # shellcheck disable=SC2086
      "$WORK/draw_dawn" "$VD/shader_cov.wgsl" "$VD/${2}dawn_cov.bin" $ca --r32u >/dev/null 2>&1 \
        || fail "vpipe: the coverage pass cannot draw with Dawn"
    }
    cov_draw "$VSCENE" ""

    # ④ oracle (layer 1 / coverage / values 4ULP@range / u8 3 requirements)
    # shellcheck disable=SC2086
    ruby "$HERE/spinel-shader-vcmp" "$VD" --res "$RES" --tsv "$VD/gates.tsv" $MGARG_TRI || rc=1

    # ⑤ uniform update: swap only ub under the same WGSL/pipeline; every oracle holds again
    if [ -f "$VSCENE2" ]; then
      "$WORK/v_raster" "$VSCENE2" "$VD/raster_ref.rgba" "$VD/cover.bin" "$VD/dist.bin"
      "$WORK/v_native" "$VSCENE2" > "$VD/native_f64.txt"
      ruby -e 'toks = File.read(ARGV[0]).split; nv = toks[0].to_i
        File.binwrite(ARGV[1], toks[1, nv*4].map(&:to_f).pack("e*"))
        File.binwrite(ARGV[2], toks[1+nv*4, 1].map(&:to_f).pack("e*"))' "$VSCENE2" "$VD/vb.bin" "$VD/ub.bin"
      # shellcheck disable=SC2086
      "$WORK/draw"      "$VD/shader.wgsl" "$VD/wgpu.ppm" $VARGS >/dev/null 2>&1
      # shellcheck disable=SC2086
      "$WORK/draw_dawn" "$VD/shader.wgsl" "$VD/dawn.ppm" $VARGS >/dev/null 2>&1
      # shellcheck disable=SC2086
      "$WORK/draw"      "$VD/shader.wgsl" "$VD/g32.ppm" $VARGS --f32 >/dev/null 2>&1 && mv "$VD/g32.ppm.rgba" "$VD/wgpu_f32.rgba"
      # shellcheck disable=SC2086
      "$WORK/draw_dawn" "$VD/shader.wgsl" "$VD/d32.ppm" $VARGS --f32 >/dev/null 2>&1 && mv "$VD/d32.ppm.rgba" "$VD/dawn_f32.rgba"
      cov_draw "$VSCENE2" ""
      # shellcheck disable=SC2086
      if ruby "$HERE/spinel-shader-vcmp" "$VD" --res "$RES" --tsv "$VD/gates2.tsv" $MGARG_TRI2 >/dev/null 2>&1; then
        echo "PASS  uniform update (H4): every oracle holds again after only replacing ub (no regeneration)"
      else fail "vpipe: an oracle broke after the uniform update ($VD/gates2.tsv)"; fi
    fi

    # ⑤b the coverage control scene: promotes a one-off observation to the standing gate.
    # Explain **the place, not the count** — every mismatch must be "within one grid step of an edge".
    if [ -f "$VSCENE_EDGE" ]; then
      echo "== coverage control scene ($(basename "$VSCENE_EDGE"))"
      "$WORK/v_raster" "$VSCENE_EDGE" "$VD/raster_ref.rgba" "$VD/cover.bin" "$VD/dist.bin"
      "$WORK/v_native" "$VSCENE_EDGE" > "$VD/native_f64.txt"
      ruby -e 'toks = File.read(ARGV[0]).split; nv = toks[0].to_i
        File.binwrite(ARGV[1], toks[1, nv*4].map(&:to_f).pack("e*"))
        File.binwrite(ARGV[2], toks[1+nv*4, 1].map(&:to_f).pack("e*"))' \
        "$VSCENE_EDGE" "$VD/vb.bin" "$VD/ub.bin"
      NVE=$(head -1 "$VSCENE_EDGE" | tr -d ' ')
      EARGS="--w $RES --h $RES --nv $NVE --vb $VD/vb.bin --stride 16 --attr 1,1,1,1 --ub $VD/ub.bin"
      # shellcheck disable=SC2086
      "$WORK/draw"      "$VD/shader.wgsl" "$VD/wgpu.ppm" $EARGS >/dev/null 2>&1
      # shellcheck disable=SC2086
      "$WORK/draw_dawn" "$VD/shader.wgsl" "$VD/dawn.ppm" $EARGS >/dev/null 2>&1
      # shellcheck disable=SC2086
      "$WORK/draw"      "$VD/shader.wgsl" "$VD/g32.ppm" $EARGS --f32 >/dev/null 2>&1 && mv "$VD/g32.ppm.rgba" "$VD/wgpu_f32.rgba"
      # shellcheck disable=SC2086
      "$WORK/draw_dawn" "$VD/shader.wgsl" "$VD/d32.ppm" $EARGS --f32 >/dev/null 2>&1 && mv "$VD/d32.ppm.rgba" "$VD/dawn_f32.rgba"
      cov_draw "$VSCENE_EDGE" ""
      # The control scene gets no u8/value requirement (its coverage is split by design, so
      # a value tolerance has no meaning in principle). Only the two coverage axes are checked.
      # shellcheck disable=SC2086
      ruby "$HERE/spinel-shader-vcmp" "$VD" --res "$RES" --tsv "$VD/gates_edge.tsv" \
        --cov-edge $GBARG > "$VD/edge_out.txt" 2>&1
      awk -F'\t' '$1=="v_cov_layer1_id" || $1=="v_cov_edge_explained" || $1=="v_cov_edge_info" {print}' \
        "$VD/gates_edge.tsv"
      if awk -F'\t' '$1=="v_cov_edge_explained" && $2=="FAIL"{f=1} END{exit !f}' "$VD/gates_edge.tsv"; then
        fail "vpipe control scene: the coverage mismatch cannot be explained as within the grid width of an edge ($VD/gates_edge.tsv)"
      fi
      if awk -F'\t' '$1=="v_cov_layer1_id" && $2=="FAIL"{f=1} END{exit !f}' "$VD/gates_edge.tsv"; then
        fail "vpipe control scene: the coverage mask differs between wgpu and Dawn (axis 1 broken)"
      fi
    fi

    # ⑥ frozen signature (tri)
    V_SIG="$(cat "$VD/sig.txt")"
    V_SPV="$(shasum -a 256 "$VD/shader.spv" | cut -d' ' -f1)"
    # The coverage shader's canonical form. It goes in the **shared golden** (it should not depend on the machine).
    V_COV="$(shasum -a 256 "$VD/shader_cov.spv" | cut -d' ' -f1)"
    if grep -q '^cov_spv_sha256' "$GOLDEN" 2>/dev/null; then
      g_cov="$(awk -F'\t' '$1=="cov_spv_sha256"{print $2}' "$GOLDEN")"
      if [ "$V_COV" = "$g_cov" ]; then echo "PASS  the coverage shader SPIR-V matches the golden (E139 H5)"
      else fail "the coverage shader SPIR-V sha256 differs from the golden (now $V_COV / golden $g_cov)"; fi
    else
      echo "SKIP  the shared golden has no cov_spv_sha256 (now $V_COV)"
      echo "      * the shared golden is frozen on darwin — the job of the Mac acceptance (E139 step 3)"
    fi
    if [ -f "$GOLDEN" ] && grep -q '^tri_sig' "$GOLDEN" 2>/dev/null; then
      g_vsig="$(awk -F'\t' '$1=="tri_sig"{print $2}' "$GOLDEN")"
      g_vspv="$(awk -F'\t' '$1=="tri_spv_sha256"{print $2}' "$GOLDEN")"
      [ "$V_SIG" = "$g_vsig" ] || fail "vpipe: the sig of tri differs from the golden (now $V_SIG / golden $g_vsig)"
      [ "$V_SPV" = "$g_vspv" ] || fail "vpipe: the SPIR-V sha256 of tri differs from the golden"
      [ "$V_SIG" = "$g_vsig" ] && [ "$V_SPV" = "$g_vspv" ] && echo "PASS  vpipe golden matches (tri: sig + SPIR-V sha256)"
    elif [ "$FREEZE" != 1 ]; then
      echo "SKIP  the golden has no tri_* (refreeze: run_shader_gate.sh --freeze)"
    fi
    if [ "$FREEZE" = 1 ] && [ -z "$MGOLDEN" ] && [ -f "$GOLDEN" ]; then
      # Added in the Mac acceptance run: the coverage shader's canonical form (shared) and darwin's grid step.
      # Metal reports no subPixelPrecisionBits, so the measured value is frozen
      # (Apple and NVIDIA both 1/256 = 8 bits, with the transition point identified).
      { printf 'tri_sig\t%s\n' "$V_SIG"; printf 'tri_spv_sha256\t%s\n' "$V_SPV"
        printf 'cov_spv_sha256\t%s\n' "$V_COV"
        printf 'coverage_grid_bits\t8\n'
        # The self-check's counterpart. The existing device line (from sysctl = the CPU's brand string)
        # stays, and **the run-time adapter** is added as a separate line (additive).
        printf 'adapter\t%s\n' "$ADAPTER"; } >> "$GOLDEN"
      echo "FREEZE  added the tri signature + the canonical coverage shader + the grid width to the golden"
    fi
  else
    fail "vpipe: the generator failed"
  fi
fi

# --- freezing the machine's own golden ---
# Holds **only observations of the machine**: the R3 attribution (attrib_r/g/b), the 3 u8 rates and the environment lines.
# sig / spv_sha256 live on the shared side (flat.tsv) — shown to be machine-independent.
if [ "$FREEZE" = 1 ] && [ -n "$MGOLDEN" ]; then
  if [ ! -f "$WORK/attrib/attributed.tsv" ]; then
    fail "--freeze but there is no attribution result — a golden that cannot be attributed is not frozen (E136)"
  else
    rate_of() { awk -F'\t' -v k="$2" '$1==k{print $3}' "$1" 2>/dev/null; }
    r_flat="$(rate_of "$WORK/out/flat/gates.tsv" u8_rate_value)"
    r_tri="$(rate_of "$WORK/vout/tri/gates.tsv" v_u8_rate_value)"
    r_tri2="$(rate_of "$WORK/vout/tri/gates2.tsv" v_u8_rate_value)"
    mkdir -p "$(dirname "$MGOLDEN")"
    {
      printf 'key\tvalue\n'
      printf 'machine\t%s\n' "$MKEY"
      # Records **the adapter observed at run time** as it is (the self-check's counterpart).
      printf 'adapter\t%s\n' "$ADAPTER"
      printf 'device\t%s\n' "$(command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name --format=csv,noheader | head -1 || echo unknown)"
      printf 'driver\t%s\n' "$(command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 || echo unknown)"
      printf 'os\t%s\n' "$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -sr)"
      printf 'kernel\t%s\n' "$(uname -r)"
      printf 'naga\t%s\n' "$(naga --version 2>/dev/null | head -1)"
      printf 'llvm\t%s\n' "$("$LLVM_BIN/mlir-opt" --version 2>/dev/null | awk '/LLVM version/{print $NF}' | head -1)"
      printf 'spinel_pin\t%s\n' "$(git -C "$ROOT/vendor/spinel" rev-parse --short HEAD 2>/dev/null || echo unknown)"
      for ch in r g b; do
        printf 'attrib_%s\t%s\n' "$ch" \
          "$(awk -F'\t' -v c="$ch" '$1==c{print $2}' "$WORK/attrib/attributed.tsv" | paste -sd'|' -)"
      done
      # The coverage grid step. Vulkan writes the reported value (subPixelPrecisionBits) as it is;
      # an environment without one (Metal) writes the measured value (both machines confirmed 1/256 = 8 bits).
      printf 'coverage_grid_bits\t%s\n' "${VK_SPB:-8}"
      [ -n "$r_flat" ] && printf 'u8_rate_flat\t%s\n' "$r_flat"
      [ -n "$r_tri" ]  && printf 'u8_rate_tri\t%s\n'  "$r_tri"
      [ -n "$r_tri2" ] && printf 'u8_rate_tri2\t%s\n' "$r_tri2"
    } > "$MGOLDEN"
    echo "FREEZE  wrote this machine's golden: $MGOLDEN (rates: flat=$r_flat tri=$r_tri tri2=$r_tri2)"
  fi
fi

# --- v2 precision contract (only when test/prec.rb exists) ---
# In expressions with `/` and `sqrt`, the GPU and R2 are **not bitwise equal** (and that is correct).
# What is checked is "the difference is inside the upper bound composed from the expression tree (SPEC)".
PSUBJ="${PSUBJ:-$HERE/test/prec.rb}"
if [ -f "$PSUBJ" ]; then
  echo "== v2 precision contract ($(basename "$PSUBJ"))"
  rm -rf "$WORK/pout"
  if ruby "$HERE/spinel-rb2spv" "$PSUBJ" --out "$WORK/pout" --res "$RES" >/dev/null 2>&1; then
    PD="$WORK/pout/prec"
    P_TOL="$(cat "$PD/tol.txt")"
    # 2 references (R2 and C(off)) — the lowering differential has the same requirement as v1
    "$CC_IR" -O2 -o "$WORK/p_ref" "$PD/ref_driver.c" "$PD/ref.o" -lm && "$WORK/p_ref" "$PD/ref.rgba" \
      || fail "prec: cannot make the R2 reference"
    "$CC_IR" -O2 -ffp-contract=off -o "$WORK/p_coff" "$PD/ref_c.c" -lm && "$WORK/p_coff" "$PD/refc_off.rgba"
    if cmp -s "$PD/ref.rgba" "$PD/refc_off.rgba"; then echo "PASS  prec lowering differential: ref.o == C(off) bitwise (including / and sqrt)"
    else fail "prec: ref.o != C(off) — the math lowering changes the semantics"; fi
    # drawing (layer 1) and the tolerance check
    "$WORK/draw"      "$PD/shader.wgsl" "$PD/wgpu.ppm" --w "$RES" --h "$RES" >/dev/null 2>&1
    "$WORK/draw_dawn" "$PD/shader.wgsl" "$PD/dawn.ppm" --w "$RES" --h "$RES" >/dev/null 2>&1
    if cmp -s "$PD/wgpu.ppm.rgba" "$PD/dawn.ppm.rgba"; then echo "PASS  prec layer 1: wgpu vs Dawn differ by 0 bytes (bitwise across implementations even with / and sqrt)"
    else fail "prec: layer 1 broke"; fi
    "$WORK/draw" "$PD/shader.wgsl" "$PD/g32.ppm" --w "$RES" --h "$RES" --f32 >/dev/null 2>&1 \
      && mv "$PD/g32.ppm.rgba" "$PD/wgpu_f32.rgba"
    ruby -e '
      tol = File.read(ARGV[0]).to_f
      g = File.binread(ARGV[1]).unpack("e*")
      r = File.binread(ARGV[2]).unpack("e*")
      n = ARGV[3].to_i ** 2
      u1 = 2.0 ** -24
      smax = 1.0
      nd = 0
      mx = 0.0
      n.times { |k| 3.times { |c| v = r[k * 4 + c].abs; smax = v if v > smax } }
      n.times do |k|
        3.times do |c|
          d = (g[k * 4 + c] - r[k * 4 + c]).abs
          nd += 1 if d > 0
          mx = d if d > mx
        end
      end
      ulp = mx / (u1 * smax)
      ok = mx <= tol * u1 * smax
      puts format("%s  prec value: max=%.2f ULP@S ≤ limit %.2f (SPEC composition) — nd=%d (a difference is expected)",
                  ok ? "PASS" : "FAIL", ulp, tol, nd)
      exit(ok && nd > 0 ? 0 : 1)
    ' "$PD/tol.txt" "$PD/wgpu_f32.rgba" "$PD/ref.rgba" "$RES" || fail "prec: the value is over the limit, or the difference is 0 (the instrument is not working)"
    echo "      (the limit $P_TOL ULP@S = the composition of varying 4 + / 2.5 + sqrt 3)"
  else
    fail "prec: the generator failed"
  fi
fi

# --- 6 refusals (looking at red too) ---
echo "== reject cases"
nrej=0; nbad=0
for f in "$HERE"/test/reject/*.rb; do
  [ -f "$f" ] || continue
  nrej=$((nrej + 1))
  ruby "$HERE/spinel-rb2spv" "$f" --out "$WORK/rej" >/dev/null 2>&1
  [ "$?" = 3 ] || { echo "FAIL  $(basename "$f") is not refused (exit != 3)"; nbad=$((nbad + 1)); }
done
if [ "$nbad" = 0 ]; then echo "PASS  refused $nrej/$nrej (all exit 3)"; else rc=1; fi

# Do not call it PASS while the machine's own golden does not exist yet.
# The 3 requirements (2 u8 rates and the R3 attribution) staying SKIP and turning green is exactly the failure this prevents.
if [ "$rc" = 0 ] && [ -n "$MGOLDEN" ] && [ ! -f "$MGOLDEN" ] && [ "$FREEZE" != 1 ]; then
  echo "---- shader gate: SKIP (no per-machine golden $MGOLDEN — rates and R3 attribution not checked)"
  echo "     freeze: tools/shader/run_shader_gate.sh --freeze"
  exit 2
fi
if [ "$rc" = 0 ]; then echo "---- shader gate: PASS"; else echo "---- shader gate: FAIL"; fi
exit "$rc"
