#!/usr/bin/env bash
#
# run_otlp_send.sh — ADR-012 / P003 S1 の転送検証
#
# nanopb encode した OTLP を otlp_http_post で実 TCP 送信し、受信側が 200 を返し
# body が正しく decode されることを assert する。
#
# 既定はローカル mock receiver (実 Collector 不要)。実 Collector を使う場合:
#   OTLP_HOST=127.0.0.1 OTLP_PORT=4318 OTLP_NO_MOCK=1 sh tests/runtime/run_otlp_send.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

CC="${CC:-clang}"
PROTOC="${PROTOC:-protoc}"
RUBY="${RUBY:-ruby}"
NANOPB="${NANOPB_DIR:-$REPO_ROOT/third_party/nanopb}"   # Spinel Extended: NANOPB_DIR names the user-local pin
PB="$REPO_ROOT/src/runtime/otlp/pb"
OTLP="$REPO_ROOT/src/runtime/otlp"
HOST="${OTLP_HOST:-127.0.0.1}"
PORT="${OTLP_PORT:-14318}"        # mock の既定。実 Collector は 4318 を渡す
TMP="$(mktemp -d)"
RECV_PID=""
cleanup() { [ -n "$RECV_PID" ] && kill -- "-$RECV_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

PB_C=$(find "$PB/opentelemetry" -name '*.pb.c' | sort)

echo "[s1] compiling send test"
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -Werror \
  -I "$NANOPB" -I "$PB" -I "$OTLP" \
  tests/runtime/otlp_send_test.c \
  "$OTLP/otlp_http.c" \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" \
  $PB_C \
  -lz \
  -o "$TMP/otlp_send"

if [ "${OTLP_NO_MOCK:-0}" != "1" ]; then
  echo "[s1] starting mock OTLP receiver on $HOST:$PORT"
  setsid "$RUBY" tests/runtime/mock_otlp_receiver.rb \
    --port "$PORT" --out "$TMP/decoded.txt" \
    --protoc "$PROTOC" --repo-root "$REPO_ROOT" &
  RECV_PID=$!
fi

echo "[s1] sending (connect は最大5回リトライ/バックオフで receiver 起動を待つ)"
"$TMP/otlp_send" "$HOST" "$PORT"
echo "[s1] HTTP 200 received"

if [ "${OTLP_NO_MOCK:-0}" != "1" ]; then
  # receiver は POST 処理時に decoded.txt を書く (200 応答の前)
  if [ ! -s "$TMP/decoded.txt" ]; then
    echo "[s1] FAIL: receiver produced no decode output"; exit 1
  fi
  echo "[s1] asserting receiver decoded the body"
  . "$REPO_ROOT/tests/runtime/otlp_common.sh"
  assert() { otlp_assert "$TMP/decoded.txt" "$1"; }
  assert 'name: "spnl_method_calls_total"'
  assert 'as_int: 500'
  assert 'string_value: "spinel-app"'
  assert 'key: "code.function"'
  assert 'aggregation_temporality: AGGREGATION_TEMPORALITY_CUMULATIVE'
  if [ "$OTLP_FAIL" -ne 0 ]; then echo "[s1] FAIL: decode mismatch"; exit 1; fi
fi

echo "[s1] PASS: OTLP/HTTP+protobuf transport delivered & decoded"
