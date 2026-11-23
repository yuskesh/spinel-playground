#!/usr/bin/env bash
#
# run_otlp_roundtrip.sh — ADR-012 / P003 S0 の round-trip 検証
#
# nanopb で encode した OTLP bytes を `protoc --decode` に流し、期待フィールドが
# 復元されることを assert する。encode が壊れていれば decode が失敗 or フィールド欠落で落ちる。
#
# 使い方: sh tests/runtime/run_otlp_roundtrip.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

CC="${CC:-clang}"
PROTOC="${PROTOC:-protoc}"
NANOPB="${NANOPB_DIR:-$REPO_ROOT/third_party/nanopb}"   # Spinel Extended: NANOPB_DIR names the user-local pin
PB="$REPO_ROOT/src/runtime/otlp/pb"
PROTO_ROOT="${OTEL_PROTO_DIR:-$REPO_ROOT/third_party/opentelemetry-proto}"   # Spinel Extended: OTEL_PROTO_DIR names the user-local pin
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PB_C=$(find "$PB/opentelemetry" -name '*.pb.c' | sort)

echo "[s0] compiling round-trip test (nanopb: pb_encode.c + pb_common.c)"
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -Werror \
  -I "$NANOPB" -I "$PB" \
  tests/runtime/otlp_roundtrip_test.c \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" \
  $PB_C \
  -o "$TMP/otlp_roundtrip"

echo "[s0] running encoder -> $TMP/out.pb"
"$TMP/otlp_roundtrip" "$TMP/out.pb"

echo "[s0] decoding with protoc ($($PROTOC --version))"
"$PROTOC" --decode=opentelemetry.proto.collector.metrics.v1.ExportMetricsServiceRequest \
  -I "$PROTO_ROOT" \
  opentelemetry/proto/collector/metrics/v1/metrics_service.proto \
  < "$TMP/out.pb" > "$TMP/decoded.txt"

echo "----- decoded -----"
cat "$TMP/decoded.txt"
echo "-------------------"

echo "[s0] asserting expected fields round-tripped"
. "$REPO_ROOT/tests/runtime/otlp_common.sh"
assert() { otlp_assert "$TMP/decoded.txt" "$1"; }
assert 'key: "service.name"'
assert 'string_value: "spinel-app"'
assert 'name: "spinel-ebpf"'
assert 'name: "spnl_method_calls_total"'
assert 'as_int: 500'
assert 'key: "code.function"'
assert 'string_value: "fib"'
assert 'is_monotonic: true'
assert 'aggregation_temporality: AGGREGATION_TEMPORALITY_CUMULATIVE'
assert 'time_unix_nano: 1700000000000000000'

otlp_done "OTLP nanopb encode round-trips through protoc --decode"
