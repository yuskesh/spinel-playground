#!/usr/bin/env bash
#
# run_otlp_metrics.sh — ADR-012 / P003 S2: per-method RED -> OTLP metrics の検証
#
# otlp_metrics_method_build が吐く ExportMetricsServiceRequest を `protoc --decode` で復元し、
# 3 つの part (Sum / ExponentialHistogram / 明示バケット Histogram) を assert する。
# E431: **1 リクエスト = 1 metric**。ここで一番効いている検査は「calls の payload に
# latency が入っていない」ことで、それが入っていたせいで Splunk の 500 が rate を
# 道連れにしていた (E429)。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

CC="${CC:-clang}"
PROTOC="${PROTOC:-protoc}"
NANOPB="${NANOPB_DIR:-$REPO_ROOT/third_party/nanopb}"   # Spinel Extended: NANOPB_DIR names the user-local pin
PB="$REPO_ROOT/src/runtime/otlp/pb"
OTLP="$REPO_ROOT/src/runtime/otlp"
PROTO_ROOT="${OTEL_PROTO_DIR:-$REPO_ROOT/third_party/opentelemetry-proto}"   # Spinel Extended: OTEL_PROTO_DIR names the user-local pin
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PB_C=$(find "$PB/opentelemetry" -name '*.pb.c' | sort)

echo "[s2] compiling metrics encoder test"
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -Werror \
  -I "$NANOPB" -I "$PB" -I "$OTLP" \
  tests/runtime/otlp_metrics_test.c \
  "$OTLP/otlp_metrics.c" "$OTLP/otlp_http.c" "$OTLP/otlp_grpc.c" "$OTLP/otlp_json.c" \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" \
  $PB_C \
  -lz \
  -o "$TMP/otlp_metrics"

# E402 (D3): 操作者のラベル。値は下の assert で wire から突き合わせる。
export OTEL_RESOURCE_ATTRIBUTES="deployment.environment=staging, spnl.e402 = yes ,broken-pair,=novalue"
echo "[s2] building sample OTLP parts -> $TMP"
"$TMP/otlp_metrics" "$TMP"

echo "[s2] decoding with protoc"
. "$REPO_ROOT/tests/runtime/otlp_common.sh"
for k in calls latency_exp latency_hist; do
  "$PROTOC" --decode=opentelemetry.proto.collector.metrics.v1.ExportMetricsServiceRequest \
    -I "$PROTO_ROOT" \
    opentelemetry/proto/collector/metrics/v1/metrics_service.proto \
    < "$TMP/$k.pb" > "$TMP/$k.txt"
done
cp "$TMP/calls.txt" "$TMP/decoded.txt"   # resource 属性の assert はどの part でも同じ

echo "----- decoded (calls) -----"; cat "$TMP/calls.txt"; echo "---------------------------"

echo "[s2] asserting: 1 request = 1 metric (E431)"
assert() { otlp_assert "$TMP/decoded.txt" "$1"; }
# calls の payload に latency が**入っていない** — これが同梱をやめたということ。
otlp_assert "$TMP/calls.txt" 'name: "spnl_method_calls_total"'
otlp_count  "$TMP/calls.txt" '    metrics {' 1
if grep -q 'spnl_method_latency_ns' "$TMP/calls.txt"; then
  echo "  UNEXPECTED: calls の payload に latency が同梱されている"; OTLP_FAIL=1
else echo "  ok: calls に latency は入っていない"; fi
otlp_assert "$TMP/latency_exp.txt" 'name: "spnl_method_latency_ns"'
otlp_count  "$TMP/latency_exp.txt" '    metrics {' 1
if grep -q 'spnl_method_calls_total' "$TMP/latency_exp.txt"; then
  echo "  UNEXPECTED: latency の payload に calls が同梱されている"; OTLP_FAIL=1
else echo "  ok: latency に calls は入っていない"; fi

echo "[s2] asserting Sum data points"
otlp_assert "$TMP/calls.txt" 'as_int: 177'
otlp_assert "$TMP/calls.txt" 'as_int: 500'
otlp_assert "$TMP/calls.txt" 'is_monotonic: true'
otlp_assert "$TMP/calls.txt" 'aggregation_temporality: AGGREGATION_TEMPORALITY_CUMULATIVE'

