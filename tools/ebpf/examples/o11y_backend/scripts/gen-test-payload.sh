#!/bin/sh
# tests/payload_logs.textproto → tests/payload_logs.bin (E438)
# protoc + third_party/opentelemetry-proto (v1.10.0) で encode。container 内で実行。
set -e
base="$(cd "$(dirname "$0")/.." && pwd)"
proto_root="$base/../../third_party/opentelemetry-proto"
command -v protoc >/dev/null || { echo "gen-test-payload: protoc not found (apt-get install protobuf-compiler)" >&2; exit 1; }
protoc --encode=opentelemetry.proto.collector.logs.v1.ExportLogsServiceRequest \
  -I "$proto_root" \
  "$proto_root/opentelemetry/proto/collector/logs/v1/logs_service.proto" \
  < "$base/tests/payload_logs.textproto" \
  > "$base/tests/payload_logs.bin"
wc -c "$base/tests/payload_logs.bin"
