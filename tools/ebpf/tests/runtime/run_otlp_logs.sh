#!/usr/bin/env bash
#
# run_otlp_logs.sh — ADR-012 / P003 S4: emit -> OTLP logs (LogRecord) の検証
#
# otlp_logs_build が吐く ExportLogsServiceRequest を `protoc --decode` で復元し、
# body (int/str) / severity / service が正しく組めているか assert する。
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

echo "[s4] compiling logs test"
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -Werror \
  -I "$NANOPB" -I "$PB" -I "$OTLP" \
  tests/runtime/otlp_logs_test.c \
  "$OTLP/otlp_logs.c" \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" \
  $PB_C \
  -o "$TMP/otlp_logs"

echo "[s4] building sample OTLP logs -> $TMP/out.pb"
"$TMP/otlp_logs" "$TMP/out.pb"

echo "[s4] decoding with protoc"
"$PROTOC" --decode=opentelemetry.proto.collector.logs.v1.ExportLogsServiceRequest \
  -I "$PROTO_ROOT" \
  opentelemetry/proto/collector/logs/v1/logs_service.proto \
  < "$TMP/out.pb" > "$TMP/decoded.txt"

echo "----- decoded -----"; cat "$TMP/decoded.txt"; echo "-------------------"

echo "[s4] asserting LogRecord mapping"
. "$REPO_ROOT/tests/runtime/otlp_common.sh"
assert() { otlp_assert "$TMP/decoded.txt" "$1"; }
count()  { otlp_count  "$TMP/decoded.txt" "$1" "$2"; }
assert 'int_value: 100'
assert 'int_value: 200'
assert 'int_value: 300'
assert 'string_value: "hello-from-emit"'
assert 'severity_number: SEVERITY_NUMBER_INFO'
assert 'severity_text: "INFO"'
assert 'string_value: "spinel-app"'
assert 'name: "spinel-ebpf"'
count 'log_records {' 4

otlp_done "emit events -> OTLP LogRecords"
