#!/bin/sh
# tests/tensor/run.sh -- the tensor lane end to end: each example is built
# (tensor_def / assign! fusion / tensor_extern -> the native importer ->
# iree-compile, one .vmfb per backend), run on the CPU (local-sync) and on the
# GPU (metal on macOS, cuda where IREE_BUILD has the CUDA driver and a GPU is
# present), and checked against what its own README says the run shows.
#
#   sh tests/tensor/run.sh
#
# Requires IREE_SRC, IREE_BUILD and IREE_COMPILE (docs/toolchains/iree-3.11.0/
# INSTALLATION-RECORD.md), LLVM_PREFIX, and the native build. mnist's run.sh
# downloads the MNIST test set and checks it by sha256.
#
# No oracle runs here. The examples' f64 and ref.c reference comparisons run
# only with SPINEL_ORACLE=1, and this runner never sets it (a check below
# confirms the default run prints none of their lines). What is checked is each
# example's own claim about the compiled kernels:
#
#   dense-relu  `reduction: :fixed_tree` is bitwise identical on CPU and GPU
#   fusion      one invocation fused against two chained, and CPU and GPU
#               give the same hashes (elementwise * + relu only)
#   mnist       all 10000 test images are classified on each device, and the
#               accuracy clears a floor of 0.9 -- a sanity bound against a
#               pipeline broken to chance level (0.1); the labels are the
#               dataset's, not another implementation's answer
#   filter      3 invokes, 1 upload, NO download before the readback (the f32
#               intermediates stay on the device), one image's bytes read
#               back, and the same output on CPU and GPU
#   resize      2 invokes, 5 uploads, no download before the readback, the
#               output's bytes read back, the same output on CPU and Metal, and
#               an output size that is not a multiple of 4 refused loudly
#               (metal-spirv would write it short, R004 W11)
#
# CUDA keeps the bitwise claims except where `fastmath<contract>`, which the
# importer emits, lets the PTX contract a multiply and an add into fma.rn: the
# fused fusion statement, and resize at the one non-dyadic size. There the check
# is the size of the difference: for fusion against the two-kernel chain, which
# stays bitwise equal to the CPU, and for resize against the CPU's image.
#
# The fusion bound: with p = a*x and u = 2^-24, the chain computes
# (p(1+d1) + y)(1+d2) and fma computes (p + y)(1+d3), so the two differ by at
# most u(|p| + 2|p + y|) to first order. Here |p| <= 2.5 and the largest result
# is above 2.5, so relative to it the difference is below 3u (1.8e-7).
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
EX=$REPO/examples
W=$(mktemp -d "${TMPDIR:-/tmp}/tensor-test.XXXXXX")
trap 'rm -rf "$W"' EXIT
unset SPINEL_ORACLE

pass=0; fail=0; failed=""; na=0
# The GPU this host can run: Metal on macOS, CUDA where the IREE runtime was built
# with its driver and a GPU is present. Without one the lane runs every example
# on the CPU (local-sync), and each check that needs the GPU is printed as `n/a`,
# named, and counted apart: neither a pass nor a silent skip.
GPU=
if [ "$(uname -s)" = Darwin ]; then GPU=metal
elif grep -q '^IREE_HAL_DRIVER_CUDA:BOOL=ON' "${IREE_BUILD:-/nonexistent}/CMakeCache.txt" 2>/dev/null &&
     nvidia-smi -L 2>/dev/null | grep -q GPU; then GPU=cuda; fi
