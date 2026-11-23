#!/bin/sh
# E457 (P013): GPU bridge harness — macOS host only.
#
# The E456 harness proved the KERNEL (Swift runner drove the GPU); this one
# proves the BRIDGE: the spinel-compiled native binary (host_saxpy.rb) drives
# the GPU itself through the gpu_metal_shim.m FFI and verifies against its own
# in-binary Ruby oracle. Two units, AMP-style:
#
#   spinel-metal compile saxpy.rb -> build/saxpy.metal   (the kernel)
#   spinel-metal host host_saxpy.rb -> build/host_saxpy  (the host, Mach-O)
#
# Host toolchain: repos/spinel built for macOS (make deps && make; bin/spinel is
# enough — the trailing bin/spin target may fail, that is upstream's self-hosted
# tool) + the host in-process codegen at build/codegen_c/host/ (kept apart from
# the container's Linux binary at build/codegen_c/).
set -u
# An oracle (tests/ORACLES.tsv): it runs only on the owner's instruction.
"$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)/tools/oracle/gate" tools/metal/tests/run_gpu_bridge.sh whole || exit 0

[ "$(uname -s)" = "Darwin" ] || { echo "SKIP: gpu bridge harness needs macOS (Metal)"; exit 0; }

METAL=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT=$(cd "$METAL/../ebpf" && pwd)
FORK="$ROOT/repos/spinel"
[ -x "$FORK/bin/spinel" ] && file "$FORK/bin/spinel" | grep -q Mach-O || {
  echo "SKIP: no macOS spinel at repos/spinel/bin/spinel (make -C repos/spinel deps && make -C repos/spinel)"; exit 0; }

export SPINEL_DIR="$FORK"
export SPNL_INPROC_BIN="$ROOT/build/codegen_c/host/spinel-ebpf-cc"
GPU_DIR="$METAL/examples"
N=${N:-4096}

cd "$GPU_DIR" || exit 1

# 1. kernel: Ruby -> MSL (host CLI end to end, same pipeline as Linux)
sh "$METAL/spinel-metal" compile saxpy.rb -o build/ > /tmp/gpu_bridge_k.log 2>&1 \
  || { echo "FAIL: kernel emit"; tail -5 /tmp/gpu_bridge_k.log; exit 1; }
[ -f build/saxpy.metal ] || { echo "FAIL: no build/saxpy.metal"; exit 1; }
[ -f build/saxpy_host.rb ] || { echo "FAIL: no build/saxpy_host.rb (E458 host binding)"; exit 1; }

# 2. host: Ruby -> native binary (FFI + ObjC shim + frameworks via markers)
sh "$METAL/spinel-metal" host host_saxpy.rb -o build/ > /tmp/gpu_bridge_h.log 2>&1 \
  || { echo "FAIL: host build"; tail -8 /tmp/gpu_bridge_h.log; exit 1; }

# 3. run: the binary dispatches the GPU and verifies in-binary
out=$(./build/host_saxpy build "$N" 2>/tmp/gpu_bridge_run.err)
echo "$out"
printf '%s' "$out" | grep -q "^BRIDGE PASS" || { echo "FAIL: bridge run"; cat /tmp/gpu_bridge_run.err; exit 1; }

# 4. negative control: the perturbed coefficient MUST fail the in-binary check
bad=$(GPU_BRIDGE_PERTURB=1 ./build/host_saxpy build "$N" 2>/dev/null)
printf '%s' "$bad" | grep -q "^BRIDGE FAIL" \
  || { echo "FAIL: negative control PASSED -- the in-binary check is vacuous"; exit 1; }
echo "  ok: negative control (perturbed coefficient) caught"

# ---- E459: the :int leg -- int64 buffers with values above 2^53, where any
# accidental double hop corrupts the low bits. Exact equality, no tolerance. ----
sh "$METAL/spinel-metal" compile scale.rb -o build/ > /tmp/gpu_bridge_k2.log 2>&1 \
  || { echo "FAIL: scale kernel emit"; tail -5 /tmp/gpu_bridge_k2.log; exit 1; }
sh "$METAL/spinel-metal" host host_scale.rb -o build/ > /tmp/gpu_bridge_h2.log 2>&1 \
  || { echo "FAIL: host_scale build"; tail -8 /tmp/gpu_bridge_h2.log; exit 1; }
out2=$(./build/host_scale build "$N" 2>/tmp/gpu_bridge_run2.err)
echo "$out2"
printf '%s' "$out2" | grep -q "^BRIDGE PASS" || { echo "FAIL: int64 bridge run"; cat /tmp/gpu_bridge_run2.err; exit 1; }
bad2=$(GPU_BRIDGE_PERTURB=1 ./build/host_scale build "$N" 2>/dev/null)
printf '%s' "$bad2" | grep -q "^BRIDGE FAIL" \
  || { echo "FAIL: int64 negative control PASSED -- the check is vacuous"; exit 1; }
