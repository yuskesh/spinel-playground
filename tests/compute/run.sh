#!/bin/sh
#
# tests/compute/run.sh -- the Ruby compute route: tools/shader/spinel-rb2comp and
# its WebGPU, CUDA and Metal hosts (decision 0031).
#
#   LLVM_PREFIX                       required
#   CUDA_PATH                         the Toolkit whose cuda.h the CUDA host builds with
#   WASI_SYSROOT, WASI_BUILTINS, PLAYWRIGHT_DIR, PLAYWRIGHT_BROWSERS_PATH   the WebGPU host
#   COMPUTE_WEBGPU=hardware           use the real GPU, not the software adapter
#   COMPUTE_CHROME_CHANNEL            an installed browser, for example chrome
#   CC                                the Metal host: the compiler Spinel builds with
#
# Every expected value is written by hand in tests/compute/hosts. A run that
# skips a host exits 2 and does not count as passing that host. A host that does
# not exist on this OS (CUDA on macOS, Metal elsewhere) is N/A and is not counted.
# Exit 0 when everything passed, 1 on a failure, 2 when something was skipped.
set -u
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
T="$REPO/tests/compute"
GEN="$REPO/tools/shader/spinel-rb2comp"
SP="$REPO/vendor/spinel/bin/spinel"
pass=0; fail=0; skip=0
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }
skp() { skip=$((skip + 1)); echo "SKIP  $1"; }
na()  { echo "N/A   $1"; }
OS=$(uname -s)
KERNELS="saxpy scale poly histogram reduce semantics unused"
PAIRS="saxpy:saxpy scale:scale poly:poly histogram:histogram reduce:reduce semantics:semantics unused:unused scale:zero reduce:failures"

[ -n "${LLVM_PREFIX:-}" ] || { echo "---- compute: SKIP (LLVM_PREFIX is not set)"; exit 2; }
export LLVM_PREFIX
[ -x "$SP" ] || { echo "---- compute: FAIL ($SP is missing)"; exit 1; }
if [ ! -x "$REPO/tools/contract/build/spinel-typedump" ]; then
  sh "$REPO/tools/contract/build.sh" >/dev/null 2>&1 || { echo "---- compute: FAIL (spinel-typedump does not build)"; exit 1; }
fi
WK=$(mktemp -d "${TMPDIR:-/tmp}/compute.XXXXXX")
trap 'rm -rf "$WK"' EXIT

# -- the subset: each refusal names its kind, with exit 3.
while IFS="$(printf '\t')" read -r name kind; do
  o="$WK/ref/$name"; mkdir -p "$o"
  "$GEN" "$T/refuse/$name.rb" --out "$o" >"$o/log" 2>&1; rc=$?
  got=$(sed -n 2p "$o/reject.tsv" 2>/dev/null | cut -f1)
  if [ "$rc" -eq 3 ] && [ "$got" = "$kind" ]; then ok "refused $name as $kind"
  else bad "refused $name: exit $rc kind '$got', wanted 3 $kind"; sed -n 1,3p "$o/log"; fi
done <"$T/refuse.tsv"

# -- every exit: every kernel passes spirv-val and naga and yields PTX.
built="$WK/webgpu"; mkdir -p "$built" "$WK/cuda"
for k in $KERNELS; do
  if "$GEN" "$T/kernels/$k.rb" --out "$built" >"$WK/$k.log" 2>&1 &&
     [ -s "$built/$k/kernel.wgsl" ] && [ -s "$built/$k/kernel.metal" ] && [ -s "$built/$k/kernel.ptx" ]; then ok "built $k through every exit"
  else bad "built $k"; sed -n 1,5p "$WK/$k.log"; fi
  if grep -q '\[\[user(' "$built/$k/kernel.metal"; then bad "$k: an argument kept naga's placeholder binding"
  else ok "$k: every argument in the MSL has its binding"; fi
done

# -- the MSL bindings: slots come from the argument names, and anything unexpected stops the build.
if grep -q 'kernel_unused_arg_1_ \[\[buffer(1)\]\]' "$built/unused/kernel.metal"; then ok "MSL: an unused buffer does not move the next"
else bad "MSL: buffer y is not bound to slot 1"; fi
if grep -q '\[\[threadgroup(0)\]\]' "$built/reduce/kernel.metal"; then ok "MSL: shared memory has a binding"
else bad "MSL: shared memory has no binding"; fi
msl() { # file: a kernel signature with the given argument lines, then an end
  { echo 'kernel void k('; cat; echo ') {'; echo '}'; } >"$1"
}
msl "$WK/ok.metal" <<'EOF'
  metal::uint3 id [[thread_position_in_grid]]
