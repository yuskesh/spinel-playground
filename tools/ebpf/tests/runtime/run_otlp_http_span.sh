#!/usr/bin/env bash
#
# run_otlp_http_span.sh — HTTP server span + W3C traceparent 伝播の検証 (P003)。
# 既知の traceparent を渡して SERVER span を送り、受信側 (mock) が trace_id/parent/kind/http.* を
# 復元できることを確認。protobuf 経路 (属性/kind/name) と JSON 経路 (hex trace_id/parent 完全一致) の両方。
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
PORT="${OTLP_SPAN_PORT:-18488}"
TP="00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
TMP="$(mktemp -d)"
SRV=""
cleanup() { [ -n "$SRV" ] && kill -- "-$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

PB_C=$(find "$PB/opentelemetry" -name '*.pb.c' | sort)
echo "[span] compiling http-span test"
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -Werror -I "$NANOPB" -I "$PB" -I "$OTLP" \
  tests/runtime/otlp_http_span_test.c \
  "$OTLP/otlp_httpspan.c" "$OTLP/otlp_traces.c" "$OTLP/otlp_metrics.c" "$OTLP/otlp_json.c" \
  "$OTLP/otlp_http.c" "$OTLP/otlp_grpc.c" \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" $PB_C -lz -o "$TMP/span"

start_mock() { setsid "$RUBY" tests/runtime/mock_otlp_receiver.rb --port "$PORT" --out "$1" \
  --protoc "$PROTOC" --repo-root "$REPO_ROOT" >"$2" 2>&1 & SRV=$!; }

echo "[span] (1) protobuf: SERVER span + http.* 属性 + name + OBI/semconv 追加属性 + resource sdk 属性"
start_mock "$TMP/pb.txt" "$TMP/pb.log"
"$TMP/span" "http://127.0.0.1:$PORT" "$TP" 200 /hello
kill -- "-$SRV" 2>/dev/null || true; SRV=""
echo "----- decoded (protobuf) -----"; sed -n '1,60p' "$TMP/pb.txt"; echo "------------------------------"
otlp_assert "$TMP/pb.txt" 'name: "GET /hello"'
otlp_assert "$TMP/pb.txt" 'kind: SPAN_KIND_SERVER'
otlp_assert "$TMP/pb.txt" 'key: "http.request.method"'
otlp_assert "$TMP/pb.txt" 'string_value: "GET"'
otlp_assert "$TMP/pb.txt" 'key: "url.path"'
otlp_assert "$TMP/pb.txt" 'string_value: "/hello"'
otlp_assert "$TMP/pb.txt" 'int_value: 200'
# E272: OBI/semconv v1.41.0 互換の追加属性
otlp_assert "$TMP/pb.txt" 'key: "server.address"'
otlp_assert "$TMP/pb.txt" 'string_value: "127.0.0.1"'
otlp_assert "$TMP/pb.txt" 'key: "server.port"'
otlp_assert "$TMP/pb.txt" 'key: "client.address"'
otlp_assert "$TMP/pb.txt" 'key: "url.scheme"'
otlp_assert "$TMP/pb.txt" 'string_value: "http"'
otlp_assert "$TMP/pb.txt" 'key: "http.route"'
# E272: resource 属性 (全シグナル共通)
otlp_assert "$TMP/pb.txt" 'key: "service.instance.id"'
otlp_assert "$TMP/pb.txt" 'key: "telemetry.sdk.name"'
otlp_assert "$TMP/pb.txt" 'string_value: "spinel-ebpf"'
otlp_assert "$TMP/pb.txt" 'key: "telemetry.sdk.language"'
otlp_assert "$TMP/pb.txt" 'string_value: "ruby"'

echo "[span] (2) JSON: traceId/parentSpanId が incoming traceparent と完全一致 (伝播の証明)"
start_mock "$TMP/json.txt" "$TMP/json.log"
OTEL_EXPORTER_OTLP_PROTOCOL=http/json "$TMP/span" "http://127.0.0.1:$PORT" "$TP" 200 /hello
kill -- "-$SRV" 2>/dev/null || true; SRV=""
echo "----- decoded (json) -----"; cat "$TMP/json.txt"; echo; echo "--------------------------"
otlp_assert "$TMP/json.txt" '"traceId":"4bf92f3577b34da6a3ce929d0e0e4736"'   # incoming trace を継続
otlp_assert "$TMP/json.txt" '"parentSpanId":"00f067aa0ba902b7"'              # incoming span が親
otlp_assert "$TMP/json.txt" '"kind":2'
otlp_assert "$TMP/json.txt" '"http.request.method"'
otlp_assert "$TMP/json.txt" '"url.path"'
otlp_assert "$TMP/json.txt" '"server.address"'
otlp_assert "$TMP/json.txt" '"url.scheme"'
otlp_assert "$TMP/json.txt" '"http.route"'
otlp_assert "$TMP/json.txt" '"service.instance.id"'
otlp_assert "$TMP/json.txt" '"telemetry.sdk.name"'

echo "[span] (3) protobuf: status=500 で Span.status = STATUS_CODE_ERROR"
start_mock "$TMP/err.txt" "$TMP/err.log"
"$TMP/span" "http://127.0.0.1:$PORT" "$TP" 500 /boom || true
kill -- "-$SRV" 2>/dev/null || true; SRV=""
echo "----- decoded (protobuf, 500) -----"; sed -n '1,60p' "$TMP/err.txt"; echo "-----------------------------------"
otlp_assert "$TMP/err.txt" 'code: STATUS_CODE_ERROR'
otlp_assert "$TMP/err.txt" 'int_value: 500'

otlp_done "OTLP HTTP server span + W3C traceparent 伝播 + OBI/semconv v1.41.0 整合"
