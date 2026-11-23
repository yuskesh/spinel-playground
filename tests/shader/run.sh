#!/bin/sh
#
# tests/shader/run.sh — the shader lane, end to end, on this machine's GPU.
#
#   LLVM_PREFIX=... WGPU_NATIVE=... sh tests/shader/run.sh
#
#   LLVM_PREFIX  the LLVM whose mlir-opt, mlir-translate and clang the lane uses
#   WGPU_NATIVE  an unpacked wgpu-native release (include/, lib/); without it the
#                WGSL drawing section SKIPs
#   naga and spirv-val must be on PATH. RUBY defaults to ruby.
#
# What is checked, all against the lane's own contract:
#
#   1. generation: each subject (test/flat.rb, flat_msl.rb, tri.rb, prec.rb,
#      tex.rb, tex_nouni.rb, pass.rb, pass_explicit.rb)
#      compiles to SPIR-V that spirv-val accepts, is converted by naga, and
#      passes the generator's emission check (no hand-written spirv dialect
#      outside the shell);
#   2. the SPIR-V is canonical: adding the MSL lane leaves it byte-identical,
#      and :separate writes its FP_CONTRACT pragma into the MSL; a varying that
#      names an attribute gives the same WGSL as the method written out;
#   3. every file in test/reject/ is refused with exit 3; a textured shader's
#      output is marked and has no CPU references, and cmp and vcmp refuse a marked
#      directory before reading it, and without the marker stop at their missing
#      inputs in an empty directory (their only use here: no comparison runs);
#   4. Metal (draw_metal.m): the device compiles the generated MSL and draws with
#      it, under :separate and :fused; a broken MSL is refused (the control);
#   5. WGSL through wgpu-native (draw.c): the fragment subjects draw; the vertex
#      pipeline subject draws its quad over exactly the pixels whose centres the
#      scene's vertices enclose, and its coverage shader gives both triangles'
#      ids over the same pixels; a uniform change alone changes the image; a 2x2
#      texture gives hand-written RGBA at interior pixels, and three planted
#      faults (alpha dropped, arguments exchanged, u and v exchanged) are seen.
#
# Not run, because they compare with another implementation (oracles, kept as
# files): tools/shader/spinel-shader-cmp, spinel-shader-vcmp and
# spinel-shader-attrib, the CPU references the generator writes (ref.o, ref_c.c,
# ref_native.rb, raster_ref.c), the golden/ digests, and run_shader_gate.sh,
# which does all of those plus a wgpu/Dawn comparison.
#
# Exit 0 when everything passed, 1 on any failure, 2 when nothing failed but
# something was skipped.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
T="$REPO/tools/shader"
RUBY="${RUBY:-ruby}"
RES=256
IMG="$REPO/tests/shader/check_image.rb"

pass=0
fail=0
skip=0
W=$(mktemp -d "${TMPDIR:-/tmp}/shader-test.XXXXXX")
trap 'rm -rf "$W"' EXIT

ok()   { pass=$((pass + 1)); echo "PASS  $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL  $1"; }
skp()  { skip=$((skip + 1)); echo "SKIP  $1"; }
# img <name> <args for check_image.rb>
img() {
  name=$1; shift
  if line=$("$RUBY" "$IMG" "$@"); then ok "$name ($line)"; else bad "$name ($line)"; fi
}

[ -n "${LLVM_PREFIX:-}" ] || { echo "---- shader: SKIP (LLVM_PREFIX is not set)"; exit 2; }
CC="${CC:-$LLVM_PREFIX/bin/clang}"
export LLVM_PREFIX CC
for tool in naga spirv-val; do
  command -v "$tool" >/dev/null 2>&1 || { echo "---- shader: SKIP ($tool is not on PATH)"; exit 2; }
done
[ -x "$REPO/vendor/spinel/bin/spinel" ] || { echo "---- shader: SKIP (build vendor/spinel first)"; exit 2; }
if [ ! -x "$REPO/tools/contract/build/spinel-typedump" ]; then
  sh "$REPO/tools/contract/build.sh" >"$W/typedump.log" 2>&1 ||
    { cat "$W/typedump.log"; echo "---- shader: FAIL (spinel-typedump does not build)"; exit 1; }
