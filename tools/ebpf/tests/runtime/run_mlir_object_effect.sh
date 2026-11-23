#!/usr/bin/env bash
#
# run_mlir_object_effect.sh — E154 checkpoint 3: **実行時の map effect 差動**。
#
# 静的な object 差動 (test_mlir_object_shadow.rb) は helper 呼び出し列と map
# 参照までしか主張しない。ここでは現行 backend の .bpf.o と MLIR backend の
# .bpf.o を **kernel でそれぞれ 1 回実行**し、counter が 0 -> 1 に増えることと
# 返り値 (XDP_PASS=2) を突き合わせる。
#
# 陽性対照: body step を落とした MLIR object (verdict と宣言の外形は同じ) を
# 同じ probe にかけ、**差動が赤になる**ことを毎回確かめる。これが緑のままなら
# 比較器は何も見ていない。
#
# 前提: spbpf-compile (spinel-llvm)、libbpf-dev、clang、BPF を load できる権限
# (root か sudo -n)。**前提が無いことを成功扱いにしない** — 明示して exit 1。
#
# 使い方: sh tests/runtime/run_mlir_object_effect.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

CC="${CC:-cc}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SPBPF="${SPNL_SPBPF_COMPILE:-}"
if [ ! -x "$SPBPF" ]; then
  echo "FAIL: mlir_object_effect — spbpf-compile が無い ($SPBPF)。SPNL_SPBPF_COMPILE で指す。"
  exit 1
fi
if [ ! -x build/codegen_c/spinel_ebpf_cc ]; then
  echo "FAIL: mlir_object_effect — codegen が無い。make -C src/codegen_c で建てる。"
  exit 1
fi
# libspbpf C ABI の検証段 (compile_mlir の必須前段)。
if ! sh tools/build_spbpf_schema_check.sh >/dev/null; then
  echo "FAIL: mlir_object_effect — spnl_spbpf_schema_check を建てられない (spinel-llvm の native build が要る)。"
  exit 1
fi

AS_ROOT=""
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then
    AS_ROOT="sudo -n"
  else
    echo "FAIL: mlir_object_effect — BPF を load する権限が無い (root でも sudo -n でもない)。"
    exit 1
  fi
fi

# --- 3 つの object を作る: 現行 / MLIR / body を落とした MLIR (陽性対照) -----
SPNL_SPBPF_COMPILE="$SPBPF" ruby -Isrc -e '
  require "spinel_ebpf/mlir_backend"
  require "fileutils"
  dir = ARGV[0]
  ir, ast, base = "tests/fixtures/24_xdp_counter.ir", "tests/fixtures/24_xdp_counter.ast", "u_24_xdp_counter"
  FileUtils.cp(SpinelEbpf::MlirBackend.compile_current(ir, ast, base, dir), File.join(dir, "current.bpf.o"))
  m = SpinelEbpf::MlirBackend.manifest(ir, ast, base)
  FileUtils.cp(SpinelEbpf::MlirBackend.compile_mlir(m, base, dir), File.join(dir, "mlir.bpf.o"))
  # 陽性対照: 宣言と verdict はそのまま、body step だけを空にする。
  m["programs"][0]["body"]["steps"] = []
  FileUtils.cp(SpinelEbpf::MlirBackend.compile_mlir(m, "#{base}_dropped", dir), File.join(dir, "dropped.bpf.o"))
' "$TMP"

# --- probe を建てる -----------------------------------------------------------
"$CC" -O2 -Wall -Wextra tools/spnl_map_effect_probe.c -lbpf -lelf -lz \
  -o "$TMP/probe"

run_probe() { # $1 = object
  $AS_ROOT "$TMP/probe" "$1" xdp__main u_24_xdp_counter_top_rx_pkts
}

rc=0
echo "== current backend =="
CUR="$(run_probe "$TMP/current.bpf.o")" || rc=1
echo "$CUR"
echo "== mlir backend =="
MLIR="$(run_probe "$TMP/mlir.bpf.o")" || rc=1
echo "$MLIR"
if [ "$rc" -ne 0 ]; then echo "FAIL: mlir_object_effect — probe が測れなかった"; exit 1; fi

WANT="RETVAL=2 BEFORE=absent AFTER=1"
if [ "$CUR" != "$WANT" ]; then
  echo "FAIL: mlir_object_effect — 現行 object の実行結果が期待と違う: $CUR"
  exit 1
fi
if [ "$MLIR" != "$CUR" ]; then
  echo "FAIL: mlir_object_effect — 実行時の map effect が食い違う: current=[$CUR] mlir=[$MLIR]"
  exit 1
fi

echo "== 陽性対照 (body を落とした MLIR object) =="
DROPPED="$(run_probe "$TMP/dropped.bpf.o")" || {
  echo "FAIL: mlir_object_effect — 陽性対照の probe が測れなかった"; exit 1; }
echo "$DROPPED"
if [ "$DROPPED" = "$CUR" ]; then
  echo "FAIL: mlir_object_effect — body を落とした object が現行と同じに見える。比較器が何も見ていない。"
  exit 1
fi
case "$DROPPED" in
  *"AFTER=1"*) echo "FAIL: mlir_object_effect — body を落としたのに counter が増えた"; exit 1 ;;
esac

echo "PASS: mlir_object_effect (counter 0 -> 1、RETVAL=2、陽性対照は赤)"
