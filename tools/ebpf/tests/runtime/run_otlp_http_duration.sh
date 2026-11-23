#!/usr/bin/env bash
#
# run_otlp_http_duration.sh — http.server.request.duration (秒・OBI 同一バケット) の検証 (E272 S2)。
# 既知 duration の span を記録 → メトリクス push。受信側 (mock) が明示バケット Histogram の
# name/unit/explicit_bounds/正しいバケット/属性を復元できることを protobuf + JSON 両方で確認。
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
PORT="${OTLP_DUR_PORT:-18489}"
TMP="$(mktemp -d)"
SRV=""
cleanup() { [ -n "$SRV" ] && kill -- "-$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

PB_C=$(find "$PB/opentelemetry" -name '*.pb.c' | sort)
echo "[dur] compiling http-duration test"
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -Werror -I "$NANOPB" -I "$PB" -I "$OTLP" \
  tests/runtime/otlp_http_duration_test.c \
  "$OTLP/otlp_httpspan.c" "$OTLP/otlp_traces.c" "$OTLP/otlp_metrics.c" "$OTLP/otlp_json.c" \
  "$OTLP/otlp_http.c" "$OTLP/otlp_grpc.c" \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" $PB_C -lz -o "$TMP/dur"

start_mock() { setsid "$RUBY" tests/runtime/mock_otlp_receiver.rb --port "$PORT" --out "$1" \
  --protoc "$PROTOC" --repo-root "$REPO_ROOT" >"$2" 2>&1 & SRV=$!; }

echo "[dur] (1) protobuf: explicit-bounds Histogram + 属性"
start_mock "$TMP/pb.txt" "$TMP/pb.log"
"$TMP/dur" "http://127.0.0.1:$PORT"
kill -- "-$SRV" 2>/dev/null || true; SRV=""
echo "----- decoded (protobuf) -----"; sed -n '1,80p' "$TMP/pb.txt"; echo "------------------------------"
otlp_assert "$TMP/pb.txt" 'name: "http.server.request.duration"'
otlp_assert "$TMP/pb.txt" 'unit: "s"'
otlp_assert "$TMP/pb.txt" 'explicit_bounds: 0.005'
otlp_assert "$TMP/pb.txt" 'explicit_bounds: 2.5'
otlp_assert "$TMP/pb.txt" 'count: 2'   # series A (/fast x2)
otlp_assert "$TMP/pb.txt" 'count: 1'   # series B (/slow x1)
otlp_assert "$TMP/pb.txt" 'key: "http.request.method"'
otlp_assert "$TMP/pb.txt" 'string_value: "GET"'
otlp_assert "$TMP/pb.txt" 'key: "http.route"'
otlp_assert "$TMP/pb.txt" 'string_value: "/fast"'
otlp_assert "$TMP/pb.txt" 'string_value: "/slow"'
otlp_assert "$TMP/pb.txt" 'key: "http.response.status_code"'
otlp_assert "$TMP/pb.txt" 'string_value: "200"'
otlp_assert "$TMP/pb.txt" 'aggregation_temporality: AGGREGATION_TEMPORALITY_CUMULATIVE'

echo "[dur] (2) JSON: 正しいバケットに count (3ms->idx1, 1.2s->idx11) が入っている"
start_mock "$TMP/json.txt" "$TMP/json.log"
OTEL_EXPORTER_OTLP_PROTOCOL=http/json "$TMP/dur" "http://127.0.0.1:$PORT"
kill -- "-$SRV" 2>/dev/null || true; SRV=""
echo "----- decoded (json) -----"; cat "$TMP/json.txt"; echo; echo "--------------------------"
"$RUBY" -rjson - "$TMP/json.txt" <<'RBEOF'
def check(ok, what) = ok || abort("FAIL: #{what}")
d = JSON.parse(File.read(ARGV[0]))
m = d["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]
check(m["name"] == "http.server.request.duration", m["name"])
check(m["unit"] == "s", m["unit"])
h = m["histogram"]
check(h["aggregationTemporality"] == 2, h["aggregationTemporality"])
bounds = [0, 0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 7.5, 10]
by_route = {}
h["dataPoints"].each do |dp|
  attrs = dp["attributes"].to_h { |a| [a["key"], a["value"]["stringValue"]] }
  by_route[attrs["http.route"]] = dp
  # explicit bounds は OBI 既定と一致
  check(dp["explicitBounds"].map { |x| Float(x) } == bounds, dp["explicitBounds"])
  # bucketCounts の長さ = 境界数 + 1
  check(dp["bucketCounts"].size == bounds.size + 1, dp["bucketCounts"].size)
  check(attrs["http.request.method"] == "GET", attrs)
  check(attrs["http.response.status_code"] == "200", attrs)
end
fast = by_route.fetch("/fast")
slow = by_route.fetch("/slow")
# 3ms=0.003 -> (0, 0.005] = index 1、1.2s -> (1, 2.5] = index 11
check(fast["count"] == "2", fast["count"])
check(fast["bucketCounts"][1] == "2", fast["bucketCounts"])
check(fast["bucketCounts"].sum { |x| Integer(x) } == 2, fast["bucketCounts"])
check(slow["count"] == "1", slow["count"])
check(slow["bucketCounts"][11] == "1", slow["bucketCounts"])
check(slow["bucketCounts"].sum { |x| Integer(x) } == 1, slow["bucketCounts"])
puts "  ok: /fast count=2 bucket[1]=2 (3ms -> (0,0.005])"
puts "  ok: /slow count=1 bucket[11]=1 (1.2s -> (1,2.5])"
puts "  ok: explicitBounds == OBI 既定、bucketCounts 長 = 16、属性 method/route/status"
RBEOF

otlp_done "OTLP http.server.request.duration (秒・OBI 同一バケット、E272 S2)"
