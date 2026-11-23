#!/usr/bin/env bash
#
# run_otlp_xlayer.sh — E274: L2–L8 横断・単一レコード相関の検証。
# 実 loopback fd から SERVER span を組み、L3(client.address)/L4(server.port +
# net.tcp.established/state_changes)/L7(method/route/status)/L8(tenant)/trace 継承が
# **1 span (1 record) に同居**することを JSON で確認する。libbpf 非依存 (span builder 経路)。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
. "$REPO_ROOT/tests/runtime/otlp_common.sh"

CC="${CC:-clang}"
RUBY="${RUBY:-ruby}"
NANOPB="${NANOPB_DIR:-$REPO_ROOT/third_party/nanopb}"   # Spinel Extended: NANOPB_DIR names the user-local pin
PB="$REPO_ROOT/src/runtime/otlp/pb"
OTLP="$REPO_ROOT/src/runtime/otlp"
PORT="${OTLP_XLAYER_PORT:-18491}"
TP="00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
TMP="$(mktemp -d)"
SRV=""
cleanup() { [ -n "$SRV" ] && kill -- "-$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

PB_C=$(find "$PB/opentelemetry" -name '*.pb.c' | sort)
echo "[xlayer] compiling cross-layer span test"
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -Werror -I "$NANOPB" -I "$PB" -I "$OTLP" \
  tests/runtime/otlp_xlayer_span_test.c \
  "$OTLP/otlp_httpspan.c" "$OTLP/otlp_traces.c" "$OTLP/otlp_metrics.c" "$OTLP/otlp_json.c" \
  "$OTLP/otlp_http.c" "$OTLP/otlp_grpc.c" \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" $PB_C -lz -o "$TMP/xlayer"

start_mock() { setsid "$RUBY" tests/runtime/mock_otlp_receiver.rb --port "$PORT" --out "$1" \
  --protoc "${PROTOC:-protoc}" --repo-root "$REPO_ROOT" >"$2" 2>&1 & SRV=$!; }

echo "[xlayer] (JSON) 1 span に L3/L4 + L7 + L8 が同居 + traceId 継承"
start_mock "$TMP/json.txt" "$TMP/json.log"
sleep 0.4
OTEL_EXPORTER_OTLP_PROTOCOL=http/json "$TMP/xlayer" "http://127.0.0.1:$PORT" "$TP" "acme" 1 3 200
sleep 0.2
kill -- "-$SRV" 2>/dev/null || true; SRV=""
echo "----- correlated record (json) -----"; cat "$TMP/json.txt"; echo; echo "------------------------------------"
# L7
otlp_assert "$TMP/json.txt" '"kind":2'                       # SERVER span
otlp_assert "$TMP/json.txt" '"http.request.method"'
otlp_assert "$TMP/json.txt" '"url.path"'
otlp_assert "$TMP/json.txt" '"http.route"'
otlp_assert "$TMP/json.txt" '"http.response.status_code"'
# L3 / L4 (アドレッシング + 横断 4-tuple keyed メトリクス)
otlp_assert "$TMP/json.txt" '"client.address"'              # L3 src ip
otlp_assert "$TMP/json.txt" '"server.port"'                 # L4 dst port
otlp_assert "$TMP/json.txt" '"net.tcp.established"'         # L4 4-tuple keyed
otlp_assert "$TMP/json.txt" '"net.tcp.state_changes"'      # L4 4-tuple keyed
# L8 (ビジネス文脈) + trace 継承
otlp_assert "$TMP/json.txt" '"tenant"'
otlp_assert "$TMP/json.txt" '"stringValue":"acme"'
otlp_assert "$TMP/json.txt" '"traceId":"4bf92f3577b34da6a3ce929d0e0e4736"'   # incoming trace 継続
otlp_assert "$TMP/json.txt" '"parentSpanId":"00f067aa0ba902b7"'

echo "[xlayer] (protobuf) 同じ属性が protobuf 経路でも出る"
start_mock "$TMP/pb.txt" "$TMP/pb.log"
sleep 0.4
"$TMP/xlayer" "http://127.0.0.1:$PORT" "$TP" "acme" 2 5 200
sleep 0.2
kill -- "-$SRV" 2>/dev/null || true; SRV=""
echo "----- correlated record (protobuf) -----"; sed -n '1,80p' "$TMP/pb.txt"; echo "----------------------------------------"
otlp_assert "$TMP/pb.txt" 'key: "tenant"'
otlp_assert "$TMP/pb.txt" 'string_value: "acme"'
otlp_assert "$TMP/pb.txt" 'key: "net.tcp.established"'
otlp_assert "$TMP/pb.txt" 'key: "net.tcp.state_changes"'
otlp_assert "$TMP/pb.txt" 'key: "client.address"'
otlp_assert "$TMP/pb.txt" 'key: "server.port"'

if [ "$OTLP_FAIL" = 0 ]; then echo "[xlayer] PASS"; else echo "[xlayer] FAIL"; exit 1; fi
