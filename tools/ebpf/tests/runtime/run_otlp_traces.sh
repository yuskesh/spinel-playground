#!/usr/bin/env bash
#
# run_otlp_traces.sh — ADR-012 / P003 S3: span 組み立て + OTLP traces 変換の検証
#
# otlp_traces_test が C レベルで木構造を assert し、OTLP bytes を出す。それを `protoc --decode`
# して span 名 / parent_span_id / code.* / service.name を確認する。
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

echo "[s3] compiling traces test"
# shellcheck disable=SC2086
"$CC" -O2 -Wall -Wextra -Werror \
  -I "$NANOPB" -I "$PB" -I "$OTLP" \
  tests/runtime/otlp_traces_test.c \
  "$OTLP/otlp_traces.c" \
  "$NANOPB/pb_encode.c" "$NANOPB/pb_common.c" \
  $PB_C \
  -o "$TMP/otlp_traces"

echo "[s3] assembling + encoding -> $TMP/out.pb"
"$TMP/otlp_traces" "$TMP/out.pb"

echo "[s3] decoding with protoc"
"$PROTOC" --decode=opentelemetry.proto.collector.trace.v1.ExportTraceServiceRequest \
  -I "$PROTO_ROOT" \
  opentelemetry/proto/collector/trace/v1/trace_service.proto \
  < "$TMP/out.pb" > "$TMP/decoded.txt"

echo "----- decoded -----"; cat "$TMP/decoded.txt"; echo "-------------------"

echo "[s3] asserting span tree round-tripped"
. "$REPO_ROOT/tests/runtime/otlp_common.sh"
assert() { otlp_assert "$TMP/decoded.txt" "$1"; }
count()  { otlp_count  "$TMP/decoded.txt" "$1" "$2"; }
assert 'name: "driver"'
assert 'name: "add"'
assert 'name: "square"'
assert 'kind: SPAN_KIND_INTERNAL'
assert 'parent_span_id:'
assert 'key: "code.function"'
assert 'string_value: "spinel-app"'
count 'name: "driver"' 1
count 'parent_span_id:' 2

otlp_done "method call tree -> OTLP spans (parent-linked, single trace)"
