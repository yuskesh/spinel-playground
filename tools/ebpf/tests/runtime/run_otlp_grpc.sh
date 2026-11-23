#!/usr/bin/env bash
#
# run_otlp_grpc.sh — ADR-012 / P003 S5: OTLP/gRPC transport の検証
#
# 自前 HTTP/2 gRPC クライアントで sample metrics を送り、mock が request を decode
# できることを assert する (decode できた = HTTP/2 + HPACK + gRPC framing が正しい)。
# Spinel Extended: the mock is tests/runtime/mock_otlp_grpc.rb (CRuby), written here in
# place of spinel-ebpf's grpcio mock; its own HTTP/2 is checked against curl (nghttp2).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

CC="${CC:-clang}"
PROTOC="${PROTOC:-protoc}"
RUBY="${RUBY:-ruby}"
NANOPB="${NANOPB_DIR:-$REPO_ROOT/third_party/nanopb}"   # Spinel Extended: NANOPB_DIR names the user-local pin
PB="$REPO_ROOT/src/runtime/otlp/pb"
OTLP="$REPO_ROOT/src/runtime/otlp"
PORT="${OTLP_GRPC_PORT:-14317}"
TMP="$(mktemp -d)"
RECV_PID=""
cleanup() { [ -n "$RECV_PID" ] && kill -- "-$RECV_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

PB_C=$(find "$PB/opentelemetry" -name '*.pb.c' | sort)

echo "[s5] compiling gRPC client test"
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -Werror \
  -I "$NANOPB" -I "$PB" -I "$OTLP" \
  tests/runtime/otlp_grpc_test.c \
  "$OTLP/otlp_grpc.c" "$OTLP/otlp_http.c" \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" \
  $PB_C \
  -lz \
  -o "$TMP/otlp_grpc"

echo "[s5] starting the gRPC mock on 127.0.0.1:$PORT"
setsid "$RUBY" tests/runtime/mock_otlp_grpc.rb \
  --port "$PORT" --out "$TMP/decoded.txt" --protoc "$PROTOC" --repo-root "$REPO_ROOT" &
RECV_PID=$!

echo "[s5] sending (connect retries cover mock startup)"
"$TMP/otlp_grpc" 127.0.0.1 "$PORT"
echo "[s5] gRPC stream completed ok"

# the mock writes decoded.txt before it replies, so it is there once the stream has ended
if [ ! -s "$TMP/decoded.txt" ]; then echo "[s5] FAIL: mock produced no decode output"; exit 1; fi

echo "----- mock decoded -----"; cat "$TMP/decoded.txt"; echo "------------------------"
. "$REPO_ROOT/tests/runtime/otlp_common.sh"
assert() { otlp_assert "$TMP/decoded.txt" "$1"; }
assert 'name: "spnl_method_calls_total"'
assert 'as_int: 500'
assert 'string_value: "spinel-app"'
assert 'aggregation_temporality: AGGREGATION_TEMPORALITY_CUMULATIVE'
otlp_done "OTLP/gRPC (hand-rolled HTTP/2) delivered & decoded by the gRPC mock"