fi

echo "== 1. generation"
for s in flat flat_msl tri prec tex tex_nouni pass pass_explicit; do
  if "$RUBY" "$T/spinel-rb2spv" "$T/test/$s.rb" --out "$W/$s" --res $RES >"$W/$s.log" 2>&1; then
    ok "$s.rb compiles"
  else
    bad "$s.rb compiles"; sed 's/^/      /' "$W/$s.log"; continue
  fi
  d=$(ls -d "$W/$s"/*/ | head -1)
  for spv in "$d"shader.spv "$d"shader_cov.spv; do
    [ -f "$spv" ] || continue
    if spirv-val "$spv" >"$W/val.log" 2>&1; then ok "$s: spirv-val accepts $(basename "$spv")"
    else bad "$s: spirv-val rejects $(basename "$spv")"; sed 's/^/      /' "$W/val.log"; fi
  done
  if [ -s "${d}shader.wgsl" ]; then ok "$s: naga wrote WGSL"; else bad "$s: no WGSL"; fi
  if grep -q '^  ok emission.mlir' "$W/$s.log"; then ok "$s: emission check holds"
  else bad "$s: the generator did not report its emission check"; fi
done

echo "== 2. canonical SPIR-V"
if cmp -s "$W/flat/flat/shader.spv" "$W/flat_msl/flat/shader.spv"; then
  ok "the MSL lane leaves the SPIR-V byte-identical"
else
  bad "adding the MSL lane changed the SPIR-V"
fi
if grep -q '^#pragma STDC FP_CONTRACT OFF' "$W/flat_msl/flat/shader.metal" 2>/dev/null; then
  ok ":separate writes the FP_CONTRACT OFF pragma into the MSL"
else
  bad "no FP_CONTRACT pragma in the :separate MSL"
fi

echo "== 2b. attributes passed through as varyings"
if cmp -s "$W/pass/pass/shader.wgsl" "$W/pass_explicit/pass/shader.wgsl"; then
  ok "a varying naming an attribute gives the WGSL of the method written out"
else
  bad "a varying naming an attribute differs from the method written out"
fi
sed 's/vr: :ar, vg: :ag, vb: :ab/vr: :ag, vg: :ar, vb: :ab/' "$T/test/pass.rb" >"$W/pass_swapped.rb"
if "$RUBY" "$T/spinel-rb2spv" "$W/pass_swapped.rb" --out "$W/pass_swapped" --res $RES >"$W/swap.log" 2>&1 &&
   [ -s "$W/pass_swapped/pass/shader.wgsl" ] &&
   ! cmp -s "$W/pass/pass/shader.wgsl" "$W/pass_swapped/pass/shader.wgsl"; then
  ok "two exchanged attributes change the WGSL (the control)"
else
  bad "the comparison does not see two exchanged attributes"
fi
if "$REPO/vendor/spinel/bin/spinel" "$W/pass/pass/ref_native.rb" -c -o "$W/pass_ref.c" >"$W/ref.log" 2>&1; then
  ok "the written methods also reach the CPU reference source (it compiles)"
else
  bad "the CPU reference source does not compile"; sed 's/^/      /' "$W/ref.log"
fi

echo "== 3. refusals"
nrej=0
for f in "$T"/test/reject/*.rb; do
  nrej=$((nrej + 1))
  "$RUBY" "$T/spinel-rb2spv" "$f" --out "$W/rej" >"$W/rej.log" 2>&1
  rc=$?
  if [ "$rc" = 3 ]; then ok "$(basename "$f") is refused (exit 3)"
  else bad "$(basename "$f") exit $rc, expected 3"; sed 's/^/      /' "$W/rej.log"; fi
done
[ "$nrej" -gt 0 ] || bad "no refusal cases found"

echo "== 3b. textured output"
d="$W/tex/tex"
if [ -f "$d/textured" ]; then ok "a textured shader's output carries the marker"; else bad "no textured marker"; fi
missing=0
for f in ref_native.rb ref_c.c ref_driver.c raster_ref.c; do [ -e "$d/$f" ] && missing=1; done
if [ "$missing" = 0 ]; then ok "a textured shader writes no CPU reference sources"; else bad "CPU references written for a textured shader"; fi
if grep -q '@group(0) @binding(1)' "$d/shader.wgsl" && grep -q '@group(0) @binding(2)' "$d/shader.wgsl" &&
   grep -q '@group(0) @binding(0)' "$d/shader.wgsl"; then ok "uniform, texture and sampler sit at bindings 0, 1 and 2"
else bad "the bindings of the textured shader moved"; fi
n="$W/tex_nouni/tex_nouni"
if grep -q '@group(0) @binding(1)' "$n/shader.wgsl" && ! grep -q '@group(0) @binding(0)' "$n/shader.wgsl"; then
  ok "without a uniform the texture stays at binding 1"
else bad "the bindings were closed up without a uniform"; fi
# The entry refusal of the comparison tools: they stop before reading anything.
# The empty directory is the control: without the marker each tool goes past the
# refusal and stops at its missing inputs, having compared nothing and started nothing.
mkdir -p "$W/mark/file" "$W/mark/dir/textured" "$W/mark/none"
: > "$W/mark/file/textured"
: > "$W/mark/file/ref_native.rb"
for tool in spinel-shader-cmp spinel-shader-vcmp; do
  for m in file dir; do
    "$RUBY" "$T/$tool" "$W/mark/$m" --res 4 >/dev/null 2>"$W/t.log"; rc=$?
    if [ "$rc" = 3 ] && grep -q 'samples a texture' "$W/t.log"; then ok "$tool refuses a marked directory ($m)"
    else bad "$tool on a marked directory ($m): exit $rc"; fi
  done
  "$RUBY" "$T/$tool" "$W/mark/none" --res 4 >"$W/t.log" 2>&1; rc=$?
  case "$tool" in
    spinel-shader-cmp)  want=1; text='^---- shader oracle: FAIL (5 failures)$' ;;
    spinel-shader-vcmp) want=4; text='FATAL No such file or directory .*wgpu\.ppm\.rgba' ;;
  esac
  if [ "$rc" = "$want" ] && grep -q "$text" "$W/t.log"; then ok "$tool stops at its missing inputs without the marker (the control)"
  else bad "$tool without the marker: exit $rc, expected $want"; sed 's/^/      /' "$W/t.log"; fi
done
# One output directory, rebuilt across the two forms.
R="$W/reuse"
genr() { "$RUBY" "$T/spinel-rb2spv" "$T/test/$1.rb" --out "$R" --res $RES >"$W/r.log" 2>&1; }
mark="$R/tex_nouni/textured"
refs() { n=0; for f in ref_native.rb ref_c.c ref_driver.c raster_ref.c; do [ -e "$R/tex_nouni/$f" ] && n=$((n + 1)); done; echo "$n"; }
if genr tex_nouni_plain && [ ! -e "$mark" ] && [ "$(refs)" = 4 ] &&
   genr tex_nouni && [ -f "$mark" ] && [ "$(refs)" = 0 ]; then
  ok "plain to textured: the marker appears and the CPU references go"
else bad "plain to textured in one directory"; sed 's/^/      /' "$W/r.log"; fi
mkdir -p "$W/fake"
printf '#!/bin/sh\nexit 1\n' > "$W/fake/naga"; chmod +x "$W/fake/naga"
if PATH="$W/fake:$PATH" "$RUBY" "$T/spinel-rb2spv" "$T/test/tex_nouni_plain.rb" --out "$R" --res $RES >"$W/r.log" 2>&1; then
  bad "the planted naga failure did not fail the build (the control)"
elif [ -f "$mark" ]; then ok "a failed plain build keeps the marker"
else bad "a failed plain build dropped the marker"; fi
if genr tex_nouni_plain && [ ! -e "$mark" ] && [ "$(refs)" = 4 ]; then ok "textured to plain: the marker goes after a complete build"
else bad "textured to plain in one directory"; sed 's/^/      /' "$W/r.log"; fi
# The texture's name reaches no SPIR-V, and sits past where decl_text stops.
sed 's/atlas:/glyphs:/' "$T/test/tex.rb" > "$W/sigctl.rb"
if "$RUBY" "$T/spinel-rb2spv" "$W/sigctl.rb" --out "$W/sigctl" --res $RES >"$W/r.log" 2>&1 &&
   cmp -s "$d/shader.spv" "$W/sigctl/tex/shader.spv" && ! cmp -s "$d/sig.txt" "$W/sigctl/tex/sig.txt"; then
  ok "a declaration change that leaves the SPIR-V alone still changes the signature"
else bad "the signature missed a change inside a multi-line textures:"; fi

echo "== 4. Metal"
if [ "$(uname -s)" != Darwin ]; then
  skp "Metal is macOS only"
elif ! "$CC" -O2 -fobjc-arc -framework Metal -framework Foundation "$T/draw_metal.m" \
       -o "$W/draw_metal" >"$W/dm.log" 2>&1; then
  bad "draw_metal.m builds"; sed 's/^/      /' "$W/dm.log"
else
  ok "draw_metal.m builds"
  M="$W/flat_msl/flat"
  sed 's|^#pragma STDC FP_CONTRACT OFF.*$||' "$M/shader.metal" > "$W/fused.metal"
  for v in separate fused; do
    src="$M/shader.metal"; [ "$v" = fused ] && src="$W/fused.metal"
    if "$W/draw_metal" "$src" default u8 "$W/metal_$v.rgba" $RES $RES >"$W/m.log" 2>&1; then
      ok "Metal compiles the :$v MSL and draws ($(sed -n 's/^# device=//p' "$W/m.log"))"
      img "Metal :$v image" "$W/metal_$v.rgba" rgba8 $RES $RES --opaque --min-colors 1000
    else
      bad "Metal :$v"; sed 's/^/      /' "$W/m.log"
    fi
  done
  { cat "$M/shader.metal"; echo "this is not MSL"; } > "$W/broken.metal"
  if "$W/draw_metal" "$W/broken.metal" default u8 "$W/broken.rgba" $RES $RES >"$W/m.log" 2>&1; then
    bad "Metal accepted a broken MSL (the control)"
  else
    ok "Metal refuses a broken MSL (the control)"
  fi
fi

echo "== 5. WGSL through wgpu-native"
WG="${WGPU_NATIVE:-}"
if [ -z "$WG" ] || [ ! -f "$WG/lib/libwgpu_native.a" ]; then
  skp "WGPU_NATIVE is not set to an unpacked wgpu-native release"
else
  case "$(uname -s)" in
    Darwin) LIBS="-framework Metal -framework Foundation -framework QuartzCore -framework IOKit -framework IOSurface" ;;
    *)      LIBS="-lm -ldl -lpthread" ;;
  esac
  # shellcheck disable=SC2086
  if "$CC" -O2 -std=c11 -D_POSIX_C_SOURCE=200809L -I"$WG/include" "$T/draw.c" -o "$W/draw" \
       "$WG/lib/libwgpu_native.a" $LIBS >"$W/d.log" 2>&1; then
    ok "draw.c builds against wgpu-native"
    for s in flat prec; do
      d="$W/$s/$s"
      if "$W/draw" "$d/shader.wgsl" "$W/$s.ppm" --w $RES --h $RES >"$W/d.log" 2>&1; then
        ok "wgpu draws $s ($(sed -n 's/^adapter.device=//p' "$W/d.log"))"
        img "wgpu $s image" "$W/$s.ppm.rgba" rgba8 $RES $RES --opaque --min-colors 1000
      else
        bad "wgpu draws $s"; sed 's/^/      /' "$W/d.log"
      fi
    done

    # The vertex pipeline. The scene's quad spans NDC x -0.685546875..0.564453125
    # and y -0.720703125..0.529296875: pixel edges 40.25..200.25 across and
    # 60.25..220.25 down at 256, so the centres inside are columns 40..199 and
    # rows 60..219, 160 x 160 = 25600 pixels. Background is cleared to black.
    d="$W/tri/tri"
    scene() {   # <scene> -> vb.bin, vb_cov.bin (id = triangle + 1), ub.bin
      "$RUBY" -e 'toks = File.read(ARGV[0]).split; nv = toks[0].to_i
        a = toks[1, nv * 4].map(&:to_f)
        File.binwrite(ARGV[1], a.pack("e*"))
        cov = []
        nv.times { |v| cov.concat(a[v * 4, 4]); cov << (v / 3 + 1).to_f }
        File.binwrite(ARGV[2], cov.pack("e*"))
        File.binwrite(ARGV[3], [toks[1 + nv * 4].to_f].pack("e*"))' \
        "$1" "$W/vb.bin" "$W/vb_cov.bin" "$W/ub.bin"
    }
    NV=$(head -1 "$T/test/tri.scene.txt" | tr -d ' ')
    scene "$T/test/tri.scene.txt"
    if "$W/draw" "$d/shader.wgsl" "$W/tri1.ppm" --w $RES --h $RES --nv "$NV" \
         --vb "$W/vb.bin" --stride 16 --attr 1,1,1,1 --ub "$W/ub.bin" >"$W/d.log" 2>&1; then
      ok "wgpu draws the vertex pipeline (tri)"
      img "tri covers exactly the enclosed pixels" "$W/tri1.ppm.rgba" rgba8 $RES $RES \
        --opaque --lit 25600 --bbox 40,60,199,219 --min-colors 1000
    else
      bad "wgpu draws tri"; sed 's/^/      /' "$W/d.log"
    fi
    if "$W/draw" "$d/shader_cov.wgsl" "$W/cov.bin" --w $RES --h $RES --nv "$NV" \
         --vb "$W/vb_cov.bin" --stride 20 --attr 1,1,1,1,1 --ub "$W/ub.bin" --r32u >"$W/d.log" 2>&1; then
      img "the coverage shader gives both triangles' ids over the same pixels" \
        "$W/cov.bin.r32u" r32u $RES $RES --lit 25600 --bbox 40,60,199,219 --ids 1,2
    else
      bad "wgpu draws the coverage shader"; sed 's/^/      /' "$W/d.log"
    fi
    scene "$T/test/tri.scene2.txt"
    if "$W/draw" "$d/shader.wgsl" "$W/tri2.ppm" --w $RES --h $RES --nv "$NV" \
         --vb "$W/vb.bin" --stride 16 --attr 1,1,1,1 --ub "$W/ub.bin" >"$W/d.log" 2>&1 &&
       ! cmp -s "$W/tri1.ppm.rgba" "$W/tri2.ppm.rgba"; then
      ok "a uniform change alone (t 1.5 -> 0.5) changes the image, same WGSL"
    else
      bad "the uniform change did not reach the image"
    fi

    # A texture, drawn. Every expected pixel is written here by hand from the
    # 2x2 texture in tex_scene.rb: 16x16 target, u across and v down, so the
    # quadrants are the four texels. The pixels avoid the texel seams and the
    # quad's diagonal; no blending, so the raw alpha is what the shader wrote.
    TX="$W/texscene"; mkdir -p "$TX"
    AT_TEXEL="--at 3,3,16,32,48,64 --at 5,4,16,32,48,64 --at 9,1,80,96,112,128 --at 14,6,80,96,112,128 --at 1,9,144,160,176,184 --at 6,14,144,160,176,184 --at 11,11,208,224,240,200 --at 13,12,208,224,240,200"
    AT_TINT="--at 3,3,51,102,153,32 --at 9,1,51,102,153,64 --at 1,9,51,102,153,92 --at 11,11,51,102,153,100"
    AT_RGB5="--at 3,3,16,32,48,128 --at 9,1,80,96,112,128 --at 1,9,144,160,176,128 --at 11,11,208,224,240,128"
    tex_draw() {   # <wgsl> <out> glyph <color> <faint> | <wgsl> <out> plain
      wgsl=$1; out=$2; shift 2
      "$RUBY" "$REPO/tests/shader/tex_scene.rb" "$TX" "$@"
      if [ "$1" = glyph ]; then
        "$W/draw" "$wgsl" "$out" --w 16 --h 16 --nv 6 --vb "$TX/vb.bin" --stride 36 \
          --attr 1,1,1,1,1,1,1,1,1 --ub "$TX/ub.bin" --tex "$TX/tex.rgba" --tex-w 2 --tex-h 2 >"$W/d.log" 2>&1
      else
        "$W/draw" "$wgsl" "$out" --w 16 --h 16 --nv 6 --vb "$TX/vb.bin" --stride 16 \
          --attr 1,1,1,1 --tex "$TX/tex.rgba" --tex-w 2 --tex-h 2 >"$W/d.log" 2>&1
      fi
    }
    d="$W/tex/tex"
    # shellcheck disable=SC2086
    if tex_draw "$d/shader.wgsl" "$W/t1.ppm" glyph 1.0 0.5; then
      img "color=1: the texel's RGBA, faint ignored" "$W/t1.ppm.rgba" rgba8 16 16 --lit 256 --tol 1 $AT_TEXEL
    else bad "wgpu draws the textured subject"; sed 's/^/      /' "$W/d.log"; fi
    # shellcheck disable=SC2086
    if tex_draw "$d/shader.wgsl" "$W/t0.ppm" glyph 0.0 0.5; then
      img "color=0: the varying's RGB, the texel's alpha times faint" "$W/t0.ppm.rgba" rgba8 16 16 --lit 256 --tol 1 $AT_TINT
    else bad "wgpu draws the textured subject (color=0)"; sed 's/^/      /' "$W/d.log"; fi
    # shellcheck disable=SC2086
    if tex_draw "$W/tex_nouni/tex_nouni/shader.wgsl" "$W/tn.ppm" plain; then
      img "no uniform: the texel's RGB, the constant alpha" "$W/tn.ppm.rgba" rgba8 16 16 --lit 256 --tol 1 $AT_RGB5
    else bad "wgpu draws the textured subject without a uniform"; sed 's/^/      /' "$W/d.log"; fi
    # The controls: each breaks one thing the checks above claim to see.
    tex_broken() {   # <what> <sed expression>
      nm=$(printf '%s' "$1" | tr -c 'a-z' _)
      sed "$2" "$T/test/tex.rb" > "$W/$nm.rb"
      cmp -s "$W/$nm.rb" "$T/test/tex.rb" && { bad "control '$1' changed nothing"; return; }
      "$RUBY" "$T/spinel-rb2spv" "$W/$nm.rb" --out "$W/$nm" --res $RES >"$W/r.log" 2>&1 ||
        { bad "control '$1' does not build"; sed 's/^/      /' "$W/r.log"; return; }
      tex_draw "$W/$nm/tex/shader.wgsl" "$W/$nm.ppm" glyph 1.0 0.5 ||
        { bad "control '$1' does not draw"; sed 's/^/      /' "$W/d.log"; return; }
      # shellcheck disable=SC2086
      "$RUBY" "$IMG" "$W/$nm.ppm.rgba" rgba8 16 16 --tol 1 $AT_TEXEL >"$W/c.log"; rc=$?
      if [ "$rc" = 1 ]; then ok "the check sees $1 (the control)"
      else bad "the check missed $1 (exit $rc): $(cat "$W/c.log")"; fi
    }
    tex_broken "the sampled alpha dropped" 's/^  ta \* (color.*/  faint/'
    tex_broken "two texel arguments exchanged" '/def frag_r/s/tr, tg, tb, ta/tg, tr, tb, ta/'
    tex_broken "u and v exchanged" 's/coord: \[:u, :v\]/coord: [:v, :u]/'
  else
    bad "draw.c builds against wgpu-native"; sed 's/^/      /' "$W/d.log"
  fi
fi

echo "---- shader: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ] || exit 1
[ "$skip" = 0 ] || exit 2
