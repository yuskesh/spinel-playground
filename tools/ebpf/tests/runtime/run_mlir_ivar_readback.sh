#!/usr/bin/env bash
#
# run_mlir_ivar_readback.sh — E155: **map 値を Ruby へ読み返す** (checkbox 3) を
# 現行 / MLIR の両埋め込みで通す。
#
# E022 の top-level ivar map (@rx_pkts) は、これまで bpftool で外から覗くしか
# なかった。E155 で glue に spnl_top_ivar_i64 (key=0 __s64 singleton の読み出し)
# を足し、Spinel-emitted main が ffi_func で宣言して呼べるようにした。ここでは:
#
#   1. XDP counter unit (heredoc — golden セットには足さない) を現行 /
#      SPNL_BPF_BACKEND=mlir の両方で --build
#   2. それぞれの単一バイナリを lo へ attach して走らせ、ping で packet を流す
#   3. Ruby (FFI) から読めた counter が両方とも増えていること、
#      無い ivar は -1 で loud に返ることを確かめる
#
# ping の到着数は走行ごとに揺れるので、値の同一性はここでは主張しない —
# 決定的な同一 workload 差動は run_mlir_embedded_object.sh (BPF_PROG_TEST_RUN
# で N 回) が持つ。ここが確かめるのは **Ruby の面から見えること** と、
# 両 backend で同じ面が動くこと。
#
# 前提: E154/E155 の道具一式 + BPF/attach 権限 (root か sudo -n)。
# **前提が無いことを成功扱いにしない** — 明示して exit 1。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SPBPF="${SPNL_SPBPF_COMPILE:-}"
if [ ! -x "$SPBPF" ]; then
  echo "FAIL: mlir_ivar_readback — spbpf-compile が無い ($SPBPF)。"
  exit 1
fi
if ! sh tools/build_spbpf_schema_check.sh >/dev/null; then
  echo "FAIL: mlir_ivar_readback — spnl_spbpf_schema_check を建てられない。"
  exit 1
fi

AS_ROOT=""
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then
    AS_ROOT="sudo -n"
  else
    echo "FAIL: mlir_ivar_readback — XDP を attach する権限が無い (root でも sudo -n でもない)。"
    exit 1
  fi
fi

# --- unit (E022 counter + E155 readback)。golden セットに足さず、ここで完結 ---
cat > "$TMP/e155_readback.rb" <<'RUBY'
# E155: top-level ivar map を Ruby へ読み返す最小 unit。
XDP_ABORTED  = 0
XDP_DROP     = 1
XDP_PASS     = 2
XDP_TX       = 3
XDP_REDIRECT = 4

@rx_pkts = 0

def xdp__main
  @rx_pkts = @rx_pkts + 1
  XDP_PASS
end

module IvarFFI
  ffi_func :spnl_top_ivar_i64, [:str], :long
  ffi_func :spnl_top_ivar_set_i64, [:str, :long], :int
end

sleep 2
puts IvarFFI.spnl_top_ivar_i64("rx_pkts")
puts IvarFFI.spnl_top_ivar_i64("no_such_ivar")
# 書き込み面 (E155): set -> read の往復。docs/reference/map_io_ruby_contract.md。
puts IvarFFI.spnl_top_ivar_set_i64("rx_pkts", 1000000)
puts IvarFFI.spnl_top_ivar_i64("rx_pkts")
puts IvarFFI.spnl_top_ivar_set_i64("no_such_ivar", 1)
RUBY

build_one() { # $1 = out dir, 残り = 追加 env
  local dir="$1"; shift
  mkdir -p "$dir"
  if ! env "$@" SPNL_SPBPF_COMPILE="$SPBPF" \
       bin/spinel-ebpf compile "$TMP/e155_readback.rb" -o "$dir" --build >"$dir/build.log" 2>&1; then
    echo "FAIL: mlir_ivar_readback — --build が失敗した ($dir):"
    tail -5 "$dir/build.log"
    exit 1
  fi
}
build_one "$TMP/current" SPNL_UNUSED=1
build_one "$TMP/mlir"    SPNL_BPF_BACKEND=mlir

if ! readelf -sW "$TMP/mlir/e155_readback.bpf.o" 2>/dev/null | grep -q spbpf; then
  echo "FAIL: mlir_ivar_readback — 採用側の object が spbpf 由来でない。"
  exit 1
fi

run_one() { # $1 = dir -> stdout 2 行 (counter, missing)
  local dir="$1"
  ( $AS_ROOT env SPNL_XDP_IFACE=lo "$dir/e155_readback" >"$dir/run.log" 2>"$dir/run.err" ) &
  local pid=$!
  sleep 0.5
  ping -c 3 -i 0.2 -q 127.0.0.1 >/dev/null 2>&1 || true
  wait "$pid" || {
    echo "FAIL: mlir_ivar_readback — バイナリの実行が失敗した ($dir):"
    tail -5 "$dir/run.err"
    exit 1
  }
  cat "$dir/run.log"
}

check_one() { # $1 = 名前, $2 = dir
  local out; out="$(run_one "$2")"
  local rx missing setrc after setmiss
  rx="$(echo "$out" | sed -n 1p)"
  missing="$(echo "$out" | sed -n 2p)"
  setrc="$(echo "$out" | sed -n 3p)"
  after="$(echo "$out" | sed -n 4p)"
  setmiss="$(echo "$out" | sed -n 5p)"
  echo "$1: rx=$rx missing=$missing set=$setrc after=$after set_missing=$setmiss"
  if ! [ "$rx" -gt 0 ] 2>/dev/null; then
    echo "FAIL: mlir_ivar_readback — $1: counter が Ruby から読めていない (rx=$rx)"
    exit 1
  fi
  if [ "$missing" != "-1" ]; then
    echo "FAIL: mlir_ivar_readback — $1: 無い ivar が -1 にならない (missing=$missing)。読めなかったを黙って 0 にしない。"
    exit 1
  fi
  if [ "$setrc" != "0" ]; then
    echo "FAIL: mlir_ivar_readback — $1: 書き込みが失敗した (set=$setrc)"
    exit 1
  fi
  if ! [ "$after" -ge 1000000 ] 2>/dev/null; then
    echo "FAIL: mlir_ivar_readback — $1: set -> read が往復しない (after=$after)"
    exit 1
  fi
  if [ "$setmiss" != "-1" ]; then
    echo "FAIL: mlir_ivar_readback — $1: 無い ivar への書き込みが -1 にならない (set_missing=$setmiss)"
    exit 1
  fi
}

check_one current "$TMP/current"
check_one mlir    "$TMP/mlir"

echo "PASS: mlir_ivar_readback (両 backend で Ruby から counter が読め、無い ivar は -1)"
