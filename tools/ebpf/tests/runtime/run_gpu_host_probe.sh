#!/usr/bin/env bash
#
# run_gpu_host_probe.sh — E471 (P013 Phase 0): GPU ホスト API 観測の配管検証。
#
# CUDA driver API の実シンボル名 (cuLaunchKernel / cuMemcpyHtoD / cuMemcpyDtoH) を
# 持つ mock バイナリに実 uprobe を張り、keyed latency → OTLP metrics push →
# 受信側 protoc decode まで端から端まで通す。実 NVIDIA HW が来たら
# SPNL_UPROBE_BINARY を libcuda.so に差し替えるだけ、の状態を固定する。
#
# 検証は 2 方向:
#   正: mock を N 回叩き、decoded OTLP の各 API series の histogram count が
#       ちょうど N (uprobe 対の取りこぼしゼロ)
#   負: シンボルを持たないバイナリを指すと FATAL + exit 1 (E471 で fold —
#       それまでは warn + 続行で空メトリクスを exit 0 のまま出し続けていた)
#
# Spinel Extended: uprobes need BPF rights. With EBPF_CAP_DIR (a directory the
# caller owns on a filesystem without nosuid, as tests/ebpf/live.sh takes it),
# the built probe is copied there, given
# cap_bpf,cap_net_admin,cap_perfmon,cap_sys_admin with `$SUDO setcap` (SUDO
# defaults to sudo) and deleted at the end; without it the probe runs where it
# was built, as before. cap_sys_admin is there because on Debian 13 (kernel
# 7.1.8) the uprobe's perf_event_open is refused with the other three alone
# (the owner, 2026-10-24; docs/toolchains/spinel-ebpf-deps). Every privileged
# command is printed on a `priv:` line.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

CC="${CC:-cc}"
RUBY="${RUBY:-ruby}"
PROTOC="${PROTOC:-protoc}"
PORT="${GPU_HOST_PROBE_PORT:-18497}"
N=50
TMP="$(mktemp -d)"
SRV=""
CAP_PROBE=""
cleanup() { [ -n "$SRV" ] && kill -- "-$SRV" 2>/dev/null || true; [ -n "$CAP_PROBE" ] && rm -f "$CAP_PROBE"; rm -rf "$TMP"; }
trap cleanup EXIT

echo "[gpu-host] building mock CUDA target + probe"
"$CC" -O2 -o "$TMP/mock_cuda" tests/runtime/mock_cuda.c
ruby bin/spinel-ebpf compile examples/observability/otlp/gpu_host_probe.rb \
  --build -o build/gpu_host_probe > "$TMP/build.log" 2>&1 \
  || { echo "FAIL: probe build"; tail -5 "$TMP/build.log"; exit 1; }
PROBE_BIN=./build/gpu_host_probe/gpu_host_probe
if [ -n "${EBPF_CAP_DIR:-}" ]; then
  case "$(findmnt -n -o OPTIONS -T "$EBPF_CAP_DIR" 2>/dev/null)" in
    *nosuid*) echo "FAIL: EBPF_CAP_DIR ($EBPF_CAP_DIR) is on a nosuid mount; file capabilities would be ignored"; exit 1 ;;
  esac
  mkdir -p "$EBPF_CAP_DIR"
  CAP_PROBE="$EBPF_CAP_DIR/gpu_host_probe.$$"
  cp "$PROBE_BIN" "$CAP_PROBE"
  echo "priv: ${SUDO:-sudo} setcap cap_bpf,cap_net_admin,cap_perfmon,cap_sys_admin+ep $CAP_PROBE"
  ${SUDO:-sudo} setcap cap_bpf,cap_net_admin,cap_perfmon,cap_sys_admin+ep "$CAP_PROBE"
  PROBE_BIN=$CAP_PROBE
fi

echo "[gpu-host] receiver + probe + $N mock rounds"
setsid "$RUBY" tests/runtime/mock_otlp_receiver.rb --port "$PORT" --out "$TMP/pb.txt" \
  --protoc "$PROTOC" --repo-root "$REPO_ROOT" > "$TMP/recv.log" 2>&1 & SRV=$!
sleep 1
SPNL_UPROBE_BINARY="$TMP/mock_cuda" OTLP_ENDPOINT="http://127.0.0.1:$PORT" \
  PROBE_SECONDS=1 PROBE_ROUNDS=5 "$PROBE_BIN" > "$TMP/probe.log" 2>&1 &
PROBE=$!
sleep 2
"$TMP/mock_cuda" "$N" > /dev/null
wait "$PROBE" || { echo "FAIL: probe run"; tail -5 "$TMP/probe.log"; exit 1; }
kill -- "-$SRV" 2>/dev/null || true; SRV=""

fail=0
for api in cuLaunchKernel cuMemcpyHtoD cuMemcpyDtoH; do
  grep -q "string_value: \"$api\"" "$TMP/pb.txt" \
    || { echo "FAIL: decoded OTLP has no series for $api"; fail=1; }
done
grep -q 'name: "gpu_host_calls_latency_ns"' "$TMP/pb.txt" \
  || { echo "FAIL: latency histogram metric missing"; fail=1; }
# 取りこぼしゼロ: 3 series 全部が count == N ちょうど (1 fire でも欠けたら別の数)。
hits=$(grep -c "count: $N\$" "$TMP/pb.txt" || true)
[ "$hits" -ge 3 ] || { echo "FAIL: expected 3 series with count: $N, got $hits"; fail=1; }
[ "$fail" -eq 0 ] && echo "  ok: 3 API series decoded, histogram count == $N each (no lost fires)"

echo "[gpu-host] negative control: a symbol-less target must refuse loudly"
if SPNL_UPROBE_BINARY=/bin/true OTLP_ENDPOINT="http://127.0.0.1:$PORT" \
   timeout 10 "$PROBE_BIN" > "$TMP/neg.log" 2>&1; then
  echo "FAIL: probe exited 0 with nothing attached -- the declared handlers never fire"; fail=1
else
  grep -q "FATAL" "$TMP/neg.log" || { echo "FAIL: refusal is not loud (no FATAL line)"; fail=1; }
  grep -q "pushed" "$TMP/neg.log" && { echo "FAIL: metrics were pushed with nothing attached"; fail=1; }
  echo "  ok: symbol-less target -> FATAL, no metrics pushed"
fi

[ "$fail" -eq 0 ] && echo "PASS: gpu host-API probe plumbing (uprobe fire -> keyed latency -> OTLP -> decode)" \
                  || { echo "FAIL: gpu host-API probe gate"; exit 1; }
