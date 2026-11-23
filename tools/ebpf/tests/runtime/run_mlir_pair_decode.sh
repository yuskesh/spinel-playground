#!/usr/bin/env bash
#
# run_mlir_pair_decode.sh — E155: **MLIR object の record を Ruby 値へ decode する**。
#
# 187_xdp_emit_pair の単一バイナリを現行 / SPNL_BPF_BACKEND=mlir (採用) の両方で
# --build し、lo へ XDP attach して ping を流す。Ruby 側は on_emit_pair
# (E242 の schema/consumer 面 — glue の drain が hdr を検査し、accessor が
# Ruby 値へ渡す) で record を受けて
#   件数 / 最後の a / 最後の b
# を印字する。**採用側では ring buffer に入るのは MLIR object が作った record**
# であり、それが既存の Ruby 面でそのまま decode できることを確かめる。
#
# 前提: E154/E155 の道具一式 + attach 権限。前提不足は loud に exit 1。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SPBPF="${SPNL_SPBPF_COMPILE:-}"
[ -x "$SPBPF" ] || { echo "FAIL: mlir_pair_decode — spbpf-compile が無い ($SPBPF)"; exit 1; }
sh tools/build_spbpf_schema_check.sh >/dev/null || {
  echo "FAIL: mlir_pair_decode — spnl_spbpf_schema_check を建てられない"; exit 1; }

AS_ROOT=""
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then AS_ROOT="sudo -n"; else
    echo "FAIL: mlir_pair_decode — XDP を attach する権限が無い"; exit 1; fi
fi

build_one() { # $1 = dir, 残り = env
  local dir="$1"; shift
  mkdir -p "$dir"
  if ! env "$@" SPNL_SPBPF_COMPILE="$SPBPF" \
       bin/spinel-ebpf compile tests/fixtures/187_xdp_emit_pair.rb -o "$dir" --build >"$dir/build.log" 2>&1; then
    echo "FAIL: mlir_pair_decode — --build が失敗した ($dir):"; tail -5 "$dir/build.log"; exit 1
  fi
}
build_one "$TMP/current" SPNL_UNUSED=1
build_one "$TMP/mlir"    SPNL_BPF_BACKEND=mlir

readelf -sW "$TMP/mlir/187_xdp_emit_pair.bpf.o" 2>/dev/null | grep -q spbpf || {
  echo "FAIL: mlir_pair_decode — 採用側の object が spbpf 由来でない"; exit 1; }

run_one() { # $1 = dir -> stdout 3 行 (pairs, last_a, last_b)
  local dir="$1"
  ( $AS_ROOT env SPNL_XDP_IFACE=lo "$dir/187_xdp_emit_pair" >"$dir/run.log" 2>"$dir/run.err" ) &
  local pid=$!
  sleep 0.5
  ping -c 3 -i 0.2 -q 127.0.0.1 >/dev/null 2>&1 || true
  wait "$pid" || {
    echo "FAIL: mlir_pair_decode — バイナリの実行が失敗した ($dir):"; tail -5 "$dir/run.err"; exit 1; }
  cat "$dir/run.log"
}

check_one() { # $1 = 名前, $2 = dir
  local out; out="$(run_one "$2")"
  local pairs a b
  pairs="$(echo "$out" | sed -n 1p)"; a="$(echo "$out" | sed -n 2p)"; b="$(echo "$out" | sed -n 3p)"
  echo "$1: pairs=$pairs a=$a b=$b"
  if ! [ "$pairs" -gt 0 ] 2>/dev/null; then
    echo "FAIL: mlir_pair_decode — $1: record が Ruby へ届いていない (pairs=$pairs)"; exit 1
  fi
  if [ "$a" != "7" ] || [ "$b" != "9" ]; then
    echo "FAIL: mlir_pair_decode — $1: decode された値が違う (a=${a} b=${b}、期待 7/9)"; exit 1
  fi
}

check_one current "$TMP/current"
check_one mlir    "$TMP/mlir"

echo "PASS: mlir_pair_decode (両 backend で record が Ruby 値 (7, 9) へ decode された)"
