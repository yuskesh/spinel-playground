#!/usr/bin/env bash
#
# run_mlir_embedded_object.sh — E155: **単一バイナリへ埋め込まれた object** の差動。
#
# E154 の run_mlir_object_effect.sh は .bpf.o ファイルを直接 load した。ここは
# 製品の埋め込み経路そのもの — `bin/spinel-ebpf compile --build` が bpftool gen
# skeleton で .bpf.o を C 配列にしてバイナリへ埋め込む — を通す:
#
#   1. 現行 backend と SPNL_BPF_BACKEND=mlir (採用) で同じ fixture を --build
#   2. 生成された skel.h だけを残して **.bpf.o を全部消す** (隣接 ELF 不要の証明)
#   3. 両方の skel.h を同じ検査 TU (test_mlir_embedded_object.c) に埋めて
#      kernel で実行し、retval 列と counter を文字列比較する
#
# 陽性対照: 採用側の .bpf.o (削除前) に spbpf の FILE symbol が居ること、かつ
# 2 つの skel.h が byte 単位で異なること — 「同じ object を 2 回測って一致」を
# 差動と呼ばないため。
#
# 前提: spinel の native build (CLI --build)、spbpf-compile、
# spnl_spbpf_schema_check、bpftool、libbpf-dev、BPF load 権限 (root か sudo -n)。
# **前提が無いことを成功扱いにしない** — 明示して exit 1。
#
# 使い方: sh tests/runtime/run_mlir_embedded_object.sh [--static-only]
#
# --static-only (E157 product gate 用): --build と静的 assertion (spbpf FILE
# symbol / skel.h 差 / ELF magic in C 配列) までを非 root で実行し、kernel load
# へは進まない。BPF 権限の検査は既定 (引数なし) の kernel 側が持ち分のまま。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

STATIC_ONLY=0
if [ "${1:-}" = "--static-only" ]; then
  STATIC_ONLY=1
elif [ $# -gt 0 ]; then
  echo "usage: $0 [--static-only]" >&2
  exit 2
fi

CC="${CC:-cc}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SPBPF="${SPNL_SPBPF_COMPILE:-}"
if [ ! -x "$SPBPF" ]; then
  echo "FAIL: mlir_embedded_object — spbpf-compile が無い ($SPBPF)。SPNL_SPBPF_COMPILE で指す。"
  exit 1
fi
if ! sh tools/build_spbpf_schema_check.sh >/dev/null; then
  echo "FAIL: mlir_embedded_object — spnl_spbpf_schema_check を建てられない。"
  exit 1
fi
if ! command -v bpftool >/dev/null 2>&1; then
  echo "FAIL: mlir_embedded_object — bpftool が無い (skeleton 生成に要る)。"
  exit 1
fi

AS_ROOT=""
if [ "$STATIC_ONLY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then
    AS_ROOT="sudo -n"
  else
    echo "FAIL: mlir_embedded_object — BPF を load する権限が無い (root でも sudo -n でもない)。"
    exit 1
  fi
fi

# --- 1. 両 backend で --build ------------------------------------------------
FIXTURE=tests/fixtures/24_xdp_counter.rb
build_one() { # $1 = out dir, 残り = 追加 env
  local dir="$1"; shift
  mkdir -p "$dir"
  if ! env "$@" SPNL_SPBPF_COMPILE="$SPBPF" \
       bin/spinel-ebpf compile "$FIXTURE" -o "$dir" --build >"$dir/build.log" 2>&1; then
    echo "FAIL: mlir_embedded_object — --build が失敗した ($dir):"
    tail -5 "$dir/build.log"
    exit 1
  fi
}
build_one "$TMP/current" SPNL_UNUSED=1
build_one "$TMP/mlir"    SPNL_BPF_BACKEND=mlir

# --- 陽性対照: 2 つの埋め込みが本当に別物 ------------------------------------
if ! readelf -sW "$TMP/mlir/24_xdp_counter.bpf.o" 2>/dev/null | grep -q spbpf; then
  echo "FAIL: mlir_embedded_object — 採用側の object が spbpf 由来でない (採用が効いていない)。"
  exit 1
fi
if cmp -s "$TMP/current/24_xdp_counter.skel.h" "$TMP/mlir/24_xdp_counter.skel.h"; then
  echo "FAIL: mlir_embedded_object — 両者の skel.h が同一。別 object を埋め込めていない。"
  exit 1
fi
# 埋め込みは ELF magic ごと C 配列に入る (E153 の Go 側と同じ確認点)。
# bpftool gen skeleton は hex escape で埋める: \x7f\x45\x4c\x46 = \177ELF。
for d in current mlir; do
  if ! grep -qF '\x7f\x45\x4c\x46' "$TMP/$d/24_xdp_counter.skel.h"; then
    echo "FAIL: mlir_embedded_object — $d の skel.h に ELF が埋まっていない。"
    exit 1
  fi
done

if [ "$STATIC_ONLY" -eq 1 ]; then
  echo "PASS: mlir_embedded_object (static-only: spbpf symbol / skel.h 差 / ELF magic。kernel load は --kernel 側の持ち分)"
  exit 0
fi

# --- 2. 隣接 .bpf.o を消す (埋め込みだけで load できることの証明) ------------
rm -f "$TMP"/current/*.bpf.o "$TMP"/mlir/*.bpf.o

# --- 3. 同じ検査 TU を両方の skel.h で建てて実行 ------------------------------
for d in current mlir; do
  "$CC" -O2 -Wall -Wextra -I "$TMP/$d" \
    tests/runtime/test_mlir_embedded_object.c -lbpf -lelf -lz \
    -o "$TMP/$d/probe"
done

CUR="$($AS_ROOT "$TMP/current/probe")" || {
  echo "FAIL: mlir_embedded_object — 現行埋め込みの実行が失敗した"; exit 1; }
echo "current: $CUR"
MLIR="$($AS_ROOT "$TMP/mlir/probe")" || {
  echo "FAIL: mlir_embedded_object — MLIR 埋め込みの実行が失敗した"; exit 1; }
echo "mlir:    $MLIR"

WANT="EMBED_LOAD=ok RETVALS=2,2,2 COUNT=3"
if [ "$CUR" != "$WANT" ]; then
  echo "FAIL: mlir_embedded_object — 現行埋め込みの実行結果が期待と違う: $CUR"
  exit 1
fi
if [ "$MLIR" != "$CUR" ]; then
  echo "FAIL: mlir_embedded_object — 埋め込み object の実行が食い違う: current=[$CUR] mlir=[$MLIR]"
  exit 1
fi

echo "PASS: mlir_embedded_object (隣接 ELF なしで load、retval/counter 一致、埋め込みは別 object)"
