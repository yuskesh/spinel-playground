#!/usr/bin/env bash
#
# run_amp_ring.sh — P007 S1: M7<->A55 共有リング -> OTLP logs の host 検証。
#
# producer (amp_emit) が ADR-002 レコードをリングに書き、consumer が drain して
# OTLP ExportLogsServiceRequest を組む。SPSC の wrap/full-drop はテスト内 assert、
# 組んだ payload は protoc --decode で body/severity/service を検証する。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

CC="${CC:-clang}"
PROTOC="${PROTOC:-protoc}"
NANOPB="${NANOPB_DIR:-$REPO_ROOT/third_party/nanopb}"   # Spinel Extended: NANOPB_DIR names the user-local pin
PB="$REPO_ROOT/src/runtime/otlp/pb"
OTLP="$REPO_ROOT/src/runtime/otlp"
AMP="$REPO_ROOT/src/runtime/amp"
PROTO_ROOT="${OTEL_PROTO_DIR:-$REPO_ROOT/third_party/opentelemetry-proto}"   # Spinel Extended: OTEL_PROTO_DIR names the user-local pin
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PB_C=$(find "$PB/opentelemetry" -name '*.pb.c' | sort)

echo "[s1] compiling amp ring test"
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -Werror \
  -I "$REPO_ROOT/include" -I "$NANOPB" -I "$PB" -I "$OTLP" -I "$AMP" \
  tests/runtime/amp_ring_test.c \
  "$AMP/amp_otlp.c" \
  "$OTLP/otlp_logs.c" "$OTLP/otlp_traces.c" "$OTLP/otlp_metrics.c" \
  "$OTLP/otlp_json.c" "$OTLP/otlp_http.c" "$OTLP/otlp_grpc.c" \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" \
  $PB_C -lz \
  -o "$TMP/amp_ring"

echo "[s1] producer->ring->drain->OTLP logs -> $TMP/out.pb"
"$TMP/amp_ring" "$TMP/out.pb"

echo "[s1] decoding with protoc"
"$PROTOC" --decode=opentelemetry.proto.collector.logs.v1.ExportLogsServiceRequest \
  -I "$PROTO_ROOT" \
  opentelemetry/proto/collector/logs/v1/logs_service.proto \
  < "$TMP/out.pb" > "$TMP/decoded.txt"

echo "----- decoded -----"; cat "$TMP/decoded.txt"; echo "-------------------"

echo "[s1] asserting ring->LogRecord mapping (values 1,2,3 from amp_emit)"
. "$REPO_ROOT/tests/runtime/otlp_common.sh"
assert() { otlp_assert "$TMP/decoded.txt" "$1"; }
count()  { otlp_count  "$TMP/decoded.txt" "$1" "$2"; }
assert 'int_value: 1'
assert 'int_value: 2'
assert 'int_value: 3'
assert 'severity_number: SEVERITY_NUMBER_INFO'
assert 'string_value: "spinel-amp-m7"'
assert 'name: "spinel-amp-m7"'
count 'log_records {' 3

otlp_done "amp ring (ADR-002 records) -> A55 drain -> OTLP LogRecords"