, device t& k_arg_0_ [[user(fake0)]]
, constant s& _buffer_sizes [[user(fake0)]]
EOF
if "$GEN" --check-msl "$WK/ok.metal" 1 2>/dev/null | grep -q 'k_arg_0_ \[\[buffer(0)\]\]'; then ok "MSL rewrite accepts naga's argument list"
else bad "MSL rewrite refused naga's argument list"; fi
msl "$WK/m_range.metal" <<'EOF'
, device t& k_arg_1_ [[user(fake0)]]
EOF
msl "$WK/m_dup.metal" <<'EOF'
, device t& k_arg_0_ [[user(fake0)]]
, device t& k_arg_0_ [[user(fake0)]]
EOF
msl "$WK/m_other.metal" <<'EOF'
, device t& something_else [[user(fake0)]]
EOF
printf 'void f() {\n}\n' >"$WK/m_none.metal"
{ cat "$WK/ok.metal" "$WK/ok.metal"; } >"$WK/m_two.metal"
{ cat "$WK/ok.metal"; echo 'uint n = _buffer_sizes.size0;'; } >"$WK/m_sizes.metal"
for c in range dup other none two sizes; do
  "$GEN" --check-msl "$WK/m_$c.metal" 1 >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 4 ]; then ok "MSL rewrite stops on: $c"; else bad "MSL rewrite on $c: exit $rc, wanted 4"; fi
done

# -- the body allowlist accepts a real emission and refuses a planted op.
if "$GEN" --check-emission "$built/semantics/emission.mlir" >/dev/null 2>&1; then ok "allowlist accepts a real emission"
else bad "allowlist accepts a real emission"; fi
{ cat "$built/semantics/emission.mlir"; echo '      spirv.Bogus'; } >"$WK/planted.mlir"
"$GEN" --check-emission "$WK/planted.mlir" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then ok "allowlist refuses a planted spirv op"; else bad "allowlist refused nothing (exit $rc)"; fi

