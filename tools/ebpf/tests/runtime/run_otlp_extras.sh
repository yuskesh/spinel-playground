#!/usr/bin/env bash
#
# run_otlp_extras.sh — E264: 直送イネーブラの検証。
#   OTEL_EXPORTER_OTLP_HEADERS  (auth ヘッダ、例 Splunk X-SF-Token)
#   OTEL_EXPORTER_OTLP_COMPRESSION=gzip
# が HTTP / gRPC 両経路で効く (受信側が header を受け取り、gzip body を解凍できる) ことを確認。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
. "$REPO_ROOT/tests/runtime/otlp_common.sh"

CC="${CC:-clang}"
PROTOC="${PROTOC:-protoc}"
RUBY="${RUBY:-ruby}"
NANOPB="${NANOPB_DIR:-$REPO_ROOT/third_party/nanopb}"   # Spinel Extended: NANOPB_DIR names the user-local pin
PB="$REPO_ROOT/src/runtime/otlp/pb"
OTLP="$REPO_ROOT/src/runtime/otlp"
PROTO_ROOT="${OTEL_PROTO_DIR:-$REPO_ROOT/third_party/opentelemetry-proto}"   # Spinel Extended: OTEL_PROTO_DIR names the user-local pin
TMP="$(mktemp -d)"
RECV=""
cleanup() { [ -n "$RECV" ] && kill -- "-$RECV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

PB_C=$(find "$PB/opentelemetry" -name '*.pb.c' | sort)

export OTEL_EXPORTER_OTLP_HEADERS="x-test-token=tok-abcdef0123456789, x-extra=hello"
export OTEL_EXPORTER_OTLP_COMPRESSION="gzip"

echo "[extras] compiling HTTP + gRPC send tests (-lz)"
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -Werror -I "$NANOPB" -I "$PB" -I "$OTLP" \
  tests/runtime/otlp_send_test.c "$OTLP/otlp_http.c" "$OTLP/otlp_grpc.c" \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" $PB_C -lz -o "$TMP/send"
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -Werror -I "$NANOPB" -I "$PB" -I "$OTLP" \
  tests/runtime/otlp_grpc_test.c "$OTLP/otlp_grpc.c" "$OTLP/otlp_http.c" \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" $PB_C -lz -o "$TMP/grpc"

echo "[extras] HTTP: gzip body + auth header -> mock_otlp_receiver"
setsid "$RUBY" tests/runtime/mock_otlp_receiver.rb --port 14500 --out "$TMP/http.txt" \
  --protoc "$PROTOC" --repo-root "$REPO_ROOT" >"$TMP/http_recv.log" 2>&1 &
RECV=$!
"$TMP/send" 127.0.0.1 14500
kill -- "-$RECV" 2>/dev/null || true; RECV=""
otlp_assert "$TMP/http.txt" 'name: "spnl_method_calls_total"'   # gzip body が decode できた
if grep -qi "gunzip ->" "$TMP/http_recv.log"; then echo "  ok: HTTP gzip decompressed"; else echo "  MISSING: gunzip"; OTLP_FAIL=1; fi
if grep -qi "header x-test-token: tok-abcdef" "$TMP/http_recv.log"; then echo "  ok: HTTP auth header received"; else echo "  MISSING: auth header"; OTLP_FAIL=1; fi

echo "[extras] gRPC: gzip body + auth metadata -> mock_otlp_grpc"
setsid "$RUBY" tests/runtime/mock_otlp_grpc.rb --port 14501 --out "$TMP/grpc.txt" \
  --protoc "$PROTOC" --repo-root "$REPO_ROOT" >"$TMP/grpc_recv.log" 2>&1 &
RECV=$!
"$TMP/grpc" 127.0.0.1 14501
kill -- "-$RECV" 2>/dev/null || true; RECV=""
otlp_assert "$TMP/grpc.txt" 'name: "spnl_method_calls_total"'   # the mock inflates the gzip message (grpc-encoding: gzip)
if grep -qi "meta x-test-token: tok-abcdef" "$TMP/grpc_recv.log"; then echo "  ok: gRPC auth metadata received"; else echo "  MISSING: grpc auth metadata"; OTLP_FAIL=1; fi

otlp_done "OTLP auth headers + gzip (HTTP & gRPC)"
