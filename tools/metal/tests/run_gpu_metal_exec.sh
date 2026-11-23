#!/bin/sh
# E456 (P013): gpu-metal EXECUTION harness — macOS host only.
#
#   Ruby (tools/metal/examples/saxpy.rb)
#     -> spinel-metal compile  (in the spnlbuild container if the
#        host has no runnable in-process codegen)  -> saxpy.metal
#     -> gpu_metal_runner.swift: runtime-compile + dispatch N threads on the GPU
#     -> gpu_oracle.rb: CRuby executes the SAME .rb per gid (double precision)
#     -> gpu_compare.rb: numeric compare, rel tol 1e-5
#     -> negative control: a 1-element perturbed oracle MUST fail the compare
#        (E415 discipline: prove the gate can fail before trusting its pass).
set -u
# An oracle (tests/ORACLES.tsv): it runs only on the owner's instruction.
"$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)/tools/oracle/gate" tools/metal/tests/run_gpu_metal_exec.sh whole || exit 0

[ "$(uname -s)" = "Darwin" ] || { echo "SKIP: gpu-metal exec harness needs macOS (Metal)"; exit 0; }
command -v swift >/dev/null 2>&1 || { echo "SKIP: swift not found"; exit 0; }

METAL=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT=$(cd "$METAL/../ebpf" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
N=${N:-4096}

# ---- 1. emit saxpy.metal (host binary if runnable, else the build container) ----
METAL="$TMP/saxpy.metal"
if [ -x "$ROOT/build/codegen_c/spinel-ebpf-cc" ] && \
   "$ROOT/build/codegen_c/spinel-ebpf-cc" --help >/dev/null 2>&1; then
  SPNL_GPU_METAL=1 "$ROOT/build/codegen_c/spinel-ebpf-cc" \
    "$METAL/examples/saxpy.rb" saxpy > "$METAL" 2>"$TMP/emit.err" \
    || { echo "FAIL: host MSL emit"; cat "$TMP/emit.err"; exit 1; }
elif command -v container >/dev/null 2>&1 && container exec spnlbuild true 2>/dev/null; then
  container exec spnlbuild sh -c \
    'cd /work && SPNL_GPU_METAL=1 build/codegen_c/spinel-ebpf-cc examples/gpu/saxpy.rb saxpy' \
    > "$METAL" 2>"$TMP/emit.err" \
    || { echo "FAIL: container MSL emit"; cat "$TMP/emit.err"; exit 1; }
else
  echo "SKIP: no runnable in-process codegen (build third_party/spinel + tools/spinel_ebpf_inproc.c, or start the spnlbuild container)"
  exit 0
fi
grep -q "kernel void saxpy" "$METAL" || { echo "FAIL: emitted file is not the saxpy kernel"; exit 1; }

# ---- 2. GPU run ----
swift "$METAL/tests/gpu_metal_runner.swift" "$METAL" saxpy "$N" > "$TMP/gpu.txt" \
  || { rc=$?; [ "$rc" = 3 ] && { echo "SKIP: no Metal device"; exit 0; }; echo "FAIL: GPU run (rc=$rc)"; exit 1; }

# ---- 3. CRuby oracle (same .rb) ----
ruby "$METAL/tests/gpu_oracle.rb" "$METAL/examples/saxpy.rb" kernel__saxpy "$N" > "$TMP/oracle.txt" \
  || { echo "FAIL: oracle run"; exit 1; }

# ---- 4. compare + negative control ----
ruby "$METAL/tests/gpu_compare.rb" "$TMP/gpu.txt" "$TMP/oracle.txt" 1e-5 \
  || { echo "FAIL: GPU output != CRuby oracle"; exit 1; }
ruby "$METAL/tests/gpu_oracle.rb" "$METAL/examples/saxpy.rb" kernel__saxpy "$N" --perturb > "$TMP/oracle_bad.txt"
if ruby "$METAL/tests/gpu_compare.rb" "$TMP/gpu.txt" "$TMP/oracle_bad.txt" 1e-5 >/dev/null 2>&1; then
  echo "FAIL: negative control PASSED the compare -- the gate is vacuous"
  exit 1
fi
echo "  ok: negative control (1 perturbed element) caught"
echo "PASS: gpu-metal saxpy == CRuby oracle (N=$N) with working negative control"