echo "  ok: int64 negative control (perturbed multiplier) caught"
# ---- E466: the loop leg -- an 8-step Horner chain, `8.times` on BOTH sides
# (MSL for-loop in the kernel, Ruby times in the in-binary double oracle). ----
sh "$METAL/spinel-metal" compile poly.rb -o build/ > /tmp/gpu_bridge_k3.log 2>&1 \
  || { echo "FAIL: poly kernel emit"; tail -5 /tmp/gpu_bridge_k3.log; exit 1; }
grep -q "for (__s64 " build/poly.metal \
  || { echo "FAIL: poly.metal has no for loop -- times did not lower to MSL"; exit 1; }
sh "$METAL/spinel-metal" host host_poly.rb -o build/ > /tmp/gpu_bridge_h3.log 2>&1 \
  || { echo "FAIL: host_poly build"; tail -8 /tmp/gpu_bridge_h3.log; exit 1; }
out3=$(./build/host_poly build "$N" 2>/tmp/gpu_bridge_run3.err)
echo "$out3"
printf '%s' "$out3" | grep -q "^BRIDGE PASS" || { echo "FAIL: loop bridge run"; cat /tmp/gpu_bridge_run3.err; exit 1; }
bad3=$(GPU_BRIDGE_PERTURB=1 ./build/host_poly build "$N" 2>/dev/null)
printf '%s' "$bad3" | grep -q "^BRIDGE FAIL" \
  || { echo "FAIL: loop negative control PASSED -- the check is vacuous"; exit 1; }
echo "  ok: loop negative control (perturbed constant term) caught"
# ---- E467: the cooperation leg -- 256-lane tree reduction: gpu_shared staging,
# gpu_barrier between halving steps, lane 0 writes partial[gpu_group_id]. ----
sh "$METAL/spinel-metal" compile reduce.rb -o build/ > /tmp/gpu_bridge_k4.log 2>&1 \
  || { echo "FAIL: reduce kernel emit"; tail -5 /tmp/gpu_bridge_k4.log; exit 1; }
grep -q "threadgroup float _sh_acc\[256\];" build/reduce.metal \
  || { echo "FAIL: reduce.metal has no threadgroup array"; exit 1; }
grep -q "threadgroup_barrier(mem_flags::mem_threadgroup);" build/reduce.metal \
  || { echo "FAIL: reduce.metal has no barrier"; exit 1; }
sh "$METAL/spinel-metal" host host_reduce.rb -o build/ > /tmp/gpu_bridge_h4.log 2>&1 \
  || { echo "FAIL: host_reduce build"; tail -8 /tmp/gpu_bridge_h4.log; exit 1; }
out4=$(./build/host_reduce build "$N" 2>/tmp/gpu_bridge_run4.err)
echo "$out4"
printf '%s' "$out4" | grep -q "^BRIDGE PASS" || { echo "FAIL: reduction bridge run"; cat /tmp/gpu_bridge_run4.err; exit 1; }
bad4=$(GPU_BRIDGE_PERTURB=1 ./build/host_reduce build "$N" 2>/dev/null)
printf '%s' "$bad4" | grep -q "^BRIDGE FAIL" \
  || { echo "FAIL: reduction negative control PASSED -- the check is vacuous"; exit 1; }
echo "  ok: reduction negative control (perturbed input formula) caught"
# ---- E469: the atomic leg -- 64-bin histogram, every thread hammering the same
# atomic_int cells; integer counts, EXACT equality (one lost update = one
# missing count). ----
sh "$METAL/spinel-metal" compile histogram.rb -o build/ > /tmp/gpu_bridge_k5.log 2>&1 \
  || { echo "FAIL: histogram kernel emit"; tail -5 /tmp/gpu_bridge_k5.log; exit 1; }
grep -q "device atomic_int \*h" build/histogram.metal \
  || { echo "FAIL: histogram.metal has no atomic_int buffer"; exit 1; }
grep -q "atomic_fetch_add_explicit" build/histogram.metal \
  || { echo "FAIL: histogram.metal has no atomic add"; exit 1; }
sh "$METAL/spinel-metal" host host_histogram.rb -o build/ > /tmp/gpu_bridge_h5.log 2>&1 \
  || { echo "FAIL: host_histogram build"; tail -8 /tmp/gpu_bridge_h5.log; exit 1; }
out5=$(./build/host_histogram build "$N" 2>/tmp/gpu_bridge_run5.err)
echo "$out5"
printf '%s' "$out5" | grep -q "^BRIDGE PASS" || { echo "FAIL: histogram bridge run"; cat /tmp/gpu_bridge_run5.err; exit 1; }
bad5=$(GPU_BRIDGE_PERTURB=1 ./build/host_histogram build "$N" 2>/dev/null)
printf '%s' "$bad5" | grep -q "^BRIDGE FAIL" \
  || { echo "FAIL: histogram negative control PASSED -- the check is vacuous"; exit 1; }
echo "  ok: histogram negative control (perturbed binning) caught"
echo "PASS: spinel native binaries drove the GPU and verified in-binary (float32 + int64>2^53 + 8-step loop + threadgroup reduction + atomic histogram, N=$N)"