if [ -n "$GPU" ]; then DEVS="local-sync $GPU"; DEVNAME="local-sync and $GPU"
else DEVS="local-sync"; DEVNAME="local-sync"; fi
na() { echo "n/a  $1 (${2:-no GPU runtime here})"; na=$((na + 1)); }
ok() {  # name got want
  if [ "$2" = "$3" ]; then echo "ok   $1"; pass=$((pass + 1))
  else echo "FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); failed="$failed|$1"; fi
}
field() { awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$1"; }   # log key
# split a two-device log into one file per device (blocks start with `device`)
split_dev() {  # log prefix
  awk -F'\t' -v p="$2" '$1 == "device" { f = p "." $2 } f { print > f }' "$1"
}
step() {  # name command...  -- a build or run step; failure is counted
  n=$1; shift
  if "$@" > "$W/$n.log" 2>&1; then echo "ok   $n"; pass=$((pass + 1)); return 0; fi
  echo "FAIL $n"; tail -5 "$W/$n.log" | sed 's/^/     /'
  fail=$((fail + 1)); failed="$failed|$n"; return 1
}

# ---- dense-relu -------------------------------------------------------------
if step "dense-relu builds" sh "$EX/tensor/dense-relu/build.sh" &&
   step "dense-relu runs on $DEVNAME" sh "$EX/tensor/dense-relu/run.sh" $DEVS; then
  split_dev "$W/dense-relu runs on $DEVNAME.log" "$W/dr"
  ok "dense-relu ran on the CPU" "$(field "$W/dr.local-sync" device)" "local-sync"
  if [ -n "$GPU" ]; then
  ok "dense-relu ran on the GPU" "$(field "$W/dr.$GPU" device)" "$GPU"
  f1=$(field "$W/dr.local-sync" sumsq_fixed_tree); f2=$(field "$W/dr.$GPU" sumsq_fixed_tree)
  ok "dense-relu :fixed_tree is bitwise identical on CPU and $GPU" \
     "$([ -n "$f1" ] && [ "$f1" = "$f2" ] && echo yes || echo "no ($f1 / $f2)")" "yes"
  else na "dense-relu ran on the GPU"; na "dense-relu :fixed_tree is bitwise identical on CPU and Metal"; fi
  ok "dense-relu prints no oracle line by default" \
     "$(grep -cE 'oracle|ndiff_vs_f64|normwise' "$W/dense-relu runs on $DEVNAME.log")" "0"
fi

# ---- fusion -----------------------------------------------------------------
if step "fusion builds" sh "$EX/tensor/fusion/build.sh" &&
   step "fusion runs on $DEVNAME" sh "$EX/tensor/fusion/run.sh" $DEVS; then
  split_dev "$W/fusion runs on $DEVNAME.log" "$W/fu"
  for d in $DEVS; do
    ok "fusion on $d: the fused statement is one invocation" "$(field "$W/fu.$d" invocations_fused)" "1"
    ok "fusion on $d: the chain is two" "$(field "$W/fu.$d" invocations_chain)" "2"
  done
  for k in hash_fused hash_chain; do
    if [ "$GPU" = cuda ] && [ "$k" = hash_fused ]; then
    na "fusion hash_fused on CPU and cuda" "fastmath<contract> becomes fma.rn in the fused PTX"
    elif [ -n "$GPU" ]; then
    a=$(field "$W/fu.local-sync" $k); b=$(field "$W/fu.$GPU" $k)
    ok "fusion $k is the same on CPU and $GPU" \
       "$([ -n "$a" ] && [ "$a" = "$b" ] && echo yes || echo "no ($a / $b)")" "yes"
    else na "fusion on metal: the fused statement is one invocation, the chain is two, and $k is the same"; fi
  done
  if [ "$GPU" = cuda ]; then
    r=$(field "$W/fu.cuda" maxrel_fused_vs_chain)
    ok "fusion on cuda: the fused statement is within 3*2^-24 of the chain, relative to its largest value ($r)" \
       "$(awk -v v="$r" 'BEGIN { print (v ~ /^[0-9.]+e[-+][0-9]+$/ && v + 0 <= 1.8e-7) ? "yes" : "no" }')" "yes"
  fi
fi

# ---- mnist --------------------------------------------------------------------
if step "mnist builds" sh "$EX/tensor/mnist/build.sh" &&
   step "mnist runs on $DEVNAME" sh "$EX/tensor/mnist/run.sh" $DEVS; then
  split_dev "$W/mnist runs on $DEVNAME.log" "$W/mn"
  [ -n "$GPU" ] || na "mnist on metal classifies all 10000 test images and clears the 0.9 floor"
  for d in $DEVS; do
    ok "mnist on $d classifies all 10000 test images" "$(field "$W/mn.$d" n)/$(field "$W/mn.$d" batches)" "10000/100"
    acc=$(field "$W/mn.$d" accuracy)
    ok "mnist on $d clears the 0.9 sanity floor (accuracy $acc)" \
       "$(awk -v a="${acc:-0}" 'BEGIN { print (a >= 0.9) ? "yes" : "no" }')" "yes"
  done
fi

# ---- filter -------------------------------------------------------------------
if step "filter builds" sh "$EX/image/filter/build.sh" &&
   step "filter runs thr and gain on $DEVNAME" sh "$EX/image/filter/run.sh" $DEVS; then
  L="$W/filter runs thr and gain on $DEVNAME.log"
  # One blank-line-separated block per (device, tail). Each block is read whole
  # before it is filed, because `tail` comes after `pixels` within it.
  awk -v w="$W" 'BEGIN { RS = ""; FS = "\n" }
    { d = ""; t = ""
      for (i = 1; i <= NF; i++) { split($i, a, "\t"); if (a[1] == "device") d = a[2]; if (a[1] == "tail") t = a[2] }
      if (d != "" && t != "") print > (w "/fi." d "." t) }' "$L"
  for t in thr gain; do
    for d in $DEVS; do
      f="$W/fi.$d.$t"
      ok "filter $t on $d: 3 invokes, 1 upload, 0 downloads before the readback" \
         "$(field "$f" invoke)/$(field "$f" h2d)/$(field "$f" d2h_before_readback)" "3/1/0"
      ok "filter $t on $d: one image's bytes read back" "$(field "$f" readback_bytes)" "$(field "$f" pixels)"
    done
    if [ -n "$GPU" ]; then
    a=$(field "$W/fi.local-sync.$t" hash); b=$(field "$W/fi.$GPU.$t" hash)
    ok "filter $t gives the same image on CPU and $GPU" \
       "$([ -n "$a" ] && [ "$a" = "$b" ] && echo yes || echo "no ($a / $b)")" "yes"
    else na "filter $t on metal, and the same image on CPU and Metal"; fi
  done
  ok "filter prints no oracle line by default" "$(grep -cE 'ref_hash|ndiff_vs_f32ref|ties' "$L")" "0"
fi

# ---- resize -------------------------------------------------------------------
if step "resize builds" sh "$EX/image/resize/build.sh" &&
   step "resize runs on $DEVNAME" sh "$EX/image/resize/run.sh" $DEVS; then
  L="$W/resize runs on $DEVNAME.log"
  ndev=$(echo $DEVS | wc -w | tr -d ' ')
  rows=$(awk -F'  +' -v g="$GPU" '$2 == "local-sync" || (g != "" && $2 == g)' "$L" | wc -l | tr -d ' ')
  ok "resize produced its $((6 * ndev)) rows (6 per device)" "$rows" "$((6 * ndev))"
  bad=$(awk -F'  +' -v g="$GPU" '($2 == "local-sync" || (g != "" && $2 == g)) {
          split($4, o, "x")
          if ($6 != 5 || $7 != 0 || $8 != 2 || $10 != o[1] * o[2]) print }' "$L" | wc -l | tr -d ' ')
  ok "resize every row: 5 uploads, 0 downloads before readback, 2 invokes, the output's bytes" "$bad" "0"
  if [ -n "$GPU" ]; then
  # The one row CUDA may round differently (see the head of this file).
  skip=; [ "$GPU" = cuda ] && skip=1620x911
  diff=$(awk -F'  +' -v g="$GPU" -v skip="$skip" '$2 == "local-sync" { h[$1 " " $4] = $5 } $2 == g && $4 != skip && h[$1 " " $4] != $5 { print }' "$L" | wc -l | tr -d ' ')
  ok "resize gives the same image on CPU and $GPU for every size${skip:+ but $skip}" "$diff" "0"
  # W11: 1621x911 = 1476731 pixels, not a multiple of 4.
  I=${IMG:-$EX/image/img}/uhd.pgm
  B=$EX/image/resize/build
  if [ "$GPU" = metal ]; then
    if "$B/app" metal "$B/resize_metal.vmfb" 911 1621 - "$I" > "$W/w11.log" 2>&1; then r=accepted; else r=refused; fi
    ok "resize refuses an output that is not a multiple of 4" "$r" "refused"
    ok "resize the refusal says why" "$(grep -c 'multiple of 4' "$W/w11.log")" "1"
  else
    na "resize refuses an output that is not a multiple of 4" "a metal-spirv defect"
    p1=$B/uhd_1620x911_local-sync.pgm; p2=$B/uhd_1620x911_cuda.pgm
    if [ -s "$p1" ] && [ -s "$p2" ]; then
      m=$(cmp -l "$p1" "$p2" | awk 'function o(s, v, i) { v = 0; for (i = 1; i <= length(s); i++) v = v * 8 + substr(s, i, 1); return v }
        { d = o($2) - o($3); if (d < 0) d = -d; if (d > m) m = d } END { print m + 0 }')
    else m=missing; fi
    ok "resize $skip on cuda is within 1 of the CPU's image in every byte (largest difference $m)" \
       "$([ "$m" = 0 ] || [ "$m" = 1 ] && echo yes || echo no)" "yes"
  fi
  else na "resize on a GPU: the same image as the CPU, and the output size that is not a multiple of 4"; fi
fi

echo
echo "tensor: $pass passed, $fail failed$([ "$na" -gt 0 ] && echo ", $na not applicable")"
[ "$fail" = 0 ] || { echo "tensor: failed:$failed" | tr '|' '\n  '; exit 1; }
