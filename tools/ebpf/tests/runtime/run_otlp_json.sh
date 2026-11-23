#!/usr/bin/env bash
#
# run_otlp_json.sh — OTLP/HTTP+JSON エンコーダ検証 (otlp_json.c)。
# metrics/traces/logs の JSON をサンプルから組み、ruby で妥当性 + 期待フィールドを確認。
# nanopb 非依存 (JSON 経路は protobuf を使わない)。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
. "$REPO_ROOT/tests/runtime/otlp_common.sh"

CC="${CC:-clang}"
RUBY="${RUBY:-ruby}"
OTLP="$REPO_ROOT/src/runtime/otlp"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[json] compiling otlp_json encoder test"
"$CC" -O2 -Wall -Wextra -Werror -I "$OTLP" \
  tests/runtime/otlp_json_test.c "$OTLP/otlp_json.c" -o "$TMP/jt"

# E402 (D3): OTEL_RESOURCE_ATTRIBUTES は protobuf 経路と JSON 経路で**同じ**でなければ
# ならない (jw_resource の宣言そのもの: 「protobuf 版 otlp_enc_resource_attrs と一致」)。
# JSON だけ操作者のラベルを落とす、が起き得る場所なので両方で pin する。
export OTEL_RESOURCE_ATTRIBUTES="deployment.environment=staging, spnl.e402 = yes ,broken-pair,=novalue"

for sig in metrics metrics_lat metrics_lat_hist traces logs; do
  "$TMP/jt" "$sig" > "$TMP/$sig.json"
  # Spinel Extended: CRuby's JSON parser checks the document (spinel-ebpf: python3's json).
  if "$RUBY" -rjson -e 'JSON.parse(File.read(ARGV[0]))' "$TMP/$sig.json" 2>/dev/null; then
    echo "  ok: $sig は valid JSON"
  else
    echo "  INVALID JSON: $sig"; OTLP_FAIL=1
  fi
done

# proto3 JSON mapping: 64bit は文字列、enum は数値、trace_id は hex
otlp_assert "$TMP/metrics.json" '"spnl_method_calls_total"'
otlp_assert "$TMP/metrics.json" '"asInt":"500"'
otlp_assert "$TMP/metrics.json" '"aggregationTemporality":2'
otlp_assert "$TMP/metrics.json" '"code.function"'
# E431: metrics は part ごとに 1 リクエスト。calls に latency は入らない。
if grep -q 'spnl_method_latency_ns' "$TMP/metrics.json"; then
  echo "  UNEXPECTED: calls の JSON に latency が同梱されている"; OTLP_FAIL=1
else echo "  ok: calls に latency は入っていない"; fi
otlp_assert "$TMP/metrics_lat.json" '"exponentialHistogram"'
otlp_assert "$TMP/metrics_lat.json" '"bucketCounts":["300","200"]'
# 明示バケット (bounds set log2_ns_31)。slot 10/11 -> bucket 10/11 に同じ数が出る。
otlp_assert "$TMP/metrics_lat_hist.json" '"histogram"'
otlp_assert "$TMP/metrics_lat_hist.json" '"explicitBounds"'
otlp_assert "$TMP/metrics_lat_hist.json" '"0","0","0","0","0","0","0","0","0","0","300","200"'
otlp_assert "$TMP/traces.json" '"traceId":"0102030405060708090a0b0c0d0e0f10"'
otlp_assert "$TMP/traces.json" '"spanId":"a0a1a2a3a4a5a6a7"'
otlp_assert "$TMP/traces.json" '"name":"add"'
otlp_assert "$TMP/logs.json" '"intValue":"42"'
otlp_assert "$TMP/logs.json" '"stringValue":"hello"'
otlp_assert "$TMP/logs.json" '"eventName":"evt"'
otlp_assert "$TMP/logs.json" '"severityText":"INFO"'

# E402 (D3): resource 属性は 3 シグナルすべてに乗る (protobuf 経路と同じ扱い)、
# trim される、不正なペアは落ちる。
for sig in metrics metrics_lat metrics_lat_hist traces logs; do
  otlp_assert "$TMP/$sig.json" '"deployment.environment"'
  otlp_assert "$TMP/$sig.json" '"stringValue":"staging"'
  otlp_assert "$TMP/$sig.json" '"spnl.e402"'
  otlp_assert "$TMP/$sig.json" '"telemetry.sdk.name"'   # 自分の identity は残る
  if grep -q "broken-pair" "$TMP/$sig.json"; then
    echo "  UNEXPECTED($sig): '=' の無いペアが属性になった"; OTLP_FAIL=1
  fi
  if grep -q "novalue" "$TMP/$sig.json"; then
    echo "  UNEXPECTED($sig): 空 key が属性になった"; OTLP_FAIL=1
  fi
done

otlp_done "OTLP/JSON encoders (metrics/traces/logs、proto3 JSON mapping)"