# The division reaches the hardware with a divisor that cannot be 0 or -1.
if ruby -e '
  lines = File.readlines(ARGV[0])
  divs = lines.map { |l| l[/arith\.floordivsi %\w+, (%\w+)/, 1] }.compact
  exit 1 if divs.empty?
  exit divs.all? { |d| lines.any? { |l| l =~ /#{d} = arith\.select %\w+, %\w+, %\w+ : i32/ } } ? 0 : 1
' "$built/semantics/emission.mlir"; then ok "every division takes a selected divisor"
else bad "a division does not take a selected divisor"; fi

check_output() { # label output-file exit-status
  n_pass=$(grep -c '^PASS' "$2"); n_fail=$(grep -c '^FAIL' "$2")
  if [ "$3" -eq 0 ] && [ "$n_pass" -gt 0 ] && [ "$n_fail" -eq 0 ]; then ok "$1 ($n_pass checks)"
  else bad "$1: exit $3, $n_pass passed, $n_fail failed"; grep '^FAIL' "$2" | sed -n 1,5p; fi
}

# -- the CUDA host
cuda=1
if [ "$OS" = Darwin ]; then na "CUDA host: not on macOS"; cuda=0
elif [ -z "${CUDA_PATH:-}" ] || [ ! -f "$CUDA_PATH/targets/x86_64-linux/include/cuda.h" ]; then skp "CUDA host: no cuda.h (set CUDA_PATH)"; cuda=0
elif ! nvidia-smi -L 2>/dev/null | grep -q GPU; then skp "CUDA host: no GPU"; cuda=0; fi
native() { # unit host-body output
  cat "$WK/cuda/$1/$1_host.rb" "$T/hosts/prelude.rb" "$T/hosts/$2.rb" >"$WK/n_$2.rb"
  "$SP" "$WK/n_$2.rb" -o "$WK/n_$2" >"$WK/n_$2.log" 2>&1 || { sed -n 1,5p "$WK/n_$2.log"; return 9; }
  "$WK/n_$2" >"$3" 2>&1
}
if [ "$cuda" -eq 1 ]; then
  export CUDA_PATH
  for k in $KERNELS; do
    "$GEN" "$T/kernels/$k.rb" --out "$WK/cuda" --host cuda >"$WK/$k.c.log" 2>&1 || bad "CUDA build $k"
  done
  for pair in $PAIRS; do
    u=${pair%:*}; h=${pair#*:}
    native "$u" "$h" "$WK/c_$h.out"; check_output "CUDA $h" "$WK/c_$h.out" $?
  done
  # Built and run once with the device, only to build it; the check is the next line.
  native scale nogpu "$WK/c_nogpu0.out" >/dev/null 2>&1
  CUDA_VISIBLE_DEVICES= "$WK/n_nogpu" >"$WK/c_nogpu.out" 2>&1; check_output "CUDA reports a missing device" "$WK/c_nogpu.out" $?

  # Controls: a planted fault must be seen.
  mkdir -p "$WK/pl" "$WK/cuda"
  cp "$T/planted/semantics.rb" "$WK/pl/semantics.rb"
  "$GEN" "$WK/pl/semantics.rb" --out "$WK/cuda" --host cuda >/dev/null 2>&1
  native semantics semantics "$WK/c_pl.out" || true
  if grep -q '^FAIL row' "$WK/c_pl.out"; then ok "control: a shared memory index error is seen"; else bad "control: a shared memory index error went unseen"; fi
  "$GEN" "$T/planted/nonatomic.rb" --out "$WK/cuda" --host cuda >/dev/null 2>&1
  native nonatomic nonatomic "$WK/c_na.out" || true
  if grep -q '^FAIL no update' "$WK/c_na.out"; then ok "control: a non-atomic count loses updates"; else bad "control: a non-atomic count lost nothing"; sed -n 1,3p "$WK/c_na.out"; fi
  # Restore the real kernel for anything after this point.
  "$GEN" "$T/kernels/semantics.rb" --out "$WK/cuda" --host cuda >/dev/null 2>&1
fi

# -- the WebGPU host
web=1
if [ -z "${WASI_SYSROOT:-}" ] || [ -z "${WASI_BUILTINS:-}" ]; then skp "WebGPU host: WASI_SYSROOT and WASI_BUILTINS are required"; web=0
elif [ -z "${PLAYWRIGHT_DIR:-}" ]; then skp "WebGPU host: PLAYWRIGHT_DIR is not set"; web=0; fi
wasm() { # unit host-body [gendir]
  gd=${3:-$built}
  cat "$gd/$1/$1_host.rb" "$T/hosts/prelude.rb" "$T/hosts/$2.rb" >"$WK/w_$2.rb"
  "$REPO/tools/wasm/spinel-wasm" "$WK/w_$2.rb" -o "$WK/w_$2.wasm" --host-api >"$WK/w_$2.log" 2>&1 || { sed -n 1,6p "$WK/w_$2.log"; return 9; }
}
browser() { node "$T/browser.mjs" "$REPO" "$1" "$2"; }
if [ "$web" -eq 1 ]; then
  export WASI_SYSROOT WASI_BUILTINS PLAYWRIGHT_DIR PLAYWRIGHT_BROWSERS_PATH
  for pair in $PAIRS; do
    u=${pair%:*}; h=${pair#*:}
    if wasm "$u" "$h"; then browser "$WK/w_$h.wasm" normal >"$WK/b_$h.out" 2>&1; check_output "WebGPU $h" "$WK/b_$h.out" $?
      [ "$h" != saxpy ] || grep '^adapter' "$WK/b_$h.out"
    else bad "WebGPU build $h"; fi
  done
  if wasm scale nogpu; then
    browser "$WK/w_nogpu.wasm" nogpu >"$WK/b_nogpu.out" 2>&1; check_output "WebGPU reports no GPU" "$WK/b_nogpu.out" $?
    browser "$WK/w_nogpu.wasm" nojspi >"$WK/b_nojspi.out" 2>&1
    if grep -q 'JSPI' "$WK/b_nojspi.out"; then ok "WebGPU reports no JSPI"; else bad "WebGPU reports no JSPI"; sed -n 1,3p "$WK/b_nojspi.out"; fi
  else bad "WebGPU build nogpu"; fi

  # Control: without the signed operand types, naga's WGSL divides as unsigned.
  mkdir -p "$WK/plw"
  "$GEN" "$T/kernels/semantics.rb" --out "$WK/plw" >/dev/null 2>&1
  if ruby "$T/plant_unsigned.rb" "$WK/plw/semantics/semantics_host.rb" && wasm semantics semantics "$WK/plw"; then
    browser "$WK/w_semantics.wasm" normal >"$WK/b_pl.out" 2>&1
    if grep -q '^FAIL row' "$WK/b_pl.out"; then ok "control: a signed-division error is seen"; else bad "control: a signed-division error went unseen"; fi
  else bad "WebGPU build of the control"; fi
fi

# -- the Metal host
metal=1
if [ "$OS" != Darwin ]; then na "Metal host: macOS only"; metal=0
elif [ -z "${CC:-}" ]; then skp "Metal host: CC is not set"; metal=0; fi
mbuild() { # gendir unit host-body
  cat "$1/$2/$2_host.rb" "$T/hosts/prelude.rb" "$T/hosts/$3.rb" >"$WK/m_$3.rb"
  "$SP" --cc="$CC" "$WK/m_$3.rb" -o "$WK/m_$3" >"$WK/m_$3.log" 2>&1 || { sed -n 1,5p "$WK/m_$3.log"; return 9; }
}
if [ "$metal" -eq 1 ]; then
  md="$WK/metal"; mkdir -p "$md"
  for k in $KERNELS; do
    "$GEN" "$T/kernels/$k.rb" --out "$md" --host metal >"$WK/$k.m.log" 2>&1 || bad "Metal build $k"
  done
  for pair in $PAIRS; do
    u=${pair%:*}; h=${pair#*:}
    mbuild "$md" "$u" "$h"; rc=$?
    if [ "$rc" -ne 0 ]; then bad "Metal build of $h"; continue; fi
    "$WK/m_$h" >"$WK/m_$h.out" 2>&1; check_output "Metal $h" "$WK/m_$h.out" $?
    MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 "$WK/m_$h" >"$WK/m_$h.dbg" 2>&1; check_output "Metal $h under the debug layer" "$WK/m_$h.dbg" $?
  done
  na "Metal reports a missing device: a Metal device cannot be hidden from a process"

  # Controls: a planted fault must be seen.
  pl="$WK/mpl"; mkdir -p "$pl"
  "$GEN" "$T/planted/semantics.rb" --out "$pl" --host metal >/dev/null 2>&1
  mbuild "$pl" semantics semantics && "$WK/m_semantics" >"$WK/m_pl.out" 2>&1
  if grep -q '^FAIL row' "$WK/m_pl.out"; then ok "control: a shared memory index error is seen"; else bad "control: a shared memory index error went unseen"; fi
  "$GEN" "$T/planted/nonatomic.rb" --out "$pl" --host metal >/dev/null 2>&1
  mbuild "$pl" nonatomic nonatomic && "$WK/m_nonatomic" >"$WK/m_na.out" 2>&1
  if grep -q '^FAIL no update' "$WK/m_na.out"; then ok "control: a non-atomic count loses updates"; else bad "control: a non-atomic count lost nothing"; sed -n 1,3p "$WK/m_na.out"; fi
  "$GEN" "$T/kernels/unused.rb" --out "$pl" --host metal >/dev/null 2>&1
  if ruby "$T/plant_metal.rb" bindings "$pl/unused/unused_host.rb" && mbuild "$pl" unused unused; then
    "$WK/m_unused" >"$WK/m_pb.out" 2>&1
    if grep -q '^FAIL unused' "$WK/m_pb.out"; then ok "control: without the bindings an unused buffer moves the next"; else bad "control: removing the bindings changed nothing"; sed -n 1,3p "$WK/m_pb.out"; fi
  else bad "Metal build of the binding control"; fi
  "$GEN" "$T/kernels/reduce.rb" --out "$pl" --host metal >/dev/null 2>&1
  if ruby "$T/plant_metal.rb" shared "$pl/reduce/reduce_host.rb" "$REPO/tools/shader/sp_metal_compute.m" "$WK/sp_no_shared.m" && mbuild "$pl" reduce reduce; then
    "$WK/m_reduce" >"$WK/m_ps.out" 2>&1
    if grep -q '^FAIL' "$WK/m_ps.out"; then ok "control: without a shared memory length the result is wrong"; else bad "control: removing the shared memory length changed nothing"; sed -n 1,3p "$WK/m_ps.out"; fi
  else bad "Metal build of the shared memory control"; fi
fi

echo "---- compute: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ] || exit 1
[ "$skip" -eq 0 ] || exit 2
exit 0
