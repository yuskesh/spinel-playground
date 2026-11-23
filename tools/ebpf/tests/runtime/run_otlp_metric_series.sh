#!/usr/bin/env bash
#
# run_otlp_metric_series.sh — 汎用 keyed メトリクス (任意ラベル、--instrument 非依存、E271) の検証。
# 2 series (function=read/write + pid) を OTLP metrics で送り、受信側が name/labels/count を復元できることを確認。
# protobuf 経路 + JSON 経路の両方。
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
PROTO_ROOT="${OTEL_PROTO_DIR:-$REPO_ROOT/third_party/opentelemetry-proto}"  # otlp_decode (phase 3) が読む; Spinel Extended: OTEL_PROTO_DIR names the user-local pin
PORT="${OTLP_METRIC_PORT:-18491}"
TMP="$(mktemp -d)"
SRV=""
cleanup() { [ -n "$SRV" ] && kill -- "-$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

PB_C=$(find "$PB/opentelemetry" -name '*.pb.c' | sort)
echo "[metric] compiling generic keyed-metric test"
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -Werror -I "$NANOPB" -I "$PB" -I "$OTLP" \
  tests/runtime/otlp_metric_test.c \
  "$OTLP/otlp_metrics.c" "$OTLP/otlp_json.c" "$OTLP/otlp_http.c" "$OTLP/otlp_grpc.c" \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" $PB_C -lz -o "$TMP/m"

# E431: --append。この試験のプローブは rate と latency を **別リクエスト**で送るので、
# 上書きだと 1 本目 (rate) が消えて「送っていない」と区別がつかない。
start_mock() { setsid "$RUBY" tests/runtime/mock_otlp_receiver.rb --port "$PORT" --out "$1" --append \
  --protoc "$PROTOC" --repo-root "$REPO_ROOT" >"$2" 2>&1 & SRV=$!; }

echo "[metric] (1) protobuf: 任意ラベル + 2 series"
start_mock "$TMP/pb.txt" "$TMP/pb.log"
"$TMP/m" "http://127.0.0.1:$PORT"
kill -- "-$SRV" 2>/dev/null || true; SRV=""
echo "----- decoded (protobuf) -----"; sed -n '1,30p' "$TMP/pb.txt"; echo "------------------------------"
otlp_assert "$TMP/pb.txt" 'name: "probe_calls"'
otlp_assert "$TMP/pb.txt" 'name: "probe_latency_ns"'
otlp_assert "$TMP/pb.txt" 'key: "function"'
otlp_assert "$TMP/pb.txt" 'string_value: "read"'
otlp_assert "$TMP/pb.txt" 'string_value: "write"'
otlp_assert "$TMP/pb.txt" 'key: "pid"'
otlp_assert "$TMP/pb.txt" 'as_int: 5'
otlp_assert "$TMP/pb.txt" 'as_int: 7'

echo "[metric] (2) JSON: 任意ラベル"
start_mock "$TMP/json.txt" "$TMP/json.log"
OTEL_EXPORTER_OTLP_PROTOCOL=http/json "$TMP/m" "http://127.0.0.1:$PORT"
kill -- "-$SRV" 2>/dev/null || true; SRV=""
echo "----- decoded (json) -----"; cat "$TMP/json.txt"; echo; echo "--------------------------"
otlp_assert "$TMP/json.txt" '"probe_calls"'
otlp_assert "$TMP/json.txt" '"function"'
otlp_assert "$TMP/json.txt" '"read"'
otlp_assert "$TMP/json.txt" '"asInt":"5"'

echo "[metric] (3) 型別 build: 1 payload = 1 metric 型 (E429)"
# E291 は Splunk の HTTP 500 を型に切り分けられなかった。理由は series_build が Sum と
# ExponentialHistogram を必ず対で出すことで、「Sum だけなら通るのか」を作る手段が無かったから。
# E429 でその口を開けた (実測: Splunk /v2/datapoint/otlp は Sum/Gauge/明示バケット Histogram を
# 200 で受け、ExponentialHistogram だけ 500)。ここは「片方だけ作れる」ことが残っているかを見る。
"$TMP/m" --dump-kinds "$TMP" >/dev/null 2>&1
for k in gauge exphist; do
  otlp_decode opentelemetry.proto.collector.metrics.v1.ExportMetricsServiceRequest \
    opentelemetry/proto/collector/metrics/v1/metrics_service.proto "$TMP/$k.pb" "$TMP/$k.txt"
done
otlp_assert "$TMP/gauge.txt" 'gauge {'
otlp_count  "$TMP/gauge.txt" '    metrics {' 1   # 4 space = ScopeMetrics.metrics (resource_/scope_metrics と区別)
otlp_assert "$TMP/exphist.txt" 'exponential_histogram {'
otlp_count  "$TMP/exphist.txt" '    metrics {' 1
otlp_assert "$TMP/exphist.txt" 'offset: 10'
# Gauge に温度計 (Sum の temporality/monotonic) が紛れていないこと — 型を選べることの意味
if grep -q 'is_monotonic' "$TMP/gauge.txt"; then
  echo "  UNEXPECTED: Gauge に is_monotonic が出た"; OTLP_FAIL=1
else echo "  ok: Gauge は Sum ではない"; fi

otlp_done "OTLP 汎用 keyed メトリクス (任意ラベル、--instrument 非依存)"