echo "[s2] asserting ExponentialHistogram (log2 -> scale=0)"
otlp_assert "$TMP/latency_exp.txt" 'exponential_histogram {'
otlp_assert "$TMP/latency_exp.txt" 'unit: "ns"'
otlp_assert "$TMP/latency_exp.txt" 'offset: 9'
otlp_assert "$TMP/latency_exp.txt" 'offset: 10'
otlp_assert "$TMP/latency_exp.txt" 'bucket_counts: 100'
otlp_assert "$TMP/latency_exp.txt" 'bucket_counts: 77'
otlp_assert "$TMP/latency_exp.txt" 'bucket_counts: 500'
otlp_assert "$TMP/latency_exp.txt" 'count: 177'
otlp_assert "$TMP/latency_exp.txt" 'count: 500'
# sum 近似 (Σ count_s * 1.5*2^s)
otlp_assert "$TMP/latency_exp.txt" 'sum: 313344'
otlp_assert "$TMP/latency_exp.txt" 'sum: 768000'

echo "[s2] asserting explicit-bucket Histogram (bounds set log2_ns_31、E431)"
otlp_assert "$TMP/latency_hist.txt" 'histogram {'
otlp_assert "$TMP/latency_hist.txt" 'unit: "ns"'
# 境界は log2 slot の上端 2^(k+1)-1。1048575 = 2^20-1 は **生成器の %g バグが
# 1.04858e+06 (= 1048580) に丸めていた**値で、丸まると slot 20 の下 5 個が隣の
# バケットに移り「1 バケット = 連続した slot まるごと」が静かに嘘になる (E431)。
otlp_assert "$TMP/latency_hist.txt" 'explicit_bounds: 1048575'
otlp_assert "$TMP/latency_hist.txt" 'explicit_bounds: 34359738367'
otlp_count  "$TMP/latency_hist.txt" 'explicit_bounds:' 62   # 31 境界 x 2 data point
otlp_count  "$TMP/latency_hist.txt" 'bucket_counts:' 64     # 32 バケット x 2 data point
# **同じ数**が bucket 9 / 11 / 10 に出ること — 型を替えても件数は割れない
# (E431 D1: 3 分布 60 万標本で slot 別カウントと bucket 別カウントの不一致 0)
otlp_assert "$TMP/latency_hist.txt" 'bucket_counts: 100'
otlp_assert "$TMP/latency_hist.txt" 'bucket_counts: 77'
otlp_assert "$TMP/latency_hist.txt" 'bucket_counts: 500'
otlp_assert "$TMP/latency_hist.txt" 'count: 177'
otlp_assert "$TMP/latency_hist.txt" 'count: 500'
# sum は表現を替えても動かない (ExponentialHistogram 経路と同じ近似規約)
otlp_assert "$TMP/latency_hist.txt" 'sum: 313344'
otlp_assert "$TMP/latency_hist.txt" 'sum: 768000'

# Resource / code.* 属性
assert 'string_value: "spinel-app"'
assert 'key: "code.function"'
# E402 (D3): OTEL_RESOURCE_ATTRIBUTES — OTel 標準の「この生産者にラベルを付ける」env。
# E402 以前は未対応 (OTEL_SERVICE_NAME だけ) で、それが Tetragon の `tags` に相当する穴
# だった。独自語彙を作らずに標準の口を開けた、その回帰。protobuf 側の resource encoder
# (otlp_enc_resource_attrs) を通るのはこの試験なのでここに置く — run_otlp_send.sh は
# payload を手組みするので resource encoder を通らず、run_otlp_extras.sh は grpcio が
# 無いと**丸ごと SKIP** する (どちらも実測、黙って走らない検査になる)。
# 不正なペアを 2 つ混ぜてあるのは意図的 ('=' 無し / 空 key)。
assert 'key: "deployment.environment"'
assert 'string_value: "staging"'
assert 'key: "spnl.e402"'
assert 'string_value: "yes"'          # 前後空白は trim される
assert 'key: "telemetry.sdk.name"'    # 自分の identity は残る (ラベルは後置)
if grep -q "broken-pair" "$TMP/decoded.txt"; then
  echo "  UNEXPECTED: '=' の無いペアが属性になった"; OTLP_FAIL=1
else echo "  ok: '=' 無しのペアは捨てられた"; fi
if grep -q "novalue" "$TMP/decoded.txt"; then
  echo "  UNEXPECTED: 空 key が属性になった"; OTLP_FAIL=1
else echo "  ok: 空 key は捨てられた"; fi
assert 'string_value: "fib"'
assert 'string_value: "add"'
assert 'key: "code.lineno"'
assert 'int_value: 19'

otlp_done "per-method RED -> OTLP Sum + ExponentialHistogram"
