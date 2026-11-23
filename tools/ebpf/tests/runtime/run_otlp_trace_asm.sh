#!/usr/bin/env bash
#
# run_otlp_trace_asm.sh — E312: マルチ span トレース組み立て (層 2) の host 検証
#
# otlp_trace_asm_test が C レベルで木構造 (共通 trace_id / 親子 / kind / nest / traceparent 継承)
# を assert し、/sleep の 2 span を OTLP bytes に出す。それを protoc --decode して
# span 名 / parent_span_id / kind / 単一 trace / service.name を確認する。
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

echo "[e312] compiling trace-assembler test"
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -Werror \
  -I "$NANOPB" -I "$PB" -I "$OTLP" \
  tests/runtime/otlp_trace_asm_test.c \
  "$OTLP/otlp_traces.c" \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" \
  $PB_C \
  -o "$TMP/otlp_trace_asm"

echo "[e312] assembling + encoding -> $TMP/out.pb"
"$TMP/otlp_trace_asm" "$TMP/out.pb"

echo "[e312] decoding with protoc"
"$PROTOC" --decode=opentelemetry.proto.collector.trace.v1.ExportTraceServiceRequest \
  -I "$PROTO_ROOT" \
  opentelemetry/proto/collector/trace/v1/trace_service.proto \
  < "$TMP/out.pb" > "$TMP/decoded.txt"

echo "----- decoded -----"; cat "$TMP/decoded.txt"; echo "-------------------"

echo "[e312] asserting 2-span tree round-tripped"
. "$REPO_ROOT/tests/runtime/otlp_common.sh"
assert() { otlp_assert "$TMP/decoded.txt" "$1"; }
count()  { otlp_count  "$TMP/decoded.txt" "$1" "$2"; }
assert 'name: "GET /sleep"'
assert 'name: "off-CPU wait (sleep)"'
assert 'kind: SPAN_KIND_SERVER'
assert 'kind: SPAN_KIND_INTERNAL'
assert 'parent_span_id:'
assert 'string_value: "spinel-e312-test"'
count 'parent_span_id:' 1     # child のみ parent を持つ (parent は root)
count 'trace_id:' 2           # 親子 2 span、trace_id は同値だが行としては 2 回出力

otlp_done "off-CPU record -> 2-span tree (parent SERVER + child INTERNAL, single trace)"
