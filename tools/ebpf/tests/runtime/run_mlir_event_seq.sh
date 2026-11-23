#!/usr/bin/env bash
#
# run_mlir_event_seq.sh — E155: **イベント列の現行/MLIR 差動**。
#
# 187_xdp_emit_pair (xdp で packet ごとに pair record を emit) を両 backend で
# object にし、kernel で N 回ずつ実行して ring buffer から出た列
# (type / version / a / b、timestamp は除く) を文字列比較する。
#
# 陽性対照 (manifest を書き換えてから spbpf-compile を通す = 本物の別 object):
#   1. body step の a を 7 -> 8   — イベントの値が変わり赤になる
#      (静的な map effect 差動は値を見ないので、ここが実行時差動の持ち分)
#   2. record の evt_tag を別 channel へ — hdr.type が変わり赤になる
#      (consumer 側の未知 ID 拒否が落とすのと同じ record が本当に作れることの証明)
#
# 前提: E154/E155 の道具一式 + BPF load 権限。前提不足は loud に exit 1。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

CC="${CC:-cc}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SPBPF="${SPNL_SPBPF_COMPILE:-}"
[ -x "$SPBPF" ] || { echo "FAIL: mlir_event_seq — spbpf-compile が無い ($SPBPF)"; exit 1; }
sh tools/build_spbpf_schema_check.sh >/dev/null || {
  echo "FAIL: mlir_event_seq — spnl_spbpf_schema_check を建てられない"; exit 1; }
[ -x build/codegen_c/spinel_ebpf_cc ] || {
  echo "FAIL: mlir_event_seq — codegen が無い (make -C src/codegen_c)"; exit 1; }

AS_ROOT=""
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then AS_ROOT="sudo -n"; else
    echo "FAIL: mlir_event_seq — BPF を load する権限が無い"; exit 1; fi
fi

# --- 4 つの object: 現行 / MLIR / a 変異 / evt_tag 変異 ----------------------
SPNL_SPBPF_COMPILE="$SPBPF" ruby -Isrc -e '
  require "spinel_ebpf/mlir_backend"
  require "fileutils"
  dir = ARGV[0]
  ir, ast, base = "tests/fixtures/187_xdp_emit_pair.ir", "tests/fixtures/187_xdp_emit_pair.ast", "u_187_xdp_emit_pair"
  FileUtils.cp(SpinelEbpf::MlirBackend.compile_current(ir, ast, base, dir), File.join(dir, "current.bpf.o"))
  m = SpinelEbpf::MlirBackend.manifest(ir, ast, base)
  FileUtils.cp(SpinelEbpf::MlirBackend.compile_mlir(m, base, dir), File.join(dir, "mlir.bpf.o"))
  m2 = SpinelEbpf::MlirBackend.manifest(ir, ast, base)
  m2["programs"][0]["body"]["steps"][0]["a"] = 8
  FileUtils.cp(SpinelEbpf::MlirBackend.compile_mlir(m2, "#{base}_a8", dir), File.join(dir, "mut_a.bpf.o"))
  m3 = SpinelEbpf::MlirBackend.manifest(ir, ast, base)
  m3["records"][0]["evt_tag"] = "SPNL_EVT_EMIT3"
  FileUtils.cp(SpinelEbpf::MlirBackend.compile_mlir(m3, "#{base}_tag", dir), File.join(dir, "mut_tag.bpf.o"))
' "$TMP"

"$CC" -O2 -Wall -Wextra tools/spnl_event_seq_probe.c -lbpf -lelf -lz -o "$TMP/probe"

run_probe() { $AS_ROOT "$TMP/probe" "$1" xdp__main u_187_xdp_emit_pair_pair_events 3; }

CUR="$(run_probe "$TMP/current.bpf.o")" || { echo "FAIL: mlir_event_seq — 現行の実行が失敗"; exit 1; }
MLIR="$(run_probe "$TMP/mlir.bpf.o")"   || { echo "FAIL: mlir_event_seq — MLIR の実行が失敗"; exit 1; }
echo "current: "; echo "$CUR"
echo "mlir:    "; echo "$MLIR"

WANT="RETVALS=2,2,2
EVT type=0x0102 version=1 a=7 b=9
EVT type=0x0102 version=1 a=7 b=9
EVT type=0x0102 version=1 a=7 b=9
COUNT=3"
if [ "$CUR" != "$WANT" ]; then
  echo "FAIL: mlir_event_seq — 現行のイベント列が期待と違う"; exit 1
fi
if [ "$MLIR" != "$CUR" ]; then
  echo "FAIL: mlir_event_seq — イベント列が食い違う"; exit 1
fi

MUT_A="$(run_probe "$TMP/mut_a.bpf.o")" || { echo "FAIL: mlir_event_seq — a 変異の実行が失敗"; exit 1; }
if [ "$MUT_A" = "$CUR" ]; then
  echo "FAIL: mlir_event_seq — a の変異 (7->8) が緑のまま。イベント列の値を見ていない。"; exit 1
fi
echo "$MUT_A" | grep -q "a=8 b=9" || {
  echo "FAIL: mlir_event_seq — a 変異が object に届いていない: $MUT_A"; exit 1; }

MUT_TAG="$(run_probe "$TMP/mut_tag.bpf.o")" || { echo "FAIL: mlir_event_seq — tag 変異の実行が失敗"; exit 1; }
if [ "$MUT_TAG" = "$CUR" ]; then
  echo "FAIL: mlir_event_seq — evt_tag の変異が緑のまま。hdr.type を見ていない。"; exit 1
fi
echo "$MUT_TAG" | grep -q "type=0x0103" || {
  echo "FAIL: mlir_event_seq — tag 変異が object に届いていない: $MUT_TAG"; exit 1; }

echo "PASS: mlir_event_seq (イベント列一致、a 変異と evt_tag 変異は赤)"
